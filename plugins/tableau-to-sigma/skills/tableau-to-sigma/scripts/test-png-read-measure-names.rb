#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan C live regression R2: a Measure Names/Measure Values text table (shelf
# kind pivot-table) whose view CSV carries a 4th colour-encoding header must
# stay a pivot when png-read.json verifies the tile as 'table'. The override
# used to downgrade it to a flat table, which lost the flag colour rules and
# (via the native top-N filter's includeNulls:'never') the NULL-revenue store.
#
# Usage: ruby scripts/test-png-read-measure-names.rb

require 'json'
require_relative 'lib/builder_test_harness'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MMAP = {
  '(?i)^Store Name$'    => { 'id' => 'm-store', 'name' => 'Store Name' },
  '(?i)^Net Revenue$'   => { 'id' => 'm-rev', 'name' => 'Net Revenue' },
  '(?i)^Gross Profit$'  => { 'id' => 'm-gp', 'name' => 'Gross Profit' },
  '(?i)^Order Id$'      => { 'id' => 'm-oid', 'name' => 'Order Id' }
}.freeze

def png_read(kind)
  JSON.dump('verified' => true, 'source_png' => 'views/x.png',
            'tiles' => [{ 'title' => 'Scorecard', 'kind' => kind }],
            'text_elements' => [], 'filter_shelf' => [])
end

def mn_zone
  z = BuilderTestHarness.chart_zone(id: 'z1', caption: 'Scorecard', chart_kind: 'pivot-table', mark_class: 'Automatic',
                                    dim: 'Store Name', measure: 'Net Revenue', dim_on_rows: true)
  z['rows_shelf'] = { 'raw' => '[ds].[none:Store Name:nk]', 'fields' => [
    { 'raw' => '[ds].[none:Store Name:nk]', 'role' => 'dim', 'derivation' => 'none', 'caption' => 'Store Name' }
  ], 'dim_count' => 1, 'measure_count' => 0, 'cont_measure_count' => 0,
                      'has_measure_names' => false, 'has_measure_values' => false }
  z['cols_shelf'] = { 'raw' => '[ds].[:Measure Names]', 'fields' => [{ 'raw' => '[ds].[:Measure Names]', 'role' => 'measure-names' }],
                      'dim_count' => 0, 'measure_count' => 0, 'cont_measure_count' => 0,
                      'has_measure_names' => true, 'has_measure_values' => false }
  z['is_crosstab'] = true
  z['aggregations'] = { '[Store Name]' => 'None', '[Net Revenue]' => 'Sum', '[Margin]' => 'User', '[Low Margin Flag]' => 'User' }
  z['calculations'] = [
    { 'name' => '[Margin]', 'caption' => 'Margin', 'datatype' => 'real', 'role' => 'measure', 'class' => 'tableau',
      'formula' => 'SUM([Gross Profit]) / SUM([Net Revenue])' },
    { 'name' => '[Low Margin Flag]', 'caption' => 'Low Margin Flag', 'datatype' => 'boolean', 'role' => 'measure',
      'class' => 'tableau', 'formula' => 'SUM([Gross Profit]) / SUM([Net Revenue]) < 0.66' }
  ]
  z['measures'] = [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }, { 'column' => '[Margin]', 'derivation' => 'User' }]
  z['channels'] = { 'color' => { 'column' => '[ds].[usr:Low Margin Flag:nk]', 'field' => nil },
                    'text' => { 'column' => '[ds].[Multiple Values]', 'field' => nil } }
  z['series_colors'] = [{ 'member' => 'true', 'color' => '#d1495b' }, { 'member' => 'false', 'color' => '#1b5e20' }]
  z['series_color_field'] = 'Low Margin Flag'
  z['filters'] = [{ 'raw_class' => 'categorical', 'raw_param' => '[ds].[none:Store Name:nk]', 'column_caption' => 'Store Name',
                    'datatype' => 'string', 'is_action' => false, 'kind' => 'list', 'members' => [],
                    'topn' => { 'end' => 'top', 'units' => 'records', 'n' => 15, 'direction' => 'DESC',
                                'order_expr' => 'SUM([Net Revenue])' } }]
  z['measure_names_sort'] = { 'kind' => 'alphabetic' }
  z
end

MN_CSV = "Measure Names,Store Name,Low Margin Flag,Measure Values\n" \
         "Net Revenue,Portland,false,\"17,199.67\"\n" \
         "Net Revenue,Phoenix Outlet,,\n" \
         "Margin,Portland,false,70.0%\n" \
         "Margin,Phoenix Outlet,,\n"

def refs(obj)
  JSON.dump(obj).scan(%r{\[[^\[\]"]*/(Measure Names|Measure Values)\]})
end

puts '== Measure Names/Values pivot survives a png-read table verdict'
res = BuilderTestHarness.run([mn_zone], captions: ['Scorecard'], csvs: { 'Scorecard' => MN_CSV },
                                        files: { 'png-read.json' => png_read('table') }, mmap: MMAP)
el = res[:elements].find { |e| e['name'].to_s =~ /Scorecard/ }
puts res[:log] unless el
ok(!el.nil?, 'Scorecard element built')
if el
  ok(el['kind'] == 'pivot-table', "stays a pivot-table (got #{el['kind'].inspect})")
  ok(refs(el).empty?, "no [.../Measure Names] / [.../Measure Values] refs (got #{refs(el).inspect})")
  cfs = Array(el['conditionalFormats']).select { |c| c['condition'] == 'formula' }
  ok(cfs.size >= 2 && cfs.any? { |c| c['formula'] =~ /Low Margin Flag/ },
     "flag colour conditionalFormats present (#{cfs.size})")
  ok(el.dig('source', 'elementId').to_s.include?('topn-src'), "top-N bridge source kept (#{el.dig('source', 'elementId')})")
  ok(!JSON.dump(el).include?('"includeNulls":"never"') && !JSON.dump(res[:data_elements]).include?('"includeNulls":"never"'),
     'no includeNulls:never member drop')
end
ok(res[:log].include?("OVERRIDES shelf-inferred") == false, 'no downgrade logged')
ok(res[:log] =~ /keeps shelf-inferred 'pivot-table'/, 'log explains why the pivot kind was kept')

puts '== A plain pivot with a png-read table verdict is still overridden'
plain = BuilderTestHarness.chart_zone(id: 'z2', caption: 'Scorecard', chart_kind: 'pivot-table', mark_class: 'Automatic')
res2 = BuilderTestHarness.run([plain], captions: ['Scorecard'],
                                       csvs: { 'Scorecard' => "Region,Net Revenue\nWest,100\n" },
                                       files: { 'png-read.json' => png_read('table') })
el2 = res2[:elements].find { |e| e['name'].to_s =~ /Scorecard/ }
ok(res2[:log].include?("verified kind 'table' OVERRIDES shelf-inferred 'pivot-table'"), 'override still logged for non-Measure-Names tile')
ok(el2 && el2['kind'] == 'table', "plain tile becomes table (got #{el2 && el2['kind'].inspect})")

puts '== A plain 3-column Measure Names/Values export still follows png-read (dissolved by the table path)'
res3 = BuilderTestHarness.run([mn_zone], captions: ['Scorecard'],
                                         csvs: { 'Scorecard' => "Measure Names,Store Name,Measure Values\nNet Revenue,Portland,\"17,199.67\"\n" },
                                         files: { 'png-read.json' => png_read('table') }, mmap: MMAP)
ok(res3[:log].include?("verified kind 'table' OVERRIDES shelf-inferred 'pivot-table'"), '3-column export keeps the png-read override')

puts
if $fails.empty?
  puts 'ALL PASS'
else
  puts "#{$fails.length} FAILURE(S):"
  $fails.each { |f| puts "  - #{f}" }
end
exit($fails.empty? ? 0 : 1)
