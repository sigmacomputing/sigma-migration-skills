#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/migration_diagnostics'

class MigrationDiagnosticsTest < Minitest::Test
  def events(work)
    Dir.glob(File.join(work, 'diagnostic-events', '*.json')).map { |path| JSON.parse(File.read(path)) }
  end

  def test_child_status_output_and_environment_are_not_changed_or_logged
    Dir.mktmpdir do |work|
      out, status = MigrationDiagnostics.capture(work, [RbConfig.ruby, '-e',
        "puts 'Unknown column SYNTHETIC-FIELD'; exit 4"], env: { 'SYNTHETIC_SECRET' => 'SYNTHETIC-TOKEN' })
      assert_equal 4, status.exitstatus
      assert_includes out, 'SYNTHETIC-FIELD'
      rows = events(work)
      assert_equal 2, rows.size
      finish = rows.find { |row| row['event'] == 'end' }
      assert_equal 4, finish['exit_code']
      assert_equal 'missing-reference', finish['error_category']
      assert_operator finish['elapsed_s'], :>=, 0
      refute_includes JSON.generate(rows), 'SYNTHETIC-FIELD'
      refute_includes JSON.generate(rows), 'SYNTHETIC-TOKEN'
    end
  end

  def test_process_exit_is_recorded_and_finish_is_idempotent
    Dir.mktmpdir do |work|
      lib = File.join(__dir__, 'lib/migration_diagnostics.rb')
      _, status = Open3.capture2e(RbConfig.ruby, '-r', lib, '-e',
        "MigrationDiagnostics.process(ARGV[0], kind: 'invocation', operation: 'migrate-tableau.rb'); exit 12", work)
      assert_equal 12, status.exitstatus
      assert_equal 12, events(work).find { |row| row['event'] == 'end' }['exit_code']
      span = MigrationDiagnostics::Span.new(work, 'repair', 'runtime-repair')
      File.write(File.join(work, 'wb-spec.json'), '{"synthetic":true}')
      span.finish(0)
      span.finish(9)
      assert_equal 4, events(work).size
      repair = events(work).find { |row| row['event'] == 'end' && row['kind'] == 'repair' }
      assert_equal ['wb-spec.json'], repair['changed_artifacts']
      refute repair.key?('error_category')
    end
  end

  def test_fingerprint_failure_is_isolated_to_one_artifact
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'wb-spec.json'), '{}')
      File.write(File.join(work, 'dm-spec.json'), '{}')
      original = Digest::SHA256.method(:file)
      replacement = lambda do |path|
        raise Errno::EACCES if File.basename(path) == 'dm-spec.json'
        original.call(path)
      end
      fingerprints = Digest::SHA256.stub(:file, replacement) { MigrationDiagnostics.fingerprints(work) }
      assert_equal MigrationDiagnostics::ARTIFACTS, fingerprints.keys
      assert_equal Digest::SHA256.hexdigest('{}'), fingerprints['wb-spec.json']
      assert_nil fingerprints['dm-spec.json']
    end
  end

  def test_failed_diagnostic_writes_do_not_break_child_commands
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'diagnostic-events'), 'occupied')
      capture_io do
        out, status = MigrationDiagnostics.capture(work, [RbConfig.ruby, '-e', 'puts 42'])
        assert status.success?
        assert_equal "42\n", out
      end
      assert_equal 'occupied', File.read(File.join(work, 'diagnostic-events'))
    end
  end

  def test_concurrent_writers_and_path_validation
    Dir.mktmpdir do |work|
      threads = 12.times.map do
        Thread.new { MigrationDiagnostics::Span.new(work, 'script', 'external-command').finish(0) }
      end
      threads.each(&:value)
      assert_equal 24, events(work).size
      assert_equal 12, events(work).map { |row| row['id'] }.uniq.size
      refute MigrationDiagnostics.emit(work, 'id' => '../escape', 'event' => 'end')
    end
  end

  def test_spawn_failure_still_records_an_unfinished_command_result
    Dir.mktmpdir do |work|
      assert_raises(Errno::ENOENT) { MigrationDiagnostics.capture(work, [File.join(work, 'nonexistent')]) }
      finish = events(work).find { |row| row['event'] == 'end' }
      assert_equal 'launch-failed', finish['error_category']
      assert_nil finish['exit_code']
    end
  end
end
