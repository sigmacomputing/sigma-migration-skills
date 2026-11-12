#!/usr/bin/env ruby
# frozen_string_literal: true

# Live-proof regression: the exit-4 loop breaker tripped "same failure, no
# progress" after 2 re-entries although the operator CHANGED the spec between
# them. The attempt identity now carries the input spec digest: an identical
# error on an edited spec is a new attempt; an identical error on the same
# spec is still a repeat.

require 'tmpdir'
require_relative 'lib/offramp'
require_relative 'lib/attempt_fingerprint'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

REGION = ['[FAIL] ref gate: 3 reference(s) unresolved: Cohort Year'].freeze

def attempt(work, spec)
  ctx = AttemptFingerprint.context('exit4', AttemptFingerprint.input_specs(wb_spec_opt: spec, dm_spec_opt: nil,
                                                                           generated_wb_spec: nil))
  key = { handoff: 4, child: 1 }
  mode = Offramp.failure_mode(script: 'migrate-tableau', context: ctx, exit_code: key,
                              error_class: 'WorkbookBuildError', error_region: REGION)
  sig = Offramp.failure_signature(script: 'migrate-tableau', context: ctx, exit_code: key,
                                  error_class: 'WorkbookBuildError', error_line: REGION.first, error_region: REGION)
  [Offramp.loop_check(work, signature: sig, mode: mode, measure: Offramp.region_measure(REGION),
                                scope: 'migrate-tableau:exit4'), sig]
end

Dir.mktmpdir do |work|
  spec = File.join(work, 'wb-spec-edit.json')
  File.write(spec, '{"elements":[{"id":"a"}]}')
  v1, s1 = attempt(work, spec)
  ok(v1 == :first, "first failure is :first (got #{v1.inspect})")
  ok(s1.include?(':spec='), "signature carries the spec digest (#{s1})")
  File.write(spec, '{"elements":[{"id":"a"},{"id":"helper"}]}')
  v2, s2 = attempt(work, spec)
  ok(v2 == :first, "same error after the spec CHANGED is a new attempt, not a loop stop (got #{v2.inspect})")
  ok(s1 != s2, 'different spec → different signature')
  v3, = attempt(work, spec)
  ok(v3 != :first, "same error on the SAME spec still trips the breaker (got #{v3.inspect})")
end

ok(AttemptFingerprint.context('exit4', []) == 'exit4', 'no readable spec → context unchanged')
Dir.mktmpdir do |d|
  a = File.join(d, 'wb.json')
  b = File.join(d, 'dm.json')
  File.write(a, 'x')
  File.write(b, 'y')
  ok(AttemptFingerprint.input_specs(wb_spec_opt: a, dm_spec_opt: b, generated_wb_spec: 'gen') == [a, b],
     'operator --wb-spec/--dm-spec are the input when given')
  ok(AttemptFingerprint.input_specs(wb_spec_opt: nil, dm_spec_opt: nil, generated_wb_spec: a) == [a],
     'generated spec is the input on the mechanical path')
  d1 = AttemptFingerprint.digest([a, b])
  File.write(b, 'z')
  ok(d1 != AttemptFingerprint.digest([a, b]), 'a DM spec edit changes the digest too')
end

puts 'finalize: agent progress between attempts is a new attempt (live re-proof finding 6)'
def finalize_attempt(work, actuals)
  ctx = AttemptFingerprint.finalize_context(work, actuals: actuals)
  key = { phase6: 0, gate: 25, report: 1 }
  sig = Offramp.failure_signature(script: 'migrate-tableau', context: ctx, exit_code: key,
                                  error_line: '[FAIL] gate 18', error_region: ['[FAIL] gate 18: 2 tile(s) unverified'])
  [Offramp.loop_check(work, signature: sig, scope: 'migrate-tableau:finalize'), ctx]
end
Dir.mktmpdir do |work|
  act = File.join(work, 'parity-actuals.json')
  File.write(act, '{"A":[[1]]}')
  File.write(File.join(work, 'source-anchors.json'), '{"anchors":[{"id":"a1","raw":"1"}]}')
  File.write(File.join(work, 'lod-audit.json'), '{"entries":[{"calc":"X","status":"unresolved"}]}')
  v1, c1 = finalize_attempt(work, act)
  ok(v1 == :first && c1.start_with?('finalize:inputs='), "first finalize (#{c1})")
  # finalize itself rewrites its own artifacts — not progress
  File.write(File.join(work, 'parity-final.json'), '{"status":"FAIL","ran_at":"later"}')
  File.write(File.join(work, 'numeric-parity.json'), '{"verified_at":"later"}')
  ok(AttemptFingerprint.finalize_context(work, actuals: act) == c1, 'artifacts the finalize rewrites do not change the attempt identity')
  # the agent adds anchors between attempts → a new attempt, not grinding
  File.write(File.join(work, 'source-anchors.json'), '{"anchors":[{"id":"a1","raw":"1"},{"id":"a13","raw":"17.2%"}]}')
  v2, c2 = finalize_attempt(work, act)
  ok(v2 == :first && c2 != c1, "anchors added between identical-status finalizes → new attempt (#{v2.inspect})")
  # a recorded LOD resolution is progress too
  File.write(File.join(work, 'lod-audit.json'), '{"entries":[{"calc":"X","status":"unresolved","resolution":{"how":"waived"}}]}')
  v3, = finalize_attempt(work, act)
  ok(v3 == :first, 'a recorded ledger resolution is progress')
  v4, = finalize_attempt(work, act)
  ok(v4 != :first, "the SAME inputs and the same failure still trip the breaker (#{v4.inspect})")
end

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
