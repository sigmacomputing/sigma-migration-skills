#!/usr/bin/env ruby
# Regression test: when the source dashboard has its OWN top title banner (a
# styled text zone near the top), build-charts must NOT also synthesize a
# "# <dashboard>" title — that renders the title TWICE (at the top AND in a stray
# text band, the reported "title top + bottom" duplicate). Covers both the
# --page-per-dashboard path (which migrate-tableau uses, and which unconditionally
# emitted title-<slug>) and the single-page path.
#
# Usage: ruby scripts/test-no-double-title.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Dashboard WITH its own styled top title banner ("Orders — Executive Overview").
LAYOUT = [{
  'dashboard' => 'Executive Overview',
  'zones' => [
    { 'id' => 'banner', 'kind' => 'text', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 4,
      'text_runs' => [{ 'text' => 'Orders — Executive Overview' }] },
    { 'id' => 'b1', 'kind' => 'chart', 'caption' => 'Rev by Region', 'chart_kind' => 'bar',
      'mark_class' => 'Bar', 'x_pct' => 0, 'y_pct' => 10, 'w_pct' => 100, 'h_pct' => 40,
      'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
      'ref_marks' => [], 'aggregations' => { '[Region]' => 'None', '[Net Revenue]' => 'Sum' },
      'rows_shelf' => { 'fields' => [{ 'caption' => 'Net Revenue', 'role' => 'measure' }] },
      'cols_shelf' => { 'fields' => [{ 'caption' => 'Region', 'role' => 'dim' }] },
      'measures' => [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }], 'calculations' => [] }
  ]
}]
META = { 'worksheets' => {}, 'shared_filters' => [], 'parameters' => [], 'column_aliases' => {}, 'columns_by_guid' => {} }
MMAP = {
  '(?i)^Region$'      => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Net Revenue$' => { 'id' => 'm-rev',    'name' => 'Net Revenue' }
}

def run_build(build, mode_flag)
  out = nil
  Dir.mktmpdir do |d|
    File.write("#{d}/layout.json", JSON.dump(LAYOUT))
    File.write("#{d}/meta.json",   JSON.dump(META))
    File.write("#{d}/mm.json",     JSON.dump(MMAP))
    File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Rev by Region' }] }))
    Dir.mkdir("#{d}/views")
    File.write("#{d}/views/v1.csv", "Region,Net Revenue\nWest,100\n")
    o = "#{d}/specs.json"
    IO.popen(['ruby', build, '--tableau-dir', d, '--layout', "#{d}/layout.json",
              '--meta', "#{d}/meta.json", '--master-map', "#{d}/mm.json",
              '--master-element-id', 'master', *mode_flag.to_s.split,
              '--title', 'Executive Overview', '--skip-dashboard-read', 'unit-test',
              '--out', o], err: %i[child out], &:read)
    out = JSON.parse(File.read(o)) if File.exist?(o)
  end
  out
end

def texts(out)
  return [] unless out
  els = out.is_a?(Array) ? out : (out['elements'] || (out['pages'] || []).flat_map { |p| p['elements'] || [] })
  els.select { |e| e['kind'] == 'text' }
end

# --page-per-dashboard (the orchestrator's mode).
td = texts(run_build(BUILD, '--page-per-dashboard'))
check(td.length == 1, "page-per-dashboard: exactly ONE title text element (got #{td.length}: #{td.map { |t| (t['body'] || '')[0, 25] }})", fails)
check(td.none? { |t| t['body'].to_s =~ /\A#\s*Executive Overview\s*\z/ },
      'page-per-dashboard: NO synthetic "# Executive Overview" (the duplicate)', fails)
check(td.any? { |t| t['body'].to_s.include?('Orders — Executive Overview') },
      'page-per-dashboard: the source banner is kept as the title', fails)

# single-page path.
ts = texts(run_build(BUILD, ''))
check(ts.length == 1, "single-page: exactly ONE title text element (got #{ts.length})", fails)
check(ts.none? { |t| t['body'].to_s =~ /\A#\s*Executive Overview\s*\z/ },
      'single-page: NO synthetic "# Executive Overview"', fails)

puts
if fails.empty?
  puts 'ALL PASS — source top-title banner suppresses the synthetic title (no double)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
