#!/usr/bin/env ruby
# frozen_string_literal: true
# Plan C live regression R5: on a synthesized page with a sidebar rail, a legend control whose
# source legend zone sits inside the rail goes INTO the rail (source y order, below the rail's
# controls, at least entries + 1 rows tall) and never into a `-ctl` control band. The wb-ids
# readback of a live workbook may not carry `controlType`, so the legend is also recognised
# through chart-provenance.json (legend_control_id).
#
# Usage:  ruby scripts/test-legend-rail.rb
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

def chart_zone(id, cap, x, y, w, h)
  { 'id' => id, 'kind' => 'chart', 'caption' => cap, 'chart_kind' => 'bar', 'show_title' => true,
    'measures' => [{ 'column' => '[m]' }], 'x_pct' => x, 'y_pct' => y, 'w_pct' => w, 'h_pct' => h }
end

# Left rail x 0..14: text, two filters, then a legend zone at y 49.2 (the Stress 4 shape).
def dashboard(legend_y: 49.2, legend_h: 20.7, legend_x: 0.0, legend_w: 14.0)
  zones = [
    { 'id' => '9', 'kind' => 'text', 'caption' => nil, 'x_pct' => 0.0, 'y_pct' => 6.0, 'w_pct' => 14.0, 'h_pct' => 3.8 },
    { 'id' => '10', 'kind' => 'filter', 'caption' => 'Days', 'x_pct' => 0.0, 'y_pct' => 9.8, 'w_pct' => 14.0, 'h_pct' => 16.9 },
    { 'id' => '11', 'kind' => 'filter', 'caption' => 'Store Type', 'x_pct' => 0.0, 'y_pct' => 26.7, 'w_pct' => 14.0, 'h_pct' => 22.6 },
    { 'id' => '12', 'kind' => 'legend', 'caption' => 'Mix', 'x_pct' => legend_x, 'y_pct' => legend_y, 'w_pct' => legend_w, 'h_pct' => legend_h },
    chart_zone('16', 'Dist', 14.0, 6.0, 38.7, 32.0),
    chart_zone('17', 'Heat', 52.7, 6.0, 47.3, 32.0),
    chart_zone('22', 'Mix', 14.0, 69.0, 47.3, 31.0),
    chart_zone('23', 'Share', 61.3, 69.0, 38.7, 31.0)
  ]
  { 'dashboard' => 'Dash', 'is_story' => false, 'canvas_px' => nil, 'zones' => zones, 'zone_tree' => nil }
end

def wb(entries: 4, control_type: true)
  els = [
    { 'id' => 'el-dist', 'kind' => 'bar-chart', 'name' => 'Dist' },
    { 'id' => 'el-heat', 'kind' => 'bar-chart', 'name' => 'Heat' },
    { 'id' => 'el-mix', 'kind' => 'bar-chart', 'name' => 'Mix' },
    { 'id' => 'el-share', 'kind' => 'bar-chart', 'name' => 'Share' },
    { 'id' => 'ctl-days', 'kind' => 'control', 'name' => 'Days' },
    { 'id' => 'ctl-store', 'kind' => 'control', 'name' => 'Store Type' }
  ]
  lg = { 'id' => 'legend-12', 'kind' => 'control', 'controlId' => 'legend-12-ctl',
         'targets' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-seg' }] }
  if control_type
    lg['controlType'] = 'legend'
    lg['colorAssignment'] = { 'customColors' => (1..entries).map { |i| { 'value' => "v#{i}", 'color' => '#4e79a7' } } }
  end
  els.insert(4, lg)
  { 'pages' => [{ 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
                { 'name' => 'Dash', 'id' => 'page-d1', 'elements' => els }] }
end

PROV = { 'el-mix' => { 'worksheet' => 'Mix', 'legend_control_id' => 'legend-12', 'legend_fallback' => { 'position' => 'left' } } }.freeze

def run(dash, wbj)
  r = {}
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'dl.json'), JSON.generate([dash]))
    File.write(File.join(d, 'wb.json'), JSON.generate(wbj))
    File.write(File.join(d, 'chart-provenance.json'), JSON.generate('version' => 1, 'elements' => PROV))
    out = File.join(d, 'layout.xml')
    r[:log] = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out],
                       err: %i[child out], &:read)
    abort "build produced no layout\n#{r[:log]}" unless File.exist?(out)
    r[:doc] = REXML::Document.new("<Root>#{File.read(out).sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")
    r[:patches] = JSON.parse(File.read("#{out}.kpi-band-style.json"))
    r[:prune] = JSON.parse(File.read("#{out}.prune-elements.json"))
  end
  r
end

def rail_of(doc)
  doc.elements.to_a('//Container').find { |c| c.attributes['elementId'].to_s.end_with?('-rail') }
end

def rail_cell(rail, id)
  e = rail.elements.to_a('Element').find { |x| x.attributes['elementId'] == id }
  e && span(e.attributes['gridRow'])
end

def assert_in_rail(r, entries, label)
  check(r[:log].include?('left sidebar rail'), "#{label}: synthesized path with a sidebar rail")
  rail = rail_of(r[:doc])
  check(!rail.nil?, "#{label}: rail container exists")
  return unless rail
  bands = r[:doc].elements.to_a('//Container').select { |c| c.attributes['elementId'].to_s.end_with?('-ctl') }
  check(bands.none? { |c| c.elements.to_a('.//Element').any? { |e| e.attributes['elementId'] == 'legend-12' } },
        "#{label}: no -ctl band contains the legend control")
  check(bands.empty?, "#{label}: no -ctl band exists only for the legend")
  lg = rail_cell(rail, 'legend-12')
  days = rail_cell(rail, 'ctl-days')
  store = rail_cell(rail, 'ctl-store')
  check(lg && days && store, "#{label}: legend and both filters are rail children (#{[lg, days, store].inspect})")
  return unless lg && days && store
  check(lg[0] >= store[1] && store[0] >= days[1], "#{label}: legend sits below the controls in source y order")
  check(lg[1] - lg[0] >= entries + 1, "#{label}: legend height #{lg[1] - lg[0]} >= #{entries} entries + 1")
  check(lg[1] - lg[0] >= [entries + 4, 4].max, "#{label}: legend height has room for the title and the trailing Others entry (live-measured entries + 4)")
  check(lg[1] - lg[0] >= 4, "#{label}: legend height >= 4 rows")
  check(r[:doc].elements.to_a('//Element').count { |e| e.attributes['elementId'] == 'legend-12' } == 1,
        "#{label}: legend placed exactly once")
  check(r[:prune]['elements'].none? { |p| p['element_id'] == 'legend-12' }, "#{label}: legend not pruned")
  check(r[:patches]['el-mix'].nil?, "#{label}: no chart legend fallback patch")
end

puts 'Case 1 - wb-ids carries controlType + colorAssignment (4 entries)'
assert_in_rail(run(dashboard, wb(entries: 4)), 4, 'with controlType')

puts 'Case 2 - wb-ids readback without controlType (provenance identifies the legend control)'
# entry count unknown without colorAssignment: the 4-row minimum applies
assert_in_rail(run(dashboard, wb(control_type: false)), 0, 'readback shape')

puts 'Case 3 - 7 entries: the rail cell grows to entries + 1'
assert_in_rail(run(dashboard, wb(entries: 7)), 7, 'seven entries')

puts 'Case 4 - legend zone outside the rail x-range: beside its chart, not in the rail'
r = run(dashboard(legend_x: 52.0, legend_w: 14.0, legend_y: 38.0, legend_h: 20.0), wb(entries: 4))
rail = rail_of(r[:doc])
check(rail && rail_cell(rail, 'legend-12').nil?, 'legend is not a rail child')
check(r[:doc].elements.to_a('//Container').none? { |c| c.attributes['elementId'].to_s.end_with?('-ctl') &&
                                                       c.elements.to_a('.//Element').any? { |e| e.attributes['elementId'] == 'legend-12' } },
      'legend is not in a control band')

puts 'Case 5 - 40 entries cannot fit any cell: never placed short; pruned with the chart legend restored'
r = run(dashboard, wb(entries: 40))
check(cell_missing = r[:doc].elements.to_a('//Element').none? { |e| e.attributes['elementId'] == 'legend-12' },
      'legend control is not placed anywhere')
check(r[:prune]['elements'].any? { |p| p['element_id'] == 'legend-12' && p['page_id'] == 'page-d1' && p['reason'] == 'legend-no-room' },
      "legend control is on the prune list with reason legend-no-room (#{r[:prune]['elements'].inspect})")
check(r[:patches]['el-mix'] == { 'legend' => { 'position' => 'left' } }, 'chart keeps its own legend through the sidecar')

puts
if $fails.empty?
  puts 'ALL PASS'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
