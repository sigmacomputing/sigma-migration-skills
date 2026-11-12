#!/usr/bin/env ruby
# frozen_string_literal: true
# Plan C14 final-review fix 2: a native legend control is NEVER swept into a full-width
# control band. After any layout path (synthesized, banded, tree) a post-pass places each
# not-yet-placed legend control beside its chart by splitting the chart's cell (side from
# the source legend zone, share from its width, clamps legend >= 3 cols / chart >= 12). When
# the cell is too narrow the control is pruned and the chart's legend goes back to its
# pre-C14 value through the per-element sidecar.
#
# Usage:  ruby scripts/test-legend-placement.rb
require 'json'
require 'rexml/document'
require 'tmpdir'
require 'rbconfig'

BUILD = File.join(__dir__, 'build-dashboard-layout.rb')
RUBY  = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def span(attr)
  a, b = attr.to_s.split(' / ').map(&:to_i)
  [a, b]
end

def kpi_zones(n)
  (0...n).map do |i|
    { 'id' => "b#{i}", 'kind' => 'chart', 'caption' => "BAN #{i}", 'chart_kind' => 'kpi', 'show_title' => true,
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => i * 20.0, 'y_pct' => 5.0, 'w_pct' => 18.0, 'h_pct' => 10.0 }
  end
end

# chart zone x 0..chart_w, legend zone to its right (or `legend_side` :left/:top)
def dashboard(chart_w:, legend_w:, kpis: 2, legend_side: :right, neighbour: false)
  kz = kpi_zones(kpis)
  cx = legend_side == :left ? legend_w : 0.0
  lx = legend_side == :left ? 0.0 : chart_w
  chart = { 'id' => '5', 'kind' => 'chart', 'caption' => 'Seg', 'chart_kind' => 'bar', 'show_title' => true,
            'measures' => [{ 'column' => '[m]' }], 'x_pct' => cx, 'y_pct' => 20.0, 'w_pct' => chart_w, 'h_pct' => 80.0 }
  legend = { 'id' => '9', 'kind' => 'legend', 'caption' => 'Seg', 'x_pct' => lx, 'y_pct' => 20.0,
             'w_pct' => legend_w, 'h_pct' => 30.0 }
  other = { 'id' => '6', 'kind' => 'chart', 'caption' => 'Other', 'chart_kind' => 'bar', 'show_title' => true,
            'measures' => [{ 'column' => '[m]' }], 'x_pct' => chart_w + legend_w, 'y_pct' => 20.0,
            'w_pct' => 100.0 - chart_w - legend_w, 'h_pct' => 80.0 }
  extra = neighbour ? [other] : []
  d = { 'dashboard' => 'Dash', 'is_story' => false, 'canvas_px' => nil, 'zones' => kz + [chart, legend] + extra }
  d['zone_tree'] = [{ 'id' => 'root', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0,
                      'h_pct' => 100.0, 'direction' => 'vert', 'children' => [
    { 'id' => 'band', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 5.0, 'w_pct' => 100.0, 'h_pct' => 10.0,
      'direction' => 'horz', 'children' => kz.map { |z| { 'id' => z['id'], 'kind' => 'chart', 'caption' => z['caption'] } } },
    chart.dup, legend.dup] + extra.map(&:dup) }]
  [d, kz]
end

def wb_for(kz, with_legend: true, other: false, entries: nil)
  els = kz.map { |z| { 'id' => "el-#{z['id']}", 'kind' => 'kpi-chart', 'name' => z['caption'] } }
  els << { 'id' => 'el-seg', 'kind' => 'bar-chart', 'name' => 'Seg' }
  els << { 'id' => 'el-other', 'kind' => 'bar-chart', 'name' => 'Other' } if other
  # Live-proven shape (plan C live regression R1): the legend control names a column of the chart's
  # SOURCE table (the master), not the chart, and its controlId differs from its id. The layout finds
  # the chart through chart-provenance.json's legend_control_id (run() supplies it by default).
  lg = { 'id' => 'legend-9', 'kind' => 'control', 'controlType' => 'legend', 'controlId' => 'legend-9-ctl',
         'targets' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-seg' }] }
  lg['colorAssignment'] = { 'customColors' => (1..entries).map { |i| { 'value' => "v#{i}", 'color' => '#4e79a7' } } } if entries
  els << lg if with_legend
  { 'pages' => [{ 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
                { 'name' => 'Dash', 'id' => 'page-d1', 'elements' => els }] }
end

# -> { doc:, elements:, patches:, prune:, log: }
DEFAULT_PROVENANCE = { 'el-seg' => { 'worksheet' => 'Seg', 'legend_control_id' => 'legend-9' } }.freeze

def run(dash, wbj, provenance: DEFAULT_PROVENANCE)
  r = {}
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'dl.json'), JSON.generate([dash]))
    File.write(File.join(d, 'wb.json'), JSON.generate(wbj))
    File.write(File.join(d, 'chart-provenance.json'), JSON.generate('version' => 1, 'elements' => provenance)) if provenance
    out = File.join(d, 'layout.xml')
    r[:log] = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out],
                       err: %i[child out], &:read)
    abort "build produced no layout\n#{r[:log]}" unless File.exist?(out)
    r[:doc] = REXML::Document.new("<Root>#{File.read(out).sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")
    r[:elements] = JSON.parse(File.read("#{out}.elements.json"))
    r[:patches] = JSON.parse(File.read("#{out}.kpi-band-style.json"))
    r[:prune] = JSON.parse(File.read("#{out}.prune-elements.json"))
  end
  r
end

def cell(doc, id)
  e = doc.elements.to_a('//Element').find { |x| x.attributes['elementId'] == id }
  e && [span(e.attributes['gridColumn']), span(e.attributes['gridRow'])]
end

puts 'Case 1 - synthesized path (two-BAN KPI row + chart with a right-hand legend zone)'
d, kz = dashboard(chart_w: 75.0, legend_w: 25.0)
r = run(d, wb_for(kz))
check(r[:log].include?('synthesized layout'), 'used the synthesized path')
bands_with_legend = r[:doc].elements.to_a('//Container').select do |c|
  c.elements.to_a('.//Element').any? { |e| e.attributes['elementId'] == 'legend-9' } && c.attributes['elementId'].to_s =~ /-ctl\z/
end
check(bands_with_legend.empty?, 'no control band holds the legend control')
check(r[:doc].elements.to_a('//Container').none? { |c| c.attributes['elementId'].to_s.end_with?('-ctl') },
      'no control band exists at all (legend only)')
lc = cell(r[:doc], 'legend-9')
cc = cell(r[:doc], 'el-seg')
check(lc && cc, "both chart and legend control are placed (#{lc.inspect} / #{cc.inspect})")
if lc && cc
  check(lc[1] == cc[1], "legend control shares the chart's row range (#{lc[1].inspect} vs #{cc[1].inspect})")
  check(lc[0][0] == cc[0][1], "legend sits immediately right of the chart (#{lc[0].inspect} / #{cc[0].inspect})")
  check(lc[0][1] - lc[0][0] >= 3 && cc[0][1] - cc[0][0] >= 12, 'clamps hold: legend >= 3 cols, chart >= 12 cols')
  check(cc[0][1] - cc[0][0] < 24, "chart columns shrank to make room (#{cc[0].inspect})")
end
check(r[:prune]['elements'].empty?, 'nothing pruned')
check(r[:patches]['el-seg'].nil?, 'no chart legend patch when the control is placed')

puts 'Case 1b - entries + 4 rows must fit the beside-chart cell (title row + trailing Others entry)'
d, kz = dashboard(chart_w: 75.0, legend_w: 25.0)
r0 = run(d, wb_for(kz))
chart_rows = cell(r0[:doc], 'el-seg')[1]
cell_rows = chart_rows[1] - chart_rows[0]
r = run(d, wb_for(kz, entries: 8))
lc = cell(r[:doc], 'legend-9')
check(lc && lc[1][1] - lc[1][0] >= 12, "8 entries fit the #{cell_rows}-row cell and are placed with >= 12 rows (#{lc.inspect})")
fits_plus1_not_plus4 = cell_rows - 2 # entries + 1 = cell_rows - 1 fits; entries + 4 = cell_rows + 2 does not
r = run(d, wb_for(kz, entries: fits_plus1_not_plus4))
check(cell(r[:doc], 'legend-9').nil?, "#{fits_plus1_not_plus4} entries (entries + 1 fits, entries + 4 does not): not placed")
check(r[:prune]['elements'].any? { |p| p['element_id'] == 'legend-9' && p['reason'] == 'legend-no-room' }, 'pruned with legend-no-room')
check(r[:patches]['el-seg'] == { 'legend' => { 'position' => 'right' } }, 'chart keeps its own legend through the sidecar')

puts 'Case 2 - legend zone on the left of the chart'
d, kz = dashboard(chart_w: 75.0, legend_w: 25.0, legend_side: :left)
r = run(d, wb_for(kz))
lc = cell(r[:doc], 'legend-9')
cc = cell(r[:doc], 'el-seg')
check(lc && cc && lc[0][1] == cc[0][0] && lc[0][0] < cc[0][0], "legend control left of the chart (#{lc.inspect} / #{cc.inspect})")

puts 'Case 3 - too narrow to split: control pruned, chart legend restored via the sidecar'
d, kz = dashboard(chart_w: 30.0, legend_w: 15.0, neighbour: true)
r = run(d, wb_for(kz, other: true))
check(cell(r[:doc], 'legend-9').nil?, 'legend control is not placed')
check(r[:prune]['elements'].any? { |p| p['element_id'] == 'legend-9' && p['page_id'] == 'page-d1' }, "legend control is on the prune list (#{r[:prune]['elements'].inspect})")
check(r[:patches]['el-seg'] == { 'legend' => { 'position' => 'right' } }, "chart legend patch = nearest-edge position (#{r[:patches]['el-seg'].inspect})")
check(!r[:log].include?('FATAL'), 'layout validator accepts the legend prune')
prov = { 'el-seg' => { 'worksheet' => 'Seg', 'legend_fallback' => { 'position' => 'left' }, 'legend_control_id' => 'legend-9' } }
r = run(d, wb_for(kz, other: true), provenance: prov)
check(r[:patches]['el-seg'] == { 'legend' => { 'position' => 'left' } }, "builder-recorded fallback wins (#{r[:patches]['el-seg'].inspect})")

puts 'Case 4 - banded path (no KPI row): no control band for the legend'
d, kz = dashboard(chart_w: 75.0, legend_w: 25.0, kpis: 0)
d['zone_tree'] = nil
d.delete('zone_tree')
r = run(d, wb_for(kz))
check(r[:doc].elements.to_a('//Container').none? { |c| c.attributes['elementId'].to_s.end_with?('-ctl') }, 'no control band')
lc = cell(r[:doc], 'legend-9')
cc = cell(r[:doc], 'el-seg')
check(lc && cc && lc[1] == cc[1] && lc[0][0] == cc[0][1], "legend beside the chart (#{lc.inspect} / #{cc.inspect})")

puts($fails.empty? ? "\nALL PASS - C14 legend placement post-pass" : "\n#{$fails.size} FAILED")
exit($fails.empty? ? 0 : 1)
