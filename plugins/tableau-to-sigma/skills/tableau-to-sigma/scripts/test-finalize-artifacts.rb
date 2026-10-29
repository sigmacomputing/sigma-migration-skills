#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class FinalizeArtifactsTest < Minitest::Test
  def test_reused_provenance_uses_readback_and_still_rejects_stale_evidence
    Dir.mktmpdir do |work|
      original = File.join(work, 'dm-spec.json')
      reused = File.join(work, 'dm-spec-reused.json')
      File.write(original, JSON.generate('pages' => [], 'name' => 'Draft'))
      File.write(reused, JSON.generate('pages' => [], 'name' => 'Readback'))
      File.utime(Time.now + 1, Time.now + 1, reused)
      command = [RbConfig.ruby, File.join(__dir__, 'sql-provenance.rb'), '--workdir', work]
      output, status = Open3.capture2e(*command, '--dm-spec', reused)
      assert status.success?, output
      output, status = Open3.capture2e(*command, '--check')
      assert status.success?, output
      output, status = Open3.capture2e(*command, '--dm-spec', original, '--check')
      assert_equal 3, status.exitstatus, output
      File.write(original, JSON.generate('pages' => [], 'name' => 'Fresh Draft'))
      File.utime(Time.now + 2, Time.now + 2, original)
      output, status = Open3.capture2e(*command, '--check')
      assert_equal 3, status.exitstatus, output
      assert_includes output, 'stale'
      output, status = Open3.capture2e(*command, '--dm-spec', original)
      assert status.success?, output
      File.write(reused, JSON.generate('pages' => [], 'name' => 'Changed'))
      File.utime(Time.now + 3, Time.now + 3, reused)
      output, status = Open3.capture2e(*command, '--check')
      assert_equal 3, status.exitstatus, output
      assert_includes output, 'stale'
    end
  end

  def test_finalize_generates_empty_action_accounting_but_preserves_existing_files
    source = File.read(File.join(__dir__, 'migrate-tableau.rb'))
    chunk = source.split('  # Generate the missing action-accounting pair', 2).last
                  .split('  # The census-aware hard gate.', 2).first
    chunk = chunk.lines.drop(2).join
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'workbook-content.twb'), '<workbook/>')
      File.write(File.join(work, 'wb-ids.json'), JSON.generate('pages' => []))
      runner = Module.new
      runner.const_set(:WORK, work)
      runner.const_set(:HERE, __dir__)
      runner.define_singleton_method(:run!) do |args, **|
        output, status = Open3.capture2e(*args)
        raise output unless status.success?
      end
      runner.module_eval(chunk)
      ledger = File.join(work, 'action-ledger.json')
      guide = File.join(work, 'POSTPUBLISH_GUIDE.md')
      assert_equal 0, JSON.parse(File.read(ledger))['detectedCount']
      assert File.file?(guide)
      File.write(ledger, 'invalid existing ledger')
      File.write(guide, 'operator notes')
      runner.module_eval(chunk)
      assert_equal 'invalid existing ledger', File.read(ledger)
      assert_equal 'operator notes', File.read(guide)
      File.unlink(ledger)
      runner.module_eval(chunk)
      refute File.exist?(ledger), 'a partial pair must reach validation, not be silently repaired'
      assert_equal 'operator notes', File.read(guide)
    end
  end
end
