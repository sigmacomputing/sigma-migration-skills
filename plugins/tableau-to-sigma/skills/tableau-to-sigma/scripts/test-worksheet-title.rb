#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for worksheet-title → element display name (2026-07-09).
#
# Element titles came out as worksheet NICKNAMES ("OV KPI Revenue") instead of
# the source-DISPLAYED worksheet title ("Net Revenue"), because parse-twb-layout
# never extracted the worksheet <title> run. This drives parse-twb-layout on a
# minimal .twb and asserts: (a) a CUSTOM worksheet <title> is extracted to
# display_title on both the worksheet meta and the dashboard zone; (b) a DEFAULT
# title (the "<Sheet Name>" field token) is skipped (nil) so the builder falls
# back to the nickname; (c) Tableau's Æ line-break sentinel is stripped; and
# (d) build-charts' tile_title consumes display_title.
#
# Usage: ruby scripts/test-worksheet-title.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
PARSE = File.join(DIR, 'parse-twb-layout.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <worksheets>
      <worksheet name='OV KPI Revenue'>
        <layout-options><title><formatted-text><run>Net Revenue</run></formatted-text></title></layout-options>
        <table><view><datasources/></view></table>
      </worksheet>
      <worksheet name='Plain Sheet'>
        <layout-options><title><formatted-text><run>&lt;Sheet Name&gt;</run></formatted-text></title></layout-options>
        <table><view><datasources/></view></table>
      </worksheet>
      <worksheet name='Sentinel Sheet'>
        <layout-options><title><formatted-text><run>CQ DAYS NOT TOUCHED</run><run>Æ&#10;</run><run>Percentage of Total</run></formatted-text></title></layout-options>
        <table><view><datasources/></view></table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='D'>
        <zones><zone id='1' name='OV KPI Revenue' x='0' y='0' w='100000' h='100000'><zone id='2' name='OV KPI Revenue' param='vizic'/></zone></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  out = File.join(d, 'layout.json')
  File.write(twb, TWB)
  system('ruby', PARSE, twb, out, out: File::NULL, err: File::NULL)

  meta = JSON.parse(File.read(out.sub(/\.json$/, '-meta.json')))
  ws = meta['worksheets'] || {}
  check(ws.dig('OV KPI Revenue', 'display_title') == 'Net Revenue',
        "custom worksheet <title> extracted (got #{ws.dig('OV KPI Revenue', 'display_title').inspect})", fails)
  check(ws.dig('Plain Sheet', 'display_title').nil?,
        "default '<Sheet Name>' token skipped -> nil (got #{ws.dig('Plain Sheet', 'display_title').inspect})", fails)
  sentinel_title = ws.dig('Sentinel Sheet', 'display_title')
  check(sentinel_title == "CQ DAYS NOT TOUCHED\nPercentage of Total" && !sentinel_title.include?('Æ'),
        "Tableau Æ title sentinel stripped while preserving newline (got #{sentinel_title.inspect})", fails)

  doc = JSON.parse(File.read(out))
  dashes = doc.is_a?(Array) ? doc : (doc['dashboards'] || [doc])
  zone = dashes.flat_map { |x| x['zones'] || [] }.find { |z| z['caption'] == 'OV KPI Revenue' }
  check(zone && zone['display_title'] == 'Net Revenue',
        "display_title threaded onto the dashboard zone (got #{zone && zone['display_title'].inspect})", fails)
end

# tile_title (build-charts) prefers display_title, else falls back to the nickname.
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
src = File.read(BUILD)
check(src.include?('def tile_title'), 'build-charts defines tile_title helper', fails)
check(src.scan(/tile_title\(z, cap\)/).size >= 3, 'tile_title applied at multiple element-name sites', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
