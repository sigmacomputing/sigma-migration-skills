#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the SINGLE offline "are we actually done?" check.
#
# The migration is a two-pass design: PASS 1 (migrate-tableau.rb) ends at exit 12
# with parity + the hard-gate suite still PENDING; only PASS 2 (--finalize) runs
# assert-phase6-ran.rb, whose exit 0 is the one legitimate GREEN. A low-context
# agent can mistake a clean PASS-1 (DM + workbook POSTed, HTTP 200s) for "done"
# and stop before the gates ever fire. This script makes "done" a fact on disk,
# not a narration:
#
#   * PASS 1 writes   <workdir>/parity-pending.json  and clears the success marker
#   * assert-phase6-ran.rb (at --finalize, exit 0) writes <workdir>/phase6-success.json
#     and clears the pending marker
#
# So the ONLY state that reports DONE here is: success marker present, no pending
# marker. The SKILL's definition of done is "verify-complete.rb exits 0" —
# nothing else counts. It is fully offline; run it before claiming completion
# or handing off.
#
# VERDICT + LEDGER CROSS-CHECK (PLAN-v3 PR-14): DONE is not the same as GREEN.
# This script RE-DERIVES the degradation ledger from the workdir's artifacts
# (lib/degradation_ledger.rb — scope cuts, quality waivers, recorded escapes,
# fidelity residuals, waived resolutions; deterministic, never self-reported),
# prints the verdict (GREEN / YELLOW / PARTIAL / PARTIAL+YELLOW) with every
# ledger entry inline, and FAILS (exit 6) when the run's own reports contradict
# the derivation — a phase6-success.json / parity-final.json claiming a verdict
# or waiver census the artifacts don't support, or a degradation-ledger.json
# that no longer matches a fresh derivation. This is the anti-"GREEN, 0
# waivers" mechanism: a report can no longer claim clean over a workdir whose
# artifacts recorded scope cuts or escapes.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — phase6-success.json present (and matches --workbook-id if given);
#      the derived verdict + ledger are printed (GREEN only on an empty ledger)
#   2  NOT DONE — the hard gate never stamped success (finalize not run / failed)
#   3  NOT DONE — still at PASS 1 (parity-pending.json present); run --finalize
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked
#   5  NOT DONE — loop-log.jsonl shows a tripped loop breaker since the last
#      green reset: the SAME failure signature 2+ times (stop-at-2 tripped/was
#      breached) or a record the breaker stamped as a hard stop (same-mode
#      no-progress / attempt-cap rules stop WITHOUT a signature repeat); an
#      operator must resolve it
#   6  REPORT CONTRADICTS LEDGER — a completion claim (phase6-success.json /
#      parity-final.json / degradation-ledger.json) is inconsistent with the
#      ledger derived fresh from the artifacts; the report is lying about the
#      run's degradations. Fix the report (or the tampered artifact), never
#      the ledger.

require 'json'
require 'optparse'
require_relative 'lib/offramp'
require_relative 'lib/degradation_ledger'

# Print the off-ramp trail + any gate waivers for this workdir — the "where did
# this run leave the golden path" readout. Advisory; shown under every verdict.
def print_offramps(wd)
  trail = Offramp.trail(wd)
  waivers = begin
    JSON.parse(File.read(File.join(wd, 'waivers.json')))
  rescue StandardError
    nil
  end
  wv = waivers.is_a?(Array) ? waivers : (waivers.is_a?(Hash) ? (waivers['waivers'] || []) : [])
  return if trail.empty? && wv.empty?
  warn ''
  warn "   off-ramps taken this run (#{trail.size} logged, #{wv.size} gate waiver(s)) — where it left the golden path:"
  trail.each { |r| warn "     • #{r['kind']}#{r['reason'] ? " — #{r['reason']}" : ''}#{r['detail'] ? " (#{r['detail']})" : ''}" }
  warn "     • #{wv.size} assert-phase6-ran gate waiver(s) — see waivers.json" unless wv.empty?
end

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--workbook-id ID') { |v| opts[:wb] = v }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

wd       = opts[:wd]
pending  = File.join(wd, 'parity-pending.json')
success  = File.join(wd, 'phase6-success.json')

def load(path)
  JSON.parse(File.read(path))
rescue StandardError
  {}
end

if File.exist?(pending)
  pj = load(pending)
  warn '⛔ NOT DONE — still at PASS 1 (parity + hard gates have not run).'
  warn "   workbook: #{pj['workbookId'] || '?'}   stage: #{pj['stage'] || '?'}"
  warn '   Collect parity actuals, then run the --finalize command PASS 1 printed,'
  warn '   which runs assert-phase6-ran.rb (the only path to GREEN).'
  print_offramps(wd)
  exit 3
end

# Loop-log enforcement (stop-at-2, PLAN E5.1: refusal threshold 2+ in the same
# PR as the breaker): a signature recorded 2+ times since the last green reset
# means the run ground the same failure in a loop — completion can never be
# claimed over it, success marker or not. ALSO refuse over any record the
# breaker itself stamped as a hard stop: the mode-no-progress and attempt-cap
# rules stop a run while every signature is still at a 1-count, so the count
# threshold alone would let a hard-STOPPED run falsely report DONE. Both
# windows are post-reset (loop_counts / loop_stops only see entries after the
# last {'reset'} record), so a GREEN finalize re-arms this refusal
# automatically; otherwise the operator resolves the failure, then clears the log.
looped = Offramp.loop_counts(wd).select { |_, n| n >= 2 }
stops  = Offramp.loop_stops(wd)
unless looped.empty? && stops.empty?
  warn '⛔ NOT DONE — loop-log.jsonl records a tripped loop breaker (repeat / no-progress / attempt-cap):'
  looped.each { |sig, n| warn "   • #{sig}  × #{n}" }
  stops.reject { |r| looped.key?(r['signature']) }
       .each { |r| warn "   • hard STOP (#{r['stop_rule'] || 'stop'}) at #{r['at']}: #{r['signature']}" }
  warn '   The run was grinding, not converging — an operator must resolve it.'
  warn "   (After resolving, clear #{File.join(wd, 'loop-log.jsonl')} and re-run the gates;"
  warn '    a GREEN finalize also re-arms the breaker automatically.)'
  print_offramps(wd)
  exit 5
end

unless File.exist?(success)
  warn '⛔ NOT DONE — no phase6-success.json in the workdir.'
  warn '   The hard-gate suite (assert-phase6-ran.rb) has not passed for this run.'
  warn "   Run PASS 1, then --finalize. Workdir checked: #{wd}"
  print_offramps(wd)
  exit 2
end

sj = load(success)
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  warn '   You are likely looking at a stale workdir or the wrong run.'
  exit 4
end

# ---------------------------------------------------------------------------
# PR-14 — re-derive the degradation ledger and cross-check every completion
# claim against it. Derivation is mechanical (artifacts only), so any claim it
# contradicts is a report lying about the run. Absent claims (legacy markers
# with no verdict key) are not failures — the derived verdict is printed for
# them; an EXPLICIT contradicting claim is exit 6.
# ---------------------------------------------------------------------------
deg_entries = DegradationLedger.derive(wd)
derived_verdict = DegradationLedger.verdict(deg_entries)
pf = load(File.join(wd, 'parity-final.json'))
contradictions = []

# W2.3 — the labeled factory verdict. On a Tier-S factory run (migrate-state
# tier 'S', lane A) that ends GREEN with verdict_by 'builder-self-attested',
# the ONLY honest verdict string is the labeled one — the gate never mints a
# bare 'GREEN' there, so a bare claim means the label was stripped after the
# fact. Conversely the label without that basis is a claim the artifacts do
# not support. Vocabulary: Offramp::FACTORY_VERDICT_SUFFIX / VERDICT_BY.
run_tier = begin
  JSON.parse(File.read(File.join(wd, 'migrate-state.json')))['tier'].to_s
rescue StandardError
  nil
end
# The countersignature is RE-DERIVED from the evidence on disk, never trusted
# from the markers — the gate's own two evidence forms (orchestration.md O3):
# a verifier-recorded final pass in parity-final.json (visual_verdict 'pass' +
# 'VERIFIER:'-prefixed visual_notes), or a parseable verification-result.json
# carrying the verifier's final verdict (GREEN/YELLOW/RED — the
# verifier-brief.md deliverable). A marker claiming verdict_by 'verifier' with
# neither on disk is attestation laundering: a two-field edit (verdict +
# verdict_by) would otherwise slip past the label check, which only catches
# the one-field strip.
countersign_evidence = pf['visual_verdict'].to_s == 'pass' &&
                       pf['visual_notes'].to_s.start_with?('VERIFIER:')
unless countersign_evidence
  _vr = begin
    JSON.parse(File.read(File.join(wd, 'verification-result.json')))
  rescue StandardError
    nil
  end
  countersign_evidence = _vr.is_a?(Hash) && %w[GREEN YELLOW RED].include?(_vr['verdict'].to_s)
end
factory_green = derived_verdict == 'GREEN' && run_tier == 'S' &&
                pf['verdict_by'].to_s == Offramp::VERDICT_BY_BUILDER
expected_verdict = factory_green ? "GREEN#{Offramp::FACTORY_VERDICT_SUFFIX}" : derived_verdict

# Internal census arithmetic: waiver_count must equal the census it counts.
if pf.key?('waiver_count') && pf['waivers'].is_a?(Array) &&
   pf['waiver_count'].to_i != pf['waivers'].length
  contradictions << "parity-final.json claims waiver_count=#{pf['waiver_count']} but its own census lists #{pf['waivers'].length} waiver(s)"
end
# The success marker's census must match parity-final's (both are stamped by
# the gate on the same run; drift means one was edited after the fact).
if sj['waivers'].is_a?(Array) && pf['waivers'].is_a?(Array) && sj['waivers'] != pf['waivers']
  contradictions << "phase6-success.json waiver census (#{sj['waivers'].length}) differs from parity-final.json (#{pf['waivers'].length})"
end
# Claimed verdicts must match the derivation — INCLUDING the factory label:
# a Tier-S self-attested GREEN claim must carry the suffix (the bare string
# is the exact laundering W2.3 forbids), and the suffix without the factory
# basis is equally a lie.
{ 'phase6-success.json' => sj['verdict'], 'parity-final.json' => pf['verdict'] }.each do |src, claim|
  next if claim.to_s.empty?
  next if claim.to_s == expected_verdict
  contradictions << if factory_green && claim.to_s == derived_verdict
                      "#{src} claims the BARE string #{claim} but this is a Tier-S factory self-attested run — " \
                      "the labeled verdict #{expected_verdict.inspect} is mandatory (never launder the label off)"
                    elsif !factory_green && claim.to_s == "#{derived_verdict}#{Offramp::FACTORY_VERDICT_SUFFIX}"
                      "#{src} claims the factory label #{claim.inspect} without a Tier-S self-attested basis " \
                      "(tier=#{run_tier.inspect}, verdict_by=#{pf['verdict_by'].inspect})"
                    else
                      "#{src} claims verdict #{claim} but the artifacts derive #{expected_verdict}"
                    end
end
# A 'verifier' attestation claim is only as good as the countersignature
# evidence behind it (re-derived above) — without evidence the claim is the
# exact laundering the label check alone cannot see.
{ 'phase6-success.json' => sj['verdict_by'], 'parity-final.json' => pf['verdict_by'] }.each do |src, claim|
  next unless claim.to_s == Offramp::VERDICT_BY_VERIFIER
  next if countersign_evidence
  contradictions << "#{src} claims verdict_by #{Offramp::VERDICT_BY_VERIFIER.inspect} but the workdir holds no " \
                    'countersignature evidence (no VERIFIER:-prefixed visual pass in parity-final.json, no valid ' \
                    'verification-result.json) — attestation laundering'
end
# A zero-waiver claim over a ledger that records waivers/escapes is the exact
# field lie this closes ("GREEN, 0 waivers" after --skip-ref-check).
if pf.key?('waiver_count') && pf['waiver_count'].to_i.zero? &&
   deg_entries.any? { |e| %w[quality-waiver recorded-escape].include?(e['class']) }
  contradictions << 'parity-final.json claims 0 waivers but the artifacts record waiver/escape degradations'
end
# A stored ledger that drifted from a fresh derivation was edited by hand.
stored = begin
  JSON.parse(File.read(DegradationLedger.ledger_path(wd)))
rescue StandardError
  nil
end
if stored.is_a?(Hash) && stored['entries'].is_a?(Array) && stored['entries'] != deg_entries
  contradictions << "degradation-ledger.json on disk (#{stored['entries'].length} entr#{stored['entries'].length == 1 ? 'y' : 'ies'}) does not match a fresh derivation (#{deg_entries.length}) — the ledger was edited, not re-derived"
end

if contradictions.any?
  warn '⛔ REPORT CONTRADICTS LEDGER — completion claims are inconsistent with the degradations'
  warn '   derived from this workdir\'s artifacts (the ledger is mechanical; the claims are not):'
  contradictions.each { |c| warn "   • #{c}" }
  warn "   Derived verdict: #{derived_verdict} — ledger (#{deg_entries.length} entr#{deg_entries.length == 1 ? 'y' : 'ies'}):"
  DegradationLedger.report_lines(deg_entries).each { |l| warn "   #{l}" }
  warn '   Re-run assert-phase6-ran.rb to re-stamp honest claims. Never edit the ledger or the'
  warn '   markers by hand — fix the underlying artifacts (or the report) instead.'
  exit 6
end

puts "✅ DONE — assert-phase6-ran.rb passed all gates for this run. VERDICT: #{expected_verdict}"
if factory_green
  puts '   attested : builder-self-attested (Tier-S factory — the label above is part of the verdict'
  puts '              string; quote it verbatim. A verifier countersignature + gate re-run yields bare GREEN.)'
elsif !pf['verdict_by'].to_s.empty?
  puts "   attested : #{pf['verdict_by']}"
end
puts "   workbook : #{sj['workbookId']}"
puts "   gates    : #{sj['gates']}"
puts "   run id   : #{sj['run_id']}" if sj['run_id']
puts "   waivers  : #{sj['waivers'].join(', ')}" if sj['waivers'].is_a?(Array) && sj['waivers'].any?
puts "   stamped  : #{sj['generatedAt']}"
if deg_entries.empty?
  puts '   ledger   : empty — no scope cuts, no waivers, no residuals (GREEN)'
else
  puts "   ledger   : #{deg_entries.length} degradation(s) — GREEN requires an empty ledger:"
  DegradationLedger.report_lines(deg_entries).each { |l| puts "   #{l}" }
  if derived_verdict.start_with?('PARTIAL')
    puts '   PARTIAL: a scope cut shipped — the delivered workbook is a SUBSET of the source.'
  end
end
puts '   Quote this marker (workbook + run id + verdict) and the ledger in your completion report.'
print_offramps(wd) # even a DONE run can carry waivers/degradations — surface them
exit 0
