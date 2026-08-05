#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for ROUTE PERSISTENCE (v4.2, P2).
#
# migrate-state.json records how a workdir was driven
# ('orchestrated' | 'manual-authorized'). A pass-1 re-entry on the OTHER route
# fails closed ("finish it the same way"), with two sanctioned exceptions:
# switching TO manual through the manual-spec admit set (STOP token / explicit
# --reuse-dm id / --allow-manual-spec), and an explicit
# --force-route-switch "<reason>" (recorded to offramps.jsonl and counted as a
# quality waiver by assert-phase6-ran — see test-anchors-waiver-gates.rb).
#
# Hermetic: fresh HOME, creds via env, Tableau gate skipped via the sanctioned
# MCP flag; every asserted stop fires before any network. Cases that proceed
# past the checks are killed by timeout and asserted on message absence only.
#
# Usage: ruby scripts/test-route-persistence.rb

require 'json'
require 'tmpdir'

DIR = __dir__
MT  = File.join(DIR, 'migrate-tableau.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

def run_mt(home, work, args, timeout: 20)
  env = {
    'HOME' => home, 'SIGMA_SKIP_DOCTOR_GATE' => 'test',
    'SIGMA_CLIENT_ID' => 'id-123', 'SIGMA_CLIENT_SECRET' => 'sec-456',
    'SIGMA_API_TOKEN' => nil, 'SIGMA_TABLEAU_VIA_MCP' => '1'
  }
  cmd = ['ruby', MT, '--workbook', 'WB', '--connection', 'c1', '--out', work] + args
  io = IO.popen(env, cmd, err: %i[child out]); pid = io.pid; out = +''
  t = Thread.new { out << io.read.to_s }
  if t.join(timeout).nil?
    Process.kill('KILL', pid) rescue nil
    t.join(2)
  end
  io.close rescue nil
  out
end

ROUTE_MSG = 'finish it the same way'

Dir.mktmpdir do |home|
  # (1) state says manual-authorized; a plain ORCHESTRATED re-entry is refused.
  Dir.mktmpdir do |work|
    File.write(File.join(work, 'migrate-state.json'),
               JSON.generate('workbook_id' => 'wb-1', 'route' => 'manual-authorized'))
    out = run_mt(home, work, [])
    check(out.include?(ROUTE_MSG), 'manual workdir + orchestrated re-entry is refused', fails)
    check(out.include?('--force-route-switch'), 'refusal names the escape flag', fails)
  end

  # (2) --force-route-switch proceeds AND records the off-ramp (waiver-counted).
  Dir.mktmpdir do |work|
    File.write(File.join(work, 'migrate-state.json'),
               JSON.generate('workbook_id' => 'wb-1', 'route' => 'manual-authorized'))
    out = run_mt(home, work, ['--force-route-switch', 'rebuilt mechanically on purpose'])
    check(!out.include?(ROUTE_MSG), '--force-route-switch waives the refusal', fails)
    trail = File.exist?(File.join(work, 'offramps.jsonl')) ?
              File.readlines(File.join(work, 'offramps.jsonl')).map { |l| JSON.parse(l) rescue nil }.compact : []
    check(trail.any? { |r| r['kind'] == 'route-switch-forced' },
          'forced switch recorded to offramps.jsonl (assert-phase6-ran counts it)', fails)
  end

  # (3) orchestrated workdir + manual invocation WITHOUT a STOP on record:
  #     the manual-spec gate refuses first (the route check defers to its admit set).
  Dir.mktmpdir do |work|
    File.write(File.join(work, 'migrate-state.json'),
               JSON.generate('workbook_id' => 'wb-1', 'route' => 'orchestrated'))
    wb = File.join(work, 'wb-spec.json')
    File.write(wb, JSON.generate('pages' => [{ 'id' => 'p', 'elements' => [] }]))
    out = run_mt(home, work, ['--wb-spec', wb])
    check(out.include?('ROUTED fallback, not a cold'), 'cold manual entry still refused by the manual-spec gate', fails)
  end

  # (4) orchestrated workdir + manual invocation WITH the STOP token: sanctioned
  #     handoff — neither the manual gate nor the route check refuses.
  Dir.mktmpdir do |work|
    File.write(File.join(work, 'migrate-state.json'),
               JSON.generate('workbook_id' => 'wb-1', 'route' => 'orchestrated'))
    File.write(File.join(work, 'manual-path-authorized.json'),
               JSON.generate('via' => 'workbook-handoff', 'exit_code' => 4))
    wb = File.join(work, 'wb-spec.json')
    File.write(wb, JSON.generate('pages' => [{ 'id' => 'p', 'elements' => [] }]))
    out = run_mt(home, work, ['--wb-spec', wb, '--reuse-dm', 'dm-live-1'])
    check(!out.include?('ROUTED fallback, not a cold') && !out.include?(ROUTE_MSG),
          'STOP-authorized manual re-entry passes both gates (the designed handoff)', fails)
  end

  # (5) same-route re-entry is never blocked.
  Dir.mktmpdir do |work|
    File.write(File.join(work, 'migrate-state.json'),
               JSON.generate('workbook_id' => 'wb-1', 'route' => 'orchestrated'))
    out = run_mt(home, work, [])
    check(!out.include?(ROUTE_MSG), 'orchestrated → orchestrated re-entry proceeds', fails)
  end
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
