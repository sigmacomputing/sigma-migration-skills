#!/usr/bin/env ruby
# test-build-oracle-sql.rb — unit smoke test for build-oracle-sql.rb (DAX→warehouse
# SQL oracle for offline Phase 6 parity). Pure, no network. Run:
#   ruby scripts/test-build-oracle-sql.rb
require_relative 'build-oracle-sql'

$fail = 0
def ok(name, cond); puts((cond ? '  ok  ' : 'FAIL  ') + name); $fail += 1 unless cond; end

# ---- transpile(): aggregate grammar ----
ok 'SUM',            OracleSql.transpile('SUM(Orders[Sales])') == 'SUM(SALES)'
ok 'AVERAGE->AVG',   OracleSql.transpile('AVERAGE(Orders[Discount])') == 'AVG(DISCOUNT)'
ok 'MIN',            OracleSql.transpile('MIN(Orders[Sales])') == 'MIN(SALES)'
ok 'DISTINCTCOUNT',  OracleSql.transpile('DISTINCTCOUNT(Orders[Order Id])') == 'COUNT(DISTINCT ORDER_ID)'
ok 'COUNTROWS->*',   OracleSql.transpile('COUNTROWS(Orders)') == 'COUNT(*)'
ok 'DIVIDE ratio',   OracleSql.transpile('DIVIDE(SUM(Orders[Profit]), SUM(Orders[Sales]))') == 'SUM(PROFIT) / NULLIF(SUM(SALES),0)'
ok 'quoted table',   OracleSql.transpile("SUM('Fact Orders'[Sales])") == 'SUM(SALES)'

# ---- transpile(): unsupported -> nil (forces online/waiver fallback) ----
ok 'RANKX nil',      OracleSql.transpile('RANKX(ALL(Orders[Region]), [Total Sales])').nil?
ok 'CALCULATE nil',  OracleSql.transpile('CALCULATE(SUM(Orders[Sales]), Orders[Region]="West")').nil?
ok 'SAMEPERIOD nil', OracleSql.transpile('CALCULATE(SUM(F[Net]), SAMEPERIODLASTYEAR(D[Date]))').nil?

# ---- explicit column_map wins over the heuristic (PromoteHeaders / renamed) ----
ok 'column_map honored', OracleSql.transpile('SUM(Cust[Customer Name])', { 'Customer Name' => 'C2' }) == 'SUM(C2)'
fb = []
OracleSql.transpile('SUM(Orders[Sales])', {}, fb)
ok 'fallback tracked',   fb == ['Sales']

# ---- chart_sql(): scalar + grouped + unsupported ----
sc = OracleSql.chart_sql('Total Sales', 'SUM(Orders[Sales])', 'DB.SCH.T')
ok 'scalar sql', sc['supported'] && sc['sql'] == 'SELECT SUM(SALES) AS "Total Sales" FROM DB.SCH.T' && sc['dim_col'].nil?

gr = OracleSql.chart_sql('Sales by Region', 'SUM(Orders[Sales])', 'DB.SCH.T', dim: 'Region')
ok 'grouped sql', gr['supported'] &&
   gr['sql'] == 'SELECT REGION AS "Region", SUM(SALES) AS "Sales by Region" FROM DB.SCH.T GROUP BY REGION ORDER BY 2 DESC' &&
   gr['dim_col'] == 'Region'

uns = OracleSql.chart_sql('Exotic', 'RANKX(ALL(Orders[Region]),[X])', 'DB.SCH.T')
ok 'unsupported flagged', uns['supported'] == false && uns['reason'].include?('unsupported DAX')

nofqn = OracleSql.chart_sql('NoFqn', 'SUM(Orders[Sales])', nil)
ok 'missing fqn flagged', nofqn['supported'] == false && nofqn['reason'].include?('no fqn')

# ---- today-relative measures on the REPORT CLOCK (one clock for "today") ----
NYC = { 'timezone' => 'America/New_York', 'dialect' => 'snowflake' }.freeze
T = "CAST(CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP()) AS DATE)"
CM = { 'Date' => 'ORDER_DATE', 'Order Date' => 'ORDER_DATE', 'Sales' => 'SALES', 'Ship Date' => 'SHIP_DATE' }.freeze
MS = { 'Total Sales' => 'SUM(Orders[Sales])' }.freeze

l28 = OracleSql.transpile("CALCULATE(SUM(Orders[Sales]), DATESINPERIOD('Date'[Date], TODAY(), -28, DAY))", CM, [], clock: NYC)
ok 'DATESINPERIOD -28 DAY = (today-28, today]',
   l28 == "SUM(CASE WHEN ORDER_DATE > DATEADD('day', -28, #{T}) AND ORDER_DATE <= #{T} THEN SALES END)"
mtd = OracleSql.transpile("CALCULATE([Total Sales], DATESBETWEEN('Date'[Date], DATE(YEAR(TODAY()), MONTH(TODAY()), 1), TODAY()))",
                          CM, [], clock: NYC, measures: MS)
ok 'MTD via DATESBETWEEN + measure ref',
   mtd == "SUM(CASE WHEN ORDER_DATE BETWEEN DATE_TRUNC('month', #{T}) AND #{T} THEN SALES END)"
ytd = OracleSql.transpile("CALCULATE([Total Sales], DATESBETWEEN('Date'[Date], DATE(YEAR(TODAY()), 1, 1), TODAY()))",
                          CM, [], clock: NYC, measures: MS)
ok 'YTD', ytd == "SUM(CASE WHEN ORDER_DATE BETWEEN DATE_TRUNC('year', #{T}) AND #{T} THEN SALES END)"
qtd = OracleSql.transpile("CALCULATE([Total Sales], DATESBETWEEN('Date'[Date], DATE(YEAR(TODAY()), (QUARTER(TODAY())-1)*3+1, 1), TODAY()))",
                          CM, [], clock: NYC, measures: MS)
ok 'QTD', qtd == "SUM(CASE WHEN ORDER_DATE BETWEEN DATE_TRUNC('quarter', #{T}) AND #{T} THEN SALES END)"
today_rows = OracleSql.transpile('CALCULATE(COUNTROWS(Orders), Orders[Order Date] = TODAY())', CM, [], clock: NYC)
ok 'COUNTROWS filtered to today', today_rows == "COUNT(CASE WHEN ORDER_DATE = #{T} THEN 1 END)"
since = OracleSql.transpile('DATEDIFF(MAX(Shipments[Ship Date]), TODAY(), DAY)', CM, [], clock: NYC)
ok 'days since', since == "DATEDIFF('day', MAX(SHIP_DATE), #{T})"
fwd = OracleSql.transpile("CALCULATE(SUM(Orders[Sales]), DATESINPERIOD('Date'[Date], TODAY(), 7, DAY))", CM, [], clock: NYC)
ok 'DATESINPERIOD +7 DAY = [today, today+7)',
   fwd == "SUM(CASE WHEN ORDER_DATE >= #{T} AND ORDER_DATE < DATEADD('day', 7, #{T}) THEN SALES END)"
mon = OracleSql.transpile("CALCULATE(SUM(Orders[Sales]), DATESINPERIOD('Date'[Date], TODAY(), -1, MONTH))", CM, [], clock: NYC)
ok 'DATESINPERIOD -1 MONTH', mon == "SUM(CASE WHEN ORDER_DATE > DATEADD('month', -1, #{T}) AND ORDER_DATE <= #{T} THEN SALES END)"
ok 'TODAY() without a report clock is unsupported (never the warehouse session clock)',
   OracleSql.transpile('DATEDIFF(MAX(Shipments[Ship Date]), TODAY(), DAY)', CM).nil?
ok 'TOTALMTD (filter-context MTD) stays unsupported', OracleSql.transpile('TOTALMTD(SUM(Orders[Sales]), D[Date])', CM, [], clock: NYC).nil?
pinned = OracleSql.transpile('DATEDIFF(MAX(Shipments[Ship Date]), TODAY(), DAY)', CM, [],
                             clock: NYC.merge('as_of' => '2026-11-17T03:00:00Z'))
ok 'as_of pins the oracle clock to an instant',
   pinned == "DATEDIFF('day', MAX(SHIP_DATE), CAST(CONVERT_TIMEZONE('America/New_York', '2026-11-17T03:00:00Z'::TIMESTAMP_TZ) AS DATE))"
bq = OracleSql.transpile("CALCULATE(SUM(Orders[Sales]), DATESINPERIOD('Date'[Date], TODAY(), -28, DAY))", CM, [],
                         clock: { 'timezone' => 'UTC', 'dialect' => 'bigquery' })
ok 'BigQuery dialect', bq == "SUM(CASE WHEN ORDER_DATE > DATE_ADD(CURRENT_DATE('UTC'), INTERVAL -28 DAY) AND ORDER_DATE <= CURRENT_DATE('UTC') THEN SALES END)"

tc = OracleSql.chart_sql('Sales L28D by Region', "CALCULATE([Total Sales], DATESINPERIOD('Date'[Date], TODAY(), -28, DAY))",
                         'TJ.S.ORDERS', dim: 'Region', col_map: CM, clock: NYC, measures: MS)
ok 'chart_sql flags today_relative + echoes the clock',
   tc['supported'] && tc['today_relative'] == true && tc['clock']['timezone'] == 'America/New_York' &&
   tc['sql'].start_with?('SELECT REGION AS "Region", SUM(CASE WHEN ORDER_DATE >') && tc['sql'].include?('GROUP BY REGION')
plain = OracleSql.chart_sql('Total Sales', 'SUM(Orders[Sales])', 'TJ.S.ORDERS', col_map: CM, clock: NYC)
ok 'a clock-free chart is not today_relative', plain['supported'] && plain['today_relative'] == false
same_name = OracleSql.chart_sql('Column Sales', 'SUM(Orders[Sales])', 'TJ.S.ORDERS', col_map: CM, clock: NYC,
                                measures: { 'Sales' => 'DATEDIFF(MAX(Orders[Date]), TODAY(), DAY)' })
ok 'a qualified column is not mistaken for a same-named today-relative measure',
   same_name['supported'] && same_name['today_relative'] == false
noclk = OracleSql.chart_sql('Days Since', 'DATEDIFF(MAX(Shipments[Ship Date]), TODAY(), DAY)', 'TJ.S.SHIPMENTS', col_map: CM)
ok 'unsupported TODAY() chart says how to fix it', noclk['supported'] == false && noclk['reason'].include?('report_timezone')

# ---- review fixes: nested measures, blank grouped rows ----
NEST = { 'A' => 'DIVIDE([B], [C])', 'B' => "CALCULATE(SUM(Orders[Sales]), DATESINPERIOD('Date'[Date], TODAY(), -28, DAY))",
         'C' => 'SUM(Orders[Sales])' }.freeze
nest = OracleSql.chart_sql('Ratio', '[A]', 'TJ.S.ORDERS', col_map: CM, clock: NYC, measures: NEST)
ok 'today-relative through two measure hops', nest['supported'] && nest['today_relative'] == true && nest['clock']
nest_nc = OracleSql.chart_sql('Ratio', '[A]', 'TJ.S.ORDERS', col_map: CM, measures: NEST)
ok '... and without a clock the reason names the report clock', nest_nc['supported'] == false && nest_nc['reason'].include?('report_timezone')
cyc = OracleSql.today_relative?('[X]', { 'X' => '[Y]', 'Y' => '[X]' })
ok 'a measure cycle terminates', cyc == false
blank = OracleSql.chart_sql('L28 by Region', "CALCULATE(SUM(Orders[Sales]), DATESINPERIOD('Date'[Date], TODAY(), -28, DAY))",
                            'TJ.S.ORDERS', dim: 'Region', col_map: CM, clock: NYC)
ok 'grouped windowed SUM drops blank groups like Power BI (HAVING ... IS NOT NULL)',
   blank['sql'].include?('GROUP BY REGION HAVING SUM(CASE WHEN') && blank['sql'].include?('IS NOT NULL ORDER BY 2 DESC')
cnt = OracleSql.chart_sql('Today by Region', 'CALCULATE(COUNTROWS(Orders), Orders[Order Date] = TODAY())',
                          'TJ.S.ORDERS', dim: 'Region', col_map: CM, clock: NYC)
ok 'grouped windowed COUNT drops empty groups (HAVING ... > 0)', cnt['sql'].include?('HAVING COUNT(CASE WHEN') && cnt['sql'].include?('> 0 ORDER BY')
plain_g = OracleSql.chart_sql('Sales by Region', 'SUM(Orders[Sales])', 'TJ.S.ORDERS', dim: 'Region', col_map: CM, clock: NYC)
ok 'an unfiltered grouped chart is unchanged (no HAVING)', !plain_g['sql'].include?('HAVING')

puts(($fail.zero? ? 'ALL PASS' : "#{$fail} FAILED"))
exit($fail.zero? ? 0 : 1)
