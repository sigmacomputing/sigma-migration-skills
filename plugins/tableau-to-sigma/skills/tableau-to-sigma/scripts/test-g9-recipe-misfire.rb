#!/usr/bin/env ruby
# frozen_string_literal: true
# G9 regression tests (run-2 postmortem, 2026-07): the multi-metric recipe
# MISFIRED in the field on four fronts, all traced to exact-string field
# matching between the three spellings a column travels under (UI caption /
# extract caption / landed physical name):
#   (i)   snapshot master-column overrides silently skipped — the recipe guard
#         compared pit fields to master columns with exact downcase, missed the
#         landed-physical variant, DELETED the pit fields, and every snapshot
#         measure degraded to a raw Sum() (lib/recipe_multimetric.rb guard).
#   (ii)  the world-by-year rollup-exclusion WHERE was silently omitted when the
#         discriminator caption didn't resolve to the physical column
#         (mechanical-specs.rb phys() inserts underscores; call site now
#         resolves via RecipeMultimetric.resolve_scope_column and is LOUD).
#   (iii) dual-axis was emitted for one of N structurally identical trend tiles
#         (early return when the Country line already existed).
#   (iv)  IsNull discriminator semantics can't express a FLAG-valued
#         discriminator (rollup rows marked by VALUE, not NULL) — the new
#         optional png-read point_in_time.rollup_flag block.
#
# Offline + deterministic. Usage: ruby scripts/test-g9-recipe-misfire.rb

require 'json'
require_relative 'lib/recipe_multimetric'
require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

WE = 'Fact (World)' # DM element name (base-column formula prefix)

# Master carries the LANDED PHYSICAL spellings (what retain_columns! + the
# readback produce for un-plotted recipe columns) — NOT the png-read captions.
def master_cols
  [
    { 'id' => 'm_seg',  'name' => 'Segment',     'formula' => "[#{WE}/Segment]" },
    { 'id' => 'm_ent',  'name' => 'Entity Name', 'formula' => "[#{WE}/Entity Name]" },
    { 'id' => 'm_year', 'name' => 'YEAR',        'formula' => "[#{WE}/YEAR]" },
    { 'id' => 'm_grp',  'name' => 'ENTITYGROUP', 'formula' => "[#{WE}/ENTITYGROUP]" },
    { 'id' => 'm_flag', 'name' => 'ENTITY_FLAG', 'formula' => "[#{WE}/ENTITY_FLAG]" },
    { 'id' => 'm_rev',  'name' => 'Revenue',     'formula' => "[#{WE}/Revenue]" }
  ]
end

def build_spec
  master = { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
             'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'we' },
             'columns' => master_cols, 'order' => master_cols.map { |c| c['id'] } }
  control = { 'id' => 'ctrl', 'kind' => 'control', 'controlId' => 'ctl-param-seg', 'name' => 'Segment',
              'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_seg' },
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_seg' }] }
  bar = { 'id' => 'el-segbar', 'kind' => 'bar-chart', 'name' => 'SegBar',
          'source' => { 'kind' => 'table', 'elementId' => 'master' },
          'columns' => [
            { 'id' => 'b_dim', 'name' => 'Segment', 'formula' => '[Master/Segment]' },
            { 'id' => 'b_val', 'name' => 'Revenue', 'formula' => 'Sum([Master/Revenue])' }
          ], 'order' => %w[b_dim b_val] }
  top = { 'id' => 'el-revtop', 'kind' => 'table', 'name' => 'Rev Top3',
          'source' => { 'kind' => 'table', 'elementId' => 'master' },
          'columns' => [
            { 'id' => 't_ent', 'name' => 'Entity', 'formula' => '[Master/Entity Name]' },
            { 'id' => 't_val', 'name' => 'Revenue', 'formula' => 'Sum([Master/Revenue])' }
          ], 'order' => %w[t_ent t_val] }
  { 'pages' => [
    { 'id' => 'pg-data', 'name' => 'Data', 'elements' => [master] },
    { 'id' => 'pg-dash', 'name' => 'Dash', 'elements' => [control, bar, top] }
  ] }
end

def png(pit)
  { 'tiles' => [{ 'title' => 'SegBar', 'kind' => 'bar-chart', 'measure' => 'Revenue' }],
    'filter_shelf' => [{ 'label' => 'Segment', 'target_tiles' => ['Rev Top3'], 'highlight_tiles' => ['SegBar'] }],
    'point_in_time' => pit }
end

def top_formula(spec)
  spec['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-revtop' }['columns']
              .find { |c| c['id'] == 't_val' }['formula']
end

puts 'Part 1 — (i) caption-variant pit resolution against master columns'
s = build_spec
pit1 = { 'year_column' => 'Year', 'latest_year' => 2020, 'entity_discriminator' => 'Entity Group' }
sum1 = RecipeMultimetric.apply!(s, png(pit1))
check(top_formula(s) == 'Sum(If([Master/YEAR] = 2020 And Not IsNull([Master/ENTITYGROUP]), [Master/Revenue], null))',
      "pit caption variants resolve to the master's actual columns (got #{top_formula(s)})", fails)
bar1 = s['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-segbar' }
bv1 = bar1['columns'].find { |c| c['id'] == 'b_val' }
check(bv1['formula'] == 'Sum(If([Master All/YEAR] = 2020 And Not IsNull([Master All/ENTITYGROUP]), [Master All/Revenue], null))',
      "bar snapshot measure carries the resolved year+entity conditions (got #{bv1['formula']})", fails)
check(sum1[:notes].any? { |n| n =~ /'Entity Group' resolved to master column 'ENTITYGROUP'/ },
      'resolution is surfaced in the summary notes', fails)
check(sum1[:top_tables].to_i >= 1, 'snapshot rewrite actually ran (top_tables > 0) — the run-2 silent-skip is dead', fails)

puts 'Part 2 — (i) STILL-unresolved discriminator is LOUD (note + candidate list), never fabricated'
s2 = build_spec
s2['pages'][0]['elements'][0]['columns'].reject! { |c| %w[m_grp m_flag].include?(c['id']) }
sum2 = RecipeMultimetric.apply!(s2, png(pit1))
note = sum2[:notes].find { |n| n =~ /discriminator 'Entity Group' matches NO master column/i }
check(note, 'unresolved discriminator emits the loud note', fails)
check(note.to_s.include?('Master columns:') && note.to_s.include?('Segment'),
      'the note carries the candidate master-column list', fails)
check(!top_formula(s2).include?('Entity Group'), 'unresolved discriminator is NOT fabricated into the measure', fails)
check(top_formula(s2).include?('[Master/YEAR] = 2020'), 'latest-year condition survives on its own', fails)

puts 'Part 3 — (iv) rollup_flag equality predicates in the snapshot measures'
s3 = build_spec
pit3 = { 'year_column' => 'Year', 'latest_year' => 2020, 'entity_discriminator' => nil,
         'rollup_flag' => { 'column' => 'Entity Flag', 'entity_values' => ['N'] } }
RecipeMultimetric.apply!(s3, png(pit3))
check(top_formula(s3) == 'Sum(If([Master/YEAR] = 2020 And ([Master/ENTITY_FLAG] = "N"), [Master/Revenue], null))',
      "entity_values -> equality predicate, flag column caption-resolved (got #{top_formula(s3)})", fails)

s3b = build_spec
pit3b = { 'year_column' => 'Year', 'latest_year' => 2020, 'entity_discriminator' => nil,
          'rollup_flag' => { 'column' => 'Entity Flag', 'rollup_values' => %w[Y W] } }
RecipeMultimetric.apply!(s3b, png(pit3b))
check(top_formula(s3b) ==
      'Sum(If([Master/YEAR] = 2020 And (IsNull([Master/ENTITY_FLAG]) Or Not ([Master/ENTITY_FLAG] = "Y" Or [Master/ENTITY_FLAG] = "W")), [Master/Revenue], null))',
      "rollup_values-only -> NOT-IN with NULL-flag rows kept (got #{top_formula(s3b)})", fails)

s3c = build_spec
pit3c = { 'year_column' => 'Year', 'latest_year' => 2020, 'entity_discriminator' => 'Entity Group',
          'rollup_flag' => { 'column' => 'Entity Flag' } } # INVALID: no values
sum3c = RecipeMultimetric.apply!(s3c, png(pit3c))
check(sum3c[:notes].any? { |n| n =~ /rollup_flag INVALID/i }, 'invalid rollup_flag is rejected loudly (validator)', fails)
check(top_formula(s3c).include?('Not IsNull([Master/ENTITYGROUP])'),
      'invalid rollup_flag falls back to the IsNull discriminator', fails)

s3d = build_spec
pit3d = { 'year_column' => 'Year', 'latest_year' => 2020, 'entity_discriminator' => nil }
RecipeMultimetric.apply!(s3d, png(pit3d))
check(!top_formula(s3d).include?('IsNull') && top_formula(s3d).include?('[Master/YEAR] = 2020'),
      'no rollup_flag + null discriminator -> year-only condition (IsNull fallback only when a discriminator exists)', fails)

puts 'Part 4 — (ii) world-by-year SQL WHERE: caption-variant resolution + rollup_flag rewrite'
res = RecipeMultimetric.resolve_scope_column('Entity Flag', real_map: { 'Year' => 'YEAR', 'Revenue' => 'REVENUE', 'Entity Flag' => 'ENTITYFLAG' })
check(res['resolved'] && res['name'] == 'Entity Flag' && res['physical'] == 'ENTITYFLAG',
      'resolve_scope_column: manifest caption KEY hit', fails)
res2 = RecipeMultimetric.resolve_scope_column('Entity Flag', real_map: { 'EF' => 'ENTITYFLAG' })
check(res2['resolved'] && res2['name'] == 'ENTITYFLAG',
      'resolve_scope_column: physical VALUE hit when no key variant matches', fails)
res3 = RecipeMultimetric.resolve_scope_column('Nonexistent Col', real_map: { 'EF' => 'ENTITYFLAG' })
check(res3['resolved'] == false && res3['candidates'].include?('ENTITYFLAG'),
      'resolve_scope_column: unresolved -> resolved=false + candidate list (never silent)', fails)
res4 = RecipeMultimetric.resolve_scope_column('Entity Group', fact_captions: %w[ENTITYGROUP Year])
check(res4['resolved'] && res4['name'] == 'ENTITYGROUP', 'resolve_scope_column: projected-fact-caption fallback', fails)

fact = { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Fact',
         'source' => { 'connectionId' => 'c1', 'kind' => 'warehouse-table', 'path' => %w[DB SCH FACT_TBL] },
         'columns' => [{ 'id' => 'cy', 'formula' => '[FACT_TBL/Year]' },
                       { 'id' => 'cr', 'formula' => '[FACT_TBL/Revenue]' }] }
model = { 'pages' => [{ 'elements' => [fact] }] }
TWB = <<~XML
  <workbook>
    <column caption='Revenue World'><calculation class='tableau' formula='{ FIXED DATEPART(&apos;year&apos;, [Date]): SUM([Revenue]) }'/></column>
  </workbook>
XML
real_map = { 'Year' => 'YEAR', 'Revenue' => 'REVENUE', 'Entity Flag' => 'ENTITYFLAG' }
wmap = MechanicalSpecs.synthesize_fixed_lods!(model, fact, TWB, {}, discriminator: res['name'], real_map: real_map)
sqlel = model['pages'][0]['elements'].find { |e| e['id'] == 'el-world-by-year' }
st = sqlel && sqlel.dig('source', 'statement')
check(!wmap.empty? && st.to_s.include?('WHERE "ENTITYFLAG" IS NOT NULL'),
      "resolved caption variant carries the rollup-exclusion WHERE (got: #{st})", fails)
n_rw = RecipeMultimetric.apply_rollup_flag_where!(model, { 'column' => 'Entity Flag', 'entity_values' => ['N'] })
st2 = sqlel.dig('source', 'statement')
check(n_rw == 1 && st2.include?(%(WHERE "ENTITYFLAG" IN ('N'))),
      "rollup_flag entity_values rewrites the helper WHERE to IN (got: #{st2})", fails)

model_yoy = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-yoy-by-dim', 'kind' => 'table',
    'source' => { 'kind' => 'sql',
                  'statement' => 'SELECT "SEG", x FROM ( SELECT "SEG", y FROM DB.SCH."T" WHERE "ENTITYFLAG" IS NOT NULL GROUP BY "SEG" ) t GROUP BY "SEG"' } }
] }] }
n_rw2 = RecipeMultimetric.apply_rollup_flag_where!(model_yoy, { 'column' => 'Entity Flag', 'rollup_values' => ['Y'] })
st3 = model_yoy['pages'][0]['elements'][0].dig('source', 'statement')
check(n_rw2 == 1 && st3.include?(%(("ENTITYFLAG" NOT IN ('Y') OR "ENTITYFLAG" IS NULL))),
      "rollup_values-only rewrites to NOT IN + IS NULL keep (got: #{st3})", fails)
check(RecipeMultimetric.apply_rollup_flag_where!(model_yoy, { 'column' => 'Entity Flag', 'rollup_values' => ['Y'] }).zero?,
      'WHERE rewrite is idempotent (second pass rewrites nothing)', fails)

puts 'Part 5 — (iii) dual-axis is UNIFORM across structurally identical trends'
def trend(id, name, world_name)
  { 'id' => id, 'kind' => 'line-chart', 'name' => name,
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [
      { 'id' => "#{id}-year",  'name' => 'YEAR', 'formula' => '[Master/YEAR]' },
      { 'id' => "#{id}-world", 'name' => world_name, 'formula' => 'Sum([Master/Revenue World])' }
    ], 'order' => ["#{id}-year", "#{id}-world"] }
end
s5 = build_spec
t_a = trend('el-tr-a', 'Trend A', 'Revenue World')
t_b = trend('el-tr-b', 'Trend B', 'Revenue World')
# tile B ALREADY carries the decomposed Country line — the run-2 early-return case
t_b['columns'] << { 'id' => 'el-tr-b-country', 'name' => 'Revenue', 'formula' => 'Sum([Master/Revenue])' }
t_b['order'] << 'el-tr-b-country'
t_c = trend('el-tr-c', 'Trend C', 'Revenue  World') # display-name variant (double space)
s5['pages'][1]['elements'].concat([t_a, t_b, t_c])
sum5 = RecipeMultimetric.apply!(s5, png(pit1), world_lod_map: { 'revenue world' => 'Revenue' })
els5 = s5['pages'].flat_map { |p| p['elements'] }
%w[el-tr-a el-tr-b el-tr-c].each do |id|
  el = els5.find { |e| e['id'] == id }
  wcol = el['columns'].find { |c| c['name'].to_s =~ /World/ }
  check(el['kind'] == 'combo-chart' && el.dig('yAxis2', 'columnIds') == [wcol['id']],
        "#{id}: combo + World on yAxis2 (identical recipe classification -> identical axis structure)", fails)
  check(wcol['formula'].start_with?('Max('), "#{id}: World line re-aggregated to Max", fails)
  ycols = Array(el.dig('yAxis', 'columnIds')).map { |c| c.is_a?(Hash) ? c['columnId'] : c }
  country = el['columns'].find { |c| c['formula'] == 'Sum([Master/Revenue])' }
  check(country && ycols.sort == [wcol['id'], country['id']].sort, "#{id}: Country + World both on yAxis", fails)
end
check(sum5[:trends] == 3, "all 3 identical trends reshaped (got #{sum5[:trends]})", fails)
check(els5.find { |e| e['id'] == 'el-tr-b' }['columns'].count { |c| c['formula'] == 'Sum([Master/Revenue])' } == 1,
      'pre-existing Country line reused, not duplicated', fails)
before = JSON.generate(%w[el-tr-a el-tr-b el-tr-c].map { |id| els5.find { |e| e['id'] == id } })
sum5b = RecipeMultimetric.apply!(s5, png(pit1), world_lod_map: { 'revenue world' => 'Revenue' })
after = JSON.generate(%w[el-tr-a el-tr-b el-tr-c].map { |id| s5['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == id } })
check(sum5b[:trends].zero? && before == after, 'second apply! is a structural no-op (idempotent)', fails)

puts 'Part 6 — measure {"manual_residue": ...} is honored (no garbage rewrite)'
s6 = build_spec
png6 = png(pit1)
png6['tiles'] = [{ 'title' => 'SegBar', 'kind' => 'bar-chart', 'measure' => { 'manual_residue' => 'Growth Index' } }]
sum6 = RecipeMultimetric.apply!(s6, png6)
bar6 = s6['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-segbar' }
bv6 = bar6['columns'].find { |c| c['id'] == 'b_val' }
check(!bv6['formula'].include?('manual_residue') && !bv6['formula'].include?('Growth Index'),
      'Hash measure never lands in a formula', fails)
check(sum6[:notes].any? { |n| n =~ /MANUAL residue \('Growth Index'\)/ },
      'manual-residue measure surfaced in the notes', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
