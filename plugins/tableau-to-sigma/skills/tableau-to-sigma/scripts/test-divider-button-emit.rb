#!/usr/bin/env ruby
# v5.0-P2 regression tests: DIVIDER synthesis + BUTTON semantics.
#
# Corpus facts these lock (census 2026-07-11, 14 workbooks / 2,311 zones):
# 61 thin filled rules (spacers / childless containers / blank-text bars) were
# dropped or emitted as whitespace text; 145 dashboard-object buttons vanished
# silently. Dividers now emit the NATIVE Sigma divider (live-verified
# POST+readback); navigate buttons emit a text-pill link (kind:button is
# workspace-gated — live-probed PUT 400 "not enabled for this workspace");
# export/toggle buttons become named residue in coverage.json.
#
# Usage:  ruby scripts/test-divider-button-emit.rb
require 'json'
require 'tmpdir'

DIR = __dir__
$LOAD_PATH.unshift File.join(DIR, 'lib')
require 'zone_census'
require 'layout'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

CANVAS = { 'w' => 1366, 'h' => 768 }.freeze

puts 'Part 1 — ZoneCensus.divider_zone? truth table'
rule = { 'kind' => 'spacer', 'fill_color' => '#d4d4d4', 'fixed_size' => 1,
         'w_pct' => 93.0, 'h_pct' => 0.1 }
check(ZoneCensus.divider_zone?(rule, CANVAS), 'filled fixed-1px spacer → divider', fails)
check(!ZoneCensus.divider_zone?(rule.merge('fill_color' => nil), CANVAS),
      'UNFILLED thin spacer → true gap, not a divider', fails)
check(!ZoneCensus.divider_zone?(rule.merge('fixed_size' => 13, 'h_pct' => 5.0), CANVAS),
      '13px is past the 12px boundary → not a divider', fails)
check(ZoneCensus.divider_zone?({ 'kind' => 'spacer', 'fill_color' => '#eee',
                                 'w_pct' => 93.0, 'h_pct' => 0.5 }, CANVAS),
      'pct-only thinness (0.5% of 768px = 3.8px) with canvas_px → divider', fails)
check(!ZoneCensus.divider_zone?({ 'kind' => 'spacer', 'fill_color' => '#eee',
                                  'w_pct' => 93.0, 'h_pct' => 0.5 }, nil),
      'pct-only thinness WITHOUT canvas_px → cannot prove thin → not a divider', fails)
gm = { 'kind' => 'container', 'fill_color' => '#959c9e', 'fixed_size' => 5,
       'w_pct' => 100.0, 'h_pct' => 0.7 }
check(ZoneCensus.divider_zone?(gm, CANVAS), 'childless styled container (gm z43 idiom) → divider', fails)
check(!ZoneCensus.divider_zone?(gm.merge('children' => [{ 'id' => 'x' }]), CANVAS),
      'container WITH children is never a divider', fails)
bt = { 'kind' => 'text', 'fill_color' => '#dcf4ee', 'w_pct' => 45.0, 'h_pct' => 0.6,
       'text_runs' => [{ 'text' => '  ' }, { 'text' => "\n" }] }
check(ZoneCensus.divider_zone?(bt, CANVAS), 'blank-text bar (ecommerce idiom) → divider', fails)
check(!ZoneCensus.divider_zone?(bt.merge('text_runs' => [{ 'text' => 'Revenue' }]), CANVAS),
      'text zone with real prose is never a divider', fails)
check(ZoneCensus.divider_zone?(bt.merge('text_runs' => nil), CANVAS),
      'run-less filled thin text zone is the same idiom → divider', fails)
check(!ZoneCensus.divider_zone?({ 'kind' => 'chart', 'fill_color' => '#eee', 'fixed_size' => 2 }, CANVAS),
      'thin filled CHART zone is content, not a rule', fails)

puts
puts 'Part 2 — direction + divider_el shape'
check(ZoneCensus.divider_direction('w_pct' => 93.0, 'h_pct' => 0.1) == 'horizontal',
      'wide+short → horizontal', fails)
check(ZoneCensus.divider_direction('w_pct' => 0.1, 'h_pct' => 40.0) == 'vertical',
      'narrow+tall → vertical', fails)
el = SigmaLayout.divider_el('dv-1', { 'fill_color' => '#8f171641', 'fixed_size' => 2,
                                      'w_pct' => 0.1, 'h_pct' => 40.0 })
check(el == { 'id' => 'dv-1', 'kind' => 'divider', 'direction' => 'vertical',
              'style' => { 'color' => '#8f1716', 'width' => 2, 'strokeStyle' => 'solid' } },
      "8-digit alpha fill strips to 6-digit stroke color; vertical (got #{el.inspect})", fails)
w = SigmaLayout.divider_el('dv-2', { 'fill_color' => '#e6e6e6', 'fixed_size' => 9,
                                     'w_pct' => 90.0, 'h_pct' => 1.0 })
check(w['style']['width'] == 4, "stroke width clamps to 4 (9px source; got #{w['style']['width']})", fails)
check(SigmaLayout.min_rows_for('divider') == 1 && SigmaLayout.min_rows_for('button') == 2,
      'KIND_MIN_ROWS: divider=1, button=2', fails)

puts
puts 'Part 3 — parser button extraction (windows map + label fallthrough)'
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[Region]' datatype='string' role='dimension' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Trend'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Overview'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='5' name='Trend' x='0' y='20000' w='100000' h='60000' />
            <zone id='10' type-v2='dashboard-object' x='0' y='0' w='20000' h='5000'>
              <button action='tabdoc:goto-sheet window-id=&quot;{ABC-123}&quot;' button-type='text'>
                <button-visual-state><caption>Details</caption>
                  <button-caption-font-style fontcolor='#333333' fontname='Roboto' fontsize='9'/>
                </button-visual-state>
              </button>
            </zone>
            <zone id='11' type-v2='dashboard-object' x='20000' y='0' w='20000' h='5000'>
              <button action='tabdoc:goto-sheet window-id=&quot;{ABC-123}&quot;'>
                <button-visual-state><caption> .</caption>
                  <tooltip-text>Click to navigate to the Detail View</tooltip-text>
                </button-visual-state>
              </button>
            </zone>
            <zone id='12' type-v2='dashboard-object' x='40000' y='0' w='20000' h='5000'>
              <button button-click-action-metadata='pdf'>
                <button-visual-state><caption>Download Report As PDF</caption></button-visual-state>
                <export-button-action/>
              </button>
            </zone>
            <zone id='13' type-v2='dashboard-object' x='60000' y='0' w='20000' h='5000'>
              <button action='tabdoc:toggle-button-click-action zone-ids=[7]'>
                <button-visual-state><image-path>Image/down-arrow.png</image-path>
                  <tooltip-text>Show/Hide Filters</tooltip-text></button-visual-state>
                <toggle-action/>
              </button>
            </zone>
          </zone>
        </zones>
      </dashboard>
    </dashboards>
    <windows>
      <window class='dashboard' name='Detail View'><simple-id uuid='{ABC-123}'/></window>
    </windows>
  </workbook>
XML

layout = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', File.join(DIR, 'parse-twb-layout.rb'), twb, lay,
                                                out: File::NULL, err: File::NULL)
  layout = JSON.parse(File.read(lay))
end
zones = layout.first['zones']
b10 = zones.find { |z| z['id'] == '10' }
check(b10 && b10['button_intent'] == 'navigate' && b10['button_nav_target'] == 'Detail View' &&
      b10['button_nav_target_class'] == 'dashboard',
      "navigate: window-id GUID resolves via <windows> (got #{b10 && b10.values_at('button_intent', 'button_nav_target').inspect})", fails)
check(b10['button_caption'] == 'Details' && b10['button_font_color'] == '#333333',
      'caption + font style extracted', fails)
b11 = zones.find { |z| z['id'] == '11' }
check(b11 && b11['button_caption'].nil? && b11['button_tooltip'].to_s.include?('Detail View'),
      "junk caption ' .' falls through to tooltip (got caption=#{b11 && b11['button_caption'].inspect})", fails)
b12 = zones.find { |z| z['id'] == '12' }
check(b12 && b12['button_intent'] == 'export-pdf', "export-pdf intent (got #{b12 && b12['button_intent']})", fails)
b13 = zones.find { |z| z['id'] == '13' }
check(b13 && b13['button_intent'] == 'toggle' && b13['button_image_path'] == 'Image/down-arrow.png',
      "toggle intent + icon path (got #{b13 && b13.values_at('button_intent', 'button_image_path').inspect})", fails)

puts
puts 'Part 4 — button residue in spec_api_limit_entries (dedupe)'
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'), encoding: 'utf-8')
m = SRC.match(/^def spec_api_limit_entries\b.*?\n^end$/m) or abort('could not extract spec_api_limit_entries')
eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
fixture = [{ 'dashboard' => 'D', 'zones' =>
  [{ 'id' => 'e1', 'kind' => 'dashboard-object', 'button_intent' => 'export-image', 'button_caption' => 'Download PNG' }] +
  Array.new(3) { |i| { 'id' => "t#{i}", 'kind' => 'dashboard-object', 'button_intent' => 'toggle',
                       'button_tooltip' => 'expand section', 'button_image_path' => 'Image/arrow.png' } } }]
entries = spec_api_limit_entries(fixture)
exp = entries.find { |e| e['detail'].include?('download button') }
tog = entries.select { |e| e['detail'].include?('toggle') }
check(exp && exp['recoverable'] == true, 'export button → recoverable residue (Sigma has a built-in export menu)', fails)
check(tog.size == 1 && tog.first['visual'].include?('×3'),
      "3 identical toggles dedupe to ONE ledger row with a count (got #{tog.map { |t| t['visual'] }.inspect})", fails)

puts
if fails.empty?
  puts 'OK — divider synthesis + button semantics hold (predicate, shapes, parser, residue dedupe)'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
