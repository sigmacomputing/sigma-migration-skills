#!/usr/bin/env ruby
# frozen_string_literal: true
# Orchestrator reuse-check (C3) paths run for real (every script is a child process) against an in-memory fake of
# Sigma (test/support/fake_net.rb): no match -> create, match -> stop, --reuse-dm (no POST), --new-dm (waiver in
# the verdict), and stale dm-mode.json / dm-match.json files never standing in for a fresh scan.
# No network, no credentials.
#
#   ruby test/test-migrate-live-paths.rb

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'
require 'fileutils'
require_relative 'support/fake_run'
require_relative '../scripts/lib/degradation_ledger'
require_relative '../scripts/post-omni-dm'

class MigrateLivePathsTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/migrate-omni.rb', __dir__)
  FIXTURE = FakeRun::FIXTURE

  # -> [stdout, stderr, status, workdir, state_dir]
  def migrate(root, *args, env: {})
    state = File.join(root, 'state')
    wd = File.join(root, 'wd')
    FileUtils.mkdir_p(state)
    o, e, st = Open3.capture3(FakeRun.env(state, extra: env), RbConfig.ruby, SCRIPT,
                              '--model-dir', FIXTURE, '--export', File.join(FIXTURE, 'dashboard-export.json'),
                              '--topic', 'orders', '--connection-id', 'conn', '--folder-id', 'fold',
                              '--workdir', wd, *args)
    [o.dup.force_encoding('UTF-8'), e.dup.force_encoding('UTF-8'), st, wd, state] # independent of the caller's locale
  end

  def json(wd, f)
    JSON.parse(File.read(File.join(wd, f), encoding: 'UTF-8'))
  end

  def dm_posts(state)
    FakeRun.count(state, 'POST', '/v2/dataModels/spec')
  end

  def test_no_reusable_dm_creates_one_and_proceeds_past_reuse_check
    Dir.mktmpdir do |root|
      _o, err, _st, wd, state = migrate(root)
      refute_match(/FATAL: (reuse-check|post-dm)/, err, err)
      assert_equal({ 'mode' => 'create' }, json(wd, 'dm-mode.json'))
      assert_equal 1, dm_posts(state)
      assert_equal 'dm-1', json(wd, 'dm-elements.json').values.first['dataModelId']
      assert File.file?(File.join(wd, 'wb-envelope.json')), 'the workbook was built on the posted DM'
      assert_match(/"dm-1"/, File.read(File.join(wd, 'wb-envelope.json'), encoding: 'UTF-8'))
    end
  end

  def test_a_matching_dm_stops_the_run_and_never_posts_a_duplicate
    Dir.mktmpdir do |root|
      migrate(root) # creates dm-1
      assert_equal 1, dm_posts(File.join(root, 'state'))
      # dm-mode.json from the first run is still on disk: the scan must run anyway (re-run bypass)
      assert File.file?(File.join(root, 'wd', 'dm-mode.json'))
      _o, err, st, _wd, state = migrate(root)
      assert_equal 1, st.exitstatus
      assert_match(/FATAL: reuse-check: data model dm-1 .*already covers/, err)
      assert_match(/--reuse-dm dm-1/, err)
      assert_match(/--new-dm/, err)
      refute File.exist?(File.join(root, 'wd', 'dm-mode.json')), 'stale create mode was removed'
      assert_equal 1, dm_posts(state), 'no duplicate DM was posted'
    end
  end

  def test_a_stale_extend_mode_file_is_never_honoured
    Dir.mktmpdir do |root|
      wd = File.join(root, 'wd')
      FileUtils.mkdir_p(wd)
      File.write(File.join(wd, 'dm-mode.json'), JSON.generate('mode' => 'extend', 'dataModelId' => 'dm-stale'))
      _o, err, _st, wd, state = migrate(root)
      refute_match(/FATAL: (reuse-check|post-dm)/, err, err)
      assert_equal({ 'mode' => 'create' }, json(wd, 'dm-mode.json'), 'the scan result replaced the stale file')
      assert_equal 0, FakeRun.count(state, 'PUT', '/v2/dataModels/'), 'nothing was PUT into the stale id'
      assert_equal 1, dm_posts(state)
    end
  end

  def test_reuse_dm_builds_on_the_existing_dm_without_posting_one
    Dir.mktmpdir do |root|
      migrate(root)
      _o, err, _st, wd, state = migrate(root, '--reuse-dm', 'dm-1')
      refute_match(/FATAL: (reuse-check|post-dm)/, err, err)
      assert_equal 1, dm_posts(state), 'still only the first run POSTed a DM'
      assert_equal 0, FakeRun.count(state, 'PUT', '/v2/dataModels/'), 'a reused DM is never written'
      assert_equal({ 'mode' => 'reuse', 'dataModelId' => 'dm-1', 'chosen_by' => '--reuse-dm' }, json(wd, 'dm-mode.json'))
      assert_equal 'dm-1', json(wd, 'dm-elements.json').values.first['dataModelId']
      assert File.file?(File.join(wd, 'wb-envelope.json'))
    end
  end

  def test_new_dm_creates_another_and_records_a_waiver_in_the_verdict
    Dir.mktmpdir do |root|
      migrate(root)
      _o, err, _st, wd, state = migrate(root, '--new-dm', 'second copy for the pilot')
      refute_match(/FATAL: reuse-check/, err, err)
      assert_equal 2, dm_posts(state)
      assert_equal 'create', json(wd, 'dm-mode.json')['mode']
      assert_equal 'dm-1', json(wd, 'dm-mode.json')['declined_reuse']
      ledger = DegradationLedger.derive(wd)
      esc = ledger.find { |e| e['class'] == 'recorded-escape' && e['item'] =~ /--new-dm/ }
      assert esc, ledger.inspect
      assert_match(/second copy for the pilot/, esc['reason'])
      refute_equal 'GREEN', DegradationLedger.verdict(ledger)
    end
  end

  def test_a_later_reuse_clears_the_new_dm_waiver
    Dir.mktmpdir do |root|
      migrate(root)
      _o, _e, _st, wd, = migrate(root, '--new-dm')
      assert(DegradationLedger.derive(wd).any? { |e| e['item'] =~ /--new-dm/ })
      migrate(root, '--reuse-dm', 'dm-1')
      refute(DegradationLedger.derive(wd).any? { |e| e['item'] =~ /--new-dm/ }, 'the waiver no longer applies')
    end
  end

  def test_scan_failure_is_not_mistaken_for_no_match
    Dir.mktmpdir do |root|
      migrate(root)
      # a stale dm-match.json claiming "no recommendation" must not stand in for a scan that cannot run
      File.write(File.join(root, 'wd', 'dm-match.json'), JSON.generate('recommended_dm_id' => nil))
      _o, err, st, _wd, state = migrate(root, env: { 'SIGMA_BASE_URL' => '' })
      assert_equal 1, st.exitstatus
      assert_match(/FATAL: reuse-check/, err)
      refute File.exist?(File.join(root, 'wd', 'dm-mode.json')), 'a failed scan leaves no mode for a standalone post-omni-dm.rb'
      assert_equal 1, dm_posts(state)
    end
  end

  def test_reuse_and_new_dm_are_mutually_exclusive
    Dir.mktmpdir do |root|
      _o, err, st, = migrate(root, '--reuse-dm', 'dm-1', '--new-dm')
      refute st.success?
      assert_match(/--reuse-dm and --new-dm/, err)
    end
  end

  def test_post_or_put_reuse_mode_writes_nothing
    calls = []
    stub = ->(*a, **k) { calls << [a, k] }
    Sigma.stub(:request, stub) do
      assert_equal 'dm-9', post_or_put_dm({ 'pages' => [] }, { 'mode' => 'reuse', 'dataModelId' => 'dm-9' })
    end
    assert_empty calls
  end

  def test_reuse_lookup_pairs_by_name_and_flags_missing_items
    authored = { 'pages' => [{ 'elements' => [
      { 'id' => 'el-orders', 'name' => 'Orders', 'columns' => [{ 'id' => 'c1', 'name' => 'Amount' }, { 'id' => 'c2', 'name' => 'Region' }] }
    ] }] }
    live = { 'pages' => [{ 'elements' => [
      { 'id' => 'live-x', 'name' => 'Other', 'columns' => [] },
      { 'id' => 'live-o', 'name' => 'Orders', 'columns' => [{ 'id' => 'l2', 'name' => 'Region' }, { 'id' => 'l1', 'name' => 'Amount' }] }
    ] }] }
    lookup = reuse_lookup_from_readback(live, authored['pages'][0]['elements'], data_model_id: 'dm-1')
    assert_equal 'live-o', lookup['orders']['elementId']
    assert_equal 'dm-1', lookup['orders']['dataModelId']
    assert_empty reuse_mismatches(authored['pages'][0]['elements'], live)
    live['pages'][0]['elements'][1]['columns'].pop
    assert_equal ['element el-orders: column "Amount" missing from the reused data model'],
                 reuse_mismatches(authored['pages'][0]['elements'], live)
  end
end
