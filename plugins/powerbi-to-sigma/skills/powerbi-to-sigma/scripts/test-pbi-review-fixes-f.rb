#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-review-fixes-f.rb — regressions for the final-review findings fixed in group F.
# Offline, synthetic names only (SALES_FACT / Region / Period).
#
#   fidelity-1 / compat-d3-currency-symbol-lost / whole-7   escaped or quoted currency masks keep
#                                                           their symbol in the d3 format
#   fidelity-2     a bookmark never "shows" a visual it also hides
#   fidelity-4     counts do not inherit the counted column's currency/percent mask
#   compat-pivot-no-values-held-back  a dimension-only pivot is kept (degraded), not dropped
#   whole-2        the sort-by fallback column follows its chart onto a page-local master copy
#   whole-3        natural-sort keys stay distinct and ordered when the first digit run is a year
#
# Run: ruby scripts/test-pbi-review-fixes-f.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/pbi_reportbuild'
require_relative 'lib/code_rep'
require_relative 'lib/ruby_compat'

$fail = 0
def ok(name, cond, got = nil)
  puts((cond ? '  ok  ' : 'FAIL  ') + name + (cond ? '' : "   got=#{got.inspect}"))
  $fail += 1 unless cond
end
R = PbiReportBuild
BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')

# ---- fidelity-1 / compat-d3 / whole-7 -----------------------------------------------------
ok('d3: escaped dollar mask keeps $', R.d3_format('\$#,0.00;(\$#,0.00);\$#,0.00') == '$,.2f', R.d3_format('\$#,0.00;(\$#,0.00);\$#,0.00'))
ok('d3: repo fixture mask \$#,0 keeps $', R.d3_format('\$#,0') == '$,.0f', R.d3_format('\$#,0'))
ok('d3: quoted dollar keeps $', R.d3_format('"$"#,##0') == '$,.0f', R.d3_format('"$"#,##0'))
ok('d3: bare dollar still works', R.d3_format('$#,##0') == '$,.0f')
ok('d3: euro (escaped / quoted / bare) keeps its symbol',
   R.d3_format('\€#,##0.00') == '€,.2f' && R.d3_format('"€"#,##0.00') == '€,.2f' && R.d3_format('€#,##0.00') == '€,.2f',
   [R.d3_format('\€#,##0.00'), R.d3_format('"€"#,##0.00'), R.d3_format('€#,##0.00')])
ok('d3: pound keeps its symbol', R.d3_format('£#,0') == '£,.0f', R.d3_format('£#,0'))
ok('d3: a plain number mask has no symbol', R.d3_format('#,##0.00') == ',.2f')
ok('d3: a quoted non-currency literal is still dropped', R.d3_format('0.0 "units"') == '.1f', R.d3_format('0.0 "units"'))

# ---- fidelity-2: bookmark shows vs hides (builder side) -----------------------------------
rev = R.bookmark_reveals([{ 'name' => 'bm', 'display_name' => 'Detail', 'hides' => ['M'], 'shows' => %w[G M N] }])
ok('bookmark_reveals: a visual the same bookmark hides is not a reveal', rev.keys.sort == %w[G N], rev)

# ---- compat-pivot-no-values-held-back ------------------------------------------------------
sev, = R.binding_miss({ 'kind' => 'pivot-table', 'rowsBy' => [{ 'columnId' => 'r' }], 'values' => [] }, source_values: false)
ok('binding_miss: a pivot that never had values (dimension-only) is DEGRADED (kept as a member list)', sev == :degrade, sev)
sev, = R.binding_miss({ 'kind' => 'pivot-table', 'rowsBy' => [{ 'columnId' => 'r' }], 'values' => [] }, source_values: true)
ok('binding_miss: a pivot whose values failed to bind is still HELD BACK', sev == :hold, sev)
sev, = R.binding_miss({ 'kind' => 'pivot-table', 'values' => [] })
ok('binding_miss: a pivot with neither dimensions nor values is still HELD BACK', sev == :hold, sev)

# ---- whole-3: natural sort keys -----------------------------------------------------------
key = R.method(:natural_sort_key)
fy = (1..13).map { |i| "FY24 P#{i}" } + ['FY25 P1']
ok('natural key: FY24 P1..P13, FY25 P1 are distinct', fy.map { |l| key.call(l) }.uniq.size == fy.size)
ok('natural key: FY24 P1..P13, FY25 P1 sort in label order',
   fy.sort_by { |l| key.call(l) } == fy, fy.sort_by { |l| key.call(l) })
ym = (1..12).map { |m| format('2024-%02d', m) }
ok('natural key: 2024-01..2024-12 are distinct and ordered',
   ym.map { |l| key.call(l) }.uniq.size == 12 && ym.sort_by { |l| key.call(l) } == ym)
pl = %w[P1 P2 P3 P9 P10 P11 P13]
ok('natural key: single-run P1..P13 orders numerically (not alphabetically)', pl.sort_by { |l| key.call(l) } == pl)
mid = ['Week 2 Actual', 'Week 10 Actual', 'Week 9 Actual']
ok('natural key: a single digit run not at the end still pads', mid.sort_by { |l| key.call(l) } == ['Week 2 Actual', 'Week 9 Actual', 'Week 10 Actual'])
ok('natural key: several runs with no trailing digits fall back to the plain label',
   key.call('Q1 FY24 Actual') == 'Q1 FY24 Actual')
f = R.natural_sort_formula('[master-x/Period]')
ok('natural_sort_formula: handles the trailing-run and single-run shapes in one formula',
   f.include?('[0-9]+$') && f.include?('RegexpCount') && f.include?('[master-x/Period]'), f)

# ---- end to end: fidelity-4, whole-2, pivot kept ---------------------------------------------
MMAP = {
  'masters' => {
    'SALES' => { 'id' => 'master-sales', 'element_id' => 'el-sales', 'data_model' => 'dm-x',
                 'columns' => [
                   { 'id' => 'mc-region', 'name' => 'Region', 'formula' => '[SALES/Region]' },
                   { 'id' => 'mc-period', 'name' => 'Period', 'formula' => '[SALES/Period]' },
                   { 'id' => 'mc-psort', 'name' => 'Period Sort', 'formula' => '[SALES/Period Sort]' },
                   { 'id' => 'mc-amt', 'name' => 'Sales Amount', 'formula' => '[SALES/Sales Amount]' }
                 ] }
  },
  'fields' => {
    'SALES_FACT.Region' => { 'master' => 'SALES', 'ref' => '[master-sales/Region]', 'agg' => nil },
    'SALES_FACT.Period' => { 'master' => 'SALES', 'ref' => '[master-sales/Period]', 'agg' => nil },
    'SALES_FACT.Sales Amount' => { 'master' => 'SALES', 'ref' => '[master-sales/Sales Amount]', 'agg' => 'Sum' },
    'Count(SALES_FACT.Sales Amount)' => { 'master' => 'SALES', 'ref' => '[master-sales/Sales Amount]', 'agg' => 'Count' },
    'CountDistinct(SALES_FACT.Sales Amount)' => { 'master' => 'SALES', 'ref' => '[master-sales/Sales Amount]', 'agg' => 'CountDistinct' }
  }
}.freeze

MODEL = {
  'model' => {
    'tables' => [
      { 'name' => 'SALES_FACT', 'columns' => [
        { 'name' => 'Region', 'dataType' => 'string' },
        { 'name' => 'Period', 'dataType' => 'string', 'sortByColumn' => 'Period Sort' },
        { 'name' => 'Period Sort', 'dataType' => 'int64' },
        { 'name' => 'Sales Amount', 'dataType' => 'double', 'formatString' => '\$#,0.00;(\$#,0.00);\$#,0.00' }
      ] }
    ]
  }
}.freeze

def vis(id, vtype, kind, bindings, title)
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title,
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => nil, 'formats' => {} }
end

def page(id, visuals)
  { 'page_id' => id, 'page_title' => "PAGE #{id.upcase}", 'page_w' => 1280, 'page_h' => 720,
    'interactions' => [], 'visuals' => visuals }
end

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [
    page('p1', [
           vis('bar1', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Period'], 'Y' => ['SALES_FACT.Sales Amount'] }, 'By Period'),
           vis('kpi_sum', 'card', 'kpi', { 'Values' => ['SALES_FACT.Sales Amount'] }, 'Total Sales'),
           vis('kpi_cnt', 'card', 'kpi', { 'Values' => ['Count(SALES_FACT.Sales Amount)'] }, 'Sale Count'),
           vis('kpi_cd', 'card', 'kpi', { 'Values' => ['CountDistinct(SALES_FACT.Sales Amount)'] }, 'Distinct Sales'),
           vis('pv', 'pivotTable', 'pivot-table', { 'Rows' => ['SALES_FACT.Region'] }, 'Regions')
         ]),
    page('p2', [
           vis('bar2', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Period'], 'Y' => ['SALES_FACT.Sales Amount'] }, 'By Period Two'),
           vis('kpi2', 'card', 'kpi', { 'Values' => ['SALES_FACT.Sales Amount'] }, 'Sales')
         ])
  ]
}.freeze

Dir.mktmpdir do |d|
  File.write(File.join(d, 'mmap.json'), JSON.generate(MMAP))
  File.write(File.join(d, 'sig.json'), JSON.generate(SIGNALS))
  File.write(File.join(d, 'model.json'), JSON.generate(MODEL))
  wb = File.join(d, 'wb.json')
  err_f = File.join(d, 'err.txt')
  st = system(RbConfig.ruby, BUILD, '--signals', File.join(d, 'sig.json'), '--master-map', File.join(d, 'mmap.json'),
              '--model', File.join(d, 'model.json'), '--bim', File.join(d, 'model.json'),
              '--data-model', 'dm-x', '--name', 'F', '--out', wb, '--layout-out', File.join(d, 'l.xml'),
              '--coverage-out', File.join(d, 'cov.json'), '--control-scope-out', File.join(d, 'scope.json'),
              out: File::NULL, err: File.open(err_f, 'w'))
  ok('builder exits 0', st || (puts(File.read(err_f).lines.last(8).join) && false))
  doc = Sigma::CodeRep.document(JSON.parse(File.read(wb)))
  els = doc['elements']
  by_name = ->(nm) { els.find { |e| e['name'] == nm } }

  kpis = els.select { |e| e['kind'] == 'kpi-chart' }
  kcol = ->(agg) { kpis.map { |e| e['columns'].find { |c| c['formula'].to_s.start_with?("#{agg}(") } }.compact.first }
  sum = kcol.call('Sum')
  cnt = kcol.call('Count')
  ok('fidelity-1: the escaped currency mask reaches the KPI as a $ format',
     sum && sum.dig('format', 'formatString').to_s.start_with?('$'), sum && sum['format'])
  ok('fidelity-4: a count of a currency column is not formatted as currency',
     cnt && cnt.dig('format', 'formatString').to_s !~ /\$/, cnt && cnt['format'])
  cd = kcol.call('CountDistinct')
  ok('fidelity-4: a CountDistinct of a currency column is not formatted as currency',
     cd && cd.dig('format', 'formatString').to_s !~ /\$/, cd && cd['format'])

  pv = by_name.call('Regions')
  ok('compat-pivot: a dimension-only matrix is still emitted', pv && pv['kind'] == 'pivot-table', els.map { |e| e['name'] })

  # whole-2: no element on a page may still reference the shared master by ANY name form once it
  # sources its page-local copy
  masters = doc['elements'].select { |e| e['id'].to_s.start_with?('master-') }.map { |e| e['id'] }
  copies = doc['elements'].select { |e| e['id'].to_s.start_with?('pgcopy-') }
  ok('whole-2: master-sales is shared by two pages, so each page has a copy', copies.size >= 2, copies.map { |e| e['id'] })
  display = masters.map { |m| m.sub(/^master-/, '').upcase[0, 6] }
  bar = by_name.call('By Period')
  bar_js = JSON.generate(bar.reject { |k, _| k == 'source' })
  ok('whole-2: the sort-by column of a moved chart does not point at the shared master',
     bar && (masters + display).none? { |m| bar_js.include?("[#{m}/") }, bar_js[/\[[^\]\/]*\/Period Sort\]/])
  ok('whole-2: the moved chart does sort by its sort column', bar && bar.dig('xAxis', 'sort', 'by').to_s.include?('sort'), bar && bar.dig('xAxis', 'sort'))
end

puts($fail.zero? ? 'ALL PASS' : "#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
