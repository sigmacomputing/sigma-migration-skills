#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-census-page-scope.rb — gate-5 tile-census dashboard scoping (v5.5 e2e
# field-caught FALSE RED: the census pooled zones from ALL dashboards while the
# parity plan was scoped to one, so every out-of-scope tile read "unmatched" on
# any multi-dashboard workbook; repeated tile names across dashboards compound).
require 'json'
require_relative 'lib/zone_census'

PASS = []
FAIL = []
def ok(cond, msg)
  (cond ? PASS : FAIL) << msg
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def zone(caption, measures: ['m'])
  { 'kind' => 'chart', 'caption' => caption, 'measures' => measures,
    'rows_shelf' => { 'dim_count' => 1 }, 'cols_shelf' => {} }
end

layout = [
  { 'dashboard' => 'Exec Overview', 'zones' => [zone('Sales Trend'), zone('Top Regions')] },
  { 'dashboard' => 'Ops Detail',    'zones' => [zone('Sales Trend'), zone('Backlog')] },
  { 'dashboard' => 'Notes',         'zones' => [{ 'kind' => 'text', 'caption' => 'About' }] }
]
plan_exec = [{ 'tableau_view' => 'Sales Trend', 'chart' => 'Sales Trend' },
             { 'tableau_view' => 'Top Regions', 'chart' => 'Top Regions' }]

puts 'test-census-page-scope:'

# 1. THE FIELD BUG: plan scoped to one dashboard, census unscoped => false unmatched.
c_unscoped = ZoneCensus.tile_census(layout, plan_exec, [])
ok(c_unscoped['zones_unmatched'] == 1 && c_unscoped['unmatched_zone_names'] == ['Backlog'],
   'unscoped census over a scoped plan reports the out-of-scope tile (the old false RED)')

# 2. THE FIX: same plan, census scoped to the same dashboard => clean.
c_scoped = ZoneCensus.tile_census(layout, plan_exec, ['Exec Overview'])
ok(c_scoped['zones_unmatched'].zero?, 'scoped census matches the scoped plan (0 unmatched)')
ok(c_scoped['zones_total'] == 2, 'scoped denominator counts only in-scope tiles')
ok(c_scoped['dashboards_scoped'] == ['Exec Overview'], 'scope recorded for the report')

# 3. Repeated tile names: 'Sales Trend' on BOTH dashboards; scoping to Ops only —
#    the shared worksheet is matched by the plan chart, Backlog is not.
c_ops = ZoneCensus.tile_census(layout, plan_exec, ['Ops Detail'])
ok(c_ops['zones_unmatched'] == 1 && c_ops['unmatched_zone_names'] == ['Backlog'],
   'repeated tile name across dashboards does not cross-pollute; real gap still caught')

# 4. Scope match rule mirrors auto-parity-plan: case-insensitive exact, else substring.
ok(ZoneCensus.tile_census(layout, plan_exec, ['exec overview'])['zones_unmatched'].zero?,
   'case-insensitive exact scope match')
ok(ZoneCensus.tile_census(layout, plan_exec, ['Exec'])['zones_unmatched'].zero?,
   'substring scope match')

# 5. Unknown scope name => zero dashboards in scope (loud empty, not a crash).
c_none = ZoneCensus.tile_census(layout, plan_exec, ['Nope'])
ok(c_none['zones_total'].zero? && c_none['dashboards_scoped'].empty?,
   'unknown scope yields empty census, no crash')

# 6. Furniture still excluded (text zone never counted).
ok(!ZoneCensus.tile_census(layout, [], [])['unmatched_zone_names'].include?('About'),
   'text/furniture zones stay excluded from the census')

# 7. PROVENANCE alignment (v5.5): zone captions are Tableau WORKSHEET names
#    (parse-twb-layout puts the zone's worksheet ref in 'caption'; display_title
#    rides separately) and the provenance-built plan's tableau_view is the exact
#    worksheet name — so census matching is exact even when two worksheets on
#    different dashboards SHARE a display title.
shared_title = [
  { 'dashboard' => 'Alpha Overview', 'zones' => [zone('A KPI Revenue').merge('display_title' => 'Net Revenue')] },
  { 'dashboard' => 'Beta Detail',    'zones' => [zone('Net Revenue')] }
]
plan_prov = [{ 'tableau_view' => 'A KPI Revenue', 'chart' => 'Net Revenue' },
             { 'tableau_view' => 'Net Revenue',   'chart' => 'Net Revenue' }]
c_prov = ZoneCensus.tile_census(shared_title, plan_prov, [])
ok(c_prov['zones_unmatched'].zero? && c_prov['zones_total'] == 2,
   'worksheet-keyed plan (provenance) matches same-display-title zones exactly on full scope=[]')

# 8. The pre-provenance field shape: display-name matching double-mapped both
#    charts onto ONE view and dropped the other — the census must still CATCH
#    the dropped worksheet (the plan fix must not mask gate 5's job).
plan_doublemap = [{ 'tableau_view' => 'A KPI Revenue', 'chart' => 'Total Revenue' },
                  { 'tableau_view' => 'A KPI Revenue', 'chart' => 'Total Revenue' }]
c_dm = ZoneCensus.tile_census(shared_title, plan_doublemap, [])
ok(c_dm['zones_unmatched'] == 1 && c_dm['unmatched_zone_names'] == ['Net Revenue'],
   'a double-mapped plan still surfaces the dropped worksheet as unmatched (census not masked)')

puts
if FAIL.empty?
  puts "ALL PASS — tile census is dashboard-scoped; the multi-dashboard false RED is fixed"
  exit 0
else
  puts "#{FAIL.length} FAILED"
  exit 1
end
