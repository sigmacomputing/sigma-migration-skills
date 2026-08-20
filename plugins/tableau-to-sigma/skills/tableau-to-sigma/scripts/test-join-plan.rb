#!/usr/bin/env ruby
# frozen_string_literal: true
# test-join-plan.rb — unit test for scripts/lib/join_plan.rb (the join-plan
# ledger derivation, PR-4). Offline + deterministic: the federated-join side
# reuses the synthetic .twb fixtures test-join-coalesce-synthesis.rb ships
# (invented names, no customer data); the Lookup-synthesis side uses an inline
# synthetic dm-spec shaped like the converter's output.
#
# Covers: federated join detected (single- and multi-key); published-VC label
# ('NAME (X.TABLE)') + GUID-key resolution to a probeable right_table/probe_keys
# (and the safe fallback when no db/schema is available); the EMBEDDED-
# datasource shapes from the 2026-07-19 live miss (flag-key LEFT JOIN as
# <clause type='join'> expression ops in an inline datasource; the same tree
# behind _.fcp forward-compatibility mangling; the 2020.2+ object-graph
# relationship model; a function-wrapped computed-key side); the workdir_twb
# route-independent .twb read (the FAST PATH derived from a nil .twb and gate
# 16 passed on an empty ledger); Lookup synthesis detected + deduped across
# columns; Custom-SQL Lookup target recording right_sql; composite-key unwrap
# to physical probe keys; right_table FQN derivation; the empty case still
# writes a ledger.
#
# Run: ruby scripts/test-join-plan.rb
require 'json'
require 'tmpdir'
require_relative 'lib/join_plan'

FIX1 = File.join(__dir__, 'test-fixtures', 'join-coalesce.twb')
FIX2 = File.join(__dir__, 'test-fixtures', 'join-coalesce-multikey.twb')
FIX3 = File.join(__dir__, 'test-fixtures', 'join-vc.twb')
FIX4 = File.join(__dir__, 'test-fixtures', 'join-embedded-flagkey.twb')
FIX5 = File.join(__dir__, 'test-fixtures', 'join-object-graph.twb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== federated join (single-key .twb) =='
entries = JoinPlan.derive(nil, File.read(FIX1))
check(entries.size == 1, "one federated-join entry (got #{entries.size})", fails)
e = entries.first || {}
check(e['kind'] == 'federated-join', 'kind is federated-join', fails)
check(e['left'] == 'REV_PRIMARY' && e['right'] == 'REV_CONTRA', "left/right tables (got #{e['left']}/#{e['right']})", fails)
check(e['keys'] == ['ENTITY_ID'], "right key columns (got #{e['keys'].inspect})", fails)
check(e['join_type'] == 'left', 'join type carried (left)', fails)
check(e['grain_assumption'] == 'right unique on keys', 'grain assumption stamped', fails)
check(e['status'] == 'unprobed', 'status starts unprobed', fails)
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_CONTRA', "right_table FQN from dbname + table attr (got #{e['right_table'].inspect})", fails)

puts "\n== federated join (AND-wrapped 2-key .twb) =="
entries = JoinPlan.derive(nil, File.read(FIX2))
check(entries.size == 1, 'one entry for the multi-key join', fails)
e = entries.first || {}
check(e['keys'] == %w[ENTITY_ID ACTIVITY_DATE], "BOTH key columns captured (got #{e['keys'].inspect})", fails)
check(e['key_pairs'] == [{ 'left' => 'ENTITY_ID', 'right' => 'ENTITY_ID' },
                         { 'left' => 'ACTIVITY_DATE', 'right' => 'ACTIVITY_DATE' }],
      'key pairs carry both sides', fails)

puts "\n== published/virtual-connection .twb: VC labels + GUID keys resolve to probeable targets =="
vc_xml = File.read(FIX3)
entries = JoinPlan.derive(nil, vc_xml, db: 'ANALYTICS', schema: 'PUBLIC')
check(entries.size == 1, "one federated-join entry from the VC .twb (got #{entries.size})", fails)
e = entries.first || {}
check(e['right'] == 'REV_OFFSET (LEDGERSRC.REV_OFFSET)', "right keeps the VC relation label (got #{e['right'].inspect})", fails)
check(e['right_table'] == 'ANALYTICS.LEDGERSRC.REV_OFFSET',
      "right_table: 'NAME (X.TABLE)' paren path + run db → db.X.TABLE (got #{e['right_table'].inspect})", fails)
check(e['keys'] == ['9f8e7d6c-5b4a-4392-8171-605f4e3d2c1b'], 'keys keep the raw GUID for provenance', fails)
check(e['probe_keys'] == ['ENTITY_ID'],
      "probe_keys: GUID key resolved via caption + upcase/underscore folding (got #{e['probe_keys'].inspect})", fails)

# 'DB.TABLE' variant: paren path's first part IS the run database → db.schema.TABLE.
entries = JoinPlan.derive(nil, vc_xml.gsub('LEDGERSRC', 'ANALYTICS'), db: 'ANALYTICS', schema: 'PUBLIC')
e = entries.first || {}
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_OFFSET',
      "right_table: 'NAME (DB.TABLE)' + run schema → DB.schema.TABLE (got #{e['right_table'].inspect})", fails)

# 'DB.SCHEMA.TABLE' variant needs no opts at all.
entries = JoinPlan.derive(nil, vc_xml.gsub('(LEDGERSRC.REV_OFFSET)', '(ANADB.LEDGERSRC.REV_OFFSET)'))
e = entries.first || {}
check(e['right_table'] == 'ANADB.LEDGERSRC.REV_OFFSET',
      "right_table: 3-part paren path used as-is (got #{e['right_table'].inspect})", fails)

# No db/schema and a 2-part label → old (safe) behavior: the unprobeable VC
# inode FQN stays, the probe errors, and the gate keeps blocking.
entries = JoinPlan.derive(nil, vc_xml)
e = entries.first || {}
check(e['right_table'].to_s.start_with?('ab12cd34-'),
      "no resolution possible → VC inode FQN kept (safe: probe errors, gate blocks) (got #{e['right_table'].inspect})", fails)

# Non-VC .twbs are untouched by the new args.
entries = JoinPlan.derive(nil, File.read(FIX1), db: 'OTHERDB', schema: 'OTHERSCHEMA')
e = entries.first || {}
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_CONTRA',
      "plain federated .twb ignores db/schema opts (got #{e['right_table'].inspect})", fails)
check(e['probe_keys'] == ['ENTITY_ID'], 'plain federated probe keys unchanged', fails)

puts "\n== EMBEDDED datasource: flag-key LEFT JOIN as <clause type='join'> expression ops =="
# The 2026-07-19 live miss: an inline (embedded) datasource over a published
# connection whose LEFT JOIN never landed in join-plan.json — gate 16 passed
# on an empty ledger and every tile diverged 3-23x (fan-out trap). The ledger
# must carry this entry, probeable via the caption-fold helpers.
emb_xml = File.read(FIX4, encoding: 'UTF-8')
entries = JoinPlan.derive(nil, emb_xml, db: 'ANALYTICS', schema: 'PUBLIC')
check(entries.size == 1, "one federated-join entry from the embedded .twb (got #{entries.size})", fails)
e = entries.first || {}
check(e['kind'] == 'federated-join' && e['join_type'] == 'left', 'flag-key LEFT JOIN recorded (kind + join_type)', fails)
check(e['left'] == 'ACT_BASE (OPSSRC.ACT_BASE)' && e['right'] == 'STATE_REF (OPSSRC.STATE_REF)',
      "left/right keep the embedded relation labels (got #{e['left'].inspect}/#{e['right'].inspect})", fails)
check(e['keys'] == ['cccc1111-2222-4333-8444-555566667777'], 'keys keep the raw flag GUID for provenance', fails)
check(e['right_table'] == 'ANALYTICS.OPSSRC.STATE_REF',
      "right_table: paren label + run db → probeable FQN (got #{e['right_table'].inspect})", fails)
check(e['probe_keys'] == ['IS_CURRENT'],
      "probe_keys: flag GUID resolved via caption + upcase/underscore folding (got #{e['probe_keys'].inspect})", fails)
Dir.mktmpdir do |dir|
  path = JoinPlan.write(File.join(dir, 'join-plan.json'), entries)
  doc = JSON.parse(File.read(path))
  check(doc['entries'].size == 1 && doc['entries'].first['status'] == 'unprobed',
        'the ledger gate 16 inspects now CARRIES the embedded join (unprobed → gate blocks until proven)', fails)
end

puts "\n== the same embedded join behind _.fcp forward-compatibility mangling =="
fcp_xml = emb_xml.gsub('<relation ', '<_.fcp.ObjectModelEncapsulateLegacy.true...relation ')
                 .gsub('</relation>', '</_.fcp.ObjectModelEncapsulateLegacy.true...relation>')
entries = JoinPlan.derive(nil, fcp_xml, db: 'ANALYTICS', schema: 'PUBLIC')
e = entries.first || {}
check(entries.size == 1, "fcp-wrapped relation tree still yields the entry (got #{entries.size})", fails)
check(e['right_table'] == 'ANALYTICS.OPSSRC.STATE_REF' && e['probe_keys'] == ['IS_CURRENT'],
      'fcp-normalized entry identical to the plain one (right_table + probe_keys)', fails)

puts "\n== 2020.2+ object-graph relationship model (fcp-wrapped, embedded) =="
entries = JoinPlan.derive(nil, File.read(FIX5, encoding: 'UTF-8'))
check(entries.size == 1, "one entry from the object-graph relationship (got #{entries.size})", fails)
e = entries.first || {}
check(e['kind'] == 'federated-join' && e['join_type'] == 'relationship' && e['shape'] == 'object-graph',
      'relationship join recorded with object-graph provenance', fails)
check(e['left'] == 'ACT_BASE' && e['right'] == 'STATE_REF', "end-point objects resolved to their tables (got #{e['left']}/#{e['right']})", fails)
check(e['keys'] == ['ENTITY_ID'] && e['probe_keys'] == ['ENTITY_ID'],
      "bare column refs recorded + folded to physical (got #{e['keys'].inspect}/#{e['probe_keys'].inspect})", fails)
check(e['right_table'] == 'ANALYTICS.PUBLIC.STATE_REF',
      "right_table from the object's table relation + named-connection dbname (got #{e['right_table'].inspect})", fails)
check(e['status'] == 'unprobed' && e['grain_assumption'] == 'right unique on keys',
      'relationship joins carry the same grain assumption (Tableau culls per-viz; Sigma fans out)', fails)

puts "\n== object-graph duplicate-table role resolves its suffixed GUID + physical VC table =="
role_guid = '737611ae-3a14-349a-8fa8-d92dd0bb0432'
role_name = 'DATE_DIM (DEMO_SCHEMA.DATE_DIM)1'
role_xml = <<~XML
  <workbook>
    <datasource>
      <column caption='Date Key' datatype='integer'
              name='[#{role_guid} (#{role_name})]' />
      <object-graph>
        <objects>
          <object id='fact'>
            <properties>
              <relation name='EVENT_FACT (DEMO_SCHEMA.EVENT_FACT)'
                        table='[fact-inode].[EVENT_FACT (DEMO_SCHEMA.EVENT_FACT)]'
                        type='table' />
            </properties>
          </object>
          <object id='date-role'>
            <properties>
              <relation name='#{role_name}'
                        table='[date-inode].[DATE_DIM (DEMO_SCHEMA.DATE_DIM)]'
                        type='table' />
            </properties>
          </object>
        </objects>
        <relationships>
          <relationship>
            <expression op='='>
              <expression op='[fact-date-key]' />
              <expression op='[#{role_guid} (#{role_name})]' />
            </expression>
            <first-end-point object-id='fact' />
            <second-end-point object-id='date-role' />
          </relationship>
        </relationships>
      </object-graph>
    </datasource>
  </workbook>
XML
entries = JoinPlan.derive(nil, role_xml, db: 'DEMO_DB', schema: 'DEMO_SCHEMA')
check(entries.size == 1, "duplicate-table role yields one relationship entry (got #{entries.size})", fails)
e = entries.first || {}
check(e['right'] == role_name, 'ledger preserves the Tableau role name for provenance', fails)
check(e['keys'] == ["#{role_guid} (#{role_name})"],
      'ledger preserves the role-suffixed GUID key for provenance', fails)
check(e['probe_keys'] == ['DATE_KEY'],
      "role-suffixed GUID resolves through its exact caption (got #{e['probe_keys'].inspect})", fails)
check(e['right_table'] == 'DEMO_DB.DEMO_SCHEMA.DATE_DIM',
      "numeric Tableau role suffix does not corrupt the physical VC FQN (got #{e['right_table'].inspect})", fails)

puts "\n== function-wrapped (computed-key) join side still records the join =="
fn_xml = File.read(FIX1).sub("op='[REV_PRIMARY].[ENTITY_ID]'", "op='DATE([REV_PRIMARY].[ENTITY_ID])'")
entries = JoinPlan.derive(nil, fn_xml)
e = entries.first || {}
check(entries.size == 1, "computed-key side does not drop the join (got #{entries.size})", fails)
check(e['key_pairs'] == [{ 'left' => 'ENTITY_ID', 'right' => 'ENTITY_ID' }],
      "wrapped side unwrapped to its physical column (got #{e['key_pairs'].inspect})", fails)

puts "\n== workdir_twb: route-independent .twb read (the FAST PATH nil-twb hole) =="
Dir.mktmpdir do |dir|
  check(JoinPlan.workdir_twb(dir).nil?, 'no .twb in the workdir → nil (MCP-only datasource)', fails)
  File.write(File.join(dir, 'workbook-hydrated.twb'), emb_xml)
  check(!JoinPlan.workdir_twb(dir).nil?, 'workbook-hydrated.twb is the fallback', fails)
  File.write(File.join(dir, 'workbook-content.twb'), emb_xml)
  check(JoinPlan.workdir_twb(dir) == emb_xml, 'workbook-content.twb preferred when both exist', fails)
  entries = JoinPlan.derive(nil, JoinPlan.workdir_twb(dir), db: 'ANALYTICS', schema: 'PUBLIC')
  check(entries.size == 1, 'a derive fed from workdir_twb carries the embedded join (FAST PATH regression)', fails)
end
check(JoinPlan.workdir_twb(nil).nil?, 'nil workdir → nil (no raise)', fails)

puts "\n== Lookup synthesis in the dm-spec =="
dm = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Rev Primary',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_PRIMARY] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Unified Region',
          'formula' => 'Coalesce([Region], Lookup([Rev Contra/Region], [Entity Id], [Rev Contra/Entity Id]))' },
        { 'id' => 'c2', 'name' => 'Contra Amount Zn',
          'formula' => 'Coalesce(Lookup([Rev Contra/Contra Amt], [Entity Id], [Rev Contra/Entity Id]), 0)' },
        { 'id' => 'c3', 'name' => 'Plain Local', 'formula' => 'Coalesce([Channel], [Backup Channel])' }
      ] },
    { 'id' => 'el-tgt', 'name' => 'Rev Contra',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_CONTRA] },
      'columns' => [
        { 'id' => 't1', 'name' => 'Entity Id', 'formula' => '[REV_CONTRA/Entity Id]' },
        { 'id' => 't2', 'name' => 'Region', 'formula' => '[REV_CONTRA/Region]' }
      ] }
  ] }]
}
entries = JoinPlan.derive(dm, nil)
check(entries.size == 1, "two Lookups over the same target+key dedupe into ONE entry (got #{entries.size})", fails)
e = entries.first || {}
check(e['kind'] == 'lookup-synthesis', 'kind is lookup-synthesis', fails)
check(e['left'] == 'Rev Primary' && e['right'] == 'Rev Contra', "source/target elements (got #{e['left']}/#{e['right']})", fails)
check(e['keys'] == ['Entity Id'], "target key recorded (got #{e['keys'].inspect})", fails)
check(e['columns'] == ['Unified Region', 'Contra Amount Zn'], "dependent columns aggregated (got #{e['columns'].inspect})", fails)
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_CONTRA', "right_table from the target element source.path (got #{e['right_table'].inspect})", fails)
check(e['probe_keys'] == ['ENTITY_ID'], "probe key upcased to the physical column (got #{e['probe_keys'].inspect})", fails)
check(e['status'] == 'unprobed' && e['grain_assumption'] == 'right unique on keys', 'unprobed + grain assumption', fails)

puts "\n== composite-key Lookup unwraps to the base physical columns =="
dm2 = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Daily Primary',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC DAILY_PRIMARY] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Merged Segment',
          'formula' => 'Coalesce([Segment], Lookup([Daily Contra/Segment], [Daily Contra Join Key], [Daily Contra/Daily Contra Join Key]))' }
      ] },
    { 'id' => 'el-tgt', 'name' => 'Daily Contra',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC DAILY_CONTRA] },
      'columns' => [
        { 'id' => 't1', 'name' => 'Daily Contra Join Key',
          'formula' => 'Text([Entity Id]) & "|" & Text([Activity Date])' }
      ] }
  ] }]
}
entries = JoinPlan.derive(dm2, nil)
e = entries.first || {}
check(entries.size == 1, 'composite-key Lookup produces one entry', fails)
check(e['keys'] == ['Daily Contra Join Key'], 'ledger key names the synthesized composite column', fails)
check(e['probe_keys'] == %w[ENTITY_ID ACTIVITY_DATE],
      "probe keys unwrap the composite calc to the physical base columns (got #{e['probe_keys'].inspect})", fails)

puts "\n== Custom-SQL Lookup target records right_sql (right_table stays null) =="
sql_stmt = 'SELECT ENTITY_ID, REGION FROM ANALYTICS.PUBLIC.REV_OFFSET WHERE REGION IS NOT NULL'
dm3 = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Rev Primary',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_PRIMARY] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Unified Region',
          'formula' => 'Coalesce([Region], Lookup([Offset Sql/Region], [Entity Id], [Offset Sql/Entity Id]))' }
      ] },
    { 'id' => 'el-sql', 'name' => 'Offset Sql',
      'source' => { 'kind' => 'sql', 'connectionId' => 'conn-1', 'statement' => sql_stmt },
      'columns' => [
        { 'id' => 't1', 'name' => 'Entity Id', 'formula' => '[Custom SQL/ENTITY_ID]' },
        { 'id' => 't2', 'name' => 'Region', 'formula' => '[Custom SQL/REGION]' }
      ] }
  ] }]
}
entries = JoinPlan.derive(dm3, nil)
check(entries.size == 1, "one lookup-synthesis entry for the sql target (got #{entries.size})", fails)
e = entries.first || {}
check(e['right_table'].nil?, "right_table stays null for a sql-kind target (got #{e['right_table'].inspect})", fails)
check(e['right_sql'] == sql_stmt, "right_sql carries the element's statement (got #{e['right_sql'].inspect})", fails)
check(e['probe_keys'] == ['ENTITY_ID'], 'probe keys still folded to physical', fails)

puts "\n== W2.9: role-disambiguation parentheticals stripped from probe_keys, display keys verbatim =="
# The garbled-join class: Tableau suffixes same-named fields across joined objects
# with the object name in parens ('Product Key (Product Dim)'); folding that
# display label emitted PRODUCT_KEY_(PRODUCT_DIM)-shaped SQL → HTTP 400 at
# every gate-16 probe. Derivation now strips ONE balanced trailing
# parenthetical BEFORE the display->physical fold — probe_keys only; the
# ledger's display side (`keys`) stays verbatim.
check(JoinPlan.strip_role_paren('Product Key (Product Dim)') == 'Product Key',
      'strip: single trailing parenthetical', fails)
check(JoinPlan.strip_role_paren('Product Key (Product Dim (Extract))') == 'Product Key',
      'strip: nested parenthetical stripped as ONE balanced group', fails)
check(JoinPlan.strip_role_paren('Entity Id') == 'Entity Id', 'no parens → unchanged (no-false-trip)', fails)
check(JoinPlan.strip_role_paren('ENTITY_ID') == 'ENTITY_ID', 'physical name → unchanged (no-false-trip)', fails)
check(JoinPlan.strip_role_paren('(Extract)') == '(Extract)',
      'whole-label parenthetical → unchanged (emission refuses it; never guessed empty)', fails)
check(JoinPlan.strip_role_paren('Broken Key)') == 'Broken Key)',
      'unbalanced → unchanged (emission refuses; refuse-don\'t-guess)', fails)
check(JoinPlan.relationship_probe_key('Product Key (Product Dim)', {}) == 'PRODUCT_KEY',
      'relationship key: stripped then folded to physical', fails)
check(JoinPlan.relationship_probe_key('Entity Id', {}) == 'ENTITY_ID',
      'relationship key without parens folds exactly as before', fails)
guid = 'ab12cd34-0000-1111-2222-333344445555'
check(JoinPlan.physical_probe_key(guid.upcase, { guid => 'Product Key (Product Dim (Extract))' }) == 'PRODUCT_KEY',
      'GUID key: caption resolved, parenthetical stripped, folded', fails)
check(JoinPlan.physical_probe_key(guid.upcase, {}) == guid.upcase,
      'unresolvable GUID stays as-is (emission refuses it downstream; gate keeps blocking)', fails)

dm_paren = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Sales Fact',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC SALES_FACT] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Unified Product',
          'formula' => 'Coalesce([Product], Lookup([Product Dim/Product], [Product Key], [Product Dim/Product Key (Product Dim)]))' }
      ] },
    { 'id' => 'el-dim', 'name' => 'Product Dim',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC PRODUCT_DIM] },
      'columns' => [
        { 'id' => 't1', 'name' => 'Product Key (Product Dim)', 'formula' => '[PRODUCT_DIM/Product Key]' }
      ] }
  ] }]
}
entries = JoinPlan.derive(dm_paren, nil)
check(entries.size == 1, 'role-disambiguated Lookup still derives one entry', fails)
e = entries.first || {}
check(e['keys'] == ['Product Key (Product Dim)'],
      "display key keeps the parenthetical verbatim (got #{e['keys'].inspect})", fails)
check(e['probe_keys'] == ['PRODUCT_KEY'],
      "probe key stripped + folded to the physical column (got #{e['probe_keys'].inspect})", fails)

puts "\n== combined .twb + dm-spec derivation =="
entries = JoinPlan.derive(dm, File.read(FIX1))
check(entries.size == 2, "federated join + lookup synthesis both recorded (got #{entries.size})", fails)
check(entries.map { |x| x['kind'] } == %w[federated-join lookup-synthesis], 'deterministic order: joins then lookups', fails)

puts "\n== empty case still writes the ledger (its presence is the gate's evidence) =="
empty_dm = { 'pages' => [{ 'elements' => [
  { 'id' => 'el', 'name' => 'Solo', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB S T] },
    'columns' => [{ 'id' => 'c', 'name' => 'X', 'formula' => '[T/X]' }] }
] }] }
entries = JoinPlan.derive(empty_dm, nil)
check(entries == [], 'no joins / no Lookups → empty entry list', fails)
Dir.mktmpdir do |dir|
  path = File.join(dir, 'join-plan.json')
  JoinPlan.write(path, entries)
  doc = JSON.parse(File.read(path))
  check(doc['entries'] == [], 'empty ledger file written with entries: []', fails)
  check(doc['grain_note'].to_s.include?('arbitrary match'), 'ledger carries the Lookup grain note', fails)
end

puts
if fails.empty?
  puts 'test-join-plan: ALL PASS'
else
  puts "test-join-plan: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
