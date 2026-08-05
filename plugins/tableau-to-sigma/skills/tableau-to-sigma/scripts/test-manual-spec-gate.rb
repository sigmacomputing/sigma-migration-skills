#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the manual-spec authorization gate (2026-07-09, P1).
#
# Hand-authored --dm-spec/--wb-spec must be a ROUTED fallback, not a cold entry
# point (cold hand-authoring is the #1 way a run skips the converter + gated
# spine). migrate-tableau.rb accepts them only when: an orchestrator STOP emitted
# <WORK>/manual-path-authorized.json, OR --reuse-dm carries an explicit id, OR
# --allow-manual-spec "<reason>" is passed. Otherwise it refuses and routes back
# to the one command.
#
# Drives migrate-tableau.rb with a fresh HOME + client creds present (so it clears
# the step-0 cred gate) and asserts the manual-spec gate's behavior. The gate
# aborts before any network, so cases are fast; a timeout guards the authorized
# cases that proceed toward work.
#
# Usage: ruby scripts/test-manual-spec-gate.rb

require 'json'
require 'tmpdir'

DIR = __dir__
MT  = File.join(DIR, 'migrate-tableau.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

def run(mt, home, work, args, extra_env = {}, timeout: 20)
  env = {
    'HOME' => home, 'SIGMA_SKIP_DOCTOR_GATE' => 'test',
    'SIGMA_CLIENT_ID' => 'id-123', 'SIGMA_CLIENT_SECRET' => 'sec-456',
    'SIGMA_API_TOKEN' => nil,
    # Hermetic: the step-0 TABLEAU cred gate sits before the manual-spec gate;
    # without this the test only passes on machines that export TABLEAU_PAT_*.
    'SIGMA_TABLEAU_VIA_MCP' => '1'
  }.merge(extra_env)
  cmd = ['ruby', mt, '--workbook', 'WB', '--connection', 'c1', '--out', work] + args
  io = IO.popen(env, cmd, err: %i[child out]); pid = io.pid; out = +''
  t = Thread.new { out << io.read.to_s }
  if t.join(timeout).nil?
    Process.kill('KILL', pid) rescue nil; t.join(2)
  end
  Process.wait(pid) rescue nil
  io.close rescue nil
  out
end

Dir.mktmpdir do |home|
  # a minimal valid wb-spec so the gate is what's under test (not a missing file)
  Dir.mktmpdir do |work|
    wb = File.join(work, 'wb-spec.json')
    File.write(wb, JSON.generate('pages' => [{ 'id' => 'p', 'elements' => [] }]))

    # (1) COLD --wb-spec (no token, no reuse-dm, no waiver) => refused + routed.
    out = run(MT, home, work, ['--wb-spec', wb])
    check(out.include?('ROUTED fallback, not a cold'), 'cold hand-author is refused', fails)
    check(out.include?('migrate-tableau.rb --workbook'), 'refusal routes back to the one command', fails)

    # (2) --allow-manual-spec waiver => NOT refused on manual-spec grounds.
    out = run(MT, home, work, ['--wb-spec', wb, '--allow-manual-spec', 'intentional'])
    check(!out.include?('ROUTED fallback, not a cold'), '--allow-manual-spec waives the gate', fails)

    # (3) orchestrator STOP token present => NOT refused.
    File.write(File.join(work, 'manual-path-authorized.json'), JSON.generate('via' => 'converter-stop'))
    out = run(MT, home, work, ['--wb-spec', wb])
    check(!out.include?('ROUTED fallback, not a cold'), 'manual-path-authorized.json admits the path', fails)
    File.delete(File.join(work, 'manual-path-authorized.json'))

    # (4) explicit --reuse-dm <id> (fast-path re-entry) => NOT refused.
    out = run(MT, home, work, ['--wb-spec', wb, '--reuse-dm', 'dm-abc123'])
    check(!out.include?('ROUTED fallback, not a cold'), 'explicit --reuse-dm id admits the path', fails)
  end
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
