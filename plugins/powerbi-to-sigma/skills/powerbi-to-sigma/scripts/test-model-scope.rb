#!/usr/bin/env ruby
# Offline tests for lib/pbi_model_scope.rb (keep set + TMSL pruning).
# Run: ruby scripts/test-model-scope.rb
require 'json'
require 'set'
require_relative 'lib/pbi_model_scope'

SKILL = File.dirname(__dir__)
FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def tbl(name, measures = {}, cols = [])
  { 'name' => name,
    'columns' => cols,
    'measures' => measures.map { |n, e| { 'name' => n, 'expression' => e } } }
end

def rel(from, to)
  { 'name' => "#{from}_#{to}", 'fromTable' => from, 'fromColumn' => 'k', 'toTable' => to, 'toColumn' => 'k' }
end

def model(tables, rels, roles = nil)
  m = { 'tables' => tables, 'relationships' => rels }
  m['roles'] = roles if roles
  { 'model' => m }
end

def kept_names(res) res['kept'].map { |k| k['table'] }.sort end

puts 'report seeds only'
t = model([tbl('Fact'), tbl('DimA'), tbl('DimB'), tbl('Unused1')],
          [rel('Fact', 'DimA'), rel('Fact', 'DimB')])
r = PbiModelScope.scope(t, [{ 'queryRefs' => ['Fact.Amt', 'DimA.Name'] }], [])
check(kept_names(r) == %w[DimA Fact], 'kept {Fact, DimA}')
check(r['dropped_tables'].sort == %w[DimB Unused1], 'DimB and Unused1 dropped')
check(r['fallback_reason'].nil?, 'no fallback')

puts 'snowflake join path'
t = model([tbl('Fact'), tbl('Dim'), tbl('SubDim'), tbl('Other')],
          [rel('Fact', 'Dim'), rel('Dim', 'SubDim')])
r = PbiModelScope.scope(t, [['Fact.Amt', 'SubDim.Region']], [])
dim = r['kept'].find { |k| k['table'] == 'Dim' }
check(dim && dim['reasons'].include?('join-path'), 'Dim kept with join-path')
check(!kept_names(r).include?('Other'), 'Other dropped')

puts 'measure closure'
t = model([tbl('Fact', { 'Ratio' => "DIVIDE([Total], CALCULATE(SUM('Dim Date'[x])))", 'Total' => 'SUM(Fact[Amt])' }),
           tbl('Dim Date'), tbl('Unused1')],
          [rel('Fact', 'Dim Date')])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], ['Ratio'])
dd = r['kept'].find { |k| k['table'] == 'Dim Date' }
check(dd && dd['reasons'] == ['measure:Ratio'], 'Dim Date kept with measure:Ratio')
check(!kept_names(r).include?('Unused1'), 'Unused1 dropped')

puts 'dax refs quoted and unquoted'
refs = PbiModelScope.dax_table_refs("SUM('Dim Date'[d]) + SUM(Sales[a]) + SUM('O''Brien Sales'[b])",
                                    ['Dim Date', 'Sales', "O'Brien Sales", 'Nope'])
check(refs == Set.new(['Dim Date', 'Sales', "O'Brien Sales"]), 'quoted/unquoted/escaped refs')
check(PbiModelScope.dax_measure_refs('[A] + Fact[B] + [C]', %w[A B]) == Set.new(%w[A B]), 'measure refs')
check(PbiModelScope.dax_table_refs('COUNTROWS(RELATEDTABLE(Sales))', ['Sales']) == Set.new(['Sales']), 'bare table token')

puts 'apostrophes in strings/brackets/comments'
tn = ['Sales', 'Dim Date']
check(PbiModelScope.dax_table_refs(%q{IF([x]="Won't",1,CALCULATE(SUM(Sales[a]),'Dim Date'[d]))}, tn) == Set.new(tn), 'apostrophe in string literal')
check(PbiModelScope.dax_table_refs("COUNT(Sales[Cust's Name]) + COUNT('Dim Date'[d])", tn) == Set.new(tn), 'apostrophe in bracketed name')
check(PbiModelScope.dax_table_refs("1 // it's 'Dim Date'\n+ SUM(Sales[a]) /* don't */", tn) == Set.new(['Sales']), 'comments ignored')

puts 'calc tags'
t = model([tbl('Fact', {}, [{ 'name' => 'C', 'type' => 'calculated', 'expression' => 'RELATED(DimX[v])' }]),
           tbl('DimX'), tbl('Cal')], [])
t['model']['tables'][0]['partitions'] = [{ 'source' => { 'type' => 'calculated', 'expression' => "FILTER('Cal', 1=1)" } }]
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], [])
rs = Hash[r['kept'].map { |k| [k['table'], k['reasons']] }]
check(rs['DimX'] == ['calc:Fact.C'], 'calc:Table.Col tag')
check(rs['Cal'] == ['calc-table:Fact'], 'calc-table:Name tag')

puts 'RLS dimension kept'
t = model([tbl('Fact'), tbl('DimRegion'), tbl('Unused1')],
          [rel('Fact', 'DimRegion')],
          [{ 'name' => 'Region Managers',
             'tablePermissions' => [{ 'name' => 'DimRegion', 'filterExpression' => '[Region] = USERPRINCIPALNAME()' }] }])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], [])
rg = r['kept'].find { |k| k['table'] == 'DimRegion' }
check(rg && rg['reasons'] == ['rls:Region Managers'], 'DimRegion kept with rls:Region Managers')
check(!kept_names(r).include?('Unused1'), 'unrelated table still dropped')

puts 'RLS filter references another table'
t = model([tbl('Fact'), tbl('Sec'), tbl('Map')],
          [rel('Fact', 'Sec')],
          [{ 'name' => 'R', 'tablePermissions' => [{ 'name' => 'Sec', 'filterExpression' => "CONTAINS('Map', 'Map'[u], USERNAME())" }] }])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], [])
check(kept_names(r).include?('Map'), 'table referenced by RLS filter kept')

puts 'classic nested string entities'
doc = { 'sections' => [{ 'filters' => '[{"expression":{"Column":{"Expression":{"SourceRef":{"Entity":"DimB"}}}}}]' }] }
check(PbiModelScope.report_entities([doc], %w[DimA DimB]) == Set.new(['DimB']), 'DimB found in nested JSON string')
check(PbiModelScope.report_entities([JSON.generate(doc)], %w[DimA DimB]) == Set.new(['DimB']), 'raw JSON string doc')
check(PbiModelScope.report_entities([{ 'q' => 'Sum(DimA.Amt)' }], %w[DimA DimB]) == Set.new(['DimA']), 'aggregate-wrapped queryRef')

puts 'unused measure transitive drop'
t = model([tbl('Fact', { 'M1' => '[M2] * 2', 'M3' => 'SUM(Fact[Amt])' }),
           tbl('Unused1', { 'M2' => 'SUM(Unused1[v])' })], [])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], [])
fact = r['tmsl']['model']['tables'].find { |x| x['name'] == 'Fact' }
check(r['dropped_measures'].include?('Fact.M1'), 'Fact.M1 dropped')
check(fact['measures'].map { |m| m['name'] } == ['M3'], 'M3 stays, M1 gone from TMSL')

puts 'used measure referencing dropped-looking measure is never dropped'
t = model([tbl('Fact', { 'Used' => '[Helper]', 'Helper' => 'SUM(Fact[Amt])' })], [])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], ['Used'])
check(r['dropped_measures'].empty?, 'no measures dropped')

puts 'used calculated column referencing auto date table is never dropped'
calc_cols = [
  { 'name' => 'Used Year', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" },
  { 'name' => 'Unused Year', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" }
]
t = model([tbl('Fact', {}, calc_cols), tbl('LocalDateTable_abc')], [])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], [], [], ['Fact.Used Year'])
fact = r['tmsl']['model']['tables'].find { |x| x['name'] == 'Fact' }
check(fact['columns'].map { |c| c['name'] } == ['Used Year'], 'used calc column stays while unused sibling is dropped')

puts 'unused calculated column transitive drop'
calc_cols = [
  { 'name' => 'Dropped Leaf', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" },
  { 'name' => 'Dependent', 'type' => 'calculated', 'expression' => '[Dropped Leaf] * 2' }
]
t = model([tbl('Fact', {}, calc_cols), tbl('LocalDateTable_abc')], [])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], [])
check(r['dropped_calc_columns'].sort == ['Fact.Dependent', 'Fact.Dropped Leaf'], 'dependent calc column drops transitively')

puts 'calculated column dependencies stay consistent'
calc_cols = [
  { 'name' => 'Used Leaf', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" },
  { 'name' => 'Used Mid', 'type' => 'calculated', 'expression' => '[Used Leaf] * 2' },
  { 'name' => 'Used Column', 'type' => 'calculated', 'expression' => '[Used Mid] + 1' },
  { 'name' => 'Measure Leaf', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" },
  { 'name' => 'Measure Mid', 'type' => 'calculated', 'expression' => '[Measure Leaf] * 2' },
  { 'name' => 'Dead Leaf', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" }
]
t = model([tbl('Fact', { 'Used Metric' => '[Measure Mid]', 'Dead Metric' => '[Dead Leaf]' }, calc_cols),
           tbl('LocalDateTable_abc')], [])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], ['Used Metric'], [], ['Fact.Used Column'])
check(r['dropped_calc_columns'] == ['Fact.Dead Leaf'], 'used column and measure dependencies stay')
check(r['dropped_measures'] == ['Fact.Dead Metric'], 'measure over dropped calculated column drops')

puts 'sort-by calculated column is retained'
calc_cols = [
  { 'name' => 'Month', 'type' => 'data', 'sortByColumn' => 'Month Number' },
  { 'name' => 'Month Number', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[MonthNo]" }
]
t = model([tbl('Fact', {}, calc_cols), tbl('LocalDateTable_abc')], [])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }], [], [], ['Fact.Month'])
fact = r['tmsl']['model']['tables'].find { |x| x['name'] == 'Fact' }
check(fact['columns'].map { |c| c['name'] } == ['Month', 'Month Number'], 'sortByColumn target survives auto-date pruning')

puts 'prune relationships and permissions'
t = model([tbl('Fact'), tbl('Unused1'), tbl('DateTableTemplate_abc')],
          [rel('Fact', 'Unused1')],
          [{ 'name' => 'R', 'tablePermissions' => [{ 'name' => 'Unused1', 'filterExpression' => '1=1' }] }])
t['model']['perspectives'] = [{ 'name' => 'P', 'tables' => [{ 'name' => 'Fact' }, { 'name' => 'Unused1' }] }]
r = PbiModelScope.prune_model(t, { 'Fact' => ['report'] })
m = r['tmsl']['model']
check(m['relationships'] == [], 'relationship removed')
check(m['roles'][0]['tablePermissions'] == [], 'permission removed')
check(m['perspectives'][0]['tables'].map { |x| x['name'] } == ['Fact'], 'perspective table removed')
check(r['dropped_tables'] == ['Unused1'], 'date table not listed as dropped')
check(t['model']['tables'].size == 3, 'input not mutated')

puts 'empty report fallback'
t = model([tbl('Fact'), tbl('DimA')], [rel('Fact', 'DimA')])
before = JSON.generate(t)
r = PbiModelScope.scope(t, [{ 'nothing' => 1 }], [])
check(r['fallback_reason'] == 'no report entities found', 'fallback reason')
check(JSON.generate(r['tmsl']) == before, 'tmsl unchanged')
check(r['dropped_tables'] == [], 'no dropped tables')

puts 'unknown entity ignored'
t = model([tbl('Fact')], [])
r = PbiModelScope.scope(t, [{ 'Entity' => 'Fact' }, { 'Entity' => 'Ghost' }], [])
check(kept_names(r) == ['Fact'], 'Ghost ignored')

puts 'fixture 05'
bim = JSON.parse(File.read(File.join(SKILL, 'fixtures', 'fixture_05_relationships_hard.bim')))
r = PbiModelScope.scope(bim, [{ 'Entity' => 'ABSENCE_RECORDS' }], [])
check((Set.new(kept_names(r)) >= Set.new(%w[ABSENCE_RECORDS EMPLOYEES])), 'ABSENCE_RECORDS + EMPLOYEES kept')
check(r['dropped_tables'].include?('SAFETY_INCIDENTS'), 'SAFETY_INCIDENTS dropped')

puts 'view filter'
def vfix(extra_els = [], fact_cols = nil)
  fact_cols ||= [{ 'id' => 'c1', 'formula' => '[Fact/Amt]' }, { 'id' => 'c2', 'formula' => '[Fact/DimA/Name]', 'hidden' => true }]
  els = [
    { 'id' => 'e1', 'name' => 'Fact' }, { 'id' => 'e2', 'name' => 'DimA' },
    { 'id' => 'v1', 'name' => 'Fact View', 'source' => { 'kind' => 'table', 'elementId' => 'e1' }, 'columns' => fact_cols },
    { 'id' => 'v2', 'name' => 'DimA View', 'source' => { 'kind' => 'table', 'elementId' => 'e2' },
      'columns' => [{ 'id' => 'd1', 'formula' => '[DimA/Name]' }, { 'id' => 'd2', 'formula' => '[DimA/SubDim/X]', 'hidden' => true }] }
  ] + extra_els
  { 'pages' => [{ 'elements' => els }] }
end
vmodel = model([tbl('Fact'), tbl('DimA'), tbl('SubDim')], [rel('Fact', 'DimA'), rel('DimA', 'SubDim')])['model']
vsig = ->(*binds) { { 'pages' => [{ 'visuals' => binds.map { |b| { 'bindings' => { 'values' => b } } } }] } }
vnames = ->(dm) { dm['pages'].flat_map { |p| p['elements'].map { |e| e['name'] } } }

dm = vfix
dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt', 'DimA.Name']), vmodel)
check(dropped == ['DimA View'], 'cross-table visual: only DimA View dropped')
check(vnames.call(dm).include?('Fact View') && !vnames.call(dm).include?('DimA View'), 'Fact View kept in dm')

dm = vfix([{ 'id' => 'ti', 'name' => 'Fact YTD', 'source' => { 'kind' => 'table', 'elementId' => 'v1' } }])
dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt']), vmodel)
check(!dropped.include?('Fact View'), 'sourced View kept')

dm = vfix([], [{ 'id' => 'c1', 'formula' => '[Fact/Amt]' }, { 'id' => 'c2', 'formula' => '[Fact/DimA/Name] & "x"' }])
dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt']), vmodel)
check(!dropped.include?('Fact View'), 'relocated column keeps View')

dm = vfix([], [{ 'id' => 'c1', 'formula' => '[Fact/Amt]' },
               { 'id' => 'c2', 'name' => 'Related Name', 'formula' => '[Fact/DimA/Name]' }])
dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt']), vmodel)
check(!dropped.include?('Fact View'), 'simple RELATED column keeps View')

dm = vfix
dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt'], ['Fact.Qty']), vmodel)
check(dropped == ['Fact View', 'DimA View'], 'single-table report drops all Views')

dm = vfix
dm['pages'][0]['elements'][2]['metrics'] = [{ 'id' => 'm1', 'formula' => 'Sum([Fact/Amt])' }]
dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt']), vmodel)
check(!dropped.include?('Fact View'), 'View with metrics kept')

dm = { 'pages' => [{ 'elements' => [{ 'id' => 'v9', 'name' => 'Mystery View', 'source' => { 'kind' => 'table', 'elementId' => 'e9' }, 'columns' => [] }] }] }
check(PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt']), vmodel) == [], 'unmappable View kept')

pm = model([{ 'name' => 'Sales Fact', 'partitions' => [{ 'source' => { 'expression' => 'let s = x{[Name="FACT_T",Kind="Table"]}[Data] in s' } }] }, tbl('Cust')],
           [rel('Sales Fact', 'Cust')])['model']
dm = { 'pages' => [{ 'elements' => [{ 'id' => 'v1', 'name' => 'FACT_T View', 'source' => { 'kind' => 'table', 'elementId' => 'e1' }, 'columns' => [{ 'id' => 'c', 'formula' => '[FACT_T/A]' }] }] }] }
check(PbiModelScope.filter_views!(dm, vsig.call(['Sales Fact.A', 'Cust.B']), pm) == [], 'physical name maps to friendly table')

def test_binding_entity_field_unwraps
  check(PbiModelScope.binding_entity_field('Sum(Fact.Amt)') == ['Fact', 'Amt'], 'unwrap Sum')
  check(PbiModelScope.binding_entity_field('CountNonNull(Min(Fact.A.b))') == ['Fact', 'A.b'], 'unwrap nested, first dot split')
  check(PbiModelScope.binding_entity_field('Fact.Amt') == ['Fact', 'Amt'], 'plain ref')
  check(PbiModelScope.binding_entity_field('NoDot').nil?, 'no dot -> nil')
end
test_binding_entity_field_unwraps

test_view_kept_for_aggregated_binding = lambda do
  dm = vfix
  dropped = PbiModelScope.filter_views!(dm, vsig.call(['DimA.Name', 'Sum(Fact.Amt)']), vmodel)
  check(!dropped.include?('Fact View'), 'aggregated binding keeps Fact View')
end
test_view_kept_for_aggregated_binding.call

test_unresolved_entity_keeps_views = lambda do
  dm = vfix
  dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt'], ['Ghost.X', 'Fact.Qty']), vmodel)
  check(dropped == [], 'unresolved entity keeps every View')
end
test_unresolved_entity_keeps_views.call

def test_auto_date_binding_does_not_keep_views(vmodel, vsig)
  dm = vfix
  dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt', 'LocalDateTable_abc.Date Hierarchy.Year']), vmodel)
  check(dropped == ['Fact View', 'DimA View'], 'auto-date binding does not keep every View')
end
test_auto_date_binding_does_not_keep_views(vmodel, vsig)

def test_entityless_binding_keeps_views(vmodel, vsig)
  dm = vfix
  dropped = PbiModelScope.filter_views!(dm, vsig.call(['Fact.Amt', 'Display Alias']), vmodel)
  check(dropped == [], 'entity-less binding keeps every View')
end
test_entityless_binding_keeps_views(vmodel, vsig)

# ---- prune_masters -------------------------------------------------------
def mst(id, name = nil)
  { 'id' => id, 'kind' => 'table', 'name' => name || id.sub(/^master-/, '').upcase[0, 6], 'columns' => [] }
end

des = [mst('master-m1'), mst('master-m2'), mst('master-m3'), mst('master-m4'),
       { 'id' => 'helper-1', 'kind' => 'table', 'name' => 'Helper',
         'source' => { 'kind' => 'table', 'elementId' => 'master-m4' }, 'columns' => [] }]
content = [
  { 'id' => 'ch1', 'kind' => 'bar-chart', 'source' => { 'kind' => 'table', 'elementId' => 'master-m1' }, 'columns' => [] },
  { 'id' => 'ch2', 'kind' => 'bar-chart', 'source' => { 'kind' => 'table', 'elementId' => 'helper-1' }, 'columns' => [] },
  { 'id' => 'ctl', 'kind' => 'control',
    'filters' => [{ 'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master-m2' }, 'columnId' => 'c' } }] }
]
check(PbiModelScope.prune_masters(des, content) == ['master-m3'], 'prune_masters keeps sourced, control targets, helper-sourced')

des = [mst('master-m5', 'ABCDEF'), mst('master-m6', 'GHIJKL'), mst('master-m7')]
content = [{ 'id' => 'ch', 'kind' => 'table', 'source' => { 'kind' => 'table', 'elementId' => 'master-m9' },
             'columns' => [{ 'id' => 'a', 'formula' => 'Sum([master-m5/Amt])' }, { 'id' => 'b', 'formula' => '[GHIJKL/Q]' }] }]
check(PbiModelScope.prune_masters(des, content) == ['master-m7'], 'prune_masters formula refs by id and name')

des = [mst('master-a'), mst('master-b')]
des[0]['source'] = { 'kind' => 'table', 'elementId' => 'master-b' }
check(PbiModelScope.prune_masters(des, []) == ['master-a', 'master-b'], 'master reached only from unreached master is pruned')

def test_prune_masters_name_collision_keeps_all
  # builder names masters id.sub(/^master-/,'').upcase[0,6]: both collide as CUSTOM
  des = [mst('master-customers'), mst('master-customer'), mst('master-other')]
  check(des[0]['name'] == des[1]['name'], 'collision fixture shares a name')
  content = [{ 'id' => 'ch', 'kind' => 'table', 'columns' => [{ 'id' => 'a', 'formula' => 'Sum([CUSTOM/X])' }] }]
  check(PbiModelScope.prune_masters(des, content) == ['master-other'], 'name collision keeps all same-named masters')
end
test_prune_masters_name_collision_keeps_all

# ---- auto-pick guard -----------------------------------------------------
def test_auto_pick_allowed
  check(PbiModelScope.auto_pick_allowed?({ 'raw_element_count' => 7 }, 5) == true, 'auto_pick 7 vs kept 5 allowed')
  check(PbiModelScope.auto_pick_allowed?({ 'raw_element_count' => 8 }, 5) == false, 'auto_pick 8 vs kept 5 refused')
  check(PbiModelScope.auto_pick_allowed?({ 'raw_element_count' => nil }, 5) == true, 'auto_pick nil count allowed')
  check(PbiModelScope.auto_pick_allowed?({}, 5) == true, 'auto_pick missing count allowed')
  check(PbiModelScope.auto_pick_allowed?({ 'raw_element_count' => 9 }, 9) == true, 'auto_pick own prior scoped DM allowed')
  check(PbiModelScope.auto_pick_allowed?({ 'raw_element_count' => 43 }, 9) == false, 'auto_pick bloated full-model DM refused')
end
test_auto_pick_allowed


# ---- final-review fix wave -----------------------------------------------
def pview(name, cols = nil)
  { 'id' => "v-#{name}", 'name' => "#{name} View", 'source' => { 'kind' => 'table', 'elementId' => "e-#{name}" },
    'columns' => cols || [{ 'id' => 'c', 'formula' => "[#{name}/Col]" }] }
end

def pdm(*names) { 'pages' => [{ 'elements' => names.map { |n| pview(n) } }] } end

def vis(bind, filters = nil)
  v = { 'bindings' => bind }
  v['filters'] = filters.map { |t| { 'target' => t } } if filters
  v
end

def sigp(pages, report_filters = nil)
  s = { 'pages' => pages.map { |vs| { 'visuals' => vs } } }
  s['filters'] = report_filters.map { |t| { 'target' => t } } if report_filters
  s
end

sp = model([tbl('Sales', { 'Total' => 'SUM(Sales[Amt])' }), tbl('Product')], [rel('Sales', 'Product')])['model']

def test_view_kept_for_page_slicer_on_dimension(sp)
  dm = pdm('Sales', 'Product')
  sig = sigp([[vis('values' => ['Sales.Total']), vis('values' => ['Product.Category'])]])
  dropped = PbiModelScope.filter_views!(dm, sig, sp)
  check(dropped == ['Product View'], 'page slicer on dimension keeps Sales View (only Product View dropped)')
end
test_view_kept_for_page_slicer_on_dimension(sp)

def test_hub_view_kept_for_dimension_only_page
  m = model([tbl('Sales'), tbl('Product'), tbl('Customer')],
            [rel('Sales', 'Product'), rel('Sales', 'Customer')])['model']
  dm = pdm('Sales', 'Product', 'Customer')
  sig = sigp([[vis('values' => ['Product.Category']), vis('values' => ['Customer.Name'])]])
  check(!PbiModelScope.filter_views!(dm, sig, m).include?('Sales View'),
        'dimension-only page keeps hub Sales View')
end
test_hub_view_kept_for_dimension_only_page

# Regression guard: a page that also touches an UNRELATED table must still keep
# the View that serves its fact + dimension visuals (over-include).
def test_view_kept_when_page_also_touches_unrelated_table
  m = model([tbl('Sales'), tbl('Product'), tbl('Inventory')],
            [rel('Sales', 'Product')])['model']
  dm = pdm('Sales', 'Product')
  sig = sigp([[vis('values' => ['Sales.Amt']), vis('values' => ['Product.Category']),
               vis('values' => ['Inventory.Qty'])]])
  check(!PbiModelScope.filter_views!(dm, sig, m).include?('Sales View'),
        'page with an unrelated table still keeps Sales View')
end
test_view_kept_when_page_also_touches_unrelated_table

def test_view_kept_for_measures_only_table
  m = model([tbl('_Measures', { 'Total' => 'SUM(Sales[Amt])' }), tbl('Sales'), tbl('Product')],
            [rel('Sales', 'Product')])['model']
  dm = pdm('Sales', 'Product')
  sig = sigp([[vis('values' => ['_Measures.Total'], 'category' => ['Product.Category'])]])
  dropped = PbiModelScope.filter_views!(dm, sig, m)
  check(!dropped.include?('Sales View'), 'measures-only table measure + dimension keeps Sales View')
  # measures-only table in the page set; DAX of an UNBOUND sibling measure still counts
  m2 = model([tbl('_Measures', { 'Total' => 'SUM(Sales[Amt])', 'Other' => '1' }), tbl('Sales'), tbl('Product')],
             [rel('Sales', 'Product')])['model']
  dm = pdm('Sales', 'Product')
  sig = sigp([[vis('values' => ['_Measures.Other']), vis('values' => ['Product.Category'])]])
  check(!PbiModelScope.filter_views!(dm, sig, m2).include?('Sales View'), 'measures-only table sibling DAX keeps Sales View')
end
test_view_kept_for_measures_only_table

def test_view_dropped_when_page_touches_one_table(sp)
  dm = pdm('Sales', 'Product')
  sig = sigp([[vis('values' => ['Sales.Total']), vis('values' => ['Sales.Amt'])]])
  check(PbiModelScope.filter_views!(dm, sig, sp) == ['Sales View', 'Product View'], 'page touching one table drops all Views')
  # per page, not report-wide: Sales on page 1, Product on page 2
  dm = pdm('Sales', 'Product')
  sig = sigp([[vis('values' => ['Sales.Total'])], [vis('values' => ['Product.Category'])]])
  check(PbiModelScope.filter_views!(dm, sig, sp) == ['Sales View', 'Product View'], 'tables on different pages do not combine')
end
test_view_dropped_when_page_touches_one_table(sp)

def test_view_kept_for_page_and_visual_and_report_filters(sp)
  sig = sigp([[vis({ 'values' => ['Sales.Total'] })]])
  sig['pages'][0]['filters'] = [{ 'target' => 'Product.Category' }]
  check(!PbiModelScope.filter_views!(pdm('Sales', 'Product'), sig, sp).include?('Sales View'), 'page filter target joins the page set')
  sig = sigp([[vis({ 'values' => ['Sales.Total'] }, ['Product.Category'])]])
  check(!PbiModelScope.filter_views!(pdm('Sales', 'Product'), sig, sp).include?('Sales View'), 'visual filter target joins the page set')
  sig = sigp([[vis('values' => ['Sales.Total'])]], ['Product.Category'])
  check(!PbiModelScope.filter_views!(pdm('Sales', 'Product'), sig, sp).include?('Sales View'), 'report filter target joins the page set')
end
test_view_kept_for_page_and_visual_and_report_filters(sp)

def test_view_formula_keeps_view(sp)
  sig = sigp([[vis('values' => ['Sales.Amt'])]])
  dm = { 'pages' => [{ 'elements' => [pview('Sales', [{ 'id' => 'c', 'formula' => '[Other/Col]' }])] }] }
  check(PbiModelScope.filter_views!(dm, sig, sp) == [], 'column formula [Other/Col] keeps View')
  dm = { 'pages' => [{ 'elements' => [pview('Sales', [{ 'id' => 'c', 'formula' => 'Sum([Sales/Col])' }])] }] }
  check(PbiModelScope.filter_views!(dm, sig, sp) == [], 'column formula Sum([Base/Col]) keeps View')
end
test_view_formula_keeps_view(sp)

def test_resolve_binding
  names = ['Sales', 'Sales Detail', 'A.B']
  check(PbiModelScope.resolve_binding('Sum(Sales.Amt)', names) == %w[Sales Amt], 'resolve_binding unwraps')
  check(PbiModelScope.resolve_binding('CountNonNull(Min(Sales.Amt))', names) == %w[Sales Amt], 'resolve_binding nested')
  check(PbiModelScope.resolve_binding('Sales Detail.Amt', names) == ['Sales Detail', 'Amt'], 'resolve_binding table with space')
  check(PbiModelScope.resolve_binding('A.B.C', names) == ['A.B', 'C'], 'resolve_binding dotted table name')
  check(PbiModelScope.resolve_binding('Ghost.X', names).nil?, 'resolve_binding unknown table nil')
end
test_resolve_binding

def test_join_path_prefers_active
  m = model([tbl('Sales'), tbl('Customer'), tbl('Geo')],
            [rel('Sales', 'Geo').merge('isActive' => false), rel('Sales', 'Customer'), rel('Customer', 'Geo')])
  r = PbiModelScope.scope(m, [['Sales.Amt', 'Geo.Region']], [])
  c = r['kept'].find { |k| k['table'] == 'Customer' }
  check(c && c['reasons'].include?('join-path'), 'Customer kept as join-path despite inactive direct edge')
  m = model([tbl('A'), tbl('X'), tbl('Y'), tbl('B')],
            [rel('A', 'X'), rel('X', 'B'), rel('A', 'Y'), rel('Y', 'B')])
  r = PbiModelScope.scope(m, [['A.k', 'B.k']], [])
  check(Set.new(kept_names(r)) >= Set.new(%w[X Y]), 'every table on any shortest path kept')
end
test_join_path_prefers_active

def test_report_measures_from_filter_node
  m = model([tbl('Sales', { 'Margin' => 'SUM(Sales[Amount]) - SUM(Cost[Amt])' }), tbl('Cost'), tbl('Unused1')], [])
  doc = { 'filters' => [{ 'expression' => { 'Measure' => { 'Expression' => { 'SourceRef' => { 'Entity' => 'Sales' } }, 'Property' => 'Margin' } } }] }
  used = PbiModelScope.report_measures([doc], %w[Margin Other])
  check(used == Set.new(['Margin']), 'report_measures finds Measure Property in filter node')
  nested = { 'a' => JSON.generate([doc]) }
  check(PbiModelScope.report_measures([nested], %w[Margin]) == Set.new(['Margin']), 'report_measures finds it in embedded JSON string')
  r = PbiModelScope.scope(m, [doc], used.to_a)
  check(kept_names(r).include?('Cost'), 'Cost kept via filter-only measure')
  check(r['dropped_measures'].empty?, 'Margin not dropped')
end
test_report_measures_from_filter_node

def test_report_columns_from_sort_and_conditional_format
  column = ->(table, name) { { 'Column' => { 'Expression' => { 'SourceRef' => { 'Entity' => table } }, 'Property' => name } } }
  doc = { 'sort' => column.call('Sales', 'Year'),
          'conditionalFormats' => JSON.generate(column.call('Sales', 'Color')) }
  used = PbiModelScope.report_columns([doc], %w[Sales Other])
  check(used == Set.new(%w[Sales.Year Sales.Color]), 'report_columns finds sort and conditional-format columns')

  cols = [{ 'name' => 'Year', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" },
          { 'name' => 'Unused', 'type' => 'calculated', 'expression' => "'LocalDateTable_abc'[Year]" }]
  m = model([tbl('Sales', { 'Year' => 'SUM(Sales[Amount])' }, cols), tbl('LocalDateTable_abc')], [])
  r = PbiModelScope.scope(m, [doc], [], [], used.to_a)
  sales = r['tmsl']['model']['tables'].find { |t| t['name'] == 'Sales' }
  check(sales['columns'].map { |c| c['name'] } == ['Year'], 'report-used column survives measure-name collision and auto-date pruning')
end
test_report_columns_from_sort_and_conditional_format

def test_walk_string_bom_and_fallback
  doc = "﻿{\"Entity\":\"DimB\"}"
  check(PbiModelScope.report_entities([doc], %w[DimA DimB]) == Set.new(['DimB']), 'BOM-prefixed JSON string parsed')
  broken = '{"a":{"Entity":"DimA"}, oops'
  check(PbiModelScope.report_entities([broken], %w[DimA DimB]) == Set.new(['DimA']), 'unparseable JSON part falls back to Entity regex')
  brokenm = '{"Measure":{"Expression":{}, "Property":"Margin"}, oops'
  check(PbiModelScope.report_measures([brokenm], %w[Margin]) == Set.new(['Margin']), 'unparseable JSON part falls back to Measure regex')
end
test_walk_string_bom_and_fallback

def test_extra_seeds
  m = model([tbl('Fact'), tbl('DimA'), tbl('Unused1')], [rel('Fact', 'DimA')])
  r = PbiModelScope.scope(m, [{ 'nothing' => 1 }], [], ['Fact'])
  check(r['fallback_reason'].nil? && kept_names(r) == ['Fact'], 'signals-derived seeds avoid fallback and keep Fact')
end
test_extra_seeds

def test_calculation_group_refs
  grp = { 'name' => 'TimeCalc', 'columns' => [],
          'calculationGroup' => { 'calculationItems' => [{ 'name' => 'YTD', 'expression' => 'CALCULATE(SELECTEDMEASURE(), DATESYTD(\'Dim Date\'[d]))' }] } }
  m = model([tbl('Fact'), grp, tbl('Dim Date'), tbl('Unused1')], [])
  r = PbiModelScope.scope(m, [{ 'Entity' => 'Fact' }, { 'Entity' => 'TimeCalc' }], [])
  dd = r['kept'].find { |k| k['table'] == 'Dim Date' }
  check(dd && dd['reasons'] == ['calc-group:TimeCalc'], 'calculation item table refs kept with calc-group tag')
  check(!kept_names(r).include?('Unused1'), 'unrelated table still dropped')
end
test_calculation_group_refs

puts
if FAILS.empty?
  puts 'All checks passed'
else
  puts "#{FAILS.size} FAILED"
  exit 1
end
