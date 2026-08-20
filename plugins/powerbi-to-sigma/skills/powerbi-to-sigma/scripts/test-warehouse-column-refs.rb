#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/warehouse_column_refs'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

fixture = {
  'pages' => [{ 'elements' => [{
    'id' => 'orders', 'name' => 'Order Fact',
    'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn',
                  'path' => %w[DB SCHEMA ORDER_FACT] },
    'columns' => [
      { 'id' => 'inode-random/ORDER_ID', 'formula' => '[ORDER_FACT/Order Id]' },
      { 'id' => 'inode-guid/NOT_PHYSICAL', 'formula' => '[ORDER_FACT/Net Revenue]',
        'name' => 'Net Revenue' },
      { 'id' => 'calc', 'formula' => 'Text([Order Fact/Order Id])', 'name' => 'Order Text' }
    ],
    'order' => ['inode-random/ORDER_ID', 'inode-guid/NOT_PHYSICAL', 'calc'],
    'relationships' => [{ 'keys' => [{ 'sourceColumnId' => 'inode-guid/NOT_PHYSICAL' }] }]
  }, {
    'id' => 'view', 'name' => 'Order View', 'source' => { 'kind' => 'table', 'elementId' => 'orders' },
    'columns' => [{ 'id' => 'pass', 'formula' => '[Order Fact/Order Id]' }]
  }] }]
}
catalog = [{ 'name' => 'ORDER_ID' }, { 'name' => 'NET_REVENUE' }]
requester = lambda do |method, _path, **_kwargs|
  method == :get ? { 'friendlyName' => false } : { 'kind' => 'table', 'inodeId' => 'table' }
end

physical = Marshal.load(Marshal.dump(fixture))
result = WarehouseColumnRefs.apply!(physical, requester: requester, lister: ->(_path) { catalog })
orders, view = physical['pages'][0]['elements']
check.call(result['connectionModes'] == { 'conn' => false }, 'reads physical naming mode from connection metadata')
check.call(orders['name'] == 'ORDER_FACT', 'warehouse element uses its physical source prefix')
check.call(orders['columns'][0]['formula'] == '[ORDER_FACT/ORDER_ID]' &&
           orders['columns'][0]['name'] == 'Order Id', 'base formula is physical while display name stays friendly')
check.call(orders['columns'][1]['id'] == 'inode-guid/NET_REVENUE', 'inode suffix is grounded from the catalog')
check.call(orders['order'][1] == 'inode-guid/NET_REVENUE' &&
           orders['relationships'][0]['keys'][0]['sourceColumnId'] == 'inode-guid/NET_REVENUE',
           'column-id cross-references follow the re-key')
check.call(orders['columns'][2]['formula'] == 'Text([ORDER_FACT/ORDER_ID])',
           'qualified calculated-column input is grounded')
check.call(view['columns'][0]['formula'] == '[ORDER_FACT/Order Id]' &&
           view['columns'][0]['name'] == 'Order Id', 'derived passthrough is grounded and keeps a friendly name')

friendly = Marshal.load(Marshal.dump(fixture))
friendly_requester = ->(_method, _path, **_kwargs) { { 'friendlyName' => true } }
friendly_result = WarehouseColumnRefs.apply!(friendly, requester: friendly_requester, lister: ->(_path) { catalog })
check.call(friendly_result['rewritten'].zero? && friendly == fixture,
           'friendly-name connections preserve converter output')

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
