#!/usr/bin/env ruby
# frozen_string_literal: true
# test-scan-customer-style.rb — regression test for the workbook code-rep
# `document` unwrap in scripts/scan-customer-style.rb.
#
# scan-customer-style.rb GETs each sampled workbook's spec and aggregates
# style choices (chart kinds, palettes, pages/elements-per-page, etc). Workbook
# code-rep GETs nest `schemaVersion`/`pages` under a top-level `document` key
# (live since 2026-08); bare `spec['schemaVersion']`/`spec['pages']` reads
# there were always nil/empty, so every workbook silently scanned as 0 pages
# and 0 elements — the profile came back structurally empty on every run.
#
# This script hardcodes `use_ssl: true` in its own `http_get` helper, so (same
# as test-export-chart-png.rb) we shadow the stdlib `net/http` via a
# `-I <stub>` load-path shim instead of a plain-http loopback server. No real
# network, no TLS.
#
# Run: ruby scripts/test-scan-customer-style.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

SCRIPT = File.join(__dir__, 'scan-customer-style.rb')

NESTED_SPEC = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 4,
    'pages' => [{
      'id' => 'p1',
      'elements' => [
        { 'id' => 'c1', 'kind' => 'bar-chart', 'name' => 'Revenue by Region',
          'color' => { 'by' => 'series', 'scheme' => ['#0e7c7b', '#f4a261'] } },
        { 'id' => 'ctl1', 'kind' => 'control', 'controlType' => 'text' }
      ]
    }]
  }
}.freeze

NET_HTTP_STUB = <<~RUBY
  require 'json'
  module Net
    class HTTPStubResp
      attr_reader :code, :body
      def initialize(code, body); @code = code.to_s; @body = body; end
    end
    class HTTPStubReq
      attr_reader :uri
      attr_accessor :body
      def initialize(uri); @uri = uri; @headers = {}; end
      def []=(k, v); @headers[k.to_s] = v; end
      def [](k); @headers[k.to_s]; end
    end
    class HTTPGetStub < HTTPStubReq; def verb; 'GET'; end; end
    NESTED_SPEC = #{NESTED_SPEC.to_json}
    class HTTP
      Get = HTTPGetStub
      def self.start(_host, _port, **_opts)
        yield new
      end
      def request(req)
        if ENV['NET_HTTP_STUB_LOG']
          File.open(ENV['NET_HTTP_STUB_LOG'], 'a') do |f|
            f.puts JSON.generate('verb' => req.verb, 'path' => req.uri.request_uri)
          end
        end
        path = req.uri.request_uri
        case
        when req.verb == 'GET' && path == '/v2/workbooks/wb-test/spec'
          HTTPStubResp.new(200, JSON.generate(NESTED_SPEC))
        else
          HTTPStubResp.new(404, 'not found')
        end
      end
    end
  end
RUBY

def run_scan(dir, out_dir, extra_env = {})
  stub_dir = File.join(dir, 'stub', 'net')
  FileUtils.mkdir_p(stub_dir)
  File.write(File.join(stub_dir, 'http.rb'), NET_HTTP_STUB)
  Open3.capture3(
    { 'SIGMA_BASE_URL' => 'https://stub.invalid', 'SIGMA_API_TOKEN' => 'stub-token' }.merge(extra_env),
    RbConfig.ruby, '-I', File.join(dir, 'stub'), SCRIPT,
    '--workbook-ids', 'wb-test', '--out-dir', out_dir
  )
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== scan-customer-style: nested spec GET must not scan as 0 pages/elements =='
Dir.mktmpdir do |dir|
  out_dir = File.join(dir, 'profile')
  log = File.join(dir, 'stub.log')
  out, err, st = run_scan(dir, out_dir, { 'NET_HTTP_STUB_LOG' => log })

  check(st.exitstatus.zero?, "exits 0 (got #{st.exitstatus}; out=#{out.inspect} err=#{err.inspect})", fails)

  profile_path = File.join(out_dir, 'style-profile.json')
  check(File.exist?(profile_path), 'style-profile.json written', fails)
  if File.exist?(profile_path)
    profile = JSON.parse(File.read(profile_path))
    check(profile['sample_size'] == 1, "sample_size == 1 (got #{profile['sample_size'].inspect})", fails)
    check(profile['pages_per_workbook'] == [1],
          "pages_per_workbook == [1], not [0] (got #{profile['pages_per_workbook'].inspect})", fails)
    check(profile['schema_versions'] == { '4' => 1 },
          "schema_versions recovers schemaVersion=4 from the nested document (got #{profile['schema_versions'].inspect})", fails)
    check(profile['chart_kind_counts']['bar-chart'] == 1,
          "chart_kind_counts counts the nested bar-chart element (got #{profile['chart_kind_counts'].inspect})", fails)
    check(profile['palettes']['#0e7c7b,#f4a261'] == 1,
          "palette scheme recovered from the nested element (got #{profile['palettes'].inspect})", fails)
  end

  reqs = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  check(reqs.any? { |r| r['verb'] == 'GET' && r['path'] == '/v2/workbooks/wb-test/spec' },
        'spec GET issued', fails)
end

puts
if fails.empty?
  puts 'test-scan-customer-style: ALL PASS'
else
  puts "test-scan-customer-style: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
