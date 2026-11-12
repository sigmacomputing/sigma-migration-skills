#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-visual-fidelity.rb — builder-level visual-fidelity fixes (offline, synthetic Sales names).
#
#   1  display names    signals display_names -> Sigma column / value labels
#   2  slicer labels    header_title -> control label, else the field name
#   3  hidden slicers   a hidden slicer with a saved selection still filters: placed in a bottom band
#                       under "Filters hidden in the source report", visible ones stay in the top band
#   4  occluded visuals fully covered by a higher-z visual are held back (recoverable:false), unless a
#                       bookmark shows them; the check uses ABSOLUTE boxes (group offsets)
#   5  axis sort        TMSL sortByColumn drives the category axis (model passed with --model only)
#   6  table shape      tableEx -> flat `table`; pivotTable/matrix -> `pivot-table`
#   7  number formats   TMSL formatString -> d3 format; counts -> integer
#   8  legend controls  a legend control never gets a band of its own
#   9  page header      header = the PBI page name; a first textbox titled otherwise stays a text element
#   10 element height   low-cardinality pivot gets room for every row + total
#   11 literal escaping saved selection / selection values come out unescaped
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/code_rep'
require_relative 'lib/ruby_compat'
require_relative 'lib/pbi_reportbuild'

BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def mcol(name)
  { 'id' => "mc-#{name.downcase.gsub(/\W/, '')}", 'name' => name, 'formula' => "[T/#{name}]" }
end

COLS = ['Region', 'Segment', 'Channel', 'Rep', 'Age Bucket', 'Age Bucket Sort', 'Sales Amount', 'Units', 'Orders',
        'Margin Pct'].freeze
def dim(name)
  { 'master' => 'SALES', 'ref' => "[master-sales/#{name}]", 'agg' => nil }
end
def msr(name, agg)
  { 'master' => 'SALES', 'ref' => "[master-sales/#{name}]", 'agg' => agg }
end

MMAP = {
  'masters' => { 'SALES' => { 'id' => 'master-sales', 'element_id' => 'el-sales', 'data_model' => 'dm-x',
                              'columns' => COLS.map { |c| mcol(c) } } },
  'fields' => {
    'SALES_FACT.Region' => dim('Region'), 'SALES_FACT.Segment' => dim('Segment'),
    'SALES_FACT.Channel' => dim('Channel'), 'SALES_FACT.Rep' => dim('Rep'),
    'SALES_FACT.Age Bucket' => dim('Age Bucket'),
    # NOTE: 'Age Bucket Sort' is deliberately NOT a field — only a master column
    'SALES_FACT.Sales Amount' => msr('Sales Amount', 'Sum'),
    'SALES_FACT.Units' => msr('Units', 'Sum'),
    'SALES_FACT.Total Sales' => msr('Sales Amount', 'Sum'),
    'SALES_FACT.Order Count' => msr('Orders', 'Count'),
    'SALES_FACT.Margin' => msr('Margin Pct', 'Avg')
  }
}.freeze

MODEL = {
  'model' => {
    'tables' => [{
      'name' => 'SALES_FACT',
      'columns' => [
        { 'name' => 'Region', 'dataType' => 'string' }, { 'name' => 'Segment', 'dataType' => 'string' },
        { 'name' => 'Channel', 'dataType' => 'string' }, { 'name' => 'Rep', 'dataType' => 'string' },
        { 'name' => 'Age Bucket', 'dataType' => 'string', 'sortByColumn' => 'Age Bucket Sort' },
        { 'name' => 'Age Bucket Sort', 'dataType' => 'int64' },
        { 'name' => 'Sales Amount', 'dataType' => 'double', 'formatString' => '#,##0.00' },
        { 'name' => 'Units', 'dataType' => 'int64' }, { 'name' => 'Orders', 'dataType' => 'int64' },
        { 'name' => 'Margin Pct', 'dataType' => 'double' }
      ],
      'measures' => [{ 'name' => 'Total Sales', 'formatString' => '$#,##0' },
                     { 'name' => 'Margin', 'formatString' => '0.0%' }]
    }],
    'relationships' => []
  }
}.freeze

def vis(id, vtype, kind, bindings, title, x, y, w, h, extra = {})
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title,
    'x' => x, 'y' => y, 'w' => w, 'h' => h, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => nil, 'formats' => {} }.merge(extra)
end

def slicer(id, qr, title, x, extra = {})
  vis(id, 'slicer', 'control', { 'Values' => [qr] }, title, x, 100, 140, 60, extra)
end

def sel(col, values)
  { 'saved_selection' => { 'mode' => 'include', 'column' => col, 'values' => values, 'has_null' => false } }
end

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'bookmarks' => [{ 'name' => 'b1', 'display_name' => 'View 2', 'shows' => ['pv_rev'], 'hides' => [] }],
  'pages' => [
    { 'page_id' => 'p1', 'page_title' => 'Overview', 'page_w' => 1280, 'page_h' => 720, 'interactions' => [], 'visuals' => [
      vis('tb_cm', 'textbox', 'text', {}, nil, 0, 0, 600, 70, 'text' => 'Key Figures'),
      vis('tb_blank', 'textbox', 'text', {}, nil, 1000, 0, 200, 40, 'text' => '  '),
      slicer('s_region', 'SALES_FACT.Region', '', 0, 'header_title' => 'Pick a Region'),
      slicer('s_seg', 'SALES_FACT.Segment', '', 150),
      slicer('s_chan', 'SALES_FACT.Channel', '', 300, 'hidden' => true,
             'slicer_state' => sel('SALES_FACT.Channel', ['Online'])),
      slicer('s_rep', 'SALES_FACT.Rep', 'Rep', 450,
             'slicer_state' => sel('SALES_FACT.Rep', ["O'Brien"])),
      slicer('s_rep2', 'SALES_FACT.Rep', 'Rep Two', 600,
             'slicer_state' => { 'selection' => { 'type' => 'list', 'mode' => 'include', 'values' => ["'O''Brien'"] } }),
      vis('tbl', 'tableEx', 'table',
          { 'Values' => ['SALES_FACT.Region', 'SALES_FACT.Total Sales', 'SALES_FACT.Margin', 'SALES_FACT.Sales Amount'] },
          'Detail Table', 0, 200, 600, 200,
          'show_totals' => true,
          'display_names' => { 'SALES_FACT.Region' => 'Sales Region', 'SALES_FACT.Total Sales' => 'Revenue' }),
      vis('mx', 'pivotTable', 'pivot-table',
          { 'Rows' => ['SALES_FACT.Region'], 'Values' => ['SALES_FACT.Order Count'] },
          'Order Matrix', 620, 200, 640, 200,
          'row_cardinality' => 8, 'display_names' => { 'SALES_FACT.Order Count' => '# Orders' }),
      vis('bar_age', 'clusteredColumnChart', 'bar',
          { 'Category' => ['SALES_FACT.Age Bucket'], 'Y' => ['SALES_FACT.Units'] },
          'Units by Age', 0, 420, 600, 200, 'display_names' => { 'SALES_FACT.Units' => 'Units Sold' }),
      vis('line_y2', 'lineChart', 'line',
          { 'Category' => ['SALES_FACT.Age Bucket'], 'Y' => ['SALES_FACT.Units'], 'Y2' => ['SALES_FACT.Margin'] },
          'Units and Margin', 0, 1400, 1280, 200),
      vis('line_leg', 'lineChart', 'line',
          { 'Category' => ['SALES_FACT.Age Bucket'], 'Y' => ['SALES_FACT.Sales Amount'], 'Series' => ['SALES_FACT.Segment'] },
          'Sales by Age and Segment', 620, 420, 640, 200),
      # occlusion: pv_over (z 5) covers pv_under (z 1) and pv_rev (z 2, shown by bookmark b1)
      vis('pv_over', 'pivotTable', 'pivot-table', { 'Rows' => ['SALES_FACT.Segment'], 'Values' => ['SALES_FACT.Units'] },
          'Top View', 0, 640, 1280, 300, 'z' => 5),
      vis('pv_under', 'pivotTable', 'pivot-table', { 'Rows' => ['SALES_FACT.Region'], 'Values' => ['SALES_FACT.Units'] },
          'Under View', 0, 640, 600, 300, 'z' => 1),
      vis('pv_rev', 'pivotTable', 'pivot-table', { 'Rows' => ['SALES_FACT.Channel'], 'Values' => ['SALES_FACT.Units'] },
          'Toggled View', 700, 640, 500, 300, 'z' => 2)
    ] }
  ]
}.freeze

def run_build(dir, signals, extra_args = [])
  File.write(File.join(dir, 'mmap.json'), JSON.generate(MMAP))
  File.write(File.join(dir, 'sig.json'), JSON.generate(signals))
  File.write(File.join(dir, 'model.json'), JSON.generate(MODEL))
  wb = File.join(dir, 'wb.json')
  err_f = File.join(dir, 'err.txt')
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  st = system(RbConfig.ruby, BUILD, '--signals', File.join(dir, 'sig.json'), '--master-map', File.join(dir, 'mmap.json'),
              '--model', File.join(dir, 'model.json'), # NO --bim: sortByColumn must come from --model alone
              '--data-model', 'dm-x', '--name', 'Fidelity', '--out', wb, '--layout-out', File.join(dir, 'l.xml'),
              '--coverage-out', File.join(dir, 'cov.json'), '--control-scope-out', File.join(dir, 'scope.json'),
              *extra_args, out: File::NULL, err: File.open(err_f, 'w'))
  [st, wb, File.read(err_f)]
end

# element id -> [c0, c1, r0, r1] of every <Element> / <Container> in a layout page (container-relative for nested)
def boxes(layout, page_id, tag)
  block = layout[%r{<Page\b[^>]*\bid="#{Regexp.escape(page_id)}"[^>]*>(.*?)</Page>}m, 1].to_s
  block.scan(%r{<#{tag}\s+elementId="([^"]+)"[^>]*?gridColumn="(\d+) / (\d+)"\s+gridRow="(\d+) / (\d+)"}).each_with_object({}) do |m, h|
    h[m[0]] = m[1..4].map(&:to_i)
  end
end

def container_children(layout, page_id, cid)
  block = layout[%r{<Page\b[^>]*\bid="#{Regexp.escape(page_id)}"[^>]*>(.*?)</Page>}m, 1].to_s
  inner = block[%r{<Container\s+elementId="#{Regexp.escape(cid)}".*?>(.*?)</Container>}m, 1].to_s
  inner.scan(/elementId="([^"]+)"/).flatten
end

Dir.mktmpdir do |d|
  st, wb, err = run_build(d, SIGNALS)
  ok('builder exits 0', st || (puts(err.lines.last(8).join) && false))
  spec = JSON.parse(File.read(wb))
  doc = Sigma::CodeRep.document(spec)
  cover = JSON.parse(File.read(File.join(d, 'cov.json')))['unresolved'] || []
  layout = File.read(File.join(d, 'l.xml'))
  by_id = doc['elements'].each_with_object({}) { |e, h| h[e['id']] = e }
  page_ids = Sigma::CodeRep.workbook_page_element_ids(doc)
  p1 = Array(page_ids['page-p1']).filter_map { |id| by_id[id] }
  by_name = ->(nm) { p1.find { |e| e['name'] == nm } }
  by_vid = ->(vid) { p1.find { |e| e['id'] == "el-#{vid.gsub(/[^a-zA-Z0-9]/, '').downcase}" } }
  names = ->(el) { Array(el['columns']).map { |c| c['name'] } }

  # ---- 1 display names ---------------------------------------------------------------------
  tbl = by_name.call('Detail Table')
  ok('1 table column uses the PBI display name (Sales Region), field name when none', tbl && names.call(tbl).include?('Sales Region') && names.call(tbl).include?('Margin'))
  ok('1 measure column uses the PBI display name (Revenue)', tbl && names.call(tbl).include?('Revenue') && !names.call(tbl).include?('Total Sales'))
  mx = by_name.call('Order Matrix')
  ok('1 pivot value column uses the display name (# Orders)', mx && names.call(mx).include?('# Orders'))
  bar = by_name.call('Units by Age')
  ok('1 chart value column uses the display name (Units Sold)', bar && names.call(bar).include?('Units Sold'))

  # ---- 2 slicer labels ---------------------------------------------------------------------
  ok('2 slicer header title becomes the control label', by_name.call('Pick a Region'))
  ok('2 slicer with no title falls back to the field name', by_name.call('Segment'))

  # ---- 3 hidden slicer band ----------------------------------------------------------------
  chan = by_name.call('Channel')
  ok('3 the hidden slicer with a saved selection still exists as a filtering control',
     chan && chan['kind'] == 'control' && chan['values'] == ['Online'] && Array(chan['filters']).any?)
  cont = boxes(layout, 'page-p1', 'Container')
  hid_id = cont.keys.find { |k| k.end_with?('-hctrl') }
  top_id = cont.keys.find { |k| k.end_with?('-ctrl') }
  ok('3 a separate hidden-filters band container exists', !hid_id.nil?)
  if hid_id
    kids = container_children(layout, 'page-p1', hid_id)
    ok('3 the hidden control lives only in the hidden band', kids.include?(chan['id']))
    hdr = kids.map { |k| by_id[k] }.compact.find { |e| e['kind'] == 'text' }
    ok('3 the band carries a small text header "Filters hidden in the source report"',
       hdr && hdr['body'].to_s.include?('Filters hidden in the source report'))
    others = cont.reject { |k, _| k == hid_id }.values + boxes(layout, 'page-p1', 'Element').reject { |k, _| kids.include?(k) }.values
    others_nested = (cont.keys - [hid_id]).flat_map { |k| container_children(layout, 'page-p1', k) }
    top_level_els = boxes(layout, 'page-p1', 'Element').reject { |k, _| others_nested.include?(k) || kids.include?(k) }
    bottom = (cont.reject { |k, _| k == hid_id || !others.include?(cont[k]) }.values + top_level_els.values).map { |b| b[3] }.max
    ok('3 the hidden band sits BELOW every other band', cont[hid_id][2] >= bottom)
    top_kids = top_id ? container_children(layout, 'page-p1', top_id) : []
    ok('3 visible slicers stay in the top band, in source order (Region before Segment)',
       top_kids.index(by_name.call('Pick a Region')['id']) && top_kids.index(by_name.call('Segment')['id']) &&
       top_kids.index(by_name.call('Pick a Region')['id']) < top_kids.index(by_name.call('Segment')['id']) &&
       !top_kids.include?(chan['id']))
  end
  ok('3 a coverage note records the hidden-filters band',
     cover.any? { |u| u['detail'].to_s.include?('Filters hidden in the source report') })

  # ---- 4 occluded visuals ------------------------------------------------------------------
  ok('4 a visual fully covered by a higher-z visual is not emitted', by_name.call('Under View').nil?)
  occ = cover.find { |u| u['visual'] == 'Under View' }
  ok('4 coverage: recoverable:false with reason "occluded by <visual> on the default view"',
     occ && occ['recoverable'] == false && occ['detail'].to_s.include?('occluded by Top View on the default view'))
  ok('4 the covering visual is kept', by_name.call('Top View'))
  ok('4 a covered visual a bookmark shows is kept (bookmark exception)', by_name.call('Toggled View'))

  # ---- 5 axis sort -------------------------------------------------------------------------
  ok('5 category axis sorts by the model sortByColumn (a hidden column over "Age Bucket Sort")',
     bar && (sc = Array(bar['columns']).find { |c| c['id'] == bar.dig('xAxis', 'sort', 'by') }) &&
     sc['formula'].to_s.include?('Age Bucket Sort'))

  # ---- 6 table shape -----------------------------------------------------------------------
  ok('6 tableEx becomes a flat table element, not a pivot', tbl && tbl['kind'] == 'table')
  ok('6 a pivotTable stays a pivot', mx && mx['kind'] == 'pivot-table')

  # ---- 7 number formats --------------------------------------------------------------------
  fmt = ->(el, nm) { (Array(el['columns']).find { |c| c['name'] == nm } || {}).dig('format', 'formatString') }
  ok('7 measure formatString $#,##0 -> $,.0f', fmt.call(tbl, 'Revenue') == '$,.0f')
  ok('7 measure formatString 0.0% -> .1%', fmt.call(tbl, 'Margin') == '.1%')
  ok('7 column formatString #,##0.00 -> ,.2f', fmt.call(tbl, 'Sales Amount') == ',.2f')
  ok('7 a count with no format is an integer (no ".0")', fmt.call(mx, '# Orders') == ',.0f')

  # ---- 8 legend controls -------------------------------------------------------------------
  legend = p1.find { |e| e['kind'] == 'control' && e['controlType'] == 'legend' }
  ok('8 the legend control never gets a band of its own',
     legend && cont.keys.any? { |k| (kids = container_children(layout, 'page-p1', k)).include?(legend['id']) &&
                                          kids.any? { |x| x != legend['id'] && by_id[x] && by_id[x]['kind'] != 'control' } })

  # ---- 9 page header -----------------------------------------------------------------------
  hdr_text = by_id["band-page-p1-hdrtext"]
  ok('9 the page header text is the PBI page name', hdr_text && hdr_text['body'].to_s.include?('Overview') && !hdr_text['body'].to_s.include?('Key Figures'))
  ok('9 a first textbox titled otherwise stays a section text element', p1.any? { |e| e['kind'] == 'text' && e['body'].to_s.include?('Key Figures') })
  y2 = doc['elements'].find { |e| e['name'] == 'Units and Margin' }
  y2ids = y2 && (y2['yAxis2'] || {})['columnIds']
  y2col = y2 && y2ids && y2['columns'].find { |c| c['id'] == y2ids.first }
  ok('12 a lineChart Y2 role becomes a secondary-axis series (yAxis2), also listed in yAxis',
     y2 && y2ids && y2ids.size == 1 && y2['yAxis']['columnIds'].include?(y2ids.first) &&
     y2col && y2col['formula'].include?('Margin Pct'))
  ok('9b an empty (whitespace-only) textbox emits no text tile (a blank tile breaks the page PNG render)',
     doc['elements'].none? { |e| e['kind'] == 'text' && e['body'].to_s.strip.empty? })

  # ---- 10 element height -------------------------------------------------------------------
  b = boxes(layout, 'page-p1', 'Element')[mx['id']]
  ok('10 a pivot with 8 known rows gets height for every row plus a total', b && (b[3] - b[2]) >= 2 * (8 + 2))

  # ---- 11 escaping -------------------------------------------------------------------------
  rep = by_name.call('Rep')
  rep2 = by_name.call('Rep Two')
  ok("11 saved_selection value comes out unescaped (O'Brien)", rep && rep['values'] == ["O'Brien"])
  ok("11 raw legacy selection literal 'O''Brien' comes out unescaped", rep2 && rep2['values'] == ["O'Brien"])
end

# ---- 4 (unit) occlusion math: >=95% under ONE higher-z visual; 90% is not enough; equal z never occludes
mk = ->(id, x, y, w, h, z) { { 'visual_id' => id, 'visual_type' => 'card', 'sigma_kind' => 'kpi', 'x' => x, 'y' => y, 'w' => w, 'h' => h, 'z' => z } }
occ = PbiReportBuild.occluded_visuals([mk.call('a', 0, 0, 100, 100, 1), mk.call('b', 0, 0, 100, 96, 2),
                                       mk.call('c', 0, 0, 100, 100, 1), mk.call('d', 0, 0, 100, 90, 3),
                                       mk.call('e', 500, 500, 10, 10, 1), mk.call('f', 500, 500, 10, 10, 1)])
ok('4 a visual 96% under a higher-z visual is occluded', occ.key?('a') && occ['a']['visual_id'] == 'b')
ok('4 a 90%-coverer is not enough (a is occluded by b, never by d)', occ['a']['visual_id'] != 'd' && !occ.key?('d'))
ok('4 equal z never occludes', !occ.key?('e') && !occ.key?('f'))

# PBIR z is RELATIVE within a group: compare along the group chain. A child at z 2000 in a group at
# z 1 sits BELOW a child at z 0 in a group at z 5.
grp = ->(id, z) { { 'visual_id' => id, 'visual_type' => 'unknown', 'x' => 0, 'y' => 0, 'w' => 100, 'h' => 100, 'z' => z } }
occ2 = PbiReportBuild.occluded_visuals([grp.call('g_low', 1), grp.call('g_high', 5),
                                        mk.call('lo_child', 0, 0, 100, 100, 2000).merge('parent_group' => 'g_low'),
                                        mk.call('hi_child', 0, 0, 100, 100, 0).merge('parent_group' => 'g_high')])
ok('4 group-relative z: the child of the higher group occludes, whatever the raw child z',
   occ2.key?('lo_child') && occ2['lo_child']['visual_id'] == 'hi_child' && !occ2.key?('hi_child'))

# ---- 9b blank textboxes in EVERY layout mode (clean drops tiny ones itself; pbi/banded kept a ' ' tile,
# and a whitespace-only text tile made the page PNG render fail with HTTP 500 in a real workbook)
%w[pbi banded].each do |mode|
  Dir.mktmpdir do |d|
    st, wb, = run_build(d, SIGNALS, ['--layout', mode])
    doc = Sigma::CodeRep.document(JSON.parse(File.read(wb))) if st
    ok("9b #{mode}: no whitespace-only text tile is emitted",
       st && doc['elements'].none? { |e| e['kind'] == 'text' && e['body'].to_s.strip.empty? })
  end
end

puts($fail.zero? ? "\nall passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
