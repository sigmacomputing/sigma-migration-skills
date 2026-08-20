#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the LOD "refuse to guess" contract (#423) —
# scripts/lib/lod_audit.rb + scripts/audit-lod-calcs.rb.
#
# The field failure: 5 of 12 {FIXED entity: COUNTD(...)} measures were
# fuzzy-name-aliased to unrelated raw flag columns (silently wrong numbers)
# and 7 were dropped outright — zero errors anywhere. This test proves:
#   (i)   an LOD whose translation IS the documented synth output (grouped
#         helper / grouped Custom SQL / FIXED-relationship surfacing) →
#         resolved (class lod-synth);
#   (ii)  a fuzzy-aliased dm-spec column (emitted formula reads a raw column
#         NOT in the LOD expression's own reference set) → suspect-alias;
#   (iii) a dropped calc (no emitted translation anywhere) → silently-dropped;
#   (iv)  the audit script blocks unresolved (exit 2), passes resolved, and
#         records --resolve waivers that survive re-derivation.
# Deterministic + offline.
#
# Usage: ruby scripts/test-lod-audit.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/lod_audit'

SCRIPT = File.join(__dir__, 'audit-lod-calcs.rb')

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# ---- the source census: calc-fields.json shape -----------------------------
# Neutral fixture vocabulary (per tools/hygiene-patterns.txt): a per-entity
# distinct-count measure family over a generic fact table.
CALC_FIELDS = {
  'calcs' => [
    { 'name' => 'Active Seats', 'internal_name' => '[Calculation_100]',
      'formula' => '{FIXED [Account Name]: COUNTD([Seat Id])}', 'is_lod' => true },
    { 'name' => 'Aliased Seats', 'internal_name' => '[Calculation_101]',
      'formula' => '{FIXED [Account Name]: COUNTD([Seat Id])}', 'is_lod' => true },
    { 'name' => 'Dropped Seats', 'internal_name' => '[Calculation_102]',
      'formula' => '{ EXCLUDE [Region] : MAX([Seat Id]) }', 'is_lod' => true },
    { 'name' => 'Declared Residue', 'internal_name' => '[Calculation_103]',
      'formula' => '{INCLUDE [Region]: SUM([Net Value])}', 'is_lod' => true },
    { 'name' => 'Plain Calc', 'internal_name' => '[Calculation_104]',
      'formula' => 'IF [Net Value] > 0 THEN 1 ELSE 0 END', 'is_lod' => false },
    # LOD keyword inside a STRING literal must NOT census as an LOD.
    { 'name' => 'String Trap', 'internal_name' => '[Calculation_105]',
      'formula' => "'{FIXED [x]: SUM([y])}'", 'is_lod' => false }
  ]
}.freeze

# ---- the emitted specs -----------------------------------------------------
# dm-spec: 'Active Seats' is the synth output (grouped Custom SQL helper +
# FIXED-relationship surfacing on the master); 'Aliased Seats' is the fuzzy
# alias (reads raw SEAT_FLAG, which the LOD never references); 'Dropped Seats'
# appears nowhere.
DM_SPEC = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Seat Fact',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB PUBLIC SEAT_FACT] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Account Name', 'formula' => '[SEAT_FACT/Account Name]' },
        { 'id' => 'c2', 'name' => 'Seat Id',      'formula' => '[SEAT_FACT/Seat Id]' },
        # (ii) the fuzzy-alias: calc caption bound to an unrelated raw flag column
        { 'id' => 'c3', 'name' => 'Aliased Seats', 'formula' => '[SEAT_FACT/SEAT_FLAG]' }
      ] },
    # (i) the synth output: grouped Custom SQL helper...
    { 'id' => 'el-seats-by-account', 'kind' => 'table',
      'source' => { 'kind' => 'sql',
                    'statement' => 'SELECT "ACCOUNT_NAME" AS "Account Name", COUNT(DISTINCT "SEAT_ID") AS "Active Seats" ' \
                                   'FROM DEMO_DB.PUBLIC."SEAT_FACT" GROUP BY "ACCOUNT_NAME"' },
      'columns' => [
        { 'id' => 'sba-k', 'name' => 'Account Name', 'formula' => '[Custom SQL/Account Name]' },
        { 'id' => 'sba-v', 'name' => 'Active Seats', 'formula' => '[Custom SQL/Active Seats]' }
      ] },
    # ...surfaced onto the master through a FIXED relationship ref.
    { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
      'source' => { 'kind' => 'table', 'elementId' => 'el-fact' },
      'columns' => [
        { 'id' => 'm1', 'name' => 'Active Seats', 'formula' => '[Seat Fact/FIXED Account/Active Seats]' }
      ] }
  ] }]
}.freeze

MANUAL_RESIDUES = { 'residues' => [
  { 'calc' => 'Declared Residue', 'tile' => 'Region Trend', 'status' => 'unbuilt' }
] }.freeze

puts 'Part A — census (masked scan)'
calcs = LodAudit.lod_calcs(CALC_FIELDS)
check(calcs.size == 4, "4 LOD calcs censused of 6 (non-LOD + string-literal trap excluded) (got #{calcs.size})", fails)
check(calcs.none? { |c| c['calc'] == 'String Trap' }, "'{FIXED' inside a string literal does not census", fails)
active = calcs.find { |c| c['calc'] == 'Active Seats' }
check(active && active['lod_kind'] == 'FIXED', 'lod_kind FIXED detected', fails)
check(active && active['reference_set'].sort == ['Account Name', 'Seat Id'],
      "reference set = the LOD expression's own refs (got #{active && active['reference_set'].inspect})", fails)
check(calcs.find { |c| c['calc'] == 'Dropped Seats' }['lod_kind'] == 'EXCLUDE', 'EXCLUDE kind detected', fails)

puts 'Part B — classification against the emitted specs'
entries = LodAudit.derive(calcs, dm_spec: JSON.parse(JSON.generate(DM_SPEC)),
                          wb_spec: nil, manual_residues: JSON.parse(JSON.generate(MANUAL_RESIDUES)))
by = {}
entries.each { |e| by[e['calc']] = e }
check(by['Active Seats'] && by['Active Seats']['class'] == 'lod-synth' && by['Active Seats']['status'] == 'resolved',
      "(i) synth output → resolved lod-synth (got #{by['Active Seats'] && by['Active Seats']['class']})", fails)
check(by['Aliased Seats'] && by['Aliased Seats']['class'] == 'suspect-alias',
      "(ii) fuzzy alias → suspect-alias (got #{by['Aliased Seats'] && by['Aliased Seats']['class']})", fails)
check(by['Aliased Seats'] && Array(by['Aliased Seats']['suspect_refs']) == ['SEAT_FLAG'],
      "suspect-alias names the alien raw column (got #{by['Aliased Seats'] && by['Aliased Seats']['suspect_refs'].inspect})", fails)
check(by['Dropped Seats'] && by['Dropped Seats']['class'] == 'silently-dropped',
      '(iii) no translation anywhere → silently-dropped', fails)
check(by['Declared Residue'] && by['Declared Residue']['class'] == 'manual-residue' && by['Declared Residue']['status'] == 'resolved',
      'explicit manual-residues.json entry → resolved manual-residue', fails)

puts 'Part B1 — source census proves an un-emitted LOD is unused (resolved without waiver)'
unused_entries = LodAudit.derive(
  calcs,
  dm_spec: JSON.parse(JSON.generate(DM_SPEC)),
  wb_spec: nil,
  manual_residues: JSON.parse(JSON.generate(MANUAL_RESIDUES)),
  unused_fields: ['[Dropped Seats]', '[Aliased Seats]']
)
unused_by = unused_entries.each_with_object({}) { |entry, index| index[entry['calc']] = entry }
check(unused_by['Dropped Seats']['class'] == 'unused-source' &&
      unused_by['Dropped Seats']['status'] == 'resolved',
      'un-emitted calc named by the source unused-field census → resolved unused-source', fails)
check(unused_by['Dropped Seats'].dig('evidence', 'kind') == 'source-unused-field-census',
      'unused-source resolution carries explicit census evidence', fails)
check(unused_by['Aliased Seats']['class'] == 'suspect-alias',
      'unused-field census never masks an emitted suspect alias', fails)

puts 'Part B2 — reference-derived: a formula built strictly from the LOD refs resolves'
wb = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart', 'name' => 'Seats KPI',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => 'k1', 'name' => 'Dropped Seats',
                    'formula' => 'Max([Master/Seat Id])' }] }
] }] }
e2 = LodAudit.derive(calcs, dm_spec: nil, wb_spec: wb, manual_residues: nil)
d2 = e2.find { |x| x['calc'] == 'Dropped Seats' }
check(d2 && d2['class'] == 'reference-derived' && d2['status'] == 'resolved',
      "emitted formula over the LOD's own refs → reference-derived (got #{d2 && d2['class']})", fails)

puts 'Part B3 — a grouped (two-stage) wb-spec helper element counts as synth'
wb3 = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-h', 'kind' => 'table', 'name' => 'Dropped Seats Source',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => 'h1', 'name' => 'Dropped Seats', 'formula' => 'Max([Master/UNRELATED_COL])' }],
    'groupings' => [{ 'id' => 'g1', 'groupBy' => ['h0'], 'calculations' => ['h1'] }] }
] }] }
e3 = LodAudit.derive(calcs, dm_spec: nil, wb_spec: wb3, manual_residues: nil)
d3 = e3.find { |x| x['calc'] == 'Dropped Seats' }
check(d3 && d3['class'] == 'lod-synth', 'grouped helper element → lod-synth even with rewired refs', fails)

puts 'Part B3b — current flat workbook document.elements is audited too'
wb3_flat = {
  'document' => {
    'schemaVersion' => 1,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'p1', 'name' => 'Page 1' }],
    'elements' => wb3['pages'][0]['elements'],
    'layout' => '<Page id="p1"><Element elementId="el-h"/></Page>'
  }
}
e3_flat = LodAudit.derive(calcs, dm_spec: nil, wb_spec: wb3_flat, manual_residues: nil)
d3_flat = e3_flat.find { |x| x['calc'] == 'Dropped Seats' }
check(d3_flat && d3_flat['class'] == 'lod-synth',
      'flat workbook grouped helper is visible to the LOD audit', fails)

puts 'Part B4 — passthrough-only ref is NOT evidence (still dropped)'
wb4 = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-c', 'kind' => 'bar-chart', 'name' => 'Chart',
    'columns' => [{ 'id' => 'p1', 'name' => 'Dropped Seats', 'formula' => '[Master/Dropped Seats]' }] }
] }] }
e4 = LodAudit.derive(calcs, dm_spec: nil, wb_spec: wb4, manual_residues: nil)
d4 = e4.find { |x| x['calc'] == 'Dropped Seats' }
check(d4 && d4['class'] == 'silently-dropped', 'bare passthrough ref alone → still silently-dropped', fails)

puts 'Part B5 — #452: an emitted look-alike of a FILTER-CONDITION column is NOT reference-derived'
# The common field shape: {FIXED dims: COUNTD(IF <flag> = "X" THEN <key> END)}.
# The flag column ('Status Flag') is a filter PREDICATE that GATES the count; the
# counted OUTPUT is the key ('Seat Id'). A raw look-alike column 'STATUS_FLAG'
# exists in the warehouse, so the calc's caption can collide downstream with a
# BARE PASSTHROUGH of that flag — which reads the raw flag, not the COUNTD
# (silently wrong numbers). 'Status Flag' is inside the LOD's reference_set, so
# pre-#452 classify() wrongly marked this passthrough reference-derived/resolved.
GATED_FIELDS = {
  'calcs' => [
    { 'name' => 'Gated Seats', 'internal_name' => '[Calculation_200]',
      'formula' => '{FIXED [Account Name]: COUNTD(IF [Status Flag] = "ACTIVE" ' \
                   'OR [Status Flag] = "PENDING" THEN [Seat Id] END)}', 'is_lod' => true }
  ]
}.freeze
gcalcs = LodAudit.lod_calcs(GATED_FIELDS)
gated  = gcalcs.first
check(gated && gated['reference_set'].sort == ['Account Name', 'Seat Id', 'Status Flag'],
      "reference set includes the filter-predicate column (got #{gated && gated['reference_set'].inspect})", fails)

# (a) the fuzzy filter-alias: a bare passthrough of the FILTER-CONDITION column.
dm_filter = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-f', 'kind' => 'table', 'name' => 'Seat Fact',
    'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB PUBLIC SEAT_FACT] },
    'columns' => [
      { 'id' => 'g1', 'name' => 'Gated Seats', 'formula' => '[SEAT_FACT/STATUS_FLAG]' }
    ] }
] }] }
ef = LodAudit.derive(gcalcs, dm_spec: JSON.parse(JSON.generate(dm_filter)), wb_spec: nil, manual_residues: nil)
gf = ef.find { |x| x['calc'] == 'Gated Seats' }
check(gf && gf['class'] == 'suspect-alias' && gf['status'] == 'unresolved',
      "(a) passthrough of the LOD's filter-condition column → suspect-alias (gate 17 blocks) (got #{gf && gf['class']})", fails)
check(gf && Array(gf['suspect_refs']) == ['STATUS_FLAG'],
      "suspect-alias names the aliased filter column (got #{gf && gf['suspect_refs'].inspect})", fails)
check(gf && gf['detail'].to_s.include?('FILTER CONDITION'),
      'detail explains the filter-condition alias (distinct from the plain out-of-refs alias)', fails)
check(gf && !LodAudit.resolved?(gf), 'the filter-alias entry is unresolved until an operator resolves it', fails)

# (b) a GENUINE reference-derivation of the SAME LOD (re-aggregation of the
#     OUTPUT field) still passes — the fix must not over-flag the honest case.
wb_ok = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-k', 'kind' => 'kpi-chart', 'name' => 'Gated KPI',
    'columns' => [
      { 'id' => 'gk', 'name' => 'Gated Seats', 'formula' => 'CountDistinct([Seat Fact/Seat Id])' }
    ] }
] }] }
eo = LodAudit.derive(gcalcs, dm_spec: nil, wb_spec: JSON.parse(JSON.generate(wb_ok)), manual_residues: nil)
go = eo.find { |x| x['calc'] == 'Gated Seats' }
check(go && go['class'] == 'reference-derived' && go['status'] == 'resolved',
      "(b) re-aggregation of the LOD's OUTPUT field still → reference-derived (got #{go && go['class']})", fails)

# (c) a non-aggregating passthrough of the LOD's OUTPUT column (not a filter
#     column) is NOT the #452 failure — left as-is (still reference-derived),
#     so the fix stays surgical to the filter-condition blind spot.
wb_out = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-o', 'kind' => 'table', 'name' => 'Out',
    'columns' => [
      { 'id' => 'oc', 'name' => 'Gated Seats', 'formula' => '[Seat Fact/Seat Id]' }
    ] }
] }] }
ep = LodAudit.derive(gcalcs, dm_spec: nil, wb_spec: JSON.parse(JSON.generate(wb_out)), manual_residues: nil)
gp = ep.find { |x| x['calc'] == 'Gated Seats' }
check(gp && gp['class'] == 'reference-derived',
      "output-column passthrough is not the filter-alias failure (got #{gp && gp['class']})", fails)

puts 'Part C — .twb fallback census'
TWB = <<~XML
  <workbook>
    <datasources><datasource name='ds1'>
      <column caption='Active Seats' name='[Calculation_100]'>
        <calculation class='tableau' formula='{FIXED [Account Name]: COUNTD([Seat Id])}'/>
      </column>
      <column caption='Plain' name='[Calculation_104]'>
        <calculation class='tableau' formula='[Net Value] * 2'/>
      </column>
    </datasource></datasources>
  </workbook>
XML
tw = LodAudit.lod_calcs_from_twb(TWB)
check(tw.size == 1 && tw[0]['calc'] == 'Active Seats' && tw[0]['lod_kind'] == 'FIXED',
      ".twb fallback censuses the LOD calc only (got #{tw.map { |c| c['calc'] }.inspect})", fails)

puts 'Part D — (iv) audit script: block / resolve / waive round-trip'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate(CALC_FIELDS))
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_SPEC))
  File.write(File.join(dir, 'manual-residues.json'), JSON.pretty_generate(MANUAL_RESIDUES))

  out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st.exitstatus == 2, "unresolved entries → exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('LOD TRANSLATION FATAL'), 'FATAL block printed', fails)
  check(err.include?('SEAT_FLAG') && err.include?('reference set'),
        'suspect-alias failure names the alien column and the reference-set contract', fails)
  check(err.include?('--resolve'), 'failure names the sanctioned resolution path', fails)
  ledger = JSON.parse(File.read(File.join(dir, 'lod-audit.json')))
  check(ledger['entries'].size == 4, "ledger carries all 4 LOD entries (got #{ledger['entries'].size})", fails)

  # resolve the suspect-alias as waived, the dropped one as manual.
  idx = {}
  ledger['entries'].each_with_index { |e, i| idx[e['calc']] = i }
  _o, _e, st1 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                               '--resolve', idx['Aliased Seats'].to_s, '--how', 'waived',
                               '--reason', 'test operator: fixture waiver')
  check(st1.exitstatus == 2, 'one resolution recorded, one entry still blocks → exit 2', fails)
  _o, _e, st2 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                               '--resolve', idx['Dropped Seats'].to_s, '--how', 'manual',
                               '--reason', 'hand-built helper element Seats By Account')
  check(st2.exitstatus.zero?, "all entries resolved/waived → exit 0 (got #{st2.exitstatus})", fails)

  # re-derivation preserves the recorded resolutions.
  out3, _e3, st3 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st3.exitstatus.zero?, "re-derive after resolutions → still exit 0 (got #{st3.exitstatus})", fails)
  check(out3.include?('2 resolved-by-hand'), 're-derived ledger carries both resolutions forward', fails)

  # a resolution on an already-resolved class is rejected.
  _o4, e4s, st4 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                                 '--resolve', idx['Active Seats'].to_s, '--how', 'waived', '--reason', 'x')
  check(!st4.success? && e4s.include?('only suspect-alias/silently-dropped'),
        'resolving a resolved entry is refused', fails)
end

puts 'Part D2 — audit script consumes source unused-field census'
Dir.mktmpdir do |dir|
  dropped_only = { 'calcs' => [CALC_FIELDS['calcs'].find { |calc| calc['name'] == 'Dropped Seats' }] }
  gaps = { 'field_statistics' => { 'unused_field_names' => ['[Dropped Seats]'] } }
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate(dropped_only))
  File.write(File.join(dir, 'workbook-content-gaps-report.json'), JSON.pretty_generate(gaps))

  out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st.success?, "unused-only LOD audit exits 0 (got #{st.exitstatus}: #{err.lines.first})", fails)
  check(out.include?('[unused-source]') && out.include?('0 unresolved'),
        'script reports unused-source as resolved without a manual/waived resolution', fails)
end

puts 'Part B6 — wave-2 §6.6: wrong-FROM grouped Custom-SQL helper is NOT synth evidence'
# The object-model field failure: the converter elected a date dim as the fact
# and baked `SELECT DATE_MONTH, SUM(VISIT_REVENUE) FROM …DIM_DATES` — a fact
# measure aggregated off the date dimension. The audit marked it
# lod-synth/resolved on NAME MATCH ALONE (sql_grouped == GROUP BY present) and
# gate 17 passed. Now: sql_grouped is evidence only when the FROM table exists
# among the spec's base elements AND owns every identifier the statement reads.
OM_FIELDS = {
  'calcs' => [
    { 'name' => 'Monthly Revenue', 'internal_name' => '[Calculation_300]',
      'formula' => '{FIXED [Date Month]: SUM([Visit Revenue])}', 'is_lod' => true },
    { 'name' => 'Site Revenue', 'internal_name' => '[Calculation_301]',
      'formula' => '{FIXED [Site Key]: SUM([Visit Revenue])}', 'is_lod' => true }
  ]
}.freeze
def om_base_elements
  [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Fact Visits',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC FACT_VISITS] },
      'columns' => [
        { 'id' => 'f1', 'name' => 'Site Key',      'formula' => '[FACT_VISITS/Site Key]' },
        { 'id' => 'f2', 'name' => 'Date Key',      'formula' => '[FACT_VISITS/Date Key]' },
        { 'id' => 'f3', 'name' => 'Visit Revenue', 'formula' => '[FACT_VISITS/Visit Revenue]' }
      ] },
    { 'id' => 'el-dates', 'kind' => 'table', 'name' => 'Dim Dates',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC DIM_DATES] },
      'columns' => [
        { 'id' => 'd1', 'name' => 'Date Key',   'formula' => '[DIM_DATES/Date Key]' },
        { 'id' => 'd2', 'name' => 'Date Month', 'formula' => '[DIM_DATES/Date Month]' }
      ] }
  ]
end
def om_helper(stmt, name)
  { 'id' => "el-h-#{name.downcase.gsub(/[^a-z0-9]+/, '-')}", 'kind' => 'table', 'name' => "#{name} Helper",
    'source' => { 'kind' => 'sql', 'statement' => stmt },
    'columns' => [{ 'id' => 'h1', 'name' => name, 'formula' => "[Custom SQL/#{name}]" }] }
end
om_calcs = LodAudit.lod_calcs(OM_FIELDS)

# (a) the wrong-FROM helper (fact measure off the date dim) → unresolved.
dm_wrong = { 'pages' => [{ 'elements' => om_base_elements + [
  om_helper('SELECT DATE_MONTH, SUM(VISIT_REVENUE) AS MONTHLY_REVENUE ' \
            'FROM ANALYTICS.PUBLIC.DIM_DATES GROUP BY 1', 'Monthly Revenue')
] }] }
ew = LodAudit.derive(om_calcs, dm_spec: JSON.parse(JSON.generate(dm_wrong)), wb_spec: nil, manual_residues: nil)
mw = ew.find { |x| x['calc'] == 'Monthly Revenue' }
check(mw && mw['class'] == 'suspect-alias' && mw['status'] == 'unresolved',
      "wrong-FROM helper → suspect-alias/unresolved, NOT lod-synth (got #{mw && mw['class']}/#{mw && mw['status']})", fails)
check(mw && Array(mw['suspect_refs']).include?('VISIT_REVENUE'),
      "the off-table identifier is named (got #{mw && mw['suspect_refs'].inspect})", fails)
check(mw && mw['detail'].to_s.include?('FROM'), 'detail names the wrong-FROM cause', fails)

# (b) the surfacing rel-ref must NOT rescue the broken helper: same spec + a
# master column [Fact Visits/FIXED Date Month/Monthly Revenue].
dm_surfaced = JSON.parse(JSON.generate(dm_wrong))
dm_surfaced['pages'][0]['elements'] << {
  'id' => 'master', 'kind' => 'table', 'name' => 'Master',
  'source' => { 'kind' => 'table', 'elementId' => 'el-fact' },
  'columns' => [{ 'id' => 'm1', 'name' => 'Monthly Revenue',
                  'formula' => '[Fact Visits/FIXED Date Month/Monthly Revenue]' }]
}
es = LodAudit.derive(om_calcs, dm_spec: dm_surfaced, wb_spec: nil, manual_residues: nil)
ms = es.find { |x| x['calc'] == 'Monthly Revenue' }
check(ms && ms['status'] == 'unresolved',
      "a FIXED-relationship surfacing ref onto the wrong-FROM helper does not resolve it (got #{ms && ms['class']})", fails)

# (c) no-false-trip control: a fact-local helper whose FROM owns everything.
dm_right = { 'pages' => [{ 'elements' => om_base_elements + [
  om_helper('SELECT SITE_KEY, SUM(VISIT_REVENUE) AS SITE_REVENUE ' \
            'FROM ANALYTICS.PUBLIC.FACT_VISITS GROUP BY 1', 'Site Revenue')
] }] }
er = LodAudit.derive(om_calcs, dm_spec: JSON.parse(JSON.generate(dm_right)), wb_spec: nil, manual_residues: nil)
mr2 = er.find { |x| x['calc'] == 'Site Revenue' }
check(mr2 && mr2['class'] == 'lod-synth' && mr2['status'] == 'resolved',
      "correct-FROM helper stays lod-synth/resolved — no false trip (got #{mr2 && mr2['class']})", fails)

# (d) FROM table absent from the spec's base elements → unresolved, named.
dm_missing = { 'pages' => [{ 'elements' => om_base_elements + [
  om_helper('SELECT SITE_KEY, SUM(VISIT_REVENUE) AS SITE_REVENUE ' \
            'FROM ANALYTICS.PUBLIC.STAGING_ROLLUP GROUP BY 1', 'Site Revenue')
] }] }
em = LodAudit.derive(om_calcs, dm_spec: JSON.parse(JSON.generate(dm_missing)), wb_spec: nil, manual_residues: nil)
mm = em.find { |x| x['calc'] == 'Site Revenue' }
check(mm && mm['status'] == 'unresolved' && mm['detail'].to_s.include?('not a base element'),
      "helper FROM a table the spec does not model → unresolved (got #{mm && mm['class']})", fails)

# (e) no ownership oracle (all-Custom-SQL model, zero warehouse-table
# elements) → legacy behavior, resolved: nothing exists to verify against.
dm_allsql = { 'pages' => [{ 'elements' => [
  om_helper('SELECT DATE_MONTH, SUM(VISIT_REVENUE) AS MONTHLY_REVENUE ' \
            'FROM ANALYTICS.PUBLIC.DIM_DATES GROUP BY 1', 'Monthly Revenue')
] }] }
ea = LodAudit.derive(om_calcs, dm_spec: JSON.parse(JSON.generate(dm_allsql)), wb_spec: nil, manual_residues: nil)
ma = ea.find { |x| x['calc'] == 'Monthly Revenue' }
check(ma && ma['class'] == 'lod-synth',
      "no warehouse-table elements → no oracle → legacy resolved (got #{ma && ma['class']})", fails)

puts 'Part E — empty ledger is still written (gate evidence)'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Plain', 'formula' => '[A] + [B]', 'is_lod' => false }
  ]))
  out, _err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st.success?, 'no LOD calcs → exit 0', fails)
  led = JSON.parse(File.read(File.join(dir, 'lod-audit.json')))
  check(led['entries'] == [], 'empty lod-audit.json written as evidence', fails)
  check(out.include?('0 LOD calc(s)') || out.include?('Ledger'), 'summary names the ledger', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
