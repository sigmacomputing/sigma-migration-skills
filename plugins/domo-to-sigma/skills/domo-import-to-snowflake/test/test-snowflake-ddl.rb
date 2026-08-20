#!/usr/bin/env ruby
# Unit tests for lib/snowflake_ddl.rb. No network.
#   ruby test/test-snowflake-ddl.rb

require_relative '../scripts/lib/snowflake_ddl'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== column_type =="
eq(SnowflakeDDL.column_type('STRING'), 'VARCHAR', 'STRING -> VARCHAR')
eq(SnowflakeDDL.column_type('LONG'), 'NUMBER(38,0)', 'LONG -> NUMBER(38,0)')
eq(SnowflakeDDL.column_type('DECIMAL'), 'FLOAT', 'DECIMAL -> FLOAT')
eq(SnowflakeDDL.column_type('DATE'), 'DATE', 'DATE -> DATE')
eq(SnowflakeDDL.column_type('DATETIME'), 'TIMESTAMP_NTZ', 'DATETIME -> TIMESTAMP_NTZ')
eq(SnowflakeDDL.column_type('string'), 'VARCHAR', 'lowercase domo type still maps')
eq(SnowflakeDDL.column_type('WEIRD_NEW_TYPE'), 'VARCHAR', 'unknown type defaults to VARCHAR, never raises')

puts "== unknown_types =="
cols = [{ 'name' => 'a', 'type' => 'STRING' }, { 'name' => 'b', 'type' => 'PERCENT' }, { 'name' => 'c', 'type' => 'PERCENT' }]
eq(SnowflakeDDL.unknown_types(cols), ['PERCENT'], 'dedups unrecognized types, ignores known ones')

puts "== quote_identifier =="
eq(SnowflakeDDL.quote_identifier('ORDER_ID'), '"ORDER_ID"', 'always quoted, even a plain uppercase identifier')
eq(SnowflakeDDL.quote_identifier('Order Id'), '"Order Id"', 'space is preserved inside the quotes')
eq(SnowflakeDDL.quote_identifier('a"b'), '"a""b"', 'embedded quote is doubled, not escaped with backslash')
# Snowflake case-folds an UNQUOTED identifier to upper case, which destroys the
# camelCase word boundary that domo-to-sigma's DomoSigma.display_name splits on
# ('IsClosed' -> 'Is Closed' vs 'ISCLOSED' -> 'ISCLOSED'), so the landed column
# stops matching the Domo-declared one in column_preflight.rb. Found live by the
# 48-card cold run (bead q5dz): 3/3 multi-word camelCase columns mismatched.
eq(SnowflakeDDL.quote_identifier('IsClosed'), '"IsClosed"', 'camelCase is quoted so Snowflake cannot case-fold it (bead q5dz)')
eq(SnowflakeDDL.quote_identifier('Account.Name'), '"Account.Name"', 'dotted name still quoted verbatim')

puts "== create_table_sql =="
sql = SnowflakeDDL.create_table_sql('DB', 'SCH', 'SURVEYS',
  [{ 'name' => 'RESPONSE_ID', 'type' => 'STRING' }, { 'name' => 'SCORE', 'type' => 'LONG' }])
ok(sql.include?('CREATE TABLE IF NOT EXISTS DB.SCH."SURVEYS"'), 'DDL names the target table, quoted')
ok(sql.include?('"RESPONSE_ID" VARCHAR'), 'first column typed and quoted')
ok(sql.include?('"SCORE" NUMBER(38,0)'), 'second column typed and quoted')

camel = SnowflakeDDL.create_table_sql('DB', 'SCH', 'PDP',
  [{ 'name' => 'IsClosed', 'type' => 'STRING' }, { 'name' => 'StageName', 'type' => 'STRING' }])
ok(camel.include?('"IsClosed" VARCHAR'), 'camelCase column keeps its exact source case in DDL (bead q5dz)')
ok(camel.include?('"StageName" VARCHAR'), 'second camelCase column keeps its exact source case')

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
