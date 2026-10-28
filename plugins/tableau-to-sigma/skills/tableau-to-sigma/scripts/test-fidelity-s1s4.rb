#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for four fidelity bugs a live Tableau-vs-Sigma comparison found in migrated
# dashboards. Driven end to end (offline) through the real parse-twb-layout.rb/.py +
# build-charts-from-signals.rb (--page-per-dashboard, like migrate-tableau.rb) on
# scripts/fixtures/fidelity-s1s4.twb (synthetic, invented names):
#
#   1. Dual-axis combo. An UNSYNCHRONIZED dual axis is `rows = (A + B)` plus one pane per
#      measure (Bar left, Line right); only `synchronized='true'` used to raise dual_axis, so the
#      two measures collapsed into ONE shelf field (the last term), the view CSV's column order
#      (not the shelf order) picked the plotted measure, and the line vanished. Now the parser
#      emits dual_axis_series (both twins), the builder plots primary-as-bar + secondary-as-line
#      and puts the second series on yAxis2 (live-probed: without yAxis2 the 0.67 ratio line is
#      flat on the 20,000-unit bar axis).
#   2. Top-N on a chart with a COLOR dim. Sigma partitions a chart-level Rank() (and a native
#      top-n element filter) by the color series, so "top 10 products" kept the top 10 PER
#      Category. The rank now lives in a hidden dim-grain helper (unpartitioned), bridged back
#      with Lookup() and filtered on `Max(Lookup(..)) <= N`; the chart keeps its master source.
#      Covers the parameter-driven N (Rank()+keep idiom) and the literal-N native filter, the
#      helper's control ref following the per-page controlId suffix, per-page master cloning
#      keeping a formula-referenced helper, and the lint accepting the Lookup bridge.
#   3. Relative-date windows that span the current period ("years -2..+1") have no
#      last/next/current mode; they ROLL as mode:custom with unit-ed relative bounds (live-probed
#      calendar-aligned: start of the first period .. END of the last) instead of freezing to
#      build-time dates.
#
# Usage:  ruby scripts/test-fidelity-s1s4.rb
require 'json'
require 'date'
require 'time'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/ruby_compat'
require_relative 'lib/per_page_masters'
require_relative 'mechanical-specs'

DIR      = __dir__
PARSER   = File.join(DIR, 'parse-twb-layout.rb')
PARSER_PY = File.join(DIR, 'parse-twb-layout.py')
BUILD    = File.join(DIR, 'build-charts-from-signals.rb')
VALIDATE = File.join(DIR, 'validate-spec.rb')
FIXTURE  = File.join(DIR, 'fixtures', 'fidelity-s1s4.twb')
RUBY     = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def mmap_entry(name, extra = {})
  { 'id' => "m-#{name.downcase.gsub(/\W+/, '-')}", 'name' => name }.merge(extra)
end

# caption + raw warehouse name aliases, the way stress-gaps' base_mmap keys them
def build_mmap
  entries = {
    'Order Date' => {}, 'Category' => {}, 'Product Name' => {}, 'City' => {}, 'Store Type' => {},
    'Net Revenue' => {}, 'Gross Profit' => {}, 'Quantity Ordered' => {},
    'Gross Margin %' => { 'formula' => 'Sum([Master/Gross Profit]) / Sum([Master/Net Revenue])' }
  }
  raw = { 'Quantity Ordered' => 'QUANTITY' }
  entries.each_with_object({}) do |(name, extra), h|
    entry = mmap_entry(name, extra)
    [name, raw[name] || name.upcase.tr(' ', '_')].uniq.each do |alias_name|
      h["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of |(?:avg|sum|min|max|med|cnt|ctd)\\.\\s*)?#{Regexp.escape(alias_name)}$"] = entry
    end
  end
end

CSVS = {
  # Tableau exports the measure columns in ITS order (Margin % first), not the shelf order
  'Monthly Trend' => "Month of Order Date,Gross Margin %,Metric Value\nJanuary 2025,66.0%,\"1,900.00\"\nFebruary 2025,65.1%,\"2,100.50\"\n",
  'Top Products' => "Category,Product Name,Metric Value\nElectronics,Headphones,\"24,336.73\"\nHome,Air Purifier,\"15,330.25\"\n",
  'Top Cities' => "City,Store Type,Net Revenue\nAtlanta,Flagship,\"14,223.54\"\nAtlanta,Standard,\"13,288.47\"\nPortland,Standard,\"16,920.69\"\n",
  'Spanning Window' => "Category,Net Revenue\nHome,\"1,000.00\"\nSports,\"2,000.00\"\n"
}.freeze

def run_pipeline(twb_text, csvs: CSVS, mmap: build_mmap)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false } unless File.exist?(lay)
    views = csvs.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    csvs.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'FID', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(mmap))
    out = File.join(d, 'chart-specs.json')
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                              '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'),
                              '--master-element-id', 'master', '--auto-controls', '--page-per-dashboard',
                              '--skip-dashboard-read', 'offline test fixture', '--out', out)
    specs = File.exist?(out) ? JSON.parse(File.read(out)) : nil
    pages = specs.is_a?(Hash) ? specs['pages'] : []
    { ok: st.success?, log: log, specs: specs, pages: pages,
      elements: pages.flat_map { |p| p['elements'] || [] },
      data: (specs.is_a?(Hash) ? specs['data_elements'] : nil) || [],
      layout: JSON.parse(File.read(lay)) }
  end
end

def lint_spec(spec)
  Dir.mktmpdir do |d|
    f = File.join(d, 'spec.json')
    File.write(f, JSON.pretty_generate(spec))
    Open3.capture2e(RUBY, VALIDATE, '--type', 'workbook', f)
  end
end

FIX = File.read(FIXTURE, encoding: 'utf-8')
res = run_pipeline(FIX)
check(res[:ok], 'pipeline (parse + build, page-per-dashboard) exits 0', fails)
els = res[:elements] || []
el = ->(id) { els.find { |e| e['id'] == id } }
col = ->(e, id) { ((e || {})['columns'] || []).find { |c| c['id'] == id } }
zone = lambda do |caption|
  (res[:layout] || []).flat_map { |dash| dash['zones'] }.find { |z| z['kind'] == 'chart' && z['caption'] == caption }
end

# ── 1. dual-axis combo ──────────────────────────────────────────────────────
puts '1. unsynchronized dual-axis combo'
series = (zone.call('Monthly Trend') || {})['dual_axis_series']
check(series.is_a?(Array) && series.size == 2, 'parser (rb) emits dual_axis_series for the (A + B) shelf with a pane per measure', fails)
check(series && series[0]['guid'] == 'Calculation_2002' && series[0]['mark_class'] == 'Bar' && series[0]['axis'] == 'primary',
      'series[0] = the picker calc, Bar, primary (left) axis — shelf order, not CSV order', fails)
check(series && series[1]['guid'] == 'Calculation_2001' && series[1]['mark_class'] == 'Line' && series[1]['axis'] == 'secondary',
      'series[1] = Gross Margin %, Line, secondary (right) axis', fails)
check((zone.call('Top Products') || {})['dual_axis_series'].nil? && (zone.call('Top Cities') || {})['dual_axis_series'].nil?,
      'single-measure sheets carry no dual_axis_series', fails)

py_series = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  File.write(twb, FIX)
  lay = File.join(d, 'layout.json')
  _o, st = Open3.capture2e('python3', PARSER_PY, twb, lay)
  if st.success? && File.exist?(lay)
    py_zone = JSON.parse(File.read(lay)).flat_map { |dash| dash['zones'] }.find { |z| z['kind'] == 'chart' && z['caption'] == 'Monthly Trend' }
    py_series = py_zone && py_zone['dual_axis_series']
  end
end
check(py_series == series, 'the Python twin (parse-twb-layout.py) emits the identical dual_axis_series', fails)

combo = el.call('el-monthly-trend')
check(combo && combo['kind'] == 'combo-chart', 'Monthly Trend builds as a combo-chart', fails)
ycols = (combo || {})['columns'].to_a.select { |c| c['id'].to_s =~ /\Ay2?-el-monthly-trend\z/ }
check(ycols.size == 2, "both series are columns (got #{ycols.map { |c| c['name'] }.inspect})", fails)
y1 = col.call(combo, 'y-el-monthly-trend')
y2 = col.call(combo, 'y2-el-monthly-trend')
check(y1 && y1['formula'].to_s.start_with?('Sum(Switch([ctl-param-select-metric'), "primary series = the control-driven measure picker (got #{y1 && y1['formula']})", fails)
check(y2 && y2['name'] == 'Gross Margin %', "secondary series = Gross Margin % (got #{y2 && y2['name']})", fails)
yids = ((combo || {}).dig('yAxis', 'columnIds')) || []
check(yids == [{ 'columnId' => 'y-el-monthly-trend', 'type' => 'bar' }, { 'columnId' => 'y2-el-monthly-trend', 'type' => 'line' }],
      "yAxis.columnIds = [picker as bar, margin as line] (got #{yids.inspect})", fails)
check(((combo || {}).dig('yAxis2', 'columnIds')) == ['y2-el-monthly-trend'],
      "the unsynchronized line sits on yAxis2 (right axis) (got #{(combo || {})['yAxis2'].inspect})", fails)
check(res[:log].to_s.include?('right axis via yAxis2'), 'build names the dual-axis wiring in its warnings', fails)

# ── 2. top-N on a chart with a color dim ────────────────────────────────────
puts '2. top-N with a COLOR series -> unpartitioned dim-grain rank helper + Lookup keep filter'
prod = el.call('el-top-products')
check(prod && prod['color'].is_a?(Hash), 'Top Products keeps its color series (Category)', fails)
check(prod && prod['columns'].none? { |c| c['id'].to_s.start_with?('topnq-rank') },
      'no chart-level Rank() column (it partitions by the color series: top N per Category)', fails)
keep = col.call(prod, 'topnq-keep-el-top-products')
check(keep && keep['formula'] =~ /\AIf\(Max\(Lookup\(\[[^\]]*\/Rank\], \[Master\/Product Name\], \[[^\]]*\/Rank Key\]\)\) <= \[ctl-param-top-n-fidelity-board\], "keep", "cut"\)\z/,
      "keep column = If(Max(Lookup(rank, dim, key)) <= [top-N control]) (got #{keep && keep['formula']})", fails)
kflt = (prod || {})['filters'].to_a.find { |f| f['columnId'] == 'topnq-keep-el-top-products' }
check(kflt && kflt['kind'] == 'list' && kflt['values'] == ['keep'], 'chart filters on the keep flag', fails)
helper = (res[:data] || []).find { |d| d['id'] == 'el-top-products-topn-rank' }
check(helper && helper['kind'] == 'table' && helper.dig('source', 'elementId') == 'master',
      'a hidden table helper over the master is emitted', fails)
check(helper && helper['groupings'].size == 1 && helper['groupings'][0]['groupBy'] == ['el-top-products-topn-rank-d'],
      'helper groups at the DIM grain only (one row per product, no color key) — the rank is unpartitioned', fails)
hrank = col.call(helper, 'el-top-products-topn-rank-r')
check(hrank && hrank['formula'] == 'Rank([Rank Measure], "desc")', 'helper ranks desc over its measure', fails)
hmeas = col.call(helper, 'el-top-products-topn-rank-m')
check(hmeas && hmeas['formula'] =~ /\ASum\(Switch\(\[ctl-param-select-metric-fidelity-board\], 'Net Revenue', \[Master\/Net Revenue\], 'Gross Profit', \[Master\/Gross Profit\], 'Units', \[Master\/Quantity Ordered\]\)\)\z/,
      "helper measure = the picker Switch over [Master/...] columns AND the page-suffixed control id (got #{hmeas && hmeas['formula']})", fails)
check(helper && !helper.key?('_owner_element') && !helper.key?('_ctl_rewritten'), 'private helper bookkeeping keys never leak into the output', fails)
page_ctl_ids = els.select { |e| e['kind'] == 'control' }.map { |e| e['controlId'] }
check(page_ctl_ids.include?('ctl-param-select-metric-fidelity-board') && page_ctl_ids.include?('ctl-param-top-n-fidelity-board'),
      'the controls the helper + keep column read exist on the page', fails)
check(res[:log].to_s.include?('top-N (top-N from [ctl-param-top-n]'), 'build names the param-driven top-N bridge', fails)

cities = el.call('el-top-cities')
check(cities && cities['filters'].to_a.none? { |f| f['kind'] == 'top-n' },
      'literal Top N on a colored chart emits NO native top-n filter (it partitions by color: every (city,type) group is rank 1)', fails)
ckeep = col.call(cities, 'topnq-keep-el-top-cities')
check(ckeep && ckeep['formula'] =~ /<= 3, "keep", "cut"\)\z/ && ckeep['formula'].include?('Lookup(['),
      "literal N=3 keep flag via the Lookup bridge (got #{ckeep && ckeep['formula']})", fails)
chelper = (res[:data] || []).find { |d| d['id'] == 'el-top-cities-topn-rank' }
check(chelper && col.call(chelper, 'el-top-cities-topn-rank-m')['formula'] == 'Sum([Master/Net Revenue])' &&
      col.call(chelper, 'el-top-cities-topn-rank-d')['formula'] == '[Master/City]',
      'city helper ranks Sum(Net Revenue) per City', fails)

# a chart WITHOUT a color series keeps the native top-n filter / Rank() idiom (no helper)
no_color = FIX.sub(%r{\s*<encodings>\s*<color column='\[federated.fid0001\].\[none:5a1c0e7d-3f42-3b8e-9a10-0c2d4e6f8a01:nk\]' />\s*</encodings>}m, '')
nc = run_pipeline(no_color, csvs: CSVS.merge('Top Cities' => "City,Net Revenue\nAtlanta,\"27,512.01\"\nPortland,\"16,920.69\"\n"))
nc_city = (nc[:elements] || []).find { |e| e['id'] == 'el-top-cities' }
check(nc_city && nc_city['filters'].to_a.any? { |f| f['kind'] == 'top-n' && f['rowCount'] == 3 } &&
      (nc[:data] || []).none? { |d| d['id'] == 'el-top-cities-topn-rank' },
      'without a color series the native top-n filter is kept (no helper)', fails)

# per-page master cloning keeps a helper the page reaches only through a Lookup formula
pool_spec = lambda do
  mk = ->(id, name, src) { { 'id' => id, 'kind' => 'table', 'name' => name, 'source' => src, 'columns' => [] } }
  chart = lambda do |id, master_name, formula|
    { 'id' => id, 'kind' => 'bar-chart', 'name' => id, 'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [{ 'id' => 'k', 'name' => 'Keep', 'formula' => formula }] }
  end
  { 'pages' => [
    { 'id' => 'page-data', 'name' => 'Data', 'elements' => [
      mk.call('master', 'Master', { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e1' }),
      mk.call('rank-src', 'Rank Source', { 'kind' => 'table', 'elementId' => 'master' })
    ] },
    { 'id' => 'page-a', 'name' => 'Page A', 'elements' => [chart.call('chart-a', 'Master', 'Max(Lookup([Rank Source/Rank], [Master/X], [Rank Source/Key]))')] },
    { 'id' => 'page-b', 'name' => 'Page B', 'elements' => [chart.call('chart-b', 'Master', '[Master/X]')] }
  ] }
end
ps = pool_spec.call
PerPageMasters.split!(ps)
pool_ids = ps['pages'].first['elements'].map { |e| e['id'] }
check(pool_ids.include?('master-page-a') && pool_ids.include?('master-page-b'), 'per-page masters: each page still gets its own master clone', fails)
check(pool_ids.include?('rank-src-page-a') && !pool_ids.include?('rank-src-page-b'),
      "per-page masters: the Lookup-referenced helper is cloned for the page that reads it, not dropped (pool: #{pool_ids.inspect})", fails)
clone = ps['pages'].first['elements'].find { |e| e['id'] == 'rank-src-page-a' }
check(clone && clone.dig('source', 'elementId') == 'master-page-a', 'the helper clone rides that page\'s master clone', fails)

# lint: a Lookup() bridge to a workbook helper is allowed; a BARE cross-element ref still 500s
lint_spec_for = lambda do |formula|
  master = { 'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
             'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e1' },
             'columns' => [{ 'id' => 'mx', 'name' => 'X', 'formula' => '[Order Fact/X]' }] }
  helper = { 'id' => 'rank-src', 'kind' => 'table', 'name' => 'Rank Source', 'visibleAsSource' => false,
             'source' => { 'kind' => 'table', 'elementId' => 'master' },
             'columns' => [{ 'id' => 'hk', 'name' => 'Key', 'formula' => '[Master/X]' },
                           { 'id' => 'hr', 'name' => 'Rank', 'formula' => 'Rank(Sum([Master/X]), "desc")' }],
             'groupings' => [{ 'id' => 'hg', 'groupBy' => ['hk'], 'calculations' => ['hr'] }] }
  chart = { 'id' => 'c1', 'kind' => 'bar-chart', 'name' => 'C1', 'source' => { 'kind' => 'table', 'elementId' => 'master' },
            'columns' => [{ 'id' => 'x', 'name' => 'X', 'formula' => '[Master/X]' },
                          { 'id' => 'k', 'name' => 'Keep', 'formula' => formula }],
            'xAxis' => { 'columnId' => 'x' }, 'yAxis' => { 'columnIds' => ['k'] } }
  MechanicalSpecs.build_wb_spec(name: 'T', dm_id: 'dm', fact_eid: 'e1', master_columns: master['columns'],
                                chart_elements: [chart], data_elements: [helper])
end
out_ok, = lint_spec(lint_spec_for.call('Max(Lookup([Rank Source/Rank], [Master/X], [Rank Source/Key]))'))
check(out_ok !~ /NOT this element's source/, 'lint: a Lookup() bridge to a workbook helper is not a cross-source error', fails)
out_bad, = lint_spec(lint_spec_for.call('Max([Rank Source/Rank])'))
check(out_bad =~ /NOT this element's source/, 'lint: a BARE cross-element ref is still rejected (render-500 guard intact)', fails)

# ── 3. relative-date windows ────────────────────────────────────────────────
puts '3. relative-date windows that span the current period roll as mode:custom'
src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
m = src[/def relative_period_bounds.*?\[nil, :unsupported\]\nend/m]
abort 'could not extract the relative-date helpers' unless m
eval(m) # rubocop:disable Security/Eval -- trusted first-party source, test-only
NOW = Time.new(2026, 10, 27, 12, 0, 0)
rel = ->(op, unit, n) { { 'op' => op, 'unit' => unit, 'value' => n } }
{
  ['year', -2, 0]  => [:last, { 'mode' => 'last', 'value' => 3, 'unit' => 'year', 'includeToday' => true }],
  ['year', 0, 0]   => [:current, { 'mode' => 'current', 'unit' => 'year' }],
  ['year', -2, -1] => [:last, { 'mode' => 'last', 'value' => 2, 'unit' => 'year', 'includeToday' => false }],
  ['year', 0, 2]   => [:next, { 'mode' => 'next', 'value' => 3, 'unit' => 'year', 'includeToday' => true }],
  ['year', -2, 1]  => [:custom, { 'mode' => 'custom', 'startDate' => rel.call('now-minus', 'year', 2), 'endDate' => rel.call('now-plus', 'year', 1) }],
  ['year', -1, 3]  => [:custom, { 'mode' => 'custom', 'startDate' => rel.call('now-minus', 'year', 1), 'endDate' => rel.call('now-plus', 'year', 3) }],
  ['quarter', -3, -1] => [:last, { 'mode' => 'last', 'value' => 3, 'unit' => 'quarter', 'includeToday' => false }],
  ['quarter', -1, 1]  => [:custom, { 'mode' => 'custom', 'startDate' => rel.call('now-minus', 'quarter', 1), 'endDate' => rel.call('now-plus', 'quarter', 1) }],
  ['month', -8, -3]   => [:custom, { 'mode' => 'custom', 'startDate' => rel.call('now-minus', 'month', 8), 'endDate' => rel.call('now-minus', 'month', 3) }],
  ['month', 2, 5]     => [:custom, { 'mode' => 'custom', 'startDate' => rel.call('now-plus', 'month', 2), 'endDate' => rel.call('now-plus', 'month', 5) }],
  ['week', -6, -3]    => [:custom, { 'mode' => 'custom', 'startDate' => rel.call('now-minus', 'week-starting-sunday', 6), 'endDate' => rel.call('now-minus', 'week-starting-sunday', 3) }]
}.each do |(period, first, last), (want_kind, want)|
  f, k = relative_date_filter_fields(period, first, last, NOW)
  check(k == want_kind && f == want, "#{period} #{first}..#{last} → #{want_kind} #{want['mode']} (got #{k} #{f.inspect})", fails)
end
f, k = relative_date_filter_fields('weekday', -8, -3, NOW)
check(k == :unsupported && f.nil?, 'a grain with no Sigma unit and no frozen bounds stays unsupported (dropped, named)', fails)
all_modes = [['year', -2, 1], ['month', -8, -3], ['quarter', -1, 1]].map { |a| relative_date_filter_fields(*a, NOW).first }
check(all_modes.none? { |x| x['mode'] == 'between' }, 'spanning windows never freeze to build-time mode:between dates', fails)

span = el.call('el-spanning-window')
sflt = (span || {})['filters'].to_a.find { |f| f['kind'] == 'date-range' }
check(sflt && sflt['mode'] == 'custom' && sflt['startDate'] == rel.call('now-minus', 'year', 2) && sflt['endDate'] == rel.call('now-plus', 'year', 1),
      "the fixture's years -2..+1 filter emits rolling mode:custom (got #{sflt.inspect})", fails)

puts
puts '5. a colored top-N worksheet shown on two dashboards keeps the bridge on both copies'
# The second dashboard builds the worksheet again with the same element id. It must reuse
# the registered rank helper, not fall back to the native top-n / Rank() filter that Sigma
# partitions by the color series.
dash2 = FIX[%r{    <dashboard name='Fidelity Board'>.*?</dashboard>\n}m]
twice2 = FIX.sub(dash2, dash2 + dash2.sub("name='Fidelity Board'", "name='Fidelity Board Copy'"))
r2 = run_pipeline(twice2)
check(r2[:ok] && r2[:pages].size == 2, "two dashboards build (got #{r2[:pages] && r2[:pages].size} pages)", fails)
ids2 = (r2[:data] || []).map { |d| d['id'] }
check(ids2.size == ids2.uniq.size, "hidden helper ids are unique (got #{ids2.inspect})", fails)
prods = (r2[:elements] || []).select { |e| e['id'].to_s.start_with?('el-top-products') && e['kind'] != 'control' }
check(prods.size == 2 && prods.all? { |e| Array(e['filters']).any? { |f| f['values'] == ['keep'] } && e['columns'].none? { |c| c['id'].to_s.start_with?('topnq-rank') } },
      "both Top Products copies filter on the Lookup keep flag (got #{prods.map { |e| [e['id'], Array(e['filters']).map { |f| f['kind'] }] }.inspect})", fails)

r2_pages = r2[:pages] || []
r2_helper_by_name = (r2[:data] || []).to_h { |d| [d['name'], d] }
check(r2_pages.size == 2 && r2_pages.all? do |pg|
        chart = pg['elements'].find { |e| e['id'].to_s.start_with?('el-top-products') && e['kind'] != 'control' }
        keep = chart && chart['columns'].find { |c| c['id'].to_s.start_with?('topnq-keep') }
        hname = keep && keep['formula'][%r{Lookup\(\[([^\[\]/]+)/}, 1]
        h = r2_helper_by_name[hname]
        picker = pg['elements'].find { |e| e['kind'] == 'control' && e['controlId'].to_s.start_with?('ctl-param-select-metric') }
        h && picker && h.to_json.include?("[#{picker['controlId']}]")
      end, "each page's rank helper reads that page's own metric picker", fails)

puts
if fails.empty?
  puts 'ALL PASS — dual-axis combo, color-partition-safe top-N, and rolling spanning date windows'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
