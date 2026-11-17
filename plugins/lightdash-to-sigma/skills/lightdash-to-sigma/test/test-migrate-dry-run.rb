#!/usr/bin/env ruby
# frozen_string_literal: true
# End-to-end offline test of migrate-lightdash.rb --dry-run on the jaffle-orders fixture
# (and the gate that stops a real run before any network call). No network, no credentials.
#
#   ruby test/test-migrate-dry-run.rb

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'
require 'fileutils'

class MigrateDryRunTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/migrate-lightdash.rb', __dir__)
  FIXTURE = File.expand_path('../fixtures/jaffle-orders', __dir__)
  CLEAN_ENV = { 'LIGHTDASH_URL' => '', 'LIGHTDASH_API_KEY' => '', 'SIGMA_API_TOKEN' => '', 'SIGMA_BASE_URL' => 'http://127.0.0.1:9' }.freeze

  def migrate(dir, *args)
    Open3.capture3(CLEAN_ENV, RbConfig.ruby, SCRIPT, '--source-dir', FIXTURE, '--dashboard', 'jaffle-overview',
                   '--explore', 'orders', '--workdir', dir, *args)
  end

  def test_dry_run_writes_artifacts_and_prints_planned_calls
    Dir.mktmpdir do |dir|
      _o, err, st = migrate(dir, '--dry-run')
      assert_equal 0, st.exitstatus, err
      %w[dm.json field-map.json wb.json workbook-map.json rls-plan.json rls-steps.json lightdash-signature.json migrate-plan.json].each do |f|
        assert File.file?(File.join(dir, f)), "missing #{f}"
      end
      refute File.exist?(File.join(dir, 'wb-ids.json')), 'nothing was posted'
      refute File.exist?(File.join(dir, 'dm-elements.json'))
      assert_match(%r{DRY-RUN \(not performed\): .*"method":"POST","path":"/v2/workbooks"}, err)
      assert_match(/DRY-RUN \(not performed\) post-dm: POST \/v2\/dataModels\/spec/, err)
      env = JSON.parse(File.read(File.join(dir, 'dm.json'), encoding: 'UTF-8'))
      assert_equal 4, env['stats']['elements']
      map = JSON.parse(File.read(File.join(dir, 'workbook-map.json'), encoding: 'UTF-8'))
      assert_equal 6, map.values.count { |e| e['element_id'] && !e['placeholder'] }
      rls = JSON.parse(File.read(File.join(dir, 'rls-plan.json'), encoding: 'UTF-8'))
      assert_equal 'region', rls['user_attributes'][0]['name']
    end
  end

  def test_dry_run_gaps_reach_the_ledger_the_verdict_reads
    require_relative '../scripts/lib/degradation_ledger'
    Dir.mktmpdir do |dir|
      _o, err, st = migrate(dir, '--dry-run')
      assert_equal 0, st.exitstatus, err
      ledger = DegradationLedger.derive(dir)
      refute_empty ledger, 'convert-dm and builder gaps are written to coverage.json / offramps.jsonl'
      assert(ledger.any? { |e| e['class'] == 'scope-cut' && e['source_artifact'] == 'coverage.json' }, 'DM scope-cuts (e.g. percent_of_total) -> coverage.json')
      refute(ledger.any? { |e| e['item'] =~ /ECharts styling/ }, 'styling is a note, not a ledger entry')
      assert(JSON.parse(File.read(File.join(dir, 'chart-gaps.json'), encoding: 'UTF-8'))['notes'].any? { |n| n['item'] == 'ECharts styling' })
      assert(ledger.any? { |e| e['item'] =~ /RLS planned, NOT applied/ }, 'planned-but-unapplied RLS -> offramps.jsonl')
      refute_equal 'GREEN', DegradationLedger.verdict(ledger)
    end
  end

  def test_real_run_stops_at_the_rls_gate_before_any_sigma_call
    Dir.mktmpdir do |dir|
      _o, err, st = migrate(dir, '--connection-id', 'c', '--folder-id', 'f')
      assert_equal 1, st.exitstatus
      assert_match(/FATAL: rls-gate: exit 2/, err)
      refute File.exist?(File.join(dir, 'dm-mode.json'))
      refute File.exist?(File.join(dir, 'wb.json'))
    end
  end

  def test_real_run_requires_connection_and_folder
    Dir.mktmpdir do |dir|
      _o, err, st = migrate(dir)
      refute_equal 0, st.exitstatus
      assert_match(/missing --connection-id/, err)
    end
  end

  def complex_source(dir)
    src = File.join(dir, 'src')
    FileUtils.cp_r(FIXTURE, src)
    f = File.join(src, 'dbt/models/orders.yml')
    File.write(f, File.read(f, encoding: 'UTF-8').sub('${TABLE}.region IN (${lightdash.attributes.region})',
                                   '${TABLE}.region IN (${lightdash.attributes.region}) OR ${TABLE}.is_returned'))
    src
  end

  def run_real(dir, src, *args)
    Open3.capture3(CLEAN_ENV, RbConfig.ruby, SCRIPT, '--source-dir', src, '--dashboard', 'jaffle-overview', '--explore', 'orders',
                   '--workdir', File.join(dir, 'wd'), '--connection-id', 'c', '--folder-id', 'f', *args)
  end

  def test_complex_sql_filter_blocks_without_waiver_and_passes_the_rls_gate_with_one
    Dir.mktmpdir do |dir|
      src = complex_source(dir)
      _o, err, st = run_real(dir, src, '--ack-rls')
      assert_equal 1, st.exitstatus
      assert_match(/FATAL: rls-gate: exit 3/, err)
      _o, err, st = run_real(dir, src, '--ack-rls', '--ack-rls-complex', 'owner accepted')
      refute_match(/rls-gate/, err, 'waived plan passes both RLS steps')
      assert_match(/FATAL: reuse-check/, err, 'run proceeds past the RLS gate (then fails offline at the Sigma call)')
      steps = JSON.parse(File.read(File.join(dir, 'wd', 'rls-steps.json'), encoding: 'UTF-8'))
      assert_equal 'waived', steps['mode']
      assert_match(/owner accepted/, JSON.parse(File.read(File.join(dir, 'wd', 'rls-gaps.json'), encoding: 'UTF-8'))[0]['reason'])
      assert_equal 1, st.exitstatus
    end
  end

  def test_waiver_survives_the_builder_into_the_ledger_the_verdict_reads
    require_relative '../scripts/lib/degradation_ledger'
    Dir.mktmpdir do |dir|
      src = complex_source(dir)
      wd = File.join(dir, 'wd')
      _o, err, st = Open3.capture3(CLEAN_ENV, RbConfig.ruby, SCRIPT, '--source-dir', src, '--dashboard', 'jaffle-overview',
                                   '--explore', 'orders', '--workdir', wd, '--dry-run', '--ack-rls', '--ack-rls-complex', 'owner accepted')
      assert_equal 0, st.exitstatus, err
      gaps = JSON.parse(File.read(File.join(wd, 'chart-gaps.json'), encoding: 'UTF-8'))['gaps']
      assert(gaps.any? { |g| g['class'] == 'recorded-escape' && g['item'] =~ /RLS waived/ && g['reason'] =~ /owner accepted/ },
             'builder merged (did not clobber) the waiver entry')
      ledger = DegradationLedger.derive(wd)
      esc = ledger.find { |e| e['class'] == 'recorded-escape' && e['item'] =~ /RLS waived: sql_filter on orders/ }
      assert esc, ledger.inspect
      assert_match(/owner accepted/, esc['reason'])
      refute_equal 'GREEN', DegradationLedger.verdict(ledger).to_s.split.first
    end
  end

  def test_lightdash_credentials_without_project_do_not_downgrade_parity
    Dir.mktmpdir do |dir|
      _o, err, st = Open3.capture3(CLEAN_ENV.merge('LIGHTDASH_URL' => 'https://ld.example.com', 'LIGHTDASH_API_KEY' => 'k'), RbConfig.ruby, SCRIPT,
                                   '--source-dir', FIXTURE, '--dashboard', 'jaffle-overview', '--explore', 'orders', '--workdir', dir,
                                   '--connection-id', 'c', '--folder-id', 'f')
      refute_equal 0, st.exitstatus
      assert_match(/--project is missing/, err)
      refute File.exist?(File.join(dir, 'dm.json')), 'aborts before doing any work'
    end
  end

  def test_dry_run_is_offline_only
    Dir.mktmpdir do |dir|
      _o, err, st = Open3.capture3(CLEAN_ENV, RbConfig.ruby, SCRIPT, '--project', 'p', '--dashboard', 'd', '--explore', 'orders',
                                   '--workdir', dir, '--dry-run')
      refute_equal 0, st.exitstatus
      assert_match(/--dry-run is offline/, err)
    end
  end
end
