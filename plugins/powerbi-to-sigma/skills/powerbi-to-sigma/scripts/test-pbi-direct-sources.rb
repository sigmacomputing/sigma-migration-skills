#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for the workbook direct-source pass (opt-in `build-workbook-from-pbir.rb --direct-sources`,
# lib/pbi_direct_sources.rb): every chart, pivot and KPI reads its data model element, controls target the
# charts, and no Data page remains.
#
# The pass runs inside the REAL builder on fixtures/pbi-shaped/sales (signals + the direct master-map of task 14,
# and a trends map generated here), plus direct calls on small synthetic structures for the shapes the fixtures do
# not carry (single select, a helper element). No network. Run: ruby scripts/test-pbi-direct-sources.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'
require_relative 'lib/pbi_shaped_model'
require_relative 'lib/pbi_direct_map'
require_relative 'lib/pbi_direct_sources'

ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'
SKILL = File.dirname(__dir__)
FIX = File.join(SKILL, 'fixtures', 'pbi-shaped')
REPO = File.expand_path('../../../../..', __dir__)
BUILDER = File.join(__dir__, 'build-workbook-from-pbir.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def load_json(*parts)
  JSON.parse(File.read(File.join(*parts)))
end

# Runs the real builder; returns {doc:, dir:, ok:, out:, scope:, cov:}.
def build(dir, signals, map, flag: true)
  FileUtils.mkdir_p(dir)
  args = [RbConfig.ruby, BUILDER, '--signals', signals, '--master-map', map,
          '--model', File.join(FIX, 'sales', 'model.bim'),
          '--data-model', 'dm-x', '--name', 'T', '--out', File.join(dir, 'wb.json'),
          '--layout-out', File.join(dir, 'l.xml'), '--coverage-out', File.join(dir, 'cov.json')]
  args << '--direct-sources' if flag
  out, st = Open3.capture2e(*args)
  r = { ok: st.success?, out: out, dir: dir, spec: File.join(dir, 'wb.json') }
  return r unless st.success?
  r[:doc] = JSON.parse(File.read(r[:spec]))['document']
  r[:scope] = load_json(dir, 'control-scope.json')
  r[:cov] = load_json(dir, 'cov.json')
  r
end

def els(doc)
  doc['elements']
end

def el_named(doc, name)
  els(doc).find { |e| e['name'] == name }
end

def col_of(el, id)
  Array(el['columns']).find { |c| c['id'] == id }
end

def controls(doc)
  els(doc).select { |e| e['kind'] == 'control' }
end

def lint(spec)
  out, _st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'lib', 'preflight_lint.rb'), spec)
  out
end

Dir.mktmpdir do |tmp|
  smap = File.join(FIX, 'sales', 'master-map-direct.json')
  sales = build(File.join(tmp, 'sales'), File.join(FIX, 'sales', 'signals.json'), smap)
  doc = sales[:doc]

  puts "\ntest_builder_runs_with_the_flag"
  check(sales[:ok], "the real builder runs on the direct map with --direct-sources (#{sales[:out].lines.last.to_s.strip})", fails)
  abort("builder failed:\n#{sales[:out]}") unless sales[:ok]

  puts "\ntest_no_data_page_and_no_table_sources"
  check(doc['pages'].none? { |p| p['name'] == 'Data' || p['id'] == 'page-data' }, 'no page named Data', fails)
  check(!doc['layout'].include?('page-data'), 'and no Data page in the layout', fails)
  masters_map = load_json(smap)['masters'].values.map { |m| m['id'] }
  table_to_master = els(doc).select do |e|
    s = e['source'] || {}
    (s['kind'] == 'table' && masters_map.include?(s['elementId'])) ||
      (s.dig('source', 'kind') == 'table' && masters_map.include?(s.dig('source', 'elementId')))
  end
  check(table_to_master.empty?, "no element has a table source pointing at a master: #{table_to_master.map { |e| e['name'] }.inspect}", fails)
  check(!JSON.generate(els(doc)).include?('master-'), 'no master id is left anywhere in the elements', fails)
  data_kinds = %w[kpi-chart bar-chart line-chart table pivot-table]
  check(els(doc).select { |e| data_kinds.include?(e['kind']) }.all? { |e| e.dig('source', 'kind') == 'data-model' && e.dig('source', 'dataModelId') && e.dig('source', 'elementId') },
        'every chart, KPI, pivot and table reads a data model element', fails)

  puts "\ntest_chart_reads_dm_element_with_related_path"
  cat = el_named(doc, 'Sales Amount by Category')
  check(cat.dig('source', 'elementId') == 'rb-AAAAAAAAAos0', "the category chart reads the Sales element: #{cat['source'].inspect}", fails)
  check(col_of(cat, cat.dig('xAxis', 'columnId'))['formula'] == '[Sales/SKU/Product/Category/Category Name]', 'its axis is the three-hop related column', fails)
  check(col_of(cat, cat.dig('yAxis', 'columnIds')[0])['formula'] == '[Metrics/Sales Amount]', 'and its measure is the data model metric', fails)
  kpi = el_named(doc, 'Sales Amount')
  check(kpi.dig('source', 'kind') == 'data-model', 'the KPI reads the data model element', fails)
  check(col_of(kpi, kpi.dig('value', 'columnId'))['formula'] == 'Sum(Coalesce([Sales/Quantity], 0) * Coalesce([Sales/Unit Price], 0) * (1 - Coalesce([Sales/Discount], 0)))',
        "R53: the Sales Amount KPI value is the inline aggregate qualified to [Sales/..]: #{col_of(kpi, kpi.dig('value', 'columnId'))['formula']}", fails)
  gm = el_named(doc, 'GM %')
  gmf = col_of(gm, gm.dig('value', 'columnId'))['formula']
  check(gmf == '(((Sum(Coalesce([Sales/Quantity], 0) * Coalesce([Sales/Unit Price], 0) * (1 - Coalesce([Sales/Discount], 0)))) - (Sum([Sales/Quantity] * [Sales/Unit Cost])))) / NullIf(((Sum(Coalesce([Sales/Quantity], 0) * Coalesce([Sales/Unit Price], 0) * (1 - Coalesce([Sales/Discount], 0))))), 0)',
        "the GM % KPI expands its metric chain recursively: #{gmf}", fails)
  check(els(doc).select { |e| e['kind'] == 'kpi-chart' }.none? { |e| JSON.generate(e['columns']).include?('[Metrics/') }, 'no KPI keeps a [Metrics/..] ref', fails)
  pivot = els(doc).find { |e| e['kind'] == 'pivot-table' }
  check(col_of(pivot, pivot['rowsBy'][0]['columnId'])['formula'] == '[Sales/SKU/Product/Brand]', 'the pivot row is the related Brand column', fails)

  puts "\ntest_slicer_on_related_column_targets_fact_charts_with_hidden_column"
  region = controls(doc).find { |c| c['controlId'] == 'CustomerRegionFilter' }
  targets = region['filters'].map { |f| f.dig('source', 'elementId') }
  check(targets.sort == %w[el-lsalesb4fb3d el-lunitsddabd7 el-region3f2c8c el-ybrand7aad79].sort, "it targets every chart on its page: #{targets.inspect}", fails)
  tel = els(doc).select { |e| targets.include?(e['id']) }
  check(tel.all? { |e| e.dig('source', 'kind') == 'data-model' }, 'each target reads the data model element', fails)
  check(region['filters'].all? { |f| col_of(els(doc).find { |e| e['id'] == f.dig('source', 'elementId') }, f['columnId'])['formula'] == '[Sales/Customer/Customer Region]' },
        'each filter column carries the slicer field formula [Sales/Customer/Customer Region]', fails)
  axis_ids = tel.flat_map { |e| [e.dig('xAxis', 'columnId'), *e.dig('yAxis', 'columnIds').to_a, *Array(e['groupings']).flat_map { |g| g['groupBy'].to_a + g['calculations'].to_a }, e.dig('value', 'columnId')] }.compact
  check(region['filters'].none? { |f| axis_ids.include?(f['columnId']) }, 'and that column sits on no axis, grouping or value', fails)
  tbl = els(doc).find { |e| e['id'] == 'el-ybrand7aad79' }
  check(col_of(tbl, region['filters'].find { |f| f.dig('source', 'elementId') == tbl['id'] }['columnId'])['hidden'] == true, 'a flat table hides it', fails)
  first = region['filters'][0]
  check(region['source'] == { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => first.dig('source', 'elementId') }, 'columnId' => first['columnId'] },
        "the value list is the first target's own column (P3 form): #{region['source'].inspect}", fails)
  check(region['values'] == ['West'] && region['selectionMode'] == 'multiple', 'the multi-select saved default stays in values', fails)

  puts "\ntest_page_and_report_filters_move_onto_readers"
  fk = col_of(kpi, 'el-vsalesb8849a-sl-mc-cff117ee9b')
  check(fk && fk['formula'] == '[Sales/Category Name (Category)]', "the Overview KPI got the filter column: #{fk.inspect}", fails)
  check((kpi['filters'] || []).any? { |f| f['columnId'] == fk['id'] && f['mode'] == 'exclude' && f['values'] == ['Discontinued'] }, 'with the report filter (exclude Discontinued) on it', fails)

  puts "\ntest_single_select_default_uses_value"
  check(controls(doc).select { |c| c['selectionMode'] == 'single' }.all? { |c| !c.key?('values') && c.key?('value') }, 'no builder control is single select with values', fails)
  ctl = { 'id' => 'c1', 'kind' => 'control', 'controlId' => 'R', 'controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'single',
          'values' => ['West'], 'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'm-d' }, 'columnId' => 'mc-r' },
          'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-d' }, 'columnId' => 'mc-r' }] }
  ch = { 'id' => 'ch1', 'kind' => 'bar-chart', 'name' => 'C', 'source' => { 'kind' => 'table', 'elementId' => 'm-f' },
         'columns' => [{ 'id' => 'a', 'formula' => '[m-f/Cat]', 'name' => 'Cat' }] }
  pg = { 'id' => 'p', 'name' => 'P', 'elements' => [ch, ctl] }
  mk = lambda do |name, id, eid, cols|
    [name, { 'id' => id, 'direct' => true, 'element_name' => name, 'element_id' => eid }]
  end
  masters = Hash[[mk.call('Fact', 'm-f', 'e-f', nil), mk.call('Dim', 'm-d', 'e-d', nil)]]
  de = [{ 'id' => 'm-f', 'kind' => 'table', 'name' => 'F', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-f', 'kind' => 'data-model' },
          'columns' => [{ 'id' => 'mf-cat', 'name' => 'Cat', 'formula' => '[Fact/Cat]' }, { 'id' => 'mf-reg', 'name' => 'Region', 'formula' => '[Fact/Dim/Region]' }] },
        { 'id' => 'm-d', 'kind' => 'table', 'name' => 'D', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-d', 'kind' => 'data-model' },
          'columns' => [{ 'id' => 'mc-r', 'name' => 'Region', 'formula' => '[Dim/Region]' }] }]
  ctl['filters'] << { 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columnId' => 'mf-reg' }
  res = PbiDirectSources.inline!([pg], de, masters, 'dm1')
  check(ctl['value'] == 'West' && !ctl.key?('values'), "a single select default becomes value: #{ctl.slice('value', 'values').inspect}", fails)
  check(ctl['filters'] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'ch1' }, 'columnId' => 'ch1-sl-mf-reg' }], "and its filter targets the chart's own column: #{ctl['filters'].inspect}", fails)
  check(ch['source'] == { 'kind' => 'data-model', 'dataModelId' => 'dm1', 'elementId' => 'e-f' } && ch['columns'][0]['formula'] == '[Fact/Cat]', 'the chart reads the element and its master ref resolves', fails)
  check(de.empty? && res['data_elements_left'] == [], 'both masters are inlined: nothing is left for a Data page', fails)

  puts "\ntest_boolean_slicer_targets_text_filter_column"
  loy = controls(doc).find { |c| c['controlId'] == 'LoyaltyMemberFilter' }
  lf = loy['filters'][0]
  lcol = col_of(els(doc).find { |e| e['id'] == lf.dig('source', 'elementId') }, lf['columnId'])
  check(lcol['formula'] == 'If(IsNull([Sales/Customer/Loyalty Member]), Null, If([Sales/Customer/Loyalty Member], "True", "False"))', "the filter column is the text form (P12): #{lcol['formula']}", fails)
  check(loy['source']['columnId'] == lf['columnId'] && loy['controlType'] == 'list' && loy['values'] == [], 'the list reads the text column, nothing is selected by default', fails)
  check(controls(doc).none? { |c| c.key?('_boolean') } && !JSON.generate(doc).include?('_boolean'), 'the builder marker does not leak into the spec', fails)
  bctl = { 'id' => 'cb', 'kind' => 'control', 'controlId' => 'B', 'controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple',
           'values' => [false], '_boolean' => true,
           'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'm-d' }, 'columnId' => 'mc-r' },
           'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columnId' => 'mf-reg' }] }
  ch2 = { 'id' => 'ch2', 'kind' => 'bar-chart', 'name' => 'C2', 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columns' => [] }
  de2 = JSON.parse(JSON.generate([{ 'id' => 'm-f', 'kind' => 'table', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-f', 'kind' => 'data-model' },
                                    'columns' => [{ 'id' => 'mf-reg', 'name' => 'Flag', 'formula' => '[Fact/Flag]' }] }]))
  PbiDirectSources.inline!([{ 'id' => 'p', 'name' => 'P', 'elements' => [ch2, bctl] }], de2, masters, 'dm1')
  check(bctl['values'] == ['False'] && ch2['columns'][0]['formula'].include?('"True"'), 'a saved boolean selection maps to the text value', fails)

  puts "\ntest_unreachable_slicer_is_recorded_not_wired"
  sig = load_json(FIX, 'sales', 'signals.json')
  lonely = JSON.parse(JSON.generate(sig['pages'].find { |p| p['page_id'] == 'SlicersPage' }))
  lonely['page_id'] = 'LonelyPage'
  lonely['page_title'] = 'Lonely'
  slicer = lonely['visuals'].find { |v| v['visual_id'] == 'SlCustomerRegion' }
  slicer['visual_id'] = 'SlLonelyRegion'
  note = JSON.parse(JSON.generate(slicer))
  note.merge!('visual_id' => 'TbNote', 'visual_type' => 'textbox', 'sigma_kind' => 'text', 'text' => 'Notes about this page and more',
              'title' => nil, 'bindings' => {}, 'slicer_state' => nil, 'y' => 300, 'h' => 100)
  lonely['visuals'] = [slicer, note]
  sig['pages'] << lonely
  File.write(File.join(tmp, 'signals-lonely.json'), JSON.generate(sig))
  lon = build(File.join(tmp, 'lonely'), File.join(tmp, 'signals-lonely.json'), smap)
  check(lon[:ok], "the builder runs with a slicer that reaches nothing (#{lon[:out].lines.last.to_s.strip})", fails)
  ldoc = lon[:doc]
  check(ldoc && els(ldoc).none? { |e| e['id'] == 'el-lonelyregion' || (e['kind'] == 'control' && e['name'].to_s.include?('Lonely')) } &&
          controls(ldoc).count { |c| c['name'] == 'Customer Region' } == 1,
        'the stranded control is not shipped (and the Slicers page control is untouched)', fails)
  unb = lon[:scope]['unbound'].select { |u| u['status'] == 'unreachable' }
  check(unb.length == 1 && unb[0]['sourceName'].include?('Customer Region'), "control-scope.json records it: #{unb.inspect}", fails)
  check(lon[:scope]['controls'].none? { |c| c['controlId'] == 'CustomerRegionFilter2' }, 'and keeps it out of the wired controls', fails)
  check(lon[:out].include?('reaches no element'), 'with a warning', fails)
  check(lon[:cov]['unresolved'].any? { |u| u['sigma_kind'] == 'control' && u['detail'].to_s.include?('reaches no element') && u['severity'] == 'dropped' }, 'and a dropped coverage record', fails)
  lonely_targets = controls(ldoc).flat_map { |c| c['filters'].map { |f| f.dig('source', 'elementId') } }
  check(lonely_targets.none? { |t| t.to_s.include?('lonely') }, 'no control is wired to an element of another page', fails)
  stranded = [{ 'id' => 'pp', 'name' => 'Other', 'elements' => [ch.dup.merge('id' => 'chx', 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columns' => []),
                                                                  { 'id' => 'cz', 'kind' => 'control', 'controlId' => 'Z', 'controlType' => 'list', 'mode' => 'include', 'values' => [],
                                                                    'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'm-d' }, 'columnId' => 'mc-r' },
                                                                    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-d' }, 'columnId' => 'mc-r' }] }] }]
  de3 = [{ 'id' => 'm-f', 'kind' => 'table', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-f', 'kind' => 'data-model' }, 'columns' => [{ 'id' => 'mf-cat', 'name' => 'Cat', 'formula' => '[Fact/Cat]' }] },
          { 'id' => 'm-d', 'kind' => 'table', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-d', 'kind' => 'data-model' }, 'columns' => [{ 'id' => 'mc-r', 'name' => 'Region', 'formula' => '[Dim/Region]' }] }]
  r3 = PbiDirectSources.inline!(stranded, de3, masters, 'dm1')
  check(r3['unreachable'].length == 1 && r3['unreachable'][0]['control'] == 'cz' && stranded[0]['elements'].map { |e| e['id'] } == ['chx'], "a control on a dimension no chart reads is in `unreachable` and removed: #{r3['unreachable'].inspect}", fails)
  check(stranded[0]['elements'][0]['columns'].empty?, 'and no column was added to the unrelated chart', fails)

  puts "\ntest_control_source_on_a_master_without_filters_is_retargeted_or_dropped"
  mk2 = lambda do
    [{ 'id' => 'm-f', 'kind' => 'table', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-f', 'kind' => 'data-model' },
       'columns' => [{ 'id' => 'mf-cat', 'name' => 'Cat', 'formula' => '[Fact/Cat]' }, { 'id' => 'mf-reg', 'name' => 'Region (Dim)', 'formula' => '[Fact/Dim/Region]' }] },
     { 'id' => 'm-d', 'kind' => 'table', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-d', 'kind' => 'data-model' },
       'columns' => [{ 'id' => 'mc-r', 'name' => 'Region', 'formula' => '[Dim/Region]' }] }]
  end
  msrc = ->(mid, cid) { { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => mid }, 'columnId' => cid } }
  cf = { 'id' => 'chf', 'kind' => 'bar-chart', 'name' => 'F', 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columns' => [] }
  nofilt = { 'id' => 'cn', 'kind' => 'control', 'controlId' => 'N', 'controlType' => 'list', 'mode' => 'include', 'values' => [], 'source' => msrc.call('m-f', 'mf-cat'), 'filters' => [] }
  nokey = { 'id' => 'ck', 'kind' => 'control', 'controlId' => 'K', 'controlType' => 'list', 'mode' => 'include', 'values' => [], 'source' => msrc.call('m-d', 'mc-r') }
  d5 = mk2.call
  r5 = PbiDirectSources.inline!([{ 'id' => 'p', 'name' => 'P', 'elements' => [cf, nofilt, nokey] }], d5, masters, 'dm1')
  check(nofilt['source'] == { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'chf' }, 'columnId' => 'chf-sl-mf-cat' } && !JSON.generate(nofilt).include?('"m-'),
        "a value list on a master with empty filters is retargeted to a reader column: #{nofilt['source'].inspect}", fails)
  check(r5['unreachable'].map { |u| u['control'] } == ['ck'], "a source-only control on a master nothing on its page reads is dropped and recorded: #{r5['unreachable'].map { |u| u['control'] }.inspect}", fails)

  puts "\ntest_slicer_reaches_fact_charts_through_relationships"
  cf2 = { 'id' => 'chf', 'kind' => 'bar-chart', 'name' => 'F', 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columns' => [] }
  dimonly = { 'id' => 'cd', 'kind' => 'control', 'controlId' => 'D', 'controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple', 'values' => [],
              'source' => msrc.call('m-d', 'mc-r'), 'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-d' }, 'columnId' => 'mc-r' }] }
  d6 = mk2.call
  r6 = PbiDirectSources.inline!([{ 'id' => 'p', 'name' => 'P', 'elements' => [cf2, dimonly] }], d6, masters, 'dm1')
  check(dimonly['filters'] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'chf' }, 'columnId' => 'chf-sl-mf-reg' }] && r6['unreachable'].empty?,
        "a control that named only the dimension now targets the fact chart: #{dimonly['filters'].inspect}", fails)
  check(cf2['columns'].map { |c| c['formula'] } == ['[Fact/Dim/Region]'], "through the fact's related column [Fact/Dim/Region]: #{cf2['columns'].inspect}", fails)
  cf3 = { 'id' => 'cht', 'kind' => 'bar-chart', 'name' => 'T', 'source' => { 'kind' => 'table', 'elementId' => 'm-t' }, 'columns' => [] }
  d7 = mk2.call + [{ 'id' => 'm-t', 'kind' => 'table', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-t', 'kind' => 'data-model' }, 'columns' => [{ 'id' => 'mt-x', 'name' => 'X', 'formula' => '[Tm/X]' }] }]
  m7 = masters.merge('Tm' => { 'id' => 'm-t', 'direct' => true, 'element_name' => 'Tm', 'element_id' => 'e-t' })
  dim2 = JSON.parse(JSON.generate(dimonly))
  dim2['filters'] = [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-d' }, 'columnId' => 'mc-r' }]
  cf4 = { 'id' => 'chf2', 'kind' => 'bar-chart', 'name' => 'F2', 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columns' => [] }
  r7 = PbiDirectSources.inline!([{ 'id' => 'p', 'name' => 'P', 'elements' => [cf4, cf3, dim2] }], d7, m7, 'dm1')
  check(cf3['columns'].empty? && r7['not_reached'].any? { |n| n['element'] == 'cht' && n['reason'].include?('no column') }, "an element whose table lacks the column is skipped and recorded, no column added: #{r7['not_reached'].inspect}", fails)
  check(dim2['filters'].map { |f| f['source']['elementId'] } == ['chf2'], 'and only the reachable chart is targeted', fails)

  puts "\ntest_i6_not_reached_elements_are_excluded_in_the_control_scope"
  check(r7['not_reached'].any? { |n| n['controlId'] == 'D' && n['element'] == 'cht' }, 'I6: a not_reached entry names the control by controlId too', fails)
  scope_i6 = [{ 'controlId' => 'D', 'scope' => %w[chf2 cht], 'excluded' => [] }, { 'controlId' => 'other', 'scope' => %w[cht], 'excluded' => [] }]
  PbiDirectSources.exclude_unreached!(scope_i6, r7)
  check(scope_i6[0]['scope'] == ['chf2'] && scope_i6[0]['excluded'].map { |x| x['element'] } == ['cht'] && scope_i6[0]['excluded'][0]['reason'].include?('no column'),
        "I6: the element leaves the control's scope and is listed as excluded with its reason: #{scope_i6[0].inspect}", fails)
  check(scope_i6[1]['scope'] == ['cht'] && scope_i6[1]['excluded'].empty?, 'I6: another control is untouched', fails)
  PbiDirectSources.exclude_unreached!(scope_i6, r7)
  check(scope_i6[0]['excluded'].size == 1, 'I6: running it twice lists the element once', fails)

  puts "\ntest_helper_elements_that_cannot_be_inlined_keep_a_data_page"
  helper = { 'id' => 'h-src', 'kind' => 'table', 'name' => 'Scatter Source', 'source' => { 'elementId' => 'm-f', 'kind' => 'table' },
             'columns' => [{ 'id' => 'h-d', 'formula' => '[m-f/Cat]', 'name' => 'Cat' }],
             'groupings' => [{ 'id' => 'h-g', 'groupBy' => ['h-d'], 'calculations' => [] }] }
  sc = { 'id' => 'sc1', 'kind' => 'scatter-chart', 'name' => 'S', 'source' => { 'elementId' => 'h-src', 'kind' => 'table' },
         'columns' => [{ 'id' => 'sx', 'formula' => '[Scatter Source/Cat]', 'name' => 'Cat' }] }
  sctl = { 'id' => 'sct', 'kind' => 'control', 'controlId' => 'Q', 'controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple', 'values' => [],
           'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columnId' => 'mf-cat' },
           'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-f' }, 'columnId' => 'mf-cat' }] }
  de4 = [{ 'id' => 'm-f', 'kind' => 'table', 'source' => { 'dataModelId' => 'dm1', 'elementId' => 'e-f', 'kind' => 'data-model' }, 'columns' => [{ 'id' => 'mf-cat', 'name' => 'Cat', 'formula' => '[Fact/Cat]' }] }, helper]
  r4 = PbiDirectSources.inline!([{ 'id' => 'p', 'name' => 'P', 'elements' => [sc, sctl] }], de4, masters, 'dm1')
  check(r4['data_elements_left'] == ['h-src'] && de4.map { |e| e['id'] } == ['h-src'], "the scatter source stays: #{r4['data_elements_left'].inspect}", fails)
  check(helper['source'] == { 'kind' => 'data-model', 'dataModelId' => 'dm1', 'elementId' => 'e-f' } && helper['columns'][0]['formula'] == '[Fact/Cat]', 'but it reads the data model element directly', fails)
  check(sc['source'] == { 'elementId' => 'h-src', 'kind' => 'table' }, 'the scatter still reads the helper', fails)
  check(sctl['filters'][0]['source']['elementId'] == 'h-src', 'the control filters the helper (the element that reads the table)', fails)

  puts "\ntest_trends_time_intelligence_refs_resolve"
  dm = load_json(FIX, 'sales', 'dm-raw.json')
  tmsl = load_json(FIX, 'sales', 'model.bim')
  tsig = load_json(FIX, 'sales', 'signals-trends.json')
  log = PbiShapedModel.apply!(dm, tmsl: tmsl, signals: tsig, native_result: nil, dialect: 'snowflake')
  rb = JSON.parse(JSON.generate(dm))
  rb['dataModelId'] = 'dm-test'
  rb['pages'].each { |p| p['elements'].each { |e| e['id'] = "rb-#{e['id']}" } }
  tmap = PbiDirectMap.build(dm, rb, tmsl, log['classes'], time_intel: log['time_intel'], signals: tsig)
  File.write(File.join(tmp, 'tmap.json'), JSON.generate(tmap))
  File.write(File.join(tmp, 'tsig.json'), JSON.generate(tsig))
  tr = build(File.join(tmp, 'trends'), File.join(tmp, 'tsig.json'), File.join(tmp, 'tmap.json'))
  check(tr[:ok], "the builder runs on the trends signals (#{tr[:out].lines.last.to_s.strip})", fails)
  if tr[:ok]
    tdoc = tr[:doc]
    blob = JSON.generate(els(tdoc))
    check(!blob.include?('master-') && tdoc['pages'].none? { |p| p['name'] == 'Data' }, 'no master id and no Data page', fails)
    forms = els(tdoc).flat_map { |e| Array(e['columns']).map { |c| c['formula'].to_s } }
    check(forms.include?('Sum(If([Sales by month/Month] = Max([Sales by month/Month]), [Sales by month/Sales YTD], Null))'),
          "the YTD read became a latest-period read of the <TI element> (no master id): #{forms.grep(/Sales YTD/).first(3).inspect}", fails)
    check(forms.include?('Sum([Sales by month/Sales PY])'), "the PY read sums the prior column over the periods in scope: #{forms.grep(/Sales PY/).first(3).inspect}", fails)
    check(els(tdoc).select { |e| %w[kpi-chart line-chart bar-chart table].include?(e['kind']) }.all? { |e| e.dig('source', 'kind') == 'data-model' }, 'every element reads a data model element', fails)
    tel = els(tdoc).find { |e| e['name'] == 'Sales Amount vs prior year by month' }
    check(tel && tel.dig('source', 'elementId').to_s.start_with?('rb-'), 'the grouped time-intelligence chart reads its own element', fails)
    tl = lint(tr[:spec])
  check(tl.lines.grep(/✗/).empty? && tl.lines.first !~ /[1-9]\d* violation/, "the trends output passes preflight_lint with zero violations: #{tl.lines.first.to_s.strip}", fails)
  end

  puts "\ntest_output_passes_lint_and_spec_validation"
  sl = lint(sales[:spec])
  check(sl.lines.grep(/✗/).empty? && sl.lines.first !~ /[1-9]\d* violation/, "the sales output passes preflight_lint with zero violations: #{sl.lines.first.to_s.strip} #{sl.lines.grep(/✗/).first(2).inspect}", fails)
  out, st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'validate-spec.rb'), '--type', 'workbook', sales[:spec])
  check(st.success? && out.include?('0 errors'), "validate-spec.rb --type workbook passes: #{out.lines.last.to_s.strip}", fails)
  out, st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'validate-spec.rb'), '--type', 'workbook', lon[:spec])
  check(st.success?, 'and so does the unreachable-control variant', fails)

  puts "\ntest_without_flag_output_byte_identical"
  case_dir = File.join(REPO, 'corpus', 'powerbi', 'workbook-code-release')
  out_dir = File.join(tmp, 'wcr')
  FileUtils.mkdir_p(out_dir)
  o, st = Open3.capture2e(RbConfig.ruby, BUILDER, '--signals', File.join(case_dir, 'signals.json'), '--master-map', File.join(case_dir, 'master-map.json'),
                          '--data-model', 'dm-release', '--layout', 'pbi', '--layout-out', File.join(out_dir, 'layout.xml'),
                          '--name', 'Power BI Workbook Code Release', '--out', File.join(out_dir, 'workbook.json'))
  check(st.success?, "the release case builds without the flag (#{o.lines.last.to_s.strip})", fails)
  golden_wb = File.join(case_dir, 'golden', 'workbook.json')
  check(JSON.parse(File.read(golden_wb)) == JSON.parse(File.read(File.join(out_dir, 'workbook.json'))), 'and equals its golden as JSON', fails)
  # The corpus goldens are written by a json gem older than 2.8, which pretty-prints an empty container as
  # "[\n\n]"; 2.8+ writes "[]". The corpus job pins that Ruby and byte-compares; this job runs on the image's Ruby.
  if JSON.pretty_generate('a' => []).include?("[\n")
    check(FileUtils.compare_file(golden_wb, File.join(out_dir, 'workbook.json')), 'and equals its golden byte for byte (cmp)', fails)
  else
    puts "  SKIP  byte-for-byte compare: json #{JSON::VERSION} prints empty containers as [] (the corpus job byte-compares)"
  end
  nf = build(File.join(tmp, 'noflag'), File.join(FIX, 'sales', 'signals.json'), smap, flag: false)
  check(nf[:ok] && nf[:doc]['pages'].any? { |p| p['id'] == 'page-data' } && nf[:doc]['elements'].any? { |e| e.dig('source', 'kind') == 'table' }, 'without the flag the Data page and table sources are still emitted', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.length} FAILED:"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
