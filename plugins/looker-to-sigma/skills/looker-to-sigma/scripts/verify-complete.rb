#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the single offline "is this migration actually done?" check.
#
# A Looker→Sigma conversion is done ONLY when migrate-looker.py finished
# with a real, parity-passing workbook — recorded by the assert-phase6-ran hard
# gate stamping <workdir>/phase6-success.json (workbookId + chartCount +
# gates=all-pass) at exit 0 — AND the final migration report reconciles exactly
# with the source-object census and mechanically re-derived degradation ledger.
# "Done" is a fact on disk, not "pages look right". Run before claiming success
# or handing off.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — phase6-success.json present (gates passed; chartCount > 0 when recorded)
#   2  NOT DONE — no success marker (conversion didn't complete / was hand-built)
#   3  NOT DONE — marker present but 0 chart elements AND no gate record (empty)
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked
#   5  NOT DONE — migration-result.json or source-object-census.json is absent/bad
#   6  NOT DONE — report/census is RED, incomplete, or has non-terminal objects
#   7  NOT DONE — report identities/statuses do not exactly match the census
#   8  REPORT CONTRADICTION — report/ledger/phase6/waiver claims disagree

require 'json'
require 'optparse'
require_relative 'lib/degradation_ledger'

TERMINAL_STATUSES = %w[migrated approximated needs-review skipped not-applicable].freeze

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--workbook-id ID') { |v| opts[:wb] = v }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

wd = opts[:wd]
succ = File.join(wd, 'phase6-success.json')
unless File.exist?(succ)
  warn '⛔ NOT DONE — no phase6-success.json in the workdir.'
  warn '   The conversion did not complete a parity-passing build (assert-phase6-ran did not pass).'
  warn '   If pages exist but are empty, they were NOT produced by a real migrate-looker.rb run —'
  warn "   re-run the orchestrator (never hand-author a workbook). Workdir checked: #{opts[:wd]}"
  exit 2
end

sj = begin
  JSON.parse(File.read(succ))
rescue StandardError
  {}
end

# Tolerant empty-check: fail only when there are 0 charts AND no gate record. A
# stamp from the shared assert-phase6-ran gate always carries gates=all-pass (the
# gate enforced charts_total>0 to be stamped), so a missing/zero chartCount with
# a gate record still means a real green.
if sj['chartCount'].to_i <= 0 && sj['gates'].to_s.empty?
  warn '⛔ NOT DONE — success marker present but 0 chart elements and no gate record (empty workbook).'
  exit 3
end
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  exit 4
end

def load_json(path)
  JSON.parse(File.read(path))
rescue StandardError
  nil
end

def object_rows(doc)
  return doc if doc.is_a?(Array)
  return [] unless doc.is_a?(Hash)

  %w[source_objects sourceObjects objects inventory items].each do |key|
    value = doc[key]
    return value if value.is_a?(Array)
    next unless value.is_a?(Hash)
    return value.keys.sort.flat_map do |type|
      Array(value[type]).select { |row| row.is_a?(Hash) }.map do |row|
        row.key?('type') ? row : row.merge('type' => type.to_s.sub(/ies\z/, 'y').sub(/s\z/, ''))
      end
    end
  end
  []
end

def object_status(row)
  %w[terminal_status terminalStatus migration_status migrationStatus
     accounting_status accountingStatus status outcome disposition result].each do |key|
    value = row[key]
    return value.to_s.downcase.tr('_ ', '--').gsub(/-+/, '-') unless value.to_s.empty?
  end
  ''
end

def object_identity(row)
  type = (row['type'] || row['object_type'] || row['objectType'] ||
          row['source_type'] || row['sourceType'] || row['kind']).to_s.downcase.strip
  id = (row['id'] || row['object_id'] || row['objectId'] ||
        row['source_object_id'] || row['sourceObjectId'] ||
        row['source_id'] || row['sourceId'] || row['luid'] || row['guid']).to_s.strip
  name = (row['name'] || row['object_name'] || row['objectName'] ||
          row['source_object_name'] || row['sourceObjectName'] ||
          row['title'] || row['visual'] || row['control']).to_s.strip
  identity = id.empty? ? "name:#{name.downcase}" : id.downcase
  [type, identity]
end

def canonical_objects(doc)
  object_rows(doc).map do |row|
    [object_identity(row), object_status(row)]
  end.sort_by { |identity, status| [identity[0], identity[1], status] }
end

report_path = File.join(wd, 'migration-result.json')
census_path = File.join(wd, 'source-object-census.json')
missing = [report_path, census_path].reject { |path| File.file?(path) }
unless missing.empty?
  warn "⛔ NOT DONE — missing completion contract: #{missing.map { |p| File.basename(p) }.join(', ')}."
  warn '   Re-run migrate-looker.py so final accounting and build-migration-report.rb run.'
  exit 5
end

report = load_json(report_path)
census = load_json(census_path)
unless report.is_a?(Hash) && census.is_a?(Hash)
  warn '⛔ NOT DONE — migration-result.json or source-object-census.json is malformed.'
  exit 5
end

report_rows = object_rows(report)
census_rows = object_rows(census)
report_complete = report.dig('summary', 'complete') == true &&
                  report.dig('summary', 'accounted').to_i == report.dig('summary', 'total').to_i
census_complete = census.dig('summary', 'complete') != false &&
                  !census_rows.empty? &&
                  census_rows.all? { |row| TERMINAL_STATUSES.include?(object_status(row)) }
if report['verdict'].to_s.upcase == 'RED' || census['verdict'].to_s.upcase == 'RED' ||
   !report_complete || !census_complete ||
   report_rows.any? { |row| !TERMINAL_STATUSES.include?(object_status(row)) }
  warn '⛔ NOT DONE — migration report/source census is RED or incomplete.'
  warn "   report: verdict=#{report['verdict'].inspect} complete=#{report.dig('summary', 'complete').inspect} " \
       "accounted=#{report.dig('summary', 'accounted').inspect}/#{report.dig('summary', 'total').inspect}"
  warn "   census: objects=#{census_rows.length} complete=#{census.dig('summary', 'complete').inspect}"
  exit 6
end

report_objects = canonical_objects(report)
census_objects = canonical_objects(census)
unless report_objects == census_objects
  warn '⛔ NOT DONE — migration-result.json does not exactly match source-object-census.json.'
  (census_objects - report_objects).first(10).each do |identity, status|
    warn "   missing/report-drift: #{identity.join(':')} status=#{status}"
  end
  (report_objects - census_objects).first(10).each do |identity, status|
    warn "   extra/report-drift: #{identity.join(':')} status=#{status}"
  end
  exit 7
end

derived = DegradationLedger.derive(wd)
derived_verdict = DegradationLedger.verdict(derived)
parity = load_json(File.join(wd, 'parity-final.json')) || {}
stored_ledger = load_json(DegradationLedger.ledger_path(wd))
contradictions = []
run_state = load_json(File.join(wd, 'migrate-state.json')) || {}
factory_labeled = derived_verdict == 'GREEN' && run_state['tier'].to_s == 'S' &&
                  parity['verdict_by'].to_s == 'builder-self-attested'
expected_phase6_verdict = factory_labeled ? 'GREEN (factory, self-attested)' : derived_verdict

if stored_ledger.is_a?(Hash) && stored_ledger['entries'].is_a?(Array) &&
   stored_ledger['entries'] != derived
  contradictions << "degradation-ledger.json has #{stored_ledger['entries'].length} entries but fresh derivation has #{derived.length}"
end
if report['degradations'].is_a?(Array) && report['degradations'] != derived
  contradictions << "migration-result.json degradation ledger has #{report['degradations'].length} entries but fresh derivation has #{derived.length}"
end

accounting_yellow = report_rows.any? do |row|
  %w[approximated needs-review skipped].include?(object_status(row))
end
expected_report_verdict = derived.empty? && !accounting_yellow ? 'GREEN' : 'YELLOW'
if report['verdict'].to_s.upcase != expected_report_verdict
  contradictions << "migration-result.json claims #{report['verdict'].inspect} but the ledger requires #{expected_report_verdict}"
end

{ 'phase6-success.json' => sj, 'parity-final.json' => parity }.each do |name, doc|
  claim = doc['verdict'].to_s
  next if claim.empty? || claim == expected_phase6_verdict
  contradictions << "#{name} claims verdict #{claim.inspect} but the artifacts require #{expected_phase6_verdict}"
end

if parity.key?('waiver_count') && parity['waivers'].is_a?(Array) &&
   parity['waiver_count'].to_i != parity['waivers'].length
  contradictions << "parity-final.json claims waiver_count=#{parity['waiver_count']} but lists #{parity['waivers'].length}"
end
if sj['waivers'].is_a?(Array) && parity['waivers'].is_a?(Array) && sj['waivers'] != parity['waivers']
  contradictions << 'phase6-success.json and parity-final.json waiver censuses differ'
end
if parity.key?('waiver_count') && parity['waiver_count'].to_i.zero? &&
   derived.any? { |entry| %w[quality-waiver recorded-escape].include?(entry['class']) }
  contradictions << 'parity-final.json claims zero waivers but artifacts record waiver/escape degradations'
end

reported_waivers = Array(report['waivers']).map do |entry|
  entry.is_a?(Hash) ? (entry['flag'] || entry['reason'] || entry['name']).to_s : entry.to_s
end.reject(&:empty?).uniq.sort
phase6_waivers = Array(parity['waivers']).map { |entry| entry.is_a?(Hash) ? (entry['flag'] || entry['reason']).to_s : entry.to_s }
                                     .reject(&:empty?)
waiver_doc = load_json(File.join(wd, 'waivers.json'))
waiver_doc = waiver_doc['waivers'] if waiver_doc.is_a?(Hash)
artifact_waivers = Array(waiver_doc).map do |entry|
  entry.is_a?(Hash) ? (entry['flag'] || entry['reason'] || entry['name']).to_s : entry.to_s
end
expected_waivers = (phase6_waivers + artifact_waivers).reject(&:empty?).uniq.sort
if report.key?('waivers') && reported_waivers != expected_waivers
  contradictions << "migration-result.json waiver census #{reported_waivers.inspect} differs from artifacts #{expected_waivers.inspect}"
end

unless contradictions.empty?
  warn '⛔ REPORT CONTRADICTION — report/ledger/phase6/waiver claims disagree:'
  contradictions.each { |message| warn "   • #{message}" }
  warn "   derived verdict: #{derived_verdict}"
  DegradationLedger.report_lines(derived).each { |line| warn "   #{line}" }
  exit 8
end

completion_verdict = report['verdict'].to_s.upcase == 'YELLOW' &&
                     derived_verdict == 'GREEN' ? 'YELLOW' : expected_phase6_verdict
puts "✅ DONE — hard gates and completion accounting reconcile. VERDICT: #{completion_verdict}"
puts "   workbook : #{sj['workbookId']}"
puts "   charts   : #{sj['chartCount']}"
puts "   gates    : #{sj['gates']}"
puts "   stamped  : #{sj['generatedAt']}"
puts "   objects  : #{report_objects.length}/#{report_objects.length} exactly reconciled"
if derived.empty?
  puts '   ledger   : empty'
else
  puts "   ledger   : #{derived.length} degradation(s)"
  DegradationLedger.report_lines(derived).each { |line| puts "   #{line}" }
end
exit 0
