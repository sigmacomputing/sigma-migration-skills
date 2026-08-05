#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-estimate-cost-refit.rb — W2.22: the measured calibration loop.
#
#   1. standalone --from-metrics over 3 turn-capturing runs → MEASURED fit
#      (median rate), per-tier band published as {n, range, rate};
#   2. combined --workdir + --from-metrics → the estimate uses the fitted
#      rate, the report carries a measured provenance block, and stdout leads
#      with the provenance header;
#   3. low-n (2 runs) → refit REFUSED BY NAME, priors retained, band refused
#      ("a single flattering minute is not a band");
#   4. pre-turn-capture runs (wave-1 files, no `turn` keys) → wall band still
#      publishable at n>=3, rate refused (nil ≠ 0 — never derived);
#   5. bad workdirs are named errors, usable runs still fit (degrade, no crash);
#   6. NO-FALSE-TRIP: without --from-metrics the artifact keeps priors
#      behavior (confidence rough, priors provenance, priors minutes);
#   7. hygiene: the standalone report contains NO workdir paths.
#
# Deterministic, no network. Usage: ruby scripts/test-estimate-cost-refit.rb

require 'json'
require 'tmpdir'

DIR      = __dir__
ESTIMATE = File.join(DIR, 'estimate-cost.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# One measured-run workdir: `turns` mark events of wall_s each (turn capture
# + invocation token), plus migrate-state.json carrying the tier.
def write_run(dir, turns:, wall_s_each:, tier: 'S', invs: 1, with_turn_keys: true, tokens_each: nil)
  phases = %w[phase1-lane(bg) phase1-foreground phase2-columns phase3-dm
              phase4-workbook phase5-layout phase6-pass1 phase6-finalize]
  t0 = Time.utc(2026, 7, 1, 12, 0, 0)
  File.open(File.join(dir, 'phase-metrics.jsonl'), 'w') do |f|
    turns.times do |i|
      rec = { 'phase' => phases[i % phases.size], 'wall_s' => wall_s_each.to_f,
              'at' => (t0 + (i * wall_s_each)).strftime('%Y-%m-%dT%H:%M:%SZ') }
      if with_turn_keys
        rec['turn'] = (i % (turns / invs)) + 1
        rec['inv']  = "100#{i / (turns / invs)}-1753000000000"
      end
      rec['tokens'] = tokens_each if tokens_each
      f.puts(JSON.generate(rec))
    end
  end
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate('tier' => tier))
end

def scope_fixture(dir)
  File.write(File.join(dir, 'get-workbook.json'), JSON.generate(
    'workbook' => { 'name' => 'Fixture WB', 'views' => { 'view' => [
      { 'sheetType' => 'dashboard' }, { 'sheetType' => 'worksheet' }
    ] } }))
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate(
    [{ 'zones' => [{ 'kind' => 'chart' }, { 'kind' => 'chart' }] }]))
end

puts '— 1. standalone refit: 3 runs → measured fit + published tier band —'
Dir.mktmpdir do |top|
  dirs = [
    { turns: 20, wall_s_each: 30.0 },  # 10 min → 0.50 min/turn
    { turns: 20, wall_s_each: 36.0 },  # 12 min → 0.60
    { turns: 20, wall_s_each: 54.0 }   # 18 min → 0.90
  ].each_with_index.map do |cfg, i|
    d = File.join(top, "r#{i}")
    Dir.mkdir(d)
    write_run(d, tokens_each: 9_000, **cfg)
    d
  end
  out = IO.popen(['ruby', ESTIMATE, '--from-metrics', dirs.join(',')], err: %i[child out], &:read)
  st = $?.exitstatus
  check(st.zero?, "standalone refit exits 0 (got #{st})", fails)
  doc = JSON.parse(out[out.index('{')..-1]) rescue nil
  check(doc && doc['kind'] == 'calibration-refit', 'emits the calibration-refit document', fails)
  mpt = doc && doc.dig('fit', 'minutes_per_turn')
  check(mpt && mpt['source'] == 'measured' && mpt['value'] == 0.6 && mpt['n'] == 3,
        "minutes_per_turn measured median 0.6 n=3 (got #{mpt.inspect})", fails)
  check(out.include?('coefficients: MEASURED'), 'stdout leads with the measured provenance header', fails)
  band = doc && doc.dig('bands', 'S')
  check(band && band['n'] == 3 && band.dig('wall_minutes', 'median') == 12.0 &&
        band.dig('wall_minutes', 'min') == 10.0 && band.dig('wall_minutes', 'max') == 18.0,
        "tier-S band published n=3 wall 10–18 median 12 (got #{band.inspect})", fails)
  check(band && band.dig('turns', 'median') == 20,
        'band states measured turns (median 20)', fails)
  check(doc && doc['publication_rule'].to_s.include?('never a single run'),
        'publication rule stated in the artifact', fails)
  tok = doc && doc.dig('fit', 'tokens_per_turn_total')
  check(tok && tok['source'] == 'measured' && tok['value'] == 9_000,
        'measured token total per turn reported as INFO (in/out split stays stated)', fails)
  check(!out.include?(top), 'hygiene: no workdir paths anywhere in the report/stdout', fails)

  puts '— 2. combined --workdir + --from-metrics: fitted rate drives the estimate —'
  wd = File.join(top, 'wd')
  Dir.mkdir(wd)
  scope_fixture(wd)
  out2 = IO.popen(['ruby', ESTIMATE, '--workdir', wd, '--from-metrics', dirs.join(',')],
                  err: %i[child out], &:read)
  st2 = $?.exitstatus
  ce = JSON.parse(File.read(File.join(wd, 'cost-estimate.json'))) rescue nil
  check(st2.zero? && ce, "combined mode exits 0 and writes cost-estimate.json (got #{st2})", fails)
  check(out2.lines.first.to_s.include?('[calibration] coefficients: MEASURED'),
        'stdout line 1 is the provenance header', fails)
  prov = ce && ce.dig('calibration', 'provenance')
  check(prov && prov['coefficients'] == 'measured' && (prov['runs'] || []).size == 3,
        'report provenance: measured, 3 runs recorded', fails)
  check(ce && ce['confidence'] == 'measured-rate', 'confidence upgraded to measured-rate', fails)
  turns = ce && ce.dig('estimate', 'agent_turns')
  check(turns && ce.dig('estimate', 'estimated_minutes') == (turns * 0.6).round,
        "estimated_minutes uses the fitted 0.6 rate (#{ce && ce.dig('estimate', 'estimated_minutes')} vs #{turns} turns)", fails)
  check(prov && prov['runs'].all? { |r| r.keys.none? { |k| k.include?('path') } && r.values.none? { |v| v.to_s.include?(top) } },
        'hygiene: provenance run stats carry no paths', fails)
end

puts '— 3. low-n refusal: 2 runs keep priors, band refused by name —'
Dir.mktmpdir do |top|
  dirs = [0, 1].map do |i|
    d = File.join(top, "r#{i}")
    Dir.mkdir(d)
    write_run(d, turns: 20, wall_s_each: 30.0)
    d
  end
  out = IO.popen(['ruby', ESTIMATE, '--from-metrics', dirs.join(',')], err: %i[child out], &:read)
  doc = JSON.parse(out[out.index('{')..-1]) rescue nil
  mpt = doc && doc.dig('fit', 'minutes_per_turn')
  check(mpt && mpt['source'] == 'priors' && mpt['value'] == 0.75,
        "2 runs → priors retained (got #{mpt.inspect})", fails)
  check((doc && doc['refused'] || []).any? { |r| r.include?('minutes_per_turn: low-n (2') },
        'refusal is NAMED with its n', fails)
  check(out.include?('coefficients: PRIORS'), 'stdout header says PRIORS', fails)
  band = doc && doc.dig('bands', 'S')
  check(band && band['refused'].to_s.include?('low-n (n=2') && band['n'] == 2 &&
        band['observed_wall_minutes'] == [10.0, 10.0],
        'band refused by name; observations stated, never banded', fails)
end

puts '— 4. pre-turn-capture runs: wall band publishable, rate never derived —'
Dir.mktmpdir do |top|
  dirs = [0, 1, 2].map do |i|
    d = File.join(top, "r#{i}")
    Dir.mkdir(d)
    write_run(d, turns: 10, wall_s_each: 60.0, with_turn_keys: false)
    d
  end
  out = IO.popen(['ruby', ESTIMATE, '--from-metrics', dirs.join(',')], err: %i[child out], &:read)
  doc = JSON.parse(out[out.index('{')..-1]) rescue nil
  mpt = doc && doc.dig('fit', 'minutes_per_turn')
  check(mpt && mpt['source'] == 'priors' && mpt['n'].zero?,
        'no turn-capturing runs → rate refit refused (0 usable), priors kept', fails)
  band = doc && doc.dig('bands', 'S')
  check(band && band['n'] == 3 && band.dig('wall_minutes', 'median') == 10.0,
        'wall band still publishable from 3 turn-less runs', fails)
  check(band && band.dig('rate_min_per_turn', 'refused').to_s.include?('low-n (0'),
        'rate inside the band refused by name (nil ≠ 0)', fails)
end

puts '— 5. bad workdirs are named, usable runs still fit —'
Dir.mktmpdir do |top|
  good = [0, 1, 2].map do |i|
    d = File.join(top, "r#{i}")
    Dir.mkdir(d)
    write_run(d, turns: 20, wall_s_each: 36.0)
    d
  end
  empty = File.join(top, 'empty')
  Dir.mkdir(empty)
  args = good + [empty, '/nonexistent-metrics-dir']
  out = IO.popen(['ruby', ESTIMATE, '--from-metrics', args.join(',')], err: %i[child out], &:read)
  st = $?.exitstatus
  doc = JSON.parse(out[out.index('{')..-1]) rescue nil
  check(st.zero?, "bad inputs never crash the refit (got #{st})", fails)
  errs = (doc && doc['runs'] || []).select { |r| r['error'] }
  check(errs.size == 2 && errs.any? { |r| r['error'].include?('no phase-metrics.jsonl') } &&
        errs.any? { |r| r['error'].include?('not found') },
        "both bad dirs named as errors (got #{errs.inspect})", fails)
  check(doc && doc.dig('fit', 'minutes_per_turn', 'source') == 'measured' &&
        doc.dig('fit', 'minutes_per_turn', 'n') == 3,
        'the 3 usable runs still produce the measured fit', fails)
end

puts '— 6. NO-FALSE-TRIP: without --from-metrics the priors artifact is unchanged —'
Dir.mktmpdir do |wd|
  scope_fixture(wd)
  out = IO.popen(['ruby', ESTIMATE, '--workdir', wd], err: %i[child out], &:read)
  st = $?.exitstatus
  ce = JSON.parse(File.read(File.join(wd, 'cost-estimate.json'))) rescue nil
  check(st.zero? && ce, 'priors path exits 0 with the artifact', fails)
  check(ce && ce['confidence'] == 'rough', 'confidence stays rough', fails)
  check(ce && ce.dig('calibration', 'provenance', 'coefficients') == 'priors',
        'provenance states priors explicitly', fails)
  turns = ce && ce.dig('estimate', 'agent_turns')
  check(turns && ce.dig('estimate', 'estimated_minutes') == (turns * 0.75).round,
        'estimated_minutes uses the 0.75 prior', fails)
  check(!out.include?('[calibration]'), 'no provenance header without --from-metrics (stdout unchanged)', fails)
end

puts
if fails.empty?
  puts 'OK — all refit checks passed'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
