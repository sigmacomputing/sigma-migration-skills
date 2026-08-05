#!/usr/bin/env ruby
# Offline unit test for hydrate-custom-sql.rb — the published-datasource (sqlproxy)
# Custom SQL splice. Deterministic, no network / creds.
#
# Usage:  ruby scripts/test-hydrate-custom-sql.rb

require 'rexml/document'
require_relative 'hydrate-custom-sql'

fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

H = HydrateCustomSql

puts 'Part A — alias_for / quote_ref / wrap_sql (pure)'
check(H.alias_for('SFDC Oppty ID') == 'SFDC_OPPTY_ID', 'alias_for spaces→upper-snake', fails)
check(H.alias_for('Amount USD') == 'AMOUNT_USD', 'alias_for another spaced name', fails)
check(H.alias_for('STAGE_NAME') == 'STAGE_NAME', 'alias_for already-upper is identity', fails)
check(H.alias_for('Sub-Category') == 'SUB_CATEGORY', 'alias_for dash→underscore', fails)
check(H.quote_ref('Sales Region') == '"Sales Region"', 'quote_ref quotes mixed-case', fails)
check(H.quote_ref('STAGE_NAME') == 'STAGE_NAME', 'quote_ref leaves upper bare', fails)
wrapped = H.wrap_sql('SELECT a FROM t', ['SFDC Oppty ID', 'STAGE_NAME'])
check(wrapped.include?('"SFDC Oppty ID" AS SFDC_OPPTY_ID'), 'wrap_sql quotes+aliases mixed-case col', fails)
check(wrapped.include?('STAGE_NAME AS STAGE_NAME'), 'wrap_sql keeps upper col bare (aliased)', fails)
check(wrapped.include?('FROM (') && wrapped.include?(') t'), 'wrap_sql wraps original SQL in a subquery', fails)
begin
  H.wrap_sql('SELECT 1', [])
  check(false, 'wrap_sql raises on empty columns', fails)
rescue ArgumentError
  check(true, 'wrap_sql raises on empty columns', fails)
end

puts 'Part B — connection classification'
sqlproxy_twb = <<~XML
  <workbook><datasources>
    <datasource caption='Dormant Accounts' name='federated.d'>
      <connection class='sqlproxy' dbname='DormantAccounts'>
        <relation name='DormantAccounts' table='[sqlproxy]' type='table' />
        <metadata-records>
          <metadata-record class='column'><remote-name>SFDC Oppty ID</remote-name><caption>SFDC Oppty ID</caption></metadata-record>
          <metadata-record class='column'><remote-name>Sales Region</remote-name><caption>Sales Region</caption></metadata-record>
          <metadata-record class='measure'><remote-name>Amount USD</remote-name><caption>Amount USD</caption></metadata-record>
        </metadata-records>
      </connection>
    </datasource>
    <datasource caption='Live' name='federated.live'>
      <connection class='snowflake' dbname='DEMO_DB' schema='DEMO'>
        <relation name='ORDERS' table='[DEMO_DB].[DEMO].[ORDERS]' type='table' />
      </connection>
    </datasource>
  </datasources></workbook>
XML
doc = REXML::Document.new(sqlproxy_twb)
proxy_conn = doc.elements["/workbook/datasources/datasource[@caption='Dormant Accounts']/connection"]
live_conn  = doc.elements["/workbook/datasources/datasource[@caption='Live']/connection"]
check(H.sqlproxy_connection?(proxy_conn), 'detects sqlproxy connection', fails)
check(!H.sqlproxy_connection?(live_conn), 'live snowflake connection is not sqlproxy', fails)
check(!H.has_real_relation?(proxy_conn), 'sqlproxy placeholder is not a real relation', fails)
check(H.has_real_relation?(live_conn), 'live table relation is a real relation', fails)
check(H.cached_columns(proxy_conn) == ['SFDC Oppty ID', 'Sales Region', 'Amount USD'], 'cached_columns reads remote-names', fails)
check(H.published_ds_name(proxy_conn) == 'DormantAccounts', 'published_ds_name reads dbname', fails)
require 'tempfile'
Tempfile.create(['sqlproxy', '.twb']) do |f|
  f.write(sqlproxy_twb); f.flush
  check(H.twb_has_sqlproxy?(f.path), 'twb_has_sqlproxy? true for a sqlproxy workbook', fails)
end
Tempfile.create(['live', '.twb']) do |f|
  f.write("<workbook><datasources><datasource caption='L'><connection class='snowflake'><relation name='O' table='[A].[B].[O]' type='table'/></connection></datasource></datasources></workbook>")
  f.flush
  check(!H.twb_has_sqlproxy?(f.path), 'twb_has_sqlproxy? false for a live-table-only workbook', fails)
end

puts 'Part C — query_for matching'
blocks = [
  { 'name' => 'Dormant SQL', 'query' => 'SELECT 1 FROM x',
    'downstreamDatasources' => [{ 'name' => 'DormantAccounts' }] },
  { 'name' => 'Other SQL', 'query' => 'SELECT 2 FROM y', 'downstreamDatasources' => [{ 'name' => 'Other' }] }
]
q, _ = H.query_for(proxy_conn, 'Dormant Accounts', blocks)
check(q == 'SELECT 1 FROM x', 'query_for matches by downstream datasource name', fails)
q1, _ = H.query_for(proxy_conn, 'Dormant Accounts', [{ 'name' => 'x', 'query' => 'SELECT 9', 'downstreamDatasources' => [] }])
check(q1 == 'SELECT 9', 'query_for falls back to the lone block', fails)
qn, _ = H.query_for(proxy_conn, 'Dormant Accounts', [])
check(qn.nil?, 'query_for returns nil when nothing matches', fails)

puts 'Part D — hydrate! end-to-end (XML mutation)'
doc2 = REXML::Document.new(sqlproxy_twb)
hydrated = H.hydrate!(doc2, blocks: blocks, db: 'DEMO_DB', schema: 'DEMO')
check(hydrated.size == 1, 'exactly one datasource hydrated (the sqlproxy one)', fails)
check(hydrated.first['column_source'] == 'cached-metadata', 'columns sourced from cached metadata when no probe', fails)
new_proxy = doc2.elements["/workbook/datasources/datasource[@caption='Dormant Accounts']/connection"]
check(new_proxy.attributes['class'] == 'snowflake', 'connection class rewritten to warehouse', fails)
check(new_proxy.attributes['dbname'] == 'DEMO_DB' && new_proxy.attributes['schema'] == 'DEMO', 'db/schema set on connection', fails)
text_rel = nil
new_proxy.each_element('.//relation') { |r| text_rel = r if (r.attributes['type'] == 'text') }
check(!text_rel.nil?, 'a <relation type=text> was spliced in', fails)
check(new_proxy.get_elements('.//relation').size == 1, 'the sqlproxy placeholder relation was removed', fails)
sql = text_rel&.text.to_s
check(sql.include?('"SFDC Oppty ID" AS SFDC_OPPTY_ID'), 'spliced SQL quotes+aliases mixed-case output col', fails)
check(sql.include?('"Sales Region" AS SALES_REGION'), 'spliced SQL aliases Sales Region', fails)
check(sql.include?('SELECT 1 FROM x'), 'original Custom SQL preserved verbatim inside the wrap', fails)
remotes = []
new_proxy.each_element('.//metadata-records/metadata-record') { |m| remotes << m.get_text('remote-name').value }
check(remotes == %w[SFDC_OPPTY_ID SALES_REGION AMOUNT_USD], 'metadata remote-names rewritten to upper-snake aliases', fails)
# The live datasource must be untouched.
live2 = doc2.elements["/workbook/datasources/datasource[@caption='Live']/connection"]
check(live2.attributes['class'] == 'snowflake' && live2.get_elements('.//relation').first.attributes['type'] == 'table',
      'non-sqlproxy datasource left unchanged', fails)

puts 'Part E — probe columns override cached metadata'
doc3 = REXML::Document.new(sqlproxy_twb)
H.hydrate!(doc3, blocks: blocks, columns_by_key: { 'dormantaccounts' => ['Only One Col'] }, db: 'DEMO_DB', schema: 'DEMO')
c3 = doc3.elements["/workbook/datasources/datasource[@caption='Dormant Accounts']/connection"]
rel3 = nil; c3.each_element('.//relation') { |r| rel3 = r if r.attributes['type'] == 'text' }
check(rel3.text.to_s.include?('"Only One Col" AS ONLY_ONE_COL'), 'probe columns override cached metadata', fails)

puts 'Part F — parse_sql_columns (published-DS Custom SQL is its own column source)'
check(H.parse_sql_columns(%q{SELECT "Order ID","Sub-Category","SFDC Oppty ID" FROM T}) == ['Order ID', 'Sub-Category', 'SFDC Oppty ID'],
      'parses a flat quoted projection', fails)
check(H.parse_sql_columns('SELECT a, b AS "Foo Bar", SUM(c) AS total FROM t GROUP BY 1,2') == ['a', 'Foo Bar', 'total'],
      'handles AS aliases + expressions', fails)
check(H.parse_sql_columns('WITH m AS (SELECT x FROM y) SELECT "Region", SUM(z) AS s FROM m GROUP BY 1') == ['Region', 's'],
      'finds the FINAL top-level SELECT past a WITH CTE', fails)
check(H.parse_sql_columns('SELECT t."Col A", u.col_b FROM t JOIN u ON t.id=u.id') == ['Col A', 'col_b'],
      'strips table qualifiers', fails)
check(H.parse_sql_columns('SELECT * FROM t') == [], 'SELECT * → [] (caller falls back to a probe)', fails)
check(H.qualify_table('[STATE_FACT]', 'DB', 'SC') == '[DB].[SC].[STATE_FACT]', 'qualify 1-part table', fails)
check(H.qualify_table('[JOBLOSSES].[STATE_FACT]', 'DB', 'SC') == '[DB].[JOBLOSSES].[STATE_FACT]', 'qualify 2-part table (schema kept)', fails)
check(H.qualify_table('[DB].[SC].[T]', 'X', 'Y') == '[DB].[SC].[T]', 'leave 3-part table alone', fails)

puts 'Part G — hydrate_pds! descriptor-driven (REST chase, table + text)'
pds_twb = <<~XML
  <workbook><datasources>
    <datasource caption='CSQL'>
      <repository-location id='PDS_CSQL'/>
      <connection class='sqlproxy' dbname='PDS_CSQL' server='10ay'><relation name='sqlproxy' table='[sqlproxy]' type='table'/></connection>
    </datasource>
    <datasource caption='TableDS'>
      <repository-location id='PDS_TABLE'/>
      <connection class='sqlproxy' dbname='PDS_TABLE' server='10ay'><relation name='sqlproxy' table='[sqlproxy]' type='table'/></connection>
    </datasource>
  </datasources></workbook>
XML
pdoc = REXML::Document.new(pds_twb)
descs = [
  {'contentUrl'=>'PDS_CSQL','relationType'=>'text','sql'=>%q{SELECT "SFDC Oppty ID","Region" FROM RAW.MC},'db'=>'RAW','schema'=>'ING','columns'=>['SFDC Oppty ID','Region']},
  {'contentUrl'=>'PDS_TABLE','relationType'=>'table','table'=>'[JOBLOSSES].[STATE_FACT]','db'=>'RAW','schema'=>'ING','columns'=>[]},
]
ph = H.hydrate_pds!(pdoc, descriptors: descs, db: 'DEMO_DB', schema: 'DEMO')
check(ph.size == 2, 'both sqlproxy datasources hydrated via descriptors', fails)
csql_conn = pdoc.elements["/workbook/datasources/datasource[@caption='CSQL']/connection"]
csql_rel = nil; csql_conn.each_element('.//relation') { |r| csql_rel = r }
check(csql_rel.attributes['type'] == 'text', 'Custom SQL PDS → text relation', fails)
check(csql_rel.text.to_s.include?('"SFDC Oppty ID" AS SFDC_OPPTY_ID'), 'Custom SQL wrapped + aliased', fails)
tbl_conn = pdoc.elements["/workbook/datasources/datasource[@caption='TableDS']/connection"]
tbl_rel = nil; tbl_conn.each_element('.//relation') { |r| tbl_rel = r }
check(tbl_rel.attributes['type'] == 'table', 'table PDS → table relation (not text, no phantom)', fails)
check(tbl_rel.attributes['table'] == '[RAW].[JOBLOSSES].[STATE_FACT]', 'table relation qualified from PDS db', fails)
check(tbl_conn.attributes['class'] == 'snowflake' && tbl_conn.attributes['dbname'] == 'RAW', 'table PDS connection presented as warehouse', fails)
# Neither should still look like a sqlproxy placeholder.
check(!pdoc.to_s.include?('[sqlproxy]'), 'no [sqlproxy] placeholder remains after hydration', fails)

puts 'Part H — text splice preserves cached type/class, fills the full column set'
htwb = <<~XML
  <workbook><datasources>
    <datasource caption='PDS'>
      <repository-location id='PDS_X'/>
      <connection class='sqlproxy' dbname='PDS_X'>
        <relation name='sqlproxy' table='[sqlproxy]' type='table'/>
        <metadata-records>
          <metadata-record class='measure'><remote-name>Amount USD</remote-name><local-name>[Amount USD]</local-name><local-type>real</local-type><aggregation>Sum</aggregation><caption>Amount USD</caption></metadata-record>
        </metadata-records>
      </connection>
    </datasource>
  </datasources></workbook>
XML
hdoc = REXML::Document.new(htwb)
# workbook cached only 1 of 3 output columns; parsed SQL has all 3
H.hydrate_pds!(hdoc, descriptors: [{'contentUrl'=>'PDS_X','relationType'=>'text',
  'sql'=>%q{SELECT "Sales Region","Amount USD","SFDC Oppty ID" FROM T},'db'=>'RAW','schema'=>'ING',
  'columns'=>['Sales Region','Amount USD','SFDC Oppty ID']}], db: 'DEMO_DB', schema: 'DEMO')
hrecs = {}
hdoc.each_element("//metadata-record") { |m| hrecs[m.get_text('remote-name').value] = m }
check(hrecs.keys.sort == %w[AMOUNT_USD SALES_REGION SFDC_OPPTY_ID], 'full 3-column set emitted (not just the 1 cached)', fails)
check(hrecs['AMOUNT_USD'].attributes['class'] == 'column', 'class forced to "column" (converter drops non-column custom-SQL metadata-records)', fails)
check(hrecs['AMOUNT_USD'].get_text('local-type').value == 'real', 'cached local-type=real PRESERVED (not downgraded to string)', fails)
check(hrecs['SALES_REGION'].get_text('local-type').value == 'string' && hrecs['SALES_REGION'].attributes['class'] == 'column', 'uncached column defaults to string/column', fails)

puts 'Part I — warehouse-class case sensitivity (#454)'
check(H.canon_warehouse_class('snowflake') == 'snowflake', 'canon snowflake', fails)
check(H.canon_warehouse_class('Databricks') == 'databricks', 'canon Databricks (case/punct-insensitive)', fails)
check(H.canon_warehouse_class('spark') == 'databricks', 'canon spark→databricks family', fails)
check(H.canon_warehouse_class('') == 'snowflake', 'canon empty→snowflake default (back-compat)', fails)
check(!H.case_preserving_warehouse?('snowflake'), 'snowflake is NOT case-preserving (upper-folds)', fails)
check(H.case_preserving_warehouse?('databricks'), 'databricks IS case-preserving', fails)
check(!H.case_preserving_warehouse?('redshift'), 'unknown/other warehouse keeps upper default (no regression)', fails)
check(H.alias_for('Order Date', 'snowflake') == 'ORDER_DATE', 'alias_for uppercases for snowflake', fails)
check(H.alias_for('Order Date') == 'ORDER_DATE', 'alias_for defaults to snowflake (upper) when no class', fails)
check(H.alias_for('order_date', 'databricks') == 'order_date', 'alias_for preserves lowercase for databricks (#454)', fails)
check(H.alias_for('Region Name', 'databricks') == 'Region_Name', 'alias_for preserves case (snake punctuation) for databricks', fails)
check(H.quote_ref('order_date', 'databricks') == 'order_date', 'quote_ref leaves databricks-native lowercase bare', fails)
check(H.quote_ref('order_date', 'snowflake') == '"order_date"', 'quote_ref quotes non-upper for snowflake', fails)
dbx_wrap = H.wrap_sql('SELECT * FROM reporting.curated.foo', ['customer_id', 'Region Name'], 'databricks')
check(dbx_wrap.include?('customer_id AS customer_id'), 'databricks wrap: lowercase col stays bare + preserved (not uppercased)', fails)
check(dbx_wrap.include?('"Region Name" AS Region_Name'), 'databricks wrap: mixed-case preserved (quoted src, case-kept alias)', fails)
sf_wrap = H.wrap_sql('SELECT * FROM T', ['customer_id'], 'snowflake')
check(sf_wrap.include?('"customer_id" AS CUSTOMER_ID'), 'snowflake wrap still uppercases (unchanged behavior)', fails)

puts 'Part J — bare SELECT * expansion helper (#453)'
check(H.bare_select_star_table('SELECT * FROM analytics_db.reporting.foo') == 'analytics_db.reporting.foo', 'bare star → dotted table token', fails)
check(H.bare_select_star_table('select   *   from   [DB].[SC].[T]') == '[DB].[SC].[T]', 'bare star (bracketed, extra whitespace) → table', fails)
check(H.bare_select_star_table('SELECT * FROM foo AS f') == 'foo', 'bare star + AS alias → table', fails)
check(H.bare_select_star_table('SELECT * FROM foo f') == 'foo', 'bare star + bare alias → table', fails)
check(H.bare_select_star_table('SELECT DISTINCT * FROM foo') == 'foo', 'bare DISTINCT star → table', fails)
check(H.bare_select_star_table('SELECT * FROM foo;') == 'foo', 'trailing semicolon tolerated', fails)
check(H.bare_select_star_table('SELECT * FROM a JOIN b ON a.id=b.id').nil?, 'star with JOIN → nil (semantics differ)', fails)
check(H.bare_select_star_table('SELECT * FROM foo WHERE x=1').nil?, 'star with WHERE → nil (would drop the filter)', fails)
check(H.bare_select_star_table('SELECT * FROM (SELECT 1) t').nil?, 'star over a subquery → nil', fails)
check(H.bare_select_star_table('SELECT a, b FROM foo').nil?, 'explicit projection → nil (not a star)', fails)
check(H.bare_select_star_table('SELECT * FROM a, b').nil?, 'comma table list → nil', fails)

puts 'Part K — hydrate_pds! expands bare SELECT * (no abort) + case-preserving warehouse (#453/#454)'
star_twb = <<~XML
  <workbook><datasources>
    <datasource caption='Bare'>
      <repository-location id='PDS_BARE'/>
      <connection class='sqlproxy' dbname='PDS_BARE'><relation name='sqlproxy' table='[sqlproxy]' type='table'/></connection>
    </datasource>
    <datasource caption='Unresolvable'>
      <repository-location id='PDS_BAD'/>
      <connection class='sqlproxy' dbname='PDS_BAD'><relation name='sqlproxy' table='[sqlproxy]' type='table'/></connection>
    </datasource>
  </datasources></workbook>
XML
sdoc = REXML::Document.new(star_twb)
sdescs = [
  { 'contentUrl' => 'PDS_BARE', 'relationType' => 'text',
    'sql' => 'SELECT * FROM analytics_db.reporting.order_events',
    'db' => 'analytics_db', 'schema' => 'reporting', 'columns' => [], 'warehouseClass' => 'databricks' },
  { 'contentUrl' => 'PDS_BAD', 'relationType' => 'text',
    'sql' => 'SELECT * FROM a JOIN b ON a.id = b.id', 'db' => 'RAW', 'schema' => 'ING', 'columns' => [] }
]
sh = H.hydrate_pds!(sdoc, descriptors: sdescs, db: 'DB', schema: 'SC')
check(sh.size == 1, 'only the resolvable (bare SELECT*) PDS hydrated; the unresolvable one is dropped', fails)
check(sh.first['relationType'] == 'table', 'bare SELECT* resolved to a TABLE relation (no abort) (#453)', fails)
bare_conn = sdoc.elements["/workbook/datasources/datasource[@caption='Bare']/connection"]
bare_rel = nil; bare_conn.each_element('.//relation') { |r| bare_rel = r }
check(bare_rel.attributes['type'] == 'table', 'Bare PDS spliced as a table relation', fails)
check(bare_rel.attributes['table'] == '[analytics_db].[reporting].[order_events]', 'table qualified, lowercase PRESERVED (databricks, #454)', fails)
check(bare_conn.attributes['class'] == 'databricks', 'connection stamped with the databricks class (#454)', fails)
bad_conn = sdoc.elements["/workbook/datasources/datasource[@caption='Unresolvable']/connection"]
check(bad_conn.attributes['class'] == 'sqlproxy' && bad_conn.to_s.include?('[sqlproxy]'),
      'genuinely-unresolvable PDS left as sqlproxy placeholder → migrate hard-aborts loudly', fails)

# Databricks Custom SQL with explicit columns: aliases + metadata remote-names case-preserved.
ddoc = REXML::Document.new("<workbook><datasources><datasource caption='DBX'><repository-location id='PDS_DBX'/><connection class='sqlproxy' dbname='PDS_DBX'><relation name='sqlproxy' table='[sqlproxy]' type='table'/></connection></datasource></datasources></workbook>")
H.hydrate_pds!(ddoc, descriptors: [{ 'contentUrl' => 'PDS_DBX', 'relationType' => 'text',
  'sql' => 'SELECT customer_id, "Region Name" FROM analytics_db.reporting.t',
  'columns' => ['customer_id', 'Region Name'], 'warehouseClass' => 'databricks' }], db: 'DB', schema: 'SC')
dconn = ddoc.elements["/workbook/datasources/datasource[@caption='DBX']/connection"]
check(dconn.attributes['class'] == 'databricks', 'databricks custom-SQL PDS: connection class=databricks', fails)
drel = nil; dconn.each_element('.//relation') { |r| drel = r if r.attributes['type'] == 'text' }
check(drel.text.to_s.include?('customer_id AS customer_id'), 'databricks custom SQL: lowercase col preserved (not uppercased)', fails)
dremotes = []; dconn.each_element('.//metadata-records/metadata-record') { |m| dremotes << m.get_text('remote-name').value }
check(dremotes == %w[customer_id Region_Name], 'databricks custom SQL: metadata remote-names case-preserved', fails)

puts
if fails.empty?
  puts "ALL PASS (#{File.foreach(__FILE__).count { |l| l.include?('check(') } - 1} assertions)"
  exit 0
else
  puts "#{fails.size} FAILED:"
  fails.each { |m| puts "  - #{m}" }
  exit 1
end
