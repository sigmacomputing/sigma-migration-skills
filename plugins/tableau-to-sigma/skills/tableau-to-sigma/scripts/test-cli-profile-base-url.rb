#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline coverage: tableau-to-sigma's plugin-local runtime scripts take the Sigma
# host from the shared REST client (Sigma.base_url) instead of reading
# SIGMA_BASE_URL themselves.
#
# A user whose only credential is a signed-in Sigma CLI profile has no exported
# SIGMA_BASE_URL. The shared client asks the token provider, which reports the
# profile's host. Each case runs a real script with:
#   - a fake `sigma` CLI first on PATH (it reports a published Sigma API host),
#   - the real vendored get_token.py provider, minus its network /v2/whoami check,
#   - a preloaded shim that sends that host's HTTPS traffic to a loopback stub.
# Nothing leaves the machine. HOME is a temp dir, so no settings file is read.

require 'json'
require 'open3'
require 'rbconfig'
require 'socket'
require 'tmpdir'

HERE = __dir__
CLI_HOST = 'aws-api.sigmacomputing.com'
FAKE_JWT = ['{"alg":"none"}', '{"sub":"fixture"}', 'signature']
           .map { |part| [part].pack('m0').tr('+/', '-_').delete('=') }.join('.')
PROVIDER = File.join(HERE, 'get_token.py')
abort 'get_token.py not found next to this test' unless File.file?(PROVIDER)

failures = []
def check(condition, message, failures)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end

# Loopback stand-in for the Sigma API. Records [method, path, host, auth] per request.
class StubSigma
  attr_reader :port, :requests

  def initialize(&router)
    @router = router
    @requests = []
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def close
    @server.close
    @thread.join
  end

  private

  def serve
    loop do
      client = @server.accept
      method, path = client.gets.to_s.split
      headers = {}
      while (line = client.gets)
        break if line == "\r\n"
        key, value = line.split(':', 2)
        headers[key.downcase] = value.to_s.strip if value
      end
      length = headers['content-length'].to_i
      client.read(length) if length.positive?
      @requests << [method, path, headers['host'], headers['authorization']]
      status, body = @router.call(method, path)
      client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
end

def fixtures(dir)
  bindir = File.join(dir, 'bin')
  Dir.mkdir(bindir)
  cli_log = File.join(dir, 'cli.log')
  File.write(File.join(bindir, 'sigma'), <<~SH, perm: 0o700)
    #!/bin/sh
    # Synthetic stand-in for the Sigma CLI.
    echo "$*" >> "#{cli_log}"
    case "$1 $2" in
      'auth --help') echo 'Commands: login status token' ;;
      'auth status') printf 'Profile:  example\\nBase URL: https://#{CLI_HOST}\\nAuth:     OK\\n' ;;
      'auth token')  printf '%s\\n' "$FAKE_SIGMA_TOKEN" ;;
      *) exit 3 ;;
    esac
  SH
  provider = File.join(dir, 'provider.py')
  File.write(provider, <<~PY)
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("gt", #{File.expand_path(PROVIDER).inspect})
    gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)
    gt._verify_token = lambda result: result  # no network in this offline test
    sys.exit(gt.main(sys.argv[1:]))
  PY
  shim = File.join(dir, 'offline_sigma_host.rb')
  File.write(shim, <<~RUBY)
    # Route the CLI profile's published host to the loopback stub, without TLS.
    require 'net/http'
    module OfflineSigmaHost
      def new(address, port = nil, *rest)
        return super unless address.to_s == ENV['OFFLINE_SIGMA_HOST']
        http = super('127.0.0.1', Integer(ENV.fetch('OFFLINE_SIGMA_PORT')), *rest)
        http.instance_variable_set(:@offline_sigma, true)
        http
      end
    end
    module OfflineSigmaPlainText
      define_method(:use_ssl=) { |flag| super(@offline_sigma ? false : flag) }
    end
    Net::HTTP.singleton_class.prepend(OfflineSigmaHost)
    Net::HTTP.prepend(OfflineSigmaPlainText)
  RUBY
  { bindir: bindir, cli_log: cli_log, provider: provider, shim: shim }
end

# CLI-only environment: no SIGMA_BASE_URL, no token, no client credentials.
def cli_env(dir, fx, port)
  env = ENV.keys.grep(/\A(?:SIGMA|TABLEAU)_/).to_h { |key| [key, nil] }
  env.merge(
    'HOME' => dir,
    'PATH' => "#{fx[:bindir]}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
    'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8',
    'SIGMA_TOKEN_PROVIDER' => fx[:provider],
    'SIGMA_PYTHON' => ENV['SIGMA_PYTHON'] || 'python3',
    'FAKE_SIGMA_TOKEN' => FAKE_JWT,
    'OFFLINE_SIGMA_HOST' => CLI_HOST,
    'OFFLINE_SIGMA_PORT' => port.to_s
  )
end

def run(env, fx, script, *args)
  # Test harness: runs a fixed script under test with the current interpreter and temp-dir fixtures; no user input reaches the command.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3(env, RbConfig.ruby, '-r', fx[:shim], File.join(HERE, script), *args)
end

def reached_cli_host?(requests, path_fragment)
  requests.any? do |_method, path, host, auth|
    path.to_s.include?(path_fragment) && host.to_s.start_with?(CLI_HOST) && auth == "Bearer #{FAKE_JWT}"
  end
end

def json(body)
  [200, JSON.generate(body)]
end

LAYOUT = '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1"></Page>'

puts 'test-cli-profile-base-url.rb — tableau scripts use the host a Sigma CLI profile reports'

puts '== post-and-readback.rb =='
Dir.mktmpdir('cli-base-par') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new { |_method, _path| json('dataModelId' => 'dm-new') }
  spec = File.join(dir, 'dm-spec.json')
  File.write(spec, JSON.generate('pages' => []))
  _o, err, _status = run(cli_env(dir, fx, stub.port), fx, 'post-and-readback.rb',
                         '--type', 'datamodel', '--spec', spec, '--out', File.join(dir, 'ids.json'),
                         '--workdir', dir)
  stub.close
  check(!err.include?('KeyError'), 'no KeyError for the missing SIGMA_BASE_URL', failures)
  check(reached_cli_host?(stub.requests, '/v2/dataModels/spec'),
        'the POST goes to the CLI profile host with the CLI token', failures)
end

Dir.mktmpdir('cli-base-par-token') do |dir|
  fx = fixtures(dir)
  spec = File.join(dir, 'dm-spec.json')
  File.write(spec, JSON.generate('pages' => []))
  env = cli_env(dir, fx, 1).merge('SIGMA_API_TOKEN' => 'caller-token')
  _o, err, status = run(env, fx, 'post-and-readback.rb', '--type', 'datamodel', '--spec', spec,
                        '--out', File.join(dir, 'ids.json'), '--workdir', dir)
  check(!status.success? && err.include?('post-and-readback.rb: SIGMA_BASE_URL not set'),
        'a caller token with no base URL fails with the clear message', failures)
  check(!err.match?(/\.rb:\d+:in /), 'that failure is a message, not a backtrace', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is never consulted for a caller-supplied token', failures)
end

Dir.mktmpdir('cli-base-par-explicit') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new { |_method, _path| json('dataModelId' => 'dm-new') }
  spec = File.join(dir, 'dm-spec.json')
  File.write(spec, JSON.generate('pages' => []))
  env = cli_env(dir, fx, 1).merge('SIGMA_BASE_URL' => "http://127.0.0.1:#{stub.port}",
                                  'SIGMA_API_TOKEN' => 'explicit-token')
  run(env, fx, 'post-and-readback.rb', '--type', 'datamodel', '--spec', spec,
      '--out', File.join(dir, 'ids.json'), '--workdir', dir)
  stub.close
  check(stub.requests.any? { |_m, _p, _h, auth| auth == 'Bearer explicit-token' },
        'an explicit SIGMA_BASE_URL + token still win', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is not consulted when SIGMA_BASE_URL is explicit', failures)
end

puts '== put-layout.rb =='
Dir.mktmpdir('cli-base-layout') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new do |method, _path|
    if method == 'GET'
      json('document' => { 'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p1', 'name' => 'P' }],
                           'elements' => [], 'layout' => LAYOUT })
    else
      json('workbookId' => 'wb-test')
    end
  end
  layout = File.join(dir, 'layout.xml')
  File.write(layout, LAYOUT)
  _o, err, status = run(cli_env(dir, fx, stub.port), fx, 'put-layout.rb',
                        '--workbook', 'wb-test', '--layout', layout, '--workdir', dir)
  stub.close
  check(status.success?, "put-layout succeeds with no SIGMA_BASE_URL (exit #{status.exitstatus})", failures)
  check(!err.include?('KeyError'), 'no KeyError for the missing SIGMA_BASE_URL', failures)
  check(reached_cli_host?(stub.requests, '/v2/workbooks/wb-test'),
        'the workbook GET goes to the CLI profile host with the CLI token', failures)
  check(stub.requests.any? { |method, _p, host, _a| method == 'PUT' && host.to_s.start_with?(CLI_HOST) },
        'the layout PUT goes to the CLI profile host', failures)
end

Dir.mktmpdir('cli-base-layout-token') do |dir|
  fx = fixtures(dir)
  layout = File.join(dir, 'layout.xml')
  File.write(layout, LAYOUT)
  env = cli_env(dir, fx, 1).merge('SIGMA_API_TOKEN' => 'caller-token')
  _o, err, status = run(env, fx, 'put-layout.rb', '--workbook', 'wb-test', '--layout', layout, '--workdir', dir)
  check(!status.success? && err.include?('put-layout.rb: SIGMA_BASE_URL not set'),
        'a caller token with no base URL fails with the clear message', failures)
  check(!err.match?(/\.rb:\d+:in /), 'that failure is a message, not a backtrace', failures)
end

puts '== verify-workbook.rb =='
Dir.mktmpdir('cli-base-verify') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new { |_method, _path| json('entries' => []) }
  out, err, status = run(cli_env(dir, fx, stub.port), fx, 'verify-workbook.rb', 'wb-verify')
  stub.close
  # The stub serves an empty element list, so the script reports that and exits 1:
  # it got as far as reading the workbook, which needs the host.
  check(status.exitstatus == 1 && (out + err).include?('no elements on workbook wb-verify'),
        "verify-workbook reads the workbook with no SIGMA_BASE_URL (exit #{status.exitstatus})", failures)
  check(!err.include?('SIGMA_BASE_URL not set'), 'no "SIGMA_BASE_URL not set" refusal', failures)
  check(reached_cli_host?(stub.requests, '/v2/workbooks/wb-verify/elements'),
        'the elements GET goes to the CLI profile host with the CLI token', failures)
end

Dir.mktmpdir('cli-base-verify-token') do |dir|
  fx = fixtures(dir)
  env = cli_env(dir, fx, 1).merge('SIGMA_API_TOKEN' => 'caller-token')
  _o, err, status = run(env, fx, 'verify-workbook.rb', 'wb-verify')
  check(status.exitstatus == 2 && err.include?('SIGMA_BASE_URL not set'),
        'a caller token with no base URL exits 2 (setup error) with the clear message', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is never consulted for a caller-supplied token', failures)
end

puts '== discover-columns.rb =='
Dir.mktmpdir('cli-base-discover') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new { |_method, _path| [404, '{}'] }
  _o, err, status = run(cli_env(dir, fx, stub.port), fx, 'discover-columns.rb',
                        '--connection-id', 'conn-1', '--table-path', 'DB.SCH.TBL')
  stub.close
  check(status.exitstatus == 4, "the catalog lookup runs and 404s (exit #{status.exitstatus})", failures)
  check(!err.include?('set SIGMA_BASE_URL') && !err.include?('set SIGMA_API_TOKEN'),
        'no "set SIGMA_BASE_URL / SIGMA_API_TOKEN" refusal for a CLI-only user', failures)
  check(reached_cli_host?(stub.requests, '/v2/connection/conn-1/lookup'),
        'the lookup goes to the CLI profile host with the CLI token', failures)
end

puts '== assert-datasource-filters.rb =='
Dir.mktmpdir('cli-base-dsf') do |dir|
  fx = fixtures(dir)
  File.write(File.join(dir, 'dashboard-layout-meta.json'), JSON.generate(
    'datasource_filters' => [{ 'column_caption' => 'Company Active', 'is_datasource_filter' => true,
                               'is_active_flag' => true, 'members' => ['true'] }]
  ))
  stub = StubSigma.new { |_method, _path| [404, '{}'] }
  out, _err, status = run(cli_env(dir, fx, stub.port), fx, 'assert-datasource-filters.rb',
                          '--workdir', dir, '--workbook-id', 'wb-dsf')
  stub.close
  check(status.success?, 'the gate exits 0 on a live 404 (stated SKIP)', failures)
  check(!out.include?('no Sigma host/credentials resolvable'),
        'a CLI profile counts as a Sigma host and credentials (no credential SKIP)', failures)
  check(reached_cli_host?(stub.requests, '/v2/workbooks/wb-dsf'),
        'the live spec GET goes to the CLI profile host with the CLI token', failures)
end

puts '== migrate-tableau.rb credential gate =='
Dir.mktmpdir('cli-base-gate') do |dir|
  fx = fixtures(dir)
  env = cli_env(dir, fx, 1).merge('SIGMA_SKIP_DOCTOR_GATE' => 'test')
  work = File.join(dir, 'work')
  out, _err = Open3.capture2e(env, RbConfig.ruby, File.join(HERE, 'migrate-tableau.rb'),
                              '--workbook-id', 'wb-x', '--connection', 'conn-x', '--out', work,
                              chdir: dir)
  check(!out.include?('no usable Sigma authentication'),
        'a signed-in CLI profile (no SIGMA_BASE_URL) satisfies the Sigma credential gate', failures)
  check(out.include?('no Tableau credentials resolvable'),
        'the run moves on to the next precondition (Tableau credentials)', failures)
end

if failures.empty?
  puts 'test-cli-profile-base-url.rb: ALL PASS'
  exit 0
end
warn "test-cli-profile-base-url.rb: #{failures.length} FAILURE(S)"
failures.each { |failure| warn "  - #{failure}" }
exit 1
