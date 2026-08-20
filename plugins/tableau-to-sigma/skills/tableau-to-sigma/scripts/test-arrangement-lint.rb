#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-arrangement-lint.rb — layout-arrangement parity lint (PLAN-v3 PR-11).
#
# Covers lib/arrangement_lint.rb (pure) and the build-dashboard-layout.rb
# producer (layout-arrangement.json emission + WARN lines):
#   - absolute_rects: container flattening (local child coords → page-absolute)
#   - matching arrangement → clean
#   - inverted stacking → flagged, NAMING the tiles
#   - within-band left-right inversion → flagged
#   - source top-shelf controls built as a sidebar (and vice versa) → flagged
#   - quantization jitter (small center deltas, band-boundary wiggle) → NOT flagged
#   - quadrant flip → flagged; midline-ambiguous tiles → skipped
#   - E2E: the builder emits layout-arrangement.json with a clean record when
#     it mirrors the source geometry (its own output must never self-flag)
#
# Offline, creds-free. Run: ruby scripts/test-arrangement-lint.rb

require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/arrangement_lint'

BUILD = File.join(__dir__, 'build-dashboard-layout.rb')
RUBY  = RbConfig.ruby

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def tile(name, x0, x1, y0, y1)
  { name: name, role: 'tile', rect: [x0, x1, y0, y1] }
end

def ctl(name, x0, x1, y0, y1)
  { name: name, role: 'control', rect: [x0, x1, y0, y1] }
end

# ---- absolute_rects: container flattening ------------------------------------
puts '-- absolute_rects'
xml = <<~XML
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg">
  <Container elementId="band-1" type="grid" gridColumn="1 / 25" gridRow="4 / 12" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="el-a" gridColumn="1 / 13" gridRow="1 / 9"/>
    <Element elementId="el-b" gridColumn="13 / 25" gridRow="1 / 9"/>
  </Container>
  <Container elementId="rail" type="grid" gridColumn="21 / 25" gridRow="12 / 30" gridTemplateColumns="repeat(1, 1fr)" gridTemplateRows="auto">
    <Element elementId="ctl-1" gridColumn="1 / 2" gridRow="1 / 3"/>
    <Element elementId="ctl-2" gridColumn="1 / 2" gridRow="3 / 5"/>
  </Container>
  <Element elementId="el-c" gridColumn="1 / 21" gridRow="12 / 30"/>
  </Page>
XML
rects = ArrangementLint.absolute_rects(xml)
ok('page-level element keeps page coords', rects['el-c'] == [1.0, 21.0, 12.0, 30.0])
ok('band child columns map through the container span',
   rects['el-a'] == [1.0, 13.0, 4.0, 12.0] && rects['el-b'] == [13.0, 25.0, 4.0, 12.0])
ok('vertical rail (repeat(1,1fr)) children span the rail column, rows offset by the rail top',
   rects['ctl-1'] == [21.0, 25.0, 12.0, 14.0] && rects['ctl-2'] == [21.0, 25.0, 14.0, 16.0])
ok('container itself gets a rect', rects['band-1'] == [1.0, 25.0, 4.0, 12.0])

# ---- matching arrangement → clean --------------------------------------------
puts '-- matching arrangement'
# Source (canvas %): KPI row on top, two charts below side-by-side, table at bottom.
SRC_OK = [
  tile('KPI A', 2, 25, 5, 15), tile('KPI B', 27, 50, 5, 15),
  tile('Trend', 2, 49, 20, 55), tile('Split', 51, 98, 20, 55),
  tile('Detail', 2, 98, 60, 95)
]
# Built (grid units): same relative arrangement, different absolute scale + a
# header offset (rows start at 4).
BLT_OK = [
  tile('KPI A', 1, 7, 4, 8), tile('KPI B', 7, 13, 4, 8),
  tile('Trend', 1, 13, 8, 20), tile('Split', 13, 25, 8, 20),
  tile('Detail', 1, 25, 20, 34)
]
rec = ArrangementLint.compare_page('Overview', SRC_OK, BLT_OK)
ok('matching arrangement → 0 violations', rec['violations'].empty?)
ok('record carries page + tiles_compared', rec['page'] == 'Overview' && rec['tiles_compared'] == 5)
ok('checks block present (row/in-band/quadrant/shelf)',
   %w[row_band_order in_band_order quadrant controls_shelf].all? { |k| rec['checks'].key?(k) })
ok('no controls on either side → shelf class none / no mismatch',
   rec['checks']['controls_shelf'] == { 'source' => 'none', 'built' => 'none', 'mismatch' => false })

# ---- inverted stacking → flagged, naming tiles -------------------------------
puts '-- inverted stacking'
blt_inv = [
  tile('KPI A', 1, 7, 4, 8), tile('KPI B', 7, 13, 4, 8),
  tile('Trend', 1, 13, 22, 34), tile('Split', 13, 25, 22, 34), # swapped with Detail
  tile('Detail', 1, 25, 8, 22)
]
rec = ArrangementLint.compare_page('Overview', SRC_OK, blt_inv)
inv = rec['violations'].select { |v| v.include?('stacking inverted') }
ok('inverted stacking flagged', inv.any?)
ok('violation NAMES both tiles', inv.any? { |v| v.include?('"Trend"') && v.include?('"Detail"') })
ok('inversions recorded in the checks block',
   rec['checks']['row_band_order']['inversions'].include?(%w[Trend Detail]))

# ---- within-band left-right inversion → flagged ------------------------------
puts '-- left-right inversion'
blt_lr = BLT_OK.map do |t|
  case t[:name]
  when 'Trend' then tile('Trend', 13, 25, 8, 20)
  when 'Split' then tile('Split', 1, 13, 8, 20)
  else t
  end
end
rec = ArrangementLint.compare_page('Overview', SRC_OK, blt_lr)
lr = rec['violations'].select { |v| v.include?('left-right order inverted') }
ok('left-right inversion flagged', lr.any?)
ok('violation names the swapped pair', lr.any? { |v| v.include?('"Trend"') && v.include?('"Split"') })

# ---- quantization jitter → NOT flagged ---------------------------------------
puts '-- quantization jitter'
# Small center wobble (< X_JITTER) and a band boundary that merges two source
# bands into one built band must never flag.
blt_jitter = [
  tile('KPI A', 1, 7, 4, 8), tile('KPI B', 8, 13, 4, 8),          # 1-col x wobble
  tile('Trend', 2, 13, 8, 20), tile('Split', 13, 25, 9, 21),      # 1-row y wobble
  tile('Detail', 1, 25, 19, 34)                                   # slight overlap w/ chart band
]
rec = ArrangementLint.compare_page('Overview', SRC_OK, blt_jitter)
ok('grid-quantization jitter NOT flagged', rec['violations'].empty?)
# Two overlapped tiles whose source centers sit ~2% apart (a quantization-scale
# delta on the real content frame) may land in either order without a flag.
src_close = [tile('L', 47, 53, 10, 50), tile('R', 49, 55, 10, 50),
             tile('Anchor', 2, 98, 55, 95)]
blt_close = [tile('L', 12, 15, 1, 11), tile('R', 11, 14, 1, 11),
             tile('Anchor', 1, 25, 20, 34)]
rec = ArrangementLint.compare_page('P', src_close, blt_close)
ok('near-identical source centers never produce an ordering flag', rec['violations'].empty?)

# ---- quadrant flip → flagged; ambiguous centers skipped ----------------------
puts '-- quadrant flip'
src_q = [tile('Map', 2, 45, 5, 45), tile('Bars', 55, 98, 5, 45),
         tile('Table', 2, 98, 55, 95)]
blt_q = [tile('Map', 13, 25, 20, 34), tile('Bars', 1, 13, 4, 18), # Map: top-left → bottom-right
         tile('Table', 1, 25, 4, 18)]
rec = ArrangementLint.compare_page('P', src_q, blt_q)
qf = rec['violations'].select { |v| v.include?('quadrant flip') }
ok('quadrant flip flagged and names the tile', qf.any? { |v| v.include?('"Map"') })
ok('flip recorded in checks', rec['checks']['quadrant']['flips'].include?('Map'))
# A tile straddling the midline (center in the dead-band) is never compared.
src_mid = [tile('Wide', 20, 80, 5, 45), tile('Anchor', 2, 40, 55, 95), tile('Anchor2', 60, 98, 55, 95)]
blt_mid = [tile('Wide', 8, 18, 20, 30), tile('Anchor', 1, 10, 1, 10), tile('Anchor2', 15, 25, 1, 10)]
rec = ArrangementLint.compare_page('P', src_mid, blt_mid)
ok('midline-ambiguous horizontal position produces no horizontal flip for the wide tile',
   rec['violations'].none? { |v| v.include?('"Wide"') && (v.include?('left') || v.include?('right')) })

# ---- controls shelf: top-shelf vs sidebar ------------------------------------
puts '-- controls shelf class'
# Source: full-width top shelf of 3 controls above two charts.
src_shelf = [
  ctl('Region', 2, 32, 2, 8), ctl('Segment', 35, 65, 2, 8), ctl('Year', 68, 98, 2, 8),
  tile('Trend', 2, 49, 12, 95), tile('Split', 51, 98, 12, 95)
]
# Built: controls stacked in a narrow right rail instead (the field failure).
blt_rail = [
  ctl('c1', 21, 25, 4, 7), ctl('c2', 21, 25, 7, 10), ctl('c3', 21, 25, 10, 13),
  tile('Trend', 1, 11, 4, 30), tile('Split', 11, 21, 4, 30)
]
rec = ArrangementLint.compare_page('P', src_shelf, blt_rail)
ok('source classified top-shelf', rec['checks']['controls_shelf']['source'] == 'top-shelf')
ok('built classified sidebar', rec['checks']['controls_shelf']['built'] == 'sidebar')
sm = rec['violations'].select { |v| v.include?('controls-shelf class mismatch') }
ok('top-shelf → sidebar flagged', sm.any? && rec['checks']['controls_shelf']['mismatch'])

# Inverse direction: source sidebar built as a top shelf.
src_rail = [
  ctl('Metric', 2, 12, 20, 26), ctl('Region', 2, 12, 30, 36), ctl('Segment', 2, 12, 40, 46),
  tile('Main', 16, 98, 10, 95)
]
blt_shelf = [
  ctl('c1', 1, 9, 4, 7), ctl('c2', 9, 17, 4, 7), ctl('c3', 17, 25, 4, 7),
  tile('Main', 1, 25, 7, 34)
]
rec = ArrangementLint.compare_page('P', src_rail, blt_shelf)
ok('sidebar → top-shelf flagged (vice-versa direction)',
   rec['violations'].any? { |v| v.include?('controls-shelf class mismatch') })

# Matching shelves stay clean, both directions.
rec = ArrangementLint.compare_page('P', src_shelf,
                                   [ctl('c1', 1, 9, 4, 7), ctl('c2', 9, 17, 4, 7), ctl('c3', 17, 25, 4, 7),
                                    tile('Trend', 1, 13, 7, 34), tile('Split', 13, 25, 7, 34)])
ok('top-shelf built as top-shelf → clean', rec['violations'].empty?)
rec = ArrangementLint.compare_page('P', src_rail,
                                   [ctl('c1', 21, 25, 4, 7), ctl('c2', 21, 25, 7, 10), ctl('c3', 21, 25, 10, 13),
                                    tile('Main', 1, 21, 4, 34)])
ok('sidebar built as sidebar → clean', rec['violations'].empty?)
# 'scattered'/'none' never mismatches (conservative).
rec = ArrangementLint.compare_page('P', [ctl('One', 40, 60, 40, 46), tile('Main', 2, 98, 50, 95)],
                                   [ctl('c1', 21, 25, 4, 7), ctl('c2', 21, 25, 7, 10), ctl('c3', 21, 25, 10, 13),
                                    tile('Main', 1, 21, 4, 34)])
ok('scattered source class never flags a shelf mismatch', rec['violations'].empty?)

# ---- E2E: the builder emits a self-consistent layout-arrangement.json --------
puts '-- E2E producer (build-dashboard-layout.rb)'
DL = [{
  'dashboard' => 'Overview',
  'zones' => [
    { 'id' => 'z1', 'kind' => 'chart', 'caption' => 'Sales Trend', 'chart_kind' => 'bar',
      'measures' => ['m'], 'x_pct' => 1, 'y_pct' => 30, 'w_pct' => 48, 'h_pct' => 30 },
    { 'id' => 'z2', 'kind' => 'chart', 'caption' => 'Category Split', 'chart_kind' => 'line',
      'measures' => ['m'], 'x_pct' => 51, 'y_pct' => 30, 'w_pct' => 48, 'h_pct' => 30 },
    { 'id' => 'z3', 'kind' => 'chart', 'caption' => 'Order Detail', 'chart_kind' => 'table',
      'measures' => ['m'], 'x_pct' => 1, 'y_pct' => 62, 'w_pct' => 98, 'h_pct' => 36 }
  ],
  'zone_tree' => []
}].freeze
WB = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Overview', 'id' => 'page-ov', 'elements' => [
    { 'id' => 'el-1', 'kind' => 'bar-chart', 'name' => 'Sales Trend' },
    { 'id' => 'el-2', 'kind' => 'line-chart', 'name' => 'Category Split' },
    { 'id' => 'el-3', 'kind' => 'table', 'name' => 'Order Detail' }
  ] }
] }.freeze
Dir.mktmpdir do |d|
  File.write(File.join(d, 'dl.json'), JSON.generate(DL))
  File.write(File.join(d, 'wb.json'), JSON.generate(WB))
  out = File.join(d, 'layout.xml')
  log = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out], err: %i[child out], &:read)
  arr_path = File.join(d, 'layout-arrangement.json')
  ok('builder wrote layout-arrangement.json', File.exist?(arr_path))
  ok('builder announces the arrangement report', log.include?('layout-arrangement.json'))
  if File.exist?(arr_path)
    arr = JSON.parse(File.read(arr_path))
    ok('report shape: pages + violations_total + enforcement warn',
       arr['pages'].is_a?(Array) && arr.key?('violations_total') && arr['enforcement'] == 'warn')
    pg = arr['pages'].first || {}
    ok('one record for the Overview page comparing all 3 tiles',
       pg['page'] == 'Overview' && pg['tiles_compared'] == 3)
    ok('builder output does not self-flag (faithful geometry → 0 violations)',
       arr['violations_total'] == 0 && Array(pg['violations']).empty?)
    ok('no ARRANGEMENT WARN lines on a faithful build', !log.include?('ARRANGEMENT WARN'))
  end
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
