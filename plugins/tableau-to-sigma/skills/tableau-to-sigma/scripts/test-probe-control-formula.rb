#!/usr/bin/env ruby
# frozen_string_literal: true
# test-probe-control-formula.rb — regression test for the workbook code-rep
# `document` unwrap/wrap in scripts/probe-control-formula.rb.
#
# probe-control-formula.rb borrows a schemaVersion + control + warehouse-table
# source from a real workbook in the org (GET .../spec), then POSTs a
# throwaway probe workbook built from those borrowed pieces. Workbook code-rep
# GETs nest `schemaVersion`/`pages` under a top-level `document` key (live
# since 2026-08); a bare `spec['schemaVersion']` read on that response is
# always nil, so the discovery loop's `next unless spec['schemaVersion']`
# guard fires on EVERY workbook it looks at and the script hard-aborts with
# "could not find a warehouse-table source in any workbook" before it ever
# reaches the probe-workbook POST.
#
# Same offline seam convention as test-probe-join-keys.rb: stub sigma_rest.rb,
# run the real script via `ruby -I <stub> -r sigma_rest`, no live network.
#
# Run: ruby scripts/test-probe-control-formula.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'probe-control-formula.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

# The discovery-source workbook's LIVE (nested) readback: schemaVersion/pages
# live under `document`; workbookId is metadata alongside it.
DISCOVERY_SPEC = {
  'workbookId' => 'wb-src',
  'document' => {
    'schemaVersion' => 3,
    'pages' => [{
      'id' => 'p1',
      'elements' => [
        { 'id' => 'src-tbl', 'kind' => 'table',
          'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1', 'path' => %w[DB SCHEMA T] } },
        { 'id' => 'src-ctl', 'kind' => 'control', 'controlType' => 'text', 'controlId' => 'SrcCtl' }
      ]
    }]
  }
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
        { 'workbookId' => 'wb-new' }
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

def spec_posts(log)
  return [] unless File.exist?(log)
  File.readlines(log).map { |l| JSON.parse(l) }
      .select { |r| r['method'] == 'post' && r['path'] == '/v2/workbooks/spec' }
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== probe-control-formula: nested discovery GET must not abort the run =='
Dir.mktmpdir do |dir|
  log = File.join(dir, 'stub.log')
  out, err, _st = run_probe(dir, { 'SIGMA_STUB_LOG' => log })
  check(!err.include?('could not find a warehouse-table source'),
        'discovery loop does NOT hard-abort on the nested-document readback', fails)
  check(out.include?('created throwaway workbook wb-new'),
        'probe reaches workbook creation (schemaVersion + source + control all recovered)', fails)

  posts = spec_posts(log)
  check(posts.size == 1, "exactly one probe-workbook POST captured (got #{posts.size})", fails)
  if posts.size == 1
    body = JSON.parse(posts.first['body'])
    check(body.key?('document') && body['document'].is_a?(Hash),
          'probe-workbook POST body carries a top-level `document` key', fails)
    check(!body.key?('pages') && !body.key?('schemaVersion'),
          'probe-workbook POST body has NO top-level pages/schemaVersion (must be nested)', fails)
    check(body['document']['schemaVersion'] == 3,
          "wrapped document carries the borrowed schemaVersion=3 (got #{body['document']['schemaVersion'].inspect})", fails)
    check(body['document']['pages'].is_a?(Array) && !body['document']['pages'].empty?,
          'wrapped document carries pages', fails)
    check(body['name'] && body['folderId'] == 'home-1',
          'name/folderId stay OUTSIDE document as metadata', fails)
  end
end

puts
if fails.empty?
  puts 'test-probe-control-formula: ALL PASS'
else
  puts "test-probe-control-formula: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
