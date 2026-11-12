#!/usr/bin/env ruby
# frozen_string_literal: true

# Live-proof regression (PR #940 re-proof): on a virtual-connection workbook
# whose db/schema was INFERRED (no --db/--schema), the --reuse-dm/--wb-spec
# re-entry derived join-plan.json with right_table
#   "<vc-table-uuid>.CUSTOMER_DIM (DB_A.CUSTOMER_DIM)"
# (no db/schema on the fast path), and the finalize join probe refused all 7
# entries. The probe target must be the DB.SCHEMA.TABLE the data model reads.

$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'json'
require 'join_plan'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

U_FACT = 'd2633ac0-4c26-4cc1-b9e7-000000000001'
U_DIM = 'c91c16a6-66d6-4232-b140-000000000002'
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='FACT_A (DB_A.FACT_A)+ (New Virtual Connection)' name='federated.vc1'>
        <connection class='federated'>
          <named-connections>
            <named-connection caption='New Virtual Connection' name='publishedConnection.x'>
              <connection class='publishedConnection' resourceName='New Virtual Connection' />
            </named-connection>
          </named-connections>
          <relation join='left' type='join'>
            <clause type='join'>
              <expression op='='>
                <expression op='[FACT_A (DB_A.FACT_A)].[CUSTOMER_KEY]' />
                <expression op='[DIM_C (DB_A.DIM_C)].[CUSTOMER_KEY]' />
              </expression>
            </clause>
            <relation connection='publishedConnection.x' name='FACT_A (DB_A.FACT_A)' table='[#{U_FACT}].[FACT_A (DB_A.FACT_A)]' type='table' />
            <relation connection='publishedConnection.x' name='DIM_C (DB_A.DIM_C)' table='[#{U_DIM}].[DIM_C (DB_A.DIM_C)]' type='table' />
          </relation>
        </connection>
      </datasource>
    </datasources>
  </workbook>
XML

def dm(paths)
  { 'pages' => [{ 'elements' => paths.each_with_index.map do |pth, i|
    { 'id' => "e#{i}", 'name' => pth.last, 'source' => { 'kind' => 'warehouse-table', 'path' => pth },
      'columns' => [{ 'id' => "c#{i}", 'formula' => "[#{pth.last}/Customer Key]", 'name' => 'CUSTOMER_KEY' }] }
  end }] }
end

puts 'fast-path shape: no db/schema, DM reads DB_A.SCHEMA_A.*'
entries = JoinPlan.derive(dm([%w[DB_A SCHEMA_A FACT_A], %w[DB_A SCHEMA_A DIM_C]]), TWB)
j = entries.find { |e| e['right'].to_s.start_with?('DIM_C') }
ok(j, "federated join recorded (#{entries.map { |e| e['right'] }.inspect})")
ok(j && j['right_table'] == 'DB_A.SCHEMA_A.DIM_C', "right_table is the DM's warehouse path (got #{j && j['right_table'].inspect})")
ok(j && j['right_table_via'] == 'data-model warehouse-table path', 'provenance recorded')
ok(j && j['right_table_source'].to_s.include?(U_DIM), 'the VC-relation form it replaced is kept for audit')

puts 'with db/schema known, the VC label path still wins (unchanged)'
entries = JoinPlan.derive(dm([%w[DB_A SCHEMA_A FACT_A], %w[DB_A SCHEMA_A DIM_C]]), TWB, db: 'DB_A', schema: 'SCHEMA_A')
j = entries.find { |e| e['right'].to_s.start_with?('DIM_C') }
ok(j && j['right_table'] == 'DB_A.SCHEMA_A.DIM_C' && j['right_table_via'].nil?, "vc_physical_fqn path untouched (#{j && j.slice('right_table', 'right_table_via').inspect})")

puts 'ambiguous DM match leaves the entry for the gate'
entries = JoinPlan.derive(dm([%w[DB_A SCHEMA_A FACT_A], %w[DB_A SCHEMA_A DIM_C], %w[DB_A SCHEMA_B DIM_C]]), TWB)
j = entries.find { |e| e['right'].to_s.start_with?('DIM_C') }
ok(j && !JoinPlan.warehouse_fqn?(j['right_table']), "two DIM_C tables in the DM -> not guessed (got #{j && j['right_table'].inspect})")

ok(JoinPlan.warehouse_fqn?('DB.S.T') && !JoinPlan.warehouse_fqn?("#{U_DIM}.T (DB.T)") && !JoinPlan.warehouse_fqn?('S.T'),
   'warehouse_fqn? accepts only legal 3-part paths')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
