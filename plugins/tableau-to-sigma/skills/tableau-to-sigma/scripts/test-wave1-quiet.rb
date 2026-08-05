#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-quiet.rb — `--quiet` machine stdout (speed review #3 slice,
# refs/performance.md): poll turns re-ingest ~60-line banners; with --quiet,
# STDOUT carries only JSON event lines + WARN/FATAL/error-shaped lines + the
# terminal state JSON, while the full human output streams to
# <WORK>/migrate-full.log. Default output (no flag) stays byte-identical in
# kind: the banners print to stdout as before.
#
#   T1: --quiet stop run    → stdout is machine-shaped; ev:stop + ev:exit
#   T2: --quiet sidecar     → migrate-full.log carries the full banner
#   T3: default (no flag)   → banner ON stdout, no ev: lines, no sidecar
#   T4: quiet events at the wait-gate (ev:wait) + phase marks (ev:mark)
# Usage: ruby scripts/test-wave1-quiet.rb   (~8s, spawns real runs)

require 'json'
require 'tmpdir'
require 'open3'
require_relative 'test-wave1-support'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# STDOUT-only capture (capture3): the quiet contract is about STDOUT — stderr
# (warn) is deliberately untouched.
def run_split(dir, extra, png_wait: '1')
  cmd = [RbConfig.ruby, Wave1Fixture::ORCH, *Wave1Fixture::BASE_ARGS, '--out', dir, *extra]
  Open3.capture3(Wave1Fixture.hermetic_env(dir, png_wait: png_wait), *cmd)
end

# Mirrors QUIET_PASS_RE in migrate-tableau.rb: error shapes + the house
# one-line verdict markers (system()-spawned children write those directly).
PASS_RE = /\A\s*(?:⚠|⛔|✗|WARN\b|FATAL\b|ERROR\b|error:|\[(?:OK|PASS|SKIP|FAIL|WARN)\])/i

puts 'T1 — --quiet: stdout is machine-shaped on a checkpoint stop'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, _err, st = run_split(d, ['--folder', 'fold-x', '--quiet'])
  check(st.exitstatus == 10, "stop still exits 10 under --quiet (got #{st.exitstatus})", fails)
  lines = out.lines.map(&:chomp).reject(&:empty?)
  bad = lines.reject do |l|
    (JSON.parse(l).is_a?(Hash) rescue false) || l =~ PASS_RE
  end
  check(bad.empty?, "every stdout line is a JSON event or an error-shaped line (#{bad.size} stray: #{bad.first.to_s[0, 60].inspect})", fails)
  evs = lines.map { |l| JSON.parse(l) rescue nil }.compact
  check(evs.any? { |e| e['ev'] == 'phase' }, 'phase-entry events emitted', fails)
  check(evs.any? { |e| e['ev'] == 'mark' && e['wall_s'] }, 'phase-completion (mark) events carry wall_s', fails)
  stop = evs.find { |e| e['ev'] == 'stop' }
  check(stop && stop['code'] == 10 && stop['artifact'].to_s.end_with?('open-questions.json'),
        'ev:stop names the code AND the artifact to read once', fails)
  exitev = evs.find { |e| e['ev'] == 'exit' }
  check(exitev && exitev['code'] == 10 && exitev['full_log'].to_s.end_with?('migrate-full.log'),
        'terminal ev:exit carries the code + full-log path', fails)
  check(!out.include?('PRE-BUILD CHECKPOINT ('), 'no banner on stdout under --quiet', fails)
end

puts 'T2 — --quiet: the full human output lands in migrate-full.log'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  run_split(d, ['--folder', 'fold-x', '--quiet'])
  full = File.read(File.join(d, 'migrate-full.log'))
  check(full.include?('PRE-BUILD CHECKPOINT (ONE stop: gaps + decisions + cost)'),
        'checkpoint banner preserved in the sidecar', fails)
  check(full.include?('── Phase 1/6 · Discover ──'), 'phase banners preserved in the sidecar', fails)
  check(full.include?('PHASE TIMINGS'), 'phase-timings summary preserved in the sidecar', fails)
end

puts 'T3 — default (no --quiet): human output unchanged, no machine events'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, _err, st = run_split(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "default stop exit 10 (got #{st.exitstatus})", fails)
  check(out.include?('PRE-BUILD CHECKPOINT (ONE stop: gaps + decisions + cost)'),
        'banner on stdout by default', fails)
  check(out.lines.none? { |l| l.start_with?('{"ev":') }, 'no machine event lines by default', fails)
  check(!File.exist?(File.join(d, 'migrate-full.log')), 'no sidecar log by default', fails)
end

puts 'T4 — quiet events at the wait-gate'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, _err, st = run_split(d, ['--folder', 'fold-x', '--quiet', '--yes'], png_wait: '1')
  check(st.exitstatus == 18, "wait-gate trip still exits 18 under --quiet (got #{st.exitstatus})", fails)
  evs = out.lines.map { |l| JSON.parse(l) rescue nil }.compact
  check(evs.any? { |e| e['ev'] == 'wait' && e['gate'] == 'phase-1d-dashboard-read' },
        'ev:wait announces the gate + timeout for pollers', fails)
  check(evs.any? { |e| e['ev'] == 'stop' && e['code'] == 18 }, 'ev:stop carries exit 18', fails)
end

puts
if fails.empty?
  puts 'test-wave1-quiet: ALL PASS'
else
  puts "test-wave1-quiet: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
