#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof regression: Phase 1d requires point_in_time.latest_year when a
# control highlights a tile; with latest_year set, the multi-metric recipe
# rewrote an unrelated "Top 10 Customers" bar's RANK measure to a Year=<latest>
# point-in-time sum, collapsing the Top-N to one bar. A Top-N / RANK tile with
# no year filter in the source keeps its all-years measure; a year-scoped Top-N
# table (the recipe's own case) is still rewritten.

require 'json'
require_relative 'lib/recipe_multimetric'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MCOLS = [
  { 'id' => 'm_cust', 'name' => 'Customer Id', 'formula' => '[Fact/Customer Id]' },
  { 'id' => 'm_year', 'name' => 'Year', 'formula' => '[Fact/Year]' },
  { 'id' => 'm_rev', 'name' => 'Net Revenue', 'formula' => '[Fact/Net Revenue]' }
].freeze

def spec
  master = { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
             'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'fact' },
             'columns' => MCOLS.map(&:dup), 'order' => MCOLS.map { |c| c['id'] } }
  control = { 'id' => 'ctrl', 'kind' => 'control', 'controlId' => 'ctl-param-metric', 'name' => 'Select Metric',
              'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_cust' },
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_cust' }] }
  trend = { 'id' => 'el-trend', 'kind' => 'line-chart', 'name' => 'Revenue Trend',
            'source' => { 'kind' => 'table', 'elementId' => 'master' },
            'columns' => [{ 'id' => 'tr_y', 'name' => 'Year', 'formula' => '[Master/Year]' },
                          { 'id' => 'tr_v', 'name' => 'Net Revenue', 'formula' => 'Sum([Master/Net Revenue])' }] }
  top10 = { 'id' => 'el-top10', 'kind' => 'bar-chart', 'name' => 'Top 10 Customers',
            'source' => { 'kind' => 'table', 'elementId' => 'master' },
            'columns' => [{ 'id' => 'x', 'name' => 'Customer Id', 'formula' => '[Master/Customer Id]' },
                          { 'id' => 'rank', 'name' => 'Top-N Rank Measure', 'formula' => 'Sum([Master/Net Revenue])' }],
            'filters' => [{ 'id' => 'f-top', 'columnId' => 'rank', 'kind' => 'top-n', 'rowCount' => 10 }] }
  yeartop = { 'id' => 'el-yeartop', 'kind' => 'table', 'name' => 'Top Customers This Year',
              'source' => { 'kind' => 'table', 'elementId' => 'master' },
              'columns' => [{ 'id' => 'yc', 'name' => 'Customer Id', 'formula' => '[Master/Customer Id]' },
                            { 'id' => 'yv', 'name' => 'Net Revenue', 'formula' => 'Sum([Master/Net Revenue])' },
                            { 'id' => 'yy', 'name' => 'Year', 'formula' => '[Master/Year]' }],
              'filters' => [{ 'id' => 'f-y', 'columnId' => 'yy', 'kind' => 'list', 'values' => ['2026'] },
                            { 'id' => 'f-yt', 'columnId' => 'yv', 'kind' => 'top-n', 'rowCount' => 5 }] }
  { 'pages' => [{ 'id' => 'pg-data', 'name' => 'Data', 'elements' => [master] },
                { 'id' => 'pg-dash', 'name' => 'Overview', 'elements' => [control, trend, top10, yeartop] }] }
end

PNG = {
  'filter_shelf' => [{ 'label' => 'Select Metric', 'target_tiles' => ['Top 10 Customers'], 'highlight_tiles' => ['Revenue Trend'] }],
  'point_in_time' => { 'year_column' => 'Year', 'latest_year' => 2026, 'entity_discriminator' => nil }
}.freeze

s = spec
sum = RecipeMultimetric.apply!(s, JSON.parse(JSON.generate(PNG)))
els = s['pages'].flat_map { |p| p['elements'] }
rank = els.find { |e| e['id'] == 'el-top10' }['columns'].find { |c| c['id'] == 'rank' }
ok(rank['formula'] == 'Sum([Master/Net Revenue])', "unscoped Top-N rank measure keeps its all-years sum (got #{rank['formula']})")
ok(sum[:notes].any? { |n| n.include?('Top 10 Customers') && n.include?('NOT applied') }, 'the skip is noted, not silent')
yv = els.find { |e| e['id'] == 'el-yeartop' }['columns'].find { |c| c['id'] == 'yv' }
ok(yv && yv['formula'].include?('2026'), "year-scoped Top-N table still gets the latest-year rewrite (got #{yv && yv['formula']})")
ok(RecipeMultimetric.ranked?(els.find { |e| e['id'] == 'el-top10' }), 'top-n filter => ranked')
ok(!RecipeMultimetric.year_scoped?(els.find { |e| e['id'] == 'el-top10' }, PNG['point_in_time']), 'no year filter => not year-scoped')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
