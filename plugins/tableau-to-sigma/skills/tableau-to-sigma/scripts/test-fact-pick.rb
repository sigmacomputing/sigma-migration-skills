#!/usr/bin/env ruby
# Regression test for fact-element picking (2026-06-17). Deterministic + offline.
# Guards the date-crosstab regression: a narrow time dimension named "Dim Time"
# (or "Date Dim", "Dim Date") must NEVER be chosen as the fact/master element —
# its name doesn't end in " Dim" so a trailing-only / Dim$/ test let it slip
# through and win max_by, making the workbook master source the wrong element
# ("Dependency not found: 'dim time/...'" on POST).
#
# Part A: MechanicalSpecs.pick_fact excludes "Dim Time" and picks the widest
#         non-dim element (the real fact view).
# Part B: source-guard — both migrate-tableau fact-resolution paths (fresh +
#         reuse) use the leading+trailing dim test and tie-break by column count.
#
# Usage:  ruby scripts/test-fact-pick.rb

require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

puts 'Part A — pick_fact never returns a dim, prefers the widest view'
# A converter-shaped model: dims (incl. the tricky "Dim Time"), a base fact, and
# the wide flattened "Order Fact View" derived element.
cols = ->(n) { Array.new(n) { |i| { 'id' => "c#{i}", 'name' => "c#{i}" } } }
model = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-dimtime', 'name' => 'Dim Time',        'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB DEMO DIM_TIME] },   'columns' => cols.call(8) },
  { 'id' => 'e-custdim', 'name' => 'Customer Dim',    'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB DEMO CUSTOMER_DIM] }, 'columns' => cols.call(18) },
  { 'id' => 'e-ordfact', 'name' => 'Order Fact',      'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB DEMO ORDER_FACT] },   'columns' => cols.call(36) },
  { 'id' => 'e-ofview',  'name' => 'Order Fact View', 'source' => { 'kind' => 'table', 'elementId' => 'e-ordfact' },                  'columns' => cols.call(94) }
] }] }
fact = MechanicalSpecs.pick_fact(model)
check(fact && fact['name'] == 'Order Fact View', "picks 'Order Fact View' (got #{fact && fact['name'].inspect})", fails)
check(fact && fact['name'] != 'Dim Time', "does NOT pick 'Dim Time'", fails)

# Even with NO derived view, a base fact must beat the narrow time dim.
model2 = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-dimtime', 'name' => 'Dim Time',   'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB DEMO DIM_TIME] }, 'columns' => cols.call(8) },
  { 'id' => 'e-ordfact', 'name' => 'Order Fact', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB DEMO ORDER_FACT] }, 'columns' => cols.call(36) }
] }] }
f2 = MechanicalSpecs.pick_fact(model2)
check(f2 && f2['name'] == 'Order Fact', "base-only: picks 'Order Fact' over 'Dim Time' (got #{f2 && f2['name'].inspect})", fails)

puts 'Part A2 — concatenated dim names (field failure: /(^Dim\\b| Dim$)/i missed DIMSITES)'
# The concatenated shape: dim tables named DIMSITES/DIMDATES (display "Dimsites"
# etc.) have NO word boundary after "Dim", so the old regex left them
# fact-eligible and the widest dim view won. dim_like? must catch them.
%w[Dimsites Dimdates Vdimdates].each do |n|
  check(MechanicalSpecs.dim_like?(n), "dim_like?(#{n.inspect}) is true", fails)
  check(MechanicalSpecs.dim_like?("#{n} View"), "dim_like?(#{"#{n} View".inspect}) is true", fails)
end
check(MechanicalSpecs.dim_like?('Dim Time'), "dim_like?('Dim Time') is true", fails)
check(MechanicalSpecs.dim_like?('Customer Dim'), "dim_like?('Customer Dim') is true", fails)
check(!MechanicalSpecs.dim_like?('Fact Visits'), "dim_like?('Fact Visits') is false", fails)
check(!MechanicalSpecs.dim_like?('Order Fact View'), "dim_like?('Order Fact View') is false", fails)
check(!MechanicalSpecs.dim_like?('Entitlements View'), "dim_like?('Entitlements View') is false (dim test must not eat non-dims)", fails)
model_cat = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-dimdates', 'name' => 'Dimdates View',     'source' => { 'kind' => 'table', 'elementId' => 'x1' }, 'columns' => cols.call(16) },
  { 'id' => 'e-factv',   'name' => 'Fact Visits View', 'source' => { 'kind' => 'table', 'elementId' => 'x2' }, 'columns' => cols.call(12) }
] }] }
fc = MechanicalSpecs.pick_fact(model_cat)
check(fc && fc['name'] == 'Fact Visits View', "concatenated-dim view loses to the fact view despite more columns (got #{fc && fc['name'].inspect})", fails)

puts 'Part B — migrate-tableau fact-resolution guards (both paths)'
mig = File.read(File.join(__dir__, 'migrate-tableau.rb'))
check(mig.scan(/MechanicalSpecs\.dim_like\?/).size >= 2, 'both fresh + reuse paths use the shared dim_like? test (leading+trailing+concatenated)', fails)
check(mig.match?(/max_by \{ \|e\| \(e\['columnLabels'\] \|\| \[\]\)\.size \}/),
      'fact fallback tie-breaks by column count, not list order', fails)
check(mig.include?('prefer_table: prefer_fact_table') || mig.include?('prefer_table: (defined?(prefer_fact_table)'),
      'both pick_fact call sites thread prefer_fact_table', fails)

puts 'Part C — prefer_table overrides column count (multi-extract regression)'
# The Metric Series shape: the UNUSED datasource projects MORE columns (14) than the
# one the charts use (9). Default max_by picks the wide unused one; prefer_table
# must override to the used table.
m3 = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-unused', 'name' => 'Rev2005',    'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB PUBLIC MS_REV2005] },   'columns' => cols.call(14) },
  { 'id' => 'e-used',   'name' => 'Metric Series', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB PUBLIC METRIC_SERIES] }, 'columns' => cols.call(9) }
] }] }
check(MechanicalSpecs.pick_fact(m3)['id'] == 'e-unused', 'default (no hint): max_by columns picks the WIDE unused table', fails)
check(MechanicalSpecs.pick_fact(m3, prefer_table: 'METRIC_SERIES')['id'] == 'e-used',
      'prefer_table picks the USED (narrower) table, overriding count', fails)
check(MechanicalSpecs.pick_fact(m3, prefer_table: 'NOPE_MISSING')['id'] == 'e-unused',
      'unmatched prefer_table falls through to the default heuristic', fails)

puts 'Part D — dominant_fact_table (worksheet deps → caption → manifest → sf_table)'
require 'json'
require 'tmpdir'
TWB = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='Parameters' caption='Parameters'/>
    <datasource name='federated.aaa' caption='1. Metric Series Extract'>
      <connection class='federated'><named-connections><named-connection>
        <connection class='hyper' dbname='Data/dataengine_a.hyper'/>
      </named-connection></named-connections></connection>
    </datasource>
    <datasource name='federated.bbb' caption='ZQXKPnullREV2005 Extract'>
      <connection class='federated'><named-connections><named-connection>
        <connection class='hyper' dbname='dataengine_b.hyper'/>
      </named-connection></named-connections></connection>
    </datasource>
  </datasources>
  <worksheets>
    #{Array.new(9) { |i| "<worksheet name='w#{i}'><table><view><datasource-dependencies datasource='federated.aaa'/><datasource-dependencies datasource='Parameters'/></view></table></worksheet>" }.join}
  </worksheets></workbook>
XML
MANIFEST = [
  { 'datasource' => 'federated.aaa', 'caption' => '1. Metric Series Extract', 'hyper' => 'dataengine_a.hyper', 'sf_table' => 'DEMO_DB.PUBLIC.METRIC_SERIES', 'columns' => {} },
  { 'datasource' => 'federated.bbb', 'caption' => 'ZQXKPnullREV2005 Extract', 'hyper' => 'dataengine_b.hyper', 'sf_table' => 'DEMO_DB.PUBLIC.MS_REV2005', 'columns' => {} }
]
Dir.mktmpdir do |d|
  mp = File.join(d, 'landing-manifest.json')
  File.write(mp, JSON.generate(MANIFEST))
  got = MechanicalSpecs.dominant_fact_table(TWB, mp)
  check(got == 'METRIC_SERIES', "dominant datasource (9 worksheets) → METRIC_SERIES (got #{got.inspect})", fails)
  # MISLABELED-caption manifest: land-extracts couldn't resolve the caption and
  # labeled entries by the GUID hyper stem. Caption-only matching would fail; the
  # .hyper match must still resolve the dominant datasource to the right table.
  mislabeled = JSON.parse(JSON.generate(MANIFEST))
  mislabeled[0]['caption'] = 'dataengine_a'
  mislabeled[1]['caption'] = 'dataengine_b'
  mp2 = File.join(d, 'mislabeled.json'); File.write(mp2, JSON.generate(mislabeled))
  got2 = MechanicalSpecs.dominant_fact_table(TWB, mp2)
  check(got2 == 'METRIC_SERIES', "mislabeled caption → still resolves via .hyper match (got #{got2.inspect})", fails)
  # single-source manifest → that source's table (re-enabled for single-DS:
  # previously nil, which disabled prefer_table for every single-datasource
  # multi-table workbook and let the width heuristic elect a dim view).
  sp = File.join(d, 'single.json'); File.write(sp, JSON.generate([MANIFEST[0]]))
  got1 = MechanicalSpecs.dominant_fact_table(TWB, sp)
  check(got1 == 'METRIC_SERIES', "single-source manifest → its sf_table (got #{got1.inspect})", fails)
end

puts 'Part E — object_model_fact_table (single-DS noodle hint from <object-graph> degree)'
NOODLE_TWB = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources><datasource name='federated.noodle' caption='Star'>
    <connection class='federated'>
      <relation type='collection'>
        <relation connection='c1' name='DIM_DATES' table='[PUBLIC].[DIM_DATES]' type='table' />
        <relation connection='c1' name='DIM_SITES' table='[PUBLIC].[DIM_SITES]' type='table' />
        <relation connection='c1' name='FACT_VISITS' table='[PUBLIC].[FACT_VISITS]' type='table' />
      </relation>
    </connection>
    <object-graph>
      <relationships>
        <relationship>
          <expression op='='><expression op='[DATE_KEY]'/><expression op='[DATE_KEY]'/></expression>
          <first-end-point object-id='DIM_DATES_AA11' />
          <second-end-point object-id='FACT_VISITS_BB22' />
        </relationship>
        <relationship>
          <expression op='='><expression op='[SITE_KEY]'/><expression op='[SITE_KEY]'/></expression>
          <first-end-point object-id='DIM_SITES_CC33' />
          <second-end-point object-id='FACT_VISITS_BB22' />
        </relationship>
      </relationships>
    </object-graph>
  </datasource></datasources></workbook>
XML
gotN = MechanicalSpecs.object_model_fact_table(NOODLE_TWB)
check(gotN == 'FACT_VISITS', "noodle degree hint elects FACT_VISITS (2 edges vs 1) (got #{gotN.inspect})", fails)
# Tie (one edge, both endpoints degree 1) → nil, never guess.
TIE_TWB = NOODLE_TWB.sub(%r{<relationship>\s*<expression op='='><expression op='\[SITE_KEY\]'/><expression op='\[SITE_KEY\]'/></expression>\s*<first-end-point object-id='DIM_SITES_CC33' />\s*<second-end-point object-id='FACT_VISITS_BB22' />\s*</relationship>}m, '')
check(MechanicalSpecs.object_model_fact_table(TIE_TWB).nil?, 'degree tie → nil (refuse-dont-guess)', fails)
check(MechanicalSpecs.object_model_fact_table('<workbook/>').nil?, 'no object graph → nil', fails)

puts
if fails.empty?
  puts 'OK — fact-pick guards all pass'; exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"; fails.each { |f| warn "  - #{f}" }; exit 1
end
