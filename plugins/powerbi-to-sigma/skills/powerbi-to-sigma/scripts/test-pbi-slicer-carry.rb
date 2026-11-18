#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for lib/pbi_slicer_carry.rb and its edits to pbi_time_intel_gen.rb, pbi_direct_sources.rb and
# pbi_direct_map.rb (Power BI-shaped model mode, task 16): slicers on pages whose charts read a summary table --
# carry the slicer's field (grouped element: outer levels + Sum consumer; rolling summary: GROUP BY / PARTITION BY
# over a dense spine x the distinct combinations) or give the page ONE live element that applies the picks.
#
# Fixtures: fixtures/pbi-shaped/sales (placeholder Snowflake coordinates only). Synthetic names only.
# No network. The SQL is run in Python's stdlib sqlite3 (dialect 'sqlite', test-only); Sigma templates are
# rendered by hand the way Sigma inlines them.
# Run: ruby scripts/test-pbi-slicer-carry.rb
require 'json'
require 'open3'
require 'date'
require 'tmpdir'
require_relative 'lib/pbi_shaped_model'
require_relative 'lib/pbi_measure_class'
require_relative 'lib/pbi_time_intel_gen'
require_relative 'lib/pbi_direct_map'
require_relative 'lib/pbi_direct_sources'
require_relative 'lib/pbi_slicer_carry'

FIX = File.join(File.dirname(__dir__), 'fixtures', 'pbi-shaped')
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'
C = PbiSlicerCarry
G = PbiTimeIntelGen
S = PbiShapedModel
D = PbiDirectSources

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def load_json(*parts)
  JSON.parse(File.read(File.join(FIX, *parts)))
end

def setup
  dm = load_json('sales', 'dm-raw.json')
  tmsl = load_json('sales', 'model.bim')
  signals = load_json('sales', 'signals-trends.json')
  table_for = S.table_for_elements(dm, tmsl)
  S.drop_views!(dm)
  er = S.rename_elements!(dm, table_for)
  cr = S.rename_columns!(dm, tmsl, table_for)
  S.rewrite_refs!(dm, er, cr)
  S.relationships!(dm, tmsl, table_for)
  classes = PbiMeasureClass.classify_all(signals, tmsl, (tmsl['model'] || tmsl)['relationships'])
  S.build_b_metrics!(dm, tmsl, classes)
  [dm, tmsl, classes]
end

def c_entries(classes, *names)
  classes.select { |k, v| v['class'] == 'C' && names.include?(k.split('.', 2)[1]) }.map { |k, v| v.merge('key' => k) }
end

def element(dm, name)
  S.elements_of(dm).find { |e| e['name'] == name }
end

def col_formula(el, name)
  (el['columns'] || []).find { |c| S.display_name(c) == name }&.dig('formula')
end

REGION_CARRY = { 'name' => 'Store Region', 'formula' => '[Sales/Store/Store Region]',
                 'sql' => { 'name' => 'Store Region', 'expr' => 'cd0."STORE_REGION"',
                            'join' => { 'sql' => 'SELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_STORE"', 'alias' => 'cd0',
                                        'on' => 'cd0."STORE_KEY" = f."STORE_KEY"' } } }.freeze

# ---------------------------------------------------------------------------------------------------
puts "\ntest_decide_carries_until_factor"
# R56: carry order = ascending single-column cardinality; every multi-column size is a MEASURED prefix count
counts = { 'base' => 100, 'region' => 400, 'channel' => 300, 'product' => 50_000,
           'combined' => { 'channel|region' => 900, 'channel|region|product' => 90_000 } }
d = C.decide(counts)
check(C.carry_order(counts) == %w[channel region product], 'order: channel (300), region (400), product (50,000)', fails)
check(d['carry'] == %w[channel region] && d['live'] == true && d['counts'] == counts && d['combined_rows'] == 900, "base 100: carry channel and region (measured 900), live (#{d['carry'].inspect})", fails)
check(C.decide(counts) == d, 'deterministic', fails)
check(!d.key?('estimated'), 'no estimate path remains', fails)
tie = C.decide({ 'base' => 100, 'b' => 400, 'a' => 400, 'c' => 400, 'combined' => { 'a|b' => 700, 'a|b|c' => 2000 } })
check(tie['carry'] == %w[a b], "ties break by name: a, b carried, c exceeds (#{tie['carry'].inspect})", fails)
d2 = C.decide({ 'base' => 100, 'region' => 400, 'channel' => 300, 'combined' => { 'channel|region' => 900 } })
check(d2['carry'] == %w[channel region] && d2['live'] == false, 'every column fits: no live element', fails)
d3 = C.decide({ 'base' => 100, 'region' => 4000 })
check(d3['carry'] == [] && d3['live'] == true && d3['combined_rows'] == 100, 'a column beyond 10x is not carried; live', fails)
d4 = C.decide({ 'base' => 100, 'region' => 400, 'channel' => 300, 'combined' => { 'channel|region' => 2500 } })
check(d4['carry'] == %w[channel] && d4['live'] == true, 'singles fit (400, 300) but the measured pair (2,500 > 1,000) does not: only the first column is carried', fails)
miss = begin; C.decide({ 'base' => 100, 'region' => 400, 'channel' => 300 }); rescue C::MissingCount => e; e.message; end
check(miss.to_s.include?('channel|region'), "a missing prefix count raises, naming it (#{miss.inspect[0, 70]})", fails)
check(C.decide({ 'base' => 100, 'region' => 4000, 'channel' => 5000 })['carry'] == [], 'no prefix count needed once the first column already exceeds the bound', fails)
check((begin; C.decide({ 'base' => 0, 'a' => 1 }); rescue ArgumentError => e; e.message; end).to_s.include?('base'), 'a zero base is refused', fails)

puts "\ntest_decide_density_required_for_grouped"
gc = { 'base' => 100, 'region' => 400, 'channel' => 300, 'combined' => { 'channel|region' => 900 },
       'density' => { 'channel' => { 'present' => 36, 'expected' => 36 }, 'channel|region' => { 'present' => 100, 'expected' => 144 } } }
g1 = C.decide(gc, grouped: true)
check(g1['carry'] == %w[channel] && g1['dense'] == true && g1['stepped_back'] == true && g1['live'] == true, 'the pair is sparse: step back to the longest dense prefix (channel)', fails)
check(C.decide(gc)['carry'] == %w[channel region], 'density is not consulted for a non-grouped summary', fails)
g2 = C.decide(gc.merge('density' => gc['density'].merge('channel|region' => { 'present' => 144, 'expected' => 144 })), grouped: true)
check(g2['carry'] == %w[channel region] && g2['dense'] == true && g2['stepped_back'] == false && g2['live'] == false, 'a dense pair is carried', fails)
g3 = C.decide(gc.merge('density' => { 'channel' => { 'present' => 30, 'expected' => 36 }, 'channel|region' => { 'present' => 100, 'expected' => 144 } }), grouped: true)
check(g3['carry'] == [] && g3['live'] == true && g3['dense'].nil? && g3['stepped_back'] == true, 'every prefix sparse: nothing carried, live', fails)
miss = begin; C.decide(gc.reject { |k, _| k == 'density' }, grouped: true); rescue C::MissingCount => e; e.message; end
check(miss.to_s.include?('density'), "grouped without density counts raises (#{miss.inspect[0, 60]})", fails)
miss = begin; C.decide(gc.merge('density' => { 'channel|region' => { 'present' => 144, 'expected' => 144 } }), grouped: true); rescue C::MissingCount => e; e.message; end
check(miss.to_s.include?('density'), 'a missing density for the chosen prefix raises, not guessed', fails)
check(C.log_entry(page: 'P', summary: 'S', decision: g1, form: 'grouped')['reason'] == C::SPARSE, 'the log names the sparse step-back', fails)

puts "\ntest_size_queries"
q1 = C.size_queries('SELECT MONTH, SUM(X) AS V FROM T GROUP BY MONTH;', %w[REGION CHANNEL], dialect: 'snowflake', grain: ['MONTH'], period: 'MONTH')
check(q1.keys == %w[base REGION CHANNEL], "round 1: base and singles only (#{q1.keys.inspect})", fails)
q = C.size_queries('SELECT MONTH, SUM(X) AS V FROM T GROUP BY MONTH;', %w[REGION CHANNEL PRODUCT], dialect: 'snowflake', grain: ['MONTH'], period: 'MONTH', order: %w[CHANNEL REGION PRODUCT])
check(q.keys == ['base', 'REGION', 'CHANNEL', 'PRODUCT', 'density:CHANNEL', 'prefix:CHANNEL|REGION', 'density:CHANNEL|REGION', 'prefix:CHANNEL|REGION|PRODUCT', 'density:CHANNEL|REGION|PRODUCT'], "round 2 keys: #{q.keys.inspect}", fails)
check(q['base'].include?('SELECT DISTINCT "MONTH" FROM pbi_summary') && !q['base'].include?(';'), 'base counts the summary grain, trailing ; stripped', fails)
check(q['REGION'].include?('SELECT DISTINCT "MONTH", "REGION" FROM pbi_summary') && q['prefix:CHANNEL|REGION'].include?('SELECT DISTINCT "MONTH", "CHANNEL", "REGION" FROM pbi_summary'), 'a prefix count is DISTINCT(grain + prefix columns), in prefix order', fails)
dq = q['density:CHANNEL|REGION']
check(dq.include?('AS PRESENT') && dq.include?('AS EXPECTED') && dq.include?('"CHANNEL", "REGION", MONTH AS pbi_period') && dq.include?('pbi_c) *'), 'density query per prefix: present vs prefix combos x periods', fails)
check(C.size_queries('x', %w[A B], order: %w[A B]).keys == %w[base A B prefix:A|B], 'no period: no density queries', fails)
check((begin; C.size_queries('x', %w[A B], order: %w[A]); rescue ArgumentError => e; e.message; end).to_s.include?('order must list'), 'an order that is not the column set is refused', fails)
check(C.size_queries('SELECT 1', ['A'], dialect: 'databricks')['A'].include?('`A`'), 'databricks quotes with backticks', fails)
check((begin; C.size_queries('x', ['A'], dialect: 'oracle'); rescue ArgumentError => e; e.message; end).to_s.include?('unsupported dialect'), 'unknown dialect refused', fails)

# ---------------------------------------------------------------------------------------------------
# sqlite harness
PY = <<~'PYTHON'
  import json, sqlite3, sys
  cfg = json.load(sys.stdin)
  con = sqlite3.connect(':memory:')
  for ddl in cfg['ddl']:
      con.execute(ddl)
  for table, rows in cfg['data'].items():
      if rows:
          con.executemany('INSERT INTO %s VALUES (%s)' % (table, ','.join('?' * len(rows[0]))), rows)
  out = {}
  for name, sql in cfg['queries'].items():
      out[name] = con.execute(sql).fetchall()
  print(json.dumps(out))
PYTHON

def run_sqlite(ddl, data, queries)
  out, err, st = Open3.capture3('python3', '-I', '-c', PY, stdin_data: JSON.generate('ddl' => ddl, 'data' => data, 'queries' => queries))
  raise "sqlite failed: #{err.lines.last(3).join}" unless st.success?
  JSON.parse(out)
end

N_DAYS = 60
START = Date.new(2025, 1, 1)
DDL = ['CREATE TABLE DIM_DATE (DATE_KEY INTEGER, CAL_DATE TEXT)',
       'CREATE TABLE FACT (ORDER_DATE_KEY INTEGER, STORE_KEY INTEGER, QTY REAL, PRICE REAL)',
       'CREATE TABLE DIM_STORE (STORE_KEY INTEGER, STORE_REGION TEXT)'].freeze
STORES = [[1, 'West'], [2, 'East'], [3, 'West'], [4, nil]].freeze # store 4 has a NULL region; store key 99 below is unmatched
FACTS = begin
  rows = []
  (1..N_DAYS).each do |k|
    next unless k % 4 == 1 || k % 11 == 0 || k % 6 == 0
    rows << [k, [1, 2, 3, 4][k % 4], k % 5 + 1, 2.5]
    rows << [k, 2, 3, 1.25] if k % 7 == 0
    rows << [k, nil, 2, 2.0] if k % 13 == 0 # NULL key
    rows << [k, 99, 1, 3.0] if k % 17 == 0  # unmatched key
  end
  rows
end.freeze
DATA = { 'DIM_DATE' => (0...N_DAYS).map { |i| [i + 1, (START + i).iso8601] }, 'FACT' => FACTS, 'DIM_STORE' => STORES }.freeze
REGION_OF = ->(key) { (STORES.find { |s| s[0] == key } || [nil, nil])[1] }

# calendar oracle: rolling `win` days over the daily totals of `facts`, absent days = 0
def rolling_truth(facts, win)
  daily = Hash.new(0.0)
  facts.each { |f| daily[f[0]] += f[2] * f[3] }
  (0...N_DAYS).map { |i| ((i + 2 - win).clamp(1, N_DAYS)..(i + 1)).sum { |k| daily[k] } }
end

def sqlite_rolling_sql(carry: [], hook: nil, days: 28)
  G.rolling_sql(fact_sql: 'SELECT * FROM FACT', date_sql: 'SELECT * FROM DIM_DATE', measure_sql: 'SUM(f."QTY" * f."PRICE")',
                days: days, dialect: 'sqlite', fact_key: 'ORDER_DATE_KEY', date_key: 'DATE_KEY', date_col: 'CAL_DATE', carry: carry, hook: hook)
end

SQLITE_CARRY = [{ 'name' => 'Store Region', 'expr' => 'cd0."STORE_REGION"',
                  'join' => { 'sql' => 'SELECT * FROM DIM_STORE', 'alias' => 'cd0', 'on' => 'cd0."STORE_KEY" = f."STORE_KEY"' } }].freeze

puts "\ntest_carried_rolling_sql_matches_python_oracle_per_region"
sql = sqlite_rolling_sql(carry: SQLITE_CARRY)
check(sql.include?('pbi_combos') && sql.include?('CROSS JOIN pbi_combos') && sql.include?('PARTITION BY spine."Store Region"') &&
      sql.include?('GROUP BY dd."CAL_DATE", cd0."STORE_REGION"'), 'GROUP BY and PARTITION BY carry the field, spine x combos', fails)
check(sqlite_rolling_sql == G.rolling_sql(fact_sql: 'SELECT * FROM FACT', date_sql: 'SELECT * FROM DIM_DATE', measure_sql: 'SUM(f."QTY" * f."PRICE")',
                                          days: 28, dialect: 'sqlite', fact_key: 'ORDER_DATE_KEY', date_key: 'DATE_KEY', date_col: 'CAL_DATE') &&
      !sqlite_rolling_sql.include?('pbi_combos'), 'no carry, no hook: the SQL is the uncarried form', fails)
res = run_sqlite(DDL, DATA, 'carried' => sql)
rows = res['carried']
by_region = rows.group_by { |r| r[1] }
regions = FACTS.map { |f| REGION_OF.call(f[1]) }.uniq
check(by_region.keys.sort_by(&:to_s) == regions.sort_by(&:to_s), "one window per region incl. the blank one (#{by_region.keys.inspect})", fails)
check(rows.length == N_DAYS * regions.length, "dense: every (region, day) has a row (#{rows.length} = #{N_DAYS} x #{regions.length})", fails)
bad = 0
regions.each do |reg|
  truth = rolling_truth(FACTS.select { |f| REGION_OF.call(f[1]) == reg }, 28)
  got = by_region[reg].sort_by { |r| r[0] }
  bad += got.each_with_index.count { |r, i| r[0] != (START + i).iso8601 || ((r[2] || 0) - truth[i]).abs > 1e-9 }
end
check(bad.zero?, "every region's 28-day window equals the calendar oracle on all #{N_DAYS} days (#{bad} differ)", fails)
sums = (0...N_DAYS).map { |i| rows.select { |r| r[0] == (START + i).iso8601 }.sum { |r| r[2] || 0 } }
total = rolling_truth(FACTS, 28)
check(sums.each_with_index.all? { |v, i| (v - total[i]).abs < 1e-9 }, 'Sum over the regions (no pick) = the all-region rolling total on every day', fails)
pick = (0...N_DAYS).map { |i| rows.select { |r| r[0] == (START + i).iso8601 && r[1] == 'West' }.sum { |r| r[2] || 0 } }
west = rolling_truth(FACTS.select { |f| REGION_OF.call(f[1]) == 'West' }, 28)
check(pick.each_with_index.all? { |v, i| (v - west[i]).abs < 1e-9 } && pick != total, 'a West pick (rows filtered by region, then Sum) = West-only truth and differs from the total', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_live_sql_matches_python_oracle_for_picks"
STORE_SLICER = { 'control_id' => 'Region Ctl', 'column' => 'STORE_REGION',
                 'path' => [{ 'from_source' => 'DIM_STORE', 'from_col' => 'STORE_KEY', 'to_col' => 'STORE_KEY', 'type' => '1:M' }] }.freeze
base_sql = sqlite_rolling_sql(hook: 'Sales')
live = C.live_sql(base_sql, [STORE_SLICER], dialect: 'sqlite')
check(live.scan('{{#formula ArrayLength([Region Ctl])}} = 0').length == 1 && live.scan('{{Region Ctl}}').length == 2, 'one guard template per control; the value list is the {{Ctl}} form', fails)
check(live !~ /union/i && !live.include?('> 0'), 'no union and no closed gate branch', fails)
check(live.index('WHERE 1 = 1 /*@slicers') < live.index('AND (CASE WHEN') && live.index('AND (CASE WHEN') < live.index('GROUP BY dd'), 'the predicate sits on the fact rows, before the GROUP BY and the window', fails)
check(live.include?("'(Blank)' IN {{Region Ctl}} AND (f.\"STORE_KEY\" IS NULL OR f.\"STORE_KEY\" NOT IN (SELECT sjb.\"STORE_KEY\" FROM DIM_STORE sjb WHERE sjb.\"STORE_KEY\" IS NOT NULL))") &&
      live.include?("COALESCE(CAST(sj1.\"STORE_REGION\" AS VARCHAR), '(Blank)') IN {{Region Ctl}}"), '(Blank): attribute coalesced, plus NULL / unmatched fact keys', fails)

render = lambda do |sql, picks|
  sql.gsub(/\{\{#formula ArrayLength\(\[([^\]]+)\]\)\}\}/) { picks.fetch(Regexp.last_match(1), []).length.to_s }
     .gsub(/\{\{([^}#]+)\}\}/) { "(#{(picks[Regexp.last_match(1)] || ['']).map { |v| "'#{v}'" }.join(', ')})" }
end
picks_cases = [[], ['West'], ['East'], ['(Blank)'], ['West', '(Blank)']]
queries = picks_cases.each_with_index.map { |pk, i| ["p#{i}", render.call(live, 'Region Ctl' => pk)] }.to_h
res = run_sqlite(DDL, DATA, queries)
picks_cases.each_with_index do |pk, i|
  keep = FACTS.select do |f|
    reg = REGION_OF.call(f[1])
    pk.empty? || pk.include?(reg.nil? ? '(Blank)' : reg)
  end
  truth = rolling_truth(keep, 28)
  got = res["p#{i}"].sort_by { |r| r[0] }
  mism = got.each_with_index.count { |r, j| ((r[1] || 0) - truth[j]).abs > 1e-9 } # m5: an empty window is NULL (blank), the oracle counts 0
  check(got.length == N_DAYS && mism.zero?, "pick #{pk.inspect}: #{N_DAYS} days equal the filtered-facts oracle (#{mism} differ)", fails)
end
check(res['p1'].map { |r| r[1].to_f } != res['p0'].map { |r| r[1].to_f }, 'a pick changes the numbers', fails)
two = C.live_sql(base_sql, [STORE_SLICER, STORE_SLICER.merge('control_id' => 'Other Ctl', 'column' => 'STORE_REGION')], dialect: 'sqlite')
check(two.scan('{{#formula ArrayLength([').length == 2 && two.scan('AND (CASE WHEN').length == 2, 'two controls: one guard each, ANDed', fails)
typed = C.live_sql(base_sql, [{ 'control_id' => 'N', 'column' => 'QTY', 'path' => [], 'typed' => true }], dialect: 'sqlite')
check(typed.include?('f."QTY" IN {{N}}') && !typed.include?('(Blank)'), 'a typed control compares the raw column with no (Blank) member', fails)
check((begin; C.live_sql('SELECT 1', [STORE_SLICER], dialect: 'sqlite'); rescue C::NoHook => e; e.message; end).to_s.include?('no /*@slicers'), 'SQL without a hook is refused (page left as built)', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_live_element_name_and_single_element"
summary = { 'id' => 'dm-sum', 'name' => 'Sales Trend – summary',
            'source' => { 'kind' => 'sql', 'connectionId' => 'conn-1', 'statement' => base_sql },
            'columns' => [{ 'id' => 'sc0', 'name' => 'Day', 'formula' => '[Custom SQL/DAY]' },
                          { 'id' => 'sc1', 'name' => 'Sales R28', 'formula' => '[Custom SQL/VALUE]', 'format' => { 'kind' => 'number' } }] }
chart = { 'id' => 'ch1', 'kind' => 'line-chart', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'dm-sum' },
          'columns' => [{ 'id' => 'a', 'formula' => '[Sales Trend – summary/Day]' }, { 'id' => 'b', 'formula' => 'Max([Sales Trend – summary/Sales R28])' }] }
other = { 'id' => 'ch2', 'kind' => 'table', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'other-el' }, 'columns' => [] }
ctl = { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'Region Ctl', 'filters' => [] }
page = { 'id' => 'p1', 'name' => 'Trends', 'elements' => [ctl, chart, other] }
pages = [page]
el = D.live_element!(page, summary, [STORE_SLICER], dialect: 'sqlite')
check(el['name'] == 'Sales Trend – summary – live, filtered by your slicer picks', "name: #{el['name']}", fails)
check(el['kind'] == 'table' && el['source']['kind'] == 'sql' && el['source']['connectionId'] == 'conn-1' && el['description'].to_s.include?('applied to the underlying rows'), 'a workbook Custom SQL element with a description', fails)
check(el['source']['statement'] == live && el['source']['statement'] !~ /union/i, 'its SQL is the summary SQL plus the predicate; no union', fails)
check(page['elements'].count { |e| e['name'].to_s.end_with?('live, filtered by your slicer picks') } == 1, 'exactly one live element on the page', fails)
check(chart['source'] == { 'kind' => 'table', 'elementId' => el['id'] } && other['source']['elementId'] == 'other-el', 'the chart that read the summary is repointed; others untouched', fails)
check(chart['columns'][0]['formula'] == "[#{el['id']}/Day]" && chart['columns'][1]['formula'] == "Max([#{el['id']}/Sales R28])", "its formulas read the live element: #{chart['columns'].map { |c| c['formula'] }.inspect}", fails)
check(el['columns'].map { |c| [c['name'], c['formula']] } == [['Day', '[Custom SQL/DAY]'], ['Sales R28', '[Custom SQL/VALUE]'], ['Slicer Filter Count', 'ArrayLength([Region Ctl])']] &&
      el['columns'][1]['format'] == { 'kind' => 'number' }, 'summary columns kept (with format) plus a Slicer Filter Count that names the control', fails)
check(D.live_element!(page, summary, [STORE_SLICER], dialect: 'sqlite').equal?(el) && page['elements'].length == 4, 'a second call returns the same element and adds nothing', fails)
other_sum = summary.merge('id' => 'dm-sum2', 'name' => 'Other summary')
check((begin; D.live_element!(page, other_sum, [STORE_SLICER], dialect: 'sqlite'); rescue ArgumentError => e; e.message; end).to_s.include?('one per page'), 'a second summary on the same page gets no second live element (one per page)', fails)
check(!D.summary_still_read?(pages, summary), 'nothing reads the summary any more: it need not be built', fails)
check(D.summary_still_read?([{ 'elements' => [{ 'id' => 'z', 'kind' => 'table', 'source' => { 'kind' => 'data-model', 'elementId' => 'dm-sum' } }] }], summary), 'a reader on another page keeps the summary', fails)
check((begin; D.live_element!({ 'elements' => [] }, summary, [], dialect: 'sqlite'); rescue ArgumentError => e; e.message; end).to_s.include?('no slicer controls'), 'no controls: refused', fails)
check((begin; D.live_element!({ 'elements' => [] }, summary.merge('source' => { 'kind' => 'table' }), [STORE_SLICER], dialect: 'sqlite'); rescue ArgumentError => e; e.message; end).to_s.include?('not a Custom SQL'), 'a non-SQL summary is refused', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_grouped_carry_outer_levels_sum_consumers"
dm, tmsl, classes = setup
cfg = { 'Sales' => { 'columns' => [REGION_CARRY], 'dense' => true, 'live' => false } }
res = G.generate!(dm, c_entries(classes, 'Sales YTD', 'Sales PY', 'Sales YoY %'), date_element: 'Date', dialect: 'snowflake', tmsl: tmsl, slicer_carry: cfg)
by = res.map { |r| [r['measure'], r] }.to_h
check(res.length == 3 && res.all? { |r| r['form'] == 'grouped' && r['consumer_agg'] == 'Sum' && r['carried'] == ['Store Region'] }, 'three grouped entries, consumer_agg Sum (R43), carried names listed', fails)
el = element(dm, 'Sales by month')
ids = el['columns'].map { |c| [S.display_name(c), c['id']] }.to_h
g = el['groupings']
ints = [ids['Year Number'], ids['Quarter Number'], ids['Month Number']]
check(g.map { |x| x['groupBy'] } == [[ids['Store Region']], [ids['Year']], [ids['Month']]], "levels outer to inner: Store Region, Year, Month (P15; I2: the integer date columns are calculations of the Month level, not keys): #{g.map { |x| x['groupBy'] }.inspect}", fails)
check(g[0]['calculations'].nil? && g[1]['calculations'].nil? && g[2]['calculations'].length == (el['columns'].length - 3) && ints.all? { |i| g[2]['calculations'].include?(i) }, 'the calculations sit on the innermost (Month) level only', fails)
check(col_formula(el, 'Store Region') == '[Sales/Store/Store Region]' && col_formula(el, 'Sales YTD') == 'CumulativeSum([Sales Amount])' &&
      col_formula(el, 'Sales PY') == 'DateLookback([Sales Amount], [Month], 1, "year")', 'carried field is a column; YTD and PY keep their formulas (per region, per year)', fails)
check(el['description'].include?('Store Region is carried as the outermost level') && el['description'].include?('Sum()'), 'the description says what was carried and to read with Sum', fails)
check(col_formula(el, 'Sales YoY %').nil? && col_formula(el, 'Sales YoY % (numerator)') == '[Sales Amount] - Coalesce([Sales PY], 0)' && col_formula(el, 'Sales YoY % (denominator)') == '[Sales PY]', 'YoY % is carried as numerator and denominator (R19), not as a summable ratio', fails)
check(by['Sales.Sales YoY %']['ratio'] == { 'numerator' => 'Sales YoY % (numerator)', 'denominator' => 'Sales YoY % (denominator)' } && by['Sales.Sales YoY %']['column'] == 'Sales YoY % (numerator)', 'the record names the split', fails)
# direct map follows consumer_agg and the ratio
mid = 'master-x'
keys = { el => 'k' }
masters = { 'k' => { 'id' => mid } }
fields = {}
unresolved = []
res.each { |r| PbiDirectMap.bind_time_intel(fields, masters, keys, [el], r['measure'], res, unresolved) }
check(fields['Sales.Sales YTD']['formula'] == "Sum(If([#{mid}/Month] = Max([#{mid}/Month]), [#{mid}/Sales YTD], Null))", "carried YTD sums the carried values on the latest period in scope: #{fields['Sales.Sales YTD']['formula']}", fails)
check(fields['Sales.Sales PY']['formula'] == "Sum([#{mid}/Sales PY])", 'carried PY sums the carried values over the periods in scope', fails)
check(fields['Sales.Sales YoY %']['formula'] == "Sum([#{mid}/Sales YoY % (numerator)]) / NullIf(Sum([#{mid}/Sales YoY % (denominator)]), 0)", 'YoY % is summed then divided in the consumer', fails)
dm0, tmsl0, classes0 = setup
res0 = G.generate!(dm0, c_entries(classes0, 'Sales YTD', 'Sales PY', 'Sales YoY %'), date_element: 'Date', dialect: 'snowflake', tmsl: tmsl0)
el0 = element(dm0, 'Sales by month')
check(res0.all? { |r| r['consumer_agg'] == 'Max' && !r.key?('ratio') && !r.key?('carried') } && el0['groupings'].length == 2 && col_formula(el0, 'Sales YoY %'), 'with no carry nothing changes: Max consumers, two levels', fails)
fields0 = {}
res0.each { |r| PbiDirectMap.bind_time_intel(fields0, { 'k' => { 'id' => mid } }, { el0 => 'k' }, [el0], r['measure'], res0, []) }
check(fields0['Sales.Sales YTD']['formula'] == "Sum(If([#{mid}/Month] = Max([#{mid}/Month]), [#{mid}/Sales YTD], Null))", 'uncarried YTD reads the latest period too', fails)
check(fields0['Sales.Sales YoY %']['formula'] == "(Sum([#{mid}/Sales Amount]) - Sum([#{mid}/Sales PY])) / NullIf(Sum([#{mid}/Sales PY]), 0)", 'uncarried YoY % is a ratio of the summed base and prior', fails)

puts "\ntest_carried_yoy_numerator_coalesces_missing_py"
# one region lacks a prior year: Power BI's total subtracts only the PY that exists
cur = { 'West' => 100.0, 'East' => 50.0 }
py = { 'West' => 80.0, 'East' => nil }
num = cur.keys.map { |r| cur[r] - (py[r] || 0) }.sum # what Sum(numerator) gives with Coalesce
den = py.values.compact.sum
check((num / den - (150.0 - 80.0) / 80.0).abs < 1e-12, 'Sum(numerator)/Sum(denominator) = (total current - total PY) / total PY when East has no PY', fails)
naive = cur.keys.map { |r| py[r].nil? ? nil : cur[r] - py[r] }.compact.sum
check((naive / den - (150.0 - 80.0) / 80.0).abs > 0.1, 'a plain [b] - [py] numerator would drop East (NULL) and give the wrong total', fails)
check(col_formula(element(dm, 'Sales by month'), 'Sales YoY % (numerator)') == '[Sales Amount] - Coalesce([Sales PY], 0)', 'the generated numerator coalesces the PY', fails)

puts "\ntest_carry_two_columns_levels_in_order"
dm, tmsl, classes = setup
two_cfg = { 'Sales' => { 'columns' => [REGION_CARRY, { 'name' => 'Channel', 'formula' => '[Sales/Store/Channel]' }], 'dense' => true } }
G.generate!(dm, c_entries(classes, 'Sales YTD'), date_element: 'Date', dialect: 'snowflake', tmsl: tmsl, slicer_carry: two_cfg)
el = element(dm, 'Sales by month')
ids = el['columns'].map { |c| [S.display_name(c), c['id']] }.to_h
check(el['groupings'].map { |x| x['groupBy'] } == [[ids['Store Region']], [ids['Channel']], [ids['Year']], [ids['Month']]], 'two carried columns both above Year', fails)

puts "\ntest_sparse_or_live_refuses_carry_on_grouped"
{ 'sparse' => { 'columns' => [REGION_CARRY], 'dense' => false }, 'beyond 10x' => { 'columns' => [REGION_CARRY], 'live' => true, 'dense' => true } }.each do |label, c|
  dmx, tmslx, classesx = setup
  rx = G.generate!(dmx, c_entries(classesx, 'Sales YTD', 'Sales PY'), date_element: 'Date', dialect: 'snowflake', tmsl: tmslx, slicer_carry: { 'Sales' => c })
  check(rx.empty? && rx.reclassified.length == 2 && rx.reclassified.all? { |r| r['reason'].include?('needs a live summary') }, "#{label}: both measures reclassified D (#{rx.reclassified.map { |r| r['reason'] }.uniq.inspect})", fails)
  check(element(dmx, 'Sales by month').nil?, "#{label}: the element does not exist", fails)
end
dmx, tmslx, classesx = setup
entries = c_entries(classesx, 'Sales YTD')
G.generate!(dmx, entries, date_element: 'Date', dialect: 'snowflake', tmsl: tmslx, slicer_carry: { 'Sales' => { 'columns' => [REGION_CARRY], 'live' => true } })
check(entries[0]['class'] == 'D' && entries[0]['reason'] == C::NEEDS_LIVE, "the class entry is D with reason: #{entries[0]['reason']}", fails)
dmx, tmslx, classesx = setup
rx = G.generate!(dmx, c_entries(classesx, 'Sales YTD', 'Sales YTD (As Of)', 'Sales R28'), date_element: 'Date', dialect: 'snowflake', tmsl: tmslx,
                 slicer_carry: { 'Sales' => { 'columns' => [REGION_CARRY], 'live' => true } })
check(rx.map { |r| r['form'] }.sort == %w[metric rolling_sql] && rx.reclassified.length == 1, 'as-of metrics and rolling summaries are still built; only the grouped measure is reclassified', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_carried_columns_present_on_rolling_summary"
dm, tmsl, classes = setup
res = G.generate!(dm, c_entries(classes, 'Sales R28'), date_element: 'Date', dialect: 'snowflake', tmsl: tmsl, slicer_carry: { 'Sales' => { 'columns' => [REGION_CARRY], 'dense' => true } })
roll = element(dm, 'Sales – rolling 28 days by day')
sql = roll['source']['statement']
check(roll['columns'].map { |c| c['name'] } == ['Day', 'Store Region', 'Sales R28'] && col_formula(roll, 'Store Region') == '[Custom SQL/Store Region]', "columns: #{roll['columns'].map { |c| c['name'] }.inspect}", fails)
check(res[0]['consumer_agg'] == 'Sum' && res[0]['carried'] == ['Store Region'] && res[0]['form'] == 'rolling_sql', 'record: Sum consumer, carried names', fails)
check(sql.include?('PARTITION BY spine."Store Region" ORDER BY spine."CAL_DATE"') && sql.include?(%(LEFT JOIN (\nSELECT * FROM "SAMPLE_DB"."ZZ_CLAUDE_PBI_SHAPED"."DIM_STORE"\n) cd0)) && sql.include?('/*@slicers fact="Sales" alias="f"*/'), 'SQL: PARTITION BY, the dimension join, and the live hook', fails)
check(roll['description'].include?('Store Region carried') && roll['description'].include?('latest day'), 'description names the carried field', fails)
fields = {}
PbiDirectMap.bind_time_intel(fields, { 'k' => { 'id' => mid } }, { roll => 'k' }, [roll], res[0]['measure'], res, [])
check(fields['Sales.Sales R28']['formula'] == "Sum(If([#{mid}/Day] = Max([#{mid}/Day]), [#{mid}/Sales R28], Null))", 'direct map: Sum over the carried rows of the latest day', fails)
dm_u, _t, classes_u = setup
G.generate!(dm_u, c_entries(classes_u, 'Sales R28'), date_element: 'Date', dialect: 'snowflake')
usql = element(dm_u, 'Sales – rolling 28 days by day')['source']['statement']
check(!usql.include?('pbi_combos') && !usql.include?('PARTITION BY') && usql.include?('/*@slicers fact="Sales"'), 'uncarried rolling SQL has no combos or PARTITION BY (hook only)', fails)
live_trends = C.live_sql(usql, [STORE_SLICER.merge('control_id' => 'Store Region Ctl')], dialect: 'snowflake')
check(live_trends.include?('{{#formula ArrayLength([Store Region Ctl])}} = 0'), 'the trends rolling summary takes a live predicate through its hook', fails)

# ---------------------------------------------------------------------------------------------------
puts "\ntest_decision_log"
dec = C.decide({ 'base' => 100, 'region' => 400, 'channel' => 300, 'product' => 50_000, 'combined' => { 'channel|region' => 900, 'channel|region|product' => 90_000 } })
e1 = C.log_entry(page: 'Trends', summary: 'Trends – summary', decision: dec, form: 'summary', live_element: 'Trends – summary – live, filtered by your slicer picks')
check(e1['base'] == 100 && e1['counts'] == { 'region' => 400, 'channel' => 300, 'product' => 50_000 } && e1['carry'] == %w[channel region] &&
      e1['live'] == true && e1['dense'].nil? && e1['reason'] == C::NEEDS_LIVE && e1['tradeoff'].include?('live, filtered by your slicer picks') &&
      e1['tradeoff'].include?('channel, region'), 'log entry: base, counts, density, carry, live, reason, trade-off', fails)
e2 = C.log_entry(page: 'Trends', summary: 'Sales by month', decision: C.decide({ 'base' => 100, 'region' => 400, 'density' => { 'region' => { 'present' => 10, 'expected' => 12 } } }, grouped: true), form: 'grouped')
check(e2['live'] == true && e2['carry'] == [] && e2['reason'] == C::SPARSE, 'a sparse grouped decision says why', fails)
Dir.mktmpdir do |dir|
  path = C.write_log(File.join(dir, 'slicer-carry.json'), [e1, e2])
  back = JSON.parse(File.read(path))
  check(back['summaries'].length == 2 && back['summaries'][0]['page'] == 'Trends' && back['summaries'][0]['carry'] == %w[channel region], 'slicer-carry.json round-trips', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.length} FAILED:"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
