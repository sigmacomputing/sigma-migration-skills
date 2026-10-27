#!/usr/bin/env ruby
# frozen_string_literal: true

# Crosstab (pivot) finish: runs the parser + chart builder offline on the
# synthetic fixtures/pivot-finish.twb and asserts the three fidelity fixes on
# its "KPI Crosstab" pivot:
#   1. date header format — the label rule '*m/d/yy' (leading '*' = Tableau's
#      locale-default marker) lands on the column dim as the unpadded d3-time
#      format '%-m/%-d/%y'
#   2. Measure Names on Rows (outermost) → display.stacked + measureShelfPosition
#      (and NO display.rowLayout — Sigma drops it on readback once stacked)
#   3. display-field-labels scope=cols value=false → tableComponents
#      { columnHeaders: hidden }
#   4. Measure Names member ORDER — datasource <layout measure-ordering=
#      'alphabetic'> → measures sorted by caption (not .twb document order);
#      an explicit <manual-sort> on [:Measure Names] wins over it
# Plus a negative variant: no hidden-label rule, Measure Names moved LAST on
# Rows → no tableComponents, `stacked` without a position.

require 'json'
require 'rbconfig'
require 'tmpdir'

DIR = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
FIXTURE = File.join(DIR, 'fixtures', 'pivot-finish.twb')
RUBY = RbConfig.ruby

FAILS = []
def check(condition, message)
  FAILS << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

MASTER_MAP = {
  '(?i)^Order Date$' => { 'id' => 'm-order-date', 'name' => 'Order Date' },
  '(?i)^Order Channel$' => { 'id' => 'm-order-channel', 'name' => 'Order Channel' },
  '(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Net Revenue$' => { 'id' => 'm-net-revenue', 'name' => 'Net Revenue' },
  '(?i)^Gross Revenue$' => { 'id' => 'm-gross-revenue', 'name' => 'Gross Revenue' },
  '(?i)^Net Profit$' => { 'id' => 'm-net-profit', 'name' => 'Net Profit' },
  '(?i)^Week Start$' => { 'id' => 'm-week-start', 'name' => 'Week Start' },
  '(?i)^Profit Ratio$' => { 'id' => 'm-profit-ratio', 'name' => 'Profit Ratio' },
  '(?i)^info$' => { 'id' => 'm-info', 'name' => 'info' }
}.freeze

# Parse + build one .twb text in a tmpdir; returns [meta, KPI Crosstab pivot, log].
def run_case(twb_text)
  meta = nil
  pivot = nil
  log = ''
  Dir.mktmpdir do |dir|
    twb_path = File.join(dir, 'workbook-content.twb')
    layout_path = File.join(dir, 'dashboard-layout.json')
    meta_path = File.join(dir, 'dashboard-layout-meta.json')
    map_path = File.join(dir, 'master-columns.json')
    out_path = File.join(dir, 'chart-specs.json')
    File.write(twb_path, twb_text)
    File.write(map_path, JSON.generate(MASTER_MAP))
    File.write(File.join(dir, 'get-workbook.json'),
               JSON.generate('workbook' => { 'name' => 'Pivot Finish', 'hasExtracts' => false }))
    parsed = system(RUBY, PARSER, twb_path, layout_path, out: File::NULL, err: File::NULL)
    check(parsed, 'parser completed')
    next unless parsed
    meta = JSON.parse(File.read(meta_path))
    log = IO.popen(
      [RUBY, BUILD, '--tableau-dir', dir, '--layout', layout_path, '--meta', meta_path,
       '--master-map', map_path, '--master-element-id', 'master', '--auto-controls',
       '--skip-dashboard-read', 'offline fixture', '--out', out_path],
      err: %i[child out], &:read
    )
    next unless File.exist?(out_path)
    out = JSON.parse(File.read(out_path))
    elements = out.is_a?(Array) ? out : Array(out['elements']) + Array(out['pages']).flat_map { |p| p['elements'] || [] }
    pivot = elements.find { |e| e['kind'] == 'pivot-table' && e['name'] == 'KPI Crosstab' }
  end
  [meta, pivot, log]
end

# Pivot `values` ids → the owning columns' display names, in values order.
def value_names(pivot)
  cols = Array(pivot['columns'])
  Array(pivot['values']).map { |id| (cols.find { |c| c['id'] == id } || {})['name'] }
end

fixture = File.read(FIXTURE)

# ---- positive: the fixture as authored ---------------------------------------
puts '== pivot-finish.twb as authored'
meta, pivot, log = run_case(fixture)
check(!pivot.nil?, 'builder emits the KPI Crosstab pivot-table')
ws = meta && meta.dig('worksheets', 'KPI Crosstab')
check(ws && ws['field_labels_hidden'] == ['cols'],
      "parser surfaces field_labels_hidden == ['cols'] (got #{ws && ws['field_labels_hidden'].inspect})")

if pivot
  cols = Array(pivot['columns'])
  week = cols.find { |c| c['name'] == 'Week Start' }
  check(week && week['format'] == { 'kind' => 'datetime', 'formatString' => '%-m/%-d/%y' },
        "Week Start header format is unpadded datetime %-m/%-d/%y (got #{week && week['format'].inspect})")
  region = cols.find { |c| c['name'] == 'Region' }
  check(region && !region.key?('format'), 'dimension columns without a source format get none')
  display = pivot['display'] || {}
  check(display['stacked'] == 'stacked', "display.stacked == 'stacked' (got #{display.inspect})")
  check(display['measureShelfPosition'] == 0,
        "Measure Names first on Rows → measureShelfPosition 0 (got #{display.inspect})")
  check(!display.key?('rowLayout'), "no display.rowLayout alongside stacked (got #{display.inspect})")
  check(pivot['tableComponents'] == { 'columnHeaders' => 'hidden' },
        "hidden column field labels → tableComponents columnHeaders=hidden (got #{pivot['tableComponents'].inspect})")
  check(Array(pivot['rowsBy']).size == 2 && Array(pivot['columnsBy']).size == 1,
        'rowsBy (Region, Order Channel) / columnsBy (Week Start) unchanged')
end
check(log.include?("Measure Names on Rows at position 0"), 'builder warns about the Measure Names position')
check(ws && ws['measure_names_sort'] == { 'kind' => 'alphabetic' },
      "parser: datasource measure-ordering='alphabetic' → measure_names_sort alphabetic (got #{ws && ws['measure_names_sort'].inspect})")
check(meta && !meta.dig('worksheets', 'Revenue by Region').key?('measure_names_sort'),
      'parser: worksheet without a Measure Names pill carries no measure_names_sort')
check(pivot && value_names(pivot) == ['Gross Revenue', 'Net Revenue', 'Profit Ratio'],
      "Measure Names members follow alphabetic measure-ordering (got #{pivot && value_names(pivot).inspect})")

# ---- negative: no hidden-label rule, Measure Names LAST on Rows --------------
puts '== variant: labels shown, Measure Names last on Rows'
variant = fixture.sub(%r{<style-rule element='worksheet'>.*?</style-rule>}m, '')
nested = '([federated.pivfin0001].[:Measure Names] / ([federated.pivfin0001].[none:REGION:nk] / ' \
         '[federated.pivfin0001].[none:ORDER_CHANNEL:nk]))'
moved = '(([federated.pivfin0001].[none:REGION:nk] / [federated.pivfin0001].[none:ORDER_CHANNEL:nk]) / ' \
        '[federated.pivfin0001].[:Measure Names])'
check(variant != fixture && variant.include?(nested), 'variant removed the worksheet style-rule and kept the rows shelf')
variant = variant.sub(nested, moved)
check(variant.include?(moved), 'variant moved Measure Names to the end of Rows')
meta2, pivot2, = run_case(variant)
ws2 = meta2 && meta2.dig('worksheets', 'KPI Crosstab')
check(ws2 && ws2['field_labels_hidden'] == [],
      "parser: no display-field-labels rule → field_labels_hidden == [] (got #{ws2 && ws2['field_labels_hidden'].inspect})")
check(pivot2 && !pivot2.key?('tableComponents'),
      "no tableComponents without an explicit value='false' (got #{pivot2 && pivot2['tableComponents'].inspect})")
d2 = (pivot2 && pivot2['display']) || {}
check(d2['stacked'] == 'stacked' && !d2.key?('measureShelfPosition') && !d2.key?('rowLayout'),
      "Measure Names last → stacked without a position, no rowLayout (got #{d2.inspect})")

# ---- negative: Measure Names on Columns keeps today's behavior ---------------
puts '== variant: no Measure Names pill on Rows → never stacked'
no_mn = fixture.sub(nested, '([federated.pivfin0001].[none:REGION:nk] / [federated.pivfin0001].[none:ORDER_CHANNEL:nk])')
_, pivot3, = run_case(no_mn)
d3 = (pivot3 && pivot3['display']) || {}
check(!d3.key?('stacked') && !d3.key?('measureShelfPosition'),
      "no Measure Names pill on Rows → no stacked (got #{d3.inspect})")

# ---- variant: explicit manual sort on [:Measure Names] wins over alphabetic ---
puts '== variant: manual sort on Measure Names (Profit Ratio, Net Revenue, Gross Revenue)'
manual_sort = "<manual-sort column='[federated.pivfin0001].[:Measure Names]' direction='ASC'><dictionary>" \
              '<bucket>&quot;[federated.pivfin0001].[usr:Calculation_202:qk]&quot;</bucket>' \
              '<bucket>&quot;[federated.pivfin0001].[sum:NET_REVENUE:qk]&quot;</bucket>' \
              '<bucket>&quot;[federated.pivfin0001].[sum:GROSS_REVENUE:qk]&quot;</bucket>' \
              '</dictionary></manual-sort>'
manual = fixture.sub('          <slices>', "          #{manual_sort}\n          <slices>")
check(manual != fixture, 'variant inserted a manual-sort dictionary into the KPI Crosstab view')
meta4, pivot4, = run_case(manual)
ws4 = meta4 && meta4.dig('worksheets', 'KPI Crosstab')
check(ws4 && ws4.dig('measure_names_sort', 'kind') == 'manual' &&
      ws4.dig('measure_names_sort', 'members').size == 3,
      "parser: manual-sort → measure_names_sort manual with 3 members (got #{ws4 && ws4['measure_names_sort'].inspect})")
check(pivot4 && value_names(pivot4) == ['Profit Ratio', 'Net Revenue', 'Gross Revenue'],
      "manual sort order wins over alphabetic (got #{pivot4 && value_names(pivot4).inspect})")

# ---- variant: no layout element and no manual sort → no signal, doc order ----
puts '== variant: no measure-ordering layout → no measure_names_sort'
no_layout = fixture.sub(/\s*<layout [^>]*\/>/, '')
check(no_layout != fixture, 'variant removed the datasource <layout>')
meta5, pivot5, = run_case(no_layout)
ws5 = meta5 && meta5.dig('worksheets', 'KPI Crosstab')
check(ws5 && !ws5.key?('measure_names_sort'),
      "parser: no ordering signal → key omitted (got #{ws5 && ws5['measure_names_sort'].inspect})")
check(pivot5 && value_names(pivot5).sort == ['Gross Revenue', 'Net Revenue', 'Profit Ratio'],
      "builder still emits all three members without an ordering signal (got #{pivot5 && value_names(pivot5).inspect})")

puts
if FAILS.empty?
  puts 'ALL PASS - pivot date format, Measure Names position/order, hidden field labels'
  exit 0
end

puts "FAILURES (#{FAILS.length}):"
FAILS.each { |failure| puts "  - #{failure}" }
exit 1
