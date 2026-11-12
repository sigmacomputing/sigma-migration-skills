#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-builder-followups.rb — builder follow-ups found integrating a large multi-page report on top
# of the first-wave builder (pure helpers + one end-to-end offline build). Synthetic names only
# (Sales / Orders / Customer) — NO customer data.
#
#   G30  hidden visuals     — `hidden: true` (or `is_hidden`) is held back and recorded "hidden in
#                             source"; a bookmark that reveals it keeps it (recorded); a hidden
#                             SLICER with a saved selection stays (it still filters in PBI).
#   G31  synced slicers     — the primary's filters reach the page-local copy on EVERY member page;
#                             a saved selection on ANY member is the group default.
#   G32  empty containers   — never emit an empty layout container; legend bands use auto rows;
#                             the legend/drill control of a held-back chart is dropped; control
#                             filters/targets/controlScope pointing at held-back elements go.
#   +    page filters       — a page filter on a shared master lands on THIS page's copy.
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/pbi_reportbuild'
require_relative 'lib/layout'
require_relative 'lib/code_rep'
require_relative 'lib/control_lint'
require_relative 'lib/layout_lint'
require_relative 'lib/ruby_compat'

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end
R = PbiReportBuild

# ---- G30: hidden-visual partition (pure) -----------------------------------------------------------
v = ->(id, extra = {}) { { 'visual_id' => id, 'sigma_kind' => 'bar', 'visual_type' => 'barChart' }.merge(extra) }
ok('hidden_visual?: hidden true / is_hidden true / "true" string', R.hidden_visual?(v.call('a', 'hidden' => true)) &&
   R.hidden_visual?(v.call('a', 'is_hidden' => true)) && R.hidden_visual?(v.call('a', 'hidden' => 'true')))
ok('hidden_visual?: false / nil / missing / non-hash are visible',
   [v.call('a', 'hidden' => false), v.call('a'), v.call('a', 'hidden' => nil), nil, 'x'].none? { |x| R.hidden_visual?(x) })
slicer = lambda do |id, extra = {}|
  { 'visual_id' => id, 'sigma_kind' => 'control', 'visual_type' => 'slicer', 'hidden' => true }.merge(extra)
end
sel = { 'saved_selection' => { 'mode' => 'include', 'column' => 'T.C', 'values' => %w[a], 'has_null' => false } }
part = R.partition_hidden(
  [v.call('shown'), v.call('h1', 'hidden' => true), v.call('h2', 'is_hidden' => true), v.call('rev', 'hidden' => true),
   slicer.call('hs', 'slicer_state' => sel), slicer.call('hs0'),
   slicer.call('hs_self', 'slicer_state' => { 'selection' => { 'type' => 'list', 'values' => ['x'], 'scope' => 'slicer-self' } })],
  [{ 'name' => 'b1', 'display_name' => 'Show detail', 'shows' => ['rev'], 'hides' => [] }, { 'name' => 'b2', 'hides' => ['shown'], 'shows' => [] }]
)
ok('partition: visible + bookmark-revealed + hidden-saved-selection slicer are kept, in source order',
   part['kept'].map { |x| x['visual_id'] } == %w[shown rev hs])
ok('partition: held = hidden with no bookmark and no filtering effect (incl. a slicer-self-only hidden slicer)',
   part['held'].map { |x, _| x['visual_id'] } == %w[h1 h2 hs0 hs_self] && part['held'].all? { |_, why| why == 'hidden in source' })
ok('partition: the revealed visual carries its bookmark display name',
   part['revealed'].size == 1 && part['revealed'][0][0]['visual_id'] == 'rev' && part['revealed'][0][1] == ['Show detail'])
ok('partition: the filtering hidden slicer is reported', part['filtering'].map { |(x)| x['visual_id'] } == ['hs'])
ok('partition: nothing hidden -> everything kept untouched, bookmarks may be nil',
   R.partition_hidden([v.call('a'), v.call('b')], nil)['held'].empty?)
ok('bookmark_reveals accepts shows (canonical) / shown / visible / show / unhidden keys',
   R.bookmark_reveals([{ 'name' => 'w', 'shows' => ['d'] }, { 'name' => 'x', 'visible' => ['a'] }, { 'name' => 'y', 'show' => ['b'] },
                       { 'name' => 'z', 'unhidden' => ['c'] }]).keys.sort == %w[a b c d])

# ---- G31: synced groups (pure) -----------------------------------------------------------------------
sv = lambda do |id, grp, extra = {}|
  { 'visual_id' => id, 'sigma_kind' => 'control', 'sync_group' => grp, 'bindings' => { 'Values' => ['T.Year'] } }.merge(extra)
end
sel_for = ->(vals, mode = 'include') { { 'saved_selection' => { 'mode' => mode, 'column' => 'T.Year', 'values' => vals, 'has_null' => false } } }
qr_of = ->(x) { x['sigma_kind'] == 'control' ? x['bindings']['Values'].first : nil }
pages = [{ 'visuals' => [sv.call('p', 'G')] }, { 'visuals' => [sv.call('m1', 'G'), sv.call('m2', 'G', 'slicer_state' => sel_for.call(['2026L']))] }]
notes = R.sync_group_defaults!(pages, qr_of)
ok('sync defaults: a primary with no selection borrows the first member selection (any page)',
   pages[0]['visuals'][0]['slicer_state'] == sel_for.call(['2026L']) && notes == [{ 'group' => 'G', 'primary' => 'p', 'from' => 'm2', 'conflict' => false }])
ok('sync defaults: the donor member is left as it was', pages[1]['visuals'][1]['slicer_state'] == sel_for.call(['2026L']))
pages = [{ 'visuals' => [sv.call('p', 'G', 'slicer_state' => sel_for.call(['2025L']))] },
         { 'visuals' => [sv.call('m', 'G', 'slicer_state' => sel_for.call(['2026L']))] }]
notes = R.sync_group_defaults!(pages, qr_of)
ok('sync defaults: the primary\'s own selection wins; disagreeing members are flagged as a conflict',
   pages[0]['visuals'][0]['slicer_state'] == sel_for.call(['2025L']) && notes.size == 1 && notes[0]['conflict'] && notes[0]['from'].nil?)
pages = [{ 'visuals' => [sv.call('p', 'G', 'slicer_state' => sel_for.call(['1L']))] }, { 'visuals' => [sv.call('m', 'G', 'slicer_state' => sel_for.call(['1L']))] }]
ok('sync defaults: agreeing members produce no note', R.sync_group_defaults!(pages, qr_of).empty?)
pages = [{ 'visuals' => [sv.call('p', 'G'), sv.call('o', '')] }, { 'visuals' => [sv.call('m', 'G', 'bindings' => { 'Values' => ['T.Other'] },
                                                                                     'slicer_state' => sel_for.call(['9L']))] }]
ok('sync defaults: a member slicing a DIFFERENT field never lends its selection',
   R.sync_group_defaults!(pages, qr_of).empty? && pages[0]['visuals'][0]['slicer_state'].nil?)

# page_local_masters!: a primary on page 1 reaches the copies of pages 2 AND 3 (members stay minimal)
mcols = [{ 'id' => 'mc-r', 'name' => 'Region', 'formula' => '[T/Region]' }, { 'id' => 'mc-y', 'name' => 'Year', 'formula' => '[T/Year]' }]
data = [{ 'id' => 'm-sales', 'kind' => 'table', 'name' => 'S', 'columns' => mcols }]
chart = ->(id) { { 'id' => id, 'kind' => 'bar-chart', 'source' => { 'kind' => 'table', 'elementId' => 'm-sales' },
                   'columns' => [{ 'id' => "#{id}-c", 'formula' => '[m-sales/Region]' }] } }
prim = { 'id' => 'ctl-1', 'kind' => 'control', 'controlId' => 'Year', 'controlType' => 'list',
         'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'm-sales' }, 'columnId' => 'mc-y' }] }
mem = ->(id) { { 'id' => id, 'kind' => 'control', 'controlId' => 'Year', 'controlType' => 'synced' } }
cp = [{ 'id' => 'page-1', 'name' => 'One', 'elements' => [prim, chart.call('c1')] },
      { 'id' => 'page-2', 'name' => 'Two', 'elements' => [mem.call('ctl-2'), chart.call('c2')] },
      { 'id' => 'page-3', 'name' => 'Three', 'elements' => [mem.call('ctl-3'), chart.call('c3')] }]
res = R.page_local_masters!(cp, data, ['m-sales'])
tg = prim['filters'].map { |f| f.dig('source', 'elementId') }.sort
want = cp.map { |p| res['copies']["m-sales|#{p['id']}"] }.sort
ok('synced primary filters the page-local copy on EVERY member page (3 pages -> 3 targets, none on the shared master)',
   res['copies'].size == 3 && tg == want && !tg.include?('m-sales'))
ok('synced primary column ids follow the copies', prim['filters'].all? { |f| f['columnId'].start_with?('mc-y-') })
ok('synced members stay minimal', cp[1]['elements'][0].keys.sort == %w[controlId controlType id kind])
ok('a synced group whose primary reaches copies is not reported inert', res['emptied'].empty?)

# ---- G32: layout + control pruning (pure) -------------------------------------------------------------
x = SigmaLayout.page_xml('pg',
                         SigmaLayout.gc('band-1', 1, 25, 1, 9, SigmaLayout.le('gone', 1, 25, 1, 9)),
                         SigmaLayout.gc('band-2', 1, 25, 9, 17, SigmaLayout.gc('inner', 1, 25, 1, 3, '')),
                         SigmaLayout.gc('band-3', 1, 25, 17, 25, SigmaLayout.le('keep', 1, 25, 1, 9)),
                         SigmaLayout.le('loose', 1, 25, 25, 30))
out, cts, els = SigmaLayout.prune_empty_containers(x, %w[band-1 band-2 band-3 inner keep loose])
ok('prune_empty_containers: a band whose only child is unknown is omitted, and so is a container of empty containers',
   cts.sort == %w[band-1 band-2 inner] && els == ['gone'])
ok('prune_empty_containers: untouched containers/elements survive verbatim',
   out.include?('elementId="band-3"') && out.include?('elementId="keep"') && out.include?('elementId="loose"') &&
   !out.include?('band-1') && !out.include?('gone'))
ok('prune_empty_containers: an already-clean layout comes back byte-identical',
   SigmaLayout.prune_empty_containers(out, %w[band-3 keep loose]).first == out)
ok('prune_empty_containers: the legend-band container (gc default) uses auto rows',
   SigmaLayout.gc('c', 1, 25, 1, 9, '').include?('gridTemplateRows="auto"'))

els = [
  { 'id' => 'chart-a', 'kind' => 'bar-chart' },
  { 'id' => 'chart-a-legend', 'kind' => 'control', 'controlId' => 'AL', 'controlType' => 'legend',
    'targets' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'chart-a' }, 'columnId' => 'x' }],
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'chart-a' }, 'columnId' => 'x' }], 'controlScope' => ['chart-a'] },
  { 'id' => 'slicer', 'kind' => 'control', 'controlId' => 'S', 'controlType' => 'list',
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master-1' }, 'columnId' => 'c' }],
    'controlScope' => ['chart-a', 'chart-b'] },
  { 'id' => 'drill', 'kind' => 'control', 'controlId' => 'D', 'controlType' => 'drill',
    'targets' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'chart-b' }, 'columnIds' => %w[a b] }],
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'chart-b' }, 'columnId' => 'a' }], 'controlScope' => ['chart-b'] },
  { 'id' => 'chart-b', 'kind' => 'bar-chart' }
]
gone = R.prune_control_refs!(els, ['chart-a'])
ok('prune_control_refs!: the legend control of a held-back chart is dropped (and reported with its controlId)',
   gone == { 'elements' => ['chart-a-legend'], 'controls' => ['AL'] } && els.none? { |e| e['id'] == 'chart-a-legend' })
sl = els.find { |e| e['id'] == 'slicer' }
ok('prune_control_refs!: a control that keeps a real filter loses only the stale controlScope id',
   sl && sl['controlScope'] == ['chart-b'] && sl['filters'].size == 1)
ok('prune_control_refs!: an unrelated drill control is untouched', els.find { |e| e['id'] == 'drill' }['targets'].size == 1)
ok('prune_control_refs!: nothing removed -> nothing changes', R.prune_control_refs!(els, []) == { 'elements' => [], 'controls' => [] })

# ---- end to end: build ----------------------------------------------------------------------------------
BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
mcol = ->(pfx, name) { { 'id' => "#{pfx}-#{name.downcase.gsub(/\W/, '')}", 'name' => name, 'formula' => "[T/#{name}]" } }
MMAP = {
  'masters' => {
    'SALES' => { 'id' => 'master-sales', 'element_id' => 'el-sales', 'data_model' => 'dm-x',
                 'columns' => ['Region', 'Segment', 'Fiscal Year', 'Sales Amount'].map { |c| mcol.call('mc', c) } },
    'ORDER' => { 'id' => 'master-order', 'element_id' => 'el-order', 'data_model' => 'dm-x',
                 'columns' => ['Order Date', 'Channel', 'Net Revenue'].map { |c| mcol.call('oc', c) } },
    'PY' => { 'id' => 'master-py', 'element_id' => 'el-py', 'data_model' => 'dm-x',
              'columns' => [mcol.call('pc', 'Net Revenue PY')] }
  },
  'fields' => {
    'SALES_FACT.Region' => { 'master' => 'SALES', 'ref' => '[master-sales/Region]', 'agg' => nil },
    'SALES_FACT.Segment' => { 'master' => 'SALES', 'ref' => '[master-sales/Segment]', 'agg' => nil },
    'SALES_FACT.Fiscal Year' => { 'master' => 'SALES', 'ref' => '[master-sales/Fiscal Year]', 'agg' => nil },
    'SALES_FACT.Sales Amount' => { 'master' => 'SALES', 'ref' => '[master-sales/Sales Amount]', 'agg' => 'Sum' },
    'ORDER_FACT.Order Date' => { 'master' => 'ORDER', 'ref' => '[master-order/Order Date]', 'agg' => nil },
    'ORDER_FACT.Channel' => { 'master' => 'ORDER', 'ref' => '[master-order/Channel]', 'agg' => nil },
    'ORDER_FACT.Net Revenue' => { 'master' => 'ORDER', 'ref' => '[master-order/Net Revenue]', 'agg' => 'Sum' },
    # declared on ORDER, formula leaks master-py -> the post-assembly gate drops it and holds the chart back
    'ORDER_FACT.YoY Pct' => { 'master' => 'ORDER', 'agg' => nil,
                              'formula' => 'Sum([master-py/Net Revenue PY]) / Sum([master-order/Net Revenue])' }
  }
}.freeze
MODEL = {
  'model' => {
    'tables' => [
      { 'name' => 'SALES_FACT', 'columns' => [{ 'name' => 'Region', 'dataType' => 'string' }, { 'name' => 'Segment', 'dataType' => 'string' },
                                              { 'name' => 'Fiscal Year', 'dataType' => 'int64' }, { 'name' => 'Sales Amount', 'dataType' => 'double' }] },
      { 'name' => 'ORDER_FACT', 'columns' => [{ 'name' => 'Order Date', 'dataType' => 'string' }, { 'name' => 'Channel', 'dataType' => 'string' },
                                              { 'name' => 'Net Revenue', 'dataType' => 'double' }] }
    ],
    'relationships' => []
  }
}.freeze

def vis(id, vtype, kind, bindings, title, x, y, w, h, extra = {})
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title, 'x' => x, 'y' => y, 'w' => w, 'h' => h,
    'z' => 0, 'parent_group' => nil, 'bindings' => bindings, 'sort' => nil, 'formats' => {} }.merge(extra)
end

def slc(id, qr, title, i, extra = {})
  vis(id, 'slicer', 'control', { 'Values' => [qr] }, title, i * 150, 0, 140, 60, extra)
end

FY_SEL = { 'saved_selection' => { 'mode' => 'include', 'column' => 'SALES_FACT.Fiscal Year', 'values' => [2026], 'has_null' => false } }.freeze
SEG_SEL = { 'saved_selection' => { 'mode' => 'include', 'column' => 'SALES_FACT.Segment', 'values' => %w[Retail], 'has_null' => false } }.freeze
SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'bookmarks' => [{ 'name' => 'bm1', 'display_name' => 'Show detail', 'shows' => ['v_revealed'], 'hides' => [] }],
  'pages' => [
    { 'page_id' => 'p1', 'page_title' => 'Overview', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [], 'visuals' => [
      slc('s_region', 'SALES_FACT.Region', 'Region', 0),
      # the FY sync group's primary has NO saved selection; its member on page 2 does
      slc('s_fy', 'SALES_FACT.Fiscal Year', 'Fiscal Year', 1, 'sync_group' => 'FYSync'),
      slc('s_hidden_seg', 'SALES_FACT.Segment', 'Hidden Segment', 2, 'hidden' => true, 'slicer_state' => SEG_SEL),
      slc('s_hidden_plain', 'SALES_FACT.Segment', 'Hidden Plain', 3, 'hidden' => true),
      vis('kpi_sales', 'card', 'kpi', { 'Values' => ['SALES_FACT.Sales Amount'] }, 'Total Sales', 0, 80, 300, 80),
      vis('bar_region', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Region'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Sales by Region', 320, 80, 940, 200),
      vis('v_hidden', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Segment'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Hidden Variant', 0, 300, 600, 200, 'hidden' => true),
      vis('v_hidden2', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Segment'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Hidden Variant Two', 620, 300, 600, 200, 'is_hidden' => true),
      vis('v_revealed', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Segment'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Revealed Chart', 0, 520, 1260, 200, 'hidden' => true)
    ] },
    { 'page_id' => 'p2', 'page_title' => 'Detail', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [],
      'filters' => [{ 'type' => 'list', 'mode' => 'include', 'values' => ['West'], 'target' => 'SALES_FACT.Region' }],
      'visuals' => [
        slc('s2_fy', 'SALES_FACT.Fiscal Year', 'Fiscal Year', 0, 'sync_group' => 'FYSync', 'slicer_state' => FY_SEL),
        vis('bar_seg', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Segment'], 'Y' => ['SALES_FACT.Sales Amount'] },
            'Sales by Segment', 0, 100, 1280, 200)
      ] },
    { 'page_id' => 'p3', 'page_title' => 'Orders', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [], 'visuals' => [
      vis('kpi_net', 'card', 'kpi', { 'Values' => ['ORDER_FACT.Net Revenue'] }, 'Net Revenue', 0, 0, 400, 80),
      # has a legend (Series) -> legend control + legend band; the chart survives
      vis('bar_chan', 'clusteredColumnChart', 'bar',
          { 'Category' => ['ORDER_FACT.Order Date'], 'Series' => ['ORDER_FACT.Channel'], 'Y' => ['ORDER_FACT.Net Revenue'] },
          'Revenue by Channel', 0, 100, 1280, 200),
      # same shape but its only measure leaks another master -> held back by the cross-master gate;
      # its legend band + legend control must go with it
      vis('bar_yoy', 'clusteredColumnChart', 'bar',
          { 'Category' => ['ORDER_FACT.Order Date'], 'Series' => ['ORDER_FACT.Channel'], 'Y' => ['ORDER_FACT.YoY Pct'] },
          'YoY by Channel', 0, 320, 1280, 200)
    ] }
  ]
}.freeze

def run_build(dir, extra_args = [])
  File.write(File.join(dir, 'mmap.json'), JSON.generate(MMAP))
  File.write(File.join(dir, 'sig.json'), JSON.generate(SIGNALS))
  File.write(File.join(dir, 'model.json'), JSON.generate(MODEL))
  wb = File.join(dir, 'wb.json')
  err_f = File.join(dir, 'err.txt')
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  st = system(RbConfig.ruby, BUILD, '--signals', File.join(dir, 'sig.json'), '--master-map', File.join(dir, 'mmap.json'),
              '--model', File.join(dir, 'model.json'), '--bim', File.join(dir, 'model.json'),
              '--data-model', 'dm-x', '--name', 'Followups', '--out', wb, '--layout-out', File.join(dir, 'l.xml'),
              '--coverage-out', File.join(dir, 'cov.json'), '--control-scope-out', File.join(dir, 'scope.json'),
              *extra_args, out: File::NULL, err: File.open(err_f, 'w'))
  [st, wb, File.read(err_f)]
end

keep = ENV['FOLLOWUPS_OUT']
Dir.mkdir(keep) if keep && !Dir.exist?(keep)
(keep ? ->(&blk) { blk.call(keep) } : ->(&blk) { Dir.mktmpdir { |dd| blk.call(dd) } }).call do |d|
  st, wb, err = run_build(d)
  ok('builder exits 0', st || (puts(err.lines.last(8).join) && false))
  spec = JSON.parse(File.read(wb))
  doc = Sigma::CodeRep.document(spec)
  covj = JSON.parse(File.read(File.join(d, 'cov.json')))
  cover = covj['unresolved'] || []
  els = doc['elements']
  by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
  page_ids = Sigma::CodeRep.workbook_page_element_ids(doc)
  page_els = doc['pages'].each_with_object({}) { |p, h| h[p['id']] = Array(page_ids[p['id']]).filter_map { |id| by_id[id] } }
  p1, p2, p3 = %w[page-p1 page-p2 page-p3].map { |k| page_els[k] }
  by_name = ->(pg, nm) { pg.find { |e| e['name'] == nm } }
  layout = doc['layout']

  # ---- G30 ----
  ok('G30 hidden visuals (hidden / is_hidden) are not emitted',
     by_name.call(p1, 'Hidden Variant').nil? && by_name.call(p1, 'Hidden Variant Two').nil?)
  ok('G30 a hidden slicer with no saved selection is not emitted', by_name.call(p1, 'Hidden Plain').nil?)
  ok('G30 the held-back visuals are recorded "hidden in source" (dropped, decoration — no functional loss)',
     ['Hidden Variant', 'Hidden Variant Two', 'Hidden Plain'].all? do |nm|
       cover.any? { |u| u['visual'] == nm && u['severity'] == 'dropped' && u['detail'].include?('hidden in source') && u['role_class'] == 'decoration' }
     end)
  ok('G30 the hold-back never reaches the layout (no placement of a hidden visual)',
     !layout.include?('el-v_hidden') && !layout.include?('el-v_hidden2'))
  ok('G30 a bookmark-revealed hidden visual is KEPT and recorded with the bookmark name',
     by_name.call(p1, 'Revealed Chart') &&
       cover.any? { |u| u['visual'] == 'Revealed Chart' && u['severity'] == 'degraded' && u['detail'].include?('Show detail') })
  hs = by_name.call(p1, 'Hidden Segment')
  ok('G30 a hidden slicer with a saved selection is KEPT (it still filters in PBI), default applied, recorded',
     hs && hs['values'] == ['Retail'] &&
       cover.any? { |u| u['visual'] == 'Hidden Segment' && u['severity'] == 'degraded' && u['detail'].include?('hidden in source') })
  ok('G30 sourceVisuals still counts the held-back visuals', covj['summary']['sourceVisuals'] == SIGNALS['pages'].sum { |pg| pg['visuals'].size })

  # ---- G31 ----
  fy1 = by_name.call(p1, 'Fiscal Year')
  fy2 = p2.find { |e| e['controlType'] == 'synced' }
  ok('G31 the synced primary takes the saved selection of its member on another page as the group default',
     fy1 && fy1['mode'] == 'include' && fy1['values'] == [2026])
  ok('G31 the synced member stays minimal', fy2 && fy2.keys.sort == %w[controlId controlType id kind] && fy2['controlId'] == fy1['controlId'])
  copy_of = lambda do |pg|
    pg.select { |e| e['kind'] != 'control' && e['kind'] != 'container' }
      .map { |e| e.dig('source', 'elementId').to_s }.uniq.find { |s| s.start_with?('pgcopy-') && s.end_with?('master-sales') }
  end
  c1 = copy_of.call(p1)
  c2 = copy_of.call(p2)
  ok('G31 pages 1 and 2 each source their own copy of master-sales', c1 && c2 && c1 != c2)
  ok('G31 the primary filters the copy on EVERY member page, never the shared master',
     fy1['filters'].map { |f| f.dig('source', 'elementId') }.sort == [c1, c2].sort)

  # ---- page filters onto page-local copies ----
  ok('page filter: page 2\'s filter (Region = West) is an element filter on page 2\'s copy',
     (f = Array(by_id[c2]['filters']).first) && f['kind'] == 'list' && f['values'] == ['West'] &&
       f['columnId'].end_with?("-#{c2[/pgcopy-([0-9a-f]{6})/, 1]}"))
  ok('page filter: it does NOT land on the shared master or on page 1\'s copy',
     Array(by_id['master-sales']['filters']).empty? && Array(by_id[c1]['filters']).empty?)
  ok('page filter: no "page_shared_master" gap is recorded', cover.none? { |u| u['detail'].to_s.include?('shared by other pages') })

  # ---- G32 ----
  ok('G32 no empty <Container> in the layout',
     layout !~ %r{<Container\b[^>]*>\s*</Container>} && layout !~ %r{<Container\b[^>]*/>})
  cont_ok = layout.scan(%r{<Container\b[^>]*>(.*?)</Container>}m).all? { |(inner)| inner.include?('<Element') }
  placed = layout.scan(/<Element\s+elementId="([^"]+)"/).flatten
  ok('G32 every container holds a child element', cont_ok)
  ok('G32 every placed element exists in the spec and every spec container is placed',
     placed.all? { |id| by_id.key?(id) } && els.select { |e| e['kind'] == 'container' }.all? { |e| layout.include?(%(elementId="#{e['id']}")) })
  ok('G32 the held-back chart (leaked measure) is gone', by_name.call(p3, 'YoY by Channel').nil?)
  ok('G32 its legend control is dropped with it (no control targets a missing element)',
     els.select { |e| e['kind'] == 'control' }.all? do |c|
       refs = Array(c['filters']).map { |f| f.dig('source', 'elementId') } + Array(c['targets']).map { |t| t.dig('source', 'elementId') } + Array(c['controlScope'])
       refs.all? { |r| by_id.key?(r) }
     end)
  ok('G32 the surviving chart keeps its legend control',
     els.count { |e| e['kind'] == 'control' && e['controlType'] == 'legend' } == 1 &&
       els.any? { |e| e['kind'] == 'control' && e['controlType'] == 'legend' && e['name'].include?('Revenue by Channel') })
  legend_tags = layout.scan(%r{<Container elementId="band-page-p3-legend[^>]*>})
  ok('G32 legend band containers use gridTemplateRows="auto" (never repeat(8, 1fr))',
     !legend_tags.empty? && legend_tags.all? { |t| t.include?('gridTemplateRows="auto"') })
  ok('G32 control-scope.json carries no entry for a dropped legend control',
     (JSON.parse(File.read(File.join(d, 'scope.json')))['controls'] || []).none? { |c| c['sourceName'].to_s.include?('YoY by Channel') })
  lint = LayoutLint.lint(spec)
  ok('G32 layout lint: no sub-minimum tile / orphan control / empty container',
     lint.none? { |m| m.include?('sub-minimum') || m.include?('orphan control') || m =~ /empty container/i } || (puts("    #{lint.inspect}") && false))

  # ---- legacy path keeps its behaviour (no page-local copies) ----
  Dir.mktmpdir do |d2|
    st2, _wb2, e2 = run_build(d2, ['--no-page-local-masters'])
    ok('legacy: --no-page-local-masters still builds', st2 || (puts(e2.lines.last(5).join) && false))
    cov2 = (JSON.parse(File.read(File.join(d2, 'cov.json')))['unresolved'] || [])
    ok('legacy: a page filter on a master shared by other pages is recorded (cannot be isolated)',
       cov2.any? { |u| u['detail'].to_s.include?('shared by other pages') })
  end
end

puts($fail.zero? ? "\nall builder follow-up tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
