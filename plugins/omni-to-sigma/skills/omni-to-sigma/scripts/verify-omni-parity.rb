#!/usr/bin/env ruby
# frozen_string_literal: true
# Compare each Sigma chart's exported values against Omni's POST /api/v1/query/run
# oracle (or an offline fixture) and write parity-final.json in the shape
# assert-phase6-ran.rb requires.
#
#   ruby scripts/verify-omni-parity.rb --workbook-id <id> --plan parity-plan.json --out parity-final.json

require 'optparse'
require 'json'
require 'csv'
require 'time'
require 'timeout'
require_relative 'lib/sigma_rest'
require_relative 'lib/omni_rest'

def parse_csv(text)
  CSV.parse(text.to_s)
end

def rows_match?(a, b)
  norm = ->(rows) { rows.map { |r| r.map { |c| Float(c) rescue c.to_s } }.sort_by(&:to_s) }
  norm.call(a) == norm.call(b)
end

def data_rows_match?(omni_csv_text, sigma_csv_text)
  rows_match?(parse_csv(omni_csv_text).drop(1), parse_csv(sigma_csv_text).drop(1))
end

def omni_response_to_rows(resp)
  return [] unless resp.is_a?(Hash)
  rows = resp['rows'] || resp.dig('result', 'rows') || resp.dig('data', 'rows')
  return rows if rows.is_a?(Array) && rows.all? { |r| r.is_a?(Array) }
  if rows.is_a?(Array) && rows.all? { |r| r.is_a?(Hash) }
    return [] if rows.empty?
    keys = rows.first.keys
    return rows.map { |r| keys.map { |k| r[k] } }
  end
  []
end

TRANSIENT_ERROR = /\b(429|408|50[234])\b|Too Many Requests|timed? ?out/i
def transient_error?(message)
  !(message.to_s =~ TRANSIENT_ERROR).nil?
end

def retry_delay(attempts)
  (1.5 * (2**(attempts - 1))) + rand * 0.5
end

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
      return body if body && !body.to_s.empty?
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

def compare_entry(entry, workbook_id)
  omni_resp = OmniRest.post('/api/v1/query/run', body: { 'query' => entry['query'] || {} })
  omni_rows = omni_response_to_rows(omni_resp)
  sigma_csv = sigma_export_csv(workbook_id, entry['chart_element_id'])
  sigma_rows = parse_csv(sigma_csv).drop(1)
  { 'chart' => entry['chart_name'], 'pass' => rows_match?(omni_rows, sigma_rows) }
rescue OmniRest::Error, Sigma::Error, Timeout::Error, Errno::ETIMEDOUT, CSV::MalformedCSVError => e
  { 'chart' => entry['chart_name'], 'pass' => false, 'reason' => e.message.lines.first.to_s.strip[0, 160] }
end

def summarize_parity(results, workbook_id:)
  passed = results.select { |r| r['pass'] }
  failed = results.reject { |r| r['pass'] }
  {
    'workbook_id' => workbook_id,
    'ran_at' => Time.now.utc.iso8601,
    'verified_against' => 'omni_query_run',
    'charts_total' => results.size,
    'charts_pass' => passed.size,
    'charts_fail' => failed.size,
    'pass_names' => passed.map { |r| r['chart'] },
    'fail_names' => failed.map { |r| r['chart'] },
    'status' => failed.empty? ? 'PASS' : 'FAIL'
  }
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--workbook-id ID') { |v| opts[:workbook_id] = v }
    o.on('--plan PATH')      { |v| opts[:plan] = v }
    o.on('--out PATH')       { |v| opts[:out] = v }
    o.on('--fixture PATH', 'TEST ONLY: pre-built results array, bypasses Omni + Sigma export API') { |v| opts[:fixture] = v }
  end.parse!(ARGV)
  abort 'missing --out' if opts[:out].to_s.empty?

  results = if opts[:fixture]
              JSON.parse(File.read(opts[:fixture], encoding: 'UTF-8'))
            else
              plan = JSON.parse(File.read(opts[:plan], encoding: 'UTF-8'))
              plan.map { |entry| compare_entry(entry, opts[:workbook_id]) }
            end
  summary = summarize_parity(results, workbook_id: opts[:workbook_id])
  File.write(opts[:out], JSON.pretty_generate(summary) + "\n")
  exit(summary['status'] == 'PASS' ? 0 : 2)
end
