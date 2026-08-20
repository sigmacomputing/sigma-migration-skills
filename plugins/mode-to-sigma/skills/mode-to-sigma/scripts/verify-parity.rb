#!/usr/bin/env ruby
# Compare each Sigma chart's value against a fresh re-run of the SAME Mode
# Query (true source-value parity, not just warehouse-verified) and write
# parity-final.json in the exact shape assert-phase6-ran.rb requires.
#
#   ruby scripts/verify-parity.rb --workbook-id <id> --report <report-token> \
#     --plan parity-plan.json --out parity-final.json
require 'optparse'
require 'json'
require 'csv'
require 'time'
require 'timeout'
require_relative 'lib/sigma_rest'
require_relative 'mode-discover' # reuses run_report_and_fetch_csvs — one place for the run+poll logic

# Real CSV parsing (stdlib), not a hand-rolled split(',') — a value like
# `"Springfield, IL"` has an embedded comma inside quotes that split(',')
# would cut in half. Same library mode-discover.rb and gooddata-to-sigma's
# verify-warehouse.rb both already use for this.
def parse_csv(text)
  CSV.parse(text.to_s)
end

# Order-insensitive row comparison, tolerant of float-formatting differences
# (1.0 vs 1) the same way every other converter's parity script is.
def rows_match?(a, b)
  norm = ->(rows) { rows.map { |r| r.map { |c| Float(c) rescue c } }.sort_by(&:to_s) }
  norm.call(a) == norm.call(b)
end

# Compares only the DATA rows of two CSV texts, stripping each side's header
# row first. Sigma's chart-export header and Mode's raw column name are
# expected to differ (casing, aliasing, friendly display names) — that is a
# chart-binding-correctness question for Task 7, not this value-level check —
# so folding headers into the diff produces spurious FAILs unrelated to
# whether the actual values match. Pure function: no I/O, safe to unit test
# directly (this is the piece Finding 3 needed covered).
def data_rows_match?(mode_csv_text, sigma_csv_text)
  rows_match?(parse_csv(mode_csv_text).drop(1), parse_csv(sigma_csv_text).drop(1))
end

# Transient-vs-permanent classification for the retry loop below, ported
# byte-for-byte from gooddata-to-sigma's verify-warehouse.rb `element_csv`
# (429/408/50x or a timeout message is worth a retry; anything else — e.g. a
# 400 — is a permanent failure and must not be retried). Extracted as its own
# pure function so it has a direct unit test independent of the live-network
# retry loop that uses it.
TRANSIENT_ERROR = /\b(429|408|50[234])\b|Too Many Requests|timed? ?out/i
def transient_error?(message)
  !(message.to_s =~ TRANSIENT_ERROR).nil?
end

# Exponential backoff with jitter, same formula as verify-warehouse.rb:
# 1.5s, 3.0s, 6.0s (+ up to 0.5s jitter) for attempts 1, 2, 3. Extracted as
# its own pure function for the same reason as transient_error? above.
def retry_delay(attempts)
  (1.5 * (2**(attempts - 1))) + rand * 0.5
end

# Pulls one Sigma chart element's current CSV via the export API — the
# verified POST -> {queryId} -> poll GET .../download pattern from
# gooddata-to-sigma's verify-warehouse.rb (Step 0 above) — including that
# precedent's bounded retry-with-backoff for transient errors (429/408/50x/
# timeout) up to 4 attempts before giving up. This is a live-network I/O
# function (never unit tested directly, same as before this fix — only the
# transient_error?/retry_delay helpers it calls are pure-function tested).
def sigma_export_csv(workbook_id, element_id, timeout: 60)
  attempts = 0
  begin
    attempts += 1
    r = Sigma.request(:post, "/v2/workbooks/#{workbook_id}/export",
                       body: JSON.generate({ elementId: element_id, format: { type: 'csv' } }))
    qid = r && r['queryId']
    raise Sigma::Error, "export POST returned no queryId: #{r.inspect[0, 120]}" unless qid
    t0 = Time.now
    loop do
      raise Sigma::Error, "export poll timed out (#{timeout}s)" if Time.now - t0 > timeout
      sleep 1.0
      body = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
      return body if body && !body.to_s.empty? # empty = still rendering
    end
  rescue Sigma::Error, Timeout::Error, Errno::ETIMEDOUT => e
    msg = e.message.lines.first.to_s
    if attempts < 4 && transient_error?(msg)
      sleep(retry_delay(attempts))
      retry
    end
    raise
  end
end

# This is a HARD GATE run against live Mode + Sigma data: a missing plan
# token, a transient 429, or an export timeout on any ONE chart must never
# crash the whole process before parity-final.json is written — that would
# fail every chart, not just the broken one, and hand Task 9's orchestrator a
# bare crash instead of a readable report. Mirrors gooddata-to-sigma's
# verify-warehouse.rb discipline: catch it here, return a FAIL tuple.
def compare_entry(entry, mode_csv_by_token, workbook_id)
  mode_csv = mode_csv_by_token.fetch(entry['query_token'])
  sigma_csv = sigma_export_csv(workbook_id, entry['chart_element_id'])
  { 'chart' => entry['chart_name'], 'pass' => data_rows_match?(mode_csv, sigma_csv) }
rescue KeyError
  { 'chart' => entry['chart_name'], 'pass' => false,
    'reason' => "no fresh Mode result for query_token #{entry['query_token'].inspect}" }
# CSV::MalformedCSVError covers a genuinely malformed CSV payload (e.g. an
# unbalanced/stray quote in a cell) from either the Mode re-run or the Sigma
# export — real-world Mode/Sigma export data, not a hypothetical. Without
# this, CSV.parse (inside data_rows_match?) raises past compare_entry's rescue
# and crashes the whole script before parity-final.json is ever written,
# failing every chart instead of just the one with bad CSV.
rescue Sigma::Error, Timeout::Error, Errno::ETIMEDOUT, CSV::MalformedCSVError => e
  { 'chart' => entry['chart_name'], 'pass' => false, 'reason' => e.message.lines.first.to_s.strip[0, 160] }
end

def summarize_parity(results, workbook_id:)
  passed = results.select { |r| r['pass'] }
  failed = results.reject { |r| r['pass'] }
  {
    'workbook_id' => workbook_id, 'ran_at' => Time.now.utc.iso8601, 'verified_against' => 'mode_query',
    'charts_total' => results.size, 'charts_pass' => passed.size, 'charts_fail' => failed.size,
    'pass_names' => passed.map { |r| r['chart'] }, 'fail_names' => failed.map { |r| r['chart'] },
    'status' => failed.empty? ? 'PASS' : 'FAIL'
  }
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--workbook-id ID') { |v| opts[:workbook_id] = v }
    o.on('--report TOKEN')  { |v| opts[:report] = v }
    o.on('--plan PATH')      { |v| opts[:plan] = v }
    o.on('--out PATH')       { |v| opts[:out] = v }
    o.on('--fixture PATH', 'TEST ONLY: pre-built results array, bypasses Mode + the Sigma export API') { |v| opts[:fixture] = v }
  end.parse!(ARGV)

  results = if opts[:fixture]
              JSON.parse(File.read(opts[:fixture]))
            else
              plan = JSON.parse(File.read(opts[:plan]))
              mode_csv_by_token = run_report_and_fetch_csvs(opts[:report])
              plan.map { |entry| compare_entry(entry, mode_csv_by_token, opts[:workbook_id]) }
            end
  summary = summarize_parity(results, workbook_id: opts[:workbook_id])
  File.write(opts[:out], JSON.pretty_generate(summary))
  exit(summary['status'] == 'PASS' ? 0 : 2)
end
