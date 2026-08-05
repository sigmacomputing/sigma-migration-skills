#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for the Rec5 element-quarantine ("don't lose the other 4
# elements"): scripts/lib/dm_quarantine.rb pure functions + the
# assert-phase6-ran.rb gate 12 (deferred-elements.json blocks GREEN, exit 17).
# Deterministic — no network, no live Sigma API.
#
# Usage:  ruby scripts/test-dm-quarantine.rb

require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/dm_quarantine'
require_relative 'lib/blind_fixture'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

Q = DmQuarantine
GATE = File.join(__dir__, 'assert-phase6-ran.rb')

# A 4-element DM shaped like the field regression: warehouse fact, a 2-column
# LOD SQL helper, a derived view whose formulas reference base+helper, and an
# unrelated healthy dim. Fact carries the relationship to the helper.
def spec_fixture
  {
    'name' => 'Pipeline Deals', 'schemaVersion' => 1,
    'pages' => [{ 'id' => 'pg1', 'name' => 'Page 1', 'elements' => [
      { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Deal Facts',
        'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS SALES DEAL_FACTS] },
        'columns' => [{ 'id' => 'c1', 'formula' => '[DEAL_FACTS/Customer Ref Id]' },
                      { 'id' => 'c2', 'formula' => '[DEAL_FACTS/Deal Value]' }],
        'relationships' => [{ 'id' => 'r1', 'targetElementId' => 'el-helper',
                              'keys' => [{ 'sourceColumnId' => 'c1', 'targetColumnId' => 'h1' }] }] },
      { 'id' => 'el-helper', 'kind' => 'table', 'name' => 'DEAL_FACTS FIXED CUSTOMER_REF_ID',
        'source' => { 'kind' => 'sql', 'statement' => 'SELECT CUSTOMER_SFDC_ID, COUNT(1) AS N FROM ANALYTICS.SALES.DEAL_FACTS GROUP BY 1' },
        'columns' => [{ 'id' => 'h1', 'formula' => '[Custom SQL/CUSTOMER_REF_ID]' }] },
      { 'id' => 'el-view', 'kind' => 'table', 'name' => 'Deal Facts View',
        'source' => { 'kind' => 'table', 'elementId' => 'el-fact' },
        'columns' => [{ 'id' => 'v1', 'formula' => '[Deal Facts/Customer Ref Id]' },
                      { 'id' => 'v2', 'formula' => '[Deal Facts/FIXED Customer Ref ID/Max West]' }] },
      { 'id' => 'el-dim', 'kind' => 'table', 'name' => 'Account Dim',
        'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS SALES ACCOUNT_DIM] },
        'columns' => [{ 'id' => 'd1', 'formula' => '[ACCOUNT_DIM/Account Name]' }] }
    ] }]
  }
end

puts 'Part A — offending_from_error: dependency-not-found refs blame the DEPENDENT'
err = '{"code":"bad_request","message":"Dependency not found: [Deal Facts/Customer Ref Id] ' \
      '(and 299 more) while compiling element"}'
found = Q.offending_from_error(spec_fixture, err)
check(found[:ids].include?('el-view'), 'view (holder of the broken refs) blamed', fails)
check(!found[:ids].include?('el-fact'), 'base fact NOT blamed for its own self-refs', fails)

puts 'Part B — offending_from_error: element name / SQL identifier attribution'
found = Q.offending_from_error(spec_fixture, 'Element "Deal Facts View" failed to compile')
check(found[:ids] == ['el-view'], "name mention → el-view (got #{found[:ids].inspect})", fails)
found = Q.offending_from_error(spec_fixture, "SQL compilation error: invalid identifier 'CUSTOMER_SFDC_ID'")
check(found[:ids] == ['el-helper'], "invalid identifier → the sql element (got #{found[:ids].inspect})", fails)
found = Q.offending_from_error(spec_fixture, 'internal server error, request id 12345')
check(found[:ids].empty?, 'unattributable error → NOTHING quarantined (fail-loud contract)', fails)

puts 'Part C — offending_from_error_columns: live census → spec elements'
census = [{ 'elementId' => 'el-view', 'columnId' => 'v2', 'label' => 'Max West', 'type' => { 'type' => 'error' } }]
found = Q.offending_from_error_columns(spec_fixture, census)
check(found[:ids] == ['el-view'], 'direct spec-id match', fails)
census = [{ 'elementId' => 'live-9x', 'columnId' => 'v2', 'label' => 'Max West', 'type' => { 'type' => 'error' } }]
found = Q.offending_from_error_columns(spec_fixture, census, { 'live-9x' => 'Deal Facts View' })
check(found[:ids] == ['el-view'], 'server-assigned live id maps back via element NAME', fails)
found = Q.offending_from_error_columns(spec_fixture, census, {})
check(found[:ids].empty?, 'unmappable live id → nothing quarantined', fails)

puts 'Part D — quarantine: removes offenders, keeps the rest, drops dangling rels'
src = spec_fixture
q = Q.quarantine(src, ['el-helper'], { 'el-helper' => 'SQL compile error' })
kept_ids = q[:spec]['pages'][0]['elements'].map { |e| e['id'] }
check(kept_ids == %w[el-fact el-view el-dim], "helper removed, other 3 kept (got #{kept_ids.inspect})", fails)
fact2 = q[:spec]['pages'][0]['elements'].find { |e| e['id'] == 'el-fact' }
check(!fact2.key?('relationships'), 'dangling fact→helper relationship dropped from the cleaned spec', fails)
check(q[:deferred].size == 1 && q[:deferred][0]['element']['id'] == 'el-helper', 'deferred record carries the full element spec', fails)
check(q[:deferred][0]['reason'] == 'SQL compile error', 'deferred record carries the reason', fails)
check(q[:deferred][0]['removedRelationships'].size == 1 &&
      q[:deferred][0]['removedRelationships'][0]['sourceElementId'] == 'el-fact',
      'removed relationship recorded for restoration', fails)
check(src['pages'][0]['elements'].size == 4 && src['pages'][0]['elements'][0].key?('relationships'),
      'original spec untouched (deep copy)', fails)
doc = Q.deferred_doc(q[:deferred], data_model_id: 'dm-123', spec_path: '/x/dm-spec.json')
check(doc['dataModelId'] == 'dm-123' && doc['deferred'].size == 1 && doc['note'].include?('PARTIAL'),
      'deferred_doc shape (id + note + deferred[])', fails)

puts 'Part E — gate 12 (assert-phase6-ran.rb): deferred-elements.json blocks GREEN'
# Workdir that passes every default gate (mirrors test-assert-phase6-gates.rb).
def base_workdir(dir)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(
    'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
    'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
    'pass_names' => %w[KPI Trend], 'fail_names' => [],
    'visual_checked' => true, 'visual_verdict' => 'pass', 'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass', 'composition_match' => 'pass', 'chart_shapes_match' => 'pass', 'labels_legible' => 'pass', 'numbers_formatted' => 'pass' }, 'agent_vision' => true))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(dir) # PR-9: gate 8b refuses a self-attested visual pass
end

def run_gate(dir, *args)
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }
  Open3.capture3(env, RbConfig.ruby, GATE, '--workdir', dir, *args)
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _e, st = run_gate(dir)
  check(st.success? && out.include?('gate 12: no deferred-elements.json'),
        'no deferred file → gate 12 OK, all gates pass', fails)

  File.write(File.join(dir, 'deferred-elements.json'), JSON.pretty_generate(
    Q.deferred_doc(q[:deferred], data_model_id: 'dm-123')))
  out, err, st = run_gate(dir)
  check(st.exitstatus == 17, "non-empty deferred → exit 17 (got #{st.exitstatus})", fails)
  check(err.include?('resolve the deferred elements and re-POST') || err.downcase.include?('resolve the deferred'),
        'failure text says to resolve the deferred elements and re-POST', fails)
  check(err.include?('DEAL_FACTS FIXED CUSTOMER_REF_ID'), 'failure names the deferred element', fails)
  check(!out.include?('all gates pass'), 'GREEN clearance withheld', fails)

  out, _e, st = run_gate(dir, '--accept-deferred-elements', 'customer accepted partial DM for pilot')
  check(st.success?, 'waiver → gates pass', fails)
  check(out.include?('--accept-deferred-elements') && out.include?('WAIVED'),
        'waiver recorded loudly (never silent)', fails)
  waivers = JSON.parse(File.read(File.join(dir, 'waivers.json'))) rescue []
  check(waivers.any? { |w| w['flag'] == '--accept-deferred-elements' }, 'waiver persisted to waivers.json', fails)

  File.write(File.join(dir, 'deferred-elements.json'), JSON.pretty_generate('deferred' => []))
  out, _e, st = run_gate(dir)
  check(st.success? && out.include?('all quarantined elements resolved'),
        'EMPTY deferred list → gate 12 OK (resolved)', fails)

  File.write(File.join(dir, 'deferred-elements.json'), '{not json')
  _o, err, st = run_gate(dir)
  check(st.exitstatus == 17 && err.include?('malformed'), 'malformed deferred file → exit 17, stated', fails)
end

puts 'Part F — shared twin in sync (md5 discipline)'
require 'digest'
local  = Digest::MD5.file(GATE).hexdigest
shared = Digest::MD5.file(File.expand_path('../../../../../shared/scripts/assert-phase6-ran.rb', __dir__)).hexdigest
check(local == shared, 'scripts/assert-phase6-ran.rb byte-identical to shared/scripts twin (run tools/sync-shared.rb)', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
