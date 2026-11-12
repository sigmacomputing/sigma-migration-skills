#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for the --finalize PREFLIGHT (lib/finalize_preflight.rb):
#   * the prerequisite list builder (analyze/resolve) with a fake runner;
#   * a preflight stop in migrate-tableau.rb --finalize exits 29 and writes NO
#     loop-log.jsonl (so it can never consume an Offramp attempt).
# Usage: ruby scripts/test-finalize-preflight.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'fileutils'
require_relative 'lib/finalize_preflight'
require_relative 'lib/evidence_inputs'

$fails = 0
def ok(cond, msg)
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
  $fails += 1 unless cond
end
def w(dir, name, obj)
  File.write(File.join(dir, name), obj.is_a?(String) ? obj : JSON.generate(obj))
end
FP = FinalizePreflight

puts '— analyze(): list builder —'
Dir.mktmpdir do |d|
  items = FP.analyze(d)
  ok(items.map { |i| i[:id] } == %w[parity-plan anchors-transcribe], "empty workdir → parity-plan + anchors-transcribe (got #{items.map { |i| i[:id] }})")
  ok(items.none? { |i| i[:auto] }, 'neither item is auto-runnable')
end
Dir.mktmpdir do |d|
  w(d, 'parity-plan.json', { 'charts' => [{ 'chart' => 'T1' }] })
  w(d, 'source-anchors.json', { 'anchors' => [{ 'id' => 'a1', 'raw' => '1' }] * 5 })
  w(d, 'join-plan.json', { 'entries' => [{ 'status' => 'unprobed', 'kind' => 'lookup' }] })
  w(d, 'calc-fields.json', [{ 'formula' => '{FIXED [A] : SUM([B])}' }])
  w(d, 'x.twb', '<workbook/>')
  w(d, 'dm-spec.json', '{"source":{"connectionId":"conn-9"}}')
  items = FP.analyze(d, actuals: '/a.json', wb_id: 'wb1')
  ids = items.map { |i| i[:id] }
  ok(ids == %w[join-probe lod-audit anchors-verdict gt-derive gt-run gt-verify], "ordered chain (got #{ids})")
  ok(items.all? { |i| i[:auto] }, 'all auto when a connection id is known from dm-spec.json')
  ok(items.find { |i| i[:id] == 'join-probe' }[:cmd].include?('conn-9'), 'connection id resolved from dm-spec.json')
  ok(items.find { |i| i[:id] == 'gt-verify' }[:cmd].include?('/a.json'), 'verify gets --sigma-actuals')
  File.delete(File.join(d, 'dm-spec.json'))
  nc = FP.analyze(d)
  ok(!nc.find { |i| i[:id] == 'join-probe' }[:auto] && !nc.find { |i| i[:id] == 'gt-run' }[:auto], 'no connection id → probe/run are manual')
  ok(FP.analyze(d, tier: 'S').none? { |i| i[:id].start_with?('gt-') }, 'Tier-S skips the ground-truth trio')
end

puts '— stale parity actuals (Stress 4: first finalize used actuals from before the RCF patches) —'
Dir.mktmpdir do |d|
  act = File.join(d, 'parity-actuals.json')
  w(d, 'parity-plan.json', { 'charts' => [{ 'chart' => 'T1' }] })
  w(d, 'parity-actuals.json', { 'T1' => [[1]] })
  w(d, 'wb-spec.json', { 'elements' => [] })
  w(d, 'wb-readback.json', { 'elements' => [{ 'id' => 'stale' }] })
  File.utime(Time.now - 600, Time.now - 600, act)
  File.utime(Time.now - 900, Time.now - 900, File.join(d, 'parity-plan.json'))
  it = FP.check_actuals(d, act, 'wb1')
  ok(it && it[:id] == 'parity-actuals' && it[:auto], 'actuals older than wb-spec.json → auto re-collect item')
  ok(it && it[:cmd].include?('scripts/collect-parity-actuals.rb') && it[:cmd].include?(act) && it[:cmd].include?('wb1'),
     're-collect command targets the same actuals file + workbook')
  spec_arg = it[:cmd][it[:cmd].index('--workbook-spec') + 1]
  ok(spec_arg == File.join(d, 'wb-spec.json'), 're-collect maps the patched live workbook with wb-spec.json, not the stale readback')
  ok(it && it[:why].include?('wb-spec.json'), 'names the newer input')
  ok(FP.analyze(d, actuals: act, wb_id: 'wb1').map { |i| i[:id] }.include?('parity-actuals'), 'analyze lists it')
  ok(!FP.check_actuals(d, act, nil)[:auto], 'no workbook id → manual')
  File.utime(Time.now, Time.now, act)
  ok(FP.check_actuals(d, act, 'wb1').nil?, 'fresh actuals → nothing to do')
  ok(FP.check_actuals(d, File.join(d, 'none.json'), 'wb1').nil?, 'missing actuals file is not this check')
end

puts '— repair re-entry (2026-11-03: an RCF patch archived the actuals; "run pass 1" reverted the fix) —'
Dir.mktmpdir do |d|
  act = File.join(d, 'parity-actuals.json')
  archive = File.join(d, 'repair-checkpoints', '0123456789abcdef0123456789abcdef', 'prior-evidence')
  FileUtils.mkdir_p(archive)
  w(archive, 'parity-actuals.json', { 'T1' => [[1]] })
  w(archive, 'parity-plan.json', { 'charts' => [{ 'chart' => 'T1' }] })
  w(d, 'wb-spec.json', { 'elements' => [] })
  plan_it = FP.check_parity_plan(d, 'wb1')
  ok(plan_it && plan_it[:cmd].each_cons(2).include?(['--workbook-id', 'wb1']),
     'plan archived by a repair → phase6-parity pass 1 command carries the workbook id')
  ok(plan_it && plan_it[:why].include?('repair') && plan_it[:why].match?(/do NOT re-run migrate-tableau\.rb pass 1/i),
     'plan item names the repair and warns off the orchestrator pass 1 (it reverts RCF fixes)')
  w(d, 'parity-plan.json', { 'charts' => [{ 'chart' => 'T1' }] })
  it = FP.check_actuals(d, act, 'wb1')
  ok(it && it[:id] == 'parity-actuals' && it[:auto], 'actuals archived by a repair → auto re-collect item')
  ok(it && it[:cmd].include?('scripts/collect-parity-actuals.rb') && it[:cmd].include?(act),
     're-collect command writes the expected actuals file')
  ok(it && it[:why].include?('prior-evidence') && it[:why].match?(/do NOT re-run migrate-tableau\.rb pass 1/i),
     'actuals item names the archive and warns off the orchestrator pass 1')
  ok(FP.analyze(d, actuals: act, wb_id: 'wb1').map { |i| i[:id] }.include?('parity-actuals'), 'analyze lists it')
end

puts '— resolve(): auto-run + residual manual list —'
Dir.mktmpdir do |d|
  w(d, 'parity-plan.json', { 'charts' => [] })
  w(d, 'x.twb', '<workbook/>')
  w(d, 'source-anchors.json', { 'anchors' => [{ 'id' => 'a' }] })
  w(d, 'join-plan.json', { 'entries' => [{ 'status' => 'non-unique' }] })
  calls = []
  runner = lambda do |cmd|
    calls << File.basename(cmd[1])
    case File.basename(cmd[1])
    when 'verify-anchors.rb' then w(d, 'anchors-verdict.json', { 'pass' => true, 'checked' => 1 })
    when 'derive-ground-truth.rb' then w(d, 'ground-truth-plan.json', { 'generated_at' => 'T0', 'entries' => [] })
    when 'run-ground-truth.rb' then w(d, 'ground-truth-actuals.json', { 'plan_generated_at' => 'T0' })
    when 'verify-ground-truth.rb'
      # the real script stamps the digest of its inputs (lib/evidence_inputs.rb)
      w(d, 'numeric-parity.json', { 'plan_generated_at' => 'T0', 'tiles' => {}, 'inputs' => EvidenceInputs.gt_fingerprint(d) })
    end
    [true, 'ok']
  end
  r = FP.resolve(d, runner: runner, conn_id: 'c1', wb_id: 'wb1')
  ok(calls == %w[verify-anchors.rb derive-ground-truth.rb run-ground-truth.rb verify-ground-truth.rb], "auto steps ran once, in order (#{calls})")
  ok(r[:missing].map { |i| i[:id] } == ['join-resolve'], "only the decision-needing item remains (got #{r[:missing].map { |i| i[:id] }})")
  ok(FP.render_missing(r[:missing]).first.include?('--resolve 0'), 'rendered list carries the exact --resolve command')
  r2 = FP.resolve(d, runner: ->(_c) { raise 'nothing should re-run' }, conn_id: 'c1', wb_id: 'wb1')
  ok(r2[:ran].empty?, 'second pass: artifacts fresh → nothing re-runs')
end
Dir.mktmpdir do |d|
  w(d, 'parity-plan.json', {})
  w(d, 'source-anchors.json', { 'anchors' => [{ 'id' => 'a' }] })
  r = FP.resolve(d, runner: ->(_c) { [false, 'boom'] }, wb_id: 'wb1')
  m = r[:missing].find { |i| i[:id] == 'anchors-verdict' }
  ok(m && !m[:auto] && m[:why].include?('did not clear it') && m[:why].include?('boom'), 'failed auto step is demoted to a manual item with its output tail')
end
Dir.mktmpdir do |d|
  w(d, 'parity-plan.json', {})
  w(d, 'source-anchors.json', { 'anchors' => [{ 'id' => 'a' }] })
  w(d, 'anchors-verdict.json', { 'pass' => false, 'checked' => 1 })
  r = FP.resolve(d, runner: ->(_c) { raise 'failing verdict should not re-run' }, wb_id: 'wb1')
  ok(r[:ran].empty? && r[:missing].empty?, 'fresh failing anchors verdict proceeds to the final gate')
end

puts '— migrate-tableau.rb --finalize: preflight stop is not an attempt —'
Dir.mktmpdir do |d|
  w(d, 'migrate-state.json', { 'workbook_id' => 'wb1' })
  w(d, 'source-anchors.json', { 'anchors' => [] })
  env = { 'SIGMA_ALLOW_STALE' => 'test', 'SIGMA_SKIP_DOCTOR_GATE' => 'test', 'SIGMA_SKIP_CRED_GATE' => 'test',
          'SIGMA_BASE_URL' => 'https://x.invalid', 'SIGMA_API_TOKEN' => 't' }
  cmd = [RbConfig.ruby, File.join(__dir__, 'migrate-tableau.rb'), '--workbook-id', 'wbx', '--out', d,
         '--finalize', '--actuals', File.join(d, 'a.json')]
  2.times do |n|
    out, st = Open3.capture2e(env, *cmd)
    ok(st.exitstatus == FP::EXIT_PREFLIGHT_STOP, "run #{n + 1}: exit #{FP::EXIT_PREFLIGHT_STOP} (got #{st.exitstatus})")
    ok(out.include?('FINALIZE PREFLIGHT STOP') && out.include?('parity-plan.json missing'), "run #{n + 1}: prints the ordered missing list")
    ok(!File.exist?(File.join(d, 'loop-log.jsonl')), "run #{n + 1}: loop-log.jsonl not written (no attempt consumed)")
  end
end

puts $fails.zero? ? 'ALL PASS' : "#{$fails} FAILED"
exit($fails.zero? ? 0 : 1)
