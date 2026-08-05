#!/usr/bin/env ruby
# frozen_string_literal: true
# Tests for scripts/vds-oracle.rb — the VDS table-calc oracle (Phase 6w, advisory).
#
#   1. Pure core (VdsOracle): VDS query construction for RUNNING_SUM / RANK /
#      WINDOW_MAX — asserting the LIVE-VERIFIED request shapes (tableCalculation
#      {tableCalcType: CUSTOM, dimensions: [addressing dims]}; partition dims are
#      query dims EXCLUDED from tableCalculation.dimensions; sortDirection +
#      sortPriority on dims) — formula preflight (unsupported constructs,
#      parameter refs, one-level inlining), value comparison (tolerance, rank-as-
#      integer, date normalization, unjoined accounting), filtered-context
#      downgrade.
#   2. CLI offline mode (--offline --vds-fixtures): verdict file shape, statuses
#      (match / skipped-embedded-ds / filtered-context / diverge), the
#      parity-final.json `vds_oracle` stamp, missing-sidecar soft exit 0, and the
#      --gate exit code (21 — the reserved oracle gate slot).
#
# Offline, no network: the CLI is exercised only via --offline (canned VDS
# responses per entry id), and the pure core is called directly through the
# ENV-guarded require (same pattern as test-verify-anchors.rb).
#
# Usage: ruby scripts/test-vds-oracle.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

ENV['VDS_ORACLE_CLI'] = nil
require_relative 'vds-oracle' # loads VdsOracle (CLI guarded out)

SCRIPT = File.join(__dir__, 'vds-oracle.rb')

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---------------------------------------------------------------------------
puts '-- pure core: formula preflight --'
ok(!VdsOracle.preflight('WINDOW_MEDIAN(SUM([Sales]))', {})['ok'],
   'WINDOW_MEDIAN → skipped-unsupported (VDS cannot execute it)')
ok(!VdsOracle.preflight('SIZE()', {})['ok'], 'SIZE() → skipped-unsupported')
ok(!VdsOracle.preflight('SUM([Sales]) * [Parameters].[Factor]', {})['ok'],
   '[Parameters].[X] reference → skipped (no parameter binding in VDS)')
pf = VdsOracle.preflight('RANK([% of total])',
                         '% of total' => 'SUM([Profit]) / TOTAL(SUM([Profit]))')
ok(pf['ok'] && pf['formula'] == 'RANK((SUM([Profit]) / TOTAL(SUM([Profit]))))',
   'workbook-local calc reference inlined ONE level (VDS only knows published fields)')
ok(pf['inlined'] == true, 'inlining is flagged so the check note can record it')
deep = VdsOracle.preflight('RUNNING_SUM([a])', 'a' => '[b] + 1', 'b' => 'SUM([x])')
ok(!deep['ok'] && deep['reason'].include?('b'),
   'calc refs nested deeper than one level → skipped, naming the leftover ref')
plain = VdsOracle.preflight('RUNNING_SUM(SUM([Sales]))', {})
ok(plain['ok'] && plain['formula'] == 'RUNNING_SUM(SUM([Sales]))' && plain['inlined'] == false,
   'plain published-field formula passes through untouched')

# ---------------------------------------------------------------------------
puts '-- pure core: VDS query construction (live-verified shapes) --'
e_run = { 'id' => 'wc-1', 'element_id' => 'el-run', 'element_name' => 'Running Sales by Category',
          'column_id' => 'y0-el-run', 'column_name' => 'Running Sales', 'calc_name' => 'Running Sales',
          'tableau_formula' => 'RUNNING_SUM(SUM([Sales]))', 'mode' => 'inline',
          'datasource_caption' => 'Superstore Datasource',
          'dims' => [{ 'caption' => 'Category', 'sort' => 'asc' }],
          'partition_dims' => [], 'date_trunc' => nil, 'filters_present' => false }
q, caps = VdsOracle.build_query([e_run], 'wc-1' => 'RUNNING_SUM(SUM([Sales]))')
ok(q['fields'][0] == { 'fieldCaption' => 'Category', 'sortDirection' => 'ASC', 'sortPriority' => 1 },
   'RUNNING_SUM: dim field carries sortDirection ASC + sortPriority (accumulation order)')
ok(q['fields'][1] == { 'fieldCaption' => 'Running Sales',
                       'calculation' => 'RUNNING_SUM(SUM([Sales]))',
                       'tableCalculation' => { 'tableCalcType' => 'CUSTOM',
                                               'dimensions' => [{ 'fieldCaption' => 'Category' }] } },
   'RUNNING_SUM: exact live-verified tableCalculation spec (CUSTOM + addressing dims)')
ok(caps == { 'wc-1' => 'Running Sales' }, 'entry id → response field caption map')

e_rank = e_run.merge('id' => 'wc-2', 'element_id' => 'el-rank', 'column_id' => 'y0-el-rank',
                     'calc_name' => 'Sales Rank', 'column_name' => 'Sales Rank',
                     'tableau_formula' => 'RANK(SUM([Sales]))')
q2, = VdsOracle.build_query([e_rank], 'wc-2' => 'RANK(SUM([Sales]))')
ok(q2['fields'][1] == { 'fieldCaption' => 'Sales Rank',
                        'calculation' => 'RANK(SUM([Sales]))',
                        'tableCalculation' => { 'tableCalcType' => 'CUSTOM',
                                                'dimensions' => [{ 'fieldCaption' => 'Category' }] } },
   'RANK: original formula verbatim under CUSTOM (Tableau RANK defaults DESC server-side)')

e_win = { 'id' => 'wc-3', 'element_id' => 'el-win', 'element_name' => 'Window Max by Month',
          'column_id' => 'y0-el-win', 'column_name' => 'Window Max Sales', 'calc_name' => 'Window Max Sales',
          'tableau_formula' => 'WINDOW_MAX(SUM([Sales]))', 'mode' => 'inline',
          'datasource_caption' => 'Superstore Datasource',
          'dims' => [{ 'caption' => 'Order Date', 'sort' => 'asc' }],
          'partition_dims' => ['Region'], 'date_trunc' => 'month', 'filters_present' => false }
q3, = VdsOracle.build_query([e_win], 'wc-3' => 'WINDOW_MAX(SUM([Sales]))')
ok(q3['fields'][0] == { 'fieldCaption' => 'Order Date', 'function' => 'TRUNC_MONTH',
                        'fieldAlias' => 'Order Date', 'sortDirection' => 'ASC', 'sortPriority' => 1 },
   'WINDOW_MAX: date dim carries TRUNC_MONTH (DateTrunc grain, not the MONTH date-part)')
ok(q3['fields'][1] == { 'fieldCaption' => 'Region' },
   'partition dim is a plain query dim (no sort, no function)')
ok(q3['fields'][2]['tableCalculation'] ==
   { 'tableCalcType' => 'CUSTOM',
     'dimensions' => [{ 'fieldCaption' => 'Order Date', 'function' => 'TRUNC_MONTH' }] },
   'partition dim EXCLUDED from tableCalculation.dimensions (live-verified: unlisted dims = partition)')

# Batching: two calcs on one chart share ONE query (VDS rate cap: 100/hr/Creator).
qb, capsb = VdsOracle.build_query([e_run, e_run.merge('id' => 'wc-1b', 'calc_name' => 'Pct of Total',
                                                      'tableau_formula' => 'SUM([Sales])/TOTAL(SUM([Sales]))')],
                                  'wc-1' => 'RUNNING_SUM(SUM([Sales]))',
                                  'wc-1b' => 'SUM([Sales])/TOTAL(SUM([Sales]))')
ok(qb['fields'].length == 3 && capsb.keys.sort == %w[wc-1 wc-1b],
   'all of one chart\'s calcs batch into ONE query (dims + N calc fields)')

# ---------------------------------------------------------------------------
puts '-- pure core: value comparison --'
CMP = { tolerance: 1e-6, near_tol: 0.01, max_unjoined_frac: 0.1 }.freeze
vds_run = [{ 'Category' => 'Furniture', 'Running Sales' => 100.0 },
           { 'Category' => 'Office Supplies', 'Running Sales' => 250.0 },
           { 'Category' => 'Technology', 'Running Sales' => 400.0 }]
cols_run = %w[x-el-run y0-el-run]
sig_ok = [['Furniture', 100.0], ['Office Supplies', 250.0], ['Technology', 400.0000001]]
r = VdsOracle.compare(e_run, vds_run, 'Running Sales', ['Category'], sig_ok, cols_run, **CMP)
ok(r['status'] == 'match' && r['n_joined'] == 3 && r['n_unjoined'] == 0,
   'values within tolerance → match (float noise ignored)')
sig_near = [['Furniture', 100.0], ['Office Supplies', 250.0], ['Technology', 401.0]]
r = VdsOracle.compare(e_run, vds_run, 'Running Sales', ['Category'], sig_near, cols_run, **CMP)
ok(r['status'] == 'near' && r['max_rel_diff'] > 1e-6 && r['max_rel_diff'] <= 0.01,
   'rel diff within near-tol → near (format/rounding noise)')
sig_bad = [['Furniture', 100.0], ['Office Supplies', 250.0], ['Technology', 500.0]]
r = VdsOracle.compare(e_run, vds_run, 'Running Sales', ['Category'], sig_bad, cols_run, **CMP)
ok(r['status'] == 'diverge' && r['worst_row'] == { 'dims' => ['technology'],
                                                   'tableau_value' => 400.0, 'sigma_value' => 500.0 },
   'beyond near-tol → diverge, worst_row names the offending tuple')
ok(r['tableau_value'] == 400.0 && r['sigma_value'] == 500.0,
   'check carries top-level tableau_value/sigma_value from the worst row')

vds_rank = [{ 'Category' => 'Furniture', 'Sales Rank' => 2.0 },
            { 'Category' => 'Office Supplies', 'Sales Rank' => 3.0 },
            { 'Category' => 'Technology', 'Sales Rank' => 1.0 }]
r = VdsOracle.compare(e_rank, vds_rank, 'Sales Rank', ['Category'],
                      [['Furniture', 2], ['Office Supplies', 3], ['Technology', 1]],
                      %w[x-el-rank y0-el-rank], **CMP)
ok(r['status'] == 'match', 'RANK compares as integers (2.0 == 2 exact)')
r = VdsOracle.compare(e_rank, vds_rank, 'Sales Rank', ['Category'],
                      [['Furniture', 3], ['Office Supplies', 2], ['Technology', 1]],
                      %w[x-el-rank y0-el-rank], **CMP)
ok(r['status'] == 'diverge', 'swapped ranks → diverge (no tolerance for rank values)')

e_date = e_run.merge('column_id' => 'y0-el-d', 'dims' => [{ 'caption' => 'Order Date' }])
r = VdsOracle.compare(e_date, [{ 'Order Date' => '2022-11-01T00:00:00', 'RS' => 10.0 }],
                      'RS', ['Order Date'], [['2022-11-01', 10.0]], %w[x-el-d y0-el-d], **CMP)
ok(r['status'] == 'match', "VDS '2022-11-01T00:00:00' joins Sigma '2022-11-01' (ISO date prefix)")
r = VdsOracle.compare(e_date, [{ 'Order Date' => '2022-11-01T00:00:00', 'RS' => 10.0 }],
                      'RS', ['Order Date'], [['11/1/2022', 10.0]], %w[x-el-d y0-el-d], **CMP)
ok(r['status'] == 'match', 'US-format Sigma date joins the same ISO tuple')

sig_extra = sig_ok + [['Uncategorized', 999.0]]
r = VdsOracle.compare(e_run, vds_run, 'Running Sales', ['Category'], sig_extra, cols_run, **CMP)
ok(r['status'] == 'diverge' && r['n_unjoined'] == 1,
   'unjoined fraction beyond --max-unjoined-frac → diverge with unjoined accounting')
r = VdsOracle.compare(e_run, vds_run, 'Running Sales', ['Category'], sig_extra, cols_run,
                      tolerance: 1e-6, near_tol: 0.01, max_unjoined_frac: 0.5)
ok(r['status'] == 'match' && r['n_unjoined'] == 1,
   'unjoined rows under the threshold are reported but do not fail (VDS drops NULL-key rows)')
r = VdsOracle.compare(e_run.merge('column_id' => 'y9-not-there'), vds_run, 'Running Sales',
                      ['Category'], sig_ok, cols_run, **CMP)
ok(r['status'] == 'skipped-no-actuals', 'plan column id missing from sigma_columns → skipped-no-actuals')

puts '-- pure core: filtered-context downgrade --'
c = VdsOracle.apply_filter_context({ 'status' => 'diverge', 'note' => nil },
                                   'filters_present' => true)
ok(c['status'] == 'filtered-context' && c['note'].include?('advisory'),
   'mismatch on a filtered chart downgrades to filtered-context (advisory)')
c = VdsOracle.apply_filter_context({ 'status' => 'diverge' }, 'filters_present' => false)
ok(c['status'] == 'diverge', 'unfiltered mismatch stays diverge (the loud signal)')
c = VdsOracle.apply_filter_context({ 'status' => 'match' }, 'filters_present' => true)
ok(c['status'] == 'match', 'a match on a filtered chart is not downgraded')

# ---------------------------------------------------------------------------
puts '-- CLI offline mode --'
LUID = '0f0e0d0c-0b0a-4900-8807-060504030201'

def entry(id, el, name, calc, formula, extra = {})
  { 'id' => id, 'worksheet' => name, 'dashboard' => 'Dash', 'element_id' => el,
    'element_name' => name, 'column_id' => "y0-#{el}", 'column_name' => calc,
    'calc_name' => calc, 'tableau_formula' => formula, 'sigma_formula' => 'x',
    'mode' => 'inline', 'datasource_caption' => 'Superstore Datasource',
    'dims' => [{ 'caption' => 'Category', 'sort' => 'asc' }], 'partition_dims' => [],
    'date_trunc' => nil, 'filters_present' => false, 'translator_note' => nil }.merge(extra)
end

def write_workdir(dir, entries, fixtures, plan_charts, actuals)
  File.write(File.join(dir, 'window-calcs.json'),
             JSON.pretty_generate('version' => 1, 'generated_at' => '2026-07-11T00:00:00Z',
                                  'entries' => entries))
  File.write(File.join(dir, 'pds.json'),
             JSON.pretty_generate([{ 'caption' => 'Superstore Datasource',
                                     'pdsName' => 'Superstore Datasource', 'pdsLuid' => LUID }]))
  File.write(File.join(dir, 'landing-manifest.json'),
             JSON.pretty_generate([{ 'slug' => 'wb', 'datasource' => 'federated.0aa6xvz08571t41g7lqve0',
                                     'caption' => 'Embedded Extract', 'sf_table' => 'DB.S.T' }]))
  File.write(File.join(dir, 'parity-plan.json'),
             JSON.pretty_generate('extract' => false, 'charts' => plan_charts))
  File.write(File.join(dir, 'parity-actuals.json'), JSON.pretty_generate(actuals))
  File.write(File.join(dir, 'intake.json'), JSON.pretty_generate('input_mode' => 'both'))
  fdir = File.join(dir, 'fixtures')
  Dir.mkdir(fdir)
  fixtures.each { |id, resp| File.write(File.join(fdir, "#{id}.json"), JSON.pretty_generate(resp)) }
  fdir
end

def run_cli(dir, fdir, *extra)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--offline', '--vds-fixtures', fdir, *extra)
end

plan_a = [{ 'chart' => 'Running Sales by Category', 'sigma_element_id' => 'el-run',
            'sigma_kind' => 'bar', 'sigma_columns' => %w[x-el-run y0-el-run] },
          { 'chart' => 'Window Max by Category', 'sigma_element_id' => 'el-filt',
            'sigma_kind' => 'bar', 'sigma_columns' => %w[x-el-filt y0-el-filt] }]
actuals_a = { 'Running Sales by Category' => [['Furniture', 100.0], ['Office Supplies', 250.0], ['Technology', 400.0]],
              'Window Max by Category' => [['Furniture', 400.0], ['Office Supplies', 400.0], ['Technology', 400.0]] }
entries_a = [
  entry('wc-1', 'el-run', 'Running Sales by Category', 'Running Sales', 'RUNNING_SUM(SUM([Sales]))'),
  entry('wc-2', 'el-emb', 'Embedded Chart', 'Running X', 'RUNNING_SUM(SUM([X]))',
        'datasource_caption' => 'Embedded Extract'),
  entry('wc-3', 'el-filt', 'Window Max by Category', 'Window Max', 'WINDOW_MAX(SUM([Sales]))',
        'filters_present' => true)
]
fixtures_a = {
  'wc-1' => { 'data' => [{ 'Category' => 'Furniture', 'Running Sales' => 100.0 },
                         { 'Category' => 'Office Supplies', 'Running Sales' => 250.0 },
                         { 'Category' => 'Technology', 'Running Sales' => 400.0 }] },
  'wc-3' => { 'data' => [{ 'Category' => 'Furniture', 'Window Max' => 999.0 },
                         { 'Category' => 'Office Supplies', 'Window Max' => 999.0 },
                         { 'Category' => 'Technology', 'Window Max' => 999.0 }] }
}

Dir.mktmpdir do |dir|
  fdir = write_workdir(dir, entries_a, fixtures_a, plan_a, actuals_a)
  File.write(File.join(dir, 'parity-final.json'),
             JSON.pretty_generate('status' => 'PASS', 'charts_total' => 2, 'charts_pass' => 2))
  out, err, st = run_cli(dir, fdir)
  ok(st.exitstatus.zero?, "advisory run exits 0 even with a downgraded mismatch (got #{st.exitstatus})")
  doc = JSON.parse(File.read(File.join(dir, 'vds-oracle.json')))
  ok(doc['version'] == 1 && doc['advisory'] == true, 'vds-oracle.json carries version + advisory flag')
  ok(doc['datasources'] == { 'Superstore Datasource' => LUID, 'Embedded Extract' => nil },
     'datasources map records resolved luid + nil for the embedded extract')
  by_id = doc['checks'].each_with_object({}) { |ch, h| h[ch['id']] = ch }
  ok(by_id['wc-1'] && by_id['wc-1']['status'] == 'match', 'published-DS calc verified → match')
  ok(by_id['wc-1']['calc'] == 'Running Sales' && by_id['wc-1']['dims'] == ['Category'] &&
     by_id['wc-1']['tableau_value'].is_a?(Float) && by_id['wc-1']['sigma_value'].is_a?(Float),
     'check carries the contract keys (calc/dims/tableau_value/sigma_value/status)')
  ok(by_id['wc-2'] && by_id['wc-2']['status'] == 'skipped-embedded-ds' &&
     by_id['wc-2']['note'].include?('published datasources only'),
     'embedded/federated datasource → clean skipped-embedded-ds (never an error)')
  ok(by_id['wc-3'] && by_id['wc-3']['status'] == 'filtered-context',
     'mismatch on a filtered chart → filtered-context (advisory downgrade)')
  s = doc['summary']
  ok(s['checked'] == 3 && s['match'] == 1 && s['filtered'] == 1 && s['skipped'] == 1 &&
     s['diverge'] == 0 && s['queries_issued'] == 2 && s['pass'] == true,
     'summary counts checked/match/filtered/skipped/queries and passes with 0 diverges')
  pf2 = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  ok(pf2['vds_oracle'].is_a?(Hash) && pf2['vds_oracle']['checked'] == 3 &&
     pf2['vds_oracle']['pass'] == true && pf2['vds_oracle']['advisory'] == true,
     'vds_oracle summary stamped into parity-final.json (verify-anchors pattern)')
  ok(err.include?('vds-oracle (advisory)'), 'stderr carries the one-line advisory summary')
  ok(out.include?('MATCH') && out.include?('FILTERED'), 'per-check lines printed')

  # --calc filter narrows the run
  out2, _err2, st2 = run_cli(dir, fdir, '--calc', 'Running Sales')
  doc2 = JSON.parse(File.read(File.join(dir, 'vds-oracle.json')))
  ok(st2.exitstatus.zero? && doc2['summary']['checked'] == 1 && out2.include?('wc-1'),
     '--calc filter verifies only the matching calc')
end

puts '-- CLI: gate exit code --'
plan_b = [{ 'chart' => 'Sales Rank by Category', 'sigma_element_id' => 'el-rank',
            'sigma_kind' => 'bar', 'sigma_columns' => %w[x-el-rank y0-el-rank] }]
actuals_b = { 'Sales Rank by Category' => [['Furniture', 3], ['Office Supplies', 2], ['Technology', 1]] }
entries_b = [entry('wc-9', 'el-rank', 'Sales Rank by Category', 'Sales Rank', 'RANK(SUM([Sales]))')]
fixtures_b = { 'wc-9' => { 'data' => [{ 'Category' => 'Furniture', 'Sales Rank' => 2.0 },
                                      { 'Category' => 'Office Supplies', 'Sales Rank' => 3.0 },
                                      { 'Category' => 'Technology', 'Sales Rank' => 1.0 }] } }
Dir.mktmpdir do |dir|
  fdir = write_workdir(dir, entries_b, fixtures_b, plan_b, actuals_b)
  _out, err, st = run_cli(dir, fdir)
  ok(st.exitstatus.zero?, "unfiltered diverge WITHOUT --gate → advisory exit 0 (got #{st.exitstatus})")
  ok(err.include?('ADVISORY'), 'advisory run announces the diverge on stderr')
  doc = JSON.parse(File.read(File.join(dir, 'vds-oracle.json')))
  ok(doc['checks'][0]['status'] == 'diverge' && doc['summary']['pass'] == false,
     'diverge recorded in the verdict; summary.pass false')
  _out, err, st = run_cli(dir, fdir, '--gate')
  ok(st.exitstatus == 21, "diverge WITH --gate → exit 21, the reserved gate slot (got #{st.exitstatus})")
  ok(err.include?('GATE'), 'gate failure names itself on stderr')
  doc = JSON.parse(File.read(File.join(dir, 'vds-oracle.json')))
  ok(doc['advisory'] == false, '--gate run records advisory: false')
end

puts '-- CLI: missing / empty sidecar soft exit --'
Dir.mktmpdir do |dir|
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--offline')
  ok(st.exitstatus.zero?, "missing window-calcs.json → exit 0, never blocks old workdirs (got #{st.exitstatus})")
  ok(err.include?('nothing to verify'), 'soft exit says nothing to verify')
  doc = JSON.parse(File.read(File.join(dir, 'vds-oracle.json')))
  ok(doc['summary']['checked'] == 0 && doc['summary']['pass'] == true &&
     doc['note'].to_s.include?('no window-calc sidecar'),
     'verdict written with checked 0 + the builder-predates-sidecar note')
end
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'window-calcs.json'),
             JSON.pretty_generate('version' => 1, 'entries' => []))
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--offline')
  ok(st.exitstatus.zero? && err.include?('nothing to verify'),
     'empty entries[] (builder ran, no window calcs) → soft exit 0')
end
Dir.mktmpdir do |dir|
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT)
  ok(st.exitstatus == 2 && err.include?('--workdir'), 'no --workdir → usage exit 2')
end

puts
if $fails.empty?
  puts 'ALL PASS — vds-oracle core + offline CLI'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
