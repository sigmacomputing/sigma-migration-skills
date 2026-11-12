#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/pbi_native_query'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

native_m = lambda do |sql, post = nil|
  escaped = sql.gsub('"', '""').gsub("\n", '#(lf)')
  lines = [
    'let',
    "  Source = Value.NativeQuery(Snowflake.Databases(\"acct\"){[Name=\"ENTERPRISE\"]}[Data], \"#{escaped}\", null, [EnableFolding=true])#{post ? ',' : ''}"
  ]
  lines << post if post
  lines << "in #{post ? '#\"Renamed Columns\"' : 'Source'}"
  lines
end

cor_sql = <<~SQL.strip
  SELECT c.COST_CENTER, c.PROPERTY_ID, c.AMOUNT
  FROM ENTERPRISE.MASTER.COR_DETAIL c
  JOIN ENTERPRISE.MASTER.PROPERTY p ON p.ID = c.PROPERTY_ID
SQL
property_sql = <<~SQL.strip
  SELECT c.PROPERTY_ID, p.PROPERTY_NAME
  FROM ENTERPRISE.MASTER.COR_DETAIL c
  JOIN ENTERPRISE.MASTER.PROPERTY p ON p.ID = c.PROPERTY_ID
SQL

fixture = File.expand_path('../fixtures/native_query_cor_pl/model.bim', __dir__)
tmsl = JSON.parse(File.read(fixture))

puts "\n1. normalize array-valued calculation items"
normalized = PbiNativeQuery.normalize_tmsl(tmsl)
expr = normalized.dig('model', 'tables', 2, 'calculationGroup', 'calculationItems', 1, 'expression')
check.call(expr.is_a?(String) && expr.include?("SELECTEDMEASURE(),\n"), 'calculation-item expression is joined into a string')

puts "\n2. pinned converter runs, then compatibility layer restores native SQL"
Dir.mktmpdir('pbi-native-query-test') do |dir|
  input = File.join(dir, 'model.json')
  output = File.join(dir, 'result.json')
  shim = File.join(dir, 'convert.mjs')
  converter = File.expand_path('../converter/powerbi.mjs', __dir__)
  File.write(input, JSON.generate(normalized))
  File.write(shim, <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    const { convertPowerBIToSigma } = await import(pathToFileURL(#{converter.to_json}).href);
    const out = convertPowerBIToSigma(JSON.parse(readFileSync(#{input.to_json}, 'utf8')), { connectionId: 'conn' });
    writeFileSync(#{output.to_json}, JSON.stringify(out.model || out.sigmaDataModel || out));
  JS
  _out, err, status = Open3.capture3('node', shim)
  check.call(status.success?, "pinned converter accepts normalized calc group#{": #{err}" unless status.success?}")
  if status.success?
    dm = JSON.parse(File.read(output))
    result = PbiNativeQuery.apply!(dm, tmsl['model'])
    check.call(result['blockers'].empty?, 'native queries restore without blockers')
    sql_elements = dm['pages'][0]['elements'].select { |e| e.dig('source', 'kind') == 'sql' && %w[COR Property].include?(e['name']) }
    check.call(sql_elements.size == 2, 'two logical Custom SQL elements remain distinct')
    cor = sql_elements.find { |e| e['name'] == 'COR' }
    property = sql_elements.find { |e| e['name'] == 'Property' }
    check.call(cor&.dig('source', 'statement') == cor_sql, 'COR preserves the complete multi-join SQL')
    check.call(property&.dig('source', 'statement') == property_sql, 'Property preserves its distinct SQL')
    check.call(cor && cor['columns'].first['formula'] == '[Custom SQL/COST_CENTER]', 'column formula uses exact SQL output name')
    check.call(cor && cor['columns'].first['name'] == 'Cost Center', 'column keeps the Power BI display name')
    check.call(!dm['pages'][0]['elements'].any? { |e| e.dig('source', 'kind') == 'warehouse-table' && e.dig('source', 'path')&.last == 'COR_DETAIL' },
               'first FROM table is not emitted as the source architecture')
    view = dm['pages'][0]['elements'].find { |e| e['name'] == 'COR View' }
    check.call(view && view['columns'].all? { |c| !c['formula'].to_s.start_with?('[COR_DETAIL/') },
               'derived View references are re-prefixed to the logical table')
  end
end

puts "\n3. unsupported post-query M transforms are gated"
post_tmsl = JSON.parse(JSON.generate(tmsl))
post = '  #"Renamed Columns" = Table.RenameColumns(Source, {{"COST_CENTER", "Cost Center"}})'
post_tmsl['model']['tables'][0]['partitions'][0]['source']['expression'] = native_m.call(cor_sql, post)
native = PbiNativeQuery.native_queries(post_tmsl['model']).first
check.call(native.post_transform, 'post-NativeQuery transform is detected')

puts "\n4. connector Query option is extracted"
query = PbiNativeQuery.extract_from_expression(
  'Orders',
  'let Source = Sql.Database("server", "DB", [Query="SELECT ORDER_ID FROM dbo.orders"]) in Source'
)
check.call(query&.statement == 'SELECT ORDER_ID FROM dbo.orders', 'Query= SQL is preserved')

puts "\n5. Power Query steps after the native SQL are folded where exact"
steps_m = lambda do |sql, steps, nav: ''|
  escaped = sql.gsub('"', '""').gsub("\n", '#(lf)')
  body = ["  Source = Value.NativeQuery(Snowflake.Databases(\"acct\")#{nav}, \"#{escaped}\", null, [EnableFolding=true])"]
  body += steps
  "let\n#{body.join(",\n")}\nin\n  Last"
end
orders_sql = 'SELECT ORDER_ID, STATUS, QTY, ORDERDATE FROM SALES.ORDERS'
renames = [
  '  #"Renamed Columns" = Table.RenameColumns(Source,{{"ORDER_ID", "Order Id"}, {"ORDERDATE", "Order Date"}})',
  '  #"Changed Type" = Table.TransformColumnTypes(#"Renamed Columns",{{"Order Date", type date}})',
  '  Last = Table.RemoveColumns(#"Changed Type",{"QTY"})'
]
native = PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, renames))
fold = PbiNativeQuery.fold(native)
check.call(fold.unsupported.empty?, "renames, type changes and column removals all fold (#{fold.unsupported.inspect})")
check.call(fold.source_name('Order Id') == 'ORDER_ID' && fold.source_name('Order Date') == 'ORDERDATE' &&
             fold.source_name('STATUS') == 'STATUS',
           'renamed columns bind to the name the SQL returns; untouched ones keep theirs')
check.call(fold.statement == orders_sql, 'renames and types leave the SQL itself unchanged')
check.call(fold.notes.any? { |n| n.include?('Table.TransformColumnTypes') }, 'type changes are recorded, not silently dropped')

filtered = [
  '  #"Renamed Columns" = Table.RenameColumns(Source,{{"STATUS", "Status"}})',
  '  #"Filtered Rows" = Table.SelectRows(#"Renamed Columns", each ([Status] <> "Closed" and [QTY] > 0) or [Status] = null)',
  '  Last = Table.Distinct(#"Filtered Rows")'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, filtered)))
expected = %(SELECT DISTINCT * FROM (\nSELECT * FROM (\n#{orders_sql}\n) AS m WHERE (("STATUS" <> 'Closed' OR "STATUS" IS NULL) AND "QTY" > 0) OR "STATUS" IS NULL\n) AS m)
check.call(fold.unsupported.empty? && fold.statement == expected,
           "row filters become a null-aware WHERE and Table.Distinct a SELECT DISTINCT (got #{fold.statement.inspect})")
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, filtered)), 'bigquery')
check.call(fold.statement.include?('`STATUS` IS NULL'), 'identifiers are quoted for the warehouse dialect')

%w[RemoveColumns SelectColumns].each do |function|
  projected = [
    "  #\"Projected Columns\" = Table.#{function}(Source,{\"QTY\"})",
    '  Last = Table.Distinct(#"Projected Columns")'
  ]
  fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, projected)))
  check.call(fold.unsupported == ['Last (Table.Distinct)'],
             "unkeyed distinct after Table.#{function} is gated (got #{fold.unsupported.inspect})")
end

swap = ['  Last = Table.RenameColumns(Source,{{"STATUS", "QTY"}, {"QTY", "STATUS"}})']
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, swap)))
check.call(fold.source_name('QTY') == 'STATUS' && fold.source_name('STATUS') == 'QTY',
           "a rename list applies all at once, so swapped names bind crosswise (got QTY->#{fold.source_name('QTY')}, STATUS->#{fold.source_name('STATUS')})")
chain = ['  Last = Table.RenameColumns(Source,{{"STATUS", "ORDER_ID"}, {"ORDER_ID", "Order Id"}})']
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, chain)))
check.call(fold.source_name('Order Id') == 'ORDER_ID' && fold.source_name('ORDER_ID') == 'STATUS',
           'a rename whose new name is another pair\'s old name reads the pre-rename columns')

narrowed = [
  '  #"Removed Columns" = Table.RemoveColumns(Source,{"QTY"})',
  '  Last = Table.Distinct(#"Removed Columns")'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, narrowed)))
check.call(fold.unsupported == ['Last (Table.Distinct)'],
           "Table.Distinct after a column removal is not folded: it dedupes the kept columns only (got #{fold.unsupported.inspect})")
selected = [
  '  #"Kept Columns" = Table.SelectColumns(Source,{"STATUS"})',
  '  Last = Table.Distinct(#"Kept Columns")'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, selected)))
check.call(fold.unsupported == ['Last (Table.Distinct)'], 'Table.Distinct after Table.SelectColumns is not folded either')
commented = [
  '  /* tidy, then rename in one go */ #"Renamed Columns" = Table.RenameColumns(Source,{{"ORDER_ID", "Order Id"}}) /* a, b in c */',
  '  Last = Table.AddColumn(#"Renamed Columns", "X", each Number.Random())'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, commented)))
check.call(fold.source_name('Order Id') == 'ORDER_ID' && fold.unsupported == ['Last (Table.AddColumn)'],
           "a comma or `in` inside a block comment does not end the step early (got #{fold.unsupported.inspect})")

after_gap = [
  '  #"Added Custom" = Table.AddColumn(Source, "Bucket", each Number.Random())',
  '  #"Filtered Rows" = Table.SelectRows(#"Added Custom", each [Bucket] = 1)',
  '  Last = Table.RenameColumns(#"Filtered Rows",{{"STATUS", "Status"}})'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, after_gap)))
check.call(fold.unsupported == ['#"Added Custom" (Table.AddColumn)', '#"Filtered Rows" (Table.SelectRows)', 'Last (Table.RenameColumns)'] &&
             fold.statement == orders_sql && fold.source_name('Status') == 'Status',
           "nothing after an unfoldable step is folded onto SQL that lacks its columns (got #{fold.unsupported.inspect})")
gap_noop = [
  '  #"Added Custom" = Table.AddColumn(Source, "Bucket", each Number.Random())',
  '  Last = Table.TransformColumnTypes(#"Added Custom",{{"Bucket", Int64.Type}})'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, gap_noop)))
check.call(fold.unsupported == ['#"Added Custom" (Table.AddColumn)'] && fold.notes.any? { |n| n.start_with?('Last (Table.TransformColumnTypes)') },
           "a no-op step after an unfoldable one is a note, not another stop (got #{fold.unsupported.inspect})")
comment_let = "// let this stand: the query is native\n/* let */ " +
              steps_m.call(orders_sql, ['  Last = Table.RenameColumns(Source,{{"ORDER_ID", "Order Id"}})'])
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', comment_let))
check.call(fold.source_name('Order Id') == 'ORDER_ID', 'a `let` inside a leading comment does not hide the real let block')
quoted_let = 'let Note = "let x = 1", ' +
             steps_m.call(orders_sql, ['  Last = Table.AddColumn(Source, "X", each Number.Random())']).sub(/\Alet\n/, '')
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', quoted_let))
check.call(fold.unsupported == ['Last (Table.AddColumn)'], "a `let` inside a string is not a let block (got #{fold.unsupported.inspect})")

dup = ['  Last = Table.DuplicateColumn(Source, "STATUS", "Status Copy")']
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, dup)))
check.call(fold.unsupported.empty? && fold.source_name('Status Copy') == 'STATUS', 'a duplicated column binds to its source column')

atomic_renames = ['  Last = Table.RenameColumns(Source,{{"ORDER_ID", "STATUS"}, {"STATUS", "ORDER_ID"}})']
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, atomic_renames)))
check.call(fold.source_name('STATUS') == 'ORDER_ID' && fold.source_name('ORDER_ID') == 'STATUS',
           'rename pairs are resolved atomically, including swaps')

custom = [
  '  #"Added Custom" = Table.AddColumn(Source, "Full", each [STATUS] & "x")',
  '  Last = Table.SelectRows(#"Added Custom", each Text.Contains([STATUS], "A"))'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, custom)))
check.call(fold.unsupported == ['#"Added Custom" (Table.AddColumn)', 'Last (Table.SelectRows)'],
           "steps that cannot be folded exactly are named (got #{fold.unsupported.inspect})")
check.call(PbiNativeQuery.fold(native).unsupported.empty? && native.post_transform, 'a foldable native query still reports its post transforms')

commented = [
  '  #"Renamed Columns" = Table.RenameColumns(Source,{{"STATUS", "Status"}}) /* comma, and in */',
  '  Last = Table.AddColumn(#"Renamed Columns", "Full", each [Status] & "x")'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, commented)))
check.call(fold.source_name('Status') == 'STATUS' && fold.unsupported == ['Last (Table.AddColumn)'],
           "block comments do not truncate later M steps (got #{fold.unsupported.inspect})")

puts "\n6. the M database parameter qualifies two-part table names"
model_expressions = [{ 'name' => 'SourceDb', 'kind' => 'm',
                       'expression' => '"RAW_DB" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]' }]
qualify_sql = <<~SQL.strip
  -- FROM NOT.THIS
  SELECT o.ORDER_ID, EXTRACT(YEAR FROM o.ORDERDATE) AS Y, 'FROM A.B' AS LIT
  FROM SALES.ORDERS o
  JOIN OTHER_DB.SALES.CUSTOMERS c ON c.ID = o.CUSTOMER_ID
  LEFT JOIN (SELECT ID FROM SALES."Order Lines") l ON l.ID = o.ORDER_ID
SQL
native = PbiNativeQuery.extract_from_expression('Orders', steps_m.call(qualify_sql, [], nav: '{[Name=SourceDb]}[Data]'),
                                                model_expressions)
fold = PbiNativeQuery.fold(native)
check.call(native.database == 'RAW_DB', "the navigated database parameter resolves (got #{native.database.inspect})")
check.call(fold.statement.include?('FROM RAW_DB.SALES.ORDERS o') && fold.statement.include?('FROM RAW_DB.SALES."Order Lines"'),
           "two-part FROM/JOIN tables gain the database, in subqueries too (got #{fold.statement.inspect})")
check.call(fold.statement.include?('JOIN OTHER_DB.SALES.CUSTOMERS') && fold.statement.include?('EXTRACT(YEAR FROM o.ORDERDATE)') &&
             fold.statement.include?("'FROM A.B'") && fold.statement.include?('-- FROM NOT.THIS'),
           'three-part names, EXTRACT(... FROM ...), strings and comments are untouched')
comma_sql = "SELECT a.X, b.Y FROM SALES.A a, SALES.B b, OTHER_DB.SALES.C c WHERE a.ID = b.ID ORDER BY a.X, b.Y"
comma = PbiNativeQuery.extract_from_expression('Orders', steps_m.call(comma_sql, [], nav: '{[Name=SourceDb]}[Data]'),
                                               model_expressions)
check.call(PbiNativeQuery.fold(comma).statement ==
             'SELECT a.X, b.Y FROM RAW_DB.SALES.A a, RAW_DB.SALES.B b, OTHER_DB.SALES.C c WHERE a.ID = b.ID ORDER BY a.X, b.Y',
           "every table in a comma-separated FROM list is qualified, and the SELECT/ORDER BY lists are not (got #{PbiNativeQuery.fold(comma).statement.inspect})")
ident_sql = 'SELECT 1 FROM SALES.A preorder, RE_ORDER.B b, SALES.C c'
ident = PbiNativeQuery.extract_from_expression('Orders', steps_m.call(ident_sql, [], nav: '{[Name=SourceDb]}[Data]'),
                                               model_expressions)
check.call(PbiNativeQuery.fold(ident).statement == 'SELECT 1 FROM RAW_DB.SALES.A preorder, RAW_DB.RE_ORDER.B b, RAW_DB.SALES.C c',
           "a clause keyword inside an identifier (an alias like preorder) does not end the FROM list (got #{PbiNativeQuery.fold(ident).statement.inspect})")
quoted_sql = 'SELECT o.X AS "X FROM A.B, C.D", o.Y AS `JOIN E.F` FROM SALES.ORDERS o, SALES.LINES l'
quoted = PbiNativeQuery.extract_from_expression('Orders', steps_m.call(quoted_sql, [], nav: '{[Name=SourceDb]}[Data]'),
                                                model_expressions)
check.call(PbiNativeQuery.fold(quoted).statement ==
             'SELECT o.X AS "X FROM A.B, C.D", o.Y AS `JOIN E.F` FROM RAW_DB.SALES.ORDERS o, RAW_DB.SALES.LINES l',
           "FROM/JOIN inside a quoted identifier is not a clause (got #{PbiNativeQuery.fold(quoted).statement.inspect})")
quoted_sql = 'SELECT 1 AS "metric FROM SALES.VALUE", 2 AS `metric JOIN SALES.OTHER` FROM SALES.A'
check.call(PbiNativeQuery.qualify_tables(quoted_sql, 'RAW_DB', 'databricks') ==
             'SELECT 1 AS "metric FROM SALES.VALUE", 2 AS `metric JOIN SALES.OTHER` FROM RAW_DB.SALES.A',
           'FROM/JOIN inside double-quoted and backtick-quoted identifiers are ignored')
literal_db = PbiNativeQuery.extract_from_expression('Orders', steps_m.call('SELECT 1 FROM S.T', [], nav: '{[Name="ENTERPRISE"]}[Data]'))
check.call(literal_db.database == 'ENTERPRISE' && PbiNativeQuery.fold(literal_db).statement == 'SELECT 1 FROM ENTERPRISE.S.T',
           'a literal navigated database qualifies too')
split_navigation = <<~M
  let
    Source = Snowflake.Databases("acct"),
    Nav = Source{[Name=SourceDb, Kind="Database"]}[Data],
    Native = Value.NativeQuery(Nav, "SELECT 1 FROM SALES.ORDERS")
  in
    Native
M
split_db = PbiNativeQuery.extract_from_expression('Orders', split_navigation, model_expressions)
check.call(split_db.database == 'RAW_DB' && PbiNativeQuery.fold(split_db).statement == 'SELECT 1 FROM RAW_DB.SALES.ORDERS',
           'database navigation in prior let steps qualifies two-part tables')
comma_db = PbiNativeQuery.extract_from_expression(
  'Orders', steps_m.call('SELECT o.ID, c.ID FROM SALES.ORDERS o, SALES.CUSTOMERS c WHERE o.ID = c.ID', [],
                         nav: '{[Name="ENTERPRISE"]}[Data]')
)
check.call(PbiNativeQuery.fold(comma_db).statement.include?('FROM ENTERPRISE.SALES.ORDERS o, ENTERPRISE.SALES.CUSTOMERS c'),
           'all two-part tables in a comma-separated FROM list gain the database')

puts "\n7. the orchestrator gate stops only on steps that cannot be folded"
gate_model = { 'tables' => [
  { 'name' => 'Folds', 'partitions' => [{ 'source' => { 'expression' => steps_m.call(orders_sql, renames) } }] },
  { 'name' => 'Stops', 'partitions' => [{ 'source' => { 'expression' => steps_m.call(orders_sql, custom) } }] }
] }
gaps = PbiNativeQuery.unfoldable(gate_model)
check.call(gaps.map { |native, _fold| native.table } == ['Stops'], "only the table with unfoldable steps is gated (got #{gaps.map { |n, _| n.table }})")
mt = File.read(File.join(__dir__, 'migrate-powerbi.rb'), encoding: 'utf-8')
gate_at = mt.index('PbiNativeQuery.unfoldable(scoped_model || model, opts[:wh_type])')
check.call(gate_at && mt.index('write_model_scope.call') && gate_at > mt.index('write_model_scope.call') &&
             mt.include?('PbiNativeQuery.apply!(dm_model, scoped_model || model, dialect: opts[:wh_type])'),
           'migrate-powerbi.rb gates on unfoldable steps of the report-scoped model and folds with the warehouse dialect')

puts "\n8. incremental-refresh RangeStart/RangeEnd folds to a rolling window from the refresh policy"
range_sql = 'SELECT EVENT_ID, EVENT_TS FROM LOGS.EVENTS'
range_step = ['  Last = Table.SelectRows(Source, each [EVENT_TS] >= RangeStart and [EVENT_TS] < RangeEnd)']
policy = { 'policyType' => 'basic', 'rollingWindowGranularity' => 'month', 'rollingWindowPeriods' => 48,
           'incrementalGranularity' => 'day', 'incrementalPeriods' => 10 }
range_native = PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, range_step), nil, policy)
fold = PbiNativeQuery.fold(range_native)
expected = %(SELECT * FROM (\n#{range_sql}\n) AS m WHERE "EVENT_TS" >= DATEADD(month, -48, DATE_TRUNC('month', CURRENT_DATE())) ) +
           %(AND "EVENT_TS" < DATEADD(day, 1, DATE_TRUNC('day', CURRENT_DATE())))
check.call(fold.unsupported.empty? && fold.statement == expected,
           "RangeStart/RangeEnd become a rolling-window predicate (got #{fold.statement.inspect} / #{fold.unsupported.inspect})")
check.call(fold.notes.any? { |n| n.include?('RangeStart') && n.include?('48 month') && n.include?('approximation') },
           "the window is recorded as an approximation anchored at today (got #{fold.notes.inspect})")

no_policy = PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, range_step))
fold = PbiNativeQuery.fold(no_policy)
check.call(fold.unsupported == ['Last (Table.SelectRows)'] && fold.statement == range_sql,
           "without a refresh policy RangeStart/RangeEnd stays unsupported (got #{fold.unsupported.inspect})")
bad_policy = PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, range_step), nil,
                                                    { 'rollingWindowGranularity' => 'fortnight', 'rollingWindowPeriods' => 2 })
check.call(PbiNativeQuery.fold(bad_policy).unsupported == ['Last (Table.SelectRows)'],
           'an unrecognised window granularity is not guessed at')

quarter = { 'rollingWindowGranularity' => 'quarter', 'rollingWindowPeriods' => 8 }
wrapped = ['  Last = Table.SelectRows(Source, each ([EVENT_TS] >= #"RangeStart") and ([EVENT_TS] < #"RangeEnd") and [EVENT_ID] <> null)']
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, wrapped), nil, quarter))
check.call(fold.unsupported.empty? &&
             fold.statement.include?(%("EVENT_TS" >= DATEADD(quarter, -8, DATE_TRUNC('quarter', CURRENT_DATE())))) &&
             fold.statement.include?(%("EVENT_TS" < DATEADD(quarter, 1, DATE_TRUNC('quarter', CURRENT_DATE())))) &&
             fold.statement.include?('"EVENT_ID" IS NOT NULL'),
           "quoted #\"RangeStart\", parentheses and other conjuncts fold; the end falls back to the rolling unit (got #{fold.statement.inspect})")

renamed_range = [
  '  #"Renamed" = Table.RenameColumns(Source,{{"EVENT_TS", "Event Time"}})',
  '  Last = Table.SelectRows(#"Renamed", each [Event Time] >= RangeStart and [Event Time] < RangeEnd)'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, renamed_range), nil, policy))
check.call(fold.unsupported.empty? && fold.statement.include?('"EVENT_TS" >= DATEADD(month, -48'),
           'the window predicate binds to the SQL output name of a renamed column')

fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, range_step), nil, policy), 'databricks')
check.call(fold.unsupported.empty? &&
             fold.statement.include?("`EVENT_TS` >= DATEADD(MONTH, -48, DATE_TRUNC('MONTH', CURRENT_DATE()))") &&
             fold.statement.include?("`EVENT_TS` < DATEADD(DAY, 1, DATE_TRUNC('DAY', CURRENT_DATE()))"),
           "the window uses Databricks syntax and identifiers (got #{fold.statement.inspect})")
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, range_step), nil, policy), 'bigquery')
check.call(fold.unsupported.empty? &&
             fold.statement.include?('CAST(`EVENT_TS` AS DATE) >= DATE_SUB(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 48 MONTH)') &&
             fold.statement.include?('CAST(`EVENT_TS` AS DATE) < DATE_ADD(DATE_TRUNC(CURRENT_DATE(), DAY), INTERVAL 1 DAY)'),
           "the window uses BigQuery syntax and compares dates (got #{fold.statement.inspect})")

reversed = ['  Last = Table.SelectRows(Source, each RangeStart <= [EVENT_TS])']
check.call(PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, reversed), nil, policy)).unsupported ==
             ['Last (Table.SelectRows)'], 'only the field-first range comparison shape is folded')
equality = ['  Last = Table.SelectRows(Source, each [EVENT_TS] = RangeStart)']
check.call(PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Events', steps_m.call(range_sql, equality), nil, policy)).unsupported ==
             ['Last (Table.SelectRows)'], 'an equality against RangeStart is not a window and is not folded')

policy_model = { 'tables' => [{ 'name' => 'Events', 'refreshPolicy' => policy,
                                'partitions' => [{ 'source' => { 'expression' => steps_m.call(range_sql, range_step) } }] }] }
natives = PbiNativeQuery.native_queries(policy_model)
check.call(natives.first.refresh_policy == policy && PbiNativeQuery.unfoldable(policy_model).empty?,
           "native_queries carries the table's TMSL refreshPolicy so the orchestrator gate passes it")

puts "\n6. F8: SQL output columns containing '/' are aliased and bound via the alias"
slash_sql = 'SELECT PCT/TOTAL AS "Pct/Total", ID, "A/B/C" FROM SALES.ORDERS'
slash_model = { 'tables' => [{
  'name' => 'Orders',
  'columns' => [{ 'name' => "Pct∕Total", 'sourceColumn' => 'Pct/Total' },
                { 'name' => 'Id', 'sourceColumn' => 'ID' },
                { 'name' => 'Path', 'sourceColumn' => 'A/B/C' }],
  'partitions' => [{ 'source' => { 'expression' => steps_m.call(slash_sql, []) } }]
}] }
slash_dm = lambda do
  { 'pages' => [{ 'elements' => [{
    'id' => 'el1', 'name' => 'ORDERS',
    'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn', 'path' => %w[DB SALES ORDERS] },
    'columns' => [{ 'id' => 'c1', 'name' => 'PCT', 'formula' => '[ORDERS/PCT]' },
                  { 'id' => 'c2', 'name' => 'ID', 'formula' => '[ORDERS/ID]' },
                  { 'id' => 'c3', 'name' => 'A', 'formula' => '[ORDERS/A]' }]
  }] }] }
end
dm = slash_dm.call
res = PbiNativeQuery.apply!(dm, slash_model)
el = dm['pages'][0]['elements'][0]
check.call(res['blockers'].empty?, 'a native query with slashed outputs restores without blockers')
check.call(el['columns'][0]['formula'] == '[Custom SQL/Pct_Total]', "slashed output binds via its alias (got #{el['columns'][0]['formula'].inspect})")
check.call(el['columns'][2]['formula'] == '[Custom SQL/A_B_C]', 'every slash in the name becomes an underscore')
check.call(el['columns'][1]['formula'] == '[Custom SQL/ID]', 'a name without a slash is bound as before')
check.call(el['columns'][0]['name'] == "Pct∕Total", 'the display name is kept')
check.call(el['source']['statement'].start_with?('SELECT * RENAME ("Pct/Total" AS "Pct_Total", "A/B/C" AS "A_B_C") FROM (') &&
             el['source']['statement'].include?(slash_sql),
           "statement wraps the original SQL in a Snowflake RENAME (got #{el['source']['statement'].inspect})")
check.call(res['converted'][0]['slashAliases'] == { 'Pct/Total' => 'Pct_Total', 'A/B/C' => 'A_B_C' }, 'the aliases are recorded in the conversion result')

dm = slash_dm.call
PbiNativeQuery.apply!(dm, slash_model, dialect: 'databricks')
stmt = dm['pages'][0]['elements'][0]['source']['statement']
check.call(stmt.start_with?('SELECT * EXCEPT (`Pct/Total`, `A/B/C`), `Pct/Total` AS `Pct_Total`, `A/B/C` AS `A_B_C` FROM ('),
           "Databricks has no RENAME: exclude and re-select (got #{stmt.inspect})")

plain_model = { 'tables' => [slash_model['tables'][0].merge('columns' => [{ 'name' => 'Id', 'sourceColumn' => 'ID' }])] }
dm = slash_dm.call
res = PbiNativeQuery.apply!(dm, plain_model)
check.call(dm['pages'][0]['elements'][0]['source']['statement'] == slash_sql && res['converted'][0]['slashAliases'] == {},
           'no slash in any bound output: the statement is untouched')

clash = { 'tables' => [slash_model['tables'][0].merge('columns' => [
  { 'name' => 'A', 'sourceColumn' => 'A/B' }, { 'name' => 'B', 'sourceColumn' => 'A_B' }, { 'name' => 'C', 'sourceColumn' => 'A/ B' }
])] }
dm = slash_dm.call
res = PbiNativeQuery.apply!(dm, clash)
check.call(res['converted'][0]['slashAliases']['A/B'] == 'A_B_2' && res['converted'][0]['slashAliases']['A/ B'] == 'A_ B',
           "an alias never collides with another output name (got #{res['converted'][0]['slashAliases'].inspect})")

renamed_step = ['  Last = Table.RenameColumns(Source,{{"Pct/Total", "Share"}})']
ren_model = { 'tables' => [{
  'name' => 'Orders', 'columns' => [{ 'name' => 'Share', 'sourceColumn' => 'Share' }],
  'partitions' => [{ 'source' => { 'expression' => steps_m.call(slash_sql, renamed_step) } }]
}] }
dm = slash_dm.call
PbiNativeQuery.apply!(dm, ren_model)
check.call(dm['pages'][0]['elements'][0]['columns'][0]['formula'] == '[Custom SQL/Pct_Total]',
           'a column renamed in M from a slashed SQL output binds to the alias of that output')

puts "\n12. keyed Distinct, AddIndexColumn and AddColumn fold (UI-generated steps)"
ui_steps = [
  '  #"Renamed Columns" = Table.RenameColumns(Source,{{"ORDER_ID", "Order Id"}, {"STATUS", "Status"}})',
  '  #"Removed Duplicates" = Table.Distinct(#"Renamed Columns", {"Order Id"})',
  '  #"Added Index" = Table.AddIndexColumn(#"Removed Duplicates", "Index", 0, 1, Int64.Type)',
  '  #"Added Conditional Column" = Table.AddColumn(#"Added Index", "Is Open", each if [Status] = "OPEN" then true else false)',
  '  #"Added Custom" = Table.AddColumn(#"Added Conditional Column", "Recent", each ([ORDERDATE] > #date(2024,1,1) and [ORDERDATE] < #date(2024,7,1)) or [QTY] > 10)',
  '  #"Kept Status" = Table.AddColumn(#"Added Custom", "Status Sort", each if [Status] = "Other" then "z" else [Status])',
  '  Last = Table.AddColumn(#"Kept Status", "Label", each Text.Combine({Text.Proper([Status]), " ", Text.From([QTY], "en-US")}), type text)'
]
fold = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, ui_steps)))
check.call(fold.unsupported.empty?, "every UI-generated step folds (unsupported: #{fold.unsupported.inspect})")
st = fold.statement
check.call(st.include?('QUALIFY ROW_NUMBER() OVER (PARTITION BY "ORDER_ID" ORDER BY NULL) = 1'),
           'keyed Table.Distinct -> QUALIFY ROW_NUMBER() = 1 on the SQL output column behind the renamed key')
check.call(st.include?('(ROW_NUMBER() OVER (ORDER BY NULL) - 1) * 1 + 0 AS "Index"'), 'AddIndexColumn -> ROW_NUMBER() index from the start/step')
check.call(st.include?(%q(CASE WHEN "STATUS" = 'OPEN' THEN TRUE ELSE FALSE END AS "Is Open")),
           'if/then/else conditional column -> CASE WHEN on the renamed field')
check.call(st.include?(%q(("ORDERDATE" > DATE '2024-01-01' AND "ORDERDATE" < DATE '2024-07-01') OR "QTY" > 10 AS "Recent")),
           'a boolean custom column (M predicate with #date) becomes a SQL boolean expression')
check.call(st.include?(%q(CASE WHEN "STATUS" = 'Other' THEN 'z' ELSE "STATUS" END AS "Status Sort")), 'field refs in branches use the SQL output name')
check.call(st.include?(%q[(COALESCE(INITCAP("STATUS"), '') || COALESCE(' ', '') || COALESCE(CAST("QTY" AS VARCHAR), '')) AS "Label"]),
           'Text.Combine/Text.Proper/Text.From -> null-skipping concatenation')
check.call(fold.notes.any? { |n| n.start_with?('Last (Table.AddColumn): Text.From') && n.include?('approximation') && n.include?('culture') },
           'Text.From folds to CAST but records a culture-formatting approximation note (pipeline-7)')
tf = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, [
  '  Last = Table.AddColumn(Source, "Label", each Text.From([ORDERDATE], "de-DE"))'])))
check.call(tf.statement.include?('CAST("ORDERDATE" AS VARCHAR)') && tf.unsupported.empty? && tf.notes.any? { |n| n.include?('Text.From') && n.include?('culture') },
           'a date argument with an explicit culture is folded with the approximation note, not silently')
nf = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, [
  '  Last = Table.AddColumn(Source, "Label", each Text.Upper([STATUS]))'])))
check.call(nf.notes.none? { |n| n.include?('Text.From') }, 'no Text.From, no note')
check.call(fold.notes.any? { |n| n.include?('arbitrary') } && fold.notes.count { |n| n.include?('approximation') } >= 2,
           'keyed Distinct and AddIndexColumn record their arbitrary-row approximation')
check.call(fold.renames['Index'] == 'Index' && fold.renames['Is Open'] == 'Is Open', 'added columns bind to their own alias')
bq = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, ui_steps)), 'bigquery')
check.call(bq.statement.include?('WHERE TRUE QUALIFY') && bq.statement.include?('ROW_NUMBER() OVER () - 1') && bq.statement.include?('CAST(`QTY` AS STRING)'),
           'BigQuery: QUALIFY needs a WHERE, ROW_NUMBER() OVER (), STRING casts')
nested = ['  Last = Table.AddColumn(Source, "Band", each if [QTY] > 100 then "L" else if [QTY] > 10 then "M" else "S")']
f2 = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, nested)))
check.call(f2.statement.include?(%q(CASE WHEN "QTY" > 100 THEN 'L' ELSE CASE WHEN "QTY" > 10 THEN 'M' ELSE 'S' END END AS "Band")),
           'nested else-if chains fold to nested CASE')
bad = ['  Last = Table.AddColumn(Source, "X", each List.Sum({[QTY], 1}))']
f3 = PbiNativeQuery.fold(PbiNativeQuery.extract_from_expression('Orders', steps_m.call(orders_sql, bad)))
check.call(f3.unsupported == ['Last (Table.AddColumn)'], 'an AddColumn expression outside the supported subset stays unsupported')

puts "\n13. a measure-only table with a native source is not a restore blocker"
mo_model = { 'tables' => [
  { 'name' => 'Measures', 'columns' => [], 'measures' => [{ 'name' => 'Total', 'expression' => '1' }],
    'partitions' => [{ 'source' => { 'expression' => steps_m.call('SELECT NULL AS C WHERE 1 = 0', ['  Last = Table.RemoveColumns(Source,{"C"})']) } }] }
] }
mo = PbiNativeQuery.apply!({ 'pages' => [{ 'elements' => [] }] }, mo_model)
check.call(mo['blockers'].empty? && mo['converted'].empty?, "measure-only tables are skipped, not blockers (got #{mo['blockers'].inspect})")

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
