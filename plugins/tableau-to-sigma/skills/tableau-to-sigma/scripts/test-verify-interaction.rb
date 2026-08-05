#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for verify-interaction.rb's pure core (InteractionOracle).
# No network, no creds — the CLI is guarded out on require (same idiom as
# test-verify-anchors.rb / test-fidelity-loop.rb). Covers:
#   1. control selection from a control-scope fixture (filters+emitted only;
#      per-dashboard grouping; parameter controls SKIP with the v2 note)
#   2. flip-value picking from a view CSV vs saved Sigma defaults
#   3. the tableau_flip_changed validity rule (no flip → SKIP-INVALID, not FAIL)
#   4. verdict matching (formatted Tableau "$48,210" vs raw Sigma 48210.5 must
#      match via AnchorValues; 10x-off must miss; inert Sigma flip FAILs)
#
# Usage: ruby scripts/test-verify-interaction.rb

ENV['VERIFY_INTERACTION_CLI'] = nil
require_relative 'verify-interaction' # loads InteractionOracle (CLI guarded out)

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

O = InteractionOracle

puts '-- control selection (spec 3.2) --'
scope = [
  { 'controlId' => 'ctl-region', 'name' => 'Region', 'mechanism' => 'filters',
    'status' => 'emitted', 'targets' => [{ 'source' => { 'elementId' => 'master' }, 'columnId' => 'c1' }],
    'zone_dashboards' => ['Overview'] },
  { 'controlId' => 'ctl-segment', 'name' => 'Segment', 'mechanism' => 'filters',
    'status' => 'emitted', 'targets' => [{ 'source' => { 'elementId' => 'master' }, 'columnId' => 'c2' }],
    'zone_dashboards' => [] }, # no zone parsed → applies everywhere
  { 'controlId' => 'ctl-param-year', 'name' => 'Year', 'mechanism' => 'formula',
    'status' => 'emitted' }, # Tableau parameter → v1 SKIP
  { 'controlId' => 'ctl-dropped', 'name' => 'Ship Mode', 'mechanism' => 'filters',
    'status' => 'dropped', 'intended' => [] } # no targets → not probeable
]
sel = O.select_controls(scope, %w[Overview Detail])
ok(sel['by_dashboard']['Overview'].map { |r| r['controlId'] } == %w[ctl-region ctl-segment],
   'Overview gets its zone control plus the everywhere control, in order')
ok(sel['by_dashboard']['Detail'].map { |r| r['controlId'] } == %w[ctl-segment],
   'Detail gets only the everywhere control (zone grouping respected)')
param_skip = sel['skips'].find { |s| s['controlId'] == 'ctl-param-year' }
ok(param_skip && param_skip['result'] == 'SKIP' && param_skip['note'].include?('unverified'),
   'parameter (mechanism=formula) control SKIPs with the v2 note')
ok(sel['skips'].any? { |s| s['controlId'] == 'ctl-dropped' && s['note'].include?('not probeable') },
   'dropped/no-target filters control SKIPs as not probeable')
only = O.select_controls(scope, ['Overview'], only: ['ctl-segment'])
ok(only['by_dashboard']['Overview'].map { |r| r['controlId'] } == %w[ctl-segment] && only['skips'].empty?,
   '--control restriction filters candidates AND skips')
none = O.select_controls(scope, [])
ok(none['by_dashboard'].keys == [nil] && none['by_dashboard'][nil].length == 2,
   'no dashboard layout → one implicit dashboard with every candidate')

puts '-- flip-value picking (spec 3.3) --'
view_csv = <<~CSV
  Region,Sales
  East,"48,210"
  West,"12,003"
  South,"9,750"
CSV
val, note, hdr = O.pick_flip_value('Region', 'list', view_csv, ['East'])
ok(val == 'West' && hdr == 'Region', "first non-default distinct value picked (got #{val.inspect})")
ok(note.include?('auto-picked'), 'note records the auto-pick source')
val2, = O.pick_flip_value(' REGION ', 'segmented', view_csv, [])
ok(val2 == 'East', 'caption match is norm_cap (case/space-insensitive); no defaults → first distinct')
val3, note3, = O.pick_flip_value('Region', 'list', view_csv, %w[East West South])
ok(val3.nil? && note3.include?('no non-default'), 'all values are defaults → no flip value')
val4, note4, = O.pick_flip_value('Category', 'list', view_csv, [])
ok(val4.nil? && note4.include?('not in the view CSV'), 'caption absent from the view CSV → skip note')
val5, = O.pick_flip_value('Flag', 'switch', '', ['true'])
ok(val5 == 'false', 'switch flips true → false')
val6, note6, = O.pick_flip_value('Order Date', 'date-range', view_csv, [])
ok(val6.nil? && note6.include?('no auto flip value'), 'date/range/slider control types SKIP')
bom_csv = "\uFEFFRegion,Sales\nEast,1\nWest,2\n"
val7, = O.pick_flip_value('Region', 'list', bom_csv, ['East'])
ok(val7 == 'West', 'BOM-prefixed Tableau CSV still parses (header match survives)')

puts '-- tableau_flip_changed validity rule (spec 3.5.1) --'
tab_base = "Region,Sales\nEast,10\nWest,20\n"
tab_noop = "West,20\nRegion,Sales\nEast,10\n" # same lines, different order
sig_base = "Region,Sales\nEast,10\n"
sig_flip = "Region,Sales\nWest,20\n"
v = O.checks_for(tab_base, tab_noop, sig_base, sig_flip)
ok(v['result'] == 'SKIP-INVALID', 'unchanged Tableau CSV (row order ignored) → SKIP-INVALID, never FAIL')
ok(v['checks']['tableau_flip_changed'] == false && v['checks']['sigma_flip_changed'].nil?,
   'invalid probe records check 1 false and leaves the Sigma checks null')

puts '-- verdict matching (spec 3.5.2 + 3.5.3) --'
# Formatted Tableau values vs raw Sigma numbers — AnchorValues must bridge.
tab_flip = <<~CSV
  Segment,Sales
  Consumer,"$48,210"
  Corporate,"$12,003"
CSV
sigma_flip_good = <<~CSV
  Segment,Sales
  Consumer,48210.5
  Corporate,12003.2
CSV
sigma_base2 = "Segment,Sales\nConsumer,99999\n"
v_pass = O.checks_for(tab_base, tab_flip, sigma_base2, sigma_flip_good)
ok(v_pass['result'] == 'PASS' && v_pass['checks']['sigma_flip_changed'] == true,
   'formatted "$48,210" matches raw 48210.5 → PASS')
ok(v_pass['checks']['cross_anchor_match'] == true, 'cross_anchor_match true on the good flip')
by_kind = v_pass['anchors'].each_with_object({}) { |a, h| h[a['kind']] = a }
ok(by_kind['max'] && by_kind['max']['raw'] == '$48,210' && by_kind['max']['matched'],
   'max anchor carries the printed cell form and matched')
ok(by_kind['sum'] && by_kind['sum']['matched'],
   'sum anchor (48210.5+12003.2 vs $48,210+$12,003 at printed precision) matched')

# The field failure this oracle exists for: 10x-off values must MISS.
sigma_flip_10x = "Segment,Sales\nConsumer,482105\nCorporate,120032\n"
v_10x = O.checks_for(tab_base, tab_flip, sigma_base2, sigma_flip_10x)
ok(v_10x['result'] == 'FAIL' && v_10x['checks']['cross_anchor_match'] == false,
   '10x-off Sigma values → cross_anchor_match false → FAIL')

# Wired-but-inert: Sigma export identical under the flip.
v_inert = O.checks_for(tab_base, tab_flip, sigma_flip_good, sigma_flip_good)
ok(v_inert['result'] == 'FAIL' && v_inert['checks']['sigma_flip_changed'] == false,
   'identical Sigma base/flip → wired but inert → FAIL')
ok(v_inert['note'].include?('inert'), 'inert failure says so in the note')

# No shared numeric columns → anchor check N/A, verdict degrades to check 2.
sigma_other = "Completely,Different\nx,y\n"
sigma_other2 = "Completely,Different\nz,w\n"
v_na = O.checks_for(tab_base, tab_flip, sigma_other, sigma_other2)
ok(v_na['checks']['cross_anchor_match'].nil? && v_na['result'] == 'PASS',
   'no shared numeric columns → cross check null, sigma_flip_changed carries the verdict')
ok(v_na['note'].include?('N/A'), 'anchor N/A note recorded')

puts '-- anchor derivation details --'
cols = O.columns_of("A,B,Label\n1,\"$5,000\",x\n2,\"$1,000\",y\n3,\"$2,500\",z\n")
anchors = O.derive_anchors(cols, %w[A B Label])
ok(anchors.none? { |a| a['column'] == 'Label' }, 'non-numeric column yields no anchors')
b = anchors.select { |a| a['column'] == 'B' }
ok(b.map { |a| a['kind'] }.sort == %w[max min sum], 'numeric column yields max+min+sum')
ok(b.find { |a| a['kind'] == 'max' }['raw'] == '$5,000' &&
   b.find { |a| a['kind'] == 'min' }['raw'] == '$1,000',
   'max/min anchors keep the printed cell forms')
big = O.derive_anchors(O.columns_of("Id\n9000000000000\n9100000000000\n"), ['Id'])
ok(big.none? { |a| a['kind'] == 'sum' }, 'non-additive-looking column (|v|>=1e12) skips the sum anchor')

puts
if $fails.empty?
  puts 'ALL PASS — interaction oracle core (selection / flip pick / validity / verdict) behaves'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
