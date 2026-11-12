#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for lib/pbi_name_sanitize.rb (F13: "/" in column/measure names).
# Run: ruby scripts/test-pbi-name-sanitize.rb
require 'json'
require_relative 'lib/pbi_name_sanitize'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

S = "∕"

def tmsl
  {
    'model' => {
      'tables' => [
        { 'name' => 'Sales',
          'columns' => [
            { 'name' => 'Amount', 'dataType' => 'double', 'sourceColumn' => 'AMOUNT' },
            { 'name' => 'Ship/Bill Flag', 'dataType' => 'string' },
            { 'name' => 'Unit Cost/Price', 'dataType' => 'double', 'sourceColumn' => 'UCP', 'sortByColumn' => 'Ship/Bill Flag' },
            { 'name' => 'Margin/Unit', 'type' => 'calculated', 'expression' => "[Amount] / [Unit Cost/Price]" }
          ],
          'measures' => [
            { 'name' => 'Total', 'expression' => 'SUM(Sales[Amount])' },
            { 'name' => 'Growth A/B',
              'expression' => ["DIVIDE([Total], CALCULATE([Total], X))", "-- note about [Growth A/B] in a comment",
                               'VAR s = "keep [Ship/Bill Flag] in a string"', 'RETURN SUM(Sales[Unit Cost/Price]) / SUM(\'Sales\'[Ship/Bill Flag]) + [Growth A/B]'] },
            { 'name' => 'Ratio', 'expression' => 'DIVIDE(1, 2) + [Growth A/B]',
              'formatStringDefinition' => { 'expression' => '"0.0" & [Margin/Unit]' } }
          ],
          'hierarchies' => [{ 'name' => 'H', 'levels' => [{ 'name' => 'L1', 'column' => 'Ship/Bill Flag' }] }],
          'partitions' => [{ 'name' => 'p', 'source' => { 'type' => 'm',
                                                          'expression' => 'let Source = Foo, T = Table.SelectRows(Source, each [Ship/Bill Flag] = 1) in T' } }] },
        { 'name' => 'Customer',
          'columns' => [{ 'name' => 'Id' }, { 'name' => 'Region/Country' }],
          'partitions' => [{ 'name' => 'c', 'source' => { 'type' => 'calculated',
                                                          'expression' => 'SELECTCOLUMNS(Sales, "k", [Ship/Bill Flag])' } }] },
        { 'name' => 'A/B Dim', 'columns' => [{ 'name' => 'K' }] }
      ],
      'relationships' => [
        { 'name' => 'r1', 'fromTable' => 'Sales', 'fromColumn' => 'Ship/Bill Flag', 'toTable' => 'Customer', 'toColumn' => 'Region/Country' },
        { 'name' => 'r2', 'fromTable' => 'Sales', 'fromColumn' => 'Amount', 'toTable' => 'Customer', 'toColumn' => 'Id' }
      ],
      'roles' => [{ 'name' => 'R', 'tablePermissions' => [{ 'name' => 'Customer', 'filterExpression' => '[Region/Country] = "x/y"' }] }],
      'perspectives' => [{ 'name' => 'P', 'tables' => [{ 'name' => 'Sales', 'columns' => [{ 'name' => 'Ship/Bill Flag' }], 'measures' => [{ 'name' => 'Growth A/B' }] }] }]
    }
  }
end

puts 'sanitize TMSL'
orig = tmsl
out, _sig, rep = PbiNameSanitize.sanitize(orig)
check(orig == tmsl, 'sanitize does not mutate its input')
m = out['model']
sales = m['tables'][0]
check(sales['columns'].map { |c| c['name'] } == ['Amount', "Ship#{S}Bill Flag", "Unit Cost#{S}Price", "Margin#{S}Unit"], 'column names renamed to U+2215')
check(sales['measures'].map { |c| c['name'] } == ['Total', "Growth A#{S}B", 'Ratio'], 'measure names renamed')
check(sales['columns'][0]['sourceColumn'] == 'AMOUNT', 'explicit sourceColumn untouched')
check(sales['columns'][2]['sourceColumn'] == 'UCP', 'explicit sourceColumn untouched on renamed column')
check(sales['columns'][1]['sourceColumn'] == 'Ship/Bill Flag', 'renamed physical column without sourceColumn is pinned to its old name')
check(!sales['columns'][3].key?('sourceColumn'), 'renamed calculated column is NOT given a sourceColumn')
check(rep['source_columns_pinned'] == ['Sales.Ship/Bill Flag', 'Customer.Region/Country'], 'pinned sourceColumns recorded')
check(sales['columns'][2]['sortByColumn'] == "Ship#{S}Bill Flag", 'sortByColumn follows the rename')
check(sales['columns'][3]['expression'] == "[Amount] / [Unit Cost#{S}Price]", 'calculated column DAX bracket renamed, division slash kept')
mx = sales['measures'][1]['expression']
check(mx[0] == 'DIVIDE([Total], CALCULATE([Total], X))', 'unrelated DAX line untouched')
check(mx[1] == '-- note about [Growth A/B] in a comment', 'DAX line comment untouched')
check(mx[2] == 'VAR s = "keep [Ship/Bill Flag] in a string"', 'DAX string literal untouched')
check(mx[3] == "RETURN SUM(Sales[Unit Cost#{S}Price]) / SUM('Sales'[Ship#{S}Bill Flag]) + [Growth A#{S}B]", 'qualified + quoted-table refs renamed')
check(mx.is_a?(Array) && mx.length == 4, 'array-valued expression stays array-valued')
check(sales['measures'][2]['formatStringDefinition']['expression'] == %("0.0" & [Margin#{S}Unit]), 'nested formatStringDefinition expression renamed')
check(sales['hierarchies'][0]['levels'][0]['column'] == "Ship#{S}Bill Flag", 'hierarchy level column renamed')
check(sales['partitions'][0]['source']['expression'].include?('each [Ship/Bill Flag] = 1'), 'M partition text (physical names) untouched')
check(m['tables'][1]['partitions'][0]['source']['expression'] == %(SELECTCOLUMNS(Sales, "k", [Ship#{S}Bill Flag])), 'calculated-table partition DAX renamed')
check(m['tables'][1]['columns'][1]['name'] == "Region#{S}Country", 'second table column renamed')
check(m['relationships'][0]['fromColumn'] == "Ship#{S}Bill Flag" && m['relationships'][0]['toColumn'] == "Region#{S}Country", 'relationship columns renamed')
check(m['relationships'][1]['fromColumn'] == 'Amount', 'untouched relationship left alone')
check(m['roles'][0]['tablePermissions'][0]['filterExpression'] == %([Region#{S}Country] = "x/y"), 'RLS filter expression renamed, literal kept')
check(m['perspectives'][0]['tables'][0]['columns'][0]['name'] == "Ship#{S}Bill Flag", 'perspective member renamed')
check(rep['renames'].length == 5, "5 renames recorded (got #{rep['renames'].length})")
check(rep['relationship_rewrites'] == 2, 'relationship rewrites counted')
check(rep['unsanitized_tables'] == ['A/B Dim'], 'table names containing "/" are recorded, not renamed')
check(m['tables'][2]['name'] == 'A/B Dim', 'table name left as-is')

puts 'bare (unwrapped) TMSL and idempotency'
bare = tmsl['model']
rep2 = PbiNameSanitize.sanitize!(bare)
check(rep2['renames'].length == 5, 'works on a bare model hash')
rep3 = PbiNameSanitize.sanitize!(bare)
check(rep3['renames'].empty? && rep3['dax_rewrites'] == 0, 'second pass is a no-op')

puts 'no slashes -> nothing to do'
clean = { 'model' => { 'tables' => [{ 'name' => 'T', 'columns' => [{ 'name' => 'A' }], 'measures' => [] }] } }
o2, _s, r4 = PbiNameSanitize.sanitize(clean)
check(o2 == clean && r4['renames'].empty?, 'clean model returned unchanged')

puts 'signals'
signals = {
  'pages' => [{ 'visuals' => [
    { 'bindings' => { 'Y' => ['Sales.Growth A/B', 'Sum(Sales.Unit Cost/Price)', 'Sales.Amount'], 'Category' => ['Customer.Region/Country'] },
      'sort' => { 'queryRef' => 'Sales.Growth A/B', 'direction' => 'asc' },
      'field_map' => { 'Sales.Ship/Bill Flag' => 'x' },
      'filters' => [{ 'target' => 'Customer.Region/Country' }],
      'formats' => [{ 'entity' => 'Sales', 'property' => 'Ship/Bill Flag' }, { 'entity' => 'Customer', 'property' => 'Ship/Bill Flag' }],
      'title' => 'Growth A/B by region (Sales.Growth A/B not a ref here? it is textually)' }
  ] }]
}
o3, s3, r5 = PbiNameSanitize.sanitize(tmsl, signals)
v = s3['pages'][0]['visuals'][0]
check(v['bindings']['Y'] == ["Sales.Growth A#{S}B", "Sum(Sales.Unit Cost#{S}Price)", 'Sales.Amount'], 'queryRefs incl. aggregate-wrapped renamed')
check(v['bindings']['Category'] == ["Customer.Region#{S}Country"], 'other-table binding renamed')
check(v['sort']['queryRef'] == "Sales.Growth A#{S}B", 'sort queryRef renamed')
check(v['field_map'].keys == ["Sales.Ship#{S}Bill Flag"], 'hash keys renamed')
check(v['filters'][0]['target'] == "Customer.Region#{S}Country", 'filter target renamed')
check(v['formats'][0]['property'] == "Ship#{S}Bill Flag", '{entity, property} pair renamed when the table owns that column')
check(v['formats'][1]['property'] == 'Ship/Bill Flag', '{entity, property} pair left alone for a table without that column')
check(r5['signals_rewrites'] >= 6, "signals rewrites counted (#{r5['signals_rewrites']})")
check(o3['model']['tables'][0]['columns'][1]['name'] == "Ship#{S}Bill Flag", 'TMSL renamed in the same call')

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "#{FAILS.size} FAILED:"
  FAILS.each { |f| puts "  - #{f}" }
  exit 1
end
