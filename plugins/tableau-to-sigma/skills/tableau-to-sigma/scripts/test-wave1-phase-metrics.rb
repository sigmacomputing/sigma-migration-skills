#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-phase-metrics.rb — the wave-1 timing hook: every mark() phase
# boundary appends {phase, wall_s, at} to <WORK>/phase-metrics.jsonl via the
# SHARED phase-metrics lib (shared/lib/phase_metrics.rb), guarded on every
# axis so an absent or raising lib is a silent no-op (a metrics write must
# never touch the conversion). Capture is LOCAL — files stay in the workdir and
# are never sent off-box (ratified decision: measure before optimizing).
#
#   T1: a real fixture run appends well-formed per-phase records
#   T2: the guards are wired (lib-absent no-op; raising lib swallowed)
#   T3: the artifact stays out of the repo (gitignored local state)
# Usage: ruby scripts/test-wave1-phase-metrics.rb   (~4s, spawns one real run)

require 'json'
require 'tmpdir'
require_relative 'test-wave1-support'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'T1 — a real run appends {phase, wall_s, at} per mark()'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  _out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "fixture run reached the checkpoint (got #{st.exitstatus})", fails)
  pm = File.join(d, 'phase-metrics.jsonl')
  check(File.exist?(pm), 'phase-metrics.jsonl written in the workdir', fails)
  recs = File.readlines(pm).map { |l| JSON.parse(l) }
  check(recs.size >= 5, "one record per phase boundary (got #{recs.size})", fails)
  check(recs.all? { |r| r['phase'].is_a?(String) && r['wall_s'].is_a?(Numeric) && r['at'].to_s =~ /\A\d{4}-\d\d-\d\dT/ },
        'every record carries {phase, wall_s, at}', fails)
  check(recs.map { |r| r['phase'] }.include?('phase1-foreground'),
        'records use the PHASE_T keys (phase1-foreground present)', fails)
  check(recs.all? { |r| r['turn'].is_a?(Integer) } && recs.map { |r| r['inv'] }.compact.uniq.size == 1,
        'W2.22: every record carries a turn ordinal + one invocation token', fails)
  check(recs.none? { |r| r['phase'].to_s =~ /wave1|fixture/i },
        'no workbook/customer identifiers in phase keys (coarse names only)', fails)
  # The shared lib reads its own file back (integration with lane D's API).
  $LOAD_PATH.unshift File.join(__dir__, 'lib')
  require 'phase_metrics'
  check(PhaseMetrics.entries(d).size == recs.size, 'PhaseMetrics.entries round-trips the file', fails)
end

puts 'T2 — defensive wiring (string-pins: absent lib = no-op, raising lib swallowed)'
src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
check(src =~ /begin\s+require 'phase_metrics'\s+rescue LoadError, StandardError\s+nil\s+end/,
      'guarded require: an absent lib never breaks the orchestrator', fails)
check(src.include?("defined?(PhaseMetrics) && PhaseMetrics.respond_to?(:record) && defined?(WORK)"),
      'call site guards on module presence + API shape', fails)
check(src =~ /PhaseMetrics\.record\(workdir: WORK, phase: key, wall_s: seg, at: now\.utc,\s+turn: \(\$pm_turn = \$pm_turn\.to_i \+ 1\),\s+inv: [^\n]*\)\s+rescue StandardError\s+nil/,
      'a raising lib is swallowed (metrics must never sink a run)', fails)

puts 'T3 — machine-local contract'
gitignore = File.read(File.expand_path('../../../../../.gitignore', __dir__))
check(gitignore.include?('phase-metrics.jsonl'), 'phase-metrics.jsonl is gitignored (never committed)', fails)
check(gitignore.include?('decisions.jsonl') && gitignore.include?('consent-answer.json') &&
      gitignore.include?('migrate-full.log'),
      'the other wave-1 local-state artifacts are gitignored too', fails)

puts
if fails.empty?
  puts 'test-wave1-phase-metrics: ALL PASS'
else
  puts "test-wave1-phase-metrics: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
