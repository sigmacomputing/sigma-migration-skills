# frozen_string_literal: true
# run: ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb
require 'json'
require_relative 'lib/kpi_card'
require_relative 'lib/kpi_comparison_detect'

$failures = 0
def check(desc); ok = yield; puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}"); $failures += 1 unless ok; end

# pick_kpi_measure lives in build-charts-from-signals.rb (unsafe to require —
# it runs a whole CLI). Extract the pure def the same way test-kpi-value-
# fidelity.rb does, so the value-picker fix (never headline a delta/CHANGE
# measure) can be unit-asserted alongside the detector.
BUILD_SRC = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
%w[map_column guid_from_text placeholder_calc? pick_kpi_measure].each do |fn|
  m = BUILD_SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn} from build-charts-from-signals.rb")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

# Single-value KPI: the element the emitter produces must carry the same
# load-bearing fields the old inline hash did (kind, source, value.columnId).
check('single-value KPI element preserves kind/source/value.columnId') do
  el = KpiCard.build(id: 'kpi-x', name: 'Sales', source_element_id: 'tbl-src',
                     columns: [{ 'id' => 'sales_col' }], value_column_id: 'sales_col')
  el['kind'] == 'kpi-chart' &&
    el['source'] == { 'kind' => 'table', 'elementId' => 'tbl-src' } &&
    el['value']['columnId'] == 'sales_col' &&
    !el.key?('comparisonColumn')
end

# Task 5 detector: KpiComparisonDetect.detect(measures, value_col_id) — the
# require-safe, unit-testable home for the prior/target comparison regex
# (moved out of build-charts-from-signals.rb, which is unsafe to require in a
# test — see task-5-report.md).
check('detect_comparison_measure picks a single prior-period measure') do
  measures = [
    { 'id' => 'rev_cur',   'name' => 'Revenue' },
    { 'id' => 'rev_prior', 'name' => 'Revenue vs Prior Year' }
  ]
  KpiComparisonDetect.detect(measures, 'rev_cur') == 'rev_prior'
end

check('detect_comparison_measure returns nil when none match') do
  measures = [{ 'id' => 'rev_cur', 'name' => 'Revenue' }, { 'id' => 'units', 'name' => 'Units' }]
  KpiComparisonDetect.detect(measures, 'rev_cur').nil?
end

# Two prior-VALUE siblings on the same shelf is genuinely ambiguous → nil.
# (A "change from prev" DELTA is NOT a prior value under the sharpened
# semantics, so it no longer counts toward ambiguity — see the delta guard.)
check('detect_comparison_measure returns nil when ambiguous (2+ prior-value siblings)') do
  measures = [
    { 'id' => 'a', 'name' => 'Revenue' },
    { 'id' => 'b', 'name' => 'vs prior month' },
    { 'id' => 'c', 'name' => 'PY revenue' }
  ]
  KpiComparisonDetect.detect(measures, 'a').nil?
end

# A DELTA sibling ("change from prev") is never a prior VALUE, so a lone real
# prior-value sibling alongside it is unambiguous and still wires.
check('detect_comparison_measure ignores a delta sibling and wires the lone prior value') do
  measures = [
    { 'id' => 'a', 'name' => 'Revenue' },
    { 'id' => 'b', 'name' => 'Revenue Prior Year' },
    { 'id' => 'c', 'name' => 'change from prev' }
  ]
  KpiComparisonDetect.detect(measures, 'a') == 'b'
end

# End-to-end: a detected comparison id flows into KpiCard.build exactly like
# an explicitly-wired one (the actual integration point in build_kpi_element).
check('a detected comparison id wires KpiCard.build\'s comparisonColumn') do
  measures = [
    { 'id' => 'rev_cur',   'name' => 'Revenue' },
    { 'id' => 'rev_prior', 'name' => 'Revenue vs Prior Year' }
  ]
  cmp_id = KpiComparisonDetect.detect(measures, 'rev_cur')
  el = KpiCard.build(id: 'kpi-y', name: 'Revenue', source_element_id: 'tbl-src',
                     columns: [{ 'id' => 'rev_cur' }], value_column_id: 'rev_cur',
                     comparison_column_id: cmp_id, good_direction: :up)
  el['comparisonColumn'] == { 'columnId' => 'rev_prior' } &&
    el['columns'].any? { |c| c['id'] == 'rev_prior' }
end

# ---------------------------------------------------------------------------
# Superstore YTD-vs-PYTD pattern (cold-migration gap: none of these auto-wired).
# The KPI tile shelf carries a TOTAL + two sign-split delta ratios; the PRIOR
# VALUE lives only in the MASTER/DM columns, NOT on the tile shelf.
# ---------------------------------------------------------------------------

# Fix #1a — the value picker must NEVER headline a pre-computed delta/CHANGE
# measure. Given TOTAL YTD SALES + SALES CHANGE POS/NEG (CHANGE ordered FIRST,
# so the old first-wins tiebreak would have grabbed a CHANGE ratio), pick the
# total/period measure.
check('pick_kpi_measure headlines TOTAL YTD SALES, not a CHANGE delta measure') do
  measures = [
    { 'column' => '[SALES CHANGE NEG]', 'derivation' => 'usr' },
    { 'column' => '[SALES CHANGE POS]', 'derivation' => 'usr' },
    { 'column' => '[TOTAL YTD SALES]',  'derivation' => 'usr' }
  ]
  picked = pick_kpi_measure(measures, {})
  picked && picked['column'] == '[TOTAL YTD SALES]'
end

# Fix #1b — YTD↔PYTD comparison detection via MASTER columns. The tile's own
# siblings are deltas (CHANGE POS/NEG), so shelf detection finds nothing; the
# detector must pair the value's base metric (Sales) against a prior-VALUE
# master column (PYTD Sales) and wire THAT.
SUPERSTORE_TILE = [
  { 'id' => 'v-sales',  'name' => 'TOTAL YTD SALES' },
  { 'id' => 'cp-sales', 'name' => 'SALES CHANGE POS' },
  { 'id' => 'cn-sales', 'name' => 'SALES CHANGE NEG' }
].freeze
SUPERSTORE_MASTER = [
  { 'id' => 'm-ytd-sales',   'name' => 'YTD Sales' },
  { 'id' => 'm-pytd-sales',  'name' => 'PYTD Sales' },
  { 'id' => 'm-ytd-profit',  'name' => 'YTD Profit' },
  { 'id' => 'm-pytd-profit', 'name' => 'PYTD Profit' }
].freeze

check('detect pairs TOTAL YTD SALES with the PYTD Sales MASTER column') do
  KpiComparisonDetect.detect(SUPERSTORE_TILE, 'm-ytd-sales',
                             master_columns: SUPERSTORE_MASTER,
                             value_name: 'TOTAL YTD SALES') == 'm-pytd-sales'
end

check('detect does NOT pick a CHANGE/delta sibling as the comparison') do
  cmp = KpiComparisonDetect.detect(SUPERSTORE_TILE, 'm-ytd-sales',
                                   master_columns: SUPERSTORE_MASTER,
                                   value_name: 'TOTAL YTD SALES')
  %w[cp-sales cn-sales].none? { |x| cmp == x } && cmp != 'm-ytd-sales'
end

check('detect base-pairs the RIGHT prior metric (Profit→PYTD Profit, not PYTD Sales)') do
  KpiComparisonDetect.detect(
    [{ 'id' => 'v-p', 'name' => 'TOTAL YTD Profit' }, { 'id' => 'c-p', 'name' => 'Profit Change Neg' }],
    'm-ytd-profit', master_columns: SUPERSTORE_MASTER, value_name: 'TOTAL YTD Profit'
  ) == 'm-pytd-profit'
end

check('a tile with no prior-value sibling and no prior MASTER column → single-value (nil)') do
  KpiComparisonDetect.detect(
    [{ 'id' => 'v-o', 'name' => 'Total Orders' }],
    'm-orders', master_columns: [{ 'id' => 'm-orders', 'name' => 'Orders' }],
    value_name: 'Total Orders'
  ).nil?
end

check('detect stays conservative: ambiguous prior-value master columns → nil') do
  KpiComparisonDetect.detect(
    [{ 'id' => 'v-s', 'name' => 'TOTAL YTD Sales' }], 'm-ytd-sales',
    master_columns: [{ 'id' => 'p1', 'name' => 'PYTD Sales' }, { 'id' => 'p2', 'name' => 'Prior Year Sales' }],
    value_name: 'TOTAL YTD Sales'
  ).nil?
end

check('detect never treats a YoY Change master column as the prior value') do
  KpiComparisonDetect.detect(
    [{ 'id' => 'v-s', 'name' => 'TOTAL YTD Sales' }], 'm-ytd-sales',
    master_columns: [{ 'id' => 'chg', 'name' => 'YoY Change Sales' }],
    value_name: 'TOTAL YTD Sales'
  ).nil?
end

exit($failures.zero? ? 0 : 1)
