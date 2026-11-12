#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-matrix-levels.rb — a Power BI matrix (pivotTable) with several Rows levels builds a Sigma
# pivot-table carrying EVERY level in order as rowsBy, records one informational coverage note
# (approximated, non-gating), and still drops + reports an unresolvable level.
# Runs build-workbook-from-pbir.rb offline on synthetic Orders names.
require 'json'
require 'tmpdir'
require 'rbconfig'

BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
$fail = 0
def ok(name, cond); puts((cond ? '  ok  ' : 'FAIL  ') + name); $fail += 1 unless cond; end

MMAP = {
  'masters' => { 'Orders' => { 'id' => 'master-ord', 'element_id' => 'el-ord', 'data_model' => 'dm-x',
    'columns' => [{ 'id' => 'mc-region', 'name' => 'Region', 'formula' => '[Orders/Region]' },
                  { 'id' => 'mc-cat', 'name' => 'Category', 'formula' => '[Orders/Category]' },
                  { 'id' => 'mc-prod', 'name' => 'Product', 'formula' => '[Orders/Product]' },
                  { 'id' => 'mc-seg', 'name' => 'Segment', 'formula' => '[Orders/Segment]' },
                  { 'id' => 'mc-yr', 'name' => 'Year', 'formula' => '[Orders/Year]' },
                  { 'id' => 'mc-amt', 'name' => 'Amount', 'formula' => '[Orders/Amount]' }] } },
  'fields' => {
    'Orders.Region'   => { 'master' => 'Orders', 'ref' => '[master-ord/Region]', 'agg' => nil },
    'Orders.Category' => { 'master' => 'Orders', 'ref' => '[master-ord/Category]', 'agg' => nil },
    'Orders.Product'  => { 'master' => 'Orders', 'ref' => '[master-ord/Product]', 'agg' => nil },
    'Orders.Segment'  => { 'master' => 'Orders', 'ref' => '[master-ord/Segment]', 'agg' => nil },
    'Orders.Year'     => { 'master' => 'Orders', 'ref' => '[master-ord/Year]', 'agg' => nil },
    'Orders.Amount'   => { 'master' => 'Orders', 'ref' => 'Sum([master-ord/Amount])', 'agg' => nil }
  }
}.freeze

def vis(id, bindings, extra = {})
  { 'visual_id' => id, 'visual_type' => 'pivotTable', 'sigma_kind' => 'pivot-table', 'title' => "matrix #{id}",
    'role_class' => 'table', 'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => nil, 'formats' => {} }.merge(extra)
end

def build(visuals)
  signals = { 'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
              'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
                            'interactions' => [], 'visuals' => visuals }] }
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'mmap.json'), JSON.generate(MMAP))
    File.write(File.join(d, 'sig.json'), JSON.generate(signals))
    wb = File.join(d, 'wb.json'); cov = File.join(d, 'cov.json')
    st = system(RbConfig.ruby, BUILD, '--signals', File.join(d, 'sig.json'), '--master-map', File.join(d, 'mmap.json'),
                '--data-model', 'dm-x', '--name', 'T', '--out', wb, '--layout-out', File.join(d, 'l.xml'),
                '--coverage-out', cov, out: File::NULL, err: File::NULL)
    return [st, nil, nil] unless st
    [st, JSON.parse(File.read(wb)), JSON.parse(File.read(cov))]
  end
end
pivots = ->(spec) { spec.dig('document', 'elements').select { |e| e['kind'] == 'pivot-table' } }

# 1. three Rows levels, only the first active in the drill signal
m = vis('v_m1', { 'Rows' => %w[Orders.Region Orders.Category Orders.Product], 'Values' => ['Orders.Amount'] },
        'matrix_levels' => { 'Rows' => { 'levels' => %w[Orders.Region Orders.Category Orders.Product],
                                         'active' => ['Orders.Region'], 'date' => false } })
st, spec, cov = build([m])
ok('builder exits 0', st)
pv = st && pivots.call(spec).first
ok('one pivot-table element', !pv.nil?)
if pv
  names = pv['rowsBy'].map { |r| pv['columns'].find { |c| c['id'] == r['columnId'] }['name'] }
  ok('3 rowsBy entries, in order', names == %w[Region Category Product])
  note = (cov['unresolved'] || []).select { |u| u['pbi_type'] == 'pivotTable' && u['severity'] == 'approximated' }
  ok('exactly one informational note', note.length == 1)
  n = note.first || {}
  ok('note is non-gating (approximated, not recoverable, role_class table)',
     n['recoverable'] == false && n['role_class'] == 'table')
  ok('note names the 3 levels, the opening level and the expanded Sigma start',
     n['detail'].to_s =~ /rows \(3 levels/ && n['detail'].to_s =~ /opens at Region/ && n['detail'].to_s =~ /opens expanded/)
  ok('note does not mention the single-level/absent Columns role', n['detail'].to_s !~ /columns \(/)
  ok('no dropped entry', (cov['unresolved'] || []).none? { |u| u['severity'] == 'dropped' })
end

# 2. single-level matrix: no note
st, _spec, cov = build([vis('v_m2', { 'Rows' => ['Orders.Region'], 'Values' => ['Orders.Amount'] })])
ok('single-level matrix builds with no coverage note', st && (cov['unresolved'] || []).empty?)

# 3. an unresolvable level is still dropped AND reported
bad = vis('v_m3', { 'Rows' => %w[Orders.Region Geo.Country Orders.Product], 'Values' => ['Orders.Amount'] })
st, spec, cov = build([bad])
pv = st && pivots.call(spec).first
if pv
  cnames = pv['columns'].map { |c| c['name'] }
  ok('unresolvable level is dropped from the pivot', !cnames.include?('Country'))
  ok('resolvable levels survive in order',
     pv['rowsBy'].map { |r| pv['columns'].find { |c| c['id'] == r['columnId'] }['name'] } == %w[Region Product])
else
  ok('pivot built for unresolvable-level case', false)
end
ok('the drop is reported', st && (cov['unresolved'] || []).any? { |u| u['severity'] == 'dropped' && u['detail'].to_s =~ /Country/ })

# 4. Power BI shows these fully expanded: all levels active, or no active flags -> no note
all_active = vis('v_m4', { 'Rows' => %w[Orders.Region Orders.Category], 'Values' => ['Orders.Amount'] },
                 'matrix_levels' => { 'Rows' => { 'levels' => %w[Orders.Region Orders.Category],
                                                  'active' => %w[Orders.Region Orders.Category], 'date' => false } })
no_flags = vis('v_m5', { 'Rows' => %w[Orders.Region Orders.Category], 'Values' => ['Orders.Amount'] },
               'matrix_levels' => { 'Rows' => { 'levels' => %w[Orders.Region Orders.Category],
                                                'active' => [], 'date' => false } })
st, spec, cov = build([all_active, no_flags])
ok('all-active and no-flag matrices build, both multi-level', st && pivots.call(spec).length == 2 &&
   pivots.call(spec).all? { |p| p['rowsBy'].length == 2 })
ok('no note for all-active / no-flag matrices', st && (cov['unresolved'] || []).empty?)

# 5. counts reflect dropped levels; one surviving level is not a "multi-level" claim
bad = vis('v_m6', { 'Rows' => %w[Orders.Region Geo.Country Orders.Product], 'Values' => ['Orders.Amount'] },
          'matrix_levels' => { 'Rows' => { 'levels' => %w[Orders.Region Geo.Country Orders.Product],
                                           'active' => ['Orders.Region'], 'date' => false } })
st, _spec, cov = build([bad])
n = st && (cov['unresolved'] || []).find { |u| u['severity'] == 'approximated' }
ok('note counts the 2 carried levels, not the 3 bound', n && n['detail'] =~ /rows \(2 levels/ && n['detail'] !~ /3 levels/)
bad1 = vis('v_m7', { 'Rows' => %w[Orders.Region Geo.Country], 'Values' => ['Orders.Amount'] },
           'matrix_levels' => { 'Rows' => { 'levels' => %w[Orders.Region Geo.Country],
                                            'active' => ['Orders.Region'], 'date' => false } })
st, _spec, cov = build([bad1])
ok('a role left with one level gets no note', st && (cov['unresolved'] || []).none? { |u| u['severity'] == 'approximated' })

# 6. per-role wording: Rows collapsed + Columns collapsed, each with its own level count
both = vis('v_m8', { 'Rows' => %w[Orders.Region Orders.Category Orders.Product],
                     'Columns' => %w[Orders.Segment Orders.Year], 'Values' => ['Orders.Amount'] },
           'matrix_levels' => {
             'Rows' => { 'levels' => %w[Orders.Region Orders.Category Orders.Product], 'active' => ['Orders.Region'], 'date' => false },
             'Columns' => { 'levels' => %w[Orders.Segment Orders.Year], 'active' => ['Orders.Segment'], 'date' => false } })
st, _spec, cov = build([both])
n = (st && (cov['unresolved'] || []).find { |u| u['severity'] == 'approximated' }) || {}
ok('per-role counts and opening levels', n['detail'].to_s =~ /rows \(3 levels, Power BI opens at Region\)/ &&
   n['detail'].to_s =~ /columns \(2 levels, Power BI opens at Segment\)/)
ok('no "all N levels" max-across-roles claim', n['detail'].to_s !~ /all \d+ levels/)

# 7. M1: a date hierarchy on Columns carries only its active level and says so
dh = vis('v_m9', { 'Rows' => ['Orders.Region'], 'Columns' => ['Orders.Year'], 'Values' => ['Orders.Amount'] },
         'matrix_levels' => { 'Columns' => { 'levels' => %w[Orders.Year Orders.Quarter Orders.Month Orders.Day],
                                             'active' => ['Orders.Year'], 'date' => true } })
st, spec, cov = build([dh])
pv = st && pivots.call(spec).first
ok('date matrix pivot carries one Columns level', pv && pv['columnsBy'].length == 1)
n = (st && (cov['unresolved'] || []).find { |u| u['severity'] == 'approximated' }) || {}
ok('note records the uncarried date levels',
   n['detail'].to_s =~ /date hierarchy opens at Year and can expand to Year\/Quarter\/Month\/Day/ &&
   n['detail'].to_s =~ /pivot carries only Year/)

# 8. D2: the date branch honours the same gates as the non-date branch
DL = %w[Orders.Year Orders.Quarter Orders.Month Orders.Day]
def date_vis(id, active, bindings = nil)
  vis(id, { 'Rows' => ['Orders.Region'], 'Columns' => bindings || ['Orders.Year'], 'Values' => ['Orders.Amount'] },
      'matrix_levels' => { 'Columns' => { 'levels' => DL, 'active' => active, 'date' => true } })
end
notes = ->(cov) { (cov['unresolved'] || []).select { |u| u['severity'] == 'approximated' } }
st, _s, cov = build([date_vis('v_d1', []), date_vis('v_d2', DL)])
ok('date hierarchy with no active flag / all levels active gets no note', st && notes.call(cov).empty?)
# only an unresolved level dropped: Power BI active set is the full carried set, pivot carries what exists
st, _s, cov = build([vis('v_d3', { 'Columns' => %w[Orders.Year Geo.Quarter], 'Values' => ['Orders.Amount'] },
                         'matrix_levels' => { 'Columns' => { 'levels' => %w[Orders.Year Geo.Quarter],
                                                             'active' => %w[Orders.Year Geo.Quarter], 'date' => true } })])
ok('date role with only an unresolved level dropped gets no note', st && notes.call(cov).empty?)
# nothing carried: no empty "the Sigma pivot shows )"
st, _s, cov = build([vis('v_d4', { 'Columns' => %w[Geo.Year Geo.Quarter], 'Rows' => ['Orders.Region'], 'Values' => ['Orders.Amount'] },
                         'matrix_levels' => { 'Columns' => { 'levels' => %w[Geo.Year Geo.Quarter],
                                                             'active' => ['Geo.Year'], 'date' => true } })])
ok('date role carrying no levels never prints an empty carried list',
   st && notes.call(cov).none? { |u| u['detail'].to_s =~ /carries only\s*[);]|carries only $/ })

# 9. D3: a held-back pivot gets no matrix-levels note (values bound to an unresolvable field)
held = vis('v_h1', { 'Rows' => %w[Orders.Region Orders.Category], 'Values' => ['Geo.Missing'] },
           'matrix_levels' => { 'Rows' => { 'levels' => %w[Orders.Region Orders.Category],
                                            'active' => ['Orders.Region'], 'date' => false } })
st, spec, cov = build([held])
ok('held-back pivot is not emitted', st && pivots.call(spec).empty?)
ok('held-back pivot is recorded dropped', st && (cov['unresolved'] || []).any? { |u| u['severity'] == 'dropped' })
ok('held-back pivot gets no matrix-levels note', st && notes.call(cov).empty?)

puts($fail.zero? ? "\nall passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
