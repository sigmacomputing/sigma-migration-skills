#!/usr/bin/env ruby
# frozen_string_literal: true
# test-dangling-sort-prune.rb — offline regression for the dangling grouped-table sort
# (2026-11-16, seen twice migrating test reports).
#
# A tableEx "Sales YTD by segment" bound Customers.Segment (a dimension the chosen
# master 'Orders' cannot reach, or one with no master-map entry at all) plus a measure.
# PBI's default table sort is its first column ascending, so apply_sort nested
# groupings[0].sort = [{columnId: <Segment col>}]. The unresolved-column drop then
# removed the Segment column and pruned it from groupBy, but prune_columns! never
# looked at sort entries, so the spec shipped a sort pointing at a column that no
# longer existed and the workbook POST failed with 400
#   elements[N].groupings[0].sort[0].columnId: references column '<id>' which is not
#   declared in columns.
# The orchestrator then fell back to the agent path.
#
# Runs build-workbook-from-pbir.rb (NO API, NO creds) and asserts:
#   * no element ships a sort / groupBy / calculation / shelf-sort id that is not in
#     its own columns[];
#   * a sort that still resolves is kept;
#   * the lost sort is recorded in coverage.json;
#   * validate-spec.rb rejects each dangling-reference shape before the POST.
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

BUILD    = File.join(__dir__, 'build-workbook-from-pbir.rb')
VALIDATE = File.join(__dir__, 'validate-spec.rb')
RUBY     = RbConfig.ruby
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

MMAP = {
  'masters' => {
    'Orders' => { 'id' => 'master-orders', 'element_id' => 'el-orders', 'data_model' => 'dm-x',
                  'columns' => [
                    { 'id' => 'mo-region', 'name' => 'Region', 'formula' => '[ORDERS/Region]' },
                    { 'id' => 'mo-sales',  'name' => 'Sales',  'formula' => '[ORDERS/Sales]' },
                    { 'id' => 'mo-qty',    'name' => 'Qty',    'formula' => '[ORDERS/Qty]' }
                  ] },
    'Customers' => { 'id' => 'master-customers', 'element_id' => 'el-customers', 'data_model' => 'dm-x',
                     'columns' => [
                       { 'id' => 'mc-tier', 'name' => 'Tier', 'formula' => '[CUSTOMERS/Tier]' }
                     ] }
  },
  'fields' => {
    'Orders.Region'    => { 'master' => 'Orders', 'ref' => '[master-orders/Region]', 'agg' => nil },
    'Orders.Sales YTD' => { 'master' => 'Orders', 'ref' => 'Sum([master-orders/Sales])', 'agg' => nil },
    'Orders.Qty'       => { 'master' => 'Orders', 'ref' => 'Sum([master-orders/Qty])', 'agg' => nil },
    # Mapped, but only on Customers: "not reachable on master 'Orders'".
    'Customers.Tier'   => { 'master' => 'Customers', 'ref' => '[master-customers/Tier]', 'agg' => nil }
    # Customers.Segment has NO field entry at all (the reported repro).
  }
}.freeze

def vis(id, type, kind, bindings, sort)
  { 'visual_id' => id, 'visual_type' => type, 'sigma_kind' => kind, 'title' => "#{kind} #{id}",
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => sort, 'formats' => {} }
end

# Shapes the extractors emit (extract-pbir.py _sort_signal): direction is "asc"/"desc";
# with no persisted sort a tableEx gets PBI's default, its first column ascending.
default_sort = ->(qr) { { 'queryRef' => qr, 'direction' => 'asc', 'default' => true } }
asc  = ->(qr) { { 'queryRef' => qr, 'direction' => 'asc' } }
desc = ->(qr) { { 'queryRef' => qr, 'direction' => 'desc' } }

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
                'interactions' => [], 'visuals' => [
                  # the reported case: dimension with no master-map entry, default first-column sort
                  vis('v_seg', 'tableEx', 'table',
                      { 'Values' => ['Customers.Segment', 'Orders.Sales YTD'] }, default_sort.call('Customers.Segment')),
                  # dimension mapped only on a master the element cannot source
                  vis('v_tier', 'tableEx', 'table',
                      { 'Values' => ['Customers.Tier', 'Orders.Sales YTD', 'Orders.Qty'] }, desc.call('Customers.Tier')),
                  # ungrouped (dimension-only) table: the sort is element-level
                  vis('v_flat', 'tableEx', 'table',
                      { 'Values' => ['Orders.Region', 'Customers.Segment'] }, asc.call('Customers.Segment')),
                  # control: a sort that still resolves must survive
                  vis('v_keep', 'tableEx', 'table',
                      { 'Values' => ['Orders.Region', 'Orders.Sales YTD'] }, desc.call('Orders.Sales YTD'))
                ] }]
}.freeze

# Every column id an element's grouping / sort / shelf references, with its JSON path.
def column_refs(el)
  id_of = ->(x) { x.is_a?(Hash) ? (x['columnId'] || x['id']) : x }
  refs = []
  Array(el['groupings']).each_with_index do |g, gi|
    Array(g['groupBy']).each_with_index { |x, i| refs << ["groupings[#{gi}].groupBy[#{i}]", id_of.call(x)] }
    Array(g['calculations']).each_with_index { |x, i| refs << ["groupings[#{gi}].calculations[#{i}]", id_of.call(x)] }
    Array(g['sort']).each_with_index { |s, i| refs << ["groupings[#{gi}].sort[#{i}].columnId", s['columnId']] }
  end
  Array(el['sort']).each_with_index { |s, i| refs << ["sort[#{i}].columnId", s['columnId']] } if el['sort'].is_a?(Array)
  %w[rowsBy columnsBy].each do |k|
    Array(el[k]).each_with_index do |x, i|
      refs << ["#{k}[#{i}].columnId", id_of.call(x)]
      by = x.is_a?(Hash) ? x.dig('sort', 'by') : nil
      refs << ["#{k}[#{i}].sort.by", by] if by && by != 'row-count'
    end
  end
  refs << ['xAxis.sort.by', el.dig('xAxis', 'sort', 'by')] if el['xAxis'].is_a?(Hash)
  refs << ['color.sort.by', el.dig('color', 'sort', 'by')] if el['color'].is_a?(Hash)
  refs.reject { |_, v| v.nil? }
end

def dangling(el)
  own = Array(el['columns']).map { |c| c['id'] }
  column_refs(el).reject { |_, v| own.include?(v) }
end

def validate(path)
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, st = Open3.capture2e(RUBY, VALIDATE, '--type', 'workbook', path)
  [st.success?, out]
end

Dir.mktmpdir do |d|
  File.write(File.join(d, 'mmap.json'), JSON.generate(MMAP))
  File.write(File.join(d, 'sig.json'), JSON.generate(SIGNALS))
  wb  = File.join(d, 'wb.json')
  cov = File.join(d, 'cov.json')
  log, st = Open3.capture2e(RUBY, BUILD, '--signals', File.join(d, 'sig.json'),
                            '--master-map', File.join(d, 'mmap.json'),
                            '--data-model', 'dm-x', '--name', 'T', '--out', wb,
                            '--layout-out', File.join(d, 'l.xml'), '--coverage-out', cov)
  ok('builder exits 0', st.success? || (puts(log) && false))
  spec = JSON.parse(File.read(wb))
  content = spec.dig('document', 'elements').reject { |e| e['visibleAsSource'] == false }
  el = ->(vid) { content.find { |e| e['name'].to_s.include?(vid) } }

  puts "\n1. no element ships an id that is not declared in its columns[]"
  bad = content.flat_map { |e| dangling(e).map { |path, id| "#{e['name']}: #{path} -> #{id}" } }
  ok("no dangling grouping / sort / shelf reference#{bad.empty? ? '' : " #{bad.inspect}"}", bad.empty?)

  puts "\n2. the reported case (Segment has no master-map entry)"
  seg = el.call('v_seg')
  ok('v_seg is built', !seg.nil?)
  ok('v_seg dropped the Segment column', seg && seg['columns'].none? { |c| c['name'] == 'Segment' })
  ok('v_seg keeps its Sales YTD calculation', seg && Array(seg['groupings']).any? { |g| !Array(g['calculations']).empty? })
  ok('v_seg carries no sort on the dropped column', seg && Array(seg['groupings']).all? { |g| Array(g['sort']).empty? })

  puts "\n3. dimension mapped only on a master the element cannot source"
  tier = el.call('v_tier')
  ok('v_tier is built', !tier.nil?)
  ok('v_tier dropped the Tier column', tier && tier['columns'].none? { |c| c['name'] == 'Tier' })
  ok('v_tier carries no sort on the dropped column', tier && Array(tier['groupings']).all? { |g| Array(g['sort']).empty? })

  puts "\n4. ungrouped table: the element-level sort is pruned too"
  flat = el.call('v_flat')
  ok('v_flat is built with Region', flat && flat['columns'].any? { |c| c['name'] == 'Region' })
  ok('v_flat carries no element-level sort on the dropped column', flat && Array(flat['sort']).empty?)

  puts "\n5. a sort that still resolves is kept"
  keep = el.call('v_keep')
  ksort = keep && Array(keep['groupings']).first&.dig('sort')
  sales = keep && keep['columns'].find { |c| c['name'] == 'Sales YTD' }
  ok('v_keep keeps groupings[0].sort on Sales YTD (descending)',
     sales && ksort == [{ 'columnId' => sales['id'], 'direction' => 'descending' }])

  puts "\n6. coverage records the lost sort"
  unresolved = JSON.parse(File.read(cov))['unresolved'] || []
  for_visual = ->(vid) { unresolved.select { |u| u['visual_id'] == vid || u['visual'].to_s.include?(vid) } }
  %w[v_seg v_tier v_flat].each do |vid|
    ok("#{vid}: a coverage entry names the removed sort",
       for_visual.call(vid).any? { |u| u['detail'].to_s =~ /sort/i })
  end
  ok("v_tier: the 'not reachable on master' degrade is still recorded",
     for_visual.call('v_tier').any? { |u| u['detail'].to_s.include?("not reachable on master 'Orders'") })
  ok('v_keep: no sort-loss entry for a sort that resolved',
     for_visual.call('v_keep').none? { |u| u['detail'].to_s =~ /sort/i })

  puts "\n7. validate-spec.rb rejects every dangling-reference shape before the POST"
  ok_built, out_built = validate(wb)
  ok("validate-spec passes the fixed builder output#{ok_built ? '' : " #{out_built}"}", ok_built)

  shapes = {
    'groupings[0].sort[0].columnId' => ->(e) { e['groupings'][0]['sort'] = [{ 'columnId' => 'ghost-col', 'direction' => 'ascending' }] },
    'groupings[0].groupBy[1]' => ->(e) { e['groupings'][0]['groupBy'] = Array(e['groupings'][0]['groupBy']) + ['ghost-col'] },
    'sort[0].columnId' => ->(e) { e['sort'] = [{ 'columnId' => 'ghost-col', 'direction' => 'ascending' }] }
  }
  shapes.each do |path, mutate|
    mutated = JSON.parse(JSON.generate(spec))
    target = mutated.dig('document', 'elements').find { |e| e['name'].to_s.include?('v_keep') }
    mutate.call(target)
    mp = File.join(d, "mut-#{path.gsub(/\W+/, '_')}.json")
    File.write(mp, JSON.generate(mutated))
    st_m, out_m = validate(mp)
    ok("validate-spec rejects a dangling #{path}",
       !st_m && out_m.include?(path) && out_m.include?('ghost-col'))
  end

  # pivot shelf sort.by — rowsBy[0].sort.by may be a column id (or the literal "row-count").
  pv = JSON.parse(JSON.generate(spec))
  target = pv.dig('document', 'elements').find { |e| e['name'].to_s.include?('v_keep') }
  cols = target['columns']
  target['kind'] = 'pivot-table'
  target.delete('groupings')
  target['rowsBy'] = [{ 'columnId' => cols[0]['id'], 'sort' => { 'by' => 'ghost-col', 'direction' => 'ascending' } }]
  target['values'] = [cols[1]['id']]
  pp = File.join(d, 'mut-pivot.json')
  File.write(pp, JSON.generate(pv))
  st_p, out_p = validate(pp)
  ok('validate-spec rejects a dangling rowsBy[0].sort.by',
     !st_p && out_p.include?('rowsBy[0].sort.by') && out_p.include?('ghost-col'))
  target['rowsBy'][0]['sort']['by'] = 'row-count'
  File.write(pp, JSON.generate(pv))
  _st_rc, out_rc = validate(pp)
  ok('validate-spec accepts rowsBy sort.by "row-count"', out_rc !~ /not declared in this element's columns/)
end

puts $fail.zero? ? "\nall dangling-sort-prune tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
