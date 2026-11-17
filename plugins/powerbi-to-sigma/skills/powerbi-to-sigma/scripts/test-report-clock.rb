#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline contract tests for scripts/lib/pbi_report_clock.rb — one clock for
# "today". Power BI evaluates TODAY()/NOW() on one clock (the service: UTC), but a
# naive migration evaluates it on two: Sigma's Today()/Now() (the Sigma account
# time zone) and warehouse CURRENT_DATE (the warehouse session time zone). The
# report clock pins both to one IANA time zone.

require 'json'
require 'time'
require_relative 'lib/pbi_report_clock'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

NY = 'America/New_York'

puts "\n1. timezone validation"
check.call(PbiReportClock.valid_timezone?('UTC'), 'UTC is valid')
check.call(PbiReportClock.valid_timezone?(NY), 'America/New_York is valid')
check.call(!PbiReportClock.valid_timezone?('America/Nowhere'), 'an unknown zone is rejected (no silent UTC fallback)')
check.call(!PbiReportClock.valid_timezone?("UTC'; DROP"), 'quote/semicolon injection is rejected')
check.call(!PbiReportClock.valid_timezone?(''), 'empty is rejected')
raised = begin
  PbiReportClock.validate_timezone!('Mars/Olympus')
  false
rescue ArgumentError
  true
end
check.call(raised, 'validate_timezone! raises ArgumentError on an unknown zone')

puts "\n2. clock expressions"
check.call(PbiReportClock.sigma_today(NY) == 'DateTrunc("day", ConvertTimezone(Now(), "America/New_York"))',
           'Sigma report-today pins Now() to the report zone, truncated to the day')
check.call(PbiReportClock.sigma_now(NY) == 'ConvertTimezone(Now(), "America/New_York")', 'Sigma report-now')
check.call(PbiReportClock.today_sql(NY, 'snowflake') ==
           "CAST(CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP()) AS DATE)",
           'Snowflake report-today is independent of the session TIMEZONE')
check.call(PbiReportClock.now_sql(NY, 'snowflake') ==
           "CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ",
           'Snowflake report-now is wall-clock time in the report zone')
check.call(PbiReportClock.today_sql(NY, 'bigquery') == "CURRENT_DATE('America/New_York')", 'BigQuery report-today')
check.call(PbiReportClock.today_sql(NY, 'databricks') ==
           "CAST(from_utc_timestamp(to_utc_timestamp(current_timestamp(), current_timezone()), 'America/New_York') AS DATE)",
           'Databricks report-today normalizes the session zone first')
pinned = PbiReportClock.today_sql(NY, 'snowflake', as_of: '2026-11-17T03:00:00Z')
check.call(pinned == "CAST(CONVERT_TIMEZONE('America/New_York', '2026-11-17T03:00:00Z'::TIMESTAMP_TZ) AS DATE)",
           'an explicit as-of instant replaces the live clock (reproducible oracle)')
bad_as_of = begin
  PbiReportClock.today_sql(NY, 'snowflake', as_of: "2026-11-17'; --")
  false
rescue ArgumentError
  true
end
check.call(bad_as_of, 'a malformed as-of instant is rejected')

puts "\n3. formula rewrite (Sigma)"
f = 'CountIf([Order Date] = Today())'
out = PbiReportClock.pin_formula(f, NY)
check.call(out == 'CountIf([Order Date] = DateTrunc("day", ConvertTimezone(Now(), "America/New_York")))',
           'Today() is pinned to the report clock')
check.call(PbiReportClock.pin_formula(out, NY) == out, 'pinning is idempotent')
check.call(PbiReportClock.pin_formula('DateDiff("day", Max([Ship Date]), Now())', NY) ==
           'DateDiff("day", Max([Ship Date]), ConvertTimezone(Now(), "America/New_York"))', 'Now() is pinned')
check.call(PbiReportClock.pin_formula('Concat("Today() ", [Today()])', NY) == 'Concat("Today() ", [Today()])',
           'string literals and [column refs] are never rewritten')
check.call(PbiReportClock.pin_formula('today( )', NY) == 'DateTrunc("day", ConvertTimezone(Now(), "America/New_York"))',
           'function names are case-insensitive, spacing tolerated')
check.call(PbiReportClock.pin_formula('Sum([Sales])', NY) == 'Sum([Sales])', 'a formula without a clock is untouched')
check.call(PbiReportClock.pin_formula(out, 'UTC') == out, 'pinning under another zone never re-zones or nests an explicit clock')

puts "\n4. SQL rewrite"
sql = 'SELECT CURRENT_DATE AS "Value"'
pin = PbiReportClock.pin_sql(sql, NY, 'snowflake')
check.call(pin == "SELECT CAST(CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP()) AS DATE) AS \"Value\"",
           'converter TODAY() calc table SQL is pinned')
check.call(PbiReportClock.pin_sql(pin, NY, 'snowflake') == pin, 'SQL pinning is idempotent')
window = %(WHERE "TS" >= DATEADD(month, -48, DATE_TRUNC('month', CURRENT_DATE())) AND x < CURRENT_TIMESTAMP)
w2 = PbiReportClock.pin_sql(window, NY, 'snowflake')
check.call(w2.include?("DATE_TRUNC('month', CAST(CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP()) AS DATE))") &&
           w2.include?("x < CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ"),
           'incremental-refresh windows: CURRENT_DATE() and CURRENT_TIMESTAMP are pinned')
lit = %(SELECT 'CURRENT_DATE' AS "CURRENT_DATE" -- CURRENT_DATE\nFROM t)
check.call(PbiReportClock.pin_sql(lit, NY, 'snowflake') == lit, 'strings, quoted identifiers and comments are never rewritten')
check.call(PbiReportClock.pin_sql('SELECT CURRENT_DATE()', NY, 'bigquery') == "SELECT CURRENT_DATE('America/New_York')",
           'BigQuery CURRENT_DATE() gains the zone argument')
check.call(PbiReportClock.pin_sql("SELECT CURRENT_DATE('UTC')", NY, 'bigquery') == "SELECT CURRENT_DATE('UTC')",
           'an already zoned BigQuery call is left alone')
check.call(PbiReportClock.pin_sql('SELECT GETDATE()', NY, 'snowflake').include?('CONVERT_TIMEZONE'), 'GETDATE() is pinned')

puts "\n5. scan finds the unpinned clock sites"
sites = PbiReportClock.session_clock_refs("SELECT CURRENT_DATE, SYSDATE(), 'now()' FROM t WHERE d < NOW()")
check.call(sites.sort == %w[CURRENT_DATE NOW SYSDATE], "session clock refs: #{sites.inspect}")
check.call(PbiReportClock.session_clock_refs(pin).empty?, 'a pinned statement has no session clock refs')
check.call(PbiReportClock.bare_formula_clocks('If(Today() > [D], Now(), Null)') == %w[Today Now], 'bare Today()/Now() in a formula')
check.call(PbiReportClock.bare_formula_clocks(out).empty?, 'a pinned formula has no bare clock')

puts "\n6. apply! over a converted data model + a workbook document"
dm = {
  'pages' => [{ 'elements' => [
    { 'id' => 'orders', 'name' => 'ORDERS', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[TJ S ORDERS] },
      'columns' => [{ 'id' => 'c', 'formula' => '[ORDERS/Order Date]' }],
      'metrics' => [{ 'name' => 'Orders Today', 'formula' => 'CountIf([Order Date] = Today())' },
                    { 'name' => 'Total', 'formula' => 'Sum([Sales])' }] },
    { 'id' => 'rd', 'kind' => 'table', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT CURRENT_DATE AS "Value"' },
      'columns' => [{ 'id' => 'v', 'formula' => '[Custom SQL/Value]' }] }
  ] }]
}
audit = PbiReportClock.apply!(dm, timezone: NY, dialect: 'snowflake', scope: 'data_model')
m = dm['pages'][0]['elements'][0]['metrics']
check.call(m[0]['formula'].include?('ConvertTimezone(Now(), "America/New_York")') && m[1]['formula'] == 'Sum([Sales])',
           'only the clock-bearing metric is rewritten')
check.call(dm['pages'][0]['elements'][1]['source']['statement'].include?("CONVERT_TIMEZONE('America/New_York'"),
           'the SQL element statement is rewritten')
check.call(audit['pinned'].size == 2 && audit['pinned'].map { |s| s['kind'] }.sort == %w[formula sql],
           "audit lists both pinned sites (#{audit['pinned'].size})")
check.call(audit['unpinned'].empty?, 'nothing is left unpinned')
again = PbiReportClock.apply!(dm, timezone: NY, dialect: 'snowflake', scope: 'data_model')
check.call(again['pinned'].empty? && again['already_pinned'] == 2, 'a second apply! is a no-op and counts the pinned sites')

wb = { 'elements' => [{ 'id' => 'k', 'columns' => [{ 'id' => 'x', 'formula' => 'SumIf([m/Sales], [m/Order Date] <= Today())' }],
                        'filters' => [{ 'condition' => { 'formula' => '[m/Order Date] > DateAdd("day", -7, Today())' } }] }] }
wa = PbiReportClock.apply!(wb, timezone: NY, dialect: 'snowflake', scope: 'workbook')
check.call(wa['pinned'].size == 2 && JSON.generate(wb).scan('ConvertTimezone(Now()').size == 2,
           'every nested formula in a workbook document is pinned (columns AND filter conditions)')
scan = PbiReportClock.scan({ 'elements' => [{ 'columns' => [{ 'formula' => 'Today()' }] }] })
check.call(scan.size == 1 && scan[0]['clock'] == 'Today', 'scan reports an unpinned workbook formula')

puts "\n7. local dates and the disagreement band"
check.call(PbiReportClock.local_date('2026-11-17T03:00:00Z', NY).to_s == '2026-11-16', '03:00Z is still 16 Nov in New York')
check.call(PbiReportClock.local_date('2026-11-17T03:00:00Z', 'UTC').to_s == '2026-11-17', '03:00Z is 17 Nov in UTC')
check.call(PbiReportClock.local_date('2026-11-17T15:00:00Z', 'Asia/Tokyo').to_s == '2026-11-18', 'Tokyo is ahead')
band = PbiReportClock.disagreement_band(NY, 'UTC', on: '2026-11-17')
check.call(band == { 'from' => '2026-11-17T00:00:00Z', 'to' => '2026-11-17T05:00:00Z' },
           "the New York vs UTC band on 17 Nov is 00:00-05:00Z (#{band.inspect})")
check.call(PbiReportClock.disagreement_band('UTC', 'Etc/UTC', on: '2026-11-17').nil?, 'UTC aliases never disagree')

puts "\n8. parity clock verdicts"
clock = { 'report_timezone' => NY, 'data_model' => { 'unpinned' => [] }, 'workbook' => { 'unpinned' => [] } }
oracle = { 'kind' => 'report-clock', 'timezone' => NY }
v = PbiReportClock.parity_verdict(clock: clock, oracle_clock: oracle,
                                  expected_as_of: '2026-11-17T03:00:00Z', actual_as_of: '2026-11-17T03:20:00Z')
check.call(v['ok'], "pinned Sigma + report-clock oracle in the band is OK (#{v['reason']})")
v = PbiReportClock.parity_verdict(clock: clock, oracle_clock: oracle,
                                  expected_as_of: '2026-11-17T04:55:00Z', actual_as_of: '2026-11-17T05:05:00Z')
check.call(!v['ok'] && v['reason'].include?('midnight'), 'oracle and actuals on different report days are refused')
unpinned = { 'report_timezone' => NY, 'sigma_org_timezone' => 'UTC',
             'data_model' => { 'unpinned' => [{ 'clock' => 'Today' }] }, 'workbook' => { 'unpinned' => [] } }
v = PbiReportClock.parity_verdict(clock: unpinned, oracle_clock: oracle,
                                  expected_as_of: '2026-11-16T15:00:00Z', actual_as_of: '2026-11-16T15:01:00Z')
check.call(!v['ok'] && v['sigma_clock'] == 'UTC' && v['reason'].include?('two clocks'),
           'bare Today() on a UTC org vs a New York oracle is refused at ANY hour (not just in the band)')
v = PbiReportClock.parity_verdict(clock: clock, oracle_clock: { 'kind' => 'warehouse-session', 'timezone' => nil },
                                  expected_as_of: '2026-11-16T15:00:00Z', actual_as_of: '2026-11-16T15:01:00Z')
check.call(!v['ok'] && v['oracle_clock'] == 'unknown', 'an oracle on the warehouse session clock is refused')
v = PbiReportClock.parity_verdict(clock: clock, oracle_clock: { 'kind' => 'powerbi-service', 'timezone' => 'UTC' },
                                  expected_as_of: '2026-11-16T15:00:00Z', actual_as_of: '2026-11-16T15:01:00Z')
check.call(!v['ok'] && v['reason'].include?('UTC'), 'the Power BI service (UTC) oracle is refused for a New York report')
v = PbiReportClock.parity_verdict(clock: nil, oracle_clock: oracle,
                                  expected_as_of: '2026-11-16T15:00:00Z', actual_as_of: '2026-11-16T15:01:00Z')
check.call(!v['ok'] && v['reason'].include?('report-clock.json'), 'no clock record → refused with the remedy')
utc_clock = { 'report_timezone' => 'UTC', 'sigma_org_timezone' => 'UTC',
              'data_model' => { 'unpinned' => [{ 'clock' => 'Today' }] }, 'workbook' => { 'unpinned' => [] } }
v = PbiReportClock.parity_verdict(clock: utc_clock, oracle_clock: { 'kind' => 'powerbi-service', 'timezone' => 'UTC' },
                                  expected_as_of: '2026-11-16T15:00:00Z', actual_as_of: '2026-11-16T15:01:00Z')
check.call(v['ok'], "a UTC report on a UTC org agrees even unpinned (#{v['reason']})")

puts "\n9. today-relative detection"
check.call(PbiReportClock.today_relative_dax?('CALCULATE([S], DATESINPERIOD(D[Date], TODAY(), -28, DAY))'), 'DAX TODAY()')
check.call(PbiReportClock.today_relative_dax?('UTCNOW()'), 'DAX UTCNOW()')
check.call(!PbiReportClock.today_relative_dax?('SUM(T[Today Flag])'), 'a column named Today is not a clock')
check.call(PbiReportClock.today_relative_formula?('DateTrunc("day", ConvertTimezone(Now(), "UTC"))'), 'pinned Sigma clock')
check.call(!PbiReportClock.today_relative_formula?('Sum([Today])'), 'a [Today] column ref is not a clock')

puts "\n10. review fixes"
# explicit zones are authored, never re-zoned; an off-clock zone is reported, not trusted
ny_pin = 'CountIf([D] = DateTrunc("day", ConvertTimezone(Now(), "America/New_York")))'
check.call(PbiReportClock.pin_formula(ny_pin, 'UTC') == ny_pin, 'an explicitly zoned Sigma clock is left as authored')
off = PbiReportClock.scan({ 'elements' => [{ 'columns' => [{ 'formula' => ny_pin }] }] }, report_timezone: 'UTC')
check.call(off.size == 1 && off[0]['zone'] == NY, "a clock pinned to another zone is reported as off-clock (#{off.inspect})")
check.call(PbiReportClock.scan({ 'elements' => [{ 'columns' => [{ 'formula' => ny_pin }] }] }, report_timezone: NY).empty?,
           'a clock pinned to the report zone is on-clock')
reused = { 'report_timezone' => 'UTC', 'sigma_org_timezone' => 'UTC',
           'data_model' => { 'unpinned' => off }, 'workbook' => { 'unpinned' => [] } }
v = PbiReportClock.parity_verdict(clock: reused, oracle_clock: { 'kind' => 'report-clock', 'timezone' => 'UTC' },
                                  expected_as_of: '2026-11-17T02:00:00Z', actual_as_of: '2026-11-17T02:01:00Z')
check.call(!v['ok'] && v['sigma_clock'] == NY, 'a reused DM pinned to New York cannot pass a UTC report')
three = "SELECT CONVERT_TIMEZONE('UTC', 'America/New_York', CURRENT_TIMESTAMP()) AS T"
check.call(PbiReportClock.pin_sql(three, NY, 'snowflake') == three, '3-arg CONVERT_TIMEZONE is already zoned (no double shift)')
la = "SELECT CONVERT_TIMEZONE('America/Los_Angeles', CURRENT_TIMESTAMP()) AS T -- CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())"
check.call(PbiReportClock.pin_sql(la, 'UTC', 'snowflake') == la, 'authored SQL zones and comments are left alone')
sql_off = PbiReportClock.scan({ 'elements' => [{ 'source' => { 'kind' => 'sql', 'statement' => la } }] }, report_timezone: 'UTC')
check.call(sql_off.map { |s| s['zone'] } == ['America/Los_Angeles'], 'an off-clock SQL zone is reported')
bq = PbiReportClock.scan({ 'elements' => [{ 'source' => { 'kind' => 'sql', 'statement' => "SELECT CURRENT_DATE('Asia/Tokyo')" } }] },
                         report_timezone: 'UTC', dialect: 'bigquery')
check.call(bq.size == 1 && bq[0]['zone'] == 'Asia/Tokyo', 'an off-clock BigQuery zone is reported')
# identifiers that merely look like clocks
alias_sql = 'SELECT updated AS now, t.now, x AS current_date, getdate FROM t'
check.call(PbiReportClock.pin_sql(alias_sql, NY, 'snowflake') == alias_sql, 'aliases / qualified columns named like clocks are untouched')
check.call(PbiReportClock.session_clock_refs(alias_sql).empty?, '... and are not reported')
# BigQuery CURRENT_TIMESTAMP is an absolute instant: not a session clock there
bq_ts = { 'elements' => [{ 'source' => { 'kind' => 'sql', 'statement' => 'SELECT CURRENT_TIMESTAMP() AS T' } }] }
check.call(PbiReportClock.scan(bq_ts, report_timezone: 'UTC', dialect: 'bigquery').empty?, 'BigQuery CURRENT_TIMESTAMP is not unpinned')
check.call(PbiReportClock.scan(bq_ts, report_timezone: 'UTC', dialect: 'snowflake').size == 1, 'Snowflake CURRENT_TIMESTAMP is')
# backslash-escaped quotes do not hide a clock
esc = "SELECT 'it\\'s' AS X, CURRENT_DATE AS D"
check.call(PbiReportClock.pin_sql(esc, NY, 'snowflake').include?("CONVERT_TIMEZONE('America/New_York'"),
           'a backslash-escaped quote does not swallow the following clock')
# warehouses without a pinning dialect: formulas pinned, SQL left and reported
pg = { 'elements' => [{ 'id' => 'e', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT CURRENT_DATE - 7 AS D' },
                        'columns' => [{ 'formula' => 'Today()' }] }] }
pa = PbiReportClock.apply!(pg, timezone: NY, dialect: nil, scope: 'data_model')
check.call(pg['elements'][0]['source']['statement'] == 'SELECT CURRENT_DATE - 7 AS D' &&
           pg['elements'][0]['columns'][0]['formula'].include?('ConvertTimezone') &&
           pa['unpinned'].map { |s| s['kind'] } == ['sql'],
           'an unsupported dialect: SQL untouched and recorded unpinned, formulas still pinned')
rec = PbiReportClock.record(timezone: NY, dialect: nil, data_model: pa)
check.call(rec['dialect'] == 'unsupported' && rec['warehouse_today_sql'].nil?, 'the record says the dialect is unsupported')
# no tz database on the host: fail closed for non-UTC report days
orig = PbiReportClock.method(:zoneinfo_dir)
PbiReportClock.define_singleton_method(:zoneinfo_dir) { nil }
begin
  closed = PbiReportClock.parity_verdict(clock: clock, oracle_clock: oracle,
                                         expected_as_of: '2026-11-17T03:00:00Z', actual_as_of: '2026-11-17T03:10:00Z')
  check.call(!closed['ok'] && closed['reason'].include?('time zone database'),
             'without a tz database a New York report day cannot be proven (fail closed)')
  check.call(PbiReportClock.local_date('2026-11-17T03:00:00Z', 'UTC').to_s == '2026-11-17', 'UTC still works without one')
ensure
  PbiReportClock.define_singleton_method(:zoneinfo_dir, orig)
end

puts
puts fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"
exit(fails.empty? ? 0 : 1)
