#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for the PLAN-v3 PR-3 estimate-cost wiring:
#   1. workdir mode over a minimal signals fixture → cost-estimate.json with
#      scope (tiles, calc classes, untranslatable gap classes), a rough-marked
#      estimate, and a per-phase breakdown;
#   2. missing gap scan → the estimator DEGRADES gracefully and NAMES the
#      missing input (never crashes, still writes the artifact);
#   3. fully-empty workdir → still degrades, every input named missing;
#   4. run-state ack recording (RunState.record): the sign-off fields land in
#      run-state.json, merge with phase stamps, and survive re-stamps;
#   5. orchestrator seam (source-order assertions on migrate-tableau.rb): the
#      estimator runs AFTER the gap-scan join and BEFORE the Phase 3 DM build,
#      prints a sign-off block, records both provenance modes, and the missing
#      ack is WARN-only at Phase 3 (no hard gate this release);
#   6. legacy pre-scoping mode (--workbook) still works.
# Deterministic, no network. Usage: ruby scripts/test-estimate-cost.rb

require 'json'
require 'tmpdir'
require_relative 'lib/run_state'

DIR      = __dir__
ESTIMATE = File.join(DIR, 'estimate-cost.rb')
MIGRATE  = File.join(DIR, 'migrate-tableau.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def write_fixture(dir, with_gaps: true)
  File.write(File.join(dir, 'get-workbook.json'), JSON.generate(
    'workbook' => { 'name' => 'Fixture WB', 'id' => 'luid-1',
                    'views' => { 'view' => [
                      { 'name' => 'Dash', 'sheetType' => 'dashboard' },
                      { 'name' => 'S1', 'sheetType' => 'worksheet' },
                      { 'name' => 'S2', 'sheetType' => 'worksheet' }
                    ] } }))
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate(
    [{ 'dashboard' => 'Dash', 'zones' => [
      { 'kind' => 'chart', 'chart_kind' => 'bar' },
      { 'kind' => 'chart', 'chart_kind' => 'line' },
      { 'kind' => 'chart', 'chart_kind' => 'kpi' },
      { 'kind' => 'text' }
    ] }]))
  File.write(File.join(dir, 'calc-fields.json'), JSON.generate(
    'calcs' => [
      { 'name' => 'Simple', 'formula' => '[Sales] * 2' },
      { 'name' => 'Lod', 'formula' => '{ FIXED [Region] : SUM([Sales]) }', 'is_lod' => true },
      { 'name' => 'Residue', 'formula' => 'WINDOW_MEDIAN(SUM([Sales]))', 'requires_custom_sql' => true }
    ]))
  File.write(File.join(dir, 'custom-sql.json'), JSON.generate([]))
  return unless with_gaps
  File.write(File.join(dir, 'wb-gaps-report.json'), JSON.generate(
    'detected_features' => [
      { 'name' => 'Quick filters', 'status' => 'auto', 'count' => 3 },
      { 'name' => 'LOD (FIXED)', 'status' => 'auto', 'count' => 1 },
      { 'name' => 'Data blending', 'status' => 'unhandled', 'count' => 1 }
    ]))
end

puts '— workdir mode: minimal signals fixture —'
base_turns = nil
Dir.mktmpdir do |d|
  write_fixture(d)
  out = IO.popen(['ruby', ESTIMATE, '--workdir', d], err: %i[child out], &:read); st = $?.exitstatus
  ce_path = File.join(d, 'cost-estimate.json')
  check(st == 0, "estimator exits 0 (got #{st}: #{out.lines.first})", fails)
  check(File.exist?(ce_path), 'writes <workdir>/cost-estimate.json by default', fails)
  ce = JSON.parse(File.read(ce_path))
  check(ce['confidence'] == 'rough', "estimate marked confidence: rough (got #{ce['confidence'].inspect})", fails)
  check(ce['workbook'] == 'Fixture WB', 'workbook name from get-workbook.json', fails)
  scope = ce['scope'] || {}
  check(scope['tiles'] == 3, "tile count from dashboard-layout chart zones (got #{scope['tiles'].inspect})", fails)
  calcs = scope['calcs'] || {}
  check(calcs['total'] == 3 && calcs['simple'] == 1 && calcs['complex'] == 1 &&
        calcs['requires_custom_sql'] == 1,
        "calc count by class 1/1/1 (got #{calcs.inspect})", fails)
  check(scope['gap_classes'] == { 'auto' => 2, 'unhandled' => 1 },
        "gap classes from the gap scan (got #{scope['gap_classes'].inspect})", fails)
  check(scope['untranslatable_classes'] == ['Data blending'],
        "untranslatable classes = the ❌-unhandled rows (got #{scope['untranslatable_classes'].inspect})", fails)
  est = ce['estimate'] || {}
  base_turns = est['agent_turns']
  check(est['agent_turns'].to_i.positive? && est['input_tokens'].to_i.positive? &&
        est['output_tokens'].to_i.positive? &&
        est['total_tokens'] == est['input_tokens'] + est['output_tokens'],
        'estimate has positive turn/input/output token counts that sum', fails)
  check((est['per_phase'] || {}).size >= 4 &&
        est['per_phase'].values.all? { |p| p['input_tokens'].to_i.positive? },
        'per-phase breakdown present with per-phase token counts', fails)
  check((ce.dig('inputs', 'missing') || []).empty?, 'complete fixture → no missing inputs', fails)
  check(ce.dig('calibration', 'tokens_per_turn', 'input').to_i.positive?,
        'calibration block states the tokens-per-turn assumption', fails)
end

puts '— workdir mode: missing gap scan degrades gracefully —'
Dir.mktmpdir do |d|
  write_fixture(d, with_gaps: false)
  out = IO.popen(['ruby', ESTIMATE, '--workdir', d], err: %i[child out], &:read); st = $?.exitstatus
  ce = JSON.parse(File.read(File.join(d, 'cost-estimate.json'))) rescue nil
  check(st == 0 && ce, "no gap scan → still exits 0 and writes the artifact (got #{st})", fails)
  missing = (ce && ce.dig('inputs', 'missing') || []).map { |m| m['artifact'] }
  check(missing.any? { |a| a.include?('gaps') },
        "missing gap scan is NAMED in inputs.missing (got #{missing.inspect})", fails)
  check(out.include?('degraded') && out.include?('gaps'),
        'stdout names the degraded input', fails)
  check(ce && ce['scope'] && !ce['scope'].key?('gap_classes'),
        'no fabricated gap classes when the scan is absent', fails)
  # The unhandled-class penalty (+25 turns/class) must apply only when the gap
  # scan actually reported an unhandled class.
  check(base_turns && ce && base_turns - ce['estimate']['agent_turns'] >= 20,
        "unhandled gap class carries the heavy-failure turn penalty (#{base_turns} vs #{ce && ce['estimate']['agent_turns']})", fails)
end

puts '— workdir mode: empty workdir (fully degraded) —'
Dir.mktmpdir do |d|
  out = IO.popen(['ruby', ESTIMATE, '--workdir', d], err: %i[child out], &:read); st = $?.exitstatus
  ce = JSON.parse(File.read(File.join(d, 'cost-estimate.json'))) rescue nil
  check(st == 0 && ce, "empty workdir → still exits 0 with an artifact (got #{st})", fails)
  missing = (ce && ce.dig('inputs', 'missing') || []).map { |m| m['artifact'] }
  %w[get-workbook.json dashboard-layout.json calc-fields.json custom-sql.json].each do |a|
    check(missing.include?(a), "missing input named: #{a}", fails)
  end
  check(missing.any? { |a| a.include?('gaps') }, 'missing input named: gap scan', fails)
end

puts '— run-state ack recording (RunState.record) —'
Dir.mktmpdir do |d|
  RunState.record(d, 'cost_estimate_acknowledged' => true,
                     'cost_estimate_provenance'   => 'auto-yes')
  doc = JSON.parse(File.read(RunState.path(d)))
  check(doc['cost_estimate_acknowledged'] == true, 'run-state records cost_estimate_acknowledged: true', fails)
  check(doc['cost_estimate_provenance'] == 'auto-yes', 'run-state records provenance auto-yes', fails)
  # The ack must MERGE with phase stamps, in both orders.
  RunState.stamp(d, 'phase-1', note: 'discover')
  doc = JSON.parse(File.read(RunState.path(d)))
  check(doc['cost_estimate_acknowledged'] == true && doc['phases'].key?('phase-1'),
        'phase stamp after the ack preserves the ack (merge)', fails)
  RunState.record(d, 'cost_estimate_provenance' => 'stated')
  doc = JSON.parse(File.read(RunState.path(d)))
  check(doc['cost_estimate_provenance'] == 'stated' && doc['phases'].key?('phase-1'),
        're-record updates provenance without dropping phases', fails)
  check(RunState.load(d)['cost_estimate_acknowledged'] == true,
        'RunState.load surfaces the ack (the Phase 3 WARN check reads this)', fails)
  # Best-effort contract: a bogus workdir must never raise.
  check(RunState.record('/nonexistent-workdir-xyz', 'k' => 1).nil?,
        'record on a missing workdir is a safe no-op', fails)
end

puts '— orchestrator seam (source-order assertions on migrate-tableau.rb) —'
src = File.read(MIGRATE)
i_join  = src.index("mark('phase1-join')")
i_est   = src.index("estimate-cost.rb'")
i_block = src.index('SCOPE / COST SIGN-OFF')
i_dec   = src.index('DECISIONS CHECKPOINT')
i_dm    = src.index("hdr(3, 'Build data model')")
check(!i_est.nil? && !i_join.nil? && i_est > i_join,
      'estimator runs AFTER the phase-1 join (gap-scan artifacts exist)', fails)
check(!i_block.nil? && !i_dec.nil? && i_est < i_block && i_block < i_dec,
      'sign-off block prints before the decisions checkpoint', fails)
check(!i_dm.nil? && i_block < i_dm, 'sign-off happens BEFORE the Phase 3 DM build', fails)
check(src.include?("'--workdir', WORK, '--out', cost_est_path"),
      'estimator is invoked in workdir mode writing <workdir>/cost-estimate.json', fails)
check(src.include?("allow_fail: true)\ncost_est = ") || src[i_est - 200, 400].include?('allow_fail'),
      'estimator invocation is allow_fail (a scoping estimate never blocks)', fails)
check(src.include?("'auto-yes'") && src.include?("'stated'"),
      'both ack provenance modes present (auto-yes for --yes/--answers, stated interactive)', fails)
check(src.include?("RunState.record(WORK, 'cost_estimate_acknowledged' => true"),
      'ack recorded via RunState.record into run-state.json', fails)
i_warn = src.index('cost_estimate_acknowledged missing')
check(!i_warn.nil? && i_warn > i_dm && src[i_warn - 600, 700].include?('WARN-only'),
      'missing ack at the DM build is a WARN, not a hard gate (first release)', fails)
check(src.scan('cost_estimate_acknowledged').size >= 2,
      'Phase 3 checks the run-state ack', fails)

puts '— legacy pre-scoping mode (--workbook) —'
Dir.mktmpdir do |d|
  wb = File.join(d, 'get-workbook.json')
  File.write(wb, JSON.generate(
    'workbook' => { 'name' => 'Legacy WB', 'views' => { 'view' => [
      { 'sheetType' => 'dashboard' }, { 'sheetType' => 'worksheet' }, { 'sheetType' => 'worksheet' }
    ] } }))
  out = IO.popen(['ruby', ESTIMATE, '--workbook', wb], err: %i[child out], &:read); st = $?.exitstatus
  ce = JSON.parse(out) rescue nil
  check(st == 0 && ce && ce['workbook'] == 'Legacy WB' && ce['confidence'] == 'rough',
        "legacy --workbook mode emits a rough estimate to stdout (got #{st})", fails)
  check(ce && ce['scope'] && ce['scope']['tiles'] == 2 && ce['scope']['tiles_proxied_from'],
        'legacy mode proxies tiles from the sheet count and says so', fails)
end

puts
if fails.empty?
  puts "OK — all checks passed"
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
