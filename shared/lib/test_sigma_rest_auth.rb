#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'net/http'
require_relative 'sigma_rest'

class SigmaRestDualAuthTest < Minitest::Test
  BASE = 'https://api.sigmacomputing.com'
  PROVIDER = {
    'SIGMA_API_TOKEN' => 'browser-refreshed-token',
    'SIGMA_TOKEN_MINTED_AT' => '2026-10-05T20:00:00Z',
    'SIGMA_AUTH_METHOD' => 'browser'
  }.freeze

  class SequenceHTTP
    attr_reader :authorization

    def initialize(*responses)
      @responses = responses
      @authorization = []
    end

    def request(request)
      @authorization << request['Authorization']
      @responses.shift
    end
  end

  def response(klass, code, message, body)
    value = klass.new('1.1', code, message)
    value.instance_variable_set(:@read, true)
    value.instance_variable_set(:@body, body)
    value
  end

  def setup
    @saved = ENV.to_h
    ENV['SIGMA_BASE_URL'] = BASE
    ENV['SIGMA_API_TOKEN'] = 'caller-token'
    %w[SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET SIGMA_TOKEN_MINTED_AT SIGMA_AUTH_METHOD].each do |key|
      ENV.delete(key)
    end
    Sigma.instance_variable_set(:@token_override, nil)
    Sigma.instance_variable_set(:@minted_at, nil)
    Sigma.instance_variable_set(:@refresh_inflight, false)
  end

  def teardown
    ENV.replace(@saved)
  end

  def test_unknown_age_caller_token_waits_for_401_then_refreshes_without_client_id
    http = SequenceHTTP.new(
      response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{"code":"unauthorized"}'),
      response(Net::HTTPOK, '200', 'OK', '{"ok":true}')
    )

    result = Sigma.stub(:token_provider_result, PROVIDER) do
      Sigma.request(:get, '/v2/whoami', http: http)
    end

    assert_equal({ 'ok' => true }, result)
    assert_equal ['Bearer caller-token', 'Bearer browser-refreshed-token'], http.authorization
    assert_equal 'browser', ENV['SIGMA_AUTH_METHOD']
  end

  def test_known_stale_token_refreshes_proactively_without_client_id
    ENV['SIGMA_TOKEN_MINTED_AT'] = '2026-10-05T19:09:59Z'

    token = Time.stub(:now, Time.utc(2026, 10, 5, 20, 0, 0)) do
      Sigma.stub(:token_provider_result, PROVIDER) { Sigma.auth_token }
    end

    assert_equal 'browser-refreshed-token', token
  end

  def test_cli_token_never_refreshes_proactively
    ENV['SIGMA_AUTH_METHOD'] = 'sigma-cli'
    ENV['SIGMA_TOKEN_MINTED_AT'] = '2000-01-01T00:00:00Z'
    token = Sigma.stub(:token_provider_result, -> { flunk 'provider should not run' }) { Sigma.auth_token }
    assert_equal 'caller-token', token
  end

  def test_cli_401_remint_pins_provider_to_cli_mode
    ENV['SIGMA_AUTH_METHOD'] = 'sigma-cli'
    captured = nil
    status = Object.new
    status.define_singleton_method(:success?) { true }
    runner = lambda do |*args|
      captured = args
      ["export SIGMA_API_TOKEN=cli-refreshed-token\nexport SIGMA_AUTH_METHOD=sigma-cli\n", '', status]
    end
    values = Open3.stub(:capture3, runner) { Sigma.token_provider_result }

    assert_equal 'cli-refreshed-token', values['SIGMA_API_TOKEN']
    assert_includes captured.each_cons(2).to_a, ['--auth-mode', 'sigma-cli']
  end

  def provider_run(stdout)
    status = Object.new
    status.define_singleton_method(:success?) { true }
    Open3.stub(:capture3, ->(*_args) { [stdout, '', status] }) { Sigma.token_provider_result }
  end

  def test_provider_output_without_mint_time_is_rejected_for_non_cli_methods
    %w[browser client-credentials].each do |method|
      err = assert_raises(Sigma::AuthError) do
        provider_run("export SIGMA_API_TOKEN=minted-token\nexport SIGMA_AUTH_METHOD=#{method}\n")
      end
      assert_match(/SIGMA_TOKEN_MINTED_AT/, err.message)
    end
  end

  def test_provider_output_without_mint_time_is_accepted_for_sigma_cli
    values = provider_run("export SIGMA_API_TOKEN=cli-token\nunset SIGMA_TOKEN_MINTED_AT\nexport SIGMA_AUTH_METHOD=sigma-cli\n")
    assert_equal 'cli-token', values['SIGMA_API_TOKEN']
    refute values.key?('SIGMA_TOKEN_MINTED_AT')
  end

  def test_refresh_requires_mint_time_unless_sigma_cli
    [{ 'SIGMA_API_TOKEN' => 'token' },
     { 'SIGMA_API_TOKEN' => 'token', 'SIGMA_AUTH_METHOD' => 'browser' }].each do |incomplete|
      assert_raises(Sigma::AuthError) do
        Sigma.stub(:token_provider_result, incomplete) { Sigma.refresh_token! }
      end
    end
    cli = { 'SIGMA_API_TOKEN' => 'cli-token', 'SIGMA_AUTH_METHOD' => 'sigma-cli' }
    ENV['SIGMA_TOKEN_MINTED_AT'] = '2000-01-01T00:00:00Z'
    assert_equal 'cli-token', Sigma.stub(:token_provider_result, cli) { Sigma.refresh_token! }
    assert_nil ENV['SIGMA_TOKEN_MINTED_AT']
    assert_nil Sigma.token_minted_at
  end

  def test_second_401_is_not_retried
    http = SequenceHTTP.new(
      response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{}'),
      response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{}')
    )

    assert_raises(Sigma::Error) do
      Sigma.stub(:token_provider_result, PROVIDER) do
        Sigma.request(:get, '/v2/whoami', http: http)
      end
    end
    assert_equal 2, http.authorization.length
  end
end

# CLI-only user: SIGMA_BASE_URL unset, the provider supplies the host.
class SigmaRestDerivedBaseTest < Minitest::Test
  require 'tmpdir'
  require 'rbconfig'

  CLI_BASE = 'https://aws-api.sigmacomputing.com'
  # Built at runtime (header {"alg":"none"}, payload {"sub":"test"}, signature
  # "signature") so no JWT-shaped literal sits in the source.
  FAKE_JWT = ['{"alg":"none"}', '{"sub":"test"}', 'signature']
             .map { |part| [part].pack('m0').tr('+/', '-_').delete('=') }.join('.')
  PROVIDER = {
    'SIGMA_API_TOKEN' => FAKE_JWT,
    'SIGMA_AUTH_METHOD' => 'sigma-cli',
    'SIGMA_BASE_URL' => CLI_BASE
  }.freeze
  FAKE_SIGMA = <<~'SH'
    #!/bin/bash
    # Synthetic stand-in for the Sigma CLI.
    if [ "$1 $2" = "auth --help" ]; then echo "Commands: login token status"; exit 0; fi
    if [ "$1 $2" = "auth status" ]; then
      { echo "Profile:   example-profile"; echo "Base URL:  ${FAKE_SIGMA_BASE}"; echo "Auth:      OK (token acquired)"; } >&2
      exit 0
    fi
    if [ "$1 $2" = "auth token" ]; then printf '%s\n' "${FAKE_SIGMA_TOKEN}"; exit 0; fi
    exit 3
  SH

  class RecordingHTTP
    attr_reader :urls, :authorization

    def initialize
      @urls = []
      @authorization = []
    end

    def request(request)
      @urls << request.uri.to_s
      @authorization << request['Authorization']
      value = Net::HTTPOK.new('1.1', '200', 'OK')
      value.instance_variable_set(:@read, true)
      value.instance_variable_set(:@body, '{"ok":true}')
      value
    end
  end

  def setup
    @saved = ENV.to_h
    %w[SIGMA_BASE_URL SIGMA_API_TOKEN SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET SIGMA_TOKEN_MINTED_AT
       SIGMA_AUTH_METHOD SIGMA_AUTH_MODE SIGMA_TOKEN_PROVIDER SIGMA_PYTHON].each { |key| ENV.delete(key) }
    Sigma.instance_variable_set(:@token_override, nil)
    Sigma.instance_variable_set(:@minted_at, nil)
    Sigma.instance_variable_set(:@refresh_inflight, false)
    Sigma.instance_variable_set(:@validated_bases, nil)
  end

  def teardown
    ENV.replace(@saved)
  end

  def test_request_derives_base_url_from_the_provider_result
    http = RecordingHTTP.new
    Sigma.stub(:token_provider_result, PROVIDER) do
      assert_equal({ 'ok' => true }, Sigma.request(:get, '/v2/whoami', http: http))
    end
    assert_equal ["#{CLI_BASE}/v2/whoami"], http.urls
    assert_equal ["Bearer #{FAKE_JWT}"], http.authorization
    assert_equal CLI_BASE, ENV['SIGMA_BASE_URL']
    assert_equal 'sigma-cli', ENV['SIGMA_AUTH_METHOD']
    assert_nil Sigma.token_minted_at
  end

  def test_derived_non_sigma_host_is_refused_before_any_request
    http = RecordingHTTP.new
    evil = PROVIDER.merge('SIGMA_BASE_URL' => 'https://api.evil.test')
    err = assert_raises(SystemExit) do
      capture_io do
        Sigma.stub(:token_provider_result, evil) { Sigma.request(:get, '/v2/whoami', http: http) }
      end
    end
    refute err.success?
    assert_empty http.urls
    assert_nil ENV['SIGMA_BASE_URL']
    assert_nil ENV['SIGMA_API_TOKEN']
  end

  def test_derived_non_https_host_is_refused
    http = RecordingHTTP.new
    plain = PROVIDER.merge('SIGMA_BASE_URL' => 'http://aws-api.sigmacomputing.com')
    assert_raises(SystemExit) do
      capture_io do
        Sigma.stub(:token_provider_result, plain) { Sigma.request(:get, '/v2/whoami', http: http) }
      end
    end
    assert_empty http.urls
  end

  def test_explicit_base_url_wins_over_a_derived_one
    ENV['SIGMA_BASE_URL'] = 'https://api.sigmacomputing.com'
    ENV['SIGMA_API_TOKEN'] = FAKE_JWT
    http = RecordingHTTP.new
    Sigma.stub(:token_provider_result, PROVIDER) { Sigma.request(:get, '/v2/whoami', http: http) }
    assert_equal ['https://api.sigmacomputing.com/v2/whoami'], http.urls
    # A refresh (as after a 401) must not rewrite an explicit base URL either.
    Sigma.stub(:token_provider_result, PROVIDER) { Sigma.refresh_token! }
    assert_equal 'https://api.sigmacomputing.com', ENV['SIGMA_BASE_URL']
  end

  def test_a_caller_token_without_a_base_url_never_triggers_derivation
    ENV['SIGMA_API_TOKEN'] = 'caller-token'
    called = false
    Sigma.stub(:token_provider_result, -> { called = true; PROVIDER }) do
      assert_raises(Sigma::Error) { Sigma.request(:get, '/v2/whoami', http: RecordingHTTP.new) }
    end
    refute called
  end

  def test_provider_without_a_base_url_leaves_the_clear_error
    no_base = PROVIDER.reject { |key, _| key == 'SIGMA_BASE_URL' }
    err = assert_raises(Sigma::Error) do
      Sigma.stub(:token_provider_result, no_base) { Sigma.request(:get, '/v2/whoami', http: RecordingHTTP.new) }
    end
    assert_match(/SIGMA_BASE_URL/, err.message)
  end

  def test_fake_cli_through_the_real_provider_reaches_the_derived_host
    provider = ['../get_token.py', '../scripts/get_token.py']
               .map { |rel| File.expand_path(rel, __dir__) }.find { |path| File.file?(path) }
    skip 'get_token.py is not vendored next to this sigma_rest.rb' unless provider
    Dir.mktmpdir do |tmp|
      bindir = File.join(tmp, 'bin')
      Dir.mkdir(bindir)
      File.write(File.join(bindir, 'sigma'), FAKE_SIGMA)
      File.chmod(0o700, File.join(bindir, 'sigma'))
      # The real provider, minus its network /v2/whoami verification.
      wrapper = File.join(tmp, 'provider.py')
      File.write(wrapper, <<~PY)
        import importlib.util, sys
        spec = importlib.util.spec_from_file_location('gt', #{provider.inspect})
        gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)
        gt._verify_token = lambda r: r
        sys.exit(gt.main(sys.argv[1:]))
      PY
      ENV['HOME'] = tmp
      ENV['PATH'] = "#{bindir}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
      ENV['SIGMA_TOKEN_PROVIDER'] = wrapper
      ENV['FAKE_SIGMA_BASE'] = CLI_BASE
      ENV['FAKE_SIGMA_TOKEN'] = FAKE_JWT
      ENV['SIGMA_AUTH_MODE'] = 'sigma-cli'
      http = RecordingHTTP.new
      Sigma.request(:get, '/v2/whoami', http: http)
      assert_equal ["#{CLI_BASE}/v2/whoami"], http.urls
      assert_equal ["Bearer #{FAKE_JWT}"], http.authorization
      assert_equal 'sigma-cli', ENV['SIGMA_AUTH_METHOD']
    end
  end
end
