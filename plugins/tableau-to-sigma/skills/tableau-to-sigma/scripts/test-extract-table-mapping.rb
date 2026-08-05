#!/usr/bin/env ruby
# Regression test for extract-backed (.twbx) table-mapping threading (2026-07-05).
# Deterministic + offline: drives the VENDORED converter (converter/tableau.mjs)
# through MechanicalSpecs.run_converter on a synthetic extract-shaped .twb — no
# network, no Sigma, no Tableau.
#
# Guards the "Source not found" blocker: a packaged-extract workbook names its
# table after the extract sheet ("Orders$"), which does not match the physical
# warehouse table ("ORDERS"), and the schema override used to be force-uppercased
# ("Tableau Test" -> "TABLEAU TEST"). Both broke the DM POST.
#
#   Part A — run_converter threads `table_mapping` + preserves schema case, and
#            the "$" extract suffix is stripped by default.
#   Part B — a "/"- or "-"-containing column name folds to a resolvable ref
#            (was a type=error / phantom-dropped column).
#   Part C — fixup_dm_spec phantom-drop keeps a separator-mismatch column that
#            exists in the warehouse and drops only a genuine rename.
#   Part D — --column-mapping remaps a genuine rename to its warehouse column
#            (keeping the original caption) instead of dropping it.
#
# Usage:  ruby scripts/test-extract-table-mapping.rb

require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'

HERE = __dir__
VENDORED = File.expand_path('../converter/tableau.mjs', HERE)

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

abort "vendored converter missing: #{VENDORED}" unless File.exist?(VENDORED)

# Synthetic single-table extract-backed .twb: relation table='[Orders$]' with a
# slash-named and a dash-named column (the two separator classes) plus a genuine
# extract-only rename ("State" that the warehouse spells "STATE_PROVINCE").
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8'?>
  <workbook>
    <datasources>
      <datasource caption='Superstore' name='federated.orders'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='hyper' caption='hyper'>
              <connection class='hyper' dbname='x.hyper' schema='Extract'/>
            </named-connection>
          </named-connections>
          <relation connection='hyper' name='Orders' table='[Orders$]' type='table'>
            <columns>
              <column name='Row Id' datatype='integer'/>
              <column name='Region' datatype='string'/>
              <column name='Country/Region' datatype='string'/>
              <column name='Sub-Category' datatype='string'/>
              <column name='State' datatype='string'/>
              <column name='Sales' datatype='real'/>
            </columns>
          </relation>
        </connection>
      </datasource>
    </datasources>
  </workbook>
XML

model = nil
Dir.mktmpdir do |dir|
  twb_path = File.join(dir, 'extract.twb')
  File.write(twb_path, TWB)
  conv = MechanicalSpecs.run_converter(
    twb_path: twb_path, conn: 'conn-1', db: 'DEMO_DB', schema: 'Tableau Test',
    mcp_build: VENDORED, workdir: dir, table_mapping: { 'Orders$' => 'ORDERS' })
  model = conv['model']
end

el = (model['pages'] || []).flat_map { |p| p['elements'] || [] }
     .find { |e| e.dig('source', 'kind') == 'warehouse-table' }
abort 'converter produced no warehouse-table element' unless el

puts 'Part A — table mapping + schema case + $-strip'
check(el.dig('source', 'path') == ['DEMO_DB', 'Tableau Test', 'ORDERS'],
      "path resolves to DEMO_DB.'Tableau Test'.ORDERS (got #{el.dig('source', 'path').inspect})", fails)
formulas = (el['columns'] || []).map { |c| c['formula'] }
check(formulas.all? { |f| f =~ /\A\[ORDERS\// },
      'every base-column formula prefix follows the resolved table name', fails)

puts 'Part B — separator-in-name folding (no type=error / no drop)'
check(formulas.include?('[ORDERS/Country Region]'),
      "'Country/Region' folds to [ORDERS/Country Region] (was a broken nested ref)", fails)
check(formulas.include?('[ORDERS/Sub Category]'),
      "'Sub-Category' folds to [ORDERS/Sub Category] (was dropped as phantom)", fails)

puts 'Part C — fixup phantom-drop: keep separator matches, drop genuine renames'
real_cols = { 'ORDERS' => %w[ROW_ID REGION COUNTRY_REGION SUB_CATEGORY STATE_PROVINCE SALES] }
pf = MechanicalSpecs.fixup_dm_spec(model, real_cols)
kept = (el['columns'] || []).map { |c| c['formula'] }
check(kept.include?('[ORDERS/Country Region]'), 'Country Region KEPT (exists as COUNTRY_REGION)', fails)
check(kept.include?('[ORDERS/Sub Category]'), 'Sub Category KEPT (exists as SUB_CATEGORY)', fails)
check(kept.none? { |f| f == '[ORDERS/State]' }, 'State DROPPED (genuine rename → STATE_PROVINCE)', fails)
check(pf[:phantom].to_i == 1, "exactly 1 phantom column dropped (got #{pf[:phantom]})", fails)

puts 'Part D — --column-mapping remaps a genuine rename (keeps the caption)'
model2 = nil
Dir.mktmpdir do |dir|
  twb_path = File.join(dir, 'extract.twb')
  File.write(twb_path, TWB)
  model2 = MechanicalSpecs.run_converter(
    twb_path: twb_path, conn: 'conn-1', db: 'DEMO_DB', schema: 'Tableau Test',
    mcp_build: VENDORED, workdir: dir, table_mapping: { 'Orders$' => 'ORDERS' })['model']
end
pf2 = MechanicalSpecs.fixup_dm_spec(model2, real_cols, column_mapping: { 'State' => 'STATE_PROVINCE' })
el2 = (model2['pages'] || []).flat_map { |p| p['elements'] || [] }
      .find { |e| e.dig('source', 'kind') == 'warehouse-table' }
state_col = (el2['columns'] || []).find { |c| c['name'] == 'State' }
check(pf2[:remapped].to_i == 1, "exactly 1 column remapped (got #{pf2[:remapped]})", fails)
check(pf2[:phantom].to_i.zero?, "nothing dropped once State is mapped (got phantom #{pf2[:phantom]})", fails)
check(state_col && state_col['formula'] == '[ORDERS/State Province]',
      "State refs [ORDERS/State Province] (→ STATE_PROVINCE) (got #{state_col && state_col['formula']})", fails)
check(state_col && state_col['name'] == 'State', 'original caption "State" preserved as the display name', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
