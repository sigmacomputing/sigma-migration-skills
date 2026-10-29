# frozen_string_literal: true

require 'json'
require 'time'
require 'rbconfig'

module MigrationProcess
  class Busy < StandardError; end
  INHERITED_FD = 'SIGMA_MIGRATION_LOCK_FD'

  # Windows emulates exec and cannot preserve an arbitrary locked descriptor.
  def self.exec_supported?(host_os = RbConfig::CONFIG.fetch('host_os'))
    !host_os.match?(/mswin|mingw/i)
  end

  # The OS lock, not a PID file, is authoritative. A killed process releases it;
  # a stale/recycled PID never authorizes another writer or a kill operation.
  def self.acquire(workdir)
    path = File.join(workdir, 'migration.lock')
    inherited = ENV.delete(INHERITED_FD)
    lock = inherited ? File.for_fd(Integer(inherited), 'r+') : File.open(path, File::RDWR | File::CREAT, 0o600)
    # Fresh handles were opened from this path. Only inherited POSIX handles
    # need identity validation; Windows fstat/stat device identities can differ.
    if inherited && !(lock.stat.ino == File.stat(path).ino && lock.stat.dev == File.stat(path).dev)
      lock.close
      raise Busy, 'inherited migration lock does not match this workdir'
    end
    unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close
      raise Busy, 'another migration owns this workdir; inspect migration-process.json and migrate-full.log; wait for it to exit before resuming'
    end
    lock.close_on_exec = true
    record = { 'pid' => Process.pid, 'started_at' => Time.now.utc.iso8601, 'status' => 'running' }
    status_path = File.join(workdir, 'migration-process.json')
    write_status(status_path, record)
    at_exit do
      error = $!
      code = if error.is_a?(SystemExit)
               error.status
             elsif error.is_a?(SignalException)
               128 + error.signo
             else
               error ? 1 : 0
             end
      begin
        write_status(status_path, record.merge('status' => 'exited', 'exit_code' => code,
                                               'finished_at' => Time.now.utc.iso8601))
      ensure
        lock.close unless lock.closed?
      end
    end
    lock
  end

  def self.write_status(path, record)
    tmp = "#{path}.#{Process.pid}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.generate(record)) }
    begin
      File.rename(tmp, path)
    rescue Errno::EEXIST, Errno::EACCES
      raise unless File.exist?(path)
      contents = File.binread(tmp)
      File.open(path, File::WRONLY | File::TRUNC) { |f| f.write(contents) }
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
  end
end
