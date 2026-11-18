#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline test of scripts/pbi-shaped-report.rb (Task 19): the Power BI -> Sigma map, the limits list and the
# views/pbi comparison. Report-only: reads its inputs, writes only into --out-dir. Placeholder data, no network.
#
#   test_every_visible_measure_has_a_home_or_reason
#   test_class_d_and_live_pages_listed_in_limits
#   test_clicks_views_shape_counts_master_hop
#   test_default_shape_gets_map_without_build_change
#   test_bidi_and_many_to_many_relationships_listed_as_limits
#   test_custom_sql_sources_get_create_view_suggestion
#
# Run: ruby scripts/test-pbi-shaped-report.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

REPORT = File.join(__dir__, 'pbi-shaped-report.rb')
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'

def wj(dir, name, doc)
  File.write(File.join(dir, name), JSON.pretty_generate(doc))
  File.join(dir, name)
end

def tmsl_doc
  { 'model' => {
    'tables' => [
      { 'name' => 'Sales', 'columns' => [{ 'name' => 'Amount' }],
        'measures' => [{ 'name' => 'Total Sales', 'expression' => 'SUM(Sales[Amount])' },
                       { 'name' => 'Open Orders', 'expression' => 'COUNTROWS(Sales)' },
                       { 'name' => 'Region Sales', 'expression' => 'CALCULATE([Total Sales], Region[Name] = "East")' },
                       { 'name' => 'Orphan Measure', 'expression' => '1' }] },
      { 'name' => 'Date', 'columns' => [{ 'name' => 'Day' }] },
      { 'name' => 'Customer', 'columns' => [{ 'name' => 'Name' }] },
      { 'name' => 'Region', 'columns' => [{ 'name' => 'Name' }] }
    ],
    'relationships' => [
      { 'name' => 'r1', 'fromTable' => 'Sales', 'fromColumn' => 'DateKey', 'toTable' => 'Date', 'toColumn' => 'Key',
        'crossFilteringBehavior' => 'bothDirections' },
      { 'name' => 'r2', 'fromTable' => 'Sales', 'fromColumn' => 'CustKey', 'toTable' => 'Customer', 'toColumn' => 'Key',
        'fromCardinality' => 'many', 'toCardinality' => 'many' },
      { 'name' => 'r3', 'fromTable' => 'Sales', 'fromColumn' => 'RegKey', 'toTable' => 'Region', 'toColumn' => 'Key' }
    ] } }
end

def signals_doc
  { 'pages' => [{ 'page_id' => 'P1', 'page_title' => 'Overview', 'visuals' => [
    { 'visual_id' => 'V1', 'visual_type' => 'card', 'title' => 'Sales KPI', 'sigma_kind' => 'kpi',
      'bindings' => { 'Values' => ['Sales.Total Sales'] } },
    { 'visual_id' => 'V2', 'visual_type' => 'card', 'title' => 'Open', 'sigma_kind' => 'kpi',
      'bindings' => { 'Values' => ['Sales.Open Orders'] } },
    { 'visual_id' => 'V3', 'visual_type' => 'card', 'title' => 'Regional', 'sigma_kind' => 'kpi',
      'bindings' => { 'Values' => ['Sales.Region Sales'] } },
    { 'visual_id' => 'V4', 'visual_type' => 'slicer', 'title' => 'Customer', 'sigma_kind' => 'control',
      'bindings' => { 'Values' => ['Customer.Name'] } },
    { 'visual_id' => 'V5', 'visual_type' => 'slicer', 'title' => 'Region picker', 'sigma_kind' => 'control',
      'bindings' => { 'Values' => ['Region.Name'] } }
  ] }] }
end

def pbi_dm
  { 'name' => 'Model', 'pages' => [{ 'id' => 'pg', 'name' => 'Page 1', 'elements' => [
    { 'id' => 'e-sales', 'kind' => 'table', 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH SALES] },
      'columns' => [{ 'id' => 'c1', 'formula' => '[SALES/Amount]', 'name' => 'Amount' }],
      'relationships' => [{ 'id' => 'rl1', 'targetElementId' => 'e-date', 'keys' => [], 'name' => 'Date' },
                          { 'id' => 'rl2', 'targetElementId' => 'e-cust', 'keys' => [], 'name' => 'Customer' }],
      'metrics' => [{ 'id' => 'm1', 'name' => 'Total Sales', 'formula' => 'Sum([Amount])' },
                    { 'id' => 'm3', 'name' => 'Region Sales', 'formula' => 'Sum([Amount])',
                      'description' => "Power BI's CALCULATE filter on Region Name overrides slicers on that column" }] },
    { 'id' => 'e-date', 'kind' => 'table', 'name' => 'Date', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH DIM_DATE] }, 'columns' => [] },
    { 'id' => 'e-cust', 'kind' => 'table', 'name' => 'Customer', 'source' => { 'kind' => 'sql', 'statement' => "SELECT id, name\nFROM src.customers" }, 'columns' => [] },
    { 'id' => 'e-sum', 'kind' => 'table', 'name' => 'Open Orders by Day', 'source' => { 'kind' => 'table', 'elementId' => 'e-sales' },
      'columns' => [{ 'id' => 'sc1', 'formula' => '[Sales/Amount]', 'name' => 'Day' }],
      'metrics' => [{ 'id' => 'm2', 'name' => 'Open Orders', 'formula' => 'Sum([Amount])' }] }
  ] }] }
end

def pbi_wb
  { 'pages' => [{ 'id' => 'wp1', 'name' => 'Overview' }, { 'id' => 'wp2', 'name' => 'Scratch', 'visibility' => 'hidden' }],
    'elements' => [
      { 'id' => 'el-v1xx', 'kind' => 'kpi', 'name' => 'Sales KPI', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e-sales' } },
      { 'id' => 'el-v2xx', 'kind' => 'kpi', 'name' => 'Open', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e-sum' } },
      { 'id' => 'el-live', 'kind' => 'table', 'name' => 'Open Orders by Day - live, filtered by your slicer picks',
        'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1' } },
      { 'id' => 'el-v4xx', 'kind' => 'control', 'name' => 'Customer', 'controlId' => 'ctl-customer', 'controlType' => 'list',
        'source' => { 'kind' => 'source', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e-cust' }, 'columnId' => 'x' } },
      { 'id' => 'el-ctl-region', 'kind' => 'control', 'name' => 'Region picker', 'controlId' => 'ctl-region', 'controlType' => 'list' },
      { 'id' => 'el-hid', 'kind' => 'kpi', 'name' => 'Hidden one', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e-sales' } },
      { 'id' => 'el-lost', 'kind' => 'kpi', 'name' => 'Unplaced', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e-sales' } }
    ],
    'layout' => %(<?xml version="1.0" encoding="utf-8"?>\n<Page type="grid" id="wp1">\n<Element elementId="el-v1xx"/>\n<Element elementId="el-v2xx"/>\n<Element elementId="el-live"/>\n<Element elementId="el-v4xx"/>\n</Page>\n<Page type="grid" id="wp2">\n<Element elementId="el-hid"/>\n</Page>\n) }
end

def shaped_log
  { 'dropped' => { 'elements' => [], 'retargeted' => [] }, 'renames' => { 'elements' => {}, 'columns' => {} },
    'relationships' => { 'renamed' => [], 'added' => [], 'not_carried' => [], 'conflicts' => [] },
    'class_counts' => { 'A' => 1, 'D' => 1 },
    'element_name_resets' => [{ 'from' => 'Total Sales', 'to' => 'TOTAL_SALES' }],
    'direct_map' => { 'conflicts' => [], 'unresolved' => [], 'class_d_fields' => ['Sales.Open Orders'] },
    'slicers' => { 'carried' => [], 'live' => [{ 'element' => 'Open Orders by Day - live, filtered by your slicer picks', 'page' => 'Overview',
                                                  'controls' => [{ 'field' => 'Customer.Name' }] }],
                   'date_filters' => [],
                   'not_applied' => [{ 'page' => 'Overview', 'control' => 'ctl-region', 'field' => 'Region.Name', 'reason' => 'no reader carries it' }],
                   'unreached' => [{ 'control' => 'ctl-customer', 'source' => 'Store.Name', 'element' => 'x', 'reason' => 'no element reads Store' }] },
    'limits' => [{ 'kind' => 'mixed_summary', 'visual' => 'Mix', 'visual_id' => 'V9', 'source' => 'Open Orders by Day',
                   'dropped' => ['Customer.Name'], 'dropped_measures' => [], 'reason' => 'one element reads one data model element' }] }
end

def classes_doc
  { 'Sales.Total Sales' => { 'class' => 'A', 'reason' => 'plain', 'home' => 'Sales', 'ti' => nil },
    'Sales.Open Orders' => { 'class' => 'D', 'reason' => 'snapshot logic', 'home' => nil, 'ti' => nil },
    'Sales.Region Sales' => { 'class' => 'B', 'reason' => 'filter on a dimension column', 'home' => 'Sales', 'ti' => nil } }
end

def run_report(dir, extra = [])
  tmsl = wj(dir, 'model.bim', tmsl_doc)
  sig = wj(dir, 'signals.json', signals_doc)
  args = [RbConfig.ruby, REPORT, '--tmsl', tmsl, '--signals', sig,
          '--dm-spec', File.join(dir, 'dm-spec.json'), '--wb-spec', File.join(dir, 'workbook-spec.json'), '--out-dir', dir] + extra
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture2e(*args)
end

def write_pbi_inputs(dir)
  wj(dir, 'dm-spec.json', pbi_dm)
  wj(dir, 'workbook-spec.json', pbi_wb)
  wj(dir, 'measure-classes.json', classes_doc)
  wj(dir, 'pbi-shaped-model.json', shaped_log)
  wj(dir, 'slicer-carry.json', {})
end

def pbi_args(dir)
  ['--classes', File.join(dir, 'measure-classes.json'), '--shaped-log', File.join(dir, 'pbi-shaped-model.json'),
   '--slicer-carry', File.join(dir, 'slicer-carry.json')]
end

def test_wrapped_workbook_spec_and_limits_wording
  puts 'test_wrapped_workbook_spec_and_limits_wording'
  Dir.mktmpdir do |root|
    d = File.join(root, 'cur')
    o = File.join(root, 'other')
    FileUtils.mkdir_p([d, o])
    write_pbi_inputs(d)
    # the real workbook-spec.json shape: {name, document: {elements, layout, pages}, folderId}
    wrap = ->(dir) { wj(dir, 'workbook-spec.json', { 'name' => 'W', 'document' => JSON.parse(File.read(File.join(dir, 'workbook-spec.json'))), 'folderId' => 'f' }) }
    wrap.call(d)
    log = JSON.parse(File.read(File.join(d, 'pbi-shaped-model.json')))
    log['slicers']['unreached'] = %w[a b c].map { |e| { 'control' => 'ctl-region', 'source' => 'Store.Name', 'element' => "chart #{e}", 'reason' => 'no element reads Store' } }
    wj(d, 'pbi-shaped-model.json', log)
    write_pbi_inputs(o)
    wrap.call(o)
    out, st = run_report(d, pbi_args(d) + ['--compare-dir', o])
    check(st.success?, "report runs on a document-wrapped spec (#{out.strip[0, 200]})")
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    vis = map['visuals'].find { |v| v['pbi'].include?('Sales KPI') }
    check(vis && vis['sigma'] && vis['sigma']['id'] == 'el-v1xx', 'a visual maps to its workbook element')
    check(map['visuals'].any? { |v| v['sigma'] } && map['slicers'].any? { |v| v['sigma'] }, 'visuals and slicers are mapped')
    check(vis['reason'].to_s !~ /no workbook element/, 'no "no workbook element" reason')
    cmp = JSON.parse(File.read(File.join(d, 'comparison.json')))
    check(cmp.values.all? { |c| c['wb_elements'].to_i.positive? && c['clicks_to_source'] }, "comparison counts are not zero on the wrapped shape (#{cmp.values.map { |c| c['wb_elements'] }.inspect})")
    check(cmp.values.all? { |c| c['hidden_or_unread'].to_i >= 1 }, 'hidden or unread counts read the wrapped layout and pages')
    lim = File.read(File.join(d, 'limits.md'))
    check(lim.scan('Unreached: Region picker').length == 1 && lim.include?('chart a, chart b, chart c'), 'an unreached control is one line, titled by its workbook name, elements listed once')
    plain = tmsl_doc
    plain['model']['relationships'].each { |r| r.delete('crossFilteringBehavior'); r.delete('fromCardinality'); r.delete('toCardinality') }
    wj(d, 'model.bim', plain)
    Open3.capture2e(RbConfig.ruby, REPORT, '--tmsl', File.join(d, 'model.bim'), '--signals', File.join(d, 'signals.json'), '--dm-spec', File.join(d, 'dm-spec.json'),
                    '--wb-spec', File.join(d, 'workbook-spec.json'), '--out-dir', d, *pbi_args(d))
    lim = File.read(File.join(d, 'limits.md'))
    check(lim.include?('None in this model.'), 'an empty relationships section says so')
  end
end

def test_every_visible_measure_has_a_home_or_reason
  puts 'test_every_visible_measure_has_a_home_or_reason'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    out, st = run_report(d, pbi_args(d))
    check(st.success?, "report runs (#{out.strip[0, 200]})")
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    check(%w[tables relationships measures visuals slicers].all? { |k| map[k].is_a?(Array) }, 'map has the five sections')
    names = map['measures'].map { |m| m['pbi'] }
    %w[Sales.Total\ Sales Sales.Open\ Orders Sales.Region\ Sales].each { |n| check(names.include?(n), "measure #{n} listed") }
    check(!names.include?('Sales.Orphan Measure'), 'a measure on no visible visual is not listed')
    all_items = map.values.flatten
    check(all_items.all? { |i| i.is_a?(Hash) && (i.keys - %w[pbi sigma homes reason]).empty? && i.key?('homes') }, 'items carry exactly pbi/sigma/homes/reason')
    check(all_items.all? { |i| i['sigma'].nil? || (i['sigma'].keys.sort == %w[id kind name]) }, 'sigma is null or {kind,name,id}')
    check(all_items.all? { |i| i['sigma'] || !i['reason'].to_s.strip.empty? }, 'an item without a home has a reason')
    check(all_items.all? { |i| !i['reason'].to_s.strip.empty? }, 'every item has a reason')
    tot = map['measures'].find { |m| m['pbi'] == 'Sales.Total Sales' }
    check(tot['sigma'] && tot['sigma']['name'] == 'Total Sales' && tot['sigma']['kind'] == 'metric', 'Total Sales maps to its data model metric')
    od = map['measures'].find { |m| m['pbi'] == 'Sales.Open Orders' }
    check(od['sigma'] && od['sigma']['name'] == 'Open Orders' && od['homes'].include?('Open Orders by Day'), 'class D measure maps to its summary')
    check(File.exist?(File.join(d, 'pbi-map.md')), 'pbi-map.md written')
    vis = map['visuals'].map { |v| v['pbi'] }
    check(vis.any? { |v| v.include?('Sales KPI') }, 'visuals listed')
    sl = map['slicers'].find { |s| s['pbi'].include?('Customer') }
    check(sl && sl['sigma'] && sl['sigma']['id'] == 'el-v4xx', 'slicer maps to its control')
  end
end

def test_class_d_and_live_pages_listed_in_limits
  puts 'test_class_d_and_live_pages_listed_in_limits'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    run_report(d, pbi_args(d))
    md = File.read(File.join(d, 'limits.md'))
    check(md =~ /Class D/ && md.include?('Sales.Open Orders') && md.include?('Open Orders by Day'), 'class D measure and its summary listed')
    check(md.include?('computed in the warehouse on every slicer change instead of read from a summary'), 'live-page trade-off stated')
    check(md.include?('Overview') && md.include?('Customer.Name'), 'live page names page and controls')
    check(md.include?('TOTAL_SALES'), 'physical names shown')
    check(md.include?('Sales.Region Sales') && md =~ /CALCULATE/, 'CALCULATE-override measure listed')
    check(md.include?('Region.Name') && md.include?('Region picker') && !md.include?('Not applied: ctl-region'), 'not-applied slicer labelled by its control name, not its id')
    check(md.include?('Unreached: Customer (Store.Name)'), 'unreached slicer labelled by its control name')
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    rs = map['slicers'].find { |x| x['sigma'] && x['sigma']['id'] == 'el-ctl-region' }
    check(rs && rs['reason'].include?('not applied: no reader carries it'), 'slicer item picks up the not-applied reason by controlId')
    s2 = md[/^## [^\n]*Measures on summaries.*?(?=^## |\z)/m].to_s
    check(s2.empty?, 'class D (section 1) and measures at their Power BI home are not listed as on summaries')
    Dir.mktmpdir do |d2|
      write_pbi_inputs(d2)
      c = classes_doc
      c['Sales.Total Sales']['home'] = 'Date'
      wj(d2, 'measure-classes.json', c)
      run_report(d2, pbi_args(d2))
      s2b = File.read(File.join(d2, 'limits.md'))[/^## [^\n]*Measures on summaries.*?(?=^## |\z)/m].to_s
      check(s2b.include?('Sales.Total Sales') && !s2b.include?('Open Orders'), 'a class A measure away from its Power BI home is listed')
    end
    Dir.mktmpdir do |d3|
      write_pbi_inputs(d3)
      FileUtils.rm_f(File.join(d3, 'pbi-shaped-model.json'))
      out3, st3 = run_report(d3, ['--shaped-log', File.join(d3, 'pbi-shaped-model.json'), '--compare-dir', d3])
      cmp3 = JSON.parse(File.read(File.join(d3, 'comparison.json')))
      check(st3.success? && out3.include?('missing or unreadable') && cmp3.key?('pbi'), 'unreadable --shaped-log warns and the shape stays pbi')
    end
    check(md.include?('Customer.Name') && md.include?('Mix'), 'mixed-summary dropped fields listed')
    order = ['Class D', 'Bidirectional', 'Live pages', 'Physical names', 'CALCULATE', 'Slicers not applied', 'Mixed', 'Optional customer step']
    idx = order.map { |h| md.index(/^## .*#{Regexp.escape(h)}/) }
    check(idx.none?(&:nil?) && idx == idx.sort, "sections in the specified order (#{idx.inspect})")
  end
end

def views_inputs(dir)
  wj(dir, 'dm-spec.json', { 'pages' => [{ 'id' => 'p', 'name' => 'P', 'elements' => [
    { 'id' => 'base', 'kind' => 'table', 'name' => 'FACT', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB S FACT] }, 'columns' => [] },
    { 'id' => 'view', 'kind' => 'table', 'name' => 'Sales View', 'source' => { 'kind' => 'table', 'elementId' => 'base' }, 'columns' => [],
      'metrics' => [{ 'id' => 'vm', 'name' => 'Total Sales', 'formula' => 'Sum([Amount])' }] }
  ] }] })
  wj(dir, 'workbook-spec.json', { 'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden' }, { 'id' => 'wp1', 'name' => 'Overview' }],
                                  'elements' => [
                                    { 'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'view' } },
                                    { 'id' => 'el-v1xx', 'kind' => 'kpi', 'name' => 'Sales KPI', 'source' => { 'kind' => 'table', 'elementId' => 'master' } }
                                  ],
                                  'layout' => %(<Page id="page-data">\n<Element elementId="master"/>\n</Page>\n<Page id="wp1">\n<Element elementId="el-v1xx"/>\n</Page>\n) })
end

def pbi_compare_inputs(dir)
  wj(dir, 'dm-spec.json', { 'pages' => [{ 'id' => 'p', 'name' => 'P', 'elements' => [
    { 'id' => 'src', 'kind' => 'table', 'name' => 'Sales (source)', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB S FACT] }, 'columns' => [] },
    { 'id' => 'child', 'kind' => 'table', 'name' => 'Sales', 'source' => { 'kind' => 'table', 'elementId' => 'src' }, 'columns' => [],
      'metrics' => [{ 'id' => 'vm', 'name' => 'Total Sales', 'formula' => 'Sum([Amount])' }] }
  ] }] })
  wj(dir, 'workbook-spec.json', { 'pages' => [{ 'id' => 'wp1', 'name' => 'Overview' }],
                                  'elements' => [
                                    { 'id' => 'el-v1xx', 'kind' => 'kpi', 'name' => 'Sales KPI', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'child' } }
                                  ],
                                  'layout' => %(<Page id="wp1">\n<Element elementId="el-v1xx"/>\n</Page>\n) })
  wj(dir, 'pbi-shaped-model.json', shaped_log)
  wj(dir, 'timings.json', { 'phases' => [{ 'phase' => 'x', 'seconds' => 1.5 }], 'totalSeconds' => 1.5 })
  wj(dir, 'parity-final.json', { 'overall' => 'PASS' })
end

def test_clicks_views_shape_counts_master_hop
  puts 'test_clicks_views_shape_counts_master_hop'
  Dir.mktmpdir do |root|
    views = File.join(root, 'views')
    pbi = File.join(root, 'pbi')
    FileUtils.mkdir_p([views, pbi])
    views_inputs(views)
    pbi_compare_inputs(pbi)
    wj(views, 'timings.json', { 'phases' => [], 'totalSeconds' => 9.0 })
    # current = views shape, compared against the pbi run
    out, st = run_report(views, ['--compare-dir', pbi])
    check(st.success?, "views run with --compare-dir (#{out.strip[0, 200]})")
    cmp = JSON.parse(File.read(File.join(views, 'comparison.json')))
    check(cmp.dig('views', 'clicks_to_source') == 3, "views: chart -> master -> View -> base = 3 (#{cmp.dig('views', 'clicks_to_source').inspect})")
    check(cmp.dig('pbi', 'clicks_to_source') == 2, "pbi: chart -> child -> source = 2 (#{cmp.dig('pbi', 'clicks_to_source').inspect})")
    check(cmp.dig('views', 'clicks_to_source_max') == 3 && cmp.dig('views', 'clicks_by_visual').is_a?(Hash), 'max and per-visual reported')
    check(cmp.dig('views', 'dm_elements') == 2 && cmp.dig('views', 'band') == 'below', 'element count and band reported')
    check(cmp.dig('views', 'wb_elements') == 2 && cmp.dig('views', 'hidden_or_unread') == 1, 'workbook element counts (the master is on the hidden page)')
    check(cmp.dig('views', 'timing', 'totalSeconds') == 9.0 && cmp.dig('pbi', 'timing', 'totalSeconds') == 1.5, 'timing read per shape')
    check(cmp.dig('pbi', 'parity') == 'PASS' && cmp.dig('views', 'parity').nil?, 'parity read per shape, null when missing')
    check(File.exist?(File.join(views, 'comparison.md')), 'comparison.md written')
  end
end

def test_default_shape_gets_map_without_build_change
  puts 'test_default_shape_gets_map_without_build_change'
  Dir.mktmpdir do |d|
    views_inputs(d)
    before = %w[dm-spec.json workbook-spec.json model.bim signals.json].map { |f| [f, File.exist?(File.join(d, f)) ? File.binread(File.join(d, f)) : nil] }
    wj(d, 'coverage.json', { 'unresolved' => [] })
    wj(d, 'control-scope.json', { 'controls' => [], 'unbound' => [] })
    out, st = run_report(d)
    check(st.success?, "views shape runs without pbi inputs (#{out.strip[0, 200]})")
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    tot = map['measures'].find { |m| m['pbi'] == 'Sales.Total Sales' }
    check(tot && tot['sigma'] && tot['sigma']['name'] == 'Total Sales', 'views shape: measure maps to the same-named metric')
    od = map['measures'].find { |m| m['pbi'] == 'Sales.Open Orders' }
    check(od && od['sigma'].nil? && !od['reason'].to_s.empty?, 'views shape: no metric gives a reason')
    after = %w[dm-spec.json workbook-spec.json].map { |f| [f, File.binread(File.join(d, f))] }
    check(after.all? { |f, c| before.assoc(f)[1] == c }, 'spec inputs are byte-identical afterwards')
    allowed = %w[pbi-map.json pbi-map.md limits.md comparison.json comparison.md]
    inputs = %w[dm-spec.json workbook-spec.json model.bim signals.json coverage.json control-scope.json]
    extra = Dir.children(d) - inputs
    check((extra - allowed).empty? && %w[pbi-map.json pbi-map.md limits.md].all? { |f| extra.include?(f) }, "only allowed files written (#{extra.sort.inspect})")
    md = File.read(File.join(d, 'limits.md'))
    check(md =~ /^## .*Bidirectional/ && md =~ /^## .*Optional customer step/, 'views shape still gets the relationship and CREATE VIEW sections')
    check(md !~ /Class D|Live pages/, 'empty sections are left out')
  end
end

def test_bidi_and_many_to_many_relationships_listed_as_limits
  puts 'test_bidi_and_many_to_many_relationships_listed_as_limits'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    run_report(d, pbi_args(d))
    md = File.read(File.join(d, 'limits.md'))
    sec = md[/^## [^\n]*Bidirectional.*?(?=^## |\z)/m].to_s
    check(sec.include?('Sales') && sec.include?('Date') && sec =~ /bidirectional/i, 'bidirectional relationship listed')
    check(sec.include?('Customer') && sec =~ /many-to-many/i, 'many-to-many relationship listed')
    check(!sec.include?('Region'), 'a plain one-to-many relationship is not listed')
    Dir.mktmpdir do |v|
      views_inputs(v)
      wj(v, 'coverage.json', { 'unresolved' => [] })
      run_report(v)
      vsec = File.read(File.join(v, 'limits.md'))[/^## [^\n]*Bidirectional.*?(?=^## |\z)/m].to_s
      check(vsec.include?('Date') && vsec.include?('Customer'), 'views shape lists them too')
    end
  end
end

def test_custom_sql_sources_get_create_view_suggestion
  puts 'test_custom_sql_sources_get_create_view_suggestion'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    run_report(d, pbi_args(d))
    md = File.read(File.join(d, 'limits.md'))
    sec = md[/^## [^\n]*Optional customer step.*/m].to_s
    check(sec.scan('CREATE OR REPLACE VIEW').length == 1, 'one CREATE VIEW per Custom SQL source')
    check(sec.include?('CREATE OR REPLACE VIEW <TARGET_SCHEMA>.CUSTOMER AS'), 'view name is the element name in upper snake case')
    check(sec.include?("SELECT id, name\nFROM src.customers\n;") || sec.include?("FROM src.customers;"), 'statement carried, ends with a semicolon')
    check(!md.include?('CREATE OR REPLACE VIEW <TARGET_SCHEMA>.SALES'), 'warehouse-table sources get none')
  end
end

def test_report_filters_and_unverified_controls_listed
  puts 'test_report_filters_and_unverified_controls_listed'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    log = shaped_log
    log['filters'] = { 'applied' => [], 'skipped' => [], 'not_reachable' => [],
                       'dimension_unfiltered' => [{ 'filter' => 'Customer.Name exclude ["Acme"]', 'element' => 'Customer',
                                                    'reason' => 'a Lookup() into a filtered element returns NULL' }] }
    wj(d, 'pbi-shaped-model.json', log)
    FileUtils.mkdir_p(File.join(d, 'probe-controls'))
    wj(File.join(d, 'probe-controls'), 'probe-results.json',
       [{ 'control' => 'ctl-region', 'result' => 'SKIP', 'note' => 'no value found in the warehouse that differs from the saved selection' },
        { 'control' => 'ctl-customer', 'result' => 'PASS', 'note' => 'in-closure export differs' }])
    run_report(d, pbi_args(d))
    md = File.read(File.join(d, 'limits.md'))
    sec = md[/^## Report filters.*?(?=^## |\z)/m].to_s
    check(sec.include?('Customer filter Name exclude ["Acme"] applies to fact visuals; slicer value lists and dimension-only visuals on Customer still show the excluded members'),
          "limits.md has a Report filters section for each dimension_unfiltered entry: #{sec.inspect}")
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    sl = map['slicers'].find { |x| x['pbi'].include?('Customer') }
    check(sl && sl['reason'].include?('still lists the excluded members') && sl['reason'].include?('Name exclude ["Acme"]'), "the Customer slicer in pbi-map says its value list shows the excluded members: #{sl && sl['reason']}")
    rg = map['slicers'].find { |x| x['pbi'].include?('Region') }
    check(rg && !rg['reason'].include?('excluded members'), 'a slicer on another table is not flagged')
    usec = md[/^## Controls the flip test could not verify.*?(?=^## |\z)/m].to_s
    check(usec.include?('Region picker') && usec.include?('no value found in the warehouse') && !usec.include?('Customer'),
          "limits.md lists the SKIPped control as UNVERIFIED with the reason, not the proven one: #{usec.inspect}")
    Dir.mktmpdir do |v|
      write_pbi_inputs(v)
      FileUtils.rm_f(File.join(v, 'pbi-shaped-model.json')) # no shaped log: the default (views) shape
      FileUtils.mkdir_p(File.join(v, 'probe-controls'))
      wj(File.join(v, 'probe-controls'), 'probe-results.json', [{ 'control' => 'ctl-region', 'result' => 'SKIP', 'note' => 'x' }])
      run_report(v, [])
      vmd = File.read(File.join(v, 'limits.md'))
      check(!vmd.include?('Report filters') && !vmd.include?('flip test could not verify'), 'the default (views) shape report is unchanged by either section')
    end
  end
end

# Task 21a2 (live): the class D visual section said "Held back (no chart built)" even after --page-facts built the visual on a
# page summary. A visual is held back only while coverage.json records it dropped.
def test_class_d_visual_listed_only_while_held_back
  puts 'test_class_d_visual_listed_only_while_held_back'
  dv = { 'page' => 'Shipping', 'visual' => 'Ship vs order', 'visual_id' => 'V1', 'reason' => 'needs two relationship paths to Date' }
  held = { 'unresolved' => [{ 'visual' => 'Ship vs order', 'severity' => 'dropped', 'detail' => 'class D visual held back (not built): x' }] }
  [[held, true], [{ 'unresolved' => [] }, false]].each do |cov, listed|
    Dir.mktmpdir do |d|
      write_pbi_inputs(d)
      lg = shaped_log
      lg['direct_map']['class_d_visuals'] = [dv]
      wj(d, 'pbi-shaped-model.json', lg)
      wj(d, 'coverage.json', cov)
      run_report(d, pbi_args(d))
      md = File.read(File.join(d, 'limits.md'))
      check(md.include?("Visual 'Ship vs order'") == listed, "class D visual #{listed ? 'listed while coverage has it dropped' : 'not listed once it is built (a page summary carries it)'}")
      check(md.include?('## Class D measures and visuals') == listed, "section heading follows the listed visuals (#{listed})")
    end
  end
end

# Task 21b (live): a page summary's measure columns are named for what they hold ("YTD at Month"), not for the measure, so the map said
# "no data model metric or column of that name; the measure is not carried" and limits.md said "lands in no summary" for measures
# that the summary feeds (visuals read them). The summary's column descriptions ("Feeds <measure>[ and <measure>]: ...") name them.
def test_measure_fed_by_a_summary_column_has_that_home
  puts 'test_measure_fed_by_a_summary_column_has_that_home'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    t = tmsl_doc
    t['model']['tables'][0]['measures'] += [{ 'name' => 'Sales YTD', 'expression' => 'TOTALYTD([Total Sales], Date[Day])' },
                                            { 'name' => 'Sales PY', 'expression' => 'CALCULATE([Total Sales], SAMEPERIODLASTYEAR(Date[Day]))' },
                                            { 'name' => 'Sales YoY %', 'expression' => 'DIVIDE([Total Sales] - [Sales PY], [Sales PY])' },
                                            { 'name' => 'Sales MTD', 'expression' => 'TOTALMTD([Total Sales], Date[Day])' }]
    sg = signals_doc
    sg['pages'][0]['visuals'] << { 'visual_id' => 'V6', 'visual_type' => 'lineChart', 'title' => 'Trend', 'sigma_kind' => 'line',
                                   'bindings' => { 'Y' => ['Sales.Sales YTD', 'Sales.Sales PY', 'Sales.Sales YoY %', 'Sales.Sales MTD'] } }
    dm = pbi_dm
    dm['pages'][0]['elements'] << { 'id' => 'e-trend', 'kind' => 'table', 'name' => 'Trends – summary', 'source' => { 'kind' => 'sql', 'statement' => 'SELECT 1' },
                                    'columns' => [{ 'id' => 'tc1', 'name' => 'YTD at Month', 'formula' => '[Custom SQL/A]', 'description' => 'Feeds Sales YTD: running total per month' },
                                                  { 'id' => 'tc2', 'name' => 'Prior Year', 'formula' => '[Custom SQL/B]', 'description' => 'Feeds Sales PY and Sales YoY %: same month last year' },
                                                  { 'id' => 'tc3', 'name' => 'Unrelated', 'formula' => '[Custom SQL/C]', 'description' => 'Feeds Sales YTD (As Of): constant' },
                                                  { 'id' => 'tc4', 'name' => 'Latest', 'formula' => '[Custom SQL/D]', 'description' => 'Feeds Sales MTD with no date axis: the latest month' }] }
    cl = classes_doc
    cl['Sales.Sales YTD'] = { 'class' => 'D', 'reason' => 'slicer fields exceed carry size', 'home' => 'Sales', 'ti' => nil }
    wj(d, 'model.bim', t)
    wj(d, 'signals.json', sg)
    wj(d, 'dm-spec.json', dm)
    wj(d, 'measure-classes.json', cl)
    lg = shaped_log
    lg['direct_map']['class_d_fields'] = ['Sales.Sales YTD']
    wj(d, 'pbi-shaped-model.json', lg)
    out, st = Open3.capture2e(RbConfig.ruby, REPORT, '--tmsl', File.join(d, 'model.bim'), '--signals', File.join(d, 'signals.json'),
                              '--dm-spec', File.join(d, 'dm-spec.json'), '--wb-spec', File.join(d, 'workbook-spec.json'), '--out-dir', d, *pbi_args(d))
    check(st.success?, "report runs (#{out.strip[0, 200]})")
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    homes = ->(n) { (map['measures'].find { |m| m['pbi'] == n } || {})['homes'] }
    check(homes.call('Sales.Sales YTD') == ['Trends – summary'], "a measure a summary column 'Feeds' has that summary as its home (#{homes.call('Sales.Sales YTD').inspect})")
    check(homes.call('Sales.Sales YoY %') == ['Trends – summary'] && homes.call('Sales.Sales PY') == ['Trends – summary'], 'one column can feed two measures ("Feeds A and B")')
    check(homes.call('Sales.Sales MTD') == ['Trends – summary'], '"Feeds <measure> with ..." names the measure too')
    check(File.read(File.join(d, 'limits.md')).include?("Sales.Sales YTD (slicer fields exceed carry size): lands in summary 'Trends – summary'"), 'limits.md says the class D measure lands in the summary')
  end
end

def test_inactive_relationship_and_time_intelligence_map_to_distinct_homes
  puts 'test_inactive_relationship_and_time_intelligence_map_to_distinct_homes'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    t = tmsl_doc
    t['model']['relationships'] << { 'name' => 'r-ship', 'fromTable' => 'Sales', 'fromColumn' => 'ShipDateKey',
                                     'toTable' => 'Date', 'toColumn' => 'Key', 'isActive' => false }
    t['model']['tables'][0]['measures'] += [{ 'name' => 'Sales PY', 'expression' => 'CALCULATE([Total Sales], SAMEPERIODLASTYEAR(Date[Day]))' },
                                            { 'name' => 'Sales YoY %', 'expression' => 'DIVIDE([Total Sales] - [Sales PY], [Sales PY])' }]
    sg = signals_doc
    sg['pages'][0]['visuals'] << { 'visual_id' => 'V6', 'visual_type' => 'lineChart', 'title' => 'Trend', 'sigma_kind' => 'line',
                                   'bindings' => { 'Y' => ['Sales.Sales PY', 'Sales.Sales YoY %'] } }
    dm = pbi_dm
    sales = dm['pages'][0]['elements'][0]
    sales['relationships'] << { 'id' => 'rl-ship', 'targetElementId' => 'e-date', 'keys' => [], 'name' => 'Date (ShipDateKey)' }
    dm['pages'][0]['elements'] += [
      { 'id' => 'e-quarter', 'kind' => 'table', 'name' => 'Sales by quarter', 'columns' => [
        { 'id' => 'py-helper', 'name' => 'Sales PY', 'description' => 'Power BI measure Sales[Sales PY], read by Sales[Sales YoY %].' },
        { 'id' => 'yoy-num', 'name' => 'Sales YoY % (numerator)', 'description' => 'Numerator of Power BI measure Sales[Sales YoY %] (the chart sums it).' },
        { 'id' => 'yoy-den', 'name' => 'Sales YoY % (denominator)', 'description' => 'Denominator of Power BI measure Sales[Sales YoY %].' }
      ] },
      { 'id' => 'e-month', 'kind' => 'table', 'name' => 'Sales by month', 'columns' => [
        { 'id' => 'py', 'name' => 'Sales PY', 'description' => 'Power BI measure Sales[Sales PY].' }
      ] }
    ]
    wj(d, 'model.bim', t)
    wj(d, 'signals.json', sg)
    wj(d, 'dm-spec.json', dm)
    Open3.capture2e(RbConfig.ruby, REPORT, '--tmsl', File.join(d, 'model.bim'), '--signals', File.join(d, 'signals.json'),
                    '--dm-spec', File.join(d, 'dm-spec.json'), '--wb-spec', File.join(d, 'workbook-spec.json'), '--out-dir', d, *pbi_args(d))
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    ship = map['relationships'].find { |r| r['pbi'].include?('r-ship') }
    check(ship && ship.dig('sigma', 'id') == 'rl-ship', 'the inactive relationship maps to its distinct Sigma relationship')
    py = map['measures'].find { |m| m['pbi'] == 'Sales.Sales PY' }
    check(py && py.dig('sigma', 'id') == 'py', 'a direct prior-year column wins over the helper generated for a YoY measure')
    yoy = map['measures'].find { |m| m['pbi'] == 'Sales.Sales YoY %' }
    check(yoy && yoy.dig('sigma', 'id') == 'yoy-num', 'a carried YoY ratio maps to its numerator column')
  end
end

# The report maps a Power BI relationship by the shaper's 'carried' log (which Sigma relationship carries it), never
# by guessing from names: a uniquified " (2)" name, an occupant holding the plain name, or an inactive relationship
# whose fromColumn is numeric ("Date (2)") all read alike.
def test_relationship_mapped_by_the_carried_log
  puts 'test_relationship_mapped_by_the_carried_log'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    t = tmsl_doc
    t['model']['relationships'] << { 'name' => 'r-ship', 'fromTable' => 'Sales', 'fromColumn' => 'ShipDateKey',
                                     'toTable' => 'Date', 'toColumn' => 'Key', 'isActive' => false }
    t['model']['relationships'] += [
      { 'name' => 'r-customer-date', 'fromTable' => 'Customer', 'fromColumn' => 'DateKey', 'toTable' => 'Date', 'toColumn' => 'Key' },
      { 'name' => 'r-customer-date-numeric', 'fromTable' => 'Customer', 'fromColumn' => '2',
        'toTable' => 'Date', 'toColumn' => 'Key', 'isActive' => false }
    ]
    dm = pbi_dm
    dm['pages'][0]['elements'][0]['relationships'] += [
      { 'id' => 'rl-occupant', 'targetElementId' => 'e-date', 'keys' => [], 'name' => 'Date (ShipDateKey)' },
      { 'id' => 'rl-ship', 'targetElementId' => 'e-date', 'keys' => [], 'name' => 'Date (ShipDateKey) (2)' },
      { 'id' => 'rl-inactive-date', 'targetElementId' => 'e-date', 'keys' => [], 'name' => 'Date (2)' }
    ]
    dm['pages'][0]['elements'][2]['relationships'] = [
      { 'id' => 'rl-numeric', 'targetElementId' => 'e-date', 'keys' => [], 'name' => 'Date (2)' }
    ]
    log = shaped_log
    log['relationships']['carried'] = [
      { 'relationship' => 'r1', 'element' => 'Sales', 'id' => 'rl1', 'name' => 'Date' },
      { 'relationship' => 'r2', 'element' => 'Sales', 'id' => 'rl2', 'name' => 'Customer' },
      { 'relationship' => 'r-ship', 'element' => 'Sales', 'id' => 'rl-ship', 'name' => 'Date (ShipDateKey) (2)' },
      { 'relationship' => 'r-customer-date-numeric', 'element' => 'Customer', 'id' => 'rl-numeric', 'name' => 'Date (2)' }
    ]
    wj(d, 'model.bim', t)
    wj(d, 'dm-spec.json', dm)
    wj(d, 'pbi-shaped-model.json', log)
    Open3.capture2e(RbConfig.ruby, REPORT, '--tmsl', File.join(d, 'model.bim'), '--signals', File.join(d, 'signals.json'),
                    '--dm-spec', File.join(d, 'dm-spec.json'), '--wb-spec', File.join(d, 'workbook-spec.json'), '--out-dir', d, *pbi_args(d))
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    by = ->(name) { map['relationships'].find { |r| r['pbi'].include?("(#{name})") } }
    check(by.call('r-ship') && by.call('r-ship').dig('sigma', 'id') == 'rl-ship',
          "the uniquified 'Date (ShipDateKey) (2)' is mapped, not the occupant holding the plain name: #{by.call('r-ship').inspect}")
    check(by.call('r1') && by.call('r1').dig('sigma', 'id') == 'rl1', "the active relationship maps to its own 'Date', not a 'Date (2)' beside it")
    check(by.call('r-customer-date-numeric') && by.call('r-customer-date-numeric').dig('sigma', 'id') == 'rl-numeric',
          'an inactive relationship with a numeric fromColumn maps to its "Date (2)"')
    check(by.call('r-customer-date') && by.call('r-customer-date')['sigma'].nil?,
          "an active relationship the shaper did not carry is not guessed onto 'Date (2)': #{by.call('r-customer-date').inspect}")
    # the occupant is carried for no Power BI relationship, so nothing maps to it
    check(map['relationships'].none? { |r| r.dig('sigma', 'id') == 'rl-occupant' }, 'nothing maps to the occupant')
  end
end

def test_time_axis_density_and_blank_versus_zero_limits
  puts 'test_time_axis_density_and_blank_versus_zero_limits (Task 21z2)'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    log = shaped_log
    log['time_density'] = { 'facts' => { 'Sales' => { 'month' => { 'verified' => true, 'sparse' => true, 'expected' => 38, 'present' => 36 },
                                                      'quarter' => { 'verified' => true, 'sparse' => false, 'expected' => 12, 'present' => 12 },
                                                      'year' => { 'verified' => false, 'reason' => 'no probe results' } } },
                            'sparse' => [{ 'fact' => 'Sales', 'grain' => 'month' }] }
    log['time_intel'] = [{ 'measure' => 'Sales.Sales YTD', 'form' => 'grouped', 'kind' => 'ytd', 'period' => 'Month', 'element' => 'Sales by month' }]
    wj(d, 'pbi-shaped-model.json', log)
    run_report(d, pbi_args(d))
    md = File.read(File.join(d, 'limits.md'))
    sec = md[/^## Time-axis density.*?(?=^## |\z)/m].to_s
    check(sec.include?('Sales at month grain: sparse (36 of 38 Date-table months have Sales rows)') && sec.include?('class D'), "sparse fact listed (#{sec[0, 300].inspect})")
    check(sec.include?('Sales at year grain: time-axis density not verified (no probe results)'), 'an unverified grain is listed loudly')
    check(!sec.include?('quarter grain'), 'a verified dense grain is not listed')
    check(!md.include?('Blank versus zero'), 'no blank-versus-zero limit: the latest-period reads use Null as the else branch (Sum of an all-null group is Null, proven live in 21c)')
  end
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    run_report(d, pbi_args(d))
    md = File.read(File.join(d, 'limits.md'))
    check(!md.include?('Time-axis density') && !md.include?('Blank versus zero'), 'no sections when the run has no grouped or rolling time intelligence')
  end
end

# Final review I7 + Fix A limits + m4: the report names what the run could not verify or held back.
def test_key_check_and_fix_a_limits_listed
  puts 'test_key_check_and_fix_a_limits_listed'
  Dir.mktmpdir do |d|
    write_pbi_inputs(d)
    log = shaped_log
    log['notes'] = ['key check skipped: no --probe-sources']
    log['blank_arith'] = [{ 'element' => 'Sales', 'metric' => 'Gross Margin', 'from' => '[Metrics/A] - [Metrics/B]', 'to' => 'If(...)' }]
    log['time_intel'] = [{ 'measure' => 'Sales.Sales YTD (As Of)', 'form' => 'metric', 'element' => 'Sales', 'column' => 'Sales YTD (As Of)' },
                         { 'measure' => 'Sales.Sales R28', 'form' => 'rolling_sql', 'element' => 'Sales rolling 28 days by day',
                           'report_filters' => ['Category.Category Name exclude ["Discontinued"]'] }]
    log['direct_map']['asof_ignore_date'] = [{ 'page' => 'Trends', 'visual' => 'Sales YTD (As Of)', 'visual_id' => 'TrAsOf' }]
    wj(d, 'pbi-shaped-model.json', log)
    cls = classes_doc
    cls['Sales.Sales YTD (As Of)'] = { 'class' => 'C', 'reason' => 'ytd time intelligence (as_of anchor) over [Total Sales]', 'home' => 'Sales', 'ti' => {} }
    cls['Sales.Sales by Ship Date'] = { 'class' => 'B', 'reason' => 'uses inactive relationship Date (ShipDateKey)', 'home' => 'Sales', 'ti' => nil }
    cls['Sales.Rolling Between'] = { 'class' => 'D', 'reason' => 'DATESBETWEEN window is not a recognised YTD, MTD or day offset', 'home' => nil, 'ti' => nil }
    cls['Sales.Sales PY'] = { 'class' => 'D', 'reason' => 'day-grain prior period not probed', 'home' => nil, 'ti' => nil }
    cls['Sales.Distinct Customers'] = { 'class' => 'A', 'reason' => 'aggregates over Sales columns only', 'home' => 'Sales', 'ti' => nil }
    wj(d, 'measure-classes.json', cls)
    t = tmsl_doc
    t['model']['tables'][0]['measures'] << { 'name' => 'Distinct Customers', 'expression' => 'DISTINCTCOUNT(Sales[CustKey])' }
    File.write(File.join(d, 'model.bim'), JSON.pretty_generate(t))
    tmsl = File.join(d, 'model.bim')
    sig = wj(d, 'signals.json', signals_doc)
    Open3.capture2e(RbConfig.ruby, REPORT, '--tmsl', tmsl, '--signals', sig, '--dm-spec', File.join(d, 'dm-spec.json'),
                    '--wb-spec', File.join(d, 'workbook-spec.json'), '--out-dir', d, *pbi_args(d))
    md = File.read(File.join(d, 'limits.md'))
    sec = ->(title) { md[/^## #{Regexp.escape(title)}.*?(?=^## |\z)/m].to_s }
    k = sec.call('Key check not run')
    check(k.include?('3 relationship(s) unverified') && k.include?('--probe-sources'), "I7: limits.md says the key check did not run (#{k.inspect})")
    map = JSON.parse(File.read(File.join(d, 'pbi-map.json')))
    check(map['relationships'].all? { |r| r['reason'].include?('key uniqueness not verified') || r['sigma'].nil? }, 'I7: the map notes each carried relationship as unverified')
    a = sec.call('As-of measures')
    check(a.include?('Sales.Sales YTD (As Of)') && a.include?('flat across the Date table') && a.include?("Visual 'Sales YTD (As Of)' on page 'Trends'") && a.include?('not applied'),
          "C1: as-of measures and the all-as-of visual whose date pick is not applied are listed (#{a.inspect})")
    r = sec.call('Rolling windows and report filters')
    check(r.include?('Sales rolling 28 days by day') && r.include?('Category.Category Name exclude ["Discontinued"]') && r.include?('class D') && r.include?('blank'),
          "C2: the rolling element names its report filters and the hold-back rule (#{r.inspect})")
    df = sec.call('Date fields')
    check(df.include?('fiscal') && df.include?('Quarter Number') && df.include?('class D'), "I2: only provable calendar fields bind (#{df.inspect})")
    u = sec.call('USERELATIONSHIP measures')
    check(u.include?('Sales.Sales by Ship Date') && u.include?('report-level Date filter') && u.include?('class D'), "I3: USERELATIONSHIP under date controls is listed (#{u.inspect})")
    c = sec.call('CALCULATE-override measures')
    check(c.empty? || c.include?('class D'), "I4: the CALCULATE section says the affected visuals are class D (#{c.inspect})")
    f = sec.call('Time-intelligence forms held back')
    check(f.include?('Sales.Rolling Between') && f.include?('MAX(') && f.include?('Sales.Sales PY') && f.include?('day-grain'), "I5/m12: DATESBETWEEN and day-grain prior-period holds are explained (#{f.inspect})")
    b = sec.call('Blank-as-zero arithmetic')
    check(b.include?('top-level') && b.include?('Sales.Gross Margin'), "I1: the blank-as-zero rewrite lists its top-level-only limit (#{b.inspect})")
    dc = sec.call('DISTINCTCOUNT')
    check(dc.include?('Sales.Distinct Customers') && dc.include?('BLANK') && dc.include?('CountDistinct'), "m4: DISTINCTCOUNT counts BLANK in DAX, CountDistinct ignores NULL (#{dc.inspect})")
    # a no-probe run is the only run that gets the key section; a probed run and the views shape do not
    Dir.mktmpdir do |v|
      write_pbi_inputs(v)
      run_report(v, pbi_args(v))
      vmd = File.read(File.join(v, 'limits.md'))
      check(!vmd.include?('Key check not run') && !vmd.include?('As-of measures') && !vmd.include?('DISTINCTCOUNT'), 'a run with a key check and none of those forms lists none of the sections')
    end
    Dir.mktmpdir do |w|
      write_pbi_inputs(w)
      lg = shaped_log
      lg['waivers'] = [{ 'flag' => '--allow-unverified-keys', 'relationships' => ['Sales->Date'], 'errors' => ['x'] }]
      wj(w, 'pbi-shaped-model.json', lg)
      run_report(w, pbi_args(w))
      wk = File.read(File.join(w, 'limits.md'))[/^## Key check not run.*?(?=^## |\z)/m].to_s
      check(wk.include?('Sales->Date') && wk.include?('--allow-unverified-keys'), "a waived key check lists the relationships kept unverified (#{wk.inspect})")
    end
  end
end

test_every_visible_measure_has_a_home_or_reason
test_wrapped_workbook_spec_and_limits_wording
test_class_d_and_live_pages_listed_in_limits
test_clicks_views_shape_counts_master_hop
test_default_shape_gets_map_without_build_change
test_bidi_and_many_to_many_relationships_listed_as_limits
test_custom_sql_sources_get_create_view_suggestion
test_report_filters_and_unverified_controls_listed
test_class_d_visual_listed_only_while_held_back
test_measure_fed_by_a_summary_column_has_that_home
test_inactive_relationship_and_time_intelligence_map_to_distinct_homes
test_relationship_mapped_by_the_carried_log
test_time_axis_density_and_blank_versus_zero_limits
test_key_check_and_fix_a_limits_listed

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "FAILED (#{FAILS.size}):"
  FAILS.each { |f| puts "  - #{f}" }
  exit 1
end
