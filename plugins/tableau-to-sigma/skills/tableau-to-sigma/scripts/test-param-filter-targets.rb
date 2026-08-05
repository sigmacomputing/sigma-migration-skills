#!/usr/bin/env ruby
# Unit test for param_filter_targets (TASK C / #259) — the pure tracer that
# turns a data-scoping Tableau parameter into a real Sigma filter target.
#
# A data-scoping parameter drives a boolean filter calc "[Col] = [Param]" used as
# a worksheet filter. Being merely referenced by a translated calc does NOT scope
# data in Sigma — the control needs a filter target on [Col]. This locks:
#   - clean equality "[Col] = [Parameters].[Param]" (either operand order) →
#     resolves [Col] to a master column, op '='.
#   - directional "[Col] > [Param]" is reported (op '>') but NOT auto-wired by the
#     caller (an inclusion filter can't express ">").
#   - multi-param period engines yield NO clean match but DO surface every master
#     column their calcs reference (candidates), so the operator knows the target.
#   - [<guid>] refs resolve through columns_by_guid; non-referencing calcs ignored.
#
# Deterministic/offline: extracts map_column + param_filter_targets from
# build-charts-from-signals.rb and runs them in isolation (no script side effects).
#
# Usage:  ruby scripts/test-param-filter-targets.rb

SRC = File.join(__dir__, 'build-charts-from-signals.rb')
src = File.read(SRC)
%w[map_column param_filter_targets].each do |fn|
  block = src[/^def #{fn}\b.*?^end$/m]
  abort "could not extract #{fn} from #{SRC}" unless block
  eval(block) # rubocop:disable Security/Eval — trusted first-party source, test-only
end

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# mmap: regex-pattern → master column info (id + name), matching map_column's shape.
MMAP = {
  '(?i)^region$'     => { 'id' => 'col-region', 'name' => 'Region' },
  '(?i)^sales$'      => { 'id' => 'col-sales',  'name' => 'Sales' },
  '(?i)^order date$' => { 'id' => 'col-date',   'name' => 'Order Date' }
}.freeze
CBG = {
  'aaaaaaaa-1111-2222-3333-444444444444' => { 'caption' => 'Region' },
  'pppppppp-1111-2222-3333-444444444444' => { 'caption' => 'Region Param' }
}.freeze

puts 'Clean equality — "[Region] = [Parameters].[Region Param]"'
r = param_filter_targets('Region Param',
      { 'RegionFilter' => '[Region] = [Parameters].[Region Param]' }, MMAP, CBG)
check(r['clean'].size == 1, 'one clean target', fails)
check(r['clean'].first == { 'col' => 'Region', 'column_id' => 'col-region', 'op' => '=' },
      "resolves [Region]→col-region op '=' (got #{r['clean'].first.inspect})", fails)

puts 'Operand order flipped — "[Region Param] = [Region]"'
r = param_filter_targets('Region Param',
      { 'RegionFilter' => '[Parameters].[Region Param] = [Region]' }, MMAP, CBG)
check(r['clean'].first == { 'col' => 'Region', 'column_id' => 'col-region', 'op' => '=' },
      'flipped operands still resolve to the column with op =', fails)

puts 'Directional op — "[Sales] >= [Threshold]" (reported, not equality)'
r = param_filter_targets('Threshold',
      { 'Big' => '[Sales] >= [Parameters].[Threshold]' }, MMAP, CBG)
check(r['clean'].first && r['clean'].first['op'] == '>=', "op reported as '>=' (surfaced)", fails)
check(r['clean'].none? { |c| c['op'] == '=' }, 'no equality target (caller will not auto-wire)', fails)

puts 'Directional flip normalizes to column-relative — "[Threshold] < [Sales]" → Sales >= Threshold? "> "'
r = param_filter_targets('Threshold',
      { 'Big' => '[Parameters].[Threshold] < [Sales]' }, MMAP, CBG)
check(r['clean'].first && r['clean'].first['col'] == 'Sales' && r['clean'].first['op'] == '>',
      "param-on-left '<' flips to column-relative '>' (got #{r['clean'].first.inspect})", fails)

puts 'Multi-param period engine — no clean match, surfaces candidate columns'
complex = 'CASE [Parameter 8] WHEN 1 THEN (IF [Region] = [Region Param] THEN ' \
          '[Order Date] > [Region Param] END) END'
r = param_filter_targets('Region Param', { 'PeriodEngine' => complex }, MMAP, CBG)
check(r['clean'].empty?, 'no whole-formula clean match on a nested CASE', fails)
check((%w[Region] - r['candidates']).empty?, "candidates include referenced master cols (got #{r['candidates'].inspect})", fails)

puts 'GUID ref resolves through columns_by_guid'
r = param_filter_targets('Region Param',
      { 'RegionFilter' => '[aaaaaaaa-1111-2222-3333-444444444444] = [Parameters].[Region Param]' }, MMAP, CBG)
check(r['clean'].first && r['clean'].first['column_id'] == 'col-region',
      'a [<guid>] column ref resolves to its master column', fails)

puts 'Non-referencing calc is ignored'
r = param_filter_targets('Region Param',
      { 'Other' => '[Sales] > 100', 'Unrelated' => '[Region] = "West"' }, MMAP, CBG)
check(r['clean'].empty? && r['candidates'].empty?, 'a calc that never touches the param yields nothing', fails)

puts 'Column that does not resolve to a master is dropped'
r = param_filter_targets('Region Param',
      { 'Ghost' => '[Nonexistent Col] = [Parameters].[Region Param]' }, MMAP, CBG)
check(r['clean'].empty?, 'unresolvable [Col] is not offered as a clean target', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
