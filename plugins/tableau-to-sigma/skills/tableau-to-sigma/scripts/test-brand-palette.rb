#!/usr/bin/env ruby
# Regression test for the general D1 brand-palette extraction in
# parse-twb-layout.rb: the workbook's real categorical/brand palette comes from
# the color ENCODING (<map to='#..'>) + custom <color-palette>, NOT container
# fills. Neutrals (grey / near-white / near-black) are dropped so a vivid colour
# with a single near-max channel (orange #f06719, red #ff0000) is KEPT.
#
# Exercises the pure helpers directly (no .twb file needed).
# Usage:  ruby scripts/test-brand-palette.rb

DIR = __dir__
SRC = File.read(File.join(DIR, 'parse-twb-layout.rb'))
%w[color_neutral? extract_brand_palette].each do |fn|
  m = SRC.match(/^def #{Regexp.escape(fn)}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# --- color_neutral? -----------------------------------------------------------
check(color_neutral?('#ffffff'), "pure white is neutral", fails)
check(color_neutral?('#fafafa'), "near-white grey is neutral", fails)
check(color_neutral?('#ececec'), "light grey is neutral", fails)
check(color_neutral?('#111111'), "near-black is neutral", fails)
check(!color_neutral?('#f06719'), "vivid orange (r=240) is NOT neutral — the near-white bug", fails)
check(!color_neutral?('#ff0000'), "pure red (r=255) is NOT neutral", fails)
check(!color_neutral?('#ba2020'), "brand red is NOT neutral", fails)
check(!color_neutral?('#b9ddf1'), "light-but-chromatic blue (Water) is NOT neutral", fails)

# --- extract_brand_palette: frequency rank + neutral drop + dedup -------------
twb = <<~XML
  <workbook>
    <worksheet><encoding attr='color'>
      <map to='#ba2020'></map><map to='#ba2020'></map><map to='#ba2020'></map>
      <map to='#ececec'></map><map to='#ffffff'></map>
      <map to="#f06719"></map><map to="#f06719"></map>
    </encoding></worksheet>
    <color-palette custom='true' name='Custom' type='regular'>
      <color>#4e79a7</color>
    </color-palette>
    <color-palette custom='true' name='Ramp' type='ordered-sequential'>
      <color>#023858</color><color>#045a8d</color><color>#0570b0</color>
    </color-palette>
  </workbook>
XML
pal = extract_brand_palette(twb)
check(pal == %w[#ba2020 #f06719 #4e79a7],
      "freq-ranked, neutrals dropped, deduped (got #{pal.inspect})", fails)
check(!pal.include?('#ffffff') && !pal.include?('#ececec'),
      "white / grey encoding buckets excluded", fails)
# v5.0 (S2 fix): sequential/diverging RAMP palettes are heatmap gradients, not
# a brand palette — their steps must not pollute categoricalScheme.
check((pal & %w[#023858 #045a8d #0570b0]).empty?,
      "ordered-sequential ramp members excluded (type='regular' only)", fails)

# Tableau-10 swatches must keep Tableau's semantic sequence rather than hex
# sorting; Sigma applies categorical schemes positionally.
tableau10_xml = <<~XML
  <x>
    <map to='#59a14f'/><map to='#e15759'/><map to='#4e79a7'/>
    <map to='#76b7b2'/><map to='#f28e2b'/>
  </x>
XML
check(extract_brand_palette(tableau10_xml) ==
        %w[#4e79a7 #f28e2b #e15759 #76b7b2 #59a14f],
      'Tableau-10 palette preserves blue→orange→red→teal→green order', fails)

# Source with no non-neutral colours → empty palette (theme then omitted).
mono = extract_brand_palette("<x><map to='#ffffff'></map><map to='#eeeeee'></map></x>")
check(mono == [], "all-neutral source → empty palette (got #{mono.inspect})", fails)

# --- C5: Tableau 10 default palette in Tableau's member order -----------------
require_relative 'lib/series_colors'
require_relative 'lib/builder_test_harness'
map = SeriesColors.resolved_member_map(%w[Standard Express Economy Slow])
check(map == { 'Economy' => '#4e79a7', 'Express' => '#f28e2b', 'Slow' => '#e15759', 'Standard' => '#76b7b2' },
      'default palette in alpha order', fails)
map2 = SeriesColors.resolved_member_map(%w[Economy Express Slow Standard], {}, %w[Standard Slow])
check(map2.keys.first == 'Standard' && map2['Standard'] == '#4e79a7' && map2['Slow'] == '#f28e2b' &&
        map2.keys == %w[Standard Slow Economy Express],
      'manual sort order respected (manual first, rest alphabetical)', fails)
map3 = SeriesColors.resolved_member_map(%w[Economy Express Slow], { 'Express' => '#1F77B4' })
check(map3['Express'] == '#1f77b4' && map3['Economy'] == '#4e79a7', 'explicit encoding wins per member', fails)
map4 = SeriesColors.resolved_member_map((1..12).map { |i| format('M%02d', i) })
check(map4['M11'] == '#4e79a7' && map4['M12'] == '#f28e2b' && map4['M10'] == '#bab0ac',
      'palette cycles past 10 members', fails)
check(SeriesColors.scheme_from_map(map2) == [map2['Economy'], map2['Express'], map2['Slow'], map2['Standard']],
      'scheme is positional in ascending member order, carrying the manual-order colours', fails)

H = BuilderTestHarness
csv = "Region,Segment,Net Revenue\nEast,Standard,10\nEast,Express,20\nWest,Economy,30\nWest,Slow,40\n"
bar = lambda do |cap, extra = {}|
  H.chart_zone(id: cap, caption: cap, extra: { 'channels' => { 'color' => { 'column' => '[Segment]' } } }.merge(extra))
end
res = H.run([bar.call('Default Colors'), bar.call('Manual Colors', 'color_manual_order' => %w[Standard Slow])],
            csvs: { 'Default Colors' => csv, 'Manual Colors' => csv })
# Explicit run is separate: a sibling zone's explicit map would pin the shared dict (D2).
res_ex = H.run([bar.call('Explicit Colors', 'series_color_field' => 'Segment',
                         'series_colors' => [{ 'member' => 'Express', 'color' => '#1f77b4' },
                                             { 'member' => 'Slow', 'color' => '#ff7f0e' }])],
               csvs: { 'Explicit Colors' => csv })
check(res[:status].success? && res_ex[:status].success?, 'builder exits 0', fails)
sch = ->(re) { H.find_chart(res, re)&.dig('color', 'scheme') }
check(sch.call(/Default Colors/) == %w[#4e79a7 #f28e2b #e15759 #76b7b2],
      'builder: default chart gets Tableau 10 in alpha member order', fails)
check(sch.call(/Manual Colors/) == %w[#e15759 #76b7b2 #f28e2b #4e79a7],
      'builder: manual member order drives colours (Standard first)', fails)
ex = H.find_chart(res_ex, /Explicit Colors/)&.dig('color', 'scheme')
check(ex && ex.include?('#1f77b4') && ex.include?('#ff7f0e'), 'builder: explicit encodings still win', fails)

puts
if fails.empty?
  puts 'ALL PASS — D1 brand-palette extraction (color encodings, neutral drop, freq rank)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
