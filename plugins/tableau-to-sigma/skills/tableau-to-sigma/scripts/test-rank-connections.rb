#!/usr/bin/env ruby
# Offline unit test for rank-connections.rb (pure scoring + .twb fingerprint).
require_relative 'rank-connections'

$fail = 0
def check(desc)
  ok = yield
  puts "#{ok ? '  ok  ' : ' FAIL '} #{desc}"
  $fail += 1 unless ok
end

# Realistic org: 26-connection estate reduced here to the relevant mix (multiple Snowflakes).
CANDS = [
  { 'connection_id' => 'c-prod', 'name' => 'Snowflake Prod', 'type' => 'snowflake', 'host' => 'prodco.us-east-1.snowflakecomputing.com', 'account' => 'prodco' },
  { 'connection_id' => 'c-ask',  'name' => 'Staging - Snowflake', 'type' => 'snowflake', 'host' => 'stagingco.snowflakecomputing.com', 'account' => 'stagingco' },
  { 'connection_id' => 'c-bq',   'name' => 'BigQuery- Sandbox', 'type' => 'bigQuery', 'host' => nil, 'account' => nil },
  { 'connection_id' => 'c-dbx',  'name' => 'Databricks data-science-dev', 'type' => 'databricks', 'host' => 'adb-123.azuredatabricks.net' },
  { 'connection_id' => 'c-rs',   'name' => 'Redshift Analytics', 'type' => 'redshift', 'host' => 'rs.abc.us-east-1.redshift.amazonaws.com' },
]

# 1) Confident auto-pick: type + host token both point at Snowflake Prod.
fp1 = { 'type' => 'snowflake', 'host' => 'prodco.us-east-1.snowflakecomputing.com', 'database' => 'PROD_DB' }
r1 = RankConnections.rank(fp1, CANDS)
check('recommends Snowflake Prod on type+host match') { r1['confident'] && r1['recommended']['connection_id'] == 'c-prod' }
check('Snowflake Prod outscores the other Snowflake') { r1['ranked'][0]['match_score'] > r1['ranked'][1]['match_score'] }
check('wrong-warehouse connections score 0') { r1['ranked'].select { |c| %w[c-bq c-dbx c-rs].include?(c['connection_id']) }.all? { |c| c['match_score'].zero? } }

# 2) Ambiguous: two Snowflakes, neither host matches the source → not confident.
fp2 = { 'type' => 'snowflake', 'host' => 'unknownco.snowflakecomputing.com' }
r2 = RankConnections.rank(fp2, CANDS)
check('two same-type, no host match → NOT confident (still asks)') { !r2['confident'] && r2['type_match_count'] == 2 }

# 3) Type normalization across Tableau/Sigma spellings.
check('bigquery <-> bigQuery normalize equal') { RankConnections.canon_type('bigquery') == RankConnections.canon_type('bigQuery') }
check('sqlserver <-> mssql normalize equal')    { RankConnections.canon_type('sqlserver') == RankConnections.canon_type('mssql') }
check('databricks <-> sparksql normalize equal'){ RankConnections.canon_type('databricks') == RankConnections.canon_type('sparksql') }

# 4) .twb fingerprint: picks the real warehouse connection, skips extract/federated/categorical.
TWB = <<~XML
  <workbook>
   <datasources>
    <datasource caption='Demo'>
     <connection class='federated'>
      <named-connections>
       <named-connection caption='SF'><connection class='snowflake' server='prodco.us-east-1.snowflakecomputing.com' dbname='PROD_DB' schema='DBO'/></named-connection>
      </named-connections>
      <relation type='text'>SELECT 1</relation>
     </connection>
    </datasource>
    <datasource><connection class='categorical'/></datasource>
   </datasources>
  </workbook>
XML
fp_twb = RankConnections.fingerprint_from_twb(TWB)
check('.twb fingerprint type = snowflake') { RankConnections.canon_type(fp_twb['type']) == 'snowflake' }
check('.twb fingerprint host = prodco host') { fp_twb['host'] == 'prodco.us-east-1.snowflakecomputing.com' }
check('.twb fingerprint database = PROD_DB') { fp_twb['database'] == 'PROD_DB' }

# 5) A .twb fingerprint feeds ranking to the same confident pick.
r5 = RankConnections.rank(RankConnections.merge_fp(fp_twb, {}), CANDS)
check('.twb-derived fingerprint recommends Snowflake Prod') { r5['confident'] && r5['recommended']['connection_id'] == 'c-prod' }

# 6) PDS / Virtual-Connection resolution (bead tt3z #388 follow-up). A duck-typed
#    REST stub mirrors the live shapes so fingerprint_from_workbook is tested offline.
class FakeRest
  def initialize(h) ; @h = h ; end
  def workbook_connections(_id) ; @h[:wb] || [] ; end
  def datasource_connections(id) ; (@h[:ds] || {})[id] || [] ; end
  def virtual_connections ; @h[:vcs] || [] ; end
  def virtual_connection_connections(id) ; (@h[:vcc] || {})[id] || [] ; end
end
DS_NAME = 'ORDER_FACT (DEMO_DB.ORDER_FACT)+ (New Virtual Connection)'

# (6a) garbage-fp regression: a publishedConnection stub yields EMPTY (not {type:'publishedConnection'}).
check('publishedConnection stub → empty direct fingerprint (was the score-0 bug)') do
  RankConnections.fingerprint_from_wb_connections([{ 'type' => 'publishedConnection', 'serverAddress' => '' }]) == {}
end

# (6b) VC-backed workbook resolves through the virtual connection to the real warehouse.
vc_rest = FakeRest.new(
  wb:  [{ 'type' => 'publishedConnection', 'serverAddress' => '', 'datasource' => { 'id' => 'ds1', 'name' => DS_NAME } }],
  ds:  { 'ds1' => [{ 'type' => 'publishedConnection', 'serverAddress' => '' }] },        # dead-ends (VC-backed)
  vcs: [{ 'id' => 'vc1', 'name' => 'New Virtual Connection' }],
  vcc: { 'vc1' => [{ 'dbClass' => 'snowflake', 'server' => 'https://gxb98765.snowflakecomputing.com/console/login#/' }] })
vc_fp = RankConnections.fingerprint_from_workbook(vc_rest, 'wb1')
check('VC-backed → type snowflake') { RankConnections.canon_type(vc_fp['type']) == 'snowflake' }
check('VC-backed → host cleaned (no scheme/path/port)') { vc_fp['host'] == 'gxb98765.snowflakecomputing.com' }

# (6c) classic published DS resolves at the datasource hop; VC endpoints never consulted.
pds_rest = FakeRest.new(
  wb: [{ 'type' => 'publishedConnection', 'serverAddress' => '', 'datasource' => { 'id' => 'ds1', 'name' => 'X' } }],
  ds: { 'ds1' => [{ 'type' => 'snowflake', 'serverAddress' => 'acme.snowflakecomputing.com' }] })
pds_fp = RankConnections.fingerprint_from_workbook(pds_rest, 'wb1')
check('classic PDS → resolves at datasource hop (host=acme)') { pds_fp['host'] == 'acme.snowflakecomputing.com' && RankConnections.canon_type(pds_fp['type']) == 'snowflake' }

# (6d) ambiguity guard: 2 VCs, neither uniquely named in ds_name → EMPTY (never guess).
amb_rest = FakeRest.new(
  wb:  [{ 'type' => 'publishedConnection', 'serverAddress' => '', 'datasource' => { 'id' => 'ds1', 'name' => 'unmatched' } }],
  ds:  { 'ds1' => [{ 'type' => 'publishedConnection', 'serverAddress' => '' }] },
  vcs: [{ 'id' => 'a', 'name' => 'VC A' }, { 'id' => 'b', 'name' => 'VC B' }])
check('ambiguous VC (no unique name match) → empty (falls back to asking the user, never guesses)') do
  RankConnections.fingerprint_from_workbook(amb_rest, 'wb1') == {}
end

# (6e) direct-warehouse workbook ("Test Custom Sql" analog): direct fp, resolution NOT invoked.
direct_rest = FakeRest.new(wb: [{ 'type' => 'snowflake', 'serverAddress' => 'prodco.us-east-1.snowflakecomputing.com' }])
direct_fp = RankConnections.fingerprint_from_workbook(direct_rest, 'wb1')
check('direct-warehouse workbook fingerprints straight from serverAddress') do
  RankConnections.canon_type(direct_fp['type']) == 'snowflake' && direct_fp['host'] == 'prodco.us-east-1.snowflakecomputing.com'
end

# (6f) VC fingerprint then RANKS the DEMO_DB.DEMO (gxb98765) candidates to the top.
CANDS2 = CANDS + [{ 'connection_id' => 'c-ymb', 'name' => 'gxb98765', 'type' => 'snowflake', 'host' => 'gxb98765.snowflakecomputing.com', 'account' => 'gxb98765' }]
r6 = RankConnections.rank(RankConnections.merge_fp(vc_fp, {}), CANDS2)
check('VC fingerprint ranks the gxb98765 (DEMO_DB.DEMO) connection #1 (score>100, was 0)') do
  r6['ranked'].first['connection_id'] == 'c-ymb' && r6['ranked'].first['match_score'] > 100
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
