#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline coverage: metabase's plugin-local runtime scripts take the Sigma host
# from the shared REST client instead of reading SIGMA_BASE_URL themselves.
#
# A user whose only credential is a signed-in Sigma CLI profile has no exported
# SIGMA_BASE_URL. Each case runs a real script with a fake `sigma` CLI first on
# PATH, the real get_token.py provider (minus its network /v2/whoami check) and
# a shim/wrapper that sends the profile host's HTTPS traffic to a loopback stub.
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
RLS = File.join(HERE, 'apply_sigma_rls.py')
GATE = File.join(HERE, 'assert-phase6-ran.rb')

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
  # Python scripts: run the real script with sigma_rest._send redirected to the
  # loopback stub (the original host is kept in the Host header).
  pywrap = File.join(dir, 'run_py.py')
  File.write(pywrap, <<~PY)
    import os, runpy, sys, urllib.error, urllib.request
    script = sys.argv[1]
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(script)), "lib"))
    import sigma_rest
    def _send(method, url, headers, body, timeout):
        host = os.environ["OFFLINE_SIGMA_HOST"]
        assert url.startswith("https://" + host), url
        local = "http://127.0.0.1:" + os.environ["OFFLINE_SIGMA_PORT"] + url.split(host, 1)[1]
        data = body.encode() if isinstance(body, str) else body
        req = urllib.request.Request(local, data=data, method=method.upper())
        for k, v in headers.items():
            req.add_header(k, v)
        req.add_header("Host", host)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return sigma_rest._Resp(r.status, r.read(), "")
        except urllib.error.HTTPError as e:
            return sigma_rest._Resp(e.code, e.read(), e.reason)
    sigma_rest._send = _send
    sys.argv = sys.argv[1:]
    runpy.run_path(script, run_name="__main__")
  PY
  { bindir: bindir, cli_log: cli_log, provider: provider, shim: shim, pywrap: pywrap }
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

def run_rb(env, fx, script, *args)
  # Test harness: runs a fixed script under test with the current interpreter and temp-dir fixtures; no user input reaches the command.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3(env, RbConfig.ruby, '-r', fx[:shim], script, *args)
end

def run_py(env, fx, script, *args)
  # Test harness: runs a fixed script under test with the current interpreter and temp-dir fixtures; no user input reaches the command.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3(env, env['SIGMA_PYTHON'], fx[:pywrap], script, *args)
end

def reached_cli_host?(requests, path_fragment)
  requests.any? do |_method, path, host, auth|
    path.to_s.include?(path_fragment) && host.to_s.start_with?(CLI_HOST) && auth == "Bearer #{FAKE_JWT}"
  end
end

def json(body)
  [200, JSON.generate(body)]
end

puts 'test-cli-base-url.rb — metabase scripts use the host a Sigma CLI profile reports'

puts '== apply_sigma_rls.py =='
Dir.mktmpdir('mb-base-rls') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new do |_method, path|
    if path.start_with?('/v2/user-attributes')
      json('entries' => [{ 'userAttributeId' => 'ua-1', 'name' => 'region' }])
    else
      [404, '{}']
    end
  end
  out, err, status = run_py(cli_env(dir, fx, stub.port), fx, RLS, '--attr', 'region')
  stub.close
  check(status.success?, "lookup succeeds with no SIGMA_BASE_URL (exit #{status.exitstatus})", failures)
  check(out.include?('REUSE') && out.include?('ua-1'), 'the live attribute list is read and reused', failures)
  check(reached_cli_host?(stub.requests, '/v2/user-attributes'),
        'requests carry the CLI profile host and the CLI token', failures)
  puts err unless status.success?
end

Dir.mktmpdir('mb-base-rls-explicit') do |dir|
  fx = fixtures(dir)
  stub = StubSigma.new { |_method, _path| json('entries' => []) }
  env = cli_env(dir, fx, stub.port).merge('SIGMA_BASE_URL' => "https://#{CLI_HOST}",
                                          'SIGMA_API_TOKEN' => 'caller-token')
  _out, _err, status = run_py(env, fx, RLS, '--attr', 'region')
  stub.close
  check(status.success?, 'an explicit SIGMA_BASE_URL + token works', failures)
  check(stub.requests.any? { |_m, _p, _h, auth| auth == 'Bearer caller-token' },
        'the caller token is used as-is', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is never consulted when SIGMA_BASE_URL is set', failures)
end

Dir.mktmpdir('mb-base-rls-token') do |dir|
  fx = fixtures(dir)
  env = cli_env(dir, fx, 1).merge('SIGMA_API_TOKEN' => 'caller-token')
  _out, err, status = run_py(env, fx, RLS, '--attr', 'region')
  check(!status.success? && err.include?('SIGMA_BASE_URL not set'),
        'a caller token with no base URL fails with the clear message', failures)
  check(!err.include?('Traceback'), 'that failure is a message, not a traceback', failures)
  check(!File.exist?(fx[:cli_log]), 'the CLI is never consulted for a caller-supplied token', failures)
end

puts '== assert-phase6-ran.rb =='
Dir.mktmpdir('mb-base-phase6') do |dir|
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
  out, err, = run_rb(cli_env(dir, fx, stub.port), fx, GATE, '--workdir', dir)
  stub.close
  check(!out.include?('[SKIP] gate 3/7') && !err.include?('[SKIP] gate 3/7'),
        'gate 3 does not SKIP for a CLI-only user', failures)
  check(reached_cli_host?(stub.requests, '/v2/workbooks/wb-cli/columns'),
        'the live column GET goes to the CLI profile host with the CLI token', failures)
  check(!err.include?('SIGMA_BASE_URL / SIGMA_API_TOKEN not set'),
        'no live gate SKIPs for missing credentials', failures)
  puts out, err unless failures.empty?
end

if failures.empty?
  puts 'test-cli-base-url.rb: ALL PASS'
  exit 0
end
warn "test-cli-base-url.rb: #{failures.length} FAILURE(S)"
failures.each { |failure| warn "  - #{failure}" }
exit 1
