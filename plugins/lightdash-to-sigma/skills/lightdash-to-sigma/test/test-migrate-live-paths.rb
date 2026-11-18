#!/usr/bin/env ruby
# frozen_string_literal: true
# Orchestrator paths PAST the offline gates, run for real (every script is a child process) against an in-memory
# fake of Sigma and Lightdash (test/support/fake_net.rb): reuse-check (no match / match / --reuse-dm / --new-dm /
# stale dm-mode.json), DM post + readback, the workbook dry-run validation, live --dashboard resolution, and that
# builder / DM / RLS gaps reach the verdict ledger. No network, no credentials.
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
require_relative '../scripts/migrate-lightdash'

class MigrateLivePathsTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/migrate-lightdash.rb', __dir__)
  SCRIPTS = File.expand_path('../scripts', __dir__)
  FIXTURE = FakeRun::FIXTURE

  # -> [stdout, stderr, status, workdir, state_dir] (a fresh tmp pair unless given)
  def migrate(root, *args, live: false, env: {})
    state = File.join(root, 'state')
    wd = File.join(root, 'wd')
    FileUtils.mkdir_p(state)
    src = live ? [] : ['--source-dir', FIXTURE]
    base = live ? ['--project', 'p', '--dashboard', 'Jaffle Overview'] : ['--dashboard', 'jaffle-overview']
    o, e, st = Open3.capture3(FakeRun.env(state, lightdash: live, extra: env), RbConfig.ruby, SCRIPT, *src, *base, '--explore', 'orders',
                              '--workdir', wd, '--connection-id', 'conn', '--folder-id', 'fold', '--ack-rls', *args)
    [o, e, st, wd, state]
  end

  def json(wd, f)
    JSON.parse(File.read(File.join(wd, f), encoding: 'UTF-8'))
  end

  def test_no_reusable_dm_creates_one_and_proceeds_past_reuse_check
    Dir.mktmpdir do |root|
      _o, err, _st, wd, state = migrate(root)
      refute_match(/FATAL: reuse-check/, err, err)
      assert_equal({ 'mode' => 'create' }, json(wd, 'dm-mode.json'))
      assert_equal 1, FakeRun.count(state, 'POST', '/v2/dataModels/spec')
      assert_equal 'dm-1', json(wd, 'dm-elements.json').values.first['dataModelId']
      assert File.file?(File.join(wd, 'wb.json')), 'workbook was built on the posted DM'
      assert_match(/"dataModelId": "dm-1"/, File.read(File.join(wd, 'wb.json'), encoding: 'UTF-8'))
    end
  end

  def test_a_matching_dm_stops_the_run_and_never_posts_a_duplicate
    Dir.mktmpdir do |root|
      migrate(root) # creates dm-1
      posts = FakeRun.count(File.join(root, 'state'), 'POST', '/v2/dataModels/spec')
      assert_equal 1, posts
      # dm-mode.json from the first run is still on disk: the scan must run anyway (re-run bypass)
      assert File.file?(File.join(root, 'wd', 'dm-mode.json'))
      _o, err, st, _wd, state = migrate(root)
      assert_equal 1, st.exitstatus
      assert_match(/FATAL: reuse-check: data model dm-1 .*already covers/, err)
      assert_match(/--reuse-dm dm-1/, err)
      assert_match(/--new-dm/, err)
      assert_equal posts, FakeRun.count(state, 'POST', '/v2/dataModels/spec'), 'no duplicate DM was posted'
      refute File.file?(File.join(root, 'wd', 'dm-mode.json')),
             'a match-stop must not leave the prior run\'s {"mode":"create"} for a standalone post-lightdash-dm.rb'
    end
  end

  def test_reuse_dm_builds_on_the_existing_dm_without_posting_one
    Dir.mktmpdir do |root|
      migrate(root)
      _o, err, _st, wd, state = migrate(root, '--reuse-dm', 'dm-1')
      refute_match(/FATAL: (reuse-check|post-dm)/, err, err)
      assert_equal 1, FakeRun.count(state, 'POST', '/v2/dataModels/spec'), 'still only the first run POSTed a DM'
      assert_equal 0, FakeRun.count(state, 'PUT', '/v2/dataModels/'), 'a reused DM is never written'
      assert_equal({ 'mode' => 'reuse', 'dataModelId' => 'dm-1', 'chosen_by' => '--reuse-dm' }, json(wd, 'dm-mode.json'))
      assert_equal 'dm-1', json(wd, 'dm-elements.json').values.first['dataModelId']
      assert File.file?(File.join(wd, 'wb.json'))
    end
  end

  def test_new_dm_creates_another_and_records_a_waiver_in_the_verdict
    Dir.mktmpdir do |root|
      migrate(root)
      _o, err, _st, wd, state = migrate(root, '--new-dm', 'second copy for the pilot')
      refute_match(/FATAL: reuse-check/, err, err)
      assert_equal 2, FakeRun.count(state, 'POST', '/v2/dataModels/spec')
      assert_equal 'create', json(wd, 'dm-mode.json')['mode']
      esc = DegradationLedger.derive(wd).find { |e| e['class'] == 'recorded-escape' && e['item'] =~ /--new-dm/ }
      assert esc, DegradationLedger.derive(wd).inspect
      assert_match(/second copy for the pilot/, esc['reason'])
    end
  end

  def test_scan_failure_is_not_mistaken_for_no_match
    Dir.mktmpdir do |root|
      migrate(root)
      # a stale dm-match.json claiming "no recommendation" must not stand in for a scan that cannot run
      File.write(File.join(root, 'wd', 'dm-match.json'), JSON.generate('recommended_dm_id' => nil))
      _o, err, st, = migrate(root, env: { 'SIGMA_BASE_URL' => '' })
      assert_equal 1, st.exitstatus
      assert_match(/FATAL: reuse-check/, err)
    end
  end

  def test_builder_dm_and_rls_gaps_reach_the_verdict_ledger
    Dir.mktmpdir do |root|
      _o, _e, _st, wd, = migrate(root)
      ledger = DegradationLedger.derive(wd)
      refute_empty ledger, 'derive reads coverage.json / offramps.jsonl: gaps must be in them'
      assert(ledger.any? { |e| e['class'] == 'scope-cut' }, 'scope-cuts (placeholders, skipped fields) -> coverage.json')
      refute(ledger.any? { |e| e['item'] =~ /ECharts styling/ }, 'styling is a note, never a ledger entry')
      assert(ledger.any? { |e| e['class'] == 'recorded-escape' && e['item'] =~ /RLS planned, NOT applied/ }, 'pending RLS -> offramps')
      refute_equal 'GREEN', DegradationLedger.verdict(ledger)
      # an unchanged re-run does not accumulate duplicate rows
      cov = json(wd, 'coverage.json')['unresolved']
      assert_equal cov.uniq.length, cov.length
    end
  end

  def test_rls_applied_clears_only_the_pending_record
    Dir.mktmpdir do |root|
      _o, _e, _st, wd, = migrate(root)
      assert(DegradationLedger.derive(wd).any? { |e| e['item'] =~ /RLS planned, NOT applied/ })
      _o, err, st = Open3.capture3(RbConfig.ruby, File.join(SCRIPTS, 'apply-sigma-rls.rb'), '--plan', File.join(wd, 'rls-plan.json'),
                                   '--out', File.join(wd, 'rls-steps.json'), '--applied', 'filter applied, no-attribute user sees 0 rows (TJ)')
      assert_equal 0, st.exitstatus, err
      ledger = DegradationLedger.derive(wd)
      refute(ledger.any? { |e| e['item'] =~ /RLS planned, NOT applied/ })
      assert(ledger.any? { |e| e['class'] == 'scope-cut' }, 'other records survive')
      assert_match(/no-attribute user/, json(wd, 'rls-steps.json')['applied_note'])
    end
  end

  def test_workbook_dry_run_validation_failure_is_readable_and_posts_nothing
    Dir.mktmpdir do |root|
      _o, err, st, wd, state = migrate(root, env: { 'FAKE_DRYRUN_ERROR' => 'elements[3].columns[0].id is duplicated' })
      assert_equal 1, st.exitstatus
      assert_match(/FATAL: post-workbook/, err)
      assert_match(/failed the dry-run validation \(nothing was created\)/, err)
      assert_match(/elements\[3\]\.columns\[0\]\.id is duplicated/, err)
      refute File.exist?(File.join(state, 'workbook.json')), 'the real POST never happened'
      refute File.exist?(File.join(wd, 'wb-ids.json'))
    end
  end

  def test_workbook_is_validated_then_posted
    Dir.mktmpdir do |root|
      _o, _e, _st, _wd, state = migrate(root)
      posts = FakeRun.calls(state).select { |c| c['method'] == 'POST' && c['path'] == '/v2/workbooks' }
      assert_equal [true, nil], posts.map { |c| JSON.parse(c['body'])['dryRun'] }, 'dry run first, then the real create'
    end
  end

  def test_live_dashboard_resolves_by_name_via_the_discovery_manifest
    Dir.mktmpdir do |root|
      _o, err, _st, wd, = migrate(root, live: true)
      refute_match(/FATAL: discover/, err, err)
      assert_equal 'jaffle-overview', json(wd, 'discovery/manifest.json')['dashboard']
      assert File.file?(File.join(wd, 'wb.json')), 'a display-name --dashboard reached the builder in live mode'
    end
  end

  def test_pick_dashboard_matches_basename_slug_uuid_and_name
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'file-one.yml'), YAML.dump('name' => 'Alpha Board', 'slug' => 'alpha', 'uuid' => 'u-1'))
      File.write(File.join(dir, 'file-two.yml'), YAML.dump('name' => 'Beta', 'slug' => 'beta', 'dashboardUuid' => 'u-2'))
      pick = ->(ref) { File.basename(pick_dashboard(dir, ref)) }
      assert_equal 'file-one.yml', pick.call('file-one')
      assert_equal 'file-one.yml', pick.call('alpha')
      assert_equal 'file-one.yml', pick.call('u-1')
      assert_equal 'file-two.yml', pick.call('u-2')
      assert_equal 'file-one.yml', pick.call('alpha board')
      assert_raises(MigrationFailed) { pick.call('nope') }
      m = File.join(dir, 'manifest.json')
      File.write(m, JSON.generate('dashboard' => 'beta'))
      assert_equal 'beta', resolved_dashboard_ref(dir, 'u-2', true)
      assert_equal 'u-2', resolved_dashboard_ref(dir, 'u-2', false)
    end
  end
end
