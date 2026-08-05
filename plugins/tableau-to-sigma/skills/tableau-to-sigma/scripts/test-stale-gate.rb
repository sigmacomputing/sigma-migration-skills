#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the Step-0 STALENESS HARD GATE (PR-2 field-ops).
#
# The doctor stamps {behind_count, days_since_commit} into doctor.json; the
# orchestrator now REFUSES to start on a stale checkout (behind upstream, or
# >14 days old) instead of warning past it — unless SIGMA_ALLOW_STALE names a
# reason, in which case the waiver is recorded as a 'stale-skill-waived'
# off-ramp. Drives migrate-tableau.rb to (or past) the gate offline: the run
# is invoked as --finalize with dummy Sigma creds, so the very next stop after
# the gate is the deterministic "--actuals required" abort — reaching it
# proves the gate let the run proceed. Offline.
#
# GATE-ORDER contract (post main-merge): the staleness gate runs BEFORE the
# bootstrap-sentinel environment gate. Cases 1-2 therefore fixture NO
# bootstrap.json — a stale checkout must refuse with the STALE remediation
# even on a never-bootstrapped machine (the sentinel gate's "run bootstrap"
# advice would just bless a stale build). Cases 3-4 fixture a workdir
# bootstrap.json sentinel (a bootstrapped machine) so the proceed-path also
# exercises main's PR-15 sentinel semantics in assert-doctor-ran.rb without
# depending on ~/.sigma-migration state.
#
# Usage: ruby scripts/test-stale-gate.rb

require 'json'
require 'tmpdir'

DIR = __dir__
MIG = File.join(DIR, 'migrate-tableau.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

def doctor_json(behind:, days:)
  { 'os' => 'macos', 'shell' => 'bash',
    'runtimes' => { 'ruby' => true, 'python' => true, 'node' => true, 'bash' => true },
    'versions' => { 'ruby' => '3.0.0', 'python' => 'Python 3.11', 'node' => 'v20' },
    'sandbox_hint' => 'none', 'cred_smoke' => { 'sigma' => 'skipped', 'tableau' => 'skipped' },
    'hyperapi_present' => false, 'skill_sha' => 'abc1234',
    'behind_count' => behind, 'days_since_commit' => days,
    'agent_vision' => true, 'model_hint' => '', 'generated_at' => '2026-07-18T00:00:00Z',
    'pass' => true, 'failures' => [] }
end

# Run the orchestrator against WD (which carries a doctor.json fixture) with
# dummy creds; --finalize makes "--actuals required" the first post-gate stop.
def run_gate(wd, extra_env = {})
  env = { 'SIGMA_CLIENT_ID' => 'test-id', 'SIGMA_CLIENT_SECRET' => 'test-cred-value',
          'SIGMA_ALLOW_STALE' => nil }.merge(extra_env)
  out = IO.popen(env, ['ruby', MIG, '--workbook-id', 'wb-test', '--out', wd, '--finalize'],
                 err: %i[child out], &:read)
  [$?.exitstatus, out]
end

# (1) stale (behind upstream) + no waiver => refuses with the fix named.
# Deliberately NO bootstrap.json: staleness must fire before the sentinel gate.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'doctor.json'), JSON.generate(doctor_json(behind: 3, days: 2)))
  code, out = run_gate(wd)
  check(code != 0, "stale (behind) refuses to proceed (exit #{code})", fails)
  check(out.include?('FATAL: stale skill checkout'), 'refusal is a clear FATAL naming staleness', fails)
  check(out.include?('git pull') && out.include?('reinstall'), 'refusal names the fix (git pull / reinstall)', fails)
  check(!out.include?('--actuals required'), 'run never got past the gate', fails)
  check(!File.exist?(File.join(wd, 'offramps.jsonl')), 'a refusal records no waiver off-ramp', fails)
end

# (2) stale (>14 days old, not behind) + no waiver => also refuses.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'doctor.json'), JSON.generate(doctor_json(behind: 0, days: 30)))
  code, out = run_gate(wd)
  check(code != 0 && out.include?('FATAL: stale skill checkout'),
        "stale (>14 days) refuses to proceed (exit #{code})", fails)
  check(out.include?('30 days old'), 'refusal names the build age', fails)
end

# (3) stale + SIGMA_ALLOW_STALE => proceeds AND records the off-ramp.
# Workdir sentinel = bootstrapped machine, so the run clears the environment
# gate after the waiver and reaches the next deterministic stop.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'doctor.json'), JSON.generate(doctor_json(behind: 3, days: 2)))
  File.write(File.join(wd, 'bootstrap.json'), JSON.generate('doctor_pass' => true))
  code, out = run_gate(wd, 'SIGMA_ALLOW_STALE' => 'test-waiver')
  check(out.include?('--actuals required'), 'waived run proceeds past the gate (reaches the next stop)', fails)
  check(!out.include?('FATAL: stale skill checkout'), 'no stale FATAL when waived', fails)
  trail = File.readlines(File.join(wd, 'offramps.jsonl')).map { |l| JSON.parse(l) } rescue []
  rec = trail.find { |r| r['kind'] == 'stale-skill-waived' }
  check(!rec.nil?, 'waiver recorded as a stale-skill-waived off-ramp', fails)
  check(rec && rec['reason'] == 'test-waiver', 'off-ramp carries the waiver reason', fails)
  _ = code
end

# (4) fresh checkout (bootstrapped) => proceeds, no off-ramp.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'doctor.json'), JSON.generate(doctor_json(behind: 0, days: 1)))
  File.write(File.join(wd, 'bootstrap.json'), JSON.generate('doctor_pass' => true))
  _, out = run_gate(wd)
  check(out.include?('--actuals required'), 'fresh checkout proceeds past the gate', fails)
  check(!File.exist?(File.join(wd, 'offramps.jsonl')), 'fresh run records no waiver off-ramp', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
