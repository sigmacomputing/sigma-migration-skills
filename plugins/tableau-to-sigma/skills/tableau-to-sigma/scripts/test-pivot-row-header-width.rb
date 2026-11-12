#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan C10 (verdict pivot-value-column-width): pivot display.headerWidths /
# bodyWidths .uniformWidth so row labels and values do not truncate. Display-only.
require 'json'
require_relative 'lib/builder_test_harness'
require_relative 'lib/pivot_widths'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def pivot_zone(caption)
  dim  = { 'caption' => 'Region', 'raw' => '[Region]', 'role' => 'dim' }
  cdim = { 'caption' => 'Segment', 'raw' => '[Segment]', 'role' => 'dim' }
  meas = { 'caption' => 'Net Revenue', 'raw' => '[sum:Net Revenue:qk]', 'derivation' => 'Sum', 'role' => 'measure' }
  BuilderTestHarness.chart_zone(
    id: 1, caption: caption, chart_kind: 'pivot-table', mark_class: 'Automatic',
    extra: { 'w_pct' => 100,
             'rows_shelf' => { 'fields' => [dim] }, 'cols_shelf' => { 'fields' => [cdim, meas] } }
  )
end

CSV_TEXT = "Region,Segment,Net Revenue\nElectronics,Retail,\"16,463.02\"\nElectronics,Wholesale,\"9,001.10\"\nHome,Retail,\"1,000.00\"\nHome,Wholesale,\"2.00\"\n"

res = BuilderTestHarness.run([pivot_zone('Pivot')], csvs: { 'Pivot' => CSV_TEXT },
                             canvas_px: { 'w' => 1000, 'h' => 800, 'sizing_mode' => 'fixed' })
piv = res[:elements].find { |e| e['kind'] == 'pivot-table' }
ok(!piv.nil?, 'pivot emitted')
d = (piv && piv['display']) || {}
hw = d.dig('headerWidths', 'uniformWidth')
bw = d.dig('bodyWidths', 'uniformWidth')
ok(hw.is_a?(Numeric) && hw >= 90, "row header width fits \"Electronics\" (got #{hw.inspect})")
ok(bw.is_a?(Numeric) && bw > 0, "body uniformWidth present (got #{bw.inspect})")
# Live-corrected (plan C R4): Sigma does not squeeze pivot columns to the frame and discards the whole
# width spec when header_total + body_total overflows the cell (cell = viewport - 64 = 936 at 1000).
ok(bw == (936 - hw - 8) / 2, "body = floor((936 - header - 8) / 2 value columns) (got #{bw.inspect})")
ok(!d['headerWidths'].to_h.key?('columns') && !d['bodyWidths'].to_h.key?('columns'), 'no per-column widths[]')
ok(!(piv.to_h['tableStyle'] || {}).key?('autofitColumns'), 'no autofitColumns on pivot')
ok(hw.to_f + 2 * bw.to_f <= 928, "header + body totals fit the 936px cell with 8px slack (got #{hw.to_f + 2 * bw.to_f})")

# Frame unknown -> header only (no guessed body width)
res2 = BuilderTestHarness.run([pivot_zone('Pivot')], csvs: { 'Pivot' => CSV_TEXT })
d2 = (res2[:elements].find { |e| e['kind'] == 'pivot-table' } || {})['display'] || {}
ok(d2.dig('headerWidths', 'uniformWidth').to_f >= 90, 'header width emitted without a canvas')
ok(d2['bodyWidths'].nil?, 'no body width without a known frame')

# --- R4: long-format Measure Names/Values CSV, 2 separate-column row headers, 5 regions x 5 measures
MM = {}
['Category', 'Subcategory', 'Region', 'Net Revenue', 'Gross Profit', 'Orders', 'Units', 'Discount'].each do |n|
  MM["(?i)^#{n}$"] = { 'id' => "m-#{n.downcase.tr(' ', '-')}", 'name' => n }
end
MEASURES = ['Net Revenue', 'Gross Profit', 'Orders', 'Units', 'Discount'].freeze

def fld(name, role = 'dim')
  { 'raw' => "[ds].[none:#{name}:nk]", 'role' => role, 'derivation' => 'none', 'caption' => name }
end

def mn_pivot_zone(measures, w_pct: 100)
  z = BuilderTestHarness.chart_zone(id: 'z1', caption: 'Mx', chart_kind: 'pivot-table', mark_class: 'Automatic',
                                    dim: 'Category', measure: measures.first, dim_on_rows: true, extra: { 'w_pct' => w_pct })
  shelf = { 'dim_count' => 0, 'measure_count' => 0, 'cont_measure_count' => 0, 'has_measure_values' => false }
  z['rows_shelf'] = shelf.merge('fields' => [fld('Category'), fld('Subcategory')], 'dim_count' => 2, 'has_measure_names' => false)
  z['cols_shelf'] = shelf.merge('fields' => [fld('Region'), { 'raw' => '[ds].[:Measure Names]', 'role' => 'measure-names' }],
                                'dim_count' => 1, 'has_measure_names' => true)
  z['is_crosstab'] = true
  z['aggregations'] = { '[Category]' => 'None', '[Subcategory]' => 'None', '[Region]' => 'None' }
                      .merge(measures.to_h { |m| ["[#{m}]", 'Sum'] })
  z['measures'] = measures.map { |m| { 'column' => "[#{m}]", 'derivation' => 'Sum' } }
  z
end

def mn_csv(measures, regions, cat_member)
  csv = +"Category,Measure Names,Region,Subcategory,Measure Values\n"
  [cat_member, 'Sports'].each do |c|
    ['A', 'B'].each do |s|
      regions.each { |r| measures.each { |m| csv << "#{c},#{m},#{r},#{s}-sub,1.0\n" } }
    end
  end
  csv
end

def run_mn(measures, regions, cat_member: 'Home', canvas_w: 1000, w_pct: 100)
  res = BuilderTestHarness.run([mn_pivot_zone(measures, w_pct: w_pct)], captions: ['Mx'],
                               csvs: { 'Mx' => mn_csv(measures, regions, cat_member) },
                               canvas_px: { 'w' => canvas_w, 'h' => 800, 'sizing_mode' => 'fixed' }, mmap: MM)
  [res[:elements].find { |e| e['kind'] == 'pivot-table' }, res[:log]]
end

puts '== R4: long-format Measure Names pivot, 25 value columns at canvas 1000'
el3, log3 = run_mn(MEASURES, %w[East West North South Midwest])
d3 = (el3 && el3['display']) || {}
h3 = d3.dig('headerWidths', 'uniformWidth')
b3 = d3.dig('bodyWidths', 'uniformWidth')
ok(h3.is_a?(Numeric), "header width emitted (got #{h3.inspect})")
ok(b3 == (936 - 2 * h3.to_i - 8) / 25, "long-format CSV still gets body = floor((936 - 2h - 8) / 25) (got #{b3.inspect}, h=#{h3.inspect})")
ok(2 * h3.to_i + 25 * b3.to_i <= 928, 'header + body totals <= 928 (936 cell - 8 slack)')
ok(d3['rowLayout'] == 'separate-columns', 'rowLayout separate-columns kept alongside widths')
ok(b3.to_i < 48 && log3.include?('overflow-hash-vs-ellipsis'), 'body < 48 records the overflow-hash-vs-ellipsis residual')
ok(log3.include?((2 * h3.to_i + 25 * 50 + 64).to_s), "residual names the legible viewport width (#{2 * h3.to_i + 25 * 50 + 64}px)")

puts '== R4: legible case records no residual'
el4, log4 = run_mn(MEASURES.first(2), %w[East West])
d4 = (el4 && el4['display']) || {}
h4 = d4.dig('headerWidths', 'uniformWidth')
b4 = d4.dig('bodyWidths', 'uniformWidth')
ok(b4 == (936 - 2 * h4.to_i - 8) / 4, "4 value columns: body = floor((936 - 2h - 8) / 4) (got #{b4.inspect})")
ok(!log4.include?('overflow-hash-vs-ellipsis'), 'body >= 48: no residual')

puts '== R4 round 1: tiles sharing a row lose gutter + padding (live-measured cells)'
# Live measurements at a 1000px viewport: full width 936, half 444, third 280 (16px gap, 32px element padding).
ok(PivotWidths.cell_px(1000, 100) == 936, 'full-width cell = canvas - 64 (936)')
ok(PivotWidths.cell_px(1000, 50) == 436, "half-width cell = 436 (measured 444; conservative by one extra gap), got #{PivotWidths.cell_px(1000, 50).inspect}")
ok(PivotWidths.cell_px(1000, 33.33) == 274, "third-width cell = 274 (measured 280), got #{PivotWidths.cell_px(1000, 33.33).inspect}")
ok(PivotWidths.cell_px(1000, 50) <= 444 && PivotWidths.cell_px(1000, 50) >= 444 - 16, 'half-width never above the measured cell, within one gap of it')
ok(PivotWidths.cell_px(1000, 33.33) <= 280 && PivotWidths.cell_px(1000, 33.33) >= 280 - 16, 'third-width never above the measured cell, within one gap of it')
ok(PivotWidths.cell_px(nil, 50).nil? && PivotWidths.cell_px(1000, 0).nil?, 'unknown canvas / zone width -> no cell')
el5, = run_mn(MEASURES.first(2), %w[East West], canvas_w: 1000, w_pct: 50)
d5 = (el5 && el5['display']) || {}
h5 = d5.dig('headerWidths', 'uniformWidth')
ok(d5.dig('bodyWidths', 'uniformWidth') == (436 - 2 * h5.to_i - 8) / 4, 'half-width zone: body from the 436px cell')
ok(2 * h5.to_i + 4 * d5.dig('bodyWidths', 'uniformWidth').to_i <= 444 - 8, 'half-width totals fit the measured 444px cell with slack')

puts '== R4 round 1: legible viewport scales with the zone width'
ok(PivotWidths.legible_viewport_px(93, 2, 25, 100) == 2 * 93 + 25 * 50 + 64, 'full-width legible viewport = 2h + 50n + 64')
ok(PivotWidths.legible_viewport_px(93, 2, 25, 50) == (2 * 93 + 25 * 50) * 2 + 64, 'half-width zone needs a viewport twice as wide before the +64')
el8, log8 = run_mn(MEASURES, %w[East West North South Midwest], w_pct: 50)
h8 = PivotWidths.text_px('Sports') # longest row member; 25 columns in a 436px cell give body 12 -> no widths emitted
ok(!(el8['display'] || {}).key?('bodyWidths'), 'half-width 25 columns: body under 16px -> no widths')
ok(log8.include?(PivotWidths.legible_viewport_px(h8, 2, 25, 50).to_s), "residual names the w_pct-scaled viewport (#{PivotWidths.legible_viewport_px(h8, 2, 25, 50)}px)")

puts '== R4: header cap n_hdr x header <= 0.35 x frame'
el6, = run_mn(MEASURES.first(2), %w[East West], cat_member: 'X' * 60)
d6 = (el6 && el6['display']) || {}
h6 = d6.dig('headerWidths', 'uniformWidth')
ok(h6 == (0.35 * 936 / 2).floor, "two-column header capped to floor(0.35 * 936 / 2) (got #{h6.inspect})")
ok(d6.dig('bodyWidths', 'uniformWidth') == (936 - 2 * h6.to_i - 8) / 4, 'body computed from the capped header')

puts '== R4: body < 16 -> no widths at all, residual recorded'
many = (1..20).map { |i| "M#{i}" }
mmap_many = MM.merge(many.to_h { |m| ["(?i)^#{m}$", { 'id' => "m-#{m.downcase}", 'name' => m }] })
zmany = mn_pivot_zone(many)
res7 = BuilderTestHarness.run([zmany], captions: ['Mx'], csvs: { 'Mx' => mn_csv(many, %w[E W N S M], 'Home') },
                                       canvas_px: { 'w' => 1000, 'h' => 800, 'sizing_mode' => 'fixed' }, mmap: mmap_many)
el7 = res7[:elements].find { |e| e['kind'] == 'pivot-table' }
d7 = (el7 && el7['display']) || {}
ok(el7 && !d7.key?('headerWidths') && !d7.key?('bodyWidths'), "100 columns (body would be < 16): no width spec (got #{d7.inspect})")
ok(res7[:log].include?('overflow-hash-vs-ellipsis'), 'residual recorded when widths are omitted')

puts '== R6: squeezed pivot (body < 48) gets the legible tableStyle'
t3 = (el3 && el3['tableStyle']) || {}
ok(t3['cellSpacing'] == 'extra-small', "body 28: cellSpacing extra-small (got #{t3['cellSpacing'].inspect})")
ok(t3.dig('textStyles', 'columnHeader', 'fontSize') == 8, 'columnHeader fontSize 8')
ok(t3.dig('textStyles', 'cell', 'fontSize') == 9, 'cell fontSize 9')
ok(t3.dig('textStyles', 'header', 'fontSize') == 9, 'header fontSize 9')
ok(!t3.key?('banding') && !t3.key?('bandingColor') && !t3.key?('heavyHorizontalDividers'), 'no banding / dividers without a TWB band fact')
ok(!t3.key?('textWrap') && !t3.dig('textStyles', 'columnHeader').to_h.key?('textWrap'), 'no textWrap (live: no effect on pivot headers)')
ok(log3.include?('pivot residual row-height-fixed') && log3.include?('cannot stretch'), 'residual: Sigma pivot rows cannot stretch to the frame height')
ok(d3.dig('bodyWidths', 'uniformWidth') == b3, 'widths unchanged by the style merge')
ok(el4 && !el4.key?('tableStyle'), 'body >= 48: tableStyle untouched (absent)')
ok(!log4.include?('row-height-fixed'), 'body >= 48: no row-height residual')
ok(el7 && !el7.key?('tableStyle'), 'widths omitted (body < 16): tableStyle untouched')

puts '== R6: merge keeps existing tableStyle keys, existing values win'
existing = { 'banding' => 'shown', 'bandingColor' => '#eeeeee', 'cellSpacing' => 'small',
             'textStyles' => { 'cell' => { 'fontSize' => 11, 'align' => 'center' }, 'columnHeader' => { 'fontWeight' => 'bold' } } }
m = PivotWidths.merge_squeezed_table_style(existing)
ok(m['banding'] == 'shown' && m['bandingColor'] == '#eeeeee', 'existing banding preserved')
ok(m['cellSpacing'] == 'small', 'existing explicit cellSpacing wins')
ok(m.dig('textStyles', 'cell') == { 'fontSize' => 11, 'align' => 'center' }, 'existing cell style (fontSize, align) wins intact')
ok(m.dig('textStyles', 'columnHeader') == { 'fontWeight' => 'bold', 'fontSize' => 8 }, 'columnHeader gains fontSize 8, keeps fontWeight')
ok(m.dig('textStyles', 'header', 'fontSize') == 9, 'header fontSize 9 added')
ok(existing.dig('textStyles', 'columnHeader') == { 'fontWeight' => 'bold' }, 'input not mutated')
ok(PivotWidths.merge_squeezed_table_style(nil) == { 'cellSpacing' => 'extra-small', 'textStyles' => { 'columnHeader' => { 'fontSize' => 8 }, 'cell' => { 'fontSize' => 9 }, 'header' => { 'fontSize' => 9 } } }, 'nil -> exactly the squeezed recipe')

if $fails.empty?
  puts 'ALL PASS'
else
  puts "FAILED: #{$fails.size}"
  exit 1
end
