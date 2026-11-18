#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Issue sigmacomputing/sigma-migration-skills#97: a composite report that uses
# DirectQuery to a published Power BI semantic model stores each remote measure
# as a pointer, EXTERNALMEASURE("<measure>", <type>, "DirectQuery to AS - <model>").
# Its DAX lives in the remote model, not in the .pbix. The --pbix route used to
# copy that pointer into a Sigma metric formula verbatim, with no warning.
#
#   1. lib/pbi_external_measure.rb: parse a pointer, name the remote models from
#      the model's shared expressions, find everything built on a pointer, and
#      turn those metrics into Null gaps in a converted data model.
#   2. The REAL orchestrator on the --pbix route (a fake python stands in for
#      pbixray, as in test-pbi-orchestrator-speed.rb), offline, no Sigma calls:
#      a. a composite model STOPS (exit 10) before conversion and names the
#         remote models;
#      b. --allow-incomplete-model continues: the pointers and the measures
#         built on them are Null metrics reported as gaps, and no emitted
#         formula carries EXTERNALMEASURE;
#      c. a non-composite .pbix is unchanged (no stop, no gap record);
#      d. the Fabric --tmsl composite gate names the remote models;
#      e. pointers that only arrive in --converter-out still stop / neutralize;
#      f. convert-model.rb (the run.sh route) refuses a pointer.
#   The lib cases also cover the review findings: a local column that shares a
#   pointer's name, comments and strings, a "%" in a workspace name, and no
#   collateral nulling of warehouse columns or local metrics.
#
# Remote TABLES too: a DirectQuery-to-AS proxy table (an `entity` partition whose
# expressionSource is the `DirectQuery to AS - <model>` shared expression) has no
# warehouse table behind it. The --pbix route used to point it at
# --database/--schema + the table name (converter: "could not extract source
# path"). Now it stops with the remote measures (naming the remote model and the
# remote table), and under --allow-incomplete-model it ships as a zero-row typed
# Custom SQL placeholder reported as a gap, never as a guessed warehouse path
# (2c, 2d, 4a, 4b, 4d, 4g).
#
# Fixture: fixtures/composite-externalmeasure/ (synthetic; every name invented).
# Run: ruby scripts/test-external-measure.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative 'lib/pbi_external_measure'
require_relative 'lib/pbi_native_query'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

SKILL = File.expand_path('..', __dir__)
MIGRATE = File.join(__dir__, 'migrate-powerbi.rb')
FIXTURE = File.join(SKILL, 'fixtures', 'composite-externalmeasure')
CONN = '12345678-1234-1234-1234-123456789012'
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'
# The orchestrator prints non-ASCII (box drawing, arrows); read its output as UTF-8
# even when this test itself was started under a US-ASCII locale.
Encoding.default_external = Encoding::UTF_8

def jread(path)
  JSON.parse(File.read(path))
end

COMPOSITE = jread(File.join(FIXTURE, 'model.bim'))

# Every formula string in a converted data model (metrics, columns, anywhere).
def formulas(node, acc = [])
  case node
  when Array then node.each { |x| formulas(x, acc) }
  when Hash
    node.each { |k, v| k == 'formula' && v.is_a?(String) ? acc << v : formulas(v, acc) }
  end
  acc
end

def metric(dm, name)
  (dm['pages'] || []).flat_map { |p| p['elements'] || [] }.flat_map { |e| e['metrics'] || [] }.find { |m| m['name'] == name }
end

def elements(dm)
  (dm['pages'] || []).flat_map { |p| p['elements'] || [] }
end

def deep(obj)
  JSON.parse(JSON.generate(obj))
end

AS_EXPR = lambda do |model, workspace|
  { 'name' => "DirectQuery to AS - #{model}", 'kind' => 'm',
    'expression' => "let\n    Source = AnalysisServices.Database(\"powerbi://api.powerbi.com/v1.0/myorg/#{workspace}\", \"#{model}\")\nin\n    Source" }
end

ENTITY_TABLE = lambda do |name, entity, source = nil|
  src = { 'type' => 'entity', 'entityName' => entity }
  src['expressionSource'] = source if source
  { 'name' => name, 'columns' => [{ 'name' => 'Key', 'dataType' => 'int64', 'sourceColumn' => 'Key' }],
    'partitions' => [{ 'name' => name, 'mode' => 'directQuery', 'source' => src }] }
end

puts "\n1. lib: parse a pointer"
parsed = PbiExternalMeasure.parse('EXTERNALMEASURE("Net Revenue", DOUBLE, "DirectQuery to AS - Harbor Sales Model")')
check(parsed == { 'measure' => 'Net Revenue', 'type' => 'DOUBLE', 'connection' => 'DirectQuery to AS - Harbor Sales Model' },
      "parses measure, type and connection (got #{parsed.inspect})")
escaped = PbiExternalMeasure.parse("  externalmeasure ( \"Say \"\"Hi\"\"\" , INTEGER , \"DirectQuery to AS - M\" )")
check(escaped && escaped['measure'] == 'Say "Hi"' && escaped['connection'] == 'DirectQuery to AS - M',
      "case-insensitive, tolerates spacing and DAX doubled quotes (got #{escaped.inspect})")
check(PbiExternalMeasure.parse('SUM(Sales[Amount])').nil?, 'an ordinary measure is not a pointer')
check(PbiExternalMeasure.pointer?(['EXTERNALMEASURE("A",', ' DOUBLE, "DirectQuery to AS - M")']),
      'an array-valued TMSL expression is read as one string')

puts "\n2. lib: scan names the remote models and everything built on a pointer"
scan = PbiExternalMeasure.scan(COMPOSITE['model'])
models = scan['remote_models'].map { |r| [r['model'], r['workspace']] }
check(models.sort == [['Harbor Finance Model', 'Finance Demo'], ['Harbor Sales Model', 'Demo Workspace']],
      "remote models and workspaces come from the shared expressions (got #{models.inspect})")
sales = scan['remote_models'].find { |r| r['model'] == 'Harbor Sales Model' } || {}
check(sales['connection'] == 'DirectQuery to AS - Harbor Sales Model' &&
        sales['server'] == 'powerbi://api.powerbi.com/v1.0/myorg/Demo Workspace' && sales['pointers'] == ['Remote Revenue'],
      "each remote model carries its connection, server and pointer measures (got #{sales.inspect})")
check(scan['pointers'].map { |p| p['measure'] }.sort == ['Remote Margin', 'Remote Revenue'],
      'both pointer measures are found')
rr = scan['pointers'].find { |p| p['measure'] == 'Remote Revenue' } || {}
check(rr['table'] == 'Harbor Sales' && rr['remote_measure'] == 'Net Revenue' && rr['model'] == 'Harbor Sales Model',
      "a pointer records its table, remote measure and model (got #{rr.inspect})")
deps = scan['dependents'].map { |d| d['measure'] }
check(deps.sort == ['Remote Order Count', 'Remote Revenue K', 'Revenue Gap', 'Revenue vs Target'],
      "measures built on a pointer or a remote table are found, transitively (got #{deps.inspect})")
check(!deps.include?('Total Target'), 'a purely local measure is not a dependent')
gap = scan['dependents'].find { |d| d['measure'] == 'Revenue Gap' } || {}
check(gap['depends_on'] == ['Revenue vs Target'], "a dependent names what it is built on (got #{gap.inspect})")
check(PbiExternalMeasure.scan({ 'tables' => [{ 'name' => 'T', 'measures' => [{ 'name' => 'M', 'expression' => 'SUM(T[x])' }] }] })['pointers'].empty?,
      'a model with no pointers scans empty')
orphan = PbiExternalMeasure.scan({ 'tables' => [{ 'name' => 'T', 'measures' => [
  { 'name' => 'P', 'expression' => 'EXTERNALMEASURE("X", DOUBLE, "DirectQuery to AS - Lonely Model")' }
] }] })
check(orphan['remote_models'].map { |r| r['model'] } == ['Lonely Model'],
      "without a shared expression the model is named from the connection (got #{orphan['remote_models'].inspect})")
puts "\n2b. lib: column references, comments and strings are not measure references"
collide = PbiExternalMeasure.scan({ 'tables' => [
  { 'name' => 'Remote', 'measures' => [{ 'name' => 'Sales Amount', 'expression' => 'EXTERNALMEASURE("Sales Amount", DOUBLE, "DirectQuery to AS - M")' }] },
  { 'name' => 'Budget', 'columns' => [{ 'name' => 'Sales Amount', 'dataType' => 'double' }], 'measures' => [
    { 'name' => 'Budget Sales', 'expression' => 'SUM(Budget[Sales Amount])' },
    { 'name' => 'Budget Sales Q', 'expression' => "SUMX('Budget', 'Budget'[Sales Amount])" },
    { 'name' => 'Vs Remote', 'expression' => "DIVIDE([Budget Sales], 'Remote'[Sales Amount])" },
    { 'name' => 'Commented', 'expression' => "-- 5\" wide\n[Sales Amount] * 2 & \"a\"" },
    { 'name' => 'In String', 'expression' => '"[Sales Amount]" & SUM(Budget[Sales Amount])' }
  ] }
] })
cdeps = collide['dependents'].map { |d| d['measure'] }.sort
check(!cdeps.include?('Budget Sales') && !cdeps.include?('Budget Sales Q') && !cdeps.include?('In String'),
      "a column that shares a pointer's name is not a reference to it, qualified or in a string (got #{cdeps.inspect})")
check(cdeps.include?('Vs Remote') && cdeps.include?('Commented'),
      "a table-qualified measure reference, and a reference after a comment with a stray quote, still count (got #{cdeps.inspect})")
check(!PbiExternalMeasure.pointer?("// was EXTERNALMEASURE(\"A\", DOUBLE, \"DirectQuery to AS - M\")\nSUM(T[x])") &&
        !PbiExternalMeasure.pointer?('"EXTERNALMEASURE(" & SUM(T[x])'),
      'EXTERNALMEASURE inside a comment or a string is not a pointer')
commented = PbiExternalMeasure.parse("/* remote */ EXTERNALMEASURE(\"A\", DOUBLE, \"DirectQuery to AS - M\") // note")
check(commented && commented['measure'] == 'A' && commented['connection'] == 'DirectQuery to AS - M',
      "a pointer next to comments still parses (got #{commented.inspect})")
pct = PbiExternalMeasure.scan({ 'tables' => [{ 'name' => 'T', 'measures' => [
  { 'name' => 'P', 'expression' => 'EXTERNALMEASURE("X", DOUBLE, "DirectQuery to AS - Q")' }] }],
  'expressions' => [{ 'name' => 'DirectQuery to AS - Q', 'expression' =>
    'AnalysisServices.Database("powerbi://api.powerbi.com/v1.0/myorg/Q1 50%DE", "Q")' }] })
check(pct['remote_models'].first.to_h['workspace'] == 'Q1 50%DE' &&
        (JSON.generate(PbiExternalMeasure.record(pct, status: 'blocked')) rescue nil),
      "a workspace name with a percent sign is kept as written and the record serializes (got #{pct['remote_models'].inspect})")

check(PbiExternalMeasure.stop_lines(scan).join("\n").then { |t| t.include?('Harbor Sales Model') && t.include?('Harbor Finance Model') && t.include?('--allow-incomplete-model') },
      'the stop text names both models and the --allow-incomplete-model choice')

puts "\n2c. lib: DirectQuery-to-AS proxy tables (entity partitions over a remote model)"
proxies = scan['proxy_tables'].to_a
check(proxies.map { |p| p.values_at('table', 'remote_table', 'model', 'workspace', 'connection') } ==
        [['Harbor Sales', 'Sales', 'Harbor Sales Model', 'Demo Workspace', 'DirectQuery to AS - Harbor Sales Model']],
      "the entity partition is a proxy of the remote table in the model its expressionSource names (got #{proxies.inspect})")
finance = scan['remote_models'].find { |r| r['model'] == 'Harbor Finance Model' } || {}
check(sales['tables'] == ['Harbor Sales'] && finance['tables'] == [],
      "each remote model lists its proxy tables (got #{sales['tables'].inspect} / #{finance['tables'].inspect})")
roc = scan['dependents'].find { |d| d['measure'] == 'Remote Order Count' } || {}
check(roc['remote_tables'] == ['Harbor Sales'] && roc['depends_on'] == [],
      "a local measure over a proxy table is built on that remote table (got #{roc.inspect})")
check(PbiExternalMeasure.stop_lines(scan).join("\n").then { |t| t.include?('Harbor Sales (remote table "Sales")') && t.include?('zero-row') },
      'the stop text names the proxy table, the remote table it mirrors, and what the override does with it')
alone = PbiExternalMeasure.scan({ 'tables' => [ENTITY_TABLE.call('Orders', 'Orders', 'DirectQuery to AS - Ops Model')],
                                  'expressions' => [AS_EXPR.call('Ops Model', 'Ops')] })
check(PbiExternalMeasure.any?(alone) && alone['pointers'].empty? && alone['remote_models'].map { |r| [r['model'], r['tables']] } == [['Ops Model', ['Orders']]],
      "a proxy table with no pointer measure still counts and names its model (got #{alone['remote_models'].inspect})")
alone_text = PbiExternalMeasure.stop_lines(alone).join("\n")
check(!alone_text.include?('EXTERNALMEASURE pointers') && alone_text.include?('Ops Model') && alone_text.include?('Orders (remote table "Orders")'),
      'with no pointers the stop text is about the remote table only')
lake = PbiExternalMeasure.scan({ 'tables' => [ENTITY_TABLE.call('Lake', 'lake_tbl', 'DatabaseQuery')],
                                 'expressions' => [{ 'name' => 'DatabaseQuery', 'kind' => 'm',
                                                     'expression' => 'let Source = Sql.Database("x.datawarehouse.example.net", "abc") in Source' }] })
check(lake['proxy_tables'].empty? && !PbiExternalMeasure.any?(lake),
      'an entity partition over a warehouse SQL endpoint (Direct Lake) is not a remote-model proxy')
pbids = PbiExternalMeasure.scan({ 'tables' => [ENTITY_TABLE.call('Ds', 'Ds', 'Remote Link')],
                                  'expressions' => [{ 'name' => 'Remote Link', 'kind' => 'm', 'expression' => 'PowerBI.Datasets(null)' }] })
check(pbids['proxy_tables'].map { |p| p['model'] } == ['Remote Link'],
      "an entity partition over another remote-model connector counts, named from the connection (got #{pbids['proxy_tables'].inspect})")
both = [AS_EXPR.call('Alpha Model', 'WS A'), AS_EXPR.call('Beta Model', 'WS B')]
unresolved = PbiExternalMeasure.scan({ 'tables' => [ENTITY_TABLE.call('Mystery', 'Mys')], 'expressions' => both })
mys = unresolved['proxy_tables'].first || {}
check(mys['connection'].to_s.empty? && mys['candidates'].to_a.size == 2 &&
        PbiExternalMeasure.stop_lines(unresolved).join("\n").then { |t| t.include?('Alpha Model') && t.include?('Beta Model') },
      "without an expressionSource and several remote models, the candidates are named, not guessed (got #{mys.inspect})")
single = PbiExternalMeasure.scan({ 'tables' => [ENTITY_TABLE.call('Mystery', 'Mys')], 'expressions' => both.first(1) })
check(single['proxy_tables'].map { |p| [p['model'], p['connection']] } == [['Alpha Model', 'DirectQuery to AS - Alpha Model']],
      "without an expressionSource and one remote model, it is that model (got #{single['proxy_tables'].inspect})")
names = { 'harbor sales' => 'Harbor Sales', 'orders' => 'Orders' }
check(PbiExternalMeasure.table_refs("SUM('Harbor Sales'[Amount]) + COUNTROWS(Orders)", names) == ['Harbor Sales', 'Orders'],
      'a quoted or bare table reference is found')
check(PbiExternalMeasure.table_refs("\"'Harbor Sales'\" & [Orders] // Orders\n+ SUM(Targets[Orders]) /* 'Harbor Sales' */", names).empty?,
      'a table name inside a string, a comment or a [column] is not a reference')
function_names = { 'date' => 'Date', 'calendar' => 'Calendar', 'value' => 'Value' }
check(PbiExternalMeasure.table_refs('DATE(2025, 1, 1) + COUNTROWS(CALENDAR(DATE(2025, 1, 1), DATE(2025, 1, 2))) + VALUE("1")',
                                    function_names).empty?,
      'a function that shares a proxy table name is not a table reference')
dotted_names = { 'rank' => 'Rank', 'stdev' => 'Stdev', 'norm' => 'Norm', 'value' => 'Value' }
check(PbiExternalMeasure.table_refs("RANK.EQ([x], 'T'[c]) + STDEV.S(Norm[v]) + DATE (2025, 1, 1) + COUNTROWS( Value )", dotted_names) == %w[Norm Value],
      'dotted DAX functions (RANK.EQ, STDEV.S) and a space before "(" are calls; a table used bare as an argument still counts')
scoped_only = PbiExternalMeasure.scan({ 'tables' => [{ 'name' => 'Targets', 'measures' => [] }] },
                                      expressions: COMPOSITE['model']['expressions'], proxy_model: { 'tables' => [] })
check(scoped_only['proxy_tables'].empty?, 'proxy tables are read from proxy_model when it is given (the scoped model)')

puts "\n2d. lib: under --allow-incomplete-model a proxy table becomes a zero-row placeholder, not a guessed warehouse path"
hs_table = COMPOSITE['model']['tables'].find { |t| t['name'] == 'Harbor Sales' }
sf = PbiExternalMeasure.placeholder_sql(hs_table, proxies.first, 'snowflake')
check(sf.include?('CAST(NULL AS VARCHAR) AS "Region"') && sf.include?('CAST(NULL AS TIMESTAMP) AS "Order Date"') &&
        sf.end_with?('WHERE 1 = 0') && sf !~ /FROM\s+"?\w+"?\./,
      "Snowflake: one typed NULL per column, no rows, no table path (got #{sf.inspect})")
check(sf.start_with?('/*') && sf.include?('Harbor Sales Model') && sf.include?('"Sales"') && sf.scan('*/').size == 1,
      'the placeholder SQL says what it stands in for, in one block comment')
typed = { 'name' => 'T', 'columns' => [{ 'name' => 'S', 'dataType' => 'string' }, { 'name' => 'D', 'dataType' => 'double' },
                                        { 'name' => 'B', 'dataType' => 'boolean' }, { 'name' => 'Calc', 'type' => 'calculated', 'dataType' => 'double' },
                                        { 'name' => 'Blob', 'dataType' => 'binary' }, { 'name' => 'Shown', 'sourceColumn' => '[Raw Name]', 'dataType' => 'int64' }] }
dbx = PbiExternalMeasure.placeholder_sql(typed, {}, 'databricks')
bq = PbiExternalMeasure.placeholder_sql(typed, {}, 'bigquery')
pg = PbiExternalMeasure.placeholder_sql(typed, {}, 'redshift')
other = PbiExternalMeasure.placeholder_sql(typed, {}, 'synapse')
check(dbx.include?('CAST(NULL AS STRING) AS `S`') && dbx.include?('CAST(NULL AS DOUBLE) AS `D`') &&
        bq.include?('CAST(NULL AS FLOAT64) AS `D`') && bq.include?('CAST(NULL AS BOOL) AS `B`') &&
        pg.include?('CAST(NULL AS DOUBLE PRECISION) AS "D"') && pg.include?('CAST(NULL AS BIGINT) AS "Raw Name"'),
      "Databricks / BigQuery / ANSI types and quoting (got #{[dbx, bq, pg].inspect})")
check(other.include?('NULL AS "S"') && !other.include?('CAST('), "an unsupported warehouse gets untyped NULLs, not another dialect's types (got #{other.inspect})")
check(!dbx.include?('Calc') && !dbx.include?('Blob'), 'calculated and binary columns are not SQL outputs (the converter does not bind them)')
check(PbiExternalMeasure.placeholder_sql(hs_table, proxies.first.merge('remote_table' => 'a */ b'), 'snowflake').scan('*/').size == 1,
      'a name containing */ cannot close the comment early')
rewritten = deep(COMPOSITE['model'])
tgaps = PbiExternalMeasure.placeholder_partitions!(rewritten, scan, 'snowflake')
native = PbiNativeQuery.native_queries(rewritten).find { |n| n.table == 'Harbor Sales' }
check(native && native.statement == sf && !native.post_transform && PbiNativeQuery.fold(native, 'snowflake').unsupported.empty?,
      'the placeholder rides the NativeQuery restore: its M decodes back to the same SQL, nothing to fold')
check(tgaps.map { |g| g.values_at('table', 'element', 'name', 'kind') } == [['Harbor Sales', 'Harbor Sales', 'Harbor Sales', 'table']] &&
        tgaps.first['reason'].include?('Harbor Sales Model') && tgaps.first['reason'].include?('zero-row'),
      "the placeholder is reported as a table gap naming the remote model (got #{tgaps.inspect})")
check(rewritten['tables'].find { |t| t['name'] == 'Targets' } == COMPOSITE['model']['tables'].find { |t| t['name'] == 'Targets' },
      'a local table is untouched')
puts "\n2e. lib: a data-model POST that fails on a proxy table's fallback path says remote table, not GRANT"
post_els = [{ 'id' => 'eS', 'name' => 'HARBOR SALES', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[SAMPLE_DB DEMO HARBOR_SALES] } },
            { 'id' => 'eT', 'name' => 'TARGETS', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[SAMPLE_DB DEMO TARGETS] } }]
by_path = PbiExternalMeasure.failure_proxies("400: Source not found: warehouse table 'SAMPLE_DB.DEMO.HARBOR_SALES'", post_els, scan)
by_id = PbiExternalMeasure.failure_proxies("cannot read table 'eS'", post_els, scan)
by_ref = PbiExternalMeasure.failure_proxies("bad formula reference 'HARBOR SALES/Region'", post_els, scan)
check([by_path, by_id, by_ref].all? { |f| f.map { |p| p['table'] } == ['Harbor Sales'] },
      "the proxy table is found from the warehouse path, the element id or a formula reference (got #{[by_path, by_id, by_ref].map { |f| f.map { |p| p['table'] } }.inspect})")
check(PbiExternalMeasure.failure_proxies("Source not found: warehouse table 'SAMPLE_DB.DEMO.TARGETS'", post_els, scan).empty? &&
        PbiExternalMeasure.failure_proxies("Source not found: warehouse table 'SAMPLE_DB.DEMO.HARBOR_SALES'", post_els, { 'proxy_tables' => [] }).empty?,
      'an ordinary unreadable table, or a model without proxy tables, is not reported as remote')
box = PbiExternalMeasure.failure_lines(by_path).join("\n")
check(box.include?('not a missing GRANT') && box.include?('Harbor Sales (remote table "Sales")') &&
        box.include?('"Harbor Sales Model" (workspace "Demo Workspace")') && box.include?('--allow-incomplete-model'),
      "the failure box names the remote table, its model and the way out (got #{box.inspect})")
check(PbiExternalMeasure.name_key('HARBOR_SALES') == PbiExternalMeasure.name_key('Harbor Sales') &&
        PbiExternalMeasure.name_key('VENTES_ÉTÉ') == PbiExternalMeasure.name_key('Ventes été'),
      'names match ignoring case and punctuation, non-ASCII letters included')

tw = ['⚠ Table "Harbor Sales": could not extract source path from M expression — using default.',
      '⚠ Table "Targets": could not extract source path from M expression — using default.']
rl = PbiExternalMeasure.relabel_warnings(tw, scan)
check(rl[0].start_with?('ℹ') && rl[0].include?('"Harbor Sales"') && rl[0] !~ /using default/ && rl[1] == tw[1],
      "the converter's default-path warning about a proxy table becomes informational (got #{rl.inspect})")

puts "\n3. lib: neutralize! turns pointers and their dependents into Null gaps"
dm = { 'pages' => [{ 'elements' => [
  { 'name' => 'HARBOR_SALES', 'metrics' => [
    { 'id' => 'm1', 'name' => 'Remote Revenue', 'formula' => 'EXTERNALMEASURE("Net Revenue", DOUBLE, "DirectQuery to AS - Harbor Sales Model")' },
    { 'id' => 'm2', 'name' => 'Remote Margin', 'formula' => 'EXTERNALMEASURE("Gross Margin", DOUBLE, "DirectQuery to AS - Harbor Finance Model")' }
  ] },
  { 'name' => 'TARGETS', 'metrics' => [
    { 'id' => 'm3', 'name' => 'Total Target', 'formula' => 'Sum([Target])' },
    { 'id' => 'm4', 'name' => 'Revenue vs Target', 'formula' => '([Remote Revenue]) / NullIf(([Total Target]), 0)' },
    { 'id' => 'm5', 'name' => 'Revenue Gap', 'formula' => '[Revenue vs Target] - 1' }
  ], 'columns' => [{ 'id' => 'c1', 'name' => 'Odd', 'formula' => 'EXTERNALMEASURE("Y", DOUBLE, "DirectQuery to AS - Harbor Sales Model")' }] }
] }] }
gaps = PbiExternalMeasure.neutralize!(dm, scan)
check(formulas(dm).none? { |f| f.match?(/EXTERNALMEASURE/i) }, 'no formula in the data model carries EXTERNALMEASURE')
check(%w[Remote\ Revenue Remote\ Margin Revenue\ vs\ Target Revenue\ Gap].all? { |n| metric(dm, n)['formula'] == 'Null' },
      'pointer metrics and the metrics built on them are Null')
check(metric(dm, 'Total Target')['formula'] == 'Sum([Target])', 'the local metric is untouched')
check(metric(dm, 'Remote Revenue')['description'].to_s.include?('Harbor Sales Model') &&
        !metric(dm, 'Remote Revenue')['description'].to_s.match?(/EXTERNALMEASURE/i),
      'a nulled pointer metric says which remote model holds it (without the raw pointer text)')
check(gaps.map { |g| g['name'] }.sort == ['Odd', 'Remote Margin', 'Remote Revenue', 'Revenue Gap', 'Revenue vs Target'],
      "every nulled metric or column is reported as a gap (got #{gaps.map { |g| g['name'] }.inspect})")
check(gaps.find { |g| g['name'] == 'Revenue Gap' }.to_h['reason'].to_s.include?('built on'),
      'a dependent gap says it is built on a remote measure')
check(PbiExternalMeasure.neutralize!(dm, scan).empty?, 'neutralize! is idempotent')
check(gaps.find { |g| g['name'] == 'Remote Revenue' }.to_h.values_at('table', 'element') == ['Harbor Sales', 'HARBOR_SALES'],
      'a gap names both its Power BI table and its data model element')
region_scan = PbiExternalMeasure.scan({ 'tables' => [
  { 'name' => '_Measures', 'measures' => [
    { 'name' => 'Region', 'expression' => 'EXTERNALMEASURE("Region Count", INTEGER, "DirectQuery to AS - M")' },
    { 'name' => 'Revenue', 'expression' => 'EXTERNALMEASURE("Revenue", DOUBLE, "DirectQuery to AS - M")' }] },
  { 'name' => 'ORDERS', 'columns' => [{ 'name' => 'Region' }, { 'name' => 'REVENUE' }] }] })
rehomed = { 'pages' => [{ 'elements' => [{ 'name' => 'ORDERS',
  'columns' => [{ 'id' => 'c1', 'formula' => '[ORDERS/Region]' }, { 'id' => 'c2', 'name' => 'Revenue Usd', 'formula' => '[ORDERS/REVENUE]' }],
  'metrics' => [{ 'id' => 'm1', 'name' => 'Region', 'formula' => 'EXTERNALMEASURE("Region Count", INTEGER, "DirectQuery to AS - M")' },
                { 'id' => 'm2', 'name' => 'Revenue', 'formula' => 'EXTERNALMEASURE("Revenue", DOUBLE, "DirectQuery to AS - M")' },
                { 'id' => 'm3', 'name' => 'Local Revenue', 'formula' => 'Sum([REVENUE])' }] }] }] }
rgaps = PbiExternalMeasure.neutralize!(rehomed, region_scan)
rel = rehomed['pages'][0]['elements'][0]
check(rel['columns'].map { |c| c['formula'] } == ['[ORDERS/Region]', '[ORDERS/REVENUE]'] &&
        metric(rehomed, 'Local Revenue')['formula'] == 'Sum([REVENUE])',
      'a warehouse column or local metric that shares a pointer\'s name is left alone')
check(rgaps.map { |g| g['name'] }.sort == %w[Region Revenue], "only the two pointer metrics are gaps (got #{rgaps.map { |g| g['name'] }.inspect})")
tdm = { 'pages' => [{ 'elements' => [{ 'name' => 'TARGETS', 'metrics' => [{ 'id' => 'm1', 'name' => 'Remote Order Count', 'formula' => 'Count()' }] }] }] }
tdgaps = PbiExternalMeasure.neutralize!(tdm, scan)
check(metric(tdm, 'Remote Order Count')['formula'] == 'Null' && tdgaps.first.to_h['reason'].to_s.include?('remote table') &&
        metric(tdm, 'Remote Order Count')['description'].to_s.include?('Harbor Sales'),
      "a metric over a proxy table is a Null gap that names the remote table (got #{tdgaps.inspect})")

puts "\n3b. lib: measures the converter dropped come back as Null metrics; their warnings stop asking for a restructure"
dropped = { 'pages' => [{ 'elements' => [
  { 'id' => 'eH', 'name' => 'HARBOR_SALES', 'metrics' => [{ 'id' => 'm1', 'name' => 'Remote Revenue', 'formula' => 'Null' },
                                                          { 'id' => 'm2', 'name' => 'Remote Margin', 'formula' => 'Null' }] },
  { 'id' => 'eT', 'name' => 'Targets', 'metrics' => [{ 'id' => 'm3', 'name' => 'Total Target', 'formula' => 'Sum([Target])' }] }
] }] }
placed = PbiExternalMeasure.place_missing!(dropped, scan, home: { 'targets' => dropped['pages'][0]['elements'][1] })
check(placed.map { |g| g['name'] }.sort == ['Remote Order Count', 'Remote Revenue K', 'Revenue Gap', 'Revenue vs Target'],
      "every pointer or dependent missing from the data model is added and reported (got #{placed.map { |g| g['name'] }.inspect})")
targets_metrics = dropped['pages'][0]['elements'][1]['metrics'].map { |m| [m['name'], m['formula']] }
check(targets_metrics.include?(['Revenue vs Target', 'Null']) && targets_metrics.include?(['Revenue Gap', 'Null']),
      "a dropped dependent is a Null metric on its home table's element (got #{targets_metrics.inspect})")
check(metric(dropped, 'Remote Revenue K').to_h['formula'] == 'Null' &&
        dropped['pages'][0]['elements'][0]['metrics'].any? { |m| m['name'] == 'Remote Revenue K' },
      'without a home element it goes on the element of the measure it is built on')
ids = dropped['pages'][0]['elements'].flat_map { |e| e['metrics'] }.map { |m| m['id'] }
check(ids.uniq.size == ids.size && ids.all? { |i| i.is_a?(String) && !i.empty? }, "added metrics get unique ids (got #{ids.inspect})")
check(PbiExternalMeasure.place_missing!(dropped, scan, home: {}).empty?, 'place_missing! is idempotent')
# home_elements: a calculated or proxy table has no warehouse path, so it is matched by table ORDER, but
# only when the converter emitted exactly one base element per table (Views do not count).
e_sales = { 'name' => 'SALES', 'source' => { 'kind' => 'warehouse-table' } }
e_store = { 'name' => 'STORE', 'source' => { 'kind' => 'warehouse-table' } }
e_calc = { 'source' => { 'kind' => 'sql' } }
e_view = { 'name' => 'SALES View', 'source' => { 'kind' => 'table' } }
tbl = ->(*names) { names.map { |n| { 'name' => n } } }
aligned = PbiExternalMeasure.home_elements([e_sales, e_store, e_calc, e_view], tbl.call('Sales', 'Store', 'Targets'), { 0 => 'Sales', 1 => 'Store' })
check(aligned['targets'].equal?(e_calc) && aligned['sales'].equal?(e_sales),
      'a table with no warehouse path gets the base element in its table position')
skipped = PbiExternalMeasure.home_elements([e_sales, e_calc, e_view], tbl.call('Sales', 'LocalDateTable_x', 'Targets'), { 0 => 'Sales' })
check(skipped['targets'].equal?(e_calc) && !skipped.key?('localdatetable_x'),
      'a table the converter never emits (an auto date table) does not shift the order')
skewed = PbiExternalMeasure.home_elements([e_sales, e_calc, e_view], tbl.call('Sales', 'Unexpected', 'Targets'), { 0 => 'Sales' })
check(!skewed.key?('targets') && !skewed.key?('unexpected') && skewed['sales'].equal?(e_sales),
      "when the elements still do not line up with the tables, order is not used (got #{skewed.keys.inspect})")
nameless = { 'pages' => [{ 'elements' => [{ 'id' => 'eS', 'name' => 'SALES', 'metrics' => [{ 'id' => 's1', 'name' => 'Remote Revenue', 'formula' => 'Null' }] },
                                           { 'id' => 'eC', 'source' => { 'kind' => 'sql' }, 'metrics' => [] }] }] }
ngaps = PbiExternalMeasure.place_missing!(nameless, scan, home: { 'targets' => nameless['pages'][0]['elements'][1] })
check(ngaps.select { |g| g['table'] == 'Targets' }.map { |g| g['element'] }.uniq == ['Targets'],
      "a gap on a nameless element names it by its Power BI table (got #{ngaps.map { |g| g['element'] }.uniq.inspect})")
warnings = ['⚠ "Revenue vs Target": references "[Remote Revenue]" which is not a column or metric on this element (cross-table measure) — dropped.',
            '⚠ "Other Measure": references "[X]" (cross-table measure) — dropped.',
            '⛔ "Remote Margin": no translation']
relabeled = PbiExternalMeasure.relabel_warnings(warnings, scan)
check(relabeled[0].start_with?('ℹ') && relabeled[0].include?('remote') && relabeled[2].start_with?('ℹ'),
      "a converter warning about a pointer or dependent becomes informational (got #{relabeled.inspect})")
check(relabeled[0] !~ /cross-table|different relationship path/i && relabeled[0].include?('"Revenue vs Target"'),
      'the rewritten warning keeps the measure name but not the cross-table wording the coverage gate keys on')
check(relabeled[1] == warnings[1], 'a warning about any other measure is unchanged')

puts "\n4. orchestrator, --pbix route (offline)"
Dir.mktmpdir('pbi-externalmeasure') do |dir|
  signals = File.join(dir, 'signals.canned.json')
  _o, e, st = Open3.capture3('python3', File.join(__dir__, 'extract-report-classic.py'),
                             '--report-json', File.join(FIXTURE, 'report.json'), '--out', signals)
  abort "fixture signals failed: #{e}" unless st.success?

  # The non-composite twin: same report, the pointers and their dependents and
  # the remote connections removed (an ordinary import model).
  plain = JSON.parse(JSON.generate(COMPOSITE))
  pm = plain['model']
  pm['tables'].each do |t|
    t['measures'].reject! { |m| m['expression'].include?('EXTERNALMEASURE') || m['expression'].include?('[Re') || m['expression'].include?("'Harbor Sales'") }
  end
  pm.delete('expressions')
  # ... and Harbor Sales an ordinary warehouse table.
  pm['tables'].find { |t| t['name'] == 'Harbor Sales' }['partitions'] = [
    { 'name' => 'Harbor Sales', 'mode' => 'import', 'source' => { 'type' => 'm', 'expression' => [
      'let', '    Source = Snowflake.Databases("example-account.snowflakecomputing.com", "EXAMPLE_WH"),',
      '    DB = Source{[Name = "SAMPLE_DB", Kind = "Database"]}[Data],', '    SCH = DB{[Name = "DEMO", Kind = "Schema"]}[Data],',
      '    T = SCH{[Name = "HARBOR_SALES", Kind = "Table"]}[Data]', 'in', '    T'
    ] } }
  ]

  cur_signals = signals
  cur_report = File.join(FIXTURE, 'report.json')
  run = lambda do |name, model, composite, *extra|
    case_dir = File.join(dir, name)
    FileUtils.mkdir_p(case_dir)
    File.write(File.join(case_dir, 'model.bim'), JSON.pretty_generate(model))
    File.write(File.join(case_dir, 'a.pbix'), 'not-a-real-pbix')
    fake_py = File.join(case_dir, 'fakepy')
    File.write(fake_py, <<~SH)
      #!/bin/sh
      case "$*" in
        *--detect-composite*) echo '{"composite":#{composite},"remoteArtifacts":[]}'; exit 0;;
        *extract-model-pbix.py*) out=""; prev=""
          for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
          cp "#{File.join(case_dir, 'model.bim')}" "$out"; exit 0;;
        *extract-report-classic.py*) out=""; dump=""; prev=""
          for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; [ "$prev" = "--dump-layout" ] && dump="$a"; prev="$a"; done
          cp "#{cur_signals}" "$out"; cp "#{cur_report}" "$dump"; exit 0;;
        *importlib.metadata*) echo 9.9.9; exit 0;;
      esac
      exec python3 "$@"
    SH
    File.chmod(0o755, fake_py)
    work = File.join(case_dir, 'w')
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, status = Open3.capture2e(RbConfig.ruby, MIGRATE, '--pbix', File.join(case_dir, 'a.pbix'), '--python', fake_py,
                                  '--out', work, '--connection', CONN, '--database', 'SAMPLE_DB', '--schema', 'DEMO', *extra)
    [out, status.exitstatus, work]
  end

  puts "\n4a. composite model: stop before conversion, naming the remote models"
  out, code, work = run.call('stop', COMPOSITE, true)
  check(code == 10, "exit 10 (got #{code})")
  check(out.include?('EXTERNALMEASURE') && out.include?('Harbor Sales Model') && out.include?('Harbor Finance Model'),
        'the stop names both remote models')
  check(out.include?('Demo Workspace') && out.include?('--allow-incomplete-model'),
        'the stop names the workspace and the --allow-incomplete-model choice')
  check(!out.include?('decisions_needed') && !File.exist?(File.join(work, 'dm-raw.json')),
        'it stops before conversion (no dm-raw.json, no decisions checkpoint)')
  check(!out.include?('carries the COMPLETE'), 'Phase 0 no longer claims the local file carries the complete model')
  rec = File.exist?(File.join(work, 'external-measures.json')) ? jread(File.join(work, 'external-measures.json')) : {}
  check(rec['status'] == 'blocked' && rec['remote_models'].to_a.size == 2 && rec['pointers'].to_a.size == 2,
        "external-measures.json records the stop (got status #{rec['status'].inspect})")
  check(out.include?('Harbor Sales (remote table "Sales")') && out.include?('1 table(s) are DirectQuery proxies'),
        'the stop names the proxy table and the remote table it mirrors')
  check(rec['proxy_tables'].to_a.map { |p| [p['table'], p['remote_table'], p['model']] } == [['Harbor Sales', 'Sales', 'Harbor Sales Model']],
        "external-measures.json records the proxy table (got #{rec['proxy_tables'].inspect})")

  puts "\n4b. --allow-incomplete-model: pointers and their dependents become Null gaps"
  out, code, work = run.call('allow', COMPOSITE, true, '--allow-incomplete-model')
  check(code == 10 && out.include?('decisions_needed'), "the run continues to the decisions checkpoint (exit #{code})#{code == 10 && out.include?('decisions_needed') ? '' : "\n#{out[-3000..] || out}"}")
  dm_path = File.join(work, 'dm-raw.json')
  dm_raw = File.exist?(dm_path) ? jread(dm_path) : {}
  meta = File.exist?(File.join(work, 'conv-meta.json')) ? jread(File.join(work, 'conv-meta.json')) : {}
  check(!formulas(dm_raw).empty? && formulas(dm_raw).none? { |f| f.match?(/EXTERNALMEASURE/i) } &&
          formulas(meta).none? { |f| f.match?(/EXTERNALMEASURE/i) },
        'no formula in dm-raw.json or conv-meta.json carries EXTERNALMEASURE')
  check(['Remote Revenue', 'Remote Margin', 'Remote Revenue K', 'Revenue vs Target', 'Revenue Gap', 'Remote Order Count'].all? { |n| metric(dm_raw, n).to_h['formula'] == 'Null' },
        'every pointer and every measure built on one or on the remote table is a Null metric, also the ones the converter dropped')
  check(metric(dm_raw, 'Total Target').to_h['formula'].to_s.match?(/Sum/i), 'the local metric still converts')
  rec = File.exist?(File.join(work, 'external-measures.json')) ? jread(File.join(work, 'external-measures.json')) : {}
  metric_gaps = rec['gaps'].to_a.reject { |g| g['kind'] == 'table' }.map { |g| g['name'] }.sort
  check(rec['status'] == 'accepted_incomplete' &&
          metric_gaps == ['Remote Margin', 'Remote Order Count', 'Remote Revenue', 'Remote Revenue K', 'Revenue Gap', 'Revenue vs Target'],
        "external-measures.json reports every metric gap, also the ones the converter dropped (got #{metric_gaps.inspect})")
  hs_el = elements(dm_raw).find { |e| e['name'] == 'Harbor Sales' } || {}
  check(hs_el.dig('source', 'kind') == 'sql' && hs_el.dig('source', 'statement').to_s.include?('WHERE 1 = 0') &&
          hs_el.dig('source', 'statement').to_s.include?('Harbor Sales Model') &&
          Array(hs_el['columns']).map { |c| c['formula'] }.include?('[Custom SQL/Region]'),
        "the proxy table ships as a zero-row Custom SQL placeholder with its columns bound (got #{hs_el['source'].inspect})")
  check(elements(dm_raw).none? { |e| e.dig('source', 'kind') == 'warehouse-table' && Array(e.dig('source', 'path')).last.to_s.casecmp('HARBOR_SALES').zero? },
        'no element ships the guessed --database/--schema path for the proxy table')
  check(rec['gaps'].to_a.select { |g| g['kind'] == 'table' }.map { |g| [g['name'], g['element']] } == [['Harbor Sales', 'Harbor Sales']] &&
          rec['proxy_tables'].to_a.size == 1,
        "external-measures.json reports the proxy table as a table gap (got #{rec['gaps'].to_a.select { |g| g['kind'] == 'table' }.inspect})")
  check(meta['warnings'].to_a.none? { |w| w.include?('"Harbor Sales"') && w.include?('could not extract source path') } &&
          out.lines.none? { |l| l.include?('"detail"') && l.include?('could not extract source path') && l.include?('Harbor Sales') },
        'the converter default-path warning about the proxy table is replaced, not raised as a question')
  target_el = (dm_raw['pages'] || []).flat_map { |p| p['elements'] || [] }
                                         .find { |el| Array(el['metrics']).any? { |m| m['name'] == 'Total Target' } }
  dependent_els = rec['gaps'].to_a.select { |g| ['Revenue Gap', 'Revenue vs Target', 'Remote Order Count'].include?(g['name']) }
                                  .map { |g| g['element'] }.uniq
  check(target_el && dependent_els == [target_el['name']],
        "dropped dependents stay on their Power BI table's element (got #{dependent_els.inspect})")
  check(meta['warnings'].to_a.none? { |w| w.include?('Revenue vs Target') && w =~ /cross-table/i } &&
          out.lines.none? { |l| l.include?('"detail"') && l.include?('Revenue vs Target') },
        'the cross-table drop of a measure built on a remote measure is not raised as a restructure question')
  offramps = File.exist?(File.join(work, 'offramps.jsonl')) ? File.readlines(File.join(work, 'offramps.jsonl')).map { |l| JSON.parse(l) } : []
  check(File.exist?(File.join(work, 'external-measures.json')) && rec['gaps'].to_a.all? { |g| g['table'] && g['element'] },
        'each reported gap names its Power BI table and its data model element')
  el_names = elements(dm_raw).map { |e| e['name'] }
  check(rec['gaps'].to_a.all? { |g| el_names.include?(g['element']) },
        "every gap names an element that exists in dm-raw.json, also after the placeholder restore renamed one " \
        "(got #{rec['gaps'].to_a.map { |g| g['element'] }.uniq.inspect} vs #{el_names.inspect})")
  check(offramps.any? { |r| r['kind'] == 'skip-flag-waived' && r['detail'] == '--allow-incomplete-model' && r['reason'].to_s.include?('Harbor Sales Model') &&
                            r['reason'].to_s.include?('remote table') },
        'the escape is recorded for the degradation ledger (skip-flag-waived --allow-incomplete-model), remote tables included')
  check(out.lines.any? { |l| l.include?('Remote Revenue') && l.include?('Harbor Sales Model') } &&
          out.lines.any? { |l| l.include?('Revenue Gap') && l.include?('built on') } && out.include?('external-measures.json') &&
          out.lines.any? { |l| l.include?('Harbor Sales (') && l.include?('zero-row') },
        'the run prints each gap with its remote model or what it is built on, the placeholder table too')

  shifted = JSON.parse(JSON.generate(COMPOSITE))
  shifted['model']['tables'].insert(1, {
    'name' => 'LocalDateTable_shift', 'columns' => [{ 'name' => 'Date', 'dataType' => 'dateTime' }]
  })
  shifted['model']['tables'][2]['partitions'][0]['source']['expression'] =
    ['-- no warehouse path captured for this proxy table']
  out, code, work = run.call('shifted-home', shifted, true, '--allow-incomplete-model', '--full-model')
  shifted_dm = jread(File.join(work, 'dm-raw.json'))
  target_el = (shifted_dm['pages'] || []).flat_map { |p| p['elements'] || [] }
                                             .find { |el| Array(el['metrics']).any? { |m| m['name'] == 'Total Target' } }
  check(code == 10 && target_el &&
          ['Revenue Gap', 'Revenue vs Target'].all? { |n| Array(target_el['metrics']).any? { |m| m['name'] == n } },
        'skipped auto-date tables do not shift the fallback home for dropped metrics')

  puts "\n4c. non-composite .pbix: unchanged"
  out, code, work = run.call('plain', plain, false)
  check(code == 10 && out.include?('decisions_needed'), "the run reaches the decisions checkpoint (exit #{code})")
  check(!out.include?('EXTERNALMEASURE') && !File.exist?(File.join(work, 'external-measures.json')),
        'no remote-measure stop and no gap record')
  offramps = File.exist?(File.join(work, 'offramps.jsonl')) ? File.read(File.join(work, 'offramps.jsonl')) : ''
  check(!offramps.include?('--allow-incomplete-model'), 'no --allow-incomplete-model escape is recorded')
  check(metric(jread(File.join(work, 'dm-raw.json')), 'Total Target').to_h['formula'].to_s.match?(/Sum/i), 'the local metric converts as before')

  puts "\n4e. --converter-out with pointers the report does not use: still stopped, or neutralized"
  only_local = File.join(dir, 'only-local.json')
  rj = jread(File.join(FIXTURE, 'report.json'))
  rj['sections'][0]['visualContainers'].select! { |vc| vc['config'].include?('Total Target') }
  File.write(only_local, JSON.generate(rj))
  lsig = File.join(dir, 'signals.local.json')
  _o, e, st = Open3.capture3('python3', File.join(__dir__, 'extract-report-classic.py'), '--report-json', only_local, '--out', lsig)
  abort "local signals failed: #{e}" unless st.success?
  cvt = File.join(dir, 'cvt-full.json')
  _o, e, st = Open3.capture3('node', '--input-type=module', '-e', <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    const { convertPowerBIToSigma } = await import(pathToFileURL(#{File.join(SKILL, 'converter', 'powerbi.mjs').to_json}).href);
    const out = convertPowerBIToSigma(JSON.parse(readFileSync(#{File.join(FIXTURE, 'model.bim').to_json}, 'utf8')),
      { connectionId: #{CONN.to_json}, database: 'SAMPLE_DB', schema: 'DEMO', warehouseType: '' });
    writeFileSync(#{cvt.to_json}, JSON.stringify(out));
  JS
  abort "full-model conversion failed: #{e}" unless st.success?
  # --pbix route (no composite gate there); the report uses no pointer, so the scoped scan is clean.
  cur_signals = lsig
  cur_report = only_local
  out, code, work = run.call('cvt-stop', COMPOSITE, true, '--converter-out', cvt)
  check(code == 10 && !out.include?('decisions_needed') && out.include?('Harbor Sales Model') &&
          (jread(File.join(work, 'external-measures.json'))['status'] rescue nil) == 'blocked',
        "pointers that arrive in --converter-out stop the run and name the remote models (exit #{code})")
  out, code, work = run.call('cvt-allow', COMPOSITE, true, '--converter-out', cvt, '--allow-incomplete-model')
  dm_raw = jread(File.join(work, 'dm-raw.json'))
  check(code == 10 && out.include?('decisions_needed') && formulas(dm_raw).none? { |f| f.match?(/EXTERNALMEASURE/i) },
        "with the override they are neutralized even though the report uses none (exit #{code})")
  cur_signals = signals
  cur_report = File.join(FIXTURE, 'report.json')

  puts "\n4f. convert-model.rb (the run.sh route) refuses a converter output that still carries a pointer"
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, st3 = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'convert-model.rb'), '--converter-out', cvt,
                             '--out', File.join(dir, 'cm-spec.json'), '--name', 'zz test')
  check(st3.exitstatus == 10 && out.include?('EXTERNALMEASURE') && out.include?('migrate-powerbi.rb') && !File.exist?(File.join(dir, 'cm-spec.json')),
        "it stops (exit #{st3.exitstatus}) and points at migrate-powerbi.rb, writing no spec")

  puts "\n4d. Fabric --tmsl route: the composite gate names the remote models; the override neutralizes"
  fdir = File.join(dir, 'fabric')
  FileUtils.mkdir_p(fdir)
  File.write(File.join(fdir, 'bundle.json'), JSON.generate('report.json' => File.read(File.join(FIXTURE, 'report.json'))))
  fabric = lambda do |*extra|
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    o, st = Open3.capture2e(RbConfig.ruby, MIGRATE, '--tmsl', File.join(FIXTURE, 'model.bim'), '--pbir', File.join(fdir, 'bundle.json'),
                            '--out', File.join(fdir, "w#{extra.size}"), '--connection', CONN, '--database', 'SAMPLE_DB', '--schema', 'DEMO', *extra)
    [o, st.exitstatus]
  end
  out, code = fabric.call
  check(code == 10 && out.include?('composite / live-connected report') &&
          out.include?('"Harbor Sales Model" (workspace "Demo Workspace")') &&
          out.include?('"Harbor Finance Model" (workspace "Finance Demo")') && out.include?('migrate those models first'),
        "the composite gate stops (exit #{code}) and names both remote models and their workspaces")
  check(out.include?('Harbor Sales (remote table "Sales")'), 'the composite gate names the proxy table too')
  out, code = fabric.call('--allow-incomplete-model')
  dm_raw = jread(File.join(fdir, 'w1', 'dm-raw.json'))
  check(code == 10 && out.include?('decisions_needed') && formulas(dm_raw).none? { |f| f.match?(/EXTERNALMEASURE/i) } &&
          metric(dm_raw, 'Remote Revenue').to_h['formula'] == 'Null',
        "with the override no formula carries EXTERNALMEASURE (exit #{code})")
  fhs = elements(dm_raw).find { |e| e['name'] == 'Harbor Sales' } || {}
  check(fhs.dig('source', 'kind') == 'sql' && fhs.dig('source', 'statement').to_s.include?('WHERE 1 = 0'),
        "with the override the Fabric proxy table is the same zero-row placeholder (got #{fhs['source'].inspect})")

  puts "\n4g. --pbix: a proxy table alone (no EXTERNALMEASURE pointer) still stops, naming the remote model and table"
  tonly = deep(COMPOSITE)
  tonly['model']['tables'].each do |t|
    t['measures'].select! { |m| ['Total Target', 'Remote Order Count'].include?(m['name']) }
  end
  tonly_report = File.join(dir, 'table-only.json')
  trj = jread(File.join(FIXTURE, 'report.json'))
  trj['sections'][0]['visualContainers'].select! { |vc| vc['config'].include?('Total Target') || vc['config'].include?('Remote Order Count') }
  File.write(tonly_report, JSON.generate(trj))
  tsig = File.join(dir, 'signals.table-only.json')
  _o, e, st = Open3.capture3('python3', File.join(__dir__, 'extract-report-classic.py'), '--report-json', tonly_report, '--out', tsig)
  abort "table-only signals failed: #{e}" unless st.success?
  cur_signals = tsig
  cur_report = tonly_report
  out, code, work = run.call('table-stop', tonly, true)
  trec = File.exist?(File.join(work, 'external-measures.json')) ? jread(File.join(work, 'external-measures.json')) : {}
  check(code == 10 && !out.include?('decisions_needed') && !File.exist?(File.join(work, 'dm-raw.json')) &&
          out.include?('Harbor Sales (remote table "Sales")') && out.include?('"Harbor Sales Model" (workspace "Demo Workspace")'),
        "it stops before conversion (exit #{code}) and names the remote model and the remote table")
  check(trec['status'] == 'blocked' && trec['pointers'] == [] && trec['proxy_tables'].to_a.map { |p| p['table'] } == ['Harbor Sales'] &&
          trec['dependents'].to_a.map { |d| d['measure'] } == ['Remote Order Count'],
        "external-measures.json records the proxy table and the measure built on it (got #{trec.reject { |k, _| k == 'remote_models' }.inspect})")
  out, code, work = run.call('table-allow', tonly, true, '--allow-incomplete-model')
  tdm_raw = File.exist?(File.join(work, 'dm-raw.json')) ? jread(File.join(work, 'dm-raw.json')) : {}
  ths = elements(tdm_raw).find { |e| e['name'] == 'Harbor Sales' } || {}
  check(code == 10 && out.include?('decisions_needed') && ths.dig('source', 'kind') == 'sql' &&
          metric(tdm_raw, 'Remote Order Count').to_h['formula'] == 'Null' && metric(tdm_raw, 'Total Target').to_h['formula'].to_s.match?(/Sum/i),
        "with the override it continues: placeholder table, Null metric over it, local metric intact (exit #{code})")
  cur_signals = signals
  cur_report = File.join(FIXTURE, 'report.json')
end

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "#{FAILS.size} FAIL(S)"
  FAILS.each { |f| puts "  - #{f}" }
  exit 1
end
