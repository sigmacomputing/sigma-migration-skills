#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-factory-punchlist.rb — W2.2 factory default + punch-list renderer.
# The renderer CONSUMES the shipped degradation-ledger.json schema as-is
# (frozen — changes go via lane B); these tests pin both honesty directions:
#
#   T1 trip: a 3-ledger-class fixture emits 3 RUNNABLE re-entry commands
#      (join-plan → probe-join-keys --resolve/--how; coverage → --master-col;
#      waiver → re-run-without-flag), 1:1 with the ledger (report/ledger
#      cross-check, direction 1).
#   T2 INVERSION (the Opus test): a ledger claiming degradations while
#      presenting none — and by construction any non-GREEN verdict with zero
#      items — FAILS (exit 2); a punch list must never understate.
#   T3 no-false-trip: clean run stays GREEN — empty ledger → exit 0, empty
#      list, verdict GREEN, 0 items == 0 entries (cross-check, direction 2).
#   T4 pre-gate render: no ledger file on disk → derive fallback (same
#      schema), stated in the artifact's source field.
#   T5 gate context: non-pass EvidenceLedger rows ride the md as context.
#   T6 wiring pins: finalize renders at EVERY terminal + RESULT line +
#      'punchlist-emitted' off-ramp (items>0 only); --certified restores
#      RCF 5 at BOTH default sites; migration-notes embeds PUNCHLIST.md
#      verbatim; both artifacts gitignored (local-state discipline).
#
# Usage: ruby scripts/test-factory-punchlist.rb   (<10s, no network)

require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative 'lib/factory_punchlist'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

CLI = File.join(__dir__, 'build-punchlist.rb')
def run_cli(d)
  Open3.capture2e(RbConfig.ruby, CLI, '--workdir', d)
end

def ledger!(d, entries, counts: nil)
  counts ||= entries.each_with_object(Hash.new(0)) { |e, h| h[e['class']] += 1 }
  File.write(File.join(d, 'degradation-ledger.json'), JSON.pretty_generate(
               'version' => 1, 'derivedAt' => '2026-01-01T00:00:00Z',
               'counts' => counts, 'entries' => entries))
end

THREE = [
  { 'class' => 'scope-cut', 'item' => 'Region Trend',
    'reason' => 'dropped visual (derived master column missing)', 'source_artifact' => 'coverage.json' },
  { 'class' => 'quality-waiver', 'item' => '--skip-flip-test',
    'reason' => 'waived: flip probe env unavailable', 'source_artifact' => 'parity-final.json (waivers census)' },
  { 'class' => 'resolution-waived', 'item' => 'ORDER_KEY',
    'reason' => 'join-key resolution how=waived', 'source_artifact' => 'join-plan.json' }
].freeze

puts 'T1 — trip: 3 ledger classes → 3 runnable re-entry commands (1:1)'
Dir.mktmpdir do |d|
  ledger!(d, THREE.map(&:dup))
  out, st = run_cli(d)
  check(st.exitstatus.zero?, "renderer exits 0 (got #{st.exitstatus})", fails)
  pl = JSON.parse(File.read(File.join(d, 'punchlist.json')))
  check(pl['items'].size == 3 && pl['items'].size == THREE.size,
        'punchlist items are 1:1 with ledger entries (cross-check, direction 1)', fails)
  check(pl['verdict'] == 'PARTIAL+YELLOW', "verdict derived from entries (got #{pl['verdict']})", fails)
  check(pl['items'].all? { |i| i['reentry'].is_a?(String) && !i['reentry'].empty? },
        'every item carries a non-empty re-entry command', fails)
  by_src = pl['items'].each_with_object({}) { |i, h| h[i['source_artifact']] = i['reentry'] }
  check(by_src['join-plan.json'].to_s.include?('probe-join-keys.rb') &&
        by_src['join-plan.json'].to_s.include?('--resolve') && by_src['join-plan.json'].to_s.include?('--how'),
        'join-plan line → probe-join-keys --resolve/--how command', fails)
  check(by_src['coverage.json'].to_s.include?('--master-col'),
        'coverage scope-cut → --master-col re-entry hint', fails)
  check(by_src['parity-final.json (waivers census)'].to_s.include?('WITHOUT --skip-flip-test'),
        'quality waiver → re-run-without-flag hint', fails)
  md = File.read(File.join(d, 'PUNCHLIST.md'))
  check(md.include?('# PUNCH LIST — PARTIAL+YELLOW') && md.scan(/- \[ \]/).size == 3,
        'PUNCHLIST.md carries the verdict headline + one checkbox per item', fails)
  check(md.include?('--certified'), 'md names the --certified loop-to-green opt-in', fails)
  check(out.include?('3 item(s)'), 'CLI summary names the item count', fails)
end

puts 'T2 — INVERSION: a ledger claiming entries it does not present FAILS'
Dir.mktmpdir do |d|
  ledger!(d, [], counts: { 'scope-cut' => 2 })
  out, st = run_cli(d)
  check(st.exitstatus == 2, "exit 2 on inversion (got #{st.exitstatus})", fails)
  check(out.include?('INVERSION'), 'failure names the inversion', fails)
  check(!File.exist?(File.join(d, 'PUNCHLIST.md')),
        'no understating artifact is written on inversion', fails)
end

puts 'T3 — no-false-trip: the clean run stays GREEN'
Dir.mktmpdir do |d|
  ledger!(d, [])
  out, st = run_cli(d)
  check(st.exitstatus.zero?, "clean ledger renders fine (got #{st.exitstatus})", fails)
  pl = JSON.parse(File.read(File.join(d, 'punchlist.json')))
  check(pl['verdict'] == 'GREEN' && pl['items'].empty?,
        'GREEN + 0 items == 0 entries (cross-check, direction 2)', fails)
  md = File.read(File.join(d, 'PUNCHLIST.md'))
  check(md.include?('GREEN') && md =~ /Empty — the degradation ledger is EMPTY/,
        'md states the empty-ledger doctrine (GREEN requires exactly that)', fails)
  check(out.include?('0 item(s)'), 'CLI summary says 0 items', fails)
end

puts 'T4 — pre-gate render: no ledger file → derive fallback, stated'
Dir.mktmpdir do |d|
  _out, st = run_cli(d)
  check(st.exitstatus.zero?, "derive fallback renders (got #{st.exitstatus})", fails)
  pl = JSON.parse(File.read(File.join(d, 'punchlist.json')))
  check(pl['source'].to_s.include?('derived'), 'artifact names the derive fallback as its source', fails)
end

puts 'T5 — gate context: non-pass evidence rows ride the md'
Dir.mktmpdir do |d|
  ledger!(d, [THREE.first.dup])
  File.write(File.join(d, 'evidence-ledger.jsonl'),
             [{ 'gate' => '8b', 'verdict' => 'fail', 'at' => '2026-01-01T00:00:00Z' },
              { 'gate' => '5', 'verdict' => 'pass', 'at' => '2026-01-01T00:00:01Z' }].map { |r| JSON.generate(r) }.join("\n") + "\n")
  _out, st = run_cli(d)
  check(st.exitstatus.zero?, 'renders with evidence ledger present', fails)
  md = File.read(File.join(d, 'PUNCHLIST.md'))
  check(md.include?('Gate context') && md.include?('8b=fail') && !md.include?('5=pass'),
        'md lists non-pass gate rows only', fails)
end

puts 'T6 — wiring pins (finalize render, RESULT line, off-ramp, --certified, embed, gitignore)'
src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
check(src.include?("run!(['ruby', File.join(HERE, 'build-punchlist.rb'), '--workdir', WORK], allow_fail: true)"),
      'finalize renders the punch list at EVERY terminal (allow_fail — bookkeeping never sinks a run)', fails)
check(src.include?('puts "PUNCH LIST  : #{_pl_note}" if _pl_note'),
      'RESULT block stamps the punch list', fails)
check(src =~ /Offramp\.log\(WORK, kind: 'punchlist-emitted', detail: _pl_note\) if Array\(_pl\['items'\]\)\.any\?/,
      "off-ramp kind 'punchlist-emitted' (lane B vocabulary, verbatim) — only when items exist", fails)
check(src.scan(/opts\[:rcf_passes\] \|\| \(opts\[:certified\] \? 5 : \(\$tier == 'S' \? 1 : 5\)\)/).size == 2,
      '--certified restores RCF 5 at BOTH default sites (factory default stays one pass on Tier-S)', fails)
mn = File.read(File.join(__dir__, 'migration-notes.rb'), encoding: 'UTF-8')
check(mn.include?("File.join(File.dirname(opts[:out]), 'PUNCHLIST.md')") && mn =~ /md << File\.read\(pl_path/,
      'migration-notes embeds PUNCHLIST.md VERBATIM into the report', fails)
gitignore = File.read(File.expand_path('../../../../../.gitignore', __dir__))
check(gitignore.include?('PUNCHLIST.md') && gitignore.include?('punchlist.json'),
      'both punch-list artifacts are gitignored (workdir-local state, same-commit discipline)', fails)

puts
if fails.empty?
  puts 'test-factory-punchlist: ALL PASS'
else
  puts "test-factory-punchlist: #{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
