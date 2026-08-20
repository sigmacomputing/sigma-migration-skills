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
require 'action_ledger'

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
puts 'Part 5 — Stage 1: navigate buttons emit a valid action (SIGMA_BUTTON_ELEMENTS=on)'
# Re-run the SAME fixture (the TWB constant from Part 3, zones 10 + 11) through
# the REAL parse + emit path (parse-twb-layout.rb -> build-charts-from-signals.rb
# as subprocesses, exactly like Parts 3/4 drive the real parser/residue code) —
# never a locally-constructed element. That is the only way this check can
# fail when the emitter regresses, which is how the missing-`id` bug shipped.
els = nil
manifest = nil
charts_log = ''
ENV['SIGMA_BUTTON_ELEMENTS'] = 'on'
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump({}))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Trend' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', File.join(DIR, 'parse-twb-layout.rb'), twb, lay,
                                                out: File::NULL, err: File::NULL)

  out = File.join(d, 'specs.json')
  charts_log = IO.popen(['ruby', File.join(DIR, 'build-charts-from-signals.rb'),
                         '--tableau-dir', d, '--layout', lay,
                         '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                         '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                         '--title', 'Overview', '--out', out], err: %i[child out], &:read)
  els = JSON.parse(File.read(out)) if File.exist?(out)
  mpath = out.sub(/\.json$/, '-actions-emitted.json')
  manifest = JSON.parse(File.read(mpath)) if File.exist?(mpath)
end
ENV.delete('SIGMA_BUTTON_ELEMENTS')

if els.nil?
  check(false, "build-charts-from-signals.rb produced no --out — log tail:\n#{charts_log.to_s.lines.last(15).join}", fails)
  els = []
end

btn = els.find { |e| e['kind'] == 'button' }
check(!btn.nil?, 'a kind:button element is emitted with the flag on', fails)
act = btn && (btn['actions'] || []).first
check(!act.nil?, 'the button carries an action', fails)
check(!act.nil? && !act['id'].to_s.empty?,
      "the action has an id (THE SHIPPING BUG - got #{act && act['id'].inspect})", fails)
check(!act.nil? && act['trigger'] == 'on-click', 'trigger is on-click', fails)
check(!act.nil? && act['effects'].is_a?(Array) && act['effects'][0]['effect'] == 'navigate',
      "effect is navigate, not open-url (got #{act && act['effects'] && act['effects'][0] && act['effects'][0]['effect'].inspect})", fails)
check(!act.nil? && act['effects'].is_a?(Array) && act['effects'][0].dig('target', 'type') == 'page',
      'target.type is page', fails)
check(!JSON.generate(els).include?('nav.invalid'),
      'the emitted button carries no nav.invalid placeholder', fails)

# workbook-global id uniqueness across BOTH button zones (10 and 11)
ids = els.select { |e| e['kind'] == 'button' }
         .flat_map { |e| (e['actions'] || []).map { |a| a['id'] } }
check(ids.size == ids.uniq.size, "action ids unique workbook-wide (#{ids.inspect})", fails)

els.select { |e| e['kind'] == 'button' }.each do |e|
  (e['actions'] || []).each do |a|
    errs = ActionLedger.validate_action(a)
    check(errs.empty?, "emitted action #{a['id'].inspect} validates: #{errs.inspect}", fails)
  end
end

# Fix 1: every manifest entry carries the raw target dashboard NAME — the key
# put-layout.rb's publish-time repair needs to resolve navigate.target.page by
# name (the build-time "page-<slug>" id is only a guess; see the comment at
# the emission site for why it can't be authoritative here).
check(!manifest.nil? && manifest.is_a?(Array) && manifest.size == 2,
      "manifest has one entry per emitted action (got #{manifest.inspect})", fails)
Array(manifest).each do |entry|
  check(!entry['targetPageName'].to_s.empty?,
        "manifest entry #{entry['actionId'].inspect} carries a non-empty targetPageName (got #{entry['targetPageName'].inspect})", fails)
end

puts
puts 'Part 6 — Fix 2 regression: manifest must not go stale under --page-per-dashboard renaming'
# Tableau zone ids restart per dashboard, so TWO dashboards each having a
# nav-button at zone id 10 is a common collision, not an edge case. In
# --page-per-dashboard mode the SECOND dashboard's "btn-10" element (and its
# embedded action id, which EMBEDS the element-id stem) gets renamed by the
# cross-dashboard id-namespacing pass (`namespace_ids`, build-charts-from-
# signals.rb) — a pass that runs AFTER the manifest was originally populated.
# This reproduces that exact collision end-to-end and asserts the manifest
# entry for the renamed button tracks the SAME rename, not the pre-rename id.
TWB2 = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[Region]' datatype='string' role='dimension' />
        <column caption='Revenue' name='[Revenue]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Trend'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x'>
              <column caption='Region' name='[Region]' datatype='string' role='dimension' />
              <column caption='Revenue' name='[Revenue]' datatype='real' role='measure' />
              <column-instance column='[Region]' derivation='None' name='[none:Region:nk]' pivot='key' type='nominal' />
              <column-instance column='[Revenue]' derivation='Sum' name='[sum:Revenue:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <rows>[federated.x].[sum:Revenue:qk]</rows>
          <cols>[federated.x].[none:Region:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash One'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='5' name='Trend' x='0' y='20000' w='100000' h='60000' />
            <zone id='10' type-v2='dashboard-object' x='0' y='0' w='20000' h='5000'>
              <button action='tabdoc:goto-sheet window-id=&quot;{ABC-999}&quot;'>
                <button-visual-state><caption>Go to Detail (One)</caption></button-visual-state>
              </button>
            </zone>
          </zone>
        </zones>
      </dashboard>
      <dashboard name='Dash Two'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='5' name='Trend' x='0' y='20000' w='100000' h='60000' />
            <zone id='10' type-v2='dashboard-object' x='0' y='0' w='20000' h='5000'>
              <button action='tabdoc:goto-sheet window-id=&quot;{ABC-999}&quot;'>
                <button-visual-state><caption>Go to Detail (Two)</caption></button-visual-state>
              </button>
            </zone>
          </zone>
        </zones>
      </dashboard>
    </dashboards>
    <windows>
      <window class='dashboard' name='Dash One'/>
      <window class='dashboard' name='Dash Two'/>
      <window class='dashboard' name='Detail View'><simple-id uuid='{ABC-999}'/></window>
    </windows>
  </workbook>
XML

spec2 = nil
manifest2 = nil
charts_log2 = ''
ENV['SIGMA_BUTTON_ELEMENTS'] = 'on'
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB2)
  File.write(mm, JSON.dump('(?i)^Region$' => { 'id' => 'm-reg', 'name' => 'Region' },
                           '(?i)^Revenue$' => { 'id' => 'm-rev', 'name' => 'Revenue' }))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Trend' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), "Region,Revenue\nEast,100\nWest,200\n")
  abort 'parse-twb-layout failed' unless system('ruby', File.join(DIR, 'parse-twb-layout.rb'), twb, lay,
                                                out: File::NULL, err: File::NULL)

  out = File.join(d, 'specs.json')
  charts_log2 = IO.popen(['ruby', File.join(DIR, 'build-charts-from-signals.rb'),
                          '--tableau-dir', d, '--layout', lay,
                          '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                          '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                          '--page-per-dashboard', '--out', out], err: %i[child out], &:read)
  spec2 = JSON.parse(File.read(out)) if File.exist?(out)
  mpath = out.sub(/\.json$/, '-actions-emitted.json')
  manifest2 = JSON.parse(File.read(mpath)) if File.exist?(mpath)
end
ENV.delete('SIGMA_BUTTON_ELEMENTS')

if spec2.nil? || manifest2.nil?
  check(false, "Part 6 fixture produced no --out/manifest — log tail:\n#{charts_log2.to_s.lines.last(15).join}", fails)
else
  pages2 = spec2['pages'] || []
  dash_one_els = (pages2.find { |p| p['name'] == 'Dash One' } || {})['elements'] || []
  dash_two_els = (pages2.find { |p| p['name'] == 'Dash Two' } || {})['elements'] || []
  btn_one = dash_one_els.find { |e| e['kind'] == 'button' }
  btn_two = dash_two_els.find { |e| e['kind'] == 'button' }

  check(!btn_one.nil? && !btn_two.nil?, 'both dashboards emitted their nav-button element', fails)
  check(!btn_one.nil? && btn_one['id'] == 'btn-10',
        "the FIRST occurrence of the colliding zone id keeps its plain id (got #{btn_one && btn_one['id'].inspect})", fails)
  check(!btn_two.nil? && btn_two['id'] != 'btn-10',
        "the SECOND occurrence of the colliding zone id (btn-10 on Dash Two) was renamed by the namespacing pass " \
        "(got #{btn_two && btn_two['id'].inspect}) — if this is still 'btn-10' the collision fixture stopped colliding", fails)

  # Ground truth: every navigate action id actually present in the built spec.
  spec_action_ids = pages2.flat_map { |p| p['elements'] || [] }
                          .select { |e| e['kind'] == 'button' }
                          .flat_map { |e| (e['actions'] || []).map { |a| a['id'] } }
  spec_host_ids = pages2.flat_map { |p| p['elements'] || [] }
                        .select { |e| e['kind'] == 'button' }
                        .map { |e| e['id'] }
  manifest_action_ids = manifest2.map { |m| m['actionId'] }
  manifest_host_ids   = manifest2.map { |m| m['hostElementId'] }

  # Bidirectional: manifest <-> spec must agree exactly (the later gate the
  # coordinator described asserts precisely this both ways).
  check(manifest_action_ids.sort == spec_action_ids.sort,
        "manifest actionIds match the spec's actual action ids exactly, both directions " \
        "(manifest=#{manifest_action_ids.sort.inspect}, spec=#{spec_action_ids.sort.inspect})", fails)
  check(manifest_host_ids.sort == spec_host_ids.sort,
        "manifest hostElementIds match the spec's actual button element ids exactly, both directions " \
        "(manifest=#{manifest_host_ids.sort.inspect}, spec=#{spec_host_ids.sort.inspect})", fails)

  # The specific stale-entry shape the coordinator described: Dash Two's
  # manifest entry must carry the RENAMED id, not the pre-rename "btn-10".
  two_entry = manifest2.find { |m| m['source'] && m['source']['sourceSheet'] == 'Dash Two' }
  check(!two_entry.nil? && !btn_two.nil? && two_entry['hostElementId'] == btn_two['id'],
        "Dash Two's manifest entry hostElementId matches its ACTUAL (renamed) element id, not the stale pre-rename one " \
        "(manifest=#{two_entry && two_entry['hostElementId'].inspect}, actual=#{btn_two && btn_two['id'].inspect})", fails)
  check(!two_entry.nil? && !btn_two.nil? &&
        two_entry['actionId'] == (btn_two['actions'] || []).first&.dig('id'),
        "Dash Two's manifest entry actionId matches the ACTUAL emitted action id, not the stale pre-rename one " \
        "(manifest=#{two_entry && two_entry['actionId'].inspect}, " \
        "actual=#{btn_two && (btn_two['actions'] || []).first&.dig('id').inspect})", fails)
end

puts
puts 'Part 7 - Default mode (flag OFF): nav buttons stay kind:text with the nav.invalid placeholder'
# Same fixture, same real subprocess pipeline as Part 5 (parse-twb-layout.rb ->
# build-charts-from-signals.rb) - but with SIGMA_BUTTON_ELEMENTS explicitly
# UNSET, not merely absent by luck of part ordering. Save/restore whatever the
# env held before so this part's outcome can never depend on what ran earlier
# (Parts 5/6 set the flag to 'on'). The brief calls a regression here Critical:
# this is the path every real conversion runs by default.
had_flag = ENV.key?('SIGMA_BUTTON_ELEMENTS')
prev_flag = ENV['SIGMA_BUTTON_ELEMENTS']
ENV.delete('SIGMA_BUTTON_ELEMENTS')

els7 = nil
manifest7 = nil
charts_log7 = ''
begin
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    lay = File.join(d, 'layout.json')
    mm  = File.join(d, 'master-map.json')
    File.write(twb, TWB)
    File.write(mm, JSON.dump({}))
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Trend' }] }))
    Dir.mkdir(File.join(d, 'views'))
    File.write(File.join(d, 'views', 'v1.csv'), '')
    abort 'parse-twb-layout failed' unless system('ruby', File.join(DIR, 'parse-twb-layout.rb'), twb, lay,
                                                  out: File::NULL, err: File::NULL)

    out = File.join(d, 'specs.json')
    charts_log7 = IO.popen(['ruby', File.join(DIR, 'build-charts-from-signals.rb'),
                            '--tableau-dir', d, '--layout', lay,
                            '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                            '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                            '--title', 'Overview', '--out', out], err: %i[child out], &:read)
    els7 = JSON.parse(File.read(out)) if File.exist?(out)
    mpath = out.sub(/\.json$/, '-actions-emitted.json')
    manifest7 = JSON.parse(File.read(mpath)) if File.exist?(mpath)
  end
ensure
  check(!ENV.key?('SIGMA_BUTTON_ELEMENTS'), 'SIGMA_BUTTON_ELEMENTS stayed unset for the whole subprocess run', fails)
  if had_flag
    ENV['SIGMA_BUTTON_ELEMENTS'] = prev_flag
  else
    ENV.delete('SIGMA_BUTTON_ELEMENTS')
  end
end

if els7.nil?
  check(false, "build-charts-from-signals.rb produced no --out -- log tail:\n#{charts_log7.to_s.lines.last(15).join}", fails)
  els7 = []
end

nav_els7 = els7.select { |e| %w[btn-10 btn-11].include?(e['id']) }
check(nav_els7.size == 2,
      "both nav-button elements (zones 10 + 11) present in default mode (got ids #{els7.map { |e| e['id'] }.inspect})", fails)

nav_els7.each do |e|
  check(e['kind'] == 'text',
        "default mode: nav-button #{e['id'].inspect} is kind:text (got #{e['kind'].inspect})", fails)
  check(e['kind'] != 'button',
        "default mode: nav-button #{e['id'].inspect} is NOT kind:button", fails)
  check(JSON.generate(e).include?('nav.invalid'),
        "default mode: nav-button #{e['id'].inspect} still carries the nav.invalid placeholder URL", fails)
  check(!e.key?('actions'),
        "default mode: nav-button #{e['id'].inspect} has no actions key " \
        "(kind:text cannot host actions -- got keys #{e.keys.inspect})", fails)
end

check(!manifest7.nil?, 'default mode: the emitted-actions manifest sidecar was still written (empty is meaningful)', fails)
manifest7_hosts = Array(manifest7).map { |m| m['hostElementId'] }
check((manifest7_hosts & %w[btn-10 btn-11]).empty?,
      "default mode: manifest claims NO entry for either nav-button (nothing was auto-wired; got hosts #{manifest7_hosts.inspect})", fails)
check(Array(manifest7).empty?,
      "default mode: manifest is an empty array -- no actions were auto-emitted at all (got #{manifest7.inspect})", fails)

puts
if fails.empty?
  puts 'OK — divider synthesis + button semantics hold (predicate, shapes, parser, residue dedupe)'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
