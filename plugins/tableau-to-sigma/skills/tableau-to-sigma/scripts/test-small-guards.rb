#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the v5.4 small guards:
#   - cull_failed_fields must never extract PROSE as a field name (round 6:
#     "Dependency not found. The usual cause…" yielded the field '. The usual'
#     and garbled offramp reason strings) — the colon is mandatory and every
#     capture passes a plausibility filter.
#   - preflight lint I1 flags If( bare predicates ONLY — Sigma's Switch is
#     MATCH-form, so a bare [col] subject (the builder's own SORT_ORD columns)
#     is legitimate and was a field false-positive twice.
# Usage: ruby scripts/test-small-guards.rb
require 'json'

DIR = __dir__
SRC = File.read(File.join(DIR, 'migrate-tableau.rb'))
%w[plausible_field_name? cull_failed_fields].each do |fn|
  m = SRC.match(/^def #{Regexp.escape(fn).sub('\\?', '\\?')}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(c, msg, fails)
  fails << msg unless c
  puts "  #{c ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'cull_failed_fields — prose never becomes a field name'
prose_log = <<~LOG
  ERROR: Dependency not found. The usual cause is a stale reference that was
  removed from the model, or a renamed column.
LOG
check(cull_failed_fields(prose_log) == [], "prose after a period extracts nothing (got #{cull_failed_fields(prose_log).inspect})", fails)

real_log = <<~LOG
  POST failed: Dependency not found: Preset Room Used
  compile: Unknown column "[Runner Dir]" on element master
  unmapped measure: Net Revenue
LOG
got = cull_failed_fields(real_log)
check(got.include?('Preset Room Used') && got.include?('Runner Dir') && got.include?('Net Revenue'),
      "real field names still extracted (got #{got.inspect})", fails)

long_prose = 'Dependency not found: the element you referenced was removed from the data model during quarantine'
check(cull_failed_fields(long_prose) == [],
      'sentence-length capture rejected by the plausibility filter', fails)

puts 'plausible_field_name?'
{ 'Preset Room Used' => true, 'NUM_ENROLLED' => true, '% of Total lab' => true,
  # v5.4.9: long enterprise KPI captions (8+ words) are legitimate field names.
  'Average Revenue Per Paying User Per Month (USD)' => true,
  '. The usual' => false, '' => false, 'a b c d e f g h' => false,
  'the element you referenced was removed' => false,
  '- dropped from the grid' => false }.each do |s, want|
  check(plausible_field_name?(s) == want, "plausible_field_name?(#{s.inspect}) == #{want}", fails)
end

puts 'preflight lint I1 — If-only bare predicate'
require_relative 'lib/preflight_lint'
elements = [
  { 'id' => 'e1', 'kind' => 'bar-chart', 'name' => 'tile', 'columns' => [
    { 'id' => 'c-sort', 'name' => 'SORT_ORD',
      'formula' => 'Switch([Master/Preset Room Used], "A", 1, "B", 2, 3)' },
    { 'id' => 'c-if', 'name' => 'Flag', 'formula' => 'If([Master/Bit], "y", "n")' },
    { 'id' => 'c-ok', 'name' => 'Cmp', 'formula' => 'If([Master/Bit] = 1, "y", "n")' }
  ] }
]
spec = {
  'document' => {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'p1', 'name' => 'Dashboard' }],
    'elements' => elements,
    'layout' => '<Page id="p1"><Element elementId="e1"/></Page>'
  }
}
warns = lint_warnings(spec)
i1 = warns.select { |w| w.start_with?('I1') }
check(i1.none? { |w| w.include?('SORT_ORD') },
      "match-form Switch subject NOT flagged (got #{i1.inspect})", fails)
check(i1.any? { |w| w.include?("'Flag'") }, 'If( bare predicate still flagged', fails)
check(i1.none? { |w| w.include?("'Cmp'") }, 'explicit comparison not flagged', fails)

if fails.empty?
  puts 'test-small-guards: ALL PASS'
else
  puts "test-small-guards: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
