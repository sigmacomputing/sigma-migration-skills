#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test for phase_metrics.rb (reconciled ADD-6 — local capture, never
# sends). Run: ruby shared/lib/test_phase_metrics.rb
#
# Proves: require-safe standalone (stdlib only); record appends one JSON line
# per call and never raises (bad workdir → false, run unbroken); entries skips
# torn lines; aggregate sums wall/tokens per phase and keeps tokens nil when
# never measured; summarize prints the per-phase table + TOTAL and returns the
# aggregate. Also pins the LOCAL-ONLY contract: recording touches nothing but
# <WORK>/phase-metrics.jsonl.

require 'json'
require 'tmpdir'
require 'stringio'
require_relative 'phase_metrics'

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "  [ok] #{desc}" : "  [FAIL] #{desc}")
  $failures += 1 unless ok
end

check('require-safe standalone: no repo siblings loaded') do
  # stdlib only — a stray require of a repo sibling (e.g. sigma_rest) would show up here.
  $LOADED_FEATURES.none? { |f| f =~ /sigma_rest/ }
end

Dir.mktmpdir do |wd|
  check('record appends and returns true') do
    PhaseMetrics.record(workdir: wd, phase: 'discover', wall_s: 61.7, tokens: 120_000) &&
      File.exist?(File.join(wd, 'phase-metrics.jsonl'))
  end

  check('record without tokens omits the key (nil ≠ 0)') do
    PhaseMetrics.record(workdir: wd, phase: 'dm-build', wall_s: 10.25)
    last = JSON.parse(File.readlines(File.join(wd, 'phase-metrics.jsonl')).last)
    last['phase'] == 'dm-build' && last['wall_s'] == 10.25 && !last.key?('tokens')
  end

  check('second record for a phase accumulates') do
    PhaseMetrics.record(workdir: wd, phase: 'discover', wall_s: 38.3, tokens: 80_000)
    a = PhaseMetrics.aggregate(wd)['discover']
    a['n'] == 2 && a['wall_s'] == 100.0 && a['tokens'] == 200_000 && a['wall_s_mean'] == 50.0
  end

  check('phase with no token measurements aggregates tokens as nil') do
    PhaseMetrics.aggregate(wd)['dm-build']['tokens'].nil?
  end

  check('entries returns oldest-first parsed records') do
    e = PhaseMetrics.entries(wd)
    e.size == 3 && e.first['phase'] == 'discover' && e.first['wall_s'] == 61.7 &&
      e.all? { |r| r['at'] =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/ }
  end

  check('torn/malformed lines are skipped, not fatal') do
    File.open(File.join(wd, 'phase-metrics.jsonl'), 'a') { |f| f.print('{"phase":"tor') } # no newline, torn
    PhaseMetrics.entries(wd).size == 3
  end

  check('summarize prints per-phase rows + TOTAL and returns the aggregate') do
    io = StringIO.new
    agg = PhaseMetrics.summarize(wd, io: io)
    out = io.string
    agg.key?('discover') &&
      out =~ /^discover\s+2\s+100\.0\s+50\.0\s+200000$/ &&
      out =~ /^dm-build\s+1\s+10\.2\s+10\.2\s+-$/ &&
      out =~ /^TOTAL\s+3\s+110\.2\s+\s*200000$/
  end

  check('LOCAL-ONLY: the workdir gained exactly one metrics file') do
    Dir.children(wd) == ['phase-metrics.jsonl']
  end
end

check('record on a missing workdir → false, never raises') do
  PhaseMetrics.record(workdir: '/nonexistent/nowhere', phase: 'x', wall_s: 1) == false
end

check('record with a blank phase → false (no junk lines)') do
  Dir.mktmpdir do |wd|
    PhaseMetrics.record(workdir: wd, phase: '  ', wall_s: 1) == false &&
      !File.exist?(File.join(wd, 'phase-metrics.jsonl'))
  end
end

check('summarize on an empty workdir prints the no-records line, returns {}') do
  Dir.mktmpdir do |wd|
    io = StringIO.new
    PhaseMetrics.summarize(wd, io: io) == {} && io.string.include?('no records')
  end
end

# ── W2.22 turn/invocation capture ──────────────────────────────────────────

check('invocation_token is numbers-only and stable within the process') do
  t1 = PhaseMetrics.invocation_token
  t2 = PhaseMetrics.invocation_token
  t1 == t2 && t1 =~ /\A\d+-\d+\z/
end

Dir.mktmpdir do |wd|
  check('record with turn/inv writes both keys; without them the old shape is unchanged') do
    PhaseMetrics.record(workdir: wd, phase: 'discover', wall_s: 30.0, turn: 1, inv: '11-1000')
    PhaseMetrics.record(workdir: wd, phase: 'dm-build', wall_s: 30.0, turn: 2, inv: '11-1000',
                        tokens: 9_000)
    PhaseMetrics.record(workdir: wd, phase: 'finalize', wall_s: 60.0, turn: 1, inv: '22-2000')
    PhaseMetrics.record(workdir: wd, phase: 'legacy', wall_s: 5.0) # wave-1 shape
    recs = File.readlines(File.join(wd, 'phase-metrics.jsonl')).map { |l| JSON.parse(l) }
    recs[0]['turn'] == 1 && recs[0]['inv'] == '11-1000' &&
      !recs[3].key?('turn') && !recs[3].key?('inv')
  end

  check('run_stats derives turn_events / invocations / re_entries / walls / tokens') do
    s = PhaseMetrics.run_stats(wd)
    s['records'] == 4 && s['turn_events'] == 3 && s['invocations'] == 2 &&
      s['re_entries'] == 1 && s['wall_s_total'] == 125.0 && s['tokens_total'] == 9_000 &&
      s['span_s'].is_a?(Numeric) && s['span_s'] >= 0
  end

  check('summarize table shape is unchanged by turn/inv keys (no new columns)') do
    io = StringIO.new
    PhaseMetrics.summarize(wd, io: io)
    header = io.string.lines.first.to_s
    header.split.sort == %w[phase n wall_s mean_s tokens].sort
  end
end

check('run_stats on a pre-turn-capture file: turn_events/invocations/re_entries nil, never 0') do
  Dir.mktmpdir do |wd|
    PhaseMetrics.record(workdir: wd, phase: 'discover', wall_s: 10.0)
    PhaseMetrics.record(workdir: wd, phase: 'dm-build', wall_s: 20.0)
    s = PhaseMetrics.run_stats(wd)
    s['turn_events'].nil? && s['invocations'].nil? && s['re_entries'].nil? &&
      s['wall_s_total'] == 30.0 && s['tokens_total'].nil?
  end
end

check('run_stats on an empty workdir is all-nil/zero, never raises') do
  Dir.mktmpdir do |wd|
    s = PhaseMetrics.run_stats(wd)
    s['records'].zero? && s['turn_events'].nil? && s['wall_s_total'].zero? && s['span_s'].nil?
  end
end

puts $failures.zero? ? "\nall phase_metrics tests passed" : "\n#{$failures} FAILED"
exit($failures.zero? ? 0 : 1)
