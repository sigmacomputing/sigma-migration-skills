#!/usr/bin/env ruby
# frozen_string_literal: true

# C1: null members display as Tableau shows them (display-only; verdict
# table-null-blank). No Coalesce, no data change.

require 'json'
require_relative 'lib/null_member_display'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

dt = lambda do |c|
  { 'Region' => 'string', 'Store Key' => 'integer', 'Order Date' => 'date', 'Sales' => 'real' }[c['name']]
end

def table
  { 'id' => 't1', 'kind' => 'table', 'source' => { 'kind' => 'table', 'elementId' => 'm' },
    'columns' => [
      { 'id' => 'c-region', 'name' => 'Region', 'formula' => '[Master/Region]' },
      { 'id' => 'c-key', 'name' => 'Store Key', 'formula' => '[Master/Store Key]' },
      { 'id' => 'c-date', 'name' => 'Order Date', 'formula' => '[Master/Order Date]',
        'format' => { 'kind' => 'datetime', 'formatString' => '%b %Y' } },
      { 'id' => 'c-sales', 'name' => 'Sales', 'formula' => 'Sum([Master/Sales])',
        'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
      { 'id' => 'c-hid', 'name' => 'Hidden', 'formula' => '[Master/Hidden]', 'hidden' => true }
    ],
    'groupings' => [{ 'id' => 'g', 'groupBy' => %w[c-region c-key c-date c-hid], 'calculations' => ['c-sales'],
                      'sort' => [{ 'columnId' => 'c-region', 'direction' => 'ascending' }] }],
    'conditionalFormats' => [{ 'type' => 'single', 'columnIds' => ['c-sales'], 'condition' => 'formula',
                               'formula' => '[Sales] > 0', 'style' => { 'color' => '#00AA00' } }] }
end

t = table
n = NullMemberDisplay.apply!(t, datatype_of: dt)
cols = t['columns'].each_with_object({}) { |c, h| h[c['id']] = c }
cfs = t['conditionalFormats']
null_cf = cfs.find { |r| r['condition'] == 'IsNull' }

ok(null_cf && null_cf['columnIds'] == %w[c-region c-date] &&
   null_cf['style'] == { 'backgroundColor' => '#FFFFFF', 'color' => '#333333',
                         'format' => { 'kind' => 'number', 'displayNullAs' => 'Null' } },
   'text + date dims get ONE IsNull CF with Null label and explicit bg')
ok(!cols['c-region'].key?('format'), 'text dim column format untouched (displayNullAs ignored on text)')
ok(cols['c-date']['format'] == { 'kind' => 'datetime', 'formatString' => '%b %Y' }, 'datetime format never given displayNullAs')
ok(cols['c-key']['format'] == { 'kind' => 'number', 'displayNullAs' => 'Null' }, 'numeric group key displayNullAs Null')
ok(cols['c-sales']['format'] == { 'kind' => 'number', 'formatString' => '$,.0f', 'displayNullAs' => '' },
   'numeric measure displayNullAs blank')
ok(cols['c-sales']['format']['formatString'] == '$,.0f', 'existing format keys preserved')
ok(!cols['c-hid'].key?('format') && !null_cf['columnIds'].include?('c-hid'), 'hidden columns skipped')
ok(cfs.size == 2 && cfs.first['condition'] == 'formula', 'existing conditionalFormats kept')
ok(JSON.generate(t) !~ /Coalesce/, 'no Coalesce formula emitted')
ok(t['columns'].map { |c| c['formula'] } == table['columns'].map { |c| c['formula'] }, 'formulas unchanged')
ok(t['groupings'] == table['groupings'], 'groupings and sort unchanged')
ok(n == 3, "touched count (got #{n})")

NullMemberDisplay.apply!(t, datatype_of: dt)
ok(t['conditionalFormats'].size == 2, 'idempotent on re-run')

# element style bg honoured
t2 = table.merge('style' => { 'backgroundColor' => '#F5F5F5' })
NullMemberDisplay.apply!(t2, datatype_of: dt)
ok(t2['conditionalFormats'].last['style']['backgroundColor'] == '#F5F5F5', 'source table fill used when present')

# pivot: values get blank, headers untouched
pv = { 'id' => 'p1', 'kind' => 'pivot-table',
       'columns' => [{ 'id' => 'r', 'name' => 'Region', 'formula' => '[Master/Region]' },
                     { 'id' => 'k', 'name' => 'Store Key', 'formula' => '[Master/Store Key]' },
                     { 'id' => 'v', 'name' => 'Sales', 'formula' => 'Sum([Master/Sales])' }],
       'values' => ['v'], 'rowsBy' => [{ 'columnId' => 'r' }], 'columnsBy' => [{ 'columnId' => 'k' }] }
NullMemberDisplay.apply!(pv, datatype_of: dt)
ok(pv['columns'][2]['format'] == { 'kind' => 'number', 'displayNullAs' => '' }, 'pivot value displayNullAs blank')
ok(!pv['columns'][0].key?('format') && !pv['columns'][1].key?('format') && !pv.key?('conditionalFormats'),
   'pivot headers untouched')

# charts untouched, data_elements untouched, flat (ungrouped) table untouched
chart = { 'id' => 'b', 'kind' => 'bar-chart', 'columns' => [{ 'id' => 'x', 'name' => 'Region', 'formula' => '[Master/Region]' }] }
flat = { 'id' => 'f', 'kind' => 'table', 'columns' => [{ 'id' => 'x', 'name' => 'Region', 'formula' => '[Master/Region]' }] }
helper = table.merge('hidden' => true)
tree = { 'pages' => [{ 'elements' => [chart, flat] }], 'data_elements' => [table] }
before = JSON.generate(tree)
NullMemberDisplay.apply!(tree, datatype_of: dt)
ok(JSON.generate(tree) == before, 'chart, ungrouped table and data_elements untouched')
h2 = helper
ok(NullMemberDisplay.apply!(h2, datatype_of: dt).zero?, 'hidden helper table untouched')

# merge helper contract
c = { 'format' => { 'kind' => 'datetime' } }
ok(NullMemberDisplay.merge_format!(c, { 'kind' => 'number', 'displayNullAs' => '' }) == false && c['format'] == { 'kind' => 'datetime' },
   'merge_format! refuses incompatible kind, leaves it intact')

src = File.read(File.join(__dir__, 'build-charts-from-signals.rb'), encoding: 'UTF-8')
ok(src.scan('apply_null_member_display!(').size >= 4, 'builder runs the pass at every output write site')

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
