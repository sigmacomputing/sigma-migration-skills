#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the pivot-export render-verify fallback (§D4 known-
# platform-bug fallbacks). Live bugs: the element CSV export returns HTTP 500
# (control-driven pivots; totals.showGrandTotals:hidden) or an EMPTY/HTML body
# (large pivots) while the rendered values are CORRECT. The old behavior failed
# those charts, pushing agents into ad-hoc --min-pass-rate waivers (three
# different waiver styles in one run). New contract, end to end:
#
#   collect-parity-actuals.rb  export 5xx / empty / HTML → chart marked in the
#     actuals JSON as {"status":"render-verify-required","reason":...}, run
#     exits 0, ONE summary line lists the charts. Real rows never clobbered.
#   phase6-parity.rb --finalize  passes the marker through to the plan as-is.
#   verify-parity.rb  marker → PENDING (never DIVERGE); once the plan chart
#     carries "render_verified": true → PASS with a named note.
#   parity-final.json  carries pending_names / charts_pending_manual; status
#     stays FAIL (blocks GREEN) until every pending chart is resolved.
#   assert-phase6-ran.rb gate 1  failure message names the pending charts.
#
# The Sigma REST layer is stubbed per-element (el-500 / el-empty / el-html /
# el-ok); no network. Usage:  ruby scripts/test-parity-render-verify-fallback.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPTS = __dir__
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', SCRIPTS)
REASON = 'pivot CSV export 500/empty (known Sigma limitation)'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Stub sigma_rest: loaded FIRST (ruby -I <stub> -r sigma_rest); it then marks
# the real lib path as already-required so the script's own `require
# 'sigma_rest'` no-ops instead of overriding the stub.
STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if method == :post && path.include?('/export')
        eid = JSON.parse(body)['elementId']
        raise Error, "POST #{path} -> 500 Internal Server Error\n{}" if eid == 'el-500'
        return { 'queryId' => eid }
      end
      if method == :get && path.start_with?('/v2/query/')
        case path.split('/')[3]
        when 'el-ok'    then return "Region,Revenue\nEast,100\nWest,200\n"
        when 'el-empty' then return "Region,Revenue\n"
        when 'el-html'  then return "<html><body>export renderer error</body></html>"
        end
      end
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

ELEMENTS = [
  { 'id' => 'el-ok',    'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
  { 'id' => 'el-500',   'columns' => [{ 'id' => 'c-a', 'name' => 'A' }, { 'id' => 'c-b', 'name' => 'B' }] },
  { 'id' => 'el-empty', 'columns' => [{ 'id' => 'c-e', 'name' => 'E' }] },
  { 'id' => 'el-html',  'columns' => [{ 'id' => 'c-h', 'name' => 'H' }] },
  { 'id' => 'el-pivot', 'columns' => [{ 'id' => 'c-p', 'name' => 'P' }] }
].freeze
SPEC = {
  'document' => {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'p1', 'name' => 'Overview' }],
    'elements' => ELEMENTS,
    'layout' => "<Page id=\"p1\">#{ELEMENTS.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
  }
}.freeze

PLAN_CHARTS = [
  { 'chart' => 'OK Chart',        'sigma_kind' => 'bar-chart',   'sigma_element_id' => 'el-ok',      'sigma_columns' => %w[c-r c-v] },
  { 'chart' => 'Pivot 500',       'sigma_kind' => 'table',       'sigma_element_id' => 'el-500',     'sigma_columns' => %w[c-a c-b] },
  { 'chart' => 'Pivot Preseeded', 'sigma_kind' => 'table',       'sigma_element_id' => 'el-500',     'sigma_columns' => %w[c-a c-b] },
  { 'chart' => 'Pivot Empty',     'sigma_kind' => 'table',       'sigma_element_id' => 'el-empty',   'sigma_columns' => %w[c-e] },
  { 'chart' => 'Pivot HTML',      'sigma_kind' => 'table',       'sigma_element_id' => 'el-html',    'sigma_columns' => %w[c-h] },
  { 'chart' => 'Wide Pivot',      'sigma_kind' => 'pivot-table', 'sigma_element_id' => 'el-pivot',   'sigma_columns' => %w[c-p] },
  { 'chart' => 'Ghost',           'sigma_kind' => 'table',       'sigma_element_id' => 'el-missing', 'sigma_columns' => %w[c-x] }
].freeze

# ============================================================================
# Part 1 — collect-parity-actuals.rb classification + merge + summary line
# ============================================================================
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  plan_path = File.join(dir, 'parity-plan.json')
  spec_path = File.join(dir, 'wb-readback.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  File.write(plan_path, JSON.pretty_generate('charts' => PLAN_CHARTS))
  File.write(spec_path, JSON.pretty_generate(SPEC))
  # Pre-seeded agent rows for one export-500 chart — must NOT be clobbered.
  File.write(out_path, JSON.pretty_generate('Pivot Preseeded' => [['x', 1]]))

  out, err, st = Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid', 'SIGMA_API_TOKEN' => 'stub' },
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest',
    File.join(SCRIPTS, 'collect-parity-actuals.rb'),
    '--plan', plan_path, '--workbook-id', 'wb', '--workbook-spec', spec_path, '--out', out_path)

  check(st.success?, "collect exits 0 despite 500/empty/HTML exports (got #{st.exitstatus}: #{err.lines.first})", fails)
  actuals = JSON.parse(File.read(out_path))
  check(actuals['OK Chart'] == [['East', 100.0], ['West', 200.0]], 'healthy chart still collected as rows', fails)
  %w[500 Empty HTML].each do |k|
    m = actuals["Pivot #{k}"]
    check(m == { 'status' => 'render-verify-required', 'reason' => REASON },
          "Pivot #{k} → render-verify marker with the known-limitation reason", fails)
  end
  check(actuals['Pivot Preseeded'] == [['x', 1]], 'pre-existing agent rows never clobbered by a marker', fails)
  check(!actuals.key?('Wide Pivot'), 'pivot-table stays agent-mediated (skip, no marker)', fails)
  check(!actuals.key?('Ghost'), 'unknown element stays NOT COLLECTED (fail, no marker)', fails)

  rv_lines = out.lines.grep(/RENDER-VERIFY REQUIRED/)
  check(rv_lines.size == 1, "exactly ONE render-verify summary line (got #{rv_lines.size})", fails)
  check(rv_lines.first.to_s.include?('(3)') &&
        %w[500 Empty HTML].all? { |k| rv_lines.first.include?("Pivot #{k}") } &&
        !rv_lines.first.to_s.include?('Preseeded'),
        'summary line lists exactly the marked charts', fails)
  check(rv_lines.first.to_s.include?('render-read or direct SQL'),
        'summary line tells the agent HOW to verify', fails)
  check(out.include?('AGENT-MEDIATED  Wide Pivot'), 'pivot skip line preserved', fails)
  check(out.include?('NOT COLLECTED   Ghost'), 'genuine failure line preserved', fails)
end

# ============================================================================
# Part 2 — verify-parity.rb: PENDING (never DIVERGE) → render_verified PASS
# ============================================================================
VERIFY = File.join(SCRIPTS, 'verify-parity.rb')
Dir.mktmpdir do |dir|
  plan_path = File.join(dir, 'plan.json')
  base_plan = [
    { 'chart' => 'Healthy', 'expected' => [['East', 100]], 'actual' => { 'rows' => [['East', 100]] } },
    { 'chart' => 'Pivot 500', 'expected' => [['East', 1]],
      'actual' => { 'status' => 'render-verify-required', 'reason' => REASON } }
  ]
  File.write(plan_path, JSON.pretty_generate(base_plan))
  out, _err, st = Open3.capture3(RbConfig.ruby, VERIFY, '--plan', plan_path)
  check(!st.success?, 'unresolved marker keeps verify-parity failing (blocks GREEN)', fails)
  check(out.match?(/^PENDING\s+\[strict\]\s+Pivot 500\s+\(render-verify-required\)$/),
        "marker chart reports PENDING, not DIVERGE (got: #{out.lines.grep(/Pivot 500/).first.to_s.strip})", fails)
  check(out.lines.grep(/^DIVERGE/).empty?, 'no DIVERGE line for the marker chart', fails)
  check(out.include?('render-read or direct SQL'), 'PENDING note says how to resolve', fails)
  check(out.include?('1 pending render-verify'), 'summary counts the pending tile', fails)
  check(out.include?('value-parity score: 100.0%'), 'pending tile excluded from the score mean (not zeroed)', fails)

  # resolve via render_verified:true → PASS with a named note
  resolved = JSON.parse(JSON.generate(base_plan))
  resolved[1]['render_verified'] = true
  resolved[1]['render_verified_notes'] = '35 cells exact vs SQL oracle'
  File.write(plan_path, JSON.pretty_generate(resolved))
  out, _err, st = Open3.capture3(RbConfig.ruby, VERIFY, '--plan', plan_path)
  check(st.success?, 'render_verified:true → verify-parity passes', fails)
  check(out.match?(/^PASS\s+\[strict\]\s+Pivot 500/), 'resolved marker chart reports PASS', fails)
  check(out.include?('render-verified:') && out.include?('35 cells exact vs SQL oracle'),
        'PASS carries the named render-verified note', fails)

  # score-out: pending tiles carry score:null, never a fake 0
  File.write(plan_path, JSON.pretty_generate(base_plan))
  score_path = File.join(dir, 'score.json')
  Open3.capture3(RbConfig.ruby, VERIFY, '--plan', plan_path, '--score-out', score_path)
  tiles = JSON.parse(File.read(score_path))['tiles']
  pend = tiles.find { |t| t['chart'] == 'Pivot 500' }
  check(pend['status'] == 'PENDING' && pend['score'].nil?, 'score-out records PENDING with score:null', fails)
end

# ============================================================================
# Part 3 — phase6-parity.rb --finalize threads the marker through to
# parity-final.json (pending_names) and assert-phase6-ran names the pendings
# ============================================================================
PHASE6 = File.join(SCRIPTS, 'phase6-parity.rb')
GATE   = File.join(SCRIPTS, 'assert-phase6-ran.rb')
Dir.mktmpdir do |dir|
  plan = { 'charts' => [
    { 'chart' => 'Healthy', 'expected' => [['East', 100]], 'sigma_columns' => %w[c-r c-v] },
    { 'chart' => 'Pivot 500', 'expected' => [['East', 1]], 'sigma_columns' => %w[c-a c-b] }
  ] }
  File.write(File.join(dir, 'parity-plan.json'), JSON.pretty_generate(plan))
  File.write(File.join(dir, 'parity-actuals.json'), JSON.pretty_generate(
    'Healthy'   => [['East', 100]],
    'Pivot 500' => { 'status' => 'render-verify-required', 'reason' => REASON }))

  env = { 'SIGMA_BASE_URL' => 'https://stub.invalid', 'SIGMA_API_TOKEN' => 'stub' }
  _out, err, st = Open3.capture3(env, RbConfig.ruby, PHASE6, '--tableau', dir, '--finalize',
                                 '--actuals', File.join(dir, 'parity-actuals.json'))
  check(st.exitstatus == 2, "finalize with an unresolved marker exits 2 (got #{st.exitstatus})", fails)
  final = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(final['status'] == 'FAIL', 'parity-final status stays FAIL while pending (blocks GREEN)', fails)
  check(final['charts_pass'] == 1 && final['fail_names'] == [],
        'pending chart is NOT counted as a divergence', fails)
  check(final['charts_pending_manual'] == 1 && final['pending_names'] == ['Pivot 500'],
        'parity-final names the pending render-verify chart', fails)
  check(err.include?('pending render-verify'), 'finalize prints the resolution instructions', fails)
  injected = JSON.parse(File.read(File.join(dir, 'parity-plan.json')))
  check(injected['charts'][1]['actual'] == { 'status' => 'render-verify-required', 'reason' => REASON },
        'finalize passes the marker through to the plan as-is (no bogus rows wrapper)', fails)

  # gate 1 failure names the pendings with the fix
  _out, gerr, gst = Open3.capture3({ 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil },
                                   RbConfig.ruby, GATE, '--workdir', dir)
  check(gst.exitstatus == 2, 'assert-phase6-ran fails gate 1 on the pending run', fails)
  check(gerr.include?('Pending render-verify') && gerr.include?('Pivot 500') && gerr.include?('render_verified'),
        'gate 1 failure names the pending charts + the render_verified fix', fails)

  # resolve → finalize passes
  resolved = JSON.parse(File.read(File.join(dir, 'parity-plan.json')))
  resolved['charts'][1]['render_verified'] = true
  File.write(File.join(dir, 'parity-plan.json'), JSON.pretty_generate(resolved))
  _out, _err2, st = Open3.capture3(env, RbConfig.ruby, PHASE6, '--tableau', dir, '--finalize',
                                   '--actuals', File.join(dir, 'parity-actuals.json'))
  check(st.success?, 'finalize passes once the chart is render_verified', fails)
  final = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(final['status'] == 'PASS' && final['charts_pass'] == 2 && !final.key?('pending_names'),
        'resolved run: status PASS, no pending names', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — pivot-export render-verify fallback (collect → verify → finalize → gate)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
