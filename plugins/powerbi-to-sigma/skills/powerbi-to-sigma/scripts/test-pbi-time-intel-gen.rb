#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for lib/pbi_time_intel_gen.rb (Power BI-shaped model mode, task 12): the Sigma form of each
# class C time-intelligence measure -- as-of metric (P8a), grouped element (P8b/P15/P16), rolling N days
# over a dense spine (P8c) -- and the reclassification of anything that is not exact.
#
# Fixtures: fixtures/pbi-shaped/sales (placeholder Snowflake coordinates only). Synthetic names only.
# No network. The rolling SQL is run in Python's stdlib sqlite3 (dialect 'sqlite', test-only).
# Run: ruby scripts/test-pbi-time-intel-gen.rb
require 'json'
require 'open3'
require 'date'
require_relative 'lib/pbi_shaped_model'
require_relative 'lib/pbi_measure_class'
require_relative 'lib/pbi_time_intel_gen'

FIX = File.join(File.dirname(__dir__), 'fixtures', 'pbi-shaped')
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'
G = PbiTimeIntelGen
S = PbiShapedModel

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def load_json(*parts)
  JSON.parse(File.read(File.join(FIX, *parts)))
end

# The real pipeline up to the point this task runs: drop Views, rename, name relationships, classify, build
# the B metrics, split the facts that need it. `signals` picks the fixture's report (trends has the class C).
def setup(signals_file: 'signals-trends.json', split: false)
  dm = load_json('sales', 'dm-raw.json')
  tmsl = load_json('sales', 'model.bim')
  signals = load_json('sales', signals_file)
  table_for = S.table_for_elements(dm, tmsl)
  S.drop_views!(dm)
  er = S.rename_elements!(dm, table_for)
  cr = S.rename_columns!(dm, tmsl, table_for)
  S.rewrite_refs!(dm, er, cr)
  S.relationships!(dm, tmsl, table_for)
  classes = PbiMeasureClass.classify_all(signals, tmsl, (tmsl['model'] || tmsl)['relationships'])
  S.build_b_metrics!(dm, tmsl, classes)
  S.split_facts!(dm, classes) if split
  [dm, tmsl, classes]
end

def c_entries(classes)
  classes.select { |_k, v| v['class'] == 'C' }.map { |k, v| v.merge('key' => k) }
end

def element(dm, name)
  S.elements_of(dm).find { |e| e['name'] == name }
end

def col_formula(el, name)
  (el['columns'] || []).find { |c| S.display_name(c) == name }&.dig('formula')
end

def gen(dm, tmsl, entries, **kw)
  G.generate!(dm, entries, date_element: 'Date', dialect: 'snowflake', tmsl: tmsl, **kw)
end

def only(entries, *names)
  entries.select { |e| names.include?(e['key'].split('.', 2)[1]) }
end

# ---------------------------------------------------------------------------------------------------
puts "\ntest_as_of_ytd_becomes_metric"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD (As Of)'))
sales = element(dm, 'Sales')
metric = sales['metrics'].find { |m| m['name'] == 'Sales YTD (As Of)' }
check(res.length == 1 && res[0]['form'] == 'metric' && res[0]['element'] == 'Sales' && res[0]['column'] == 'Sales YTD (As Of)', "one metric entry (#{res.map { |r| r['form'] }.inspect})", fails)
check(res.reclassified.empty?, 'nothing reclassified', fails)
check(col_formula(sales, 'Date (Date)') == 'Lookup([Date/Date], [OrderDateKey], [Date/DateKey])', "date comes through the active date relationship: #{col_formula(sales, 'Date (Date)')}", fails)
check(col_formula(sales, 'One') == '1' && col_formula(element(dm, 'As Of'), 'One') == '1', 'One = 1 on the fact and on As Of', fails)
check(col_formula(sales, 'As Of Date') == 'Lookup([As Of/As Of Date], [One], [As Of/One])', "as-of date by constant-key Lookup: #{col_formula(sales, 'As Of Date')}", fails)
check(metric && metric['formula'] == 'SumIf(Coalesce([Quantity], 0) * Coalesce([Unit Price], 0) * (1 - Coalesce([Discount], 0)), [Date (Date)] >= DateTrunc("year", [As Of Date]) and [Date (Date)] <= [As Of Date])', "SumIf metric on the fact: #{metric && metric['formula']}", fails)
check(metric['format'] == sales['metrics'].find { |m| m['name'] == 'Sales Amount' }['format'], 'metric keeps the base metric format', fails)
check(!Array(element(dm, 'Date')['relationships']).any? { |r| r['targetElementId'] == element(dm, 'As Of')['id'] } && sales['relationships'].none? { |r| r['name'] == 'As Of' }, 'no relationship to As Of is needed', fails)
before = JSON.generate(dm)
res2 = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD (As Of)'))
check(JSON.generate(dm) == before && res2.length == 1, 'a second run adds nothing', fails)

# QTD / MTD as-of reuse the same lookups and use quarter / month
dm_q, tmsl_q, classes_q = setup
%w[qtd mtd].each do |pat|
  entry = c_entries(classes_q).find { |e| e['key'] == 'Sales.Sales YTD (As Of)' }.merge('key' => "Sales.AsOf #{pat.upcase}")
  entry['ti'] = entry['ti'].merge('pattern' => pat)
  entry['expression'] = 'CALCULATE([Sales Amount], DATESBETWEEN(x))'
  r = G.generate!(dm_q, [entry], date_element: 'Date', dialect: 'snowflake')
  f = element(dm_q, 'Sales')['metrics'].find { |m| m['name'] == "AsOf #{pat.upcase}" }
  check(r.length == 1 && f && f['formula'].include?("DateTrunc(\"#{pat == 'qtd' ? 'quarter' : 'month'}\", [As Of Date])"), "as-of #{pat.upcase} truncates to the #{pat == 'qtd' ? 'quarter' : 'month'}", fails)
end
check(element(dm_q, 'Sales')['columns'].count { |c| S.display_name(c) == 'As Of Date' } == 1, 'the as-of Lookup is shared by YTD, QTD and MTD', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_axis_ytd_and_py_share_one_grouped_element_per_grain"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD', 'Sales PY', 'Sales YoY %'))
by = res.map { |r| [r['measure'], r] }.to_h
check(res.length == 3 && res.all? { |r| r['form'] == 'grouped' && r['consumer_agg'] == 'Max' }, 'three grouped entries, consumers read with Max', fails)
check(by['Sales.Sales YTD']['kind'] == 'ytd' && by['Sales.Sales PY']['kind'] == 'py' && by['Sales.Sales YoY %']['kind'] == 'yoy' && by.values.all? { |r| r['period'] == 'Month' && !r.key?('whole') }, 'each record says its kind and period column, none is a whole-period form', fails)
check(by['Sales.Sales YoY %']['yoy'] == { 'base' => 'Sales Amount', 'prior' => 'Sales PY' }, "YoY % names the base and prior columns it is rebuilt from: #{by['Sales.Sales YoY %']['yoy'].inspect}", fails)
check(by['Sales.Sales YTD']['element'] == 'Sales by month' && by['Sales.Sales PY']['element'] == 'Sales by month' && by['Sales.Sales YoY %']['element'] == 'Sales by month', 'YTD, PY and YoY % all land on "Sales by month"', fails)
check(S.elements_of(dm).count { |e| e['name'] == 'Sales by month' } == 1, 'exactly one such element', fails)
el = element(dm, 'Sales by month')
sales = element(dm, 'Sales')
check(el['source'] == { 'kind' => 'table', 'elementId' => sales['id'] }, 'it is a child of the Sales element', fails)
check(col_formula(el, 'Year') == 'DateTrunc("year", [Sales/Date (Date)])' && col_formula(el, 'Month') == 'DateTrunc("month", [Sales/Date (Date)])', 'Year and Month columns truncate the looked-up date', fails)
check(col_formula(el, 'Sales Amount') == '[Metrics/Sales Amount]', "base read from the parent metric: #{col_formula(el, 'Sales Amount')}", fails)
check(col_formula(el, 'Sales YTD') == 'CumulativeSum([Sales Amount])', "YTD: #{col_formula(el, 'Sales YTD')}", fails)
check(col_formula(el, 'Sales PY') == 'DateLookback([Sales Amount], [Month], 1, "year")', "PY: #{col_formula(el, 'Sales PY')}", fails)
check(col_formula(el, 'Sales YoY %') == '([Sales Amount] - [Sales PY]) / NullIf([Sales PY], 0)', "YoY %: #{col_formula(el, 'Sales YoY %')}", fails)
ids = el['columns'].map { |c| [S.display_name(c), c['id']] }.to_h
g = el['groupings']
check(g.length == 2 && g[0]['groupBy'] == [ids['Year']] && g[0]['calculations'].nil?, 'Year is its own outer level with no calculations', fails)
check(g[1]['groupBy'] == [ids['Month']] && g[1]['calculations'].sort == %w[Sales\ Amount Sales\ YTD Sales\ PY Sales\ YoY\ % Year\ Number Quarter\ Number Month\ Number].map { |n| ids[n] }.sort, 'I2: Month is the only key of the inner level; it holds every calculation, the integer Number columns included', fails)
check(el['columns'].reject { |c| %w[Year Month].include?(c['name']) || c['name'].end_with?(' Number') }.all? { |c| c['description'].to_s.include?('Power BI') } && ['Sales YTD', 'Sales PY', 'Sales YoY %'].all? { |m| el['description'].include?("Sales[#{m}]") }, 'column descriptions and the element description name the measures', fails)
check(el['order'] == el['columns'].map { |c| c['id'] }, 'order lists every column', fails)
allids = S.elements_of(dm).flat_map { |e| [e['id']] + Array(e['columns']).map { |c| c['id'] } }
check(allids.uniq.length == allids.length, 'ids stay unique', fails)
check(S.elements_of(dm).index(el) == S.elements_of(dm).index(sales) + 1, 'placed right after the fact', fails)

puts "\ntest_qtd_mtd_get_their_own_reset_level"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD', 'Sales QTD', 'Sales MTD', 'Sales PY'), grains: { 'Sales.Sales MTD' => 'day', 'Sales.Sales QTD' => 'day' })
names = res.map { |r| [r['measure'], r['element']] }.to_h
check(names['Sales.Sales YTD'] == 'Sales by month' && names['Sales.Sales PY'] == 'Sales by month', 'YTD and PY share the plain element', fails)
check(names['Sales.Sales QTD'] == 'Sales by day (quarter reset)' && names['Sales.Sales MTD'] == 'Sales by day (month reset)', "QTD and MTD at day grain: #{names.inspect}", fails)
qtd = element(dm, 'Sales by day (quarter reset)')
check(col_formula(qtd, 'Quarter') == 'DateTrunc("quarter", [Sales/Date (Date)])' && qtd['groupings'][0]['groupBy'] == [qtd['columns'].find { |c| c['name'] == 'Quarter' }['id']], 'QTD resets on its own Quarter level', fails)
mtd = element(dm, 'Sales by day (month reset)')
check(mtd['groupings'][0]['groupBy'] == [mtd['columns'].find { |c| c['name'] == 'Month' }['id']] && col_formula(mtd, 'Sales MTD') == 'CumulativeSum([Sales Amount])', 'MTD resets on its own Month level', fails)
check(res.reclassified.empty?, 'nothing reclassified', fails)

puts "\ntest_grain_override_and_grain_equal_to_reset"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD', 'Sales PY'), grains: { 'Sales.Sales YTD' => 'year', 'Sales.Sales PY' => 'quarter' })
el_y = element(dm, 'Sales by year')
check(el_y && el_y['groupings'].length == 1 && col_formula(el_y, 'Sales YTD') == '[Sales Amount]', 'YTD at year grain is the base itself (single level, no CumulativeSum)', fails)
check(el_y['columns'].find { |c| c['name'] == 'Sales YTD' }['description'].include?('Equals Sales Amount at year grain (the period resets every row)'), 'and its description says so', fails)
el_q = element(dm, 'Sales by quarter')
check(el_q && col_formula(el_q, 'Sales PY') == 'DateLookback([Sales Amount], [Quarter], 1, "year")' && el_q['groupings'].length == 1, 'PY at quarter grain looks back a year on the Quarter column', fails)

puts "\ntest_reset_equal_to_grain_emits_the_base (R42)"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales MTD', 'Sales QTD'), grains: { 'Sales.Sales MTD' => 'month', 'Sales.Sales QTD' => 'quarter' })
m = element(dm, 'Sales by month (month reset)')
check(res.length == 2 && m && col_formula(m, 'Sales MTD') == '[Sales Amount]' && m['groupings'].length == 1 && m['groupings'][0]['groupBy'].length == 1, "MTD at month grain equals the base column: #{m && col_formula(m, 'Sales MTD')}", fails)
check(m['columns'].find { |c| c['name'] == 'Sales MTD' }['description'].include?('Equals Sales Amount at month grain (the period resets every row)'), 'description names the equality', fails)
q = element(dm, 'Sales by quarter (quarter reset)')
check(q && col_formula(q, 'Sales QTD') == '[Sales Amount]' && !q['columns'].any? { |c| c['formula'].include?('CumulativeSum') }, 'QTD at quarter grain equals the base, no CumulativeSum', fails)
check(!S.elements_of(dm).any? { |e| e['name'] == 'Sales by month' }, 'no plain element is invented', fails)

puts "\ntest_naming_is_set_independent"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales QTD'), grains: { 'Sales.Sales QTD' => 'day' })
check(res.length == 1 && res[0]['element'] == 'Sales by day (quarter reset)', "QTD alone is still named for its reset: #{res.map { |r| r['element'] }.inspect}", fails)
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD', 'Sales QTD', 'Sales MTD'), grains: { 'Sales.Sales QTD' => 'day', 'Sales.Sales MTD' => 'day', 'Sales.Sales YTD' => 'day' })
check(res.map { |r| r['element'] }.sort == ['Sales by day', 'Sales by day (month reset)', 'Sales by day (quarter reset)'], 'the full set uses the same names', fails)

puts "\ntest_split_fact_uses_the_child"
dm, tmsl, classes = setup(signals_file: 'signals.json', split: true)
trends = load_json('sales', 'signals-trends.json')
classes_t = PbiMeasureClass.classify_all(trends, tmsl, (tmsl['model'] || tmsl)['relationships'])
check(element(dm, 'Sales (source)') && element(dm, 'Sales'), 'the fixture splits Sales', fails)
res = gen(dm, tmsl, only(c_entries(classes_t), 'Sales YTD (As Of)', 'Sales YTD', 'Sales R28'))
child = element(dm, 'Sales')
check(res.map { |r| r['form'] }.sort == %w[grouped metric rolling_sql], "all three forms built on the split fact (#{res.map { |r| r['form'] }.inspect}, reclassified #{res.reclassified.inspect})", fails)
check(child['metrics'].any? { |m| m['name'] == 'Sales YTD (As Of)' } && !Array(element(dm, 'Sales (source)')['metrics']).any?, 'the as-of metric lands on the child, the base keeps none', fails)
check(col_formula(child, 'Date (Date)') && !col_formula(element(dm, 'Sales (source)'), 'Date (Date)'), 'the Lookup lands on the child', fails)
roll = element(dm, "Sales – rolling 28 days by day")
check(roll && roll['source']['statement'].include?('"SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."FACT_SALES"') && roll['source']['statement'].include?('f."QUANTITY"'), 'rolling SQL reads the base fact warehouse table and physical columns', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_rolling_sql_uses_dense_spine"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales R28'))
roll = element(dm, "Sales – rolling 28 days by day")
sql = roll && roll['source']['statement']
check(res.length == 1 && res[0]['form'] == 'rolling_sql' && res[0]['element'] == "Sales – rolling 28 days by day" && res[0]['column'] == 'Sales R28', "one rolling entry: #{res.map { |r| r['element'] }.inspect}", fails)
check(roll['source']['kind'] == 'sql' && roll['source']['connectionId'] == '00000000-0000-0000-0000-000000000000', 'a Custom SQL source on the fact connection', fails)
check(sql.include?('FROM pbi_dates spine LEFT JOIN pbi_daily daily') && sql !~ /MovingSum/i, 'the SQL left-joins the date spine and contains no MovingSum', fails)
check(sql.include?('ROWS BETWEEN 27 PRECEDING AND CURRENT ROW') && sql.include?('COALESCE(daily."SALES_R28", 0)'), 'a 28-day ROWS window over COALESCE(day value, 0)', fails)
check(sql.include?('SUM(COALESCE(f."QUANTITY", 0) * COALESCE(f."UNIT_PRICE", 0) * (1 - COALESCE(f."DISCOUNT", 0)))'), 'R50: the row has a binary minus, so every column is COALESCEd to 0 (DAX reads a blank as 0)', fails)
check(sql.include?('dd."DATE_KEY" = f."ORDER_DATE_KEY"') && sql.include?('SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_DATE"'), 'joined through the active date relationship, date table SQL as the spine', fails)
check(roll['columns'].map { |c| [c['name'], c['formula']] } == [['Day', '[Custom SQL/DAY]'], ['Sales R28', '[Custom SQL/SALES_R28]']], 'columns Day and the window', fails)
check(roll['columns'][1]['description'].include?('Sales[Sales R28]') && roll['description'].include?('Sales[Sales R28]'), 'the window column and the element name the measure', fails)
check(roll['order'] == roll['columns'].map { |c| c['id'] }, 'order lists every column', fails)

puts "\ntest_rolling_sql_dialects_and_validation"
%w[snowflake databricks bigquery sqlite].each do |d|
  s = G.rolling_sql(fact_sql: 'SELECT 1', date_sql: 'SELECT 2;', measure_sql: 'SUM(f.x)', days: 7, dialect: d)
  q = d == 'snowflake' || d == 'sqlite' ? '"' : '`'
  check(s.include?("#{q}DAY#{q}") && s.include?('6 PRECEDING') && !s.include?(';'), "#{d}: quoted identifiers, 6 PRECEDING, trailing ; stripped", fails)
end
bad = begin; G.rolling_sql(fact_sql: 'a', date_sql: 'b', measure_sql: 'c', days: 7, dialect: 'oracle'); rescue ArgumentError => e; e.message; end
check(bad.to_s.include?('unsupported dialect'), 'an unknown dialect is refused', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_rolling_sql_matches_python_oracle_in_sqlite"
PY = <<~'PYTHON'
  import json, sqlite3, sys, datetime
  cfg = json.load(sys.stdin)
  con = sqlite3.connect(':memory:')
  con.execute('CREATE TABLE DIM_DATE (DATE_KEY INTEGER, CAL_DATE TEXT)')
  con.execute('CREATE TABLE FACT (ORDER_DATE_KEY INTEGER, QTY REAL, PRICE REAL)')
  start = datetime.date.fromisoformat(cfg['start'])
  for i in range(cfg['n_days']):
      d = start + datetime.timedelta(days=i)
      con.execute('INSERT INTO DIM_DATE VALUES (?, ?)', (i + 1, d.isoformat()))
  con.executemany('INSERT INTO FACT VALUES (?, ?, ?)', cfg['facts'])
  rows = con.execute(cfg['sql']).fetchall()
  # calendar oracle: trailing N calendar days of the daily totals, absent days count as 0
  daily = {}
  for key, q, p in cfg['facts']:
      daily[key] = daily.get(key, 0) + q * p
  win = cfg['days']
  oracle = []
  for i in range(cfg['n_days']):
      total = sum(daily.get(k, 0) for k in range(max(1, i + 2 - win), i + 2))
      oracle.append(((start + datetime.timedelta(days=i)).isoformat(), total))
  print(json.dumps({'rows': rows, 'oracle': oracle}))
PYTHON

n_days = 60
facts = []
(1..n_days).each do |k|
  next unless k % 4 == 1 || k % 11 == 0 # sparse: about a third of the days have rows
  facts << [k, k % 5 + 1, 2.5]
  facts << [k, 3, 1.25] if k % 7 == 0 # several rows on one day
end
sql = G.rolling_sql(fact_sql: 'SELECT * FROM FACT', date_sql: 'SELECT * FROM DIM_DATE', measure_sql: 'SUM(f."QTY" * f."PRICE")',
                    days: 28, dialect: 'sqlite', fact_key: 'ORDER_DATE_KEY', date_key: 'DATE_KEY', date_col: 'CAL_DATE')
out, err, st = Open3.capture3('python3', '-I', '-c', PY, stdin_data: JSON.generate('sql' => sql, 'facts' => facts, 'start' => '2025-01-01', 'n_days' => n_days, 'days' => 28))
check(st.success?, "python3 ran the SQL in sqlite (#{err.to_s.lines.last(2).join.strip})", fails)
if st.success?
  got = JSON.parse(out)
  rows = got['rows'].sort_by { |r| r[0] }
  oracle = got['oracle']
  check(rows.length == n_days && oracle.length == n_days, "one row per calendar day (#{rows.length})", fails)
  mism = rows.each_with_index.count { |r, i| r[0] != oracle[i][0] || (r[1] - oracle[i][1]).abs > 1e-9 }
  check(mism.zero?, "all #{n_days} days equal the calendar rolling-28 oracle (#{mism} differ)", fails)
  # the sparse sample really exercises the dense-spine point: a row-count window would differ
  present = facts.map(&:first).uniq.length
  check(present < n_days / 2 + 10, "sample is sparse (#{present} of #{n_days} days have rows)", fails)
  rows_window = (0...n_days).count do |i|
    ks = facts.map(&:first).uniq.sort.select { |k| k <= i + 1 }.last(28)
    mv = ks.sum { |k| facts.select { |f| f[0] == k }.sum { |f| f[1] * f[2] } }
    (mv - oracle[i][1]).abs > 1e-9
  end
  check(rows_window > n_days / 3, "a rows-not-days window (MovingSum) would be wrong on #{rows_window} of #{n_days} days", fails)
end

# ---------------------------------------------------------------------------------------------------
puts "\ntest_inline_base_and_count_rolling"
dm, tmsl, classes = setup
inline = { 'key' => 'Sales.Inline R7', 'class' => 'C', 'home' => 'Sales',
           'ti' => { 'pattern' => 'rolling', 'base' => nil, 'base_expr' => 'SUMX(Sales, Sales[Quantity] * Sales[Unit Cost])', 'anchor' => 'axis', 'days' => 7, 'date_table' => 'Date' } }
cnt = { 'key' => 'Sales.Count R7', 'class' => 'C', 'home' => 'Sales',
        'ti' => { 'pattern' => 'rolling', 'base' => nil, 'base_expr' => 'COUNT(Sales[Quantity])', 'anchor' => 'axis', 'days' => 7, 'date_table' => 'Date' } }
res = G.generate!(dm, [inline, cnt], date_element: 'Date', dialect: 'snowflake')
roll = element(dm, "Sales – rolling 7 days by day")
check(res.length == 2 && roll && res.all? { |r| r['element'] == roll['name'] }, 'two measures with the same window share one element', fails)
check(roll['source']['statement'].include?('SUM(f."QUANTITY" * f."UNIT_COST") AS "INLINE_R7"') && roll['source']['statement'].include?('NULLIF(COUNT(f."QUANTITY"), 0) AS "COUNT_R7"'), 'inline Sum and Count bases become SUM and COUNT', fails)
dm_g, = setup
inl_g = inline.merge('key' => 'Sales.Inline YTD', 'ti' => inline['ti'].merge('pattern' => 'ytd', 'days' => nil))
res = G.generate!(dm_g, [inl_g], date_element: 'Date', dialect: 'snowflake')
elg = element(dm_g, 'Sales by month')
check(res.length == 1 && col_formula(elg, 'Inline YTD (base)') == 'Sum([Sales/Quantity] * [Sales/Unit Cost])' && col_formula(elg, 'Inline YTD') == 'CumulativeSum([Inline YTD (base)])', "inline base in a grouped element: #{col_formula(elg, 'Inline YTD (base)')}", fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_unbuildable_forms_are_reclassified_d"
dm, tmsl, classes = setup
def mk(key, pattern, base, **ti)
  with_expr = ti.delete(:expr)
  e = { 'key' => key, 'class' => 'C', 'home' => 'Sales', 'ti' => { 'pattern' => pattern, 'base' => base, 'anchor' => 'axis', 'days' => nil, 'date_table' => 'Date' }.merge(ti.map { |k, v| [k.to_s, v] }.to_h) }
  e['expression'] = "CALCULATE([#{base}], DATEADD('Date'[Date], -1, #{(ti[:unit] || 'year').upcase}))" if with_expr && pattern == 'pp'
  e
end
cases = [
  ['non-additive base (a ratio)', mk('Sales.GM YTD', 'ytd', 'GM %'), /not a Sum or Count/],
  ['distinct count base', mk('Sales.Orders YTD', 'ytd', 'Orders'), /not a Sum or Count/],
  ['base metric missing', mk('Sales.X YTD', 'ytd', 'Nope'), /no Sigma metric/],
  ['as-of prior year', mk('Sales.AsOf PY', 'py', 'Sales Amount', anchor: 'as_of'), /as-of py has no probe-proven form/],
  ['as-of rolling', mk('Sales.AsOf R', 'rolling', 'Sales Amount', anchor: 'as_of', days: 7), /as-of rolling/],
  ['other date table', mk('Sales.Ship YTD', 'ytd', 'Sales Amount', date_table: 'Ship Calendar'), /not Date/],
  ['unknown fact', mk('Sales.Z', 'ytd', 'Sales Amount').merge('home' => 'Nowhere'), /fact element Nowhere not found/],
  ['rolling without days', mk('Sales.R', 'rolling', 'Sales Amount'), /no day count/],
  ['pp without a unit', mk('Sales.PP', 'pp', 'Sales Amount', expr: 1), /no unit/],
  ['inline Avg base', mk('Sales.Avg YTD', 'ytd', nil, base_expr: 'AVERAGE(Sales[Quantity])'), /Sum or Count/],
  ['inline base with a function call', mk('Sales.Fn YTD', 'ytd', nil, base_expr: 'SUMX(Sales, ABS(Sales[Quantity]))'), /other parts|not arithmetic/]
]
cases.each do |label, entry, pat|
  d2, = setup
  r = G.generate!(d2, [entry], date_element: 'Date', dialect: 'snowflake')
  ok = r.empty? && r.reclassified.length == 1 && r.reclassified[0]['reason'] =~ /\AC form not buildable: / && r.reclassified[0]['reason'] =~ pat &&
       entry['class'] == 'D' && entry['reason'] == r.reclassified[0]['reason'] && r.reclassified[0]['key'] == entry['key']
  check(ok, "#{label}: #{r.reclassified.map { |x| x['reason'] }.inspect}", fails)
end
dm_w, = setup
res = G.generate!(dm_w, [mk('Sales.W YTD', 'ytd', 'Sales Amount')], date_element: 'Date', dialect: 'snowflake', grains: { 'Sales.W YTD' => 'week' })
check(res.empty? && res.reclassified[0]['reason'].include?('weeks do not nest'), 'week grain is refused', fails)
res = G.generate!(setup[0], [mk('Sales.Q', 'qtd', 'Sales Amount')], date_element: 'Date', dialect: 'snowflake', grains: { 'Sales.Q' => 'year' })
check(res.empty? && res.reclassified[0]['reason'].include?('QTD at year grain'), 'QTD at year grain is refused', fails)
res = G.generate!(setup[0], [mk('Sales.PPq', 'pp', 'Sales Amount', unit: 'quarter', expr: 1)], date_element: 'Date', dialect: 'snowflake', grains: { 'Sales.PPq' => 'year' })
check(res.empty? && res.reclassified[0]['reason'].include?('not a whole-period lookback'), 'a quarter shift at year grain is refused', fails)
dm_n = setup[0]
dm_n['pages'][0]['elements'].delete_if { |e| e['name'] == 'As Of' }
res = G.generate!(dm_n, [mk('Sales.AO', 'ytd', 'Sales Amount', anchor: 'as_of')], date_element: 'Date', dialect: 'snowflake')
check(res.empty? && res.reclassified[0]['reason'].include?('as-of element As Of not found'), 'a missing As Of table is refused', fails)

puts "\ntest_py_pp_need_the_expression"
dm, tmsl, classes = setup
no_tmsl = only(c_entries(classes), 'Sales PY', 'Sales YoY %', 'Sales YTD')
r = G.generate!(dm, no_tmsl, date_element: 'Date', dialect: 'snowflake')
why = 'C form not buildable: needs the DAX expression to tell PY from a derived ratio'
check(r.reclassified.map { |x| x['reason'] }.sort == [why, why] && r.map { |x| x['measure'] } == ['Sales.Sales YTD'], 'without tmsl or an expression PY and YoY % are D, YTD still built', fails)
check(no_tmsl.select { |e| e['class'] == 'D' }.length == 2, 'both entries set to class D', fails)

puts "\ntest_year_end_and_filter_arguments_are_refused"
[["TOTALYTD([Sales Amount], 'Date'[Date], \"6/30\")", 'TOTALYTD'], ["TOTALYTD([Sales Amount], 'Date'[Date], Product[Brand] = \"A\")", 'TOTALYTD'],
 ["CALCULATE([Sales Amount], DATESYTD('Date'[Date], \"6/30\"))", 'DATESYTD'], ["TOTALMTD([Sales Amount], 'Date'[Date], Store[Channel] = \"Web\")", 'TOTALMTD']].each do |expr, fn|
  e = { 'key' => 'Sales.X', 'class' => 'C', 'home' => 'Sales', 'expression' => expr,
        'ti' => { 'pattern' => fn =~ /MTD/ ? 'mtd' : 'ytd', 'base' => 'Sales Amount', 'anchor' => 'axis', 'days' => nil, 'date_table' => 'Date' } }
  r = G.generate!(setup[0], [e], date_element: 'Date', dialect: 'snowflake')
  check(r.empty? && r.reclassified[0]['reason'].include?("#{fn} carries a year-end or filter argument"), "#{expr[0, 40]}... refused", fails)
end
ok = { 'key' => 'Sales.X', 'class' => 'C', 'home' => 'Sales', 'expression' => "TOTALYTD([Sales Amount], 'Date'[Date])",
       'ti' => { 'pattern' => 'ytd', 'base' => 'Sales Amount', 'anchor' => 'axis', 'days' => nil, 'date_table' => 'Date' } }
check(G.generate!(setup[0], [ok], date_element: 'Date', dialect: 'snowflake').length == 1, 'the plain two-argument form still builds', fails)

puts "\ntest_existing_element_is_reused_only_with_a_matching_formula"
dm, tmsl, classes = setup
gen(dm, tmsl, only(c_entries(classes), 'Sales YTD'))
el = element(dm, 'Sales by month')
el['columns'].find { |c| c['name'] == 'Sales YTD' }['formula'] = 'CumulativeSum([Units])'
r = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD'))
check(r.empty? && r.reclassified.length == 1 && r.reclassified[0]['reason'].include?('without a matching column'), 'a same-named column with another formula is not reused', fails)
dm, tmsl, classes = setup
gen(dm, tmsl, only(c_entries(classes), 'Sales R28'))
roll = element(dm, "Sales \u2013 rolling 28 days by day")
roll['columns'][1]['formula'] = '[Custom SQL/OTHER]'
r = gen(dm, tmsl, only(c_entries(classes), 'Sales R28'))
check(r.empty? && r.reclassified.length == 1, 'same for the rolling element', fails)

puts "\ntest_expression_checks (tmsl supplies the DAX)"
dm, tmsl, classes = setup
prev = { 'key' => 'Sales.PrevYear', 'class' => 'C', 'home' => 'Sales', 'expression' => "CALCULATE([Sales Amount], PREVIOUSYEAR('Date'[Date]))",
         'ti' => { 'pattern' => 'py', 'base' => 'Sales Amount', 'anchor' => 'axis', 'days' => nil, 'date_table' => 'Date' } }
r = G.generate!(dm, [prev], date_element: 'Date', dialect: 'snowflake')
check(r.empty? && r.reclassified[0]['reason'].include?('PREVIOUSYEAR returns the whole previous year'), 'PREVIOUSYEAR at month grain is refused (it returns the whole year)', fails)
prev = prev.merge('class' => 'C').tap { |h| h.delete('reason') } # the refusal above set it to D
r = G.generate!(dm, [prev], date_element: 'Date', dialect: 'snowflake', grains: { 'Sales.PrevYear' => 'year' })
check(r.length == 1 && r[0]['element'] == 'Sales by year' && col_formula(element(dm, 'Sales by year'), 'PrevYear') == 'DateLookback([Sales Amount], [Year], 1, "year")', 'PREVIOUSYEAR at year grain is a one-year lookback', fails)
check(r[0]['whole'] == 'PREVIOUSYEAR' && r[0]['grain'] == 'year' && r[0]['unit'] == 'year' && r[0]['kind'] == 'py' && r[0]['period'] == 'Year', "the record flags the whole-period form: #{r[0].inspect}", fails)
odd = { 'key' => 'Sales.Odd', 'class' => 'C', 'home' => 'Sales', 'expression' => '[Sales PY] * 2',
        'ti' => { 'pattern' => 'py', 'base' => 'Sales Amount', 'anchor' => 'axis', 'days' => nil, 'date_table' => 'Date' } }
r = G.generate!(setup[0], [odd], date_element: 'Date', dialect: 'snowflake')
check(r.empty? && r.reclassified[0]['reason'].include?('not a recognised YoY'), 'a derived measure that is not YoY % is refused', fails)
dm, tmsl, classes = setup
yoy_only = only(c_entries(classes), 'Sales YoY %')
r = gen(dm, tmsl, yoy_only)
check(r.empty? && r.reclassified[0]['reason'].include?('is not a prior-year measure'), 'YoY % without its PY measure in the set is refused', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_every_class_c_measure_in_the_trends_fixture"
dm, tmsl, classes = setup
entries = c_entries(classes)
res = gen(dm, tmsl, entries)
check(res.reclassified.empty? && res.length == entries.length, "all #{entries.length} class C measures built, none reclassified (#{res.reclassified.inspect})", fails)
forms = res.map { |r| [r['measure'].split('.', 2)[1], r['form']] }.to_h
check(forms == { 'Sales YTD' => 'grouped', 'Sales QTD' => 'grouped', 'Sales MTD' => 'grouped', 'Sales PY' => 'grouped', 'Sales YoY %' => 'grouped', 'Sales YTD (As Of)' => 'metric', 'Sales R28' => 'rolling_sql' }, "forms: #{forms.inspect}", fails)
check(S.elements_of(dm).count { |e| e['groupings'] } == 3, 'three grouped elements (year, quarter and month resets at month grain)', fails)
all_ids = S.elements_of(dm).flat_map { |e| [e['id']] + Array(e['columns']).map { |c| c['id'] } + Array(e['metrics']).map { |m| m['id'] } + Array(e['relationships']).map { |x| x['id'] } }
check(all_ids.uniq.length == all_ids.length, 'ids stay unique across the whole model', fails)
check(JSON.generate(dm) == JSON.generate(JSON.parse(JSON.generate(dm))), 'the model round-trips as JSON', fails)

# ---------------------------------------------------------------------------------------------------
# Task 21z2: time-axis density. A grouped element has rows only for periods that have fact rows; Power BI shows
# every Date-table period in range (TOTALYTD stays flat after the last sale, SAMEPERIODLASTYEAR shows months whose
# prior-year month had sales). A fact whose Date table has periods with no fact rows is reclassified D.
require_relative 'lib/pbi_shape_run'

puts "\ntest_density_queries_are_dialect_quoted"
dm, tmsl, classes = setup
date = G.date_config(dm, 'Date')
fact = element(dm, 'Sales')
expect = lambda do |q, fn_trunc|
  fsql = "SELECT * FROM #{q.call('SAMPLE_DB')}.#{q.call('ZZ_CLAUDE_PBI_SHAPED')}.#{q.call('FACT_SALES')}"
  dsql = "SELECT * FROM #{q.call('SAMPLE_DB')}.#{q.call('ZZ_CLAUDE_PBI_SHAPED')}.#{q.call('DIM_DATE')}"
  "WITH pbi_fact_periods AS (\n" \
  "SELECT DISTINCT #{fn_trunc.call("dd.#{q.call('CAL_DATE')}")} AS #{q.call('PBI_PERIOD')} FROM (\n#{fsql}\n) f JOIN (\n#{dsql}\n) dd " \
  "ON dd.#{q.call('DATE_KEY')} = f.#{q.call('ORDER_DATE_KEY')}\n)\n" \
  "SELECT (SELECT COUNT(DISTINCT #{fn_trunc.call("d.#{q.call('CAL_DATE')}")}) FROM (\n#{dsql}\n) d " \
  "WHERE #{fn_trunc.call("d.#{q.call('CAL_DATE')}")} >= (SELECT MIN(#{q.call('PBI_PERIOD')}) FROM pbi_fact_periods)) AS #{q.call('EXPECTED')}, " \
  "(SELECT COUNT(*) FROM pbi_fact_periods) AS #{q.call('PRESENT')}"
end
sql, why = PbiShapeRun.density_query(dm, fact, 'month', 'snowflake', date)
check(why.nil? && sql == expect.call(->(n) { "\"#{n}\"" }, ->(x) { "DATE_TRUNC('month', #{x})" }), "snowflake density SQL is exact:\n#{sql}", fails)
sql, why = PbiShapeRun.density_query(dm, fact, 'quarter', 'bigquery', date)
check(why.nil? && sql == expect.call(->(n) { "`#{n}`" }, ->(x) { "DATE_TRUNC(#{x}, QUARTER)" }), "bigquery density SQL is exact (backticks, DATE_TRUNC(x, QUARTER)):\n#{sql}", fails)
# a fact with no path to the date table has no query, with a reason (never a guess)
nofact = { 'name' => 'Nope', 'id' => 'x', 'columns' => [] }
sql, why = PbiShapeRun.density_query(dm, nofact, 'month', 'snowflake', date)
check(sql.nil? && why.to_s.include?('no relationship path'), "no date path: no query, a reason (#{why.inspect})", fails)

puts "\ntest_sparse_time_axis_moves_grouped_c_to_d"
sparse = { 'Sales' => { 'month' => { 'sparse' => true, 'expected' => 14, 'present' => 12 } } }
dm, tmsl, classes = setup
ents = only(c_entries(classes), 'Sales YTD', 'Sales PY')
res = gen(dm, tmsl, ents, grains: { 'Sales.Sales YTD' => 'month', 'Sales.Sales PY' => 'month' }, time_density: sparse)
want = 'the Date table has month periods with no Sales rows (2 of 14; trailing or gaps); a grouped element cannot show them - needs a page summary over the Date table'
check(res.empty? && res.reclassified.map { |r| r['key'] }.sort == ['Sales.Sales PY', 'Sales.Sales YTD'], "both grouped C measures are reclassified (#{res.reclassified.inspect})", fails)
check(res.reclassified.all? { |r| r['reason'] == want } && ents.all? { |e| e['class'] == 'D' && e['reason'] == want }, "with the explicit reason: #{res.reclassified[0] && res.reclassified[0]['reason']}", fails)
check(!S.elements_of(dm).any? { |e| e['name'] == 'Sales by month' }, 'no grouped element is built', fails)
# dense (or another grain flagged) keeps the grouped form
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales YTD', 'Sales PY'), grains: { 'Sales.Sales YTD' => 'month', 'Sales.Sales PY' => 'month' },
          time_density: { 'Sales' => { 'month' => { 'sparse' => false, 'expected' => 12, 'present' => 12 }, 'quarter' => { 'sparse' => true, 'expected' => 5, 'present' => 4 } } })
check(res.length == 2 && res.reclassified.empty? && res.all? { |r| r['form'] == 'grouped' } && element(dm, 'Sales by month'), 'a dense month axis keeps the grouped element (the sparse quarter grain is not used)', fails)

# ---------------------------------------------------------------------------------------------------
# Final review fixes (Fix A): C2 report filters in the rolling SQL, m5, m7, m12, m13
puts "\ntest_i2_integer_date_levels_are_columns_of_the_grouped_element"
dm, tmsl, classes = setup
gen(dm, tmsl, only(c_entries(classes), 'Sales YTD'))
el = element(dm, 'Sales by month')
check(col_formula(el, 'Year Number') == 'Year([Month])' && col_formula(el, 'Quarter Number') == 'Quarter([Month])' && col_formula(el, 'Month Number') == 'Month([Month])',
      "I2: month grain: integer Year/Quarter/Month Number columns over the level date (#{el['columns'].map { |c| c['name'] }.inspect})", fails)
dm, tmsl, classes = setup
gen(dm, tmsl, only(c_entries(classes), 'Sales PY'), grains: { 'Sales.Sales PY' => 'year' })
ey = element(dm, 'Sales by year')
check(ey['columns'].map { |c| c['name'] }.grep(/ Number\z/) == ['Year Number'], "year grain: only Year Number (#{ey['columns'].map { |c| c['name'] }.inspect})", fails)

puts "\ntest_i2_number_columns_are_calculations_never_group_keys (A2: DateLookback finds no prior year beside extra keys)"
a2_runs = [
  [%w[Sales\ YTD Sales\ PY], { 'Sales.Sales YTD' => 'month', 'Sales.Sales PY' => 'month' }, 'Sales by month', 'Month'],
  [%w[Sales\ PY], { 'Sales.Sales PY' => 'quarter' }, 'Sales by quarter', 'Quarter'],
  [%w[Sales\ PY], { 'Sales.Sales PY' => 'year' }, 'Sales by year', 'Year'],
  [%w[Sales\ QTD], { 'Sales.Sales QTD' => 'month' }, 'Sales by month (quarter reset)', 'Month'],
  [%w[Sales\ MTD], { 'Sales.Sales MTD' => 'day' }, 'Sales by day (month reset)', 'Day'],
  [%w[Sales\ MTD], { 'Sales.Sales MTD' => 'month' }, 'Sales by month (month reset)', 'Month']
]
a2_runs.each do |names, grains, ename, grain|
  dm, tmsl, classes = setup
  gen(dm, tmsl, only(c_entries(classes), *names), grains: grains)
  el = element(dm, ename)
  check(!el.nil?, "A2: #{ename} generated", fails)
  next unless el
  ids = el['columns'].map { |c| [S.display_name(c), c['id']] }.to_h
  nums = el['columns'].select { |c| S.display_name(c).end_with?(' Number') }
  keys = el['groupings'].flat_map { |x| x['groupBy'] }
  inner = el['groupings'].last
  check(!nums.empty? && nums.none? { |c| keys.include?(c['id']) }, "A2: #{ename}: no Number column is in any groupBy (#{nums.map { |c| c['name'] }.inspect})", fails)
  check(inner['groupBy'] == [ids[grain]] && nums.all? { |c| inner['calculations'].include?(c['id']) }, "A2: #{ename}: the Number columns are calculations of the #{grain} level, whose only key is #{grain}", fails)
  check(nums.all? { |c| c['formula'] =~ /\A(Year|Quarter|Month)\(\[#{grain}\]\)\z/ }, "A2: #{ename}: each Number column is Year/Quarter/Month of [#{grain}]", fails)
end

puts "\ntest_c2_report_filter_reaches_the_rolling_sql"
def apply_with_report_filter(filters)
  dm = load_json('sales', 'dm-raw.json')
  tmsl = load_json('sales', 'model.bim')
  sig = load_json('sales', 'signals-trends.json')
  sig['filters'] = filters
  log = S.apply!(dm, tmsl: tmsl, signals: sig, dialect: 'snowflake')
  [dm, log]
end
cat_filter = [{ 'scope' => 'report', 'target' => 'Category.Category Name', 'type' => 'list', 'mode' => 'exclude', 'values' => ['Discontinued'] }]
dm_c2, log_c2 = apply_with_report_filter(cat_filter)
roll_c2 = element(dm_c2, "Sales – rolling 28 days by day")
stmt_c2 = roll_c2 && roll_c2['source']['statement']
check(log_c2['filters']['applied'].any? { |a| a['element'] == 'Sales' }, 'the report filter is applied to the Sales fact', fails)
check(stmt_c2 && stmt_c2.include?("LOWER(k3.\"CATEGORY_NAME\") IN ('discontinued')") && stmt_c2.include?('NOT COALESCE('),
      "C2: the R28 SQL carries the null-safe, case-insensitive exclude (#{stmt_c2 && stmt_c2[/WHERE 1 = 1.*?\/\*@slicers/m].to_s.gsub(/\s+/, ' ')[0, 400]})", fails)
check(stmt_c2 && stmt_c2.include?('DIM_SKU') && stmt_c2.include?('DIM_PRODUCT') && stmt_c2.include?('DIM_CATEGORY'), 'it walks the same path as the fact filter: Sales > SKU > Product > Category', fails)
check(stmt_c2 && stmt_c2.index('NOT COALESCE(') < stmt_c2.index('/*@slicers') && stmt_c2[/\/\*@slicers[^*]*\*\//] && stmt_c2.scan('/*@slicers').length == 1,
      'the predicate sits in the daily scan WHERE, before the single /*@slicers*/ hook', fails)
rec_c2 = log_c2['time_intel'].find { |r| r['form'] == 'rolling_sql' }
check(rec_c2 && rec_c2['report_filters'] == ['Category.Category Name exclude ["Discontinued"]'], "the record names the filter it applied (#{rec_c2 && rec_c2['report_filters'].inspect})", fails)
# a filter that cannot be written exactly moves the fact's rolling measures to D with a reason
blank_filter = [{ 'scope' => 'report', 'target' => 'Category.Category Name', 'type' => 'list', 'mode' => 'include', 'values' => ['A', nil] }]
dm_b, log_b = apply_with_report_filter(blank_filter)
check(log_b['classes']['Sales.Sales R28']['class'] == 'D' && log_b['classes']['Sales.Sales R28']['reason'].include?('blank') && element(dm_b, "Sales – rolling 28 days by day").nil?,
      "C2: a blank in the list is not expressible, so R28 is class D (#{log_b['classes']['Sales.Sales R28']['reason']})", fails)
# a report filter on the date table is ignored by DATESINPERIOD (the Date filter is replaced): no predicate
date_filter = [{ 'scope' => 'report', 'target' => 'Date.Year', 'type' => 'list', 'mode' => 'include', 'values' => [2025] }]
dm_d, log_d = apply_with_report_filter(date_filter)
sd = element(dm_d, "Sales – rolling 28 days by day")
check(sd && !sd['source']['statement'].include?('COALESCE(k') && log_d['classes']['Sales.Sales R28']['class'] == 'C', 'a Date-table report filter adds no predicate (Power BI replaces it inside the window)', fails)
dm_n, log_n = apply_with_report_filter([])
sn = element(dm_n, "Sales – rolling 28 days by day")
check(sn && !sn['source']['statement'].include?("\n    AND ") && sn['source']['statement'].include?('WHERE 1 = 1 /*@slicers'), 'no report filter: the SQL is unchanged', fails)

puts "\ntest_c2_rolling_predicate_runs_in_sqlite"
if stmt_c2
  sqlite_sql = stmt_c2.gsub(/"SAMPLE_DB"\."ZZ_CLAUDE_PBI_SHAPED"\./, '')
  py = <<~'PYTHON'
    import json, sqlite3, sys
    cfg = json.load(sys.stdin)
    con = sqlite3.connect(':memory:')
    con.executescript("""
    CREATE TABLE DIM_DATE (DATE_KEY INTEGER, CAL_DATE TEXT);
    CREATE TABLE DIM_CATEGORY (CATEGORY_KEY INTEGER, CATEGORY_NAME TEXT);
    CREATE TABLE DIM_PRODUCT (PRODUCT_KEY INTEGER, CATEGORY_KEY INTEGER);
    CREATE TABLE DIM_SKU (SKU_KEY INTEGER, PRODUCT_KEY INTEGER);
    CREATE TABLE FACT_SALES (ORDER_DATE_KEY INTEGER, SKU_KEY INTEGER, QUANTITY REAL, UNIT_PRICE REAL, DISCOUNT REAL, UNIT_COST REAL);
    INSERT INTO DIM_DATE VALUES (1,'2025-01-01'),(2,'2025-01-02'),(3,'2025-01-03');
    INSERT INTO DIM_CATEGORY VALUES (1,'Food'),(2,'DISCONTINUED'),(3,NULL);
    INSERT INTO DIM_PRODUCT VALUES (10,1),(20,2),(30,3),(40,NULL);
    INSERT INTO DIM_SKU VALUES (100,10),(200,20),(300,30),(400,40),(500,NULL);
    INSERT INTO FACT_SALES VALUES (1,100,1,10,0,0),(1,200,1,100,0,0),(2,300,1,1000,0,0),(2,400,1,10000,0,0),(3,500,1,100000,0,0),(3,NULL,1,1000000,0,0),(3,999,1,10000000,0,0);
    """)
    rows = con.execute(cfg['sql']).fetchall()
    print(json.dumps(rows))
  PYTHON
  out, err, st = Open3.capture3('python3', '-I', '-c', py, stdin_data: JSON.generate('sql' => sqlite_sql.gsub('DATE_TRUNC', 'DATE_TRUNC')))
  check(st.success?, "python3 ran the filtered R28 SQL in sqlite (#{err.to_s.lines.last(2).join.strip})", fails)
  if st.success?
    rows = JSON.parse(out).sort_by { |r| r[0] }
    # Discontinued (case-insensitive) is dropped (the 100.0 and its day-1 row); a NULL category, a NULL key and an
    # unmatched key all stay: day 1 = 10, day 2 = +1000 +10000, day 3 = +100000 +1000000 +10000000
    check(rows.map { |r| r[1] } == [10.0, 11010.0, 11111010.0], "the exclude keeps NULL attribute, NULL key and orphan key rows: #{rows.map { |r| r[1] }.inspect}", fails)
  end
end

puts "\ntest_m5_rolling_window_with_no_rows_reads_blank"
sql5 = G.rolling_sql(fact_sql: 'SELECT * FROM FACT', date_sql: 'SELECT * FROM DIM_DATE', measure_sql: 'SUM(f."QTY")', days: 3, dialect: 'sqlite',
                     fact_key: 'ORDER_DATE_KEY', date_key: 'DATE_KEY', date_col: 'CAL_DATE')
py5 = <<~'PYTHON'
  import json, sqlite3, sys
  cfg = json.load(sys.stdin)
  con = sqlite3.connect(':memory:')
  con.execute('CREATE TABLE DIM_DATE (DATE_KEY INTEGER, CAL_DATE TEXT)')
  con.execute('CREATE TABLE FACT (ORDER_DATE_KEY INTEGER, QTY REAL)')
  for i in range(8):
      con.execute('INSERT INTO DIM_DATE VALUES (?, ?)', (i + 1, '2025-01-%02d' % (i + 1)))
  con.execute('INSERT INTO FACT VALUES (1, 5)')
  con.execute('INSERT INTO FACT VALUES (2, NULL)')
  print(json.dumps(con.execute(cfg['sql']).fetchall()))
PYTHON
out5, err5, st5 = Open3.capture3('python3', '-I', '-c', py5, stdin_data: JSON.generate('sql' => sql5))
check(st5.success?, "python3 ran the SQL (#{err5.to_s.lines.last(2).join.strip})", fails)
if st5.success?
  got5 = JSON.parse(out5).sort_by { |r| r[0] }.map { |r| r[1] }
  # days 1-3 window holds day 1 (5); day 4 window = days 2-4 holds only a NULL sum (a day with rows, all NULL) and empty days: blank;
  # days 5-8: nothing in the window: blank (DAX BLANK), not 0
  check(got5 == [5.0, 5.0, 5.0, nil, nil, nil, nil, nil], "m5: windows with no rows read NULL, not 0 (#{got5.inspect})", fails)
end

puts "\ntest_m12_day_grain_prior_period_is_not_built"
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales PY'), grains: { 'Sales.Sales PY' => 'day' })
check(res.empty? && res.reclassified.length == 1 && res.reclassified[0]['reason'] == 'C form not buildable: day-grain prior period not probed',
      "m12: PY at day grain is D with a reason (#{res.reclassified.map { |r| r['reason'] }.inspect})", fails)
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales PY', 'Sales YoY %'), grains: { 'Sales.Sales PY' => 'day', 'Sales.Sales YoY %' => 'day' })
check(res.empty? && res.reclassified.length == 2 && res.reclassified.all? { |r| r['reason'].include?('day-grain prior period not probed') },
      "m12: a day-grain YoY % is D too (#{res.reclassified.map { |r| r['reason'] }.inspect})", fails)
dm, tmsl, classes = setup
res = gen(dm, tmsl, only(c_entries(classes), 'Sales PY'), grains: { 'Sales.Sales PY' => 'month' })
check(res.length == 1 && res.reclassified.empty?, 'month-grain PY still builds', fails)

puts "\ntest_m13_density_probe_uses_each_records_date_table"
dm, tmsl, classes = setup
cal = JSON.parse(JSON.generate(element(dm, 'Date')))
cal['id'] = 'fiscal-el'
cal['name'] = 'Fiscal Date'
cal['source']['path'] = cal['source']['path'][0...-1] + ['DIM_FISCAL_DATE']
dm['pages'][0]['elements'] << cal
sales_el = element(dm, 'Sales')
rel = JSON.parse(JSON.generate(sales_el['relationships'].find { |r| r['name'] == 'Date' }))
rel['id'] = 'rel-fiscal'
rel['name'] = 'Fiscal Date'
rel['targetElementId'] = 'fiscal-el'
sales_el['relationships'] << rel
cls13 = { 'Sales.A' => { 'class' => 'C', 'home' => 'Sales', 'ti' => { 'date_table' => 'Date' } },
          'Sales.B' => { 'class' => 'C', 'home' => 'Sales', 'ti' => { 'date_table' => 'Fiscal Date' } } }
recs13 = [{ 'measure' => 'Sales.A', 'form' => 'grouped', 'period' => 'Month' }, { 'measure' => 'Sales.B', 'form' => 'grouped', 'period' => 'Quarter' }]
seen13 = {}
probe13 = lambda do |_stage, qs|
  seen13.update(qs)
  qs.map { |k, _| [k, { 'ok' => true, 'rows' => [{ 'EXPECTED' => 3, 'PRESENT' => 3 }] }] }.to_h
end
PbiShapeRun.density_plan(dm, cls13, recs13, tmsl, probe13, 'snowflake')
check(seen13['density:Sales:month'].to_s.include?('DIM_DATE') && !seen13['density:Sales:month'].to_s.include?('DIM_FISCAL_DATE'),
      'm13: the Date record is probed against Date', fails)
check(seen13['density:Sales:quarter'].to_s.include?('DIM_FISCAL_DATE') && !seen13['density:Sales:quarter'].to_s.include?('"DIM_DATE"'),
      "m13: the Fiscal Date record is probed against Fiscal Date (#{seen13['density:Sales:quarter'].to_s[0, 120].gsub("\n", ' ')})", fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.length} FAILED:"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
