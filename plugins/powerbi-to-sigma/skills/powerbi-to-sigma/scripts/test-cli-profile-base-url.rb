#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline coverage: powerbi's plugin-local Sigma scripts (post-and-readback.rb,
# phase6-parity.rb, and the Phase 6b credential gate in migrate-powerbi.rb) take
# the Sigma host from the shared REST client instead of reading SIGMA_BASE_URL
# themselves, and post-and-readback refreshes an expired token without needing
# exported client credentials.
#
# A CLI-only user (signed-in Sigma CLI profile, nothing exported) used to hit
# KeyError on ENV.fetch('SIGMA_BASE_URL'). Each case runs the real script with
# a fake `sigma` CLI first on PATH, the real get_token.py provider (minus its
# network whoami check), and a preloaded shim that sends the CLI host's HTTPS
# traffic to a loopback stub. Nothing leaves the machine; HOME is a temp dir.

require 'json'
require 'open3'
require 'rbconfig'
require 'socket'
require 'tmpdir'

SCRIPTS = __dir__
CLI_HOST = 'aws-api.sigmacomputing.com'
EXPLICIT_HOST = 'explicit-api.sigmacomputing.com'
FAKE_JWT = ['{"alg":"none"}', '{"sub":"fixture"}', 'signature']
           .map { |part| [part].pack('m0').tr('+/', '-_').delete('=') }.join('.')
PROVIDER = File.join(SCRIPTS, 'get_token.py')
abort 'get_token.py not found' unless File.file?(PROVIDER)

failures = []
def check(condition, message, failures)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end

# Loopback stand-in for the Sigma API. Records [method, path, host, auth].
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
      status, body = @router.call(method, path, @requests.length)
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
    spec = importlib.util.spec_from_file_location("gt", #{PROVIDER.inspect})
    gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)
    gt._verify_token = lambda result: result  # no network in this offline test
    sys.exit(gt.main(sys.argv[1:]))
  PY
  shim = File.join(dir, 'offline_sigma_host.rb')
  File.write(shim, <<~RUBY)
    # Route the chosen Sigma host to the loopback stub, without TLS.
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
  env = ENV.keys.grep(/\ASIGMA_/).to_h { |key| [key, nil] }
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
  Open3.capture3(env, RbConfig.ruby, '-r', fx[:shim], File.join(SCRIPTS, script), *args)
end

def reached_cli_host?(requests, method, path_fragment)
  requests.any? do |m, path, host, auth|
    m == method && path.to_s.include?(path_fragment) && host.to_s.start_with?(CLI_HOST) &&
      auth == "Bearer #{FAKE_JWT}"
  end
end

def json(body)
  [200, JSON.generate(body)]
end

puts 'test-cli-profile-base-url.rb (powerbi) - scripts use the host a Sigma CLI profile reports'

puts '== post-and-readback.rb =='
Dir.mktmpdir('pbi-base-post') do |dir|
  fx = fixtures(dir)
  spec = File.join(dir, 'dm-spec.json')
  File.write(spec, JSON.generate('pages' => []))
  # First PUT answers 401 (expired token); the retry must re-mint through the
  # provider even though no SIGMA_CLIENT_ID is exported.
  stub = StubSigma.new do |method, _path, n|
    if method == 'PUT' && n == 1 then [401, '{"message":"expired"}']
    elsif method == 'PUT' then json('dataModelId' => 'dm-1')
    else json('pages' => [], 'entries' => [])
    end
  end
  _o, err, status = run(cli_env(dir, fx, stub.port), fx, 'post-and-readback.rb',
                        '--type', 'datamodel', '--spec', spec, '--out', File.join(dir, 'map.json'),
                        '--update-id', 'dm-1')
  stub.close
  puts_seen = stub.requests.count { |m, *| m == 'PUT' }
  check(!err.include?('KeyError'), 'no KeyError for the missing SIGMA_BASE_URL', failures)
  check(reached_cli_host?(stub.requests, 'PUT', '/v2/dataModels/dm-1/spec'),
        'the PUT goes to the CLI profile host with the CLI token', failures)
  check(puts_seen >= 2, "a 401 is retried after a provider refresh with no client id (#{puts_seen} PUTs)", failures)
  check(err.include?('PUT ok'), "the retried PUT succeeds (exit #{status.exitstatus})", failures)
end

Dir.mktmpdir('pbi-base-post-explicit') do |dir|
  fx = fixtures(dir)
  spec = File.join(dir, 'dm-spec.json')
  File.write(spec, JSON.generate('pages' => []))
  stub = StubSigma.new { |method, _p, _n| method == 'PUT' ? json('dataModelId' => 'dm-1') : json('pages' => []) }
  env = cli_env(dir, fx, stub.port).merge('SIGMA_BASE_URL' => "https://#{EXPLICIT_HOST}",
                                          'SIGMA_API_TOKEN' => 'explicit-token',
                                          'OFFLINE_SIGMA_HOST' => EXPLICIT_HOST)
  run(env, fx, 'post-and-readback.rb', '--type', 'datamodel', '--spec', spec,
      '--out', File.join(dir, 'map.json'), '--update-id', 'dm-1')
  stub.close
  check(stub.requests.any? { |m, _p, host, auth| m == 'PUT' && host.to_s.start_with?(EXPLICIT_HOST) && auth == 'Bearer explicit-token' },
        'an explicit SIGMA_BASE_URL still wins', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is never consulted when the base URL is explicit', failures)
end

Dir.mktmpdir('pbi-base-post-token') do |dir|
  fx = fixtures(dir)
  spec = File.join(dir, 'dm-spec.json')
  File.write(spec, JSON.generate('pages' => []))
  env = cli_env(dir, fx, 1).merge('SIGMA_API_TOKEN' => 'caller-token')
  _o, err, status = run(env, fx, 'post-and-readback.rb', '--type', 'datamodel', '--spec', spec,
                        '--out', File.join(dir, 'map.json'), '--update-id', 'dm-1')
  check(!status.success? && err.include?('SIGMA_BASE_URL not set'),
        'a caller token with no base URL fails with the clear message', failures)
  check(!err.match?(/\.rb:\d+:in /), 'that failure is a message, not a backtrace', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is never consulted for a caller-supplied token', failures)
end

puts '== phase6-parity.rb =='
Dir.mktmpdir('pbi-base-parity') do |dir|
  fx = fixtures(dir)
  tab = File.join(dir, 'tab')
  Dir.mkdir(tab)
  stub = StubSigma.new do |_method, _path, _n|
    json('workbookId' => 'wb-1', 'contents' => { 'pages' => [], 'layout' => '' })
  end
  _o, err, _status = run(cli_env(dir, fx, stub.port), fx, 'phase6-parity.rb',
                         '--tableau', tab, '--workbook-id', 'wb-1')
  stub.close
  check(!err.include?('KeyError'), 'no KeyError for the missing SIGMA_BASE_URL', failures)
  check(reached_cli_host?(stub.requests, 'GET', '/v2/workbooks/wb-1'),
        'the pass-1 readback goes to the CLI profile host with the CLI token', failures)
end

Dir.mktmpdir('pbi-base-parity-finalize') do |dir|
  fx = fixtures(dir)
  tab = File.join(dir, 'tab')
  Dir.mkdir(tab)
  actuals = File.join(dir, 'actuals.json')
  File.write(actuals, '{}')
  _o, err, _status = run(cli_env(dir, fx, 1), fx, 'phase6-parity.rb',
                         '--tableau', tab, '--finalize', '--actuals', actuals)
  check(!err.include?('KeyError') && !err.include?('SIGMA_BASE_URL'),
        '--finalize makes no Sigma call and no longer demands SIGMA_BASE_URL', failures)
  check(!File.exist?(fx[:cli_log]), '--finalize never consults the CLI', failures)
end

Dir.mktmpdir('pbi-base-parity-token') do |dir|
  fx = fixtures(dir)
  tab = File.join(dir, 'tab')
  Dir.mkdir(tab)
  env = cli_env(dir, fx, 1).merge('SIGMA_API_TOKEN' => 'caller-token')
  _o, err, status = run(env, fx, 'phase6-parity.rb', '--tableau', tab, '--workbook-id', 'wb-1')
  check(!status.success? && err.include?('SIGMA_BASE_URL not set'),
        'a caller token with no base URL fails with the clear message', failures)
  check(!err.match?(/\.rb:\d+:in /), 'that failure is a message, not a backtrace', failures)
end

puts '== migrate-powerbi.rb Phase 6b credential gate =='
# The orchestrator is too heavy to run offline, so evaluate the gate's own
# `has_creds = begin ... end` block (extracted from the source) in a process
# that loads the real shared client.
orchestrator = File.read(File.join(SCRIPTS, 'migrate-powerbi.rb'))
gate = orchestrator[/^  has_creds = begin\n.*?^  end\n/m]
check(!gate.nil?, 'the Phase 6b credential gate is present in migrate-powerbi.rb', failures)
if gate
  Dir.mktmpdir('pbi-base-gate') do |dir|
    fx = fixtures(dir)
    probe = File.join(dir, 'gate.rb')
    File.write(probe, <<~RUBY)
      $LOAD_PATH.unshift #{File.join(SCRIPTS, 'lib').inspect}
      require 'sigma_rest'
      #{gate}
      puts "has_creds=\#{has_creds}"
    RUBY
    out, _err, _status = Open3.capture3(cli_env(dir, fx, 1), RbConfig.ruby, probe)
    check(out.include?('has_creds=true'), 'a signed-in CLI profile counts as credentials', failures)
    failing = File.join(dir, 'failing_provider.py')
    File.write(failing, "import sys\nsys.exit(1)\n")
    offline = cli_env(dir, fx, 1).merge('SIGMA_TOKEN_PROVIDER' => failing)
    offline_out, = Open3.capture3(offline, RbConfig.ruby, probe)
    check(offline_out.include?('has_creds=false'), 'with no credential source the gate stays closed', failures)
  end
end

if failures.empty?
  puts 'test-cli-profile-base-url.rb (powerbi): ALL PASS'
  exit 0
end
warn "test-cli-profile-base-url.rb (powerbi): #{failures.length} FAILURE(S)"
failures.each { |failure| warn "  - #{failure}" }
exit 1
