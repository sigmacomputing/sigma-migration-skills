#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for lib/pbi_dm_resolver.rb: the deterministic converter-output
# fixer (D1 stale prefixes, D2 exact-name refs, D3 leaked DAX, D4 unresolvable
# refs -> Null, D5 duplicate ids, D7 integer date keys, D8 unnamed Null columns).
# Synthetic converter outputs only. Run: ruby scripts/test-pbi-dm-resolver.rb
require 'json'
require 'set'
require_relative 'lib/pbi_dm_resolver'

SKILL = File.dirname(__dir__)
FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def deep(o) JSON.parse(JSON.generate(o)) end

def col(id, formula, name = nil)
  c = { 'id' => id, 'formula' => formula }
  c['name'] = name if name
  c
end

def sql_el(id, name, statement, cols, metrics = nil, rels = nil)
  e = { 'id' => id, 'kind' => 'table', 'name' => name,
        'source' => { 'connectionId' => 'c', 'kind' => 'sql', 'statement' => statement },
        'columns' => cols }
  e['metrics'] = metrics if metrics
  e['relationships'] = rels if rels
  e['order'] = cols.map { |c| c['id'] }
  e
end

def view_el(id, name, src_id, cols)
  { 'id' => id, 'kind' => 'table', 'name' => name, 'source' => { 'kind' => 'table', 'elementId' => src_id },
    'columns' => cols, 'order' => cols.map { |c| c['id'] } }
end

def dm(*els) { 'name' => 'm', 'schemaVersion' => 1, 'pages' => [{ 'id' => 'p', 'name' => 'Page 1', 'elements' => els }] } end
def elems(d) d['pages'][0]['elements'] end
def by(d, name) elems(d).find { |e| e['name'] == name } end
def f(d, el, col_name) (by(d, el)['columns'] + (by(d, el)['metrics'] || [])).find { |c| c['name'] == col_name }['formula'] end

# A small realistic base: Orders (restored Custom SQL) -> Customer (rel), plus Views.
def base
  orders = sql_el('o1', 'Orders', 'SELECT * FROM DB.SCH.ORDERS_TBL',
                  [col('o1a', '[Custom SQL/Amount]'), col('o1d', '[Custom SQL/Order Date]'),
                   col('o1k', '[Custom SQL/SaleDateID]'), col('o1c', '[Custom SQL/CustKey]')],
                  [{ 'id' => 'o1m', 'name' => 'Total', 'formula' => 'Sum([Amount])' }],
                  [{ 'id' => 'o1r', 'name' => 'Cust', 'targetElementId' => 'c1',
                     'keys' => [{ 'sourceColumnId' => 'o1c', 'targetColumnId' => 'c1k' }] }])
  cust = sql_el('c1', 'Customer', 'SELECT * FROM DB.SCH.CUSTOMER_TBL',
                [col('c1k', '[Custom SQL/CustKey]'), col('c1r', '[Custom SQL/Region]'), col('c1v', '[Custom SQL/Tier - Major Group]')])
  oview = view_el('ov1', 'Orders View', 'o1',
                  [col('ov1a', '[Orders/Amount]'), col('ov1d', '[Orders/Order Date]'), col('ov1k', '[Orders/SaleDateID]'),
                   col('ov1r', '[Orders/Cust/Region]')])
  [orders, cust, oview]
end

puts 'D1 stale converter prefixes'
d = dm(*base, view_el('x1', 'YTD', 'ov1', [col('x1a', 'Sum([ORDERS_TBL View/Amount])', 'Amt'),
                                           col('x1b', '[ORDERS_TBL/Amount] * 2', 'Dbl')]))
res = PbiDmResolver.resolve!(d)
check(f(d, 'YTD', 'Amt') == 'Sum([Orders View/Amount])', 'View-suffixed stale prefix remapped to the restored view')
check(f(d, 'YTD', 'Dbl') == '[Orders/Amount] * 2', 'plain stale prefix remapped to the restored element')
check(res['prefix_remaps'] == { 'ORDERS_TBL View' => 'Orders View', 'ORDERS_TBL' => 'Orders' }, "prefix map recorded #{res['prefix_remaps']}")
check(res['rewrites'].any? { |r| r['rule'] == 'D1' && r['element'] == 'YTD' }, 'each D1 rewrite is itemised')

d = dm(*base,
       sql_el('s1', 'Ambig A', 'SELECT * FROM X.Y.SHARED_T', [col('s1a', '[Custom SQL/A]')]),
       sql_el('s2', 'Ambig B', 'SELECT * FROM X.Y.SHARED_T', [col('s2a', '[Custom SQL/A]')]),
       view_el('x1', 'D', 'ov1', [col('x1a', 'Sum([SHARED_T/A])', 'S'), col('x1b', 'Sum([GHOST View/z])', 'G')]))
res = PbiDmResolver.resolve!(d)
check(res['prefix_unresolved'].key?('SHARED_T') && res['prefix_unresolved']['SHARED_T'].include?('2 candidates'), 'ambiguous stale prefix is recorded as unresolved with candidates')
check(res['prefix_unresolved'].key?('GHOST View') && res['prefix_unresolved']['GHOST View'].include?('0 candidates'), 'stale prefix with no candidate is recorded')
check(f(d, 'D', 'S') == 'Null' && f(d, 'D', 'G') == 'Null', 'formulas that stay unresolvable are nulled (D4)')

d = dm(*base, view_el('x1', 'D', 'ov1', [col('x1a', 'Sum([orders view/Amount])', 'S')]))
res = PbiDmResolver.resolve!(d)
check(f(d, 'D', 'S') == 'Sum([Orders View/Amount])', 'element head differing only by case/punctuation is rewritten to the exact element name')

puts 'D2 exact-name rewrites'
d = dm(*base,
       view_el('v2', 'Cust View', 'c1', [col('v2a', '[Customer/Region]')]),
       sql_el('m1', 'Metrics Host', 'SELECT 1', [col('m1a', '[Custom SQL/One]')],
              [{ 'id' => 'mm1', 'name' => 'M1', 'formula' => 'Sum([Orders View/amount])' },
               { 'id' => 'mm2', 'name' => 'M2', 'formula' => 'Sum([Orders/Cust/region])' },
               { 'id' => 'mm3', 'name' => 'M3', 'formula' => 'Sum([Orders View/Cust/region])' },
               { 'id' => 'mm4', 'name' => 'M4', 'formula' => 'Sum([Orders/total])' },
               { 'id' => 'mm5', 'name' => 'M5', 'formula' => 'Max([Customer/tier major group])' },
               { 'id' => 'mm6', 'name' => 'M6', 'formula' => 'Sum([Orders/Amount]) & "[Nope] x"' }])
       )
res = PbiDmResolver.resolve!(d)
check(f(d, 'Metrics Host', 'M1') == 'Sum([Orders View/Amount])', 'case-insensitive column ref rewritten')
check(f(d, 'Metrics Host', 'M2') == 'Sum([Orders/Cust/Region])', '[Fact/Rel/Col] resolves Col on the relationship target')
check(f(d, 'Metrics Host', 'M3') == 'Sum([Orders View/Cust/Region])', 'relationship path through a View inherits the base element relationships')
check(f(d, 'Metrics Host', 'M4') == 'Null', '[El/Col] is columns-only: a metric of El does not resolve')
check(f(d, 'Metrics Host', 'M5') == 'Max([Customer/Tier - Major Group])', 'punctuation/space-insensitive match rewrites to the exact name')
check(f(d, 'Metrics Host', 'M6') == 'Sum([Orders/Amount]) & "[Nope] x"', 'bracket text inside a string literal is never treated as a ref')
check(res['nulled'].any? { |n| n['element'] == 'Metrics Host' && n['name'] == 'M4' && n['unresolved_refs'] == ['Orders/total'] && n['reason'] == 'unresolved-ref' }, 'nulled formula records its unresolved refs')

d = dm(sql_el('q1', 'Q', 'SELECT 1', [col('q1a', '[Custom SQL/Amt]'), col('q1b', '[Custom SQL/Other]', 'Renamed')],
              [{ 'id' => 'q1m', 'name' => 'S', 'formula' => 'Sum([Custom SQL/amt])' }]),
       sql_el('q2', 'Q2', 'SELECT 1', [col('q2a', '[Custom SQL/Real]')],
              [{ 'id' => 'q2m', 'name' => 'Bad', 'formula' => 'Sum([Custom SQL/Gone])' },
               { 'id' => 'q2n', 'name' => 'Good', 'formula' => 'Sum([Custom SQL/real])' }]))
res = PbiDmResolver.resolve!(d, sql_names: { 'Q2' => ['Real', 'Other'] })
check(f(d, 'Q', 'S') == 'Sum([Custom SQL/Amt])', '[Custom SQL/X] resolves against exposed SQL output names')
check(f(d, 'Q2', 'Good') == 'Sum([Custom SQL/Real])' && f(d, 'Q2', 'Bad') == 'Null', 'probed sql_names are authoritative: unknown output name is nulled, near-miss rewritten')

d = dm(sql_el('a1', 'Amb', 'SELECT 1', [col('a1a', '[Custom SQL/A B]', 'A B'), col('a1b', '[Custom SQL/AB]', 'AB')],
              [{ 'id' => 'a1m', 'name' => 'Mx', 'formula' => 'Sum([a-b])' }, { 'id' => 'a1n', 'name' => 'My', 'formula' => 'Sum([ab])' }]))
res = PbiDmResolver.resolve!(d)
check(f(d, 'Amb', 'Mx') == 'Sum([a-b])', 'ambiguous fuzzy match is left unchanged (not guessed)')
check(res['ambiguous'].length == 1 && res['ambiguous'][0]['ref'] == 'a-b' && res['ambiguous'][0]['candidates'].sort == ['A B', 'AB'], 'ambiguity is recorded with candidates')
check(f(d, 'Amb', 'My') == 'Sum([ab])' || f(d, 'Amb', 'My') =~ /Sum\(\[(A B|AB)\]\)/, 'case-only difference still resolves when one name is a case-insensitive exact match')
check(!f(d, 'Amb', 'Mx').include?('Null'), 'ambiguous refs are not nulled')

puts 'D3 leaked DAX'
def dax(formula, **opts)
  d = dm(sql_el('t1', 'T', 'SELECT 1', [col('t1a', '[Custom SQL/A]'), col('t1b', '[Custom SQL/B]'), col('t1c', '[Custom SQL/D]')],
                [{ 'id' => 't1m', 'name' => 'X', 'formula' => formula }]))
  res = PbiDmResolver.resolve!(d, **opts)
  [f(d, 'T', 'X'), res]
end
out, = dax("-- a comment line\nSum([A])")
check(out == 'Sum([A])', '-- comment line stripped')
out, = dax("Sum([A]) -- trailing note\n+ Sum([B])")
check(out == "Sum([A])\n+ Sum([B])", 'trailing -- comment stripped')
out, = dax('DIVIDE(Sum([A]), Sum([B]))')
check(out == 'If(IsNull(Sum([B])) or (Sum([B])) = 0, Null, (Sum([A])) / (Sum([B])))', 'DIVIDE(a,b): null/zero guard, Null result')
out, = dax('DIVIDE(Sum([A]), Sum([B]), 0)')
check(out == 'If(IsNull(Sum([B])) or (Sum([B])) = 0, 0, (Sum([A])) / (Sum([B])))', 'DIVIDE(a,b,alt): BLANK denominator also takes alt')
out, = dax('divide(DIVIDE([A], [B]), [D])')
check(out == 'If(IsNull([D]) or ([D]) = 0, Null, (If(IsNull([B]) or ([B]) = 0, Null, ([A]) / ([B]))) / ([D]))', 'nested + case-insensitive DIVIDE')
out, = dax('DIVIDE([A], "x,y(")')
check(out == 'If(IsNull("x,y(") or ("x,y(") = 0, Null, ([A]) / ("x,y("))', 'commas/parens inside string literals do not confuse argument splitting')
out, = dax('LASTDATE([A])')
check(out == 'Max([A])', 'LASTDATE -> Max')
out, = dax('MEDIAN([A]) + VALUE([B])')
check(out == 'Median([A]) + Number([B])', 'MEDIAN / VALUE')
out, = dax('CONVERT([A], STRING)')
check(out == 'Text([A])', 'CONVERT(x, STRING) -> Text')
out, res = dax('CONVERT([A], DATETIME)')
check(out == 'Null' && res['nulled'].any? { |n| n['reason'] == 'untranslatable-dax' }, 'CONVERT to an unmapped type is nulled and recorded, not approximated')
out, = dax('[A] IN {1, 2, 3}')
check(out == 'In([A], 1, 2, 3)', 'x IN {..}')
out, = dax('([A]) IN {"p", "q"}')
check(out == 'In(([A]), "p", "q")', 'parenthesised x IN {..} with strings')
out, = dax('AND([A] > 1, [B] < 5)')
check(out == '(([A] > 1) and ([B] < 5))', 'AND() function form')
out, = dax('OR(AND([A] > 1, [B] < 2), [D] = 3)')
check(out == '(((([A] > 1) and ([B] < 2))) or ([D] = 3))', 'nested AND()/OR()')
out, = dax('([A] > 1) and ([B] < 2) or ([D] = 3)')
check(out == '([A] > 1) and ([B] < 2) or ([D] = 3)', 'lower-case and/or operators survive (case-sensitive)')
out, = dax('[A] <> null')
check(out == 'IsNotNull([A])', '<> null')
out, = dax('[A] = null')
check(out == 'IsNull([A])', '= null')
out, = dax('[A] >= null')
check(out == '[A] >= null', '>= null is not an equality test and is left alone')
out, = dax('If([A] = "DIVIDE(x)", [B], 0)')
check(out == 'If([A] = "DIVIDE(x)", [B], 0)', 'DAX-looking text inside a string literal is untouched')
out, res = dax("(Sum([A]) -- explanation) collapsed\n")
check(out == 'Null' && res['nulled'].any? { |n| n['reason'] == 'unbalanced' }, 'comment swallowing a paren leaves an unbalanced formula -> nulled and recorded')
out, res = dax('CALCULATE(Sum([A]), ALL([B]))')
check(out == 'Null' && res['nulled'][0]['reason'] == 'untranslatable-dax', 'CALCULATE/ALL (no Sigma equivalent) is nulled and recorded')
out, = dax('SUMX(FILTER(T, [A] > 1), [B])')
check(out == 'Null', 'SUMX/FILTER nulled')
out, = dax('SelectedValue([A])')
check(out == 'SelectedValue([A])' || out == 'Null', 'mixed-case names are not guessed as DAX')
out, res = dax('DIVIDE([A])')
check(out == 'Null' && res['nulled'][0]['reason'] == 'untranslatable-dax', 'malformed DIVIDE is nulled, not mangled')
res_dax = dax('DIVIDE([A], [B])')[1]
check(res_dax['dax'].length == 1 && res_dax['dax'][0]['rules'] == ['DIVIDE'] && res_dax['dax'][0]['was'] == 'DIVIDE([A], [B])', 'translations are recorded with rule names and the original text')

puts 'D4 fixpoint + D8 unnamed Null columns'
d = dm(*base.first(2),
       view_el('ov1', 'Orders View', 'o1',
               [col('ov1a', '[Orders/Amount]'), col('ov1g', '[Orders/Ghost]'), col('ov1n', '[Orders/Ghost2]', 'Named Ghost')]).merge('folders' => [{ 'id' => 'fo', 'name' => 'F', 'items' => ['ov1g', 'ov1a'] }, { 'id' => 'fe', 'name' => 'E', 'items' => ['ov1g'] }]),
       view_el('x1', 'Roll', 'ov1', [col('x1a', 'Sum([Orders View/Ghost])', 'GSum'), col('x1b', 'Sum([Orders View/Amount])', 'ASum'),
                                     col('x1c', '[GSum] + 1', 'Chain')]).merge('groupings' => [{ 'id' => 'g1', 'groupBy' => ['x1a'], 'calculations' => ['x1b', 'x1c'] }]))
elems(d)[2]['groupings'] = [{ 'id' => 'g0', 'groupBy' => ['ov1g'], 'calculations' => ['ov1a'] }]
res = PbiDmResolver.resolve!(d)
ov = by(d, 'Orders View')
check(ov['columns'].map { |c| c['id'] } == ['ov1a', 'ov1n'], 'unnamed column that ends up Null is removed (not left as a column named "Null")')
check(ov['columns'].find { |c| c['id'] == 'ov1n' }['formula'] == 'Null', 'a NAMED column that ends up Null stays, with formula Null')
check(ov['order'] == ['ov1a', 'ov1n'], 'removed column leaves the order array')
check(ov['folders'].length == 1 && ov['folders'][0]['items'] == ['ov1a'], 'removed column leaves folders and emptied folders are dropped')
check(ov['groupings'][0]['groupBy'] == [] && ov['groupings'][0]['calculations'] == ['ov1a'], 'removed column leaves groupings')
check(f(d, 'Roll', 'GSum') == 'Null' && f(d, 'Roll', 'Chain') == '[GSum] + 1', 'dependent formula nulled on the next round; sibling ref to a named Null column still resolves')
check(res['removed_columns'].length == 1 && res['removed_columns'][0]['id'] == 'ov1g' && res['removed_columns'][0]['was'] == '[Orders/Ghost]', 'removal recorded with the original formula')
check(res['summary']['columns_removed'] == 1 && res['summary']['unresolved_nulled'] >= 2, 'summary counters')

puts 'D5 duplicate element ids'
d = dm(sql_el('RunningTotalAB', 'A', 'SELECT 1', [col('a1', '[Custom SQL/X]')]),
       sql_el('RunningTotalAB', 'B', 'SELECT 1', [col('b1', '[Custom SQL/X]')]),
       sql_el('RunningTotalAB', 'C', 'SELECT 1', [col('c1', '[Custom SQL/X]')]),
       sql_el('RunningTotal02', 'D', 'SELECT 1', [col('d1', '[Custom SQL/X]')]))
res = PbiDmResolver.resolve!(d)
ids = elems(d).map { |e| e['id'] }
check(ids.uniq.length == 4 && ids[0] == 'RunningTotalAB', "duplicates suffixed, first keeps its id (#{ids})")
check(ids.all? { |i| i.length <= 16 }, 'suffixed ids stay within 16 chars')
check(res['duplicate_ids'].length == 2 && res['duplicate_ids'][0]['element'] == 'B', 'duplicate ids recorded')

puts 'D7 integer YYYYMMDD keys'
ymd = ->(r) { "MakeDate(Floor(#{r} / 10000), Floor(Mod(#{r}, 10000) / 100), Mod(#{r}, 100))" }
d = dm(*base, view_el('x1', 'Cum', 'ov1', [col('x1a', 'DateTrunc("year", [Orders View/SaleDateID])', 'Y'),
                                           col('x1b', 'DateLookback([Y], [Orders View/SaleDateID], 1, "year")', 'LY'),
                                           col('x1c', 'DateTrunc("month", [Orders View/Order Date])', 'M'),
                                           col('x1e', 'DateLookback([Y], [Y], 1, "year")', 'LY2')]))
res = PbiDmResolver.resolve!(d)
check(f(d, 'Cum', 'Y') == %(DateTrunc("year", #{ymd.call('[Orders View/SaleDateID]')})), 'DateTrunc over a *DateID key -> MakeDate(...)')
check(f(d, 'Cum', 'LY') == %(DateLookback([Y], #{ymd.call('[Orders View/SaleDateID]')}, 1, "year")), 'DateLookback over a key -> MakeDate(...)')
check(f(d, 'Cum', 'M') == 'DateTrunc("month", [Orders View/Order Date])', 'real date column untouched')
check(f(d, 'Cum', 'LY2') == 'DateLookback([Y], [Y], 1, "year")', 'DateLookback over a sibling is untouched')
check(res['date_keys'].length == 2 && res['summary']['date_key_rewrites'] == 2, 'date-key rewrites recorded')
snap = deep(d)
res2 = PbiDmResolver.resolve!(d)
check(d == snap && res2['summary'].values.all? { |v| v == 0 }, 'D7 + everything else idempotent on a second run')
d = dm(*base, view_el('x1', 'Cum', 'ov1', [col('x1a', 'DateTrunc("year", [Orders View/SaleDateID])', 'Y')]))
PbiDmResolver.resolve!(d, date_key_columns: Set.new(['somethingelse']))
check(f(d, 'Cum', 'Y') == 'DateTrunc("year", [Orders View/SaleDateID])', 'an explicit date_key_columns set overrides the name heuristic')
d = dm(*base, view_el('x1', 'Cum', 'ov1', [col('x1a', 'DateTrunc("year", [Orders View/Order Date])', 'Y')]))
PbiDmResolver.resolve!(d, date_key_columns: Set.new(['orderdate']))
check(f(d, 'Cum', 'Y').start_with?('DateTrunc("year", MakeDate('), 'an explicit date_key_columns set can name keys the heuristic would miss')
model = { 'tables' => [{ 'name' => 'Orders', 'columns' => [{ 'name' => 'SaleDateID', 'dataType' => 'int64' }, { 'name' => 'ShipDateKey', 'dataType' => 'dateTime' }, { 'name' => 'Qty', 'dataType' => 'int64' }, { 'name' => 'Day Id', 'dataType' => 'string' }] }] }
ks = PbiDmResolver.date_key_columns_from_tmsl(model)
check(ks == Set.new(['saledateid']), "date keys from TMSL: integer-typed AND key-shaped only (#{ks.to_a})")
check(PbiDmResolver.date_key_columns_from_tmsl({ 'tables' => [{ 'name' => 'T', 'columns' => [{ 'name' => 'A' }] }] }).nil?, 'no dataType info in the TMSL -> nil (fall back to the name heuristic)')

puts 'overrides / null list'
d = dm(sql_el('t1', 'T', 'SELECT 1', [col('t1a', '[Custom SQL/A]')], [{ 'id' => 'm1', 'name' => 'X', 'formula' => 'Sum([A])' }, { 'id' => 'm2', 'name' => 'Y', 'formula' => 'Sum([A])' }]))
res = PbiDmResolver.resolve!(d, overrides: { 'T|X' => 'Max([A])' }, null_list: ['T|Y'])
check(f(d, 'T', 'X') == 'Max([A])' && f(d, 'T', 'Y') == 'Null', 'overrides and null_list apply')
check(res['nulled'].any? { |n| n['reason'] == 'null-list' } && res['overrides'] == ['T|X'], 'and are recorded')

puts 'healthy converter output is (almost) a no-op'
GOLD = File.expand_path('../../../../corpus/powerbi/model-fixtures/golden', SKILL)
if Dir.exist?(GOLD)
  Dir[File.join(GOLD, '*.dm.json')].sort.each do |p|
    j = JSON.parse(File.read(p))
    model = j['model'] || j['sigmaDataModel']
    next unless model.is_a?(Hash) && model['pages']
    before = deep(model)
    r = PbiDmResolver.resolve!(model)
    # fixture_01's golden carries ONE genuinely leaked LOOKUPVALUE: the resolver must null exactly that and nothing else.
    leaked = r['nulled'].map { |n| n['name'] }
    expected = File.basename(p).start_with?('fixture_01') ? ['Manager Lookup'] : []
    check(leaked == expected && r['rewrites'].empty? && r['dax'].empty? && r['removed_columns'].empty?,
          "#{File.basename(p)}: only genuinely leaked DAX is touched (#{r['summary'].reject { |_, v| v.zero? }})")
  end
else
  puts '  SKIP  corpus golden fixtures not present'
end

puts 'wiring in migrate-powerbi.rb'
mt = File.read(File.join(__dir__, 'migrate-powerbi.rb'), encoding: 'utf-8')
at = ->(needle) { mt.index(needle) }
check(at.call('PbiNameSanitize.sanitize(tmsl, signals)') && at.call('PbiNameSanitize.sanitize(tmsl, signals)') > at.call("model_scope_path = File.join(WORK, 'model-scope.json')") &&
        at.call('PbiNameSanitize.sanitize(tmsl, signals)') < at.call('PbiNativeQuery.unfoldable(scoped_model || model'),
      'name sanitize runs after model scope and before the NativeQuery gate / conversion')
restore = at.call('PbiNativeQuery.apply!(dm_model')
vfilter = at.call('PbiModelScope.filter_views!(dm_model, signals, scoped_model)')
resolver = at.call('PbiDmResolver.resolve!(dm_model')
gate = at.call('DaxGate.calculated_table_issues(dm_model, conv_warnings)')
check(restore && vfilter && resolver && gate && restore < vfilter && vfilter < resolver && resolver < gate,
      'resolver runs after the NativeQuery restore + view filter and before the calculated-table gate')
check(mt.include?("File.join(WORK, 'dm-resolver.json')") && mt.include?("File.join(WORK, 'name-sanitize.json')"), 'audit files are written to the work dir')
check(mt.include?("PbiDmResolver.date_key_columns_from_tmsl(scoped_model || model)"), 'integer date keys come from the (sanitized) model types')

puts 'scale: 120 tables x 61 formulas stay fast'
big = (0...120).flat_map do |t|
  [sql_el("t#{t}", "T#{t}", "select * from X.T#{t}_RAW", (0...40).map { |i| col("t#{t}c#{i}", "[Custom SQL/Col #{i}]") },
          (0...21).map { |i| { 'id' => "t#{t}m#{i}", 'name' => "M#{t}_#{i}", 'formula' => "DIVIDE(Sum([col #{i}]), Sum([COL #{(i + 1) % 40}]))" } }),
   view_el("v#{t}", "T#{t} View", "t#{t}", (0...40).map { |i| col("v#{t}c#{i}", "[T#{t}/col #{i}]") })]
end
t0 = Time.now
bres = PbiDmResolver.resolve!(dm(*big))
check(Time.now - t0 < 15 && bres['summary']['nulled'].zero? && bres['summary']['dax_translated'] == 120 * 21, "2.5k measures + 9.6k columns resolved in #{(Time.now - t0).round(2)}s")

puts 'log shape'
d = dm(*base, view_el('x1', 'YTD', 'ov1', [col('x1a', 'Sum([ORDERS_TBL View/amount])', 'Amt')]))
res = PbiDmResolver.resolve!(d)
check(%w[schema summary prefix_remaps prefix_unresolved rewrites dax date_keys nulled removed_columns duplicate_ids ambiguous unverified overrides].all? { |k| res.key?(k) }, 'log carries every documented key')
check(res['schema'] == 'dm-resolver/1', 'schema tag')
check(JSON.parse(JSON.generate(res)) == res, 'log is plain JSON')
check(PbiDmResolver.summary_line(res).include?('rewrite'), 'summary_line renders')

puts 'review-fix A: nk keeps semantic symbols'
d = dm(sql_el('k1', 'Sales', 'SELECT 1', [col('k1a', '[Custom SQL/Margin %]', 'Margin %'), col('k1b', '[Custom SQL/Amount]', 'Amount'),
                                          col('k1c', '[Custom SQL/# Count]', '# Count'), col('k1d', '[Custom SQL/Sales Amt]', 'Sales Amt')],
              [{ 'id' => 'k1m', 'name' => 'Dbl', 'formula' => 'Sum([Margin]) * 2' },
               { 'id' => 'k1n', 'name' => 'Cnt', 'formula' => 'Sum([Count])' },
               { 'id' => 'k1o', 'name' => 'Ok', 'formula' => 'Sum([sales_amt]) + Sum([Sales-Amt])' }]))
res = PbiDmResolver.resolve!(d)
check(f(d, 'Sales', 'Dbl') == 'Null' && f(d, 'Sales', 'Cnt') == 'Null', 'a ref that only matches by dropping % / # is NOT rewritten (unresolved, nulled)')
check(f(d, 'Sales', 'Ok') == 'Sum([Sales Amt]) + Sum([Sales Amt])', 'case, underscore, hyphen and whitespace differences still rewrite')
check(PbiDmResolver.nk('A/B') == PbiDmResolver.nk("A∕B"), 'slash vs U+2215 equivalence kept')

puts 'review-fix A: IN rewrite'
out, = dax('Lower([A]) IN {"x"}')
check(out == 'In(Lower([A]), "x")', "function-call left operand wrapped whole (got #{out.inspect})")
out, = dax('Text(Year([A]) IN {2020,2021})')
check(out == 'Text(In(Year([A]), 2020,2021))', "call inside another call (got #{out.inspect})")
out, = dax('Upper(Lower([A])) IN {"x"} and [B] > 1')
check(out == 'In(Upper(Lower([A])), "x") and [B] > 1', "nested call operand, trailing code kept (got #{out.inspect})")
out, res = dax('[A] + [B] IN {1,2}')
check(out == 'Null' && res['nulled'].any? { |n| n['reason'] == 'untranslatable-dax' }, 'compound left operand is left untranslated (nulled via the untranslatable path)')
out, = dax('[B] > 1 and [A] IN {1,2}')
check(out == '[B] > 1 and In([A], 1,2)', "bare ref after a lower-precedence operator still rewrites (got #{out.inspect})")

puts 'review-fix A: DIVIDE null guard'
out, = dax('DIVIDE([A], [B], 0)')
check(out == 'If(IsNull([B]) or ([B]) = 0, 0, ([A]) / ([B]))', 'DIVIDE with alt guards null and zero')

puts 'review-fix A: relationship keys'
cust = sql_el('c1', 'Customer', 'SELECT 1', [col('c1k', '[Custom SQL/CustKey]'), col('c1r', '[Custom SQL/Region]')])
ord = sql_el('o1', 'Orders', 'SELECT 1', [col('o1a', '[Custom SQL/Amount]'), col('o1c', '[Custom SQL/CustKey]')],
             [{ 'id' => 'o1m', 'name' => 'Reg', 'formula' => 'Max([Cust/Region])' }],
             [{ 'id' => 'o1r', 'name' => 'Cust', 'targetElementId' => 'c1', 'keys' => [{ 'sourceColumnId' => 'o1c', 'targetColumnId' => 'c1k' }] }])
d = dm(ord, cust)
by(d, 'Customer')['columns'][0]['formula'] = '[Custom SQL/Ghost]'
PbiDmResolver.resolve!(d, sql_names: { 'Customer' => ['Region'] })
check((by(d, 'Orders')['relationships'] || []).empty?, 'relationship whose targetColumnId was removed is dropped')
check(f(d, 'Orders', 'Reg') == 'Null', 'the [Rel/..] formula that depended on it is nulled by the fixpoint')
ord2 = sql_el('o1', 'Orders', 'SELECT 1', [col('o1a', '[Custom SQL/Amount]'), col('o1c', '[Custom SQL/CustKey]'), col('o1u', '[Custom SQL/Ghost]')],
              nil, [{ 'id' => 'o1r', 'name' => 'Cust', 'targetElementId' => 'c1',
                      'keys' => [{ 'sourceColumnId' => 'o1c', 'targetColumnId' => 'c1k' }, { 'sourceColumnId' => 'o1u', 'targetColumnId' => 'c1r' }] }])
d = dm(ord2, sql_el('c1', 'Customer', 'SELECT 1', [col('c1k', '[Custom SQL/CustKey]'), col('c1r', '[Custom SQL/Region]')]))
PbiDmResolver.resolve!(d, sql_names: { 'Orders' => ['Amount', 'CustKey'] })
check((by(d, 'Orders')['relationships'] || []).empty?, 'composite-key relationship with one removed key is dropped whole, not weakened')

puts 'review-fix A: duplicate id referenced is a blocker'
d = dm(sql_el('RunningTotalAB', 'A', 'SELECT 1', [col('a1', '[Custom SQL/X]')]),
       sql_el('RunningTotalAB', 'B', 'SELECT 1', [col('b1', '[Custom SQL/X]')]),
       view_el('v1', 'V', 'RunningTotalAB', [col('v1a', '[A/X]')]))
res = PbiDmResolver.resolve!(d)
check(res['blockers'].is_a?(Array) && res['blockers'].length == 1 && res['blockers'][0]['id'] == 'RunningTotalAB' && res['blockers'][0]['reason'] == 'duplicate-id-referenced',
      "referenced duplicate id is recorded as a blocker (got #{res['blockers'].inspect})")
check(res['summary']['blockers'] == 1 && PbiDmResolver.summary_line(res).include?('1 blocker'), 'blocker is in the summary line')
check(res['duplicate_ids'].length == 1, 'renaming still happens')
d = dm(sql_el('RunningTotalAB', 'A', 'SELECT 1', [col('a1', '[Custom SQL/X]')]), sql_el('RunningTotalAB', 'B', 'SELECT 1', [col('b1', '[Custom SQL/X]')]))
check(PbiDmResolver.resolve!(d)['blockers'].empty?, 'unreferenced duplicate ids are not blockers')

puts 'review-fix A: friendly != physical warehouse-table prefix is re-prefixed, never nulled'
wh = { 'id' => 'w1', 'kind' => 'table', 'name' => 'DIM_CUSTOMER',
       'source' => { 'connectionId' => 'c', 'kind' => 'warehouse-table', 'path' => %w[DB SCH DIM_CUSTOMER] },
       'columns' => [col('w1a', '[CUSTOMER/Cust Nm]'), col('w1b', '[CUSTOMER/Amt]'), col('w1c', '[CUSTOMER/Order Date Key]')],
       'metrics' => [{ 'id' => 'w1m', 'name' => 'Total', 'formula' => 'Sum([Amt])' }] }
wh['order'] = %w[w1a w1b w1c]
d = dm(wh)
res = PbiDmResolver.resolve!(d)
w = by(d, 'DIM_CUSTOMER')
check(w['columns'].map { |c| c['formula'] } == ['[DIM_CUSTOMER/Cust Nm]', '[DIM_CUSTOMER/Amt]', '[DIM_CUSTOMER/Order Date Key]'], "columns re-prefixed to the element name (got #{w['columns'].map { |c| c['formula'] }})")
check(w['metrics'][0]['formula'] == 'Sum([Amt])' && res['summary']['nulled'].zero? && res['summary']['columns_removed'].zero?, 'nothing nulled or removed')
check(res['rewrites'].any? { |r| r['rule'] == 'D9' && r['element'] == 'DIM_CUSTOMER' }, 'each re-prefix is itemised')
wh2 = Marshal.load(Marshal.dump(wh))
wh2['columns'][0]['formula'] = '[DIM_ORDERS/Cust Nm]'
d = dm(wh2, { 'id' => 'w2', 'kind' => 'table', 'name' => 'DIM_ORDERS', 'source' => { 'kind' => 'warehouse-table' }, 'columns' => [col('w2a', '[DIM_ORDERS/X]', 'X')] })
PbiDmResolver.resolve!(d)
check(by(d, 'DIM_CUSTOMER')['columns'][0]['formula'] != '[DIM_CUSTOMER/Cust Nm]', 'a prefix that IS a known element is a cross-element ref, not re-prefixed')

puts 'review-fix A: nulled report lines list every name'
res = { 'nulled' => (1..12).map { |i| { 'element' => 'E', 'name' => "N#{i}", 'reason' => 'untranslatable-dax', 'detail' => 'x' } }, 'blockers' => [] }
lines = PbiDmResolver.report_lines(res)
check((1..12).all? { |i| lines.any? { |l| l.include?("N#{i}") } }, 'report_lines names all 12 nulled formulas, not the first 8')

puts 'review-fix A: nk keeps semantic symbols'
d = dm(sql_el('k1', 'Sales', 'SELECT 1', [col('k1a', '[Custom SQL/Margin %]', 'Margin %'), col('k1b', '[Custom SQL/Amount]', 'Amount'),
                                          col('k1c', '[Custom SQL/# Count]', '# Count'), col('k1d', '[Custom SQL/Sales Amt]', 'Sales Amt')],
              [{ 'id' => 'k1m', 'name' => 'Dbl', 'formula' => 'Sum([Margin]) * 2' },
               { 'id' => 'k1n', 'name' => 'Cnt', 'formula' => 'Sum([Count])' },
               { 'id' => 'k1o', 'name' => 'Ok', 'formula' => 'Sum([sales_amt]) + Sum([Sales-Amt])' }]))
res = PbiDmResolver.resolve!(d)
check(f(d, 'Sales', 'Dbl') == 'Null' && f(d, 'Sales', 'Cnt') == 'Null', 'a ref that only matches by dropping % / # is NOT rewritten (unresolved, nulled)')
check(f(d, 'Sales', 'Ok') == 'Sum([Sales Amt]) + Sum([Sales Amt])', 'case, underscore, hyphen and whitespace differences still rewrite')
check(PbiDmResolver.nk('A/B') == PbiDmResolver.nk("A∕B"), 'slash vs U+2215 equivalence kept')

puts 'review-fix A: IN rewrite'
out, = dax('Lower([A]) IN {"x"}')
check(out == 'In(Lower([A]), "x")', "function-call left operand wrapped whole (got #{out.inspect})")
out, = dax('Text(Year([A]) IN {2020,2021})')
check(out == 'Text(In(Year([A]), 2020,2021))', "call inside another call (got #{out.inspect})")
out, = dax('Upper(Lower([A])) IN {"x"} and [B] > 1')
check(out == 'In(Upper(Lower([A])), "x") and [B] > 1', "nested call operand, trailing code kept (got #{out.inspect})")
out, res = dax('[A] + [B] IN {1,2}')
check(out == 'Null' && res['nulled'].any? { |n| n['reason'] == 'untranslatable-dax' }, 'compound left operand is left untranslated (nulled via the untranslatable path)')
out, = dax('[B] > 1 and [A] IN {1,2}')
check(out == '[B] > 1 and In([A], 1,2)', "bare ref after a lower-precedence operator still rewrites (got #{out.inspect})")

puts 'review-fix A: DIVIDE null guard'
out, = dax('DIVIDE([A], [B], 0)')
check(out == 'If(IsNull([B]) or ([B]) = 0, 0, ([A]) / ([B]))', 'DIVIDE with alt guards null and zero')

puts 'review-fix A: relationship keys'
cust = sql_el('c1', 'Customer', 'SELECT 1', [col('c1k', '[Custom SQL/CustKey]'), col('c1r', '[Custom SQL/Region]')])
ord = sql_el('o1', 'Orders', 'SELECT 1', [col('o1a', '[Custom SQL/Amount]'), col('o1c', '[Custom SQL/CustKey]')],
             [{ 'id' => 'o1m', 'name' => 'Reg', 'formula' => 'Max([Cust/Region])' }],
             [{ 'id' => 'o1r', 'name' => 'Cust', 'targetElementId' => 'c1', 'keys' => [{ 'sourceColumnId' => 'o1c', 'targetColumnId' => 'c1k' }] }])
d = dm(ord, cust)
by(d, 'Customer')['columns'][0]['formula'] = '[Custom SQL/Ghost]'
PbiDmResolver.resolve!(d, sql_names: { 'Customer' => ['Region'] })
check((by(d, 'Orders')['relationships'] || []).empty?, 'relationship whose targetColumnId was removed is dropped')
check(f(d, 'Orders', 'Reg') == 'Null', 'the [Rel/..] formula that depended on it is nulled by the fixpoint')
ord2 = sql_el('o1', 'Orders', 'SELECT 1', [col('o1a', '[Custom SQL/Amount]'), col('o1c', '[Custom SQL/CustKey]'), col('o1u', '[Custom SQL/Ghost]')],
              nil, [{ 'id' => 'o1r', 'name' => 'Cust', 'targetElementId' => 'c1',
                      'keys' => [{ 'sourceColumnId' => 'o1c', 'targetColumnId' => 'c1k' }, { 'sourceColumnId' => 'o1u', 'targetColumnId' => 'c1r' }] }])
d = dm(ord2, sql_el('c1', 'Customer', 'SELECT 1', [col('c1k', '[Custom SQL/CustKey]'), col('c1r', '[Custom SQL/Region]')]))
PbiDmResolver.resolve!(d, sql_names: { 'Orders' => ['Amount', 'CustKey'] })
check((by(d, 'Orders')['relationships'] || []).empty?, 'composite-key relationship with one removed key is dropped whole, not weakened')

puts 'review-fix A: duplicate id referenced is a blocker'
d = dm(sql_el('RunningTotalAB', 'A', 'SELECT 1', [col('a1', '[Custom SQL/X]')]),
       sql_el('RunningTotalAB', 'B', 'SELECT 1', [col('b1', '[Custom SQL/X]')]),
       view_el('v1', 'V', 'RunningTotalAB', [col('v1a', '[A/X]')]))
res = PbiDmResolver.resolve!(d)
check(res['blockers'].is_a?(Array) && res['blockers'].length == 1 && res['blockers'][0]['id'] == 'RunningTotalAB' && res['blockers'][0]['reason'] == 'duplicate-id-referenced',
      "referenced duplicate id is recorded as a blocker (got #{res['blockers'].inspect})")
check(res['summary']['blockers'] == 1 && PbiDmResolver.summary_line(res).include?('1 blocker'), 'blocker is in the summary line')
check(res['duplicate_ids'].length == 1, 'renaming still happens')
d = dm(sql_el('RunningTotalAB', 'A', 'SELECT 1', [col('a1', '[Custom SQL/X]')]), sql_el('RunningTotalAB', 'B', 'SELECT 1', [col('b1', '[Custom SQL/X]')]))
check(PbiDmResolver.resolve!(d)['blockers'].empty?, 'unreferenced duplicate ids are not blockers')

puts 'review-fix A: friendly != physical warehouse-table prefix is re-prefixed, never nulled'
wh = { 'id' => 'w1', 'kind' => 'table', 'name' => 'DIM_CUSTOMER',
       'source' => { 'connectionId' => 'c', 'kind' => 'warehouse-table', 'path' => %w[DB SCH DIM_CUSTOMER] },
       'columns' => [col('w1a', '[CUSTOMER/Cust Nm]'), col('w1b', '[CUSTOMER/Amt]'), col('w1c', '[CUSTOMER/Order Date Key]')],
       'metrics' => [{ 'id' => 'w1m', 'name' => 'Total', 'formula' => 'Sum([Amt])' }] }
wh['order'] = %w[w1a w1b w1c]
d = dm(wh)
res = PbiDmResolver.resolve!(d)
w = by(d, 'DIM_CUSTOMER')
check(w['columns'].map { |c| c['formula'] } == ['[DIM_CUSTOMER/Cust Nm]', '[DIM_CUSTOMER/Amt]', '[DIM_CUSTOMER/Order Date Key]'], "columns re-prefixed to the element name (got #{w['columns'].map { |c| c['formula'] }})")
check(w['metrics'][0]['formula'] == 'Sum([Amt])' && res['summary']['nulled'].zero? && res['summary']['columns_removed'].zero?, 'nothing nulled or removed')
check(res['rewrites'].any? { |r| r['rule'] == 'D9' && r['element'] == 'DIM_CUSTOMER' }, 'each re-prefix is itemised')
wh2 = Marshal.load(Marshal.dump(wh))
wh2['columns'][0]['formula'] = '[DIM_ORDERS/Cust Nm]'
d = dm(wh2, { 'id' => 'w2', 'kind' => 'table', 'name' => 'DIM_ORDERS', 'source' => { 'kind' => 'warehouse-table' }, 'columns' => [col('w2a', '[DIM_ORDERS/X]', 'X')] })
PbiDmResolver.resolve!(d)
check(by(d, 'DIM_CUSTOMER')['columns'][0]['formula'] != '[DIM_CUSTOMER/Cust Nm]', 'a prefix that IS a known element is a cross-element ref, not re-prefixed')

puts 'review-fix A: nulled report lines list every name'
res = { 'nulled' => (1..12).map { |i| { 'element' => 'E', 'name' => "N#{i}", 'reason' => 'untranslatable-dax', 'detail' => 'x' } }, 'blockers' => [] }
lines = PbiDmResolver.report_lines(res)
check((1..12).all? { |i| lines.any? { |l| l.include?("N#{i}") } }, 'report_lines names all 12 nulled formulas, not the first 8')

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "#{FAILS.size} FAILED:"
  FAILS.each { |x| puts "  - #{x}" }
  exit 1
end
