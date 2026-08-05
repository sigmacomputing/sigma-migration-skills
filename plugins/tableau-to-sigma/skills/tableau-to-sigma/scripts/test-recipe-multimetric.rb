#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for lib/recipe_multimetric.rb (2026-07-08).
#
# Deterministic + offline: a synthetic BUILT wb-spec in the shape build-charts +
# build_wb_spec produce for the Metric Series dashboard (the E2E's
# degraded output), transformed → the recipe shape. Asserts the transform:
#  A — clones master → an UNFILTERED masterAll and routes the highlight (bar)
#      tile to it (rewriting [Master/…] → [Master All/…]) + a highlight color col
#  B — leaves the FILTERED tiles (trend/top) on master, and never adds masterAll
#      to the control's filter set
#  C — rewrites the Top-N table measure to the latest-year + real-entity
#      conditional and GROUPS it (never ungrouped)
#  D — is a safe no-op when png-read has no highlight_tiles
#
# Usage: ruby scripts/test-recipe-multimetric.rb

require 'json'
require_relative 'lib/recipe_multimetric'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

WE = 'Metric Series (World)' # DM element name (base-column formula prefix)

def master_cols
  [
    { 'id' => 'm_region', 'name' => 'New Region',   'formula' => "[#{WE}/New Region]" },
    { 'id' => 'm_country','name' => 'Country Name', 'formula' => "[#{WE}/Country Name]" },
    { 'id' => 'm_year',   'name' => 'Year',         'formula' => "[#{WE}/Year]" },
    { 'id' => 'm_income', 'name' => 'Entity Group', 'formula' => "[#{WE}/Entity Group]" },
    { 'id' => 'm_rev',    'name' => 'REV',          'formula' => "[#{WE}/Revenue (current US$)]" }
  ]
end

def build_spec
  master = { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
             'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'we' },
             'columns' => master_cols, 'order' => master_cols.map { |c| c['id'] } }
  control = { 'id' => 'ctrl', 'kind' => 'control', 'controlId' => 'ctl-param-region', 'name' => 'Region',
              'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_region' },
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_region' }] }
  # Year-on-Year BAR (should be highlighted, all regions) — ungrouped, raw Sum
  bar = { 'id' => 'el-revpie', 'kind' => 'bar-chart', 'name' => 'RevPie',
          'source' => { 'kind' => 'table', 'elementId' => 'master' },
          'columns' => [
            { 'id' => 'b_dim', 'name' => 'New Region', 'formula' => '[Master/New Region]' },
            { 'id' => 'b_val', 'name' => 'REV', 'formula' => 'Sum([Master/REV])' }
          ], 'order' => %w[b_dim b_val] }
  # Top-N table (should filter to selected region, real countries, latest year).
  # Carries the spurious Date passthrough column + its list filter that
  # build-charts emits for the point-in-time year — both must be dropped once
  # the latest-year is inlined into the measure (else the filter dangles → 400).
  top = { 'id' => 'el-revtop', 'kind' => 'table', 'name' => 'Rev Top3',
          'source' => { 'kind' => 'table', 'elementId' => 'master' },
          'columns' => [
            { 'id' => 't_country', 'name' => 'Country', 'formula' => '[Master/Country Name]' },
            { 'id' => 't_val', 'name' => 'REV', 'formula' => 'Sum([Master/REV])' },
            { 'id' => 'f-el-revtop-date', 'name' => 'Date', 'formula' => '[Master/Date]' }
          ], 'order' => %w[t_country t_val f-el-revtop-date],
          'filters' => [
            { 'id' => 'flt-date', 'columnId' => 'f-el-revtop-date', 'kind' => 'list', 'values' => ['2015'] },
            { 'id' => 'topn', 'columnId' => 't_val', 'kind' => 'top-n', 'rowCount' => 8 }
          ] }
  { 'pages' => [
    { 'id' => 'pg-data', 'name' => 'Data', 'elements' => [master] },
    { 'id' => 'pg-dash', 'name' => 'Indicators', 'elements' => [control, bar, top] }
  ] }
end

PNG = {
  'filter_shelf' => [
    { 'label' => 'Region', 'target_tiles' => ['Rev Top3'], 'highlight_tiles' => ['RevPie'] }
  ],
  'point_in_time' => { 'year_column' => 'Year', 'latest_year' => 2015, 'entity_discriminator' => 'Entity Group' }
}

spec = build_spec
summary = RecipeMultimetric.apply!(spec, PNG)
els = spec['pages'].flat_map { |p| p['elements'] }
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }

puts 'Part A — master/masterAll split + highlight routing'
check(summary[:applied], 'transform reports applied', fails)
ma = by_id['masterAll']
check(ma && ma['name'] == 'Master All', 'masterAll element added (name "Master All")', fails)
check(ma && ma.dig('source', 'kind') == 'data-model', 'masterAll is DM-sourced (unfiltered clone)', fails)
check(ma && ma['columns'].map { |c| c['id'] }.all? { |i| i.start_with?('ma-') }, 'masterAll columns have fresh ids', fails)
bar = by_id['el-revpie']
check(bar.dig('source', 'elementId') == 'masterAll', 'bar tile retargeted to masterAll', fails)
check(bar['columns'].all? { |c| !c['formula'].include?('[Master/') }, 'bar formulas rewritten off [Master/…]', fails)
hl = bar['columns'].find { |c| c['name'] == 'Selected' }
check(hl && hl['formula'].include?('[ctl-param-region]') && hl['formula'].include?('[Master All/New Region]'),
      'highlight category column references the control + masterAll dim', fails)
check(bar.dig('color', 'column') == hl['id'] && bar.dig('color', 'scheme').is_a?(Array),
      'bar color = category by the highlight column', fails)

puts 'Part A2 — discriminator ABSENT from the master is dropped (guard), not fabricated'
# The mechanical DM retains only PLOTTED columns, so a png-read discriminator the
# source never plotted isn't on the fact — fabricating [Master/discr] would dangle
# and fail the POST. The guard must DROP it (with a note) and fall back to a
# year-only conditional, NOT invent a broken ref.
s_nodisc = build_spec
s_nodisc['pages'][0]['elements'][0]['columns'].reject! { |c| c['id'] == 'm_income' } # master has no Entity Group
s_nodisc['pages'][0]['elements'][0]['order']&.delete('m_income')
sum_nd = RecipeMultimetric.apply!(s_nodisc, PNG)
nd_top = s_nodisc['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-revtop' }
nd_val = nd_top['columns'].find { |c| c['id'] == 't_val' }
check(!nd_val['formula'].include?('Entity Group'), 'absent discriminator NOT fabricated into the measure', fails)
check(nd_val['formula'].include?('[Master/Year] = 2015'), 'still applies the latest-year filter (year IS on the master)', fails)
check(s_nodisc['pages'].flat_map { |p| p['elements'] }.none? { |e| (e['columns'] || []).any? { |c| c['name'] == 'Entity Group' } },
      'no dangling Entity Group column added anywhere', fails)
check(sum_nd[:notes].any? { |n| n =~ /discriminator/i }, 'guard emits a note about the skipped discriminator', fails)

puts 'Part B — filtered tile stays on master; control unchanged'
top = by_id['el-revtop']
check(top.dig('source', 'elementId') == 'master', 'Top table still sources master (filtered)', fails)
ctrl = by_id['ctrl']
check(ctrl['filters'].none? { |f| f.dig('source', 'elementId') == 'masterAll' }, 'control never filters masterAll', fails)

puts 'Part C — point-in-time measure + grouping on the Top table'
tval = top['columns'].find { |c| c['id'] == 't_val' }
check(tval['formula'] == 'Sum(If([Master/Year] = 2015 And Not IsNull([Master/Entity Group]), [Master/REV], null))',
      "Top measure rewritten to latest-year + real-entity conditional (got #{tval['formula']})", fails)
check(Array(top['groupings']).any? && top['groupings'][0]['groupBy'] == ['t_country'],
      'Top table grouped by Country (not ungrouped)', fails)
check(top['groupings'][0]['sort'][0]['direction'] == 'descending', 'grouped sort is value-descending', fails)
check(top['columns'].none? { |c| c['id'] == 'f-el-revtop-date' }, 'spurious Date column dropped from the Top table', fails)
check(top['filters'].none? { |f| f['columnId'] == 'f-el-revtop-date' },
      'orphaned Date list filter dropped with the column (no dangling dependency → no 400)', fails)
bval = bar['columns'].find { |c| c['id'] == 'b_val' }
check(bval['formula'].start_with?('Sum(If([Master All/Year] = 2015'),
      'bar magnitude measure also pinned to latest year (on masterAll)', fails)

puts 'Part C2 — trend dual-axis via the world_lod_map'
s_tr = build_spec
# a trend tile that (like the mechanical build) carries ONLY the World measure
s_tr['pages'][1]['elements'] << {
  'id' => 'el-revtrend', 'kind' => 'line-chart', 'name' => 'RevRegionLine',
  'source' => { 'kind' => 'table', 'elementId' => 'master' },
  'columns' => [
    { 'id' => 'tr_year',  'name' => 'Year', 'formula' => '[Master/Year]' },
    { 'id' => 'tr_world', 'name' => 'Revenue World', 'formula' => '[Master/Revenue World]' }
  ], 'order' => %w[tr_year tr_world]
}
sum_tr = RecipeMultimetric.apply!(s_tr, PNG, world_lod_map: { 'revenue world' => 'REV' })
tr = s_tr['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-revtrend' }
check(sum_tr[:trends] == 1, "reshaped 1 trend (got #{sum_tr[:trends]})", fails)
country = tr['columns'].find { |c| c['formula'] == 'Sum([Master/REV])' }
check(country, 'added the region-filtered Country line Sum([Master/REV])', fails)
check(tr['kind'] == 'combo-chart', 'trend promoted to combo-chart', fails)
# Dual-axis contract (matches the source design; live-verified): yAxis lists
# ALL series, yAxis2 is a PLAIN-STRING SUBSET naming which ride the right axis.
check(tr.dig('yAxis2', 'columnIds') == %w[tr_world],
      'World line marked onto yAxis2 as a plain-string subset of yAxis', fails)
check(tr['yAxis']['columnIds'].map { |c| c.is_a?(Hash) ? c['columnId'] : c }.sort == %w[tr_world trend-country-el-revtrend].sort,
      'both lines live in yAxis', fails)
check(tr['dataLabel'].nil?, 'no per-point data labels on the trend', fails)
check(tr['columns'].find { |c| c['id'] == 'tr_world' }['formula'] == 'Max([Master/Revenue World])',
      'World line aggregated (Max) to one value per year', fails)
check(tr['columns'].find { |c| c['id'] == 'tr_world' }.dig('format', 'formatString') == ',.3~s',
      'World line uses the compact SI format', fails)
# build-charts often emits the World col as Sum([…World]); the OUTER agg must be
# rewritten to Max (Sum over region-filtered rows inflates the per-year constant ~40x).
s_trs = build_spec
s_trs['pages'][1]['elements'] << {
  'id' => 'el-nfitrend', 'kind' => 'line-chart', 'name' => 'NFIRegionLine',
  'source' => { 'kind' => 'table', 'elementId' => 'master' },
  'columns' => [{ 'id' => 'y2', 'name' => 'Year', 'formula' => '[Master/Year]' },
                { 'id' => 'w2', 'name' => 'NFI World', 'formula' => 'Sum([Master/NFI World])' }],
  'order' => %w[y2 w2]
}
RecipeMultimetric.apply!(s_trs, PNG, world_lod_map: { 'nfi world' => 'NFI' })
w2 = s_trs['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-nfitrend' }['columns'].find { |c| c['id'] == 'w2' }
check(w2['formula'] == 'Max([Master/NFI World])', "Sum([…World]) outer-agg rewritten to Max (got #{w2['formula']})", fails)

puts 'Part C3 — data-scoping control (no columnId): highlight dim fallback + bar-measure rewrite + per-metric year'
s_b = build_spec
# make the control a data-scoping control with NO bound columnId
s_b['pages'][1]['elements'].find { |e| e['id'] == 'ctrl' }['source'] = { 'kind' => 'source' }
# give the bar a (copy)-calc-collapsed measure (renders 0)
bar_b = s_b['pages'][1]['elements'].find { |e| e['id'] == 'el-revpie' }
bar_b['columns'].find { |c| c['id'] == 'b_val' }['formula'] = '0'
png_b = {
  'tiles' => [{ 'title' => 'RevPie', 'kind' => 'bar-chart', 'measure' => 'REV' }],
  'filter_shelf' => [{ 'label' => 'Region', 'target_tiles' => ['Rev Top3'], 'highlight_tiles' => ['RevPie'] }],
  'point_in_time' => { 'year_column' => 'Year', 'latest_year' => { 'REV' => 2015, 'UNITS' => 2014 }, 'entity_discriminator' => 'Entity Group' }
}
RecipeMultimetric.apply!(s_b, png_b)
bar_b = s_b['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-revpie' }
hlc = bar_b['columns'].find { |c| c['name'] == 'Selected' }
check(hlc && hlc['formula'].include?('[Master All/New Region]'), 'highlight built from the bar\'s OWN dim when control has no columnId', fails)
bval_b = bar_b['columns'].find { |c| c['id'] == 'b_val' }
check(bval_b['formula'] == 'Sum(If([Master All/Year] = 2015 And Not IsNull([Master All/Entity Group]), [Master All/REV], null))',
      "copy-calc bar measure replaced via png-read tile.measure (got #{bval_b['formula']})", fails)
check(bval_b.dig('format', 'formatString') == ',.3~s',
      'bar measure re-formatted to compact SI number (not the source %-calc format)', fails)
check(bar_b['dataLabel'].nil?, 'no data labels on the bar', fails)
check(bar_b.dig('xAxis', 'sort', 'by') == 'b_val', 'bar sorted by the VALUE column (not the category name)', fails)
# per-metric year: a UNITS tile would use 2014
units_year = RecipeMultimetric.latest_year_for(png_b['point_in_time'], 'UNITS')
check(units_year == 2014, "per-metric latest_year map resolves UNITS->2014 (got #{units_year})", fails)

puts 'Part D — no-op without highlight_tiles'
s2 = build_spec
sum2 = RecipeMultimetric.apply!(s2, { 'filter_shelf' => [{ 'label' => 'Region', 'target_tiles' => ['Rev Top3'] }] })
check(!sum2[:applied] && s2['pages'].flat_map { |p| p['elements'] }.none? { |e| e['id'] == 'masterAll' },
      'no highlight_tiles → transform is a safe no-op', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
