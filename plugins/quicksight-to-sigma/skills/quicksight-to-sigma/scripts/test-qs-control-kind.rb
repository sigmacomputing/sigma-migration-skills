#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-control-kind.rb — the Sigma control kind comes from the bound column's TYPE.
#
# build_qs_control used to decide `date-range` vs `list` from the column NAME
# (/(^|_)(date|dt|timestamp)(_|$)/): a text column called `ship_date` became a date-range
# control, while a datetime column without a date token in its name (`returned_at`) became a
# `list` control — which the spec API strips on POST (refs/catalogs/control.json).
#
# Authority order (decision): the data model's own column type (dm-readback columnTypes, from
# GET /v2/dataModels/{id}/columns) > the dataset OutputColumns type (--discover-dir) > the name
# heuristic, which now warns (type ControlKind) because it is a guess. datetime -> date-range,
# anything else -> list.
#
# Offline: the REAL builder runs as a subprocess on a synthetic analysis.
#
# Run: ruby scripts/test-qs-control-kind.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'rbconfig'

HERE    = __dir__
BUILDER = File.join(HERE, 'build-workbook-from-quicksight.rb')
RUBY    = RbConfig.ruby

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def col(c) { 'DataSetIdentifier' => 'orders', 'ColumnName' => c }; end

LABELS = { 'region' => 'Region', 'amount' => 'Amount', 'ship_date' => 'Ship Date', 'returned_at' => 'Returned At',
           'order_date' => 'Order Date', 'status_code' => 'Status Code' }.freeze

# One sheet: a bar chart (so the page has content) + ONE filter control on `raw`.
def analysis(raw, wrap)
  filter = wrap == 'DateTimePicker' ?
    { 'TimeRangeFilter' => { 'FilterId' => 'flt', 'Column' => col(raw), 'IncludeMinimum' => true, 'IncludeMaximum' => true } } :
    { 'CategoryFilter' => { 'FilterId' => 'flt', 'Column' => col(raw),
                            'Configuration' => { 'FilterListConfiguration' => { 'CategoryValues' => [], 'MatchOperator' => 'CONTAINS' } } } }
  { 'Name' => 'Synthetic Orders', 'AnalysisId' => 'syn-1',
    'Definition' => { 'CalculatedFields' => [], 'ParameterDeclarations' => [],
      'FilterGroups' => [{ 'FilterGroupId' => 'fg', 'Status' => 'ENABLED', 'CrossDataset' => 'SINGLE_DATASET', 'Filters' => [filter],
                           'ScopeConfiguration' => { 'SelectedSheets' => { 'SheetVisualScopingConfigurations' => [
                             { 'SheetId' => 's1', 'Scope' => 'ALL_VISUALS' }] } } }],
      'Sheets' => [{ 'SheetId' => 's1', 'Name' => 'Overview',
        'FilterControls' => [{ wrap => { 'FilterControlId' => 'fc', 'Title' => 'Control', 'SourceFilterId' => 'flt' } }],
        'Visuals' => [{ 'BarChartVisual' => { 'VisualId' => 'b1', 'Title' => { 'FormatText' => { 'PlainText' => 'Amount by Region' } },
          'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
            'Category' => [{ 'CategoricalDimensionField' => { 'FieldId' => 'c1', 'Column' => col('region') } }],
            'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => 'v1', 'Column' => col('amount'),
                           'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } } }] }] } }
end

# dm_types: { raw => sigma type } stamped as columnTypes; ds_types: { raw => QS OutputColumns type }.
def control(raw, wrap: 'Dropdown', dm_types: nil, ds_types: nil)
  Dir.mktmpdir('qs-ctlkind') do |dir|
    el = { 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders', 'columnLabels' => LABELS.values }
    el['columnTypes'] = dm_types.each_with_object({}) { |(r, t), h| h[LABELS.fetch(r)] = t } if dm_types
    File.write(File.join(dir, 'dm-readback.json'),
               JSON.generate('dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'elements' => [el] }]))
    File.write(File.join(dir, 'analysis.json'), JSON.generate(analysis(raw, wrap)))
    args = [RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'), '--dm-readback', File.join(dir, 'dm-readback.json'),
            '--folder-id', 'f', '--out', File.join(dir, 'wb-spec.json')]
    if ds_types
      FileUtils.mkdir_p(File.join(dir, 'disc', 'datasets'))
      File.write(File.join(dir, 'disc', 'datasets', 'orders.json'), JSON.generate('DataSet' => {
        'DataSetId' => 'orders', 'PhysicalTableMap' => {},
        'OutputColumns' => ds_types.map { |n, t| { 'Name' => n, 'Type' => t } } }))
      args += ['--discover-dir', File.join(dir, 'disc')]
    end
    _o, e, st = Open3.capture3(*args)
    abort "builder failed: #{e}" unless st.success?
    doc = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))['document']
    warns = JSON.parse(File.read(File.join(dir, 'wb-spec.warnings.json')))['warnings']
    [doc['elements'].find { |x| x['kind'] == 'control' }, warns]
  end
end

puts 'test-qs-control-kind.rb'

# ---- data-model type is the authority ----------------------------------------------------
c, w = control('ship_date', dm_types: { 'ship_date' => 'text' })
ok 'text column named ship_date (DM type text) -> list, not date-range', c && c['controlType'] == 'list'
ok '... with no ControlKind warning (the type decided it)', w.none? { |x| x['type'] == 'ControlKind' }

c, w = control('returned_at', dm_types: { 'returned_at' => 'datetime' })
ok 'datetime column with no date token in its name (DM type datetime) -> date-range', c && c['controlType'] == 'date-range'
ok 'date-range keeps its flat between mode and filter wiring', c && c['mode'] == 'between' && Array(c['filters']).size == 1

c, = control('order_date', wrap: 'DateTimePicker', dm_types: { 'order_date' => 'datetime' })
ok 'a DateTimePicker on a datetime column -> date-range', c && c['controlType'] == 'date-range'

c, w = control('ship_date', wrap: 'DateTimePicker', dm_types: { 'ship_date' => 'text' })
ok 'a DateTimePicker bound to a TEXT column follows the column type (list) and says so',
   c && c['controlType'] == 'list' && w.any? { |x| x['type'] == 'ControlKind' && x['reason'].include?('DateTimePicker') }

# ---- dataset OutputColumns is the second authority ---------------------------------------------
ds = { 'ship_date' => 'STRING', 'returned_at' => 'DATETIME', 'region' => 'STRING', 'amount' => 'DECIMAL' }
c, w = control('returned_at', ds_types: ds)
ok 'no DM types: dataset DATETIME -> date-range', c && c['controlType'] == 'date-range'
c, = control('ship_date', ds_types: ds)
ok 'no DM types: dataset STRING named ship_date -> list', c && c['controlType'] == 'list'

c, = control('returned_at', dm_types: { 'returned_at' => 'text' }, ds_types: ds)
ok 'the DATA MODEL type outranks the dataset type (DM text beats dataset DATETIME) -> list', c && c['controlType'] == 'list'

# ---- name heuristic is the last resort and WARNS -----------------------------------------------------
c, w = control('order_date')
ok 'no type anywhere + date-ish name -> date-range (heuristic)', c && c['controlType'] == 'date-range'
ok '... and a ControlKind warning says the kind is a name guess',
   w.any? { |x| x['type'] == 'ControlKind' && x['reason'].include?('order_date') }
c, w = control('status_code')
ok 'no type anywhere + plain name -> list, also flagged (no type authority was available)',
   c && c['controlType'] == 'list' && w.any? { |x| x['type'] == 'ControlKind' }

puts
if $fail.zero?
  puts 'test-qs-control-kind.rb: ALL PASS'
else
  puts "test-qs-control-kind.rb: #{$fail} FAILURE(S)"
  exit 1
end
