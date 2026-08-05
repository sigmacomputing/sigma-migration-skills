#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-wait-gate.rb — the Phase-1d dashboard-read WAIT-GATE at the
# DM-POST barrier (#2a): the orchestrator polls for a verified png-read.json
# (bounded, SIGMA_PNG_READ_TIMEOUT_S) instead of the old guaranteed abort;
# the deadline is a distinct exit (18) + a banner naming what is missing; a
# stale seed is never silently reused. Six-trajectory matrix over the REAL
# orchestrator, fully offline (test-wave1-support.rb).
#
#   T1 trip:  no verified read at the deadline → exit 18, named banner
#   T2 clear: verified read already present    → gate passes, no wait
#   T3 clear: read verified MID-WAIT           → continues in-process
#   T4 clear: --skip-dashboard-read waiver     → recorded skip, no wait
#   T5 contract: timeout 0 = fail-fast contract for headless callers
#   T6 contract: FAST-PATH skip + freshness rule stay wired (string-pins;
#      the stale mtime unit lives in test-wave1-predicates.rb)
# Usage: ruby scripts/test-wave1-wait-gate.rb   (~20s, spawns real runs)

require 'json'
require 'tmpdir'
require_relative 'test-wave1-support'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'T1 — deadline passes with an unverified draft → exit 18'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'], {}, png_wait: '1')
  check(st.exitstatus == 18, "distinct exit 18 (got #{st.exitstatus})", fails)
  check(out.include?('DASHBOARD-READ WAIT-GATE TIMEOUT (exit 18)'), 'timeout banner printed', fails)
  check(out.include?('still missing: png-read.json is present but not verified'),
        'banner NAMES what is missing (unverified draft)', fails)
  check(out.include?('[WAIT] Phase 1d source dashboard-read gate'),
        'wait announcement replaces the old [FAIL] abort', fails)
  # Review finding (headless regression): the env hint must be on line ONE of
  # the wait announcement — a headless caller with no driving agent otherwise
  # blocks the full default bound before learning the fail-fast switch.
  wait_line = out.lines.find { |l| l.include?('[WAIT] Phase 1d') }
  check(wait_line && wait_line.include?('SIGMA_PNG_READ_TIMEOUT_S') &&
        wait_line.include?('0 = fail-fast exit 18'),
        'FIRST wait line names the override + the 0=fail-fast headless contract', fails)
  check(out.include?('re-run this exact command: discovery is cached'),
        'banner names the cheap re-entry', fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  check(offr.any? { |r| r['kind'] == 'png-wait-timeout' }, 'png-wait-timeout offramp recorded', fails)
  check(File.exist?(File.join(d, 'png-read.json')) &&
        JSON.parse(File.read(File.join(d, 'png-read.json')))['verified'] == false,
        'the seeded DRAFT survives for the operator to edit', fails)
  # A4 (wave-1 review): with NO downloaded PNG on disk, step 1 stays the MCP
  # fetch — that is the fallback branch (the preferred branch is T1b below).
  check(out.include?('1. Fetch the dashboard view PNG with mcp__tableau__get-view-image'),
        'A4 fallback: no on-disk PNG → step 1 is still the MCP fetch', fails)
end

puts 'T1b — A4: discovery already downloaded the dashboard PNG → banner points at the FILE'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  FileUtils.mkdir_p(File.join(d, 'dashboards'))
  File.binwrite(File.join(d, 'dashboards', 'Alpha_Overview.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 200))
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'], {}, png_wait: '1')
  check(st.exitstatus == 18, "gate still trips without a verified read (got #{st.exitstatus})", fails)
  check(out.include?('already downloaded by the discovery lane'),
        'A4: step 1 points at the on-disk PNG instead of a fresh MCP fetch', fails)
  check(out.include?(File.join(d, 'dashboards', 'Alpha_Overview.png')),
        'A4: the exact local path is named', fails)
  check(!out.match?(/^\s+1\. Fetch the dashboard view PNG/),
        'A4: the solo MCP fetch is no longer step 1 when the bytes are local', fails)
  check(out.include?('Fallback: fetch it with') && out.include?('mcp__tableau__get-view-image'),
        'A4: the MCP fetch survives as the named fallback', fails)
end

puts 'T2 — verified read already on disk → gate passes without waiting'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  Wave1Fixture.verified_png_read(d)
  t0 = Time.now
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'], {}, png_wait: '300')
  check(st.exitstatus != 18, "no false trip (got #{st.exitstatus})", fails)
  check(Time.now - t0 < 60, 'no wait paid when the read is already verified', fails)
  check(out.include?('dashboard-read gate: 2 tile(s) verified (png-read.json)'),
        'gate pass line printed', fails)
  check(!out.include?('[WAIT] Phase 1d'), 'no wait banner on a satisfied gate', fails)
  check(out.include?('Phase 3/6 · Build data model'), 'run proceeded to the DM-POST phase', fails)
end

puts 'T3 — read verified MID-WAIT → the same invocation continues'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  writer = Thread.new do
    sleep 4 # let the run reach the gate and start waiting
    Wave1Fixture.verified_png_read(d)
  end
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'], {}, png_wait: '90')
  writer.join
  check(st.exitstatus != 18, "no trip when the read lands mid-wait (got #{st.exitstatus})", fails)
  check(out.include?('dashboard-read verified MID-WAIT — continuing in-process'),
        'mid-wait pickup line printed (no re-invocation paid)', fails)
  check(out.include?('Phase 3/6 · Build data model'), 'run proceeded to Phase 3 in the SAME invocation', fails)
end

puts 'T4 — --skip-dashboard-read waiver: recorded, no wait, no trip'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes',
                                 '--skip-dashboard-read', 'no PNG access in test'], {}, png_wait: '300')
  check(st.exitstatus != 18, "waiver never trips the gate (got #{st.exitstatus})", fails)
  check(out.include?('dashboard-read gate WAIVED'), 'waiver line printed', fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  check(offr.any? { |r| r['kind'] == 'skip-flag-waived' && r['detail'] == '--skip-dashboard-read' },
        'waiver recorded on the off-ramp trail (never silent)', fails)
end

puts 'T5 — SIGMA_PNG_READ_TIMEOUT_S=0 keeps a fail-fast contract'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  t0 = Time.now
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'], {}, png_wait: '0')
  check(st.exitstatus == 18, "timeout 0 → immediate exit 18 (got #{st.exitstatus})", fails)
  check(Time.now - t0 < 30, 'no wait paid at timeout 0 (headless fail-fast)', fails)
  check(out.include?('Waited 0s at the DM-POST barrier'), 'banner still names the contract', fails)
  check(out.include?('SIGMA_PNG_READ_TIMEOUT_S=0 so this gate fails fast'),
        'timeout banner tells headless/CI callers about the fail-fast switch', fails)
end

puts 'T6 — routing + freshness stay wired (string-pins)'
src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
check(src.include?("line 'dashboard-read gate: SKIPPED (FAST PATH"),
      'FAST-PATH skip branch unchanged (recorded, never silent)', fails)
check(src =~ /_dr_fetch_started = .*lane\[:reused\].*lane\[:started\]/,
      'freshness bound derives from THIS run\'s fetch start (reuse ⇒ no bound)', fails)
check(src.include?('_dr_set_aside_stale.call # a stale file copied in mid-wait is refused too'),
      'mid-wait stale copies are re-checked inside the poll loop', fails)
check(src =~ /while Time\.now < _dr_deadline/ && src =~ /sleep 2/,
      'the wait is a bounded 2s poll loop, not an unbounded spin', fails)

puts
if fails.empty?
  puts 'test-wave1-wait-gate: ALL PASS'
else
  puts "test-wave1-wait-gate: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
