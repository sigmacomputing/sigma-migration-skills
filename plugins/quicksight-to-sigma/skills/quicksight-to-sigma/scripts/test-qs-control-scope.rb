#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-control-scope.rb — a QuickSight FilterControl keeps the SCOPE of its FilterGroup.
#
# A QuickSight filter control only filters what its FilterGroup is scoped to (AllSheets, or per sheet
# ALL_VISUALS / SELECTED_VISUALS). build_qs_control wired EVERY control to the shared master, so a
# control scoped to one table also filtered every element sourcing the master - on other pages too -
# and control-scope.json asserted that every control reaches every queryable element.
#
# Now: scope narrower than "everything" + every in-scope element is a TABLE that can carry the column
#      -> the control is re-wired to exactly those tables (value list still from the master;
#         a hidden helper column is added where a table lacks the column), the sidecar asserts the
#         QuickSight scope (scope / mustReach), and the control is ordered AFTER its targets.
#      scope narrower + a chart/KPI/pivot/map (or an ineligible grouped table) is in scope
#         -> Sigma cannot target those, so the master wiring stays and a ControlScope manual item
#            says what the control still reaches that QuickSight would not filter.
#      scope = everything -> unchanged.
# Two controls on the same column with different scopes are two controls (the second was dropped
# as a "duplicate").
#
# Offline: the REAL builder runs as a subprocess; the shared control lint checks the result.
#
# Run: ruby scripts/test-qs-control-scope.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'rbconfig'

HERE    = __dir__
BUILDER = File.join(HERE, 'build-workbook-from-quicksight.rb')
RUBY    = RbConfig.ruby
$LOAD_PATH.unshift File.join(HERE, 'lib')
require 'control_lint'

# The assertions index into elements that only exist once the fix is in; a missing one must FAIL its
# assertion (and let the rest run), not crash the file.
class NilClass; def [](*) nil; end; end

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def col(c) { 'DataSetIdentifier' => 'orders', 'ColumnName' => c }; end
def title(t); { 'Visibility' => 'VISIBLE', 'FormatText' => { 'PlainText' => t } }; end

def detail(vid, ttl, cols)
  { 'TableVisual' => { 'VisualId' => vid, 'Title' => title(ttl), 'ChartConfiguration' => { 'FieldWells' => { 'TableUnaggregatedFieldWells' => {
    'Values' => cols.map { |c| { 'FieldId' => "#{vid}-#{c}", 'Column' => col(c) } } } } } } }
end

def grouped(vid, ttl)
  { 'TableVisual' => { 'VisualId' => vid, 'Title' => title(ttl), 'ChartConfiguration' => { 'FieldWells' => { 'TableAggregatedFieldWells' => {
    'GroupBy' => [{ 'CategoricalDimensionField' => { 'FieldId' => "#{vid}-g", 'Column' => col('channel') } }],
    'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => "#{vid}-m", 'Column' => col('amount'),
                                                'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } } }
end

def bar(vid, ttl)
  { 'BarChartVisual' => { 'VisualId' => vid, 'Title' => title(ttl), 'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
    'Category' => [{ 'CategoricalDimensionField' => { 'FieldId' => "#{vid}-c", 'Column' => col('region') } }],
    'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => "#{vid}-v", 'Column' => col('amount'),
                                                'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } } }
end

# scope: :all_sheets | [[sheet_id, 'ALL_VISUALS'|'SELECTED_VISUALS', [visual ids]], ...]
def group(gid, fid, c, scope)
  sc = scope == :all_sheets ? { 'AllSheets' => {} } :
       { 'SelectedSheets' => { 'SheetVisualScopingConfigurations' => scope.map { |sid, kind, vids|
         h = { 'SheetId' => sid, 'Scope' => kind }; h['VisualIds'] = vids if vids; h } } }
  { 'FilterGroupId' => gid, 'Status' => 'ENABLED', 'CrossDataset' => 'SINGLE_DATASET', 'ScopeConfiguration' => sc,
    'Filters' => [{ 'CategoryFilter' => { 'FilterId' => fid, 'Column' => col(c),
                                          'Configuration' => { 'FilterListConfiguration' => { 'CategoryValues' => [], 'MatchOperator' => 'CONTAINS' } } } }] }
end

def analysis(groups, controls)
  { 'Name' => 'Synthetic Orders', 'AnalysisId' => 'syn-1',
    'Definition' => { 'CalculatedFields' => [], 'ParameterDeclarations' => [], 'FilterGroups' => groups,
      'Sheets' => [
        { 'SheetId' => 's-orders', 'Name' => 'Orders',
          'Visuals' => [detail('tbl-orders', 'Order Detail', %w[order_id region amount]), grouped('tbl-chan', 'By Channel'), bar('bar-net', 'Net by Region')],
          'FilterControls' => controls.map { |cid, fid| { 'Dropdown' => { 'FilterControlId' => cid, 'Title' => cid, 'SourceFilterId' => fid } } } },
        { 'SheetId' => 's-returns', 'Name' => 'Returns', 'Visuals' => [detail('tbl-returns', 'Returned Orders', %w[order_id amount])] }] } }
end

READBACK = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'elements' => [{ 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders',
             'columns' => ['Order Id', 'Region', 'Channel', 'Amount'].map { |n| { 'name' => n } } }] }] }.freeze

def build(groups, controls)
  dir = Dir.mktmpdir('qs-ctlscope')
  File.write(File.join(dir, 'analysis.json'), JSON.generate(analysis(groups, controls)))
  File.write(File.join(dir, 'dm-readback.json'), JSON.generate(READBACK))
  _o, e, st = Open3.capture3(RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'), '--dm-readback', File.join(dir, 'dm-readback.json'),
                             '--folder-id', 'f', '--out', File.join(dir, 'wb-spec.json'))
  abort "builder failed: #{e}" unless st.success?
  spec = JSON.parse(File.read(File.join(dir, 'wb-spec.json')))
  r = { doc: spec['document'], spec: spec, warns: JSON.parse(File.read(File.join(dir, 'wb-spec.warnings.json'))),
        scope: JSON.parse(File.read(File.join(dir, 'control-scope.json'))), map: JSON.parse(File.read(File.join(dir, 'wb-spec.map.json'))), err: e }
  FileUtils.rm_rf(dir)
  r
end

def el(doc, name); doc['elements'].find { |x| x['name'] == name }; end
def controls(doc); doc['elements'].select { |x| x['kind'] == 'control' }; end
def targets(ctl); ctl['filters'].map { |f| f.dig('source', 'elementId') }; end
def manual(r, type = 'ControlScope'); (r[:warns]['manual'] || []).select { |m| m['type'] == type }; end
def lint(r); ControlLint.lint(r[:spec], scope: r[:scope]); end

puts 'test-qs-control-scope.rb'

# ---- S1: scoped to two tables -> re-wired to exactly those tables -------------------------------
r = build([group('fg1', 'f1', 'region', [['s-orders', 'SELECTED_VISUALS', ['tbl-orders']], ['s-returns', 'ALL_VISUALS', nil]])], [['fc-region', 'f1']])
d = r[:doc]
c = controls(d).first
od = el(d, 'Order Detail'); ro = el(d, 'Returned Orders')
ok 'a control scoped to two tables is wired to exactly those two tables (not the master)',
   c && targets(c).sort == [od['id'], ro['id']].sort
ok '... its value list still comes from the master column',
   c && c.dig('source', 'source', 'elementId') == 'master'
ok '... a table that lacks the column gets a HIDDEN helper column (Returned Orders has no region)',
   ro['columns'].any? { |x| x['hidden'] == true && x['formula'] == '[Orders/Region]' } &&
   targets(c).include?(ro['id']) && c['filters'].find { |f| f['source']['elementId'] == ro['id'] }['columnId'] ==
     ro['columns'].find { |x| x['hidden'] == true }['id']
ok '... and the existing column is reused where the table already has it',
   od['columns'].count { |x| x['formula'] == '[Orders/Region]' } == 1 &&
   c['filters'].find { |f| f['source']['elementId'] == od['id'] }['columnId'] == od['columns'].find { |x| x['formula'] == '[Orders/Region]' }['id']
sc = r[:scope]['controls'].first
ok 'control-scope.json asserts the QuickSight scope (scope + mustReach = the two tables)',
   sc && Array(sc['scope']).sort == [od['id'], ro['id']].sort && Array(sc['mustReach']).sort == [od['id'], ro['id']].sort
ok 'the control comes AFTER its targets in document element order (array-order dependency walk)',
   d['elements'].index { |x| x['id'] == c['id'] } > [d['elements'].index { |x| x['id'] == od['id'] }, d['elements'].index { |x| x['id'] == ro['id'] }].max
ok 'no ControlScope manual item (the scope is fully expressed)', manual(r).empty?
ok 'the shared control lint is clean on the re-wired workbook', lint(r).empty?

# ---- S2: chart in scope -> master wiring kept + manual item ---------------------------------------------------------
r = build([group('fg2', 'f2', 'region', [['s-orders', 'SELECTED_VISUALS', %w[tbl-orders bar-net]]])], [['fc-region', 'f2']])
d = r[:doc]; c = controls(d).first
ok 'a chart in scope: the control keeps the shared-master wiring', c && targets(c) == ['master']
m = manual(r).first
ok '... and a ControlScope manual item names the chart, the QuickSight scope and what is over-reached',
   m && m['reason'].include?('Net by Region') && m['reason'].include?('Order Detail') && m['reason'].include?('Returned Orders')
sc = r[:scope]['controls'].first
ok '... control-scope.json asserts only the QuickSight-scoped elements, not every element',
   sc && Array(sc['mustReach']).sort == [el(d, 'Order Detail')['id'], el(d, 'Net by Region')['id']].sort
ok '... lint stays clean', lint(r).empty?

# ---- S3/S4: scope = everything -> unchanged ----------------------------------------------------------------------------
[[:all_sheets, 'AllSheets'], [[['s-orders', 'ALL_VISUALS', nil], ['s-returns', 'ALL_VISUALS', nil]], 'ALL_VISUALS on every sheet']].each do |scope, label|
  r = build([group('fg3', 'f3', 'region', scope)], [['fc-region', 'f3']])
  c = controls(r[:doc]).first
  ok "scope #{label}: master wiring, no ControlScope item, mustReach covers every queryable element",
     c && targets(c) == ['master'] && manual(r).empty? && r[:scope]['controls'].first['mustReach'].size == 4
end

# ---- S5: a grouped table without the column cannot take a hidden helper -----------------------------------------------------------
r = build([group('fg5', 'f5', 'region', [['s-orders', 'SELECTED_VISUALS', ['tbl-chan']]])], [['fc-region', 'f5']])
c = controls(r[:doc]).first
ok 'a grouped table that does not carry the column is not re-wirable: master wiring + manual item',
   c && targets(c) == ['master'] && manual(r).any? { |x| x['reason'].include?('By Channel') }

# ---- S6: same column, different scopes -> two controls ------------------------------------------------------------------------------------
r = build([group('fg6a', 'f6a', 'region', [['s-orders', 'SELECTED_VISUALS', ['tbl-orders']]]), group('fg6b', 'f6b', 'region', :all_sheets)],
          [['fc-narrow', 'f6a'], ['fc-all', 'f6b']])
cs = controls(r[:doc])
ok 'two controls on one column with different scopes are BOTH built, with distinct controlIds',
   cs.size == 2 && cs.map { |x| x['controlId'] }.uniq.size == 2
ok '... and neither is reported as a duplicate', r[:scope]['unbound'].none? { |u| u['status'] == 'duplicate' }
ok '... the lint is clean', lint(r).empty?

puts
if $fail.zero?
  puts 'test-qs-control-scope.rb: ALL PASS'
else
  puts "test-qs-control-scope.rb: #{$fail} FAILURE(S)"
  exit 1
end
