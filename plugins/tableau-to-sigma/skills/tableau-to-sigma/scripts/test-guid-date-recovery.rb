#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'mechanical-specs'

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

GUID = 'c2ec6b07-897e-39ab-9422-aa895d35a627'

def model(table: 'ORDER_FACT')
  fact = {
    'id' => 'el-fact',
    'kind' => 'table',
    'name' => 'Order Fact',
    'source' => { 'kind' => 'warehouse-table', 'path' => ['DB', 'SCHEMA', table] },
    'columns' => [{ 'id' => 'c-order-id', 'name' => 'Order Id', 'formula' => "[#{table}/Order Id]" }],
    'order' => ['c-order-id']
  }
  derived = {
    'id' => 'el-derived',
    'kind' => 'table',
    'name' => 'Order Fact View',
    'source' => { 'kind' => 'table', 'elementId' => 'el-fact' },
    'columns' => [],
    'order' => []
  }
  { 'pages' => [{ 'id' => 'page-model', 'elements' => [fact, derived] }] }
end

def twb(caption: 'Order Date', format: 'yyyyMMdd', second_owner: false)
  relation = lambda do |name|
    <<~XML
      <relation name='#{name}' table='[#{name}]' type='table'>
        <columns>
          <column datatype='date' date-parse-format='#{format}' name='#{GUID}' />
        </columns>
      </relation>
    XML
  end
  <<~XML
    <workbook>
      <datasource>
        <connection>
          <relation type='collection'>
            #{relation.call('ORDER_FACT')}
            #{second_owner ? relation.call('ORDER_FACT_ALT') : ''}
          </relation>
          <metadata-records>
            <metadata-record class='column'>
              <remote-name>#{GUID}</remote-name>
              <local-name>[#{GUID}]</local-name>
              <parent-name>[ORDER_FACT]</parent-name>
              <local-type>date</local-type>
            </metadata-record>
          </metadata-records>
        </connection>
        <column caption='#{caption} ' datatype='date' name='[#{GUID}]' role='dimension' />
      </datasource>
    </workbook>
  XML
end

def fact(model)
  MechanicalSpecs.all_elements(model).find { |element| element['id'] == 'el-fact' }
end

puts 'Part A — GUID-backed yyyyMMdd field is recovered before phantom filtering'
m = model
catalogs = {
  'ORDER_FACT' => [
    { 'name' => 'ORDER_ID', 'type' => 'NUMBER' },
    { 'name' => 'ORDER_DATE_KEY', 'type' => 'NUMBER' }
  ]
}
result = MechanicalSpecs.recover_guid_backed_date_fields!(
  m, twb, { 'ORDER_FACT' => %w[ORDER_ID ORDER_DATE_KEY] }, catalogs
)
names = fact(m)['columns'].map { |column| column['name'] }
date = fact(m)['columns'].find { |column| column['name'] == 'Order Date' }
check(result[:recovered] == 1, "one field recovered (got #{result.inspect})", fails)
check(names.include?('Order Date Key'), 'verified physical ORDER_DATE_KEY is emitted', fails)
check(date && date['formula'].include?('Date(Left(Text([Order Date Key])'),
      "date-typed Order Date is synthesized from the key (got #{date.inspect})", fails)

fixup = MechanicalSpecs.fixup_dm_spec(
  m, { 'ORDER_FACT' => %w[ORDER_ID ORDER_DATE_KEY] }
)
names_after = fact(m)['columns'].map { |column| column['name'] }
check(fixup[:phantom].zero? && names_after.include?('Order Date Key') && names_after.include?('Order Date'),
      'recovered key/date survive the phantom filter', fails)

puts
puts 'Part B — --column-mapping injects an omitted mapped date field'
mapped = model(table: 'INVOICE_FACT')
mapped_catalog = {
  'INVOICE_FACT' => [
    { 'name' => 'ORDER_ID', 'type' => 'NUMBER' },
    { 'name' => 'INVOICE_DT_INT', 'type' => 'INTEGER' }
  ]
}
mapped_result = MechanicalSpecs.recover_guid_backed_date_fields!(
  mapped,
  twb(caption: 'Invoice Date').gsub('ORDER_FACT', 'INVOICE_FACT'),
  { 'INVOICE_FACT' => %w[ORDER_ID INVOICE_DT_INT] },
  mapped_catalog,
  column_mapping: { 'Invoice Date' => 'INVOICE_DT_INT' }
)
mapped_names = fact(mapped)['columns'].map { |column| column['name'] }
mapped_date = fact(mapped)['columns'].find { |column| column['name'] == 'Invoice Date' }
check(mapped_result[:recovered] == 1, "mapped omitted field recovered (got #{mapped_result.inspect})", fails)
check(mapped_names.include?('Invoice Dt Int'), 'mapped physical column is injected', fails)
check(mapped_date && mapped_date['formula'].include?('[Invoice Dt Int]'),
      'mapped date synthesis references the injected physical column', fails)

puts
puts 'Part C — recovery is idempotent'
before = JSON.generate(mapped)
second = MechanicalSpecs.recover_guid_backed_date_fields!(
  mapped,
  twb(caption: 'Invoice Date').gsub('ORDER_FACT', 'INVOICE_FACT'),
  { 'INVOICE_FACT' => %w[ORDER_ID INVOICE_DT_INT] },
  mapped_catalog,
  column_mapping: { 'Invoice Date' => 'INVOICE_DT_INT' }
)
check(second[:recovered].zero?, "second run reports no recovery (got #{second.inspect})", fails)
check(JSON.generate(mapped) == before, 'second run leaves the model byte-identical', fails)

puts
puts 'Part D — synthesis refuses insufficient or incompatible evidence'
no_format = model
r1 = MechanicalSpecs.recover_guid_backed_date_fields!(
  no_format, twb(format: ''), { 'ORDER_FACT' => %w[ORDER_ID ORDER_DATE_KEY] }, catalogs
)
check(r1[:recovered].zero? && fact(no_format)['columns'].size == 1,
      'missing parse format does not synthesize a date', fails)

ambiguous = model
ambiguous['pages'][0]['elements'].insert(
  1,
  {
    'id' => 'el-alt',
    'kind' => 'table',
    'name' => 'Order Fact Alt',
    'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCHEMA ORDER_FACT_ALT] },
    'columns' => [],
    'order' => []
  }
)
r2 = MechanicalSpecs.recover_guid_backed_date_fields!(
  ambiguous,
  twb(second_owner: true),
  { 'ORDER_FACT' => %w[ORDER_ID ORDER_DATE_KEY],
    'ORDER_FACT_ALT' => %w[ORDER_ID ORDER_DATE_KEY] },
  catalogs.merge('ORDER_FACT_ALT' => catalogs['ORDER_FACT'])
)
check(r2[:recovered].zero? && r2[:messages].any? { |message| message.include?('ambiguous owning table') },
      "ambiguous owner refuses clearly (got #{r2.inspect})", fails)

incompatible = model
bad_catalog = {
  'ORDER_FACT' => [
    { 'name' => 'ORDER_ID', 'type' => 'NUMBER' },
    { 'name' => 'ORDER_DATE_KEY', 'type' => 'BOOLEAN' }
  ]
}
r3 = MechanicalSpecs.recover_guid_backed_date_fields!(
  incompatible,
  twb,
  { 'ORDER_FACT' => %w[ORDER_ID ORDER_DATE_KEY] },
  bad_catalog
)
check(r3[:recovered].zero? && r3[:messages].any? { |message| message.include?('incompatible warehouse type') },
      "incompatible physical type refuses clearly (got #{r3.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — GUID-backed date recovery is evidence-gated, mapped, and idempotent'
  exit 0
else
  puts "FAILURES (#{fails.size}):"
  fails.each { |failure| puts "  - #{failure}" }
  exit 1
end
