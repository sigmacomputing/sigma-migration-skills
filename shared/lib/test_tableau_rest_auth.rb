#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'timeout'
saved = ENV['TABLEAU_PAT_SECRET']
ENV['TABLEAU_PAT_SECRET'] = 'synthetic-secret'
require_relative 'tableau_rest'
saved ? ENV['TABLEAU_PAT_SECRET'] = saved : ENV.delete('TABLEAU_PAT_SECRET')

class TableauRefreshTest < Minitest::Test
  def test_killed_signin_releases_waiter_and_recursive_signin_fails_closed
    saved = ENV.to_h
    ENV.update('TABLEAU_SERVER_URL' => 'https://tableau.example', 'TABLEAU_PAT_NAME' => 'synthetic',
               'TABLEAU_PAT_SECRET' => 'synthetic-secret', 'TABLEAU_SITE_CONTENT_URL' => '')
    entered, release = Queue.new, Queue.new
    threads = []
    Net::HTTP.stub(:start, ->(*_args) { entered << true; release.pop }) do
      begin
        owner = Thread.new { Tableau.refresh_token! }
        threads << owner
        Timeout.timeout(3) { entered.pop }
        waiter = Thread.new { Tableau.refresh_token! rescue $! }
        threads << waiter
        Timeout.timeout(3) { Thread.pass until waiter.status != 'run' }
        owner.kill
        owner.join
        error = Timeout.timeout(3) { waiter.value }
        assert_kind_of Tableau::AuthError, error
        assert_match(/aborted/, error.message)
      ensure
        release << true
        threads.each { |thread| thread.kill if thread.alive? }
        threads.each(&:join)
      end
    end
    Net::HTTP.stub(:start, ->(*_args) { Tableau.refresh_token! }) do
      assert_raises(Tableau::AuthError) { Tableau.refresh_token! }
    end
  ensure
    ENV.replace(saved)
  end

  def test_malformed_signin_does_not_replace_cached_credentials
    saved = ENV.to_h
    ENV.update('TABLEAU_SERVER_URL' => 'https://tableau.example', 'TABLEAU_PAT_NAME' => 'synthetic',
               'TABLEAU_PAT_SECRET' => 'synthetic-secret', 'TABLEAU_SITE_CONTENT_URL' => '')
    Tableau.instance_variable_set(:@token_override, 'prior-token')
    Tableau.instance_variable_set(:@site_id_override, 'prior-site')
    [{}, [], { 'credentials' => { 'token' => 'new-token' } },
     { 'credentials' => { 'token' => '', 'site' => { 'id' => 'new-site' } } }].each do |body|
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, JSON.generate(body))
      Net::HTTP.stub(:start, ->(*_args) { response }) do
        assert_raises(Tableau::AuthError) { Tableau.refresh_token! }
      end
      assert_equal 'prior-token', Tableau.instance_variable_get(:@token_override)
      assert_equal 'prior-site', Tableau.site_id
    end
  ensure
    ENV.replace(saved)
  end

  def test_concurrent_signin_shares_success_or_failure_without_stale_tokens
    [false, true].each do |failure|
      saved = ENV.to_h
      ENV.update('TABLEAU_SERVER_URL' => 'https://tableau.example', 'TABLEAU_PAT_NAME' => 'synthetic',
                 'TABLEAU_PAT_SECRET' => 'synthetic-secret', 'TABLEAU_SITE_CONTENT_URL' => '')
      Tableau.instance_variable_set(:@token_override, 'expired-token')
      Tableau.instance_variable_set(:@refresh_inflight, false)
      entered, release = Queue.new, Queue.new
      calls = 0
      transport = lambda do |*_args|
        calls += 1
        entered << true
        release.pop
        raise Tableau::AuthError, 'synthetic failure' if failure
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, JSON.generate('credentials' => { 'token' => 'fresh-token', 'site' => { 'id' => 'site-new' } }))
        response
      end
      attempt = -> { Tableau.refresh_token! rescue $! }
      threads = []
      Net::HTTP.stub(:start, transport) do
        begin
          threads << Thread.new(&attempt)
          Timeout.timeout(3) { entered.pop }
          waiter = Thread.new(&attempt)
          threads << waiter
          Timeout.timeout(3) { Thread.pass until waiter.status != 'run' }
          release << true
          results = Timeout.timeout(3) { threads.map(&:value) }
          if failure
            assert results.all? { |result| result.is_a?(Tableau::AuthError) }, results.inspect
          else
            assert_equal ['fresh-token', 'fresh-token'], results
            assert_equal 'site-new', Tableau.site_id
          end
          assert_equal 1, calls
        ensure
          release << true
          threads.each { |thread| thread.kill if thread.alive? }
          threads.each(&:join)
          ENV.replace(saved)
        end
      end
    end
  end
end

# tableau_rest's settings-file loader runs at require time (before sigma_rest in
# scripts such as rank-connections.rb), so it must apply the same explicit
# SIGMA_CLI_PROFILE pin rule and marker. Each case runs in a fresh Ruby process.
class TableauExplicitProfileTest < Minitest::Test
  require 'tmpdir'
  require 'open3'
  require 'rbconfig'

  SETTINGS = <<~ENVFILE
    export TABLEAU_PAT_NAME='pat'
    export SIGMA_BASE_URL='https://api.sigmacomputing.com'
    export SIGMA_CLIENT_ID='org-a-id'
    export SIGMA_CLIENT_SECRET='org-a-secret'
    export SIGMA_API_TOKEN='org-a-token'
    export SIGMA_AUTH_MODE='client-credentials'
  ENVFILE
  KEYS = %w[TABLEAU_PAT_NAME SIGMA_BASE_URL SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET SIGMA_API_TOKEN
            SIGMA_AUTH_MODE SIGMA_CLI_PROFILE SIGMA_CLI_PROFILE_FROM_FILE].freeze
  TABLEAU = File.expand_path('tableau_rest.rb', __dir__)
  SIGMA = File.expand_path('sigma_rest.rb', __dir__)

  def loaded(settings, extra = {}, also_sigma = false)
    Dir.mktmpdir do |home|
      Dir.mkdir(File.join(home, '.sigma-migration'))
      File.write(File.join(home, '.sigma-migration', 'env'), settings)
      reqs = "require #{TABLEAU.inspect}; "
      reqs += "require #{SIGMA.inspect}; " if also_sigma
      script = "#{reqs}puts #{KEYS.inspect}.map { |k| \"\#{k}=\#{ENV[k]}\" }"
      env = { 'HOME' => home, 'PATH' => ENV['PATH'], 'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8' }.merge(extra)
      # Test harness: runs a literal require-and-print script with the current interpreter in a scrubbed env; no user input reaches the command.
      # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
      out, err, status = Open3.capture3(env, RbConfig.ruby, '-e', script, unsetenv_others: true)
      assert status.success?, err
      out.lines.to_h { |l| l.chomp.split('=', 2).then { |k, v| [k, v.to_s] } }
    end
  end

  def test_explicit_profile_skips_sigma_org_keys_but_loads_tableau_keys
    got = loaded(SETTINGS, 'SIGMA_CLI_PROFILE' => 'work (1)')
    %w[SIGMA_BASE_URL SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET SIGMA_API_TOKEN SIGMA_AUTH_MODE].each do |key|
      assert_equal '', got[key], key
    end
    assert_equal 'pat', got['TABLEAU_PAT_NAME']
    assert_equal '', got['SIGMA_CLI_PROFILE_FROM_FILE']
  end

  def test_explicit_profile_still_pins_when_sigma_rest_loads_after_tableau_rest
    got = loaded(SETTINGS, { 'SIGMA_CLI_PROFILE' => 'work (1)' }, true)
    assert_equal '', got['SIGMA_BASE_URL']
    assert_equal '', got['SIGMA_CLIENT_ID']
  end

  def test_no_profile_loads_everything_as_before
    got = loaded(SETTINGS)
    assert_equal 'org-a-id', got['SIGMA_CLIENT_ID']
    assert_equal 'https://api.sigmacomputing.com', got['SIGMA_BASE_URL']
  end

  def test_file_set_profile_is_marked_and_not_explicit
    got = loaded(SETTINGS + "export SIGMA_CLI_PROFILE='from-file'\n", {}, true)
    assert_equal 'from-file', got['SIGMA_CLI_PROFILE']
    assert_equal 'from-file', got['SIGMA_CLI_PROFILE_FROM_FILE']
    assert_equal 'org-a-id', got['SIGMA_CLIENT_ID']
  end

  def test_explicit_profile_under_a_stale_marker_still_pins
    got = loaded(SETTINGS, 'SIGMA_CLI_PROFILE' => 'work (1)', 'SIGMA_CLI_PROFILE_FROM_FILE' => 'from-file')
    assert_equal '', got['SIGMA_CLIENT_ID']
  end

  def test_sourced_file_only_profile_without_marker_is_not_explicit
    settings = SETTINGS + "export SIGMA_CLI_PROFILE='from-file'\n"
    assert_equal 'org-a-id', loaded(settings, 'SIGMA_CLI_PROFILE' => 'from-file')['SIGMA_CLIENT_ID']
    assert_equal '', loaded(settings, 'SIGMA_CLI_PROFILE' => 'work (1)')['SIGMA_CLIENT_ID']
  end

  def test_profile_matching_the_marker_is_not_explicit
    got = loaded(SETTINGS, 'SIGMA_CLI_PROFILE' => 'from-file', 'SIGMA_CLI_PROFILE_FROM_FILE' => 'from-file')
    assert_equal 'org-a-id', got['SIGMA_CLIENT_ID']
  end
end
