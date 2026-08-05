#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-reportbuild.rb — unit tests for the pure report-build helpers
# (lib/pbi_reportbuild.rb): friendly naming, one-base-table-per-page master
# selection, and boolean-slicer detection. Creds-free, network-free, synthetic
# data only (generic SALES_FACT/DATE_DIM/REGION names — NO customer data).
require_relative 'lib/pbi_reportbuild'

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# ---- friendly_label: raw warehouse names -> human display names -------------
F = PbiReportBuild.method(:friendly_label)
ok('raw ALL-CAPS indicator "IS Active IND" -> "Is Active Ind"', F.call('IS Active IND') == 'Is Active Ind')
ok('snake_case "SALES_AMOUNT" -> "Sales Amount"',              F.call('SALES_AMOUNT') == 'Sales Amount')
ok('mixed raw "Submission KEY by Level 1 Name" fixes KEY',
   F.call('Submission KEY by Level 1 Name') == 'Submission Key by Level 1 Name')
ok('preserves real acronym "Customer ID"',                     F.call('Customer ID') == 'Customer ID')
ok('preserves "GL Balance" acronym',                           F.call('GL Balance') == 'GL Balance')
ok('leaves already-human "Total Sales" untouched',             F.call('Total Sales') == 'Total Sales')
ok('leaves "Sales by Region" untouched',                       F.call('Sales by Region') == 'Sales by Region')
ok('non-string passes through (nil)',                          F.call(nil).nil?)
ok('empty string passes through',                              F.call('') == '')
ok('all-caps single token "REGION" -> "Region"',               F.call('REGION') == 'Region')

# ---- page_base_master: the ONE master resolving the most page fields --------
# masters_for maps a queryRef to the masters it can resolve on (primary + alts).
FIELD_MASTER = {
  'SALES_FACT.Region'      => ['SALES'],
  'SALES_FACT.Sales Amount' => ['SALES'],
  'SALES_FACT.Order Count'  => ['SALES'],
  'DATE_DIM.Order Date'     => ['SALES'],       # dim folded into the wide base
  'INVENTORY.On Hand'       => ['INVENTORY']    # a different fact — minority on the page
}.freeze
masters_for = ->(qr) { FIELD_MASTER[qr] || [] }

# A page whose visuals overwhelmingly hit SALES + one INVENTORY tile.
page_visuals = [
  { 'bindings' => { 'Values' => ['SALES_FACT.Sales Amount'] } },              # kpi
  { 'bindings' => { 'Category' => ['SALES_FACT.Region'], 'Y' => ['SALES_FACT.Sales Amount', 'SALES_FACT.Order Count'] } }, # bar
  { 'bindings' => { 'Values' => ['SALES_FACT.Region', 'SALES_FACT.Sales Amount'] } }, # table
  { 'bindings' => { 'Values' => ['INVENTORY.On Hand'] } }                     # lone other-fact tile
]
ok('page_base_master picks the dominant master (SALES)',
   PbiReportBuild.page_base_master(page_visuals, masters_for) == 'SALES')

ok('page_base_master is nil when nothing resolves',
   PbiReportBuild.page_base_master([{ 'bindings' => { 'Values' => ['GHOST.Col'] } }], masters_for).nil?)

# deterministic tie-break: first-seen master wins on a tie.
tie_for = ->(qr) { { 'a' => ['A'], 'b' => ['B'] }[qr] }
tie_visuals = [{ 'bindings' => { 'X' => ['a'], 'Y' => ['b'] } }]
ok('page_base_master tie -> first-seen (A)', PbiReportBuild.page_base_master(tie_visuals, tie_for) == 'A')

# ---- boolean_leaf?: indicator naming, conservative --------------------------
B = PbiReportBuild.method(:boolean_leaf?)
ok('"Is Active" -> boolean',        B.call('Is Active'))
ok('"IS Active IND" -> boolean',    B.call('IS Active IND'))
ok('"Has Discount" -> boolean',     B.call('Has Discount'))
ok('"Active Flag" -> boolean',      B.call('Active Flag'))
ok('"Region" -> NOT boolean',       !B.call('Region'))
ok('"Order Count" -> NOT boolean',  !B.call('Order Count'))

ok('boolean_domain_values is [true, false]', PbiReportBuild.boolean_domain_values == [true, false])

# ---- foreign_master_refs: cross-master leak detection -----------------------
MIDS = %w[master-order master-py].freeze
BYNAME = { 'ORDER' => 'master-order', 'PY' => 'master-py' }.freeze
G = ->(f, src) { PbiReportBuild.foreign_master_refs(f, src, MIDS, BYNAME) }
ok('same-source ref is allowed (Sum([master-order/Net Revenue]) sourced from master-order)',
   G.call('Sum([master-order/Net Revenue])', 'master-order').empty?)
ok('cross-master ref is flagged (references master-py while sourced from master-order)',
   G.call('Sum([master-py/Net Revenue PY])', 'master-order') == ['master-py'])
ok('mixed formula flags only the foreign master',
   G.call('Sum([master-py/PY]) / Sum([master-order/Cur])', 'master-order') == ['master-py'])
ok('display-name token resolves to a master id and is flagged',
   G.call('Sum([PY/Net Revenue PY])', 'master-order') == ['master-py'])
ok('display-name token equal to the source is allowed',
   G.call('[ORDER/Region]', 'master-order').empty?)
ok('same-element column ref [Col] (no slash) is ignored',
   G.call('[Sales Amount] / [Order Count]', 'master-order').empty?)
ok('a non-master cross-element ref ([Metrics/..]) is ignored',
   G.call('[Metrics/Net Revenue]', 'master-order').empty?)

puts($fail.zero? ? "\nall pbi-reportbuild unit tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
