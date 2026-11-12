#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof findings 3 + 4:
#   * anchor a9 was transcribed as 0.641016176 (9 digits) from the Gross
#     Margin view CSV; the export rounds to 0.64101618, so it could never
#     match. Anchors are written at the source's DISPLAYED precision
#     (p0.0% → "64.1%"; the shared comparator then matches at that precision)
#     — normalized only before the anchors lock exists;
#   * gate 18 needed valued anchors for Gross Margin and Category x Region,
#     added by hand. Every tile with a view CSV and no valued anchor is seeded
#     from it; only a tile with NO CSV is left for a person.

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/anchor_seed'
require_relative 'lib/finalize_preflight'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def workdir
  Dir.mktmpdir do |wd|
    FileUtils.mkdir_p(File.join(wd, 'views'))
    File.write(File.join(wd, 'get-workbook.json'), JSON.generate('views' => { 'view' => [
      { 'id' => 'v-gm', 'name' => 'KPI Gross Margin' }, { 'id' => 'v-share', 'name' => 'Category x Region Share' },
      { 'id' => 'v-rev', 'name' => 'KPI Net Revenue' }, { 'id' => 'v-map', 'name' => 'State Map' }
    ] }))
    File.write(File.join(wd, 'dashboard-layout.json'), JSON.generate([{ 'dashboard' => 'Overview', 'zones' => [
      { 'caption' => 'KPI Gross Margin', 'kind' => 'chart', 'is_kpi' => true, 'formats' => { 'f' => 'p0.0%' } },
      { 'caption' => 'Category x Region Share', 'kind' => 'chart', 'formats' => { 'f' => 'p0.0%' } },
      { 'caption' => 'KPI Net Revenue', 'kind' => 'chart', 'is_kpi' => true, 'formats' => { 'f' => 'n"$"#,##0' } },
      { 'caption' => 'State Map', 'kind' => 'chart', 'formats' => { 'f' => 'n"$"#,##0' } },
      { 'caption' => 'Unexported Sheet', 'kind' => 'chart', 'formats' => {} }
    ] }]))
    File.write(File.join(wd, 'views', 'v-gm.csv'), "Gross Margin Pct\n0.641016176\n")
    File.write(File.join(wd, 'views', 'v-share.csv'), "Category,Region,Pct of Net Revenue\nApparel,,2.8%\nApparel,Midwest,17.2%\n")
    File.write(File.join(wd, 'views', 'v-rev.csv'), "Net Revenue\n\"198,157.88\"\n")
    File.write(File.join(wd, 'views', 'v-map.csv'), "State,Latitude (generated),Longitude (generated),Net Revenue\nAZ,34.5,-111.5,\nCA,36.1,-119.6,\"15,964.83\"\n")
    File.write(File.join(wd, 'source-anchors.json'), JSON.generate('anchors' => [
      { 'id' => 'a1', 'panel' => 'KPI Net Revenue', 'raw' => '198,157.88', 'kind' => 'number', 'provenance' => 'view-csv' },
      { 'id' => 'a9', 'panel' => 'KPI Gross Margin', 'raw' => '0.641016176', 'kind' => 'number', 'provenance' => 'view-csv' }
    ]))
    yield wd
  end
end

puts 'format parsing / display precision'
ok(AnchorSeed.render(0.641016176, AnchorSeed.parse_format('p0.0%')) == '64.1%', 'p0.0% → 64.1%')
ok(AnchorSeed.render(198_157.88, AnchorSeed.parse_format('n"$"#,##0')) == '$198,158', 'n"$"#,##0 → $198,158')
ok(AnchorSeed.render(0.123456789, nil) == '0.123457', 'unknown format: bare float capped at 6 decimals')
ok(AnchorSeed.displayed('"198,157.88"'.delete('"'), 'Net Revenue', ['n"$"#,##0']) == '198,157.88', 'an already-printed CSV string is kept verbatim')

puts 'before the anchors lock (Phase 1d): normalize + seed'
workdir do |wd|
  plan = FinalizePreflight.check_anchor_seed(wd)
  ok(plan && plan[:auto] && plan[:cmd].include?('scripts/seed-source-anchors.rb'), 'the finalize preflight schedules the seed as an AUTO step')
  r = AnchorSeed.apply!(wd)
  doc = JSON.parse(File.read(File.join(wd, 'source-anchors.json')))
  a9 = doc['anchors'].find { |a| a['id'] == 'a9' }
  ok(a9['raw'] == '64.1%' && a9['normalized_from'] == '0.641016176', "a9 normalized to the displayed precision (#{a9['raw']})")
  seeded = doc['anchors'].select { |a| a['derived_by'] == 'seed-source-anchors' }
  share = seeded.find { |a| a['panel'] == 'Category x Region Share' }
  ok(share && share['raw'] == '17.2%' && share['kind'] == 'percent', "Category x Region seeded from a complete row, not the Null-member row (#{share && share['raw']})")
  map = seeded.find { |a| a['panel'] == 'State Map' }
  ok(map && map['raw'] == '15,964.83', "map: generated lat/long skipped, first non-empty measure cell used (#{map && map['raw']})")
  ok(seeded.none? { |a| a['panel'] =~ /Gross Margin|Net Revenue/ }, 'tiles that already have a valued anchor are not seeded again')
  ok(seeded.all? { |a| a['provenance'] == 'view-csv' && a['sigma_element_hint'] == a['panel'] }, 'seeded anchors are view-csv valued anchors aimed at their tile')
  ok(r[:no_csv] == ['Unexported Sheet'], "a tile with no CSV is left for a person (#{r[:no_csv].inspect})")
  ok(AnchorSeed.apply!(wd)[:seeded].empty?, 'idempotent')
  ok(FinalizePreflight.check_anchor_seed(wd).nil?, 'nothing left to seed → no preflight item')
end

puts 'after the anchors lock: add, never change'
workdir do |wd|
  File.write(File.join(wd, 'source-anchors.lock.json'), JSON.generate('anchors' => { 'a1' => '198,157.88', 'a9' => '0.641016176' }))
  r = AnchorSeed.apply!(wd)
  doc = JSON.parse(File.read(File.join(wd, 'source-anchors.json')))
  ok(r[:normalized].empty? && doc['anchors'].find { |a| a['id'] == 'a9' }['raw'] == '0.641016176',
     'a locked value is NOT changed (that would be tampering — use --retranscribed)')
  ok(r[:seeded].size == 2, "new anchors are still ADDED (not tampering) (#{r[:seeded].inspect})")
end

puts 'nested single-view workbook metadata'
workdir do |wd|
  view = { 'id' => 'v-share', 'name' => 'Category x Region Share' }
  File.write(File.join(wd, 'get-workbook.json'), JSON.generate('workbook' => { 'views' => { 'view' => view } }))
  File.write(File.join(wd, 'source-anchors.json'), JSON.generate('anchors' => []))
  r = AnchorSeed.apply!(wd)
  doc = JSON.parse(File.read(File.join(wd, 'source-anchors.json')))
  ok(r[:seeded].size == 1 && doc['anchors'][0]['source_csv'] == 'views/v-share.csv',
     'a nested single view resolves its CSV and seeds an anchor')
end

src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
ok(src.include?('AnchorSeed.apply!(WORK)'), 'Phase 1d acceptance seeds/normalizes before verify-anchors first locks')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
