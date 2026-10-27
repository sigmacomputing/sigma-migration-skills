#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for three Tableau -> Sigma features that used to be manual
# post-publish steps, driven end-to-end (offline) through the real
# parse-twb-layout.rb + build-charts-from-signals.rb + build-dashboard-layout.rb
# + build-postpublish-guide.rb on scripts/fixtures/drill-tooltip-scope.twb:
#
#   1. Exact quick-filter scope for charts that do not read the master directly:
#      a helper-sourced chart (an INCLUDE-LOD hidden helper) is targeted through
#      a hidden filter column on the HELPER, a master-sourced pivot through an
#      off-shelf column, a table through a hidden column — so the control no
#      longer falls back to the master and over-filters unrelated charts.
#   2. Chart tooltip fields: Tooltip-shelf fields + the fields of a customized
#      tooltip become `tooltip.columns` (ATTR semantics for dimensions).
#   3. Drill controls from Tableau drill paths (chart targets only — a Sigma
#      drill control does not drive pivots/tables), plus the off-shelf level
#      columns + pivot-collapse record for a pivot holding the first level.
#
# Usage:  ruby scripts/test-drill-tooltip-scope.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/control_lint'

DIR     = __dir__
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
PARSER_PY = File.join(DIR, 'parse-twb-layout.py')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
LAYOUT  = File.join(DIR, 'build-dashboard-layout.rb')
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'fixtures', 'drill-tooltip-scope.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Breakdown (a parameter-driven calc) is deliberately NOT a master column.
MASTER_CAPTIONS = ['Order Date', 'Order Channel', 'Net Revenue', 'Gross Revenue', 'Net Profit', 'Channel Group'].freeze

def run_pipeline(twb_text, extra_args = [], csvs: {})
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    _o, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false } unless File.exist?(lay)
    # Optional view CSVs ({worksheet name => csv text}), as Tableau discovery writes them.
    views = csvs.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    unless csvs.empty?
      Dir.mkdir(File.join(d, 'views'))
      csvs.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    end
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'DTS', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    mm = MASTER_CAPTIONS.each_with_object({}) do |c, h|
      h[Regexp.escape(c)] = { 'id' => "m-#{c.downcase.gsub(/\W+/, '_')}", 'name' => c }
    end
    File.write(File.join(d, 'master-columns.json'), JSON.dump(mm))
    out = File.join(d, 'chart-specs.json')
    # Test harness: runs the fixed build script under test against a temp-dir fixture; extra_args are this file's literals.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    log, = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                           '--meta', File.join(d, 'dashboard-layout-meta.json'),
                           '--master-map', File.join(d, 'master-columns.json'),
                           '--master-element-id', 'master', '--auto-controls',
                           '--skip-dashboard-read', 'offline test fixture', '--out', out, *extra_args)
    rd = ->(n) { f = File.join(d, n); File.exist?(f) ? JSON.parse(File.read(f)) : nil }
    # build-dashboard-layout needs the posted ids: derive them from the built spec.
    pages = out && File.exist?(out) ? JSON.parse(File.read(out)) : nil
    layout_xml = nil
    if pages
      page_list = pages.is_a?(Hash) ? pages['pages'] : [{ 'name' => 'Channel Review', 'elements' => pages }]
      wb_ids = { 'pages' => [{ 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] }] +
                            page_list.map { |pg| { 'name' => pg['name'], 'elements' => pg['elements'].map { |e| { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'].to_s } } } } }
      File.write(File.join(d, 'wb-ids.json'), JSON.dump(wb_ids))
      lx = File.join(d, 'layout.xml')
      Open3.capture2e(RUBY, LAYOUT, '--layout', lay, '--wb-ids', File.join(d, 'wb-ids.json'), '--out', lx)
      layout_xml = File.exist?(lx) ? File.read(lx) : nil
    end
    guide = nil
    ai = File.join(d, 'auto-interactions.json')
    if File.exist?(ai)
      gmd = File.join(d, 'G.md')
      gjson = File.join(d, 'ledger.json')
      Open3.capture2e(RUBY, GUIDE, '--twb', twb, '--out', gmd, '--json-out', gjson,
                      '--emitted-manifest', File.join(d, 'chart-specs-actions-emitted.json'))
      guide = { md: File.read(gmd, encoding: 'UTF-8'), ledger: JSON.parse(File.read(gjson)) } if File.exist?(gmd)
    end
    return { ok: File.exist?(out), log: log, specs: rd.call('chart-specs.json'), data: rd.call('chart-specs-data-elements.json'),
             layout: rd.call('dashboard-layout.json'), meta: rd.call('dashboard-layout-meta.json'),
             scope: rd.call('control-scope.json'), coverage: rd.call('coverage.json'),
             auto: rd.call('auto-interactions.json'), layout_xml: layout_xml, guide: guide }
  end
end

def lint_spec(specs_out, data = nil)
  pages = specs_out.is_a?(Hash) ? specs_out['pages'] : [{ 'name' => 'Channel Review', 'elements' => specs_out }]
  els = [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'source' => { 'kind' => 'data-model' } }]
  lay = '<Page id="data"><Element elementId="master"/></Page>'
  meta = [{ 'id' => 'data', 'name' => 'Data' }]
  pages.each_with_index do |pg, i|
    meta << { 'id' => "pg#{i}", 'name' => pg['name'] }
    lay += "<Page id=\"pg#{i}\">#{pg['elements'].map { |e| "<Element elementId=\"#{e['id']}\"/>" }.join}</Page>"
    els.concat(pg['elements'])
  end
  data = (specs_out.is_a?(Hash) ? Array(specs_out['data_elements']) : Array(data)).uniq { |e| e['id'] }
  lay = lay.sub('<Element elementId="master"/>', '<Element elementId="master"/>' + data.map { |e| "<Element elementId=\"#{e['id']}\"/>" }.join)
  { 'pages' => meta, 'elements' => els + data, 'layout' => lay }
end

FIXTURE_TEXT = File.read(FIXTURE, encoding: 'utf-8')
flat = run_pipeline(FIXTURE_TEXT)
specs = flat[:specs] || []
chart = ->(id) { specs.find { |e| e['id'] == id } }
data_el = ->(id) { (flat[:data] || []).find { |e| e['id'] == id } }
colf = ->(el, id) { ((el || {})['columns'] || []).find { |c| c['id'] == id } }

puts 'Part 1 - parser signals (Ruby + Python twins)'
check(flat[:ok], 'pipeline ran on the fixture', fails)
ws = (flat[:meta] || {})['worksheets'] || {}
rt_refs = ['[federated.dtscope0001].[sum:GROSS_REVENUE:qk]', '[federated.dtscope0001].[twk:ORDER_DATE:qk]',
           '[federated.dtscope0001].[sum:NET_REVENUE:qk]', '[federated.dtscope0001].[sum:NET_PROFIT:qk]',
           '[federated.dtscope0001].[attr:Calculation_301:nk]']
check(ws.dig('Revenue Trend', 'tooltip_fields') == rt_refs,
      "Revenue Trend tooltip_fields = shelf field first, then the customized-tooltip tokens, deduped (got #{ws.dig('Revenue Trend', 'tooltip_fields').inspect})", fails)
check(!ws['Channel Mix'].key?('tooltip_fields'), 'a sheet with no tooltip fields carries no tooltip_fields key', fails)
zone = (flat[:layout] || []).flat_map { |d| d['zones'] }.find { |z| z['kind'] == 'chart' && z['caption'] == 'Revenue Trend' }
check(zone && zone['tooltip_fields'] == rt_refs, 'the chart zone carries tooltip_fields', fails)
dp = (flat[:meta] || {})['drill_paths']
check(dp == [{ 'name' => 'Channel Hierarchy', 'datasource' => 'federated.dtscope0001',
               'fields' => ['[Calculation_301]', '[Calculation_303]'], 'captions' => ['Channel Group', 'Breakdown'] }],
      "meta drill_paths carries the hierarchy with captions (got #{dp.inspect})", fails)
mt = FIXTURE_TEXT.sub("<tooltip column='[federated.dtscope0001].[sum:GROSS_REVENUE:qk]' />",
                      "<encoding attr='tooltip' column='[federated.dtscope0001].[:Measure Names]' />" \
                      "<tooltip column='[federated.dtscope0001].[sum:GROSS_REVENUE:qk]' />")
mt = mt.sub('<run>Week of </run>', "<run>Week of </run><run>&lt;[federated.dtscope0001].[Multiple Values]&gt;</run>")
mtp = run_pipeline(mt)
check(mtp.dig(:meta, 'worksheets', 'Revenue Trend', 'tooltip_fields') == rt_refs,
      'Measure Names / Multiple Values refs are excluded from tooltip_fields', fails)
Dir.mktmpdir do |d|
  src = File.join(d, 'wb.twb')
  File.write(src, FIXTURE_TEXT)
  lay = File.join(d, 'py-layout.json')
  _o, st = Open3.capture2e('python3', PARSER_PY, src, lay)
  if st.success?
    pm = JSON.parse(File.read(File.join(d, 'py-layout-meta.json')))
    check(pm.dig('worksheets', 'Revenue Trend', 'tooltip_fields') == rt_refs && pm['drill_paths'] == dp,
          'the Python twin emits the same tooltip_fields and drill_paths', fails)
    pz = JSON.parse(File.read(lay)).flat_map { |dd| dd['zones'] }.find { |z| z['kind'] == 'chart' && z['caption'] == 'Revenue Trend' }
    check(pz && pz['tooltip_fields'] == rt_refs, 'the Python twin stamps tooltip_fields on the chart zone', fails)
  else
    check(false, "python twin ran (#{_o.lines.last})", fails)
  end
end

puts
puts 'Part 2 - Feature 1: exact scope without the master root fallback'
oc = specs.find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
want_filters = [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-revenue-trend' }, 'columnId' => 'f-order-channel-el-revenue-trend' },
                { 'source' => { 'kind' => 'table', 'elementId' => 'el-group-average-lod-src' }, 'columnId' => 'f-order-channel-el-group-average-lod-src' }]
check(oc && oc['filters'] == want_filters, "Order Channel targets Revenue Trend and the Group Average helper (got #{oc && oc['filters'].inspect})", fails)
check(colf.call(data_el.call('el-group-average-lod-src'), 'f-order-channel-el-group-average-lod-src') ==
      { 'id' => 'f-order-channel-el-group-average-lod-src', 'name' => 'Order Channel (filter)', 'formula' => '[Master/Order Channel]', 'hidden' => true },
      'the helper gets a hidden [Master/Order Channel] column, named "(filter)" beside its own Order Channel grouping key', fails)
helper = data_el.call('el-group-average-lod-src')
check(Array(helper['groupings']).none? { |g| (g['groupBy'] + g['calculations']).include?('f-order-channel-el-group-average-lod-src') },
      'the hidden helper column is in no grouping', fails)
check(colf.call(chart.call('el-revenue-trend'), 'f-order-channel-el-revenue-trend') &&
      !colf.call(chart.call('el-revenue-trend'), 'f-order-channel-el-revenue-trend').key?('hidden') &&
      chart.call('el-revenue-trend').dig('xAxis', 'columnId') == 'x-el-revenue-trend',
      'the chart gets the axis-less (not hidden) filter column', fails)
%w[el-channel-pivot el-channel-mix el-channel-bar].each do |id|
  check((chart.call(id)['columns'] || []).none? { |c| c['id'].start_with?('f-') }, "#{id} (out of scope) gets no filter column", fails)
end
check(!flat[:log].include?('will ALSO filter'), 'no "will ALSO filter" warning', fails)
check(flat[:log] =~ /'Order Channel' quick-filter control targets 2 chart\(s\) directly/, 'NOTE counts the 2 intended charts reached', fails)
roc = ((flat[:scope] || {})['controls'] || []).find { |r| r['name'] == 'Order Channel' }
check(roc && roc['target_mode'] == 'elements' && !roc.key?('over_filtered') && !roc.key?('root_fallback') &&
      roc['targets'] == want_filters && roc['scope'] == %w[el-revenue-trend el-group-average],
      'control-scope.json: target_mode elements, nothing over-filtered, scope = the two intended charts', fails)
check(((flat[:coverage] || {})['unresolved'] || []).none? { |u| u['visual'] == 'Order Channel' && u['severity'] == 'approximated' },
      'no approximated coverage entry for the exactly-scoped control', fails)
check(ControlLint.lint(lint_spec(flat[:specs], flat[:data]), scope: flat[:scope]).empty?,
      "control lint is clean (#{ControlLint.lint(lint_spec(flat[:specs], flat[:data]), scope: flat[:scope]).inspect})", fails)

# Pivot / table variants: Channel Pivot joins the Order Channel filter group and
# holds Order Date (not Order Channel) on Columns / nothing on Columns.
filter_block = FIXTURE_TEXT[%r{          <filter class='categorical' column='\[federated.dtscope0001\].\[none:ORDER_CHANNEL:nk\]' filter-group='7'>.*?</filter>\n}m]
variant = lambda do |cols_xml|
  head, tail = FIXTURE_TEXT.split("<worksheet name='Channel Pivot'>", 2)
  body, rest = tail.split('</worksheet>', 2)
  body = body.sub("          <aggregation value='true' />", filter_block + "          <aggregation value='true' />")
  body = body.sub("            <column-instance column='[ORDER_CHANNEL]'", "            <column-instance column='[ORDER_DATE]' derivation='None' name='[none:ORDER_DATE:nk]' pivot='key' type='nominal' />\n            <column-instance column='[ORDER_CHANNEL]'")
  body = body.sub(%r{<cols>.*?</cols>}, cols_xml)
  head + "<worksheet name='Channel Pivot'>" + body + '</worksheet>' + rest
end
pv = run_pipeline(variant.call('<cols>[federated.dtscope0001].[none:ORDER_DATE:nk]</cols>'))
pel = (pv[:specs] || []).find { |e| e['id'] == 'el-channel-pivot' }
check(pel && pel['kind'] == 'pivot-table', 'variant: Channel Pivot is a pivot-table', fails)
poc = (pv[:specs] || []).find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
check(poc && poc['filters'].include?({ 'source' => { 'kind' => 'table', 'elementId' => 'el-channel-pivot' }, 'columnId' => 'f-order-channel-el-channel-pivot' }),
      "pivot is targeted through an off-shelf column (got #{poc && poc['filters'].inspect})", fails)
pcol = colf.call(pel, 'f-order-channel-el-channel-pivot')
check(pcol == { 'id' => 'f-order-channel-el-channel-pivot', 'name' => 'Order Channel', 'formula' => '[Master/Order Channel]' } &&
      !pel['rowsBy'].to_s.include?('f-order') && !pel['columnsBy'].to_s.include?('f-order') && !pel['values'].to_s.include?('f-order'),
      'the pivot column is on no rowsBy/columnsBy/values and is not hidden', fails)
check(!pv[:log].include?('will ALSO filter') && poc['filters'].size == 3, 'pivot variant: still no over-filter warning', fails)
check(ControlLint.lint(lint_spec(pv[:specs], pv[:data]), scope: pv[:scope]).empty?, 'pivot variant: control lint clean', fails)
tv = run_pipeline(variant.call('<cols />'))
tel = (tv[:specs] || []).find { |e| e['id'] == 'el-channel-pivot' }
check(tel && tel['kind'] == 'table', 'variant: Channel Pivot is a table', fails)
tcol = colf.call(tel, 'f-order-channel-el-channel-pivot')
check(tcol && tcol['hidden'] == true && tcol['formula'] == '[Master/Order Channel]', 'the table gets a hidden filter column', fails)
check(!tv[:log].include?('will ALSO filter'), 'table variant: no over-filter warning', fails)

# Negative: a helper that ALSO feeds an out-of-scope chart must keep the root
# target (filtering the helper would over-filter its other consumer). The
# fixture has no such sharing (helpers are built per worksheet), so drive the
# real element_level_targets lambda (extracted from the builder source) directly.
src = File.read(BUILD, encoding: 'utf-8')
lam_src = src[/^element_level_targets = lambda do.*?^end\n/m]
const_src = src[/^ELEMENT_TARGET_ADD_KINDS = .*?\.freeze\n/m].to_s + src[/^def unique_col_id.*?^end\n/m].to_s.sub('def unique_col_id', 'def self.unique_col_id')
check(lam_src && const_src, 'element_level_targets is extractable for the unit-level negative case', fails)
if lam_src && const_src
  $t_helper = { 'id' => 'h1', 'kind' => 'table', 'source' => { 'kind' => 'table', 'elementId' => 'master' },
                'columns' => [{ 'id' => 'h1-d', 'name' => 'Group', 'formula' => '[Master/Group]' }] }
  mk = lambda do |id, ws, src_id, dash = 'D'|
    { 'id' => id, 'kind' => 'bar-chart', 'name' => ws, 'source' => { 'kind' => 'table', 'elementId' => src_id },
      'columns' => [], '_dashboard' => dash, '_worksheet' => ws }
  end
  run_lambda = lambda do |els, intended_ids, pages_mode = nil|
    $t_els = els
    $t_pages_mode = pages_mode
    $t_warnings = []
    $t_intended = intended_ids.map do |i|
      el = els.find { |e| e['id'] == i }
      { 'element_id' => i, 'root' => 'master', 'dashboard' => el['_dashboard'], 'worksheet' => el['_worksheet'] }
    end
    Module.new.module_eval(<<~RUBY)
      norm_cap = ->(s) { s.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '') }
      helpers_by_id = { 'h1' => $t_helper }
      elements = $t_els
      warnings = $t_warnings
      opts = { master_id: 'master', pages_mode: $t_pages_mode }
      #{const_src}
      #{lam_src}
      element_level_targets.call('Region', { 'id' => 'm-region', 'name' => 'Region' }, 'region', $t_intended,
                                 [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-region' }])
    RUBY
  end
  a = mk.call('a', 'A', 'h1')
  b = mk.call('b', 'B', 'h1')
  plan_ok = run_lambda.call([a, b], %w[a b])
  check(plan_ok[:targets] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'h1' }, 'columnId' => 'f-region-h1' }] &&
        plan_ok[:reached] == 2 && plan_ok[:kept_roots].empty? &&
        plan_ok[:pending].map { |_e, c| c } == [{ 'id' => 'f-region-h1', 'name' => 'Region', 'formula' => '[Master/Region]', 'hidden' => true }],
        "two intended charts on one helper -> ONE helper target + one hidden column (got #{plan_ok[:targets].inspect})", fails)
  plan_bad = run_lambda.call([a, b], %w[a])
  check(plan_bad[:targets] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-region' }] &&
        plan_bad[:kept_roots] == ['master'] && plan_bad[:pending].empty? && plan_bad[:reached].zero?,
        "helper shared with an out-of-scope chart keeps the root target, adds no column (got #{plan_bad[:targets].inspect})", fails)
  # page-per-dashboard: one helper feeding the SAME worksheet on two pages must not
  # be targeted by a per-page control (it would filter the other page's chart too).
  a2 = mk.call('a', 'A', 'h1', 'Page 2')
  plan_pages = run_lambda.call([a, a2], %w[a a], :dashboard)
  check(plan_pages[:targets] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-region' }] &&
        plan_pages[:pending].empty? && $t_warnings.any? { |w| w.include?("hidden helper 'h1'") && w.include?('Page 2') && w.include?('D') },
        'a helper whose consumers sit on two pages keeps the root target and warns naming helper + pages', fails)
  plan_one = run_lambda.call([a], %w[a], :dashboard)
  check(plan_one[:targets].first.dig('source', 'elementId') == 'h1', 'a single-page helper is still targeted in page mode', fails)
end
# The INCLUDE key resolves to the master caption (as it does over a published
# datasource with GUID column names), so the helper already holds an "Order
# Channel" GROUPING column: the hidden filter column is named "(filter)" instead
# of the control falling back to the master root.
inc = run_pipeline(FIXTURE_TEXT.gsub('{INCLUDE [ORDER_CHANNEL] : SUM([NET_REVENUE])}', '{INCLUDE [Order Channel] : SUM([Net Revenue])}'))
inc_ctl = (inc[:specs] || []).find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
inc_h = (inc[:data] || []).find { |e| e['id'] == 'el-group-average-lod-src' }
check(inc_h && (inc_h['columns'] || []).any? { |c| c['name'] == 'Order Channel' && c['id'] != 'f-order-channel-el-group-average-lod-src' },
      'variant: the INCLUDE helper carries its own Order Channel grouping key', fails)
check(inc_h && (inc_h['columns'] || []).find { |c| c['id'] == 'f-order-channel-el-group-average-lod-src' }&.values_at('name', 'formula', 'hidden') ==
        ['Order Channel (filter)', '[Master/Order Channel]', true],
      'variant: the hidden filter column is named "Order Channel (filter)"', fails)
check(inc_ctl && inc_ctl['filters'].map { |t| t.dig('source', 'elementId') } == %w[el-revenue-trend el-group-average-lod-src] &&
        !inc[:log].include?('will ALSO filter'),
      "variant: the control still targets the trend chart and the helper exactly (got #{inc_ctl && inc_ctl['filters'].inspect})", fails)

puts
puts 'Part 3 - Feature 2: chart tooltip fields'
rt = chart.call('el-revenue-trend')
tt_ids = %w[tt-gross-revenue-el-revenue-trend tt-net-profit-el-revenue-trend tt-channel-group-el-revenue-trend]
check(rt['tooltip'] == { 'columns' => tt_ids.map { |i| { 'id' => i } } }, "tooltip lists the three added columns (got #{rt['tooltip'].inspect})", fails)
check(colf.call(rt, tt_ids[0]) == { 'id' => tt_ids[0], 'name' => 'Gross Revenue', 'formula' => 'Sum([Master/Gross Revenue])' } &&
      colf.call(rt, tt_ids[1]) == { 'id' => tt_ids[1], 'name' => 'Net Profit', 'formula' => 'Sum([Master/Net Profit])' },
      'measure tooltip fields are Sum([Master/…])', fails)
check(colf.call(rt, tt_ids[2]) == { 'id' => tt_ids[2], 'name' => 'Channel Group',
                                    'formula' => 'If(CountDistinct([Master/Channel Group]) = 1, Min([Master/Channel Group]), "*")' },
      'an ATTR string dimension is If(CountDistinct(x) = 1, Min(x), "*")', fails)
check((rt['columns'] || []).count { |c| c['name'] == 'Order Date' } == 1 && (rt['columns'] || []).count { |c| c['name'] == 'Net Revenue' } == 1,
      'the week and Net Revenue tooltip refs are skipped (already on the chart)', fails)
check(rt.dig('xAxis', 'columnId') == 'x-el-revenue-trend' && rt.dig('yAxis', 'columnIds') == ['y-el-revenue-trend'],
      'tooltip columns are on no axis', fails)
check(flat[:log].lines.any? { |l| l.start_with?('  NOTE') && l.include?("'Revenue Trend' custom tooltip: added 3 hover field(s)") },
      'NOTE reports the added tooltip fields', fails)
check(chart.call('el-channel-mix')['tooltip'].nil? && chart.call('el-channel-bar')['tooltip'].nil?, 'charts without tooltip fields get no tooltip', fails)
ai = (flat[:auto] || {})['interactions'] || []
ctt = ai.find { |a| a['kind'] == 'custom-tooltip' }
check(ctt == { 'kind' => 'custom-tooltip', 'caption' => 'Revenue Trend', 'fields_added' => ['Gross Revenue', 'Net Profit', 'Channel Group'], 'fields_unresolved' => [] },
      "auto-interactions.json records the tooltip (got #{ctt.inspect})", fails)
# Unresolved field (Breakdown is not a master column) + dimension on none: + helper-sourced chart.
unres = FIXTURE_TEXT.sub('<run>Week of </run>',
                         "<run>Week of </run><run>&lt;[federated.dtscope0001].[none:Calculation_303:nk]&gt;</run>" \
                         "<run>&lt;[federated.dtscope0001].[none:ORDER_CHANNEL:nk]&gt;</run>")
ur = run_pipeline(unres)
urt = (ur[:specs] || []).find { |e| e['id'] == 'el-revenue-trend' }
check(ur[:log].lines.any? { |l| l.start_with?('  WARN') && l.include?('custom tooltip field(s) Breakdown NOT added') },
      'an unresolved tooltip field is one WARN naming it', fails)
check(((ur[:coverage] || {})['unresolved'] || []).any? { |u| u['visual'] == 'Revenue Trend' && u['severity'] == 'approximated' },
      'the unresolved tooltip field lands in coverage.json as approximated', fails)
uctt = ((ur[:auto] || {})['interactions'] || []).find { |a| a['kind'] == 'custom-tooltip' }
check(uctt && uctt['fields_unresolved'] == ['Breakdown'] && uctt['fields_added'].include?('Order Channel'),
      'the sidecar keeps Breakdown as unresolved and Order Channel as added', fails)
check(colf.call(urt, 'tt-order-channel-el-revenue-trend') &&
      urt['tooltip']['columns'].map { |c| c['id'] }.include?('tt-order-channel-el-revenue-trend'),
      'a plain dimension tooltip field is added with the ATTR form', fails)
uoc = (ur[:specs] || []).find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
check(uoc && uoc['filters'].include?({ 'source' => { 'kind' => 'table', 'elementId' => 'el-revenue-trend' }, 'columnId' => 'f-order-channel-el-revenue-trend' }) &&
      colf.call(urt, 'f-order-channel-el-revenue-trend')['name'] == 'Order Channel (filter)',
      'a tooltip column that holds the name does not break the exact filter scope (column renamed "(filter)")', fails)
ug = run_pipeline(FIXTURE_TEXT.sub("<mark class='Bar' />\n            <encodings>", "<mark class='Bar' />\n            <encodings>")
                             .sub(%r{(<worksheet name='Group Average'>.*?)(<mark class='Bar' />)}m,
                                  "\\1\\2<encodings><tooltip column='[federated.dtscope0001].[sum:NET_REVENUE:qk]' /></encodings>")
                             .sub(%r{(<worksheet name='Group Average'>.*?)(<column-instance column='\[Group Average\]')}m,
                                  "\\1<column-instance column='[NET_REVENUE]' derivation='Sum' name='[sum:NET_REVENUE:qk]' pivot='key' type='quantitative' />\n            \\2"))
check(ug[:log].lines.any? { |l| l.start_with?('  WARN') && l.include?("'Group Average' custom tooltip field(s) Net Revenue NOT added") },
      'a helper-sourced chart skips its tooltip fields with a WARN', fails)
ugt = ((ug[:auto] || {})['interactions'] || []).find { |a| a['kind'] == 'custom-tooltip' && a['caption'] == 'Group Average' }
check(ugt && ugt['fields_added'] == [] && ugt['fields_unresolved'] == ['Net Revenue'], 'and records them as unresolved', fails)

puts
# Tableau's view CSV also exports Tooltip-shelf measures, and may put one BEFORE
# the plotted measure: the chart must still plot its Rows measure (Net Revenue),
# with the tooltip field (Gross Revenue) as a hover column.
tcsv = run_pipeline(FIXTURE_TEXT, csvs: {
                      'Revenue Trend' => "Week of Order Date,Gross Revenue,Sum of Net Revenue\n\"July 7, 2024\",75.96,73.49\n"
                    })
trc = (tcsv[:specs] || []).find { |e| e['id'] == 'el-revenue-trend' }
ycol = trc && trc['columns'].find { |c| c['id'] == trc.dig('yAxis', 'columnIds', 0) }
check(ycol && ycol['name'] == 'Net Revenue' && ycol['formula'] == 'Sum([Master/Net Revenue])',
      "a Tooltip-shelf measure listed first in the view CSV is not plotted (y = #{ycol && ycol.values_at('name', 'formula').inspect})", fails)
check(trc && trc['columns'].any? { |c| c['id'] == 'tt-gross-revenue-el-revenue-trend' } &&
        tcsv[:log].include?("'Revenue Trend' plots 'Sum of Net Revenue' (its Rows/Columns measure)"),
      'the tooltip field stays a hover column and the swap is logged', fails)

puts 'Part 4 - Feature 3: drill control from the drill path'
# The orchestrator always builds with --page-per-dashboard; the flat element
# output has no master_calc_columns channel, so a derived level (Breakdown)
# cannot be carried there and the drill control is withheld with a NOTE.
check(specs.none? { |e| e['kind'] == 'control' && e['controlType'] == 'drill' } &&
      flat[:log].include?("drill path 'Channel Hierarchy' (Channel Group > Breakdown) needs a derived master column for Breakdown"),
      'flat output withholds a drill control whose level needs a derived master column', fails)
p4 = run_pipeline(FIXTURE_TEXT, ['--page-per-dashboard'])
specs4 = p4[:ok] ? p4[:specs]['pages'].flat_map { |pg| pg['elements'] } : []
chart4 = ->(id) { specs4.find { |e| e['id'] == id } }
ai4 = ((p4[:auto] || {})['interactions'] || [])
check(((p4[:specs] || {})['master_calc_columns'] || []).any? { |c| c['id'] == 'm-drill-breakdown' },
      'page output carries the derived master category column', fails)
dc = specs4.find { |e| e['kind'] == 'control' && e['controlType'] == 'drill' }
check(dc && dc.reject { |k, _| k == 'targets' } ==
      { 'id' => 'el-drill-channel-hierarchy-channel-review', 'kind' => 'control', 'controlId' => 'drill-channel-hierarchy-channel-review', 'controlType' => 'drill',
        'name' => 'Channel Hierarchy',
        'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-channel_group' },
        'categories' => [{ 'columnId' => 'm-channel_group' }, { 'columnId' => 'm-drill-breakdown' }] },
      "drill control shape (got #{dc && dc.reject { |k, _| k == 'targets' }.inspect})", fails)
check(dc && dc['targets'] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-channel-bar' },
                                'columnIds' => ['x-el-channel-bar', 'dl-channel-hierarchy-2-el-channel-bar'] }],
      "the only drill target is the Channel Bar chart (pivot, helper-sourced and non-level charts are not) (got #{dc && dc['targets'].inspect})", fails)
cb = chart4.call('el-channel-bar')
sw = colf.call(cb, 'dl-channel-hierarchy-2-el-channel-bar')
check(sw && sw['name'] == 'Breakdown' &&
      sw['formula'] == 'Switch([ctl-param-breakdown-by-channel-review], "Order Channel", [Order Channel], "Channel Group", [Channel Group])',
      "level 2 is the parameter Switch over the control id (got #{sw && sw['formula']})", fails)
check(colf.call(cb, 'dl-channel-hierarchy-sib-order-channel-el-channel-bar')&.fetch('formula') == '[Master/Order Channel]',
      'the Switch branch sibling column is added', fails)
check(cb.dig('xAxis', 'columnId') == 'x-el-channel-bar' && cb.dig('yAxis', 'columnIds') == ['y-el-channel-bar'],
      'the level columns are on no axis (axis-less)', fails)
check(specs4.any? { |e| e['kind'] == 'control' && e['controlId'] == 'ctl-param-breakdown-by-channel-review' }, 'the Breakdown By parameter control is emitted', fails)
check(p4[:log].lines.any? { |l| l.start_with?('  NOTE') && l.include?("drill path 'Channel Hierarchy' → Sigma drill control") },
      'one NOTE for the emitted drill control', fails)
check(p4[:log].include?("'Group Average' plots a drill level but is sourced from 'el-group-average-lod-src'"),
      'the helper-sourced level chart is reported, not targeted', fails)
drec = ((p4[:scope] || {})['controls'] || []).find { |r| r['controlId'] == 'drill-channel-hierarchy-channel-review' }
check(drec && drec['scope'] == ['el-channel-bar'], 'control-scope.json allowlists the drill target chart', fails)
check(ControlLint.lint(lint_spec(p4[:specs]), scope: p4[:scope]).empty?, 'control lint is clean with the drill control (targets count as wiring)', fails)
check(p4[:layout_xml].to_s.include?('elementId="el-drill-channel-hierarchy-channel-review"'), 'the layout stage places the drill control', fails)
# pivot: off-shelf level columns + pivot-collapse record
cp = chart4.call('el-channel-pivot')
check(cp['kind'] == 'pivot-table' && colf.call(cp, 'dl-channel-hierarchy-2-el-channel-pivot') &&
      !cp['rowsBy'].to_s.include?('dl-') && !cp['columnsBy'].to_s.include?('dl-') && !cp['values'].to_s.include?('dl-'),
      'the pivot gets the level-2 column off-shelf', fails)
pcr = ai4.find { |a| a['kind'] == 'pivot-collapse' }
check(pcr == { 'kind' => 'pivot-collapse', 'caption' => 'Channel Hierarchy', 'worksheet' => 'Channel Pivot', 'dashboard' => 'Channel Review',
               'element_id' => 'el-channel-pivot',
               'levels' => [{ 'name' => 'Channel Group', 'column_id' => 'p-el-channel-pivot-row-channel-group' },
                            { 'name' => 'Breakdown', 'column_id' => 'dl-channel-hierarchy-2-el-channel-pivot' }] },
      "auto-interactions.json records the pivot-collapse step (got #{pcr.inspect})", fails)
dri = ai4.find { |a| a['kind'] == 'drill-hierarchy' }
check(dri && dri['caption'] == 'Channel Hierarchy' && dri['targets'] == ['Channel Bar'] &&
      dri['manual_worksheets'] == ['Channel Pivot', 'Group Average'] && dri['pivot_worksheets'] == ['Channel Pivot'],
      "auto-interactions.json lists the built drill; the pivot AND the untargeted helper-sourced chart are manual (got #{dri.inspect})", fails)
gd = p4[:guide]
check(gd && gd[:md].include?('## Built automatically') && gd[:md].include?("Tooltip fields on 'Revenue Trend'") &&
      gd[:md].include?("Drill hierarchy 'Channel Hierarchy'"),
      'the guide lists the auto-built drill and tooltip', fails)
check(gd && gd[:ledger]['residue'].map { |e| e['kind'] } == ['drill-hierarchy'] && gd[:ledger]['detectedCount'] == 1 &&
      gd[:ledger]['emitted'].empty? && gd[:ledger]['detectedCount'] == gd[:ledger]['emitted'].size + gd[:ledger]['residue'].size,
      'the ledger keeps only the pivot drill entry (conservation holds, emitted untouched)', fails)
check(gd && gd[:md].include?("add Breakdown under Channel Group on the pivot's Rows and collapse it to the first level; the workbook spec cannot store the collapsed state.") &&
      gd[:md].include?("If the Sigma MCP is connected, the migration's pivot-collapse step does this automatically."),
      'the kept drill entry carries the pivot wording and the MCP note', fails)
# only pivot/table plot a level -> no drill control, pivot columns + record still emitted
only_pivot = FIXTURE_TEXT.sub("<cols>[federated.dtscope0001].[none:Calculation_301:nk]</cols>\n      </table>\n    </worksheet>\n  </worksheets>",
                              "<cols>[federated.dtscope0001].[none:ORDER_CHANNEL:nk]</cols>\n      </table>\n    </worksheet>\n  </worksheets>")
op = run_pipeline(only_pivot)
check(op[:ok] && (op[:specs] || []).none? { |e| e['controlType'] == 'drill' }, 'a path whose only targets are pivots emits NO drill control', fails)
oai = (op[:auto] || {})['interactions'] || []
check(oai.none? { |a| a['kind'] == 'drill-hierarchy' } && oai.any? { |a| a['kind'] == 'pivot-collapse' },
      'and is not listed as built (pivot-collapse record only)', fails)
check(op[:guide] && op[:guide][:ledger]['residue'].any? { |e| e['kind'] == 'drill-hierarchy' } &&
      !op[:guide][:md].include?("Drill hierarchy 'Channel Hierarchy'"),
      'the guide keeps the drill-hierarchy entry manual', fails)

puts
puts 'Part 5 - --page-per-dashboard (dashboard duplicated): ids follow the rename'
dash_block = FIXTURE_TEXT[/    <dashboard name='Channel Review'>.*?<\/dashboard>\n/m]
two = FIXTURE_TEXT.sub('</dashboards>', dash_block.sub('Channel Review', 'Second View') + '  </dashboards>')
pd = run_pipeline(two, ['--page-per-dashboard'])
check(pd[:ok] && pd[:specs].is_a?(Hash) && pd[:specs]['pages'].size == 2, 'two-dashboard page pipeline ran', fails)
if pd[:ok] && pd[:specs].is_a?(Hash)
  pages = pd[:specs]['pages']
  all_ids = pages.flat_map { |pg| pg['elements'].map { |e| e['id'] } } + Array(pd[:specs]['data_elements']).map { |e| e['id'] } + ['master']
  dangling = []
  pages.each do |pg|
    pg['elements'].select { |e| e['kind'] == 'control' }.each do |c|
      (Array(c['filters']) + Array(c['targets'])).each do |t|
        tid = t.dig('source', 'elementId')
        dangling << [c['id'], tid] unless all_ids.include?(tid)
        cols = (pg['elements'] + Array(pd[:specs]['data_elements'])).find { |e| e['id'] == tid }&.fetch('columns', nil)
        next unless cols && tid != 'master'
        Array(t['columnId'] ? [t['columnId']] : t['columnIds']).compact.each do |cid|
          dangling << [c['id'], tid, cid] unless cols.any? { |col| col['id'] == cid }
        end
      end
    end
  end
  check(dangling.empty?, "every control target element and column id exists (dangling: #{dangling.inspect})", fails)
  p2 = pages.find { |pg| pg['name'] == 'Second View' }
  p1 = pages.find { |pg| pg['name'] == 'Channel Review' }
  d2 = p2['elements'].find { |e| e['controlType'] == 'drill' }
  check(d2 && d2['targets'] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-channel-bar-second-view' },
                                  'columnIds' => ['x-el-channel-bar-second-view', 'dl-channel-hierarchy-2-el-channel-bar-second-view'] }],
        "Second View's drill control targets that page's renamed chart + level columns (got #{d2 && d2['targets'].inspect})", fails)
  d1 = p1['elements'].find { |e| e['controlType'] == 'drill' }
  check(d1 && d1['targets'].first.dig('source', 'elementId') == 'el-channel-bar' && d1['controlId'] != d2['controlId'],
        'the first page keeps the original ids and the controlIds are page-unique', fails)
  [p1, p2].each do |pg|
    param = pg['elements'].find { |e| e['kind'] == 'control' && e['name'] == 'Breakdown By' }
    sw_el = pg['elements'].find { |e| e['id'].start_with?('el-channel-bar') }
    sw_col = (sw_el['columns'] || []).find { |c| c['name'] == 'Breakdown' }
    check(param && sw_col && sw_col['formula'].include?("[#{param['controlId']}]"),
          "#{pg['name']}: the parameter control stays and the Breakdown level formula names this page's control id", fails)
  end
  # The helper is shared by both pages' Group Average charts: no page's control may
  # target it (that would filter the other page too) — the root fallback + a warning stay.
  oc1 = p1['elements'].find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
  oc2 = p2['elements'].find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
  helper_targets = [oc1, oc2].flat_map { |c| Array(c['filters']) }.select { |t| t.dig('source', 'elementId') == 'el-group-average-lod-src' }
  check(helper_targets.empty?, "no helper target is shared by two pages' controls (got #{helper_targets.inspect})", fails)
  check(oc2 && oc2['filters'] == [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-order_channel' }],
        "Second View's Order Channel control keeps the master root target (got #{oc2 && oc2['filters'].inspect})", fails)
  check(pd[:log].include?("hidden helper 'el-group-average-lod-src' feeds charts on several pages (Channel Review, Second View)"),
        'the shared helper is named with its pages in a warning', fails)
  check(pd[:log].include?('will ALSO filter'), 'and the over-filter warning stays', fails)
  check(Array(pd[:specs]['master_calc_columns']).any? { |c| c['id'] == 'm-drill-breakdown' && c['formula'] == 'Switch("Order Channel", "Order Channel", [Order Channel], "Channel Group", [Channel Group])' },
        'the derived Breakdown category column rides master_calc_columns, frozen to the parameter default (no control id)', fails)
  rt2 = p2['elements'].find { |e| e['id'] == 'el-revenue-trend-second-view' }
  check(rt2 && rt2['tooltip']['columns'].map { |c| c['id'] }.all? { |i| i.end_with?('el-revenue-trend-second-view') && (rt2['columns'] || []).any? { |c| c['id'] == i } },
        'tooltip column ids follow the element rename', fails)
  pcs = ((pd[:auto] || {})['interactions'] || []).select { |a| a['kind'] == 'pivot-collapse' }
  check(pcs.map { |a| a['element_id'] }.sort == %w[el-channel-pivot el-channel-pivot-second-view] &&
        pcs.find { |a| a['element_id'] == 'el-channel-pivot-second-view' }['levels'].last['column_id'] == 'dl-channel-hierarchy-2-el-channel-pivot-second-view',
        'one pivot-collapse record per page with the final renamed element and column ids', fails)
  check(ControlLint.lint(lint_spec(pd[:specs]), scope: pd[:scope]).empty?,
        "control lint clean on the two-page workbook (#{ControlLint.lint(lint_spec(pd[:specs]), scope: pd[:scope]).inspect})", fails)
end
single = run_pipeline(FIXTURE_TEXT, ['--page-per-dashboard'])
check(single[:ok] && ControlLint.lint(lint_spec(single[:specs]), scope: single[:scope]).empty?,
      'single-dashboard page mode: control lint clean', fails)
check(single[:ok] && single[:specs]['pages'][0]['elements'].any? { |e| e['kind'] == 'control' && e['name'] == 'Breakdown By' },
      'single-dashboard page mode keeps the Breakdown By parameter control (a drill-level formula consumes it)', fails)

puts
puts 'Part 6 - drill coverage honesty, duplicate names, quotes, parser twins'
dp_block_re = %r{      <drill-paths>.*?</drill-paths>\n}m
drill_variant = lambda do |paths_xml|
  FIXTURE_TEXT.sub(dp_block_re, "      <drill-paths>\n#{paths_xml}      </drill-paths>\n")
end
orig_path = "        <drill-path name='Channel Hierarchy'>\n          <field>[Calculation_301]</field>\n          <field>[Calculation_303]</field>\n        </drill-path>\n"
extra_path = lambda do |name, f2|
  "        <drill-path name='#{name}'>\n          <field>[Calculation_301]</field>\n          <field>#{f2}</field>\n        </drill-path>\n"
end
ctl_of = ->(r) { ((r[:specs] || {})['pages'] || []).flat_map { |pg| pg['elements'] }.select { |e| e['controlType'] == 'drill' } }

# (2) a pivot that no longer plots a level: the helper-sourced Group Average is the manual sheet
np = FIXTURE_TEXT.sub(%r{(<worksheet name='Channel Pivot'>.*?)<rows>\[federated.dtscope0001\].\[none:Calculation_301:nk\]</rows>}m,
                      "\\1<rows>[federated.dtscope0001].[none:ORDER_CHANNEL:nk]</rows>")
              .sub(%r{(<worksheet name='Channel Pivot'>.*?)<cols>.*?</cols>}m, "\\1<cols />")
npr = run_pipeline(np, ['--page-per-dashboard'])
nai = ((npr[:auto] || {})['interactions'] || []).find { |a| a['kind'] == 'drill-hierarchy' }
check(nai && nai['manual_worksheets'] == ['Group Average'] && nai['pivot_worksheets'] == [] && nai['targets'] == ['Channel Bar'],
      "an untargeted helper-sourced chart is listed as manual even with no pivot (got #{nai.inspect})", fails)
gres = (npr[:guide] || {}).dig(:ledger, 'residue') || []
gdrill = gres.find { |e| e['kind'] == 'drill-hierarchy' }
check(gdrill && gdrill['ui_steps'].include?('Group Average') && !gdrill['ui_steps'].include?("pivot's Rows") &&
      !gdrill['ui_steps'].include?('pivot-collapse'),
      'the guide keeps a manual drill entry naming Group Average, without the pivot-Rows instruction', fails)
check(((npr[:auto] || {})['interactions'] || []).none? { |a| a['kind'] == 'pivot-collapse' }, 'no pivot-collapse record once the pivot plots no level', fails)

# (5) a chart plotting only a lower level is not targeted
lo = FIXTURE_TEXT.sub(%r{(<worksheet name='Channel Mix'>.*?)(<column-instance column='\[ORDER_CHANNEL\]' derivation='None' name='\[none:ORDER_CHANNEL:nk\]' pivot='key' type='nominal' />)}m,
                      "\\1\\2\n            <column-instance column='[Calculation_303]' derivation='None' name='[none:Calculation_303:nk]' pivot='key' type='nominal' />")
        .sub(%r{(<worksheet name='Channel Mix'>.*?)<cols>.*?</cols>}m, "\\1<cols>[federated.dtscope0001].[none:Calculation_303:nk]</cols>")
lop = run_pipeline(lo, ['--page-per-dashboard'])
lod = ctl_of.call(lop)
check(lod.size == 1 && lod.first['targets'].map { |t| t.dig('source', 'elementId') } == ['el-channel-bar'],
      'a chart plotting only a lower level (Breakdown) gets no drill target', fails)
loai = ((lop[:auto] || {})['interactions'] || []).find { |a| a['kind'] == 'drill-hierarchy' }
check(loai && loai['manual_worksheets'].include?('Channel Mix') && !loai['pivot_worksheets'].include?('Channel Mix'),
      'and is listed as a manual (non-pivot) worksheet', fails)
check(lop[:log].include?("'Channel Mix' plots only a lower level"), 'with a warning naming it', fails)
check((lop[:specs]['pages'].flat_map { |pg| pg['elements'] }.find { |e| e['id'] == 'el-channel-mix' }['columns'] || []).none? { |c| c['id'].start_with?('dl-') },
      'the lower-level chart gets no level-1 column', fails)

# (3) duplicate path names + a name with no ASCII word characters
dup = drill_variant.call(orig_path + extra_path.call('Channel Hierarchy', '[ORDER_CHANNEL]') + extra_path.call('階層', '[ORDER_CHANNEL]'))
dr = run_pipeline(dup, ['--page-per-dashboard'])
dctl = ctl_of.call(dr)
check(dctl.map { |c| c['controlId'] } == %w[drill-channel-hierarchy-channel-review drill-channel-hierarchy-2-channel-review drill-path-3-channel-review],
      "same-named paths and a non-ASCII name each emit a distinctly-identified control (got #{dctl.map { |c| c['controlId'] }.inspect})", fails)
check(dctl.map { |c| c['name'] } == ['Channel Hierarchy', 'Channel Hierarchy', '階層'], 'control names keep the path names', fails)
check(dctl.all? { |c| c['targets'].map { |t| t.dig('source', 'elementId') } == ['el-channel-bar'] }, 'each targets Channel Bar', fails)
check(ControlLint.lint(lint_spec(dr[:specs]), scope: dr[:scope]).empty?, 'control lint clean with three drill controls', fails)
# the guide matches auto records by caption + levels, not caption alone
half = drill_variant.call(orig_path + extra_path.call('Channel Hierarchy', '[Calculation_999]'))
hr = run_pipeline(half, ['--page-per-dashboard'])
check(ctl_of.call(hr).size == 1 && hr[:log].include?("drill path 'Channel Hierarchy' NOT emitted as a drill control"),
      'the second same-named path that cannot resolve a level warns and is not emitted', fails)
hres = ((hr[:guide] || {})[:ledger] || {})['residue'] || []
hd = hres.select { |e| e['kind'] == 'drill-hierarchy' }
check(hd.size == 2 && hd.count { |e| e['ui_steps'].start_with?('A Sigma drill control was built') } == 1 &&
      hd.find { |e| e['ui_steps'].start_with?('A Sigma drill control was built') }['fields'].last == 'Breakdown',
      'the guide marks only the path whose levels match the built record (the other stays fully manual)', fails)
# a path that cannot emit at all always warns (a one-level path here)
one = drill_variant.call("        <drill-path name='Solo'>\n          <field>[Calculation_301]</field>\n        </drill-path>\n")
check(run_pipeline(one, ['--page-per-dashboard'])[:log].include?("drill path #1 'Solo' has 1 level(s)"),
      'a path with fewer than two levels is warned about, not skipped silently', fails)

# (6) an apostrophe inside a double-quoted CASE value must survive
q = FIXTURE_TEXT.sub("WHEN &apos;Order Channel&apos; THEN [ORDER_CHANNEL] WHEN &apos;Channel Group&apos; THEN [Calculation_301]",
                     "WHEN &quot;Men&apos;s&quot; THEN [ORDER_CHANNEL] WHEN &quot;Kids&apos;&quot; THEN [Calculation_301]")
qr = run_pipeline(q, ['--page-per-dashboard'])
qcb = qr[:ok] ? qr[:specs]['pages'].flat_map { |pg| pg['elements'] }.find { |e| e['id'] == 'el-channel-bar' } : nil
qsw = qcb && (qcb['columns'] || []).find { |c| c['name'] == 'Breakdown' }
check(qsw && qsw['formula'] == 'Switch([ctl-param-breakdown-by-channel-review], "Men\'s", [Order Channel], "Kids\'", [Channel Group])',
      "apostrophes inside double-quoted CASE values are kept (got #{qsw && qsw['formula']})", fails)

# (8c) every <drill-paths> block is read, in both parser twins
two_blocks = FIXTURE_TEXT.sub(dp_block_re) do |m|
  m + "      <drill-paths>\n#{extra_path.call('Second Block', '[ORDER_CHANNEL]')}      </drill-paths>\n"
end
tb = run_pipeline(two_blocks)
check((tb[:meta] || {})['drill_paths'].to_a.map { |d| d['name'] } == ['Channel Hierarchy', 'Second Block'],
      'Ruby parser reads both <drill-paths> blocks', fails)
Dir.mktmpdir do |d|
  File.write(File.join(d, 'wb.twb'), two_blocks)
  _o, st = Open3.capture2e('python3', PARSER_PY, File.join(d, 'wb.twb'), File.join(d, 'py-layout.json'))
  pm = st.success? ? JSON.parse(File.read(File.join(d, 'py-layout-meta.json'))) : {}
  check(pm['drill_paths'] == (tb[:meta] || {})['drill_paths'], 'Python parser reads both blocks and matches Ruby', fails)
end

puts
puts 'Part 7 - derived drill columns never collide by name'
# A second hierarchy (Order Channel > a level ALSO captioned "Breakdown", with a
# different formula; Channel Mix plots its first level) must get its own master
# column, id and name, not reuse the first hierarchy's Switch.
calc2 = "      <column caption='Breakdown' datatype='string' name='[Calculation_304]' role='dimension' type='nominal'>\n" \
        "        <calculation class='tableau' formula='CASE [Parameters].[Parameter 1] WHEN &apos;Order Channel&apos; THEN [ORDER_CHANNEL] ELSE &apos;All&apos; END' />\n" \
        "      </column>\n"
two_paths = FIXTURE_TEXT
            .sub("      <drill-paths>", calc2 + "      <drill-paths>")
            .sub("        </drill-path>\n      </drill-paths>",
                 "        </drill-path>\n        <drill-path name='Channel Hierarchy B'>\n          <field>[ORDER_CHANNEL]</field>\n" \
                 "          <field>[Calculation_304]</field>\n        </drill-path>\n      </drill-paths>")
tp = run_pipeline(two_paths, ['--page-per-dashboard'])
mcc = ((tp[:specs] || {})['master_calc_columns'] || []).select { |c| c['_drill'] }
check(mcc.size == 2 && mcc.map { |c| c['id'] }.uniq.size == 2 && mcc.map { |c| c['name'] }.uniq.size == 2 &&
        mcc.map { |c| c['formula'] }.uniq.size == 2,
      "two same-named levels with different formulas get distinct master columns (got #{mcc.map { |c| c.values_at('id', 'name') }.inspect})", fails)
same = run_pipeline(FIXTURE_TEXT.sub("        </drill-path>\n      </drill-paths>",
                                     "        </drill-path>\n        <drill-path name='Channel Hierarchy C'>\n" \
                                     "          <field>[Calculation_301]</field>\n          <field>[Calculation_303]</field>\n" \
                                     "        </drill-path>\n      </drill-paths>"), ['--page-per-dashboard'])
smcc = ((same[:specs] || {})['master_calc_columns'] || []).select { |c| c['_drill'] }
check(smcc.size == 1, "two hierarchies on the SAME level formula share one master column (got #{smcc.map { |c| c['id'] }.inspect})", fails)
# An unbuilt drill path is a coverage gap (approximated), not a NOTE.
sev_src = File.read(BUILD)[/^def warning_severity\b.*?\nend\n/m]
eval(sev_src) # rubocop:disable Security/Eval
check(warning_severity("drill path 'X' (A > B) has no chart plotting a level — no drill control emitted") == :approximated &&
        warning_severity("drill path #1 'X' has 1 level(s) — no drill control emitted") == :approximated &&
        warning_severity("drill path 'X' NOT emitted as a drill control — level 'B': untranslatable") == :approximated &&
        warning_severity("drill path 'X': 'Sheet' plots only a lower level — not targeted") == :approximated,
      'unbuilt drill paths and untargeted drill charts are graded approximated', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
