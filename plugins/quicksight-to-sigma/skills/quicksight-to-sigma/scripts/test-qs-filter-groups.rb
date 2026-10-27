#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-filter-groups.rb — FilterGroups the builder cannot express are REPORTED, never dropped.
#
# QuickSight ORs the filters inside one FilterGroup and ANDs separate groups
# (https://docs.aws.amazon.com/quicksight/latest/user/add-a-compound-filter.html). Sigma's element
# `filters[]` AND-compose, and has no OR across columns. The builder applied every static
# CategoryFilter of a SELECTED_VISUALS group as its own element filter (so a two-filter group ANDed
# instead of ORed) and silently dropped everything else: parameter-bounded TimeRangeFilters, numeric
# ranges, and sheet-wide (ALL_VISUALS) static category filters; the parameter controls feeding them
# were reported as "what-if scalar, default inlined" even when no calc field read the parameter.
#
# Rule now: a group becomes element filters only when it holds ONE static CategoryFilter on selected
# visuals. Every other enabled group is a `FilterGroupNotMigrated` item in the manual list (scope,
# conditions, parameters + defaults), the parameter controls feeding it are manual too, and a
# parameter control's "inlined" claim is made only when a calc field really reads the parameter.
#
# Offline: the REAL builder runs as a subprocess on a synthetic analysis.
#
# Run: ruby scripts/test-qs-filter-groups.rb
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
def title(t); { 'Visibility' => 'VISIBLE', 'FormatText' => { 'PlainText' => t } }; end

def bar(vid, ttl)
  { 'BarChartVisual' => { 'VisualId' => vid, 'Title' => title(ttl), 'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
    'Category' => [{ 'CategoricalDimensionField' => { 'FieldId' => "c-#{vid}", 'Column' => col('region') } }],
    'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => "v-#{vid}", 'Column' => col('amount'),
                                                'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } } }
end

def detail(vid, ttl)
  { 'TableVisual' => { 'VisualId' => vid, 'Title' => title(ttl), 'ChartConfiguration' => { 'FieldWells' => {
    'TableUnaggregatedFieldWells' => { 'Values' => [{ 'FieldId' => "u-#{vid}", 'Column' => col('order_id') }] } } } } }
end

def cat(fid, c, values = nil, select_all: nil)
  cfg = if values
          { 'CustomFilterListConfiguration' => { 'CategoryValues' => values, 'MatchOperator' => 'EQUALS', 'NullOption' => 'NON_NULLS_ONLY' } }
        else
          { 'FilterListConfiguration' => { 'CategoryValues' => [], 'MatchOperator' => 'CONTAINS' }.merge(select_all ? { 'SelectAllOptions' => select_all } : {}) }
        end
  { 'CategoryFilter' => { 'FilterId' => fid, 'Column' => col(c), 'Configuration' => cfg } }
end

def time_range(fid, c, min_param, max_param)
  { 'TimeRangeFilter' => { 'FilterId' => fid, 'Column' => col(c), 'IncludeMinimum' => true, 'IncludeMaximum' => true,
                           'RangeMinimumValue' => { 'Parameter' => min_param }, 'RangeMaximumValue' => { 'Parameter' => max_param },
                           'NullOption' => 'NON_NULLS_ONLY', 'TimeGranularity' => 'DAY' } }
end

def numeric_range(fid, c)
  { 'NumericRangeFilter' => { 'FilterId' => fid, 'Column' => col(c), 'IncludeMinimum' => true,
                              'RangeMinimumValue' => { 'StaticValue' => 100.0 }, 'NullOption' => 'NON_NULLS_ONLY' } }
end

def group(gid, filters, sheet, scope, vids = nil, status: 'ENABLED')
  c = { 'SheetId' => sheet, 'Scope' => scope }
  c['VisualIds'] = vids if vids
  { 'FilterGroupId' => gid, 'Status' => status, 'CrossDataset' => 'SINGLE_DATASET', 'Filters' => filters,
    'ScopeConfiguration' => { 'SelectedSheets' => { 'SheetVisualScopingConfigurations' => [c] } } }
end

def param(name, default)
  { 'DateTimeParameterDeclaration' => { 'Name' => name, 'DefaultValues' => { 'StaticValues' => [default] }, 'TimeGranularity' => 'DAY' } }
end

def analysis(groups:, controls: [], params: [], calcs: [])
  { 'Name' => 'Synthetic Orders', 'AnalysisId' => 'syn-1',
    'Definition' => { 'CalculatedFields' => calcs, 'ParameterDeclarations' => params, 'FilterGroups' => groups,
      'Sheets' => [
        { 'SheetId' => 's-orders', 'Name' => 'Orders', 'Visuals' => [bar('bar-net', 'Net by Region'), bar('bar-other', 'Other Bar')],
          'FilterControls' => controls.select { |c| c.values.first.key?('SourceFilterId') } },
        { 'SheetId' => 's-returns', 'Name' => 'Returns', 'Visuals' => [detail('tbl-returns', 'Returned Orders')],
          'ParameterControls' => controls.reject { |c| c.values.first.key?('SourceFilterId') } }] } }
end

READBACK = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'elements' => [{ 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders',
             'columns' => ['Order Id', 'Region', 'Channel', 'Amount', 'Order Date', 'Returned At'].map { |n| { 'name' => n } } }] }] }.freeze

def build(analysis_h)
  dir = Dir.mktmpdir('qs-fg')
  File.write(File.join(dir, 'analysis.json'), JSON.generate(analysis_h))
  File.write(File.join(dir, 'dm-readback.json'), JSON.generate(READBACK))
  _o, e, st = Open3.capture3(RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'), '--dm-readback', File.join(dir, 'dm-readback.json'),
                             '--folder-id', 'f', '--out', File.join(dir, 'wb-spec.json'))
  abort "builder failed: #{e}" unless st.success?
  doc = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))['document']
  warns = JSON.parse(File.read(File.join(dir, 'wb-spec.warnings.json')))
  scope = JSON.parse(File.read(File.join(dir, 'control-scope.json')))
  FileUtils.rm_rf(dir)
  [doc, warns, scope, e]
end

def el(doc, name); doc['elements'].find { |x| x['name'] == name }; end
def manual(warns, type = 'FilterGroupNotMigrated'); (warns['manual'] || []).select { |m| m['type'] == type }; end

puts 'test-qs-filter-groups.rb'

# ---- applied: ONE static CategoryFilter on selected visuals ---------------------------------
doc, warns, = build(analysis(groups: [group('fg-one', [cat('f1', 'channel', ['Online'])], 's-orders', 'SELECTED_VISUALS', ['bar-net'])]))
f = el(doc, 'Net by Region')['filters']
ok 'a single static CategoryFilter group still becomes ONE element filter',
   f && f.size == 1 && f[0]['values'] == ['Online'] && f[0]['mode'] == 'include'
ok '... and is not reported', manual(warns).empty?

# ---- two filters = OR: not migrated, reported --------------------------------------------------
doc, warns, _s, err = build(analysis(groups: [group('fg-or', [cat('f1', 'region', ['North']), cat('f2', 'channel', ['Online'])], 's-orders', 'SELECTED_VISUALS', ['bar-net'])]))
ok 'a two-filter (OR) group is NOT applied as two AND-composed element filters', el(doc, 'Net by Region')['filters'].nil?
m = manual(warns).find { |x| x['subject'].include?('fg-or') }
ok 'it is a FilterGroupNotMigrated item that says why (OR) and lists both conditions',
   m && m['reason'].include?('OR') && m['reason'].include?('region') && m['reason'].include?('channel')
ok '... with its scope (sheet + visual title)', m && m['reason'].include?('Orders') && m['reason'].include?('Net by Region')
ok 'the build prints the manual list', err.include?('MANUAL ITEMS') && err.include?('fg-or')

# ---- parameter-bounded range group + the parameter controls that feed it -----------------------------
params = [param('PeriodStart', '2026-01-01T00:00:00.000Z'), param('PeriodEnd', '2026-03-31T00:00:00.000Z')]
controls = [{ 'DateTimePicker' => { 'ParameterControlId' => 'pc-start', 'Title' => 'Period start', 'SourceParameterName' => 'PeriodStart' } },
            { 'DateTimePicker' => { 'ParameterControlId' => 'pc-end', 'Title' => 'Period end', 'SourceParameterName' => 'PeriodEnd' } }]
groups = [group('fg-period', [time_range('t1', 'order_date', 'PeriodStart', 'PeriodEnd'), time_range('t2', 'returned_at', 'PeriodStart', 'PeriodEnd')],
                's-returns', 'SELECTED_VISUALS', ['tbl-returns'])]
doc, warns, scope, = build(analysis(groups: groups, controls: controls, params: params))
m = manual(warns).find { |x| x['subject'].include?('fg-period') }
ok 'a parameter-bounded TimeRange group is reported with its conditions, parameters and DEFAULTS',
   m && m['reason'].include?('order_date') && m['reason'].include?('returned_at') && m['reason'].include?('PeriodStart') &&
   m['reason'].include?('2026-01-01') && m['reason'].include?('2026-03-31')
ok '... and appears nowhere as a filter', doc['elements'].none? { |x| x['filters'] && x['filters'].any? { |ff| ff.key?('values') && ff['values'].to_s =~ /2026/ } }
pc = manual(warns, 'ParameterControl')
ok 'both parameter controls feeding the group are manual items naming the group',
   pc.size == 2 && pc.all? { |x| x['reason'].include?('fg-period') }
ok '... and are NOT described as "default is inlined"', warns['warnings'].none? { |w| w['type'] == 'ParameterControl' && w['reason'].include?('inlined') }
ok 'control-scope.json records them as manual (unbound), not wired',
   scope['unbound'].count { |u| u['status'] == 'manual' } == 2 && scope['unbound'].all? { |u| u['reason'].include?('FilterGroup') }

# ---- sheet-wide static category + numeric range ---------------------------------------------------------
doc, warns, = build(analysis(groups: [group('fg-all', [cat('f1', 'region', ['North'])], 's-orders', 'ALL_VISUALS'),
                                      group('fg-num', [numeric_range('n1', 'amount')], 's-orders', 'SELECTED_VISUALS', ['bar-net'])]))
ok 'a static ALL_VISUALS category group (no control) is reported, not silently dropped',
   manual(warns).any? { |x| x['subject'].include?('fg-all') && x['reason'].include?('region') }
ok 'a NumericRangeFilter group is reported',
   manual(warns).any? { |x| x['subject'].include?('fg-num') && x['reason'].include?('amount') }

# ---- not reported: control-driven group, DISABLED group, explicit select-all -----------------------------
controls = [{ 'Dropdown' => { 'FilterControlId' => 'fc-region', 'Title' => 'Region', 'SourceFilterId' => 'f-ctl' } }]
doc, warns, scope, = build(analysis(groups: [group('fg-ctl', [cat('f-ctl', 'region')], 's-orders', 'ALL_VISUALS'),
                                             group('fg-off', [cat('f2', 'channel', ['Online'])], 's-orders', 'ALL_VISUALS', status: 'DISABLED'),
                                             group('fg-noop', [cat('f3', 'channel', select_all: 'FILTER_ALL_VALUES')], 's-orders', 'ALL_VISUALS')],
                                    controls: controls))
ok 'a control-driven group is covered by its control (built, not reported)',
   doc['elements'].any? { |x| x['kind'] == 'control' } && manual(warns).none? { |x| x['subject'].include?('fg-ctl') }
ok 'a DISABLED group is ignored', manual(warns).none? { |x| x['subject'].include?('fg-off') }
ok 'an explicit select-all (no-op) group is not reported', manual(warns).none? { |x| x['subject'].include?('fg-noop') }

# ---- the what-if wording is true --------------------------------------------------------------------------------
calcs = [{ 'DataSetIdentifier' => 'orders', 'Name' => 'Scaled Amount', 'Expression' => '{amount} * ${Rate}' }]
rate = { 'DecimalParameterDeclaration' => { 'Name' => 'Rate', 'DefaultValues' => { 'StaticValues' => [1.5] }, 'ParameterValueType' => 'SINGLE_VALUED' } }
unused = { 'DecimalParameterDeclaration' => { 'Name' => 'Spare', 'DefaultValues' => { 'StaticValues' => [2.0] }, 'ParameterValueType' => 'SINGLE_VALUED' } }
controls = [{ 'Slider' => { 'ParameterControlId' => 'pc-rate', 'Title' => 'Rate', 'SourceParameterName' => 'Rate' } },
            { 'Slider' => { 'ParameterControlId' => 'pc-spare', 'Title' => 'Spare', 'SourceParameterName' => 'Spare' } }]
doc, warns, = build(analysis(groups: [], controls: controls, params: [rate, unused], calcs: calcs))
w = warns['warnings'].select { |x| x['type'] == 'ParameterControl' }
used_w   = w.find { |x| x['reason'].include?('pc-rate') }
unused_w = w.find { |x| x['reason'].include?('pc-spare') }
ok 'a what-if parameter that a calc field reads: "inlined" is true and names the calc',
   used_w && used_w['reason'].include?('inlined') && used_w['reason'].include?('Scaled Amount')
ok 'a parameter nothing reads: no "inlined" claim, says nothing consumes it',
   unused_w && !unused_w['reason'].include?('inlined') && unused_w['reason'].include?('not read')

puts
if $fail.zero?
  puts 'test-qs-filter-groups.rb: ALL PASS'
else
  puts "test-qs-filter-groups.rb: #{$fail} FAILURE(S)"
  exit 1
end
