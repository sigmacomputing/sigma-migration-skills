#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for six converter gaps real star-schema stress migrations hit (each one
# blocked the Sigma workbook from being built or posted). Driven end to end (offline) through
# the real parse-twb-layout.rb + build-charts-from-signals.rb on scripts/fixtures/stress-gaps.twb
# (synthetic, invented names), plus unit-level checks of derive_master and the calc translators:
#
#   1. Scatter: the two plotted measures come from the SHELVES, never from CSV column position
#      (a CSV led by a repeated dim made both axes resolve to the same dim and the builder
#      raised NoMethodError, killing every tile). Dimension-table measures resolve through the
#      master-map 'grain' annotation (native-grain helper when nothing fact-side rides along);
#      an unresolvable pair degrades THAT tile with a named warning; and one tile's unexpected
#      exception no longer takes the whole build down (per-zone isolation).
#   2. Calc-on-calc: a calc that references another calc resolves to the referenced calc's
#      translation (a no-dimension FIXED LOD -> GrandTotal(...)), never a dangling
#      [Master/Calculation_<id>]; an unresolvable one refuses (nil) / drops the tile loudly.
#   3. A parameter-driven AGGREGATE calc on Color becomes an element-level categorical color
#      column over the parameter's workbook control — not a master column. (Also: a measure
#      column the view CSV formats as "77.5%" is a measure, not a second dimension.)
#   4. Same-named columns of different tables ("Region (STORE_DIM (SALESDB.STORE_DIM))") each map
#      to their OWN table's master column; both copies exist under distinct names.
#   5. A filled map binds its geographic dimension (region-map keyed on the geo role) and never
#      references Tableau's generated Latitude/Longitude.
#   6. A crosstab with dimensions on Columns only gets one constant row, so it passes the
#      spec lint instead of rendering only a (hidden) grand-total row.
#
# Usage:  ruby scripts/test-stress-gaps.rb
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
FIXTURE = File.join(DIR, 'fixtures', 'stress-gaps.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

CUST = { 'element' => 'Customer Dim', 'relationship' => 'CUSTOMER_DIM', 'key' => 'Customer Key' }.freeze

def base_mmap
  {
    'Order Date' => {}, 'Order Channel' => {}, 'Promo Type' => {}, 'Customer Segment' => {},
    'Net Revenue' => {}, 'Gross Profit' => {}, 'State' => {},
    'Customer Id' => { 'grain' => CUST }, 'Lifetime Orders' => { 'grain' => CUST },
    'Lifetime Revenue' => { 'grain' => CUST }
  }.each_with_object({}) do |(name, extra), h|
    entry = { 'id' => "m-#{name.downcase.gsub(/\W+/, '-')}", 'name' => name }.merge(extra)
    # the caption AND the raw warehouse name the fixture's formulas use ([NET_REVENUE])
    [name, name.upcase.tr(' ', '_')].each do |alias_name|
      h["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of |(?:avg|sum|min|max|med|cnt|ctd)\\.\\s*)?#{Regexp.escape(alias_name)}$"] = entry
    end
  end
end

SCATTER_CSV = <<~CSV
  Customer Id,Customer Segment,Customer Segment,Avg. Lifetime Orders,Avg. Lifetime Revenue,Net Revenue
  C-001,Consumer,Consumer,2,165.5,"5,179.44"
  C-002,Corporate,Corporate,5,420.25,"9,902.10"
CSV
CSVS = {
  'Customer Scatter' => SCATTER_CSV,
  'Promo Lift' => "Order Channel,Promo Lift %\nOnline,12.5%\nStore,8.1%\n",
  # an un-captioned calc exports under its internal name
  'Tenure Bar' => "Calculation_1007,Net Revenue\n10,\"1,200.00\"\n20,\"2,300.00\"\n",
  'Margin vs Threshold' => "Order Channel,Gross Margin %,Margin Above Threshold\nOnline,77.5%,True\nStore,52.0%,False\n",
  'Revenue Map' => "State,Latitude (generated),Longitude (generated),Gross Profit,Net Revenue\nCA,37.25,-119.75,\"10,318.94\",\"15,405.07\"\nCO,39,-105.5,\"9,006.27\",\"13,586.95\"\n",
  'YoY Growth' => "Year of Order Date,YoY Growth %\n2024,\n2025,12.0%\n"
}.freeze

# One parse + one build over a (possibly edited) fixture. layout_edit: ->(layout_json_array) edits the
# parsed dashboard-layout.json before the build (to inject a failure the fixture cannot express).
def run_pipeline(twb_text, csvs: CSVS, mmap: base_mmap, layout_edit: nil)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    _o, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: _o } unless File.exist?(lay)
    doc = JSON.parse(File.read(lay))
    # The verified source-image kind (Phase 1d png-read.json) overrides the shelf-inferred 'table' for the
    # years-across crosstab — applied here the way the builder applies it (z['chart_kind'] = verified kind).
    doc.each { |dash| dash['zones'].each { |z| z['chart_kind'] = 'pivot-table' if z['caption'] == 'YoY Growth' && z['kind'] == 'chart' } }
    layout_edit&.call(doc)
    File.write(lay, JSON.pretty_generate(doc))
    views = csvs.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    csvs.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'SG', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(mmap))
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
      coverage: rd.call('coverage.json'), layout: rd.call('dashboard-layout.json'),
      meta: rd.call('dashboard-layout-meta.json') }
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

FIXTURE_TEXT = File.read(FIXTURE, encoding: 'utf-8')
# Parts 2-6 each exercise their own gap; the scatter (Part 1) used to RAISE and take every other tile
# down with it, so they run over the fixture without it — each part fails on its own bug, not on that one.
NO_SCATTER = FIXTURE_TEXT
             .sub(%r{    <worksheet name='Customer Scatter'>.*?</worksheet>\n}m, '')
             .sub(%r{\s*<zone h='33000' id='21' name='Customer Scatter'[^>]*/>}, '')
flat1 = run_pipeline(FIXTURE_TEXT, csvs: CSVS)
flat = run_pipeline(NO_SCATTER, csvs: CSVS.reject { |k, _| k == 'Customer Scatter' })
els = flat[:elements] || []
el = ->(id) { els.find { |e| e['id'] == id } }
col = ->(e, id) { ((e || {})['columns'] || []).find { |c| c['id'] == id } }
data_el = ->(id) { (flat[:data] || []).find { |e| e['id'] == id } }
all_json = JSON.generate(flat[:specs])

puts 'Part 0 - the pipeline builds the whole fixture'
check(flat1[:ok], "build-charts exits 0 on the full fixture (got: #{flat1[:log].to_s.lines.grep(/Error/).first(2).inspect})", fails)
check(!flat1[:log].include?('NoMethodError'), 'no NoMethodError in the build log', fails)
check(flat[:ok], 'build-charts exits 0 on the fixture without the scatter', fails)

puts
puts 'Part 1 - scatter: measures come from the shelves; failures degrade ONE tile'
els1 = flat1[:elements] || []
sc = els1.find { |e| e['id'] == 'el-customer-scatter' }
check(sc && sc['kind'] == 'scatter-chart', "the scatter tile is built as a scatter-chart (got #{sc && sc['kind']})", fails)
src = (flat1[:data] || []).find { |e| e['id'] == 'el-customer-scatter-src' }
check(src && src['columns'].map { |c| c['name'] } == ['Customer Id', 'Lifetime Orders', 'Lifetime Revenue', 'Net Revenue'],
      "the grouped source carries dim, X, Y and size once each (got #{src && src['columns'].map { |c| c['name'] }.inspect})", fails)
check(src && src['columns'].map { |c| c['formula'] } ==
      ['[Master/Customer Id]', 'Avg([Master/Lifetime Orders])', 'Avg([Master/Lifetime Revenue])', 'Sum([Master/Net Revenue])'],
      "X = Cols-shelf measure, Y = Rows-shelf measure, aggregates from the shelf derivation (got #{src && src['columns'].map { |c| c['formula'] }.inspect})", fails)
check(sc && sc.dig('xAxis', 'columnId') == 'x-el-customer-scatter' && col.call(sc, 'x-el-customer-scatter')&.fetch('name') == 'Lifetime Orders' &&
      col.call(sc, 'y-el-customer-scatter')&.fetch('name') == 'Lifetime Revenue', 'axes: X = Lifetime Orders (Cols), Y = Lifetime Revenue (Rows)', fails)
check(src && src.dig('source', 'elementId') == 'master',
      'a fact-side size (Net Revenue) keeps the grouped source on the master', fails)
check(flat1[:log] =~ /scatter plots dim-table measure\(s\) 'Lifetime Orders' \(Customer Dim\), 'Lifetime Revenue' \(Customer Dim\)/,
      'the dim-table-measure-over-fact-grain caveat is disclosed', fails)

# No size => nothing fact-side rides along => the native-grain DM element helper (same as the bar/KPI paths).
no_size = FIXTURE_TEXT.sub("              <size column='[federated.sgap0001].[sum:NET_REVENUE:qk]' />\n", '')
ns = run_pipeline(no_size, csvs: CSVS.merge('Customer Scatter' => SCATTER_CSV.gsub(/,"[\d,.]+"$/, '').sub(',Net Revenue', '')))
helper = (ns[:data] || []).find { |e| e['id'] == 'el-customer-scatter-grain-src' }
nsrc = (ns[:data] || []).find { |e| e['id'] == 'el-customer-scatter-src' }
check(helper && helper.dig('source', 'elementId') == '__DM_ELEMENT__:Customer Dim',
      "no fact-side column => grouped source rides the Customer Dim grain helper (got #{helper && helper['source'].inspect})", fails)
check(nsrc && nsrc.dig('source', 'elementId') == 'el-customer-scatter-grain-src' &&
      nsrc['columns'].map { |c| c['formula'] }.last(2) == ['Avg([Customer Dim Grain (customer-scatter)/Lifetime Orders])', 'Avg([Customer Dim Grain (customer-scatter)/Lifetime Revenue])'],
      "the grouped source reads the helper's columns (got #{nsrc && nsrc['columns'].map { |c| c['formula'] }.inspect})", fails)

# An unresolvable measure pair degrades THAT tile only.
no_ltr = base_mmap.reject { |_k, v| v['name'] == 'Lifetime Revenue' }
dg = run_pipeline(FIXTURE_TEXT, mmap: no_ltr)
check(dg[:ok] && dg[:elements].any? { |e| e['id'] == 'el-promo-lift' }, 'a scatter whose measure cannot resolve does not stop the other tiles', fails)
check(dg[:elements].none? { |e| e['id'] == 'el-customer-scatter' } &&
      dg[:log].lines.any? { |l| l.start_with?('  WARN') && l.include?("ZONE DROPPED: 'Customer Scatter' scatter") && l.include?('Y (Rows shelf)') },
      'the unresolvable scatter is a named ZONE DROPPED warning (coverage: dropped)', fails)
check(((dg[:coverage] || {})['unresolved'] || []).any? { |u| u['severity'] == 'dropped' && u['detail'].to_s.include?("'Customer Scatter' scatter") },
      'coverage.json records the dropped scatter', fails)

# Per-zone isolation: a tile that raises is dropped with a warning naming the exception; the rest build.
boom = run_pipeline(FIXTURE_TEXT, layout_edit: lambda do |doc|
  doc.each { |dash| dash['zones'].each { |z| z['aggregations'] = 'not-a-hash' if z['caption'] == 'Promo Lift' && z['kind'] == 'chart' } }
end)
check(boom[:ok] && boom[:elements].size >= 4,
      "a tile that raises does not take the build down (exit ok, #{boom[:elements].size} other elements built)", fails)
check(boom[:elements].none? { |e| e['id'] == 'el-promo-lift' } &&
      boom[:log].lines.any? { |l| l.include?("ZONE DROPPED: 'Promo Lift'") && l =~ /builder raised \w+Error/ },
      'the failing tile is a ZONE DROPPED warning naming the exception class', fails)
check(boom[:elements].any? { |e| e['id'] == 'el-customer-scatter' } && boom[:elements].any? { |e| e['id'] == 'el-revenue-map' },
      'the tiles around it still build', fails)

puts
puts 'Part 2 - calc-on-calc references never dangle'
pl = el.call('el-promo-lift')
plf = pl && (pl['columns'] || []).map { |c| c['formula'] }.join(' | ')
# The FIXED-no-dim LOD is inlined (translated Promo Flag) and held on a hidden scalar helper that the
# chart reads with Lookup — a chart-level GrandTotal would shrink with the chart's own filters
# (test-fidelity-s3.rb covers that route end to end).
scalar = data_el.call('fixed-scalar-1')
scalar_v = scalar && scalar['columns'].find { |c| c['name'] == 'Value' }
check(pl && plf.include?('Lookup([Fixed Scalar 1/Value], 1, [Fixed Scalar 1/Key])') && scalar_v &&
        scalar_v['formula'].include?('Avg(If(') && scalar_v['formula'].include?('[Master/Promo Type]') &&
        scalar_v['formula'].include?('[Master/Net Revenue]'),
      "Promo Lift % reads the referenced FIXED-no-dim LOD (Avg over the translated Promo Flag) from a scalar helper (got #{plf.inspect} / #{scalar_v && scalar_v['formula'].inspect})", fails)
check(!all_json.include?('Master/Calculation_'), 'no [Master/Calculation_<id>] anywhere in the built specs', fails)
check(!all_json.include?('[Calculation_'), 'no bare [Calculation_<id>] reference either', fails)
check(flat[:log] !~ /^\s+WARN .*Promo Lift/, 'Promo Lift builds without a WARN', fails)
ten = el.call('el-tenure-bar')
check(ten.nil? && flat[:log].lines.any? { |l| l.start_with?('  WARN') && l.include?("ZONE DROPPED: 'Tenure Bar'") && l.include?('[Calculation_1007]') },
      'a tile left with an unresolvable internal calc ref is dropped with a named warning (not shipped dangling)', fails)
check(((flat[:coverage] || {})['unresolved'] || []).any? { |u| u['severity'] == 'dropped' && u['detail'].to_s.include?("'Tenure Bar'") },
      'coverage.json records the dropped tile', fails)

mm = base_mmap
cbg = {
  'Calculation_1001' => { 'caption' => 'Promo Flag', 'formula' => "IF ISNULL([PROMO_TYPE]) OR [PROMO_TYPE] = 'None' THEN 'No Promo' ELSE 'Promo' END" },
  'Calculation_1002' => { 'caption' => 'Baseline', 'formula' => "{FIXED : AVG(IF [Calculation_1001] = 'No Promo' THEN [NET_REVENUE] END)}" },
  'Calculation_1006' => { 'caption' => 'First Order', 'formula' => '{FIXED [CUSTOMER_ID] : MIN([ORDER_DATE])}' },
  'Calculation_1009' => { 'caption' => 'Net Revenue', 'formula' => '' },
  'PROMO_TYPE' => { 'caption' => 'Promo Type' }, 'NET_REVENUE' => { 'caption' => 'Net Revenue' }
}
tr = translate_user_agg_formula('AVG([NET_REVENUE]) / MAX([Calculation_1002]) - 1', mm, cbg)
check(tr == 'Avg([Master/Net Revenue]) / GrandTotal(Avg(If((If(IsNull([Master/Promo Type]) or [Master/Promo Type] = "None", "No Promo", "Promo")) = "No Promo", [Master/Net Revenue], Null))) - 1',
      "unit: AVG(x)/MAX([calc-on-calc LOD]) - 1 translates (got #{tr.inspect})", fails)
check(translate_user_agg_formula('SUM([Calculation_1002])', mm, cbg).nil?,
      'unit: SUM of a table-wide constant is refused (it would multiply by the row count), not emitted dangling', fails)
check(translate_user_agg_formula('MAX([Calculation_1006])', mm, cbg).nil?,
      'unit: a FIXED LOD WITH dimensions is refused (nil) — the caller degrades', fails)
check(translate_dim_calc("IF [Calculation_1006] > [ORDER_DATE] THEN 'a' ELSE 'b' END", mm, cbg).nil?,
      'unit: a row-level calc over an unresolvable internal calc is refused', fails)
cap_map = mm.merge('(?i)^Baseline$' => { 'id' => 'm-baseline', 'name' => 'Baseline' })
check(translate_user_agg_formula('MAX([Calculation_1002])', cap_map, cbg) == 'MAX([Master/Baseline])'.sub('MAX', 'Max'),
      'unit: a calc the master carries (by caption) resolves to that master column', fails)

check(MechanicalSpecs.rewrite_metric_formula('Sum([Calculation_1002]) / Sum([Net Revenue])', {}).nil? &&
      MechanicalSpecs.rewrite_metric_formula('Sum([Gross Profit]) / Sum([Net Revenue])', {}) == 'Sum([Master/Gross Profit]) / Sum([Master/Net Revenue])',
      'unit (DM-metric path): a metric formula over a Tableau-internal calc name is refused, never [Master/Calculation_<id>]', fails)

puts
puts 'Part 3 - parameter-driven aggregate calc on Color'
mt = el.call('el-margin-vs-threshold')
check(mt && mt['kind'] == 'bar-chart', 'Margin vs Threshold is built', fails)
mcols = (mt || {})['columns'] || []
check(mcols.map { |c| c['name'] }.first(2) == ['Order Channel', 'Gross Margin %'],
      "dimension + measure resolve although the CSV formats the measure as '77.5%' (got #{mcols.map { |c| c['name'] }.inspect})", fails)
ccol = col.call(mt, mt && mt.dig('color', 'column'))
flag_helper = data_el.call('el-margin-vs-threshold-flag-src')
flag_col = flag_helper && flag_helper['columns'].find { |c| c['name'] == 'Margin Above Threshold' }
check(ccol && ccol['name'] == 'Margin Above Threshold' && ccol['formula'] == '[Margin vs Threshold Color Source/Margin Above Threshold]' &&
      flag_col && flag_col['formula'] == 'Text(Sum([Master/Gross Profit]) / Sum([Master/Net Revenue]) >= [ctl-param-margin-threshold])',
      "color column reads a per-dimension group calculation comparing the aggregate with the parameter control (got #{ccol && ccol['formula'].inspect} / #{flag_col && flag_col['formula'].inspect})", fails)
check(mt && mt.dig('color', 'by') == 'category', 'color is categorical', fails)
check(!all_json.include?('Master/Margin Above Threshold'), 'the parameter calc is not referenced as a master column', fails)
check(els.any? { |e| e['kind'] == 'control' && e['controlId'] == 'ctl-param-margin-threshold' },
      'the parameter control it reads is emitted', fails)
# Sigma's default slider step is 1: a 0..1 track without the Tableau granularity
# has no stops between its ends and the handle cannot move.
mslider = els.find { |e| e['kind'] == 'control' && e['controlId'] == 'ctl-param-margin-threshold' } || {}
check(mslider['controlType'] == 'slider' && mslider['step'] == 0.01,
      "the slider carries the Tableau range granularity as its step (got #{mslider.values_at('controlType', 'step').inspect})", fails)
eval(File.read(BUILD)[/^def slider_step\b.*?\n^end\n/m]) # rubocop:disable Security/Eval
check(slider_step(0, 100).nil? && slider_step(0, 5, integer: true).nil? && slider_step(0.4, 0.9) == 0.001 &&
        slider_step(0, 1) == 0.01 && slider_step(1, 5, '0.5') == 0.5 && slider_step(0, 10, '1') == 1 &&
        slider_step(5, 5).nil?,
      'slider_step: whole-number tracks keep the default; fractional tracks get a round step', fails)

puts
puts 'Part 5 - filled map'
mapel = el.call('el-revenue-map')
check(mapel && mapel['kind'] == 'region-map', "Revenue Map is a region-map (got #{mapel && mapel['kind']})", fails)
check(mapel && mapel['region'] && mapel['region']['regionType'] == 'us-state' &&
      col.call(mapel, mapel['region']['columnId'])['formula'] == '[Master/State]',
      "keyed on the geo-role dimension with regionType us-state (got #{mapel && mapel['region'].inspect})", fails)
check(mapel && mapel.dig('color', 'by') == 'scale' && col.call(mapel, mapel.dig('color', 'column'))['name'] == 'Net Revenue' &&
      col.call(mapel, mapel.dig('color', 'column'))['formula'] == 'Sum([Master/Net Revenue])',
      'fill = the Color-shelf measure (Net Revenue) on a sequential scale, not the first CSV measure', fails)
check(mapel && !mapel.key?('xAxis') && !mapel.key?('yAxis'), 'no x/y axes on a region-map', fails)
check(!all_json.downcase.include?('(generated)') && !all_json.include?('Latitude') && !all_json.include?('Longitude'),
      'the generated Latitude/Longitude are referenced nowhere', fails)
check(flat[:log].lines.any? { |l| l.include?('generated geocode') && l.include?("'Revenue Map'") }, 'dropping the generated columns is disclosed', fails)
check(((flat[:coverage] || {})['unresolved'] || []).none? { |u| u['visual'] == 'Revenue Map' && u['severity'] == 'degraded' },
      'coverage no longer calls the native region-map "degraded"', fails)
nonus = run_pipeline(FIXTURE_TEXT, csvs: CSVS.merge('Revenue Map' => CSVS['Revenue Map'].sub('CA,', 'Ontario,').sub('CO,', 'Quebec,')))
nm = nonus[:elements].find { |e| e['id'] == 'el-revenue-map' }
check(nm && nm['kind'] == 'bar-chart' && !nm.key?('region') &&
      nonus[:log].lines.any? { |l| l.include?('has no Sigma regionType') && l.include?("'Revenue Map'") },
      'members that are not US states fall back to a bar chart with a named warning (never a wrong region-map)', fails)
lint_out, lint_st = lint_elements([mapel].compact)
check(lint_st.success?, "validate-spec accepts the region-map (#{lint_out.lines.grep(/ERROR/).first(2).inspect})", fails)
bad = { 'id' => 'bad-map', 'kind' => 'region-map', 'name' => 'Bad', 'source' => { 'kind' => 'table', 'elementId' => 'master' },
        'columns' => [{ 'id' => 'a', 'name' => 'S', 'formula' => '[Master/State]' }, { 'id' => 'b', 'name' => 'V', 'formula' => 'Sum([Master/Net Revenue])' }],
        'xAxis' => { 'columnId' => 'a' }, 'yAxis' => { 'columnIds' => ['b'] } }
bad_out, bad_st = lint_elements([bad])
check(!bad_st.success? && bad_out.include?('region-map missing region'),
      'validate-spec rejects the old x/y-axis region-map shape (no region key)', fails)

puts
puts 'Part 6 - crosstab with dimensions on Columns only'
yoy = el.call('el-yoy-growth')
check(yoy && yoy['kind'] == 'pivot-table', 'YoY Growth is a pivot-table', fails)
check(yoy && yoy['rowsBy'].is_a?(Array) && yoy['rowsBy'].size == 1 && yoy['columnsBy'].size == 1,
      "one constant row + the year column (got rowsBy=#{yoy && yoy['rowsBy'].inspect})", fails)
rc = col.call(yoy, yoy&.dig('rowsBy', 0, 'columnId'))
check(rc && rc['formula'] == '"YoY Growth %"', "the row is the measure's name as a literal (got #{rc && rc['formula'].inspect})", fails)
check(yoy && (yoy['columns'] || []).map { |c| c['name'] }.uniq.size == yoy['columns'].size, 'column names stay unique', fails)
yo, yst = lint_elements([yoy].compact)
check(yst.success?, "validate-spec accepts it (was: pivot-table without rowsBy) #{yo.lines.grep(/ERROR/).first(2).inspect}", fails)
check(flat[:log].lines.any? { |l| l.include?("'YoY Growth'") && l.include?('Columns only') }, 'the added constant row is disclosed', fails)
check(el.call('el-margin-vs-threshold') && !el.call('el-margin-vs-threshold').key?('rowsBy'), 'non-pivot tiles are untouched', fails)

puts
puts 'Part 4 - disambiguated duplicate captions'
def conv_col(path)
  { 'id' => "c-#{path.tr('/', '-')}", 'formula' => "[ORDERS/#{path}]" }
end
fact = { 'name' => 'Orders View',
         'columns' => [{ 'id' => 'f-id', 'name' => 'Order Id', 'formula' => '[ORDERS/Order Id]' },
                       { 'id' => 'f-up', 'name' => 'Unit Price', 'formula' => '[ORDERS/Unit Price]' },
                       conv_col('CUSTOMER_DIM/Region'), conv_col('CUSTOMER_DIM/City'),
                       conv_col('STORE_DIM/Region'), conv_col('STORE_DIM/City'), conv_col('PRODUCT_DIM/Unit Price')] }
labels = ['Order Id', 'Unit Price', 'Region (CUSTOMER_DIM)', 'City (CUSTOMER_DIM)', 'Region (STORE_DIM)',
          'City (STORE_DIM)', 'Unit Price (PRODUCT_DIM)']
twb_caps = MechanicalSpecs.disambiguated_captions_from_twb(
  "<column caption='Region (STORE_DIM (SALESDB.STORE_DIM))' datatype='string' name='[g1]' />" \
  "<column caption='City (STORE_DIM (SALESDB.STORE_DIM))' datatype='string' name='[g2]' />" \
  "<column caption='Unit Price (PRODUCT_DIM (SALESDB.PRODUCT_DIM))' datatype='real' name='[g3]' />" \
  "<column caption='Net Revenue' datatype='real' name='[g4]' />")
check(twb_caps == ['Region (STORE_DIM (SALESDB.STORE_DIM))', 'City (STORE_DIM (SALESDB.STORE_DIM))', 'Unit Price (PRODUCT_DIM (SALESDB.PRODUCT_DIM))'],
      "the .twb scan finds exactly the disambiguated captions (got #{twb_caps.inspect})", fails)
d = MechanicalSpecs.derive_master(fact, 'Orders View', nil, labels, nil, disambiguated: twb_caps)
by = d['master_columns'].each_with_object({}) { |c, h| h[c['name']] = c['formula'] }
check(by['Region'] == '[Orders View/Region (CUSTOMER_DIM)]' && by['Region (STORE_DIM)'] == '[Orders View/Region (STORE_DIM)]' &&
      by['City'] == '[Orders View/City (CUSTOMER_DIM)]' && by['City (STORE_DIM)'] == '[Orders View/City (STORE_DIM)]',
      "both Region copies exist; the plain caption is the table Tableau did not rename (got #{by.select { |k, _| k =~ /Region|City/ }.inspect})", fails)
check(by['Unit Price'] == '[Orders View/Unit Price]' && by['Unit Price (PRODUCT_DIM)'] == '[Orders View/Unit Price (PRODUCT_DIM)]',
      'a fact column and a same-named dim column both survive (fact keeps the plain name)', fails)
mp = d['mmap']
check(map_column('Region (STORE_DIM (SALESDB.STORE_DIM))', mp)&.fetch('name') == 'Region (STORE_DIM)' &&
      map_column('Region', mp)&.fetch('name') == 'Region' &&
      map_column('City (STORE_DIM (SALESDB.STORE_DIM))', mp)&.fetch('name') == 'City (STORE_DIM)',
      'the master-map resolves each Tableau caption to its own table\'s master column', fails)
check(map_column('Region (STORE_DIM (OTHER.STORE_DIM))', mp)&.fetch('name') == 'Region (STORE_DIM)',
      'a disambiguated caption with a different schema label still resolves (generic shape)', fails)
rev = fact.merge('columns' => fact['columns'].reverse)
d2 = MechanicalSpecs.derive_master(rev, 'Orders View', nil, labels, nil, disambiguated: twb_caps)
by2 = d2['master_columns'].each_with_object({}) { |c, h| h[c['name']] = c['formula'] }
check(by2['Region'] == by['Region'] && by2['Region (STORE_DIM)'] == by['Region (STORE_DIM)'],
      'column order does not change which table owns the plain caption (was an unstable sort)', fails)
d3 = MechanicalSpecs.derive_master(fact, 'Orders View', nil, labels, nil)
by3 = d3['master_columns'].each_with_object({}) { |c, h| h[c['name']] = c['formula'] }
check(by3.key?('Region') && by3.key?('Region (STORE_DIM)') && by3['Region'] != by3['Region (STORE_DIM)'],
      'with no .twb captions both copies still exist (first path keeps the plain name)', fails)

puts
puts 'Part 7 - range quick filter: bounds come from <min>/<max> child elements'
# Tableau writes a quantitative filter's bounds as CHILD elements. The parser read only
# attributes, so every bounded range card lost its bounds and the builder emitted a
# slider with no low/high/value, which the API rejects ("Invalid kind: control").
range_variant = lambda do |bounds|
  FIXTURE_TEXT
    .sub("<column-instance column='[NET_REVENUE]' derivation='Sum' name='[sum:NET_REVENUE:qk]' pivot='key' type='quantitative' />\n          </datasource-dependencies>",
         "<column-instance column='[NET_REVENUE]' derivation='Sum' name='[sum:NET_REVENUE:qk]' pivot='key' type='quantitative' />\n" \
         "            <column-instance column='[NET_REVENUE]' derivation='None' name='[none:NET_REVENUE:qk]' pivot='key' type='quantitative' />\n" \
         "          </datasource-dependencies>\n" \
         "          <filter class='quantitative' column='[federated.sgap0001].[none:NET_REVENUE:qk]' included-values='in-range'>#{bounds}</filter>")
    .sub(%r{(<zone h='33000' id='22' name='Promo Lift'[^>]*/>)},
         "\\1\n              <zone h='10000' id='30' mode='slider' name='Tenure Bar' param='[federated.sgap0001].[none:NET_REVENUE:qk]' type-v2='filter' values='relevant' w='20000' x='0' y='0' />")
end
bounded_twb = range_variant.call('<min>0</min><max>5000</max>')
check(bounded_twb.include?("type-v2='filter'") && bounded_twb.include?('<max>5000</max>'), 'range-card fixture variant applied', fails)
rng_ctl = lambda do |res|
  (res[:elements] || []).find { |e| e['kind'] == 'control' && e['name'] == 'Net Revenue' }
end
bounded = run_pipeline(bounded_twb)
bc = rng_ctl.call(bounded) || {}
check(bc['controlType'] == 'range-slider' && bc['low'] == 0 && bc['high'] == 5000 && bc['min'] == 0 && bc['max'] == 5000,
      "a bounded range card becomes a range-slider over its bounds (got #{bc.values_at('controlType', 'low', 'high', 'min', 'max').inspect})", fails)
open_res = run_pipeline(range_variant.call(''))
oc = rng_ctl.call(open_res) || {}
check(oc['controlType'] == 'number-range' && !oc.key?('value'),
      "a range card with no bounds becomes an open number-range, never a value-less slider (got #{oc.values_at('controlType', 'value').inspect})", fails)
py_out = Dir.mktmpdir do |d|
  File.write(File.join(d, 'wb.twb'), bounded_twb)
  Open3.capture2e('python3', File.join(DIR, 'parse-twb-layout.py'), File.join(d, 'wb.twb'), File.join(d, 'l.json'))
  File.exist?(File.join(d, 'l.json')) ? File.read(File.join(d, 'l.json')) : ''
end
check(py_out.include?('"kind": "number-range"') && py_out =~ /"min": 0,\s*"max": 5000/,
      'the Python parser twin reads the same child-element bounds', fails)

puts
if fails.empty?
  puts 'test-stress-gaps: ALL PASS'
  exit 0
else
  puts "test-stress-gaps: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
