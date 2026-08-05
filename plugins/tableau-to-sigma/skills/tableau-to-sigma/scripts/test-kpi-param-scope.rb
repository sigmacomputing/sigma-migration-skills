#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the v5.4 KPI wave: axis-anchor placeholder rejection +
# the generic period/param-scoped KPI recipe. Grammar patterns locked:
#
#   - PLACEHOLDER: a measure whose formula is a ROW-INDEPENDENT constant
#     (min(-1.0) / AVG(0) / SUM(0)) is the Tableau dummy-axis idiom — mark
#     plumbing, never the KPI value. The binder must skip it (shelf AND marks
#     card) and bind the real measure. Row COUNTS are NOT placeholders
#     (v5.4.9): bare literal 1 is exactly [Number of Records]'s formula and
#     SUM(1) is the ad-hoc row-count idiom — both are real headline values.
#   - PERIOD/PARAM SCOPE: a KPI whose measure is AGG(IF <expr> =
#     [Parameters].[P] THEN [col] END) — with <expr> a BARE or bracketed ref,
#     possibly a calc reducing to DATEPART('year', [datetime]) — and/or whose
#     zone carries boolean param-equality filters kept 'true', must source a
#     hidden FILTERED helper pinned to the params' current values. Every
#     helper filter carries an 'id'. If the scope cannot resolve, the tile is
#     flagged STAYS-MANUAL — never a silently unscoped number.
#
# Usage: ruby scripts/test-kpi-param-scope.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- unit: placeholder_calc? ------------------------------------------------
src = File.read(BUILD)
o = Object.new
o.instance_eval(src.match(/^def placeholder_calc\?.*?\n^end$/m)[0])
puts 'placeholder_calc?'
{ 'min(-1.0)' => true, 'AVG(0)' => true, 'SUM(0)' => true, 'MAX( 2.5 )' => true,
  '-1.0' => true, '0' => true, 'SUM(-2)' => true,
  # v5.4.9: row counts are DATA, not plumbing — bare 1 IS [Number of Records].
  'SUM(1)' => false, '1' => false, '7' => false,
  'SUM([x])' => false, 'MIN([Order Date])' => false, 'AVG([a]) + 0' => false,
  '' => false }.each do |f, want|
  check(o.placeholder_calc?(f) == want, "placeholder_calc?(#{f.inspect}) == #{want}", fails)
end

# ---- integration ------------------------------------------------------------
FED = '[federated.fact]'
kpi_zone = {
  'id' => '1', 'kind' => 'chart', 'caption' => 'Students', 'view_ref' => nil,
  'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 20.0, 'h_pct' => 20.0,
  'chart_kind' => 'kpi', 'chart_kind_inferred' => false, 'mark_class' => 'Text',
  'is_kpi' => true, 'is_crosstab' => false, 'kpi_label' => nil,
  'sort' => nil, 'shelf_sorts' => [], 'quick_calc_pcto' => [],
  'filters' => [
    { 'raw_class' => 'categorical', 'raw_param' => "#{FED}.[none:CalcCatSel:nk]",
      'column_guid' => 'CalcCatSel', 'column_caption' => 'Category Selector',
      'datatype' => 'boolean', 'is_action' => false, 'kind' => 'list', 'members' => ['true'] }
  ],
  'hidden_filters' => [],
  'aggregations' => { '[CalcAnchor]' => 'User', '[CalcCY]' => 'User', '[CalcCatSel]' => 'None' },
  'channels' => { 'text' => { 'column' => "#{FED}.[usr:CalcCY:qk]", 'field' => nil } },
  'formats' => {},
  'calculations' => [
    { 'name' => '[Category Parameter]', 'caption' => 'Category Parameter', 'datatype' => 'string',  'role' => 'measure', 'class' => 'tableau', 'formula' => '"Engineering"' },
    { 'name' => '[Year Parameter]',    'caption' => 'Year Parameter',    'datatype' => 'integer', 'role' => 'measure', 'class' => 'tableau', 'formula' => '2016' },
    { 'name' => '[CalcCatSel]', 'caption' => 'Category Selector', 'datatype' => 'boolean', 'role' => 'dimension', 'class' => 'tableau', 'formula' => '[CATEGORY] = [Parameters].[Category Parameter]' },
    { 'name' => '[CalcAnchor]',  'caption' => 'min(-1.0)', 'datatype' => 'real', 'role' => 'measure', 'class' => 'tableau', 'formula' => 'min(-1.0)' },
    # BARE lhs ref (no brackets) — the Tableau grammar allows it.
    { 'name' => '[CalcCY]', 'caption' => ' CY Students', 'datatype' => 'integer', 'role' => 'measure', 'class' => 'tableau',
      'formula' => "SUM(IF Year = [Parameters].[Year Parameter] \nTHEN [NUM_ENROLLED]\nEND\n)" },
    { 'name' => '[Year]', 'caption' => nil, 'datatype' => 'integer', 'role' => 'dimension', 'class' => 'tableau', 'formula' => "DATEPART('year', [PUBLISHED DATE])" }
  ],
  'dual_axis' => false,
  'measures' => [
    { 'column' => '[CalcAnchor]', 'derivation' => 'User' },  # placeholder FIRST — old picker took it
    { 'column' => '[CalcCY]',     'derivation' => 'User' }
  ],
  'ref_marks' => [], 'axis_formats' => [], 'mark_labels_show' => false,
  'rows_shelf' => { 'raw' => nil, 'fields' => [], 'dim_count' => 0, 'measure_count' => 0,
                    'cont_measure_count' => 0, 'has_measure_names' => false, 'has_measure_values' => false },
  'cols_shelf' => {
    'raw' => "#{FED}.[usr:CalcAnchor:qk]",
    'fields' => [{ 'raw' => "#{FED}.[usr:CalcAnchor:qk]", 'role' => 'measure', 'derivation' => 'usr', 'discrete' => false, 'guid' => 'CalcAnchor' }],
    'dim_count' => 0, 'measure_count' => 1, 'cont_measure_count' => 1,
    'has_measure_names' => false, 'has_measure_values' => false
  }
}

# Unresolvable twin: the IF's value column maps to nothing → STAYS-MANUAL.
manual_zone = JSON.parse(JSON.generate(kpi_zone))
manual_zone.merge!('id' => '2', 'caption' => 'Mystery', 'x_pct' => 30.0)
manual_zone['filters'] = []
manual_zone['calculations'] = kpi_zone['calculations'].map { |c| c.dup }
manual_zone['calculations'][4] = manual_zone['calculations'][4].merge(
  'formula' => "SUM(IF Year = [Parameters].[Year Parameter] THEN [UNMAPPED_MYSTERY] END)")
manual_zone['measures'] = [{ 'column' => '[CalcCY]', 'derivation' => 'User' }]

layout = [{ 'dashboard' => 'Dash', 'is_story' => false, 'zones' => [kpi_zone, manual_zone] }]
meta = {
  'worksheets' => {}, 'stories' => [], 'shared_filters' => [], 'column_aliases' => {},
  'parameters' => [
    { 'name' => '[Category Parameter]', 'caption' => 'Category Parameter', 'datatype' => 'string',
      'param_domain' => 'list', 'default_value' => 'Engineering', 'members' => [] },
    { 'name' => '[Year Parameter]', 'caption' => 'Year Parameter', 'datatype' => 'integer',
      'param_domain' => 'list', 'default_value' => '2016', 'members' => [] }
  ],
  'columns_by_guid' => {
    'CalcAnchor'  => { 'caption' => 'min(-1.0)', 'formula' => 'min(-1.0)' },
    'CalcCY'      => { 'caption' => ' CY Students', 'formula' => 'SUM(IF Year = [Parameters].[Year Parameter] THEN [NUM_ENROLLED] END)' },
    'CalcCatSel' => { 'caption' => 'Category Selector', 'formula' => '[CATEGORY] = [Parameters].[Category Parameter]' },
    'CATEGORY'     => { 'caption' => 'Category' },
    'NUM_ENROLLED' => { 'caption' => 'Num Enrolled' },
    'PUBLISHED DATE'  => { 'caption' => 'Published Date' }
  }
}
# Display-label regexes only — the raw NUM_ENROLLED/PUBLISHED DATE tokens in
# the formulas must resolve through the NORMALIZED fallback.
mmap = {
  '(?i)^Category$'         => { 'id' => 'm-cat', 'name' => 'Category' },
  '(?i)^Num Enrolled$' => { 'id' => 'm-subs', 'name' => 'Num Enrolled' },
  '(?i)^Published Date$'  => { 'id' => 'm-pub',  'name' => 'Published Date' }
}

els = []
data_els = []
log = ''
Dir.mktmpdir do |d|
  File.write(File.join(d, 'layout.json'), JSON.pretty_generate(layout))
  File.write(File.join(d, 'layout-meta.json'), JSON.pretty_generate(meta))
  File.write(File.join(d, 'master-map.json'), JSON.pretty_generate(mmap))
  File.write(File.join(d, 'get-workbook.json'), JSON.pretty_generate('workbook' => { 'views' => { 'view' => [] } }))
  out = File.join(d, 'chart-specs.json')
  o2, e2, st = Open3.capture3(RbConfig.ruby, BUILD, '--tableau-dir', d,
                              '--layout', File.join(d, 'layout.json'),
                              '--meta', File.join(d, 'layout-meta.json'),
                              '--master-map', File.join(d, 'master-map.json'),
                              '--skip-dashboard-read', 'unit-test',
                              '--page-per-dashboard',
                              '--out', out)
  log = o2 + e2
  check(st.success?, "build-charts exits 0 (got #{st.exitstatus}: #{e2.lines.first})", fails)
  raw = JSON.parse(File.read(out)) rescue {}
  els = (raw['pages'] || []).flat_map { |p| p['elements'] || [] }
  data_els = raw['data_elements'] || []
end

# kpi-chart elements carry `name` as the house-standard object form
# {'text'=>...} (KpiCard.build); every other kind still carries a plain
# String. Accept both so this name-based lookup doesn't break on the shape.
name_of = ->(e) { n = e && e['name']; n.is_a?(Hash) ? n['text'] : n }

puts 'placeholder rejection + scoped binding'
kpi = els.find { |e| e['kind'] == 'kpi-chart' && name_of.call(e) == 'Students' }
check(!kpi.nil?, 'Students KPI element emitted', fails)
kcol = kpi && (kpi['columns'] || []).first
check(kcol && !kcol['formula'].to_s.include?('min(-1.0)'),
      "KPI value never binds the axis-anchor placeholder (got #{kcol && kcol['formula']})", fails)
check(log.include?('axis-anchor placeholder'), 'placeholder skip is disclosed', fails)

helper = data_els.find { |e| e['id'].to_s.include?('scoped-src') && e['name'].to_s =~ /Enrolled/ }
check(!helper.nil?, 'hidden filtered helper emitted into data_elements', fails)
check(kpi && helper && kpi.dig('source', 'elementId') == helper['id'],
      'KPI sources the scoped helper', fails)
check(kcol && kcol['formula'].to_s =~ /\ASum\(\[[^\]]+\/Num Enrolled\]\)\z/,
      "KPI formula aggregates the helper's value column (got #{kcol && kcol['formula']})", fails)
hf = helper ? (helper['filters'] || []) : []
check(hf.size == 2, "helper carries BOTH scope filters (got #{hf.size})", fails)
check(hf.all? { |f| f['id'].to_s != '' }, 'every helper filter carries an id', fails)
yearf = hf.find { |f| f['values'] == [2016] }
check(!yearf.nil?, 'year filter pinned to the integer param value 2016', fails)
subjf = hf.find { |f| f['values'] == ['Engineering'] }
check(!subjf.nil?, "subject filter pinned to the param's current string value", fails)
ycol = helper && (helper['columns'] || []).find { |c| c['id'] == (yearf || {})['columnId'] }
check(ycol && ycol['formula'] == 'DatePart("year", [Master/Published Date])',
      "period column derives DatePart from the datetime column (got #{ycol && ycol['formula']})", fails)
check(log.include?("'Students' KPI is parameter-scoped — emitted hidden filtered helper"),
      'scoped recipe is disclosed in the build log', fails)

puts 'unresolvable scope stays manual'
myst = els.find { |e| e['kind'] == 'kpi-chart' && name_of.call(e) == 'Mystery' }
check(!myst.nil?, 'Mystery KPI still emitted (fallback, not dropped)', fails)
check(myst && myst.dig('source', 'elementId') != (helper && helper['id']),
      'Mystery KPI does NOT silently borrow another tile\'s scope', fails)
check(log.include?("'Mystery' KPI is parameter-scoped but its scope did not resolve"),
      'unresolvable scope flagged STAYS-MANUAL', fails)
check(data_els.none? { |e| e['id'].to_s.include?('kpi-mystery-scoped') },
      'no partial helper built for the unresolvable tile', fails)

if fails.empty?
  puts 'test-kpi-param-scope: ALL PASS'
else
  puts "test-kpi-param-scope: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
