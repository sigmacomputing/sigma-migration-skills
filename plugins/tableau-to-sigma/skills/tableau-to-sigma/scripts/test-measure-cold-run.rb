#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-measure-cold-run.rb — W2.24 harness, OFFLINE (network stubbed: the
# orchestrator/sweep/cleanup commands are local stub scripts; the live cold
# runs happen at wave integration, not here).
#
#   RUN half:
#     T1 clean run     — metrics/fidelity/litter collected; VALUES redacted
#                        (equals-form --flag=VALUE truncated to the NAME too)
#     T2 exit-12 resume — re-entry argv is the orchestrator's printed pass-2
#                        command (--finalize AND --actuals <WORKDIR>/parity-
#                        actuals.json; pass 2 aborts on --finalize alone);
#                        counted (launched 2, re_entries 1)
#     T2b exit-12 dedup — base argv already carries --finalize + --actuals
#                        (equals form): neither appended twice, path kept
#     T2c exit-12 missing actuals — parity-actuals.json absent at resume →
#                        harness-level REFUSAL stop (code 12, named), NO blind
#                        re-invoke, re_entries stays 0
#     T3 stop attribution — exit 10 → named operator stop, harness exit 3
#     T4 /tmp-side refusal — repo-side --workdir/--results refused (exit 2)
#     T5 wedge kill    — invocation deadline kills a sleeping orchestrator
#     T6 litter        — outstanding registry entry recorded; sweep chain ran
#                        dry-run BEFORE --delete
#   GATE half (trip AND no-false-trip):
#     T7 clean pass    — band-adjacent-measured; re-entry proof dead; certified band
#     T8 in-band       — median <=10 min
#     T9 trip          — median 16 min → miss-publish-measured-band (measured
#                        band stated; the projection is nowhere)
#     T10 near-miss    — exactly 15.0 min / 22 turns / 1 inv / 1 stop → still
#                        band-adjacent (no false trip at the boundary)
#     T11 low-n        — 2 runs → refused (exit 3)
#     T12 unmeasured   — turn_events nil → refused-unmeasured-turns (exit 3)
#     T13 fidelity     — proof-run parity FAIL → speed VOID; headline FAIL →
#                        voided out → refused-fidelity-void
#     T14 litter gate  — registry_open_after 1 → publishable false, violation named
#     T15 terminal-only — non-terminal parity-PASS runs excluded BY NAME (trip:
#                        partial walls would read in-band → refused-non-terminal;
#                        no-false-trip: a stray partial run neither blocks nor
#                        drags the median; proof/certified need terminal too)
#
# Usage: ruby scripts/test-measure-cold-run.rb   (deterministic, no network)

require 'json'
require 'tmpdir'
require 'fileutils'

DIR     = __dir__
HARNESS = File.join(DIR, 'measure-cold-run.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def write_stubs(dir)
  orch = File.join(dir, 'stub-orch.rb')
  File.write(orch, <<~'RB')
    #!/usr/bin/env ruby
    require 'json'
    wd = ARGV[ARGV.rindex('--workdir') + 1]
    mode = ENV.fetch('STUB_MODE', 'clean')
    t0 = Time.utc(2026, 7, 1, 12, 0, 0)
    write_metrics = lambda do |inv, n|
      File.open(File.join(wd, 'phase-metrics.jsonl'), 'a') do |f|
        n.times do |i|
          f.puts(JSON.generate('phase' => "phase#{(i % 6) + 1}-x", 'wall_s' => 30.0,
                               'at' => (t0 + i * 30).strftime('%Y-%m-%dT%H:%M:%SZ'),
                               'turn' => i + 1, 'inv' => inv))
        end
      end
    end
    finish = lambda do
      File.write(File.join(wd, 'parity-final.json'),
                 JSON.generate('status' => 'PASS', 'charts_pass' => 9, 'charts_total' => 9,
                               'value_parity_score' => 1.0, 'visual_verdict' => 'pass'))
      File.write(File.join(wd, 'migrate-state.json'), JSON.generate('tier' => 'S'))
    end
    case mode
    when 'clean'
      write_metrics.call('100-1', 10); finish.call; exit 0
    when 'exit12'
      # Mirrors the real pass-1/pass-2 contract: pass 1's pooled collector
      # leaves parity-actuals.json in the workdir and exits 12; pass 2 ABORTS
      # (exit 1) on --finalize without --actuals, exactly like the orchestrator.
      if ARGV.include?('--finalize')
        ai = ARGV.index('--actuals')
        actuals = ai ? ARGV[ai + 1] : ARGV.find { |a| a.start_with?('--actuals=') }&.split('=', 2)&.last
        if actuals.to_s.empty?
          warn '--actuals required with --finalize (stub mirror of migrate-tableau.rb)'
          exit 1
        end
        File.write(File.join(wd, 'resume-argv.json'), JSON.generate(ARGV))
        write_metrics.call('200-2', 4); finish.call; exit 0
      else
        File.write(File.join(wd, 'parity-actuals.json'), JSON.generate('charts' => []))
        write_metrics.call('100-1', 8); exit 12
      end
    when 'exit12-marker'
      # Pass keyed on a MARKER FILE, not argv — lets a test preload --finalize/
      # --actuals into the base argv and still exercise the exit-12 resume.
      marker = File.join(wd, 'pass1-done.marker')
      if File.exist?(marker)
        File.write(File.join(wd, 'resume-argv.json'), JSON.generate(ARGV))
        write_metrics.call('200-2', 4); finish.call; exit 0
      else
        File.write(marker, '1')
        File.write(File.join(wd, 'parity-actuals.json'), JSON.generate('charts' => []))
        write_metrics.call('100-1', 8); exit 12
      end
    when 'exit12-noactuals'
      # Pass-1 tail reached but the pooled collector never wrote
      # parity-actuals.json. ANY second invocation is the bug (a blind
      # re-invoke can only reproduce the orchestrator abort).
      calls = File.join(wd, 'orch-calls.log')
      File.open(calls, 'a') { |f| f.puts('invoked') }
      if File.readlines(calls).size > 1
        File.write(File.join(wd, 'reinvoked.marker'), '1')
        exit 1
      end
      write_metrics.call('100-1', 8); exit 12
    when 'stop10'
      write_metrics.call('100-1', 2); exit 10
    when 'sleepy'
      sleep 30
    when 'litter'
      write_metrics.call('100-1', 10); finish.call
      File.open(File.join(wd, 'probe-artifacts.jsonl'), 'a') do |f|
        f.puts(JSON.generate('id' => 'orphan-1', 'name' => 'probe', 'created_at' => '2026-07-01T12:00:00Z'))
      end
      exit 0
    end
  RB
  sweep = File.join(dir, 'stub-sweep.rb')
  File.write(sweep, <<~'RB')
    #!/usr/bin/env ruby
    wd = ARGV[ARGV.index('--workdir') + 1]
    File.open(File.join(wd, 'sweep-calls.log'), 'a') { |f| f.puts(ARGV.include?('--delete') ? 'delete' : 'dry-run') }
    exit 0
  RB
  cleanup = File.join(dir, 'stub-cleanup.rb')
  File.write(cleanup, <<~'RB')
    #!/usr/bin/env ruby
    wd = ARGV[ARGV.index('--workdir') + 1]
    File.open(File.join(wd, 'sweep-calls.log'), 'a') { |f| f.puts('cleanup') }
    exit 0
  RB
  [orch, sweep, cleanup]
end

def run_harness(args, env = {})
  out = IO.popen(env, ['ruby', HARNESS] + args, err: %i[child out], &:read)
  [out, $?.exitstatus]
end

def stub_args(orch, sweep, cleanup, wd, results, extra = [])
  ['run', '--label', extra.delete('LABEL') || 'R2-1', '--role', 'tier-s-headline', '--target', 'REF-TEST',
   '--workdir', wd, '--results', results,
   '--orchestrator', "ruby #{orch}", '--sweep-cmd', "ruby #{sweep}", '--cleanup-cmd', "ruby #{cleanup}"] + extra
end

puts 'T1 — clean run: metrics + fidelity + litter collected, values redacted'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  results = File.join(top, 'results.jsonl')
  out, st = run_harness(stub_args(orch, sweep, cleanup, wd, results,
                                  ['--', '--db', 'SEKRIT_DB', '--schema', 'SEKRIT_SCHEMA',
                                   '--folder=SEKRIT_FOLDER', '--tier', 'auto']),
                        { 'STUB_MODE' => 'clean' })
  check(st.zero?, "clean run exits 0 (got #{st}: #{out.lines.first})", fails)
  raw = File.read(results)
  rec = JSON.parse(raw.lines.last)
  check(rec['turns']['turn_events'] == 10, "turn_events from phase-metrics (got #{rec['turns'].inspect})", fails)
  check(rec['invocations']['launched'] == 1 && rec['invocations']['re_entries'].zero? &&
        rec['invocations']['metrics_invocations'] == 1,
        'single invocation, zero re-entries, metrics cross-check agrees', fails)
  check(rec['fidelity']['parity_status'] == 'PASS' && rec['fidelity']['charts_total'] == 9 &&
        rec['fidelity']['tier'] == 'S',
        'fidelity read from parity-final.json + migrate-state.json', fails)
  check(rec['litter']['swept'] && rec['litter']['registry_open_after'].zero?,
        'litter chain ran and registry is zero-open', fails)
  check(!raw.include?('SEKRIT'), 'HYGIENE: argv VALUES never enter the record', fails)
  check(!raw.include?(wd), 'HYGIENE: workdir path never enters the record', fails)
  check(rec['argv_flags'].include?('--schema'), 'flag NAMES are kept for audit', fails)
  check(rec['argv_flags'] == ['--db', '--schema', '--folder', '--tier'],
        "equals-form --flag=VALUE truncated to the NAME (got #{rec['argv_flags'].inspect})", fails)
  check(!out.include?('SEKRIT'), 'HYGIENE: stdout invocation echo redacts equals-form values too', fails)
  check(rec['wall']['metrics_wall_minutes'] == 5.0, 'metrics wall = 10×30s = 5 min', fails)
  calls = File.readlines(File.join(wd, 'sweep-calls.log')).map(&:strip)
  check(calls == %w[dry-run delete cleanup], "sweep order dry-run → --delete → cleanup (got #{calls.inspect})", fails)
end

puts 'T2 — exit-12 resume: --finalize + --actuals re-entry (the printed pass-2 contract)'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  results = File.join(top, 'results.jsonl')
  _out, st = run_harness(stub_args(orch, sweep, cleanup, wd, results, ['--', '--db', 'X']),
                         { 'STUB_MODE' => 'exit12' })
  rec = JSON.parse(File.readlines(results).last)
  check(st.zero?, "resume run reaches terminal 0 (got #{st})", fails)
  check(rec['invocations']['launched'] == 2 && rec['invocations']['re_entries'] == 1,
        "exit 12 → one re-entry (got #{rec['invocations'].inspect})", fails)
  check(rec['invocations']['metrics_invocations'] == 2,
        'phase-metrics inv tokens see both invocations', fails)
  check(rec['turns']['turn_events'] == 12, '8 + 4 turn events across the two passes', fails)
  resume = JSON.parse(File.read(File.join(wd, 'resume-argv.json')))
  check(resume.include?('--finalize'), 'resume argv carries --finalize', fails)
  ai = resume.index('--actuals')
  check(!ai.nil? && resume[ai + 1] == File.join(wd, 'parity-actuals.json'),
        "resume argv carries --actuals <WORKDIR>/parity-actuals.json (got #{resume.inspect})", fails)
end

puts 'T2b — exit-12 resume dedup: base argv already carries --finalize + --actuals (equals form)'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  results = File.join(top, 'results.jsonl')
  actuals_eq = "--actuals=#{File.join(wd, 'parity-actuals.json')}"
  _out, st = run_harness(stub_args(orch, sweep, cleanup, wd, results,
                                   ['--', '--db', 'X', '--finalize', actuals_eq]),
                         { 'STUB_MODE' => 'exit12-marker' })
  rec = JSON.parse(File.readlines(results).last)
  check(st.zero?, "resume run reaches terminal 0 (got #{st})", fails)
  check(rec['invocations']['launched'] == 2 && rec['invocations']['re_entries'] == 1,
        "one re-entry, no refusal (got #{rec['invocations'].inspect})", fails)
  resume = JSON.parse(File.read(File.join(wd, 'resume-argv.json')))
  check(resume.count { |a| a == '--finalize' } == 1, 'no duplicate --finalize appended', fails)
  check(resume.count { |a| a == '--actuals' || a.start_with?('--actuals=') } == 1,
        "no duplicate --actuals (equals form detected; got #{resume.inspect})", fails)
  check(resume.include?(actuals_eq), 'the operator-supplied actuals path is kept as-is', fails)
  check(!File.read(results).include?(wd), 'HYGIENE: no workdir path enters the record', fails)
end

puts 'T2c — exit-12 with parity-actuals.json MISSING: harness refuses, never blind re-invokes'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  results = File.join(top, 'results.jsonl')
  out, st = run_harness(stub_args(orch, sweep, cleanup, wd, results, ['--', '--db', 'X']),
                        { 'STUB_MODE' => 'exit12-noactuals' })
  rec = JSON.parse(File.readlines(results).last)
  check(st == 3, "refused resume is a non-terminal harness halt, exit 3 (got #{st})", fails)
  check(rec['invocations']['launched'] == 1 && rec['invocations']['re_entries'].zero?,
        "no re-invocation launched, no re-entry counted (got #{rec['invocations'].inspect})", fails)
  check(!File.exist?(File.join(wd, 'reinvoked.marker')),
        'orchestrator was NOT blindly re-invoked into its --actuals abort', fails)
  stop = rec['stops'].first || {}
  check(stop['code'] == 12 && stop['named'].to_s.include?('REFUSED') &&
        stop['named'].to_s.include?('parity-actuals.json'),
        "stop names the harness-level refusal (got #{rec['stops'].inspect})", fails)
  check(rec['terminal'] == false, 'refused run is recorded non-terminal', fails)
  check(!File.read(results).include?(wd), 'HYGIENE: refusal stop keeps paths out of the record', fails)
  check(out.include?('NOT re-invoking'), 'stdout names the refusal before the litter chain', fails)
end

puts 'T3 — operator stop: exit 10 attributed by name, harness exit 3'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  results = File.join(top, 'results.jsonl')
  out, st = run_harness(stub_args(orch, sweep, cleanup, wd, results), { 'STUB_MODE' => 'stop10' })
  rec = JSON.parse(File.readlines(results).last)
  check(st == 3, "stopped run exits 3 (got #{st})", fails)
  check(rec['stops'] == [{ 'code' => 10, 'named' => 'decisions checkpoint / open questions' }],
        "stop attributed by name (got #{rec['stops'].inspect})", fails)
  check(rec['terminal'] == false && out.include?('OPERATOR STOP'), 'record + stdout say operator stop', fails)
end

puts 'T4 — /tmp-side red line: repo-side workdir/results refused'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  repo_side = File.join(DIR, 'never-a-workdir')
  results = File.join(top, 'results.jsonl')
  out, st = run_harness(stub_args(orch, sweep, cleanup, repo_side, results))
  check(st == 2 && out.include?('inside the repo'), "repo-side --workdir refused (got #{st})", fails)
  check(!File.exist?(repo_side), 'nothing created repo-side', fails)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  out2, st2 = run_harness(stub_args(orch, sweep, cleanup, wd, File.join(DIR, 'results.jsonl')))
  check(st2 == 2 && out2.include?('inside the repo'), 'repo-side --results refused too', fails)
  check(!File.exist?(File.join(DIR, 'results.jsonl')), 'no results file created repo-side', fails)
end

puts 'T5 — wedged orchestrator killed at the invocation deadline'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  results = File.join(top, 'results.jsonl')
  t0 = Time.now
  _out, st = run_harness(stub_args(orch, sweep, cleanup, wd, results, ['--invocation-timeout', '2']),
                         { 'STUB_MODE' => 'sleepy' })
  elapsed = Time.now - t0
  rec = JSON.parse(File.readlines(results).last)
  check(st == 3, "timeout run exits 3 (got #{st})", fails)
  check(elapsed < 15, "killed within budget (took #{elapsed.round(1)}s)", fails)
  check(rec['stops'].first['named'].include?('timeout'), 'stop names the harness timeout', fails)
end

puts 'T6 — litter: outstanding registry entry surfaces in the record'
Dir.mktmpdir do |top|
  orch, sweep, cleanup = write_stubs(top)
  wd = File.join(top, 'wd'); Dir.mkdir(wd)
  results = File.join(top, 'results.jsonl')
  out, st = run_harness(stub_args(orch, sweep, cleanup, wd, results), { 'STUB_MODE' => 'litter' })
  rec = JSON.parse(File.readlines(results).last)
  check(st.zero?, 'run itself is terminal-ok', fails)
  check(rec['litter']['registry_open_after'] == 1, 'registry_open_after = 1 recorded', fails)
  check(out.include?('NOT zero-open'), 'loud litter warning printed', fails)
end

# ── GATE half: synthesized records ──────────────────────────────────────────
def rec(label:, role:, wall:, turns:, inv: 1, reent: 0, stops: 0, parity: 'PASS',
        score: 1.0, cpass: 9, ctot: 9, reg: 0, terminal: true)
  { 'v' => 1, 'kind' => 'cold-run', 'label' => label, 'role' => role, 'target' => 'REF-TEST',
    'wall' => { 'operator_minutes' => wall, 'metrics_wall_minutes' => wall },
    'turns' => { 'turn_events' => turns, 'poll_events_observed' => 0 },
    'invocations' => { 'launched' => inv, 're_entries' => reent, 'wait_continuations' => 0,
                       'metrics_invocations' => inv },
    'stops' => Array.new(stops) { { 'code' => 10, 'named' => 'decisions checkpoint / open questions' } },
    'terminal' => terminal,
    'fidelity' => { 'parity_status' => parity, 'value_parity_score' => score,
                    'charts_pass' => cpass, 'charts_total' => ctot, 'tier' => 'S', 'missing' => [] },
    'litter' => { 'swept' => true, 'registry_open_after' => reg } }
end

def write_results(path, recs)
  File.open(path, 'w') { |f| recs.each { |r| f.puts(JSON.generate(r)) } }
end

def run_gate(results, extra = [])
  out = IO.popen(['ruby', HARNESS, 'gate', '--results', results] + extra, err: %i[child out], &:read)
  doc = JSON.parse(out[out.index('{')..out.rindex('}')]) rescue nil
  [out, $?.exitstatus, doc]
end

puts 'T7 — gate clean pass: band-adjacent + re-entry dead + certified band'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 12.0, turns: 18),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 13.5, turns: 20, stops: 1),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 14.0, turns: 22),
    rec(label: 'R2-M1', role: 're-entry-proof', wall: 24.0, turns: 30, inv: 2, reent: 1),
    rec(label: 'R2-C1', role: 'certified', wall: 28.0, turns: 40)
  ])
  out, st, doc = run_gate(results, ['--expect-charts', '9/9'])
  check(st.zero?, "gate evaluates (got #{st})", fails)
  check(doc.dig('headline', 'verdict') == 'band-adjacent-measured',
        "verdict band-adjacent-measured (got #{doc.dig('headline', 'verdict').inspect})", fails)
  check(doc.dig('headline', 'medians', 'wall_minutes') == 13.5, 'median wall 13.5', fails)
  check(doc.dig('re_entry_proof', 'status') == 'dead' && doc.dig('re_entry_proof', 're_entries') == 1,
        're-entry loop declared dead (1 <= 1, was 5)', fails)
  check(doc.dig('certified_band', 'wall_minutes_median') == 28.0, 'certified band reported as second number', fails)
  check(doc['publishable'] == true && out.include?('publishable: true'), 'publishable', fails)
end

puts 'T8 — gate in-band: median <=10'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 9.0, turns: 15),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 9.5, turns: 16),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 10.0, turns: 17)
  ])
  _out, st, doc = run_gate(results)
  check(st.zero? && doc.dig('headline', 'verdict') == 'in-band',
        "median 9.5 → in-band (got #{doc.dig('headline', 'verdict').inspect})", fails)
end

puts 'T9 — gate trip: median 16 min → miss, MEASURED band stated'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 15.0, turns: 24),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 16.0, turns: 26),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 21.0, turns: 30)
  ])
  _out, st, doc = run_gate(results)
  check(st.zero? && doc.dig('headline', 'verdict') == 'miss-publish-measured-band',
        "miss verdict (got #{doc.dig('headline', 'verdict').inspect})", fails)
  band = doc.dig('headline', 'measured_band')
  check(band && band['n'] == 3 && band.dig('wall_minutes', 'median') == 16.0 &&
        band['statement'].include?('measured'),
        'the MEASURED band ships with the miss', fails)
  check(band['statement'].include?('projection is not publishable'),
        'the projection is named unpublishable', fails)
end

puts 'T10 — gate near-miss-no-trip: exactly at every boundary still passes'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 15.0, turns: 22, stops: 1),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 15.0, turns: 22, stops: 1),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 15.0, turns: 22, stops: 1)
  ])
  _out, st, doc = run_gate(results)
  check(st.zero? && doc.dig('headline', 'verdict') == 'band-adjacent-measured',
        "boundary values (<=) do not trip (got #{doc.dig('headline', 'verdict').inspect})", fails)
end

puts 'T11 — gate low-n refusal: 2 runs'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 9.0, turns: 15),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 9.0, turns: 15)
  ])
  out, st, doc = run_gate(results)
  check(st == 3, "refusal exits 3 (got #{st})", fails)
  check(doc.dig('headline', 'refused').to_s.include?('refused-low-n') &&
        doc.dig('headline', 'refused').include?('2 usable'),
        'refusal named with its n', fails)
  check(out.include?('publishable: false'), 'not publishable', fails)
end

puts 'T12 — gate refuses unmeasured turns (nil never evaluated as 0)'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  rs = [rec(label: 'R2-1', role: 'tier-s-headline', wall: 9.0, turns: 15),
        rec(label: 'R2-2', role: 'tier-s-headline', wall: 9.0, turns: 15),
        rec(label: 'R2-3', role: 'tier-s-headline', wall: 9.0, turns: nil)]
  write_results(results, rs)
  _out, st, doc = run_gate(results)
  check(st == 3 && doc.dig('headline', 'refused').to_s.include?('refused-unmeasured-turns'),
        "turn capture absent → refused (got #{doc.dig('headline', 'refused').inspect})", fails)
end

puts 'T13 — fidelity: proof FAIL voids the speed number; headline FAIL voids the run'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 12.0, turns: 18),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 13.0, turns: 19),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 14.0, turns: 20),
    rec(label: 'R2-M1', role: 're-entry-proof', wall: 20.0, turns: 25, inv: 2, reent: 1, parity: 'FAIL')
  ])
  _out, st, doc = run_gate(results, ['--expect-charts', '9/9'])
  check(st.zero? && doc.dig('re_entry_proof', 'status') == 'void-fidelity' &&
        doc.dig('re_entry_proof', 'note').include?('VOID'),
        "proof fidelity mismatch → speed VOID (got #{doc.dig('re_entry_proof', 'status').inspect})", fails)

  results2 = File.join(top, 'r2.jsonl')
  write_results(results2, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 12.0, turns: 18, parity: 'FAIL'),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 13.0, turns: 19),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 14.0, turns: 20)
  ])
  _out2, st2, doc2 = run_gate(results2)
  check(st2 == 3 && doc2.dig('headline', 'refused').to_s.include?('refused-fidelity-void'),
        'headline FAIL run voided → below min-n → refused-fidelity-void', fails)
end

puts 'T14 — litter gate: open registry blocks publication by name'
Dir.mktmpdir do |top|
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 12.0, turns: 18),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 13.0, turns: 19),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 14.0, turns: 20, reg: 1)
  ])
  out, st, doc = run_gate(results)
  check(st.zero? && doc.dig('headline', 'verdict') == 'band-adjacent-measured',
        'band math itself unaffected', fails)
  check(doc.dig('litter', 'clean') == false &&
        doc.dig('litter', 'violations').first.include?('R2-3'),
        'litter violation named per run', fails)
  check(doc['publishable'] == false && out.include?('VIOLATIONS'),
        'publication blocked until re-swept', fails)
end

puts 'T15 — gate terminal-only: partial (non-terminal) walls never enter a published number'
Dir.mktmpdir do |top|
  # TRIP: two runs stopped after parity wrote PASS (terminal false, short
  # PARTIAL walls) + one clean run. Without the terminal filter this set reads
  # "in-band" off 6/7-minute partial walls — §5's wall is intake→terminal, so
  # the gate must exclude them BY NAME and refuse on n instead.
  results = File.join(top, 'r.jsonl')
  write_results(results, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 6.0, turns: 12, stops: 1, terminal: false),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 7.0, turns: 14, stops: 1, terminal: false),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 14.8, turns: 21)
  ])
  out, st, doc = run_gate(results)
  check(st == 3, "non-terminal majority → refused, exit 3 (got #{st})", fails)
  check(doc.dig('headline', 'refused').to_s.include?('refused-non-terminal') &&
        doc.dig('headline', 'non_terminal') == 2,
        "refusal named refused-non-terminal with count (got #{doc.dig('headline', 'refused').inspect})", fails)
  check(doc.dig('headline', 'refused').to_s.include?('R2-1') &&
        doc.dig('headline', 'refused').to_s.include?('R2-2'),
        'excluded runs named by label', fails)
  check(doc['publishable'] == false && out.include?('publishable: false'),
        'partial walls are never publishable', fails)

  # NO-FALSE-TRIP: three terminal runs still gate normally — a stray partial
  # run (parity PASS, 2-min wall) neither blocks the verdict nor drags the
  # median; a non-terminal proof run cannot declare the loop dead; a
  # non-terminal certified run yields no certified band.
  results2 = File.join(top, 'r2.jsonl')
  write_results(results2, [
    rec(label: 'R2-1', role: 'tier-s-headline', wall: 9.0, turns: 15),
    rec(label: 'R2-2', role: 'tier-s-headline', wall: 9.5, turns: 16),
    rec(label: 'R2-3', role: 'tier-s-headline', wall: 10.0, turns: 17),
    rec(label: 'R2-4', role: 'tier-s-headline', wall: 2.0, turns: 3, stops: 1, terminal: false),
    rec(label: 'R2-M1', role: 're-entry-proof', wall: 5.0, turns: 8, reent: 0, stops: 1, terminal: false),
    rec(label: 'R2-C1', role: 'certified', wall: 3.0, turns: 5, stops: 1, terminal: false)
  ])
  _out2, st2, doc2 = run_gate(results2)
  check(st2.zero? && doc2.dig('headline', 'verdict') == 'in-band' &&
        doc2.dig('headline', 'medians', 'wall_minutes') == 9.5,
        "terminal trio gates in-band, partial wall out of the median (got #{doc2.dig('headline', 'medians', 'wall_minutes').inspect})", fails)
  check(doc2.dig('headline', 'non_terminal') == 1, 'stray partial run counted out by name', fails)
  check(doc2.dig('re_entry_proof', 'status') == 'unproven' &&
        doc2.dig('re_entry_proof', 'note').include?('none terminal'),
        "non-terminal proof run proves nothing (got #{doc2.dig('re_entry_proof', 'status').inspect})", fails)
  check(doc2.dig('certified_band', 'n').zero? &&
        doc2.dig('certified_band', 'note').include?('none terminal'),
        'no certified band from a partial wall', fails)
end

puts
if fails.empty?
  puts 'OK — all measure-cold-run checks passed'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
