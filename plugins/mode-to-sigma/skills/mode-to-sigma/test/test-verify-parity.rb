#!/usr/bin/env ruby
#   ruby test/test-verify-parity.rb
require_relative '../scripts/verify-parity'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== parse_csv =="
eq(parse_csv("ORDER_DATE,REVENUE\n2026-01-01,100\n2026-01-02,200\n"),
   [['ORDER_DATE', 'REVENUE'], ['2026-01-01', '100'], ['2026-01-02', '200']], 'splits rows and strips quoting')
eq(parse_csv("CITY,POPULATION\n\"Springfield, IL\",5000\n"),
   [['CITY', 'POPULATION'], ['Springfield, IL', '5000']],
   'real CSV parsing (stdlib csv) keeps an embedded comma inside quotes as one field, not two')

puts "== rows_match? =="
eq(rows_match?([['a', '1'], ['b', '2']], [['b', '2'], ['a', '1']]), true, 'row order does not matter')
eq(rows_match?([['a', '1.0']], [['a', '1']]), true, 'float-formatting differences (1.0 vs 1) are not a mismatch')
eq(rows_match?([['a', '1']], [['a', '2']]), false, 'a genuine value difference is a mismatch')

puts "== data_rows_match? (Finding 3: header row must not be folded into the value comparison) =="
eq(data_rows_match?("Order Date,Revenue ($)\n2026-01-01,100\n", "ORDER_DATE,REVENUE\n2026-01-01,100\n"),
   true, 'differing column headers between Mode and the Sigma export are expected and must not fail the check')
eq(data_rows_match?("Order Date,Revenue ($)\n2026-01-01,100\n", "ORDER_DATE,REVENUE\n2026-01-02,100\n"),
   false, 'a genuine data-row value difference still fails once headers are stripped from both sides')

puts "== transient_error? (Finding 1: retry-worthy vs permanent failure classification) =="
eq(transient_error?('POST /v2/workbooks/wb-1/export -> 429 Too Many Requests'), true, '429 is transient')
eq(transient_error?('export poll timed out (60s)'), true, 'a timeout message is transient')
eq(transient_error?('GET /v2/query/q1/download -> 503 Service Unavailable'), true, '50x is transient')
eq(transient_error?('POST /v2/workbooks/wb-1/export -> 400 Bad Request'), false,
   'a 400 is a permanent client error and must not be classified as retry-worthy')

puts "== retry_delay (Finding 1: same exponential-backoff formula as verify-warehouse.rb) =="
d1 = retry_delay(1)
d2 = retry_delay(2)
eq(d1 >= 1.5 && d1 < 2.0, true, 'attempt 1 backoff is base 1.5s plus up to 0.5s jitter')
eq(d2 >= 3.0 && d2 < 3.5, true, 'attempt 2 backoff doubles to base 3.0s plus up to 0.5s jitter')

puts "== compare_entry (Finding 1: a missing plan token degrades to a FAIL tuple, never raises) =="
orphan = compare_entry(
  { 'chart_name' => 'Orphan Chart', 'query_token' => 'token-not-in-fresh-mode-results', 'chart_element_id' => 'el-x' },
  {}, # empty mode_csv_by_token — .fetch raises KeyError before any network call happens
  'wb-1'
)
eq(orphan['chart'], 'Orphan Chart', 'KeyError path still names the chart being compared')
eq(orphan['pass'], false, 'KeyError degrades to a graceful per-chart FAIL instead of crashing the process')
eq(orphan.key?('reason'), true, 'KeyError path records a human-readable reason')

puts "== compare_entry (re-review follow-up: malformed CSV degrades to a FAIL tuple, never raises) =="
# Stub the live-network sigma_export_csv (same top-level-redefine stubbing
# convention test-mode-rest.rb uses via Mode.define_singleton_method) so this
# proves the CSV::MalformedCSVError rescue in compare_entry closes the crash
# with zero live network calls — the malformed payload lives on the Mode side,
# which is parsed inside data_rows_match? after the (stubbed) Sigma export.
def sigma_export_csv(*)
  "b\n1\n"
end
malformed = compare_entry(
  { 'chart_name' => 'Malformed Chart', 'query_token' => 'tok-1', 'chart_element_id' => 'el-y' },
  { 'tok-1' => %(a,b\n"unterminated,2\n) }, # unbalanced quote -> CSV::MalformedCSVError from CSV.parse
  'wb-1'
)
eq(malformed['chart'], 'Malformed Chart', 'malformed-CSV path still names the chart being compared')
eq(malformed['pass'], false, 'malformed CSV degrades to a graceful per-chart FAIL instead of crashing the process')
eq(malformed.key?('reason'), true, 'malformed-CSV path records a human-readable reason')

puts "== summarize_parity =="
results = [
  { 'chart' => 'Monthly Revenue KPI', 'pass' => true },
  { 'chart' => 'Region Bar',          'pass' => false }
]
summary = summarize_parity(results, workbook_id: 'wb-1')
eq(summary['status'], 'FAIL', 'any failing chart -> overall FAIL')
eq(summary['charts_total'], 2, 'charts_total counts all compared charts')
eq(summary['charts_pass'], 1, 'charts_pass counts only passing charts')
eq(summary['pass_names'], ['Monthly Revenue KPI'], 'pass_names lists passing chart names')
eq(summary['fail_names'], ['Region Bar'], 'fail_names lists failing chart names')
eq(summary['verified_against'], 'mode_query', 'verified_against records the comparison source')

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
