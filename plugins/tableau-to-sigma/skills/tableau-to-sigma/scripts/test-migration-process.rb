#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'json'
require 'timeout'
require_relative 'lib/migration_process'

class MigrationProcessTest < Minitest::Test
  LIB = File.expand_path('lib/migration_process.rb', __dir__)
  CHILD = <<~'RUBY'
    require ARGV.shift
    dir, mode = ARGV
    begin
      lock = MigrationProcess.acquire(dir)
    rescue MigrationProcess::Busy => e
      warn e.message
      exit 28
    end
    if mode == 'exec'
      exec({MigrationProcess::INHERITED_FD => lock.fileno.to_s}, RbConfig.ruby,
           '-e', 'require ARGV.shift; MigrationProcess.acquire(ARGV.shift); puts "ready"; STDOUT.flush; STDIN.gets; exit 12',
           $LOADED_FEATURES.find { |p| p.end_with?('/migration_process.rb') }, dir,
           lock.fileno => lock.fileno)
    end
    puts 'ready'
    STDOUT.flush
    STDIN.gets
    exit 18
  RUBY

  def with_owner(dir, mode = 'normal')
    # Test harness: runs this file's CHILD program against the lib under test; mode is a literal.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    Open3.popen3(RbConfig.ruby, '-e', CHILD, LIB, dir, mode) do |input, output, error, child|
      assert_equal "ready\n", Timeout.timeout(5) { output.gets }, error.read_nonblock(4096, exception: false).to_s
      yield input, child
    ensure
      input.close unless input.closed?
      unless child.join(3)
        Process.kill('KILL', child.pid)
        child.join
      end
    end
  end

  def competitor(dir)
    # Test harness: the same fixed CHILD program as with_owner, against a temp dir.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    Open3.capture2e(RbConfig.ruby, '-e', CHILD, LIB, dir, 'normal', stdin_data: "\n")
  end

  def test_second_writer_refused_and_resume_after_exit
    Dir.mktmpdir do |dir|
      with_owner(dir) do |input, child|
        before = File.read(File.join(dir, 'migration-process.json'))
        out, status = competitor(dir)
        assert_equal 28, status.exitstatus
        assert_includes out, 'another migration owns this workdir'
        assert_equal before, File.read(File.join(dir, 'migration-process.json'))
        input.puts
        assert_equal 18, child.value.exitstatus
      end
      record = JSON.parse(File.read(File.join(dir, 'migration-process.json')))
      assert_equal 'exited', record['status']
      assert_equal 18, record['exit_code']
      assert_equal 18, competitor(dir).last.exitstatus
    end
  end

  def test_status_replace_recovers_when_rename_cannot_overwrite
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'migration-process.json')
      MigrationProcess.write_status(path, 'status' => 'running')
      File.stub(:rename, ->(_from, to) { raise Errno::EEXIST, to }) do
        MigrationProcess.write_status(path, 'status' => 'exited')
      end
      assert_equal 'exited', JSON.parse(File.read(path))['status']
    end
  end

  def test_failed_status_replace_preserves_existing_record
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'migration-process.json')
      MigrationProcess.write_status(path, 'status' => 'running')
      open = File.method(:open)
      File.stub(:rename, ->(_from, to) { raise Errno::EEXIST, to }) do
        File.stub(:open, lambda { |target, *args, &block|
          raise Errno::EACCES, target if target == path
          open.call(target, *args, &block)
        }) do
          assert_raises(Errno::EACCES) { MigrationProcess.write_status(path, 'status' => 'exited') }
        end
      end
      assert_equal 'running', JSON.parse(File.read(path))['status']
    end
  end

  def test_os_releases_lock_after_abrupt_death
    Dir.mktmpdir do |dir|
      with_owner(dir) do |_input, child|
        Process.kill('KILL', child.pid)
        child.join
      end
      assert_equal 18, competitor(dir).last.exitstatus
    end
  end

  def test_lock_survives_in_process_finalize_exec
    skip 'Windows uses a separate invocation instead of inheriting the lock' unless MigrationProcess.exec_supported?
    Dir.mktmpdir do |dir|
      with_owner(dir, 'exec') do |input, child|
        assert_equal 28, competitor(dir).last.exitstatus
        input.puts
        assert_equal 12, child.value.exitstatus
      end
      assert_equal 12, JSON.parse(File.read(File.join(dir, 'migration-process.json')))['exit_code']
    end
  end

  def test_different_workdirs_can_run_concurrently
    Dir.mktmpdir do |a|
      Dir.mktmpdir do |b|
        with_owner(a) { |_input, _child| assert_equal 18, competitor(b).last.exitstatus }
      end
    end
  end

  def test_inherited_handle_from_another_workdir_is_refused
    skip 'Windows does not inherit migration descriptors' unless MigrationProcess.exec_supported?
    Dir.mktmpdir do |a|
      Dir.mktmpdir do |b|
        File.write(File.join(b, 'migration.lock'), '')
        File.open(File.join(a, 'migration.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          output, status = Open3.capture2e({ MigrationProcess::INHERITED_FD => lock.fileno.to_s },
                                           RbConfig.ruby, '-e', CHILD, LIB, b, 'normal',
                                           lock.fileno => lock.fileno, stdin_data: "\n")
          assert_equal 28, status.exitstatus
          assert_includes output, 'inherited migration lock does not match'
          refute File.exist?(File.join(b, 'migration-process.json'))
        end
      end
    end
  end

  def test_windows_uses_separate_invocations_for_both_exec_paths
    %w[mingw32 mingw-ucrt mswin64].each { |os| refute MigrationProcess.exec_supported?(os) }
    %w[darwin linux-gnu].each { |os| assert MigrationProcess.exec_supported?(os) }
    source = File.read(File.join(__dir__, 'migrate-tableau.rb'))
    assert_match(/if opts\[:reuse_dm\].*MigrationProcess\.exec_supported\?/, source)
    assert_match(/if _chain_ok.*MigrationProcess\.exec_supported\?/, source)
  end
end
