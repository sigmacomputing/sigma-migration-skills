# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'time'

module ExecutionIdentity
  # Only implementation files are fingerprinted. Never scan workdir inputs,
  # credentials, environment values, or source workbook contents.
  def self.record(workdir, skill: File.expand_path('../..', __dir__), source_mode: nil)
    files = %w[SKILL.md runtime-capabilities.json] +
            Dir.glob("#{skill}/{scripts,converter,refs}/**/*.{rb,py,mjs,json,md,sh}").map { |p| p.delete_prefix("#{skill}/") }
    files = files.uniq.sort.select do |p|
      File.file?(File.join(skill, p)) && p !~ %r{\Ascripts/(?:test[^/]*|fixtures|dev|vendor)(?:/|\.)}
    end
    hashes = files.to_h { |p| [p, Digest::SHA256.file(File.join(skill, p)).hexdigest] }
    plugin = JSON.parse(File.read(File.expand_path('../../.claude-plugin/plugin.json', skill))) rescue {}
    revision, status = begin
      Open3.capture2('git', '-C', skill, 'rev-parse', 'HEAD', err: File::NULL)
    rescue Errno::ENOENT
      [nil, nil]
    end
    identity = {
      'schema_version' => 1, 'recorded_at' => Time.now.utc.iso8601,
      'skill_path' => File.realpath(skill), 'entrypoint' => File.basename($PROGRAM_NAME),
      'runtime' => "ruby #{RUBY_VERSION}", 'plugin_version' => plugin['version'],
      'source_mode' => source_mode,
      'git_revision' => (status&.success? ? revision.strip : nil),
      'implementation_sha256' => Digest::SHA256.hexdigest(JSON.generate(hashes)),
      'bundled_converter_sha256' => hashes['converter/tableau.mjs']
    }
    path = File.join(workdir, 'execution-identity.json')
    previous = begin
      JSON.parse(File.read(path)) if File.file?(path)
    rescue JSON::ParserError
      warn 'WARN: previous execution identity is unreadable; current identity will be recorded'
      nil
    end
    identity['implementation_changed'] = !!(previous && previous['implementation_sha256'] != identity['implementation_sha256'])
    File.open(File.join(workdir, 'execution-history.jsonl'), 'a', 0o600) { |f| f.puts(JSON.generate(identity)) }
    File.open(path, 'w', 0o600) { |f| f.write(JSON.pretty_generate(identity) + "\n") }
    identity
  rescue Errno::ENOENT => e
    warn "WARN: execution identity unavailable (#{e.class})"
    nil
  end

  def self.record_converter(workdir, path)
    file = File.join(workdir, 'execution-identity.json')
    return unless File.file?(file)
    identity = JSON.parse(File.read(file))
    identity['converter'] = path ? { 'backend' => 'local', 'path' => File.realpath(path),
                                    'sha256' => Digest::SHA256.file(path).hexdigest } : { 'backend' => 'hosted' }
    File.open(File.join(workdir, 'execution-history.jsonl'), 'a', 0o600) { |f| f.puts(JSON.generate(identity)) }
    File.open(file, 'w', 0o600) { |f| f.write(JSON.pretty_generate(identity) + "\n") }
  end
end
