#!/usr/bin/env ruby
# frozen_string_literal: true
# v5.1 defect 1 regression test — px-derived page height.
#
# A dashboard authored at a FIXED px canvas (<size sizing-mode='fixed'>) must
# size its Sigma page from the canvas: page_rows = round(canvas_h /
# SIGMA_ROW_PX) with row_scale NEUTRALIZED (the 1.5x scale existed only to
# compensate the 32-row default's underestimate). Before this fix every
# dashboard got 48 rows (32 * 1.5), so a 2070px source shipped a 1344px page,
# every tile mapped ~35% short, the E1 floors fired wholesale and the
# proportions inverted (small tiles grew, the hero chart shrank) — the r4
# consensus defect: 2885-3407px renders vs 2070 authored.
#
# Locks:
#   1. canvas 1200x2070 fixed -> 74 rows (2070/28), per-page census `rows` +
#      `canvas_rows`, and the px-derived warn line.
#   2. a 16.6%-tall hero chart maps to ~12 rows (px-true), NOT the 8-row floor.
#   3. absent canvas_px -> legacy 48 rows, byte-stable across runs.
#   4. explicit --page-rows always wins over the px derivation.
#   5. multi-dashboard: the derivation is PER DASHBOARD, not global.
#
# Usage:  ruby scripts/test-layout-px-rows.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/layout'

BUILD = File.join(__dir__, 'build-dashboard-layout.rb')
RUBY  = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def dash_fixture(name, canvas)
  {
    'dashboard' => name, 'is_story' => false, 'canvas_px' => canvas,
    'zones' => [
      { 'id' => '24', 'kind' => 'chart', 'caption' => 'Path Bias', 'chart_kind' => 'bar',
        'measures' => [{ 'column' => '[m]' }], 'x_pct' => 3.3, 'y_pct' => 16.0, 'w_pct' => 93.3, 'h_pct' => 16.6 },
      { 'id' => '30', 'kind' => 'chart', 'caption' => 'Detail', 'chart_kind' => 'bar',
        'measures' => [{ 'column' => '[m]' }], 'x_pct' => 3.3, 'y_pct' => 40.0, 'w_pct' => 93.3, 'h_pct' => 40.0 }
    ],
    # A styled container forces the container-tree path (tree_has_styled_containers).
    'zone_tree' => [
      { 'id' => '4', 'kind' => 'container', 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0,
        'fill_color' => '#f5f5f5ff',
        'children' => [
          { 'id' => '24', 'kind' => 'chart', 'caption' => 'Path Bias',
            'x_pct' => 3.3, 'y_pct' => 16.0, 'w_pct' => 93.3, 'h_pct' => 16.6 },
          { 'id' => '30', 'kind' => 'chart', 'caption' => 'Detail',
            'x_pct' => 3.3, 'y_pct' => 40.0, 'w_pct' => 93.3, 'h_pct' => 40.0 }
        ] }
    ]
  }
end

def wb_fixture(names)
  pages = [{ 'name' => 'Data', 'id' => 'page-data',
             'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] }]
  names.each_with_index do |n, i|
    pages << { 'name' => n, 'id' => "page-d#{i + 1}", 'elements' => [
      { 'id' => "el-hero-#{i + 1}",   'kind' => 'bar-chart', 'name' => 'Path Bias' },
      { 'id' => "el-detail-#{i + 1}", 'kind' => 'bar-chart', 'name' => 'Detail' }
    ] }
  end
  { 'pages' => pages }
end

def run_build(dl, wb, *extra)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'dl.json'), JSON.generate(dl))
    File.write(File.join(d, 'wb.json'), JSON.generate(wb))
    out = File.join(d, 'layout.xml')
    log = IO.popen([RUBY, BUILD, '--layout', File.join(d, 'dl.json'), '--wb-ids', File.join(d, 'wb.json'), '--out', out, *extra], err: %i[child out], &:read)
    xml = File.exist?(out) ? File.read(out) : nil
    cf = File.join(d, 'layout-census.json')
    census = File.exist?(cf) ? JSON.parse(File.read(cf)) : nil
    return [xml, census, log]
  end
end

def span_of(xml, id)
  m = xml.match(/elementId="#{Regexp.escape(id)}"[^>]*gridRow="(\d+)\s*\/\s*(\d+)"/)
  m && (m[2].to_i - m[1].to_i)
end

FIXED = { 'w' => 1200, 'h' => 2070, 'sizing_mode' => 'fixed' }.freeze

# ---- 0. the constant itself -------------------------------------------------
check(SigmaLayout::SIGMA_ROW_PX == 28, 'SIGMA_ROW_PX is 28 (live-derived grid row height)', fails)
check((2070 / 28.0).round == 74, 'formula sanity: 2070px / 28 rounds to 74 rows', fails)

# ---- 1. fixed 1200x2070 canvas -> 74 px-derived rows ------------------------
xml, census, log = run_build([dash_fixture('D', FIXED)], wb_fixture(['D']))
check(!xml.nil?, 'builder produced layout XML (fixed canvas)', fails)
check(log.include?('px-derived rows'), 'log announces the px-derived row model', fails)
pg = census && census['pages'] && census['pages'][0]
check(pg && pg['rows'] == 74, "census rows == 74 for the 2070px canvas (got #{pg && pg['rows']})", fails)
check(pg && pg['canvas_rows'] == 74, "census canvas_rows == 74 (got #{pg && pg['canvas_rows']})", fails)
# 16.6% of the page at px-true rows = ~12 rows (344px) — NOT the 8-row floor
# the old 48-row map collapsed it to (proportion inversion).
hero = xml && span_of(xml, 'el-hero-1')
check(hero && hero >= 11 && hero <= 13, "hero chart (16.6% = 344px) maps to ~12 rows px-true (got #{hero.inspect})", fails)

# ---- 2. absent canvas_px -> legacy 48 rows (32 * row-scale 1.5) --------------
xml_l, census_l, log_l = run_build([dash_fixture('D', nil)], wb_fixture(['D']))
pg_l = census_l && census_l['pages'] && census_l['pages'][0]
check(pg_l && pg_l['rows'] == 48, "no canvas_px -> legacy 48 rows (got #{pg_l && pg_l['rows']})", fails)
check(pg_l && !pg_l.key?('canvas_rows'), 'no canvas_px -> no canvas_rows in the census record', fails)
check(!log_l.include?('px-derived rows'), 'no px-derived announcement without a canvas', fails)
hero_l = xml_l && span_of(xml_l, 'el-hero-1')
check(hero_l && hero_l == 8, "legacy map still floors the hero to 8 rows (got #{hero_l.inspect}) — the defect the px model fixes", fails)
xml_l2, = run_build([dash_fixture('D', nil)], wb_fixture(['D']))
check(xml_l == xml_l2, 'legacy path deterministic (byte-identical across runs)', fails)

# ---- 3. explicit --page-rows wins over the px derivation ---------------------
_xml_e, census_e, log_e = run_build([dash_fixture('D', FIXED)], wb_fixture(['D']),
                                    '--page-rows', '48', '--row-scale', '1')
pg_e = census_e && census_e['pages'] && census_e['pages'][0]
check(pg_e && pg_e['rows'] == 48, "explicit --page-rows 48 --row-scale 1 overrides px derivation (got #{pg_e && pg_e['rows']})", fails)
check(!log_e.include?('px-derived rows'), 'explicit --page-rows suppresses the px derivation', fails)

# ---- 4. per-dashboard: one fixed canvas + one auto in the SAME workbook ------
dl = [dash_fixture('Fixed', FIXED), dash_fixture('Auto', nil)]
_xml_m, census_m, = run_build(dl, wb_fixture(%w[Fixed Auto]))
rows_by = (census_m && census_m['pages'] || []).each_with_object({}) { |c, h| h[c['page']] = c['rows'] }
check(rows_by['Fixed'] == 74 && rows_by['Auto'] == 48,
      "per-dashboard derivation: Fixed=74, Auto=48 (got #{rows_by.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — px-derived page height (SIGMA_ROW_PX=28, per-dashboard, explicit override, legacy fallback)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
