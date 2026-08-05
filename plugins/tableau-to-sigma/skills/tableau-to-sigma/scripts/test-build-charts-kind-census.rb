#!/usr/bin/env ruby
# Regression test for the E5.11 png-read-vs-shelf kind-divergence CENSUS entry
# in build-charts-from-signals.rb (fix-pass, lane C-evidence-chain):
#
#   * a verified png-read.json kind that OVERRIDES the shelf-inferred kind must
#     append { gate:'build-charts', verdict:'kind-override',
#     evidence_kind:'kind-divergence' } to <workdir>/evidence-ledger.jsonl —
#     the census gate 21 and the punch list read (EvidenceLedger.append rescues
#     every StandardError, so without this assertion a wrong workdir key or
#     schema drift would silently drop every census entry);
#   * the override itself lands in the built spec (line-chart, not bar-chart);
#   * no-false-trip: a png-read kind that MATCHES the shelf inference appends
#     NO census entry (divergences only — the ledger is not build chatter).
#
# Deterministic + offline: hand-builds dashboard-layout.json + png-read.json,
# runs the ACTUAL build-charts-from-signals.rb, asserts the spec + the ledger.
#
# Usage: ruby scripts/test-build-charts-kind-census.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# One dashboard, one bar-inferred chart (dim on Cols, measure on Rows).
LAYOUT = [{
  'dashboard' => 'Exec',
  'zones' => [
    { 'id' => 'b1', 'kind' => 'chart', 'caption' => 'Rev by Region', 'chart_kind' => 'bar',
      'mark_class' => 'Bar', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 60,
      'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
      'ref_marks' => [], 'aggregations' => { '[Region]' => 'None', '[Net Revenue]' => 'Sum' },
      'rows_shelf' => { 'fields' => [{ 'caption' => 'Net Revenue', 'role' => 'measure' }] },
      'cols_shelf' => { 'fields' => [{ 'caption' => 'Region', 'role' => 'dim' }] },
      'measures' => [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }], 'calculations' => [] }
  ]
}]
META = { 'worksheets' => {}, 'shared_filters' => [], 'parameters' => [], 'column_aliases' => {},
         'columns_by_guid' => {} }
MMAP = {
  '(?i)^Region$'      => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Net Revenue$' => { 'id' => 'm-rev',    'name' => 'Net Revenue' }
}

# Run the real builder against a workdir whose png-read.json reads the tile as
# `png_kind` (verified). Returns [elements, ledger_entries].
def run_build(png_kind)
  out = nil
  ledger = []
  Dir.mktmpdir do |d|
    File.write("#{d}/layout.json", JSON.dump(LAYOUT))
    File.write("#{d}/meta.json",   JSON.dump(META))
    File.write("#{d}/mm.json",     JSON.dump(MMAP))
    File.write("#{d}/get-workbook.json",
               JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Rev by Region' }] }))
    File.write("#{d}/png-read.json",
               JSON.dump('verified' => true,
                         'tiles' => [{ 'title' => 'Rev by Region', 'kind' => png_kind }]))
    Dir.mkdir("#{d}/views")
    File.write("#{d}/views/v1.csv", "Region,Net Revenue\nWest,100\nEast,50\n")
    o = "#{d}/specs.json"
    IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', "#{d}/layout.json",
              '--meta', "#{d}/meta.json", '--master-map', "#{d}/mm.json",
              '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
              '--out', o], err: %i[child out], &:read)
    out = JSON.parse(File.read(o)) if File.exist?(o)
    lp = "#{d}/evidence-ledger.jsonl"
    ledger = File.exist?(lp) ? File.readlines(lp).map { |l| JSON.parse(l) rescue nil }.compact : []
  end
  abort 'build produced no spec' unless out
  els = out.is_a?(Array) ? out : (out['elements'] || (out['pages'] || []).flat_map { |p| p['elements'] || [] })
  [els, ledger]
end

# ---- trip: png-read 'line-chart' vs shelf-inferred 'bar' → census entry ------
puts '-- png-read line-chart overrides shelf bar → kind-divergence census entry --'
els, ledger = run_build('line-chart')
chart = els.find { |e| e['name'].to_s =~ /Region/ && e['kind'].to_s.end_with?('-chart') }
check(!chart.nil? && chart['kind'] == 'line-chart',
      "the verified png-read kind is BUILT (line-chart, got #{chart && chart['kind'].inspect})", fails)
div = ledger.find { |e| e['gate'] == 'build-charts' && e['evidence_kind'] == 'kind-divergence' }
check(!div.nil?, 'kind-divergence census entry lands in <workdir>/evidence-ledger.jsonl', fails)
check(div && div['verdict'] == 'kind-override' && div['evidence_path'] == 'png-read.json',
      "entry carries verdict:kind-override + the png-read pointer (got #{div && div['verdict']})", fails)
check(div && div['detail'].is_a?(Hash) && div['detail']['tile'] == 'Rev by Region' &&
      div['detail']['png_kind'] == 'line' && div['detail']['shelf_kind'] == 'bar',
      "detail names the tile + both kinds (got #{div && div['detail'].inspect})", fails)
check(div && div['at'].to_s =~ /Z\z/, 'census entry is timestamped', fails)

# ---- no-false-trip: png-read agrees with the shelf → NO census entry ---------
puts '-- png-read bar-chart matches shelf bar → NO census entry --'
els2, ledger2 = run_build('bar-chart')
chart2 = els2.find { |e| e['name'].to_s =~ /Region/ && e['kind'].to_s.end_with?('-chart') }
check(!chart2.nil? && chart2['kind'] == 'bar-chart', 'matching kind builds unchanged (bar-chart)', fails)
check(ledger2.none? { |e| e['evidence_kind'] == 'kind-divergence' },
      'no kind-divergence entry when png-read agrees with the shelf inference', fails)

puts
if fails.empty?
  puts 'ALL PASS — png-read-vs-shelf kind divergences are census entries (and agreements are not)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
