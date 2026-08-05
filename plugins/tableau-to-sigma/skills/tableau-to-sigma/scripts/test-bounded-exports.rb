#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for issue #416 — the pooled element CSV export used by
# verify-anchors.rb and collect-parity-actuals.rb hung indefinitely (15+ min,
# 100% CPU, zero output) on multi-million-row unaggregated detail grids, and
# --timeout did not bound total runtime. New contract, end to end:
#
#   lib/export_pool.rb  ONE wall-clock Deadline per run; every poll loop,
#     download, and retry checks it; every export POST carries Sigma's
#     rowLimit; the pool prints one progress line per element start/finish.
#   verify-anchors.rb  --timeout = TOTAL budget → on expiry per-element
#     'timeout' status, partial verdict written, exit 4, timed-out elements
#     named. A miss over a TRUNCATED export → 'inconclusive-truncated' (exit
#     3), never a hard MISS. Normal path: exit 0, unchanged verdict shape.
#   collect-parity-actuals.rb  truncated chart export → FAIL-LOUD
#     'too-large-for-export' marker routed to the agent-mediated/warehouse
#     path (exit 0); total-deadline expiry → 'timeout' markers + exit 3 with
#     partial actuals; real rows never clobbered by either marker.
#   verify-parity.rb  both new markers report PENDING, never DIVERGE.
#
# The Sigma REST layer is stubbed per-element (el-anchor / el-big / el-slow /
# el-ok); no network. Usage:  ruby scripts/test-bounded-exports.rb

require 'json'
require 'csv'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPTS = __dir__
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', SCRIPTS)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Stub sigma_rest: loaded FIRST (ruby -I <stub> -r sigma_rest); it then marks
# the real lib path as already-required so the scripts' own `require
# 'sigma_rest'` no-ops. lib/export_pool.rb loads for real — it is the code
# under test — and calls this stub's Sigma.request.
#   el-anchor → small CSV carrying the anchor value (ready on first poll)
#   el-ok     → small chart CSV (Region/Revenue)
#   el-big    → header + STUB_BIG_ROWS data rows (== the row cap → truncated)
#   el-slow   → empty body forever ("still rendering") — only a deadline stops it
# Every export POST's rowLimit is appended to STUB_LOG for assertion.
STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      return File.read(ENV['STUB_SPEC']) if method == :get && path.end_with?('/spec')
      if method == :post && path.include?('/export')
        req = JSON.parse(body)
        File.open(ENV['STUB_LOG'], 'a') do |f|
          f.puts(JSON.generate('elementId' => req['elementId'], 'rowLimit' => req['rowLimit']))
        end
        return { 'queryId' => req['elementId'] }
      end
      if method == :get && path.start_with?('/v2/query/')
        case path.split('/')[3]
        when 'el-anchor' then return "Account,Revenue\nUnited Widgets,12345\nAcme,678\n"
        when 'el-ok'     then return "Region,Revenue\nEast,100\nWest,200\n"
        when 'el-big'
          n = ENV.fetch('STUB_BIG_ROWS', '5').to_i
          return "Region,Revenue\n" + (1..n).map { |i| "R#{i},#{i}" }.join("\n") + "\n"
        when 'el-slow'   then return ''
        end
      end
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_stubbed(stub_dir, extra_env, *argv)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub' }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', *argv)
end

def write_anchor_fixture(dir, elements, anchors)
  File.write(File.join(dir, 'stub-spec.json'),
             JSON.pretty_generate('pages' => [{ 'id' => 'pg1', 'elements' => elements }]))
  File.write(File.join(dir, 'source-anchors.json'),
             JSON.pretty_generate('source_image' => 'views/dash.png',
                                  'transcribed_at' => '2026-07-17T00:00:00Z',
                                  'anchors' => anchors))
end

# ============================================================================
# Part 1 — verify-anchors.rb: truncated export → inconclusive-truncated, exit 3
# ============================================================================
puts '-- verify-anchors: truncation → inconclusive-truncated (exit 3) --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  write_anchor_fixture(dir,
                       [{ 'id' => 'el-anchor', 'name' => 'Top Accounts', 'kind' => 'table' },
                        { 'id' => 'el-big', 'name' => 'Big Detail', 'kind' => 'table' }],
                       [{ 'id' => 'a1', 'panel' => 'TOP', 'label' => 'United Widgets revenue',
                          'raw' => '12,345', 'sigma_element_hint' => 'Top Accounts' },
                        { 'id' => 'a2', 'panel' => 'DETAIL', 'label' => 'Detail total',
                          'raw' => '99,999', 'sigma_element_hint' => 'Big Detail' }])
  log = File.join(dir, 'stub-log.jsonl')
  _out, err, st = run_stubbed(stub_dir,
                              { 'STUB_SPEC' => File.join(dir, 'stub-spec.json'), 'STUB_LOG' => log,
                                'STUB_BIG_ROWS' => '5' },
                              File.join(SCRIPTS, 'verify-anchors.rb'),
                              '--workdir', dir, '--workbook-id', 'wb',
                              '--row-limit', '5', '--timeout', '60', '--pool', '2')
  check(st.exitstatus == 3, "truncation-inconclusive run exits 3 (got #{st.exitstatus})", fails)
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  check(vd['missing'] == [], 'no hard MISS over the truncated export', fails)
  inc = Array(vd['inconclusive'])
  check(inc.length == 1 && inc[0]['id'] == 'a2' && inc[0]['status'] == 'inconclusive-truncated',
        'the unfound anchor is inconclusive-truncated (never MISS)', fails)
  check(inc[0]['truncated_elements'] == ['Big Detail'], 'inconclusive names the truncated element', fails)
  check(vd['matched'] == 1 && vd['pass'] == false, 'the found anchor still matches; pass stays false', fails)
  check(vd['export_status']['Big Detail'] == 'ok-truncated' && vd['export_status']['Top Accounts'] == 'ok',
        'verdict records per-element export status incl. ok-truncated', fails)
  posted = File.readlines(log).map { |l| JSON.parse(l) }
  check(posted.length == 2 && posted.all? { |p| p['rowLimit'] == 5 },
        'every export POST carries the Sigma rowLimit bound', fails)
  check(err.include?('INCONCLUSIVE') && err =~ /warehouse SQL oracle|--row-limit/,
        'guidance names the filter/warehouse-oracle/--row-limit options', fails)
  check(err.include?('START') && err.include?('DONE') && err.include?('TRUNCATED'),
        'pool progress lines printed (start/finish, truncation flagged)', fails)
end

# ============================================================================
# Part 2 — verify-anchors.rb: total deadline expiry mid-poll → exit 4, partial
# ============================================================================
puts '-- verify-anchors: --timeout bounds TOTAL runtime (exit 4, partial results) --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  write_anchor_fixture(dir,
                       [{ 'id' => 'el-anchor', 'name' => 'Top Accounts', 'kind' => 'table' },
                        { 'id' => 'el-slow', 'name' => 'Slow Tile', 'kind' => 'table' }],
                       [{ 'id' => 'a1', 'panel' => 'TOP', 'label' => 'United Widgets revenue',
                          'raw' => '12,345', 'sigma_element_hint' => 'Top Accounts' }])
  t0 = Time.now
  _out, err, st = run_stubbed(stub_dir,
                              { 'STUB_SPEC' => File.join(dir, 'stub-spec.json'),
                                'STUB_LOG' => File.join(dir, 'stub-log.jsonl') },
                              File.join(SCRIPTS, 'verify-anchors.rb'),
                              '--workdir', dir, '--workbook-id', 'wb',
                              '--row-limit', '100', '--timeout', '4', '--pool', '2')
  wall = Time.now - t0
  check(st.exitstatus == 4, "deadline expiry exits with the distinct timeout code 4 (got #{st.exitstatus})", fails)
  check(wall < 30, "total runtime bounded by --timeout (took #{wall.round(1)}s; used to hang 15+ min)", fails)
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  check(vd['export_status']['Slow Tile'] == 'timeout', "per-element status 'timeout' recorded", fails)
  check(vd['partial'] == true && vd['export_timed_out'] == ['Slow Tile'],
        'verdict marks the run partial and names the timed-out element', fails)
  check(vd['matched'] == 1, 'partial results recorded: the fast element\'s anchor still matched', fails)
  check(err.include?('[TIMEOUT]') && err.include?('"Slow Tile"'),
        'actionable timeout message names the timed-out element', fails)
end

# ============================================================================
# Part 3 — verify-anchors.rb: normal path unchanged (exit 0, progress printed)
# ============================================================================
puts '-- verify-anchors: normal bounded path (exit 0) --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  write_anchor_fixture(dir,
                       [{ 'id' => 'el-anchor', 'name' => 'Top Accounts', 'kind' => 'table' }],
                       [{ 'id' => 'a1', 'panel' => 'TOP', 'label' => 'United Widgets revenue',
                          'raw' => '12,345', 'sigma_element_hint' => 'Top Accounts' }])
  out, err, st = run_stubbed(stub_dir,
                             { 'STUB_SPEC' => File.join(dir, 'stub-spec.json'),
                               'STUB_LOG' => File.join(dir, 'stub-log.jsonl') },
                             File.join(SCRIPTS, 'verify-anchors.rb'),
                             '--workdir', dir, '--workbook-id', 'wb', '--timeout', '60')
  check(st.exitstatus.zero?, "all-matched live run still exits 0 (got #{st.exitstatus})", fails)
  check(out.include?('1/1'), 'summary reports 1/1 matched', fails)
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  check(vd['pass'] == true && vd['inconclusive'] == [] && vd['export_timed_out'] == [],
        'clean verdict: pass, no inconclusive, no timeouts', fails)
  check(err.include?('START') && err.include?('DONE'), 'pool is never silent — progress lines printed', fails)
end

# ============================================================================
# Part 4 — collect-parity-actuals.rb: truncated tile → too-large-for-export
# ============================================================================
puts '-- collect-parity-actuals: truncated tile fails LOUD, routed off the export path --'
COLLECT_SPEC = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-ok',   'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
  { 'id' => 'el-big',  'columns' => [{ 'id' => 'c-r2', 'name' => 'Region' }, { 'id' => 'c-v2', 'name' => 'Revenue' }] },
  { 'id' => 'el-slow', 'columns' => [{ 'id' => 'c-s', 'name' => 'Region' }] }
] }] }.freeze
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  plan_path = File.join(dir, 'parity-plan.json')
  spec_path = File.join(dir, 'wb-readback.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  File.write(plan_path, JSON.pretty_generate('charts' => [
    { 'chart' => 'OK Chart',       'sigma_kind' => 'bar-chart', 'sigma_element_id' => 'el-ok',  'sigma_columns' => %w[c-r c-v] },
    { 'chart' => 'Huge Table',     'sigma_kind' => 'table',     'sigma_element_id' => 'el-big', 'sigma_columns' => %w[c-r2 c-v2] },
    { 'chart' => 'Huge Preseeded', 'sigma_kind' => 'table',     'sigma_element_id' => 'el-big', 'sigma_columns' => %w[c-r2 c-v2] }
  ]))
  File.write(spec_path, JSON.pretty_generate(COLLECT_SPEC))
  File.write(out_path, JSON.pretty_generate('Huge Preseeded' => [['x', 1]])) # agent rows — never clobbered
  log = File.join(dir, 'stub-log.jsonl')
  out, _err, st = run_stubbed(stub_dir, { 'STUB_LOG' => log, 'STUB_BIG_ROWS' => '5' },
                              File.join(SCRIPTS, 'collect-parity-actuals.rb'),
                              '--plan', plan_path, '--workbook-id', 'wb', '--workbook-spec', spec_path,
                              '--out', out_path, '--row-limit', '5', '--timeout', '60')
  check(st.exitstatus.zero?, "too-large tiles do not fail the run (got #{st.exitstatus})", fails)
  actuals = JSON.parse(File.read(out_path))
  check(actuals['OK Chart'] == [['East', 100.0], ['West', 200.0]], 'healthy chart still collected as rows', fails)
  huge = actuals['Huge Table']
  check(huge.is_a?(Hash) && huge['status'] == 'too-large-for-export' && huge['reason'].to_s =~ /rowLimit 5/,
        "truncated tile marked 'too-large-for-export' (never compared over partial data)", fails)
  check(actuals['Huge Preseeded'] == [['x', 1]], 'pre-existing agent rows never clobbered by the marker', fails)
  check(out.include?('TOO LARGE FOR EXPORT (1)') && out.include?('Huge Table') &&
        out =~ /agent-mediated|warehouse/,
        'loud summary line routes the tile to the agent-mediated/warehouse path', fails)
  posted = File.readlines(log).map { |l| JSON.parse(l) }
  check(posted.all? { |p| p['rowLimit'] == 5 }, 'every export POST carries the rowLimit bound', fails)
end

# ============================================================================
# Part 5 — collect-parity-actuals.rb: total deadline expiry → exit 3, partial
# ============================================================================
puts '-- collect-parity-actuals: --timeout bounds TOTAL runtime (exit 3, partial) --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  plan_path = File.join(dir, 'parity-plan.json')
  spec_path = File.join(dir, 'wb-readback.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  File.write(plan_path, JSON.pretty_generate('charts' => [
    { 'chart' => 'OK Chart',   'sigma_kind' => 'bar-chart', 'sigma_element_id' => 'el-ok',   'sigma_columns' => %w[c-r c-v] },
    { 'chart' => 'Slow Chart', 'sigma_kind' => 'table',     'sigma_element_id' => 'el-slow', 'sigma_columns' => %w[c-s] }
  ]))
  File.write(spec_path, JSON.pretty_generate(COLLECT_SPEC))
  t0 = Time.now
  out, err, st = run_stubbed(stub_dir, { 'STUB_LOG' => File.join(dir, 'stub-log.jsonl') },
                             File.join(SCRIPTS, 'collect-parity-actuals.rb'),
                             '--plan', plan_path, '--workbook-id', 'wb', '--workbook-spec', spec_path,
                             '--out', out_path, '--timeout', '4', '--pool', '2')
  wall = Time.now - t0
  check(st.exitstatus == 3, "deadline expiry exits with the distinct code 3 (got #{st.exitstatus})", fails)
  check(wall < 30, "total runtime bounded by --timeout (took #{wall.round(1)}s)", fails)
  actuals = JSON.parse(File.read(out_path))
  check(actuals['OK Chart'].is_a?(Array), 'partial actuals written: fast chart collected', fails)
  check(actuals.dig('Slow Chart', 'status') == 'timeout',
        "timed-out chart carries a clean 'timeout' marker", fails)
  check(out.include?('TIMEOUT (1)') && out.include?('Slow Chart'),
        'summary names the timed-out chart with re-run guidance', fails)
  check(err.include?('START') && err.include?('"Slow Chart"'),
        'pool progress lines printed for the slow chart', fails)
end

# ============================================================================
# Part 6 — verify-parity.rb: new markers report PENDING, never DIVERGE
# ============================================================================
puts '-- verify-parity: too-large-for-export / timeout markers → PENDING --'
Dir.mktmpdir do |dir|
  plan_path = File.join(dir, 'plan.json')
  File.write(plan_path, JSON.pretty_generate([
    { 'chart' => 'Huge Table', 'expected' => [['East', 1]],
      'actual' => { 'status' => 'too-large-for-export', 'reason' => 'export truncated at rowLimit 5' } },
    { 'chart' => 'Slow Chart', 'expected' => [['East', 1]],
      'actual' => { 'status' => 'timeout', 'reason' => 'total --timeout deadline reached' } }
  ]))
  out, _err, _st = Open3.capture3(RbConfig.ruby, File.join(SCRIPTS, 'verify-parity.rb'), '--plan', plan_path)
  check(out.scan(/^PENDING/).length == 2 && !out.include?('DIVERGE'),
        'both markers report PENDING (never DIVERGE-against-empty)', fails)
  check(out.include?('(too-large-for-export)') && out.include?('(timeout)'),
        'PENDING lines name the marker kind', fails)
  check(out =~ /warehouse SQL oracle|AGGREGATE query/, 'too-large guidance points at the warehouse path', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — bounded exports (deadline + rowLimit + loud routing)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
