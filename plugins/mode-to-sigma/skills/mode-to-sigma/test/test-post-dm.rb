#!/usr/bin/env ruby
#   ruby test/test-post-dm.rb
require_relative '../scripts/post-dm'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== columns_for_lookup (C1 fix: per-column raw-field -> DM display-name mapping) =="
authored_el = { 'id' => 'el-q1', 'columns' => [
  { 'id' => 'q1_order_month', 'name' => 'Order Month', 'formula' => '[Custom SQL/order_month]' },
  { 'id' => 'q1_revenue',     'name' => 'Revenue',      'formula' => '[Custom SQL/revenue]' }
] }
live_el = { 'id' => 'inode-abc123', 'name' => 'Monthly Revenue', 'columns' => [
  { 'id' => 'inode-col-1', 'name' => 'Order Month' },
  { 'id' => 'inode-col-2', 'name' => 'Revenue' }
] }
eq(columns_for_lookup(authored_el, live_el, 'q1'), [
  { 'id' => 'order_month', 'name' => 'Order Month' },
  { 'id' => 'revenue',     'name' => 'Revenue' }
], 'strips the token prefix off each authored column id to recover the RAW field (e.g. "q1_order_month" ' \
   '-> "order_month"), paired positionally with the live readback\'s own display name -- ' \
   'the only place build-mode-workbook.rb can look up a raw field\'s real DM display name')

authored_el_short = { 'id' => 'el-q1', 'columns' => [{ 'id' => 'q1_revenue', 'name' => 'Revenue' }] }
live_el_no_cols = { 'id' => 'inode-abc123', 'name' => 'Monthly Revenue' } # no 'columns' key in readback
eq(columns_for_lookup(authored_el_short, live_el_no_cols, 'q1'), [{ 'id' => 'revenue', 'name' => 'Revenue' }],
   'falls back to the authored name when the live readback is missing a columns array entirely (defensive)')

puts "== element_lookup_from_readback =="
spec = { 'pages' => [{ 'elements' => [
  { 'id' => 'inode-abc123', 'name' => 'Monthly Revenue', 'columns' => [
    { 'id' => 'inode-col-1', 'name' => 'Order Month' }, { 'id' => 'inode-col-2', 'name' => 'Revenue' }
  ] },
  { 'id' => 'inode-def456', 'name' => 'Region Revenue', 'columns' => [
    { 'id' => 'inode-col-3', 'name' => 'Region' }, { 'id' => 'inode-col-4', 'name' => 'Revenue' }
  ] }
] }] }
authored_elements = [
  { 'id' => 'el-q1', 'name' => 'Monthly Revenue', 'columns' => [
    { 'id' => 'q1_order_month', 'name' => 'Order Month' }, { 'id' => 'q1_revenue', 'name' => 'Revenue' }
  ] },
  { 'id' => 'el-q2', 'name' => 'Region Revenue', 'columns' => [
    { 'id' => 'q2_region', 'name' => 'Region' }, { 'id' => 'q2_revenue', 'name' => 'Revenue' }
  ] }
]
original_ids = { 'q1' => 'el-q1', 'q2' => 'el-q2' }
lookup = element_lookup_from_readback(spec, original_ids, authored_elements, data_model_id: 'dm-1')
eq(lookup, {
  'q1' => { 'dataModelId' => 'dm-1', 'elementId' => 'inode-abc123', 'name' => 'Monthly Revenue',
            'columns' => [{ 'id' => 'order_month', 'name' => 'Order Month' }, { 'id' => 'revenue', 'name' => 'Revenue' }] },
  'q2' => { 'dataModelId' => 'dm-1', 'elementId' => 'inode-def456', 'name' => 'Region Revenue',
            'columns' => [{ 'id' => 'region', 'name' => 'Region' }, { 'id' => 'revenue', 'name' => 'Revenue' }] }
}, 'maps query token -> server-assigned element id + name + per-column raw-field/display-name list, ' \
   'matched positionally by original authoring id order')

puts "== post_or_put_dm (create vs extend) =="
calls = []
Sigma.define_singleton_method(:request) do |verb, path, body: nil|
  calls << [verb, path]
  verb == :post ? { 'dataModelId' => 'new-dm-1' } : {}
end
eq(post_or_put_dm({ 'name' => 'x' }, { 'mode' => 'create' }), 'new-dm-1', 'create mode returns the POST response dataModelId')
eq(calls.last, [:post, '/v2/dataModels/spec'], 'create mode calls POST /v2/dataModels/spec')
calls.clear
eq(post_or_put_dm({ 'name' => 'x' }, { 'mode' => 'extend', 'dataModelId' => 'dm-9' }), 'dm-9', 'extend mode returns the already-known dataModelId, not a parsed response')
eq(calls.last, [:put, '/v2/dataModels/dm-9/spec'], 'extend mode calls PUT on the exact DM the reuse-check picked, never POST')

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
