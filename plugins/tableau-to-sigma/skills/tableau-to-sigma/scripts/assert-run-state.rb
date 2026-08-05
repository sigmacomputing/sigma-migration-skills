#!/usr/bin/env ruby
# 🚧 GATE (soft) — audit the per-run phase ledger (run-state.json).
#
# Proves the load-bearing PROCESS chain ran, not just that the output artifacts
# exist. The orchestrator stamps each phase it walks (via hdr()); this asserts
# the always-required chain — discover, dashboard-read, workbook, layout, parity
# — is present, so a silent shortcut (re-run on stale artifacts, dropped phase)
# is caught even when the output files happen to exist. A deliberately skipped
# phase (e.g. Phase 2/3 under DM-reuse) records status "skip" with a reason and
# is NOT flagged. See scripts/lib/run_state.rb.
#
# NO-OP when run-state.json is absent (the hand-driven manual path that never
# ran the orchestrator): reports "not tracked" and exits 0 — like the other
# sidecar-gated checks. Run it as part of the Phase 6 gate sequence.
#
# Usage:
#   ruby scripts/assert-run-state.rb --workdir /tmp/<name>
#     [--skip-run-state REASON]   # waive — REQUIRED reason; name it in your report
#
# Exit codes:
#   0  all required chain phases stamped (or ledger absent / waived)
#   1  ledger present but a required chain phase was never entered
#   2  usage error

require 'json'
require 'optparse'
require_relative 'lib/run_state'

# The phases that run in EVERY conversion mode. Phase 0a (gap scan), 1.6
# (DM-reuse scan), and 2/3 (skipped under reuse) are intentionally NOT required
# here so a legitimate reuse run doesn't false-fail; they still appear in the
# ledger for the report.
REQUIRED = %w[phase-1 phase-1d phase-4 phase-5 phase-6].freeze
LABEL = {
  'phase-1'  => 'discover', 'phase-1d' => 'dashboard-read',
  'phase-4'  => 'workbook', 'phase-5'  => 'layout', 'phase-6' => 'parity'
}.freeze

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:dir] = v }
  p.on('--tableau DIR', 'alias of --workdir') { |v| opts[:dir] = v }
  p.on('--skip-run-state REASON',
       'waive the run-state chain audit — REQUIRED reason string; name it in your migration report') do |v|
    opts[:skip] = v
  end
end.parse!

unless opts[:dir]
  warn '--workdir required'
  exit 2
end

if opts[:skip]
  puts "[SKIP] run-state chain audit WAIVED (#{opts[:skip]}) — name this in your report."
  # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
  begin
    $LOAD_PATH.unshift File.expand_path('lib', __dir__)
    require 'offramp'
    Offramp.log(opts[:dir], kind: 'skip-flag-waived', reason: opts[:skip],
                detail: '--skip-run-state')
  rescue LoadError
    warn '       WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
  end
  exit 0
end

unless RunState.tracked?(opts[:dir])
  puts "[NOTE] run-state ledger absent (#{RunState.path(opts[:dir])}) — chain not tracked."
  puts '       This run did not go through the orchestrator (migrate-tableau.rb); the'
  puts '       output gates (assert-dashboard-read / assert-phase6-ran) still apply.'
  exit 0
end

phases = RunState.load(opts[:dir])['phases']
missing = RunState.missing(opts[:dir], REQUIRED)

# Print the whole chain for the report.
puts 'run-state chain:'
phases.sort.each do |k, v|
  mark = v['status'] == 'skip' ? '⤼ skip' : '✓ done'
  puts "  #{mark}  #{k}#{v['note'] ? " — #{v['note']}" : ''}"
end

if missing.empty?
  puts "[PASS] run-state chain audit: all required phases present (#{REQUIRED.map { |k| LABEL[k] }.join(', ')})."
  exit 0
end

warn "[FAIL] run-state chain audit — required phase(s) never entered: " \
     "#{missing.map { |k| "#{k} (#{LABEL[k]})" }.join(', ')}."
warn '       These phases run in every mode; a missing stamp means the chain took a silent'
warn '       shortcut (e.g. a re-run on stale artifacts, or an edited flow that dropped a phase).'
warn '       Re-run the conversion through scripts/migrate-tableau.rb, or if a phase was'
warn '       deliberately not run, record it: it must be stamped skip with a reason.'
warn '       Escape hatch: --skip-run-state "<reason>" (name it in your report).'
exit 1
