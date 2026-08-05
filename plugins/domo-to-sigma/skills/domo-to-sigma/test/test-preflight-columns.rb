#!/usr/bin/env ruby
# Offline: preflight-columns.rb's network seam (fetch_warehouse_columns) and
# orchestration (run_preflight) — bead m655. No live Sigma call; requester/
# lister and fetcher are injected stubs throughout (mirrors build-dm.rb's own
# fetcher: seam for autofill_dataset_map).
#   ruby test/test-preflight-columns.rb
require 'json'
require_relative '../scripts/preflight-columns'

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== fetch_warehouse_columns: happy path — lookup then paginated columns list =='
stub_requester = ->(method, path, body: nil) do
  eq(method, :post, 'lookup uses POST')
  eq(path, '/v2/connection/conn-1/lookup', 'lookup path names the connection')
  eq(JSON.parse(body), { 'path' => %w[DB SCH ORDER_FACT] }, 'lookup body carries the fully-qualified path')
  { 'inodeId' => 'inode-1', 'kind' => 'table' }
end
stub_lister = ->(path) do
  eq(path, '/v2/connections/tables/inode-1/columns', 'columns fetched at the resolved inodeId')
  [{ 'name' => 'ORDER_ID', 'type' => { 'type' => 'LONG' } }, { 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' }]
end
result = fetch_warehouse_columns('conn-1', %w[DB SCH ORDER_FACT], requester: stub_requester, lister: stub_lister)
ok(!result['error'], "no error on the happy path, got #{result['error'].inspect}")
eq(result['columns'], [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' }],
   'nested {type:{type:...}} shape is flattened to a plain type string')
eq(result['inode_id'], 'inode-1', 'inode_id carried through')

puts '== fetch_warehouse_columns: lookup 404 -> a distinct, actionable error (not a generic failure) =='
requester_404 = ->(*_a, **_kw) { raise Sigma::Error, 'POST /v2/connection/conn-2/lookup -> 404 Not Found' }
result_404 = fetch_warehouse_columns('conn-2', %w[DB SCH MISSING_TABLE], requester: requester_404, lister: ->(_p) { [] })
ok(result_404['error'], 'a 404 lookup produces an error result, not an exception')
ok(result_404['error'].include?('sync'), "the 404 message names the sync-then-retry fix, got #{result_404['error'].inspect}")

puts '== fetch_warehouse_columns: a non-404 Sigma error is reported distinctly from a 404 =='
requester_500 = ->(*_a, **_kw) { raise Sigma::Error, 'POST /v2/connection/conn-3/lookup -> 500 Internal Server Error' }
result_500 = fetch_warehouse_columns('conn-3', %w[DB SCH TABLE], requester: requester_500, lister: ->(_p) { [] })
ok(result_500['error'], 'a 500 also produces an error result, not an exception')
ok(!result_500['error'].include?('sync'), 'a non-404 error does NOT get the 404-specific sync guidance')

puts '== fetch_warehouse_columns: a stray "404" in a 500 error BODY must not false-positive as a 404 (Finding 1 regression) =='
requester_500_with_404_in_body = ->(*_a, **_kw) do
  raise Sigma::Error, "POST /v2/connection/conn-5/lookup -> 500 Internal Server Error\n{\"error\":\"upstream call to service X returned 404\",\"code\":\"E404\"}"
end
result_500_body404 = fetch_warehouse_columns('conn-5', %w[DB SCH TABLE], requester: requester_500_with_404_in_body, lister: ->(_p) { [] })
ok(result_500_body404['error'], 'a 500 whose body mentions 404 still produces an error result, not an exception')
ok(!result_500_body404['error'].include?('sync'),
   "a 404 token in the BODY (not the status line) must NOT trigger the 404-specific sync guidance, got #{result_500_body404['error'].inspect}")

puts '== fetch_warehouse_columns: a network-level exception (timeout) is caught, not propagated (Finding 2 regression) =='
requester_timeout = ->(*_a, **_kw) { raise Net::ReadTimeout, 'execution expired' }
result_timeout = fetch_warehouse_columns('conn-6', %w[DB SCH TABLE], requester: requester_timeout, lister: ->(_p) { [] })
ok(result_timeout.is_a?(Hash) && result_timeout['error'], 'a Net::ReadTimeout is caught and returned as an error Hash, not raised')

puts '== fetch_warehouse_columns: lookup resolving to a non-table kind is an error =='
requester_view = ->(*_a, **_kw) { { 'inodeId' => 'inode-9', 'kind' => 'view' } }
result_view = fetch_warehouse_columns('conn-4', %w[DB SCH V], requester: requester_view, lister: ->(_p) { [] })
ok(result_view['error'], 'a non-table lookup result is an error')
ok(result_view['error'].include?('view'), "error names the unexpected kind, got #{result_view['error'].inspect}")

puts '== run_preflight: a dataset whose warehouse table has every Domo column -> clean =='
datasets = [{ 'id' => 'ds-1', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } }]
ds_map = { 'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' } }
clean_fetcher = ->(_conn, _path) { { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } }
report, any_missing = run_preflight(datasets, ds_map, %w[ds-1], fetcher: clean_fetcher)
eq(any_missing, false, 'no unresolved columns -> any_missing is false')
eq(report['ds-1']['missing'], [], 'ds-1 report shows nothing missing')

puts '== run_preflight: a dataset with a genuinely missing column -> any_missing true, named in the report =='
gap_fetcher = ->(_conn, _path) { { 'columns' => [] } }
report2, any_missing2 = run_preflight(datasets, ds_map, %w[ds-1], fetcher: gap_fetcher)
eq(any_missing2, true, 'a missing column -> any_missing is true')
eq(report2['ds-1']['missing'], ['ORDER_ID'], 'the report names the specific missing column')

puts '== run_preflight: a fetch error is reported and counts as any_missing =='
error_fetcher = ->(_conn, _path) { { 'error' => 'table not found in Sigma catalog' } }
report3, any_missing3 = run_preflight(datasets, ds_map, %w[ds-1], fetcher: error_fetcher)
eq(any_missing3, true, 'a fetch error also makes any_missing true (nothing was actually checked)')
eq(report3['ds-1']['error'], 'table not found in Sigma catalog', 'the fetch error is carried into the report')

puts '== run_preflight: a dataset-map entry with a placeholder sentinel table is skipped, not attempted =='
ds_map_sentinel = { 'ds-1' => { 'connectionId' => '', 'database' => nil, 'schema' => nil, 'table' => nil, '_source' => 'domo-landed-data' } }
never_called = ->(*_a) { raise 'must not attempt a live fetch for an unresolved dataset-map entry' }
report4, any_missing4 = run_preflight(datasets, ds_map_sentinel, %w[ds-1], fetcher: never_called)
eq(report4, {}, 'nothing reported for a dataset with no resolved connection/table yet')
eq(any_missing4, false, 'an unresolved (not-yet-mapped) dataset does not block the pre-flight — build-dm.rb\'s own existing warnings cover it')

puts '== run_preflight: excludeColumns/columnOverrides already in dataset-map.json are honored =='
ds_map_resolved = { 'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT',
                                'excludeColumns' => ['ORDER_ID'] } }
report5, any_missing5 = run_preflight(datasets, ds_map_resolved, %w[ds-1], fetcher: gap_fetcher)
eq(any_missing5, false, 'the only gap is excluded -> clean')
eq(report5['ds-1']['resolved_by_exclude'], ['ORDER_ID'], 'the exclusion is reported, not silently applied')

puts '== fetch_warehouse_columns: honors SIGMA_HTTP_TIMEOUT for the real (non-stubbed) network path =='
captured_timeouts = []
Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &blk|
  captured_timeouts << kwargs
  # Return a minimal fake result so the block completes without a real connection.
  blk.call(Object.new.tap { |o| o.define_singleton_method(:request) { |*_a| raise Sigma::Error, 'stub: no real request' } })
end
begin
  ENV['SIGMA_HTTP_TIMEOUT'] = '45'
  ENV['SIGMA_BASE_URL'] ||= 'https://example.sigmacomputing.com'
  fetch_warehouse_columns('conn-timeout-test', %w[DB SCH T]) # requester/lister both nil -> real path
rescue StandardError
  # Expected — the stub raises past the lookup; we only care about the captured timeout kwargs.
ensure
  ENV.delete('SIGMA_HTTP_TIMEOUT')
end
ok(captured_timeouts.any? { |kw| kw[:read_timeout] == 45 }, "SIGMA_HTTP_TIMEOUT=45 was actually used as read_timeout, got #{captured_timeouts.inspect}")
ok(captured_timeouts.any? { |kw| kw[:open_timeout] == 30 }, "open_timeout is capped at 30 even though read_timeout is 45, got #{captured_timeouts.inspect}")

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
