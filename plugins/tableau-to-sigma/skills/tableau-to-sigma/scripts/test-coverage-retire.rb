#!/usr/bin/env ruby
# frozen_string_literal: true

# A+B regression: a coverage waiver on a tile that prints no value labels (OEO
# "OV Revenue Trend", RCC "RC State Map") became a resolution-waived
# degradation and forfeited GREEN, although the tile had a view CSV, a seeded
# anchor matched in it and a strict parity pass. lib/coverage_retire.rb moves
# such a waiver to coverage_notes; anything short of full coverage keeps it.

require 'json'
require 'tmpdir'
require 'fileutils'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'coverage_retire'
require 'degradation_ledger'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def w(dir, name, obj)
  File.write(File.join(dir, name), obj.is_a?(String) ? obj : JSON.pretty_generate(obj))
end

def workdir(dir, csv: true, mode: 'strict', pass: ['Net Revenue by Month'], matched_in: 'Net Revenue by Month',
            uncovered: [], gt: false, np_verdict: 'match')
  FileUtils.mkdir_p(File.join(dir, 'views'))
  w(dir, 'views/v-trend.csv', "Month,Net Revenue\n2024-12,1921.23\n") if csv
  w(dir, 'get-workbook.json', { 'workbook' => { 'views' => { 'view' => [{ 'id' => 'v-trend', 'name' => 'OV Revenue Trend' }] } } })
  w(dir, 'chart-provenance.json', { 'elements' => [['el-trend', { 'worksheet' => 'OV Revenue Trend', 'dashboard' => 'Overview' }]] })
  w(dir, 'wb-spec.json', { 'document' => { 'elements' => [{ 'id' => 'el-trend', 'name' => 'Net Revenue by Month' }] } })
  w(dir, 'source-anchors.json', { 'anchors' => [{ 'id' => 's1', 'panel' => 'OV Revenue Trend', 'raw' => '1,921.23',
                                                  'provenance' => 'view-csv', 'kind' => 'number' }],
                                  'coverage_waivers' => [{ 'tile' => 'OV Revenue Trend', 'reason' => 'line chart prints no value labels' }] })
  w(dir, 'anchors-verdict.json', { 'pass' => true, 'checked' => 1, 'anchor_coverage' => { 'uncovered' => uncovered },
                                   'detail' => [{ 'id' => 's1', 'valued' => true, 'provenance' => 'view-csv', 'matched_in' => matched_in }] })
  pf = { 'mode' => mode, 'status' => 'PASS', 'pass_names' => pass, 'fail_names' => [] }
  pf['numeric_parity'] = { 'tiles' => { 'Net Revenue by Month' => { 'verdict' => np_verdict } } } if gt
  w(dir, 'parity-final.json', pf)
  w(dir, 'ground-truth-plan.json', { 'entries' => [{ 'chart' => 'Net Revenue by Month' }],
                                     'coverage_waivers' => [{ 'tile' => 'OV Revenue Trend', 'reason' => 'no oracle' }] }) if gt
end

def waived?(dir)
  DegradationLedger.derive(dir).any? { |e| e['class'] == 'resolution-waived' && e['item'].to_s.start_with?('coverage waiver') }
end

puts 'covered tile: waiver retired, no degradation'
Dir.mktmpdir do |d|
  workdir(d)
  ok(waived?(d), 'before: the waiver is a resolution-waived degradation (the regression)')
  m0 = File.mtime(File.join(d, 'source-anchors.json'))
  r = CoverageRetire.retire!(d)
  ok(r[:retired].map { |x| x['tile'] } == ['OV Revenue Trend'], "retired (#{r.inspect})")
  ok(!waived?(d), 'after: no coverage-waiver degradation')
  sa = JSON.parse(File.read(File.join(d, 'source-anchors.json')))
  ok(!sa.key?('coverage_waivers') && sa['coverage_notes'].first['retired'] == 'covered', 'waiver kept as a non-degrading coverage note')
  ok(sa['anchors'].size == 1, 'anchors untouched')
  ok(File.mtime(File.join(d, 'source-anchors.json')) == m0, 'mtime preserved (anchors-verdict does not go stale)')
  ok(CoverageRetire.retire!(d)[:retired].empty?, 'idempotent')
end

puts 'not fully covered: waiver kept (still degrading)'
{ 'no view CSV' => { csv: false }, 'non-strict parity' => { mode: 'lenient' },
  'tile not in pass_names' => { pass: ['Other'] }, 'no anchor matched in it' => { matched_in: nil },
  'tile listed uncovered' => { uncovered: ['Net Revenue by Month'] } }.each do |label, kw|
  Dir.mktmpdir do |d|
    workdir(d, **kw)
    r = CoverageRetire.retire!(d)
    ok(r[:retired].empty? && r[:kept].size == 1 && waived?(d), "#{label}: kept (#{r[:kept].first&.fetch('why', nil)})")
  end
end

puts 'ground-truth-plan waivers'
Dir.mktmpdir do |d|
  workdir(d, gt: true)
  r = CoverageRetire.retire!(d)
  ok(r[:retired].map { |x| x['file'] }.sort == %w[ground-truth-plan.json source-anchors.json], 'numeric_parity match → retired in both ledgers')
  ok(!waived?(d), 'no coverage-waiver degradation left')
end
Dir.mktmpdir do |d|
  workdir(d, gt: true, np_verdict: 'unverifiable')
  r = CoverageRetire.retire!(d)
  ok(r[:kept].map { |x| x['file'] } == ['ground-truth-plan.json'], 'no numeric match → ground-truth waiver kept')
end

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
