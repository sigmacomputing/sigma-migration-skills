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
