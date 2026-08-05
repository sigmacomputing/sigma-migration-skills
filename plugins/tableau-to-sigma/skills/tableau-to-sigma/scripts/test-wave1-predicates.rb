#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-predicates.rb — unit tests for the wave-1 pure predicates in
# migrate-tableau.rb (extracted from source, test-small-guards.rb pattern):
#
#   finalize_chain_predicate — the STRICT empty-actuals predicate behind the
#     in-process --finalize chain (#2b): trips ONLY when every exportable plan
#     chart is machine-collected, no pivot grids, no agent-mediated markers,
#     no per-tile visual sidecar, AND the agent-side gate obligations are
#     already discharged (visual verdict recorded on parity-final.json unless
#     --fast; staged RCF ledger resolved) — a cold chain was guaranteed
#     NOT-GREEN at gate 8b/8d, burning the gate battery + a loop-log attempt.
#     Anything else keeps exit 12 (no-false-chain).
#   mission_scope_for — E9.6 mission.json scope extraction (names, single-view
#     URL segments, provenance; malformed → error, never a raise).
#   png_read_stale? — the no-stale-seed freshness rule (#2a): a png-read.json
#     older than this run's discovery fetch is stale; no fetch → never stale.
# Usage: ruby scripts/test-wave1-predicates.rb

require 'json'
require 'tmpdir'
require 'fileutils'

DIR = __dir__
SRC = File.read(File.join(DIR, 'migrate-tableau.rb'), encoding: 'UTF-8')
%w[finalize_chain_predicate mission_scope_for png_read_stale?].each do |fn|
  m = SRC.match(/^def #{Regexp.escape(fn).sub('\\?', '\\?')}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def plan(dir, charts)
  File.write(File.join(dir, 'parity-plan.json'), JSON.generate('charts' => charts))
end

def actuals(dir, h)
  File.write(File.join(dir, 'parity-actuals.json'), JSON.generate(h))
end

# Agent-side obligations discharged (re-entry workdir shape): a RECORDED visual
# verdict on parity-final.json (record-visual-check.rb — the file finalize
# writes) + migrate-state.json rcf_passes. rcf: 0 = loop unstaged (gate 8d
# records the named waiver); positive = staged (ledger must exist + resolve).
def discharged(dir, rcf: 0, verdict: 'pass')
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('visual_verdict' => verdict))
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate('rcf_passes' => rcf))
end

def rcf_ledger(dir, entries)
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate('pass' => 1, 'entries' => entries))
end

CHART_A = { 'chart' => 'Alpha Sales', 'sigma_kind' => 'bar-chart', 'sigma_columns' => %w[Region Sales] }.freeze
CHART_B = { 'chart' => 'Beta Trend', 'sigma_kind' => 'line-chart', 'sigma_columns' => %w[Month Sales] }.freeze

puts 'finalize_chain_predicate — TRIP (chain) only on the strict predicate'
Dir.mktmpdir do |d|
  plan(d, [CHART_A, CHART_B])
  actuals(d, 'Alpha Sales' => [['East', 10]], 'Beta Trend' => [['Jan', 5]])
  discharged(d)
  ok, why = finalize_chain_predicate(d)
  check(ok, "all charts machine-collected, obligations discharged → chain (#{why})", fails)
  check(why.include?('2 exportable chart(s) machine-collected'), 'reason names the count', fails)
  check(why.include?('visual verdict recorded'), 'reason names the discharged visual obligation', fails)
end
Dir.mktmpdir do |d| # staged RCF loop, ledger RESOLVED → chain (gate 8d satisfied)
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d, rcf: 5)
  rcf_ledger(d, [{ 'id' => 'f1', 'cls' => 'spec-fixable', 'resolved' => true },
                 { 'id' => 'f2', 'cls' => 'ui-only', 'resolved' => false }])
  ok, why = finalize_chain_predicate(d)
  check(ok, "resolved spec-fixable + unresolved ui-only (never blocks) → chain (#{why})", fails)
end
Dir.mktmpdir do |d| # recorded DIVERGENT verdict IS a recorded comparison (gate 8b accepts)
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d, verdict: 'divergent')
  ok, why = finalize_chain_predicate(d)
  check(ok, "divergent verdict is a RECORDED comparison → chain (#{why})", fails)
end
Dir.mktmpdir do |d| # --fast waives gates 8+8b at --finalize → no visual-verdict leg
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  File.write(File.join(d, 'migrate-state.json'), JSON.generate('rcf_passes' => 0))
  ok, why = finalize_chain_predicate(d, fast: true)
  check(ok && why.include?('waived (--fast)'), "--fast: no verdict required (visual gates waived) → chain (#{why})", fails)
end

puts 'finalize_chain_predicate — NO-FALSE-CHAIN trajectories'
Dir.mktmpdir do |d|
  ok, why = finalize_chain_predicate(d)
  check(!ok && why.include?('no parity-plan.json'), 'no plan → no chain', fails)
end
Dir.mktmpdir do |d|
  plan(d, [CHART_A, { 'chart' => 'Grid', 'sigma_kind' => 'pivot-table', 'sigma_columns' => %w[r c v] }])
  actuals(d, 'Alpha Sales' => [['East', 10]], 'Grid' => [['r', 'c', 1]])
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /pivot grid/, "pivot grid in plan → no chain (#{why})", fails)
end
Dir.mktmpdir do |d|
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => { 'status' => 'render-verify-required', 'reason' => 'pivot 500' })
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /marker/, "render-verify marker → no chain (#{why})", fails)
end
Dir.mktmpdir do |d|
  plan(d, [CHART_A, CHART_B])
  actuals(d, 'Alpha Sales' => [['East', 10]]) # Beta uncollected
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /1 exportable chart\(s\) not machine-collected/, "uncollected chart → no chain (#{why})", fails)
end
Dir.mktmpdir do |d|
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => []) # collected but EMPTY rows — strict: not proof
  ok, why = finalize_chain_predicate(d)
  check(!ok, "empty-row actuals → no chain (#{why})", fails)
end
Dir.mktmpdir do |d|
  plan(d, [{ 'chart' => 'Signal Only', 'sigma_kind' => 'bar-chart', 'sigma_columns' => [] }])
  actuals(d, {})
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /anchors-oracle/, "0 exportable charts (all-embedded) → no chain (#{why})", fails)
end
Dir.mktmpdir do |d|
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  File.write(File.join(d, 'visual-verify-tiles.json'), JSON.generate([{ 'tile' => 'x' }]))
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /per-tile visual/, "visual-verify sidecar → no chain (#{why})", fails)
end
Dir.mktmpdir do |d|
  plan(d, [CHART_A])
  File.write(File.join(d, 'parity-actuals.json'), 'not json {')
  ok, why = finalize_chain_predicate(d)
  check(!ok, "unreadable actuals → no chain (#{why})", fails)
end
# name-keyed plan charts (hand-authored plans key by 'name', not 'chart')
Dir.mktmpdir do |d|
  plan(d, [{ 'name' => 'Alpha Sales', 'sigma_kind' => 'bar-chart', 'sigma_columns' => %w[Region Sales] }])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d)
  ok, why = finalize_chain_predicate(d)
  check(ok, "hand-authored plan keyed by 'name' still matches actuals (#{why})", fails)
end

puts 'finalize_chain_predicate — NO-FALSE-CHAIN: agent-side gate obligations (review finding)'
# THE regression trajectory: a COLD run satisfying the actuals legs must NOT
# chain — parity-final.json does not exist until a finalize ran, so gate 8b
# (recorded verdict) is guaranteed to stop the chained battery at exit 13 and
# burn a loop-log attempt in scope migrate-tableau:finalize.
Dir.mktmpdir do |d|
  plan(d, [CHART_A, CHART_B])
  actuals(d, 'Alpha Sales' => [['East', 10]], 'Beta Trend' => [['Jan', 5]])
  File.write(File.join(d, 'migrate-state.json'), JSON.generate('rcf_passes' => 0))
  ok, why = finalize_chain_predicate(d)
  check(!ok && why.include?('no recorded visual verdict'),
        "COLD run (no parity-final.json) → no chain, gate 8b named (#{why})", fails)
end
Dir.mktmpdir do |d| # not-executable verdict cannot satisfy gate 8b either
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d, verdict: 'not-executable')
  ok, why = finalize_chain_predicate(d)
  check(!ok && why.include?("'not-executable'"), "not-executable verdict → no chain (#{why})", fails)
end
Dir.mktmpdir do |d| # staged loop, no ledger → gate 8d exits 15 on the missing file
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d, rcf: 5)
  ok, why = finalize_chain_predicate(d)
  check(!ok && why.include?('no fidelity-ledger.json'), "staged RCF, missing ledger → no chain (#{why})", fails)
end
Dir.mktmpdir do |d| # LEGACY state without rcf_passes defaults to staged (finalize line: fetch('rcf_passes', 5))
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  File.write(File.join(d, 'parity-final.json'), JSON.generate('visual_verdict' => 'pass'))
  File.write(File.join(d, 'migrate-state.json'), JSON.generate('workbook_id' => 'wb-x'))
  ok, why = finalize_chain_predicate(d)
  check(!ok && why.include?('rcf_passes > 0'),
        "legacy state (no rcf_passes key) defaults to STAGED, ledger required → no chain (#{why})", fails)
end
Dir.mktmpdir do |d| # unresolved spec-fixable delta → gate 8d blocks
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d, rcf: 5)
  rcf_ledger(d, [{ 'id' => 'f1', 'cls' => 'spec-fixable', 'resolved' => false }])
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /1 unresolved spec-fixable\/data/, "unresolved spec-fixable delta → no chain (#{why})", fails)
end
Dir.mktmpdir do |d| # data-class blocks whenever a ledger EXISTS — even with the loop unstaged
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d, rcf: 0)
  rcf_ledger(d, [{ 'id' => 'd1', 'cls' => 'data', 'resolved' => false }])
  ok, why = finalize_chain_predicate(d)
  check(!ok && why =~ /unresolved spec-fixable\/data/,
        "unresolved data-class delta blocks even at rcf_passes 0 (#{why})", fails)
end
Dir.mktmpdir do |d| # malformed ledger → gate 8d exits 15 on the parse
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  discharged(d, rcf: 0)
  File.write(File.join(d, 'fidelity-ledger.json'), 'not json {')
  ok, why = finalize_chain_predicate(d)
  check(!ok && why.include?('unreadable fidelity-ledger.json'), "malformed ledger → no chain (#{why})", fails)
end
Dir.mktmpdir do |d| # --fast waives the VISUAL leg only — gate 8d still applies
  plan(d, [CHART_A])
  actuals(d, 'Alpha Sales' => [['East', 10]])
  File.write(File.join(d, 'migrate-state.json'), JSON.generate('rcf_passes' => 5))
  ok, why = finalize_chain_predicate(d, fast: true)
  check(!ok && why.include?('no fidelity-ledger.json'),
        "--fast does not waive gate 8d — staged loop still needs its ledger (#{why})", fails)
end

puts 'mission_scope_for — E9.6 scope extraction'
Dir.mktmpdir do |d|
  check(mission_scope_for(d).nil?, 'no mission.json → nil (unscoped unchanged)', fails)
  File.write(File.join(d, 'mission.json'), JSON.generate(
               'scope' => { 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                            'dashboards' => ['Beta Detail'] }))
  ms = mission_scope_for(d)
  check(ms['names'] == ['Beta Detail'] && ms['provenance'] == 'stated',
        'stated dashboards extracted with provenance', fails)

  File.write(File.join(d, 'mission.json'), JSON.generate(
               'scope' => { 'value' => ['https://t.example/#/site/s/views/Wave1Fixture/BetaDetail?:iid=1'],
                            'provenance' => 'stated' }))
  ms = mission_scope_for(d)
  check(ms['view_segments'] == ['BetaDetail'] && ms['names'] == [],
        'single-view /#/views/ URL yields the view segment', fails)

  File.write(File.join(d, 'mission.json'), JSON.generate(
               'scope' => { 'value' => ['Some Workbook'], 'provenance' => 'inferred' }))
  check(mission_scope_for(d).nil?, 'workbook-only scope (no dashboards/URL) → nil', fails)

  File.write(File.join(d, 'mission.json'), JSON.generate(
               'scope' => { 'dashboard' => 'Alpha Overview', 'provenance' => 'inferred' }))
  ms = mission_scope_for(d)
  check(ms['names'] == ['Alpha Overview'] && ms['provenance'] == 'inferred',
        'inferred provenance is REPORTED (caller refuses to apply it)', fails)

  File.write(File.join(d, 'mission.json'), 'not json {')
  ms = mission_scope_for(d)
  check(ms.is_a?(Hash) && ms['error'], 'malformed mission.json → error record, never a raise', fails)
end

puts 'png_read_stale? — no-stale-seed freshness'
Dir.mktmpdir do |d|
  png = File.join(d, 'png-read.json')
  File.write(png, '{}')
  old = Time.now - 3600
  File.utime(old, old, png)
  check(png_read_stale?(png, Time.now - 60), 'file older than this run\'s fetch → STALE', fails)
  check(!png_read_stale?(png, nil), 'no fetch this run (stamp-reused discovery) → never stale', fails)
  File.utime(Time.now, Time.now, png)
  check(!png_read_stale?(png, Time.now - 60), 'file written after the fetch started → fresh', fails)
  check(!png_read_stale?(File.join(d, 'absent.json'), Time.now), 'absent file → not stale (absence handled elsewhere)', fails)
end

puts 'stale set-aside is wired at the gate (string-pins)'
check(SRC.include?("png-read.stale".sub('png-read.stale', '.stale.json')) || SRC.include?('.stale.json'),
      'gate renames a stale read to png-read.stale.json (never silently consumed, never destroyed)', fails)
check(SRC.include?("kind: 'png-read-stale'"), 'stale set-aside is offramp-recorded', fails)
check(SRC.include?("kind: 'png-wait-timeout'"), 'wait-gate deadline is offramp-recorded', fails)
check(SRC =~ /SIGMA_PNG_READ_TIMEOUT_S.*480/, 'wait bound defaults to 480s and is env-overridable', fails)

puts 'finalize chain is wired at the pass-1 tail (string-pins)'
check(SRC =~ /_chain_ok && ENV\['SIGMA_NO_CHAIN_FINALIZE'\]\.to_s\.empty\?/,
      'chain gated on the strict predicate AND the escape hatch', fails)
check(SRC =~ /exec\(RbConfig\.ruby, __FILE__,\s*\*\(ORIGINAL_ARGV \+ \['--finalize', '--actuals'/,
      'chain execs SELF with --finalize --actuals (same invocation, same pid)', fails)
check(SRC.include?("kind: 'finalize-chained'"), 'the chain is offramp-recorded', fails)
check(SRC =~ /rescue SystemCallError.*falling back to exit 12/m,
      'a failed exec falls back to the unchanged exit-12 contract', fails)
check(SRC.index('_chain_ok, _chain_why = finalize_chain_predicate(WORK, fast: !!opts[:fast])').to_i >
      SRC.index('exit 16'),
      'chain point sits AFTER the exit-16 stop and forwards --fast (the only visual-gate waiver honored)', fails)

puts
if fails.empty?
  puts 'test-wave1-predicates: ALL PASS'
else
  puts "test-wave1-predicates: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
