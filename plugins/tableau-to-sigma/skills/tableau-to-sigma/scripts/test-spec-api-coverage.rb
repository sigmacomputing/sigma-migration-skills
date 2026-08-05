#!/usr/bin/env ruby
# Regression: spec_api_limit_entries (bead ubr5.20) surfaces unsupported source
# primitives/features in coverage.json that the builder can't emit — so they
# never vanish silently. Also guards against FALSE POSITIVES on supported vizzes
# (plain bar/line/KPI). Extracts the function from build-charts-from-signals.rb
# (it's an inline top-level def, like test-param-measure-picker.rb does).
require 'json'

SRC = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
fn  = SRC[/^def spec_api_limit_entries.*?^end/m] or abort('could not extract spec_api_limit_entries')
eval(fn)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

layout = [{
  'dashboard' => 'D', 'zones' => [
    # --- SHOULD fire ---
    { 'kind' => 'chart', 'caption' => 'Rank Bump', 'chart_kind' => 'line', 'mark_class' => 'Line',
      'measures' => [{ 'column' => '[Rank]' }], 'calculations' => [] },
    { 'kind' => 'chart', 'caption' => 'Bump via INDEX', 'chart_kind' => 'line', 'mark_class' => 'Line',
      'measures' => [], 'calculations' => [{ 'caption' => 'Rank', 'formula' => 'INDEX()' }] },
    { 'kind' => 'chart', 'caption' => 'Logo', 'chart_kind' => 'scatter', 'mark_class' => 'Shape',
      'measures' => [], 'calculations' => [] },
    { 'kind' => 'chart', 'caption' => 'Sales KPI', 'chart_kind' => 'kpi', 'mark_class' => 'Automatic', 'is_kpi' => true,
      'measures' => [], 'calculations' => [{ 'caption' => 'Up Arrow', 'formula' => '' }, { 'caption' => '% Change', 'formula' => '' }] },
    # Task 5: same UI-only-delta trigger as 'Sales KPI', but this tile's
    # comparison measure WAS detected + wired (build_kpi_element records it in
    # $kpi_comparison_wired) — the warning must be demoted (not fire) here.
    { 'kind' => 'chart', 'caption' => 'Revenue KPI (wired)', 'chart_kind' => 'kpi', 'mark_class' => 'Automatic', 'is_kpi' => true,
      'measures' => [], 'calculations' => [{ 'caption' => 'Up Arrow', 'formula' => '' }, { 'caption' => '% Change', 'formula' => '' }] },
    { 'kind' => 'chart', 'caption' => 'Filled Map', 'chart_kind' => 'map', 'mark_class' => 'Map',
      'geo_role' => 'state', 'measures' => [], 'calculations' => [] },
    # --- should NOT fire (false-positive guards) ---
    { 'kind' => 'chart', 'caption' => 'Sales by Region', 'chart_kind' => 'bar', 'mark_class' => 'Automatic',
      'measures' => [{ 'column' => '[Sales]' }], 'calculations' => [] },
    { 'kind' => 'chart', 'caption' => 'Sales Trend', 'chart_kind' => 'line', 'mark_class' => 'Line',
      'measures' => [{ 'column' => '[Sales]' }], 'calculations' => [] },
    { 'kind' => 'chart', 'caption' => 'Plain KPI', 'chart_kind' => 'kpi', 'mark_class' => 'Automatic', 'is_kpi' => true,
      'measures' => [{ 'column' => '[Sales]' }], 'calculations' => [] },
    { 'kind' => 'text', 'caption' => 'A note' } # non-chart zone ignored
  ]
}]

e = spec_api_limit_entries(layout, { 'Revenue KPI (wired)' => true })
by_vis = e.each_with_object({}) { |x, h| h[x['visual']] = x }

# fires
check(by_vis['Rank Bump'] && by_vis['Rank Bump']['severity'] == 'dropped' &&
      by_vis['Rank Bump']['detail'] =~ /bump/i, 'bump via [Rank] measure → dropped', fails)
check(by_vis['Bump via INDEX'] && by_vis['Bump via INDEX']['detail'] =~ /bump/i,
      'bump via INDEX() calc → dropped', fails)
check(by_vis['Logo'] && by_vis['Logo']['severity'] == 'dropped' &&
      by_vis['Logo']['detail'] =~ /shape/i, 'shape/image mark → dropped', fails)
check(by_vis['Sales KPI'] && by_vis['Sales KPI']['severity'] == 'degraded' &&
      by_vis['Sales KPI']['detail'] =~ /comparison|▲/, 'KPI ▲/▼ delta → degraded', fails)
check(by_vis['Filled Map'] && by_vis['Filled Map']['detail'] =~ /map|choropleth/i,
      'filled map / choropleth → surfaced', fails)

# false-positive guards
check(!by_vis['Sales by Region'], 'plain bar NOT flagged', fails)
check(!by_vis['Sales Trend'],     'plain line (no rank) NOT flagged', fails)
check(!by_vis['Plain KPI'],       'plain KPI (no delta fields) NOT flagged', fails)

# Task 5: demotion — same trigger as 'Sales KPI', but wired via cmp_wired →
# must NOT fire (default cmp_wired = {} keeps 'Sales KPI' firing above).
check(!by_vis['Revenue KPI (wired)'],
      'KPI ▲/▼ delta demoted when cmp_wired marks the tile (Task 5)', fails)
check(e.size == 5, "exactly 5 entries (got #{e.size})", fails)

puts
if fails.empty?
  puts 'ALL PASS — spec-API-limit coverage surfacing (ubr5.20): unsupported primitives named, no false positives'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
