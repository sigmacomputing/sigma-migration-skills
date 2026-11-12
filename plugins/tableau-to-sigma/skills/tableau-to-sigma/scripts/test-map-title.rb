#!/usr/bin/env ruby
# frozen_string_literal: true
# Plan C16 (verdict map-title-overlay): a map's worksheet title must sit ABOVE the
# map, not overlaid on the canvas. The map element hides its own title
# (name {visibility hidden, text}); a text element carries the title; both ride
# in a grid container so the heading band and map move/resize together.
#
# Usage:  ruby scripts/test-map-title.rb
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

def map_zone(h_pct: 100.0, show_title: true)
  { 'id' => '7', 'kind' => 'chart', 'caption' => 'Sales Map', 'chart_kind' => 'map-region',
    'show_title' => show_title, 'measures' => [{ 'column' => '[m]' }],
    'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => h_pct }
end

# tree: nil => flat zones (banded path); true => styled container (container-tree path)
def dash(name, tree:, **zopts)
  z = map_zone(**zopts)
  d = { 'dashboard' => name, 'is_story' => false, 'canvas_px' => nil, 'zones' => [z] }
  if tree
    d['zone_tree'] = [{ 'id' => '1', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
                        'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
                        'children' => [z.dup, { 'id' => '9', 'kind' => 'text', 'text_runs' => [{ 'text' => 'note' }],
                                                'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 1.0, 'h_pct' => 1.0 }] }]
  end
  d
end

def wb(map_ids)
  pages = [{ 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] }]
  map_ids.each_with_index do |(pid, pname, eid), _i|
    pages << { 'name' => pname, 'id' => pid, 'elements' => [{ 'id' => eid, 'kind' => 'region-map', 'name' => 'Sales Map' }] }
  end
  { 'pages' => pages }
end

# Returns [doc, elements_sidecar, patches, log]
def run(dashes, wbj)
  xml = els = patches = log = nil
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'dl.json'), JSON.generate(dashes))
    File.write(File.join(d, 'wb.json'), JSON.generate(wbj))
    out = File.join(d, 'layout.xml')
    log = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out],
                   err: %i[child out], &:read)
    xml = File.read(out) if File.exist?(out)
    els = JSON.parse(File.read("#{out}.elements.json")) if File.exist?("#{out}.elements.json")
    patches = JSON.parse(File.read("#{out}.kpi-band-style.json")) if File.exist?("#{out}.kpi-band-style.json")
  end
  abort "build produced no layout\n#{log}" if xml.nil?
  [REXML::Document.new("<Root>#{xml.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>"), els, patches, log]
end

def container_of(doc, page_id, map_id)
  pg = doc.elements.to_a('Root/Page').find { |p| p.attributes['id'] == page_id }
  pg.elements.to_a('.//Container').find { |c| c.attributes['elementId'] == "mapbox-#{map_id}" }
end

def span(attr)
  a, b = attr.split(' / ').map(&:to_i)
  [a, b]
end

# the map's cell on the same page when its title is not wrapped (source hides the title)
def original_cell(dashes, wbj, page_id, map_id)
  hidden = dashes.map { |d| d.merge('zones' => d['zones'].map { |z| z.merge('show_title' => false) }) }
  hidden.each { |d| d['zone_tree']&.each { |n| n['children']&.each { |c| c['show_title'] = false } } }
  doc, = run(hidden, wbj)
  pg = doc.elements.to_a('Root/Page').find { |pp| pp.attributes['id'] == page_id }
  e = pg.elements.to_a('.//Element').find { |x| x.attributes['elementId'] == map_id }
  { cols: span(e.attributes['gridColumn']), rows: span(e.attributes['gridRow']) }
end

def verify_wrapped(doc, els, patches, page_id, map_id, label, orig_cell = nil)
  puts "-- #{label}"
  text_id = "maptitle-#{map_id}"
  c = container_of(doc, page_id, map_id)
  check(!c.nil?, 'map sits inside a grid Container')
  return unless c
  check(c.attributes['type'] == 'grid', 'container is type=grid')
  kids = c.elements.to_a('Element').map { |e| [e.attributes['elementId'], span(e.attributes['gridColumn']), span(e.attributes['gridRow'])] }
  t = kids.find { |k| k[0] == text_id }
  m = kids.find { |k| k[0] == map_id }
  check(!t.nil? && !m.nil?, "container holds the title text and the map (#{kids.map(&:first).inspect})")
  return unless t && m
  check(t[2] == [1, 3], "title text occupies container rows 1 / 3 - a 2-row band (got #{t[2].inspect})")
  check(m[2][0] == 3, "map starts at container row 3 (got #{m[2].inspect})")
  check(t[1] == [1, 25] && m[1] == [1, 25], 'title and map span all 24 columns')
  inner_rows = span(c.attributes['gridRow'])
  check(m[2][1] == inner_rows[1] - inner_rows[0] + 1, "map ends at container's last internal row (#{m[2][1]})")
  page_els = els[page_id] || []
  txt = page_els.find { |e| e['id'] == text_id }
  check(txt && txt['kind'] == 'text' && txt['body'] == '<span style="font-size: 20px">Sales Map</span>',
        "text element body is a 20px span, not the 48px '#' page heading (#{txt.inspect})")
  cont = page_els.find { |e| e['id'] == c.attributes['elementId'] }
  check(cont && cont['kind'] == 'container', 'container spec element emitted in the sidecar')
  if orig_cell
    check(span(c.attributes['gridColumn']) == orig_cell[:cols] && span(c.attributes['gridRow']) == orig_cell[:rows],
          "wrapper spans exactly the map's original cell #{orig_cell.inspect} (got #{c.attributes['gridColumn']} / #{c.attributes['gridRow']})")
  end
  p = patches[map_id]
  check(p && p['name'] == { 'visibility' => 'hidden', 'text' => 'Sales Map' },
        "map name patch is {visibility hidden, text} (#{p.inspect})")
end

puts 'Case 1 - banded path (flat zones)'
doc, els, patches, = run([dash('Geo', tree: false)], wb([['page-d1', 'Geo', 'el-map']]))
verify_wrapped(doc, els, patches, 'page-d1', 'el-map', 'banded path',
               original_cell([dash('Geo', tree: false)], wb([['page-d1', 'Geo', 'el-map']]), 'page-d1', 'el-map'))

puts 'Case 2 - container-tree path (styled container)'
doc, els, patches, log = run([dash('Geo', tree: true)], wb([['page-d1', 'Geo', 'el-map']]))
check(log.include?('container-tree layout'), 'used the container-tree path')
verify_wrapped(doc, els, patches, 'page-d1', 'el-map', 'tree path',
               original_cell([dash('Geo', tree: true)], wb([['page-d1', 'Geo', 'el-map']]), 'page-d1', 'el-map'))

puts 'Case 3 - dashboard 2 with a namespaced element id (title text id follows the map id)'
doc, els, patches, = run([dash('Geo', tree: false), dash('Geo2', tree: false)],
                         wb([['page-d1', 'Geo', 'el-map'], ['page-d2', 'Geo2', 'el-map-geo2']]))
verify_wrapped(doc, els, patches, 'page-d2', 'el-map-geo2', 'dashboard 2')
verify_wrapped(doc, els, patches, 'page-d1', 'el-map', 'dashboard 1')

puts 'Case 4 - source hides the worksheet title: nothing changes'
doc, els, patches, = run([dash('Geo', tree: false, show_title: false)], wb([['page-d1', 'Geo', 'el-map']]))
check(container_of(doc, 'page-d1', 'el-map').nil?, 'map stays unwrapped')
check((els['page-d1'] || []).none? { |e| e['id'].to_s.start_with?('maptitle-') }, 'no title text element')
check(patches['el-map'].nil?, 'no name patch')

puts 'Case 5 - cell too short to host a title band plus a readable map: unchanged'
short = map_zone(h_pct: 6.0)
bar = { 'id' => '8', 'kind' => 'chart', 'caption' => 'Bar', 'chart_kind' => 'bar', 'show_title' => true,
        'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 6.0, 'w_pct' => 100.0, 'h_pct' => 94.0 }
sd = { 'dashboard' => 'Geo', 'is_story' => false, 'canvas_px' => nil, 'zones' => [short, bar],
       'zone_tree' => [{ 'id' => '1', 'kind' => 'container', 'fill_color' => '#f5f5f5ff', 'x_pct' => 0.0, 'y_pct' => 0.0,
                         'w_pct' => 100.0, 'h_pct' => 100.0, 'children' => [short.dup, bar.dup] }] }
wbs = wb([['page-d1', 'Geo', 'el-map']])
wbs['pages'][1]['elements'] << { 'id' => 'el-bar', 'kind' => 'bar-chart', 'name' => 'Bar' }
doc, els, patches, log = run([sd], wbs)
check(log.include?('container-tree layout'), 'used the container-tree path')
check(container_of(doc, 'page-d1', 'el-map').nil?, 'short map stays unwrapped')
check(patches['el-map'].nil?, 'no name patch')
check(log.include?('too short for a title band'), 'warns that the title stays on the map')

puts 'Case 6 - synthesized path (KPI band above the map)'
kz = (0..4).map do |i|
  { 'id' => "b#{i}", 'kind' => 'chart', 'caption' => "BAN #{i}", 'chart_kind' => 'kpi', 'show_title' => true,
    'measures' => [{ 'column' => '[m]' }], 'x_pct' => i * 20.0, 'y_pct' => 5.0, 'w_pct' => 18.0, 'h_pct' => 10.0 }
end
mz = map_zone(h_pct: 80.0).merge('y_pct' => 20.0)
kd = { 'dashboard' => 'Geo', 'is_story' => false, 'canvas_px' => nil, 'zones' => kz + [mz],
       'zone_tree' => [{ 'id' => 'root', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0,
                         'h_pct' => 100.0, 'direction' => 'vert', 'children' => [
                           { 'id' => 'band', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 5.0, 'w_pct' => 100.0,
                             'h_pct' => 10.0, 'direction' => 'horz',
                             'children' => kz.map { |z| { 'id' => z['id'], 'kind' => 'chart', 'caption' => z['caption'] } } },
                           mz.dup
                         ] }] }
kwb = wb([['page-d1', 'Geo', 'el-map']])
kz.each { |z| kwb['pages'][1]['elements'] << { 'id' => "el-#{z['id']}", 'kind' => 'kpi-chart', 'name' => z['caption'] } }
doc, els, patches, log = run([kd], kwb)
check(log.include?('synthesized layout'), 'used the synthesized path')
verify_wrapped(doc, els, patches, 'page-d1', 'el-map', 'synthesized path')
check(patches.key?('el-b0') && patches['el-b0']['style'], 'C6 KPI band patch still written alongside the map patch')

puts 'Case 7 - title markup is escaped in the 20px span'
$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require 'layout'
esc = SigmaLayout.map_title_text_el('t', 'A & B <i>')
check(esc['body'] == '<span style="font-size: 20px">A &amp; B &lt;i&gt;</span>', "& < > are escaped (#{esc['body']})")

puts($fails.empty? ? "\nALL PASS - C16 map title above the map" : "\n#{$fails.size} FAILED")
exit($fails.empty? ? 0 : 1)
