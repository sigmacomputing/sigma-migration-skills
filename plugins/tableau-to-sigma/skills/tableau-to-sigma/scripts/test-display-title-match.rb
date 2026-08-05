#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for zone→element matching after the display-title rename
# (2026-07-09). Tiles are named by the worksheet display_title ("Net Revenue"),
# not the caption/nickname ("OV KPI Revenue"). The layout builder must match a
# zone to its Sigma element by display_title (via zone_el_name) — a live E2E
# regression dropped ALL 9 tiles (0/9 placed, collapsed layout) because the
# matcher still keyed on caption after the namer changed to display_title. This
# drives build-dashboard-layout on a fixture where caption ≠ display_title = the
# element name and asserts the tiles are PLACED (not DROPPED).
#
# Usage: ruby scripts/test-display-title-match.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
BUILD = File.join(DIR, 'build-dashboard-layout.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

LAYOUT = [{
  'dashboard' => 'D', 'is_story' => false, 'zone_tree' => nil, 'brand_palette' => [],
  'zones' => [
    { 'id' => '10', 'kind' => 'chart', 'caption' => 'OV Rev', 'display_title' => 'Net Revenue',
      'x_pct' => 0.0, 'y_pct' => 10.0, 'w_pct' => 50.0, 'h_pct' => 40.0, 'chart_kind' => 'bar' },
    { 'id' => '11', 'kind' => 'chart', 'caption' => 'OV Marg', 'display_title' => 'Gross Margin %',
      'x_pct' => 50.0, 'y_pct' => 10.0, 'w_pct' => 50.0, 'h_pct' => 40.0, 'chart_kind' => 'bar' },
    # KPI-comparison wave: a kpi-chart element's `name` is the house-standard
    # OBJECT form {'text'=>...} (KpiCard.build), not a plain String like every
    # other kind — the zone→element matcher must still resolve it by
    # display_title, or every KPI tile silently drops into the safety-net band.
    { 'id' => '12', 'kind' => 'chart', 'caption' => 'OV KPI Rev', 'display_title' => 'Net Revenue KPI',
      'x_pct' => 0.0, 'y_pct' => 60.0, 'w_pct' => 50.0, 'h_pct' => 20.0, 'chart_kind' => 'kpi' }
  ]
}]
# Elements named by display_title (what the fixed builder emits), NOT the caption.
WBIDS = { 'workbookId' => 'wb-x', 'pages' => [
  { 'id' => 'page-data', 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Master' }] },
  { 'id' => 'page-dash-1', 'name' => 'D', 'elements' => [
    { 'id' => 'el-rev',  'kind' => 'bar-chart', 'name' => 'Net Revenue' },
    { 'id' => 'el-marg', 'kind' => 'bar-chart', 'name' => 'Gross Margin %' },
    { 'id' => 'el-kpi',  'kind' => 'kpi-chart', 'name' => { 'text' => 'Net Revenue KPI' } }
  ] }
] }

Dir.mktmpdir do |d|
  lf = File.join(d, 'layout.json'); wf = File.join(d, 'wb-ids.json'); out = File.join(d, 'out.xml')
  File.write(lf, JSON.generate(LAYOUT)); File.write(wf, JSON.generate(WBIDS))
  log = IO.popen(['ruby', BUILD, '--layout', lf, '--wb-ids', wf, '--out', out],
                 err: %i[child out], &:read)
  xml = File.exist?(out) ? File.read(out) : ''

  check(!log.include?('DROPPED'), "no tile DROPPED warning (matcher found both by display_title)\n#{log}", fails)
  check(xml.include?('el-rev'),  'el-rev (name "Net Revenue") placed in the layout', fails)
  check(xml.include?('el-marg'), 'el-marg (name "Gross Margin %") placed in the layout', fails)
  check(xml.include?('el-kpi'),
        'el-kpi (Hash-shaped name {"text"=>"Net Revenue KPI"}) placed in the layout, not dropped', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
