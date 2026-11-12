#!/usr/bin/env ruby
# Regression test: a SYNTHESIZED field_map entry must wrap its inherited ALTS in the
# same transform as its primary ref.
#
# THE BUG (found by reading the rendered dashboard PNG, 2026-07-30 — not by any
# numeric check): "Hours by Location" (a pieChart) rendered its LEGEND and no slices.
#
# Mechanism. A classic report binds an aggregated measure as "Sum(TABLE.COL)". No
# field_map key exists in that shape, so migrate-powerbi.rb synthesizes one from the
# plain-column entry:
#     field_map[r] = base.merge('ref' => "Sum(#{base['ref']})", 'agg' => nil)
# `base.merge` copies EVERY key — including `alts`, the alternate resolutions on other
# masters. Only the TOP-LEVEL ref got wrapped; the alts kept their BARE column refs.
# When the page's chosen base master is the joined "View" (which is the normal case
# under one-base-table-per-page), field_spec swaps in the alt — and the aggregation is
# silently gone. Measured on a real report:
#     'Sum(ABSENCE_RECORDS.HOURS)' -> ref  "Sum([master-06cf9224/Hours])"   correct
#                                     alts [{ref: "[master-e55e899b/Hours]"}]  BARE
# A pie whose value column is a row-level column cannot compute slice angles, so Sigma
# draws the legend and nothing else.
#
# The SAME defect hits the date-hierarchy branch, which wraps in
# DateTrunc("year", ...): its alts lost the DateTrunc, so a chart that should plot by
# YEAR plotted at DAY grain (visible as a dense spiky line on the same dashboard).
#
# NOTE this class of bug is invisible to the field-binding coverage gate: the ref
# RESOLVES, it just resolves to the wrong formula. Numbers-green, render-broken — which
# is exactly why the PNG has to be read.
#
# Usage:  ruby scripts/test-alt-agg-wrapper.rb
require 'json'
require_relative 'lib/pbi_field_alts'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# The exact shape measured on the real report.
BASE = {
  'master' => 'ABSENCE_RECORDS',
  'ref' => '[master-06cf9224/Hours]',
  'agg' => nil,
  'alts' => [{ 'master' => 'ABSENCE_RECORDS View',
               'ref' => '[master-e55e899b/Hours]', 'agg' => nil }]
}.freeze

puts "\n1. an AGGREGATE wrapper is applied to the primary ref AND to every alt"
e = PbiFieldAlts.wrapped_entry(BASE) { |ref| "Sum(#{ref})" }
check(e['ref'] == 'Sum([master-06cf9224/Hours])', "primary ref wrapped (got #{e['ref']})", fails)
check(e['alts'].size == 1, 'alt count preserved', fails)
check(e['alts'][0]['ref'] == 'Sum([master-e55e899b/Hours])',
      "ALT ref wrapped too (got #{e['alts'][0]['ref'].inspect}) — this is the pie bug", fails)
check(e['alts'][0]['master'] == 'ABSENCE_RECORDS View', 'alt master untouched', fails)

puts "\n2. the source entry is NOT mutated (alts are shared by reference in the caller)"
check(BASE['ref'] == '[master-06cf9224/Hours]', 'base primary ref unchanged', fails)
check(BASE['alts'][0]['ref'] == '[master-e55e899b/Hours]',
      'base ALT unchanged — merge must deep-copy alts, not alias them', fails)
check(!e['alts'].equal?(BASE['alts']), 'the alts array is a new object, not the same one', fails)
check(!e['alts'][0].equal?(BASE['alts'][0]), 'each alt hash is a copy', fails)

puts "\n3. the DateTrunc (date-hierarchy) wrapper behaves identically"
d = PbiFieldAlts.wrapped_entry(BASE) { |ref| "DateTrunc(\"year\", #{ref})" }
check(d['ref'] == 'DateTrunc("year", [master-06cf9224/Hours])', 'primary DateTrunc applied', fails)
check(d['alts'][0]['ref'] == 'DateTrunc("year", [master-e55e899b/Hours])',
      "ALT DateTrunc applied (got #{d['alts'][0]['ref'].inspect}) — the day-grain line-chart bug", fails)

puts "\n4. an entry with NO alts still works, and agg is cleared"
plain = { 'master' => 'T', 'ref' => '[m/C]', 'agg' => 'Sum' }
p2 = PbiFieldAlts.wrapped_entry(plain) { |ref| "Sum(#{ref})" }
check(p2['ref'] == 'Sum([m/C])', 'no-alts entry wraps its ref', fails)
check(p2['agg'].nil?, "agg cleared (the wrapper IS the aggregation now; got #{p2['agg'].inspect})", fails)
check(!p2.key?('alts') || p2['alts'].nil? || p2['alts'].empty?, 'no alts invented', fails)

puts "\n5. a `formula` on an alt is wrapped too when present, never left stale"
# An alt may carry a verbatim `formula` instead of a bare ref; if we wrap the ref but
# leave a stale unwrapped formula, the builder prefers the formula and the bug returns.
withf = { 'master' => 'T', 'ref' => '[m/C]', 'agg' => nil,
          'alts' => [{ 'master' => 'V', 'ref' => '[v/C]', 'formula' => '[v/C]', 'agg' => nil }] }
w = PbiFieldAlts.wrapped_entry(withf) { |ref| "Sum(#{ref})" }
check(w['alts'][0]['ref'] == 'Sum([v/C])', 'alt ref wrapped', fails)
check(w['alts'][0]['formula'] == 'Sum([v/C])',
      "alt formula wrapped too (got #{w['alts'][0]['formula'].inspect})", fails)

puts "\n6. the orchestrator actually USES the helper at both synthesis sites"
src = File.read(File.join(__dir__, 'migrate-powerbi.rb'))
check(src.include?('PbiFieldAlts'), 'migrate-powerbi.rb requires/uses PbiFieldAlts', fails)
# neither synthesis site may still hand-roll base.merge('ref' => ...)
bad = src.scan(/base\.merge\('ref'\s*=>/).size
check(bad.zero?,
      "no synthesis site still hand-rolls base.merge('ref' => …) (found #{bad})", fails)

puts "\n7. G28: a field whose OWN name has a parenthetical keeps it when aliased to the View column"
# "DimDate.Date (Fiscal Month)" is a Power BI field literally named "Date (Fiscal Month)". The joined
# View exposes dim columns as "<Leaf> (<ENTITY>)"; stripping the field's own "(Month)"
# aliased it to "Date (DimDate)" (the plain Date column) so "monthly" charts plotted daily.
VMASTERS = {
  'Sales View' => { 'id' => 'master-view',
                    'columns' => [{ 'id' => 'v1', 'name' => 'Amount' },
                                  { 'id' => 'v2', 'name' => 'Date (DimDate)' },
                                  { 'id' => 'v3', 'name' => 'Date (Fiscal Month) (DimDate)' },
                                  { 'id' => 'v4', 'name' => 'Region (Region)' }] },
  'DimDate' => { 'id' => 'master-dd', 'columns' => [{ 'id' => 'd1', 'name' => 'Date' }, { 'id' => 'd2', 'name' => 'Date (Fiscal Month)' }] }
}.freeze
fm = {
  'DimDate.Date (Fiscal Month)' => { 'master' => 'DimDate', 'ref' => '[master-dd/Date (Fiscal Month)]', 'agg' => nil,
                              'alts' => [{ 'master' => 'Sales View', 'ref' => '[master-view/Date (DimDate)]', 'agg' => nil }] },
  'DimDate.Date'         => { 'master' => 'DimDate', 'ref' => '[master-dd/Date]', 'agg' => nil,
                              'alts' => [{ 'master' => 'Sales View', 'ref' => '[master-view/Date (DimDate)]', 'agg' => nil }] }
}
res = PbiFieldAlts.repair_view_alts!(fm, VMASTERS)
check(fm['DimDate.Date (Fiscal Month)']['alts'][0]['ref'] == '[master-view/Date (Fiscal Month) (DimDate)]',
      "Date (Fiscal Month) aliases to the View column 'Date (Fiscal Month) (DimDate)' (got #{fm['DimDate.Date (Fiscal Month)']['alts'][0]['ref'].inspect})", fails)
check(fm['DimDate.Date']['alts'][0]['ref'] == '[master-view/Date (DimDate)]',
      'a plain field (no own parenthetical) keeps its Date (DimDate) alias', fails)
check(res['fixed'] == 1 && res['dropped'].empty?, "repair reports 1 fixed / 0 dropped (got #{res.inspect})", fails)

# the exact column does not exist on the View: the wrong alias is REMOVED and reported, never kept
fm2 = { 'DimDate.Date (Fiscal Week)' => { 'master' => 'DimDate', 'ref' => '[master-dd/Date (Fiscal Week)]', 'agg' => nil,
                                   'alts' => [{ 'master' => 'Sales View', 'ref' => '[master-view/Date (DimDate)]', 'agg' => nil }] } }
res2 = PbiFieldAlts.repair_view_alts!(fm2, VMASTERS)
check(fm2['DimDate.Date (Fiscal Week)']['alts'].empty?, 'an alias that cannot be made exact is dropped (no silent daily-grain fallback)', fails)
check(res2['dropped'].size == 1 && res2['dropped'][0]['field'] == 'DimDate.Date (Fiscal Week)' &&
      res2['dropped'][0]['wanted'] == 'Date (Fiscal Week) (DimDate)', "the drop is reported (got #{res2['dropped'].inspect})", fails)

# a leaf that merely carries the ENTITY disambiguation suffix is not "own parenthetical"
fm3 = { 'DimDate.Date (DimDate)' => { 'master' => 'DimDate', 'ref' => '[master-dd/Date]', 'agg' => nil,
                                      'alts' => [{ 'master' => 'Sales View', 'ref' => '[master-view/Date (DimDate)]', 'agg' => nil }] } }
res3 = PbiFieldAlts.repair_view_alts!(fm3, VMASTERS)
check(res3['fixed'].zero? && res3['dropped'].empty? && fm3['DimDate.Date (DimDate)']['alts'].size == 1,
      'an entity-disambiguated leaf ("Date (DimDate)") is left alone', fails)
# aggregate/formula alts are never touched
fm4 = { 'DimDate.Date (Fiscal Month)' => { 'master' => 'DimDate', 'ref' => '[master-dd/Date (Fiscal Month)]', 'agg' => nil,
                                    'alts' => [{ 'master' => 'Sales View', 'ref' => 'Sum([master-view/Amount])', 'agg' => nil }] } }
res4 = PbiFieldAlts.repair_view_alts!(fm4, VMASTERS)
check(res4['fixed'].zero? && fm4['DimDate.Date (Fiscal Month)']['alts'].size == 1, 'non plain-column alts are not rewritten', fails)
# fact-owned fields: View exposes the bare leaf
fm5 = { 'Sales.Amount (USD)' => { 'master' => 'Sales', 'ref' => '[master-s/Amount (USD)]', 'agg' => nil,
                                  'alts' => [{ 'master' => 'Sales View', 'ref' => '[master-view/Amount]', 'agg' => nil }] } }
vm5 = { 'Sales View' => { 'id' => 'master-view', 'columns' => [{ 'id' => 'v1', 'name' => 'Amount' }, { 'id' => 'v9', 'name' => 'Amount (USD)' }] } }
res5 = PbiFieldAlts.repair_view_alts!(fm5, vm5)
check(fm5['Sales.Amount (USD)']['alts'][0]['ref'] == '[master-view/Amount (USD)]' && res5['fixed'] == 1,
      'a fact field keeps its own parenthetical against the bare-leaf View column', fails)
# idempotent
res6 = PbiFieldAlts.repair_view_alts!(fm, VMASTERS)
check(res6['fixed'].zero? && res6['dropped'].empty?, 'repair is idempotent', fails)

puts "\n8. view_lookup_leaf strips ONLY an entity-disambiguation suffix"
check(PbiFieldAlts.view_lookup_leaf('DimDate.Date (Fiscal Month)', %w[DimDate]) == 'Date (Fiscal Month)', 'own parenthetical kept', fails)
check(PbiFieldAlts.view_lookup_leaf('DimDate.Date (DimDate)', %w[DimDate]) == 'Date', 'entity suffix stripped', fails)
check(PbiFieldAlts.view_lookup_leaf('DimDate.Date (dimdate)', %w[DIM_DATE DimDate]) == 'Date', 'case-insensitive entity match', fails)
check(PbiFieldAlts.view_lookup_leaf('T.Plain', %w[T]) == 'Plain', 'no parenthetical -> leaf', fails)

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
