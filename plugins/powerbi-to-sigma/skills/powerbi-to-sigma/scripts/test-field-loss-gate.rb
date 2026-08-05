#!/usr/bin/env ruby
# Regression test: the orchestrator must HARD-FAIL on field-binding loss, with an
# explicit --allow-field-loss override that still states the reason.
#
# WHY (measured 2026-07-30 on 4 real Power BI reports, R1–R4): the migration reported
# "12/12 source visual(s) carried over; 0 dropped" on runs that had dropped 33–54% of
# their FIELD bindings, because coverage was accounted per-visual and a table shipping
# 3 of 8 columns is merely 'degraded'. Surfacing the loss is not enough — a rushed or
# unattended run will ship it anyway — so the run has to STOP.
#
# This exercises the ORCHESTRATOR's decision, not CoverageGate's arithmetic
# (test-field-binding-coverage.rb covers the ledger, and the shared lib has its own
# 47-assertion suite). It drives the extracted gate decision directly so it needs no
# Sigma credentials and no warehouse.
#
# Usage:  ruby scripts/test-field-loss-gate.rb
require 'json'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'coverage_gate'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

SRC = File.read(File.join(__dir__, 'migrate-powerbi.rb'))

puts "\n1. the orchestrator wires the gate and the override flag"
check(SRC.include?('--allow-field-loss'), 'the --allow-field-loss flag exists', fails)
check(SRC =~ /CoverageGate\.gate!/, 'the orchestrator calls CoverageGate.gate!', fails)
check(SRC =~ /binding_headline/, 'the orchestrator prints binding_headline', fails)
check(SRC =~ /CoverageGate\.headline/,
      'the VISUAL-level headline is KEPT too (the two measure different things)', fails)
# It must use the established open-question exit, not invent a new code. Scope the
# search to the FAIL block itself rather than a fixed-size window after gate! — a
# character window silently breaks the moment the block gains a line, which is a
# brittle test, not a real defect.
fail_block = SRC[/FIELD-LOSS GATE: FAIL.*?^end$/m] ||
             SRC[/fl_status == :fail.*?\n  end\n/m] || ''
check(!fail_block.empty?, 'the gate FAIL block is locatable', fails)
check(fail_block.include?('exit 10'),
      'a failing gate exits 10 (the established open-question code)', fails)
codes = fail_block.scan(/\bexit\s+(\d+)/).flatten.uniq
check(codes == ['10'],
      "the FAIL block introduces no other exit code (found #{codes.inspect})", fails)

# The FLAG must actually reach the GATE. Asserting only that the string
# "--allow-field-loss" exists somewhere, and then calling CoverageGate.gate! directly
# with a hand-supplied allow_override, leaves the wiring untested: a regression that
# hardcodes `allow_override: false` disconnects the flag while every assertion stays
# green (caught in review, 2026-07-30). Pin the actual argument.
check(SRC =~ /CoverageGate\.gate!\([^)]*allow_override:\s*opts\[:allow_field_loss\]/m,
      'the gate call passes opts[:allow_field_loss] as allow_override (not a literal)', fails)
check(SRC !~ /CoverageGate\.gate!\([^)]*allow_override:\s*(true|false)\b/m,
      'the gate call does NOT hardcode allow_override', fails)
# and the flag must set that opt
check(SRC =~ /--allow-field-loss.*\n?.*opts\[:allow_field_loss\]\s*=\s*true/m ||
      SRC =~ /opts\[:allow_field_loss\]\s*=\s*true/,
      'the --allow-field-loss flag sets opts[:allow_field_loss]', fails)

puts "\n2. the gate decision itself, on realistic coverage"
# 48% resolution, no dropped functional component -> must FAIL on the ratio alone.
ratio_only = { 'summary' => { 'sourceVisuals' => 12, 'sourceBindings' => 198,
                              'resolvedBindings' => 96 },
               'unresolved' => [{ 'visual' => 'Detail', 'severity' => 'degraded',
                                  'role_class' => 'table' }] }
st, why = CoverageGate.gate!(ratio_only, min_resolved: 0.95, allow_override: false)
check(st == :fail, '48% binding resolution FAILS', fails)
check(why.to_s =~ /9[0-9]|binding/i, "reason names the shortfall: #{why.to_s[0, 70]}", fails)
st2, why2 = CoverageGate.gate!(ratio_only, min_resolved: 0.95, allow_override: true)
check(st2 == :pass, '--allow-field-loss lets the 48% run through', fails)
check(why2.to_s.include?('overridden') && why2.to_s.length > 30,
      'the override STILL states the reason (never silently passes)', fails)

puts "\n3. a dropped FUNCTIONAL component fails even when the ratio is fine"
# 99/100 resolved — ratio passes — but a control was dropped: the page lost its filter.
ctl_drop = { 'summary' => { 'sourceBindings' => 100, 'resolvedBindings' => 99 },
             'unresolved' => [{ 'visual' => 'Date Filter', 'severity' => 'dropped',
                                'role_class' => 'control' }] }
st3, why3 = CoverageGate.gate!(ctl_drop, min_resolved: 0.95, allow_override: false)
check(st3 == :fail, 'a dropped control FAILS despite 99% binding resolution', fails)
check(why3.to_s =~ /Date Filter/ && why3.to_s =~ /control/,
      'reason names the lost component AND its role', fails)

puts "\n4. a cosmetic loss does NOT fail the run"
cosmetic = { 'summary' => { 'sourceBindings' => 100, 'resolvedBindings' => 100 },
             'unresolved' => [{ 'visual' => 'Deco', 'severity' => 'approximated',
                                'role_class' => 'decoration' },
                              { 'visual' => 'Logo', 'severity' => 'dropped',
                                'role_class' => 'image' }] }
st4, = CoverageGate.gate!(cosmetic, min_resolved: 0.95, allow_override: false)
check(st4 == :pass,
      'a dropped decoration/image does not fail the run (cosmetic, not data loss)', fails)

puts "\n5. a clean run passes and reports its binding headline"
clean = { 'summary' => { 'sourceBindings' => 40, 'resolvedBindings' => 40 }, 'unresolved' => [] }
st5, why5 = CoverageGate.gate!(clean, min_resolved: 0.95, allow_override: false)
check(st5 == :pass, 'a fully-resolved run passes', fails)
check(why5.to_s.include?('40/40'), "and reports 40/40: #{why5.to_s[0, 60]}", fails)

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
