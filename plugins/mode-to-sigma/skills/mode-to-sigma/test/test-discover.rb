#!/usr/bin/env ruby
#   ruby test/test-discover.rb
require_relative '../scripts/mode-discover'

ENV['MODE_ACCOUNT'] = 'acme' # Mode.account is called directly (unstubbed) below

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== columns_from_csv_header =="
eq(columns_from_csv_header("ORDER_DATE,REVENUE,REGION\n2026-01-01,100,West\n"),
   ['ORDER_DATE', 'REVENUE', 'REGION'], 'parses the header row only, preserves order')
eq(columns_from_csv_header("\"Order Date\",\"Revenue\"\n2026-01-01,100\n"),
   ['Order Date', 'Revenue'], 'strips CSV quoting from quoted aliases')

puts "== Finding 2: columns_from_csv_header uses real CSV parsing, not a bare comma-split =="
eq(columns_from_csv_header(%(ORDER_DATE,"Revenue, Net",REGION\n2026-01-01,100,West\n)),
   ['ORDER_DATE', 'Revenue, Net', 'REGION'],
   'a quoted header value with an embedded comma parses as one column, not two')
eq(columns_from_csv_header(%("Say ""Hi""",REVENUE\nx,100\n)),
   ['Say "Hi"', 'REVENUE'],
   'doubled-quote escaping inside a quoted header value unescapes to a single quote')

puts "== normalize_query =="
raw = { 'token' => 'q1', 'name' => 'Monthly Revenue', 'raw_query' => 'select * from orders',
        'data_source_id' => '49894' }
q = normalize_query(raw, columns: ['ORDER_DATE', 'REVENUE'])
eq(q, { 'token' => 'q1', 'name' => 'Monthly Revenue', 'raw_query' => 'select * from orders',
        'data_source_id' => '49894', 'columns' => ['ORDER_DATE', 'REVENUE'] }, 'normalize_query shape')

puts "== normalize_chart =="
raw = { 'token' => 'c1', 'view' => { 'selectedChart' => 'Line', 'x' => 'ORDER_DATE', 'y' => ['REVENUE'] } }
c = normalize_chart(raw, 'q1')
eq(c, { 'token' => 'c1', 'query_token' => 'q1',
        'view' => { 'selectedChart' => 'Line', 'x' => 'ORDER_DATE', 'y' => ['REVENUE'] } }, 'normalize_chart shape')

puts "== Finding I2: HAL _embedded-safety -- a response with NO _embedded key at all never crashes =="
# HAL commonly omits `_embedded` ENTIRELY when a collection is empty (not even
# `_embedded: {things: []}` -- the key can be absent outright). A Mode Report
# with a query that has zero charts is routine content, not an edge case.
eq(data_source_names({}), [], 'data_source_names on a response with NO _embedded key returns [] instead of raising NoMethodError')
eq(data_source_names({ '_embedded' => {} }), [], 'data_source_names on an _embedded hash missing data_sources also returns []')
eq(data_source_names({ '_embedded' => { 'data_sources' => [{ 'name' => 'Snowflake' }] } }), ['Snowflake'],
   'data_source_names still extracts real names when present (unchanged behavior)')

eq(queries_raw_for_report({}), [], 'queries_raw_for_report on a response with no _embedded key returns [] instead of raising')
eq(queries_raw_for_report({ '_embedded' => { 'queries' => [{ 'token' => 'q1' }] } }), [{ 'token' => 'q1' }],
   'queries_raw_for_report still extracts real queries when present')

eq(charts_for_query({}, 'q1'), [],
   'charts_for_query on a response with no _embedded key (e.g. a helper/staging query with zero charts -- ' \
   'routine, not an edge case) returns [] instead of raising')
eq(charts_for_query({ '_embedded' => {} }, 'q1'), [], 'charts_for_query on an _embedded hash missing charts also returns []')
eq(charts_for_query({ '_embedded' => { 'charts' => [{ 'token' => 'c1', 'view' => { 'selectedChart' => 'Line' } }] } }, 'q1'),
   [{ 'token' => 'c1', 'query_token' => 'q1', 'view' => { 'selectedChart' => 'Line' } }],
   'charts_for_query still normalizes real charts when present')

puts "== Finding I2: run_report_and_fetch_csvs -- a query_runs response with no _embedded key never crashes =="
orig_post = Mode.method(:post)
orig_follow = Mode.method(:follow)
Mode.define_singleton_method(:post) { |*_a, **_kw| { 'token' => 'run1', 'state' => 'succeeded' } }
Mode.define_singleton_method(:follow) { |_resource, _rel| {} } # no _embedded key at all
result = run_report_and_fetch_csvs('r1')
eq(result, {}, 'a query_runs response with no _embedded key at all degrades to {} instead of raising NoMethodError')
Mode.define_singleton_method(:post, orig_post)
Mode.define_singleton_method(:follow, orig_follow)

puts "== Finding I2: report_filters_for -- dig-safety AND the widened rescue (Mode::Error, NoMethodError) =="
orig_get = Mode.method(:get)
Mode.define_singleton_method(:get) { |*_a| {} } # no _embedded key
eq(report_filters_for('r1'), [], 'a report_filters response missing _embedded degrades to [] via dig-safety alone (no rescue needed)')

Mode.define_singleton_method(:get) { |*_a| raise Mode::Error, 'boom' }
eq(report_filters_for('r1'), [], 'a genuine Mode::Error still degrades to [] (unchanged behavior)')

Mode.define_singleton_method(:get) { |*_a| nil }
eq(report_filters_for('r1'), [],
   'a nil response (".dig" itself raising NoMethodError) is now ALSO caught by the widened rescue, not just Mode::Error')
Mode.define_singleton_method(:get, orig_get)

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
