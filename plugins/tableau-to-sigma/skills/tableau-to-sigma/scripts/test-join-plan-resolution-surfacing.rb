#!/usr/bin/env ruby
# frozen_string_literal: true
# test-join-plan-resolution-surfacing.rb — unit test for
# scripts/lib/join_plan_resolutions.rb (beads-sigma-zjkw, the real M5 gap).
#
# WHY: probe-join-keys.rb (gate 16) lets an operator resolve a non-unique join
# by recording {how, reason} on the entry's 'resolution' key in
# <workdir>/join-plan.json — but nothing downstream ever read it back out.
# A 'preaggregated' resolution means a helper element (a pre-aggregated /
# Custom-SQL-shaped table) was added to the data model to fix the grain; with
# no readback, that helper has no customer-visible explanation anywhere. This
# is the confirmed root cause of a field report ("it created a custom SQL
# aggregate table in a data model that didn't exist in the Tableau data set").
#
# Pure/offline, no network, no fixtures beyond an inline join-plan.json —
# same shape convention as test-coverage-gate.rb / test-join-plan.rb.
# Run: ruby scripts/test-join-plan-resolution-surfacing.rb
require 'json'
require 'tmpdir'
require_relative 'lib/join_plan_resolutions'

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# One RESOLVED entry (preaggregated, with a human-written reason) and one
# UNRESOLVED non-unique entry (no resolution recorded yet) — the exact mix a
# real join-plan.json carries mid-migration.
DOC = {
  'generated_at' => '2026-07-31T00:00:00Z',
  'entries' => [
    {
      'kind' => 'lookup-synthesis', 'left' => 'Orders', 'right' => 'Shipments',
      'keys' => ['Order Id'], 'status' => 'non-unique',
      'resolution' => { 'how' => 'preaggregated', 'reason' => 'Shipments Preagg by Order Id',
                         'recorded_at' => '2026-07-31T01:00:00Z' }
    },
    {
      'kind' => 'federated-join', 'left' => 'FACT_WIDE', 'right' => 'DIM_PRODUCT',
      'keys' => ['PRODUCT_ID'], 'status' => 'non-unique'
      # no 'resolution' — still blocking, NOT yet explained.
    }
  ]
}.freeze

puts '== resolved_entries: only entries with a recognized resolution =='
resolved = JoinPlanResolutions.resolved_entries(DOC)
ok('exactly one resolved entry (the unresolved one is excluded)', resolved.size == 1)
ok('the resolved entry is the Orders->Shipments one', resolved.first && resolved.first['left'] == 'Orders')

puts "\n== report_lines: names the reason + how for the resolved entry =="
lines = JoinPlanResolutions.report_lines(DOC)
joined = lines.join("\n")
ok('report mentions the left->right relationship', joined.include?('Orders') && joined.include?('Shipments'))
ok('report names the resolution kind (preaggregated)', joined.include?('preaggregated'))
ok('report carries the human-written reason verbatim', joined.include?('Shipments Preagg by Order Id'))
ok('the UNRESOLVED entry (FACT_WIDE/DIM_PRODUCT) is NOT surfaced as if it were fine',
   !joined.include?('FACT_WIDE') && !joined.include?('DIM_PRODUCT'))

puts "\n== headline names the count =="
hl = JoinPlanResolutions.headline(DOC)
ok('headline reports 1 resolution', hl.include?('1'))

puts "\n== waived resolutions are ALSO surfaced (not just preaggregated) =="
waived_doc = { 'entries' => [
  { 'kind' => 'federated-join', 'left' => 'A', 'right' => 'B', 'keys' => ['K'], 'status' => 'non-unique',
    'resolution' => { 'how' => 'waived', 'reason' => 'ops: accepted arbitrary-match risk for this report' } }
] }
w_lines = JoinPlanResolutions.report_lines(waived_doc)
ok('waived resolution surfaced', w_lines.join.include?('waived') && w_lines.join.include?('accepted arbitrary-match risk'))

puts "\n== no resolutions at all -> empty report, no crash =="
none_doc = { 'entries' => [{ 'kind' => 'federated-join', 'left' => 'X', 'right' => 'Y', 'status' => 'unique' }] }
ok('report_lines([]) for an all-unique ledger', JoinPlanResolutions.report_lines(none_doc) == [])
ok('resolved_entries([]) for an all-unique ledger', JoinPlanResolutions.resolved_entries(none_doc) == [])

puts "\n== defensive load: missing/garbage/empty doc never crashes =="
ok('load(nil) -> nil', JoinPlanResolutions.load(nil).nil?)
ok('load(missing path) -> nil', JoinPlanResolutions.load('/no/such/join-plan.json').nil?)
ok('report_lines(nil) -> []', JoinPlanResolutions.report_lines(nil) == [])
ok('resolved_entries(nil) -> []', JoinPlanResolutions.resolved_entries(nil) == [])
Dir.mktmpdir do |dir|
  path = File.join(dir, 'join-plan.json')
  File.write(path, JSON.pretty_generate(DOC))
  loaded = JoinPlanResolutions.load(path)
  ok('load() round-trips a real file', loaded && JoinPlanResolutions.resolved_entries(loaded).size == 1)
end

# An entry whose 'resolution' key exists but isn't a recognized 'how' (e.g. a
# future value, or malformed data) must not be treated as resolved — silently
# accepting an unrecognized how would risk mis-surfacing something as
# explained when it isn't.
puts "\n== unrecognized resolution.how is NOT treated as resolved =="
weird_doc = { 'entries' => [
  { 'kind' => 'federated-join', 'left' => 'A', 'right' => 'B', 'status' => 'non-unique',
    'resolution' => { 'how' => 'something-else', 'reason' => 'r' } }
] }
ok('unrecognized how excluded from resolved_entries', JoinPlanResolutions.resolved_entries(weird_doc) == [])

puts($fail.zero? ? "\ntest-join-plan-resolution-surfacing: ALL PASS" : "\ntest-join-plan-resolution-surfacing: #{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
