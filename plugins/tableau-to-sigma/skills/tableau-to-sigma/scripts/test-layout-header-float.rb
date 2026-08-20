#!/usr/bin/env ruby
# frozen_string_literal: true
# v5.1 defects 2 + 3 regression test — header composition order + floating art.
#
# Hero-art-shaped source ("four panels, one story.", fixed 1200x2070): the giant
# title is an IMAGE wordmark (zone 3) over a runic subtitle image (zone 18),
# followed by an intro text zone (zone 20, two paragraphs), with a floating
# brush-art image (zone 52, a second ROOT of the zone tree) overlapping the
# header region. The r4 consensus defects this locks against:
#   - defect 2: detect_header_title_el promoted the INTRO into the header band,
#     shipping the intro ABOVE the wordmark (inverted), and the page name was
#     fabricated over title art on other routes.
#   - defect 3: pack_rects displaced the floating art below the main container
#     — the brush art shipped at the literal page bottom in all three runs.
#
# Locks:
#   1. intro NOT promoted: no header band at all (no tc-*-hdr, no fabricated
#      hdrtext) when the top band is images; wordmark stays ABOVE the intro.
#   2. float partition: the floating image joins the header composition beside
#      the intro (intro shrinks its columns), lands in the TOP rows, never the
#      bottom band, and never the safety net.
#   3. a genuine short top TEXT banner still extracts into the header band.
#   4. a mid-page floating image that pack_rects would strand at the bottom is
#      DROPPED with a WARN + a recoverable image-assets.json record instead.
#
# Usage:  ruby scripts/test-layout-header-float.rb
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

INTRO_RUNS = [
  { 'text' => 'In the contest between four rival guilds, travelers choose one of four panels — a long introduction paragraph.' },
  { 'text' => 'Each path is measured below across bias, speed and survival.', 'break' => true }
].freeze

# ---- dashboard 1: hero shape (image wordmark + intro + floating art) -------
HERO = {
  'dashboard' => 'four panels', 'is_story' => false,
  'canvas_px' => { 'w' => 1200, 'h' => 2070, 'sizing_mode' => 'fixed' },
  'zones' => [
    { 'id' => '3',  'kind' => 'image', 'image_path' => 'Image/title.png',
      'x_pct' => 3.3, 'y_pct' => 1.9, 'w_pct' => 93.3, 'h_pct' => 3.9 },
    { 'id' => '18', 'kind' => 'image', 'image_path' => 'Image/runic.png',
      'x_pct' => 3.3, 'y_pct' => 5.8, 'w_pct' => 93.3, 'h_pct' => 1.5 },
    { 'id' => '20', 'kind' => 'text', 'text_runs' => INTRO_RUNS,
      'x_pct' => 3.3, 'y_pct' => 8.2, 'w_pct' => 93.3, 'h_pct' => 6.2 },
    { 'id' => '52', 'kind' => 'image', 'image_path' => 'Image/brush.png',
      'x_pct' => 3.6, 'y_pct' => 0.8, 'w_pct' => 33.3, 'h_pct' => 14.7 },
    { 'id' => '24', 'kind' => 'chart', 'caption' => 'Path Bias', 'chart_kind' => 'bar',
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => 3.3, 'y_pct' => 16.0, 'w_pct' => 93.3, 'h_pct' => 16.6 },
    { 'id' => '29', 'kind' => 'chart', 'caption' => 'Strip', 'chart_kind' => 'bar',
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => 3.3, 'y_pct' => 33.0, 'w_pct' => 93.3, 'h_pct' => 6.4 }
  ],
  'zone_tree' => [
    { 'id' => '4', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
      'children' => [
        { 'id' => '19', 'kind' => 'container', 'direction' => 'vert', 'fill_color' => '#f5f5f5ff',
          'x_pct' => 3.3, 'y_pct' => 1.9, 'w_pct' => 93.3, 'h_pct' => 6.3,
          'children' => [
            { 'id' => '3',  'kind' => 'image', 'x_pct' => 3.3, 'y_pct' => 1.9, 'w_pct' => 93.3, 'h_pct' => 3.9 },
            { 'id' => '18', 'kind' => 'image', 'x_pct' => 3.3, 'y_pct' => 5.8, 'w_pct' => 93.3, 'h_pct' => 1.5 }
          ] },
        { 'id' => '20', 'kind' => 'text', 'text_runs' => INTRO_RUNS,
          'x_pct' => 3.3, 'y_pct' => 8.2, 'w_pct' => 93.3, 'h_pct' => 6.2 },
        { 'id' => '24', 'kind' => 'chart', 'caption' => 'Path Bias',
          'x_pct' => 3.3, 'y_pct' => 16.0, 'w_pct' => 93.3, 'h_pct' => 16.6 },
        { 'id' => '29', 'kind' => 'chart', 'caption' => 'Strip',
          'x_pct' => 3.3, 'y_pct' => 33.0, 'w_pct' => 93.3, 'h_pct' => 6.4 }
      ] },
    # the floating brush art: a second ROOT of the dashboard <zones>
    { 'id' => '52', 'kind' => 'image', 'x_pct' => 3.6, 'y_pct' => 0.8, 'w_pct' => 33.3, 'h_pct' => 14.7 }
  ]
}.freeze

# ---- dashboard 2: genuine short TEXT banner (must still extract) -------------
EXEC = {
  'dashboard' => 'Exec', 'is_story' => false, 'canvas_px' => nil,
  'zones' => [
    { 'id' => 'b1', 'kind' => 'text', 'text_runs' => [{ 'text' => 'Executive Overview' }],
      'x_pct' => 5.0, 'y_pct' => 1.0, 'w_pct' => 90.0, 'h_pct' => 4.0 },
    { 'id' => 'c1', 'kind' => 'chart', 'caption' => 'Trend', 'chart_kind' => 'bar',
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 20.0, 'w_pct' => 100.0, 'h_pct' => 60.0 }
  ],
  'zone_tree' => [
    { 'id' => 'r1', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
      'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
      'children' => [
        { 'id' => 'b1', 'kind' => 'text', 'text_runs' => [{ 'text' => 'Executive Overview' }],
          'x_pct' => 5.0, 'y_pct' => 1.0, 'w_pct' => 90.0, 'h_pct' => 4.0 },
        { 'id' => 'c1', 'kind' => 'chart', 'caption' => 'Trend',
          'x_pct' => 0.0, 'y_pct' => 20.0, 'w_pct' => 100.0, 'h_pct' => 60.0 }
      ] }
  ]
}.freeze

# ---- dashboard 3: mid-page float over full-width content (drop + record) -----
MID = {
  'dashboard' => 'Mid', 'is_story' => false, 'canvas_px' => nil,
  'zones' => [
    { 'id' => 'f1', 'kind' => 'chart', 'caption' => 'Full', 'chart_kind' => 'bar',
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0 },
    { 'id' => '99', 'kind' => 'image', 'image_path' => 'Image/x.png',
      'x_pct' => 10.0, 'y_pct' => 50.0, 'w_pct' => 20.0, 'h_pct' => 10.0 }
  ],
  'zone_tree' => [
    { 'id' => 'r9', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
      'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
      'children' => [
        { 'id' => 'f1', 'kind' => 'chart', 'caption' => 'Full',
          'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0 }
      ] },
    { 'id' => '99', 'kind' => 'image', 'x_pct' => 10.0, 'y_pct' => 50.0, 'w_pct' => 20.0, 'h_pct' => 10.0 }
  ]
}.freeze

# ---- dashboard 4: header float with NO side-by-side text row -----------------
# (top strip fallback: the float gets its own rows at the page top and the body
# shifts below it — never the bottom band)
ART = {
  'dashboard' => 'Art', 'is_story' => false, 'canvas_px' => nil,
  'zones' => [
    { 'id' => 'a1', 'kind' => 'image', 'image_path' => 'Image/logo.png',
      'x_pct' => 0.0, 'y_pct' => 1.0, 'w_pct' => 40.0, 'h_pct' => 10.0 },
    { 'id' => 'c9', 'kind' => 'chart', 'caption' => 'Body', 'chart_kind' => 'bar',
      'measures' => [{ 'column' => '[m]' }], 'x_pct' => 0.0, 'y_pct' => 20.0, 'w_pct' => 100.0, 'h_pct' => 80.0 }
  ],
  'zone_tree' => [
    { 'id' => 'r4', 'kind' => 'container', 'fill_color' => '#f5f5f5ff',
      'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
      'children' => [
        { 'id' => 'c9', 'kind' => 'chart', 'caption' => 'Body',
          'x_pct' => 0.0, 'y_pct' => 20.0, 'w_pct' => 100.0, 'h_pct' => 80.0 }
      ] },
    { 'id' => 'a1', 'kind' => 'image', 'x_pct' => 0.0, 'y_pct' => 1.0, 'w_pct' => 40.0, 'h_pct' => 10.0 }
  ]
}.freeze

WB = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'four panels', 'id' => 'page-d1', 'elements' => [
    { 'id' => 'img-3',   'kind' => 'image', 'name' => nil },
    { 'id' => 'img-18',  'kind' => 'image', 'name' => nil },
    { 'id' => 'text-20', 'kind' => 'text',  'name' => nil },
    { 'id' => 'img-52',  'kind' => 'image', 'name' => nil },
    { 'id' => 'el-bias', 'kind' => 'bar-chart', 'name' => 'Path Bias' },
    { 'id' => 'el-strip', 'kind' => 'bar-chart', 'name' => 'Strip' }
  ] },
  { 'name' => 'Exec', 'id' => 'page-d2', 'elements' => [
    { 'id' => 'text-b1', 'kind' => 'text', 'name' => nil },
    { 'id' => 'el-trend', 'kind' => 'bar-chart', 'name' => 'Trend' }
  ] },
  { 'name' => 'Mid', 'id' => 'page-d3', 'elements' => [
    { 'id' => 'el-full', 'kind' => 'bar-chart', 'name' => 'Full' },
    { 'id' => 'img-99',  'kind' => 'image', 'name' => nil }
  ] },
  { 'name' => 'Art', 'id' => 'page-d4', 'elements' => [
    { 'id' => 'img-a1',  'kind' => 'image', 'name' => nil },
    { 'id' => 'el-body', 'kind' => 'bar-chart', 'name' => 'Body' }
  ] }
] }.freeze

xml = nil
log = ''
census = nil
assets_after = nil
prune_after = nil
Dir.mktmpdir do |d|
  File.write(File.join(d, 'dl.json'), JSON.generate([HERO, EXEC, MID, ART]))
  File.write(File.join(d, 'wb.json'), JSON.generate(WB))
  # image-assets.json beside the layout (as build-charts-from-signals writes it)
  # so the dropped mid-page float can be flagged recoverable.
  File.write(File.join(d, 'image-assets.json'), JSON.pretty_generate(
               [{ 'dashboard' => 'Mid', 'zone_id' => '99', 'image_path' => 'Image/x.png',
                  'asset' => nil, 'is_background' => false }]
             ))
  out = File.join(d, 'layout.xml')
  log = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out], err: %i[child out], &:read)
  xml = File.read(out) if File.exist?(out)
  cf = File.join(d, 'layout-census.json')
  census = JSON.parse(File.read(cf)) if File.exist?(cf)
  assets_after = JSON.parse(File.read(File.join(d, 'image-assets.json')))
  pf = "#{out}.prune-elements.json"
  prune_after = JSON.parse(File.read(pf)) if File.exist?(pf)
end

abort "build produced no layout\n#{log}" if xml.nil?
doc = REXML::Document.new("<Root>#{xml.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")

# Resolve PAGE-ABSOLUTE row/col extents for every Element (container
# children use container-relative coordinates that restart at 1).
def abs_rects(page_el)
  out = {}
  walk = lambda do |node, row_off, col_off|
    node.elements.each do |e|
      next unless %w[Container Element].include?(e.name)
      c0, c1 = e.attributes['gridColumn'].to_s.split('/').map { |s| s.strip.to_i }
      r0, r1 = e.attributes['gridRow'].to_s.split('/').map { |s| s.strip.to_i }
      ar = [c0 + col_off, c1 + col_off, r0 + row_off, r1 + row_off]
      if e.name == 'Container'
        walk.call(e, ar[2] - 1, ar[0] - 1)
      else
        out[e.attributes['elementId']] = ar
      end
    end
  end
  walk.call(page_el, 0, 0)
  out
end

pages = {}
doc.elements.each('Root/Page') { |pg| pages[pg.attributes['id']] = pg }
d1 = abs_rects(pages['page-d1'])
rows_by = (census && census['pages'] || []).each_with_object({}) { |c, h| h[c['page']] = c['rows'] }

puts '-- defect 2: image wordmark on top, intro NOT promoted'
d1_xml = xml[/(<Page[^>]*id="page-d1".*?<\/Page>)/m, 1].to_s
check(!d1_xml.include?('tc-page-d1-hdr'), 'NO header band on the image-titled page (no tc-*-hdr)', fails)
check(!d1_xml.include?('hdrtext'), 'page name NOT fabricated over the title art (no hdrtext)', fails)
check(d1.key?('img-3') && d1.key?('text-20'), "wordmark + intro both placed (got #{d1.keys.sort.inspect})", fails)
check(d1['img-3'] && d1['text-20'] && d1['img-3'][2] < d1['text-20'][2],
      "wordmark places ABOVE the intro (img-3 r0=#{d1['img-3'] && d1['img-3'][2]} < text-20 r0=#{d1['text-20'] && d1['text-20'][2]})", fails)
check(d1['img-18'] && d1['img-3'] && d1['img-18'][2] >= d1['img-3'][2],
      'runic subtitle stays under the wordmark (source order preserved)', fails)
check(rows_by['four panels'] == 74, "px-derived rows on the hero page (got #{rows_by['four panels'].inspect})", fails)

puts
puts '-- defect 3: floating brush art joins the header composition'
f52 = d1['img-52']
check(!f52.nil?, 'floating image placed in the grid', fails)
check(f52 && f52[2] <= 12, "float stays in the TOP rows (r0=#{f52 && f52[2]} <= 12), never the page bottom", fails)
check(f52 && f52[2] <= (74 * 0.25).floor, 'float within 25% of page_rows of its source y (rule-(i) invariant)', fails)
intro = d1['text-20']
check(intro && intro[0] >= 10, "overlapped intro text shrank its columns to sit beside the art (c0=#{intro && intro[0]} >= 10)", fails)
check(f52 && intro && f52[1] <= intro[0], 'art and intro are side-by-side (no column overlap)', fails)
check(f52 && intro && f52[2] == intro[2], 'art shares the intro row band (the sub-band below the wordmark)', fails)
check(!d1_xml.include?('-extra'), 'float never reaches the safety-net bottom band', fails)

puts
puts '-- defect 2 (control case): a genuine short top text banner still extracts'
d2_xml = xml[/(<Page[^>]*id="page-d2".*?<\/Page>)/m, 1].to_s
check(d2_xml.include?('tc-page-d2-hdr'), 'header band emitted for the text-titled page', fails)
hdr_gc = pages['page-d2'] && pages['page-d2'].elements.to_a('.//Container')
                                             .find { |g| g.attributes['elementId'] == 'tc-page-d2-hdr' }
hdr_ids = hdr_gc ? hdr_gc.elements.to_a('.//Element').map { |l| l.attributes['elementId'] } : []
check(hdr_ids == ['text-b1'], "the source banner text owns the header band (got #{hdr_ids.inspect})", fails)
check(!d2_xml.include?('hdrtext'), 'no fabricated page-name H1 alongside the extracted banner', fails)

puts
puts '-- defect 3 (mid-page float): drop + recoverable record, never bottom-strand'
d3_xml = xml[/(<Page[^>]*id="page-d3".*?<\/Page>)/m, 1].to_s
check(!d3_xml.include?('img-99'), 'displaced mid-page float dropped from the grid (not bottom-stranded)', fails)
check(log.include?('manual-composite'), 'WARN announces the manual-composite drop', fails)
rec = Array(assets_after).find { |a| a['zone_id'].to_s == '99' }
check(rec && rec['placement'] == 'manual-composite',
      "image-assets.json record flagged placement=manual-composite (got #{rec.inspect})", fails)
prune_records = prune_after.is_a?(Hash) ? Array(prune_after['elements']) : []
check(prune_after && prune_after['version'] == 1,
      "explicit prune sidecar uses version 1 (got #{prune_after.inspect})", fails)
check(prune_records == [{
        'element_id' => 'img-99', 'page_id' => 'page-d3',
        'reason' => 'manual-composite', 'dashboard' => 'Mid', 'zone_id' => '99'
      }],
      "explicit prune sidecar names only img-99 as manual-composite (got #{prune_records.inspect})", fails)
mid_census = Array(census && census['pages']).find { |page| page['page'] == 'Mid' }
check(mid_census && mid_census['unplaced_elements'] == [],
      "coverage has no arbitrary unplaced elements (got #{mid_census && mid_census['unplaced_elements'].inspect})", fails)
check(mid_census && mid_census['pruned_elements'] == ['img-99'],
      "coverage recognizes only the explicitly pruned id (got #{mid_census && mid_census['pruned_elements'].inspect})", fails)
check(!d3_xml.include?('-extra'), 'dropped float does NOT resurface via the safety-net band', fails)
check(d3_xml.include?('el-full'), 'the main content still ships on the mid-float page', fails)
check(xml.include?('<Element ') && xml.include?('<Container ') &&
      !xml.include?('<GridCell') && !xml.include?('<GridContainer'),
      'layout retains canonical <Element>/<Container> tags', fails)

puts
puts '-- defect 3 (no side-by-side row): header float gets its own TOP strip'
d4 = abs_rects(pages['page-d4'])
a1 = d4['img-a1']
body = d4['el-body']
check(a1 && a1[2] == 1, "float strip starts at page row 1 (r0=#{a1 && a1[2]})", fails)
check(a1 && body && body[2] >= a1[3], 'the body content shifts BELOW the float strip (no collision)', fails)
d4_xml = xml[/(<Page[^>]*id="page-d4".*?<\/Page>)/m, 1].to_s
check(!d4_xml.include?('-extra'), 'strip float never reaches the safety-net band either', fails)

puts
if fails.empty?
  puts 'ALL PASS — header order (image wordmark, no fabricated title) + float partition (top-band composition, drop+record)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts log.to_s.lines.last(15).join
  exit 1
end
