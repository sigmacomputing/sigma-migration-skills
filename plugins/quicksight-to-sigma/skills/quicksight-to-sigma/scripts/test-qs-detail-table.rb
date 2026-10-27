#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-detail-table.rb — unaggregated TableVisuals build as detail tables, TableFieldOptions
# apply, and a visual that builds nothing is REPORTED instead of vanishing.
#
# The builder's `table` branch read only the GroupBy/Values wells through field_role, which knows four
# field wrappers. A TableVisual on `TableUnaggregatedFieldWells` carries bare {FieldId, Column}
# entries, so `cols` stayed empty and `next if cols.empty?` dropped the visual with no warning while
# wb-spec.map.json still mapped it to an element id that was never emitted. Eight other branches
# skip silently the same way, `DateMeasureField` (a MIN/MAX/COUNT of a date) was unreadable, and
# table FieldOptions (labels / hidden / order) were never read.
#
# Offline: the REAL builder, layout step and validator run as subprocesses on a synthetic analysis.
#
# Run: ruby scripts/test-qs-detail-table.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'rbconfig'

HERE      = __dir__
BUILDER   = File.join(HERE, 'build-workbook-from-quicksight.rb')
LAYOUT    = File.join(HERE, 'build-quicksight-layout.rb')
VALIDATOR = File.join(HERE, 'validate-spec.rb')
RUBY      = RbConfig.ruby

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def col(c) { 'DataSetIdentifier' => 'orders', 'ColumnName' => c }; end
def ufield(fid, c); { 'FieldId' => fid, 'Column' => col(c) }; end
def title(t); { 'Visibility' => 'VISIBLE', 'FormatText' => { 'PlainText' => t } }; end

DETAIL_FIELDS = [ufield('f-id', 'order_id'), ufield('f-region', 'region'), ufield('f-ship', 'ship_date'),
                 ufield('f-order', 'order_date'), ufield('f-amt', 'amount'), ufield('f-net', 'Net Amount')].freeze

def detail_table(vid, ttl, fields: DETAIL_FIELDS, options: nil, extra: {})
  cc = { 'FieldWells' => { 'TableUnaggregatedFieldWells' => { 'Values' => fields } } }.merge(extra)
  cc['FieldOptions'] = options if options
  { 'TableVisual' => { 'VisualId' => vid, 'Title' => title(ttl), 'ChartConfiguration' => cc } }
end

OPTIONS = {
  'SelectedFieldOptions' => [
    { 'FieldId' => 'f-id', 'CustomLabel' => 'Order Number' },
    { 'FieldId' => 'f-region', 'CustomLabel' => 'Sales Region' },
    { 'FieldId' => 'f-ship', 'Visibility' => 'HIDDEN' },
    { 'FieldId' => 'f-amt', 'CustomLabel' => 'Gross Amount', 'Width' => '120px' }],
  'Order' => %w[f-order f-id f-region f-ship f-amt f-net]
}.freeze

def analysis(visuals_by_sheet, calcs: [['Net Amount', 'ifelse({region} = \'West\', {amount} * 0.9, {amount})']])
  { 'Name' => 'Synthetic Orders', 'AnalysisId' => 'syn-1',
    'Definition' => { 'CalculatedFields' => calcs.map { |n, e| { 'DataSetIdentifier' => 'orders', 'Name' => n, 'Expression' => e } },
                      'ParameterDeclarations' => [], 'FilterGroups' => [],
                      'Sheets' => visuals_by_sheet.each_with_index.map do |vs, i|
                        { 'SheetId' => "s#{i}", 'Name' => i.zero? ? 'Orders' : 'Returns', 'Visuals' => vs }
                      end } }
end

READBACK = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'elements' => [{ 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders',
             'columns' => ['Order Id', 'Region', 'Ship Date', 'Order Date', 'Amount'].map { |n| { 'name' => n } } }] }] }.freeze

def build(analysis_h)
  dir = Dir.mktmpdir('qs-detail')
  File.write(File.join(dir, 'analysis.json'), JSON.generate(analysis_h))
  File.write(File.join(dir, 'dm-readback.json'), JSON.generate(READBACK))
  _o, e, st = Open3.capture3(RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'), '--dm-readback', File.join(dir, 'dm-readback.json'),
                             '--folder-id', 'f', '--out', File.join(dir, 'wb-spec.json'))
  abort "builder failed: #{e}" unless st.success?
  doc = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))['document']
  warns = JSON.parse(File.read(File.join(dir, 'wb-spec.warnings.json')))
  map = JSON.parse(File.read(File.join(dir, 'wb-spec.map.json')))
  [doc, warns, map, e, dir]
end

def element(doc, name); doc['elements'].find { |x| x['name'] == name }; end
def names_of(doc, name); (e = element(doc, name)) && e['columns'].map { |c| c['name'] }; end

puts 'test-qs-detail-table.rb'

# ---- 1. unaggregated table -> detail table ---------------------------------------------------
orders_vis = [detail_table('tbl-orders', 'Order Detail', options: OPTIONS,
                           extra: { 'SortConfiguration' => { 'RowSort' => [{ 'FieldSort' => { 'FieldId' => 'f-amt', 'Direction' => 'DESC' } }] },
                                    'TableOptions' => { 'Orientation' => 'VERTICAL' } }),
              { 'KPIVisual' => { 'VisualId' => 'kpi-latest', 'Title' => title('Latest Order'),
                                 'ChartConfiguration' => { 'FieldWells' => { 'Values' => [
                                   { 'DateMeasureField' => { 'FieldId' => 'k1', 'Column' => col('order_date'), 'AggregationFunction' => 'MAX' } }] } } } },
              { 'KPIVisual' => { 'VisualId' => 'kpi-amt', 'Title' => title('Total Amount'),
                                 'ChartConfiguration' => { 'FieldWells' => { 'Values' => [
                                   { 'NumericalMeasureField' => { 'FieldId' => 'k2', 'Column' => col('amount'),
                                                                  'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } },
              { 'BarChartVisual' => { 'VisualId' => 'bar-empty', 'Title' => title('Empty Bar'),
                                      'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => { 'Category' => [], 'Values' => [] } } } } }]
returns_vis = [detail_table('tbl-returns', 'Returned Orders', fields: [ufield('r-id', 'order_id'), ufield('r-amt', 'amount')])]
doc, warns, map, err, dir = build(analysis([orders_vis, returns_vis]))

t = element(doc, 'Order Detail')
ok 'an unaggregated TableVisual builds a table element', t && t['kind'] == 'table'
ok '... with NO groupings (raw detail rows)', t && !t.key?('groupings')
ok '... one passthrough column per field, labels from FieldOptions CustomLabel, in Order order',
   t && t['columns'].map { |c| c['name'] } == ['Order Date', 'Order Number', 'Sales Region', 'Ship Date', 'Gross Amount', 'Net Amount']
ok '... formulas reference the master (calc field included)',
   t && t['columns'].map { |c| c['formula'] } == ['[Orders/Order Date]', '[Orders/Order Id]', '[Orders/Region]', '[Orders/Ship Date]',
                                                  '[Orders/Amount]', '[Orders/Net Amount]']
ok '... Visibility HIDDEN becomes a hidden column', t && t['columns'].find { |c| c['name'] == 'Ship Date' }['hidden'] == true
ok '... the explicit column order is emitted', t && t['order'] == t['columns'].map { |c| c['id'] }
ok '... RowSort is applied by FieldId even though the column was relabelled',
   t && t['sort'] == [{ 'columnId' => t['columns'].find { |c| c['name'] == 'Gross Amount' }['id'], 'direction' => 'descending' }]
ok 'the second sheet\'s detail table is built too', element(doc, 'Returned Orders')
ok 'unmigrated field/table options are reported (Width, TableOptions), not dropped',
   warns['warnings'].any? { |w| w['type'] == 'TableFieldOptions' && w['reason'].include?('Width') } &&
   warns['warnings'].any? { |w| w['type'] == 'TableOptions' }

k = element(doc, 'Latest Order')
ok 'a DateMeasureField KPI builds (MAX of a date)', k && k['kind'] == 'kpi-chart' && k['columns'][0]['formula'] == 'Max([Orders/Order Date])'

ok 'a visual that builds nothing is a manual item naming it (VisualNotBuilt)',
   warns['manual'].any? { |m| m['type'] == 'VisualNotBuilt' && m['subject'].include?('Empty Bar') }
ok 'visualToElement only maps visuals that got an element',
   !map['visualToElement'].key?('bar-empty') && map['visualToElement'].values.all? { |id| doc['elements'].any? { |e| e['id'] == id } }
ok 'the build prints the manual list', err.include?('MANUAL ITEMS') && err.include?('Empty Bar')
ok 'the end-of-build summary no longer calls format notes "genuinely dropped" visuals',
   !err.match?(/genuinely dropped/) && err.match?(/0 visual\(s\) with no native Sigma kind/)

# layout step + validator on the same build (the report's end-to-end shape)
_o, lerr, lst = Open3.capture3(RUBY, LAYOUT, '--analysis', File.join(dir, 'analysis.json'), '--map', File.join(dir, 'wb-spec.map.json'),
                               '--out', File.join(dir, 'layout.xml'))
ok 'the layout step places the detail tables', lst.success? && t && File.read(File.join(dir, 'layout.xml')).include?(t['id'])
vout, verr, vst = Open3.capture3(RUBY, VALIDATOR, '--type', 'workbook', '--dm-context', File.join(dir, 'dm-readback.json'),
                                 File.join(dir, 'wb-spec.json'))
ok 'validate-spec accepts the workbook', vst.success?
puts vout + verr unless vst.success?
FileUtils.rm_rf(dir)

# ---- 2. FieldOptions: swapped labels do not collide; true duplicates get a suffix; aggregated tables too -----------
swap_fields = [ufield('s1', 'region'), ufield('s2', 'amount')]
swap_opts = { 'SelectedFieldOptions' => [{ 'FieldId' => 's1', 'CustomLabel' => 'Amount' }, { 'FieldId' => 's2', 'CustomLabel' => 'Region' }] }
dup_fields = [ufield('d1', 'order_id'), ufield('d2', 'region')]
dup_opts = { 'SelectedFieldOptions' => [{ 'FieldId' => 'd1', 'CustomLabel' => 'Key' }, { 'FieldId' => 'd2', 'CustomLabel' => 'Key' }] }
agg = { 'TableVisual' => { 'VisualId' => 'tbl-agg', 'Title' => title('By Region'), 'ChartConfiguration' => {
  'FieldWells' => { 'TableAggregatedFieldWells' => {
    'GroupBy' => [{ 'CategoricalDimensionField' => { 'FieldId' => 'g1', 'Column' => col('region') } }],
    'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => 'm1', 'Column' => col('amount'),
                                                'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } },
  'FieldOptions' => { 'SelectedFieldOptions' => [{ 'FieldId' => 'g1', 'CustomLabel' => 'Territory' }, { 'FieldId' => 'm1', 'CustomLabel' => 'Total' }] },
  'SortConfiguration' => { 'RowSort' => [{ 'FieldSort' => { 'FieldId' => 'm1', 'Direction' => 'DESC' } }] } } } }
doc, warns, _map, _e, dir = build(analysis([[detail_table('t-swap', 'Swapped', fields: swap_fields, options: swap_opts),
                                            detail_table('t-dup', 'Dup Labels', fields: dup_fields, options: dup_opts), agg]]))
ok 'swapped labels (A->B, B->A) get NO spurious (2) suffix',
   names_of(doc, 'Swapped') == %w[Amount Region]
ok 'two fields with the same label: the second is made unique',
   names_of(doc, 'Dup Labels') == ['Key', 'Key (2)']
ag = element(doc, 'By Region')
ok 'an AGGREGATED table gets its FieldOptions labels too, grouping intact',
   names_of(doc, 'By Region') == %w[Territory Total] && ag['groupings'] && ag['groupings'][0]['groupBy'].size == 1
ok 'an aggregated table sort resolves by FieldId after the relabel (no "sort skipped" warning)',
   ag && ag['sort'] && ag['sort'][0]['direction'] == 'descending' && warns['warnings'].none? { |w| w['type'] == 'SortConfiguration' }
FileUtils.rm_rf(dir)

# ---- 3. every other silent-skip branch reports ----------------------------------------------------------------------
empties = [
  ['KPIVisual', { 'FieldWells' => { 'Values' => [] } }],
  ['PieChartVisual', { 'FieldWells' => { 'PieChartAggregatedFieldWells' => { 'Category' => [], 'Values' => [] } } }],
  ['PivotTableVisual', { 'FieldWells' => { 'PivotTableAggregatedFieldWells' => { 'Rows' => [], 'Columns' => [], 'Values' => [] } } }],
  ['ComboChartVisual', { 'FieldWells' => { 'ComboChartAggregatedFieldWells' => { 'Category' => [], 'BarValues' => [], 'LineValues' => [] } } }],
  ['ScatterPlotVisual', { 'FieldWells' => { 'ScatterPlotCategoricallyAggregatedFieldWells' => { 'XAxis' => [], 'YAxis' => [] } } }],
  ['FilledMapVisual', { 'FieldWells' => { 'FilledMapAggregatedFieldWells' => { 'Geospatial' => [], 'Values' => [] } } }],
  ['HistogramVisual', { 'FieldWells' => { 'HistogramAggregatedFieldWells' => { 'Values' => [] } } }]
]
vis = empties.each_with_index.map { |(vt, cc), i| { vt => { 'VisualId' => "empty-#{i}", 'Title' => title("Empty #{vt}"), 'ChartConfiguration' => cc } } }
doc, warns, map, _e, dir = build(analysis([vis]))
ok 'every empty-wells visual type is reported as VisualNotBuilt', empties.all? { |vt, _| warns['manual'].any? { |m| m['type'] == 'VisualNotBuilt' && m['subject'].include?("Empty #{vt}") } }
ok '... and none leaves a phantom visualToElement entry', map['visualToElement'].keys.none? { |k| k.start_with?('empty-') }
FileUtils.rm_rf(dir)

puts
if $fail.zero?
  puts 'test-qs-detail-table.rb: ALL PASS'
else
  puts "test-qs-detail-table.rb: #{$fail} FAILURE(S)"
  exit 1
end
