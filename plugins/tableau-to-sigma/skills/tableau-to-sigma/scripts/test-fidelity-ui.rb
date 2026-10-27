#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the presentation-fidelity gaps a live side-by-side of migrated Sigma
# workbooks against their Tableau sources turned up. Offline: the real parse-twb-layout.rb (+ its
# Python twin), build-charts-from-signals.rb and build-dashboard-layout.rb over the synthetic
# scripts/fixtures/fidelity-ui.twb (invented names) and hand-built zone trees.
#
#   1. Category colors: the member->color map lives on the <datasource> (no worksheet-level copy);
#      it is read into series_colors (rb + py), pinned as an ordered scheme, and re-derived over the
#      members a chart actually shows (a 2-of-3-member chart must not shift every slot).
#   2. Header nav button: a button in the source's header row rides the header band beside the
#      title (all three layout paths) instead of a bottom band, and no tall mostly-empty band is
#      left where its row container was.
#   3a. A crosstab sorted by a measure it does not show sorts by it (hidden helper) and a literal
#       top-N is applied as a rank-limited pre-filtered source.
#   3b. A boolean-calc Color shelf becomes conditional text color; a named built-in heat ramp
#       becomes a backgroundScale; a sort helper never shows as a visible column.
#   3c. YEAR(date) pivot headers are labelled with the year.
#   3d. A bounded in-range quick filter's control excludes NULLs (a NULL falls into an ELSE bucket).
#
# Usage:  ruby scripts/test-fidelity-ui.rb
require 'json'
require 'rexml/document'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/ruby_compat'
require_relative 'lib/series_colors'

DIR      = __dir__
PARSER   = File.join(DIR, 'parse-twb-layout.rb')
PARSER_PY = File.join(DIR, 'parse-twb-layout.py')
BUILD    = File.join(DIR, 'build-charts-from-signals.rb')
LAYOUT   = File.join(DIR, 'build-dashboard-layout.rb')
FIXTURE  = File.join(DIR, 'fixtures', 'fidelity-ui.twb')
RUBY     = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def mmap_for(names)
  names.each_with_object({}) do |name, h|
    entry = { 'id' => "m-#{name.downcase.gsub(/\W+/, '-')}", 'name' => name }
    [name, name.upcase.tr(' ', '_')].each do |alias_name|
      h["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of |(?:avg|sum|min|max|med|cnt|ctd)\\.\\s*)?#{Regexp.escape(alias_name)}$"] = entry
    end
  end
end
MMAP = mmap_for(['Category', 'Store Name', 'Store Type', 'Ship Method', 'Order Id', 'Order Date', 'Days To Ship',
                 'Net Revenue', 'Gross Profit']).freeze

CSVS = {
  'Category Bar' => "Category,Net Revenue\nElectronics,\"61,729.68\"\nApparel,\"51,400.88\"\nHome,\"37,481.97\"\n",
  'Top Bar' => "Category,Net Revenue\nElectronics,\"61,729.68\"\nHome,\"37,481.97\"\n",
  # Tableau already applied the top-3 and the sort: rank order, no Net Revenue column (never displayed)
  'Store Rank' => "Store Name,Margin %,Orders\nPortland,64.6%,103\nNYC Midtown,67.8%,94\nChicago Loop,67.5%,103\n",
  'Return Heat' => "Store Type,Ship Method,Net Revenue\nFlagship,BOPIS,\"1,000.00\"\nFlagship,Express,\"2,000.00\"\nKiosk,BOPIS,\"500.00\"\n",
  'YoY Growth' => "Year of Order Date,YoY Growth %\n2024,\n2025,12.0%\n",
  'Days Bar' => "Store Type,Net Revenue\nFlagship,\"1,000.00\"\nKiosk,\"500.00\"\n"
}.freeze

# One parse (rb) + one build over the fixture; returns the parsed layout + built elements.
def run_pipeline(twb_text)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    o, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: o } unless File.exist?(lay)
    doc = JSON.parse(File.read(lay))
    doc.each do |dash|
      dash['zones'].each do |z|
        z['chart_kind'] = 'pivot-table' if %w[YoY\ Growth].include?(z['caption']) && z['kind'] == 'chart'
      end
    end
    File.write(lay, JSON.pretty_generate(doc))
    views = CSVS.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    CSVS.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'FU', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(MMAP))
    out = File.join(d, 'chart-specs.json')
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                              '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'),
                              '--master-element-id', 'master', '--auto-controls',
                              '--skip-dashboard-read', 'offline test fixture', '--out', out)
    rd = ->(n) { f = File.join(d, n); File.exist?(f) ? JSON.parse(File.read(f)) : nil }
    specs = rd.call('chart-specs.json')
    flat = specs.is_a?(Hash) ? specs['pages'].flat_map { |p| p['elements'] } : (specs || [])
    { ok: st.success?, log: log, specs: specs, elements: flat,
      data: (specs.is_a?(Hash) ? specs['data_elements'] : nil) || rd.call('chart-specs-data-elements.json') || [],
      layout: rd.call('dashboard-layout.json') }
  end
end

FIXTURE_TEXT = File.read(FIXTURE, encoding: 'utf-8')
r = run_pipeline(FIXTURE_TEXT)
abort "pipeline failed\n#{r[:log]}" unless r[:ok]
els = r[:elements]
el = ->(id) { els.find { |e| e['id'] == id } }
zone = ->(cap) { (r[:layout].flat_map { |dash| dash['zones'] }).find { |z| z['caption'] == cap && z['kind'] == 'chart' } }
col = ->(e, frag) { ((e || {})['columns'] || []).find { |c| c['id'].to_s.include?(frag) } }

# ---------------------------------------------------------------------------
puts '-- 1. datasource-level color map -> series_colors -> pinned scheme'
sc = zone.call('Category Bar')['series_colors']
check(sc.is_a?(Array) && sc.map { |p| [p['member'], p['color']] } ==
        [['Apparel', '#4e79a7'], ['Electronics', '#f28e2b'], ['Home', '#59a14f']],
      "datasource map surfaced as the sheet's series_colors (got #{sc.inspect})", fails)
check(zone.call('Category Bar')['series_color_field'] == 'Category', 'encoded field resolves to its caption', fails)
check(zone.call('Days Bar')['series_colors'].nil?, 'a sheet whose color field has no map keeps series_colors nil', fails)

Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  File.write(twb, FIXTURE_TEXT)
  out_py = File.join(d, 'py.json')
  _o, st = Open3.capture2e('python3', PARSER_PY, twb, out_py)
  py = st.success? && File.exist?(out_py) ? JSON.parse(File.read(out_py)) : nil
  pz = py && py.flat_map { |dash| dash['zones'] }.find { |z| z['caption'] == 'Category Bar' && z['kind'] == 'chart' }
  check(pz && pz['series_colors'] == sc && pz['series_color_field'] == 'Category',
        'python twin reads the same datasource map (rb/py parity)', fails)
  hz = py && py.flat_map { |dash| dash['zones'] }.find { |z| z['caption'] == 'Return Heat' && z['kind'] == 'chart' }
  rz = zone.call('Return Heat')
  check(rz && rz['heat_scheme'] == %w[#ffc685 #f07825 #9e3d22], "built-in orange ramp surfaced as heat_scheme (got #{rz && rz['heat_scheme'].inspect})", fails)
  check(hz && hz['heat_scheme'] == rz['heat_scheme'], 'python twin resolves the same built-in ramp', fails)
end

bar = el.call('el-category-bar')
check(bar && bar.dig('color', 'scheme') == %w[#4e79a7 #f28e2b #59a14f],
      "Category Bar scheme = Apparel blue, Electronics orange, Home GREEN in ascending member order (got #{bar && bar.dig('color', 'scheme').inspect})", fails)
top = el.call('el-top-bar')
check(top && top.dig('color', 'scheme') == %w[#f28e2b #59a14f],
      "Top Bar shows 2 of 3 members: scheme re-derived over THEM (Electronics orange, Home green; got #{top && top.dig('color', 'scheme').inspect})", fails)
sub = SeriesColors.scheme_for_members({ 'Apparel' => '#4e79a7', 'Electronics' => '#f28e2b', 'Home' => '#59a14f' },
                                      %w[Home Apparel], %w[#111111 #222222])
check(sub == %w[#4e79a7 #59a14f], 'scheme_for_members: ascending members, each its own color', fails)
unk = SeriesColors.scheme_for_members({ 'Apparel' => '#4e79a7' }, %w[Apparel Zed], %w[#4e79a7 #222222])
check(unk == %w[#4e79a7 #222222], 'scheme_for_members: an unmapped member takes the next UNUSED palette color', fails)
check(SeriesColors.scheme_for_members({ 'Apparel' => '#4e79a7' }, %w[Zed Yak], %w[#111111]).nil?,
      'scheme_for_members: members the map never names -> nil (caller keeps its fallback)', fails)

# ---------------------------------------------------------------------------
puts
puts '-- 3a. crosstab sorted by an undisplayed measure + literal top-N'
rank = el.call('el-store-rank')
check(rank && rank['kind'] == 'pivot-table', 'Store Rank emitted as a pivot', fails)
check(rank && rank['rowsBy'].first['sort'].is_a?(Hash),
      "the Store axis carries a sort (was alphabetical; got #{rank && rank['rowsBy'].first.inspect})", fails)
src_id = rank && rank.dig('source', 'elementId').to_s
helper = (r[:data] + els).find { |e| e['id'] == src_id }
check(helper && src_id.include?('topn-src'), "top-3 applied as a rank-limited pre-filtered source (source=#{src_id})", fails)
members = helper && Array(helper['filters']).flat_map { |f| Array(f['values']) }
check(members == ['Portland', 'NYC Midtown', 'Chicago Loop'], "pre-filter members = the view's rank-ordered stores (got #{members.inspect})", fails)

# ---------------------------------------------------------------------------
puts
puts '-- 3b. flag color -> conditional text color; built-in ramp -> backgroundScale; no visible sort helper'
vis = rank && rank['values'].map { |v| col.call(rank, v) }.reject { |c| c['hidden'] }.map { |c| c['name'] }
check(vis == ['Margin %', 'Orders'], "only the measures Tableau shows are visible (got #{vis.inspect})", fails)
check(rank && rank['columns'].none? { |c| c['name'] == 'Net Revenue' && !c['hidden'] }, 'the Net Revenue sort key never shows', fails)
cf = rank && rank['conditionalFormats']
check(cf.is_a?(Array) && cf.size == 2 && cf.all? { |c| c['type'] == 'single' && c['condition'] == 'formula' },
      "two formula rules (true / false) carried (got #{cf.inspect})", fails)
flag_col = rank && rank['columns'].find { |c| c['name'].to_s =~ /flag/i }
check(flag_col && flag_col['hidden'] && rank['values'].include?(flag_col['id']) && flag_col['formula'].to_s.include?('< 0.66'),
      "the flag is a HIDDEN column ON the values shelf (a hidden non-value is not evaluated per row; formula #{flag_col && flag_col['formula'].inspect})", fails)
check(cf && cf[0]['style'] == { 'color' => '#d1495b', 'backgroundColor' => 'none' } &&
        cf[1]['style'] == { 'color' => '#1b5e20', 'backgroundColor' => 'none' },
      'true -> the map\'s red text, false -> green text, no default highlight fill', fails)
check(cf && cf.all? { |c| c['columnIds'].all? { |id| rank['values'].include?(id) && !col.call(rank, id)['hidden'] } },
      'rules cover the visible value columns only', fails)
heat = el.call('el-return-heat')
check(heat && heat['conditionalFormats'] == [{ 'type' => 'backgroundScale', 'columnIds' => heat['values'],
                                                'scheme' => %w[#ffc685 #f07825 #9e3d22] }],
      "heat crosstab carries the source orange ramp as backgroundScale (got #{heat && heat['conditionalFormats'].inspect})", fails)

# ---------------------------------------------------------------------------
puts
puts '-- 3c. YEAR(date) pivot header'
yoy = els.find { |e| e['kind'] == 'pivot-table' && e['name'].to_s =~ /yoy/i }
yfmt = yoy && yoy['columns'].find { |c| c['formula'].to_s =~ /DateTrunc\("year"/ }
check(yfmt && yfmt.dig('format', 'formatString') == '%Y',
      "year header formatted %Y, not 'Jan 2024' (got #{yfmt && yfmt['format'].inspect})", fails)

# ---------------------------------------------------------------------------
puts
puts '-- 3d. bounded range quick filter excludes NULLs'
ctl = els.find { |e| e['kind'] == 'control' && e['controlType'] == 'range-slider' }
check(ctl && ctl['includeNulls'] == 'never',
      "bounded Days To Ship range control: includeNulls never (got #{ctl && ctl['includeNulls'].inspect})", fails)

# ---------------------------------------------------------------------------
# Layout: header nav button on the three builder paths
# ---------------------------------------------------------------------------
BTN = { 'x_pct' => 82.0, 'y_pct' => 0.0, 'w_pct' => 18.0, 'h_pct' => 6.0 }.freeze
TITLE = { 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 72.0, 'h_pct' => 6.0 }.freeze
def tz(id, kind, geo, extra = {})
  { 'id' => id, 'kind' => kind }.merge(geo).merge(extra)
end

def chart(id, cap, x, y, w, h)
  tz(id, 'chart', { 'x_pct' => x, 'y_pct' => y, 'w_pct' => w, 'h_pct' => h },
     'caption' => cap, 'chart_kind' => 'bar', 'measures' => [{ 'column' => '[m]' }])
end

TITLE_RUNS = [{ 'text' => 'Store Network' }].freeze
# (a) container-tree path: header row container (title + spacer + button) over a body with a filter rail
TREE = {
  'dashboard' => 'Tree Page', 'is_story' => false, 'canvas_px' => { 'w' => 1400, 'h' => 900, 'sizing_mode' => 'fixed' },
  'zones' => [
    tz('27', 'text', TITLE, 'text_runs' => TITLE_RUNS),
    tz('29', 'dashboard-object', BTN),
    tz('33', 'filter', { 'x_pct' => 0.0, 'y_pct' => 10.0, 'w_pct' => 14.0, 'h_pct' => 20.0 }, 'caption' => 'Region'),
    chart('38', 'Wide Chart', 14.0, 6.0, 86.0, 60.0),
    chart('39', 'Short Chart', 14.0, 66.0, 86.0, 34.0)
  ],
  'zone_tree' => [
    { 'id' => '24', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0, 'children' => [
      { 'id' => '25', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0, 'children' => [
        { 'id' => '26', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 6.0, 'children' => [
          tz('27', 'text', TITLE, 'text_runs' => TITLE_RUNS),
          { 'id' => '28', 'kind' => 'spacer', 'x_pct' => 72.0, 'y_pct' => 0.0, 'w_pct' => 10.0, 'h_pct' => 6.0 },
          tz('29', 'dashboard-object', BTN)
        ] },
        { 'id' => '30', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 6.0, 'w_pct' => 100.0, 'h_pct' => 94.0, 'children' => [
          { 'id' => '31', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 6.0, 'w_pct' => 14.0, 'h_pct' => 94.0, 'children' => [
            tz('33', 'filter', { 'x_pct' => 0.0, 'y_pct' => 10.0, 'w_pct' => 14.0, 'h_pct' => 20.0 }, 'caption' => 'Region')
          ] },
          { 'id' => '36', 'kind' => 'container', 'x_pct' => 14.0, 'y_pct' => 6.0, 'w_pct' => 86.0, 'h_pct' => 94.0, 'children' => [
            tz('38', 'chart', { 'x_pct' => 14.0, 'y_pct' => 6.0, 'w_pct' => 86.0, 'h_pct' => 60.0 }, 'caption' => 'Wide Chart'),
            tz('39', 'chart', { 'x_pct' => 14.0, 'y_pct' => 66.0, 'w_pct' => 86.0, 'h_pct' => 34.0 }, 'caption' => 'Short Chart')
          ] }
        ] }
      ] }
    ] }
  ]
}.freeze

# (b) synthesized path: flat zones with a left control rail + two chart bands under a title/button row
SYN_RAIL = [
  tz('9', 'text', { 'x_pct' => 0.0, 'y_pct' => 6.0, 'w_pct' => 14.0, 'h_pct' => 4.0 }, 'text_runs' => [{ 'text' => 'Filters' }]),
  tz('11', 'filter', { 'x_pct' => 0.0, 'y_pct' => 10.0, 'w_pct' => 14.0, 'h_pct' => 14.0 }, 'caption' => 'Region'),
  tz('12', 'filter', { 'x_pct' => 0.0, 'y_pct' => 24.0, 'w_pct' => 14.0, 'h_pct' => 14.0 }, 'caption' => 'Channel')
].freeze
SYN = {
  'dashboard' => 'Synth Page', 'is_story' => false, 'canvas_px' => { 'w' => 1400, 'h' => 900, 'sizing_mode' => 'fixed' },
  'zones' => [
    tz('4', 'text', TITLE, 'text_runs' => TITLE_RUNS), tz('6', 'dashboard-object', BTN), *SYN_RAIL,
    chart('21', 'Left Chart', 14.0, 10.0, 43.0, 40.0), chart('22', 'Right Chart', 57.0, 10.0, 43.0, 40.0),
    chart('23', 'Lower Left', 14.0, 52.0, 43.0, 40.0), chart('24', 'Lower Right', 57.0, 52.0, 43.0, 40.0)
  ],
  'zone_tree' => []
}.freeze

# (c) banded fallback: no rail, no KPI row
BAND = {
  'dashboard' => 'Band Page', 'is_story' => false, 'canvas_px' => nil,
  'zones' => [
    tz('16', 'dashboard-object', BTN),
    chart('21', 'Band A', 0.0, 20.0, 50.0, 70.0), chart('22', 'Band B', 50.0, 20.0, 50.0, 70.0)
  ],
  'zone_tree' => []
}.freeze

def page(name, id, ids)
  { 'name' => name, 'id' => id, 'elements' => ids.map { |(eid, kind, nm)| { 'id' => eid, 'kind' => kind, 'name' => nm } } }
end
WB = { 'pages' => [
  page('Data', 'page-data', [['master', 'table', 'M']]),
  page('Tree Page', 'page-d1', [['text-27', 'text', nil], ['btn-29', 'button', nil], ['el-ctl-region', 'control', 'Region'],
                                ['el-wide', 'bar-chart', 'Wide Chart'], ['el-short', 'bar-chart', 'Short Chart']]),
  page('Synth Page', 'page-d2', [['text-4', 'text', nil], ['btn-6', 'button', nil], ['text-9', 'text', nil],
                                 ['el-ctl-s-region', 'control', 'Region'], ['el-ctl-s-channel', 'control', 'Channel'],
                                 ['el-l', 'bar-chart', 'Left Chart'], ['el-r', 'bar-chart', 'Right Chart'],
                                 ['el-ll', 'bar-chart', 'Lower Left'], ['el-lr', 'bar-chart', 'Lower Right']]),
  page('Band Page', 'page-d3', [['title-band', 'text', nil], ['btn-16', 'button', nil],
                                ['el-a', 'bar-chart', 'Band A'], ['el-b', 'bar-chart', 'Band B']])
] }.freeze

xml = nil
log = ''
Dir.mktmpdir do |d|
  File.write(File.join(d, 'dl.json'), JSON.generate([TREE, SYN, BAND]))
  File.write(File.join(d, 'wb.json'), JSON.generate(WB))
  out = File.join(d, 'layout.xml')
  log = IO.popen([RUBY, LAYOUT, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out],
                 err: %i[child out], &:read)
  xml = File.read(out) if File.exist?(out)
end
abort "layout build produced nothing\n#{log}" if xml.nil?
doc = REXML::Document.new("<Root>#{xml.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")
pages = {}
doc.elements.each('Root/Page') { |pg| pages[pg.attributes['id']] = pg }

def span(attr)
  attr.to_s.split('/').map { |s| s.strip.to_i }
end

def container(pg, id)
  pg.elements.to_a('.//Container').find { |g| g.attributes['elementId'] == id }
end

def child_cells(c)
  c.elements.to_a('Element').map { |e| [e.attributes['elementId'], [span(e.attributes['gridColumn']), span(e.attributes['gridRow'])]] }.to_h
end

def holder(pg, eid)
  pg.elements.to_a('.//Element').find { |e| e.attributes['elementId'] == eid }&.parent
end

puts
puts '-- 2. header nav button rides the header band (tree / synthesized / banded paths)'
{ 'page-d1' => ['tc-page-d1-hdr', 'text-27', 'btn-29'],
  'page-d2' => ['syn-page-d2-hdr', 'text-4', 'btn-6'],
  'page-d3' => ['band-page-d3-hdr', 'title-band', 'btn-16'] }.each do |pid, (hid, title, btn)|
  hdr = container(pages[pid], hid)
  cells = hdr ? child_cells(hdr) : {}
  check(cells.key?(title) && cells.key?(btn), "#{pid}: header band holds the title AND the nav button (#{cells.keys.inspect})", fails)
  check(cells[btn] && cells[btn][0] == [21, 25], "#{pid}: button at the top-right columns 21..25 (got #{cells[btn] && cells[btn][0].inspect})", fails)
  check(cells[title] && cells[title][0][1] <= cells[btn][0][0].to_i + 0 && cells[title][0][1] <= 21,
        "#{pid}: title narrows to end before the button (got #{cells[title] && cells[title][0].inspect})", fails)
  check(cells[btn] && cells[btn][1][0] == 1, "#{pid}: button in the TOP row of the band", fails)
  placed = pages[pid].elements.to_a('.//Element').count { |e| e.attributes['elementId'] == btn }
  check(placed == 1, "#{pid}: the button is placed exactly once (no bottom-band duplicate; #{placed})", fails)
  check(pages[pid].elements.to_a('.//Container').none? { |g| g.attributes['elementId'].to_s.end_with?('-extra') },
        "#{pid}: nothing falls into the safety-net bottom band", fails)
end

tree_page = pages['page-d1']
wide = holder(tree_page, 'el-wide')
check(tree_page.elements.to_a('.//Container').none? { |g| child_cells(g).keys == ['btn-29'] },
      'tree page: no container is left holding only the button (no tall empty row band)', fails)
w_rows = child_cells(wide)['el-wide'][1]
s_rows = child_cells(wide)['el-short'][1]
check((w_rows[1] - w_rows[0]) > (s_rows[1] - s_rows[0]),
      "tree page: the 60%-tall chart keeps more rows than the 34% chart — source proportions survive (wide=#{w_rows.inspect} short=#{s_rows.inspect})", fails)
hdr_rows = span(container(tree_page, 'tc-page-d1-hdr').attributes['gridRow'])
body_top = span(container(tree_page, 'tc-page-d1-30').attributes['gridRow'])
check(body_top[0] == hdr_rows[1], "tree page: the body starts right under the header band (hdr #{hdr_rows.inspect}, body #{body_top.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILED:"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
