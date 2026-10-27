#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for two Tableau -> Sigma fixes, driven end-to-end (offline)
# through the real parse-twb-layout.rb + build-charts-from-signals.rb +
# build-dashboard-layout.rb on scripts/fixtures/pivot-finish.twb:
#
#   1. Quick filters applied to SELECTED worksheets (`<filter filter-group='N'>`
#      per worksheet + one filter zone, no <shared-view>) used to vanish: auto
#      controls were built only from shared-view filters. Now every filter zone
#      not covered by a shared-view filter is promoted, scoped to the worksheets
#      that carry its filter-group. A root-level (master) target would also
#      filter every OTHER chart on that master, so the control targets the
#      intended CHART ELEMENTS instead (an existing plain column, or an extra
#      axis-less helper column on a master-sourced chart) = Tableau's exact
#      selected-worksheet scope; a master-sourced table takes the same column
#      with hidden:true. A root target + "will ALSO filter" warning stays only
#      where an element cannot take a column (see test-drill-tooltip-scope.rb).
#   2. A Tableau "info button" (Shape-mark sheet, empty shelves, tooltip-only
#      content) used to be dropped; it is now a Sigma icon-only button whose
#      hover text is the tooltip text, placed by the layout stage.
#
# Usage:  ruby scripts/test-filter-scope-info.rb
require 'json'
require 'rexml/document'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/control_lint'

DIR     = __dir__
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
LAYOUT  = File.join(DIR, 'build-dashboard-layout.rb')
FIXTURE = File.join(DIR, 'fixtures', 'pivot-finish.twb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MASTER_CAPTIONS = ['Order Date', 'Order Channel', 'Region', 'Net Revenue', 'Gross Revenue',
                   'Net Profit', 'Week Start', 'Profit Ratio', 'info'].freeze

# Parse + build one twb text in a tmpdir. Returns a result hash (parsed
# artifacts + the builder log), or { ok: false } when a stage failed.
def run_pipeline(twb_text, extra_args = [])
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    ok, perr = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: perr } unless File.exist?(lay)
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'Pivot Finish', 'hasExtracts' => false }))
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
    return { ok: File.exist?(out), log: log, specs: rd.call('chart-specs.json'),
             layout: rd.call('dashboard-layout.json'), meta: rd.call('dashboard-layout-meta.json'),
             scope: rd.call('control-scope.json'), coverage: rd.call('coverage.json') }
  end
end

FIXTURE_TEXT = File.read(FIXTURE, encoding: 'utf-8')

puts 'Part 1 - parser: filter-group + tooltip text signals'
base = run_pipeline(FIXTURE_TEXT)
check(base[:ok], 'pipeline ran on the fixture', fails)
ws = (base[:meta] || {})['worksheets'] || {}
fg = ->(w, col) { (ws.dig(w, 'filters') || []).find { |f| f['column_caption'] == col }&.dig('filter_group') }
check(fg.call('KPI Crosstab', 'Order Channel') == '3', 'KPI Crosstab Order Channel filter carries filter_group 3', fails)
check(fg.call('Revenue by Region', 'Order Channel') == '3', 'Revenue by Region Order Channel filter carries filter_group 3', fails)
check(fg.call('Revenue by Channel', 'Region') == '4', 'Revenue by Channel Region filter carries filter_group 4', fails)
check((ws.dig('KPI Crosstab', 'filters') || []).first.key?('filter_group') == false,
      'a filter without the attribute gets no filter_group key (byte-identical output)', fails)
tt = ws.dig('INFO Button - KPI', 'tooltip_text').to_s
check(tt.start_with?('Shows weekly revenue and margin'), 'tooltip_text starts with the first run', fails)
check(tt.include?("\n- Which channels grow week over week?"), 'tooltip_text keeps line breaks (Æ+newline -> \\n)', fails)
check(!tt.include?('Æ'), 'tooltip_text drops the Æ sentinel', fails)
check(!ws.dig('KPI Crosstab').key?('tooltip_text'), 'sheets without a tooltip carry no tooltip_text key', fails)

puts
puts 'Part 2 - filter-group quick filters become scoped controls'
specs = base[:specs] || []
controls = specs.select { |e| e['kind'] == 'control' }
oc = controls.find { |c| c['name'] == 'Order Channel' }
rg = controls.find { |c| c['name'] == 'Region' }
check(controls.size == 2, "exactly two controls emitted (got #{controls.map { |c| c['name'] }.inspect})", fails)
check(oc && oc['controlType'] == 'list' && oc['source'].dig('source', 'elementId') == 'master',
      'Order Channel is a list control sourced from the master', fails)
oc_filters = [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-kpi-crosstab' },
                'columnId' => 'p-el-kpi-crosstab-row-order-channel' },
              { 'source' => { 'kind' => 'table', 'elementId' => 'el-revenue-by-region' },
                'columnId' => 'f-order-channel-el-revenue-by-region' }]
rg_filters = [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-revenue-by-channel' },
                'columnId' => 'f-region-el-revenue-by-channel' }]
check(oc && oc['filters'] == oc_filters,
      "Order Channel targets its two intended charts directly (got #{oc && oc['filters'].inspect})", fails)
check(rg && rg['filters'] == rg_filters,
      "Region targets its one intended chart directly (got #{rg && rg['filters'].inspect})", fails)
check(controls.none? { |c| c['name'].to_s.empty? || c['name'] =~ /measure/i },
      'no control for the Measure Names filter', fails)
chart = ->(id) { specs.find { |e| e['id'] == id } }
helper_col = ->(id, col_id) { (chart.call(id)['columns'] || []).find { |c| c['id'] == col_id } }
check(helper_col.call('el-revenue-by-region', 'f-order-channel-el-revenue-by-region') ==
      { 'id' => 'f-order-channel-el-revenue-by-region', 'name' => 'Order Channel', 'formula' => '[Master/Order Channel]' },
      'Revenue by Region gets the axis-less Order Channel helper column', fails)
check(helper_col.call('el-revenue-by-channel', 'f-region-el-revenue-by-channel') ==
      { 'id' => 'f-region-el-revenue-by-channel', 'name' => 'Region', 'formula' => '[Master/Region]' },
      'Revenue by Channel gets the axis-less Region helper column', fails)
check((chart.call('el-kpi-crosstab')['columns'] || []).none? { |c| c['id'].start_with?('f-') },
      'KPI Crosstab already has a plain Order Channel column: no helper column added', fails)
check(chart.call('el-revenue-by-region').dig('xAxis', 'columnId') == 'x-el-revenue-by-region' &&
      chart.call('el-revenue-by-region').dig('yAxis', 'columnIds') == ['y-el-revenue-by-region'],
      'the helper column is on no axis', fails)
recs = ((base[:scope] || {})['controls'] || [])
roc = recs.find { |r| r['name'] == 'Order Channel' }
rrg = recs.find { |r| r['name'] == 'Region' }
check(roc && roc['filter_group'] == '3' &&
      roc['scope_worksheets'].sort == ['KPI Crosstab', 'Revenue by Region'],
      'Order Channel scope record: group 3, worksheets KPI Crosstab + Revenue by Region', fails)
check(roc && roc['intended'].map { |i| i['worksheet'] }.sort == ['KPI Crosstab', 'Revenue by Region'],
      'Order Channel intended set excludes Revenue by Channel', fails)
check(roc && roc['target_mode'] == 'elements' && !roc.key?('over_filtered') && !roc.key?('root_fallback'),
      'Order Channel record: target_mode elements, nothing over-filtered', fails)
check(rrg && rrg['filter_group'] == '4' && rrg['scope_worksheets'] == ['Revenue by Channel'] &&
      rrg['intended'].map { |i| i['worksheet'] } == ['Revenue by Channel'],
      'Region scope record: group 4, intended = Revenue by Channel only', fails)
check(rrg && rrg['target_mode'] == 'elements' && !rrg.key?('over_filtered'),
      'Region record: target_mode elements, nothing over-filtered', fails)
check(roc && roc['targets'] == oc_filters && rrg && rrg['targets'] == rg_filters,
      'the scope records carry the element-level targets', fails)
check(roc && roc['scope'] == %w[el-kpi-crosstab el-revenue-by-region] && rrg && rrg['scope'] == %w[el-revenue-by-channel],
      'sidecar scope allowlists exactly the intended chart ids', fails)
check(base[:log] =~ /'Order Channel' quick-filter control targets 2 chart\(s\) directly \(filter group 3\) — exact Tableau selected-worksheet scope/,
      'info note: Order Channel control targets 2 charts directly', fails)
check(base[:log] =~ /'Region' quick-filter control targets 1 chart\(s\) directly \(filter group 4\) — exact Tableau selected-worksheet scope/,
      'info note: Region control targets 1 chart directly', fails)
check(base[:log].lines.any? { |l| l.start_with?('  NOTE') && l.include?('targets 2 chart(s) directly') },
      'the direct-targeting message prints as NOTE (not WARN)', fails)
check(!base[:log].include?('will ALSO filter'), 'no "will ALSO filter" warning when nothing over-filters', fails)
check(((base[:coverage] || {})['unresolved'] || []).none? { |u| u['visual'] == 'Order Channel' && u['severity'] == 'approximated' },
      'no approximated coverage entry for the exactly-scoped controls', fails)

# Same fixture in the lint's eyes: element-level targets are live, scoped, reach-clean.
def lint_spec(specs_out)
  pages = specs_out.is_a?(Hash) ? specs_out['pages'] : [{ 'name' => 'Deep Dive', 'elements' => specs_out }]
  els = [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'source' => { 'kind' => 'data-model' } }]
  lay = '<Page id="data"><Element elementId="master"/></Page>'
  meta = [{ 'id' => 'data', 'name' => 'Data' }]
  pages.each_with_index do |pg, i|
    meta << { 'id' => "pg#{i}", 'name' => pg['name'] }
    lay += "<Page id=\"pg#{i}\">#{pg['elements'].map { |e| "<Element elementId=\"#{e['id']}\"/>" }.join}</Page>"
    els.concat(pg['elements'])
  end
  { 'pages' => meta, 'elements' => els, 'layout' => lay }
end
lv = ControlLint.lint(lint_spec(specs), scope: base[:scope])
check(lv.empty?, "control lint is clean on element-level targets (got #{lv.inspect})", fails)

puts
puts 'Part 2b - --page-per-dashboard keeps every element-level target valid'
def target_ids(out)
  els = out['pages'].flat_map { |pg| pg['elements'] }
  ids = els.map { |e| e['id'] }
  bad = els.select { |e| e['kind'] == 'control' }.flat_map { |c| (c['filters'] || []).map { |t| t.dig('source', 'elementId') } }
           .reject { |t| t == 'master' || ids.include?(t) }
  [els, bad]
end
pd = run_pipeline(FIXTURE_TEXT, ['--page-per-dashboard'])
check(pd[:ok] && pd[:specs].is_a?(Hash), 'page-per-dashboard pipeline ran', fails)
pels, pbad = target_ids(pd[:specs])
pctl = pels.select { |e| e['kind'] == 'control' }
check(pbad.empty?, "every control target elementId exists in the output (dangling: #{pbad.inspect})", fails)
check(pctl.map { |c| c['filters'] }.sort_by(&:to_s) == [oc_filters, rg_filters].sort_by(&:to_s),
      'single-dashboard page mode keeps the exact element targets', fails)
check(ControlLint.lint(lint_spec(pd[:specs]), scope: pd[:scope]).empty?, 'control lint clean in page-per-dashboard mode', fails)

# A worksheet reused on a second dashboard is id-suffixed on that page; the
# second page's control copies must follow the rename (own page's charts only).
two = FIXTURE_TEXT.sub('</dashboards>',
        FIXTURE_TEXT[/    <dashboard name='KPI Deep Dive'>.*?<\/dashboard>\n/m].sub('KPI Deep Dive', 'Second View') + '  </dashboards>')
pd2 = run_pipeline(two, ['--page-per-dashboard'])
check(pd2[:ok] && pd2[:specs].is_a?(Hash) && pd2[:specs]['pages'].size == 2, 'two-dashboard page pipeline ran', fails)
if pd2[:ok] && pd2[:specs].is_a?(Hash)
  _els2, bad2 = target_ids(pd2[:specs])
  check(bad2.empty?, "two dashboards: every control target elementId exists (dangling: #{bad2.inspect})", fails)
  p2 = pd2[:specs]['pages'].find { |pg| pg['name'] == 'Second View' }
  c2 = (p2['elements'] || []).find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
  check(c2 && c2['filters'] == [
          { 'source' => { 'kind' => 'table', 'elementId' => 'el-kpi-crosstab-second-view' },
            'columnId' => 'p-el-kpi-crosstab-second-view-row-order-channel' },
          { 'source' => { 'kind' => 'table', 'elementId' => 'el-revenue-by-region-second-view' },
            'columnId' => 'f-order-channel-el-revenue-by-region-second-view' }],
        "Second View's Order Channel control targets that page's renamed charts + helper column (got #{c2 && c2['filters'].inspect})", fails)
  rcol = (p2['elements'].find { |e| e['id'] == 'el-revenue-by-region-second-view' }['columns'] || [])
           .any? { |c| c['id'] == 'f-order-channel-el-revenue-by-region-second-view' }
  check(rcol, 'the renamed chart carries the renamed helper column', fails)
  p1 = pd2[:specs]['pages'].find { |pg| pg['name'] == 'KPI Deep Dive' }
  c1 = (p1['elements'] || []).find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
  check(c1 && c1['filters'] == oc_filters, 'first page keeps the original ids', fails)
  sc2 = ((pd2[:scope] || {})['controls'] || []).find { |r| r['controlId'].end_with?('second-view') && r['name'] == 'Order Channel' }
  check(sc2 && sc2['scope'] == %w[el-kpi-crosstab-second-view el-revenue-by-region-second-view],
        "sidecar scope for the second page names the renamed chart ids (got #{sc2 && sc2['scope'].inspect})", fails)
  check(ControlLint.lint(lint_spec(pd2[:specs]), scope: pd2[:scope]).empty?, 'control lint clean on the two-page workbook', fails)
end

# Two dashboards can expose the same caption from different filter groups.
# Each promoted control must stay on the dashboard whose zone resolved to it.
group_split = FIXTURE_TEXT
              .sub("column='[federated.pivfin0001].[none:REGION:nk]' filter-group='4'",
                   "column='[federated.pivfin0001].[none:ORDER_CHANNEL:nk]' filter-group='4'")
              .sub("level='[none:REGION:nk]' user:ui-enumeration='all'",
                   "level='[none:ORDER_CHANNEL:nk]' user:ui-enumeration='all'")
channel_dash = <<~XML
  <dashboard name='Channel View'>
    <size maxheight='900' maxwidth='1400' minheight='900' minwidth='1400' sizing-mode='fixed' />
    <zones>
      <zone h='8000' id='30' mode='checkdropdown' name='Revenue by Channel' param='[federated.pivfin0001].[none:ORDER_CHANNEL:nk]' type-v2='filter' values='relevant' w='18000' x='0' y='0' />
      <zone h='92000' id='31' name='Revenue by Channel' w='82000' x='18000' y='8000' />
    </zones>
  </dashboard>
XML
group_split = group_split.sub('</dashboards>', "#{channel_dash}  </dashboards>")
pd_groups = run_pipeline(group_split, ['--page-per-dashboard'])
check(pd_groups[:ok] && pd_groups[:specs].is_a?(Hash), 'different-group dashboard pipeline ran', fails)
if pd_groups[:ok] && pd_groups[:specs].is_a?(Hash)
  pd_groups[:specs]['pages'].each do |page|
    page_ids = page['elements'].map { |e| e['id'] }
    order_controls = page['elements'].select { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
    local_targets = order_controls.flat_map { |c| Array(c['filters']) }
                                  .map { |t| t.dig('source', 'elementId') }
                                  .all? { |id| id == 'master' || page_ids.include?(id) }
    check(order_controls.size == 1 && local_targets,
          "#{page['name']} gets only its filter group's control with page-local targets", fails)
  end
end

puts
puts 'Part 2c - a table takes a hidden filter column instead of falling back to the root'
# Revenue by Region as a Text-mark table: it renders every column, so the extra
# Order Channel column is added with hidden:true and targeted directly. The master
# root no longer has to carry the control, so Revenue by Channel stays unfiltered.
head2, tail2 = FIXTURE_TEXT.split("<worksheet name='Revenue by Region'>", 2)
tbl_text = head2 + "<worksheet name='Revenue by Region'>" + tail2.sub("<mark class='Bar' />", "<mark class='Text' />")
fb = run_pipeline(tbl_text)
fspecs = fb[:specs] || []
check(fspecs.find { |e| e['id'] == 'el-revenue-by-region' }&.dig('kind') == 'table',
      'variant: Revenue by Region is a table element', fails)
foc = fspecs.find { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
check(foc && foc['filters'] == oc_filters,
      "table element is targeted through its hidden column (got #{foc && foc['filters'].inspect})", fails)
check((fspecs.find { |e| e['id'] == 'el-revenue-by-region' }['columns'] || [])
        .find { |c| c['id'] == 'f-order-channel-el-revenue-by-region' } ==
      { 'id' => 'f-order-channel-el-revenue-by-region', 'name' => 'Order Channel',
        'formula' => '[Master/Order Channel]', 'hidden' => true },
      'the table gets the Order Channel column with hidden:true', fails)
check(!fb[:log].include?('will ALSO filter'), 'no over-filter warning once the table is targeted directly', fails)
frec = ((fb[:scope] || {})['controls'] || []).find { |r| r['name'] == 'Order Channel' }
check(frec && frec['target_mode'] == 'elements' && !frec.key?('over_filtered'),
      'record: target_mode elements, nothing over-filtered', fails)
# The Region control is unaffected by the variant: still exact.
frg = fspecs.find { |e| e['kind'] == 'control' && e['name'] == 'Region' }
check(frg && frg['filters'] == rg_filters, 'the Region control still targets its chart directly', fails)

puts
puts 'Part 2d - a second filter group on the same caption stays on its own dashboard'
# Revenue by Channel gains an Order Channel filter in group 5, and a second
# dashboard shows only that chart plus a zone resolving to group 5. Each control
# must land only on the dashboard whose zone belongs to its group: a group-3 copy
# on "Channel Only" would target the other page's charts.
g5_filter = "          <filter class='categorical' column='[federated.pivfin0001].[none:ORDER_CHANNEL:nk]' filter-group='5'>\n" \
            "            <groupfilter function='level-members' level='[none:ORDER_CHANNEL:nk]' user:ui-enumeration='all' user:ui-marker='enumerate' />\n" \
            "          </filter>\n"
head3, tail3 = FIXTURE_TEXT.split("<worksheet name='Revenue by Channel'>", 2)
tail3 = tail3.sub("          <slices>", g5_filter + "          <slices>")
chan_dash = <<~XML.gsub(/^/, '    ')
  <dashboard name='Channel Only'>
    <size maxheight='900' maxwidth='1400' minheight='900' minwidth='1400' sizing-mode='fixed' />
    <zones>
      <zone h='100000' id='101' type-v2='layout-basic' w='100000' x='0' y='0'>
        <zone h='8000' id='110' mode='checkdropdown' name='Revenue by Channel' param='[federated.pivfin0001].[none:ORDER_CHANNEL:nk]' type-v2='filter' values='relevant' w='18000' x='0' y='0' />
        <zone h='92000' id='123' name='Revenue by Channel' w='100000' x='0' y='8000' />
      </zone>
    </zones>
  </dashboard>
XML
g5_text = (head3 + "<worksheet name='Revenue by Channel'>" + tail3).sub('  </dashboards>', chan_dash + '  </dashboards>')
g5 = run_pipeline(g5_text, ['--page-per-dashboard'])
check(g5[:ok] && g5[:specs].is_a?(Hash) && g5[:specs]['pages'].size == 2, 'two-group page pipeline ran', fails)
if g5[:ok] && g5[:specs].is_a?(Hash)
  _g5els, g5bad = target_ids(g5[:specs])
  check(g5bad.empty?, "two groups: every control target elementId exists (dangling: #{g5bad.inspect})", fails)
  page_ctls = ->(name) { (g5[:specs]['pages'].find { |pg| pg['name'] == name }['elements'] || []).select { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' } }
  kpi_oc = page_ctls.call('KPI Deep Dive')
  chan_oc = page_ctls.call('Channel Only')
  check(kpi_oc.size == 1 && kpi_oc.first['filters'] == oc_filters,
        "KPI Deep Dive carries only the group-3 control (got #{kpi_oc.map { |c| c['controlId'] }.inspect})", fails)
  page_ids = (g5[:specs]['pages'].find { |pg| pg['name'] == 'Channel Only' }['elements'] || []).map { |e| e['id'] }
  check(chan_oc.size == 1 && chan_oc.first['controlId'].include?('-g5') &&
          chan_oc.first['filters'].all? { |t| t.dig('source', 'elementId') == 'master' || page_ids.include?(t.dig('source', 'elementId')) },
        "Channel Only carries only the group-5 control, aimed at its own page (got #{chan_oc.map { |c| [c['controlId'], c['filters']] }.inspect})", fails)
  rec3 = ((g5[:scope] || {})['controls'] || []).find { |r| r['name'] == 'Order Channel' && r['filter_group'] == '3' }
  check(rec3 && rec3['zone_dashboards'] == ['KPI Deep Dive'],
        "group-3 record names only its own dashboard (got #{rec3 && rec3['zone_dashboards'].inspect})", fails)
end

puts
puts
puts 'Part 3 - a shared-view filter is not double-emitted'
sv = <<~XML
  <shared-views>
    <shared-view name='sv1'>
      <filter class='categorical' column='[federated.pivfin0001].[none:ORDER_CHANNEL:nk]'>
        <groupfilter function='union'>
          <groupfilter function='member' level='[none:ORDER_CHANNEL:nk]' member='&quot;Web&quot;' />
          <groupfilter function='member' level='[none:ORDER_CHANNEL:nk]' member='&quot;Store&quot;' />
        </groupfilter>
      </filter>
    </shared-view>
  </shared-views>
XML
shared = run_pipeline(FIXTURE_TEXT.sub('</workbook>', "#{sv}</workbook>"))
sc = (shared[:specs] || []).select { |e| e['kind'] == 'control' && e['name'] == 'Order Channel' }
check(sc.size == 1, "Order Channel emitted exactly once when also shared-view (got #{sc.size})", fails)
srec = ((shared[:scope] || {})['controls'] || []).select { |r| r['name'] == 'Order Channel' }
check(srec.size == 1 && srec.first['source_signal'].include?('shared-view') && !srec.first.key?('scope_worksheets'),
      'the shared-view route owns it (no promoted filter-group scope record)', fails)
check((shared[:specs] || []).count { |e| e['kind'] == 'control' && e['name'] == 'Region' } == 1,
      'the non-shared Region quick filter is still promoted', fails)

puts
puts 'Part 4 - info-popup icon sheet becomes an icon button'
btn = specs.find { |e| e['id'] == 'btn-20' }
want_text = "Shows weekly revenue and margin by region and order channel.\n\nKey questions:\n" \
            "- Which channels grow week over week?\n- Where is margin slipping?"
check(btn == { 'id' => 'btn-20', 'kind' => 'button', 'text' => want_text, 'appearance' => 'text',
               'icon' => { 'type' => 'emoji', 'emoji' => "\u{1F4A1}", 'label' => 'hidden' } },
      "icon button has the exact verified shape (got #{btn.inspect})", fails)
check(btn && !btn['icon'].key?('tooltip'), 'icon omits the default tooltip key (clean readback census)', fails)
check(!base[:log].include?('ZONE DROPPED'), 'no ZONE DROPPED warning for the info sheet', fails)
cov = ((base[:coverage] || {})['unresolved'] || []).select { |u| u['visual'] == 'INFO Button - KPI' }
check(cov.size == 1 && cov.first['severity'] == 'approximated' &&
      cov.first['detail'] == "info popup → Sigma icon button tooltip (rich text formatting not carried)",
      "coverage records approximated, not dropped (got #{cov.inspect})", fails)
check(((base[:coverage] || {})['summary'] || {})['dropped'] == 0, 'coverage summary reports 0 dropped visuals', fails)
check(specs.none? { |e| e['kind'] != 'button' && e['id'].to_s.include?('info') },
      'no stand-in chart element for the info sheet', fails)

puts
puts 'Part 5 - negative cases keep today\'s behavior'
head, tail = FIXTURE_TEXT.split("<worksheet name='INFO Button - KPI'>", 2)
with_field = head + "<worksheet name='INFO Button - KPI'>" +
             tail.sub('<rows />', "<rows>[federated.pivfin0001].[none:REGION:nk]</rows>")
neg = run_pipeline(with_field)
check(neg[:ok], 'pipeline ran on the shape-sheet-with-a-field variant', fails)
check((neg[:specs] || []).none? { |e| e['id'] == 'btn-20' },
      'a Shape sheet with a field on rows is NOT turned into an info button', fails)
ncov = ((neg[:coverage] || {})['unresolved'] || []).select { |u| u['visual'] == 'INFO Button - KPI' }
check(ncov.any? { |u| u['severity'] == 'dropped' },
      "such a sheet keeps the 'dropped' coverage entry", fails)
no_tip = head + "<worksheet name='INFO Button - KPI'>" +
         tail.sub(/<customized-tooltip.*?<\/customized-tooltip>/m, '')
nt = run_pipeline(no_tip)
check((nt[:specs] || []).none? { |e| e['id'] == 'btn-20' } &&
      ((nt[:coverage] || {})['unresolved'] || []).any? { |u| u['visual'] == 'INFO Button - KPI' && u['severity'] == 'dropped' },
      'a Shape sheet with no tooltip text stays dropped', fails)

puts
puts 'Part 6 - layout places the icon button at the info zone'
def layout_xml(layout, page_name, extra_elements)
  Dir.mktmpdir do |d|
    lay = File.join(d, 'dashboard-layout.json')
    File.write(lay, JSON.dump(layout))
    wb_ids = { 'pages' => [
      { 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] },
      { 'name' => page_name, 'elements' => [
        { 'id' => 'el-kpi-crosstab', 'kind' => 'pivot-table', 'name' => 'KPI Crosstab' },
        { 'id' => 'el-revenue-by-region', 'kind' => 'bar-chart', 'name' => 'Revenue by Region' },
        { 'id' => 'el-revenue-by-channel', 'kind' => 'bar-chart', 'name' => 'Revenue by Channel' }
      ] + extra_elements }
    ] }
    wbf = File.join(d, 'wb-ids.json')
    File.write(wbf, JSON.dump(wb_ids))
    out = File.join(d, 'layout.xml')
    log, = Open3.capture2e(RUBY, LAYOUT, '--layout', lay, '--wb-ids', wbf, '--out', out)
    [File.exist?(out) ? File.read(out) : '', log]
  end
end
btn_el = { 'id' => 'btn-20', 'kind' => 'button', 'text' => 'x' }
ctl_els = [{ 'id' => 'el-oc', 'kind' => 'control', 'name' => 'Order Channel' },
           { 'id' => 'el-rg', 'kind' => 'control', 'name' => 'Region' }]
# Default fixture: the left filter rail selects the synthesized path.
synth_xml, synth_log = layout_xml(base[:layout], 'KPI Deep Dive', ctl_els + [btn_el])
check(synth_xml =~ /elementId="btn-20"/ && synth_log !~ /bottom band/,
      'synthesized layout path places btn-20 (not via the unplaced bottom-band safety net)', fails)
# Shrink the filter zones so no sidebar rail is detected -> the container-tree path.
tree_layout = JSON.parse(JSON.dump(base[:layout]))
squash = lambda do |n|
  if n['kind'] == 'filter'
    n.merge!('x_pct' => 0.0, 'w_pct' => 30.0, 'h_pct' => 5.0, 'y_pct' => n['id'] == '10' ? 0.0 : 5.0)
  end
  (n['children'] || []).each { |c| squash.call(c) }
end
tree_layout.each { |dd| dd['zones'].each { |z| squash.call(z) }; dd['zone_tree'].each { |z| squash.call(z) } }
tree_xml, = layout_xml(tree_layout, 'KPI Deep Dive', ctl_els + [btn_el])
check(tree_xml =~ %r{elementId="btn-20" gridColumn="24 / 25"},
      'container-tree layout path places btn-20 at the zone geometry (top-right column)', fails)
# The banded path: strip the filter zones so no control rail triggers the tree path.
banded = JSON.parse(JSON.dump(base[:layout]))
banded.each do |dd|
  dd['zones'].reject! { |z| z['kind'] == 'filter' }
  dd.delete('zone_tree')
end
banded_xml, banded_log = layout_xml(banded, 'KPI Deep Dive', [btn_el])
check(banded_xml.include?('btn-20') && banded_log !~ /bottom band/,
      'banded layout path places btn-20 (not via the unplaced bottom-band safety net)', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
