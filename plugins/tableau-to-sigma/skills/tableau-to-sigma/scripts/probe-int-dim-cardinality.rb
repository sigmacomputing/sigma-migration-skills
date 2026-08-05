#!/usr/bin/env ruby
# frozen_string_literal: true
# probe-int-dim-cardinality.rb — PR-18 OPTIONAL confirmation for integer-coded
# dimension detection. The .twb signal (shelf role = dimension + datatype =
# integer, surfaced by parse-twb-layout as `integer_dim`) is the PRIMARY
# detector and stands alone. This script adds a bounded warehouse confirmation:
# a low COUNT(DISTINCT <col>) is corroborating evidence that an integer column
# is a discrete DIMENSION KEY (a store/promo/site roster) rather than a
# continuous measure. It NEVER gates: it annotates the candidates ledger.
#
# Execution reuses the established warehouse-SQL seam (same one-shot probe
# workbook + CSV export + delete as probe-join-keys.rb / probe-custom-sql-
# columns.rb — no new warehouse credential path). Offline tests use --fixture
# DIR, the same `entry-<index>.json` convention as probe-join-keys.rb.
#
# Ledger — <workdir>/integer-dim-decode.json (build-charts-from-signals.rb emits
# it when it detects an integer-dim control):
#   { "version":1, "candidates":[ { "controlId":, "name":, "column":,
#       "table": "<DB.SCHEMA.TABLE>"?, "warehouse_column": "<COL>"? } ] }
# A candidate needs both `table` and `warehouse_column` to probe live; without
# them the entry is left status "unresolved-target" (the .twb detection still
# holds). The probe writes back per candidate:
#   { "cardinality": <distinct>, "confirmed": <distinct <= --max-cardinality>,
#     "probed_at":, "probe_sql":, ["probe_error":] }
#
# Usage:
#   ruby scripts/probe-int-dim-cardinality.rb --workdir <W> \
#     [--ledger PATH] [--max-cardinality N]      # default 1000
#     ( --connection-id <id> [--folder-id <id>]  # live probe via Sigma
#     | --fixture DIR )                          # offline: DIR/entry-<i>.json
#                                                #   {"distinct": N} | {"error": "..."}
#
# Exit codes: 0 = ran (probed / skipped cleanly — NEVER gates); 1 = bad
# invocation. A probe error leaves the entry status "error" and still exits 0
# (the detection is independent; this is confirmation only).
require 'json'
require 'csv'
require 'optparse'
require 'securerandom'

opts = { max_cardinality: 1000 }
OptionParser.new do |p|
  p.on('--workdir DIR')        { |v| opts[:workdir] = v }
  p.on('--ledger PATH')        { |v| opts[:ledger] = v }
  p.on('--connection-id ID')   { |v| opts[:conn] = v }
  p.on('--folder-id ID')       { |v| opts[:folder] = v }
  p.on('--fixture DIR')        { |v| opts[:fixture] = v }
  p.on('--max-cardinality N', Integer) { |v| opts[:max_cardinality] = v }
end.parse!

ledger_path = opts[:ledger] || (opts[:workdir] && File.join(opts[:workdir], 'integer-dim-decode.json'))
abort 'usage: probe-int-dim-cardinality.rb --workdir <W> (--connection-id <id> | --fixture DIR) [--max-cardinality N]' unless ledger_path
unless File.exist?(ledger_path)
  warn "probe-int-dim-cardinality: no #{ledger_path} — no integer-dim control detected on this workbook; nothing to confirm."
  exit 0
end
abort 'provide --fixture DIR (offline) or --connection-id <id> (live probe)' unless opts[:fixture] || opts[:conn]

doc = JSON.parse(File.read(ledger_path))
candidates = doc.is_a?(Hash) ? Array(doc['candidates']) : []
now_utc = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

def distinct_sql(table, col)
  "SELECT COUNT(DISTINCT #{col}) AS DISTINCT_KEYS FROM #{table}"
end

def fixture_result(dir, idx)
  f = File.join(dir, "entry-#{idx}.json")
  return { 'error' => "no fixture #{File.basename(f)} in #{dir}" } unless File.exist?(f)
  JSON.parse(File.read(f))
rescue JSON::ParserError => e
  { 'error' => "fixture unparseable: #{e.message[0, 80]}" }
end

# One-shot probe-workbook Custom SQL runner (the shared warehouse seam — mirrors
# probe-join-keys.rb sigma_sql_rows; kept self-contained so that script stays
# byte-identical). Created ids are registered in the local probe registry
# BEFORE the first export and the ensure-DELETE appends the matching cleaned
# record (E7.1).
def sigma_distinct(conn_id, folder_id, sql, workdir: nil)
  spec = {
    'name' => "_probe_intdim_#{SecureRandom.hex(4)}", 'schemaVersion' => 1,
    'pages' => [{ 'id' => 'p1', 'name' => 'p1', 'elements' => [{
      'id' => 'probe', 'kind' => 'table', 'name' => 'Probe',
      'source' => { 'kind' => 'sql', 'connectionId' => conn_id, 'statement' => sql },
      'columns' => [{ 'id' => 'c-distinct-keys', 'name' => 'DISTINCT_KEYS', 'formula' => '[Custom SQL/DISTINCT_KEYS]' }]
    }] }]
  }
  spec['folderId'] = folder_id if folder_id
  r = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec))
  wb_id = r.is_a?(Hash) ? r['workbookId'] : nil
  raise "probe workbook POST failed: #{r.inspect[0, 160]}" unless wb_id
  ProbeRegistry.created(wb_id, name: spec['name'], workdir: workdir,
                        script: 'probe-int-dim-cardinality.rb')
  begin
    exp = Sigma.request(:post, "/v2/workbooks/#{wb_id}/export",
                        body: JSON.generate('elementId' => 'probe', 'format' => { 'type' => 'csv' }))
    qid = exp && exp['queryId']
    raise "export POST returned no queryId: #{exp.inspect[0, 160]}" unless qid
    csv = nil
    30.times do |i|
      sleep(i.zero? ? 0.5 : 1)
      begin
        b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        (csv = b) && break if b && !b.to_s.empty?
      rescue Sigma::Error => e
        raise unless e.message.lines.first.to_s =~ /\b404\b/
      end
    end
    raise 'export did not complete in 30s' unless csv
    row = CSV.parse(csv, headers: true).first
    { 'distinct' => row && row['DISTINCT_KEYS'].to_i }
  ensure
    begin
      Sigma.request(:delete, "/v2/files/#{wb_id}")
      ProbeRegistry.cleaned(wb_id, workdir: workdir, via: 'ensure')
    rescue StandardError => e
      ProbeRegistry.cleaned(wb_id, workdir: workdir, via: 'ensure',
                            outcome: e.message.lines.first.to_s =~ /\b404\b/ ? '404' : 'failed')
    end
  end
rescue StandardError => e
  { 'error' => e.message.to_s.gsub(/\s+/, ' ').strip[0, 240] }
end

if opts[:conn]
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
  require 'probe_registry'
end

probed = 0
candidates.each_with_index do |c, i|
  table = c['table'].to_s
  col   = c['warehouse_column'].to_s
  if !opts[:fixture] && (table.empty? || col.empty?)
    c['cardinality_status'] = 'unresolved-target'
    puts "  SKIP  ##{i} '#{c['name']}' — no {table, warehouse_column} to probe (the .twb detection still holds)"
    next
  end
  sql = distinct_sql(table.empty? ? '<table>' : table, col.empty? ? '<col>' : col)
  c['probe_sql'] = sql
  res = opts[:fixture] ? fixture_result(opts[:fixture], i) : sigma_distinct(opts[:conn], opts[:folder], sql, workdir: opts[:workdir])
  c['probed_at'] = now_utc
  if res['error']
    c['cardinality_status'] = 'error'
    c['probe_error'] = res['error']
    puts "  ERROR ##{i} '#{c['name']}' — #{res['error']}"
    next
  end
  n = res['distinct']
  c['cardinality'] = n
  c['confirmed'] = !n.nil? && n <= opts[:max_cardinality]
  c['cardinality_status'] = c['confirmed'] ? 'confirmed-low-cardinality' : 'high-cardinality'
  probed += 1
  puts "  #{c['confirmed'] ? 'CONFIRM' : 'HICARD'} ##{i} '#{c['name']}' — COUNT(DISTINCT #{col.empty? ? '<col>' : col}) = #{n}" \
       " (threshold #{opts[:max_cardinality]})#{c['confirmed'] ? ' → integer-coded dimension confirmed' : ' → not obviously a dimension key; the .twb signal still drove the decode'}"
end

File.write(ledger_path, JSON.pretty_generate(doc))
puts "probe-int-dim-cardinality: #{candidates.size} candidate(s), #{probed} probed. Ledger: #{ledger_path}"
exit 0
