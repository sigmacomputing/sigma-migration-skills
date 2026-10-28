#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for three chart-fidelity gaps a live Tableau-vs-Sigma comparison of a star-schema
# promotion workbook found. Driven end to end (offline) through the real parse-twb-layout.rb +
# build-charts-from-signals.rb (--page-per-dashboard, as migrate-tableau runs it) on
# scripts/fixtures/fidelity-s3.twb (synthetic, invented names):
#
#   1. "Margin vs Threshold" - Color = an aggregate boolean calc (SUM(a)/SUM(b) >= [Parameters].[P]).
#      Sigma evaluates a color column per SOURCE ROW, so the element-level flag split every bar into
#      true/false/null pieces. The measure and the flag are now group calculations of a hidden helper
#      grouped by the plotted dimension; the chart plots its rows raw. The page's Category quick filter
#      still reaches the chart (it filters the helper before it groups), and the flag reads the
#      parameter control under the control's per-page id.
#   2. "Promo Lift" - y = AVG(x) / MAX({FIXED : AGG(y)}) - 1. A chart-level GrandTotal(...) is
#      evaluated AFTER the chart's own filters (the Promo Type list filter drops the very rows the
#      baseline averages -> empty chart), but a FIXED LOD ignores them. The scalar now lives on a hidden
#      helper element and is read with Lookup on a constant key.
#   3. "Promo Avg Revenue" - Measure Names on Rows next to the dimension, Measure Values on Columns:
#      horizontal bars with the measures side by side. The multi-measure builder dropped the orientation
#      and Sigma stacks several yAxis measures by default.
#
# Usage:  ruby scripts/test-fidelity-s3.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/ruby_compat'
require_relative 'lib/chart_calc_translate'
require_relative 'mechanical-specs'

DIR     = __dir__
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
VALIDATE = File.join(DIR, 'validate-spec.rb')
FIXTURE = File.join(DIR, 'fixtures', 'fidelity-s3.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

PROMO_DIM = { 'element' => 'Promo Dim', 'relationship' => 'PROMO_DIM', 'key' => 'Promo Key' }.freeze

def base_mmap(promo_grain: true)
  {
    'Category' => {}, 'Subcategory' => {}, 'Net Revenue' => {}, 'Gross Profit' => {},
    'Promo Type' => (promo_grain ? { 'grain' => PROMO_DIM } : {})
  }.each_with_object({}) do |(name, extra), h|
    entry = { 'id' => "m-#{name.downcase.gsub(/\W+/, '-')}", 'name' => name }.merge(extra)
    [name, name.upcase.tr(' ', '_')].each do |alias_name|
      h["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of |(?:avg|sum|min|max|med|cnt|ctd)\\.\\s*)?#{Regexp.escape(alias_name)}$"] = entry
    end
  end
end

CSVS = {
  'Margin vs Threshold' => "Subcategory,Gross Margin %,Margin Above Threshold\nTops,71.1%,True\nFootwear,60.5%,False\n",
  'Promo Lift' => "Promo Type,Promo Lift %\nPercentage Off,0.9%\nBOGO,-48.3%\n",
  'Promo Avg Revenue' => "Measure Names,Promo Type,Measure Values\nAvg Revenue No Promo,BOGO,149.76\n" \
                         "Avg Revenue on Promo,BOGO,77.39\nAvg Revenue No Promo,Percentage Off,149.76\n" \
                         "Avg Revenue on Promo,Percentage Off,151.13\n"
}.freeze

# One parse + one build over a (possibly edited) fixture. layout_edit: ->(layout_json_array) edits the
# parsed dashboard-layout.json before the build.
def run_pipeline(twb_text = File.read(FIXTURE, encoding: 'utf-8'), mmap: base_mmap, layout_edit: nil, csvs: CSVS)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    o, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: o } unless File.exist?(lay)
    doc = JSON.parse(File.read(lay))
    layout_edit&.call(doc)
    File.write(lay, JSON.pretty_generate(doc))
    views = csvs.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    csvs.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'FS3', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(mmap))
    out = File.join(d, 'chart-specs.json')
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                              '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'),
                              '--master-element-id', 'master', '--auto-controls', '--page-per-dashboard',
                              '--skip-dashboard-read', 'offline test fixture', '--out', out)
    specs = File.exist?(out) ? JSON.parse(File.read(out)) : nil
    flat = specs.is_a?(Hash) ? specs['pages'].flat_map { |p| p['elements'] } : (specs || [])
    { ok: st.success?, log: log, specs: specs, elements: flat,
      data: (specs.is_a?(Hash) ? specs['data_elements'] : nil) || [] }
  end
end

# validate-spec's workbook lint over the built elements (the same lint the pre-POST step runs).
def lint_elements(elements, data = [])
  Dir.mktmpdir do |d|
    spec = MechanicalSpecs.build_wb_spec(name: 'T', dm_id: 'dm', fact_eid: 'e1', master_columns: [],
                                         chart_elements: elements, data_elements: data)
    f = File.join(d, 'spec.json')
    File.write(f, JSON.pretty_generate(spec))
    Open3.capture2e(RUBY, VALIDATE, '--type', 'workbook', f)
  end
end

run = run_pipeline
els = run[:elements]
el = ->(id) { els.find { |e| e['id'] == id } }
data = run[:data]
data_el = ->(id) { data.find { |e| e['id'] == id } }
col = ->(e, id) { ((e || {})['columns'] || []).find { |c| c['id'] == id } }
cols_f = ->(e) { ((e || {})['columns'] || []).map { |c| c['formula'].to_s } }

puts 'Part 0 - the pipeline builds the fixture'
check(run[:ok], "build-charts exits 0 (got: #{run[:log].to_s.lines.grep(/Error/).first(2).inspect})", fails)
check(%w[el-margin-vs-threshold el-promo-lift el-promo-avg-revenue].all? { |id| el.call(id) },
      "all three tiles are built (got #{els.map { |e| e['id'] }.inspect})", fails)

puts
puts 'Part 1 - aggregate-calc color is computed per dimension in a grouped helper'
mt = el.call('el-margin-vs-threshold')
helper = data_el.call('el-margin-vs-threshold-flag-src')
check(helper && helper['kind'] == 'table' && helper.dig('source', 'elementId') == 'master',
      "a hidden helper over the master exists (got #{helper && helper['id'].inspect})", fails)
check(mt && mt.dig('source', 'elementId') == 'el-margin-vs-threshold-flag-src',
      "the chart is sourced from the helper (got #{mt && mt['source'].inspect})", fails)
hg = helper && helper['groupings'].to_a.first
hcol = ->(id) { col.call(helper, id) }
check(hg && hg['groupBy'].size == 1 && hcol.call(hg['groupBy'][0])['formula'] == '[Master/Subcategory]',
      "the helper groups by the plotted dimension (got #{hg && hg['groupBy'].inspect})", fails)
flag = hg && hg['calculations'].map { |id| hcol.call(id) }.find { |c| c['name'] == 'Margin Above Threshold' }
check(flag && flag['formula'] =~ %r{\AText\(Sum\(\[Master/Gross Profit\]\) / Sum\(\[Master/Net Revenue\]\) >= \[ctl-param-margin-threshold[^\]]*\]\)\z},
      "the flag is a GROUP calculation comparing the aggregate ratio with the control (got #{flag && flag['formula'].inspect})", fails)
check(hg && hg['calculations'].map { |id| hcol.call(id) }.any? { |c| c['name'] == 'Gross Margin %' && c['formula'] == 'Sum([Master/Gross Profit]) / Sum([Master/Net Revenue])' },
      'the per-group margin is a group calculation over the master columns', fails)
ccol = col.call(mt, mt && mt.dig('color', 'column'))
check(ccol && ccol['formula'] == '[Margin vs Threshold Color Source/Margin Above Threshold]',
      "the chart colors by the helper's flag column raw - no per-row comparison (got #{ccol && ccol['formula'].inspect})", fails)
check(cols_f.call(mt).none? { |f| f.include?('Master/Gross Profit') || f.include?('>=') },
      'no chart column evaluates the ratio or the comparison per source row', fails)
check(mt && col.call(mt, mt.dig('yAxis', 'columnIds', 0))['formula'] == 'Max([Margin vs Threshold Color Source/Gross Margin %])' &&
      col.call(mt, mt.dig('xAxis', 'columnId'))['formula'] == '[Margin vs Threshold Color Source/Subcategory]',
      'axes read the helper (one row per Subcategory)', fails)
# Tableau hands the default palette out in member order (False = 1st colour, True = 2nd).
check(mt && mt.dig('color', 'scheme') == %w[#4e79a7 #f28e2b],
      "False takes the first palette colour, True the second (got #{mt && mt.dig('color', 'scheme').inspect})", fails)
ctl = els.find { |e| e['kind'] == 'control' && e['controlId'].to_s.start_with?('ctl-param-margin-threshold') }
check(ctl && flag && flag['formula'].include?("[#{ctl['controlId']}]"),
      "the parameter control is emitted and the helper reads it under the control's page id (control #{ctl && ctl['controlId'].inspect})", fails)
cat = els.find { |e| e['kind'] == 'control' && e['controlId'].to_s.start_with?('ctl-category') }
tgt = cat && Array(cat['filters']).find { |t| t.dig('source', 'elementId') == 'el-margin-vs-threshold-flag-src' }
fcol = tgt && col.call(helper, tgt['columnId'])
check(tgt && fcol && fcol['formula'] == '[Master/Category]',
      "the Category quick filter targets the helper's own Category column (got #{cat && cat['filters'].inspect})", fails)
check(cat && Array(cat['filters']).none? { |t| t.dig('source', 'elementId') == 'el-promo-lift' },
      'the quick filter stays scoped to its selected worksheet (no Promo Lift target)', fails)
check(run[:log].lines.any? { |l| l.include?("'Margin vs Threshold'") && l.include?('computed per Subcategory in hidden grouped helper') },
      'the helper is disclosed in the build log', fails)
lint_out, lint_st = lint_elements([mt].compact, [helper].compact)
check(lint_st.success?, "validate-spec accepts the helper-sourced chart (#{lint_out.lines.grep(/ERROR/).first(2).inspect})", fails)

puts
puts 'Part 2 - a no-dimension FIXED LOD scalar survives the chart\'s own filters'
pl = el.call('el-promo-lift')
plf = col.call(pl, 'y-el-promo-lift')
LOOKUP = 'Max(Lookup([Fixed Scalar 1/Value], 1, [Fixed Scalar 1/Key]))'
check(plf && plf['formula'] == "Avg([Master/Net Revenue]) / #{LOOKUP} - 1",
      "Promo Lift reads the baseline through Lookup on a constant key (got #{plf && plf['formula'].inspect})", fails)
check(!JSON.generate(els).include?('GrandTotal('), 'no chart formula carries a filter-bound GrandTotal(...)', fails)
check(Array(pl && pl['filters']).any? { |f| f['kind'] == 'list' && Array(f['values']) == ['BOGO', 'Percentage Off'] },
      "the worksheet's Promo Type filter is still on the chart (it is what emptied the GrandTotal)", fails)
sc = data_el.call('fixed-scalar-1')
check(sc && sc['kind'] == 'table' && sc.dig('source', 'elementId') == 'master' && sc['visibleAsSource'] == false,
      "the scalar lives on a hidden table over the master (got #{sc && sc.reject { |k, _| k == 'columns' }.inspect})", fails)
sg = sc && sc['groupings'].to_a.first
kcol = sc && col.call(sc, sg && sg['groupBy'][0])
vcol = sc && col.call(sc, sg && sg['calculations'][0])
check(kcol && kcol['formula'] == '1' && vcol && vcol['name'] == 'Value' && vcol['formula'].start_with?('Avg(If(') &&
        vcol['formula'].include?('[Master/Promo Type]') && !vcol['formula'].include?('GrandTotal'),
      "constant key + one aggregate calculation (got #{vcol && vcol['formula'].inspect})", fails)
nnf = sc && Array(sc['filters']).first
nncol = nnf && col.call(sc, nnf['columnId'])
check(nncol && nncol['formula'] == 'Text(IsNotNull([Master/Promo Type]))' && nnf['values'] == ['true'],
      "unmatched dim-table rows are excluded like Tableau's relationship join (got #{sc && sc['filters'].inspect})", fails)
check(data.count { |e| e['id'].to_s.start_with?('fixed-scalar') } == 1,
      'the scalar used by two tiles is ONE helper element', fails)
check(run[:log].lines.any? { |l| l.include?("'Promo Lift'") && l.include?('no-dimension FIXED LOD scalar') && l.include?('Fixed Scalar 1') },
      'the re-route is disclosed in the build log', fails)
# The render-500 lint (a formula may not read a workbook element that is not its source) must let the
# Lookup read through - built by hand so this check does not ride on the builder.
syn_helper = { 'id' => 'fixed-scalar-1', 'kind' => 'table', 'name' => 'Fixed Scalar 1',
               'source' => { 'kind' => 'table', 'elementId' => 'master' },
               'columns' => [{ 'id' => 'k', 'name' => 'Key', 'formula' => '1' },
                             { 'id' => 'v', 'name' => 'Value', 'formula' => 'Avg([Master/Net Revenue])' }],
               'groupings' => [{ 'id' => 'g', 'groupBy' => ['k'], 'calculations' => ['v'] }], 'visibleAsSource' => false }
syn_chart = { 'id' => 'el-syn', 'kind' => 'bar-chart', 'name' => 'Syn', 'source' => { 'kind' => 'table', 'elementId' => 'master' },
              'columns' => [{ 'id' => 'x', 'name' => 'Promo Type', 'formula' => '[Master/Promo Type]' },
                            { 'id' => 'y', 'name' => 'Lift', 'formula' => "Avg([Master/Net Revenue]) / #{LOOKUP} - 1" }],
              'xAxis' => { 'columnId' => 'x' }, 'yAxis' => { 'columnIds' => ['y'] } }
lint_out, lint_st = lint_elements([syn_chart], [syn_helper])
check(lint_st.success?, "validate-spec accepts a Lookup read of the helper (#{lint_out.lines.grep(/ERROR/).first(2).inspect})", fails)
plain = JSON.parse(JSON.generate(syn_chart))
plain['columns'].find { |c| c['id'] == 'y' }['formula'] = 'Avg([Master/Net Revenue]) / Max([Fixed Scalar 1/Value])'
_o, plain_st = lint_elements([plain], [syn_helper])
check(!plain_st.success? && _o.include?('NOT this element\'s source'),
      'a PLAIN cross-element ref is still rejected by the render-500 guard (only Lookup is sanctioned)', fails)
# without the dim-table annotation the helper has nothing to exclude
no_grain = run_pipeline(mmap: base_mmap(promo_grain: false))
ngs = no_grain[:data].find { |e| e['id'] == 'fixed-scalar-1' }
check(ngs && ngs['filters'].nil?, 'a scalar over no dim-table column adds no keep-filter to its helper', fails)
cbg = {
  'Calculation_3001' => { 'caption' => 'Promo Flag', 'formula' => "IF [PROMO_TYPE] = 'None' THEN 'No Promo' ELSE 'Promo' END" },
  'Calculation_3002' => { 'caption' => 'Baseline', 'formula' => "{FIXED : AVG(IF [Calculation_3001] = 'No Promo' THEN [NET_REVENUE] END)}" },
  'PROMO_TYPE' => { 'caption' => 'Promo Type' }, 'NET_REVENUE' => { 'caption' => 'Net Revenue' }
}
check(translate_user_agg_formula('AVG([NET_REVENUE]) / MAX([Calculation_3002])', base_mmap, cbg)
        .to_s.include?('GrandTotal(Avg(If('),
      'unit: the pure translator still yields GrandTotal (KPIs / pivots keep it); only charts re-route', fails)

puts
puts 'Part 3 - Measure Names on a shelf: horizontal bars, measures side by side'
pa = el.call('el-promo-avg-revenue')
check(pa && pa['kind'] == 'bar-chart' && pa.dig('yAxis', 'columnIds').to_a.size == 2,
      "two measures on the yAxis (got #{pa && pa.dig('yAxis', 'columnIds').inspect})", fails)
check(pa && pa['orientation'] == 'horizontal',
      "Measure Values on Columns + the dimension on Rows is a horizontal bar (got #{pa && pa['orientation'].inspect})", fails)
check(pa && pa['stacking'] == 'none',
      "Measure Names on Rows draws the measures side by side, not stacked (got stacking=#{pa && pa['stacking'].inspect})", fails)
no_lookup_col = col.call(pa, 'y0-el-promo-avg-revenue')
check(no_lookup_col && no_lookup_col['formula'] == LOOKUP,
      "the No Promo measure is the same scalar helper read (got #{no_lookup_col && no_lookup_col['formula'].inspect})", fails)
check(run[:log].lines.any? { |l| l.include?("'Promo Avg Revenue'") && l.include?('drawn side by side') },
      'the clustered/horizontal emission is disclosed', fails)
# The worksheet's own Promo Type include filter and the null-dimension exclusion ride the multi-measure
# path too (same list_filter_for / null_exclusion_for as the single-measure path) — else the chart plots
# the None and blank promo groups Tableau filtered out.
pa_filters = Array(pa && pa['filters'])
lf = pa_filters.find { |f| f['columnId'] == 'x-el-promo-avg-revenue' }
check(lf && lf['kind'] == 'list' && lf['mode'] == 'include' && lf['values'] == ['BOGO', 'Percentage Off'] && lf['includeNulls'] == 'never',
      "the Promo Type member include is carried on the dimension column (got #{pa_filters.inspect})", fails)
nnc = col.call(pa, 'nn-x-el-promo-avg-revenue')
nnf = pa_filters.find { |f| f['columnId'] == 'nn-x-el-promo-avg-revenue' }
check(nnc && nnc['formula'] == 'Text(IsNotNull([Master/Promo Type]))' && nnf && nnf['values'] == ['true'],
      "the null-dimension exclusion is carried (got #{nnc && nnc['formula'].inspect})", fails)
check(pa_filters.map { |f| f['id'] }.uniq.size == pa_filters.size && pa_filters.all? { |f| f['id'].to_s.start_with?('flt-el-promo-avg-revenue-') },
      'every carried filter has a unique id', fails)
check(pa && pa.dig('yAxis', 'columnIds').to_a.none? { |id| id.start_with?('nn-') } && !pa['columns'].any? { |c| c['name'] == 'Measure Names' },
      'the filter helper column stays off the measure axis', fails)
# A view CSV that DOES show a null bucket keeps it (no null exclusion), as on the single-measure path.
with_null = run_pipeline(csvs: CSVS.merge('Promo Avg Revenue' => CSVS['Promo Avg Revenue'] + "Avg Revenue on Promo,,12.0\n"))
wn = with_null[:elements].find { |e| e['id'] == 'el-promo-avg-revenue' }
check(wn && wn['filters'].to_a.size == 1 && wn['filters'][0]['columnId'] == 'x-el-promo-avg-revenue',
      'a null bucket in the view CSV keeps nulls: only the member include remains', fails)
# Measure Names only on COLOR (no shelf split) keeps Tableau's stacking: no stacking override.
on_color = run_pipeline(layout_edit: lambda do |lay|
  lay.each do |dash|
    dash['zones'].each do |z|
      next unless z['caption'] == 'Promo Avg Revenue' && z['kind'] == 'chart'
      z['rows_shelf']['fields'].reject! { |f| f['role'] == 'measure-names' }
      z['rows_shelf']['has_measure_names'] = false
    end
  end
end)
pc = on_color[:elements].find { |e| e['id'] == 'el-promo-avg-revenue' }
check(pc && pc['orientation'] == 'horizontal' && !pc.key?('stacking'),
      "Measure Names only on Color keeps the default stacking (got #{pc && pc.values_at('orientation', 'stacking').inspect})", fails)

puts
puts 'Part 4 - the opt-in per-page master split keeps a Lookup-read scalar helper'
require_relative 'lib/per_page_masters'
pm_spec = { 'schemaVersion' => 1, 'pages' => [
  { 'id' => 'page-data', 'name' => 'Data', 'elements' => [
    { 'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
      'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'fact' },
      'columns' => [{ 'id' => 'm-pt', 'name' => 'Promo Type', 'formula' => '[Fact/Promo Type]' },
                    { 'id' => 'm-nr', 'name' => 'Net Revenue', 'formula' => '[Fact/Net Revenue]' }] },
    syn_helper
  ] },
  *%w[one two].map do |n|
    { 'id' => "dash-#{n}", 'name' => "Dash #{n}", 'elements' => [
      syn_chart.merge('id' => "chart-#{n}", 'columns' => syn_chart['columns'].map { |c| c.dup })
    ] }
  end
] }
PerPageMasters.split!(pm_spec)
pool = pm_spec['pages'][0]['elements']
pm_ok = %w[one two].all? do |n|
  pg = pm_spec['pages'].find { |p| p['name'] == "Dash #{n}" }
  clone = pool.find { |e| e['id'].to_s.start_with?('fixed-scalar-1-') && e['name'].to_s.end_with?("(dash-#{n})") }
  f = pg['elements'][0]['columns'].last['formula']
  clone && clone.dig('source', 'elementId') == "master-dash-#{n}" &&
    f.include?("[#{clone['name']}/Value]") && f.include?("[#{clone['name']}/Key]") &&
    pool.any? { |e| e['id'] == "master-dash-#{n}" }
end
check(pm_ok, 'each page gets its own scalar helper clone (own name, sourced from its own master) and its Lookup follows', fails)
check(pool.none? { |e| e['id'] == 'fixed-scalar-1' } && pool.none? { |e| e['id'] == 'master' },
      'no shared original is left behind for a page to dangle on', fails)

puts
puts 'Part 9 - a worksheet shown on two dashboards: each page has its own flag helper and slider'
# Each dashboard builds the worksheet again with the same element id. Helper ids must stay
# unique (two data elements with one id fail the POST), and because the flag reads the
# threshold parameter, each page's chart must read a helper bound to THAT page's slider:
# a shared helper would follow the first page's control and drop the second page's slider.
fix_text = File.read(FIXTURE, encoding: 'utf-8')
dash = fix_text[%r{    <dashboard name='Fidelity S3'>.*?</dashboard>\n}m]
# The copy's name carries '/' and ']' — the helper clone's name must not split [name/column].
twice = fix_text.sub(dash, dash + dash.sub("name='Fidelity S3'", "name='Fidelity S3 / Copy [B]'"))
rt = run_pipeline(twice)
rt_pages = rt[:specs].is_a?(Hash) ? rt[:specs]['pages'] : []
check(rt[:ok] && rt_pages.size == 2, "two dashboards build (got #{rt_pages.size} pages)", fails)
ids = (rt[:data] || []).map { |d| d['id'] }
check(ids.size == ids.uniq.size, "hidden helper ids are unique (got #{ids.inspect})", fails)
rt_helper = ->(id) { (rt[:data] || []).find { |d| d['id'] == id } }
rt_pages.each_with_index do |pg, i|
  chart = (pg['elements'] || []).find { |e| e['id'].to_s.start_with?('el-margin-vs-threshold') }
  slider = (pg['elements'] || []).find { |e| e['controlType'] == 'slider' }
  h = chart && rt_helper.call(chart.dig('source', 'elementId'))
  flag = h && Array(h['columns']).map { |c| c['formula'].to_s }.find { |f| f.include?('[ctl-') }
  check(slider && h && flag.to_s.include?("[#{slider['controlId']}]"),
        "page #{i + 1}: the chart's flag helper reads this page's own slider " \
        "(slider=#{slider && slider['controlId'].inspect}, helper=#{h && h['id'].inspect}, flag=#{flag.inspect})", fails)
  names = Array(chart && chart['columns']).flat_map { |c| c['formula'].to_s.scan(%r{\[([^\[\]/]+)/}).flatten }.uniq - ['Master']
  check(h && names.all? { |n| n == h['name'] },
        "page #{i + 1}: the chart's formulas name its own helper (got #{names.inspect} vs #{h && h['name'].inspect})", fails)
end
helper_ids = (rt[:data] || []).map { |d| d['id'] }
check(rt_pages.each_with_index.all? do |pg, i|
        own = pg['elements'].find { |e| e['id'].to_s.start_with?('el-margin-vs-threshold') }.dig('source', 'elementId')
        pg['elements'].select { |e| e['kind'] == 'control' }.flat_map { |c| Array(c['filters']) }
                      .map { |t| t.dig('source', 'elementId') }.all? { |tid| !helper_ids.include?(tid) || tid == own }
      end, 'no page\'s control filters another page\'s helper', fails)

puts
if fails.empty?
  puts 'OK  all fidelity-s3 checks passed'
else
  puts "FAIL  #{fails.size} check(s):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
