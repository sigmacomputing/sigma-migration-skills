#!/usr/bin/env ruby
# Offline test for the run-state phase ledger (scripts/lib/run_state.rb) +
# the assert-run-state.rb chain audit. Deterministic, no network.
#
# Usage: ruby scripts/test-run-state.rb

require 'json'
require 'tmpdir'
require_relative 'lib/run_state'

DIR    = __dir__
ASSERT = File.join(DIR, 'assert-run-state.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  # 1. Absent ledger → auditor is a NO-OP (exit 0, "not tracked").
  out = IO.popen(['ruby', ASSERT, '--workdir', d], err: %i[child out], &:read); st = $?.exitstatus
  check(st == 0 && out.include?('not tracked'), "absent ledger → NO-OP exit 0 (got #{st})", fails)

  # 2. Stamp the full required chain → audit PASS.
  %w[phase-1 phase-1d phase-4 phase-5 phase-6].each { |p| RunState.stamp(d, p, note: 'x') }
  check(RunState.tracked?(d), 'stamping created run-state.json', fails)
  check(File.exist?(RunState.path(d)), 'run-state.json exists', fails)
  out = IO.popen(['ruby', ASSERT, '--workdir', d], err: %i[child out], &:read); st = $?.exitstatus
  check(st == 0 && out.include?('all required phases present'), "full chain → PASS exit 0 (got #{st})", fails)

  # 3. Merge semantics: re-stamp updates, doesn't duplicate.
  RunState.stamp(d, 'phase-1', note: 'again')
  doc = JSON.parse(File.read(RunState.path(d)))
  check(doc['phases']['phase-1']['note'] == 'again', 're-stamp updates in place (merge)', fails)
  check(doc['phases'].keys.length == 5, 'no duplicate phase keys after re-stamp', fails)
end

Dir.mktmpdir do |d|
  # 4. Missing a required phase (layout dropped) → audit FAIL exit 1, names it.
  %w[phase-1 phase-1d phase-4 phase-6].each { |p| RunState.stamp(d, p) }   # no phase-5
  out = IO.popen(['ruby', ASSERT, '--workdir', d], err: %i[child out], &:read); st = $?.exitstatus
  check(st == 1 && out.include?('phase-5') && out.downcase.include?('layout'),
        "missing required phase → FAIL exit 1 naming phase-5/layout (got #{st})", fails)

  # 5. A deliberately SKIPPED conditional phase is not a silent omission.
  RunState.skip(d, 'phase-2', 'reused DM abc123')
  doc = JSON.parse(File.read(RunState.path(d)))
  check(doc['phases']['phase-2']['status'] == 'skip', 'skip() records status=skip + reason', fails)
  # phase-2 isn't in REQUIRED, but the point is skip is distinguishable from absent:
  check(RunState.missing(d, %w[phase-2]).empty?, 'an explicitly-skipped phase is NOT "missing"', fails)
  check(!RunState.missing(d, %w[phase-5]).empty?, 'an absent phase IS "missing"', fails)
end

Dir.mktmpdir do |d|
  # 6. Waiver.
  RunState.stamp(d, 'phase-1')   # incomplete chain
  out = IO.popen(['ruby', ASSERT, '--workdir', d, '--skip-run-state', 'unit-test'], err: %i[child out], &:read); st = $?.exitstatus
  check(st == 0 && out.include?('WAIVED'), "--skip-run-state waives (exit 0) (got #{st})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS — run-state ledger + chain audit behave correctly'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
