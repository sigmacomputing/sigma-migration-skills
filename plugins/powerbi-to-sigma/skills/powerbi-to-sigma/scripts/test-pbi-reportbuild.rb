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

# A dominant page base must not be forced onto a specialized visual when it
# resolves only some of that visual's fields.
special_for = lambda do |qr|
  {
    'year' => %w[BASE YEAR_GROUP],
    'revenue' => %w[BASE YEAR_GROUP],
    'prior' => ['YEAR_GROUP']
  }[qr]
end
ok('page base is rejected when one visual field needs a specialized master',
   !PbiReportBuild.all_fields_resolve_on?(%w[year revenue prior], 'BASE', special_for))
ok('specialized master is eligible when it resolves every visual field',
   PbiReportBuild.all_fields_resolve_on?(%w[year revenue prior], 'YEAR_GROUP', special_for))

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


# ---- G27 / F14: saved slicer selection -> typed list-control default ---------
VT = PbiReportBuild.method(:value_type)
ok('value_type: int64 -> :int',       VT.call('int64') == :int)
ok('value_type: double -> :float',    VT.call('double') == :float)
ok('value_type: decimal -> :float',   VT.call('decimal') == :float)
ok('value_type: boolean -> :bool',    VT.call('boolean') == :bool)
ok('value_type: string -> :text',     VT.call('string') == :text)
ok('value_type: dateTime -> :date',   VT.call('dateTime') == :date)
ok('value_type: nil -> nil',          VT.call(nil).nil?)

TS = PbiReportBuild.method(:typed_selection)
t = TS.call({ 'mode' => 'include', 'values' => %w[2026L 2025L], 'has_null' => false }, :int)
ok('typed_selection: PBI int literals "2026L" -> Integer 2026', t['values'] == [2026, 2025] && t['mode'] == 'include')
t = TS.call({ 'mode' => 'include', 'values' => [2026.0, '2024'] }, :int)
ok('typed_selection: int column accepts floats-with-no-fraction and bare digit strings', t['values'] == [2026, 2024])
t = TS.call({ 'mode' => 'exclude', 'values' => %w[true false] }, :bool)
ok('typed_selection: bool column "true"/"false" -> true/false', t['values'] == [true, false] && t['mode'] == 'exclude')
t = TS.call({ 'mode' => 'include', 'values' => [true, 'False'] }, :bool)
ok('typed_selection: bool column accepts real booleans and "False"', t['values'] == [true, false])
t = TS.call({ 'mode' => 'include', 'values' => ["'West'", "'O''Brien'", 'East'] }, :text)
ok("typed_selection: text column unquotes PBI literals and un-doubles quotes",
   t['values'] == ['West', "O'Brien", 'East'])
t = TS.call({ 'mode' => 'include', 'values' => [2026, '2025L'] }, :text)
ok('typed_selection: text column stringifies numerics ("2026","2025")', t['values'] == %w[2026 2025])
t = TS.call({ 'mode' => 'include', 'values' => ['2026L', "'x'", 'true', '1.5D'] }, nil)
ok('typed_selection: unknown column type infers per literal (2026L->int, true->bool, 1.5D->float)',
   t['values'] == [2026, 'x', true, 1.5])
t = TS.call({ 'mode' => 'include', 'values' => ["'A'", nil, 'null'], 'has_null' => false }, :text)
ok('typed_selection: null literals are dropped from values and reported as has_null',
   t['values'] == ['A'] && t['has_null'] == true)
t = TS.call({ 'mode' => 'include', 'values' => %w[abc 7L] }, :int)
ok('typed_selection: an unconvertible literal is reported in skipped, never coerced to 0',
   t['values'] == [7] && t['skipped'] == ['abc'])

SS = PbiReportBuild.method(:saved_selection)
ok('saved_selection: new contract {mode,column,values,has_null} is honoured',
   SS.call({ 'saved_selection' => { 'mode' => 'include', 'column' => 'T.C', 'values' => %w[a], 'has_null' => true } })
     .values_at('mode', 'column', 'values', 'has_null') == ['include', 'T.C', %w[a], true])
ok('saved_selection: legacy list selection still honoured',
   SS.call({ 'selection' => { 'type' => 'list', 'mode' => 'exclude', 'values' => %w[x] } })['mode'] == 'exclude')
ok('saved_selection: legacy unsupported / predicate-none selections are ignored',
   SS.call({ 'selection' => { 'type' => 'list', 'unsupported' => true, 'values' => %w[x] } }).nil? &&
   SS.call({ 'selection' => { 'type' => 'list', 'predicate' => 'none', 'values' => %w[x] } }).nil?)
ok('saved_selection (G24): a slicer-self scoped selection is NEVER a default',
   SS.call({ 'saved_selection' => { 'scope' => 'slicer-self', 'mode' => 'include', 'values' => %w[a] } }).nil? &&
   SS.call({ 'selection' => { 'type' => 'list', 'scope' => 'slicer-self', 'mode' => 'include', 'values' => %w[a] } }).nil?)
ok('saved_selection: nil state -> nil', SS.call(nil).nil?)

LD = PbiReportBuild.method(:list_default)
d = LD.call(is_bool: true, type: :bool, state: nil)
ok('list_default (G27): boolean "all" is exclude + [] (include [] matches ZERO rows in Sigma)',
   d['mode'] == 'exclude' && d['values'] == [])
d = LD.call(is_bool: false, type: :text, state: nil)
ok('list_default: non-boolean "all" stays include + []', d['mode'] == 'include' && d['values'] == [])
d = LD.call(is_bool: true, type: :bool, state: { 'saved_selection' => { 'mode' => 'include', 'values' => [] } })
ok('list_default (G27): a saved boolean include [] collapses to exclude [] (never include [])',
   d['mode'] == 'exclude' && d['values'] == [])
d = LD.call(is_bool: true, type: :bool, state: { 'saved_selection' => { 'mode' => 'include', 'values' => [false] } })
ok('list_default: saved boolean include [false] is kept and typed',
   d['mode'] == 'include' && d['values'] == [false])
d = LD.call(is_bool: false, type: :int, state: { 'saved_selection' => { 'mode' => 'include', 'values' => [2026] } })
ok('list_default (F14): saved int selection typed from the column', d['values'] == [2026] && d['mode'] == 'include')
d = LD.call(is_bool: false, type: :text, state: { 'saved_selection' => { 'mode' => 'exclude', 'values' => %w[A], 'has_null' => true } })
ok('list_default: exclude mode + has_null surfaced for coverage',
   d['mode'] == 'exclude' && d['values'] == ['A'] && d['has_null'] == true)
d = LD.call(is_bool: false, type: :text, state: { 'saved_selection' => { 'mode' => 'include', 'column' => 'T.Other', 'values' => ['a'] } },
            qr: 'T.Col')
ok('list_default: a saved selection for a DIFFERENT column is not applied (mismatch reported)',
   d['values'] == [] && d['mismatch'] == 'T.Other')
d = LD.call(is_bool: false, type: :text, state: { 'saved_selection' => { 'mode' => 'include', 'column' => 't.col', 'values' => ['a'] } },
            qr: 'T.Col')
ok('list_default: column match is case-insensitive', d['values'] == ['a'])

# ---- cosmetics helpers ---------------------------------------------------------
CN = PbiReportBuild.method(:container_name?)
ok('container_name?: "Slicer Container 3"', CN.call('Slicer Container 3'))
ok('container_name?: "Container 12"',       CN.call('Container 12'))
ok('container_name?: "Group 5"',            CN.call('Group 5'))
ok('container_name?: raw hex id',           CN.call('a1b2c3d4e5f60708'))
ok('container_name?: "slicer_2"',           CN.call('slicer_2'))
ok('container_name?: a real label "Fiscal Year" is not',  !CN.call('Fiscal Year'))
ok('container_name?: "Region" is not',      !CN.call('Region'))
ok('container_name?: nil/empty is not',     !CN.call(nil) && !CN.call(''))

DA = PbiReportBuild.method(:date_axis?)
ok('date_axis?: TMSL dateTime wins',          DA.call('Anything', 'dateTime'))
ok('date_axis?: TMSL string beats a date-ish name', !DA.call('Date Label', 'string'))
ok('date_axis?: no model -> name heuristic',   DA.call('Order Date', nil) && !DA.call('Region', nil))

NS = PbiReportBuild.method(:natural_sort_formula)
f = NS.call('[master-x/Period]')
ok('natural_sort_formula: refs the column, extracts the digit run, left-pads it',
   f.include?('[master-x/Period]') && f.include?('RegexpExtract') && f.include?('LPad') && f.include?('[0-9]+'))
ok('period_like?: Period/Week/Fiscal Month yes, Region/Customer no',
   %w[Period Week].all? { |n| PbiReportBuild.period_like?(n) } &&
   PbiReportBuild.period_like?('Fiscal Month') &&
   !PbiReportBuild.period_like?('Region') && !PbiReportBuild.period_like?('Customer'))

# ---- binding_miss: hold-back classification --------------------------------------
BM = PbiReportBuild.method(:binding_miss)
line_ok = { 'kind' => 'line-chart', 'xAxis' => { 'columnId' => 'x' }, 'yAxis' => { 'columnIds' => ['y'] } }
ok('binding_miss: a bound line chart is fine', BM.call(line_ok).nil?)
sev, = BM.call({ 'kind' => 'line-chart', 'xAxis' => { 'columnId' => 'x' } })
ok('binding_miss: a line chart with no yAxis is HELD BACK', sev == :hold)
sev, = BM.call({ 'kind' => 'line-chart', 'xAxis' => { 'columnId' => 'x' }, 'yAxis' => { 'columnIds' => [] } })
ok('binding_miss: an empty yAxis.columnIds is HELD BACK', sev == :hold)
sev, = BM.call({ 'kind' => 'bar-chart', 'yAxis' => { 'columnIds' => ['y'] } })
ok('binding_miss: a chart that only lost its xAxis is DEGRADED (still built)', sev == :degrade)
sev, = BM.call({ 'kind' => 'pivot-table', 'rowsBy' => [{ 'columnId' => 'r' }], 'values' => [] })
ok('binding_miss: a pivot with no values (bound values lost) is HELD BACK', sev == :hold)
sev, = BM.call({ 'kind' => 'pivot-table', 'values' => [] })
ok('binding_miss: a pivot with no rows, columns or values is HELD BACK', sev == :hold)
sev, = BM.call({ 'kind' => 'pivot-table', 'rowsBy' => [{ 'columnId' => 'r' }], 'values' => ['v'] })
ok('binding_miss: a pivot with values is fine', sev.nil?)
sev, = BM.call({ 'kind' => 'kpi-chart' })
ok('binding_miss: a KPI with no value is HELD BACK', sev == :hold)
sev, = BM.call({ 'kind' => 'donut-chart', 'color' => { 'columnId' => 'c' } })
ok('binding_miss: a donut with no value is HELD BACK', sev == :hold)
sev, = BM.call({ 'kind' => 'table', 'columns' => [] })
ok('binding_miss: a table with no columns is HELD BACK', sev == :hold)
sev, = BM.call({ 'kind' => 'combo-chart', 'xAxis' => { 'columnId' => 'x' }, 'yAxis' => {} })
ok('binding_miss: a combo with no yAxis columnIds is HELD BACK', sev == :hold)
ok('binding_miss: controls/text are never classified', BM.call({ 'kind' => 'control' }).nil? && BM.call({ 'kind' => 'text' }).nil?)

# ---- measure_first_master: per-visual fallback prefers the master that binds the MEASURES ----
MF = PbiReportBuild.method(:measure_first_master)
mfor = ->(qr) { { 'A.dim' => ['SALES'], 'A.m' => ['INV'], 'B.dim2' => ['SALES'], 'B.dim' => %w[SALES INV] }[qr] || [] }
isme = ->(qr) { qr.end_with?('.m') }
ok('measure_first_master: the master carrying the measure beats the dimension-only master',
   MF.call(%w[A.dim A.m], mfor, isme) == 'INV')
ok('measure_first_master: no measure -> most fields wins (legacy behaviour)',
   MF.call(%w[A.dim B.dim2], mfor, isme) == 'SALES')
ok('measure_first_master: nothing resolves -> nil', MF.call(%w[ghost], mfor, isme).nil?)
ok('measure_first_master: ties break toward the first field\'s master',
   MF.call(%w[B.dim], mfor, isme) == 'SALES')

# ---- page_local_masters!: per-page child copies of shared masters (G21) -----------
def pl_master(id, cols)
  { 'id' => id, 'kind' => 'table', 'name' => id.sub('master-', '').upcase,
    'source' => { 'dataModelId' => 'dm', 'elementId' => 'e', 'kind' => 'data-model' },
    'columns' => cols.map { |c| { 'id' => "#{id}-#{c.downcase}", 'name' => c, 'formula' => "[T/#{c}]" } } }
end

def pl_chart(id, master, col)
  { 'id' => id, 'kind' => 'bar-chart', 'name' => id, 'source' => { 'elementId' => master, 'kind' => 'table' },
    'columns' => [{ 'id' => "#{id}-x", 'formula' => "[#{master}/#{col}]", 'name' => col },
                  { 'id' => "#{id}-y", 'formula' => "Sum([#{master}/Amt])", 'name' => 'Amt' }] }
end

def pl_ctrl(id, master, col, values, page_extra = {})
  { 'id' => id, 'kind' => 'control', 'controlId' => "c-#{id}", 'controlType' => 'list', 'mode' => 'include',
    'values' => values,
    'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => master },
                  'columnId' => "#{master}-#{col.downcase}" },
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => master }, 'columnId' => "#{master}-#{col.downcase}" }] }.merge(page_extra)
end

PLM = PbiReportBuild.method(:page_local_masters!)
m1 = pl_master('master-s', %w[Region Amt])
m2 = pl_master('master-o', %w[Region Amt])
pages = [
  { 'id' => 'page-a', 'name' => 'A', 'elements' => [pl_ctrl('ca', 'master-s', 'Region', ['W']), pl_chart('ch-a', 'master-s', 'Region')] },
  { 'id' => 'page-b', 'name' => 'B', 'elements' => [pl_ctrl('cb', 'master-s', 'Region', ['E']), pl_chart('ch-b', 'master-s', 'Region'),
                                                    pl_chart('ch-b2', 'master-o', 'Region')] }
]
data = [m1, m2]
res = PLM.call(pages, data, %w[master-s master-o])
copy_a = pages[0]['elements'].find { |e| e['id'] == 'ch-a' }.dig('source', 'elementId')
copy_b = pages[1]['elements'].find { |e| e['id'] == 'ch-b' }.dig('source', 'elementId')
ok('page_local: each page gets its OWN copy of the shared master', copy_a != copy_b && copy_a != 'master-s' && copy_b != 'master-s')
ok('page_local: the copies are real Data-page table elements sourced from the master',
   [copy_a, copy_b].all? { |c| (e = data.find { |d| d['id'] == c }) && e['kind'] == 'table' && e.dig('source', 'elementId') == 'master-s' })
ok('page_local: a master used by ONE page only is left alone (no needless copy)',
   pages[1]['elements'].find { |e| e['id'] == 'ch-b2' }.dig('source', 'elementId') == 'master-o' && data.none? { |d| d['id'].include?('master-o') && d['id'] != 'master-o' })
ca = pages[0]['elements'].find { |e| e['id'] == 'ca' }
cb = pages[1]['elements'].find { |e| e['id'] == 'cb' }
ok('page_local: each control targets ONLY its own page copy', ca['filters'].map { |f| f.dig('source', 'elementId') } == [copy_a] &&
                                                               cb['filters'].map { |f| f.dig('source', 'elementId') } == [copy_b])
cpa = data.find { |d| d['id'] == copy_a }
ok('page_local: the control filter column id exists on the copy',
   cpa['columns'].map { |c| c['id'] }.include?(ca['filters'][0]['columnId']))
ok('page_local: column formulas on the page are rewritten to the copy',
   pages[0]['elements'].find { |e| e['id'] == 'ch-a' }['columns'].all? { |c| c['formula'].include?("[#{copy_a}/") && !c['formula'].include?('[master-s/') })
ok('page_local: the control VALUE source still points at the (unfiltered) master',
   ca.dig('source', 'source', 'elementId') == 'master-s')
ok('page_local: result reports copies', res['copies'].size == 2)

# synced control: the primary must also filter the other page's copy
pages = [
  { 'id' => 'page-a', 'name' => 'A', 'elements' => [pl_ctrl('ca', 'master-s', 'Region', ['W']), pl_chart('ch-a', 'master-s', 'Region')] },
  { 'id' => 'page-b', 'name' => 'B', 'elements' => [{ 'id' => 'cb-sync', 'kind' => 'control', 'controlId' => 'c-ca', 'controlType' => 'synced' },
                                                    pl_chart('ch-b', 'master-s', 'Region')] }
]
data = [pl_master('master-s', %w[Region Amt])]
PLM.call(pages, data, %w[master-s])
cp_a = pages[0]['elements'].find { |e| e['id'] == 'ch-a' }.dig('source', 'elementId')
cp_b = pages[1]['elements'].find { |e| e['id'] == 'ch-b' }.dig('source', 'elementId')
ca = pages[0]['elements'].find { |e| e['id'] == 'ca' }
ok('page_local: a synced primary filters the copy of EVERY page that hosts a member',
   ca['filters'].map { |f| f.dig('source', 'elementId') }.sort == [cp_a, cp_b].sort)
ok('page_local: a synced member stays minimal (no filters of its own)',
   pages[1]['elements'].find { |e| e['id'] == 'cb-sync' }.keys.sort == %w[controlId controlType id kind])

# a control whose page does not use the shared master loses that (unreachable) target and is reported
pages = [
  { 'id' => 'page-a', 'name' => 'A', 'elements' => [pl_chart('ch-a', 'master-s', 'Region')] },
  { 'id' => 'page-b', 'name' => 'B', 'elements' => [pl_chart('ch-b', 'master-s', 'Region'), pl_chart('ch-b2', 'master-o', 'Region'),
                                                    pl_ctrl('cb', 'master-s', 'Region', [])] },
  { 'id' => 'page-c', 'name' => 'C', 'elements' => [pl_chart('ch-c', 'master-o', 'Region'), pl_ctrl('cc', 'master-s', 'Region', ['x'])] }
]
data = [pl_master('master-s', %w[Region Amt]), pl_master('master-o', %w[Region Amt])]
res = PLM.call(pages, data, %w[master-s master-o])
cc = pages[2]['elements'].find { |e| e['id'] == 'cc' }
ok('page_local: a control on a page that does not use the shared master drops the leaking target',
   cc['filters'].empty? && res['emptied'].include?('cc'))

# scatter-style helper element (Data-page table sourcing a master) follows its consumer page
helper = { 'id' => 'h1', 'kind' => 'table', 'name' => 'H', 'source' => { 'elementId' => 'master-s', 'kind' => 'table' },
           'columns' => [{ 'id' => 'h1-d', 'formula' => '[master-s/Region]', 'name' => 'Region' }] }
scat = { 'id' => 'sc', 'kind' => 'scatter-chart', 'name' => 'S', 'source' => { 'elementId' => 'h1', 'kind' => 'table' },
         'columns' => [{ 'id' => 'sc-d', 'formula' => '[H/Region]', 'name' => 'Region' }] }
pages = [{ 'id' => 'page-a', 'name' => 'A', 'elements' => [scat] },
         { 'id' => 'page-b', 'name' => 'B', 'elements' => [pl_chart('ch-b', 'master-s', 'Region')] }]
data = [pl_master('master-s', %w[Region Amt]), helper]
PLM.call(pages, data, %w[master-s])
hcopy = helper.dig('source', 'elementId')
bcopy = pages[1]['elements'][0].dig('source', 'elementId')
ok('page_local: a helper element is repointed at its consumer page copy and its formulas rewritten',
   hcopy.start_with?('pgcopy-') && data.any? { |d| d['id'] == hcopy } && hcopy != bcopy &&
   helper['columns'][0]['formula'] == "[#{hcopy}/Region]")

# a report with a single page is a no-op
pages = [{ 'id' => 'page-a', 'name' => 'A', 'elements' => [pl_ctrl('ca', 'master-s', 'Region', []), pl_chart('ch-a', 'master-s', 'Region')] }]
data = [pl_master('master-s', %w[Region Amt])]
res = PLM.call(pages, data, %w[master-s])
ok('page_local: single-page report -> no copies, nothing rewritten',
   res['copies'].empty? && data.size == 1 && pages[0]['elements'][1].dig('source', 'elementId') == 'master-s')


puts($fail.zero? ? "\nall pbi-reportbuild unit tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
