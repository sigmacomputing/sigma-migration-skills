#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/tableau_warehouse_column_refs'

fails = []
check = ->(condition, message) { puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"; fails << message unless condition }
spec = { 'pages' => [{ 'elements' => [{
  'name' => 'Order Fact',
  'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn', 'path' => %w[DB S ORDER_FACT] },
  'columns' => [
    { 'id' => 'inode-a/GUID', 'formula' => '[ORDER_FACT/Order Id]' },
    { 'id' => 'inode-b/PHANTOM', 'formula' => '[ORDER_FACT/Product Key/Name]', 'name' => 'Product Key/Name' },
    { 'id' => 'calc', 'formula' => 'Text([Order Fact/Order Id])', 'name' => 'Order Text' }
  ], 'order' => %w[inode-a/GUID inode-b/PHANTOM calc]
}, { 'name' => 'Order View', 'source' => { 'kind' => 'table', 'elementId' => 'fact' },
     'columns' => [{ 'id' => 'pass', 'formula' => '[Order Fact/Order Id]' }] }] }] }
requester = ->(method, _path, **_kwargs) { method == :get ? { 'friendlyName' => false } : { 'kind' => 'table', 'inodeId' => 't' } }
result = TableauWarehouseColumnRefs.apply!(spec, requester: requester,
                                    lister: ->(_path) { [{ 'name' => 'ORDER_ID' }] }, drop_unresolved: true)
fact, view = spec['pages'][0]['elements']
check.call(fact['name'] == 'ORDER_FACT', 'warehouse element uses physical name')
check.call(fact['columns'][0] == { 'id' => 'inode-a/ORDER_ID', 'formula' => '[ORDER_FACT/ORDER_ID]', 'name' => 'Order Id' },
           'GUID-backed base column is catalog-grounded and keeps display name')
check.call(fact['columns'].none? { |column| column['id'] == 'inode-b/PHANTOM' },
           'catalog-proven phantom passthrough is dropped')
check.call(fact['order'] == ['inode-a/ORDER_ID', 'calc'], 'order follows re-key/drop')
check.call(fact['columns'][1]['formula'] == 'Text([ORDER_FACT/ORDER_ID])', 'same-element qualified calc is physical')
check.call(view['columns'][0]['formula'] == '[ORDER_FACT/Order Id]' && view['columns'][0]['name'] == 'Order Id',
           'derived element keeps friendly leaf under physical prefix')
check.call(result[:dropped].size == 1, 'drop is surfaced in the result')

friendly = Marshal.load(Marshal.dump(spec))
original = Marshal.load(Marshal.dump(friendly))
TableauWarehouseColumnRefs.apply!(friendly, requester: ->(_m, _p, **_k) { { 'friendlyName' => true } }, lister: ->(_p) { [] })
check.call(friendly == original, 'friendly mode is a no-op')
puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
exit(fails.empty? ? 0 : 1)
