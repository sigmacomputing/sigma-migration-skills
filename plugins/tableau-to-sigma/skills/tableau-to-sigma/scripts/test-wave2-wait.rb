#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave2-wait.rb — W2.5 (--wait one-tool-call contract) + W2.6 (pass-1-tail
# visual-verdict wait-gate). Fully offline: real orchestrator runs over the
# wave-1 fixture (test-wave1-support.rb) for the wrapper trajectories; the
# predicate/classifier matrix runs on extracted first-party code (the
# test-wave1-predicates.rb extraction pattern).
#
#   W2.5  T1 pass-through: inner exit rides out VERBATIM (18 via --yes,
#            10 via the interactive checkpoint stop); wait-mode stdout ≤5
#            lines; the child log carries the full run.
#         T2 budget exhaustion → exit 26, child STILL ALIVE (pid parsed from
#            the banner, liveness proven, then reaped by the test).
#         T3 --quiet wait mode: stdout is pure JSON quiet_event lines
#            (wait / wait-exit / exit), all parseable.
#   W2.6  T4 classifier matrix: cold (no verdict) → :wait; recorded
#            'not-executable' → :terminal (no wait, no chain); staged-RCF
#            reasons → :wait; markers/pivots → :terminal; discharged
#            obligations → :chain; --fast waives the verdict leg.
#         T5 wiring pins: banner line ONE names SIGMA_VISUAL_VERDICT_TIMEOUT_S
#            + the 0=don't-wait escape (the 1d headless-contract rule);
#            timeout falls open to exit 12; SIGMA_NO_CHAIN_FINALIZE guards
#            the wait AND the chain; six-trajectory coverage per the ≤5%
#            false-trip budget (no-false-chain legs live in the matrix).
#
# Usage: ruby scripts/test-wave2-wait.rb   (~90s, spawns offline fixture runs)

require 'json'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative 'test-wave1-support'

DIR = __dir__
SRC = File.read(File.join(DIR, 'migrate-tableau.rb'), encoding: 'UTF-8')
m = SRC.match(/^WAITABLE_CHAIN_RES = .*?\.freeze$/m) or abort('could not extract WAITABLE_CHAIN_RES')
eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
%w[finalize_chain_predicate chain_wait_class].each do |fn|
  fm = SRC.match(/^def #{Regexp.escape(fn)}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(fm[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Run the wrapper (--wait) over the fixture. Returns [stdout+stderr, status].
def wait_run(dir, extra, env_over = {}, png_wait: '1')
  Wave1Fixture.run(dir, extra, env_over, png_wait: png_wait)
end

puts 'T1 — W2.5 pass-through: inner exit codes ride out VERBATIM'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, st = wait_run(d, ['--folder', 'fold-x', '--yes', '--wait=240'])
  check(st.exitstatus == 18, "--yes run: wrapper exits the INNER 18 (got #{st.exitstatus})", fails)
  check(out.include?('--wait: run driving in background (pid '), 'wait banner names the pid', fails)
  check(out.include?('inner exit 18 (passed through verbatim)'), 'pass-through line names the inner code', fails)
  vis = out.lines.map(&:strip).reject(&:empty?)
  check(vis.size <= 5, "wait-mode stdout is ≤5 lines (got #{vis.size})", fails)
  log = File.join(d, 'migrate-full.log')
  check(File.exist?(log) && File.read(log, encoding: 'UTF-8').include?('DASHBOARD-READ WAIT-GATE TIMEOUT'),
        'the full run (incl. the inner exit-18 banner) landed in migrate-full.log', fails)
end
Dir.mktmpdir do |d|
  Wave1Fixture.build(d) # M-shaped → interactive checkpoint stop
  out, st = wait_run(d, ['--folder', 'fold-x', '--wait', '240'])
  check(st.exitstatus == 10, "interactive run: wrapper exits the INNER 10 (got #{st.exitstatus}; separated-budget form consumed)", fails)
  check(out.include?('inner exit 10'), 'pass-through line for the checkpoint stop', fails)
  check(File.exist?(File.join(d, 'open-questions.json')),
        'the child really ran the checkpoint (artifact present)', fails)
end

puts 'T2 — W2.5 budget exhaustion: exit 26, run STILL ALIVE (never a failure)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, st = wait_run(d, ['--folder', 'fold-x', '--yes', '--wait=2'],
                     {}, png_wait: '120') # child holds ≥120s in the 1d wait
  check(st.exitstatus == 26, "wrapper exits 26 (got #{st.exitstatus})", fails)
  check(out.include?('WAIT BUDGET EXHAUSTED') && out.include?('STILL ALIVE'),
        'banner says the run is STILL ALIVE (exit 26 is not a failure)', fails)
  pid = out[/pid (\d+)/, 1].to_i
  alive = pid.positive? && (Process.kill(0, pid) rescue nil) == 1
  check(alive, "child pid #{pid} is still alive after the wrapper exits", fails)
  if pid.positive? # reap the intentionally-orphaned child so the test leaves nothing behind
    Process.kill('TERM', pid) rescue nil
    20.times { break unless (Process.kill(0, pid) rescue nil); sleep 0.25 }
    Process.kill('KILL', pid) rescue nil
  end
end

puts 'T3 — W2.5 --quiet wait mode: stdout is machine JSON only'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, st = wait_run(d, ['--folder', 'fold-x', '--yes', '--quiet', '--wait=240'])
  check(st.exitstatus == 18, "quiet wrapper still passes the inner 18 through (got #{st.exitstatus})", fails)
  evs = out.lines.map(&:strip).reject(&:empty?).map { |l| JSON.parse(l) rescue nil }
  check(evs.any? && evs.all? { |e| e.is_a?(Hash) && e['ev'] },
        'every stdout line is a parseable quiet_event JSON object', fails)
  check(evs.any? { |e| e['ev'] == 'wait' && e['pid'] && e['log'] } &&
        evs.any? { |e| e['ev'] == 'wait-exit' && e['code'] == 18 },
        'wait + wait-exit events carry pid/log and the verbatim inner code', fails)
end

# ── W2.6 predicate/classifier matrix (pure, offline) ─────────────────────────
def chain_fixture(d, verdict: :none, rcf: 0, marker: false, ledger: nil)
  File.write(File.join(d, 'parity-plan.json'), JSON.generate(
               'charts' => [{ 'chart' => 'C1', 'name' => 'C1', 'sigma_kind' => 'bar-chart',
                              'sigma_columns' => ['Sales'] }]))
  File.write(File.join(d, 'parity-actuals.json'), JSON.generate(
               'C1' => marker ? 'render-verify' : [%w[East 10]]))
  File.write(File.join(d, 'migrate-state.json'), JSON.generate('rcf_passes' => rcf))
  unless verdict == :none
    File.write(File.join(d, 'parity-final.json'), JSON.generate('visual_verdict' => verdict))
  end
  File.write(File.join(d, 'fidelity-ledger.json'), JSON.generate(ledger)) if ledger
end

puts 'T4 — W2.6 classifier: wait ONLY on agent-dischargeable obligations'
Dir.mktmpdir do |d|
  chain_fixture(d) # cold: no verdict, rcf unstaged
  ok, why = finalize_chain_predicate(d)
  check(!ok && chain_wait_class(ok, why) == :wait,
        "cold run (no recorded verdict) → :wait (why: #{why[0, 50]})", fails)
end
Dir.mktmpdir do |d|
  chain_fixture(d, verdict: 'not-executable')
  ok, why = finalize_chain_predicate(d)
  check(!ok && chain_wait_class(ok, why) == :terminal,
        'recorded not-executable → :terminal (an ANSWER: no wait, no chain)', fails)
end
Dir.mktmpdir do |d|
  chain_fixture(d, verdict: 'pass', rcf: 1)
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /RCF loop staged/ && chain_wait_class(ok, why) == :wait,
        'verdict recorded but staged RCF ledger missing → :wait', fails)
end
Dir.mktmpdir do |d|
  chain_fixture(d, verdict: 'pass', rcf: 1,
                ledger: { 'entries' => [{ 'cls' => 'spec-fixable', 'resolved' => false }] })
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /unresolved spec-fixable/ && chain_wait_class(ok, why) == :wait,
        'unresolved spec-fixable RCF delta → :wait (agent resolves, then chains)', fails)
end
Dir.mktmpdir do |d|
  chain_fixture(d, verdict: 'pass', rcf: 1,
                ledger: { 'entries' => [{ 'cls' => 'spec-fixable', 'resolved' => true }] })
  ok, _why = finalize_chain_predicate(d)
  check(ok && chain_wait_class(ok, nil) == :chain,
        'discharged obligations (verdict + resolved ledger) → :chain', fails)
end
Dir.mktmpdir do |d|
  chain_fixture(d, marker: true)
  ok, why = finalize_chain_predicate(d)
  check(!ok && chain_wait_class(ok, why) == :terminal,
        'agent-mediated marker → :terminal (structural; no wait — no-false-chain)', fails)
end
Dir.mktmpdir do |d|
  chain_fixture(d) # no verdict — but --fast waives the visual legs
  ok, = finalize_chain_predicate(d, fast: true)
  check(ok, '--fast waives the verdict leg (chain reachable without a verdict)', fails)
end

puts 'T5 — W2.6 wiring pins (banner contract + fail-open + escape hatch)'
wait_banner = SRC.lines.find { |l| l.include?('PASS-1-TAIL WAIT (W2.6)') }
check(wait_banner && wait_banner.include?('SIGMA_VISUAL_VERDICT_TIMEOUT_S') &&
      wait_banner.include?("0 = don't wait"),
      'banner line ONE names the override env + the 0=don\'t-wait escape (1d headless rule)', fails)
check(SRC.include?("(ENV['SIGMA_VISUAL_VERDICT_TIMEOUT_S'] || '480').to_i"),
      'default bound is 480s', fails)
check(SRC =~ /fail-open to the exit-12 two-invocation contract/,
      'deadline falls OPEN to exit 12 (today\'s contract; a wait never invents a failure)', fails)
check(SRC.scan(/SIGMA_NO_CHAIN_FINALIZE/).size >= 3,
      'SIGMA_NO_CHAIN_FINALIZE guards the wait AND the chain (escape untouched)', fails)
check(SRC =~ /chain_wait_class\(_chain_ok, _chain_why\) == :terminal\n\s+line "visual-verdict wait ended/,
      'a mid-wait terminal answer (e.g. not-executable) ends the wait early', fails)
check(SRC.include?('ruby scripts/record-visual-check.rb --workdir'),
      'banner prints the exact record command (discharge path is copy-pasteable)', fails)

puts
if fails.empty?
  puts 'test-wave2-wait: ALL PASS'
else
  puts "test-wave2-wait: #{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
