#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline terminal contract for a Sisense migration.
# Exit 2 marker; 3 parity; 4 missing/malformed accounting; 5 census drift;
# 6 stale report/render/ledger; 7 contradictory completion claims.

require 'json'
require 'optparse'
require_relative 'lib/degradation_ledger'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze

opts = {}
OptionParser.new do |parser|
  parser.on('--workdir DIR') { |value| opts[:workdir] = value }
  parser.on('--workbook-id ID') { |value| opts[:workbook_id] = value }
end.parse!
abort '--workdir required' if opts[:workdir].to_s.empty?

workdir = File.expand_path(opts[:workdir])

def read_json(path)
  JSON.parse(File.read(path))
rescue StandardError
  nil
end

def rows(document)
  return [] unless document.is_a?(Hash)
  value = document['source_objects'] || document['objects']
  value.is_a?(Array) ? value : []
end

def status(row)
  (row['terminal_status'] || row['status']).to_s.downcase.tr('_', '-')
end

def identity(row)
  type = (row['type'] || row['object_type'] || row['source_type']).to_s.downcase
  id = (row['id'] || row['source_object_id'] || row['object_id']).to_s.downcase
  name = (row['name'] || row['visual'] || row['title']).to_s.downcase
  [type, id.empty? ? "name:#{name}" : id, status(row)]
end

marker_path = File.join(workdir, 'phase6-success.json')
marker = read_json(marker_path)
unless marker.is_a?(Hash) && marker['gates'].to_s == 'all-pass'
  warn 'NOT DONE: shared assert-phase6-ran all-pass marker is missing or invalid'
  exit 2
end
if opts[:workbook_id] && marker['workbookId'].to_s != opts[:workbook_id]
  warn 'NOT DONE: all-pass marker belongs to a different workbook'
  exit 2
end

parity_path = File.join(workdir, 'parity-final.json')
parity = read_json(parity_path)
total = parity.is_a?(Hash) ? parity['charts_total'].to_i : 0
passed = parity.is_a?(Hash) ? parity['charts_pass'].to_i : -1
failed = parity.is_a?(Hash) ? parity['charts_fail'].to_i : -1
strict = parity.is_a?(Hash) && parity['strict_complete'] == true
unless parity.is_a?(Hash) && %w[PASS GREEN].include?(parity['status'].to_s.upcase) &&
       total.positive? && passed == total && failed.zero? && strict
  warn "NOT DONE: strict parity is incomplete (#{passed}/#{total}, fail=#{failed})"
  exit 3
end

census_path = File.join(workdir, 'source-object-census.json')
report_path = File.join(workdir, 'migration-result.json')
census = read_json(census_path)
report = read_json(report_path)
unless census.is_a?(Hash) && report.is_a?(Hash)
  warn 'NOT DONE: source-object-census.json or migration-result.json is missing/malformed'
  exit 4
end
census_rows = rows(census)
report_rows = rows(report)
unless census.dig('summary', 'complete') == true && !census_rows.empty? &&
       census_rows.all? { |row| TERMINAL.include?(status(row)) } &&
       report.dig('summary', 'complete') == true &&
       report.dig('summary', 'accounted').to_i == report.dig('summary', 'total').to_i
  warn 'NOT DONE: accounting/report is incomplete or has a non-terminal object'
  exit 4
end

census_canonical = census_rows.map { |row| identity(row) }.sort
report_canonical = report_rows.map { |row| identity(row) }.sort
unless census_canonical == report_canonical
  warn 'NOT DONE: migration report does not exactly match the source census'
  exit 5
end

render_path = File.join(workdir, 'render-health.json')
ledger_path = File.join(workdir, 'degradation-ledger.json')
finalize_path = File.join(workdir, 'sisense-report-finalization.json')
render = read_json(render_path)
ledger = read_json(ledger_path)
finalization = read_json(finalize_path)
unless render.is_a?(Hash) && ledger.is_a?(Hash) && finalization.is_a?(Hash)
  warn 'NOT DONE: render health, degradation ledger, or finalization record is missing'
  exit 6
end

# Render evidence must be newer than every PNG it claims to have inspected.
png_paths = Array(render['images']).filter_map { |row| row.is_a?(Hash) ? row['path'] : nil }
png_mtimes = png_paths.filter_map { |path| File.mtime(path) if File.file?(path) }
if (!png_mtimes.empty? && File.mtime(render_path) < png_mtimes.max) ||
   File.mtime(ledger_path) < [File.mtime(census_path), File.mtime(parity_path)].max ||
   File.mtime(report_path) < [File.mtime(census_path), File.mtime(parity_path),
                              File.mtime(ledger_path), File.mtime(render_path)].max ||
   File.mtime(finalize_path) < File.mtime(report_path)
  warn 'NOT DONE: completion ledger/render/report is stale relative to its inputs'
  exit 6
end

contradictions = []
contradictions << 'render-health status is not PASS' unless render['status'].to_s.upcase == 'PASS'
contradictions << 'report finalization status is not PASS' unless finalization['status'].to_s.upcase == 'PASS'
contradictions << 'migration-result verdict is RED' if report['verdict'].to_s.upcase == 'RED'
derived = DegradationLedger.derive(workdir)
stored_entries = ledger['entries']
unless stored_entries.is_a?(Array)
  warn 'NOT DONE: degradation-ledger.json has no entries array'
  exit 6
end
if stored_entries != derived
  contradictions << "stored degradation ledger has #{stored_entries.length} entries; fresh derivation has #{derived.length}"
end
if report['degradations'].is_a?(Array) && report['degradations'] != derived
  contradictions << 'migration-result degradation ledger differs from fresh derivation'
end
accounting_yellow = report_rows.any? do |row|
  %w[approximated needs-review skipped].include?(status(row))
end
expected_report_verdict = derived.empty? && !accounting_yellow ? 'GREEN' : 'YELLOW'
unless report['verdict'].to_s.upcase == expected_report_verdict
  contradictions << "migration-result verdict #{report['verdict'].inspect} contradicts #{expected_report_verdict}"
end
state = read_json(File.join(workdir, 'run-state.json')) || {}
contradictions << 'dry-run state cannot be complete' if state['mode'] == 'dry-run' && state['complete'] == true
contradictions << 'run-state says POST incomplete' if state.key?('post_complete') && state['post_complete'] != true
contradictions << 'run-state says parity incomplete' if state.key?('parity_complete') && state['parity_complete'] != true
contradictions << 'run-state says render incomplete' if state.key?('render_complete') && state['render_complete'] != true
unless contradictions.empty?
  warn "REPORT CONTRADICTION: #{contradictions.join('; ')}"
  exit 7
end

puts "DONE: Sisense hard gates, strict parity, accounting, render, ledger, and report reconcile"
puts "  workbook: #{marker['workbookId']}"
puts "  charts: #{passed}/#{total}"
puts "  objects: #{census_rows.length}/#{census_rows.length}"
exit 0
