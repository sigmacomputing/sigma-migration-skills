#!/usr/bin/env ruby
# frozen_string_literal: true
# test-collect-parity-actuals-pivot.rb — pivot-table parity actuals come from the
# element's JSON export over the REST API, with no Sigma MCP.
#
# A pivot's CSV export is the WIDE grid, so collect-parity-actuals.rb used to
# skip every pivot and leave it to an agent-mediated MCP query, which leaves a
# customer without the Sigma MCP no automatic pivot parity. The JSON export
# returns long-form leaf rows keyed by column display name (live-verified
# 2026-10-27 on single- and multi-measure pivots, with and without totals and
# the stacked Measure Names layout), plus subtotal keys such as
# "Net Revenue (Grand Total)" that the by-name mapping must ignore.
#
# Network is stubbed the same way as test-collect-parity-actuals.rb (a
# sigma_rest.rb load-path shadow). The stub fails the run on a CSV export, so
# the test also proves the pivot never takes the wide-grid CSV route.
#
# Run: ruby scripts/test-collect-parity-actuals-pivot.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'collect-parity-actuals.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

WB_SPEC = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 4, 'kind' => 'workbook',
    'pages' => [{ 'id' => 'p1', 'name' => 'Overview' }],
    'elements' => [
      { 'id' => 'pv1', 'kind' => 'pivot-table', 'name' => 'Channel Pivot',
        'columns' => [
          { 'id' => 'p-group', 'name' => 'Channel Group' },
          { 'id' => 'p-channel', 'name' => 'Order Channel' },
          { 'id' => 'p-rev', 'name' => 'Net Revenue' }
        ],
        'rowsBy' => [{ 'columnId' => 'p-group' }], 'columnsBy' => [{ 'columnId' => 'p-channel' }],
        'values' => ['p-rev'] }
    ],
    'layout' => '<Page id="p1"><Element elementId="pv1"/></Page>'
  }
}.freeze

PLAN = { 'charts' => [
  { 'chart' => 'Channel Pivot', 'sigma_element_id' => 'pv1', 'sigma_kind' => 'pivot-table',
    'sigma_columns' => %w[p-group p-channel p-rev] }
] }.freeze

# The JSON export's wire shape as Sigma returns it: one object per leaf cell,
# keyed by display name, with subtotal keys alongside.
JSON_BODY = JSON.generate([
  { 'Channel Group' => 'Digital', 'Order Channel' => 'App', 'Net Revenue' => 17_424.3,
    'Net Revenue (Channel Group)' => 148_393.23, 'Net Revenue (Grand Total)' => 192_667.61 },
  { 'Channel Group' => 'Digital', 'Order Channel' => 'Online', 'Net Revenue' => 130_968.93,
    'Net Revenue (Channel Group)' => 148_393.23, 'Net Revenue (Grand Total)' => 192_667.61 },
  { 'Channel Group' => 'Store', 'Order Channel' => 'In-Store', 'Net Revenue' => 44_274.38,
    'Net Revenue (Channel Group)' => 44_274.38, 'Net Revenue (Grand Total)' => 192_667.61 }
])

SIGMA_STUB = <<~RUBY
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate('method' => method.to_s, 'path' => path, 'body' => body, 'accept' => accept) }
      end
      case
      when method == :post && path == '/v2/workbooks/wb-test/export'
        fmt = JSON.parse(body.to_s).dig('format', 'type')
        raise Error, 'stub: a pivot must not take the wide-grid CSV export' if fmt == 'csv'
        { 'queryId' => 'qj' }
      when method == :get && path == '/v2/query/qj/download'
        ENV.fetch('STUB_JSON_BODY')
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

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== collect-parity-actuals: a pivot is collected from the REST JSON export =='
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)
  spec_path = File.join(dir, 'wb-readback.json')
  plan_path = File.join(dir, 'parity-plan.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  log = File.join(dir, 'stub.log')
  File.write(spec_path, JSON.generate(WB_SPEC))
  File.write(plan_path, JSON.generate(PLAN))

  out, err, st = Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub-token', 'SIGMA_STUB_LOG' => log, 'STUB_JSON_BODY' => JSON_BODY },
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT,
    '--plan', plan_path, '--workbook-id', 'wb-test', '--workbook-spec', spec_path,
    '--out', out_path, '--pool', '1', '--timeout', '30', '--drift-warn-minutes', '0'
  )
  check(st.exitstatus.zero?, "exits 0 (got #{st.exitstatus}; err=#{err[0, 300].inspect})", fails)
  check(out.include?('1/1 chart(s) collected') && !out.include?('NOT COLLECTED') && !out.include?('pivot-table'),
        "the pivot is collected, not skipped for an MCP query (got: #{out.inspect})", fails)
  actuals = File.exist?(out_path) ? JSON.parse(File.read(out_path)) : {}
  check(actuals['Channel Pivot'] == [['Digital', 'App', 17_424.3], ['Digital', 'Online', 130_968.93], ['Store', 'In-Store', 44_274.38]],
        "actuals are the long-form leaf tuples; subtotal keys are ignored (got #{actuals['Channel Pivot'].inspect})", fails)
  reqs = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  posts = reqs.select { |r| r['method'] == 'post' }
  check(posts.size == 1 && JSON.parse(posts.first['body']).dig('format', 'type') == 'json',
        "exactly one export, in JSON format (got #{posts.map { |r| r['body'] }.inspect})", fails)
end

puts
if fails.empty?
  puts 'test-collect-parity-actuals-pivot: ALL PASS'
else
  puts "test-collect-parity-actuals-pivot: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
