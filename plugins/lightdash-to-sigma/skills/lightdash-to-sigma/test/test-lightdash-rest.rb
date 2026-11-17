#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for lib/lightdash_rest.rb (fake transport; no network).
#
#   ruby test/test-lightdash-rest.rb

require 'minitest/autorun'
require 'json'
require_relative '../scripts/lib/lightdash_rest'

class LightdashRestTest < Minitest::Test
  KEY = 'ld-secret-key-123'

  def client(code: 200, body: { 'status' => 'ok', 'results' => { 'a' => 1 } }, calls: [])
    t = lambda do |verb, uri, headers, payload|
      calls << { verb: verb, uri: uri.to_s, headers: headers, body: payload }
      [code, body.is_a?(String) ? body : JSON.generate(body)]
    end
    LightdashRest::Client.new(base_url: 'https://ld.example.com/', api_key: KEY, transport: t)
  end

  def test_sends_api_key_header_and_unwraps_results
    calls = []
    assert_equal({ 'a' => 1 }, client(calls: calls).get('/api/v1/org'))
    assert_equal 'ApiKey ' + KEY, calls[0][:headers]['Authorization']
    assert_equal 'https://ld.example.com/api/v1/org', calls[0][:uri]
    assert_equal 'GET', calls[0][:verb]
  end

  def test_post_sends_json_body
    calls = []
    client(calls: calls).post('/api/v1/projects/p/explores/orders/runQuery', { 'limit' => 5 })
    assert_equal 'POST', calls[0][:verb]
    assert_equal({ 'limit' => 5 }, JSON.parse(calls[0][:body]))
    assert_equal 'application/json', calls[0][:headers]['Content-Type']
  end

  def test_query_params_are_encoded
    calls = []
    client(calls: calls).get('/x', query: { 'a' => 'b c' })
    assert_equal 'https://ld.example.com/x?a=b+c', calls[0][:uri]
  end

  def test_http_error_raises_with_status_and_excerpt_without_key
    e = assert_raises(LightdashRest::Error) do
      client(code: 403, body: "Forbidden: token #{KEY} rejected").get('/api/v1/org')
    end
    assert_match(/GET \/api\/v1\/org -> HTTP 403: Forbidden/, e.message)
    refute_includes e.message, KEY
  end

  def test_non_ok_status_in_200_body_raises
    e = assert_raises(LightdashRest::Error) { client(body: { 'status' => 'error', 'error' => { 'name' => 'Nope' } }).get('/x') }
    assert_match(/status "error"/, e.message)
  end

  def test_bare_json_without_envelope_is_returned_as_is
    assert_equal [1, 2], client(body: [1, 2]).get('/x')
  end

  def test_non_json_body_raises
    assert_raises(LightdashRest::Error) { client(body: '<html>').get('/x') }
  end

  def test_from_env_requires_both_values_and_inspect_hides_key
    assert_raises(LightdashRest::Error) { LightdashRest::Client.from_env({ 'LIGHTDASH_URL' => 'https://x' }) }
    assert_raises(LightdashRest::Error) { LightdashRest::Client.from_env({ 'LIGHTDASH_API_KEY' => KEY }) }
    refute LightdashRest::Client.configured?({ 'LIGHTDASH_URL' => 'https://x' })
    env = { 'LIGHTDASH_URL' => 'https://x', 'LIGHTDASH_API_KEY' => KEY }
    assert LightdashRest::Client.configured?(env)
    refute_includes LightdashRest::Client.from_env(env).inspect, KEY
  end

  def test_warns_on_plain_http_to_a_remote_host_only
    [['http://ld.example.com', true], ['http://localhost:8080', false], ['http://127.0.0.1:8080', false],
     ['https://ld.example.com', false]].each do |url, warns|
      _o, err = capture_io { LightdashRest::Client.new(base_url: url, api_key: KEY) }
      assert_equal warns, err.include?('plain http://'), url
      refute_includes err, KEY
    end
  end
end
