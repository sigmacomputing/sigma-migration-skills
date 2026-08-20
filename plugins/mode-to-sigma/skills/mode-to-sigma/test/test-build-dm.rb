#!/usr/bin/env ruby
#   ruby test/test-build-dm.rb
require_relative '../scripts/build-dm'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== build_sql_element =="
query = { 'token' => 'q1', 'name' => 'Monthly Revenue', 'raw_query' => 'select order_date, revenue from orders',
          'columns' => ['ORDER_DATE', 'REVENUE'] }
el = build_sql_element(query, connection_id: 'conn-1')
eq(el['kind'], 'table', 'element kind is table')
eq(el['name'], 'Monthly Revenue', 'element name = query name (becomes the formula prefix)')
eq(el['source'], { 'kind' => 'sql', 'connectionId' => 'conn-1',
                    'statement' => 'select order_date, revenue from orders' }, 'sql source shape')
eq(el['columns'], [
  { 'id' => 'q1_ORDER_DATE', 'name' => 'Order Date', 'formula' => '[Custom SQL/ORDER_DATE]' },
  { 'id' => 'q1_REVENUE',    'name' => 'Revenue',     'formula' => '[Custom SQL/REVENUE]' }
], 'columns are formula-prefixed with the fixed [Custom SQL/...] sentinel, NEVER the element\'s own ' \
   'authored name -- Sigma does not honor a sql-kind element\'s own name for its own internal column ' \
   'self-references (live-verified 2026-07-30: a bare [<own name>/...] self-reference compiles to a ' \
   'Ref Cycle error, see hex-to-sigma/SKILL.md); id is qualified with the query token (bookkeeping only, never sent as a formula)')

puts "== build_sql_element: same-named column across two different queries never collides =="
query_a = { 'token' => 'q1', 'name' => 'Monthly Revenue', 'raw_query' => 'select order_month, revenue from widget_orders',
            'columns' => ['revenue'] }
query_b = { 'token' => 'q2', 'name' => 'Region Revenue', 'raw_query' => 'select region, revenue from widget_orders',
            'columns' => ['revenue'] }
el_a = build_sql_element(query_a, connection_id: 'conn-1')
el_b = build_sql_element(query_b, connection_id: 'conn-1')
id_a = el_a['columns'].first['id']
id_b = el_b['columns'].first['id']
eq(id_a == id_b, false, 'two different queries selecting the SAME raw column name (revenue) mint DIFFERENT column ids')
eq([id_a, id_b], ['q1_revenue', 'q2_revenue'], 'ids are qualified with each query\'s own token')
eq([el_a['columns'].first['formula'], el_b['columns'].first['formula']],
   ['[Custom SQL/revenue]', '[Custom SQL/revenue]'],
   'formulas always reference the fixed [Custom SQL/EXACT_SQL_OUTPUT_COLUMN_NAME] sentinel regardless of ' \
   'either element\'s own authored name -- only id (bookkeeping) differs across the two queries, never the formula')

puts "== signature_for (find-or-pick-dm.rb input) =="
report = { 'name' => 'Sigma Migration Test' }
sig = signature_for(report, [query])
eq(sig['tableau_workbook'], 'Sigma Migration Test', 'signature key is literally tableau_workbook (source-agnostic field, read verbatim by find-or-pick-dm.rb)')
eq(sig['referenced_columns'], ['ORDER_DATE', 'REVENUE'], 'referenced_columns = union of all query columns')
eq(sig['warehouse_tables'], ['CUSTOM_SQL'],
   'warehouse_tables carries the CUSTOM_SQL sentinel (not []) so find-or-pick-dm.rb\'s ' \
   'fqn_covers? can actually score a table_match instead of auto_picked being permanently unreachable')

query2 = { 'token' => 'q2', 'name' => 'Signups', 'raw_query' => 'select day, signups from users', 'columns' => ['DAY', 'SIGNUPS'] }
sig2 = signature_for(report, [query, query2])
eq(sig2['warehouse_tables'], ['CUSTOM_SQL'], 'warehouse_tables stays a single deduped CUSTOM_SQL sentinel across multiple all-SQL queries')

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
