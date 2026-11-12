#!/usr/bin/env ruby
# frozen_string_literal: true

# Four builder polish gaps from the 2026-11-09 regression graders (Stress 4, Complex Pivot).
# Every emitted shape was live-probed in Sigma on 2026-11-10 (wbs 8793373b, 0b520126):
#  1. A radiolist quick filter (Tableau "(All)" radio) -> segmented control with an "All" clear
#     option (showClearLabel + clearLabel), never an empty "Select..." control.
#  2. A bar coloured by its own axis dimension (one segment per bar) -> value as the stack
#     total (dark, past the bar end); real stacks keep segment labels.
#  3. A legend control never shows an extra "Others" row (otherCategories use-legend-palette).
#  4. A pivot ratio measure with no source number format keeps the source's printed 0dp
#     (',.0f') and is flagged PRECISION-AS-SOURCE, never silently re-formatted.
require 'json'
require_relative 'lib/builder_test_harness'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end
H = BuilderTestHarness

# ---- 1. segmented "All" -------------------------------------------------------
puts '1. segmented control All option'
qf = lambda do |caption, members|
  { 'raw_class' => 'categorical', 'column_caption' => caption, 'column_guid' => caption,
    'datatype' => 'string', 'is_action' => false, 'kind' => 'list', 'members' => members }
end
filter_zone = lambda do |id, caption, mode|
  { 'id' => id, 'kind' => 'filter', 'filter_column_caption' => caption, 'control_display' => mode,
    'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 20, 'h_pct' => 10 }
end
meta = { 'shared_filters' => [qf.call('Region', []), qf.call('Segment', [])] }
res = H.run([H.chart_zone(id: 'a', caption: 'Rev by Region'),
             filter_zone.call('f1', 'Region', 'radiolist'),
             filter_zone.call('f2', 'Segment', 'compact')], meta: meta)
ok(res[:status].success?, 'builder exits 0')
ctl = ->(re) { res[:elements].find { |e| e['kind'] == 'control' && e['name'].to_s =~ re } }
seg = ctl.call(/Region/)
ok(seg && seg['controlType'] == 'segmented', 'radiolist quick filter -> segmented control')
ok(seg && seg['showClearLabel'] == true && seg['clearLabel'] == 'All',
   "segmented carries the All clear option (got #{seg && seg.slice('showClearLabel', 'clearLabel').inspect})")
ok(seg && !seg.key?('placeholder'), 'no placeholder on segmented (list-only field)')
ok(seg && seg['value'].nil?, 'no value selected (All = nothing filtered)')
lst = ctl.call(/Segment/)
ok(lst && lst['controlType'] == 'list' && lst['placeholder'] == 'All' && !lst.key?('showClearLabel'),
   'compact quick filter keeps the list + placeholder All shape')

# ---- 2. single-segment category bars ----------------------------------------------
puts '2. bar labels when colour = axis dimension'
lab = { 'mark_labels_show' => true }
zones = [
  H.chart_zone(id: 'r', caption: 'Region Share',
               extra: lab.merge('channels' => { 'color' => { 'column' => '[Region]' } })),
  H.chart_zone(id: 's', caption: 'Region by Segment',
               extra: lab.merge('channels' => { 'color' => { 'column' => '[Segment]' } })),
  H.chart_zone(id: 'p', caption: 'Plain Bar', extra: lab)
]
res2 = H.run(zones)
ok(res2[:status].success?, 'builder exits 0')
rs = H.find_chart(res2, /Region Share/)
ok(rs && rs.dig('color', 'by') == 'category', 'region share still colours by category (source colours kept)')
ok(rs && rs['dataLabel'] == { 'labels' => 'hidden', 'totals' => { 'display' => 'shown' } },
   "colour = axis dim -> stack total label (got #{rs && rs['dataLabel'].inspect})")
ok(res2[:log].include?('emitted as the stack total'), 'builder warns about the totals label')
st = H.find_chart(res2, /Region by Segment/)
ok(st && st['dataLabel'] == { 'labels' => 'shown' }, "a real stack keeps segment labels (got #{st && st['dataLabel'].inspect})")
pl = H.find_chart(res2, /Plain Bar/)
ok(pl && pl['dataLabel'] == { 'labels' => 'shown', 'anchor' => 'outside-end' }, 'single-series bar unchanged (C2 outside-end)')

# ---- 3. legend Others row -------------------------------------------------------------
puts '3. legend control Others row'
csv = "Region,Segment,Net Revenue\nEast,Standard,10\nEast,Express,20\nWest,Economy,30\nWest,Slow,40\n"
chart = H.chart_zone(id: '5', caption: 'Seg Chart', extra: { 'channels' => { 'color' => { 'column' => '[Segment]' } } })
legend = { 'id' => '9', 'kind' => 'legend', 'caption' => 'Seg Chart', 'x_pct' => 75, 'y_pct' => 0, 'w_pct' => 25, 'h_pct' => 30 }
res3 = H.run([chart, legend], csvs: { 'Seg Chart' => csv }, args: ['--page-per-dashboard'])
lg = res3[:elements].find { |e| e['controlType'] == 'legend' }
ok(lg && lg['otherCategories'] == { 'mode' => 'use-legend-palette' },
   "legend otherCategories use-legend-palette (got #{lg && lg['otherCategories'].inspect})")
ok(lg && !lg.key?('nullValues'), 'nullValues left at default (hiding nulls does not remove Others; live-probed)')

# ---- 4. pivot ratio precision -----------------------------------------------------------
puts '4. pivot ratio precision follows the source'
mm = BuilderTestHarness::MMAP.merge('(?i)^Return Rate$' => { 'id' => 'm-rr', 'name' => 'Return Rate' })
pivot = H.chart_zone(
  id: 1, caption: 'Matrix', chart_kind: 'pivot-table', mark_class: 'Automatic',
  extra: { 'w_pct' => 100,
           'rows_shelf' => { 'fields' => [{ 'caption' => 'Region', 'raw' => '[Region]', 'role' => 'dim' }] },
           'cols_shelf' => { 'fields' => [
             { 'caption' => 'Segment', 'raw' => '[Segment]', 'role' => 'dim' },
             { 'caption' => 'Return Rate', 'raw' => '[sum:Return Rate:qk]', 'derivation' => 'Sum', 'role' => 'measure' },
             { 'caption' => 'Net Revenue', 'raw' => '[sum:Net Revenue:qk]', 'derivation' => 'Sum', 'role' => 'measure' }
           ] } }
)
res4 = H.run([pivot], mmap: mm,
             csvs: { 'Matrix' => "Region,Segment,Return Rate,Net Revenue\nEast,Retail,0.02,100\nWest,Retail,0.03,200\n" })
ok(res4[:status].success?, 'builder exits 0')
piv = res4[:elements].find { |e| e['kind'] == 'pivot-table' }
col = ->(n) { Array(piv && piv['columns']).find { |c| c['name'] == n } }
ok(col.call('Return Rate')&.dig('format', 'formatString') == ',.0f',
   "ratio with no source format keeps the source's printed 0dp (got #{col.call('Return Rate')&.dig('format').inspect})")
ok(res4[:log].include?("PRECISION-AS-SOURCE: 'Matrix' pivot value 'Return Rate'"), 'ratio measure is flagged PRECISION-AS-SOURCE')
ok(!res4[:log].include?("pivot value 'Net Revenue' has no source number format"), 'non-ratio measure is not flagged')
# A ratio measure WITH a source format (worksheet pill format) prints that format and is not flagged.
pivot_fmt = pivot.merge('formats' => { '[ds].[sum:Return Rate:qk]' => 'p0.0%' })
res5 = H.run([pivot_fmt], mmap: mm,
             csvs: { 'Matrix' => "Region,Segment,Return Rate,Net Revenue\nEast,Retail,0.02,100\nWest,Retail,0.03,200\n" })
piv5 = res5[:elements].find { |e| e['kind'] == 'pivot-table' }
rr5 = Array(piv5 && piv5['columns']).find { |c| c['name'] == 'Return Rate' }
ok(rr5&.dig('format', 'formatString') == ',.1%', "source format wins (got #{rr5&.dig('format').inspect})")
ok(!res5[:log].include?('PRECISION-AS-SOURCE'), 'ratio measure with a source format is not flagged')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
