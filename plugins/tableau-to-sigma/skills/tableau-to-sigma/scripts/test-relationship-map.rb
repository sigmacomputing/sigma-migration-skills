#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Contract test for lib/relationship_map.rb — the reused-DM relationship
# evidence route. Creds-free: every case reads the committed fixtures under
# scripts/test-fixtures/relationship-map/<case>/ (see generate.rb there).

require 'json'
require_relative 'lib/relationship_map'

FIXTURES = File.expand_path('test-fixtures/relationship-map', __dir__)

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

load_case = lambda do |name|
  dir = File.join(FIXTURES, name)
  {
    twb_xml: File.read(File.join(dir, 'workbook-content.twb'), encoding: 'bom|utf-8'),
    dm_spec: JSON.parse(File.read(File.join(dir, 'dm-spec-reused.json'))),
    dashboards: RelationshipMap.scoped_dashboards(JSON.parse(File.read(File.join(dir, 'dashboard-scope.json')))),
    resolution: File.file?(File.join(dir, 'resolution.json')) ? JSON.parse(File.read(File.join(dir, 'resolution.json'))) : nil
  }
end
derive = ->(name) { RelationshipMap.derive(**load_case.(name)) }
tableau = ->(map) { map['entries'].select { |e| e['kind'] == 'tableau' } }
entry = ->(map, left, right) { map['entries'].find { |e| [e['left'], e['right']].sort == [left, right].sort } }
fqn = ->(t) { "ANALYTICS.PUBLIC.#{t}" }

puts 'test-relationship-map — derive'

m = derive.('matched-star')
check.(m['schema_version'] == 1 && m['route'] == 'reused-dm-evidence',
       'map carries schema_version 1 and the reused-dm-evidence route')
check.(tableau.(m).size == 2 && tableau.(m).all? { |e| e['disposition'] == 'matched' && e['requires'] == [] },
       "matched-star: both Tableau relationships matched with nothing required (got #{tableau.(m).map { |e| e['disposition'] }})")
check.(m['blockers'] == [] && m['entries'].none? { |e| e['kind'] == 'extra' },
       'matched-star: no map blockers and no extra DM edges')
check.(m['tables'].map { |t| t['table'] }.sort == [fqn.('DIM_CUSTOMER'), fqn.('DIM_PRODUCT'), fqn.('ORDERS')],
       "matched-star: tables are fully-qualified (got #{m['tables'].map { |t| t['table'] }})")
check.(m['inputs']['twb_sha256'].to_s.length == 64 && m['inputs']['dm_sha256'].to_s.length == 64,
       'map records input hashes')

m = derive.('replaced-key')
e = entry.(m, fqn.('ORDERS'), fqn.('DIM_CUSTOMER'))
check.(e && e['disposition'] == 'replaced' && e['requires'] == %w[key_probe parity] && e['dm_path'].size == 1,
       "replaced-key: different key → replaced, needs key_probe + parity, one-edge path (got #{e&.slice('disposition', 'requires', 'dm_path')})")
check.(e && e['affected_worksheets'] == ['Revenue by Customer'],
       "replaced-key: affected worksheets are the migrated ones using the path's tables (got #{e&.dig('affected_worksheets')})")
check.(entry.(m, fqn.('ORDERS'), fqn.('DIM_PRODUCT'))['disposition'] == 'matched',
       'replaced-key: the untouched relationship stays matched')
check.(m['dm_edges'].size == 2 && m['dm_edges'].all? { |d| d['probe'].nil? && d['edge_sha'].to_s.length == 64 },
       'replaced-key: every DM edge listed once, unprobed, with an edge_sha')

m = derive.('dropped-unused')
e = entry.(m, fqn.('ORDERS'), fqn.('DIM_PRODUCT'))
check.(e && e['disposition'] == 'dropped' && e['requires'] == %w[field_use not_a_bridge] && e.dig('field_use', 'status') == 'pass',
       "dropped-unused: table absent from DM and unused → dropped, field use passes (got #{e&.slice('disposition', 'field_use')})")
check.(m['tables'].find { |t| t['table'] == fqn.('DIM_PRODUCT') }['dm_element_ids'] == [],
       'dropped-unused: the dropped table maps to no element')

m = derive.('dropped-used-by-calc')
e = entry.(m, fqn.('ORDERS'), fqn.('DIM_PRODUCT'))
check.(e && e.dig('field_use', 'status') == 'fail' && e.dig('field_use', 'worksheets') == ['Revenue by Customer'],
       "dropped-used-by-calc: a calc referencing the dropped table's field is field use (got #{e&.dig('field_use')})")

{ 'dropped-used-by-group' => 'fail', 'dropped-no-object-id' => 'fail',
  'dropped-unresolved-field' => 'fail', 'dropped-unused-with-pseudo-fields' => 'pass' }.each do |name, want|
  e = entry.(derive.(name), fqn.('ORDERS'), fqn.('DIM_PRODUCT'))
  check.(e && e['disposition'] == 'dropped' && e.dig('field_use', 'status') == want,
         "#{name}: dropped DIM_PRODUCT field use is #{want} (got #{e&.dig('field_use')})")
end

m = derive.('computed-condition')
e = entry.(m, fqn.('ORDERS'), fqn.('DIM_PRODUCT'))
check.(e && e['disposition'] == 'replaced' && e['computed_conditions'] == 1 && e['requires'] == %w[key_probe parity],
       "computed-condition: a relationship with a computed condition is replaced, never matched (got #{e&.slice('disposition', 'computed_conditions')})")
check.(entry.(m, fqn.('ORDERS'), fqn.('DIM_CUSTOMER'))['disposition'] == 'matched',
       'computed-condition: the plain-key relationship still matches')

m = derive.('dropped-bridge')
bridge = m['entries'].find { |x| x['bridge_for'] }
check.(bridge && [bridge['left'], bridge['right']].sort == [fqn.('REGIONS'), fqn.('SHIPMENTS')] &&
       bridge['disposition'] == 'replaced' && bridge['bridge_for'] == [fqn.('ORDERS')],
       "dropped-bridge: dropping ORDERS synthesizes SHIPMENTS↔REGIONS, replaced by the DM's direct edge (got #{bridge&.slice('left', 'right', 'disposition', 'bridge_for')})")
check.(m['entries'].none? { |x| x['kind'] == 'extra' },
       'dropped-bridge: the DM edge that carries the bridge is not reported extra')

m = derive.('disconnected-mixed')
e = entry.(m, fqn.('ORDERS'), fqn.('DIM_PRODUCT'))
check.(e && e['disposition'] == 'disconnected' && e['requires'] == ['field_use'] && e.dig('field_use', 'status') == 'fail',
       "disconnected-mixed: no DM path, one worksheet mixes both → field use fails (got #{e&.slice('disposition', 'field_use')})")

m = derive.('extra-edge')
extra = m['entries'].select { |x| x['kind'] == 'extra' }
check.(extra.size == 1 && extra[0]['disposition'] == 'extra' && extra[0]['requires'] == %w[key_probe parity] &&
       [extra[0]['left'], extra[0]['right']].sort == [fqn.('DIM_CUSTOMER'), fqn.('DIM_PRODUCT')],
       "extra-edge: a DM edge with no Tableau counterpart is listed extra (got #{extra.map { |x| x.slice('left', 'right') }})")

m = derive.('two-schemas-same-name')
check.(tableau.(m).all? { |x| x['disposition'] == 'matched' } && m['blockers'] == [],
       "two-schemas-same-name: SALES and HR DATE_DIM each match their own element (got #{tableau.(m).map { |x| x['disposition'] }})")
check.(m['tables'].find { |t| t['table'] == 'HR.PUBLIC.DATE_DIM' }['dm_element_ids'] == ['hdate'],
       'two-schemas-same-name: HR.PUBLIC.DATE_DIM maps only to the HR element')

m = derive.('short-name-ambiguous')
check.(m['blockers'].any? { |b| b['kind'] == 'ambiguous-table' && b['table'] == 'PUBLIC.DATE_DIM' },
       "short-name-ambiguous: a schema-only name matching two DM tables blocks as ambiguous-table (got #{m['blockers']})")
check.(m['tables'].find { |t| t['table'] == 'PUBLIC.DATE_DIM' }['dm_element_ids'] == [],
       'short-name-ambiguous: the ambiguous table maps to nothing (never guessed)')

m = derive.('schema-mismatch')
e = entry.(m, 'HR.HIRES', 'HR.DATE_DIM')
check.(e && e['disposition'] == 'dropped' &&
       m['tables'].find { |t| t['table'] == 'HR.DATE_DIM' }['dm_element_ids'] == [],
       "schema-mismatch: HR.DATE_DIM never matches ANALYTICS.SALES.DATE_DIM by table name (got #{e&.dig('disposition')})")
check.(m['tables'].find { |t| t['table'] == 'HR.HIRES' }['dm_element_ids'] == ['hires'],
       'schema-mismatch: HR.HIRES still matches ANALYTICS.HR.HIRES on schema + table')

m = derive.('two-tables-one-element')
amb = m['blockers'].select { |b| b['kind'] == 'ambiguous-table' }.map { |b| b['table'] }.sort
check.(amb == ['DATE_DIM', 'PUBLIC.DATE_DIM'],
       "two-tables-one-element: two Tableau tables resolving to one model element both block (got #{amb})")

m = derive.('extract-renamed')
check.(m['tables'].map { |t| t['table'] }.uniq.sort == %w[ANALYTICS.LANDED.CUSTOMERS ANALYTICS.LANDED.SALES_WIDE],
       "extract-renamed: extract tables resolve like the converter (GUID db dropped, --db/--schema, table mapping) (got #{m['tables'].map { |t| t['table'] }})")
check.(m['blockers'] == [] && m['entries'].all? { |x| x['disposition'] == 'matched' },
       "extract-renamed: both relationships (incl. the self-join over one warehouse table) match (got #{m['entries'].map { |x| [x['left'], x['right'], x['disposition']] }} #{m['blockers']})")
check.(m['inputs']['resolution'] == { 'db' => 'ANALYTICS', 'schema' => 'LANDED', 'table_mapping' =>
         { 'FACT_SALES' => 'SALES_WIDE', 'FACT_ORDERS' => 'SALES_WIDE', 'DIM_CUSTOMER' => 'CUSTOMERS' } },
       'extract-renamed: the resolution used is recorded on the map')
check.(derive.('matched-star')['inputs']['resolution'].nil?, 'no resolution given → none recorded')

m = derive.('role-played')
check.(tableau.(m).size == 1 && tableau.(m)[0]['disposition'] == 'matched',
       'role-played: the Tableau edge matches the origin role element')
check.(m['dm_edges'].size == 2 && m['entries'].count { |x| x['kind'] == 'extra' } == 1,
       "role-played: each DM relationship listed once; the destination role is one extra edge (got #{m['dm_edges'].size} edges)")

m = derive.('custom-sql')
check.(tableau.(m).all? { |x| x['disposition'] == 'matched' },
       "custom-sql: a Custom SQL element matches the Tableau text relation by normalized statement (got #{tableau.(m).map { |x| x['disposition'] }})")

c = load_case.('replaced-key')
check.(RelationshipMap.derive(**c) == RelationshipMap.derive(**c), 'derive is deterministic')

puts ''
puts 'test-relationship-map — merge_prior + evaluate'

probe_ok = { 'status' => 'pass', 'unique' => { 'total' => 10, 'distinct' => 10 }, 'unmatched' => 0, 'probed_at' => '2026-11-03T00:00:00Z' }
with_probes = lambda do |map, probe|
  JSON.parse(JSON.generate(map)).tap { |copy| copy['dm_edges'].each { |d| d['probe'] = probe } }
end
parity_for = ->(pass, fail = []) { { 'status' => fail.empty? ? 'PASS' : 'FAIL', 'pass_names' => pass, 'fail_names' => fail } }
evaluate = lambda do |name, map, **kw|
  RelationshipMap.evaluate(map, **load_case.(name), **kw)
end
kinds = ->(result) { result['blockers'].map { |b| b['kind'] }.uniq.sort }

r = evaluate.('matched-star', derive.('matched-star'))
check.(r['status'] == 'pass' && r['counts'] == { 'matched' => 2, 'replaced' => 0, 'disconnected' => 0, 'dropped' => 0, 'extra' => 0 },
       "evaluate: all-matched model passes with no evidence (got #{r['status']} #{r['counts']})")

rk = with_probes.(derive.('replaced-key'), probe_ok)
r = evaluate.('replaced-key', rk, parity: parity_for.(['Revenue by Customer', 'Revenue by Product']))
check.(r['status'] == 'pass' && r['counts']['replaced'] == 1,
       "evaluate: replaced edge with passing probe + parity passes (got #{r['status']} #{r['blockers']})")
r = evaluate.('replaced-key', rk, parity: parity_for.([' revenue by customer ']))
check.(r['status'] == 'pass', "evaluate: parity names match case-insensitively after strip (got #{r['blockers']})")

bad = with_probes.(derive.('replaced-key'), probe_ok.merge('status' => 'fail', 'unmatched' => 3))
r = evaluate.('replaced-key', bad, parity: parity_for.(['Revenue by Customer']))
check.(r['status'] == 'fail' && kinds.(r) == ['probe-failed'], "evaluate: unmatched keys fail the probe (got #{kinds.(r)})")
forged = with_probes.(derive.('replaced-key'), probe_ok.merge('unmatched' => 2))
r = evaluate.('replaced-key', forged, parity: parity_for.(['Revenue by Customer']))
check.(r['status'] == 'fail' && kinds.(r) == ['probe-failed'], "evaluate: a 'pass' status with unmatched keys is not trusted (got #{kinds.(r)})")
dup = with_probes.(derive.('replaced-key'), probe_ok.merge('unique' => { 'total' => 10, 'distinct' => 9 }))
r = evaluate.('replaced-key', dup, parity: parity_for.(['Revenue by Customer']))
check.(r['status'] == 'fail' && kinds.(r) == ['probe-failed'], "evaluate: a non-unique target fails the probe (got #{kinds.(r)})")
err = with_probes.(derive.('replaced-key'), { 'status' => 'error', 'error' => 'identifier refused' })
r = evaluate.('replaced-key', err, parity: parity_for.(['Revenue by Customer']))
check.(r['status'] == 'fail' && kinds.(r) == ['probe-error'], "evaluate: an errored probe blocks (got #{kinds.(r)})")

unprobed = derive.('replaced-key')
r = evaluate.('replaced-key', unprobed, final: false)
check.(r['status'] == 'pending' && kinds.(r) == %w[parity-missing unprobed],
       "evaluate final:false: unprobed + no parity yet is pending (got #{r['status']} #{kinds.(r)})")
r = evaluate.('replaced-key', unprobed)
check.(r['status'] == 'fail', "evaluate final:true: unprobed blocks (got #{r['status']})")

r = evaluate.('replaced-key', rk, parity: parity_for.(['Revenue by Product']))
check.(r['status'] == 'fail' && kinds.(r) == ['parity-missing'],
       "evaluate: an affected worksheet never compared in parity is parity-missing (got #{kinds.(r)})")
r = evaluate.('replaced-key', rk, parity: parity_for.([], ['Revenue by Customer']))
check.(r['status'] == 'fail' && kinds.(r) == ['parity-failed'], "evaluate: a failed affected worksheet is parity-failed (got #{kinds.(r)})")

reasoned = JSON.parse(JSON.generate(bad)).tap { |copy| copy['entries'].each { |e| e['reason'] = 'redesigned on purpose' } }
r = evaluate.('replaced-key', reasoned, parity: parity_for.(['Revenue by Customer']))
check.(r['status'] == 'fail', 'evaluate: a reason never satisfies evidence')

edited = JSON.parse(JSON.generate(rk)).tap do |copy|
  copy['entries'].each { |e| e['disposition'] = 'matched' if e['disposition'] == 'replaced' }
end
r = evaluate.('replaced-key', edited, parity: parity_for.(['Revenue by Customer']))
check.(r['status'] == 'fail' && kinds.(r).include?('stale-map'), "evaluate: a hand-edited disposition is stale (got #{kinds.(r)})")

c = load_case.('replaced-key')
changed = JSON.parse(JSON.generate(c[:dm_spec]))
changed['pages'][0]['elements'].find { |e| e['id'] == 'orders' }['relationships'][0]['keys'][0]['targetColumnId'] = 'cust-customer_key'
fresh = RelationshipMap.derive(twb_xml: c[:twb_xml], dm_spec: changed, dashboards: c[:dashboards])
merged = RelationshipMap.merge_prior(fresh, rk)
cust_edge = merged['dm_edges'].find { |d| d['edge_id'] == 'orders->cust' }
prod_edge = merged['dm_edges'].find { |d| d['edge_id'] == 'orders->prod' }
check.(cust_edge['probe'].nil? && prod_edge['probe'] == probe_ok,
       'merge_prior: a changed edge loses its probe; an unchanged edge keeps it')
r = RelationshipMap.evaluate(rk, twb_xml: c[:twb_xml], dm_spec: changed, dashboards: c[:dashboards],
                                 parity: parity_for.(['Revenue by Customer']))
check.(r['status'] == 'fail' && kinds.(r).include?('stale-map'), "evaluate: a map probed against an older model is stale (got #{kinds.(r)})")
noted = JSON.parse(JSON.generate(unprobed)).tap { |copy| copy['entries'][0]['reason'] = 'kept' }
check.(RelationshipMap.merge_prior(derive.('replaced-key'), noted)['entries'][0]['reason'] == 'kept',
       'merge_prior: reasons carry over by entry identity')

r = evaluate.('dropped-unused', derive.('dropped-unused'))
check.(r['status'] == 'pass' && r['counts']['dropped'] == 1, "evaluate: an unused dropped table passes (got #{r['blockers']})")
r = evaluate.('dropped-used-by-calc', derive.('dropped-used-by-calc'))
check.(r['status'] == 'fail' && kinds.(r) == ['field-use'], "evaluate: a dropped table a migrated view uses blocks (got #{kinds.(r)})")
r = evaluate.('short-name-ambiguous', derive.('short-name-ambiguous'))
check.(r['status'] == 'fail' && kinds.(r).include?('ambiguous-table'), "evaluate: map blockers carry through (got #{kinds.(r)})")

puts ''
puts 'test-relationship-map — parity normalization + goldens'
np = RelationshipMap.normalize_parity(
  { 'status' => 'FAIL', 'match' => false,
    'differences' => [{ 'path' => '$.Revenue by Product[2]', 'kind' => 'number' }] },
  { 'Revenue by Customer' => [[1]], 'Revenue by Product' => [[2]], 'Revenue by Product YoY' => [[3]] }
)
check.(np == { 'pass_names' => ['Revenue by Customer', 'Revenue by Product YoY'], 'fail_names' => ['Revenue by Product'] },
       "a whole-workbook parity verdict (Python profile) splits into pass/fail chart names by difference path (got #{np})")
check.(RelationshipMap.normalize_parity({ 'pass_names' => ['A'] }, { 'B' => [] }) == { 'pass_names' => ['A'], 'fail_names' => [] },
       'a parity-final.json that already names charts is used as is')
np = RelationshipMap.normalize_parity({ 'match' => false, 'differences' => [{ 'path' => '$', 'kind' => 'length' }] },
                                      { 'A' => [], 'B' => [] })
check.(np['pass_names'] == [] && np['fail_names'] == %w[A B],
       "a whole-document difference ($) fails every chart (got #{np})")
# Review I4: parity names Sigma charts; the map names Tableau worksheets.
plan = { 'charts' => [{ 'chart' => 'Customer Revenue (Top 10)', 'tableau_view' => 'Revenue by Customer' },
                      { 'chart' => 'Product Mix', 'tableau_view' => 'Revenue by Product' },
                      { 'chart' => 'Product Mix Trend', 'tableau_view' => 'Revenue by Product' }] }
np = RelationshipMap.normalize_parity({ 'pass_names' => ['Customer Revenue (Top 10)', 'Product Mix'],
                                        'fail_names' => ['Product Mix Trend'] }, nil, plan)
check.(np['pass_names'].include?('Revenue by Customer') && np['fail_names'].include?('Revenue by Product'),
       "chart names are aliased to their Tableau worksheet through parity-plan.json (got #{np})")
rk = with_probes.(derive.('replaced-key'), probe_ok)
r = evaluate.('replaced-key', rk, parity: RelationshipMap.normalize_parity(
  { 'pass_names' => ['Customer Revenue (Top 10)'], 'fail_names' => [] }, nil, plan))
check.(r['status'] == 'pass', "a renamed tile still satisfies its worksheet's parity (got #{r['blockers']})")
r = evaluate.('replaced-key', rk, parity: { 'pass_names' => ['Revenue by Customer'], 'fail_names' => ['revenue by customer'] })
check.(kinds.(r) == ['parity-failed'], "a worksheet with any failing chart is parity-failed even if another chart passed (got #{kinds.(r)})")
Dir.children(FIXTURES).sort.each do |name|
  golden = File.join(FIXTURES, name, 'expected-map.json')
  next unless File.directory?(File.join(FIXTURES, name))
  check.(File.file?(golden) && JSON.parse(File.read(golden)) == derive.(name),
         "#{name}: expected-map.json golden matches derive (regenerate with generate.rb --goldens)")
end

puts ''
puts 'test-relationship-map — self-joins (both ends are one table)'
self_rel = { 'left' => 'DB.S.EMP', 'right' => 'DB.S.EMP',
             'tableau_keys' => [{ 'left' => 'MANAGER_ID', 'right' => 'EMP_ID' }] }
self_edge = { 'edge_id' => 'e1', 'source_element' => 'emp', 'target_element' => 'mgr',
              'source_table' => 'DB.S.EMP', 'target_table' => 'DB.S.EMP',
              'keys' => [{ 'source' => 'EMP_ID', 'target' => 'MANAGER_ID' }] }
check.(RelationshipMap.same_join?(self_edge, self_rel), 'a self-edge with reversed key columns is the same join')
check.(!RelationshipMap.same_join?(self_edge.merge('keys' => [{ 'source' => 'EMP_ID', 'target' => 'EMP_ID' }]), self_rel),
       'a self-edge on other key columns is not')
path = RelationshipMap.shortest_path([self_edge], %w[emp mgr], %w[emp mgr])
check.(path && path.map { |e| e['edge_id'] } == ['e1'], "a self-join between two elements of one table has a one-edge path (got #{path.inspect})")
loop_edge = self_edge.merge('edge_id' => 'e2', 'target_element' => 'emp')
path = RelationshipMap.shortest_path([loop_edge], ['emp'], ['emp'])
check.(path && path.map { |e| e['edge_id'] } == ['e2'], "a self-loop on one element is a one-edge path (got #{path.inspect})")
check.(RelationshipMap.shortest_path([], %w[emp mgr], %w[emp mgr]).nil?, 'two unjoined elements of one table have no path')

puts ''
puts 'test-relationship-map — single-table deviations still name the worksheets parity must cover'
o1 = "#{RelationshipMap::OBJECT}ds|EMP"
o2 = "#{RelationshipMap::OBJECT}ds|EMP1"
usage = { 'both copies' => ['DB.S.EMP', o1, o2], 'one copy' => ['DB.S.EMP', o1], 'other' => ['DB.S.DEPT'] }
check.(RelationshipMap.affected(usage, ['DB.S.EMP'], [o1, o2]) == ['both copies'],
       'a replaced self-join is exercised by the worksheet reading both of its objects')
check.(RelationshipMap.affected(usage, ['DB.S.EMP']) == ['both copies', 'one copy'],
       'a same-table extra edge (no objects to tell copies apart) asks parity of every worksheet reading the table')
check.(RelationshipMap.affected(usage, ['DB.S.EMP', 'DB.S.DEPT']) == [], 'two-table paths keep the two-table rule')

puts 'test-relationship-map — self-join field use and empty calcs (fail closed)'
sj = ->(name) { derive.(name)['entries'].find { |e| e['kind'] == 'tableau' } }
e = sj.('self-join-unused')
check.(e && e['disposition'] == 'disconnected' && e['field_use'] == { 'status' => 'pass', 'worksheets' => [] },
       "a self-join no worksheet reads through its alias is unused (got #{e && e['field_use']})")
e = sj.('self-join-used')
check.(e && e['field_use'] == { 'status' => 'fail', 'worksheets' => ['Org Chart'] },
       "a worksheet that reads the aliased copy uses the self-join (got #{e && e['field_use']})")
e = derive.('dropped-used-by-empty-calc')['entries'].find { |x| x['disposition'] == 'dropped' }
check.(e && e['field_use'] == { 'status' => 'fail', 'worksheets' => ['Revenue by Customer'] },
       "a calc with an empty formula is unknown usage, never a pass (got #{e && e['field_use']})")

puts ''
puts 'test-relationship-map — extract table names ($ suffix, same as the Python twin)'
check.(RelationshipMap.suffix_match?(['ORDERS'], %w[DB S ORDERS$]), 'a model path named ORDERS$ matches the Tableau ORDERS')
check.(RelationshipMap.suffix_match?(%w[S ORDERS$], %w[DB S ORDERS]), 'a Tableau ORDERS$ matches the model ORDERS')
check.(!RelationshipMap.suffix_match?(['ORDERS'], %w[DB S ORDERS$$]), 'only one trailing $ is an extract suffix')

puts ''
if fails.empty?
  puts 'test-relationship-map.rb: ALL PASS'
  exit 0
end
puts "test-relationship-map.rb: #{fails.size} FAILURE(S)"
fails.each { |f| puts "  - #{f}" }
exit 1
