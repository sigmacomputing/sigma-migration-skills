#!/usr/bin/env ruby
# frozen_string_literal: true

# lib/lod_dim_helper.rb scope: ONE dimension + ONE aggregate over a bare field
# or YEAR/QUARTER/MONTH/DAY of one is built; anything else is left for the
# handoff (never guessed). End-to-end shape: corpus/tableau/fixed-lod-dimension.

require 'json'
require_relative 'lib/lod_dim_helper'
$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

calcs = [
  { 'caption' => 'Cohort Year', 'formula' => '{FIXED [g-cust] : MIN(YEAR([g-date]))}' },
  { 'caption' => 'First Order', 'formula' => '{ FIXED [Customer Id] : MIN([Order Date]) }' },
  { 'caption' => 'Two Dims', 'formula' => '{FIXED [Customer Id], [Region] : MIN([Order Date])}' },
  { 'caption' => 'Ratio', 'formula' => '{FIXED [Customer Id] : SUM([A]) / SUM([B])}' },
  { 'caption' => 'Include', 'formula' => '{INCLUDE [Customer Id] : SUM([A])}' }
]
plans = LodDimHelper.plans(calcs, 'g-cust' => { 'caption' => 'Customer Id ' }, 'g-date' => { 'caption' => 'Order Date' })
ok(plans['Cohort Year'] == { key: 'Customer Id', agg: 'Min', part: 'Year', field: 'Order Date' }, "GUID refs resolve via captions (#{plans['Cohort Year'].inspect})")
bracket_plans = LodDimHelper.plans(calcs, '[g-cust]' => { 'caption' => 'Customer Id ' },
                                          '[g-date]' => { 'caption' => 'Order Date' })
ok(bracket_plans['Cohort Year'] == plans['Cohort Year'], 'bracketed GUID keys resolve via captions')
ok(plans['First Order'] && plans['First Order'][:part].nil? && plans['First Order'][:field] == 'Order Date', 'bare field aggregate')
ok(!plans.key?('Two Dims') && !plans.key?('Ratio') && !plans.key?('Include'), 'multi-dim / compound / INCLUDE are left for the handoff')

spec = { 'pages' => [
  { 'id' => 'page-data', 'name' => 'Data', 'elements' => [
    { 'id' => 'm', 'kind' => 'table', 'name' => 'Master', 'source' => { 'kind' => 'data-model', 'elementId' => 'f' },
      'columns' => [{ 'id' => 'c1', 'name' => 'Region', 'formula' => '[F/Region]' }] }
  ] },
  { 'id' => 'p1', 'name' => 'D', 'elements' => [
    { 'id' => 't', 'kind' => 'table', 'name' => 'T', 'source' => { 'kind' => 'table', 'elementId' => 'm' },
      'columns' => [{ 'id' => 'x', 'name' => 'Cohort Year', 'formula' => '[Master/Cohort Year]' }] }
  ] }
] }
r = LodDimHelper.apply!(spec, plans)
master = spec['pages'][0]['elements'][0]
ok(r[:built].size == 1 && spec['pages'][0]['elements'][1]['id'] == 'lod-cohort-year-helper', 'helper inserted right after the master')
ok(master['columns'].any? { |c| c['name'] == 'Customer Id' && c['formula'] == '[F/Customer Id]' },
   'missing key added to the master by its data-model prefix (the Lookup needs it)')
ok(spec['pages'][1]['elements'][0]['columns'][0]['formula'].start_with?('Lookup([Cohort Year Helper/Cohort Year], [Master/Customer Id]'),
   'tile column rewritten to the Lookup')
spec['pages'][1]['elements'] << {
  'id' => 't2', 'kind' => 'table', 'name' => 'T2', 'source' => { 'kind' => 'table', 'elementId' => 'm' },
  'columns' => [{ 'id' => 'x2', 'name' => 'Cohort Year', 'formula' => '[Master/Cohort Year]' }]
}
spec2 = JSON.parse(JSON.generate(spec).gsub('lod-cohort-year-helper', 'x').gsub('Cohort Year Helper', 'X'))
spec2['pages'][0]['elements'].reject! { |e| e['id'] == 'x' }
spec2['pages'][1]['elements'][0]['columns'] = [
  { 'id' => 'x', 'name' => 'Cohort Year', 'formula' => '[Master/Cohort Year]' },
  { 'id' => 'nn-x', 'name' => 'Cohort Year Not Null', 'formula' => 'Text(IsNotNull([Master/Cohort Year]))' }
]
LodDimHelper.apply!(spec2, plans)
nn = spec2['pages'][1]['elements'][0]['columns'].find { |c| c['id'] == 'nn-x' }
ok(nn['formula'] == 'Text(IsNotNull(Lookup([Cohort Year Helper/Cohort Year], [Master/Customer Id], [Cohort Year Helper/Customer Id])))',
   "derived columns (pivot null-dim exclusion) are rewritten too, not left dangling (#{nn['formula']})")
r2 = LodDimHelper.apply!(spec, plans)
ok(r2[:built].empty? && spec['pages'][0]['elements'].count { |e| e['name'] == 'Cohort Year Helper' } == 1,
   're-entry reuses an existing helper instead of duplicating its id')
ok(spec['pages'][1]['elements'][1]['columns'][0]['formula'].start_with?('Lookup('),
   're-entry rewrites a remaining bare consumer through the existing helper')

two_sources = { 'pages' => [
  { 'id' => 'data', 'elements' => %w[f1 f2].each_with_index.map do |source, i|
    { 'id' => "m#{i}", 'kind' => 'table', 'name' => "Master #{i}", 'source' => { 'kind' => 'data-model', 'elementId' => source },
      'columns' => [{ 'id' => "c#{i}", 'name' => 'Region', 'formula' => "[#{source.upcase}/Region]" }] }
  end },
  { 'id' => 'dash', 'elements' => %w[f1 f2].each_with_index.map do |_source, i|
    { 'id' => "tile#{i}", 'kind' => 'table', 'name' => "Tile #{i}",
      'source' => { 'kind' => 'table', 'elementId' => "m#{i}" },
      'columns' => [{ 'id' => "x#{i}", 'name' => 'Cohort Year', 'formula' => "[Master #{i}/Cohort Year]" }] }
  end }
] }
r3 = LodDimHelper.apply!(two_sources, plans)
helper_ids = r3[:built].map { |b| b['helper'] }
helpers = two_sources['pages'][0]['elements'].select { |e| helper_ids.include?(e['id']) }
helper_column_ids = helpers.flat_map { |e| Array(e['columns']).map { |c| c['id'] } }
ok(helper_ids.size == 2 && helper_ids.uniq.size == 2 && helper_column_ids.uniq.size == helper_column_ids.size,
   'same-caption helpers and columns are source-scoped')
ok(helpers.map { |e| e['name'] }.uniq.size == 2 &&
   two_sources['pages'][1]['elements'].map { |e| e['columns'][0]['formula'][/\ALookup\(\[([^\/]+)/, 1] }.uniq.size == 2,
   'same-caption helpers have unambiguous display names and Lookup references')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
