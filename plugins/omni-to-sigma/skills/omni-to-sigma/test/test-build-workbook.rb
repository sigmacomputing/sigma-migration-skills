#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for OmniExport, OmniChartMap, and build-omni-workbook.rb
# (queryPresentationCollectionMemberships, queryJson, miniUuid layout matching,
# Vega-Lite spec mark inference, filterOrder, dm-elements lookup, and LayoutLint/ControlLint).
#
#   ruby test/test-build-workbook.rb

require 'tmpdir'
require 'json'
require 'open3'
require_relative '../scripts/lib/omni_export'
require_relative '../scripts/lib/omni_chart_map'
require_relative '../scripts/lib/layout_lint'
require_relative '../scripts/lib/control_lint'

$failures = 0
def eq(a, b, m)
  if a == b
    puts "  ok: #{m}"
  else
    $failures += 1
    puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}"
  end
end

puts '== OmniChartMap =='
eq(OmniChartMap.kind_for('line'), 'line-chart', 'line -> line-chart')
eq(OmniChartMap.kind_for('columnStacked'), 'bar-chart', 'columnStacked -> bar-chart')
eq(OmniChartMap.kind_for('barLine'), 'combo-chart', 'barLine -> combo-chart')
eq(OmniChartMap.kind_for('donut'), 'pie-chart', 'donut -> pie-chart')
eq(OmniChartMap.kind_for('omni-kpi'), 'kpi-chart', 'omni-kpi -> kpi-chart')
eq(OmniChartMap.kind_for('pivot'), 'pivot-table', 'pivot -> pivot-table')
eq(OmniChartMap.kind_for('markdown'), nil, 'markdown is skipped (nil)')
eq(OmniChartMap.kind_for('omni-ai-summary-markdown'), nil, 'omni-ai-summary-markdown is skipped (nil)')

puts '== OmniExport: real queryPresentationCollectionMemberships + Vega-Lite mark inference =='
real_export = {
  'exportVersion' => '0.1',
  'document' => { 'name' => 'Executive Pulse', 'identifier' => 'exec-pulse' },
  'workbookModel' => {
    'dimensions' => {
      'orders.channel' => { 'label' => 'Sales Channel', 'sql' => '"CHANNEL"' }
    }
  },
  'dashboard' => {
    'queryPresentationCollection' => {
      'filterOrder' => %w[f_channel f_date],
      'filterConfig' => {
        'f_date' => { 'type' => 'date', 'label' => 'Order Date', 'fieldName' => 'orders.created_at' },
        'f_channel' => { 'kind' => 'string', 'name' => 'Channel', 'column_name' => 'orders.channel' }
      },
      'queryPresentationCollectionMemberships' => [
        {
          'queryPresentation' => {
            'id' => 'uuid-tile-1',
            'miniUuid' => 'mini-1',
            'name' => 'Stacked Revenue by Channel',
            'topicName' => 'orders',
            'prefersChart' => true,
            'query' => {
              'queryJson' => {
                'table' => 'orders',
                'fields' => ['orders.created_at[quarter]', 'orders.channel', 'orders.total_revenue']
              }
            },
            'visConfig' => {
              'visType' => 'basic',
              'chartType' => nil,
              'spec' => { 'mark' => { 'type' => 'bar' }, 'stack' => 'zero' }
            }
          }
        },
        {
          'queryPresentation' => {
            'id' => 'uuid-tile-2',
            'miniUuid' => 'mini-2',
            'name' => 'Order Details Table',
            'prefersChart' => false,
            'query' => {
              'queryJson' => {
                'table' => 'orders',
                'fields' => ['orders.channel', 'orders.total_revenue']
              }
            },
            'visConfig' => { 'visType' => 'omni-table', 'chartType' => nil }
          }
        },
        {
          'queryPresentation' => {
            'id' => 'uuid-tile-3',
            'miniUuid' => 'mini-3',
            'name' => 'Combo Revenue & Count',
            'prefersChart' => true,
            'query' => {
              'queryJson' => {
                'table' => 'orders',
                'fields' => ['orders.created_at[month]', 'orders.total_revenue']
              }
            },
            'visConfig' => {
              'visType' => 'basic',
              'chartType' => nil,
              'spec' => {
                'series' => [
                  { 'mark' => { 'type' => 'bar' } },
                  { 'mark' => { 'type' => 'line' } }
                ]
              }
            }
          }
        }
      ]
    },
    'metadata' => {
      'layouts' => {
        'lg' => [
          { 'i' => 'mini-1', 'x' => 0, 'y' => 0, 'w' => 6, 'h' => 8 },
          { 'i' => 'mini-2', 'x' => 6, 'y' => 0, 'w' => 6, 'h' => 8 },
          { 'i' => 'mini-3', 'x' => 0, 'y' => 8, 'w' => 12, 'h' => 8 }
        ]
      }
    }
  }
}

norm = OmniExport.normalize(real_export)
eq(norm['name'], 'Executive Pulse', 'dashboard name extracted')
eq(norm['tiles'].length, 3, '3 tiles extracted from queryPresentationCollectionMemberships')
eq(norm['tiles'][0]['chartType'], 'columnStacked', 'null chartType with bar + stack:zero inferred as columnStacked')
eq(norm['tiles'][1]['chartType'], 'table', 'omni-table visType inferred as table')
eq(norm['tiles'][2]['chartType'], 'barLine', 'multi-series bar + line inferred as barLine (combo-chart)')
eq(norm['filters'].map { |f| f['id'] }, %w[f_channel f_date], 'filters ordered by filterOrder')

puts '== build-omni-workbook.rb CLI with --dm-elements and miniUuid layout matching =='
Dir.mktmpdir do |dir|
  export_path = File.join(dir, 'export.json')
  dm_elements_path = File.join(dir, 'dm-elements.json')
  wb_out = File.join(dir, 'wb.json')

  File.write(export_path, JSON.pretty_generate(real_export))
  File.write(dm_elements_path, JSON.pretty_generate({
    'topic-orders' => {
      'id' => 'topic-orders',
      'dataModelId' => 'dm-live-99',
      'elementId' => 'el-live-topic-1',
      'name' => 'Orders'
    }
  }))

  script = File.expand_path('../scripts/build-omni-workbook.rb', __dir__)
  fix_dir = File.expand_path('../fixtures/orders-overview', __dir__)
  _out, err, status = Open3.capture3(
    'ruby', script,
    '--export', export_path,
    '--model-dir', fix_dir,
    '--topic', 'orders',
    '--dm-elements', dm_elements_path,
    '--folder-id', 'fld-1',
    '--out', wb_out
  )
  eq(status.success?, true, "build-omni-workbook.rb succeeded (#{err.strip})")

  env = JSON.parse(File.read(wb_out))
  eq(env['stats'], { 'tiles' => 3, 'controls' => 2, 'gaps' => 0 }, '3 tiles and 2 controls built with 0 gaps')
  doc = env['workbook']['document']
  data_el = doc['elements'].find { |e| e['id'] == 'data-orders' }
  eq(data_el['source']['dataModelId'], 'dm-live-99', '--dm-elements wired dataModelId')
  eq(data_el['source']['elementId'], 'el-live-topic-1', '--dm-elements wired server elementId')

  chart_kinds = doc['elements'].select { |e| e['id'].start_with?('chart-') }.map { |e| e['kind'] }
  eq(chart_kinds, %w[bar-chart table combo-chart], 'chart elements mapped to bar-chart, table, combo-chart')
end

if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
