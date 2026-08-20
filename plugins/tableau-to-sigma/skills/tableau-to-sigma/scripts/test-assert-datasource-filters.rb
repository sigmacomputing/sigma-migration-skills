#!/usr/bin/env ruby
# frozen_string_literal: true
# test-assert-datasource-filters.rb — regression test for the workbook
# code-rep `document` unwrap in scripts/assert-datasource-filters.rb (#483).
#
# The gate GETs the live workbook spec and calls DatasourceFilterCheck.
# violations(spec:) to see whether an always-on data-source filter was
# actually applied. Workbook code-rep GETs nest `pages` under a top-level
# `document` key (live since 2026-08). DatasourceFilterCheck.all_elements
# falls back to `spec['elements']` when `spec['pages']` isn't an Array — so
# an un-unwrapped nested response silently reads as ZERO elements, and a
# data-source filter that WAS correctly applied as a master default filter
# gets reported as a FALSE violation (gate FAILs, exit 1) on every run.
#
# use_ssl on this script derives from the URI scheme (`uri.scheme == 'https'`
# at line ~99), so — unlike export-chart-png.rb / scan-customer-style.rb,
# which hardcode use_ssl:true — a plain http:// loopback WEBrick server works
# directly (same convention as test-put-layout-auth.rb).
#
# Run: ruby scripts/test-assert-datasource-filters.rb
require 'webrick'
require 'json'
require 'tmpdir'
require 'open3'

SCRIPT = File.expand_path('assert-datasource-filters.rb', __dir__)

# The LIVE (nested) readback: the data-source filter (an always-on
# `Company Active` flag) IS correctly applied as a master default filter —
# so a correct unwrap must find it and PASS (exit 0). Pre-fix, the bare
# spec['pages'] read is nil, all_elements() returns [], and the gate reports
# a false FAIL.
LIVE_SPEC = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 3,
    'pages' => [{
      'id' => 'p1',
      'elements' => [
        { 'id' => 'master', 'kind' => 'table',
          'columns' => [{ 'id' => 'm-active', 'name' => 'Company Active' }],
          'filters' => [{ 'columnId' => 'm-active', 'kind' => 'list', 'mode' => 'include', 'values' => ['true'] }] }
      ]
    }]
  }
}.freeze

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def run_gate(script, dir, port)
  Open3.capture3(
    { 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}", 'SIGMA_API_TOKEN' => 'stub-token' },
    'ruby', script, '--workdir', dir, '--workbook-id', 'wb-test'
  )
end

puts '== assert-datasource-filters: nested live GET must not false-FAIL an applied filter =='
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'dashboard-layout-meta.json'), JSON.generate(
    'datasource_filters' => [
      { 'column_caption' => 'Company Active', 'is_datasource_filter' => true,
        'is_active_flag' => true, 'members' => ['true'] }
    ]
  ))

  srv = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                 Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
  port = srv.config[:Port]
  srv.mount_proc('/v2/workbooks/wb-test/spec') do |req, res|
    check(req.request_method == 'GET', 'gate issues a GET for the spec', fails)
    res.body = JSON.generate(LIVE_SPEC)
    res['Content-Type'] = 'application/json'
    res.status = 200
  end
  th = Thread.new { srv.start }

  out, err, st = run_gate(SCRIPT, dir, port)
  srv.shutdown
  th.join

  check(st.exitstatus.zero?,
        "gate exits 0 on a correctly-applied filter seen through a nested `document` readback (exit #{st.exitstatus}; out=#{out.inspect} err=#{err.inspect})",
        fails)
  check(out.include?('[OK]') && out.include?('applied'),
        "gate reports [OK] (got stdout: #{out.inspect})", fails)
  check(!out.include?('[FAIL]'), 'gate does NOT report a false [FAIL]', fails)
end

puts
if fails.empty?
  puts 'test-assert-datasource-filters: ALL PASS'
else
  puts "test-assert-datasource-filters: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
