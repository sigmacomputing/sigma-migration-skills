#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-qs-control-layout.rb — control order, control/navigation layout, and names of untitled visuals.
#
#   * the builder `unshift`ed controls one at a time, so they ended up in REVERSE order;
#     SheetControlLayouts (QuickSight's own control grid) was never read;
#   * build-quicksight-layout.rb's lift_controls put ALL controls in one equal-width row above
#     everything and left the navigation element to the bottom of the page;
#   * a visual with no title text was named after its VisualId, which also became its Phase 6
#     check name.
#
# Now: controls keep the SheetControlLayouts order (else the FilterControls/ParameterControls
# order) in spec and layout, rows wrap by ColumnSpan (proportional widths; at most 4 per row when
# QuickSight gave no layout), the navigation element is the FIRST band, and an untitled visual is
# named after its sheet (made unique with a numeric suffix).
#
# Offline: the REAL builder and layout step run as subprocesses.
#
# Run: ruby scripts/test-qs-control-layout.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'
require 'rbconfig'

HERE    = __dir__
BUILDER = File.join(HERE, 'build-workbook-from-quicksight.rb')
LAYOUT  = File.join(HERE, 'build-quicksight-layout.rb')
RUBY    = RbConfig.ruby

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

def bar(vid, ttl)
  v = { 'VisualId' => vid, 'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
    'Category' => [{ 'CategoricalDimensionField' => { 'FieldId' => "#{vid}-c", 'Column' => col('region') } }],
    'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => "#{vid}-v", 'Column' => col('amount'),
                                                'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } }
  v['Title'] = title(ttl) if ttl
  { 'BarChartVisual' => v }
end

def kpi(vid, ttl = nil)
  v = { 'VisualId' => vid, 'ChartConfiguration' => { 'FieldWells' => { 'Values' => [
    { 'NumericalMeasureField' => { 'FieldId' => "#{vid}-v", 'Column' => col('amount'),
                                   'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } }
  v['Title'] = title(ttl) if ttl
  { 'KPIVisual' => v }
end

CTL_COLS = { 'A' => 'region', 'B' => 'channel', 'C' => 'status_code', 'D' => 'order_id', 'E' => 'amount', 'F' => 'region2' }.freeze

# controls_in_qs_order: e.g. %w[C A B]; control_layout: { 'C' => [row, col, span] } or nil
def analysis(controls_in_qs_order, control_layout, visuals)
  groups = controls_in_qs_order.map do |k|
    { 'FilterGroupId' => "fg-#{k}", 'Status' => 'ENABLED', 'CrossDataset' => 'SINGLE_DATASET',
      'ScopeConfiguration' => { 'AllSheets' => {} },
      'Filters' => [{ 'CategoryFilter' => { 'FilterId' => "f-#{k}", 'Column' => col(CTL_COLS.fetch(k)),
                                            'Configuration' => { 'FilterListConfiguration' => { 'CategoryValues' => [], 'MatchOperator' => 'CONTAINS' } } } }] }
  end
  sheet = { 'SheetId' => 's1', 'Name' => 'Overview', 'Visuals' => visuals,
            'FilterControls' => controls_in_qs_order.map { |k| { 'Dropdown' => { 'FilterControlId' => "fc-#{k}", 'Title' => "Ctl #{k}", 'SourceFilterId' => "f-#{k}" } } },
            'Layouts' => [{ 'Configuration' => { 'GridLayout' => { 'Elements' => visuals.each_with_index.map do |v, i|
              { 'ElementId' => v.values.first['VisualId'], 'ElementType' => 'VISUAL', 'ColumnIndex' => (i % 2) * 18, 'ColumnSpan' => 18, 'RowIndex' => 10 + (i / 2) * 8, 'RowSpan' => 8 }
            end } } }] }
  if control_layout
    sheet['SheetControlLayouts'] = [{ 'Configuration' => { 'GridLayout' => { 'Elements' => control_layout.map do |k, (r, c, span)|
      { 'ElementId' => "fc-#{k}", 'ElementType' => 'FILTER_CONTROL', 'RowIndex' => r, 'ColumnIndex' => c, 'ColumnSpan' => span, 'RowSpan' => 2 }
    end } } }]
  end
  { 'Name' => 'Synthetic Orders', 'AnalysisId' => 'syn-1',
    'Definition' => { 'CalculatedFields' => [], 'ParameterDeclarations' => [], 'FilterGroups' => groups,
      'Sheets' => [sheet, { 'SheetId' => 's2', 'Name' => 'Details', 'Visuals' => [kpi('k-det')] }] } }
end

READBACK = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'pg', 'elements' => [{ 'id' => 'dm-orders', 'kind' => 'table', 'name' => 'Orders',
             'columns' => ['Region', 'Channel', 'Status Code', 'Order Id', 'Amount', 'Region2'].map { |n| { 'name' => n } } }] }] }.freeze

def build(a)
  dir = Dir.mktmpdir('qs-ctllay')
  File.write(File.join(dir, 'analysis.json'), JSON.generate(a))
  File.write(File.join(dir, 'dm-readback.json'), JSON.generate(READBACK))
  _o, e, st = Open3.capture3(RUBY, BUILDER, '--analysis', File.join(dir, 'analysis.json'), '--dm-readback', File.join(dir, 'dm-readback.json'),
                             '--folder-id', 'f', '--out', File.join(dir, 'wb-spec.json'))
  abort "builder failed: #{e}" unless st.success?
  _o, lerr, lst = Open3.capture3(RUBY, LAYOUT, '--analysis', File.join(dir, 'analysis.json'), '--map', File.join(dir, 'wb-spec.map.json'),
                                 '--out', File.join(dir, 'layout.xml'))
  abort "layout failed: #{lerr}" unless lst.success?
  r = { doc: JSON.parse(File.read(File.join(dir, 'wb-spec.json')))['document'], map: JSON.parse(File.read(File.join(dir, 'wb-spec.map.json'))),
        layout: File.read(File.join(dir, 'layout.xml')) }
  FileUtils.rm_rf(dir)
  r
end

# page-level bands of one Page: [[container_start_row, [[eid, c0, c1], ...]], ...] top to bottom
def bands(layout, page_id)
  page = layout[/<Page[^>]*id="#{page_id}">(.*?)<\/Page>/m, 1]
  out = []
  page.scan(%r{<Container elementId="([^"]+)"[^>]*gridRow="(\d+) / \d+"[^>]*>(.*?)</Container>}m).each do |_cid, r0, inner|
    out << [r0.to_i, inner.scan(%r{<Element elementId="([^"]+)" gridColumn="(\d+) / (\d+)"}).map { |e, a, b| [e, a.to_i, b.to_i] }]
  end
  out.sort_by(&:first)
end

def name_of(doc, id); (e = doc['elements'].find { |x| x['id'] == id }) && e['name']; end
def band_names(r, band); band.map { |e, a, b| [name_of(r[:doc], e) || e, a, b] }; end

puts 'test-qs-control-layout.rb'
visuals = [bar('bar-1', 'Net by Region'), kpi('kpi-1'), kpi('kpi-2'), bar('bar-2', nil)]

# ---- order + layout from SheetControlLayouts ---------------------------------------------------------
r = build(analysis(%w[C A B], { 'A' => [0, 0, 12], 'B' => [0, 12, 12], 'C' => [1, 0, 36] }, visuals))
ctl_ids = r[:map]['controlElementIds']['page-dash']
ok 'controls follow SheetControlLayouts order (A, B, C), not the FilterControls order (C, A, B)',
   ctl_ids.map { |id| name_of(r[:doc], id) } == ['Ctl A', 'Ctl B', 'Ctl C']
page_els = r[:doc]['elements'].map { |e| e['id'] }
ok '... and the spec lists them in that order (not reversed)', ctl_ids == page_els.select { |id| ctl_ids.include?(id) }
bs = bands(r[:layout], 'page-dash')
nav_band = bs[1] && bs[1][1]
nav_el = nav_band && nav_band.size == 1 && r[:doc]['elements'].find { |x| x['id'] == nav_band[0][0] }
ok 'the NAVIGATION element is the first band under the header', nav_el && nav_el['kind'] == 'navigation' && nav_band[0][1..2] == [1, 25]
ctl_band_1 = bs[2] && band_names(r, bs[2][1])
ok 'row 0 of the control layout: A and B side by side, 12 + 12 of 24 columns',
   ctl_band_1 && ctl_band_1 == [['Ctl A', 1, 13], ['Ctl B', 13, 25]]
ctl_band_2 = bs[3] && band_names(r, bs[3][1])
ok 'row 1: C spans the full width on its own row', ctl_band_2 == [['Ctl C', 1, 25]]
chart_ids = bs[4..-1].flat_map { |_row, items| items.map(&:first) }
ok 'the chart bands come after the controls and still hold every visual', (chart_ids & %w[bar-1 kpi-1 kpi-2 bar-2].map { |v| r[:map]['visualToElement'][v] }).size == 4

# ---- no SheetControlLayouts: QuickSight order kept, wrapped at 4 per row --------------------------------------
r = build(analysis(%w[C A B D E F], nil, visuals))
ctl_ids = r[:map]['controlElementIds']['page-dash']
ok 'without a control layout the FilterControls order is kept (C A B D E F)',
   ctl_ids.map { |id| name_of(r[:doc], id) } == ['Ctl C', 'Ctl A', 'Ctl B', 'Ctl D', 'Ctl E', 'Ctl F']
bs = bands(r[:layout], 'page-dash')
rows = bs.map { |_row, items| band_names(r, items).map(&:first) }.select { |names| names.all? { |n| n.start_with?('Ctl ') } }
ok 'six controls wrap into rows of at most four', rows.map(&:size) == [4, 2]
ok '... in order', rows.flatten == ['Ctl C', 'Ctl A', 'Ctl B', 'Ctl D', 'Ctl E', 'Ctl F']

# ---- untitled visual names ------------------------------------------------------------------------------------------------
names = r[:doc]['elements'].reject { |e| %w[control navigation container text].include?(e['kind']) || e['id'] == 'master' }.map { |e| e['name'] }
ok 'a visual without title text is named after its sheet, made unique',
   names.include?('Overview') && names.include?('Overview (2)') && names.include?('Details') && names.include?('Net by Region')
ok '... never after its VisualId', names.none? { |n| n.to_s =~ /\Akpi-|\Abar-/ }

puts
if $fail.zero?
  puts 'test-qs-control-layout.rb: ALL PASS'
else
  puts "test-qs-control-layout.rb: #{$fail} FAILURE(S)"
  exit 1
end
