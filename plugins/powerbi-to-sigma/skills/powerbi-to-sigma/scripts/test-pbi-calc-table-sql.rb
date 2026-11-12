#!/usr/bin/env ruby
# frozen_string_literal: true

# End to end: pinned converter -> NativeQuery restore -> PbiCalcTableSql.apply!
# -> calculated-table gate. Synthetic Orders / Order Dates model. Needs node.
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/pbi_native_query'
require_relative 'lib/pbi_calc_table_sql'
require_relative 'lib/dax_gate'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

ORDERS_SQL = 'SELECT ORDER_ID, SALE_DATE_ID, REGION FROM SALES.ORDERS'

def native_m(sql)
  ['let',
   "  Source = Value.NativeQuery(Snowflake.Databases(\"acct\"){[Name=\"DB\"]}[Data], \"#{sql}\", null, [EnableFolding=true])",
   'in', '  Source']
end

def warehouse_m
  ['let',
   '  Source = Snowflake.Databases("acct"),',
   '  Db = Source{[Name="DB"]}[Data],',
   '  Sch = Db{[Name="SALES",Kind="Schema"]}[Data],',
   '  Tbl = Sch{[Name="ORDERS",Kind="Table"]}[Data]',
   'in', '  Tbl']
end

def orders_table(expression)
  { 'name' => 'Orders',
    'columns' => [
      { 'name' => 'OrderID', 'dataType' => 'int64', 'sourceColumn' => 'ORDER_ID' },
      { 'name' => 'SaleDateID', 'dataType' => 'int64', 'sourceColumn' => 'SALE_DATE_ID' },
      { 'name' => 'Region', 'dataType' => 'string', 'sourceColumn' => 'REGION' }
    ],
    'partitions' => [{ 'name' => 'p', 'mode' => 'import', 'source' => { 'type' => 'm', 'expression' => expression } }] }
end

def calc_table(name, dax, columns)
  { 'name' => name, 'columns' => columns,
    'partitions' => [{ 'name' => 'p', 'mode' => 'import', 'source' => { 'type' => 'calculated', 'expression' => dax } }] }
end

ORDER_DATES_DAX = "// distinct dates\nVAR U = DISTINCT('Orders'[SaleDateID])\n/* alt: VALUES(Orders[Region]) */\nRETURN U"

def model(orders_expr, calc_tables)
  { 'model' => {
    'tables' => [orders_table(orders_expr)] + calc_tables,
    'relationships' => [
      { 'name' => 'r1', 'fromTable' => 'Orders', 'fromColumn' => 'SaleDateID',
        'toTable' => 'Order Dates', 'toColumn' => 'SaleDateID' }
    ]
  } }
end

def order_dates(dax = ORDER_DATES_DAX)
  calc_table('Order Dates', dax, [
    { 'name' => 'SaleDateID', 'dataType' => 'int64', 'type' => 'calculatedTableColumn', 'sourceColumn' => 'SaleDateID' },
    { 'name' => 'DateCopy', 'dataType' => 'int64', 'type' => 'calculated', 'expression' => "'Order Dates'[SaleDateID]" },
    { 'name' => 'Label', 'dataType' => 'string', 'type' => 'calculated', 'expression' => "\"D\" & 'Order Dates'[SaleDateID]" }
  ])
end

# Runs the pinned converter on the TMSL; returns [dm, warnings].
def convert(tmsl, dir)
  input = File.join(dir, 'model.json')
  output = File.join(dir, 'out.json')
  shim = File.join(dir, 'convert.mjs')
  converter = File.expand_path('../converter/powerbi.mjs', __dir__)
  File.write(input, JSON.generate(PbiNativeQuery.normalize_tmsl(tmsl)))
  File.write(shim, <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    const { convertPowerBIToSigma } = await import(pathToFileURL(#{converter.to_json}).href);
    const out = convertPowerBIToSigma(JSON.parse(readFileSync(#{input.to_json}, 'utf8')), { connectionId: 'conn' });
    writeFileSync(#{output.to_json}, JSON.stringify({ model: out.model || out.sigmaDataModel || out, warnings: out.warnings || [] }));
  JS
  # Test harness: runs the temp shim this test writes, with no arguments.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  _o, err, status = Open3.capture3('node', shim)
  raise "converter failed: #{err}" unless status.success?

  r = JSON.parse(File.read(output))
  [r['model'], r['warnings']]
end

def elements(dm)
  dm['pages'].flat_map { |p| p['elements'] }
end

Dir.mktmpdir('pbi-calc-table-sql') do |dir|
  puts "\n1. NativeQuery source -> distinct Custom SQL element"
  tmsl = model(native_m(ORDERS_SQL), [order_dates])
  dm, warnings = convert(tmsl, dir)
  check.call(DaxGate.calculated_table_issues(dm, warnings).any?, 'precondition: converter output trips the gate')
  native = PbiNativeQuery.apply!(dm, tmsl['model'])
  check.call(native['blockers'].empty?, 'NativeQuery restore has no blockers')
  result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings)
  check.call(result['converted'].size == 1 && result['skipped'].empty?, "one table converted (#{result['skipped'].inspect})")
  el = elements(dm).find { |e| e['name'] == 'Order Dates' }
  orders = elements(dm).find { |e| e['name'] == 'Orders' }
  check.call(el && el.dig('source', 'kind') == 'sql', 'placeholder became a Custom SQL element named after the table')
  expected = %(SELECT DISTINCT "SALE_DATE_ID" AS "SaleDateID" FROM (\n#{orders.dig("source", "statement")}\n) AS src)
  check.call(el && el.dig('source', 'statement') == expected, "SQL is the distinct projection of the source SQL (#{el&.dig('source', 'statement').inspect})")
  check.call(el && el.dig('source', 'connectionId') == 'conn', 'connection id kept')
  key = el && el['columns'].find { |c| c['name'] == 'SaleDateID' }
  check.call(key && key['formula'] == '[Custom SQL/SaleDateID]', 'key column references the new SQL output')
  copy = el && el['columns'].find { |c| c['name'] == 'DateCopy' }
  check.call(copy && copy['formula'] == '[Custom SQL/SaleDateID]', 'a calculated column that copies a sibling is kept')
  label = result['converted'][0]['pending_calculated_columns']
  check.call(label.map { |c| c['name'] } == ['Label'] && !el['columns'].any? { |c| c['name'] == 'Label' },
             'a calculated column that cannot be translated is reported, not invented')
  check.call(el && !el.key?('ok') && el['order'] == el['columns'].map { |c| c['id'] }, 'ok:false cleared and order matches columns')
  rel = orders && (orders['relationships'] || []).find { |r| r['targetElementId'] == el['id'] }
  order_date_col = orders && orders['columns'].find { |c| c['formula'] == '[Custom SQL/SALE_DATE_ID]' }
  check.call(rel && rel['keys'] == [{ 'sourceColumnId' => order_date_col['id'], 'targetColumnId' => key['id'] }],
             'relationship Orders[SaleDateID] -> Order Dates[SaleDateID] is rebuilt on the same columns')
  check.call(warnings.none? { |w| w.include?('Order Dates') }, "converter warnings for the table are removed (#{warnings.inspect})")
  check.call(DaxGate.calculated_table_issues(dm, warnings).empty?, 'calculated-table gate is clear')
  ids = elements(dm).flat_map { |e| [e['id']] + e['columns'].map { |c| c['id'] } }
  check.call(ids.uniq.size == ids.size, 'all element and column ids are unique')
  check.call(result['converted'][0]['notes'].any?, 'approximation notes are recorded')

  puts "\n2. warehouse-table source selects from its qualified table"
  tmsl = model(warehouse_m, [order_dates('VALUES(Orders[SaleDateID])')])
  dm, warnings = convert(tmsl, dir)
  result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings, dialect: 'bigquery')
  el = elements(dm).find { |e| e['name'] == 'Order Dates' }
  check.call(result['converted'].size == 1, "converted (#{result['skipped'].inspect})")
  check.call(el&.dig('source', 'statement') == 'SELECT DISTINCT `SALE_DATE_ID` AS `SaleDateID` FROM `SALES`.`ORDERS` AS src',
             "warehouse path and BigQuery quoting (#{el&.dig('source', 'statement').inspect})")
  check.call(result['converted'][0]['notes'].any? { |n| n.include?('blank row') }, 'VALUES records the blank-row approximation')

  puts "\n3. unrecognized DAX is left alone and the gate still stops"
  tmsl = model(native_m(ORDERS_SQL), [order_dates("CALCULATETABLE(DISTINCT(Orders[SaleDateID]), Orders[Region] = \"West\")")])
  dm, warnings = convert(tmsl, dir)
  PbiNativeQuery.apply!(dm, tmsl['model'])
  before = JSON.generate([dm, warnings])
  result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings)
  check.call(result['converted'].empty? && result['skipped'].size == 1, 'nothing converted, one skip recorded')
  check.call(JSON.generate([dm, warnings]) == before, 'DM and warnings are byte-identical')
  check.call(DaxGate.calculated_table_issues(dm, warnings).any?, 'gate still fires')

  puts "\n4. unresolved source table is not converted"
  src_calc = calc_table('Orders', 'ADDCOLUMNS(SomethingElse, "X", 1)', [
    { 'name' => 'SaleDateID', 'dataType' => 'int64', 'type' => 'calculatedTableColumn', 'sourceColumn' => 'SaleDateID' }
  ])
  tmsl = { 'model' => { 'tables' => [src_calc, order_dates], 'relationships' => [] } }
  dm, warnings = convert(tmsl, dir)
  before = JSON.generate([dm, warnings])
  result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings)
  check.call(result['converted'].empty? && result['skipped'].any? { |s| s['table'] == 'Order Dates' && s['reason'].include?('calculated table') },
             'source that is itself a calculated placeholder is skipped')
  check.call(JSON.generate([dm, warnings]) == before && DaxGate.calculated_table_issues(dm, warnings).any?, 'gate still fires')

  tmsl = model(native_m(ORDERS_SQL), [order_dates("DISTINCT('Orders'[Missing])")])
  dm, warnings = convert(tmsl, dir)
  PbiNativeQuery.apply!(dm, tmsl['model'])
  result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings)
  check.call(result['converted'].empty? && result['skipped'][0]['reason'].include?('not resolvable'), 'missing source column is skipped')
  check.call(DaxGate.calculated_table_issues(dm, warnings).any?, 'gate still fires for a missing source column')

  puts "\n5. model columns pair with DAX outputs BY NAME, never by position (pipeline-4)"
  seg_dax = %q(DISTINCT(SELECTCOLUMNS(Orders, "DateKey", Orders[SaleDateID], "Area", Orders[Region])))
  seg_cols = lambda do |order|
    cols = { 'DateKey' => { 'name' => 'DateKey', 'dataType' => 'int64', 'type' => 'calculatedTableColumn', 'sourceColumn' => '[DateKey]' },
             'Area' => { 'name' => 'Area', 'dataType' => 'string', 'type' => 'calculatedTableColumn', 'sourceColumn' => '[Area]' } }
    order.map { |n| cols[n] }
  end
  [%w[DateKey Area], %w[Area DateKey]].each do |order|
    tmsl = model(native_m(ORDERS_SQL), [calc_table('Segments', seg_dax, seg_cols.call(order))])
    tmsl['model']['relationships'] = []
    dm, warnings = convert(tmsl, dir)
    PbiNativeQuery.apply!(dm, tmsl['model'])
    result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings)
    el = elements(dm).find { |e| e['name'] == 'Segments' }
    check.call(result['converted'].size == 1, "TMSL column order #{order.inspect}: converted (#{result['skipped'].inspect})")
    sql = el&.dig('source', 'statement').to_s
    check.call(sql.include?('"SALE_DATE_ID" AS "DateKey"') && sql.include?('"REGION" AS "Area"'),
               "TMSL order #{order.inspect}: each warehouse column keeps its own output name (#{sql[0, 90].inspect})")
    forms = (el ? el['columns'] : []).map { |c| [c['name'], c['formula']] }.to_h
    check.call(forms == { 'DateKey' => '[Custom SQL/DateKey]', 'Area' => '[Custom SQL/Area]' },
               "TMSL order #{order.inspect}: column bindings follow the names (#{forms.inspect})")
  end
  # sourceColumn is the DAX output reference: a model column RENAMED in the model still pairs through it
  tmsl = model(native_m(ORDERS_SQL), [calc_table('Segments', seg_dax, [
    { 'name' => 'Region Label', 'dataType' => 'string', 'type' => 'calculatedTableColumn', 'sourceColumn' => '[Area]' },
    { 'name' => 'Date Key', 'dataType' => 'int64', 'type' => 'calculatedTableColumn', 'sourceColumn' => '[DateKey]' }
  ])])
  tmsl['model']['relationships'] = []
  dm, warnings = convert(tmsl, dir)
  PbiNativeQuery.apply!(dm, tmsl['model'])
  result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings)
  el = elements(dm).find { |e| e['name'] == 'Segments' }
  sql = el&.dig('source', 'statement').to_s
  check.call(result['converted'].size == 1 && sql.include?('"SALE_DATE_ID" AS "Date_Key"') == false &&
               sql.include?('"SALE_DATE_ID" AS "Date Key"') && sql.include?('"REGION" AS "Region Label"'),
             "renamed model columns pair through sourceColumn (#{sql[0, 110].inspect})")
  # names that match nothing: refuse (leave the placeholder + gate) rather than bind by position
  tmsl = model(native_m(ORDERS_SQL), [calc_table('Segments', seg_dax, [
    { 'name' => 'Foo', 'dataType' => 'string', 'type' => 'calculatedTableColumn', 'sourceColumn' => '[Foo]' },
    { 'name' => 'Bar', 'dataType' => 'int64', 'type' => 'calculatedTableColumn', 'sourceColumn' => '[Bar]' }
  ])])
  tmsl['model']['relationships'] = []
  dm, warnings = convert(tmsl, dir)
  PbiNativeQuery.apply!(dm, tmsl['model'])
  before = JSON.generate([dm, warnings])
  result = PbiCalcTableSql.apply!(dm, tmsl['model'], warnings)
  check.call(result['converted'].empty? && result['skipped'].any? { |x| x['reason'].include?('by name') } && JSON.generate([dm, warnings]) == before,
             "unmatchable column names are skipped, never paired by position (#{result['skipped'].inspect})")
end

puts
if fails.empty?
  puts 'All checks passed'
else
  puts "#{fails.size} check(s) FAILED"
  exit 1
end
