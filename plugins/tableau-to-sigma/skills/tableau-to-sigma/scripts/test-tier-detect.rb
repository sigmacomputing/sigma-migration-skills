#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-tier-detect.rb — W2.1 tier ratchet (orchestrator half) + W2.4 Tier-S
# checkpoint auto-defaults. Six-trajectory coverage under the house ≤5%
# false-trip budget; the predicate is MECHANICAL (Tier.detect — pure function
# over on-disk artifacts), so the mis-tier budget is proven by the exhaustive
# feature-flip matrix (T1), not sampling: every predicate feature flips S→M in
# isolation, both boundaries stay S, and every unreadable input fails CLOSED
# to 'full'.
#
#   T1 unit matrix (pure, no spawns): base S; each feature flip → M; boundary
#      8-zones/2-controls stay S; missing/corrupt inputs → full (fail-closed);
#      cross-lane fixture pin (shared/lib/testdata/wave2-tier-state.json)
#      whenever lane B's vocabulary commit is present on the branch.
#   T2 trip (real orchestrator, offline): Tier-S fixture, INTERACTIVE run →
#      no checkpoint stop (proceeds to the 1d wait-gate, exit 18); the 1-line
#      notice; decisions.jsonl carries kind 'unattended-tier-default' with
#      decided_by 'unattended-flag'; migrate-state.json {tier:'S',
#      tier_basis:'auto-predicate'} (contract-4 strings).
#   T3 no-false-trip: default (M-shaped) fixture, same invocation → the
#      checkpoint stop is PRESERVED (exit 10), no auto-default line, state
#      records tier M.
#   T4 gap trajectory: one ❌-unhandled gap → tier M + the gap stop (exit 11)
#      preserved.
#   T5 waiver/override: --tier full on the S-shaped fixture → basis
#      'operator-override', 'tier-override' decision ledgered, ratchet OFF
#      (stop preserved).
#   T6 wiring pins: both rcf_passes default sites carry the Tier-S 5→1 flip;
#      0c write + RESULT stamp present; W2.10/W2.21 X1 wiring pins ride here
#      (lane D's suggested gate-argv pin + lane F's fence pin).
#
# Usage: ruby scripts/test-tier-detect.rb   (~60s, spawns offline fixture runs)

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'test-wave1-support'
require_relative 'lib/tier'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Synthetic 0c workdir for the pure matrix. Content zones = zones minus
# container/spacer/title (structural scaffolding never counts toward ≤8).
def tier_fixture(dir, dashboards: 1, charts: 3, controls: 2, pivots: 0,
                 containers: 4, extracts: false, unhandled: 0)
  dl = (1..dashboards).map do |i|
    zones = []
    charts.times { |c| zones << { 'id' => "c#{c}", 'kind' => 'chart', 'chart_kind' => 'bar', 'caption' => "Chart #{c}" } }
    pivots.times { |p| zones << { 'id' => "p#{p}", 'kind' => 'chart', 'chart_kind' => 'pivot-table', 'caption' => "Pivot #{p}" } }
    controls.times { |k| zones << { 'id' => "f#{k}", 'kind' => k.even? ? 'filter' : 'parameter', 'caption' => "Control #{k}" } }
    containers.times { |t| zones << { 'id' => "t#{t}", 'kind' => %w[container spacer title][t % 3] } }
    { 'dashboard' => "Dash #{i}", 'zones' => zones }
  end
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.pretty_generate(dl))
  File.write(File.join(dir, 'get-workbook.json'), JSON.pretty_generate(
               'workbook' => { 'name' => 'Tier Fixture', 'hasExtracts' => extracts }))
  feats = (1..unhandled).map { |i| { 'name' => "Unhandled Feature #{i}", 'status' => 'unhandled' } }
  feats << { 'name' => 'Handled Feature', 'status' => 'handled' }
  File.write(File.join(dir, 'tier-fixture-gaps-report.json'), JSON.pretty_generate('detected_features' => feats))
  dir
end

puts 'T1 — pure predicate matrix (every feature flips the tier; fail-closed on unreadable inputs)'
Dir.mktmpdir do |root|
  mk = lambda do |name, **kw|
    d = File.join(root, name)
    FileUtils.mkdir_p(d)
    tier_fixture(d, **kw)
    Tier.detect(d)
  end
  base = mk.call('base') # 1 dash, 3 charts + 2 controls = 5 content zones, scaffolding ignored
  check(base['tier'] == 'S' && base['tier_basis'] == 'auto-predicate' && base['reasons'].empty?,
        "base S-shaped workdir → S/auto-predicate (got #{base['tier']}/#{base['tier_basis']})", fails)
  check(base['features']['zones'] == 5 && base['features']['controls'] == 2,
        'structural zones (container/spacer/title) never count toward the ≤8', fails)
  boundary = mk.call('boundary', charts: 6, controls: 2) # 6+2 = exactly 8 zones, exactly 2 controls
  check(boundary['tier'] == 'S', 'boundary 8 zones / 2 controls stays S', fails)
  {
     'two dashboards → M'   => mk.call('d2', dashboards: 2),
    '9 content zones → M'  => mk.call('z9', charts: 7, controls: 2),
    '3 controls → M'       => mk.call('c3', controls: 3),
    '1 pivot tile → M'     => mk.call('p1', pivots: 1),
    'extracts → M'         => mk.call('ex', extracts: true),
    '1 ❌-unhandled class → M' => mk.call('gap', unhandled: 1)
  }.each do |why, det|
    check(det['tier'] == 'M' && det['tier_basis'] == 'auto-predicate' && det['reasons'].any?,
          "#{why} (reasons: #{det['reasons'].join('; ')[0, 60]})", fails)
  end
  # fail-closed: missing + corrupt inputs
  d_missing = File.join(root, 'missing'); FileUtils.mkdir_p(d_missing)
  det = Tier.detect(d_missing)
  check(det['tier'] == 'full' && det['tier_basis'] == 'fail-closed',
        'empty workdir → full battery, basis fail-closed', fails)
  d_bad = File.join(root, 'bad'); FileUtils.mkdir_p(d_bad)
  tier_fixture(d_bad)
  File.write(File.join(d_bad, 'dashboard-layout.json'), '{ not json')
  det = Tier.detect(d_bad)
  check(det['tier'] == 'full' && det['tier_basis'] == 'fail-closed' &&
        det['reasons'].join.include?('dashboard-layout.json'),
        'corrupt dashboard-layout.json → full, the unreadable input NAMED', fails)
  d_nogap = File.join(root, 'nogap'); FileUtils.mkdir_p(d_nogap)
  tier_fixture(d_nogap)
  FileUtils.rm(Dir[File.join(d_nogap, '*gaps*report*.json')])
  det = Tier.detect(d_nogap)
  check(det['tier'] == 'full' && det['tier_basis'] == 'fail-closed',
        'missing gap report → full (never guess S/M from partial evidence)', fails)
end

puts 'T1b — cross-lane contract fixture (lane B strings, contract 4)'
_fix = File.expand_path('../../../../../shared/lib/testdata/wave2-tier-state.json', __dir__)
if File.exist?(_fix)
  fx = JSON.parse(File.read(_fix))
  check([Tier::TIER_S, Tier::TIER_M, Tier::TIER_FULL].include?(fx['tier']),
        "fixture 'tier' value is in the closed set (got #{fx['tier'].inspect})", fails)
  check([Tier::BASIS_AUTO, Tier::BASIS_OVERRIDE, Tier::BASIS_CLOSED].include?(fx['tier_basis']),
        "fixture 'tier_basis' value is in the closed set (got #{fx['tier_basis'].inspect})", fails)
else
  puts '  NOTE  shared/lib/testdata/wave2-tier-state.json absent on this branch (lands with lane B) — pin skipped'
end

# S-shape the wave-1 fixture: single dashboard (drop 'Beta Detail' from the
# .twb so parse-twb-layout sees ONE dashboard), extracts off, no gaps.
def s_shape!(dir)
  twb = File.join(dir, 'workbook-content.twb')
  File.write(twb, File.read(twb).sub(%r{<dashboard name='Beta Detail'>.*?</dashboard>\s*}m, ''))
end

puts 'T2 — TRIP: Tier-S + clean → checkpoint auto-defaults, no stop (W2.4)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, has_extracts: false)
  s_shape!(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x']) # INTERACTIVE: no --yes/--answers
  check(st.exitstatus == 18, "no checkpoint stop — run reaches the 1d wait-gate (exit 18, got #{st.exitstatus})", fails)
  check(out.include?('tier: S (auto-predicate'), 'tier line names S/auto-predicate', fails)
  check(out.include?('TIER-S auto-defaults:') && out.scan(/TIER-S auto-defaults:/).size == 1,
        'the ONE-line auto-default notice printed', fails)
  ms = JSON.parse(File.read(File.join(d, 'migrate-state.json')))
  check(ms['tier'] == 'S' && ms['tier_basis'] == 'auto-predicate',
        'migrate-state.json carries the contract-4 strings {tier:S, tier_basis:auto-predicate}', fails)
  decs = File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) }
  tdefs = decs.select { |r| r['kind'] == 'unattended-tier-default' }
  check(tdefs.size >= 2 && tdefs.all? { |r| r['decided_by'] == 'unattended-flag' },
        "every auto-answer ledgered as unattended-tier-default/unattended-flag (got #{tdefs.size})", fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  check(offr.any? { |r| r['kind'] == 'tier-assigned' && r['detail'].to_s.include?('tier=S') },
        'tier-assigned off-ramp recorded with the resolved tier', fails)
  check(!File.exist?(File.join(d, 'open-questions.json')),
        'no checkpoint stop artifact written (run never stopped)', fails)
end

puts 'T3 — NO-FALSE-TRIP: M-shaped fixture → the checkpoint stop is preserved'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d) # default: 2 dashboards + extracts → M
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "interactive M run still stops at the checkpoint (exit 10, got #{st.exitstatus})", fails)
  check(out.include?('tier: M (auto-predicate'), 'tier line names M with reasons', fails)
  check(!out.include?('TIER-S auto-defaults:'), 'no auto-default notice on a Tier-M run', fails)
  ms = JSON.parse(File.read(File.join(d, 'migrate-state.json')))
  check(ms['tier'] == 'M', 'migrate-state.json records tier M (written at 0c, before the stop)', fails)
  decs = (File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) } rescue [])
  check(decs.none? { |r| r['kind'] == 'unattended-tier-default' },
        'no unattended-tier-default lines on a stopping run', fails)
end

puts 'T4 — one ❌-unhandled gap → tier M + the gap stop (exit 11) preserved'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, has_extracts: false,
                        gaps: [{ 'name' => 'Unhandled Fixture Feature', 'status' => 'unhandled',
                                 'count' => 1, 'blurb' => 'fixture ❌ class', 'worksheets' => ['Alpha Sales'] }])
  s_shape!(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 11, "gap review stop preserved (exit 11, got #{st.exitstatus})", fails)
  check(out.include?('tier: M (auto-predicate') && out =~ /unhandled gap class/,
        'the gap class flipped the tier to M (named reason)', fails)
  check(!out.include?('TIER-S auto-defaults:'), 'auto-defaults never fire over a gap stop', fails)
end

puts 'T5 — operator override: --tier full is a ledgered decision, ratchet OFF'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, has_extracts: false)
  s_shape!(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--tier', 'full'])
  check(st.exitstatus == 10, "override kills the S ratchet — stop preserved (exit 10, got #{st.exitstatus})", fails)
  check(out.include?('tier: full (operator-override'), 'tier line names the override basis', fails)
  ms = JSON.parse(File.read(File.join(d, 'migrate-state.json')))
  check(ms['tier'] == 'full' && ms['tier_basis'] == 'operator-override',
        'state carries {tier:full, tier_basis:operator-override}', fails)
  decs = File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) }
  check(decs.any? { |r| r['kind'] == 'tier-override' && r['answer'] == 'full' &&
                        %w[relayed unattended-flag].include?(r['decided_by']) },
        'tier-override decision ledgered with a closed-vocabulary decided_by', fails)
end

puts 'T6 — wiring pins (string-level: rcf flip sites, 0c write, X1 riders)'
src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
check(src.scan(/opts\[:rcf_passes\] \|\| \(opts\[:certified\] \? 5 : \(\$tier == 'S' \? 1 : 5\)\)/).size == 2,
      'BOTH rcf_passes default sites carry the Tier-S 5→1 flip with the --certified restore (0 stays the 8d-waiver contract)', fails)
check(src.include?("_ms.merge('tier' => $tier, 'tier_basis' => $tier_basis)"),
      '0c persists tier/tier_basis into migrate-state.json (merge, not clobber)', fails)
check(src.include?("puts \"TIER        : \#{$tier}"), 'RESULT block stamps the tier', fails)
check(src =~ /questions\.all\? \{ \|q\| q\['severity'\] != 'required' && !q\['default'\]\.nil\? \}/,
      'W2.4 auto-defaults require review-severity + non-nil default (required Qs still stop)', fails)
# X1 pins riding this suite (lane D's suggested gate-argv pin + lane F's fence pin):
check(src.include?("gate += ['--skip-anchors-gate', opts[:skip_anchors_gate]] if opts[:skip_anchors_gate]"),
      'W2.10: --skip-anchors-gate rides the finalize gate argv', fails)
check(src.include?("(opts[:dashboards] || []).each { |d| disc += ['--dashboard', d] }"),
      'W2.20: --dashboard scope threaded into the discovery lane argv', fails)
check(src.include?('pkill -TERM -P'),
      'W2.21: lane-timeout fence kills the wedged lane tree before the abort', fails)

puts
if fails.empty?
  puts 'test-tier-detect: ALL PASS'
else
  puts "test-tier-detect: #{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
