#!/usr/bin/env ruby
# Regression test for PBI visual-type resolution (viz-kind + custom-visual catalogs).
#
# The bug this guards (measured on 4 real customer .pbix files, 2026-07-30):
# extract-report-classic.py / extract-pbir.py coerced ANY unrecognized visualType
# to the 'bar' token (`VISUAL_KIND.get(vt, "bar")`). On those files that turned
# **21 third-party Powerviz date-picker slicers into bar charts** — every page lost
# its date filter — plus 4 modern `cardVisual` cards and 5 decorative `shape`s.
# The builder DID warn, but recorded them as severity 'approximated' (which the
# coverage headline counts as CARRIED OVER, failing no gate) with guidance that was
# flatly wrong: "Sigma has no native Datepicker… pick a different chart". Sigma has
# a native date-range control.
#
# The fix: a visual resolves to a ROLE CLASS (control|chart|kpi|text|decoration|
# unsupported) from the catalogs, so
#   (a) a third-party SLICER becomes a real Sigma control, never a chart;
#   (b) losing a control is a FUNCTIONAL loss the gate can fail on, not an
#       "approximation" that scores as success;
#   (c) a genuinely unsupported visual carries ACTIONABLE guidance naming the
#       closest Sigma construct — never a silent bar.
#
# Usage:  ruby scripts/test-viz-kind-catalog.rb
require 'json'
require_relative 'lib/pbi_viz_kind'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

CAT = PbiVizKind.load(File.expand_path('../refs/catalogs', __dir__))

puts "\n1. Third-party custom-visual SLICERS resolve as controls (not charts)"
# The exact tokens measured in the customer's files.
[
  ['Datepicker_1687358625_Powerviz_OrgStore', 'date-range'],
  ['Timeline1447991079480',                   'date-range'],
  ['ChicletSlicer1455240051538',              'list'],
  ['HierarchySlicer1658301220291',            'list'],
].each do |token, want_sigma|
  r = CAT.resolve(token)
  check(!r.nil?, "#{token} resolves at all", fails)
  check(r && r['role_class'] == 'control',
        "#{token} -> role_class=control (got #{r && r['role_class'].inspect})", fails)
  check(r && r['sigma'] == want_sigma,
        "#{token} -> sigma=#{want_sigma} (got #{r && r['sigma'].inspect})", fails)
  check(r && r['sigma'] != 'bar-chart', "#{token} is NOT coerced to a bar-chart", fails)
end

puts "\n2. Native types missing from the old VISUAL_KIND dict now resolve correctly"
[
  ['cardVisual',                       'kpi',        'kpi-chart'],
  ['shape',                            'decoration', nil],
  ['basicShape',                       'decoration', nil],
  ['hundredPercentStackedBarChart',    'chart',      'bar-chart'],
  ['advancedSlicerVisual',             'control',    'list'],
].each do |token, want_role, want_sigma|
  r = CAT.resolve(token)
  check(!r.nil?, "#{token} resolves at all", fails)
  check(r && r['role_class'] == want_role,
        "#{token} -> role_class=#{want_role} (got #{r && r['role_class'].inspect})", fails)
  next unless want_sigma
  check(r && r['sigma'] == want_sigma,
        "#{token} -> sigma=#{want_sigma} (got #{r && r['sigma'].inspect})", fails)
end

puts "\n3. Genuinely unsupported visuals carry ACTIONABLE guidance, never a silent bar"
%w[sankeyDiagram wordCloud decompositionTreeVisual keyInfluencers
   pythonVisual playAxis].each do |token|
  r = CAT.resolve(token)
  check(!r.nil?, "#{token} resolves at all", fails)
  check(r && !r['guidance'].to_s.strip.empty?, "#{token} has non-empty guidance", fails)
  # Guidance must name a concrete Sigma construct or say explicitly there is none.
  check(r && r['guidance'].to_s.length > 30, "#{token} guidance is substantive", fails)
end

puts "\n4. An UNKNOWN token never silently becomes a chart"
r = CAT.resolve('TotallyMadeUpVisual_9999_Vendor_Store')
check(r.nil? || r['role_class'] == 'unsupported',
      'unknown token -> nil or role_class=unsupported (never chart)', fails)
guess = CAT.resolve_or_guidance('TotallyMadeUpVisual_9999_Vendor_Store')
check(guess['role_class'] == 'unsupported', 'unknown token guidance row is unsupported', fails)
check(guess['guidance'].to_s.include?('custom visual'),
      'unknown-token guidance explains it is an unrecognized custom visual', fails)
check(guess['sigma'].nil?, 'unknown token has NO sigma target (must not default to bar)', fails)

puts "\n5. Control-class visuals are flagged as FUNCTIONAL loss when unbuilt"
check(PbiVizKind.functional?('control'), 'control is functional', fails)
check(PbiVizKind.functional?('kpi'),     'kpi is functional', fails)
check(PbiVizKind.functional?('chart'),   'chart is functional', fails)
check(!PbiVizKind.functional?('decoration'), 'decoration is NOT functional', fails)
check(!PbiVizKind.functional?('text'),       'text is NOT functional', fails)

puts "\n6. Every native visualType in viz-kind.json declares a role_class"
missing = CAT.rows.reject { |r| r['role_class'] }
check(missing.empty?,
      "all catalog rows declare role_class (missing: #{missing.map { |r| r['source'] }.first(5)})", fails)

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
