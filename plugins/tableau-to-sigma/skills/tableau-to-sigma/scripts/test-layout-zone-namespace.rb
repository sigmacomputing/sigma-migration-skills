#!/usr/bin/env ruby
# frozen_string_literal: true
# Zone ids restart on every Tableau dashboard, so build-charts' namespace pass
# renames "text-2"/"btn-3".. on dashboards 2+ to "<stem>-<dashboard-slug>".
# The layout must resolve those per page: the title + nav buttons of a later
# dashboard belong in ITS header band, never swept into the bottom "-extra"
# safety-net band.
#
# Usage:  ruby scripts/test-layout-zone-namespace.rb
require 'json'
require 'rexml/document'
require 'tmpdir'
require 'rbconfig'

BUILD = File.join(__dir__, 'build-dashboard-layout.rb')
RUBY  = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def dash(name, chart_caption)
  btn = lambda do |id, x|
    { 'id' => id, 'kind' => 'dashboard-object', 'x_pct' => x, 'y_pct' => 1.0, 'w_pct' => 18.0, 'h_pct' => 4.0 }
  end
  title = { 'id' => '2', 'kind' => 'text', 'text_runs' => [{ 'text' => name }],
            'x_pct' => 0.0, 'y_pct' => 1.0, 'w_pct' => 40.0, 'h_pct' => 4.0 }
  chart = { 'id' => '7', 'kind' => 'chart', 'caption' => chart_caption, 'chart_kind' => 'bar',
            'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 20.0, 'w_pct' => 100.0, 'h_pct' => 80.0 }
  zs = [title, btn.call('3', 40.0), btn.call('4', 60.0), btn.call('5', 80.0), chart]
  { 'dashboard' => name, 'is_story' => false, 'canvas_px' => nil, 'zones' => zs,
    'zone_tree' => [{ 'id' => '1', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
                      'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
                      'children' => zs.map(&:dup) }] }
end

def button(id)
  { 'id' => id, 'kind' => 'button', 'name' => nil }
end

WB = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Overview', 'id' => 'page-d1', 'elements' => [
    { 'id' => 'text-2', 'kind' => 'text', 'name' => nil },
    button('btn-3'), button('btn-4'), button('btn-5'),
    { 'id' => 'el-a', 'kind' => 'bar-chart', 'name' => 'A' }
  ] },
  { 'name' => 'Customers', 'id' => 'page-d2', 'elements' => [
    { 'id' => 'text-2-customers', 'kind' => 'text', 'name' => nil },
    button('btn-3-customers'), button('btn-4-customers'), button('btn-5-customers'),
    { 'id' => 'el-b', 'kind' => 'bar-chart', 'name' => 'B' }
  ] }
] }.freeze

xml = nil
log = ''
Dir.mktmpdir do |d|
  File.write(File.join(d, 'dl.json'), JSON.generate([dash('Overview', 'A'), dash('Customers', 'B')]))
  File.write(File.join(d, 'wb.json'), JSON.generate(WB))
  out = File.join(d, 'layout.xml')
  log = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out],
                 err: %i[child out], &:read)
  xml = File.read(out) if File.exist?(out)
end
abort "build produced no layout\n#{log}" if xml.nil?
doc = REXML::Document.new("<Root>#{xml.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")

def band_ids(doc, page_id, band_id)
  pg = doc.elements.to_a('Root/Page').find { |p| p.attributes['id'] == page_id }
  gc = pg && pg.elements.to_a('.//Container').find { |g| g.attributes['elementId'] == band_id }
  gc ? gc.elements.to_a('.//Element').map { |e| e.attributes['elementId'] } : []
end

[['page-d1', '', 'dashboard 1 (bare ids)'], ['page-d2', '-customers', 'dashboard 2 (namespaced ids)']].each do |pid, sfx, label|
  puts "-- #{label}"
  ids = band_ids(doc, pid, "tc-#{pid}-hdr")
  want = ["text-2#{sfx}", "btn-3#{sfx}", "btn-4#{sfx}", "btn-5#{sfx}"]
  check(want.all? { |w| ids.include?(w) }, "header band holds title + 3 nav buttons (got #{ids.inspect})", fails)
  page_xml = xml[/(<Page[^>]*id="#{pid}".*?<\/Page>)/m, 1].to_s
  check(!page_xml.include?('-extra'), 'no safety-net -extra band', fails)
end

puts
puts '-- zone_el helper boundary'
src = File.read(BUILD)
eval(src[/^def zone_el.*?^end\n/m]) # rubocop:disable Security/Eval
els = { 'btn-31' => { 'id' => 'btn-31' }, 'btn-3-customers' => { 'id' => 'btn-3-customers' } }
check(zone_el(els, 'btn', '3')['id'] == 'btn-3-customers', '"btn-3-" does not match btn-31', fails)
check(zone_el({ 'btn-31' => { 'id' => 'btn-31' } }, 'btn', '3').nil?, 'no false prefix match on btn-31', fails)

# ---- C7: crowded header buttons, bottom-floating title, body button ----------
def crowded
  zs = [
    { 'id' => '2', 'kind' => 'text', 'text_runs' => [{ 'text' => 'Crowded' }],
      'x_pct' => 0.0, 'y_pct' => 1.0, 'w_pct' => 40.0, 'h_pct' => 4.0 },
    { 'id' => '3', 'kind' => 'dashboard-object', 'x_pct' => 5.0, 'y_pct' => 1.0, 'w_pct' => 15.0, 'h_pct' => 4.0 },
    { 'id' => '4', 'kind' => 'dashboard-object', 'x_pct' => 20.0, 'y_pct' => 1.0, 'w_pct' => 15.0, 'h_pct' => 4.0 },
    { 'id' => '5', 'kind' => 'dashboard-object', 'x_pct' => 35.0, 'y_pct' => 1.0, 'w_pct' => 15.0, 'h_pct' => 4.0 },
    { 'id' => '6', 'kind' => 'dashboard-object', 'x_pct' => 60.0, 'y_pct' => 50.0, 'w_pct' => 15.0, 'h_pct' => 4.0 },
    { 'id' => '7', 'kind' => 'chart', 'caption' => 'C', 'chart_kind' => 'bar',
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 20.0, 'w_pct' => 100.0, 'h_pct' => 25.0 }
  ]
  { 'dashboard' => 'Crowded', 'is_story' => false, 'canvas_px' => nil, 'zones' => zs,
    'zone_tree' => [{ 'id' => '1', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
                      'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
                      'children' => zs.map(&:dup) }] }
end

def bottom_title
  zs = [
    { 'id' => '7', 'kind' => 'chart', 'caption' => 'D', 'chart_kind' => 'bar',
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 85.0 },
    { 'id' => '12', 'kind' => 'text', 'text_runs' => [{ 'text' => 'Footer title' }],
      'x_pct' => 0.0, 'y_pct' => 90.0, 'w_pct' => 100.0, 'h_pct' => 8.0 }
  ]
  { 'dashboard' => 'Bottom', 'is_story' => false, 'canvas_px' => nil, 'zones' => zs,
    'zone_tree' => [{ 'id' => '1', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
                      'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
                      'children' => zs.map(&:dup) }] }
end

def far_right
  btn = lambda do |id, x|
    { 'id' => id, 'kind' => 'dashboard-object', 'x_pct' => x, 'y_pct' => 1.0, 'w_pct' => 4.0, 'h_pct' => 4.0 }
  end
  zs = [{ 'id' => '22', 'kind' => 'text', 'text_runs' => [{ 'text' => 'Far' }],
          'x_pct' => 0.0, 'y_pct' => 1.0, 'w_pct' => 40.0, 'h_pct' => 4.0 },
        btn.call('23', 96.0), btn.call('24', 97.0), btn.call('25', 98.0),
        { 'id' => '27', 'kind' => 'chart', 'caption' => 'F', 'chart_kind' => 'bar',
          'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 20.0, 'w_pct' => 100.0, 'h_pct' => 50.0 }]
  { 'dashboard' => 'Far', 'is_story' => false, 'canvas_px' => nil, 'zones' => zs,
    'zone_tree' => [{ 'id' => '21', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
                      'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
                      'children' => zs.map(&:dup) }] }
end

WB2 = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Crowded', 'id' => 'page-c', 'elements' => [
    { 'id' => 'text-2', 'kind' => 'text', 'name' => nil },
    button('btn-3'), button('btn-4'), button('btn-5'), button('btn-6'),
    { 'id' => 'el-c', 'kind' => 'bar-chart', 'name' => 'C' }
  ] },
  { 'name' => 'Far', 'id' => 'page-f', 'elements' => [
    { 'id' => 'text-22', 'kind' => 'text', 'name' => nil },
    button('btn-23'), button('btn-24'), button('btn-25'),
    { 'id' => 'el-f', 'kind' => 'bar-chart', 'name' => 'F' }
  ] },
  { 'name' => 'Bottom', 'id' => 'page-b', 'elements' => [
    { 'id' => 'text-12', 'kind' => 'text', 'name' => nil },
    { 'id' => 'el-d', 'kind' => 'bar-chart', 'name' => 'D' }
  ] }
] }.freeze

xml2 = nil
log2 = ''
Dir.mktmpdir do |d|
  File.write(File.join(d, 'dl.json'), JSON.generate([crowded, far_right, bottom_title]))
  File.write(File.join(d, 'wb.json'), JSON.generate(WB2))
  out = File.join(d, 'layout.xml')
  log2 = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out],
                  err: %i[child out], &:read)
  xml2 = File.read(out) if File.exist?(out)
end
abort "C7 build produced no layout\n#{log2}" if xml2.nil?
doc2 = REXML::Document.new("<Root>#{xml2.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")

puts
puts '-- C7: crowded header buttons'
pg = doc2.elements.to_a('Root/Page').find { |p| p.attributes['id'] == 'page-c' }
hdr = pg.elements.to_a('.//Container').find { |g| g.attributes['elementId'] == 'tc-page-c-hdr' }
header_children = hdr ? hdr.elements.to_a('.//Element') : []
cols = lambda do |e|
  a, b = e.attributes['gridColumn'].split('/').map { |x| x.strip.to_i }
  [a, b]
end
btns = header_children.select { |e| e.attributes['elementId'].start_with?('btn-') }
title_e = header_children.find { |e| e.attributes['elementId'] == 'text-2' }
check(btns.length == 3, "3 top nav buttons stay in header band (got #{btns.length})", fails)
title_cols = title_e ? cols.call(title_e).then { |a, b| b - a } : 0
check(title_cols >= 6, "title shrinks, not dropped (title cols=#{title_cols})", fails)
spans = btns.map { |e| cols.call(e) }.sort
check(spans.each_cons(2).all? { |a, b| a[1] <= b[0] }, "buttons do not overlap (#{spans.inspect})", fails)
check(btns.none? { |e| cols.call(e)[0] < 7 }, 'no button starts left of column 7', fails)
check(!header_children.map { |e| e.attributes['elementId'] }.include?('btn-6'), 'body button is not in the header band', fails)
check(xml2[/(<Page[^>]*id="page-c".*?<\/Page>)/m, 1].to_s.include?('btn-6'), 'body button still placed (source position)', fails)

puts
puts '-- C7: far-right crowded buttons keep the min-cols guarantee'
pgf = doc2.elements.to_a('Root/Page').find { |p| p.attributes['id'] == 'page-f' }
hdrf = pgf.elements.to_a('.//Container').find { |g| g.attributes['elementId'] == 'tc-page-f-hdr' }
fb = (hdrf ? hdrf.elements.to_a('.//Element') : []).select { |e| e.attributes['elementId'].start_with?('btn-') }
fspans = fb.map { |e| cols.call(e) }.sort
check(fb.length == 3, "3 far-right buttons in the band (got #{fb.length})", fails)
check(fspans.all? { |a, b| b - a >= 4 && a >= 7 && b <= 25 }, "every span >= 4 cols within 7..25 (#{fspans.inspect})", fails)
check(fspans.each_cons(2).all? { |a, b| a[1] <= b[0] }, 'far-right spans do not overlap', fails)

puts
puts '-- C7: bottom-floating source title stays at the bottom'
rects = abs_rects_for = nil
pgb = doc2.elements.to_a('Root/Page').find { |p| p.attributes['id'] == 'page-b' }
walk = lambda do |node, ro, out|
  node.elements.each do |e|
    next unless %w[Container Element].include?(e.name)
    r0, r1 = e.attributes['gridRow'].to_s.split('/').map { |x| x.strip.to_i }
    if e.name == 'Container'
      walk.call(e, r0 - 1 + ro, out)
    else
      out[e.attributes['elementId']] = [r0 + ro, r1 + ro]
    end
  end
  out
end
rb = walk.call(pgb, 0, {})
check(rb['text-12'] && rb['el-d'] && rb['text-12'][0] >= rb['el-d'][1] - 1, "title below the chart (#{rb.inspect})", fails)
hb = pgb.elements.to_a('.//Container').select { |g| g.attributes['elementId'].to_s.start_with?('tc-page-b-hdr') }
check(hb.none? { |g| g.elements.to_a('.//Element').any? { |e| e.attributes['elementId'] == 'text-12' } },
      'source title is not hoisted into a header band', fails)

puts
if fails.empty?
  puts 'All checks passed.'
else
  puts "#{fails.length} check(s) FAILED:"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
