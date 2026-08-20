#!/usr/bin/env ruby
# Discover a Mode Report's Queries + Charts + Filters, sampling each Query's
# live output columns via a real run (Mode has no static schema endpoint for
# a query's result set — see docs/superpowers/specs/2026-07-31-mode-to-sigma-design.md).
#
#   ruby scripts/mode-discover.rb --probe
#   ruby scripts/mode-discover.rb --report <report-token>
require 'optparse'
require 'json'
require 'csv'
require 'fileutils'
require_relative 'lib/mode_rest'

OUT = ENV['MODE_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# Wall-clock cap on run_report_and_fetch_csvs's state-poll loop, matching the
# 60s bound used by this converter's other export/render poll loops (e.g.
# sigma-export-png.py's export-poll) — a stuck Mode run must fail loudly
# rather than poll every 2s forever.
RUN_POLL_TIMEOUT = 60

def dump(name, obj)
  FileUtils.mkdir_p(OUT)
  path = File.join(OUT, name)
  File.write(path, JSON.pretty_generate(obj))
  warn "  wrote #{path}"
end

def columns_from_csv_header(csv_text)
  header = csv_text.lines.first.to_s.chomp
  CSV.parse_line(header) || []
end

def normalize_query(raw, columns:)
  { 'token' => raw['token'], 'name' => raw['name'], 'raw_query' => raw['raw_query'],
    'data_source_id' => raw['data_source_id'], 'columns' => columns }
end

def normalize_chart(raw, query_token)
  { 'token' => raw['token'], 'query_token' => query_token, 'view' => raw['view'] }
end

# HAL commonly omits the `_embedded` key ENTIRELY when a collection is empty
# (not even `_embedded: {things: []}` -- the key can be absent outright). A
# Mode Report with a query that has zero charts is routine (e.g. a helper/
# staging query never charted directly), not an edge case -- a bare
# `resp['_embedded']['charts']` crashes with NoMethodError on ordinary
# content. Every HAL-collection accessor below goes through `dig` with an `||
# []` (or `|| {}`) default instead.
def data_source_names(acct_ds_response)
  (acct_ds_response.dig('_embedded', 'data_sources') || []).map { |d| d['name'] }
end

def queries_raw_for_report(report_queries_response)
  report_queries_response.dig('_embedded', 'queries') || []
end

def charts_for_query(charts_response, query_token)
  (charts_response.dig('_embedded', 'charts') || []).map { |c| normalize_chart(c, query_token) }
end

# Report Filters degrade to [] the same way for BOTH failure modes: a genuine
# Mode::Error (e.g. the endpoint 404s for this report) AND a missing-_embedded
# response that would otherwise raise NoMethodError past the dig-safety above
# -- the rescue is widened to NoMethodError too as defense in depth (the dig
# call already prevents this in practice, but a nil/non-Hash response from
# Mode.get would still raise NoMethodError on `.dig` itself).
def report_filters_for(report_token)
  Mode.get("/api/#{Mode.account}/reports/#{report_token}/report_filters").dig('_embedded', 'report_filters') || []
rescue Mode::Error, NoMethodError => e
  warn "report_filters fetch failed for #{report_token}: #{e.message}"
  []
end

# Triggers a fresh run of the whole report and returns {query_token => csv_text}
# for every query in it — the one shared primitive both discovery (column
# names, via columns_from_csv_header below) and verify-parity.rb (Task 8,
# full row values) build on, so the run-and-poll logic lives in exactly one
# place.
def run_report_and_fetch_csvs(report_token)
  run = Mode.post("/api/#{Mode.account}/reports/#{report_token}/runs", body: {})
  deadline = Time.now + RUN_POLL_TIMEOUT
  loop do
    break if %w[succeeded completed failed cancelled].include?(run['state'])
    if Time.now > deadline
      raise Mode::Error, "report run #{run['token']} timed out after #{RUN_POLL_TIMEOUT}s " \
                          "waiting for a terminal state (last seen state: #{run['state']})"
    end
    sleep 2
    run = Mode.follow(run, 'self')
  end
  raise Mode::Error, "report run #{run['token']} ended in state #{run['state']}" unless
    %w[succeeded completed].include?(run['state'])

  query_runs = Mode.follow(run, 'query_runs').dig('_embedded', 'query_runs') || []
  query_runs.each_with_object({}) do |qr, acc|
    query_token = qr.dig('_links', 'query', 'href').to_s.split('/').last
    acc[query_token] = Mode.get_raw(qr.dig('_links', 'content', 'href'))
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--probe')          { opts[:probe] = true }
    o.on('--report TOKEN')   { |v| opts[:report] = v }
  end.parse!(ARGV)

  if opts[:probe]
    acct = Mode.get("/api/#{Mode.account}")
    ds   = Mode.get("/api/#{Mode.account}/data_sources")
    warn "account: #{acct['username']} (plan #{acct['organization_plan_code'] rescue 'unknown'})"
    warn "data sources: #{data_source_names(ds).join(', ')}"
    exit 0
  end

  if opts[:report]
    report = Mode.get("/api/#{Mode.account}/reports/#{opts[:report]}")
    queries_raw = queries_raw_for_report(Mode.follow(report, 'queries'))
    csv_by_query = run_report_and_fetch_csvs(opts[:report])
    columns_by_query = csv_by_query.transform_values { |csv| columns_from_csv_header(csv) }

    queries = queries_raw.map { |q| normalize_query(q, columns: columns_by_query.fetch(q['token'], [])) }
    charts = queries_raw.flat_map do |q|
      charts_for_query(Mode.get("/api/#{Mode.account}/reports/#{opts[:report]}/queries/#{q['token']}/charts"), q['token'])
    end
    filters = report_filters_for(opts[:report])

    dump("report-#{opts[:report]}.json", {
      'report'  => { 'token' => report['token'], 'name' => report['name'], 'space_token' => report['space_token'] },
      'queries' => queries, 'charts' => charts, 'filters' => filters
    })
  end
end
