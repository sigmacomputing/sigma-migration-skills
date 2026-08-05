#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-pbi-flip-gate.rb — offline unit tests for migrate-powerbi.rb Phase 6b
# (runtime control-flip proof) decision glue: lib/pbi_flip.rb + the shared
# lib/flip_gate.rb contract Phase 6b depends on. No live API.

require_relative 'lib/pbi_flip'
require_relative 'lib/flip_gate'

$failures = 0
def check(cond, msg)
  if cond
    puts "  ok  #{msg}"
  else
    $failures += 1
    warn "  FAIL #{msg}"
  end
end

# --- FlipGate.decide contract (the live-probe path Phase 6b relies on) --------
puts 'FlipGate.decide:'
d, i = FlipGate.decide(0, [{ 'control' => 'c1', 'result' => 'PASS' }])
check(d == :ok && i[:passes] == ['c1'], 'rc=0 + PASS -> :ok')
d, i = FlipGate.decide(1, [{ 'control' => 'c1', 'result' => 'FAIL', 'note' => 'inert' }])
check(d == :fail && i[:fails] == [['c1', 'inert']], 'rc=1 + FAIL -> :fail with note')
d, = FlipGate.decide(1, [])
check(d == :error, 'rc=1 + no FAIL rows -> :error (abort, could not verify)')
d, = FlipGate.decide(2, [{ 'control' => 'c1', 'result' => 'SKIP', 'note' => 'date-range' }])
check(d == :advisory, 'rc=2 (nothing auto-probeable) -> :advisory')
d, = FlipGate.decide(0, [])
check(d == :advisory, 'rc=0 + no PASS rows -> :advisory')
d, = FlipGate.decide(99, nil)
check(d == :error, 'unknown rc / nil results -> :error')

# --- PbiFlip.recorded (offline recorded-evidence path) ------------------------
puts 'PbiFlip.recorded:'
d, i = PbiFlip.recorded([{ 'control' => 'c1', 'result' => 'PASS' }])
check(d == :ok && i[:passes] == ['c1'], 'recorded PASS -> :ok')
d, i = PbiFlip.recorded([{ 'control' => 'c1', 'result' => 'PASS' },
                         { 'control' => 'c2', 'result' => 'FAIL', 'note' => 'inert' }])
check(d == :fail && i[:fails] == [['c2', 'inert']], 'recorded FAIL beats PASS -> :fail')
d, = PbiFlip.recorded([])
check(d == :offline, 'recorded empty -> :offline (UNVERIFIED, do not hard-fail)')
d, = PbiFlip.recorded(nil)
check(d == :offline, 'recorded nil -> :offline')

# --- PbiFlip.outcome (decision -> summary + exit code) ------------------------
puts 'PbiFlip.outcome:'
st, line, ex = PbiFlip.outcome(:ok, { passes: %w[a b], fails: [], skips: [] })
check(st == :ok && ex.nil? && line.include?('2 control'), ':ok -> no exit, counts passes')
st, _, ex = PbiFlip.outcome(:fail, { passes: [], fails: [['c', 'inert']], skips: [] })
check(st == :fail && ex == 21, ':fail -> exit 21 (blocks migration)')
st, _, ex = PbiFlip.outcome(:error, nil)
check(st == :error && ex == 21, ':error -> exit 21 (fail-closed)')
st, _, ex = PbiFlip.outcome(:advisory, { passes: [], fails: [], skips: [['c', 'date']] })
check(st == :advisory && ex.nil?, ':advisory -> WARN, no exit')
st, _, ex = PbiFlip.outcome(:none, nil)
check(st == :none && ex.nil?, ':none (0 controls) -> pass, no exit')
st, _, ex = PbiFlip.outcome(:offline, nil)
check(st == :offline && ex.nil?, ':offline -> UNVERIFIED, no exit (never hard-fail an offline run)')

# --- orchestrator wiring smoke: --skip-control-flip is a known flag -----------
puts 'orchestrator wiring:'
mp = File.join(__dir__, 'migrate-powerbi.rb')
src = File.read(mp)
check(src.include?("--skip-control-flip"), 'migrate-powerbi.rb declares --skip-control-flip')
check(src.include?('control_flip_required'), 'migrate-powerbi.rb stamps control_flip_required into migrate-state.json')
check(src.include?('Phase 6b'), 'migrate-powerbi.rb has a Phase 6b block')
check(src.include?("require_relative 'lib/pbi_flip'"), 'migrate-powerbi.rb loads lib/pbi_flip')

if $failures.zero?
  puts "\ntest-pbi-flip-gate: ALL PASS"
  exit 0
else
  warn "\ntest-pbi-flip-gate: #{$failures} FAILURE(S)"
  exit 1
end
