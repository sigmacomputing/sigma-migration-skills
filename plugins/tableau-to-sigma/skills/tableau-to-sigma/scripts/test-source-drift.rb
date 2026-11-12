#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof: the warehouse loaded between the Tableau view-CSV capture and
# the Sigma parity query (Net Revenue 197,676.5 → 198,157.88, Orders
# 1,298 → 1,302, only the current month moved); parity failed 6/10 with no
# hint that the SOURCE moved. lib/source_drift.rb keeps values strict:
#   * assess labels a uniform small delta on matching keys
#     `suspected-source-drift` (status unchanged), anything else `divergence`;
#   * recapture! swaps in a fresh capture ONLY when the source CSV itself
#     changed — an unchanged CSV means the divergence is real.

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/source_drift'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

PLAN = { 'charts' => [
  { 'chart' => 'Net Revenue', 'tableau_view' => 'KPI Net Revenue', 'expected' => [[197_676.5]] },
  { 'chart' => 'Total Orders', 'tableau_view' => 'KPI Orders', 'expected' => [[1298]] },
  { 'chart' => 'Revenue by Month', 'tableau_view' => 'Revenue Trend', 'measure_indices' => [1],
    'expected' => [['September 2026', 9_000.0], ['October 2026', 19_634.64], ['November 2026', 2576.97]] },
  { 'chart' => 'Share', 'tableau_view' => 'Share', 'measure_indices' => [2],
    'expected' => [['Apparel', 'Midwest', 0.173], ['Apparel', 'South', 0.317]] }
] }.freeze

puts 'assess: the live-proof drift shape'
drift = { 'Net Revenue' => [[198_157.88]], 'Total Orders' => [[1302]],
          'Revenue by Month' => [['September 2026', 9_000.0], ['October 2026', 19_634.64], ['November 2026', 3058.35]],
          'Share' => [['Apparel', 'Midwest', 0.172], ['Apparel', 'South', 0.322]] }
r = SourceDrift.assess(PLAN, drift, PLAN['charts'].map { |c| c['chart'] })
ok(r['classification'] == 'suspected-source-drift', "uniform small delta on matching keys → suspected-source-drift (#{r['tiles'].map { |t| t['reason'] }.inspect})")
month = r['tiles'].find { |t| t['chart'] == 'Revenue by Month' }
ok(month['row_max_rel'] > 0.05 && month['max_rel'] < 0.05, 'a load in the newest month moves that row a lot but the tile a little (tile-level test)')
ok(r['note'].include?('recapture-source-views.rb') && r['note'].include?('status FAIL'), 'names the re-capture command; states the run stays FAIL')

puts 'assess: real divergences stay divergences'
bug = drift.merge('Total Orders' => [[1650]])
ok(SourceDrift.assess(PLAN, bug, PLAN['charts'].map { |c| c['chart'] })['classification'] == 'divergence', 'one tile off by 27% → divergence')
lost = drift.merge('Share' => [['Apparel', 'Midwest', 0.172]])
ok(SourceDrift.assess(PLAN, lost, PLAN['charts'].map { |c| c['chart'] })['classification'] == 'divergence', 'a source key missing from Sigma → divergence')
ok(SourceDrift.assess(PLAN, drift, [])['classification'] == 'divergence', 'nothing failed → nothing to classify')
same = { 'Net Revenue' => [[197_676.5]] }
ok(SourceDrift.assess(PLAN, same, ['Net Revenue'])['classification'] == 'divergence', 'identical values are never "drift" (strict)')
utf8_csv = "\uFEFFRégion,Revenue\r\nQuébec,10\r\n"
ok(SourceDrift.norm_csv(utf8_csv) == "Région,Revenue\nQuébec,10",
   'UTF-8 CSVs normalize without an encoding compatibility error')
ok(SourceDrift.norm_csv(utf8_csv.b) == SourceDrift.norm_csv(utf8_csv),
   'binary captures and UTF-8 live exports normalize identically')

puts 'recapture!: only a CHANGED source CSV is swapped'
Dir.mktmpdir do |wd|
  FileUtils.mkdir_p(File.join(wd, 'views'))
  File.write(File.join(wd, 'get-workbook.json'), JSON.generate('views' => { 'view' => [
    { 'id' => 'v-nr', 'name' => 'KPI Net Revenue' }, { 'id' => 'v-or', 'name' => 'KPI Orders' }, { 'id' => 'v-tr', 'name' => 'Revenue Trend' }
  ] }))
  File.write(File.join(wd, 'views', 'v-nr.csv'), "Net Revenue\n\"197,676.5\"\n")
  File.write(File.join(wd, 'views', 'v-or.csv'), "Orders\n1298\n")
  File.write(File.join(wd, 'source-anchors.json'), JSON.generate('anchors' => [
    { 'id' => 'a1', 'panel' => 'KPI Net Revenue', 'raw' => '197,676.5', 'provenance' => 'view-csv' },
    { 'id' => 'a2', 'panel' => 'KPI Orders', 'raw' => '1,298', 'provenance' => 'view-csv' }
  ]))
  fresh = { 'v-nr' => "Net Revenue\n\"198,157.88\"\n", 'v-or' => "Orders\r\n1298\r\n" }
  res = SourceDrift.recapture!(wd, plan: PLAN, charts: ['Net Revenue', 'Total Orders', 'Revenue by Month'],
                                   fetch: ->(vid) { fresh.fetch(vid) })
  ok(res['moved'].map { |m| m['chart'] } == ['Net Revenue'], "the moved view is detected (#{res['moved'].map { |m| m['chart'] }.inspect})")
  ok(File.read(File.join(wd, 'views', 'v-nr.csv')).include?('198,157.88') && File.read(res['moved'][0]['archived']).include?('197,676.5'),
     'fresh capture swapped in; old capture archived')
  ok(res['unchanged'].map { |m| m['chart'] } == ['Total Orders'] && File.read(File.join(wd, 'views', 'v-or.csv')) == "Orders\n1298\n",
     'line-ending-only difference is UNCHANGED and not swapped (the divergence there is real)')
  ok(res['unavailable'].map { |m| m['chart'] } == ['Revenue by Month'], 'a view with no capture is reported, not guessed')
  ok(res['stale_anchors'] == ['a1'], "anchors transcribed from the moved view are flagged stale (#{res['stale_anchors'].inspect})")
  ok(File.file?(File.join(wd, SourceDrift::RECAPTURE)), 'source-recapture.json written')
end

rb = File.read(File.join(__dir__, 'tableau-discover.rb'), encoding: 'UTF-8')
py = File.read(File.join(__dir__, 'tableau-discover.py'), encoding: 'UTF-8')
ok(rb.include?('Tableau.view_data_filtered(v[\'id\'])') && py.include?('"view_data_filtered"'), 'Phase 1 captures bypass the view-data cache (maxAge=1)')
src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
ok(src.include?('SourceDrift.assess(') && src.include?('unless parity_ok'), 'finalize assesses drift only when parity FAILED')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
