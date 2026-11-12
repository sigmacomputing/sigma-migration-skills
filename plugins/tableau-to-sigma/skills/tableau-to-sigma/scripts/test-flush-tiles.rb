#!/usr/bin/env ruby
# frozen_string_literal: true
# Plan C15 (verdict grid-gutters): a source dashboard whose tiled zones declare
# outer padding (margin) 0 and no inner padding butts its tiles together. The
# converter wraps the page's tiles in ONE full-width grid container
# {spacing small, elementGap hidden, style {padding none}} (never with
# borderWidth/borderColor) and sets settings.theme.overrides.space =
# {showElementPadding hidden, unit small}, merged into the theme.
# Default Tableau padding (margin 4) or undeclared padding is NOT flush.
#
# Usage:  LANG=en_US.UTF-8 ruby scripts/test-flush-tiles.rb
require 'json'
require 'rexml/document'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/theme_derive'

BUILD = File.join(__dir__, 'build-dashboard-layout.rb')
RUBY  = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def zone(id, cap, x, w, margins: nil, paddings: nil)
  z = { 'id' => id, 'kind' => 'chart', 'caption' => cap, 'chart_kind' => 'bar', 'show_title' => true,
        'measures' => [{ 'column' => '[m]' }],
        'x_pct' => x, 'y_pct' => 0.0, 'w_pct' => w, 'h_pct' => 100.0 }
  z['margins'] = margins if margins
  z['paddings'] = paddings if paddings
  z
end

def dash(margins:, paddings:, second_margins: margins)
  a = zone('1', 'Sales', 0.0, 50.0, margins: margins, paddings: paddings)
  b = zone('2', 'Profit', 50.0, 50.0, margins: second_margins, paddings: paddings)
  { 'dashboard' => 'D', 'is_story' => false, 'canvas_px' => nil, 'zones' => [a, b],
    'zone_tree' => [{ 'id' => '0', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0,
                      'h_pct' => 100.0, 'children' => [a.dup, b.dup] }] }
end

WB = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'D', 'id' => 'page-d1', 'elements' => [
    { 'id' => 'el-sales', 'kind' => 'bar-chart', 'name' => 'Sales' },
    { 'id' => 'el-profit', 'kind' => 'bar-chart', 'name' => 'Profit' }
  ] }
] }.freeze

def run(d)
  xml = els = log = nil
  Dir.mktmpdir do |t|
    File.write(File.join(t, 'dl.json'), JSON.generate([d]))
    File.write(File.join(t, 'wb.json'), JSON.generate(WB))
    out = File.join(t, 'layout.xml')
    log = IO.popen([RUBY, BUILD, '--layout', File.join(t, 'dl.json'), '--wb-ids', File.join(t, 'wb.json'), '--out', out],
                   err: %i[child out], &:read)
    xml = File.read(out) if File.exist?(out)
    els = JSON.parse(File.read("#{out}.elements.json")) if File.exist?("#{out}.elements.json")
  end
  abort "build produced no layout\n#{log}" if xml.nil?
  [REXML::Document.new("<Root>#{xml.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>"), els, log]
end

def page(doc, id)
  doc.elements.to_a('Root/Page').find { |p| p.attributes['id'] == id }
end

def flush_box(doc)
  page(doc, 'page-d1').elements.to_a('Container').find { |c| c.attributes['elementId'].start_with?('flush-') }
end

puts 'Case 1 - explicit margin 0 / padding 0 on every tile: wrapped'
d = dash(margins: { 'all' => 0 }, paddings: { 'all' => 0 })
check(ThemeDerive.flush_tiles?(d), 'predicate: flush')
doc, els, = run(d)
box = flush_box(doc)
check(!box.nil?, 'a top-level flush-* grid container exists')
if box
  check(box.attributes['type'] == 'grid' && box.attributes['gridColumn'] == '1 / 25', "full width 1 / 25 (got #{box.attributes['gridColumn']})")
  kids = box.elements.to_a('.//Element').map { |e| e.attributes['elementId'] }
  check(%w[el-sales el-profit].all? { |k| kids.include?(k) }, "both tiles nested inside (#{kids.inspect})")
  top = page(doc, 'page-d1').elements.to_a('*').map { |e| e.name }
  check(top == ['Container'], "the container is the page's only top-level child (#{top.inspect})")
  spec = (els['page-d1'] || []).find { |e| e['id'] == box.attributes['elementId'] }
  check(spec && spec['kind'] == 'container', 'container spec element emitted in the sidecar')
  check(spec && spec['spacing'] == 'small' && spec['elementGap'] == 'hidden', "spacing small / elementGap hidden (#{spec.inspect})")
  check(spec && spec.dig('style', 'padding') == 'none', 'style.padding none')
  check(spec && !spec['style'].key?('borderWidth') && !spec['style'].key?('borderColor'),
        'padding none never combined with borderWidth/borderColor')
end

puts 'Case 2 - default Tableau outer padding (margin 4): not flush'
d = dash(margins: { 'all' => 4 }, paddings: { 'all' => 0 })
check(!ThemeDerive.flush_tiles?(d), 'predicate: not flush')
doc, els, = run(d)
check(flush_box(doc).nil?, 'no flush container')
check((els['page-d1'] || []).none? { |e| e['id'].to_s.start_with?('flush-') }, 'no flush spec element')

puts 'Case 3 - padding undeclared (Tableau default applies): not flush'
d = dash(margins: nil, paddings: nil)
check(!ThemeDerive.flush_tiles?(d), 'predicate: not flush')
doc, = run(d)
check(flush_box(doc).nil?, 'no flush container')

puts 'Case 4 - one tile has inner padding 6: not flush'
d = dash(margins: { 'all' => 0 }, paddings: { 'all' => 0 }, second_margins: { 'all' => 0 })
d['zone_tree'][0]['children'][1]['paddings'] = { 'all' => 6 }
check(!ThemeDerive.flush_tiles?(d), 'predicate: not flush')

puts 'Case 5 - per-side zero margins count as flush'
d = dash(margins: { 'top' => 0, 'right' => 0, 'bottom' => 0, 'left' => 0 }, paddings: nil)
check(ThemeDerive.flush_tiles?(d), 'predicate: flush (all four sides explicit 0)')

puts 'Case 6 - theme space override, merged'
theme = ThemeDerive.derive([dash(margins: { 'all' => 0 }, paddings: { 'all' => 0 })])
check(theme['space'] == { 'showElementPadding' => 'hidden', 'unit' => 'small' }, "derive emits space (got #{theme['space'].inspect})")
spec = { 'settings' => { 'theme' => { 'name' => 'Light', 'overrides' => { 'categoricalScheme' => %w[#111111 #222222] } } } }
ThemeDerive.apply!(spec, theme)
ov = spec.dig('settings', 'theme', 'overrides')
check(ov['space'] == { 'showElementPadding' => 'hidden', 'unit' => 'small' }, 'apply! writes overrides.space')
check(ov['categoricalScheme'] == %w[#111111 #222222] && ov['fonts'], 'existing overrides kept and fonts merged alongside')
theme2 = ThemeDerive.derive([dash(margins: { 'all' => 4 }, paddings: nil)])
check(!theme2.key?('space'), 'non-flush dashboard: no space override')

puts 'Case 7 - synthesized path (KPI band) nests inside the flush container'
kpis = %w[a b c].each_with_index.map do |k, i|
  { 'id' => "k#{k}", 'kind' => 'chart', 'caption' => "KPI #{k}", 'chart_kind' => 'kpi', 'show_title' => true,
    'measures' => [{ 'column' => '[m]' }], 'margins' => { 'all' => 0 }, 'paddings' => { 'all' => 0 },
    'x_pct' => i * 33.3, 'y_pct' => 0.0, 'w_pct' => 33.3, 'h_pct' => 20.0 }
end
big = zone('big', 'Big', 0.0, 100.0, margins: { 'all' => 0 }, paddings: { 'all' => 0 }).merge('y_pct' => 20.0, 'h_pct' => 80.0)
sd = { 'dashboard' => 'D', 'is_story' => false, 'canvas_px' => nil, 'zones' => kpis + [big],
       'zone_tree' => [{ 'id' => '0', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0,
                         'h_pct' => 100.0, 'children' => (kpis + [big]).map(&:dup) }] }
swb = { 'pages' => [WB['pages'][0], { 'name' => 'D', 'id' => 'page-d1', 'elements' =>
  %w[a b c].map { |k| { 'id' => "el-k#{k}", 'kind' => 'kpi-chart', 'name' => "KPI #{k}" } } +
  [{ 'id' => 'el-big', 'kind' => 'bar-chart', 'name' => 'Big' }] }] }
xml = els = log = nil
Dir.mktmpdir do |t|
  File.write(File.join(t, 'dl.json'), JSON.generate([sd]))
  File.write(File.join(t, 'wb.json'), JSON.generate(swb))
  out = File.join(t, 'layout.xml')
  log = IO.popen([RUBY, BUILD, '--layout', File.join(t, 'dl.json'), '--wb-ids', File.join(t, 'wb.json'), '--out', out],
                 err: %i[child out], &:read)
  xml = File.read(out) if File.exist?(out)
end
abort "synth build failed\n#{log}" if xml.nil?
sdoc = REXML::Document.new("<Root>#{xml.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")
check(log.include?('synthesized layout'), 'used the synthesized path')
sbox = flush_box(sdoc)
check(!sbox.nil?, 'flush container wraps the synthesized page')
inner = sbox ? sbox.elements.to_a('.//Container').map { |c| c.attributes['elementId'] } : []
check(inner.any? { |i| i.start_with?('syn-') }, "the KPI band container nests inside (#{inner.inspect})")

puts 'Case 8 - partial per-side margins are not flush'
d = dash(margins: { 'left' => 0 }, paddings: nil)
check(!ThemeDerive.flush_tiles?(d), 'predicate: only margin-left=0 is not flush')

puts 'Case 9 - theme space only when every dashboard is flush'
fl = dash(margins: { 'all' => 0 }, paddings: { 'all' => 0 })
nf = dash(margins: { 'all' => 4 }, paddings: nil)
check(!ThemeDerive.derive([fl, nf]).key?('space'), 'flush + non-flush: no space')
check(ThemeDerive.derive([fl, fl.dup]).key?('space'), 'both flush: space set')

abort("\n#{$fails.length} FAIL") unless $fails.empty?
puts 'ALL PASS'
