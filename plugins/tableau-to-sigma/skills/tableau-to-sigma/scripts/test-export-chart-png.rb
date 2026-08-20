#!/usr/bin/env ruby
# frozen_string_literal: true
# test-export-chart-png.rb — regression test for the workbook code-rep
# `document` unwrap in scripts/export-chart-png.rb.
#
# export-chart-png.rb GETs the live workbook spec to discover chart-shaped
# elements to screenshot. Workbook code-rep GETs nest `pages` under a
# top-level `document` key (live since 2026-08); a bare `spec['pages']` read
# there is always nil, so `elements` comes back empty and the script hard-
# aborts with "no matching elements" before ever reaching the export/PNG
# flow.
#
# This script hardcodes `use_ssl: true` in its own `http` helper (unlike
# assert-datasource-filters.rb, which derives use_ssl from the URI scheme), so
# a plain http:// loopback WEBrick server can't be used without a TLS cert
# dance. Instead we shadow the stdlib `net/http` via a `-I <stub>` load-path
# shim — same "shadow the require, mark the real file already-loaded" trick
# test-probe-control-formula.rb / test-probe-window-contexts.rb use for
# `sigma_rest.rb`, applied here to `net/http` (this script never requires
# `sigma_rest`, so `net/http` is the only network seam to intercept). No real
# network, no TLS.
#
# Run: ruby scripts/test-export-chart-png.rb
require 'json'
require 'base64'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'export-chart-png.rb')

# The live (nested) workbook readback: one bar-chart element to screenshot,
# plus a control element that must NOT be selected (not chart-shaped).
NESTED_SPEC = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 4,
    'pages' => [{
      'id' => 'p1',
      'elements' => [
        { 'id' => 'c1', 'kind' => 'bar-chart', 'name' => 'Revenue by Region' },
        { 'id' => 'ctl1', 'kind' => 'control', 'controlType' => 'text' }
      ]
    }]
  }
}.freeze

PNG_BYTES = ("\x89PNG\r\n\x1A\n".b + ('x' * 2000).b).freeze

NET_HTTP_STUB = <<~RUBY
  require 'json'
  require 'base64'
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
    class HTTPPostStub < HTTPStubReq; def verb; 'POST'; end; end
    NESTED_SPEC = #{NESTED_SPEC.to_json}
    PNG_B64 = #{Base64.strict_encode64(PNG_BYTES).inspect}
    class HTTP
      Get = HTTPGetStub
      Post = HTTPPostStub
      def self.start(_host, _port, **_opts)
        yield new
      end
      def request(req)
        if ENV['NET_HTTP_STUB_LOG']
          File.open(ENV['NET_HTTP_STUB_LOG'], 'a') do |f|
            f.puts JSON.generate('verb' => req.verb, 'path' => req.uri.request_uri, 'body' => req.body)
          end
        end
        path = req.uri.request_uri
        case
        when req.verb == 'GET' && path == '/v2/workbooks/wb-test/spec'
          HTTPStubResp.new(200, JSON.generate(NESTED_SPEC))
        when req.verb == 'POST' && path == '/v2/workbooks/wb-test/export'
          HTTPStubResp.new(200, JSON.generate('queryId' => 'q1'))
        when req.verb == 'GET' && path == '/v2/query/q1/download'
          HTTPStubResp.new(200, Base64.decode64(PNG_B64))
        else
          HTTPStubResp.new(404, 'not found')
        end
      end
    end
  end
RUBY

def run_export(dir, extra_env = {})
  stub_dir = File.join(dir, 'stub', 'net')
  require 'fileutils'
  FileUtils.mkdir_p(stub_dir)
  File.write(File.join(stub_dir, 'http.rb'), NET_HTTP_STUB)
  out_dir = File.join(dir, 'out')
  Open3.capture3(
    { 'SIGMA_BASE_URL' => 'https://stub.invalid', 'SIGMA_API_TOKEN' => 'stub-token' }.merge(extra_env),
    RbConfig.ruby, '-I', File.join(dir, 'stub'), SCRIPT,
    '--workbook', 'wb-test', '--out-dir', out_dir
  )
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== export-chart-png: nested spec GET must not abort "no matching elements" =='
Dir.mktmpdir do |dir|
  log = File.join(dir, 'stub.log')
  out, err, st = run_export(dir, { 'NET_HTTP_STUB_LOG' => log })

  check(!err.include?('no matching elements'),
        "does NOT hard-abort with 'no matching elements' (err=#{err.inspect})", fails)
  check(st.exitstatus.zero?, "exits 0 (got #{st.exitstatus}; out=#{out.inspect} err=#{err.inspect})", fails)
  check(err.include?('1/1 ok'), "reports 1/1 screenshots ok (got stderr: #{err.inspect})", fails)

  manifest_path = File.join(dir, 'out', '_manifest.json')
  check(File.exist?(manifest_path), 'manifest.json written', fails)
  if File.exist?(manifest_path)
    manifest = JSON.parse(File.read(manifest_path))
    check(manifest.key?('c1'), "manifest carries the chart element c1 (got keys: #{manifest.keys.inspect})", fails)
    check(manifest['c1'] && manifest['c1']['status'] == 'ok',
          "c1 status ok (got #{manifest['c1'] && manifest['c1']['status']})", fails)
    check(!manifest.key?('ctl1'), 'control element ctl1 NOT screenshotted (not chart-shaped)', fails)
  end

  reqs = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  check(reqs.any? { |r| r['verb'] == 'GET' && r['path'] == '/v2/workbooks/wb-test/spec' },
        'spec GET issued', fails)
  check(reqs.any? { |r| r['verb'] == 'POST' && r['path'] == '/v2/workbooks/wb-test/export' },
        'export POST issued for the discovered chart', fails)
end

puts
if fails.empty?
  puts 'test-export-chart-png: ALL PASS'
else
  puts "test-export-chart-png: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
