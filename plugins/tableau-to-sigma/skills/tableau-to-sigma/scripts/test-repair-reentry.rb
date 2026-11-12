#!/usr/bin/env ruby
# frozen_string_literal: true
#
# A successful RCF apply-patch archives parity evidence under
# repair-checkpoints/<id>/prior-evidence/. 2026-11-03 live run: --finalize then
# said "run pass 1 first", the operator re-ran migrate-tableau.rb pass 1, and
# pass 1 rebuilt the chart from source signals — reverting the RCF fix. The
# re-entry must recollect parity against the LIVE (patched) workbook
# (phase6-parity.rb pass 1 / collect-parity-actuals.rb), never the orchestrator
# pass 1. The orchestrator route is covered in test-finalize-preflight.rb.
#
#   ruby scripts/test-repair-reentry.rb

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/repair_state'

class RepairReentryTest < Minitest::Test
  PHASE6 = File.join(__dir__, 'phase6-parity.rb')
  CHECKPOINT = '0123456789abcdef0123456789abcdef'
  ENV_STUB = { 'SIGMA_BASE_URL' => 'https://stub.invalid', 'SIGMA_API_TOKEN' => 'stub' }.freeze

  def archive(dir, *names)
    path = File.join(dir, 'repair-checkpoints', CHECKPOINT, 'prior-evidence')
    FileUtils.mkdir_p(path)
    names.each { |name| File.write(File.join(path, name), '{}') }
    path
  end

  def test_archived_by_repair_finds_the_checkpoint_copy
    Dir.mktmpdir do |dir|
      assert_nil RepairState.archived_by_repair(dir, 'parity-actuals.json')
      path = archive(dir, 'parity-actuals.json')
      assert_equal File.join(path, 'parity-actuals.json'), RepairState.archived_by_repair(dir, 'parity-actuals.json')
      assert_nil RepairState.archived_by_repair(dir, 'parity-plan.json')
    end
  end

  def test_phase6_finalize_without_archived_actuals_routes_to_recollection
    Dir.mktmpdir do |dir|
      archive(dir, 'parity-actuals.json')
      File.write(File.join(dir, 'parity-plan.json'), JSON.generate('charts' => []))
      out, status = Open3.capture2e(ENV_STUB, RbConfig.ruby, PHASE6, '--tableau', dir, '--finalize',
                                    '--actuals', File.join(dir, 'parity-actuals.json'))
      refute status.success?, out
      assert_includes out, 'prior-evidence'
      assert_includes out, 'collect-parity-actuals.rb'
      assert_match(/do NOT re-run migrate-tableau\.rb pass 1/i, out)
      refute_match(/No such file or directory/, out)
    end
  end

  def test_phase6_finalize_without_archived_plan_names_its_own_pass1
    Dir.mktmpdir do |dir|
      archive(dir, 'parity-plan.json', 'parity-actuals.json')
      out, status = Open3.capture2e(ENV_STUB, RbConfig.ruby, PHASE6, '--tableau', dir, '--finalize',
                                    '--actuals', File.join(dir, 'parity-actuals.json'))
      refute status.success?, out
      assert_includes out, "phase6-parity.rb --tableau #{dir} --workbook-id"
      assert_match(/do NOT re-run migrate-tableau\.rb pass 1/i, out)
    end
  end
end
