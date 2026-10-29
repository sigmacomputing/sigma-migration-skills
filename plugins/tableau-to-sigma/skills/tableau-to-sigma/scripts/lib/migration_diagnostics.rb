# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'time'

# Local bookkeeping only. Immutable event files avoid cross-process append races
# and preserve starts when a process is killed without running its exit hooks.
module MigrationDiagnostics
  ARTIFACTS = %w[wb-spec.json dm-spec.json dashboard-layout.json fidelity-ledger.json].freeze

  def self.emit(workdir, event)
    return false unless event['id'].to_s.match?(/\A[0-9a-f]{32}\z/) && %w[start end].include?(event['event'])
    dir = File.join(workdir, 'diagnostic-events')
    return false if File.symlink?(dir)
    return false unless Dir.exist?(workdir)
    FileUtils.mkdir_p(dir, mode: 0o700)
    path = File.join(dir, "#{event.fetch('id')}-#{event.fetch('event')}.json")
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
      f.write(JSON.generate(event) + "\n")
    end
    true
  rescue StandardError
    warn 'WARN: local diagnostic event could not be recorded; migration continues'
    false
  end

  def self.fingerprints(workdir)
    ARTIFACTS.to_h do |name|
      begin
        path = File.join(workdir, name)
        [name, File.file?(path) && !File.symlink?(path) ? Digest::SHA256.file(path).hexdigest : nil]
      rescue StandardError
        [name, nil]
      end
    end
  end

  class Span
    def initialize(workdir, kind, operation)
      @workdir, @pid = workdir, Process.pid
      @start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @before = MigrationDiagnostics.fingerprints(workdir) if %w[invocation repair].include?(kind)
      model = ENV.fetch('SIGMA_DIAGNOSTICS_MODEL', 'unknown')
      model = 'unknown' unless model.match?(/\A(?:(?:openai|anthropic|google)\/)?(?:gpt|claude|gemini)[a-z0-9.-]{1,64}\z/)
      effort = ENV.fetch('SIGMA_DIAGNOSTICS_EFFORT', 'unknown')
      effort = 'unknown' unless %w[unknown low medium high max minimal none xhigh].include?(effort)
      @event = { 'schema_version' => 1, 'id' => SecureRandom.hex(16), 'kind' => kind,
                 'operation' => operation, 'event' => 'start', 'at' => Time.now.utc.iso8601(6),
                 'runtime' => "ruby #{RUBY_VERSION}",
                 'model' => model, 'effort' => effort }
      MigrationDiagnostics.emit(workdir, @event)
    end

    def finish(code, error_category: nil)
      return if @finished || @pid != Process.pid
      @finished = true
      event = @event.merge('event' => 'end', 'at' => Time.now.utc.iso8601(6),
                           'elapsed_s' => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start).round(6),
                           'clock' => 'monotonic', 'exit_code' => code)
      event['error_category'] = error_category if error_category
      if @before
        after = MigrationDiagnostics.fingerprints(@workdir)
        event['changed_artifacts'] = ARTIFACTS.select { |name| @before[name] != after[name] }
      end
      MigrationDiagnostics.emit(@workdir, event)
    rescue StandardError
      warn 'WARN: local diagnostic duration unavailable; migration continues'
    end
  end

  def self.process(workdir, kind:, operation:)
    span = Span.new(workdir, kind, operation)
    at_exit do
      error = $!
      code = if error.is_a?(SystemExit)
               error.status
             elsif error.is_a?(SignalException)
               128 + error.signo
             else
               error ? 1 : 0
             end
      span.finish(code)
    end
    span
  end

  def self.capture(workdir, cmd, env: nil)
    # Never log argv, environment, output, field names, or URLs.
    script = cmd.find { |arg| arg.to_s.start_with?(File.expand_path('..', __dir__) + File::SEPARATOR) }
    span = Span.new(workdir, 'script', script ? File.basename(script) : 'external-command')
    code, category = nil, nil
    begin
      out, status = env ? Open3.capture2e(env, *cmd) : Open3.capture2e(*cmd)
      code = status.exitstatus || (128 + status.termsig)
      unless status.success?
        text = out.dup.force_encoding(Encoding::UTF_8).scrub
        category = if text.match?(/Dependency not found|Unknown column|unmapped|missing.*(?:column|reference)/i)
                     'missing-reference'
                   elsif text.match?(/401|403|unauthorized|authentication/i)
                     'authentication'
                   elsif text.match?(/timeout|timed out|429/i)
                     'timeout-or-rate-limit'
                   else
                     'command-failed'
                   end
      end
      [out, status]
    ensure
      span.finish(code, error_category: category || (code.nil? ? 'launch-failed' : nil))
    end
  end
end
