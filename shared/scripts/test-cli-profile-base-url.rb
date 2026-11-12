#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline coverage: standalone scripts take the Sigma host from the shared REST
# client (Sigma.base_url) instead of reading SIGMA_BASE_URL themselves.
#
# A user whose only credential is a signed-in Sigma CLI profile has no exported
# SIGMA_BASE_URL. The shared client asks the token provider, which reports the
# profile's host. Each case runs a real script with:
#   - a fake `sigma` CLI first on PATH (it reports a published Sigma API host),
#   - the real get_token.py provider, minus its network /v2/whoami check,
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
PROVIDER = [File.join(HERE, 'get_token.py'), File.join(HERE, '..', 'scripts', 'get_token.py')]
           .find { |path| File.file?(path) }
abort 'get_token.py not found next to this test' unless PROVIDER

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

puts 'test-cli-profile-base-url.rb — scripts use the host a Sigma CLI profile reports'

puts '== find-or-pick-dm.rb =='
Dir.mktmpdir('cli-base-dm') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new do |_method, path|
    if path.start_with?('/v2/dataModels?')
      json('entries' => [{ 'dataModelId' => 'dm-orders', 'name' => 'Orders Fact',
                           'updatedAt' => '2026-10-05T20:00:00Z' }], 'nextPage' => nil)
    elsif path.start_with?('/v2/dataModels/dm-orders/spec')
      json('pages' => [{ 'elements' => [{
             'source' => { 'kind' => 'warehouse-table', 'path' => %w[ACME SALES ORDERS_FACT] },
             'columns' => [{ 'name' => 'ORDER_ID' }, { 'name' => 'REVENUE' }]
           }] }])
    else
      [404, '{}']
    end
  end
  sig = File.join(dir, 'signature.json')
  out = File.join(dir, 'dm-match.json')
  File.write(sig, JSON.generate('tableau_workbook' => 'Orders Fact',
                                'warehouse_tables' => ['ACME.SALES.ORDERS_FACT'],
                                'referenced_columns' => %w[ORDER_ID REVENUE]))
  _o, err, status = run(cli_env(dir, fx, stub.port), fx, 'find-or-pick-dm.rb',
                        '--workbook-signature', sig, '--out', out, '--auto-pick', '--refresh')
  stub.close
  result = File.exist?(out) ? JSON.parse(File.read(out)) : {}
  check(status.success?, "picker succeeds with no SIGMA_BASE_URL (exit #{status.exitstatus})", failures)
  check(!err.include?('KeyError'), 'no KeyError for the missing SIGMA_BASE_URL', failures)
  check(result['recommended_dm_id'] == 'dm-orders', 'ranking still recommends the matching DM', failures)
  check(reached_cli_host?(stub.requests, '/v2/dataModels'),
        'requests carry the CLI profile host and the CLI token', failures)
end

Dir.mktmpdir('cli-base-dm-token') do |dir|
  fx = fixtures(dir)
  sig = File.join(dir, 'signature.json')
  File.write(sig, JSON.generate('warehouse_tables' => [], 'referenced_columns' => []))
  env = cli_env(dir, fx, 1).merge('SIGMA_API_TOKEN' => 'caller-token')
  _o, err, status = run(env, fx, 'find-or-pick-dm.rb',
                        '--workbook-signature', sig, '--out', File.join(dir, 'm.json'), '--refresh')
  check(!status.success? && err.include?('SIGMA_BASE_URL not set'),
        'a caller token with no base URL fails with the clear message', failures)
  check(!err.match?(/\.rb:\d+:in /), 'that failure is a message, not a backtrace', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is never consulted for a caller-supplied token', failures)
end

puts '== assert-phase6-ran.rb =='
Dir.mktmpdir('cli-base-phase6') do |dir|
  fx = fixtures(dir)
  File.write(File.join(dir, 'parity-final.json'), JSON.generate(
    'charts_total' => 1, 'charts_pass' => 1, 'status' => 'PASS', 'mode' => 'live',
    'tile_census' => { 'zones_total' => 1, 'charts_built' => 1, 'zones_unmatched' => 0,
                       'unmatched_zone_names' => [] }
  ))
  File.write(File.join(dir, 'posted-workbooks.jsonl'), JSON.generate('id' => 'wb-cli') + "\n")
  File.write(File.join(dir, 'wb-ids.json'), JSON.generate('workbookId' => 'wb-cli'))
  stub = StubSigma.new do |_method, path|
    path.include?('/columns') ? json('entries' => []) : json('contents' => { 'layout' => '' })
  end
  out, err, status = run(cli_env(dir, fx, stub.port), fx, 'assert-phase6-ran.rb', '--workdir', dir)
  stub.close
  check(!err.include?('live column-type check CANNOT run'),
        'gate 3 does not fail closed for a CLI-only user', failures)
  check(out.include?('[OK] gate 3/7: 0 live columns clean'), 'gate 3 runs its live column check', failures)
  check(status.exitstatus == 6, "the run reaches gate 4's empty-layout failure (exit #{status.exitstatus})",
        failures)
  check(reached_cli_host?(stub.requests, '/v2/workbooks/wb-cli/columns'),
        'the live column GET goes to the CLI profile host with the CLI token', failures)
end

Dir.mktmpdir('cli-base-phase6-nowb') do |dir|
  fx = fixtures(dir)
  File.write(File.join(dir, 'parity-final.json'), JSON.generate(
    'charts_total' => 1, 'charts_pass' => 1, 'status' => 'PASS', 'mode' => 'live'
  ))
  _o, _e, _s = run(cli_env(dir, fx, 1), fx, 'assert-phase6-ran.rb', '--workdir', dir)
  _o, _e, _s = run(cli_env(dir, fx, 1), fx, 'assert-phase6-ran.rb', '--help')
  check(!File.exist?(fx[:cli_log]),
        'with no workbook id (or --help) the gate never resolves credentials', failures)
end

puts '== cleanup-orphan-workbooks.rb =='
Dir.mktmpdir('cli-base-cleanup') do |dir|
  fx = fixtures(dir)
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             [{ 'id' => 'wb-old' }, { 'id' => 'wb-live' }].map { |r| JSON.generate(r) }.join("\n") + "\n")
  stub = StubSigma.new do |_method, path|
    id = path[%r{\A/v2/(?:workbooks|files)/([\w-]+)}, 1]
    meta = { 'name' => "Migration #{id}", 'path' => 'My Documents', 'ownerId' => 'member-1',
             'createdBy' => 'member-1', 'createdAt' => '2026-08-27T12:00:00Z' }
    if path.start_with?('/v2/workbooks/')
      json(meta.merge('workbookId' => id, 'workbookUrlId' => "url-#{id}"))
    elsif path.start_with?('/v2/files/')
      json(meta.merge('id' => id, 'urlId' => "url-#{id}", 'type' => 'workbook', 'parentId' => 'folder-1'))
    else
      [404, '{}']
    end
  end
  out, err, status = run(cli_env(dir, fx, stub.port), fx, 'cleanup-orphan-workbooks.rb',
                         '--workdir', dir, '--keep', 'wb-live', '--dry-run')
  stub.close
  check(status.success?, "dry-run succeeds with no SIGMA_BASE_URL (exit #{status.exitstatus})", failures)
  check(!err.include?('SIGMA_BASE_URL not set'), 'no "SIGMA_BASE_URL not set" refusal', failures)
  check(out.include?('[DRY-RUN] validated'), 'the candidate is validated against the live API', failures)
  check(reached_cli_host?(stub.requests, '/v2/files/wb-live'),
        'metadata reads go to the CLI profile host with the CLI token', failures)
end

puts '== verify-ws4-e2e.rb credential gate =='
Dir.mktmpdir('cli-base-ws4') do |dir|
  fx = fixtures(dir)
  out, _err, status = run(cli_env(dir, fx, 1), fx, 'verify-ws4-e2e.rb')
  check(status.success? && !out.include?('no Sigma credentials'),
        'a CLI profile counts as Sigma credentials', failures)
  check(out.include?('SIGMA_TEST_CONNECTION_ID'), 'the probe moves on to its next precondition', failures)
end

if failures.empty?
  puts 'test-cli-profile-base-url.rb: ALL PASS'
  exit 0
end
warn "test-cli-profile-base-url.rb: #{failures.length} FAILURE(S)"
failures.each { |failure| warn "  - #{failure}" }
exit 1
