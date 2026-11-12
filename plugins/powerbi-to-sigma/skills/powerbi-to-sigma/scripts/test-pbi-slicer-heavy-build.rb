#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-slicer-heavy-build.rb — end-to-end (offline, files only) test of the builder on a
# synthetic SLICER-HEAVY, MULTI-PAGE report: the shape of a large multi-page migration
# whose workbook was wrong and unreadable until hand-fixed. Asserts the generic fixes:
#
#   G21  page-local masters   — each page sources its own child copy of every shared master and
#                               its controls target ONLY those copies; disjoint cross-page slicer
#                               defaults no longer trip the shared control lint; a synced slicer's
#                               primary still reaches every page that hosts a member.
#   F14  saved selections     — slicer_state.saved_selection becomes the control default, typed
#                               from the column (int / bool / text); a saved (Blank) is recorded.
#   G27  boolean controls     — "all" is exclude + [] (include [] matches ZERO rows in Sigma).
#   G24  slicer-self          — a slicer's own visual-level filter is never a default.
#   G28  View aliases         — "DATE_DIM.Date (Fiscal Month)" binds the View column that keeps "(Month)".
#   hold-back                 — visuals whose measures do not bind are not emitted (no empty
#                               yAxis, no pivot without values) and are recorded as dropped.
#   per-visual master         — a visual whose measure lives only on another master sources THAT
#                               master (page-base mode) instead of losing the measure.
#   layout                    — control bands wrap at 6 x 4 cols, every kind meets its minimum
#                               height, a band whose sibling was held back spans the full width.
#   cosmetics                 — container-name slicer titles become the field name, date axes get a
#                               date format, sortByColumn axes sort by it, text periods natural-sort.
#
# Synthetic names only (Sales / Inventory / Date) — NO customer data.
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/code_rep'
require_relative 'lib/control_lint'
require_relative 'lib/layout_lint'
require_relative 'lib/layout'
require_relative 'lib/ruby_compat'

BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def mcol(master, name, key = name.downcase.gsub(/\W/, ''))
  { 'id' => "#{master}-#{key}", 'name' => name, 'formula' => "[T/#{name}]" }
end

SALES_COLS = ['Region', 'Order Date', 'Is Active Ind', 'Fiscal Year', 'Period', 'Period Sort', 'Week', 'Segment',
              'Sales Amount', 'Units'].freeze
MMAP = {
  'masters' => {
    'SALES' => { 'id' => 'master-sales', 'element_id' => 'el-sales', 'data_model' => 'dm-x',
                 'columns' => SALES_COLS.map { |c| mcol('mc', c) } },
    'INV' => { 'id' => 'master-inv', 'element_id' => 'el-inv', 'data_model' => 'dm-x',
               'columns' => ['Region', 'On Hand'].map { |c| mcol('ic', c) } },
    'DATE' => { 'id' => 'master-date', 'element_id' => 'el-date', 'data_model' => 'dm-x',
                'columns' => ['Date', 'Date (Fiscal Month)'].map { |c| mcol('dc', c) } },
    'SALES VIEW' => { 'id' => 'master-view', 'element_id' => 'el-view', 'data_model' => 'dm-x',
                      'columns' => ['Amount', 'Date (DimDate)', 'Date (Fiscal Month) (DimDate)'].map { |c| mcol('vc', c) } }
  },
  'fields' => {
    'SALES_FACT.Region' => { 'master' => 'SALES', 'ref' => '[master-sales/Region]', 'agg' => nil,
                             'alts' => [{ 'master' => 'INV', 'ref' => '[master-inv/Region]', 'agg' => nil }] },
    'DATE_DIM.Order Date' => { 'master' => 'SALES', 'ref' => '[master-sales/Order Date]', 'agg' => nil },
    'SALES_FACT.Is Active Ind' => { 'master' => 'SALES', 'ref' => '[master-sales/Is Active Ind]', 'agg' => nil },
    'SALES_FACT.Fiscal Year' => { 'master' => 'SALES', 'ref' => '[master-sales/Fiscal Year]', 'agg' => nil },
    'SALES_FACT.Period' => { 'master' => 'SALES', 'ref' => '[master-sales/Period]', 'agg' => nil },
    'SALES_FACT.Period Sort' => { 'master' => 'SALES', 'ref' => '[master-sales/Period Sort]', 'agg' => nil },
    'SALES_FACT.Week' => { 'master' => 'SALES', 'ref' => '[master-sales/Week]', 'agg' => nil },
    'SALES_FACT.Segment' => { 'master' => 'SALES', 'ref' => '[master-sales/Segment]', 'agg' => nil },
    'SALES_FACT.Units' => { 'master' => 'SALES', 'ref' => '[master-sales/Units]', 'agg' => 'Sum' },
    'SALES_FACT.Sales Amount' => { 'master' => 'SALES', 'ref' => '[master-sales/Sales Amount]', 'agg' => 'Sum',
                                   'alts' => [{ 'master' => 'SALES VIEW', 'ref' => '[master-view/Amount]', 'agg' => 'Sum' }] },
    'INV_FACT.On Hand' => { 'master' => 'INV', 'ref' => '[master-inv/On Hand]', 'agg' => 'Sum' },
    # G28: the field's OWN name carries "(Month)"; the registered View alt is the stripped (wrong) alias
    'DATE_DIM.Date (Fiscal Month)' => { 'master' => 'DATE', 'ref' => '[master-date/Date (Fiscal Month)]', 'agg' => nil,
                                 'alts' => [{ 'master' => 'SALES VIEW', 'ref' => '[master-view/Date (DimDate)]', 'agg' => nil }] }
  }
}.freeze

MODEL = {
  'model' => {
    'tables' => [
      { 'name' => 'SALES_FACT', 'columns' => [
        { 'name' => 'Region', 'dataType' => 'string' }, { 'name' => 'Segment', 'dataType' => 'string' },
        { 'name' => 'Is Active Ind', 'dataType' => 'boolean' }, { 'name' => 'Fiscal Year', 'dataType' => 'int64' },
        { 'name' => 'Period', 'dataType' => 'string', 'sortByColumn' => 'Period Sort' },
        { 'name' => 'Period Sort', 'dataType' => 'int64' }, { 'name' => 'Week', 'dataType' => 'string' },
        { 'name' => 'Sales Amount', 'dataType' => 'double' }, { 'name' => 'Units', 'dataType' => 'int64' }
      ] },
      { 'name' => 'DATE_DIM', 'columns' => [{ 'name' => 'Order Date', 'dataType' => 'dateTime' },
                                            { 'name' => 'Date (Fiscal Month)', 'dataType' => 'string' }] },
      { 'name' => 'INV_FACT', 'columns' => [{ 'name' => 'On Hand', 'dataType' => 'int64' }] }
    ],
    'relationships' => [{ 'fromTable' => 'SALES_FACT', 'toTable' => 'DATE_DIM', 'isActive' => true }]
  }
}.freeze

def vis(id, vtype, kind, bindings, title, x, y, w, h, extra = {})
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title,
    'x' => x, 'y' => y, 'w' => w, 'h' => h, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => nil, 'formats' => {} }.merge(extra)
end

def slicer(id, qr, title, i, extra = {})
  vis(id, 'slicer', 'control', { 'Values' => [qr] }, title, i * 150, 0, 140, 60, extra)
end

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [
    { 'page_id' => 'p1', 'page_title' => 'Overview', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [], 'visuals' => [
      slicer('s_region', 'SALES_FACT.Region', '', 0,
             'slicer_state' => { 'saved_selection' => { 'mode' => 'include', 'column' => 'SALES_FACT.Region',
                                                         'values' => %w[West East], 'has_null' => true } }),
      slicer('s_fy', 'SALES_FACT.Fiscal Year', 'Slicer Container 3', 1,
             'sync_group' => 'FYSync',
             'slicer_state' => { 'saved_selection' => { 'mode' => 'include', 'column' => 'SALES_FACT.Fiscal Year',
                                                         'values' => [2026], 'has_null' => false } }),
      # G24 + G27: only a slicer-self filter / selection exists -> the default must stay "all"
      slicer('s_active', 'SALES_FACT.Is Active Ind', 'Active', 2,
             'filters' => [{ 'type' => 'list', 'mode' => 'include', 'values' => [true, false], 'scope' => 'slicer-self',
                             'target' => 'SALES_FACT.Is Active Ind' }],
             'slicer_state' => { 'selection' => { 'type' => 'list', 'mode' => 'include', 'values' => [true, false],
                                                  'scope' => 'slicer-self' } }),
      slicer('s_period', 'SALES_FACT.Period', 'Period', 3),
      slicer('s_week', 'SALES_FACT.Week', 'Week', 4),
      slicer('s_units', 'SALES_FACT.Units', 'Units', 5),
      slicer('s_seg', 'SALES_FACT.Segment', 'Segment', 6),
      slicer('s_date', 'DATE_DIM.Order Date', 'Order Date', 7),
      vis('kpi_sales', 'card', 'kpi', { 'Values' => ['SALES_FACT.Sales Amount'] }, 'Total Sales', 0, 80, 300, 80),
      vis('line_period', 'lineChart', 'line', { 'Category' => ['SALES_FACT.Period'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Sales by Period', 0, 180, 620, 200),
      vis('bar_week', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Week'], 'Y' => ['SALES_FACT.Units'] },
          'Units by Week', 640, 180, 620, 200),
      vis('line_date', 'lineChart', 'line', { 'Category' => ['DATE_DIM.Order Date'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Sales over Time', 0, 400, 620, 140),
      # sibling of line_date: its measure never binds -> held back -> line_date must stretch full width
      vis('line_ghost', 'lineChart', 'line', { 'Category' => ['SALES_FACT.Region'], 'Y' => ['GHOST.Margin'] },
          'Ghost Line', 640, 400, 620, 140),
      vis('pivot_ghost', 'pivotTable', 'pivot-table', { 'Rows' => ['SALES_FACT.Region'], 'Values' => ['GHOST.Margin'] },
          'Ghost Pivot', 0, 560, 600, 100),
      vis('tbl', 'tableEx', 'table', { 'Values' => ['SALES_FACT.Region', 'SALES_FACT.Sales Amount'] }, 'Detail',
          620, 560, 640, 100),
      vis('line_month', 'lineChart', 'line', { 'Category' => ['DATE_DIM.Date (Fiscal Month)'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Monthly Sales', 0, 680, 620, 200),
      vis('inv_bar', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Region'], 'Y' => ['INV_FACT.On Hand'] },
          'On Hand by Region', 640, 680, 620, 200)
    ] },
    { 'page_id' => 'p2', 'page_title' => 'Detail', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [], 'visuals' => [
      # DISJOINT default vs page 1's Region slicer: on one shared master Sigma AND-composes them to zero rows
      slicer('s2_region', 'SALES_FACT.Region', 'Region', 0,
             'slicer_state' => { 'saved_selection' => { 'mode' => 'include', 'column' => 'SALES_FACT.Region',
                                                         'values' => %w[South], 'has_null' => false } }),
      slicer('s2_fy', 'SALES_FACT.Fiscal Year', 'Fiscal Year', 1, 'sync_group' => 'FYSync'),
      slicer('s2_active', 'SALES_FACT.Is Active Ind', 'Active', 2,
             'slicer_state' => { 'saved_selection' => { 'mode' => 'include', 'column' => 'SALES_FACT.Is Active Ind',
                                                         'values' => [false], 'has_null' => false } }),
      vis('bar_region', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Region'], 'Y' => ['SALES_FACT.Sales Amount'] },
          'Sales by Region', 0, 100, 1280, 200)
    ] },
    { 'page_id' => 'p3', 'page_title' => 'Inventory', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [], 'visuals' => [
      vis('kpi3', 'card', 'kpi', { 'Values' => ['SALES_FACT.Sales Amount'] }, 'Sales (p3)', 0, 0, 300, 80),
      vis('kpi_units3', 'card', 'kpi', { 'Values' => ['SALES_FACT.Units'] }, 'Units (p3)', 320, 0, 300, 80),
      # the dimension exists only on the base (SALES), the measure only on INV: the MEASURE wins
      vis('inv_seg', 'clusteredColumnChart', 'bar', { 'Category' => ['SALES_FACT.Segment'], 'Y' => ['INV_FACT.On Hand'] },
          'On Hand by Segment', 0, 100, 1280, 200)
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
              '--data-model', 'dm-x', '--name', 'Slicer Heavy', '--out', wb, '--layout-out', File.join(dir, 'l.xml'),
              '--coverage-out', File.join(dir, 'cov.json'), '--control-scope-out', File.join(dir, 'scope.json'),
              *extra_args, out: File::NULL, err: File.open(err_f, 'w'))
  [st, wb, File.read(err_f)]
end

# eid -> [c0, c1, r0, r1] for every <Element> of one layout page
def layout_items(layout, page_id)
  block = layout[%r{<Page\b[^>]*\bid="#{Regexp.escape(page_id)}"[^>]*>(.*?)</Page>}m, 1].to_s
  block.scan(%r{<Element\s+elementId="([^"]+)"\s+gridColumn="(\d+) / (\d+)"\s+gridRow="(\d+) / (\d+)"}).each_with_object({}) do |m, h|
    h[m[0]] = m[1..4].map(&:to_i)
  end
end

# SLICER_HEAVY_OUT=<dir> keeps the built artifacts there for inspection.
keep = ENV['SLICER_HEAVY_OUT']
Dir.mkdir(keep) if keep && !Dir.exist?(keep)
(keep ? ->(&blk) { blk.call(keep) } : ->(&blk) { Dir.mktmpdir { |dd| blk.call(dd) } }).call do |d|
  st, wb, err = run_build(d)
  ok('builder exits 0', st || (puts(err.lines.last(6).join) && false))
  spec = JSON.parse(File.read(wb))
  doc = Sigma::CodeRep.document(spec)
  cover = JSON.parse(File.read(File.join(d, 'cov.json')))['unresolved'] || []
  els = doc['elements']
  by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
  page_ids = Sigma::CodeRep.workbook_page_element_ids(doc)
  page_els = doc['pages'].each_with_object({}) do |p, h|
    h[p['id']] = Array(page_ids[p['id']]).filter_map { |id| by_id[id] }
  end
  p1 = page_els['page-p1']
  p2 = page_els['page-p2']
  p3 = page_els['page-p3']
  by_name = ->(pg, nm) { pg.find { |e| e['name'] == nm } }
  root_of = lambda do |id|
    cur = id
    cur = by_id[cur].dig('source', 'elementId') while by_id[cur] && by_id[cur].dig('source', 'kind') == 'table'
    cur
  end

  # ---- G21: page-local masters ---------------------------------------------------------------
  data_kinds = %w[kpi-chart bar-chart line-chart table pivot-table]
  src_ids = ->(pg) { pg.select { |e| data_kinds.include?(e['kind']) }.map { |e| e.dig('source', 'elementId') }.uniq }
  ok('G21 no content element sources the SHARED master-sales directly',
     (p1 + p2 + p3).none? { |e| e.dig('source', 'elementId') == 'master-sales' })
  s1 = src_ids.call(p1).select { |s| root_of.call(s) == 'master-sales' && s != 'master-sales' }
  s2 = src_ids.call(p2).select { |s| root_of.call(s) == 'master-sales' && s != 'master-sales' }
  ok('G21 each page sources its OWN copy of master-sales (distinct ids, both real children of it)',
     s1.size == 1 && s2.size == 1 && s1 != s2 && (s1 + s2).all? { |c| by_id[c].dig('source', 'elementId') == 'master-sales' })
  ok('G21 the shared master and its Data-page copies are all placed on the hidden Data page',
     (page_els['page-data'].map { |e| e['id'] } & (s1 + s2 + ['master-sales'])).size == 3)
  ctl_targets = lambda do |pg|
    pg.select { |e| e['kind'] == 'control' && e['filters'] }.flat_map { |c| c['filters'].map { |f| f.dig('source', 'elementId') } }.uniq
  end
  ok('G21 page 2 controls target ONLY page 2\'s copy (plus the sync primary reaching it)',
     ctl_targets.call(p2).all? { |t| t == s2.first })
  ok('G21 page 1 controls target page 1\'s copy (and page 2\'s copy via the synced slicer), never the shared master',
     ctl_targets.call(p1).include?(s1.first) && !ctl_targets.call(p1).include?('master-sales'))
  fy1 = by_name.call(p1, 'Fiscal Year')
  fy2 = p2.find { |e| e['controlType'] == 'synced' }
  ok('G21 a synced slicer primary filters the copy on EVERY page hosting a member',
     fy1 && fy1['filters'].map { |f| f.dig('source', 'elementId') }.sort == [s1.first, s2.first].sort)
  ok('G21 the synced member stays minimal', fy2 && fy2.keys.sort == %w[controlId controlType id kind])
  lint = ControlLint.lint(spec)
  ok('G21 the shared control lint reports NO conflicting cross-page defaults',
     lint.none? { |v| v.include?('conflicting cross-page control defaults') } || (puts("    #{lint.inspect}") && false))
  # the test has teeth: the legacy shared-master build DOES trip the lint
  Dir.mktmpdir do |d2|
    st2, wb2, = run_build(d2, ['--no-page-local-masters'])
    legacy = st2 && ControlLint.lint(JSON.parse(File.read(wb2)))
    ok('G21 (control) --no-page-local-masters reproduces the conflict the lint flags',
       legacy && legacy.any? { |v| v.include?('conflicting cross-page control defaults') })
  end

  # ---- F14 / G27 / G24: control defaults -----------------------------------------------------
  region = by_name.call(p1, 'Region')
  ok('F14 text slicer default = saved selection, unquoted', region && region['mode'] == 'include' && region['values'] == %w[West East])
  ok('F14 the saved (Blank) is recorded as degraded coverage (a Sigma list cannot hold NULL)',
     cover.any? { |u| u['severity'] == 'degraded' && u['detail'].to_s.include?('(Blank)') })
  ok('F14 int slicer default typed from the column: 2026L -> 2026', fy1 && fy1['values'] == [2026])
  active1 = by_name.call(p1, 'Active')
  ok('G27 boolean slicer with no saved selection is exclude + [] (never include [])',
     active1 && active1['mode'] == 'exclude' && active1['values'] == [])
  ok('G24 a slicer-self filter / selection is NOT turned into the default (stays "all")',
     active1 && active1['mode'] == 'exclude' && active1['values'].empty?)
  active2 = by_name.call(p2, 'Active')
  ok('F14 boolean saved selection typed: "false" -> false (include [false])',
     active2 && active2['mode'] == 'include' && active2['values'] == [false])
  region2 = by_name.call(p2, 'Region')
  ok('F14 page 2 keeps ITS OWN Region default (disjoint from page 1)', region2 && region2['values'] == ['South'])
  no_bad_bool = (p1 + p2 + p3).select { |e| e['kind'] == 'control' && e['controlType'] == 'list' }.select do |c|
    c['mode'] == 'include' && c['values'].empty? && c['name'] == 'Active'
  end
  ok('G27 no boolean control anywhere ships include + []', no_bad_bool.empty?)

  # ---- cosmetics ------------------------------------------------------------------------------
  ok('cosmetic: a container-name title ("Slicer Container 3") is replaced by the field name "Fiscal Year"',
     fy1 && fy1['name'] == 'Fiscal Year')
  ok('cosmetic: a slicer label repeated on another page is NOT suffixed "(2)"',
     p2.any? { |e| e['kind'] == 'control' && e['name'] == 'Region' } && p1.any? { |e| e['kind'] == 'control' && e['name'] == 'Region' })
  line_date = by_name.call(p1, 'Sales over Time')
  xcol = line_date['columns'].find { |c| c['id'] == line_date.dig('xAxis', 'columnId') }
  ok('cosmetic: a date x-axis gets a date format', xcol && xcol['format'] == { 'kind' => 'datetime', 'formatString' => '%Y-%m-%d' })
  line_period = by_name.call(p1, 'Sales by Period')
  scol = line_period['columns'].find { |c| c['id'] == line_period.dig('xAxis', 'sort', 'by') }
  ok('cosmetic: a TMSL sortByColumn axis sorts by the sort column ("Period Sort")',
     scol && scol['hidden'] && scol['formula'].include?('/Period Sort]'))
  bar_week = by_name.call(p1, 'Units by Week')
  ncol = bar_week['columns'].find { |c| c['id'] == bar_week.dig('xAxis', 'sort', 'by') }
  ok('cosmetic: a text period axis with no sort-by column natural-sorts (P1..P13)',
     ncol && ncol['hidden'] && ncol['formula'].include?('RegexpExtract') && ncol['formula'].include?('/Week]'))
  ok('cosmetic: a categorical (non-period) axis is left alone',
     by_name.call(p2, 'Sales by Region').dig('xAxis', 'sort').nil?)

  # ---- G28: the field's own parenthetical survives the View alias ----------------------------
  month = by_name.call(p1, 'Monthly Sales')
  mx = month && month['columns'].find { |c| c['id'] == month.dig('xAxis', 'columnId') }
  ok('G28 "DATE_DIM.Date (Fiscal Month)" binds the View column "Date (Fiscal Month) (DimDate)", not "Date (DimDate)"',
     mx && mx['formula'].include?('Date (Fiscal Month) (DimDate)') && !mx['formula'].include?('Date (DimDate)]'))
  ok('G28 the month chart sources the View master', month && root_of.call(month.dig('source', 'elementId')) == 'master-view')

  # ---- hold-back -------------------------------------------------------------------------------
  ok('hold-back: the ghost line chart is not emitted', by_name.call(p1, 'Ghost Line').nil?)
  ok('hold-back: the ghost pivot is not emitted', by_name.call(p1, 'Ghost Pivot').nil?)
  empty_y = els.select { |e| %w[line-chart bar-chart area-chart combo-chart].include?(e['kind']) && Array(e.dig('yAxis', 'columnIds')).empty? }
  empty_pv = els.select { |e| e['kind'] == 'pivot-table' && Array(e['values']).empty? }
  ok('hold-back: no emitted chart has an empty yAxis and no pivot lacks values', empty_y.empty? && empty_pv.empty?)
  ok('hold-back: both are recorded as DROPPED in coverage ("held back")',
     %w[Ghost\ Line Ghost\ Pivot].all? do |nm|
       cover.any? { |u| u['visual'] == nm && u['severity'] == 'dropped' && u['detail'].to_s.include?('held back') }
     end)

  # ---- page-base: measure-first per-visual master -----------------------------------------------
  inv = by_name.call(p1, 'On Hand by Region')
  ok('per-visual: a visual whose measure lives on another master sources THAT master (not dropped)',
     inv && root_of.call(inv.dig('source', 'elementId')) == 'master-inv' && Array(inv.dig('yAxis', 'columnIds')).size == 1)
  inv3 = by_name.call(p3, 'On Hand by Segment')
  ok('per-visual: with the dimension only on the base, the MEASURE still wins (xAxis lost -> degraded, recorded)',
     inv3 && root_of.call(inv3.dig('source', 'elementId')) == 'master-inv' && Array(inv3.dig('yAxis', 'columnIds')).size == 1 &&
       cover.any? { |u| u['visual'] == 'On Hand by Segment' })

  # ---- layout ------------------------------------------------------------------------------------
  layout = doc['layout']
  ctrl_ids = p1.select { |e| e['kind'] == 'control' }.map { |e| e['id'] }
  band = layout[%r{<Container elementId="band-page-p1-ctrl"[^>]*>(.*?)</Container>}m, 1].to_s
  cells = band.scan(%r{<Element\s+elementId="([^"]+)"\s+gridColumn="(\d+) / (\d+)"\s+gridRow="(\d+) / (\d+)"}).map { |m| [m[0]] + m[1..4].map(&:to_i) }
  ok('layout: the control band holds all 8 slicers', cells.map(&:first).sort == ctrl_ids.sort)
  row1 = cells.select { |c| c[3] == 1 }
  row2 = cells.select { |c| c[3] == 5 }
  ok('layout: the band WRAPS at 6 per row (6 + 2)', row1.size == 6 && row2.size == 2)
  ok('layout: every control cell is 4 grid columns wide and 4 rows tall',
     cells.all? { |c| c[2] - c[1] == 4 && c[4] - c[3] == 4 })
  ok('layout: row 1 tiles columns 1..25 edge to edge', row1.sort_by { |c| c[1] }.map { |c| c[1] } == [1, 5, 9, 13, 17, 21])
  items = layout_items(layout, 'page-p1')
  by_el_name = ->(nm) { (e = by_name.call(p1, nm)) && items[e['id']] }
  tbl_it = by_el_name.call('Detail')
  ok('layout: a table meets its 10-row minimum', tbl_it && tbl_it[3] - tbl_it[2] >= 10)
  ok('layout: a line chart meets its 9-row minimum', (it = by_el_name.call('Sales over Time')) && it[3] - it[2] >= 9)
  ok('layout: a KPI meets its 4-row minimum', (it = by_el_name.call('Sales Amount')) && it[3] - it[2] >= 4)
  all_ok = true
  doc['pages'].each do |pg|
    next if pg['id'] == 'page-data'
    layout_items(layout, pg['id']).each do |eid, c|
      e = by_id[eid]
      next unless e
      next if e['kind'] == 'control' # container-relative band rows, asserted above
      all_ok &&= (c[3] - c[2]) >= SigmaLayout.min_rows_for(e['kind'])
    end
  end
  ok('layout: EVERY tile on EVERY page meets its kind minimum height', all_ok)
  ok('layout: a band whose sibling was held back (Ghost Line) stretches the survivor to the full width 1..25',
     (it = by_el_name.call('Sales over Time')) && it[0] == 1 && it[1] == 25)
  lv = LayoutLint.lint(spec)
  ok('layout: lint reports no sub-minimum tile and no orphan control',
     lv.none? { |v| v.include?('sub-minimum') || v.include?('orphan control') } || (puts("    #{lv.inspect}") && false))
end

# ---- SigmaLayout helpers (pure) -------------------------------------------------------------------
cb = SigmaLayout.control_band(%w[a b c])
ok('control_band: fewer than 6 controls spread over the full width (3 -> 8 cols each), one 4-row band',
   cb[:height] == 4 && cb[:cells].map { |c| [c[1], c[2]] } == [[1, 9], [9, 17], [17, 25]])
cb = SigmaLayout.control_band((1..13).map(&:to_s))
ok('control_band: 13 controls -> 3 rows of 6/6/1, 12 rows tall, uniform 4-col cells',
   cb[:height] == 12 && cb[:cells].size == 13 && cb[:cells].all? { |c| c[2] - c[1] == 4 } &&
     cb[:cells].map { |c| c[3] }.uniq == [1, 5, 9])
ok('control_band: none -> empty', SigmaLayout.control_band([]) == { height: 0, cells: [] })
ok('min_rows_for: pivot/table 10, line 9, pie 8, kpi 4, unknown 6',
   SigmaLayout.min_rows_for('pivot-table') == 10 && SigmaLayout.min_rows_for('table') == 10 &&
     SigmaLayout.min_rows_for('line-chart') == 9 && SigmaLayout.min_rows_for('pie-chart') == 8 &&
     SigmaLayout.min_rows_for('kpi-chart') == 4 && SigmaLayout.min_rows_for('mystery') == 6)
ok('min_rows_for stays >= LayoutLint\'s floor for every kind it names',
   LayoutLint::KIND_MIN_ROWS.all? { |k, v| k == 'chart' || SigmaLayout.min_rows_for(k) >= v || !SigmaLayout::KIND_MIN_ROWS.key?(k) })

puts($fail.zero? ? "\nall slicer-heavy build tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
