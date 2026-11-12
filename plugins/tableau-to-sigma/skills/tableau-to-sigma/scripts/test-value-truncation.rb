#!/usr/bin/env ruby
# frozen_string_literal: true
# Plan C17 (verdict overflow-hash-vs-ellipsis): values never truncate.
#  - Tables: the builder emits NO columns[].style.width today, so none may appear
#    (a narrow width truncates); any width that is ever emitted must be >= the
#    longest formatted value estimate and the header estimate.
#  - KPI value font size = min(source size, tile-width fit); no frame / no value
#    text -> source size untouched.
require 'json'
require_relative 'lib/builder_test_harness'
require_relative 'lib/pivot_widths'

fails = []
check = lambda do |cond, msg|
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# --- estimate helper -----------------------------------------------------
check.call(PivotWidths.text_px('$197,677') == 8 * 7 + 16, 'text_px("$197,677") = 72')
check.call(PivotWidths.fit_font_px('$197,676.50', 100, 36) == 10, 'fit_font_px: 100px tile, 11 chars -> 10 (verdict probe: 10 shows full value)')
check.call(PivotWidths.fit_font_px('$197,676.50', 400, 36) == 36, 'fit_font_px: wide tile keeps source 36')
check.call(PivotWidths.fit_font_px('$197,676.50', nil, 36) == 36, 'fit_font_px: unknown frame keeps source size')
check.call(PivotWidths.fit_font_px(nil, 100, 36) == 36, 'fit_font_px: unknown text keeps source size')
check.call(PivotWidths.fit_font_px('$197,676.50', 100, '36') == 10, 'fit_font_px: string source size is capped numerically')
string_unknown = PivotWidths.fit_font_px(nil, 100, '36')
check.call(string_unknown == 36 && string_unknown.is_a?(Numeric), 'fit_font_px: unknown text normalizes a string source size')

check.call(PivotWidths.fit_font_px('$197,676.50', 40, 36) == PivotWidths::KPI_MIN_READABLE_PX, 'fit_font_px: tiny tile floors at the readable minimum (8)')
check.call(PivotWidths.fit_font_px('$197,676.50', 40, 6) == 6, 'fit_font_px: source below the minimum stays source (min of source, floor)')

# --- tables: no narrow widths -------------------------------------------
tbl = BuilderTestHarness.chart_zone(id: 't1', caption: 'Tbl', chart_kind: 'table', mark_class: 'Automatic')
res = BuilderTestHarness.run([tbl], csvs: { 'Tbl' => "Region,Net Revenue\nWest,\"$197,677\"\n" })
tables = res[:elements].select { |e| e['kind'] == 'table' }
check.call(!tables.empty?, 'a table element is emitted')
widths = tables.flat_map { |t| Array(t['columns']).map { |c| [c['name'], c.dig('style', 'width')] } }
floor = { 'Region' => PivotWidths.text_px('Region'), 'Net Revenue' => PivotWidths.text_px('$197,677') }
check.call(widths.all? { |n, w| w.nil? || w >= [floor[n].to_i, PivotWidths.text_px(n)].max },
           "no table column width below its value/header estimate (got #{widths.inspect})")

# --- KPI: min(source, fit) ----------------------------------------------
def ban(id, w_pct, size)
  BuilderTestHarness.chart_zone(id: id, caption: "BAN #{id}", chart_kind: 'kpi', mark_class: 'Shape',
                                extra: { 'w_pct' => w_pct, 'kpi_value_font_size' => size })
end
csv = { 'BAN narrow' => "Net Revenue\n\"$197,676.50\"\n", 'BAN wide' => "Net Revenue\n\"$197,676.50\"\n",
        'BAN nocanvas' => "Net Revenue\n\"$197,676.50\"\n", 'BAN small' => "Net Revenue\n\"$197,676.50\"\n" }
zones = [ban('narrow', 10, 36), ban('wide', 40, 36), ban('small', 10, 6)]
r = BuilderTestHarness.run(zones, csvs: csv, canvas_px: { 'w' => 1000, 'h' => 800 })
size = ->(res, cap) { res[:elements].find { |e| e['kind'] == 'kpi-chart' && e['name'].to_s.include?(cap) } }
check.call(size.call(r, 'narrow').dig('value', 'fontSize') == 10, 'narrow tile (100px): fontSize capped to fit (10)')
check.call(size.call(r, 'wide').dig('value', 'fontSize') == 36, 'wide tile (400px): source size 36 kept')
check.call(size.call(r, 'small').dig('value', 'fontSize') == 6, 'source smaller than fit: source kept (min)')
r2 = BuilderTestHarness.run([ban('nocanvas', 10, 36)], csvs: csv)
check.call(size.call(r2, 'nocanvas').dig('value', 'fontSize') == 36, 'no canvas px: source size untouched')

abort "\nFAILED: #{fails.size}" unless fails.empty?
puts "\nALL PASS"
