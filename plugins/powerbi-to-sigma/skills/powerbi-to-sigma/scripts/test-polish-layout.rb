#!/usr/bin/env ruby
# frozen_string_literal: true
# test-polish-layout.rb — the layout POLISH pass (scripts/polish-layout.rb, lib/polish_layout.rb):
# keeps the source's arrangement, renders it to the house design rules. Synthetic Sales/Orders names.
#
#   p1  left column of three charts | three cards over a big table   (XY-cut: two columns)
#   p2  8 visible + 10 hidden slicers over a chart and a table       (control band + hidden band)
#   p3  a KPI row of 4 cards over a chart (+ an element with no source box)
#   p4  a section label, chart | table, and a long caption textbox
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'digest'
require 'rexml/document'
require 'English'
require_relative 'lib/ruby_compat'
require_relative 'lib/layout'
require_relative 'lib/layout_lint'
require_relative 'lib/polish_layout'

HERE = __dir__
CLI = File.join(HERE, 'polish-layout.rb')
GEOMETRY = File.join(HERE, 'layout-geometry-check.rb')
VALIDATE = File.join(HERE, 'validate-spec.rb')
PREFLIGHT = File.join(HERE, 'lib', 'preflight_lint.rb')
BUILDER = File.join(HERE, 'build-workbook-from-pbir.rb')
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# the builder's element id for a visual (independent copy; lockstep-checked against the builder below)
def eid(id)
  clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '').downcase
  # Not a security use: a short deterministic id tag that must stay stable across runs.
  # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1
  "el-#{clean[-6, 6] || clean}#{Digest::SHA1.hexdigest(id.to_s)[0, 6]}"
end

MASTER = 'master-sales'

def vis(id, type, x, y, w, h, extra = {})
  { 'visual_id' => id, 'visual_type' => type, 'sigma_kind' => type, 'title' => id,
    'x' => x, 'y' => y, 'w' => w, 'h' => h, 'z' => 0 }.merge(extra)
end

def col(id, formula, name, fmt = nil)
  c = { 'id' => id, 'formula' => formula, 'name' => name }
  c['format'] = fmt if fmt
  c
end

def chart_el(vid, color: false)
  e = eid(vid)
  el = { 'id' => e, 'kind' => 'bar-chart', 'name' => vid, 'source' => { 'elementId' => MASTER, 'kind' => 'table' },
         'columns' => [col("#{e}-x", "[#{MASTER}/Region]", 'Region'),
                       col("#{e}-y", "Sum([#{MASTER}/Amount])", 'Revenue')],
         'xAxis' => { 'columnId' => "#{e}-x" }, 'yAxis' => { 'columnIds' => ["#{e}-y"] } }
  el['color'] = { 'by' => 'category', 'column' => "#{e}-x" } if color
  el
end

def legend_el(vid)
  e = eid(vid)
  { 'id' => "#{e}-legend", 'kind' => 'control', 'controlId' => "#{vid}Legend", 'controlType' => 'legend',
    'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => MASTER }, 'columnId' => 'mc-region' },
    'targets' => [{ 'source' => { 'kind' => 'table', 'elementId' => e }, 'columnId' => "#{e}-x" }],
    'values' => [],
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => e }, 'columnId' => "#{e}-x" }],
    'controlScope' => [e] }
end

def kpi_el(vid)
  e = eid(vid)
  { 'id' => e, 'kind' => 'kpi-chart', 'name' => vid, 'source' => { 'elementId' => MASTER, 'kind' => 'table' },
    'columns' => [col("#{e}-v", "Sum([#{MASTER}/Amount])", 'Revenue')], 'value' => { 'columnId' => "#{e}-v" } }
end

def table_el(vid, extra = {})
  e = eid(vid)
  { 'id' => e, 'kind' => 'table', 'name' => vid, 'source' => { 'elementId' => MASTER, 'kind' => 'table' },
    'columns' => [col("#{e}-r", "[#{MASTER}/Region]", 'Region'),
                  col("#{e}-a", "[#{MASTER}/Amount]", 'Amount', 'kind' => 'number', 'formatString' => '$,.0f')] }.merge(extra)
end

def text_el(vid, body)
  { 'id' => eid(vid), 'kind' => 'text', 'body' => body }
end

def ctrl_el(vid, type = 'list')
  e = eid(vid)
  { 'id' => e, 'kind' => 'control', 'controlId' => "#{vid}Ctl", 'controlType' => type, 'name' => vid,
    'mode' => 'include', 'selectionMode' => 'multiple', 'values' => [],
    'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => MASTER }, 'columnId' => 'mc-region' },
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => MASTER }, 'columnId' => 'mc-region' }] }
end

def le(id, c0, c1, r0, r1)
  SigmaLayout.le(id, c0, c1, r0, r1)
end

# ---- fixture ---------------------------------------------------------------
LONG = ('This page tracks regional sales against plan; figures refresh nightly from the warehouse and exclude returns. ' \
        'Orders placed through the partner channel are attributed to the region of the shipping address, not the buyer. ' \
        'Use the filters above to focus on a single region or segment.')

signals_pages = []
elements = []

# the shared master lives on a hidden Data page, like the builder emits it
elements << { 'id' => MASTER, 'kind' => 'table', 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB PUBLIC SALES] },
              'columns' => [col('mc-region', '[SALES/Region]', 'Region'), col('mc-amount', '[SALES/Amount]', 'Amount')] }
layout_pages = [SigmaLayout.page_xml('page-data', le(MASTER, 1, 25, 1, 11))]

# p1 -----------------------------------------------------------------------
v1 = [vis('c1', 'barChart', 0, 0, 320, 280), vis('c2', 'barChart', 0, 300, 320, 260), vis('c3', 'barChart', 0, 580, 320, 260),
      vis('k1', 'card', 340, 0, 300, 140), vis('k2', 'card', 640, 0, 300, 140), vis('k3', 'card', 940, 0, 300, 140),
      vis('t1', 'tableEx', 340, 160, 940, 700, 'row_cardinality' => 23)]
signals_pages << { 'page_id' => 'p1', 'page_title' => 'Orders Overview', 'page_w' => 1280, 'page_h' => 900, 'visuals' => v1 }
elements.concat([chart_el('c1'), chart_el('c2', color: true), legend_el('c2'), chart_el('c3'), legend_el('c3'),
                 kpi_el('k1'), kpi_el('k2'), kpi_el('k3'), table_el('t1')])
# a scrambled flat input layout (the polish pass must ignore it)
ids1 = %w[t1 k3 c3 k1 c2 k2 c1].map { |v| eid(v) } + [legend_el('c2')['id'], legend_el('c3')['id']]
layout_pages << SigmaLayout.page_xml('page-p1', ids1.each_with_index.map { |id, i| le(id, 1, 25, i * 10 + 1, i * 10 + 11) }.join("\n"))

# p2 -----------------------------------------------------------------------
vis_ctrls = (1..8).map { |i| "s#{i}" }
hid_flagged = (1..6).map { |i| "h#{i}" }
hid_unmatched = (1..4).map { |i| "u#{i}" } # no signals entry at all
v2 = vis_ctrls.each_with_index.map { |c, i| vis(c, 'slicer', (i % 6) * 200, (i / 6) * 70, 140, 60) } +
     hid_flagged.each_with_index.map { |c, i| vis(c, 'slicer', 0, 700 + i * 20, 100, 20, 'hidden' => true) } +
     [vis('ch', 'barChart', 0, 150, 600, 300), vis('tb', 'tableEx', 620, 150, 640, 300, 'row_cardinality' => 2)]
signals_pages << { 'page_id' => 'p2', 'page_title' => 'Slicer Page', 'page_w' => 1280, 'page_h' => 720, 'visuals' => v2 }
elements.concat((vis_ctrls + hid_flagged + hid_unmatched).map { |c| ctrl_el(c) })
elements.concat([chart_el('ch'), table_el('tb')])
# input: a clean-mode-style page with its own header band and hidden band (the pass keeps the header text
# and rebuilds the rest)
elements << SigmaLayout.container_el('band-page-p2-hdr', SigmaLayout::HEADER_STYLE.dup)
elements << { 'id' => 'p2-title', 'kind' => 'text', 'body' => '# <span style="color: #FFFFFF">Regional Slicers</span>' }
elements << SigmaLayout.container_el('band-page-p2-hctrl')
elements << { 'id' => 'band-page-p2-hctrl-hdr', 'kind' => 'text', 'body' => '### Filters hidden in the source report' }
elements << SigmaLayout.container_el('band-page-p2-ctrl')
old_hidden = (hid_flagged + hid_unmatched).map { |c| eid(c) }
layout_pages << SigmaLayout.page_xml(
  'page-p2',
  SigmaLayout.header_band_xml('band-page-p2-hdr', 'p2-title'),
  SigmaLayout.gc('band-page-p2-ctrl', 1, 25, 4, 7, vis_ctrls.each_with_index.map { |c, i| le(eid(c), 1 + i * 3, 4 + i * 3, 1, 4) }.join("\n")),
  le(eid('ch'), 1, 13, 7, 17), le(eid('tb'), 13, 25, 7, 17),
  SigmaLayout.gc('band-page-p2-hctrl', 1, 25, 17, 24,
                 ([le('band-page-p2-hctrl-hdr', 1, 25, 1, 3)] + old_hidden.each_with_index.map { |id, i| le(id, 1 + (i % 6) * 4, 5 + (i % 6) * 4, 3 + (i / 6) * 3, 6 + (i / 6) * 3) }).join("\n"))
)

# p3 -----------------------------------------------------------------------
v3 = (0..3).map { |i| vis("m#{i + 1}", 'card', i * 320, 0, 300, 120) } + [vis('trend', 'lineChart', 0, 140, 1280, 300)]
signals_pages << { 'page_id' => 'p3', 'page_title' => 'KPI Row', 'page_w' => 1280, 'page_h' => 460, 'visuals' => v3 }
elements.concat((1..4).map { |i| kpi_el("m#{i}") })
elements << chart_el('trend').merge('kind' => 'line-chart')
elements << { 'id' => 'el-synthetic', 'kind' => 'text', 'body' => 'Builder-generated note with no source visual.' }
layout_pages << SigmaLayout.page_xml(
  'page-p3', ((1..4).map { |i| eid("m#{i}") } + [eid('trend'), 'el-synthetic']).each_with_index.map { |id, i| le(id, 1, 25, i * 6 + 1, i * 6 + 7) }.join("\n")
)

# p4 -----------------------------------------------------------------------
v4 = [vis('lbl', 'textbox', 0, 0, 300, 40, 'text' => '## Section'),
      vis('chartA', 'barChart', 0, 50, 600, 260), vis('tblA', 'tableEx', 620, 50, 640, 260),
      vis('note', 'textbox', 0, 330, 1280, 80, 'text' => LONG)]
signals_pages << { 'page_id' => 'p4', 'page_title' => 'Notes', 'page_w' => 1280, 'page_h' => 420, 'visuals' => v4 }
elements.concat([text_el('lbl', '## Section'), chart_el('chartA'), table_el('tblA', 'tableStyle' => { 'preset' => 'spreadsheet' }),
                 text_el('note', "## #{LONG}")])
layout_pages << SigmaLayout.page_xml(
  'page-p4', %w[note tblA chartA lbl].map { |v| eid(v) }.each_with_index.map { |id, i| le(id, 1, 25, i * 8 + 1, i * 8 + 9) }.join("\n")
)

pages_meta = [{ 'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden' },
              { 'id' => 'page-p1', 'name' => 'Orders Overview' }, { 'id' => 'page-p2', 'name' => 'Slicer Page' },
              { 'id' => 'page-p3', 'name' => 'KPI Row' }, { 'id' => 'page-p4', 'name' => 'Notes' }]
SPEC = { 'name' => 'Sales Overview',
         'document' => { 'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => pages_meta, 'elements' => elements,
                         'layout' => SigmaLayout.assemble(*layout_pages) } }.freeze
SIGNALS = { 'pages' => signals_pages }.freeze

# ---- helpers ----------------------------------------------------------------
def sh(*args)
  out = IO.popen([RbConfig.ruby, *args, { err: %i[child out] }], &:read)
  [$CHILD_STATUS.success?, out]
end

def span(attr)
  attr.to_s.split('/').map { |x| x.strip.to_i }
end

# element id -> [c0, c1, r0, r1] ABSOLUTE grid lines; container -> info
def parse_layout(xml)
  doc = REXML::Document.new("<L>#{xml.sub(/\A\s*<\?xml[^>]*\?>/, '')}</L>")
  pages = {}
  doc.root.elements.each('Page') do |page|
    boxes = {}
    containers = {}
    walk = lambda do |node, origin|
      node.elements.each do |el|
        next unless %w[Element Container].include?(el.name)
        c0, c1 = span(el.attributes['gridColumn'])
        r0, r1 = span(el.attributes['gridRow'])
        w = (origin[1] - origin[0]) / 24.0
        abs = [origin[0] + (c0 - 1) * w, origin[0] + (c1 - 1) * w, origin[2] + r0 - 1, origin[2] + r1 - 1]
        id = el.attributes['elementId']
        if el.name == 'Container'
          containers[id] = { box: abs, rel: [c0, c1, r0, r1], children: el.elements.to_a.map { |e| e.attributes['elementId'] },
                             kids_xml: el, template: el.attributes['gridTemplateRows'] }
          walk.call(el, abs)
        else
          boxes[id] = abs
        end
      end
    end
    walk.call(page, [1, 25, 1])
    pages[page.attributes['id']] = { boxes: boxes, containers: containers }
  end
  pages
end

def run_polish(dir, spec, signals, name = 'out', mode = 'band')
  File.write(File.join(dir, 'spec.json'), JSON.pretty_generate(spec))
  File.write(File.join(dir, 'signals.json'), JSON.pretty_generate(signals))
  out = File.join(dir, "#{name}.json")
  st, log = sh(CLI, '--spec', File.join(dir, 'spec.json'), '--signals', File.join(dir, 'signals.json'), '--out', out,
               '--layout-out', File.join(dir, "#{name}.xml"), '--hidden-controls', mode)
  [st, log, st ? JSON.parse(File.read(out)) : nil, out]
end

def elements_of(spec)
  spec['document']['elements']
end

def by_id(spec)
  elements_of(spec).each_with_object({}) { |e, h| h[e['id']] = e }
end

# ---- run --------------------------------------------------------------------
Dir.mktmpdir do |d|
  st, log, out, out_path = run_polish(d, SPEC, SIGNALS)
  ok('the CLI exits 0', st)
  abort(log) unless st
  puts log.lines.map { |l| "      #{l}" }.join if ENV['VERBOSE']
  ok('prints a per-page summary to stderr', log.scan('[polish-layout] page ').length == 4 && log.include?('arrangement:'))
  ok('the spec shape is kept (document.layout)', out['document']['layout'].include?('<Page') && !out.key?('layout'))
  layout = out['document']['layout']
  pages = parse_layout(layout)
  els = by_id(out)

  # -- (a) the tree arrangement -------------------------------------------------
  shapes = PolishLayout.polish(SPEC, SIGNALS).last.each_with_object({}) { |s, h| h[s['page_id']] = s['shape'] }
  ok('p1: left charts | cards over table (two columns)', shapes['page-p1'] == '(chart / chart / chart) | ((kpi | kpi | kpi) / table)')
  ok('p3: KPI row over a chart (+ the box-less element last)', shapes['page-p3'] == '(kpi | kpi | kpi | kpi) / chart / text')
  ok('p4: label / (chart | table) / caption', shapes['page-p4'] == 'text / (chart | table) / text')

  # -- order preservation (content elements, source boxes vs the output grid) ----
  content_pairs = lambda do |pid, sig_vis|
    boxes = pages[pid][:boxes]
    items = sig_vis.map { |v| [v, boxes[eid(v['visual_id'])]] }.select { |_, b| b }
    bad_inv = []
    bad_hold = []
    items.combination(2).each do |(va, ga), (vb, gb)|
      sa = [va['x'], va['y'], va['x'] + va['w'], va['y'] + va['h']]
      sb = [vb['x'], vb['y'], vb['x'] + vb['w'], vb['y'] + vb['h']]
      overlap = sa[0] < sb[2] && sb[0] < sa[2] && sa[1] < sb[3] && sb[1] < sa[3]
      next if overlap
      [[sa, sb, ga, gb], [sb, sa, gb, ga]].each do |a, b, ga2, gb2|
        left = a[2] <= b[0]
        above = a[3] <= b[1]
        out_left = ga2[1] <= gb2[0]
        out_above = ga2[3] <= gb2[2]
        out_left_rev = gb2[1] <= ga2[0]
        out_above_rev = gb2[3] <= ga2[2]
        bad_inv << [va['visual_id'], vb['visual_id']] if (left && out_left_rev) || (above && out_above_rev)
        bad_hold << [va['visual_id'], vb['visual_id']] if (left || above) && !((left && out_left) || (above && out_above))
      end
    end
    [bad_inv.uniq, bad_hold.uniq]
  end
  { 'page-p1' => v1.reject { |v| v['visual_id'] == 'c3x' }, 'page-p3' => v3, 'page-p4' => v4 }.each do |pid, vs|
    inv, hold = content_pairs.call(pid, vs)
    ok("#{pid}: no left-of / above relation is inverted on the output grid", inv.empty?)
    ok("#{pid}: every source arrangement relation (left-of / above) holds on the output grid#{hold.empty? ? '' : " #{hold.inspect}"}", hold.empty?)
  end

  # -- p1 details ----------------------------------------------------------------
  b1 = pages['page-p1'][:boxes]
  kpis = %w[k1 k2 k3].map { |v| b1[eid(v)] }
  ok('p1: the three cards have equal width and identical height', kpis.map { |b| b[1] - b[0] }.uniq.length == 1 && kpis.map { |b| b[3] - b[2] }.uniq == [5])
  ok('p1: the cards share one row (same top)', kpis.map { |b| b[2] }.uniq.length == 1)
  tb = b1[eid('t1')]
  ok('p1: the table is sized from row_cardinality (5 + ceil(1.25 * 23) = 34, clamped to 30 rows)', (tb[3] - tb[2]).round == 30)
  ok('p1: the table sits under the cards, right of the charts', tb[2] >= kpis[0][3] && tb[0] >= b1[eid('c1')][1])
  c1b = b1[eid('c1')]
  c2c = pages['page-p1'][:containers]["band-page-p1-legend-#{eid('c2')}"]
  ok('p1: a chart under 300px tall gets 10 rows', (c1b[3] - c1b[2]).round == 10 && (c2c[:box][3] - c2c[:box][2]).round == 10)
  ok('p1: the left charts and the right column end on the same row (equalised)',
     [b1[eid('c1')], c2c[:box], b1[eid('c3')]].map { |b| b[3] }.max == tb[3])
  ok('p1: a header band was created from the page name',
     els['band-page-p1-hdrtext']['body'].include?('Orders Overview') && pages['page-p1'][:containers].key?('band-page-p1-hdr'))
  ok('p1: the legend of a chart WITH a color column rides inside the chart\'s own container',
     c2c && c2c[:children].sort == [eid('c2'), "#{eid('c2')}-legend"].sort)
  ok('p1: the legend of a chart with NO color column is dropped (spec + layout)',
     !els.key?("#{eid('c3')}-legend") && !layout.include?("#{eid('c3')}-legend"))
  ok('p1: no controls band without visible controls and no hidden band', !pages['page-p1'][:containers].key?('band-page-p1-ctrl') &&
                                                                          !pages['page-p1'][:containers].key?('band-page-p1-hctrl'))

  # -- p2: control band + hidden band --------------------------------------------
  ct = pages['page-p2'][:containers]
  band = ct['band-page-p2-ctrl']
  ok('p2: a control band holds the 8 visible slicers', band && band[:children].length == 8)
  cells = band[:kids_xml].elements.to_a.map { |e| [e.attributes['elementId'], span(e.attributes['gridColumn']), span(e.attributes['gridRow'])] }
  ok('p2: control band packs 6 per row, 4 columns each, 3 rows per control row',
     cells.first(6).map { |_, c, _| c[1] - c[0] }.uniq == [4] && cells.first(6).map { |_, _, r| r }.uniq == [[1, 4]] &&
     cells.last(2).map { |_, _, r| r }.uniq == [[4, 7]] && band[:rel][3] - band[:rel][2] == 6)
  ok('p2: controls keep the source order (y, then x)', cells.map(&:first) == vis_ctrls.map { |c| eid(c) })
  hb = ct['band-page-p2-hctrl']
  ok('p2: the hidden band exists and holds all 10 hidden controls (flagged + unmatched)',
     hb && (hb[:children] - ['band-page-p2-hctrl-hdr']).sort == (hid_flagged + hid_unmatched).map { |c| eid(c) }.sort)
  ok('p2: the hidden band has a small "More filters" text, rebuilt', els['band-page-p2-hctrl-hdr']['body'] == '**More filters** (hidden in the source report)')
  # Sigma text bodies accept only #, ## and ### headings: a #### heading makes PUT /contents return 400.
  ok('p2: no polished text uses a heading deeper than ###',
     els.values.none? { |e| e['kind'] == 'text' && e['body'].to_s =~ /^\s*####/ })
  hcells = hb[:kids_xml].elements.to_a.reject { |e| e.attributes['elementId'].end_with?('hctrl-hdr') }
  ok('p2: hidden controls pack 6 per row too', hcells.map { |e| span(e.attributes['gridRow']) }.group_by(&:itself).map { |_, v| v.length }.sort == [4, 6])
  top_of = ->(id) { (pages['page-p2'][:boxes][id] || ct[id][:box])[2] }
  ok('p2: header < control band < content < hidden band, top to bottom',
     top_of.call('band-page-p2-hdr') < top_of.call('band-page-p2-ctrl') && top_of.call('band-page-p2-ctrl') < top_of.call(eid('ch')) &&
     top_of.call(eid('ch')) < top_of.call('band-page-p2-hctrl'))
  ok('p2: the existing header band text is kept', els['p2-title']['body'].include?('Regional Slicers') && ct['band-page-p2-hdr'][:children] == ['p2-title'])
  ok('p2: the table with a 2-row source is not below its kind minimum (10 rows)',
     (pages['page-p2'][:boxes][eid('tb')][3] - pages['page-p2'][:boxes][eid('tb')][2]).round >= 10)
  hidden_by_page = %w[page-p1 page-p3 page-p4].map { |p| pages[p][:containers].key?("band-#{p}-hctrl") }
  ok('hidden band exists ONLY on the page with hidden controls', hidden_by_page == [false, false, false])
  ok('the hidden-band text element exists only for p2', %w[p1 p3 p4].none? { |p| els.key?("band-page-#{p}-hctrl-hdr") })

  # -- p3: KPI row of 4 ---------------------------------------------------------
  b3 = pages['page-p3'][:boxes]
  k4 = (1..4).map { |i| b3[eid("m#{i}")] }
  ok('p3: four cards, equal widths (6 columns) and identical heights (5 rows)',
     k4.map { |b| b[1] - b[0] } == [6, 6, 6, 6] && k4.map { |b| b[3] - b[2] }.uniq == [5] && k4.map { |b| b[2] }.uniq.length == 1)
  ok('p3: the chart sits under the cards, full width', b3[eid('trend')][2] >= k4[0][3] && (b3[eid('trend')][1] - b3[eid('trend')][0]) == 24)
  ok('p3: an element with no source box is placed after the content',
     b3['el-synthetic'][2] >= b3[eid('trend')][3])

  # -- p4: label + caption --------------------------------------------------------
  b4 = pages['page-p4'][:boxes]
  ok('p4: a section label becomes ### <label> and is 2 rows', els[eid('lbl')]['body'] == '### Section' &&
                                                               (b4[eid('lbl')][3] - b4[eid('lbl')][2]).round == 2)
  ok('p4: a caption loses its leading heading marks', els[eid('note')]['body'] == LONG)
  ok('p4: a long caption gets 3 + chars/180 rows', (b4[eid('note')][3] - b4[eid('note')][2]).round == 3 + LONG.length / 180)
  ok('p4: a table with no row_cardinality uses 14 (5 + ceil(17.5) = 23 rows)', (b4[eid('tblA')][3] - b4[eid('tblA')][2]).round == 23)
  ok('p4: the chart beside the taller table is stretched to equalise (23 rows); a source box >= 300px gets 12 (p3)',
     (b4[eid('chartA')][3] - b4[eid('chartA')][2]).round == 23 && (b3[eid('trend')][3] - b3[eid('trend')][2]).round == 12)
  ok('p4: an explicit tableStyle is kept (preset), headers still wrap',
     els[eid('tblA')]['tableStyle']['preset'] == 'spreadsheet' && els[eid('tblA')]['tableStyle'].dig('textStyles', 'header', 'textWrap') == 'wrap')

  # -- element tweaks -------------------------------------------------------------
  ok('tables get tableStyle presentation with wrapping column headers',
   els[eid('t1')]['tableStyle'] == { 'preset' => 'presentation', 'textStyles' => { 'header' => { 'textWrap' => 'wrap' } } })
  amount = els[eid('t1')]['columns'].find { |c| c['name'] == 'Amount' }
  region = els[eid('t1')]['columns'].find { |c| c['name'] == 'Region' }
  ok('a number-formatted column gets displayNullAs ""', amount['format']['displayNullAs'] == '' && amount['format']['formatString'] == '$,.0f')
  ok('an unformatted column is untouched', !region.key?('format'))

  # -- structural contracts -------------------------------------------------------
  empties = pages.flat_map { |pid, p| p[:containers].select { |_, c| c[:children].empty? }.keys.map { |id| "#{pid}/#{id}" } }
  ok('no empty containers', empties.empty?)
  ids = elements_of(out).map { |e| e['id'] }
  placed = layout.scan(/\belementId="([^"]+)"/).flatten
  ok('every element is placed exactly once and every placement has an element',
     placed.sort == ids.sort && placed.uniq.length == placed.length)
  ok('every container placeholder in the layout has a kind: container spec element and vice versa',
     placed.select { |i| i.start_with?('band-') && els[i] && els[i]['kind'] == 'container' }.sort ==
     ids.select { |i| els[i]['kind'] == 'container' }.sort)
  ok('every container uses gridTemplateRows="auto"', layout.scan(/<Container\b[^>]*>/).all? { |t| t.include?('gridTemplateRows="auto"') })
  ok('container children use container-relative rows (restart at 1)',
     pages.values.flat_map { |p| p[:containers].values }.all? { |c| c[:kids_xml].elements.to_a.map { |e| span(e.attributes['gridRow'])[0] }.min == 1 })
  lint = LayoutLint.lint(out)
  ok("layout lint is clean#{lint.empty? ? '' : " #{lint.inspect}"}", lint.empty?)
  pf_ok, pf_out = sh(PREFLIGHT, out_path)
  ok("preflight lint is clean#{pf_ok ? '' : " #{pf_out}"}", pf_ok)
  v_ok, v_out = sh(VALIDATE, '--type', 'workbook', out_path)
  ok("validate-spec.rb passes#{v_ok ? '' : " #{v_out}"}", v_ok)

  # -- layout-geometry-check: 0 inversions ------------------------------------------
  geo_out = File.join(d, 'geo.json')
  g_ok, g_log = sh(GEOMETRY, '--signals', File.join(d, 'signals.json'), '--spec', out_path, '--out', geo_out)
  geo = g_ok ? JSON.parse(File.read(geo_out)) : { 'summary' => {} }
  ok("layout-geometry-check reports 0 inverted visuals (#{g_log.lines.last.to_s.strip})", g_ok && geo['summary']['inverted_visuals'] == 0)

  # -- idempotence ------------------------------------------------------------------

  Dir.mkdir(File.join(d, 'again')) unless Dir.exist?(File.join(d, 'again'))
  st2, _log2, _out2, out2_path = run_polish(File.join(d, 'again'), out, SIGNALS, 'out2')
  ok('a second run succeeds', st2)
  ok('idempotent: polishing a polished spec reproduces it byte for byte', File.read(out_path) == File.read(out2_path))
  ok('the layout XML written by --layout-out matches the spec layout', File.read(File.join(d, 'out.xml')) == out['document']['layout'])
  # the original input is untouched by the library (pure)
  ok('polish does not mutate its inputs', JSON.generate(SPEC) == JSON.generate(JSON.parse(JSON.generate(SPEC))) &&
                                           SPEC['document']['layout'].include?('band-page-p2-hctrl'))

  # -- the other spec shape: a top-level `layout` / `elements` ----------------------
  flat = { 'name' => 'Sales Overview', 'pages' => pages_meta, 'elements' => Marshal.load(Marshal.dump(elements)), 'layout' => SPEC['document']['layout'] }
  fst, _flog, fout, = run_polish(d, flat, SIGNALS, 'flat')
  ok('a top-level layout/elements spec is polished in its own shape', fst && fout.key?('layout') && !fout.key?('document') &&
                                                                       fout['layout'] == out['document']['layout'])
end

# ---- unit: the XY-cut --------------------------------------------------------
def lf(id, x0, y0, x1, y1, cls = :chart)
  { id: id, cls: cls, x0: x0.to_f, y0: y0.to_f, x1: x1.to_f, y1: y1.to_f, el: { 'kind' => 'bar-chart' } }
end
sh_of = ->(items) { PolishLayout.shape(PolishLayout.xy_cut(items)) }
ok('xy_cut: stacked boxes -> bands', sh_of.call([lf('a', 0, 0, 100, 100), lf('b', 0, 120, 100, 220)]) == 'chart / chart')
ok('xy_cut: side-by-side boxes -> columns', sh_of.call([lf('a', 0, 0, 100, 100), lf('b', 120, 0, 220, 100)]) == 'chart | chart')
ok('xy_cut: an overlap under 8px does not block a horizontal cut between stacked boxes',
   sh_of.call([lf('a', 0, 0, 100, 100), lf('b', 0, 93, 100, 200)]) == 'chart / chart')
ok('xy_cut: an overlap of 8px or more blocks every cut (genuinely overlapping boxes share one row, left to right)',
   sh_of.call([lf('a', 0, 0, 100, 100), lf('b', 0, 90, 100, 200)]) == 'chart | chart')
diag = PolishLayout.xy_cut([lf('a', 0, 0, 100, 100), lf('b', 200, 95, 300, 200)])
ok('xy_cut: a tiny y overlap between boxes that are side by side keeps them in columns (left-of preserved)', PolishLayout.shape(diag) == 'chart | chart')
pin = [lf('a', 0, 0, 200, 100), lf('b', 200, 0, 300, 200), lf('c', 100, 200, 300, 300), lf('d', 0, 100, 100, 300)]
tree = PolishLayout.xy_cut(pin)
ok('xy_cut: a pinwheel (no cut in either axis) falls back to rows sorted by (y, x)',
   PolishLayout.shape(tree) == '(chart | chart) / (chart | chart)' && PolishLayout.node_leaves(tree).map { |l| l[:id] } == %w[a b d c])
ok('xy_cut: empty input is nil', PolishLayout.xy_cut([]).nil?)
# column widths: proportional, minimums respected, sum exactly 24
leaves = [lf('a', 0, 0, 100, 100), lf('b', 110, 0, 1200, 100)]
w = PolishLayout.alloc_widths(leaves.map { |l| PolishLayout.leaf_node(l) }, 24)
ok('alloc_widths: minimum 6 columns for a chart, sum exact', w.sum == 24 && w[0] == 6 && w[1] == 18)
w3 = PolishLayout.alloc_widths([lf('a', 0, 0, 400, 100), lf('b', 410, 0, 800, 100), lf('c', 810, 0, 1200, 100)].map { |l| PolishLayout.leaf_node(l) }, 24)
ok('alloc_widths: three equal source columns -> 8/8/8', w3 == [8, 8, 8])
five = (0..4).map { |i| PolishLayout.leaf_node(lf("c#{i}", i * 200, 0, i * 200 + 190, 100)) }
w5, = PolishLayout.render({ t: :cols, kids: five }.tap { |n| n[:kids].each { |k| k[:leaf][:rows] = 10 } }, 1, 24, 1)
ok('render: 5 charts across (minimums overflow) are rebalanced to sum 24 without wrapping',
   w5.map { |c| c[2] - c[1] }.sum == 24 && w5.map { |c| c[3] }.uniq == [1])
kp = (0..8).map { |i| PolishLayout.leaf_node(lf("k#{i}", i * 100, 0, i * 100 + 90, 100, :kpi)) }
kp.each { |k| k[:leaf][:rows] = 5; k[:leaf][:el] = { 'kind' => 'kpi-chart' } }
kc, = PolishLayout.render({ t: :cols, kids: kp }, 1, 24, 1)
ok('render: 9 KPI peers have equal widths (+/- the remainder column) and sum 24',
   kc.map { |c| c[2] - c[1] }.sum == 24 && (kc.map { |c| c[2] - c[1] }.max - kc.map { |c| c[2] - c[1] }.min) <= 1)
# the last stretchable element of the shorter column absorbs the surplus; KPIs / text are never stretched
tall = PolishLayout.leaf_node(lf('tall', 0, 0, 100, 100).merge(rows: 20))
mini = PolishLayout.xy_cut([lf('k', 120, 0, 220, 50, :kpi), lf('c', 120, 60, 220, 160)])
PolishLayout.node_leaves(mini).each { |l| l[:rows] = l[:cls] == :kpi ? 5 : 10; l[:el] = { 'kind' => l[:cls] == :kpi ? 'kpi-chart' : 'bar-chart' } }
cells, hh = PolishLayout.render({ t: :cols, kids: [tall, mini] }, 1, 24, 1)
ck = cells.find { |c, *_| c[:id] == 'k' }
cc = cells.find { |c, *_| c[:id] == 'c' }
ok('render: the shorter column\'s chart is stretched to equalise; the KPI keeps 5 rows', hh == 20 && (ck[4] - ck[3]) == 5 && (cc[4] - cc[3]) == 15)
tk = PolishLayout.xy_cut([lf('k1', 0, 0, 100, 50, :kpi), lf('k2', 0, 60, 100, 110, :kpi)])
PolishLayout.node_leaves(tk).each { |l| l[:rows] = 5 }
tcells, th = PolishLayout.render({ t: :cols, kids: [PolishLayout.leaf_node(lf('t', 120, 0, 220, 100, :text).merge(rows: 30)), tk] }, 1, 24, 1)
ok('render: nothing stretchable in the shorter column -> KPIs are not stretched', th == 30 && tcells.select { |cell| cell[0][:cls] == :kpi }.all? { |cell| cell[4] - cell[3] == 5 })
# control packing
pk = PolishLayout.pack_controls((1..5).map { |i| { id: "d#{i}", date_range: true } })
ok('pack_controls: date-range controls take 6 columns (4 per row)', pk[:cells].first(4).map { |_, a, b, *| b - a } == [6, 6, 6, 6] && pk[:height] == 6)
pm = PolishLayout.pack_controls([{ id: 'a', date_range: true }, { id: 'b' }, { id: 'c' }, { id: 'd' }, { id: 'e' }, { id: 'f' }])
ok('pack_controls: a mixed row fills to 24 columns then wraps', pm[:cells].map { |c| c[3] } == [1, 1, 1, 1, 1, 4] && pm[:cells][1][1] == 7)
ok('pack_controls: an empty list is an empty band', PolishLayout.pack_controls([]) == { height: 0, cells: [] })
# table height rule
ok('table_rows: clamp(5 + ceil(1.25n), 10, 30)',
   [PolishLayout.table_rows(2), PolishLayout.table_rows(6), PolishLayout.table_rows(15), PolishLayout.table_rows(100), PolishLayout.table_rows(nil)] == [10, 13, 24, 30, 23])
ok('pivot rows: clamp(5 + ceil(1.25n) + 2L, 10, 32), n + 1 with a totals row (n=6 / 15 / 8 with L=3)',
   [PolishLayout.table_rows(6, pivot: true), PolishLayout.table_rows(15, pivot: true), PolishLayout.table_rows(8, pivot: true, levels: 3),
    PolishLayout.table_rows(5, pivot: true, totals: true), PolishLayout.table_rows(100, pivot: true, levels: 3)] == [13, 24, 21, 13, 32])
ok('text_subclass: label / text / caption', [PolishLayout.text_subclass('## Section'), PolishLayout.text_subclass('x' * 80), PolishLayout.text_subclass('x' * 130), PolishLayout.text_subclass("a\nb")] == %i[label text caption caption])
# a page with no signals page, and a spec with no layout
nolayout = begin
  PolishLayout.polish({ 'name' => 'x', 'document' => { 'elements' => [] } }, SIGNALS)
  false
rescue ArgumentError
  true
end
ok('a spec with no layout is refused loudly', nolayout)
_, none = PolishLayout.polish(SPEC, { 'pages' => [] })
ok('pages without a signals page are left alone', none.empty?)

# ---- live-render tuning: heights, widths, wrap, KPI peers, year legend -------------
# mini(): one visible page of [element, visual] pairs -> [polished elements by id, parsed boxes]
def mini_doc(pairs, mode = 'drawer', hide_titles: false)
  els = [{ 'id' => MASTER, 'kind' => 'table', 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB PUBLIC SALES] },
           'columns' => [col('mc-region', '[SALES/Region]', 'Region')] }] + pairs.map(&:first)
  layout = SigmaLayout.assemble(SigmaLayout.page_xml('page-data', le(MASTER, 1, 25, 1, 11)),
                                SigmaLayout.page_xml('page-q', pairs.each_with_index.map { |(e, _), i| le(e['id'], 1, 25, i * 10 + 1, i * 10 + 11) }.join("\n")))
  spec = { 'name' => 'Mini', 'document' => { 'schemaVersion' => 1, 'kind' => 'workbook',
                                            'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden' }, { 'id' => 'page-q', 'name' => 'Q' }],
                                            'elements' => els, 'layout' => layout } }
  sig = { 'pages' => [{ 'page_id' => 'q', 'page_title' => 'Q', 'page_w' => 1280, 'page_h' => 900, 'visuals' => pairs.map(&:last) }] }
  out, = PolishLayout.polish(spec, sig, hidden_controls: mode, hide_derived_titles: hide_titles)
  out
end

def mini(pairs)
  out = mini_doc(pairs)
  [out['document']['elements'].each_with_object({}) { |e, h| h[e['id']] = e }, parse_layout(out['document']['layout'])['page-q'][:boxes]]
end

def pivot_el(vid, n_values: 3, columns_by: 0, totals: false, rows_name: 'Region', extra: {})
  e = eid(vid)
  el = { 'id' => e, 'kind' => 'pivot-table', 'name' => vid, 'source' => { 'elementId' => MASTER, 'kind' => 'table' },
         'columns' => [col("#{e}-r", "[#{MASTER}/Region]", rows_name)] +
                      (0...n_values).map { |i| col("#{e}-v#{i}", "Sum([#{MASTER}/Amount])", "M#{i}") } +
                      (0...columns_by).map { |i| col("#{e}-c#{i}", "[#{MASTER}/Seg#{i}]", "Seg#{i}") },
         'rowsBy' => [{ 'columnId' => "#{e}-r" }], 'values' => (0...n_values).map { |i| "#{e}-v#{i}" } }
  el['columnsBy'] = (0...columns_by).map { |i| { 'columnId' => "#{e}-c#{i}" } } if columns_by.positive?
  el['totals'] = { 'showGrandTotals' => 'shown', 'totalPosition' => 'last' } if totals
  el.merge(extra)
end

def rows_of(boxes, vid)
  b = boxes[eid(vid)]
  (b[3] - b[2]).round
end

# 1. heights: n = 6 / 15 / 8 (L = 3), totals row adds one
pv = [[pivot_el('pa'), vis('pa', 'pivotTable', 0, 0, 1280, 300, 'row_cardinality' => 6)],
      [pivot_el('pb'), vis('pb', 'pivotTable', 0, 320, 1280, 300, 'row_cardinality' => 15)],
      [pivot_el('pc', columns_by: 3), vis('pc', 'pivotTable', 0, 640, 1280, 300, 'row_cardinality' => 8)],
      [pivot_el('pd', totals: true), vis('pd', 'pivotTable', 0, 960, 1280, 300, 'row_cardinality' => 14)]]
pels, pboxes = mini(pv)
ok('pivot heights: n=6 -> 13, n=15 -> 24, n=8 with 3 column levels -> 21, 14 + totals row -> 24',
   [rows_of(pboxes, 'pa'), rows_of(pboxes, 'pb'), rows_of(pboxes, 'pc'), rows_of(pboxes, 'pd')] == [13, 24, 21, 24])
pa = pels[eid('pa')]
ok('every pivot gets tableStyle.textStyles.columnHeader.textWrap = wrap and align = right',
   %w[pa pb pc pd].all? { |v| pels[eid(v)]['tableStyle'].dig('textStyles', 'columnHeader') == { 'textWrap' => 'wrap', 'align' => 'right' } } &&
   pa['tableStyle']['preset'] == 'presentation')
# 2. pivot uniform widths: cell = 1536 - 32 = 1504; header = min(7*max(6,20)+16, 0.35*1504) = 156 (member labels
#    are usually longer than the dimension name); body = floor((1504-156-8)/3) = 446
ok('a pivot without columnsBy gets header and body uniformWidth (156 / 446 on a full-width cell)',
   pa['display'] == { 'headerWidths' => { 'uniformWidth' => 156 }, 'bodyWidths' => { 'uniformWidth' => 446 } })
ok('a pivot never gets columns[] widths or autofitColumns',
   pels.values.select { |e| e['kind'] == 'pivot-table' }.all? { |e| e['columns'].none? { |c| c.key?('style') } && !e['tableStyle'].key?('autofitColumns') })
ok('a pivot WITH columnsBy gets no uniform widths', !pels[eid('pc')].key?('display'))
wide, = mini([[pivot_el('pw', n_values: 40), vis('pw', 'pivotTable', 0, 0, 1280, 300, 'row_cardinality' => 5)]])
ok('a pivot whose body would be under 48px gets no widths (floor((1504-156-8)/40) = 33)', !wide[eid('pw')].key?('display'))
keep, = mini([[pivot_el('pk', extra: { 'display' => { 'bodyWidths' => { 'uniformWidth' => 90 } },
                                       'tableStyle' => { 'textStyles' => { 'columnHeader' => { 'textWrap' => 'clip', 'fontSize' => 9, 'align' => 'left' } } } }),
               vis('pk', 'pivotTable', 0, 0, 1280, 300, 'row_cardinality' => 5)]])
ok('existing display widths and an explicit textWrap / align are kept',
   keep[eid('pk')]['display']['bodyWidths']['uniformWidth'] == 90 && keep[eid('pk')]['display']['headerWidths']['uniformWidth'] == 156 &&
   keep[eid('pk')]['tableStyle']['textStyles']['columnHeader'] == { 'textWrap' => 'clip', 'fontSize' => 9, 'align' => 'left' })
# 2b. a pivot with >= 10 value columns uses a 12px cell / row-header font so large totals fit the body width;
#     narrower pivots keep the default size, and an explicit fontSize is kept
w12, = mini([[pivot_el('p12', n_values: 12), vis('p12', 'pivotTable', 0, 0, 1280, 300, 'row_cardinality' => 14)],
             [pivot_el('p9', n_values: 9), vis('p9', 'pivotTable', 0, 320, 1280, 300, 'row_cardinality' => 14)]])
ts12 = w12[eid('p12')]['tableStyle']['textStyles']
ok('2b a 12-value pivot gets cell and rowHeader fontSize 12', ts12['cell'] && ts12['cell']['fontSize'] == 12 && ts12['rowHeader'] && ts12['rowHeader']['fontSize'] == 12)
ok('2b a 9-value pivot keeps the default font size', !w12[eid('p9')]['tableStyle']['textStyles'].key?('cell'))
# 2c. currency with cents that cannot fit the uniform body width drops the cents ($,.2f -> $,.0f);
#     a pivot whose body is wide enough keeps them; percentages are untouched
cur = ->(vid, n) { pivot_el(vid, n_values: n).tap { |e| e['columns'].each { |c| c['format'] = { 'kind' => 'number', 'formatString' => '$,.2f' } if c['id'].include?('-v') }; e['columns'].last['format'] = { 'kind' => 'number', 'formatString' => ',.2%' } } }
cw, = mini([[cur.call('pcur', 13), vis('pcur', 'pivotTable', 0, 0, 1280, 300, 'row_cardinality' => 14)],
            [cur.call('pfit', 3), vis('pfit', 'pivotTable', 0, 320, 1280, 300, 'row_cardinality' => 14)]])
fmts = ->(vid) { cw[eid(vid)]['columns'].select { |c| c['id'].include?('-v') }.map { |c| c['format']['formatString'] } }
ok('2c a 13-value pivot (body < 125px) drops currency cents, keeps the percentage',
   fmts.call('pcur')[0...-1].uniq == ['$,.0f'] && fmts.call('pcur').last == ',.2%')
ok('2c a 3-value pivot keeps its cents', fmts.call('pfit')[0...-1].uniq == ['$,.2f'])
# 3. flat tables > 6 columns fill the cell
def wide_table(vid, n_text: 3, n_num: 3, n_pct: 2)
  e = eid(vid)
  cols = (0...n_text).map { |i| col("#{e}-t#{i}", "[#{MASTER}/T#{i}]", "Text #{i}") } +
         (0...n_num).map { |i| col("#{e}-n#{i}", "Sum([#{MASTER}/N#{i}])", "Num #{i}", 'kind' => 'number', 'formatString' => '$,.0f') } +
         (0...n_pct).map { |i| col("#{e}-p#{i}", "[#{MASTER}/P#{i}]", "Pct #{i}", 'kind' => 'number', 'formatString' => '.1%') }
  cols[0]['style'] = { 'fontSize' => 12 }
  { 'id' => e, 'kind' => 'table', 'name' => vid, 'source' => { 'elementId' => MASTER, 'kind' => 'table' }, 'columns' => cols }
end
tels, = mini([[wide_table('wt'), vis('wt', 'tableEx', 0, 0, 1280, 300, 'row_cardinality' => 10)],
              [wide_table('nt', n_text: 2, n_num: 2, n_pct: 2), vis('nt', 'tableEx', 0, 320, 1280, 300, 'row_cardinality' => 10)]])
tcols = tels[eid('wt')]['columns']
widths = tcols.map { |c| c.dig('style', 'width') }
ok('a table with 8 columns gets a width per column summing to ~ the cell (1504px)', widths.none?(&:nil?) && (widths.sum - 1504).abs <= 8)
ok('column weights: text 1.4 > number 1.0 > percentage 0.7, 60px minimum',
   widths[0] > widths[3] && widths[3] > widths[6] && widths.min >= 60 && widths[0] == (1504 * 1.4 / 8.6).round)
ok('an existing column style key is kept next to the new width', tcols[0]['style']['fontSize'] == 12)
ok('a table with 6 columns or fewer gets no widths', tels[eid('nt')]['columns'].none? { |c| c.dig('style', 'width') })
# 4. KPI-only columns round to a multiple of lcm(peers per row)
kp = lambda do |prefix, specs|
  specs.map { |nm, x, y| [kpi_el("#{prefix}#{nm}"), vis("#{prefix}#{nm}", 'card', x, y, 140, 100)] }
end
five = kp.call('f', [['a', 0, 0], ['b', 150, 0], ['c', 300, 0], ['d', 0, 120], ['e', 225, 120]]).each_with_index.map do |(e, v), i|
  v['w'] = 215 if i >= 3
  [e, v]
end
_, fb = mini(five + [[chart_el('fchart'), vis('fchart', 'barChart', 460, 0, 540, 220)]])
fk = %w[fa fb fc].map { |n| fb[eid(n)] }
fk2 = %w[fd fe].map { |n| fb[eid(n)] }
ok('3 + 2 KPI cards in an 11-column column -> 12 columns: spans 4/4/4 and 6/6, the chart sibling gives one up',
   fk.map { |b| b[1] - b[0] } == [4, 4, 4] && fk2.map { |b| b[1] - b[0] } == [6, 6] && fb[eid('fchart')][1] - fb[eid('fchart')][0] == 12)
three = kp.call('g', [['a', 0, 0], ['b', 220, 0], ['c', 440, 0]]).map { |e, v| v['w'] = 200; [e, v] }
_, gb = mini(three + [[chart_el('gchart'), vis('gchart', 'barChart', 660, 0, 340, 220)]])
ok('3 KPI cards in a 16-column column -> 15 (5/5/5), the sibling chart takes the spare column',
   %w[ga gb gc].map { |n| gb[eid(n)][1] - gb[eid(n)][0] } == [5, 5, 5] && gb[eid('gchart')][1] - gb[eid('gchart')][0] == 9)
# the snap respects the sibling's minimum (a chart needs 6 columns)
snapped = PolishLayout.snap_kpi_columns!(
  [{ t: :cols, kids: Array.new(3) { |i| PolishLayout.leaf_node(lf("k#{i}", 0, 0, 1, 1, :kpi)) } },
   PolishLayout.leaf_node(lf('c', 0, 0, 1, 1))], [14, 6]
)
ok('snap_kpi_columns!: 15 is nearest to 14 but the chart sibling (min 6) cannot lend a column -> falls to 12, sibling gains 2',
   snapped == [12, 8])
# 5. year legend format
yc = ->(vid, name, formula, extra = {}) do
  e = eid(vid)
  el = chart_el(vid, color: true)
  el['columns'] << col("#{e}-c", formula, name)
  el['columns'].last.merge!(extra)
  el['color'] = { 'by' => 'category', 'column' => "#{e}-c" }
  [el, vis(vid, 'lineChart', 0, 0, 600, 250)]
end
yels, = mini([yc.call('y1', 'Order Year', '[SALES/Order Year]'), yc.call('y2', 'Period', '[SALES/Fiscal Year]'),
              yc.call('y3', 'Year', '[SALES/Yr]'), yc.call('y4', 'Yearly Sales', '[SALES/Yearly Sales]'),
              yc.call('y5', 'Order Year', '[SALES/Order Year]', 'format' => { 'kind' => 'number', 'formatString' => '0' })])
fmt_of = ->(v) { yels[eid(v)]['columns'].last['format'] }
ok('a year color column with no format gets format { kind: number, formatString: d } (by name or by referenced column)',
   fmt_of.call('y1') == { 'kind' => 'number', 'formatString' => 'd' } && fmt_of.call('y2') == { 'kind' => 'number', 'formatString' => 'd' } &&
   fmt_of.call('y3') == { 'kind' => 'number', 'formatString' => 'd' })
ok('a non-year color column and an already formatted year column are left alone', fmt_of.call('y4').nil? && fmt_of.call('y5')['formatString'] == '0')
ok('the year format is not applied to non-color columns', yels[eid('y1')]['columns'].first(2).none? { |c| c.key?('format') })

# ---- hidden controls in a FILTERS DRAWER (default) ----------------------------------
Dir.mktmpdir do |d|
  st, log, dout, dpath = run_polish(d, SPEC, SIGNALS, 'drawer', 'drawer')
  ok('drawer mode: the CLI exits 0', st)
  abort(log) unless st
  dl = dout['document']['layout']
  dels = by_id(dout)
  dpages = parse_layout(dl)
  hidden_ids = (hid_flagged + hid_unmatched).map { |c| eid(c) }
  ov = dout['document']['overlays']
  ok('(a) one overlay: drawer-page-p2, type drawer, medium, shadow shown, title Filters',
     ov == [{ 'id' => 'drawer-page-p2', 'type' => 'drawer', 'name' => 'Filters',
              'drawer' => { 'width' => 'medium', 'showShadow' => 'shown', 'header' => { 'title' => 'Filters' } } }])
  ok('(a) the overlay id is not in document.pages', dout['document']['pages'].none? { |p| p['id'] == 'drawer-page-p2' })
  ok('(a) the drawer <Page> is appended AFTER the real pages and uses the grid page shape',
     dl.rindex('<Page') == dl.index('<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="drawer-page-p2">') &&
     dpages.keys.last == 'drawer-page-p2')
  db = dpages['drawer-page-p2'][:boxes]
  ok('(a) the drawer holds every hidden control, one per row (1 / 25, 3 rows each), in source order',
     db.keys == (hid_flagged.map { |c| eid(c) } + hid_unmatched.map { |c| eid(c) }) &&
     db.values.each_with_index.all? { |b, i| b[0] == 1 && b[1] == 25 && b[2] == i * 3 + 1 && b[3] == i * 3 + 4 })
  ok('(a) hidden controls keep their filters targets and are no longer placed on the page',
     hidden_ids.all? { |i| dels[i]['filters'] == [{ 'source' => { 'kind' => 'table', 'elementId' => MASTER }, 'columnId' => 'mc-region' }] } &&
     (hidden_ids & dpages['page-p2'][:boxes].keys).empty? && dpages['page-p2'][:containers].values.none? { |c| (c[:children] & hidden_ids).any? })
  ok('(a) pages without hidden controls get no drawer and no button',
     %w[p1 p3 p4].none? { |p| dpages.key?("drawer-page-#{p}") || dels.key?("btn-page-#{p}-filters") })
  btn = dels['btn-page-p2-filters']
  ok('(b) the button has the verified shape with N = 10',
     btn == { 'id' => 'btn-page-p2-filters', 'kind' => 'button', 'text' => 'More filters (10)', 'appearance' => 'filled',
              'actions' => [{ 'id' => 'a-page-p2-filters', 'trigger' => 'on-click',
                              'effects' => [{ 'effect' => 'open-overlay', 'overlayId' => 'drawer-page-p2' }] }] })
  cband = dpages['page-p2'][:containers]['band-page-p2-ctrl']
  bcell = cband[:kids_xml].elements.to_a.find { |e| e.attributes['elementId'] == 'btn-page-p2-filters' }
  ok('(b) the button is the right-end 4 columns of the control band last row (8 controls: last row has room)',
     bcell && span(bcell.attributes['gridColumn']) == [21, 25] && span(bcell.attributes['gridRow']) == [4, 7] && cband[:rel][3] - cband[:rel][2] == 6)
  ok('(c) no hidden band, no "More filters" label text on the page',
     !dpages['page-p2'][:containers].key?('band-page-p2-hctrl') && !dels.key?('band-page-p2-hctrl-hdr') &&
     dels.values.none? { |e| e['kind'] == 'text' && e['body'].to_s.include?('More filters') } && !dl.include?('hctrl'))
  # (d) band mode: the main fixture run
  Dir.mkdir(File.join(d, 'band')) unless Dir.exist?(File.join(d, 'band'))
  _sb, _lb, bm, = run_polish(File.join(d, 'band'), SPEC, SIGNALS, 'o', 'band')
  ok('(d) band mode still builds the hidden band and no overlay/button',
     !bm['document'].key?('overlays') && !by_id(bm).key?('btn-page-p2-filters') &&
     parse_layout(bm['document']['layout'])['page-p2'][:containers].key?('band-page-p2-hctrl') && !bm['document']['layout'].include?('drawer-'))
  # (e) idempotence, in place and across a mode switch
  Dir.mkdir(File.join(d, 'a')) unless Dir.exist?(File.join(d, 'a'))
  Dir.mkdir(File.join(d, 'b')) unless Dir.exist?(File.join(d, 'b'))
  Dir.mkdir(File.join(d, 'c')) unless Dir.exist?(File.join(d, 'c'))
  Dir.mkdir(File.join(d, 'e')) unless Dir.exist?(File.join(d, 'e'))
  _s1, _l1, _o1, p_d2 = run_polish(File.join(d, 'a'), dout, SIGNALS, 'o', 'drawer')
  ok('(e) drawer mode is idempotent byte for byte', File.read(dpath) == File.read(p_d2))
  _s2, _l2, band_out, p_b = run_polish(File.join(d, 'b'), dout, SIGNALS, 'o', 'band')
  ok('(e) drawer -> band: overlay, button and drawer page are removed; the hidden band is back',
     !band_out['document'].key?('overlays') && !band_out['document']['layout'].include?('drawer-') &&
     by_id(band_out).none? { |id, _| id.start_with?('btn-') } &&
     parse_layout(band_out['document']['layout'])['page-p2'][:containers]['band-page-p2-hctrl'][:children].length == 11)
  _s3, _l3, _o3, p_b2 = run_polish(File.join(d, 'c'), band_out, SIGNALS, 'o', 'band')
  ok('(e) band mode is idempotent after a switch', File.read(p_b) == File.read(p_b2))
  _s4, _l4, _o4, p_d3 = run_polish(File.join(d, 'e'), band_out, SIGNALS, 'o', 'drawer')
  ok('(e) band -> drawer reproduces the first drawer output byte for byte', File.read(dpath) == File.read(p_d3))

  # (f) lint / validate / geometry accept the overlay page
  lint = LayoutLint.lint(dout)
  ok("(f) layout lint accepts the overlay page#{lint.empty? ? '' : " #{lint.inspect}"}", lint.empty?)
  pf_ok, pf_out = sh(PREFLIGHT, dpath)
  ok("(f) preflight lint accepts the overlay page#{pf_ok ? '' : " #{pf_out}"}", pf_ok)
  v_ok, v_out = sh(VALIDATE, '--type', 'workbook', dpath)
  ok("(f) validate-spec accepts the overlay page#{v_ok ? '' : " #{v_out}"}", v_ok)
  gout = File.join(d, 'geo-drawer.json')
  g_ok, g_log = sh(GEOMETRY, '--signals', File.join(d, 'signals.json'), '--spec', dpath, '--out', gout)
  geo = g_ok ? JSON.parse(File.read(gout)) : { 'summary' => {}, 'pages' => [] }
  ok("(f) layout-geometry-check accepts it, scores no overlay page, 0 inversions (#{g_log.lines.last.to_s.strip})",
     g_ok && geo['summary']['inverted_visuals'] == 0 && !geo.to_json.include?('drawer-page'))
end

# button placement: full control row -> new row; no visible controls -> header band right side
ctl = lambda do |n, hidden|
  hidden ? vis("x#{n}", 'slicer', 0, 700 + n * 20, 100, 20, 'hidden' => true) : vis("s#{n}", 'slicer', (n % 6) * 200, 0, 140, 60)
end
full_pairs = (0...6).map { |n| [ctrl_el("s#{n}"), ctl.call(n, false)] } + (0...2).map { |n| [ctrl_el("x#{n}"), ctl.call(n, true)] }
fd = mini_doc(full_pairs)
fp = parse_layout(fd['document']['layout'])['page-q'][:containers]['band-page-q-ctrl']
fb = fp[:kids_xml].elements.to_a.find { |e| e.attributes['elementId'] == 'btn-page-q-filters' }
ok('button: a full control row (6 x 4 columns) pushes the button to a new row of its own',
   span(fb.attributes['gridColumn']) == [21, 25] && span(fb.attributes['gridRow']) == [4, 7] && fp[:rel][3] - fp[:rel][2] == 6)
hid_only = mini_doc((0...3).map { |n| [ctrl_el("x#{n}"), ctl.call(n, true)] })
hp = parse_layout(hid_only['document']['layout'])['page-q']
hh = hp[:containers]['band-page-q-hdr']
ok('button: with no visible controls it sits at the right of the header band, text on the left',
   hh[:children].sort == %w[band-page-q-hdrtext btn-page-q-filters] && hp[:containers].key?('band-page-q-hdr') &&
   hh[:kids_xml].elements.to_a.find { |e| e.attributes['elementId'] == 'btn-page-q-filters' }.attributes['gridColumn'] == '21 / 25' &&
   hid_only['document']['elements'].find { |e| e['id'] == 'btn-page-q-filters' }['text'] == 'More filters (3)')
nohid = mini_doc([[chart_el('only'), vis('only', 'barChart', 0, 0, 600, 250)]])
ok('a page with no hidden controls: no overlay, no button, no drawer page',
   !nohid['document'].key?('overlays') && nohid['document']['elements'].none? { |e| e['kind'] == 'button' } && !nohid['document']['layout'].include?('drawer-'))

# the id helper stays in lockstep with the builder's `short`
src = File.read(BUILDER)[/^def short\(id\)\n.*?^end\n/m]
ok('the builder still defines short(id) (found for the lockstep check)', !src.nil?)
if src
  mod = Module.new
  mod.module_eval(src.sub('def short(id)', 'def self.short(id)'))
  probes = %w[v1 abc-123-def a1b2c3d4e5f60001 a1b2c3d4e5f60002 Weird_ID!x]
  ok('PolishLayout.short_id matches the builder\'s short(id)', probes.all? { |p| mod.short(p) == PolishLayout.short_id(p) })
end

# ---- round 3: table header wrap/align, chart defaults, data labels, invented titles ------------------
def line_el(vid, kind: 'line-chart', ys: 1, color: false, extra: {})
  e = eid(vid)
  el = { 'id' => e, 'kind' => kind, 'name' => vid, 'source' => { 'elementId' => MASTER, 'kind' => 'table' },
         'columns' => [col("#{e}-x", "[#{MASTER}/Region]", 'Region')] +
                      (0...ys).map { |i| col("#{e}-y#{i}", "Sum([#{MASTER}/Amount])", "M#{i}") },
         'xAxis' => { 'columnId' => "#{e}-x" }, 'yAxis' => { 'columnIds' => (0...ys).map { |i| "#{e}-y#{i}" } } }
  el['color'] = { 'by' => 'category', 'column' => "#{e}-x" } if color
  el.merge(extra)
end

r3 = [[line_el('l1'), vis('l1', 'lineChart', 0, 0, 600, 300)],
      [line_el('l2', ys: 2), vis('l2', 'lineChart', 640, 0, 600, 300)],
      [line_el('l3', kind: 'area-chart', color: true), vis('l3', 'areaChart', 0, 320, 600, 300)],
      [line_el('l4', ys: 2, extra: { 'legend' => { 'visibility' => 'hidden' },
                                     'yAxis' => { 'columnIds' => %w[a b], 'format' => { 'scale' => { 'type' => 'log' } } } }),
       vis('l4', 'lineChart', 640, 320, 600, 300)],
      [line_el('b1', kind: 'bar-chart', ys: 2, color: true), vis('b1', 'barChart', 0, 640, 600, 300, 'data_labels' => true)],
      [line_el('b2', kind: 'bar-chart'), vis('b2', 'barChart', 640, 640, 600, 300, 'data_labels' => false)],
      [line_el('cb', kind: 'combo-chart', ys: 2, extra: { 'yAxis2' => { 'columnIds' => ['x'] } }), vis('cb', 'lineClusteredColumnComboChart', 0, 960, 600, 300, 'data_labels' => true)],
      [line_el('cb2', kind: 'combo-chart', extra: { 'dataLabel' => { 'labels' => 'hidden' } }), vis('cb2', 'lineClusteredColumnComboChart', 640, 960, 600, 300, 'data_labels' => true)],
      [line_el('l5', extra: { 'yAxis2' => { 'columnIds' => ['x'] } }), vis('l5', 'lineChart', 0, 1280, 600, 300)],
      [table_el('tn'), vis('tn', 'tableEx', 0, 1600, 600, 300, 'title' => nil)],
      [pivot_el('pn'), vis('pn', 'pivotTable', 640, 1600, 600, 300, 'title' => '')],
      [table_el('tt'), vis('tt', 'tableEx', 0, 1920, 600, 300, 'title' => 'Shown')],
      [kpi_el('kn'), vis('kn', 'card', 640, 1920, 600, 300, 'title' => nil)],
      [chart_el('cn'), vis('cn', 'barChart', 0, 2240, 600, 300, 'title' => nil)],
      [table_el('tu'), vis('tu', 'tableEx', 640, 2240, 600, 300).tap { |v| v.delete('title') }]]
r3els, = mini(r3)
r3_chart = ->(v) { r3els[eid(v)] }
ok('A1 legend top: a color column, or 2+ y columns, on a line/area chart',
   r3_chart.('l2')['legend'] == { 'position' => 'top' } && r3_chart.('l3')['legend'] == { 'position' => 'top' })
ok('A1 a single-series line keeps no legend; an explicit legend is kept; bar charts get none',
   !r3_chart.('l1').key?('legend') && r3_chart.('l4')['legend'] == { 'visibility' => 'hidden' } && !r3_chart.('b1').key?('legend'))
ok('A2 line/area value axis does not include zero, columnIds kept',
   r3_chart.('l1')['yAxis'] == { 'columnIds' => [eid('l1') + '-y0'], 'format' => { 'scale' => { 'type' => 'linear', 'zero' => false } } } &&
   r3_chart.('l3')['yAxis']['format']['scale']['zero'] == false)
ok('A2 an existing scale is kept; yAxis2 is merged too; bar charts untouched',
   r3_chart.('l4')['yAxis'] == { 'columnIds' => %w[a b], 'format' => { 'scale' => { 'type' => 'log' } } } &&
   r3_chart.('l5')['yAxis2'] == { 'columnIds' => ['x'], 'format' => { 'scale' => { 'type' => 'linear', 'zero' => false } } } &&
   !r3_chart.('b1')['yAxis'].key?('format') && !r3_chart.('cb')['yAxis'].key?('format'))
ok('B data_labels true -> dataLabel shown on bar and combo; false/absent and explicit dataLabel untouched',
   r3_chart.('b1')['dataLabel'] == { 'labels' => 'shown' } && r3_chart.('cb')['dataLabel'] == { 'labels' => 'shown' } &&
   !r3_chart.('b2').key?('dataLabel') && r3_chart.('cb2')['dataLabel'] == { 'labels' => 'hidden' } && !r3_chart.('l1').key?('dataLabel'))
ok('D flat table wraps via textStyles.header; no columnHeader on a table; C no align on a flat table',
   r3_chart.('tt')['tableStyle']['textStyles'] == { 'header' => { 'textWrap' => 'wrap' } })
ok('C pivot columnHeader.align right with wrap', r3_chart.('pn')['tableStyle']['textStyles']['columnHeader'] == { 'textWrap' => 'wrap', 'align' => 'right' })
ok('E (default) derived table / pivot names are kept',
   r3_chart.('tn')['name'] == 'tn' && r3_chart.('pn')['name'] == 'pn')
ok('E a shown title, a missing title key, charts and KPIs keep their names',
   r3_chart.('tt')['name'] == 'tt' && r3_chart.('tu')['name'] == 'tu' && r3_chart.('kn')['name'] == 'kn' && r3_chart.('cn')['name'] == 'cn')
hide_t = mini_doc(r3, hide_titles: true)['document']['elements'].each_with_object({}) { |e, h| h[e['id']] = e }
ok('E opt-in hide_derived_titles gives a null/empty-title table / pivot name " "',
   hide_t[eid('tn')]['name'] == ' ' && hide_t[eid('pn')]['name'] == ' ')
ok('E opt-in: a shown title, a missing title key, charts and KPIs keep their names',
   hide_t[eid('tt')]['name'] == 'tt' && hide_t[eid('tu')]['name'] == 'tu' && hide_t[eid('kn')]['name'] == 'kn' && hide_t[eid('cn')]['name'] == 'cn')
again = PolishLayout.polish(mini_doc(r3), { 'pages' => [{ 'page_id' => 'q', 'page_title' => 'Q', 'page_w' => 1280, 'page_h' => 900, 'visuals' => r3.map(&:last) }] })[0]
ok('round-3 tweaks are idempotent', JSON.generate(again) == JSON.generate(mini_doc(r3)))
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'spec.json'), JSON.generate(mini_doc(r3)))
  st, out = sh(VALIDATE, '--type', 'workbook', File.join(dir, 'spec.json'))
  ok('round-3 emissions pass validate-spec', st)
  puts out unless st
  st, out = sh(PREFLIGHT, File.join(dir, 'spec.json'))
  ok('round-3 emissions pass preflight_lint', st)
  puts out unless st
  bad = mini_doc(r3)
  bad['document']['elements'].find { |e| e['id'] == eid('cn') }['name'] = ' '
  File.write(File.join(dir, 'bad.json'), JSON.generate(bad))
  st, = sh(PREFLIGHT, File.join(dir, 'bad.json'))
  ok('preflight N1 still rejects a whitespace name on a chart', !st)
  File.write(File.join(dir, 'in.json'), JSON.generate(mini_doc(r3)))
  File.write(File.join(dir, 'sig.json'), JSON.generate('pages' => [{ 'page_id' => 'q', 'page_title' => 'Q', 'page_w' => 1280, 'page_h' => 900, 'visuals' => r3.map(&:last) }]))
  st, = sh(CLI, '--spec', File.join(dir, 'in.json'), '--signals', File.join(dir, 'sig.json'), '--out', File.join(dir, 'o1.json'))
  st2, = sh(CLI, '--spec', File.join(dir, 'in.json'), '--signals', File.join(dir, 'sig.json'), '--out', File.join(dir, 'o2.json'), '--hide-derived-titles')
  names = ->(f) { JSON.parse(File.read(File.join(dir, f)))['document']['elements'].find { |e| e['id'] == eid('tn') }['name'] }
  ok('E CLI: keeps names by default, --hide-derived-titles opts in', st && st2 && names.call('o1.json') == 'tn' && names.call('o2.json') == ' ')
end

# ---- final review: control rows, KPI snap fixed point, companion (drill) controls ---------------
# 1. slicers on one visual row with slightly different y keep left-to-right order (visible band + drawer)
ord_pairs = [['left', 0, 14], ['mid', 200, 10], ['right', 400, 12]].map do |n, x, y|
  [ctrl_el(n), vis(n, 'slicer', x, y, 140, 60)]
end
_, ob = mini(ord_pairs)
ok('control rows cluster by y within tolerance, then sort by x (visible band)',
   ob[eid('left')][0] < ob[eid('mid')][0] && ob[eid('mid')][0] < ob[eid('right')][0])
hid_pairs = [['hl', 0, 14], ['hm', 200, 10], ['hr', 400, 12]].map do |n, x, y|
  [ctrl_el(n), vis(n, 'slicer', x, y, 140, 60, 'hidden' => true)]
end
hdoc = mini_doc(hid_pairs + [[chart_el('hc'), vis('hc', 'barChart', 0, 300, 600, 300)]])
drawer_layout = parse_layout(hdoc['document']['layout'])['drawer-page-q'][:boxes]
ok('hidden controls keep the same row clustering in the drawer (top to bottom: left, mid, right)',
   drawer_layout[eid('hl')][2] < drawer_layout[eid('hm')][2] && drawer_layout[eid('hm')][2] < drawer_layout[eid('hr')][2])

# 2. KPI-only sibling columns end on lcm multiples (3 peers beside 2 peers in 24 columns)
kp = ->(n) { { t: :cols, kids: Array.new(n) { { t: :leaf, leaf: { cls: :kpi, rows: 4, el: { 'kind' => 'kpi-chart' } } } } } }
col_a = { t: :rows, kids: [kp.call(3), kp.call(3)] }
col_b = { t: :rows, kids: [kp.call(2), kp.call(2)] }
snapped = PolishLayout.snap_kpi_columns!([col_a, col_b], [16, 8])
ok('KPI snap reaches a fixed point where both columns are lcm multiples (18 / 6), total unchanged',
   snapped == [18, 6])

# 3. a builder-derived drill control is not hidden-in-source: it rides with its chart
dc = ctrl_el('dr', 'drill')
dc['id'] = "#{eid('dch')}-drill"
dc['categories'] = [{ 'columnId' => 'mc-region' }, { 'columnId' => 'mc-region' }]
dc['targets'] = [{ 'source' => { 'kind' => 'table', 'elementId' => eid('dch') }, 'columnIds' => ["#{eid('dch')}-x", "#{eid('dch')}-x"] }]
dc['value'] = 'mc-region'
dsig = { 'pages' => [{ 'page_id' => 'q', 'page_title' => 'Q', 'page_w' => 1280, 'page_h' => 900,
                       'visuals' => [vis('vs', 'slicer', 0, 0, 140, 60), vis('dch', 'barChart', 0, 100, 600, 300)] }] }
dels = [{ 'id' => MASTER, 'kind' => 'table', 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB PUBLIC SALES] },
          'columns' => [col('mc-region', '[SALES/Region]', 'Region')] }, ctrl_el('vs'), chart_el('dch'), dc]
dlayout = SigmaLayout.assemble(SigmaLayout.page_xml('page-data', le(MASTER, 1, 25, 1, 11)),
                               SigmaLayout.page_xml('page-q', [eid('vs'), eid('dch'), dc['id']].each_with_index.map { |id, i| le(id, 1, 25, i * 10 + 1, i * 10 + 11) }.join("\n")))
dspec = { 'name' => 'Mini', 'document' => { 'schemaVersion' => 1, 'kind' => 'workbook',
                                           'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden' }, { 'id' => 'page-q', 'name' => 'Q' }],
                                           'elements' => dels, 'layout' => dlayout } }
dout, dsum = PolishLayout.polish(dspec, dsig)
dxml = dout['document']['layout']
ok('drill control is not counted hidden, no drawer / overlay is created', dsum[0]['controls_hidden'] == 0 && !dout['document'].key?('overlays') && !dxml.include?('drawer-page-q'))
dbox = parse_layout(dxml)['page-q']
ok('drill control sits in the chart container, above the chart',
   dbox[:boxes][dc['id']] && dbox[:boxes][eid('dch')] && dbox[:boxes][dc['id']][3] <= dbox[:boxes][eid('dch')][2])
st_pf = false
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 's.json'), JSON.generate(dout))
  st_pf, = sh(VALIDATE, '--type', 'workbook', File.join(dir, 's.json'))
end
ok('companion-control layout passes validate-spec', st_pf)
dagain, = PolishLayout.polish(dout, dsig)
ok('companion-control polish is idempotent', JSON.generate(dagain) == JSON.generate(dout))

puts($fail.zero? ? "\nall passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
