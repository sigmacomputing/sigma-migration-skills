#!/usr/bin/env ruby
# frozen_string_literal: true
# test-probe-window-contexts.rb — regression test for the workbook code-rep
# `document` unwrap/wrap in scripts/probe-window-contexts.rb.
#
# find_schema_version borrows a schemaVersion from a real workbook (GET
# .../spec). Workbook code-rep GETs nest `schemaVersion` under a top-level
# `document` key (live since 2026-08); a bare `s['schemaVersion']` read there
# is always nil, so the probe silently falls back to the schemaVersion
# default of 1 instead of the org's real value. The two throwaway
# probe-workbook POSTs (`wb_spec`, `wb2_spec`) also need the `document` wrap
# — the data-model POST (`dm_spec`) in the same file is explicitly NOT
# touched (DM surface unchanged).
#
# Same offline seam convention as test-probe-join-keys.rb: stub sigma_rest.rb,
# run the real script via `ruby -I <stub> -r sigma_rest`, no live network.
# The DM-element context (context 3) is left to fail gracefully inside its own
# `rescue StandardError` (it needs a working dataModels stub this test does
# not provide) -- irrelevant to the wrapper fix under test, which concerns
# only the two workbook POSTs and the schemaVersion discovery GET.
#
# Run: ruby scripts/test-probe-window-contexts.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'probe-window-contexts.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

DISCOVERY_SPEC = {
  'workbookId' => 'wb-src',
  'document' => { 'schemaVersion' => 7, 'pages' => [{ 'id' => 'p1', 'elements' => [] }] }
}.freeze

SIGMA_STUB = <<~RUBY
  require 'json'
  module Sigma
    class Error < StandardError; end
    DISCOVERY_SPEC = #{DISCOVERY_SPEC.to_json}
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate('method' => method.to_s, 'path' => path, 'body' => body) }
      end
      case
      when method == :get && path == '/v2/whoami'
        { 'userId' => 'u1' }
      when method == :get && path == '/v2/members/u1'
        { 'homeFolderId' => 'home-1' }
      when method == :get && path.start_with?('/v2/workbooks?')
        { 'entries' => [{ 'workbookId' => 'wb-src' }] }
      when method == :get && path == '/v2/workbooks/wb-src/spec'
        JSON.parse(JSON.generate(DISCOVERY_SPEC))
      when method == :post && path == '/v2/workbooks/spec'
        @wb_posts ||= 0
        @wb_posts += 1
        { 'workbookId' => "wb-new-\#{@wb_posts}" }
      when method == :get && path.start_with?('/v2/dataModels/')
        raise Error, 'GET /v2/dataModels/x/spec -> 404 stub-not-implemented'
      when method == :post && path.include?('/export')
        { 'queryId' => 'q1' }
      when method == :delete
        nil
      else
        raise Error, "stub: unexpected \#{method} \#{path}"
      end
    end
    def self.base_url; 'https://stub.invalid'; end
    def self.auth_token; 'stub-token'; end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_probe(dir, extra_env = {})
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir) unless Dir.exist?(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub', 'TABLEAU_TO_SIGMA_HOME' => dir, 'KEEP' => '0' }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT)
end

def wb_posts(log)
  return [] unless File.exist?(log)
  File.readlines(log).map { |l| JSON.parse(l) }
      .select { |r| r['method'] == 'post' && r['path'] == '/v2/workbooks/spec' }
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== probe-window-contexts: nested discovery GET must recover the real schemaVersion =='
Dir.mktmpdir do |dir|
  log = File.join(dir, 'stub.log')
  out, _err, _st = run_probe(dir, { 'SIGMA_STUB_LOG' => log })
  check(out.include?('schemaVersion=7'),
        "discovery recovers the borrowed schemaVersion=7 from the nested document (got: #{out.lines.first})", fails)

  posts = wb_posts(log)
  check(posts.size == 1, "exactly one workbook POST captured (the DM-element context 3 stub 404s before its own workbook POST; got #{posts.size})", fails)
  if posts.size >= 1
    body = JSON.parse(posts.first['body'])
    check(body.key?('document') && body['document'].is_a?(Hash),
          'probe-workbook POST body carries a top-level `document` key', fails)
    check(!body.key?('pages') && !body.key?('schemaVersion'),
          'probe-workbook POST body has NO top-level pages/schemaVersion (must be nested)', fails)
    doc = body['document'].is_a?(Hash) ? body['document'] : {}
    check(doc['schemaVersion'] == 7,
          "wrapped document carries the borrowed schemaVersion=7 (got #{doc['schemaVersion'].inspect})", fails)
    check(doc['pages'].is_a?(Array) && !doc['pages'].empty?,
          'wrapped document carries pages (grouped + ungrouped table elements)', fails)
    check(body['name'] && body['folderId'] == 'home-1',
          'name/folderId stay OUTSIDE document as metadata', fails)
  end
end

puts
if fails.empty?
  puts 'test-probe-window-contexts: ALL PASS'
else
  puts "test-probe-window-contexts: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
