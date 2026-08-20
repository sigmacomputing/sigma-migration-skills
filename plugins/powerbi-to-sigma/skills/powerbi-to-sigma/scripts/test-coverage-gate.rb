#!/usr/bin/env ruby
# test-coverage-gate.rb — unit test for CoverageGate (the migration-coverage
# surfacing added for customer feedback 2026-06-25). Converter-agnostic, pure,
# no network. Canonical in shared/scripts ().
# Run: ruby scripts/test-coverage-gate.rb
require 'json'
require_relative 'lib/coverage_gate'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# A realistic coverage.json: 12 source visuals, 5 approximations (exotic chart
# types — informational), 1 degraded field-drop (recoverable). Nothing dropped.
COVERAGE = {
  'version' => 1, 'source' => 'test',
  'summary' => { 'sourceVisuals' => 12, 'builtElements' => 19,
                 'dropped' => 0, 'degraded' => 1, 'approximated' => 5, 'recoverable' => 1 },
  'unresolved' => [
    { 'visual' => 'Profit Margin (gauge)', 'source_type' => 'gauge', 'sigma_kind' => 'kpi-chart',
      'severity' => 'approximated', 'recoverable' => false,
      'detail' => 'gauge has no native Sigma element kind — approximated as kpi-chart',
      'action' => 'Sigma has no native gauge; accept or pick a different chart.' },
    { 'visual' => 'Sub-Cat table', 'source_type' => 'table', 'sigma_kind' => 'table',
      'severity' => 'degraded', 'recoverable' => true,
      'detail' => "field(s) Sales Rank not reachable on master 'SUPERSTORE' — dropped",
      'action' => 'Add a single joined master element covering Sales Rank in the source map.' }
  ]
}

# headline leads with what CARRIED OVER: nothing dropped here (5 approx + 1 degraded
# all still build), so all 12 carried over.
hl = CoverageGate.headline(COVERAGE)
ok('headline reports 12/12 carried (approx/degraded still build)', hl.include?('12/12'))
ok('headline counts approximated', hl.include?('5 approximated'))
ok('headline reports 0 dropped', hl.include?('0 dropped'))

# only DROPPED visuals reduce the carried count; approximated does NOT.
multi = { 'summary' => { 'sourceVisuals' => 3, 'approximated' => 1, 'degraded' => 1, 'dropped' => 1 },
          'unresolved' => [
            { 'visual' => 'A', 'severity' => 'degraded', 'recoverable' => true },
            { 'visual' => 'A', 'severity' => 'approximated', 'recoverable' => false },
            { 'visual' => 'B', 'severity' => 'dropped', 'recoverable' => true }
          ] }
ok('distinct_visuals_with_gaps de-dupes (A counted once)',
   CoverageGate.distinct_visuals_with_gaps(multi) == 2)
ok('distinct_dropped_visuals counts only dropped (B)',
   CoverageGate.distinct_dropped_visuals(multi) == 1)
ok('headline subtracts only DROPPED visuals (2/3 carried)',
   CoverageGate.headline(multi).include?('2/3'))

# questions: ONLY recoverable items become decisions.
qs = CoverageGate.questions(COVERAGE)
ok('exactly 1 recoverable question', qs.size == 1)
ok('question is the degraded field-drop', qs.first['visual'] == 'Sub-Cat table')
ok('question id namespaced by severity', qs.first['id'] == 'coverage_degraded')
ok('recover option carries the action note',
   qs.first['options'].first.include?('joined master'))
ok('non-recoverable approximation is NOT asked',
   qs.none? { |q| q['visual'].include?('gauge') })

# source_type passthrough accepts either the neutral key or legacy pbi_type.
legacy = { 'unresolved' => [{ 'visual' => 'V', 'pbi_type' => 'map', 'severity' => 'dropped', 'recoverable' => true }] }
ok('questions() reads legacy pbi_type into source_type',
   CoverageGate.questions(legacy).first['source_type'] == 'map')

# report ordering: dropped < degraded < approximated; every recoverable item tagged.
lines = CoverageGate.report_lines(COVERAGE)
ok('report has a line per unresolved entry', lines.size == 2)
ok('degraded line marked [recoverable]', lines.any? { |l| l.include?('[recoverable]') && l.include?('Sub-Cat') })
ok('approximation line NOT marked recoverable', lines.none? { |l| l.include?('[recoverable]') && l.include?('gauge') })
deg_i = lines.index { |l| l.include?('DEGRADED') }
app_i = lines.index { |l| l.include?('APPROXIMATED') }
ok('DEGRADED sorts before APPROXIMATED', deg_i && app_i && deg_i < app_i)

# defensive load: missing file / garbage -> nil (caller no-ops, never crashes).
ok('load(nil) -> nil', CoverageGate.load(nil).nil?)
ok('load(missing) -> nil', CoverageGate.load('/no/such/coverage.json').nil?)
ok('questions(nil) -> []', CoverageGate.questions(nil) == [])

# ── classify_causes + report_lines_by_cause (cause grouping, 2026-07-17) ──
# neutral fixture names (no customer identifiers).
cov = {
  'summary' => { 'sourceVisuals' => 4 },
  'unresolved' => [
    { 'visual' => 'Region sales', 'severity' => 'dropped', 'recoverable' => true, 'entity' => 'Dim Territory',
      'detail' => 'field(s) TerritoryName could not be resolved to a master column — dropped' },
    { 'visual' => 'Margin KPI', 'severity' => 'dropped', 'recoverable' => true, 'entity' => 'Fact Sales',
      'detail' => 'field(s) Weird Ratio could not be resolved to a master column — dropped' },
    { 'visual' => 'Rank tile', 'severity' => 'dropped', 'recoverable' => true, 'entity' => 'Fact Sales',
      'detail' => 'field(s) Sales Rank could not be resolved to a master column — dropped' }
  ]
}
CoverageGate.classify_causes(cov,
                             ungranted: { 'maincat.gold_dims' => ['Dim Territory', 'Dim Vendor'] },
                             connection: 'conn-123',
                             dax_dropped: ['Weird Ratio'],
                             dax_crosstable: ['Sales Rank'])
by = cov['unresolved'].each_with_object({}) { |u, h| h[u['visual']] = u }
ok('classify: ungranted-schema drop matched by entity', by['Region sales']['cause'] == 'ungranted_schema')
ok('classify: non-translatable DAX flipped to recoverable:false',
   by['Margin KPI']['cause'] == 'nontranslatable_dax' && by['Margin KPI']['recoverable'] == false)
ok('classify: cross-table measure stays recoverable',
   by['Rank tile']['cause'] == 'cross_table_measure' && by['Rank tile']['recoverable'] == true)
ok('classify: causes_summary carries schema + connection',
   cov.dig('causes_summary', 'ungranted_schemas').key?('maincat.gold_dims') &&
   cov.dig('causes_summary', 'connection') == 'conn-123')

cl = CoverageGate.report_lines_by_cause(cov)
ok('grouped: leads with a GRANT action naming schema + connection',
   cl.any? { |l| l.include?('UNGRANTED SCHEMA') && l.include?('gold_dims') && l.include?('grant') && l.include?('conn-123') })
ok('grouped: surfaces non-translatable DAX as its own cause',
   cl.any? { |l| l.include?('NONTRANSLATABLE DAX') })
ok('grouped: falls back to flat report when unclassified',
   CoverageGate.report_lines_by_cause(COVERAGE).size == 2)

# ── binding-level coverage (the defect this exists to catch): a dashboard
# where every visual BUILT but half its FIELDS dropped previously reported
# "12/12 source visuals carried over; 0 dropped" and passed every gate. Fields
# are what the customer actually sees, so they get their own accounting + gate.
COV = { 'summary' => { 'sourceVisuals' => 12, 'sourceBindings' => 198,
                       'resolvedBindings' => 96, 'dropped' => 0 },
        'unresolved' => [{ 'visual' => 'KPI Card', 'severity' => 'degraded',
                           'role_class' => 'kpi',
                           'field_bindings' => [
                             { 'queryRef' => 'F.Renewals Bound', 'status' => 'dropped' },
                             { 'queryRef' => 'F.Premium', 'status' => 'resolved' }] }] }.freeze
ok('binding_loss = 1 - 96/198 = 0.515', (CoverageGate.binding_loss(COV) - 0.5151).abs < 0.001)
ok('headline reports FIELD bindings, not just visuals',
   CoverageGate.binding_headline(COV).include?('96/198'))
st, why = CoverageGate.gate!(COV, min_resolved: 0.95, allow_override: false)
ok('48% field loss FAILS the gate', st == :fail)
ok('failure reason names binding loss', why.to_s =~ /binding/i)
st2, = CoverageGate.gate!(COV, min_resolved: 0.95, allow_override: true)
ok('explicit override lets a known-degraded migration through', st2 == :pass)

# A functional-role drop fails even when the ratio is fine.
COV2 = { 'summary' => { 'sourceBindings' => 100, 'resolvedBindings' => 99 },
         'unresolved' => [{ 'visual' => 'Date', 'severity' => 'dropped',
                            'role_class' => 'control' }] }.freeze
st3, why3 = CoverageGate.gate!(COV2, min_resolved: 0.95, allow_override: false)
ok('a DROPPED control fails the gate regardless of ratio', st3 == :fail)
ok('reason names the lost control', why3.to_s =~ /control/i)

# review finding: the override path for a functional-role drop must NOT hide
# the reason — the component name and its role must survive into the
# overridden message (previously they silently vanished).
st4, why4 = CoverageGate.gate!(COV2, min_resolved: 0.95, allow_override: true)
ok('override of a dropped control still PASSES', st4 == :pass)
ok('override of a dropped control still names the component', why4.to_s.include?('Date'))
ok('override of a dropped control still names its role', why4.to_s.include?('control'))
ok('override message is tagged overridden', why4.to_s.start_with?('overridden:'))

# review finding: nil coverage (CoverageGate.load returns nil when
# coverage.json is missing/absent) must be treated as "no bindings recorded" —
# never crash, never spuriously FAIL a run that has no coverage data at all.
ok('binding_totals(nil) -> [0, 0], no crash', CoverageGate.binding_totals(nil) == [0, 0])
ok('binding_loss(nil) -> 0.0, no crash', CoverageGate.binding_loss(nil) == 0.0)
ok('binding_headline(nil) -> explicit no-data message',
   CoverageGate.binding_headline(nil) == 'no field-binding data recorded')
stn, whyn = CoverageGate.gate!(nil, min_resolved: 0.95, allow_override: false)
ok('gate!(nil) does not crash and does not spuriously fail', stn == :pass)

# review finding: malformed data (resolvedBindings > sourceBindings) must not
# push binding_loss outside its documented 0.0..1.0 contract, and the headline
# must stay consistent with whatever clamp is applied (no negative counts).
BAD = { 'summary' => { 'sourceBindings' => 10, 'resolvedBindings' => 15 } }.freeze
ok('binding_totals clamps resolved to total when resolved > total',
   CoverageGate.binding_totals(BAD) == [10, 10])
ok('binding_loss stays within 0.0..1.0 for malformed (resolved > total) data',
   CoverageGate.binding_loss(BAD) == 0.0)
bad_headline = CoverageGate.binding_headline(BAD)
ok('binding_headline has no negative dropped count for malformed data',
   !bad_headline.include?('-5') && !bad_headline.include?('150.0%'))

# total == 0 (no bindings recorded anywhere) must not divide-by-zero or
# report a 100% loss — it is "no data", not "total loss".
EMPTY = { 'summary' => { 'sourceBindings' => 0, 'resolvedBindings' => 0 } }.freeze
ok('binding_totals total==0 -> [0, 0]', CoverageGate.binding_totals(EMPTY) == [0, 0])
ok('binding_loss total==0 -> 0.0 (no data, not total loss)', CoverageGate.binding_loss(EMPTY) == 0.0)
ok('binding_headline total==0 -> explicit no-data message',
   CoverageGate.binding_headline(EMPTY) == 'no field-binding data recorded')

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
