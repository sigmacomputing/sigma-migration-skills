#!/usr/bin/env ruby
# frozen_string_literal: true

# The single offline Qlik completion contract. A marker alone is insufficient:
# it must be the shared gate's all-pass marker and every underlying accounting,
# parity, PNG, ledger, and generated-report artifact must still reconcile.

require 'json'
require 'optparse'
require_relative 'lib/degradation_ledger'

TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze
PROVENANCE = %w[live engine-export inferred].freeze
PASS_STATES = %w[PASS MATCH PASSED GREEN OK].freeze

opts = {}
OptionParser.new do |parser|
  parser.on('--workdir DIR') { |value| opts[:wd] = File.expand_path(value) }
  parser.on('--workbook-id ID') { |value| opts[:wb] = value }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

def load_json(path)
  JSON.parse(File.read(path))
rescue StandardError
  nil
end

def rows(doc)
  return doc if doc.is_a?(Array)
  return [] unless doc.is_a?(Hash)
  %w[source_objects objects sourceObjects inventory items].each do |key|
    return doc[key] if doc[key].is_a?(Array)
  end
  []
end

def identity(row)
  type = (row['type'] || row['object_type'] || row['kind']).to_s.downcase.strip
  id = (row['id'] || row['source_object_id'] || row['objectId'] ||
        row['sourceId']).to_s.downcase.strip
  name = (row['name'] || row['title'] || row['visual']).to_s.downcase.strip
  [type, id.empty? ? "name:#{name}" : id]
end

def status(row)
  (row['status'] || row['terminal_status'] || row['migration_status'] ||
   row['outcome']).to_s.downcase.tr('_ ', '--').gsub(/-+/, '-')
end

def canonical(doc)
  rows(doc).map { |row| [identity(row), status(row)] }
           .sort_by { |item| [item[0][0], item[0][1], item[1]] }
end

def fail_with(code, message, details = [])
  warn "⛔ #{message}"
  details.each { |detail| warn "   #{detail}" }
  exit code
end

wd = opts[:wd]
success = load_json(File.join(wd, 'phase6-success.json'))
fail_with(2, 'NOT DONE — shared Phase 6 gate did not stamp success.') unless success.is_a?(Hash)
fail_with(3, 'NOT DONE — success marker does not prove a non-empty all-gates run.',
          ["chartCount=#{success['chartCount'].inspect}",
           "gates=#{success['gates'].inspect}"]) unless
  success['chartCount'].to_i.positive? && success['gates'] == 'all-pass'
if opts[:wb] && !success['workbookId'].to_s.empty? && success['workbookId'] != opts[:wb]
  fail_with(4, 'DONE marker belongs to a different workbook.',
            ["marker=#{success['workbookId']} requested=#{opts[:wb]}"])
end

parity = load_json(File.join(wd, 'parity-final.json'))
fail_with(5, 'NOT DONE — parity-final.json is missing or malformed.') unless parity.is_a?(Hash)
total = parity['charts_total'].to_i
passed = parity['charts_pass'].to_i
failed = parity.key?('charts_fail') ? parity['charts_fail'].to_i : total - passed
per_chart = Array(parity['per_chart'])
strict_rows = per_chart.empty? || per_chart.all? do |chart|
  chart['pass'] == true && PASS_STATES.include?(chart['status'].to_s.upcase)
end
strict_parity = parity['status'].to_s.upcase == 'PASS' &&
                parity['strict'] == true &&
                total.positive? && passed == total && failed.zero? &&
                Array(parity['fail_names']).empty? &&
                Array(parity['pending_names']).empty? &&
                parity['charts_stale_explained'].to_i.zero? &&
                parity['divergent'] != true && strict_rows
unless strict_parity
  fail_with(5, 'NOT DONE — parity is not strict, complete, and non-divergent.',
            ["status=#{parity['status'].inspect} strict=#{parity['strict'].inspect}",
             "charts=#{passed}/#{total}, failed=#{failed}, stale=#{parity['charts_stale_explained'].to_i}",
             "fail_names=#{Array(parity['fail_names']).join(', ')}"])
end

report_path = File.join(wd, 'migration-result.json')
census_path = File.join(wd, 'source-object-census.json')
report = load_json(report_path)
census = load_json(census_path)
unless report.is_a?(Hash) && census.is_a?(Hash)
  fail_with(6, 'NOT DONE — source census or migration report is missing/malformed.')
end

census_rows = rows(census)
report_rows = rows(report)
census_complete = census.dig('summary', 'complete') == true &&
                  census.dig('summary', 'accounted').to_i == census.dig('summary', 'total').to_i &&
                  census.dig('summary', 'total').to_i == census_rows.length &&
                  !census_rows.empty? &&
                  census_rows.all? do |row|
                    TERMINAL.include?(status(row)) &&
                      PROVENANCE.include?(row['source_provenance'].to_s) &&
                      row['evidence'].is_a?(Array) && !row['evidence'].empty?
                  end
report_complete = report['verdict'].to_s.upcase != 'RED' &&
                  report.dig('summary', 'complete') == true &&
                  report.dig('summary', 'accounted').to_i == report.dig('summary', 'total').to_i &&
                  report.dig('summary', 'total').to_i == report_rows.length &&
                  Array(report['checks']).any? &&
                  Array(report['checks']).all? { |check| check['status'] == 'PASS' }
unless census_complete && report_complete
  fail_with(6, 'NOT DONE — source census/report is RED, incomplete, or has a failed check.',
            ["census complete=#{census.dig('summary', 'complete').inspect} " \
             "#{census.dig('summary', 'accounted')}/#{census.dig('summary', 'total')}",
             "report verdict=#{report['verdict'].inspect} complete=#{report.dig('summary', 'complete').inspect}",
             "failed checks=#{Array(report['checks']).reject { |check| check['status'] == 'PASS' }.map { |check| check['name'] }.join(', ')}"])
end

unless canonical(census) == canonical(report)
  fail_with(7, 'REPORT CONTRADICTION — migration report does not exactly match source census.',
            ["missing/report-drift=#{(canonical(census) - canonical(report)).first(5).inspect}",
             "extra/report-drift=#{(canonical(report) - canonical(census)).first(5).inspect}"])
end

render = load_json(File.join(wd, 'render-health.json'))
blank = load_json(File.join(wd, 'blank-risk.json'))
similarity = load_json(File.join(wd, 'visual-similarity.json'))
finalization = load_json(File.join(wd, 'qlik-finalization.json'))
png_errors = []
if !render.is_a?(Hash) || render['status'] != 'PASS'
  png_errors << 'render-health.json is missing or not PASS'
else
  expected = render['expected_sigma_pages'].to_i
  sigma_pages = Array(render['sigma_pages'])
  png_errors << 'no expected Sigma pages were checked' unless expected.positive?
  png_errors << "Sigma page health covers #{sigma_pages.length}/#{expected}" if sigma_pages.length < expected
  png_errors << 'one or more Sigma page renders are unhealthy' unless sigma_pages.all? { |row| row['status'] == 'PASS' }
  sources = Array(render['sources'])
  if sources.empty?
    png_errors << 'source PNGs are absent without an explicit waiver' if render['source_page_waiver'].to_s.strip.empty?
  elsif !sources.all? { |row| row['status'] == 'PASS' }
    png_errors << 'one or more Qlik source PNGs are unhealthy'
  end
end
png_errors << 'blank-risk.json is missing/not PASS or records blanks' unless
  blank.is_a?(Hash) && blank['status'] == 'PASS' && blank['blank_count'].to_i.zero? &&
  Array(blank['failures']).empty?
if !similarity.is_a?(Hash) || !%w[PASS WAIVED].include?(similarity['status'])
  png_errors << 'visual-similarity.json is missing or failed'
elsif similarity['status'] == 'PASS'
  png_errors << 'visual similarity does not cover every page' unless
    similarity['pass'] == true &&
    similarity['pages_total'].to_i.positive? &&
    similarity['pages_compared'].to_i == similarity['pages_total'].to_i &&
    Array(similarity['pages']).all? { |page| page['pass'] == true }
elsif similarity['reason'].to_s.strip.empty? || similarity['pass'] != true
  png_errors << 'visual similarity waiver has no explicit reason'
end
unless finalization.is_a?(Hash) && finalization['status'] == 'PASS' &&
       finalization['accounting_exit'].to_i.zero? &&
       finalization['ledger_exit'].to_i.zero? &&
       finalization['report_exit'].to_i.zero? &&
       finalization['report_check_exit'].to_i.zero? &&
       finalization['render_health'] == 'PASS' &&
       finalization['visual_similarity'] == similarity['status'] &&
       finalization['report_verdict'].to_s.upcase == report['verdict'].to_s.upcase &&
       finalization['report_verdict'].to_s.upcase != 'RED' &&
       Array(finalization['failures']).empty?
  png_errors << 'qlik-finalization.json does not prove all accounting/PNG/report checks passed'
end
fail_with(8, 'NOT DONE — PNG/finalization contract failed.', png_errors) unless png_errors.empty?

# Re-run the report's deterministic check so a post-finalization edit to either
# JSON or Markdown cannot ride through on an old qlik-finalization.json.
report_check = system('ruby', File.join(__dir__, 'build-migration-report.rb'),
                      '--workdir', wd, '--inventory', census_path, '--check',
                      out: File::NULL, err: File::NULL)
fail_with(8, 'REPORT CONTRADICTION — generated migration report is stale.') unless report_check

derived = DegradationLedger.derive(wd)
stored = load_json(DegradationLedger.ledger_path(wd))
contradictions = []
unless stored.is_a?(Hash) && stored['entries'].is_a?(Array) && stored['counts'].is_a?(Hash) &&
       !stored['derivedAt'].to_s.empty?
  contradictions << 'degradation-ledger.json is missing or incomplete'
else
  contradictions << 'stored degradation entries differ from fresh derivation' unless stored['entries'] == derived
  actual_counts = Hash.new(0)
  derived.each { |entry| actual_counts[entry['class']] += 1 }
  stored_counts = stored['counts'].transform_keys(&:to_s).transform_values(&:to_i)
  contradictions << 'stored degradation counts differ from fresh derivation' unless stored_counts == actual_counts
  ledger_mtime = File.mtime(DegradationLedger.ledger_path(wd))
  ledger_inputs = %w[coverage.json parity-final.json qlik-controls-coverage.json
                     control-scope.json waivers.json offramps.jsonl].map { |name| File.join(wd, name) }
                                                      .select { |path| File.file?(path) }
  newest_input = ledger_inputs.map { |path| File.mtime(path) }.max
  contradictions << 'degradation ledger is older than an input artifact' if newest_input && ledger_mtime < newest_input
end
contradictions << 'migration report degradation list differs from fresh derivation' unless
  Array(report['degradations']) == derived

accounting_yellow = report_rows.any? { |row| %w[approximated needs-review skipped].include?(status(row)) }
expected_report_verdict = (derived.empty? && !accounting_yellow && Array(report['waivers']).empty?) ? 'GREEN' : 'YELLOW'
contradictions << "report verdict #{report['verdict'].inspect} != #{expected_report_verdict}" unless
  report['verdict'].to_s.upcase == expected_report_verdict

derived_verdict = DegradationLedger.verdict(derived)
{ 'phase6-success.json' => success, 'parity-final.json' => parity }.each do |name, doc|
  claim = doc['verdict'].to_s
  contradictions << "#{name} verdict #{claim.inspect} != #{derived_verdict}" unless
    claim.empty? || claim == derived_verdict
end
if parity.key?('waiver_count') && parity['waiver_count'].to_i != Array(parity['waivers']).length
  contradictions << 'parity waiver_count differs from its waiver list'
end
if success['waivers'].is_a?(Array) && parity['waivers'].is_a?(Array) &&
   success['waivers'] != parity['waivers']
  contradictions << 'phase6 and parity waiver lists differ'
end
fail_with(9, 'REPORT CONTRADICTION — gate/report/ledger claims disagree.', contradictions) unless contradictions.empty?

completion_verdict = report['verdict'].to_s.upcase == 'YELLOW' &&
                     derived_verdict == 'GREEN' ? 'YELLOW' : derived_verdict
puts "✅ DONE — Qlik hard gates, strict parity, PNG health, accounting, and report reconcile. VERDICT: #{completion_verdict}"
puts "   workbook : #{success['workbookId']}"
puts "   charts   : #{passed}/#{total} strict matches"
puts "   gates    : #{success['gates']}"
puts "   objects  : #{census_rows.length}/#{census_rows.length} exactly reconciled"
puts "   ledger   : #{derived.empty? ? 'empty' : "#{derived.length} degradation(s)"}"
exit 0
