#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for the end of the Power BI-shaped model step (task 14): PbiShapedModel.apply! (every model
# transform, in order), the data model pages per subject area, the size stats, and lib/pbi_direct_map.rb (the
# master-map whose masters are data model elements the charts read directly).
#
# Fixtures: fixtures/pbi-shaped/{sales,inventory} (placeholder Snowflake coordinates only). Synthetic names
# only. No network. Run: ruby scripts/test-pbi-direct-map.rb
require 'json'
require_relative 'lib/pbi_shaped_model'
require_relative 'lib/pbi_measure_class'
require_relative 'lib/pbi_direct_map'
require_relative 'lib/pbi_shape_run'
require_relative 'lib/pbi_reportbuild'

FIX = File.join(File.dirname(__dir__), 'fixtures', 'pbi-shaped')
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'
S = PbiShapedModel
D = PbiDirectMap

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def load_json(*parts)
  JSON.parse(File.read(File.join(FIX, *parts)))
end

# The pipeline the orchestrator runs: apply! on the raw model, then the direct map over a readback whose
# element ids differ from the converter's (a POST re-ids them).
def run(fixture, signals, **kw)
  dm = load_json(fixture, 'dm-raw.json')
  tmsl = load_json(fixture, 'model.bim')
  signals = load_json(fixture, signals) if signals.is_a?(String)
  log = S.apply!(dm, tmsl: tmsl, signals: signals, native_result: nil, dialect: 'snowflake', **kw)
  { dm: dm, tmsl: tmsl, signals: signals, log: log }
end

def readback(dm)
  rb = JSON.parse(JSON.generate(dm))
  rb['dataModelId'] = 'dm-test'
  rb['pages'].each { |pg| pg['elements'].each { |e| e['id'] = "rb-#{e['id']}" } }
  rb
end

def direct(ctx, **kw)
  D.build(ctx[:dm], readback(ctx[:dm]), ctx[:tmsl], ctx[:log]['classes'], time_intel: ctx[:log]['time_intel'], signals: ctx[:signals], **kw)
end

def page_of(log, name)
  log['pages'].find { |pg| pg['name'] == name }
end

def element_names(ctx, page)
  by_id = S.elements_of(ctx[:dm]).each_with_object({}) { |e, h| h[e['id']] = e['name'] }
  page['element_ids'].map { |i| by_id[i] }
end

# The builder's visual_master tally (primary master + alts of every bound field).
def visual_master(visual, fields)
  counts = Hash.new(0)
  refs = visual['bindings'].values.flatten.compact
  refs.each do |r|
    fs = fields[r] or next
    ([fs['master']] + Array(fs['alts']).map { |a| a['master'] }).compact.uniq.each { |m| counts[m] += 1 }
  end
  first = fields[refs.first] && fields[refs.first]['master']
  counts.max_by { |m, c| [c, m == first ? 1 : 0] }&.first
end

# ---------------------------------------------------------------------------------------------------
puts "\ntest_apply_runs_every_step_and_logs_json"
sales = run('sales', 'signals.json')
log = sales[:log]
names = S.elements_of(sales[:dm]).map { |e| e['name'] }
check(names.none? { |n| n.to_s.end_with?(' View') }, 'Views are gone', fails)
check(names.include?('Sales') && names.include?('Sales (source)'), "the fact is split into Sales (source) and Sales: #{names.inspect}", fails)
check(log['classes']['Sales.List Value']['class'] == 'B' && log['splits'].length == 1, 'B metrics classified and the fact split', fails)
check(log['dropped']['elements'].length == 3, "dropped the three Views (#{log['dropped']['elements'].inspect})", fails)
check(log['relationships']['renamed'].any? { |r| r['to'] == 'Date (ShipDateKey)' }, 'the inactive relationship is named after its column', fails)
check(log['filters']['applied'].any?, 'the report filter is applied', fails)
check(%w[dropped renames relationships key_decisions dangling_refs classes class_counts reclassified time_intel folders metric_renames descriptions filters pages size_stats].all? { |k| log.key?(k) }, 'the log names every step', fails)
check(JSON.parse(JSON.generate(log)) == log, 'the log round-trips as JSON', fails)
check(log['class_counts'] == { 'A' => 7, 'B' => 3 }, "class counts: #{log['class_counts'].inspect}", fails)

puts "\ntest_apply_applies_flatten_lifted_r7"
flat_ctx = run('sales', 'signals.json', flatten: ['Sales'])
check(flat_ctx[:log]['flattened'].map { |r| r['element'] } == ['Sales (flattened)'], 'a flatten list is applied (R7 lifted)', fails)
raised = begin
  run('sales', 'signals.json', flatten: ['Nope'])
  false
rescue ArgumentError => e
  e.message.include?('flatten')
end
check(raised, 'an unknown flatten name raises ArgumentError', fails)

puts "\ntest_apply_applies_key_results_between_relationships_and_classes"
dm = load_json('sales', 'dm-raw.json')
tmsl = load_json('sales', 'model.bim')
sig = load_json('sales', 'signals.json')
klog = S.apply!(dm, tmsl: tmsl, signals: sig, dialect: 'snowflake', key_results: { 'Sales->Store' => 3 })
check(klog['key_decisions'].any? { |k| k['relationship'] == 'Sales->Store' && k['action'] == 'dropped' }, "key result applied: #{klog['key_decisions'].inspect}", fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_pages_group_by_fact_with_shared_dims"
check(log['pages'].map { |pg| pg['name'] } == %w[Sales Shared], "one fact, one page plus Shared for As Of: #{log['pages'].map { |pg| pg['name'] }.inspect}", fails)
sp = element_names(sales, page_of(log, 'Sales'))
check(%w[Sales Sales\ (source) Date Category Vendor Product SKU Customer Store].all? { |n| sp.include?(n) }, "Sales page holds the fact, its source and the dimensions only it uses: #{sp.inspect}", fails)
check(element_names(sales, page_of(log, 'Shared')) == ['As Of'], 'As Of (no relationship) is on Shared', fails)
check(log['pages'].flat_map { |pg| pg['element_ids'] }.sort == S.elements_of(sales[:dm]).map { |e| e['id'] }.sort, 'every element is on exactly one page', fails)
check(sales[:dm]['pages'].map { |pg| pg['name'] } == %w[Sales Shared] && sales[:dm]['pages'].all? { |pg| pg['id'] && pg['elements'].any? }, 'dm_model pages are [{id, name, elements}]', fails)

inv = run('inventory', 'signals.json')
check(inv[:log]['pages'].map { |pg| pg['name'] } == ['Sales', 'Inventory', 'Purchase Orders', 'Shared'], "one page per fact: #{inv[:log]['pages'].map { |pg| pg['name'] }.inspect}", fails)
ip = element_names(inv, page_of(inv[:log], 'Sales'))
check(ip.include?('Sales') && ip.any? { |n| n.include?('rolling') } && ip.include?('Customer'), "the rolling element and Customer (used only by Sales) are on the Sales page: #{ip.inspect}", fails)
shared = element_names(inv, page_of(inv[:log], 'Shared'))
check(%w[Date SKU Store As\ Of].all? { |n| shared.include?(n) }, "dimensions several facts use equally go on Shared: #{shared.inspect}", fails)

# a dimension used by several facts goes to the fact whose visuals read it most
more = JSON.parse(JSON.generate(inv[:signals]))
more['pages'] << { 'page_id' => 'p9', 'page_title' => 'Stock', 'visuals' => [
  { 'visual_id' => 'v1', 'title' => 'a', 'bindings' => { 'Category' => ['Store.Store Region'], 'Y' => ['Inventory.On Hand (Latest)'] } },
  { 'visual_id' => 'v2', 'title' => 'b', 'bindings' => { 'Category' => ['Store.Channel'], 'Y' => ['Inventory.On Hand (Latest)'] } }
] }
inv2 = run('inventory', more)
check(element_names(inv2, page_of(inv2[:log], 'Inventory')).include?('Store') && !element_names(inv2, page_of(inv2[:log], 'Shared')).include?('Store'),
      'Store goes to Inventory, the fact with the most visuals reading it', fails)

one = run('sales', 'signals.json', multi_page: false)
check(one[:log]['pages'].length == 1 && one[:dm]['pages'].length == 1, 'multi_page: false keeps one page', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_size_stats_counts_sql_elements"
st = inv[:log]['size_stats']
check(st == { 'elements' => 13, 'sql_elements' => 2, 'guidance' => '30-40' }, "inventory stats: #{st.inspect}", fails)
check(S.size_stats(sales[:dm]) == { 'elements' => 10, 'sql_elements' => 0, 'guidance' => '30-40' }, 'sales stats: no SQL element', fails)
check(S.size_stats(sales[:dm]).values_at('elements', 'sql_elements') == [S.elements_of(sales[:dm]).length, S.elements_of(sales[:dm]).count { |e| e.dig('source', 'kind') == 'sql' }], 'counts come from the model', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_direct_master_has_three_hop_category_column"
map = direct(sales)
m = map['masters']['Sales']
col = m['columns'].find { |c| c['formula'] == '[Sales/SKU/Product/Category/Category Name]' }
check(col && col['name'] == "Category Name (SKU \u2215 Product \u2215 Category)", "Sales reaches Category Name in three hops (the report filter's Lookup column already owns Category Name (Category)): #{col.inspect}", fails)
check(m['direct'] == true && m['element_name'] == 'Sales', 'the master is direct and names its element', fails)
check(m['element_id'] == 'rb-' + S.elements_of(sales[:dm]).find { |e| e['name'] == 'Sales' }['id'], 'element_id is the readback id', fails)
check(m['data_model'] == 'dm-test' && m['id'] =~ /\Amaster-[0-9a-f]{8}\z/, 'data_model and id are set', fails)
check(map['masters'].values.all? { |x| x['direct'] == true && x['element_name'] }, 'every master is direct', fails)
check(!map['masters'].key?('Sales (source)'), 'the (source) base is not a master', fails)
check(m['columns'].any? { |c| c['name'] == 'Month Start (Date)' && c['formula'] == '[Sales/Date/Month Start]' }, 'one-hop column: Month Start (Date)', fails)
check(m['columns'].any? { |c| c['name'] == 'Month Start (Date (ShipDateKey))' && c['formula'] == '[Sales/Date (ShipDateKey)/Month Start]' }, 'the inactive relationship is a path too', fails)
check(m['columns'].any? { |c| c['name'] == 'List Price (Product)' && c['formula'] == '[Sales/List Price (Product)]' }, 'the Lookup column is an own column', fails)
all_names = map['masters'].values.flat_map { |x| x['columns'].map { |c| [x['id'], c['name']] } }
check(all_names.uniq.length == all_names.length, 'column names are unique per master', fails)
check(map['masters'].values.all? { |x| x['columns'].all? { |c| c['name'] !~ %r{[/\[\]]} } }, 'R47: no master column name contains / or a bracket', fails)
colide = m['columns'].find { |c| c['formula'] == '[Sales/SKU/Product/List Price]' }
check(colide && colide['name'] == "List Price (SKU \u2215 Product)", "a collision (the Lookup column List Price (Product)) takes the full path with U+2215: #{colide.inspect}", fails)
check(m['columns'].count { |c| c['name'] == 'List Price (Product)' } == 1, 'the own Lookup column keeps its name', fails)
ids = map['masters'].values.flat_map { |x| [x['id']] + x['columns'].map { |c| c['id'] } }
check(ids.uniq.length == ids.length, 'ids are unique', fails)
check(!m['columns'].any? { |c| c.keys.any? { |k| k.start_with?('_') } }, 'no private keys leak into the map', fails)
shallow = direct(sales, max_hops: 1)['masters']['Sales']
check(shallow['columns'].none? { |c| c['formula'].include?('/SKU/Product/') } && shallow['columns'].any? { |c| c['name'] == 'ProductKey (SKU)' }, 'max_hops: 1 stops at the first hop', fails)
check(JSON.parse(JSON.generate(map)) == map, 'the map round-trips as JSON', fails)

puts "\ntest_field_alts_let_the_builder_pick_the_fact_master"
f = map['fields']
check(f['Category.Category Name']['master'] == 'Category' && f['Category.Category Name']['ref'] == "[#{map['masters']['Category']['id']}/Category Name]", 'a column is keyed on its own element', fails)
alt = f['Category.Category Name']['alts'].find { |a| a['master'] == 'Sales' }
check(alt && alt['ref'] == "[#{m['id']}/Category Name (SKU \u2215 Product \u2215 Category)]", "the fact master carries an alt: #{alt.inspect}", fails)
check(f['Product.Brand']['alts'].map { |a| a['master'] }.include?('Sales'), 'Product.Brand has a Sales alt', fails)
brand = sales[:signals]['pages'][0]['visuals'].find { |v| v['title'].start_with?('Brand:') }
check(visual_master(brand, f) == 'Sales', 'a visual mixing dimension fields with fact measures sources the fact master', fails)
cat = sales[:signals]['pages'][0]['visuals'].find { |v| v['title'] == 'Sales Amount by Category' }
check(visual_master(cat, f) == 'Sales', 'Category x Sales Amount sources Sales', fails)

puts "\ntest_measure_fields_follow_the_class"
check(f['Sales.Sales Amount'] == { 'master' => 'Sales', 'ref' => '[Metrics/Sales Amount]', 'agg' => nil, 'formula' => '[Metrics/Sales Amount]' }, "class A binds [Metrics/..]: #{f['Sales.Sales Amount'].inspect}", fails)
check(f['Sales.List Value']['ref'] == '[Metrics/List Value]' && f['Sales.List Value']['master'] == 'Sales', 'class B binds on the child that holds the metric', fails)
check(f['Sales.Sales by Ship Date']['ref'] == '[Metrics/Sales by Ship Date]', 'userel metric binds like a B metric', fails)
check(map['unresolved'] == [], "nothing unresolved on the sales report (#{map['unresolved'].inspect})", fails)
# a metric renamed by unique_metric_names! stays reachable under the Power BI measure name
renamed = run('sales', 'signals.json')
S.elements_of(renamed[:dm]).find { |e| e['name'] == 'Sales' }['metrics'].find { |x| x['name'] == 'Units' }['name'] = 'Units (measure)'
rmap = direct(renamed)
check(rmap['fields']['Sales.Units']['ref'] == '[Metrics/Units (measure)]', 'a renamed metric keeps its Power BI field key', fails)

puts "\ntest_class_c_binds_the_time_intel_master"
trends = run('sales', 'signals-trends.json')
tmap = direct(trends)
tf = tmap['fields']
ytd = tf['Sales.Sales YTD']
check(ytd && ytd['master'] == 'Sales by month' && ytd['formula'].include?("[#{tmap['masters']['Sales by month']['id']}/Sales YTD]"), "YTD reads the grouped element: #{ytd.inspect}", fails)
check(tf['Sales.Sales QTD']['master'] == 'Sales by month (quarter reset)', 'QTD reads its own reset element', fails)
check(tf['Sales.Sales YTD (As Of)']['ref'] == '[Metrics/Sales YTD (As Of)]' && tf['Sales.Sales YTD (As Of)']['formula'] == '[Metrics/Sales YTD (As Of)]' && tf['Sales.Sales YTD (As Of)']['master'] == 'Sales', 'the as-of metric binds like a metric', fails)
r28 = tf['Sales.Sales R28']
rid = r28 && tmap['masters'][r28['master']]['id']
check(r28 && r28['master'].include?('rolling'), "rolling reads the SQL element: #{r28.inspect}", fails)
# a rolling window measure is the window ENDING at the context's last day: with no day axis (a KPI) it is the value on the
# latest day, not the largest (Max) or the sum over every day (Sum) -- live, a KPI read 12.0B against 9.77M in Power BI
check(r28 && r28['formula'] == "Sum(If([#{rid}/Day] = Max([#{rid}/Day]), [#{rid}/Sales R28], Null))", "rolling reads the value on the latest day in scope: #{r28.inspect}", fails)
check(tmap['masters'].keys.include?('Sales by month') && tmap['masters']['Sales by month']['direct'], 'the time-intelligence elements are masters', fails)
mdate = tf['Date.Month Start']['alts'].map { |a| a['master'] }
check(mdate.include?('Sales') && mdate.include?('Sales by month') && mdate.include?('Sales by month (quarter reset)'), "Month Start is an alt on the grouped masters: #{mdate.inspect}", fails)
check(tf['Date.Date']['alts'].any? { |a| a['master'].include?('rolling') }, 'Date.Date is an alt on the rolling element (its day column)', fails)
check(tf['Sales.Sales Amount']['alts'].any? { |a| a['master'] == 'Sales by month' && a['formula'].start_with?('Sum(') }, 'the base measure column of a grouped element is an alt', fails)
chart = trends[:signals]['pages'][0]['visuals'].find { |v| v['title'] == 'Sales Amount vs prior year by month' }
check(visual_master(chart, tf) == 'Sales by month', 'Month x Sales Amount x Sales PY sources the grouped element', fails)

puts "\ntest_no_axis_class_c_reads"
# Evaluate the consumer formulas this converter emits over the rows of a grouped element in scope (rows: [{col => value}]).
def eval_read(formula, rows)
  num = ->(v) { v.nil? ? 0 : v }
  if (m = formula.match(%r{\ASum\(If\(\[[^/\]]+/([^\]]+)\] = Max\(\[[^/\]]+/\1\]\), \[[^/\]]+/([^\]]+)\], Null\)\)\z}))
    top = rows.map { |r| r[m[1]] }.max
    vals = rows.select { |r| r[m[1]] == top }.map { |r| r[m[2]] }.compact
    return vals.empty? ? nil : vals.sum # Sigma: Sum over an all-Null group is Null (proven live, 21c), so a blank latest period stays blank
  end
  return rows.map { |r| num.call(r[$1]) }.sum if formula =~ %r{\ASum\(\[[^/\]]+/([^\]]+)\]\)\z}
  return rows.map { |r| r[$1] }.compact.max if formula =~ %r{\AMax\(\[[^/\]]+/([^\]]+)\]\)\z}
  if (m = formula.match(%r{\A\(Sum\(\[[^/\]]+/([^\]]+)\]\) - Sum\(\[[^/\]]+/([^\]]+)\]\)\) / NullIf\(Sum\(\[[^/\]]+/\2\]\), 0\)\z}))
    b = rows.map { |r| num.call(r[m[1]]) }.sum
    py = rows.map { |r| num.call(r[m[2]]) }.sum
    return py.zero? ? nil : (b - py).to_f / py
  end
  raise "cannot evaluate #{formula}"
end
# Monthly rows over three years: 2022 and 2023 are full years (2022 sells most), 2024 is a part year. A KPI with no date axis
# shows what Power BI shows at the LAST date in scope: the 2024 YTD, not the biggest YTD any period ever held.
base = { '2022' => 100, '2023' => 60, '2024' => 40 }
monthly = []
py = {}
%w[2022 2023 2024].each do |y|
  cum = 0
  (1..(y == '2024' ? 6 : 12)).each do |mo|
    cum += base[y]
    monthly << { 'Month' => format('%s-%02d', y, mo), 'Sales Amount' => base[y], 'Sales YTD' => cum,
                 'Sales PY' => base[(y.to_i - 1).to_s], 'Sales QTD' => cum % 3 }
  end
end
monthly.each { |r| r['Sales PY'] = nil if r['Month'].start_with?('2022') } # no 2021 data
ytd_all = monthly.map { |r| r['Sales YTD'] }
check(ytd_all.max == 1200 && monthly.last['Sales YTD'] == 240, 'the fixture: the largest YTD ever (1200) differs from the latest (240)', fails)
f1 = tf['Sales.Sales YTD']['formula']
mi = tmap['masters']['Sales by month']['id']
check(eval_read(f1, [{ 'Month' => '2024-05', 'Sales YTD' => 5 }, { 'Month' => '2024-06', 'Sales YTD' => nil }]).nil?, 'a latest period whose value is null reads blank, not 0', fails)
check(f1 == "Sum(If([#{mi}/Month] = Max([#{mi}/Month]), [#{mi}/Sales YTD], Null))", "a no-axis YTD KPI reads the latest period: #{f1}", fails)
check(eval_read(f1, monthly) == 240, "YTD KPI over every period = the latest period's YTD (240), not Max (1200): #{eval_read(f1, monthly)}", fails)
check(eval_read("Max([#{mi}/Sales YTD])", monthly) == 1200, 'Max over the same rows would have read 1200', fails)
only23 = monthly.select { |r| r['Month'].start_with?('2023') }
check(eval_read(f1, only23) == 720, 'a Year slicer narrows the rows: the 2023 pick reads 2023 YTD at December (720)', fails)
q1 = tf['Sales.Sales QTD']['formula']
qi = tmap['masters']['Sales by month (quarter reset)']['id']
check(q1 == "Sum(If([#{qi}/Month] = Max([#{qi}/Month]), [#{qi}/Sales QTD], Null))", "QTD reads the latest period: #{q1}", fails)
m1 = tf['Sales.Sales MTD']['formula']
check(m1.start_with?('Sum(If(') && m1.include?('/Month] = Max(['), "MTD reads the latest period: #{m1}", fails)
# PY: SAMEPERIODLASTYEAR shifts the whole date set, so with no axis it is last year's total over the shifted range
pyf = tf['Sales.Sales PY']['formula']
check(pyf == "Sum([#{mi}/Sales PY])", "a no-axis PY KPI sums the PY column over the periods in scope: #{pyf}", fails)
check(eval_read(pyf, only23) == 1200, "2023 pick: PY = 12 x 100 = 2022's total (1200), Max would read 100: #{eval_read(pyf, only23)}", fails)
only24 = monthly.select { |r| r['Month'].start_with?('2024') }
check(eval_read(pyf, only24) == 360, "2024 pick (6 months): PY = 6 x 60 = 360: #{eval_read(pyf, only24)}", fails)
yoyf = tf['Sales.Sales YoY %']['formula']
check(yoyf == "(Sum([#{mi}/Sales Amount]) - Sum([#{mi}/Sales PY])) / NullIf(Sum([#{mi}/Sales PY]), 0)", "YoY % is rebuilt from the summed base and prior: #{yoyf}", fails)
check((eval_read(yoyf, only24) - (240.0 - 360) / 360).abs < 1e-9, "2024 pick YoY % = (240 - 360) / 360: #{eval_read(yoyf, only24)}", fails)
check(eval_read(yoyf, monthly).is_a?(Float), 'YoY % over every period is a ratio of totals', fails)
ba = tf['Sales.Sales Amount']['alts'].find { |a| a['master'] == 'Sales by month' }
check(ba && ba['formula'] == "Sum([#{mi}/Sales Amount])", "the base measure alt sums over the periods in scope (Sum/Count bases are additive): #{ba.inspect}", fails)
check(eval_read(ba['formula'], only24) == 240, 'a no-axis Sales Amount read over the grouped element is the total, not the largest month', fails)
ti_recs = trends[:log]['time_intel']
check(ti_recs.select { |r| r['form'] == 'grouped' }.all? { |r| r['kind'] && r['period'] }, 'grouped records say their kind and period column', fails)
ti_ytd = ti_recs.find { |r| r['measure'] == 'Sales.Sales YTD' }
legacy = D.consumer_formula(ti_ytd.reject { |k, _| %w[kind period].include?(k) }, mi, "[#{mi}/Sales YTD]")
check(legacy == "Max([#{mi}/Sales YTD])", 'a record with no kind keeps the old Max read', fails)

puts "\ntest_whole_previous_forms_need_an_axis_at_their_grain"
ti_whole = [{ 'measure' => 'Sales.Sales PrevY', 'form' => 'grouped', 'element' => 'Sales by year', 'column' => 'Sales PrevY',
              'kind' => 'py', 'period' => 'Year', 'whole' => 'PREVIOUSYEAR', 'grain' => 'year', 'unit' => 'year' },
             { 'measure' => 'Sales.Sales PY', 'form' => 'grouped', 'element' => 'Sales by month', 'column' => 'Sales PY', 'kind' => 'py', 'period' => 'Month' }]
sig = { 'pages' => [{ 'page_title' => 'P', 'visuals' => [
  { 'visual_id' => 'kpi', 'title' => 'KPI', 'visual_type' => 'card', 'bindings' => { 'Values' => ['Sales.Sales PrevY'] } },
  { 'visual_id' => 'tbl', 'title' => 'By region', 'visual_type' => 'tableEx', 'bindings' => { 'Values' => ['Sales.Sales PrevY', 'Product.Brand'] } },
  { 'visual_id' => 'mon', 'title' => 'By month', 'visual_type' => 'columnChart', 'bindings' => { 'Category' => ['Date.Month Start'], 'Y' => ['Sales.Sales PrevY'] } },
  { 'visual_id' => 'yr', 'title' => 'By year', 'visual_type' => 'columnChart', 'bindings' => { 'Category' => ['Date.Year'], 'Y' => ['Sales.Sales PrevY'] } },
  { 'visual_id' => 'pykpi', 'title' => 'PY KPI', 'visual_type' => 'card', 'bindings' => { 'Values' => ['Sales.Sales PY'] } }
] }] }
cls = { 'Sales.Sales PrevY' => { 'class' => 'C', 'related' => [], 'userel' => nil }, 'Sales.Sales PY' => { 'class' => 'C', 'related' => [], 'userel' => nil } }
held = D.whole_form_visuals(sig, cls, ti_whole, ['Date'])
check(held.map { |h| h['visual_id'] }.sort == %w[kpi mon tbl], "visuals reading PREVIOUSYEAR without a Year axis are held back: #{held.map { |h| h['visual_id'] }.inspect}", fails)
check(held.all? { |h| h['reason'].include?('PREVIOUSYEAR') && h['reason'].include?('year') && h['reason'].include?(D::HELD_SUFFIX) }, "the reason names the function and the grain: #{held.first && held.first['reason']}", fails)
check(!held.any? { |h| h['visual_id'] == 'yr' || h['visual_id'] == 'pykpi' }, 'a Year axis, and a shifted-set PY measure with no axis, are not held', fails)
check(D.class_d_visuals(sig, cls, [], held: held).map { |h| h['visual_id'] }.sort == %w[kpi mon tbl], 'class_d_visuals lists them', fails)

puts "\ntest_non_additive_extra_metric_needs_an_axis_at_the_grain (Task 21z2)"
na_els = [{ 'id' => 'f1', 'name' => 'Sales', 'metrics' => [{ 'name' => 'Avg Price', 'formula' => 'Avg([Price])' }, { 'name' => 'Sales Amount', 'formula' => 'Sum([Amount])' }] },
          { 'id' => 'g1', 'name' => 'Sales by month', 'source' => { 'kind' => 'table', 'elementId' => 'f1' },
            'columns' => [{ 'name' => 'Sales Amount', 'formula' => '[Metrics/Sales Amount]' }, { 'name' => 'Avg Price', 'formula' => '[Metrics/Avg Price]' },
                          { 'name' => 'Sales PY', 'formula' => 'DateLookback([Sales Amount], [Month], 1, "year")' }] }]
na_ti = [{ 'measure' => 'Sales.Sales PY', 'form' => 'grouped', 'element' => 'Sales by month', 'column' => 'Sales PY', 'kind' => 'py', 'period' => 'Month' }]
na_cls = { 'Sales.Sales PY' => { 'class' => 'C', 'home' => 'Sales', 'related' => [], 'userel' => nil }, 'Sales.Avg Price' => { 'class' => 'A', 'home' => 'Sales', 'related' => [], 'userel' => nil },
           'Sales.Sales Amount' => { 'class' => 'A', 'home' => 'Sales', 'related' => [], 'userel' => nil } }
na_sig = { 'pages' => [{ 'page_title' => 'P', 'visuals' => [
  { 'visual_id' => 'kpi', 'title' => 'KPI', 'visual_type' => 'card', 'bindings' => { 'Values' => ['Sales.Sales PY', 'Sales.Avg Price'] } },
  { 'visual_id' => 'mon', 'title' => 'By month', 'visual_type' => 'columnChart', 'bindings' => { 'Category' => ['Date.Month Start'], 'Y' => ['Sales.Sales PY', 'Sales.Avg Price'] } },
  { 'visual_id' => 'yr', 'title' => 'By year', 'visual_type' => 'columnChart', 'bindings' => { 'Category' => ['Date.Year'], 'Y' => ['Sales.Sales PY', 'Sales.Avg Price'] } },
  { 'visual_id' => 'add', 'title' => 'Additive KPI', 'visual_type' => 'card', 'bindings' => { 'Values' => ['Sales.Sales PY', 'Sales.Sales Amount'] } },
  { 'visual_id' => 'solo', 'title' => 'Avg only', 'visual_type' => 'card', 'bindings' => { 'Values' => ['Sales.Avg Price'] } }
] }] }
na = D.nonadditive_visuals(na_sig, na_cls, na_ti, ['Date'], na_els)
check(na.map { |h| h['visual_id'].to_s }.sort == %w[kpi yr], "a non-additive metric read through a grouped element with no axis at its grain is held back (kpi, year axis): #{na.map { |h| h['visual_id'] }.inspect}", fails)
check(na.all? { |h| h['reason'].include?('Avg Price') && h['reason'].include?('Sales by month') && h['reason'].include?(D::HELD_SUFFIX) }, "the reason names the metric and the element: #{na.first && na.first['reason']}", fails)
check(D.class_d_visuals(na_sig, na_cls, [], held: na).map { |h| h['visual_id'] }.sort == %w[kpi yr], 'class_d_visuals lists them', fails)
check(D.additive_metric?(na_els[0], 'Sales Amount') && !D.additive_metric?(na_els[0], 'Avg Price'), 'Sum is additive, Avg is not', fails)

puts "\ntest_slicer_warning_says_what_was_wired"
rolling_name = tmap['masters'].keys.find { |k| k.include?('rolling') }
check(tmap['masters'][rolling_name]['day_column'] == 'Day' && tmap['masters'][rolling_name]['date_tables'] == ['Date'], 'the rolling master records its day column and the date table', fails)
check(tmap['masters']['Sales by month']['day_column'].nil?, 'a grouped master has no day column (a Year slicer needs a Year level there)', fails)
lines = PbiReportBuild.unwired_slicer_lines('Year', 'Year', [rolling_name], tmap['masters'], 'Date')
check(lines.length == 1 && lines[0] !~ /NOT wired/ && lines[0].include?('wires it to them through a filter column over their day column') && lines[0].include?(rolling_name), "a date slicer on a rolling element is not reported NOT wired: #{lines.inspect}", fails)
lines = PbiReportBuild.unwired_slicer_lines('Year', 'Year', [rolling_name, 'Sales by month (quarter reset)'], tmap['masters'], 'date')
check(lines.length == 2 && lines[0].include?('Sales by month (quarter reset)') && lines[0].include?('NOT wired') && !lines[0].include?(rolling_name), "a master the shape pass does not wire still says NOT wired: #{lines.inspect}", fails)
lines = PbiReportBuild.unwired_slicer_lines('Region', 'Region', [rolling_name], tmap['masters'], 'Store')
check(lines.length == 1 && lines[0].include?('NOT wired') && lines[0].include?(rolling_name), "a non-date slicer on a rolling element is NOT wired: #{lines.inspect}", fails)
check(PbiReportBuild.unwired_slicer_lines('Year', 'Year', [], tmap['masters'], 'Date') == [], 'nothing unwired, nothing said', fails)

puts "\ntest_class_d_is_left_for_integrate"
imap = direct(inv)
check(imap['class_d_fields'].sort == %w[Inventory.Days\ of\ Cover Inventory.On\ Hand\ (Latest) Inventory.Products\ by\ Cover\ Bucket], "class D listed: #{imap['class_d_fields'].inspect}", fails)
check(imap['class_d_fields'].none? { |k| imap['fields'].key?(k) }, 'class D has no field entry', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_field_keys_match_pbir_query_refs"
unresolved = []
{ ['sales', 'signals.json'] => sales, ['sales', 'signals-trends.json'] => trends, ['inventory', 'signals.json'] => inv }.each do |(fx, file), ctx|
  fmap = direct(ctx)['fields']
  classes = ctx[:log]['classes']
  ctx[:signals]['pages'].each do |pg|
    pg['visuals'].each do |v|
      next if PbiMeasureClass.classify_visual(v, classes) == 'D'
      v['bindings'].values.flatten.compact.each do |ref|
        unresolved << "#{fx}/#{file}: #{pg['page_title']} / #{v['title']}: #{ref}" unless fmap.key?(ref)
      end
    end
  end
end
check(unresolved.reject { |u| u.start_with?('inventory/') }.empty?, "every queryRef of the sales reports resolves (#{unresolved.reject { |u| u.start_with?('inventory/') }.inspect})", fails)
check(unresolved.empty?, "no unresolved queryRef on any fixture report (#{unresolved.inspect})", fails)
check(imap['unresolved'].empty?, 'the map reports nothing unresolved', fails)

puts "\ntest_open_po_units_is_built_from_a_dropped_class_a_measure"
po = S.elements_of(inv[:dm]).find { |e| e['name'] == 'Purchase Orders' }
opu = po['metrics'].to_a.find { |x| x['name'] == 'Open PO Units' }
check(opu && opu['formula'] == 'SumIf(Coalesce([Ordered Units], 0) - Coalesce([Received Units], 0), Lower([Status]) = Lower("Open"))', "Open PO Units is a SumIf metric on Purchase Orders: #{opu.inspect}", fails)
check(inv[:log]['b_metrics']['built'] == ['Inventory.Open PO Units'], 'it is the one metric built', fails)
check(imap['fields']['Inventory.Open PO Units'] == { 'master' => 'Purchase Orders', 'ref' => '[Metrics/Open PO Units]', 'agg' => nil, 'formula' => '[Metrics/Open PO Units]' }, 'it resolves in the direct map on the Purchase Orders master', fails)
check(S.method(:build_b_metrics!) && S.respond_to?(:build_missing_metrics!), 'build_b_metrics! stays as an alias', fails)
bad = JSON.parse(JSON.generate(inv[:tmsl]))
bad['model']['tables'].find { |t| t['name'] == 'Inventory' }['measures'].find { |x| x['name'] == 'Open PO Units' }['expression'] =
  "CALCULATE(SUMX('Purchase Orders', 'Purchase Orders'[Ordered Units] - 'Purchase Orders'[Received Units]), FILTER('Purchase Orders', 'Purchase Orders'[Status] = \"Open\"))" if bad['model']
dmx = load_json('inventory', 'dm-raw.json')
lx = S.apply!(dmx, tmsl: bad['model'] ? bad : inv[:tmsl], signals: inv[:signals], dialect: 'snowflake')
check(lx['classes']['Inventory.Open PO Units']['class'] == 'D' || lx['reclassified']['b'].any? { |r| r['key'] == 'Inventory.Open PO Units' && r['reason'].start_with?('A form not translatable:') },
      "an untranslatable class A measure is reclassified D with a reason, not dropped: #{lx['reclassified'].inspect}", fails)

puts "\ntest_r51_converter_built_class_a_metric_is_rebuilt"
sa = S.elements_of(sales[:dm]).find { |e| e['name'] == 'Sales' }['metrics']
want = 'Sum(Coalesce([Quantity], 0) * Coalesce([Unit Price], 0) * (1 - Coalesce([Discount], 0)))'
check(sa.find { |x| x['name'] == 'Sales Amount' }['formula'] == want, 'Sales Amount carries the Coalesce form', fails)
check(sales[:log]['rebuilt_a'] == [{ 'measure' => 'Sales.Sales Amount', 'from' => 'Sum([Quantity] * [Unit Price] * (1 - [Discount]))', 'to' => want }], "rebuilt_a logs the replacement: #{sales[:log]['rebuilt_a'].inspect}", fails)
check(sales[:log]['rebuilt_a_skipped'] == [], 'nothing skipped', fails)
check(sa.find { |x| x['name'] == 'Gross Margin' }['formula'] == 'If(IsNull([Metrics/Sales Amount]) and IsNull([Metrics/Cost]), Null, Coalesce([Metrics/Sales Amount], 0) - Coalesce([Metrics/Cost], 0))' && sa.find { |x| x['name'] == 'GM %' }['formula'].include?('[Metrics/Sales Amount]'), 'Gross Margin and GM % still reference Sales Amount (qualified [Metrics/...] since cd32d2a12; I1: blank-as-0 between metrics)', fails)
check(sa.find { |x| x['name'] == 'Cost' }['formula'] == 'Sum([Quantity] * [Unit Cost])' && sa.find { |x| x['name'] == 'Units' }['formula'] == 'Sum([Quantity])', 'metrics without + or - are untouched', fails)
check(sa.find { |x| x['name'] == 'Private Label Sales' }['formula'] !~ /Coalesce\(Coalesce/, 'the coalesce is not applied twice', fails)
check(sa.map { |x| x['id'] }.uniq.length == sa.length && sa.count { |x| x['name'] == 'Sales Amount' } == 1, 'ids and names kept, no duplicate', fails)

puts "\ntest_r52_division_rows_and_two_pass_order"
check(S.division_arith?('[a] / [b] - [c]') && S.division_arith?('([a] - [b]) / 2') && !S.division_arith?('[a] / [b]') && !S.division_arith?('[a] * [b] / 2') && !S.division_arith?('[a] / 2 - 1') && !S.division_arith?('[SKU/Product/x] - 1'), 'division_arith?: / with a binary +/- over 2+ columns only', fails)
dmd = load_json('sales', 'dm-raw.json')
tmd = load_json('sales', 'model.bim')
tmd['model']['tables'].find { |t| t['name'] == 'Sales' }['measures'].find { |x| x['name'] == 'Units' }['expression'] = 'SUMX(Sales, (Sales[Quantity] - Sales[Discount]) / 2)'
tmd['model']['tables'].find { |t| t['name'] == 'Sales' }['measures'].find { |x| x['name'] == 'Cost' }['expression'] = 'SUMX(Sales, Sales[Quantity] / 2)'
ld = S.apply!(dmd, tmsl: tmd, signals: load_json('sales', 'signals.json'), dialect: 'snowflake')
sm = S.elements_of(dmd).find { |e| e['name'] == 'Sales' }['metrics']
check(ld['rebuilt_a_skipped'] == [{ 'measure' => 'Sales.Units', 'reason' => 'blank arithmetic with division' }], "a converter metric with / and a binary - keeps its formula and is logged: #{ld['rebuilt_a_skipped'].inspect}", fails)
check(sm.find { |x| x['name'] == 'Units' }['formula'] == 'Sum([Quantity])' && ld['classes']['Sales.Units']['class'] == 'A', 'it is not reclassified', fails)
check(sm.find { |x| x['name'] == 'Cost' }['formula'] == 'Sum([Quantity] * [Unit Cost])', 'a division-only row is left alone (not in rebuilt_a_skipped)', fails)
dmq = load_json('inventory', 'dm-raw.json')
tmq = load_json('inventory', 'model.bim')
tmq['model']['tables'].find { |t| t['name'] == 'Inventory' }['measures'].find { |x| x['name'] == 'Open PO Units' }['expression'] =
  "CALCULATE(SUMX('Purchase Orders', ('Purchase Orders'[Ordered Units] - 'Purchase Orders'[Received Units]) / 2), 'Purchase Orders'[Status] = \"Open\")"
lq = S.apply!(dmq, tmsl: tmq, signals: load_json('inventory', 'signals.json'), dialect: 'snowflake')
check(lq['reclassified']['b'].any? { |r| r['key'] == 'Inventory.Open PO Units' && r['reason'] == 'A form not translatable: blank arithmetic with division' }, 'the Sigma translator reclassifies a division row D', fails)
require_relative 'lib/pbi_time_intel_gen'
fact = S.elements_of(sales[:dm]).find { |e| e['name'] == 'Sales' }
raised = begin
  PbiTimeIntelGen.base_aggregate(sales[:dm], fact, { 'base_expr' => 'SUMX(Sales, (Sales[Quantity] - Sales[Discount]) / 2)' }, 'Sales')
  nil
rescue PbiTimeIntelGen::Unbuildable => e
  e.message
end
check(raised == 'blank arithmetic with division', "the rolling/time-intel base refuses a division row: #{raised.inspect}", fails)
# order independence: a USERELATIONSHIP measure copies the rebuilt class A formula whatever the class order
dmo = load_json('sales', 'dm-raw.json')
tmo = load_json('sales', 'model.bim')
sgo = load_json('sales', 'signals.json')
tfo = S.table_for_elements(dmo, tmo)
S.drop_views!(dmo)
ero = S.rename_elements!(dmo, tfo)
cro = S.rename_columns!(dmo, tmo, tfo)
S.rewrite_refs!(dmo, ero, cro)
S.relationships!(dmo, tmo, tfo)
cls = PbiMeasureClass.classify_all(sgo, tmo, (tmo['model'] || tmo)['relationships'])
rev = cls.to_a.reverse.to_h
check(rev.keys.index('Sales.Sales by Ship Date') < rev.keys.index('Sales.Sales Amount'), 'the userel measure comes before its source in the reversed order', fails)
S.build_missing_metrics!(dmo, tmo, rev)
mo = S.elements_of(dmo).find { |e| e['name'] == 'Sales' }['metrics']
check(mo.find { |x| x['name'] == 'Sales by Ship Date' }['formula'] == want, "Sales by Ship Date has the coalesced formula: #{mo.find { |x| x['name'] == 'Sales by Ship Date' }['formula']}", fails)

puts "\ntest_r50_blank_arithmetic"
def r50_metric(expr, name)
  dm = load_json('inventory', 'dm-raw.json')
  tmsl = load_json('inventory', 'model.bim')
  tmsl['model']['tables'].find { |t| t['name'] == 'Inventory' }['measures'].find { |x| x['name'] == 'Open PO Units' }.merge!('expression' => expr, 'name' => name)
  sig = load_json('inventory', 'signals.json')
  sig['pages'][0]['visuals'].each { |v| v['bindings'].each { |k, refs| v['bindings'][k] = refs.map { |r| r == 'Inventory.Open PO Units' ? "Inventory.#{name}" : r } } }
  log = S.apply!(dm, tmsl: tmsl, signals: sig, dialect: 'snowflake')
  [dm, log, log['classes']["Inventory.#{name}"]]
end
dmr, _l, _c = r50_metric("SUMX('Purchase Orders', 'Purchase Orders'[Ordered Units] * 2)", 'Mult Only')
mult = S.elements_of(dmr).find { |e| e['name'] == 'Purchase Orders' }['metrics'].find { |x| x['name'] == 'Mult Only' }
check(mult && mult['formula'] == 'Sum([Ordered Units] * 2)', "a * row is unchanged: #{mult && mult['formula']}", fails)
dmr, _l, _c = r50_metric("SUMX('Purchase Orders', 'Purchase Orders'[Ordered Units] - 'Purchase Orders'[Received Units])", 'Net Units')
net = S.elements_of(dmr).find { |e| e['name'] == 'Purchase Orders' }['metrics'].find { |x| x['name'] == 'Net Units' }
check(net && net['formula'] == 'Sum(Coalesce([Ordered Units], 0) - Coalesce([Received Units], 0))', "a - row coalesces every column: #{net && net['formula']}", fails)
_dm, _l, c = r50_metric("AVERAGEX('Purchase Orders', 'Purchase Orders'[Ordered Units] - 'Purchase Orders'[Received Units])", 'Avg Net')
check(c['class'] == 'D' && c['reason'] == 'A form not translatable: blank arithmetic in a non-sum iterator', "AVERAGEX over [a] - [b] goes to D: #{c.inspect}", fails)
dmr, _l, c = r50_metric("AVERAGEX('Purchase Orders', 'Purchase Orders'[Ordered Units] * 2)", 'Avg Mult')
check(c['class'] == 'A', 'AVERAGEX over a * row stays A', fails)
require_relative 'lib/pbi_time_intel_gen'
sql = PbiTimeIntelGen.rolling_sql(fact_sql: 'SELECT 1', date_sql: 'SELECT 1', measure_sql: 'SUM(COALESCE(f."A", 0) - COALESCE(f."B", 0))', days: 7, dialect: 'sqlite')
check(sql.include?('SUM(COALESCE(f."A", 0) - COALESCE(f."B", 0))'), 'rolling SQL carries the COALESCE row through', fails)

puts "\ntest_apply_logs_the_table_for_summary"
tf_log = inv[:log]['table_for']
check(tf_log['elements'] == 12 && tf_log['attributed'] >= 10 && tf_log['unattributed'].is_a?(Array), "table_for summary: #{tf_log.inspect}", fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_userel_measure_routes_date_through_alt_relationship"
ship = { 'pages' => [
  { 'page_id' => 'ship', 'page_title' => 'Ship Month', 'visuals' => [
    { 'visual_id' => 's1', 'title' => 'Sales by ship month', 'bindings' => { 'Category' => ['Date.Month Start'], 'Y' => ['Sales.Sales by Ship Date'] } },
    { 'visual_id' => 's2', 'title' => 'Ship KPI', 'bindings' => { 'Values' => ['Sales.Sales by Ship Date'] } }
  ] },
  { 'page_id' => 'order', 'page_title' => 'Order Month', 'visuals' => [
    { 'visual_id' => 'o1', 'title' => 'Sales by month', 'bindings' => { 'Category' => ['Date.Month Start'], 'Y' => ['Sales.Sales Amount'] } }
  ] }
] }
sm = run('sales', ship)
smap = direct(sm)
pf = smap['page_fields']['Ship Month']
check(pf && pf['Date.Month Start'] && pf['Date.Month Start']['master'] == 'Sales', "the Ship Month page routes Date.Month Start: #{smap['page_fields'].inspect}", fails)
check(pf['Date.Month Start']['ref'] == "[#{smap['masters']['Sales']['id']}/Month Start (Date (ShipDateKey))]", "through Month Start (Date (ShipDateKey)): #{pf['Date.Month Start'].inspect}", fails)
check(smap['masters']['Sales']['columns'].find { |c| c['name'] == 'Month Start (Date (ShipDateKey))' }['formula'] == '[Sales/Date (ShipDateKey)/Month Start]', 'the routed column is the inactive relationship path', fails)
check(smap['page_fields']['Order Month'].nil? && smap['fields']['Date.Month Start']['ref'].end_with?('/Month Start]') && smap['fields']['Date.Month Start']['master'] == 'Date', 'other pages keep the active binding', fails)
check(smap['conflicts'].empty?, 'no conflict', fails)

# the same page also reads the field through the active relationship -> not routed, recorded
mixed = JSON.parse(JSON.generate(ship))
mixed['pages'][0]['visuals'] << { 'visual_id' => 's3', 'title' => 'Month slicer', 'bindings' => { 'Values' => ['Date.Month Start'] } }
mm = direct(run('sales', mixed))
check(mm['page_fields']['Ship Month'].nil?, 'a page that also reads the field through the active relationship is not routed', fails)
check(mm['conflicts'].any? { |c| c['page'] == 'Ship Month' && c['visual'] == 'Sales by ship month' && c['class'] == 'D' && c['reason'] =~ /active relationship/ }, "its userel visual is a class D conflict: #{mm['conflicts'].inspect}", fails)
# the shipped sales report mixes ship and order measures on one chart
shipping = direct(sales)
check(shipping['conflicts'].any? { |c| c['visual'] == 'Sales by ship month and order month' } && shipping['page_fields'].empty?, "the mixed ship/order chart is a conflict, nothing is routed: #{shipping['conflicts'].inspect}", fails)

puts "\ntest_builder_emits_a_metric_formula_for_a_class_a_kpi"
require 'open3'
require 'tmpdir'
require 'rbconfig'
Dir.mktmpdir do |d|
  out, st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'build-workbook-from-pbir.rb'),
                            '--signals', File.join(FIX, 'sales', 'signals.json'),
                            '--master-map', File.join(FIX, 'sales', 'master-map-direct.json'),
                            '--data-model', 'dm-x', '--name', 'T', '--out', File.join(d, 'wb.json'),
                            '--layout-out', File.join(d, 'l.xml'), '--coverage-out', File.join(d, 'cov.json'))
  check(st.success?, "the real builder runs on the direct map (#{out.lines.last.to_s.strip})", fails)
  doc = JSON.parse(File.read(File.join(d, 'wb.json')))['document']
  kpis = []
  walk = lambda do |o|
    case o
    when Hash then (kpis << o if o['kind'] == 'kpi-chart'; o.each_value { |v| walk.call(v) })
    when Array then o.each { |v| walk.call(v) }
    end
  end
  walk.call(doc)
  kpi = kpis.find { |k| k['name'] == 'Sales Amount' }
  vcol = kpi && kpi['columns'].find { |c| c['id'] == kpi.dig('value', 'columnId') }
  check(vcol && vcol['formula'] == '[Metrics/Sales Amount]', "the Sales Amount KPI's value is [Metrics/Sales Amount]: #{vcol.inspect}", fails)
  check(kpi && kpi['groupings'].nil? && kpi['columns'].none? { |c| c['formula'].to_s.start_with?('[master-') && c['formula'] !~ /Metrics/ }, 'and it is not a grouping dimension', fails)
end

puts "\ntest_direct_map_swaps_to_the_flattened_element"
ctxf = run('sales', 'signals.json', flatten: ['Sales'])
plain = direct(run('sales', 'signals.json'))
swapped = direct(ctxf, flattened: { 'Sales' => 'Sales (flattened)' })
sm = swapped['masters']['Sales']
check(sm && sm['element_name'] == 'Sales (flattened)', "the Sales master reads Sales (flattened): #{sm && sm['element_name']}", fails)
check(sm['id'] == plain['masters']['Sales']['id'], 'the master id is unchanged, so refs stay valid', fails)
check(!swapped['masters'].key?('Sales (flattened)') && swapped['fields'].keys.none? { |k| k.start_with?('Sales (flattened).') }, "the flattened element has no master or fields of its own", fails)
check(sm['columns'].any? { |c| c['name'] == 'Brand (Product)' && c['formula'] == '[Sales (flattened)/Brand (Product)]' }, 'the master carries the flattened Lookup columns', fails)
brand = swapped['fields']['Product.Brand']
check(brand && Array(brand['alts']).any? { |a| a['master'] == 'Sales' && a['ref'] == "[#{sm['id']}/Brand (Product)]" }, "Product.Brand is read from the flattened Lookup column: #{brand.inspect}", fails)
check(swapped['fields']['Sales.Sales Amount']['master'] == 'Sales', 'measures keep the fact master', fails)
check(sm['metrics'].map { |m| m['name'] } == plain['masters']['Sales']['metrics'].map { |m| m['name'] }, 'and its metrics', fails)
seg = swapped['fields']['Customer.Segment']
check(seg && Array(seg['alts']).any? { |a| a['master'] == 'Sales' && a['ref'] == "[#{sm['id']}/Segment (Customer)]" },
      "a slicer-only field (Customer.Segment) keeps a route to the flattened Sales charts: #{seg.inspect}", fails)
check(swapped['conflicts'].none? { |c| c['field'].to_s.start_with?('Customer.') }, "and is not a conflict: #{swapped['conflicts'].select { |c| c['field'].to_s.start_with?('Customer.') }.inspect}", fails)
# a related field with no Lookup column is a recorded conflict, never silently dropped
ctxu = run('sales', 'signals.json', flatten: ['Sales'])
flat_el = S.elements_of(ctxu[:dm]).find { |e| e['name'] == 'Sales (flattened)' }
gone = flat_el['columns'].find { |c| c['name'] == 'Brand (Product)' }
flat_el['columns'].delete(gone)
flat_el['order'].delete(gone['id'])
flat_el['folders'].each { |f| f['items'].delete(gone['id']) }
lost = direct(ctxu, flattened: { 'Sales' => 'Sales (flattened)' })
check(lost['conflicts'].any? { |c| c['field'] == 'Product.Brand' && c['class'] == 'D' }, 'a field the flattened element cannot carry is recorded as a conflict', fails)
same = direct(ctxf)
check(same['masters'].key?('Sales (flattened)') && same['masters']['Sales']['element_name'] == 'Sales', 'without flattened: the maps are unchanged', fails)

puts "\ntest_pbi_class_d_pages_include_conflict_visuals"
# Task 21x: the Shipping page's D-ness is visual-level (an order-date measure and a ship-date measure on one Date axis);
# no measure on it is class D. The page is still a class D page.
sal = run('sales', 'signals.json')
check(sal[:log]['classes'].values.none? { |c| c['class'] == 'D' }, 'fixture: no sales measure is class D by itself', fails)
check(PbiShapeRun.class_d_pages(sal[:signals], sal[:log]['classes']) == ['Shipping'], "class_d_pages returns the page of a class D visual: #{PbiShapeRun.class_d_pages(sal[:signals], sal[:log]['classes']).inspect}", fails)
sdm = direct(sal)
cdv = sdm['class_d_visuals']
mixed_v = cdv.find { |c| c['visual'] == 'Sales by ship month and order month' }
check(mixed_v && mixed_v['page'] == 'Shipping' && mixed_v['visual_id'].to_s != '', "class_d_visuals lists the mixed ship/order chart with its visual id: #{cdv.inspect}", fails)
check(mixed_v && mixed_v['reason'] =~ /two relationship paths to Date: .*active.*ShipDateKey.*Sigma reads one path per element/, "with the reason: #{mixed_v && mixed_v['reason']}", fails)
check(sdm['conflicts'].all? { |c| c['visual_id'].to_s != '' }, 'conflict records carry the visual id', fails)
conf_only = [{ 'page' => 'Shipping', 'visual' => 'Chart X', 'visual_id' => 'vx', 'field' => 'Date.Month', 'class' => 'D', 'reason' => 'page Shipping also reads Date.Month through the active relationship' }]
check(PbiShapeRun.class_d_pages(sal[:signals], {}, conflict_only = conf_only) == ['Shipping'], 'a conflict record alone makes its page a class D page', fails)
check(PbiShapeRun.class_d_pages(sal[:signals], {}) == [], 'no classes and no conflicts: no class D page', fails)

# ---------------------------------------------------------------------------------------------------
# Final review fixes (Fix A): C1 as-of, I2 date fields, I3 USERELATIONSHIP controls, I4 CALCULATE override, C2 page filters, m7
def deep(h)
  JSON.parse(JSON.generate(h))
end

def held_ids(map, page = nil)
  map['class_d_visuals'].select { |h| page.nil? || h['page'] == page }.map { |h| h['visual_id'] }
end

def with_visual(signals, page_title, visual)
  sg = deep(signals)
  pg = sg['pages'].find { |p| p['page_title'] == page_title }
  pg['visuals'] << visual
  sg
end

puts "\ntest_c1_as_of_metric_ignores_date_table_picks"
c1 = run('sales', 'signals-trends.json')
c1m = direct(c1)
check(held_ids(c1m, 'Trends').include?('TrYtdLine'), "C1: the chart that binds the as-of YTD with a month axis is held back (#{held_ids(c1m, 'Trends').inspect})", fails)
tr_reason = c1m['class_d_visuals'].find { |h| h['visual_id'] == 'TrYtdLine' }['reason']
check(tr_reason.include?('as-of') && tr_reason.include?('Date.Month Start'), "and says why (#{tr_reason})", fails)
check(!held_ids(c1m, 'Trends').include?('TrAsOf'), 'the as-of KPI (no date field) keeps its element', fails)
check(c1m['asof_ignore_date'] == [{ 'page' => 'Trends', 'visual' => 'TrAsOf', 'visual_id' => 'TrAsOf' }] || c1m['asof_ignore_date'].map { |x| x['visual_id'] } == ['TrAsOf'],
      "C1: the Year slicer is not targeted at the as-of-only KPI (#{c1m['asof_ignore_date'].inspect})", fails)
check(c1m['masters']['Date']['date_columns'].include?('Year') && c1m['masters']['Sales']['date_columns'].include?('Year (Date)'), 'the masters list their date-table columns (the workbook pass skips only those)', fails)
no_slicer = deep(c1[:signals])
no_slicer['pages'].find { |p| p['page_title'] == 'Trends' }['visuals'].reject! { |v| v['visual_id'] == 'TrYear' }
nm = direct(run('sales', no_slicer))
check(nm['asof_ignore_date'].empty? && !held_ids(nm, 'Trends').include?('TrAsOf'), 'C1: a no-axis as-of KPI with no date control stays exactly as it is', fails)
mixed = with_visual(c1[:signals], 'Trends', { 'visual_id' => 'MixTbl', 'visual_type' => 'tableEx', 'sigma_kind' => 'table', 'title' => 'Mixed', 'bindings' => { 'Values' => ['Sales.Sales Amount', 'Sales.Sales YTD (As Of)'] } })
mm = direct(run('sales', mixed))
check(held_ids(mm, 'Trends').include?('MixTbl'), 'C1: a visual that mixes as-of with a date-responsive measure under a date control is held back', fails)
rep = deep(c1[:signals])
rep['filters'] = [{ 'scope' => 'report', 'target' => 'Date.Year', 'type' => 'list', 'mode' => 'include', 'values' => [2025] }]
rm = direct(run('sales', rep))
check(held_ids(rm, 'Trends').include?('TrAsOf') && rm['asof_ignore_date'].empty?, 'C1: a report-level Date filter cannot be kept off the as-of KPI: it is held back', fails)
vf = deep(c1[:signals])
vf['pages'].find { |p| p['page_title'] == 'Trends' }['visuals'].find { |v| v['visual_id'] == 'TrAsOf' }['filters'] = [{ 'scope' => 'visual', 'target' => 'Date.Year', 'type' => 'list', 'mode' => 'include', 'values' => [2025] }]
check(held_ids(direct(run('sales', vf)), 'Trends').include?('TrAsOf'), 'C1: a visual-level Date filter on the as-of KPI holds it back', fails)

puts "\ntest_c1_inline_skips_date_controls_for_as_of_only_elements"
require_relative 'lib/pbi_direct_sources'
masters_c1 = { 'Sales' => { 'id' => 'm-sales', 'direct' => true, 'element_name' => 'Sales', 'date_columns' => ['Year (Date)'],
                            'columns' => [{ 'id' => 'mc-y', 'name' => 'Year (Date)', 'formula' => '[Sales/Date/Year]' }, { 'id' => 'mc-r', 'name' => 'Region', 'formula' => '[Sales/Store/Region]' }],
                            'metrics' => [] } }
de = { 'id' => 'm-sales', 'columns' => masters_c1['Sales']['columns'].map { |c| c.dup }, 'source' => { 'kind' => 'data-model', 'dataModelId' => 'd', 'elementId' => 'e' } }
mk_pages = lambda do
  [{ 'id' => 'p', 'name' => 'P', 'elements' => [
    { 'id' => 'ctl-y', 'kind' => 'control', 'controlId' => 'Year', 'controlType' => 'list', 'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-sales' }, 'columnId' => 'mc-y' }] },
    { 'id' => 'ctl-r', 'kind' => 'control', 'controlId' => 'Region', 'controlType' => 'list', 'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-sales' }, 'columnId' => 'mc-r' }] },
    { 'id' => 'asof', 'kind' => 'kpi-chart', 'source' => { 'kind' => 'table', 'elementId' => 'm-sales' }, 'columns' => [] },
    { 'id' => 'plain', 'kind' => 'kpi-chart', 'source' => { 'kind' => 'table', 'elementId' => 'm-sales' }, 'columns' => [] }
  ] }]
end
pages_c1 = mk_pages.call
out_c1 = PbiDirectSources.inline!(pages_c1, [Marshal.load(Marshal.dump(de))], masters_c1, 'd', { 'asof' => true })
fy = pages_c1[0]['elements'].find { |e| e['id'] == 'ctl-y' }['filters'].map { |f| f['source']['elementId'] }
fr = pages_c1[0]['elements'].find { |e| e['id'] == 'ctl-r' }['filters'].map { |f| f['source']['elementId'] }
check(fy == ['plain'] && fr.sort == %w[asof plain], "C1: the Year control reaches only the date-responsive element; the Region control reaches both (#{fy.inspect}, #{fr.inspect})", fails)
check(out_c1['date_ignored'].map { |d| [d['controlId'], d['element']] } == [%w[Year asof]], "and the skipped pair is reported (#{out_c1['date_ignored'].inspect})", fails)
pages_none = mk_pages.call
PbiDirectSources.inline!(pages_none, [Marshal.load(Marshal.dump(de))], masters_c1, 'd')
check(pages_none[0]['elements'].find { |e| e['id'] == 'ctl-y' }['filters'].map { |f| f['source']['elementId'] }.sort == %w[asof plain], 'with no ignore list every element is targeted (unchanged)', fails)

puts "\ntest_i2_date_fields_bind_only_when_provably_equal"
tfi = c1m['fields']
bind = ->(f, master) { Array(tfi[f]['alts']).find { |a| a['master'] == master }&.dig('ref').to_s }
mid_m = c1m['masters']['Sales by month']['id']
check(bind.call('Date.Year', 'Sales by month') == "[#{mid_m}/Year Number]", "I2: the integer Year field reads the element's Year Number column, not the DateTrunc date (#{bind.call('Date.Year', 'Sales by month')})", fails)
check(bind.call('Date.Quarter', 'Sales by month') == "[#{mid_m}/Quarter Number]", 'the integer Quarter field reads Quarter Number', fails)
check(bind.call('Date.Month Number', 'Sales by month') == "[#{mid_m}/Month Number]", 'Month Number reads Month Number', fails)
check(bind.call('Date.Month Start', 'Sales by month') == "[#{mid_m}/Month]", 'the calculated Month Start (DATE(YEAR(d), MONTH(d), 1)) reads the DateTrunc month', fails)
check(Array(tfi['Date.Month Name']['alts']).none? { |a| a['master'] == 'Sales by month' }, 'a month NAME has no alt on the element', fails)
fy_tmsl = deep(c1[:tmsl])
fy_tmsl['model']['tables'].find { |t| t['name'] == 'Date' }['columns'] << { 'name' => 'Fiscal Year', 'dataType' => 'int64', 'sourceColumn' => 'FY' }
fy_tmsl['model']['tables'].find { |t| t['name'] == 'Date' }['columns'] << { 'name' => 'Month Label', 'dataType' => 'dateTime', 'sourceColumn' => 'ML' }
fy_sig = with_visual(c1[:signals], 'Trends', { 'visual_id' => 'FyChart', 'visual_type' => 'lineChart', 'sigma_kind' => 'line', 'title' => 'Fiscal', 'bindings' => { 'Category' => ['Date.Fiscal Year'], 'Y' => ['Sales.Sales YTD'] } })
fy_sig = with_visual(fy_sig, 'Trends', { 'visual_id' => 'QOnly', 'visual_type' => 'tableEx', 'sigma_kind' => 'table', 'title' => 'Quarter only', 'bindings' => { 'Values' => ['Date.Quarter', 'Sales.Sales YTD'] } })
fy_sig = with_visual(fy_sig, 'Trends', { 'visual_id' => 'YQ', 'visual_type' => 'tableEx', 'sigma_kind' => 'table', 'title' => 'Year and quarter', 'bindings' => { 'Values' => ['Date.Year', 'Date.Quarter', 'Sales.Sales YTD'] } })
fy_sig = with_visual(fy_sig, 'Trends', { 'visual_id' => 'Lbl', 'visual_type' => 'lineChart', 'sigma_kind' => 'line', 'title' => 'Unproven month', 'bindings' => { 'Category' => ['Date.Month Label'], 'Y' => ['Sales.Sales YTD'] } })
dm_fy = load_json('sales', 'dm-raw.json')
log_fy = S.apply!(dm_fy, tmsl: fy_tmsl, signals: fy_sig, native_result: nil, dialect: 'snowflake')
map_fy = D.build(dm_fy, readback(dm_fy), fy_tmsl, log_fy['classes'], time_intel: log_fy['time_intel'], signals: fy_sig)
h_fy = held_ids(map_fy, 'Trends')
check(h_fy.include?('FyChart') && h_fy.include?('Lbl'), "I2: a Fiscal Year or an unproven date column beside a time-intelligence measure is class D (#{h_fy.inspect})", fails)
check(h_fy.include?('QOnly') && !h_fy.include?('YQ'), 'a Quarter number with no Year is class D; Year and Quarter together are built', fails)
check(PbiShapeRun.grain_of_field('Fiscal Year').nil? && PbiShapeRun.grain_of_field('Year') == 'year' && PbiShapeRun.grain_of_field('Fiscal Quarter').nil?, 'I2: grain_of_field gives no grain to a fiscal column', fails)
check(PbiShapeRun.date_part_formula('Fiscal Year', '[x]').nil? && PbiShapeRun.date_part_formula('Year', '[x]') == 'Year([x])', 'I2: date_part_formula has no expression for a fiscal column', fails)
check(PbiShapeRun.date_part_formula('Month Start', '[x]', 'Date', c1[:tmsl]) == 'MakeDate(Year([x]), Month([x]), 1)' &&
      PbiShapeRun.date_part_formula('Month Start', '[x]', 'Date', fy_tmsl.tap { |t| t['model']['tables'].find { |x| x['name'] == 'Date' }['columns'].find { |c| c['name'] == 'Month Start' }.delete('expression') }).nil?,
      'with the model: a calculated Month Start has its expression; a physical one is unproven (nil)', fails)

puts "\ntest_i3_date_controls_follow_the_activated_path"
ship_sig = lambda do |extra|
  { 'filters' => [], 'pages' => [{ 'page_id' => 'ship', 'page_title' => 'Ship', 'filters' => [], 'visuals' => [
    { 'visual_id' => 'sl', 'visual_type' => 'slicer', 'sigma_kind' => 'control', 'bindings' => { 'Values' => ['Date.Year'] } },
    { 'visual_id' => 'k1', 'title' => 'Ship KPI', 'bindings' => { 'Values' => ['Sales.Sales by Ship Date'] } },
    { 'visual_id' => 'k2', 'title' => 'Ship by region', 'bindings' => { 'Category' => ['Store.Store Region'], 'Y' => ['Sales.Sales by Ship Date'] } }
  ] + extra }] }
end
i3 = direct(run('sales', ship_sig.call([])))
yr = (i3['page_fields']['Ship'] || {})['Date.Year']
check(yr && yr['ref'].include?('Year (Date (ShipDateKey))') && i3['conflicts'].empty?, "I3: a Year slicer next to ship-date visuals filters by SHIP year (#{yr.inspect})", fails)
i3b = direct(run('sales', ship_sig.call([{ 'visual_id' => 'k3', 'title' => 'Order KPI', 'bindings' => { 'Values' => ['Sales.Sales Amount'] } }])))
check(i3b['page_fields']['Ship'].nil? && i3b['conflicts'].map { |c| c['visual_id'] }.sort == %w[k1 k2] && held_ids(i3b, 'Ship').sort == %w[k1 k2],
      "I3: a Year control that also reaches an active-path visual holds the USERELATIONSHIP visuals back (#{i3b['conflicts'].map { |c| c['visual_id'] }.inspect})", fails)
pf = ship_sig.call([])
pf['pages'][0]['visuals'].reject! { |v| v['visual_id'] == 'sl' }
pf['pages'][0]['filters'] = [{ 'scope' => 'page', 'target' => 'Date.Year', 'type' => 'list', 'mode' => 'include', 'values' => [2025] }]
i3c = direct(run('sales', pf))
check(((i3c['page_fields']['Ship'] || {})['Date.Year'] || {})['ref'].to_s.include?('ShipDateKey'), 'I3: a page filter on Date.Year is routed the same way', fails)
rf = ship_sig.call([])
rf['filters'] = [{ 'scope' => 'report', 'target' => 'Date.Year', 'type' => 'list', 'mode' => 'include', 'values' => [2025] }]
i3d = direct(run('sales', rf))
check(held_ids(i3d, 'Ship').sort == %w[k1 k2], 'I3: a report-level Date filter reaches the USERELATIONSHIP visuals through the active path: held back', fails)

puts "\ntest_i4_calculate_filter_override"
class_pl = run('sales', 'signals.json')[:log]['classes']['Sales.Private Label Sales']
check(class_pl['filter_columns'] == [%w[Product Private\ Label]], "I4: the class entry records the CALCULATE filter column (#{class_pl['filter_columns'].inspect})", fails)
check(run('sales', 'signals.json')[:log]['classes']['Sales.Sales Amount']['filter_columns'] == [], 'a measure without a CALCULATE filter records none', fails)
i4_sig = lambda do |slicer_page, report|
  { 'filters' => report, 'pages' => [
    { 'page_id' => 'p1', 'page_title' => 'P1', 'filters' => [], 'visuals' => [
      { 'visual_id' => 'ax', 'title' => 'By private label', 'bindings' => { 'Category' => ['Product.Private Label'], 'Y' => ['Sales.Private Label Sales'] } },
      { 'visual_id' => 'br', 'title' => 'By brand', 'bindings' => { 'Category' => ['Product.Brand'], 'Y' => ['Sales.Private Label Sales'] } },
      { 'visual_id' => 'kp', 'title' => 'KPI', 'bindings' => { 'Values' => ['Sales.Private Label Sales'] } }
    ] },
    { 'page_id' => 'p2', 'page_title' => 'P2', 'filters' => [], 'visuals' => ([{ 'visual_id' => 'sl', 'visual_type' => 'slicer', 'sigma_kind' => 'control',
                                                                              'bindings' => { 'Values' => [slicer_page] } }] +
      [{ 'visual_id' => 'k2', 'title' => 'PL KPI', 'bindings' => { 'Values' => ['Sales.Private Label Sales'] } },
       { 'visual_id' => 'k3', 'title' => 'Sales KPI', 'bindings' => { 'Values' => ['Sales.Sales Amount'] } }]) }
  ] }
end
i4 = direct(run('sales', i4_sig.call('Product.Private Label', [])))
check(held_ids(i4, 'P1') == ['ax'], "I4: only the visual that binds the filtered column on an axis is held on P1 (#{held_ids(i4, 'P1').inspect})", fails)
check(held_ids(i4, 'P2') == ['k2'], "I4: a slicer on the filtered column holds the visual that reads the measure (#{held_ids(i4, 'P2').inspect})", fails)
check(i4['class_d_visuals'].find { |h| h['visual_id'] == 'ax' }['reason'].include?('every Private Label member'), 'the axis reason names the repeated value', fails)
i4r = direct(run('sales', i4_sig.call('Product.Brand', [{ 'scope' => 'report', 'target' => 'Product.Private Label', 'type' => 'list', 'mode' => 'include', 'values' => [true] }])))
check(held_ids(i4r).sort == %w[ax br k2 kp], "I4: a report filter on the filtered column holds every visual reading the measure (#{held_ids(i4r).sort.inspect})", fails)

puts "\ntest_m7_rolling_day_column_is_matched_by_name"
m7 = run('sales', 'signals-trends.json')
roll7 = S.elements_of(m7[:dm]).find { |e| e['name'].to_s.include?('rolling') }
roll7['columns'].find { |c| S.display_name(c) == 'Day' }['name'] = 'Calendar Day'
raised7 = begin; direct(m7); nil; rescue ArgumentError => e; e.message; end
check(raised7.to_s.include?('no Day column'), "m7: a rolling element without a Day column raises (no silent Max fallback): #{raised7.inspect}", fails)

puts "\ntest_c2_page_filter_on_a_rolling_page"
cp = deep(c1[:signals])
roll_pg = cp['pages'].find { |p| p['page_title'] == 'Rolling' }
roll_pg['filters'] = [{ 'scope' => 'page', 'target' => 'Store.Store Region', 'type' => 'list', 'mode' => 'include', 'values' => ['West'] }]
cm = direct(run('sales', cp))
held_c2 = PbiDirectMap.rolling_filter_visuals(cp, c1[:log]['classes'], c1[:log]['time_intel'], cm)
check(held_c2.map { |h| h['visual_id'] }.sort == %w[RoByCustRegion RoByDay RoByStore RoR28], "C2: a page filter on a field the rolling element does not carry holds back its readers (#{held_c2.map { |h| h['visual_id'] }.inspect})", fails)
check(held_c2.all? { |h| h['reason'].include?('Store.Store Region') && h['reason'].include?('held back') }, 'with the field and the reason', fails)
rk = cm['masters'].find { |_k, m| m['element_name'].to_s.include?('rolling') }.first
PbiDirectMap.add_alt(cm['fields']['Store.Store Region'], 'master' => rk, 'ref' => '[x/Store Region]', 'agg' => nil)
check(PbiDirectMap.rolling_filter_visuals(cp, c1[:log]['classes'], c1[:log]['time_intel'], cm).empty?, 'C2: a filter on a carried field reaches the rolling element: nothing held', fails)
cp['pages'].find { |p| p['page_title'] == 'Rolling' }['filters'] = [{ 'scope' => 'page', 'target' => 'Date.Year', 'type' => 'list', 'mode' => 'include', 'values' => [2025] }]
check(PbiDirectMap.rolling_filter_visuals(cp, c1[:log]['classes'], c1[:log]['time_intel'], cm).length == 4, 'C2: a Date-table page filter is replaced inside the window by Power BI: its readers are held back', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.length} FAILED:"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
