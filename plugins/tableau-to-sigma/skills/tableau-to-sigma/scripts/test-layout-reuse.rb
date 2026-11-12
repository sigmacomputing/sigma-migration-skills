#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test: --reuse-workbook layout PRESERVE-vs-REGENERATE decision (lib/layout_reuse.rb).
require_relative 'lib/layout_reuse'
$fails = 0
def ok(c, m)
  puts "  #{c ? 'PASS' : 'FAIL'}  #{m}"
  $fails += 1 unless c
end
xml = '<Layout><Page id="p1"><Item elementId="kpi1"/><Item elementId="chart1"/><Item elementId="tc-p1-band1"/></Page></Layout>'

d = LayoutReuse.decide(live_layout: xml, new_ids: %w[kpi1 chart1], live_ids: %w[kpi1 chart1 tc-p1-band1])
ok(d[:path] == :preserve, "same ids + live chrome carried → preserve (#{d[:reason]})")

d = LayoutReuse.decide(live_layout: xml, new_ids: %w[kpi1 chart1], live_ids: %w[kpi1 chart1 tc-p1-band1], regenerate: true)
ok(d[:path] == :regenerate && d[:reason] =~ /--regenerate-layout/, 'explicit --regenerate-layout wins')

d = LayoutReuse.decide(live_layout: xml, new_ids: %w[kpi1], live_ids: %w[kpi1 chart1 tc-p1-band1])
ok(d[:path] == :preserve && d[:merge] && d[:stale] == %w[chart1] && d[:reason].include?('chart1'), 'removed element → preserve + prune it, naming it')

d = LayoutReuse.decide(live_layout: xml, new_ids: %w[kpi1 chart1 brand-new], live_ids: %w[kpi1 chart1 tc-p1-band1])
ok(d[:path] == :preserve && d[:merge] && d[:unplaced] == %w[brand-new], 'brand-new element → preserve + place it (never regenerate the whole layout)')

d = LayoutReuse.decide(live_layout: xml, new_ids: %w[kpi1 chart1], live_ids: %w[kpi1 chart1])
ok(d[:path] == :preserve && d[:stale] == %w[tc-p1-band1], 'chrome absent from the live spec is pruned, not a regeneration')

d = LayoutReuse.decide(live_layout: xml, new_ids: %w[new-a new-b new-c], live_ids: %w[kpi1 chart1 tc-p1-band1])
ok(d[:path] == :regenerate && d[:reason] =~ /stale generation/, 'full rebuild (no live id survives) → regenerate')

d = LayoutReuse.decide(live_layout: "  ", new_ids: %w[a], live_ids: [])
ok(d[:path] == :regenerate && d[:reason] =~ /no layout/, 'blank live layout → regenerate')

d = LayoutReuse.decide(live_layout: xml, new_ids: %w[kpi1 chart1 unplaced-live], live_ids: %w[kpi1 chart1 tc-p1-band1 unplaced-live])
ok(d[:path] == :preserve, 'element already live-but-unplaced is not a reason to regenerate')

require_relative 'lib/layout_merge'
puts 'layout merge (live-proof edit shape: one control added to the rail)'
live = <<~XML
  <?xml version="1.0" encoding="utf-8"?>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-data">
    <Element elementId="master-overview" gridColumn="1 / 25" gridRow="1 / 11"/>
  </Page>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-dash-1">
    <Container elementId="syn-page-dash-1-rail" type="grid" gridColumn="1 / 4" gridRow="1 / 15" gridTemplateColumns="repeat(1, 1fr)" gridTemplateRows="auto">
      <Element elementId="text-7" gridColumn="1 / 2" gridRow="1 / 3"/>
      <Element elementId="el-ctl-region-overview" gridColumn="1 / 2" gridRow="3 / 6"/>
      <Element elementId="el-ctl-channel-overview" gridColumn="1 / 2" gridRow="6 / 9"/>
      <Element elementId="text-10" gridColumn="1 / 2" gridRow="9 / 11"/>
      <Element elementId="el-param-metric-overview" gridColumn="1 / 2" gridRow="11 / 14"/>
    </Container>
    <Container elementId="syn-page-dash-1-sec-1" type="grid" gridColumn="4 / 25" gridRow="1 / 18" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="el-trend" gridColumn="1 / 25" gridRow="1 / 18"/>
    </Container>
    <Element elementId="el-old-table" gridColumn="1 / 25" gridRow="18 / 30"/>
  </Page>
XML
spec_layout = live.sub('<Element elementId="text-10" gridColumn="1 / 2" gridRow="9 / 11"/>',
                       '<Element elementId="el-ctl-category-overview" gridColumn="1 / 2" gridRow="9 / 12"/>' \
                       '<Element elementId="text-10" gridColumn="1 / 2" gridRow="12 / 14"/>')
ids = %w[master-overview text-7 el-ctl-region-overview el-ctl-channel-overview text-10 el-param-metric-overview el-trend
         el-ctl-category-overview syn-page-dash-1-rail syn-page-dash-1-sec-1]
kinds = Hash.new('text').merge('el-ctl-region-overview' => 'control', 'el-ctl-channel-overview' => 'control',
                               'el-param-metric-overview' => 'control', 'el-ctl-category-overview' => 'control',
                               'el-trend' => 'line-chart', 'master-overview' => 'table')
pos = ->(xml, id) { xml[/elementId="#{Regexp.escape(id)}"[^>]*gridRow="([^"]+)"/, 1] }
cols = ->(xml, id) { xml[/elementId="#{Regexp.escape(id)}" gridColumn="([^"]+)"/, 1] }
r = LayoutMerge.merge(live_xml: live, new_ids: ids, sources: [spec_layout], kinds: kinds)
x = r[:xml]
ok(r[:placed].map { |pl| [pl['id'], pl['how'], pl['parent']] } == [['el-ctl-category-overview', 'source', 'syn-page-dash-1-rail']],
   "new control placed from the spec's own layout into the live rail (#{r[:placed].inspect})")
ok(pos.call(x, 'el-ctl-category-overview') == '9 / 12', 'at the spec position')
ok(pos.call(x, 'text-10') == '12 / 14' && pos.call(x, 'el-param-metric-overview') == '14 / 17', 'later rail siblings pushed down, order kept')
ok(pos.call(x, 'el-ctl-region-overview') == '3 / 6' && pos.call(x, 'el-trend') == '1 / 18', 'every other live placement unchanged')
ok(x[/elementId="syn-page-dash-1-rail"[^>]*gridRow="([^"]+)"/, 1] == '1 / 17', 'rail container grows to fit (14 -> 16 rows)')
ok(r[:pruned] == %w[el-old-table] && !x.include?('el-old-table'), 'element dropped from the spec is pruned')
ok(!x.include?("='") && x.start_with?('<?xml'), 'double-quoted attributes, xml declaration kept')

r = LayoutMerge.merge(live_xml: live, new_ids: ids, sources: [], kinds: kinds)
ok(r[:placed].first['how'] == 'after-last-control' && r[:placed].first['page'] == 'page-dash-1',
   "no source: control goes after the last control in the page's rail, not the Data page (#{r[:placed].inspect})")
ok(pos.call(r[:xml], 'el-ctl-category-overview') == '14 / 17' && pos.call(r[:xml], 'text-10') == '9 / 11', 'appended without moving siblings')

r = LayoutMerge.merge(live_xml: live, new_ids: ids + %w[el-new-chart-overview], sources: [], kinds: kinds.merge('el-new-chart-overview' => 'bar-chart'))
nc = r[:placed].find { |pl| pl['id'] == 'el-new-chart-overview' }
ok(nc && nc['how'] == 'append-page' && nc['page'] == 'page-dash-1' && cols.call(r[:xml], 'el-new-chart-overview') == '1 / 25',
   "unplaceable chart appended full-width below the page content (#{nc.inspect})")
ok(pos.call(r[:xml], 'el-trend') == '1 / 18', 'append never moves live tiles')
r = LayoutMerge.merge(live_xml: live, new_ids: ids + %w[syn-page-dash-1-new box-1], sources: [], kinds: kinds.merge('box-1' => 'container'))
ok((r[:placed].map { |pl| pl['id'] } & %w[syn-page-dash-1-new box-1]).empty?, "new chrome / container ids are not inserted as bare elements (#{r[:placed].inspect})")

trailing_data_page = <<~XML
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="page-data">
    <Element elementId="master" gridColumn="1 / 25" gridRow="1 / 11"/>
  </Page>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="page-customer-detail">
    <Element elementId="el-chart-customer-data" gridColumn="1 / 25" gridRow="1 / 11"/>
  </Page>
XML
r = LayoutMerge.merge(live_xml: trailing_data_page, new_ids: %w[master el-chart-customer-data el-new-customer-data],
                       sources: [], kinds: { 'master' => 'table', 'el-chart-customer-data' => 'bar-chart',
                                             'el-new-customer-data' => 'bar-chart' })
ok(r[:placed].first['page'] == 'page-customer-detail', 'dashboard placement is inferred by matching element-id suffixes')

fallback_data_page = <<~XML
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="data">
    <Element elementId="master" gridColumn="1 / 25" gridRow="1 / 11"/>
  </Page>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="page-dash-1"/>
XML
r = LayoutMerge.merge(live_xml: fallback_data_page, new_ids: %w[master lod-helper], sources: [],
                       kinds: { 'master' => 'table', 'lod-helper' => 'table' }, data_ids: %w[master lod-helper])
ok(r[:placed].first['page'] == 'data' && r[:placed].first['how'] == 'data-page',
   'append fallback data page receives unplaced helpers')

spanning_tiles = <<~XML
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="page-dash-1">
    <Element elementId="short-blocker" gridColumn="1 / 13" gridRow="8 / 10"/>
    <Element elementId="tall-blocker" gridColumn="1 / 13" gridRow="8 / 20"/>
  </Page>
XML
spanning_source = spanning_tiles.sub('</Page>', '<Element elementId="new-tile" gridColumn="1 / 13" gridRow="9 / 12"/></Page>')
r = LayoutMerge.merge(live_xml: spanning_tiles, new_ids: %w[short-blocker tall-blocker new-tile],
                       sources: [spanning_source], kinds: { 'new-tile' => 'bar-chart' })
ok(pos.call(r[:xml], 'new-tile') == '20 / 23', 'insert advances past every sibling spanning its adjusted start row')

puts 'edit adds a control the author did not place (live re-proof)'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'workbook_code'
spec_els = ids.map { |id| { 'id' => id, 'kind' => kinds[id] } }
spec = { 'document' => { 'schemaVersion' => 1, 'kind' => 'workbook',
                         'pages' => [{ 'id' => 'page-data', 'name' => 'Data' }, { 'id' => 'page-dash-1', 'name' => 'Overview' }],
                         'elements' => spec_els, 'layout' => live.sub(%r{\s*<Element elementId="el-old-table"[^>]*/>}, '') } }
round = WorkbookCode.canonicalize(WorkbookCode.legacy_view(WorkbookCode.canonicalize(spec)))
ok(WorkbookCode.elements(round).any? { |e| e['id'] == 'el-ctl-category-overview' },
   'legacy_view/canonicalize round-trip KEEPS an element no layout page places (was silently dropped)')
ok(WorkbookCode.validate(round).any? { |e| e.include?('el-ctl-category-overview') }, 'and validate names it instead of losing it')
doc = WorkbookCode.document(round)
fill = LayoutMerge.complete_layout(doc['layout'], WorkbookCode.elements(round))
ok(fill[:placed].map { |pl| [pl['id'], pl['parent']] } == [%w[el-ctl-category-overview syn-page-dash-1-rail]],
   "complete_layout places it in the page's control rail (#{fill[:placed].inspect})")
doc['layout'] = fill[:xml]
ok(WorkbookCode.validate(round).empty?, "spec validates after completion (#{WorkbookCode.validate(round).inspect})")
d = LayoutReuse.decide(live_layout: live, new_ids: WorkbookCode.elements(round).map { |e| e['id'] }, live_ids: ids - %w[el-ctl-category-overview])
ok(d[:path] == :preserve && d[:unplaced] == %w[el-ctl-category-overview], "decision detects it as unplaced (#{d[:unplaced].inspect})")
m = LayoutMerge.merge(live_xml: live, new_ids: WorkbookCode.elements(round).map { |e| e['id'] }, sources: [doc['layout']], kinds: kinds)
ok(m[:placed].first && m[:placed].first['how'] == 'source' && pos.call(m[:xml], 'el-ctl-category-overview') == '14 / 17',
   'merge keeps the completed spot in the live layout')
ok(%w[text-10 el-param-metric-overview el-trend].all? { |i| pos.call(m[:xml], i) == pos.call(live, i) }, 'no live frame moved')
ok(LayoutMerge.complete_layout(live, spec_els - [{ 'id' => 'el-ctl-category-overview', 'kind' => 'control' }])[:xml].nil?,
   'complete_layout is a no-op when everything is placed')

puts $fails.zero? ? 'ALL PASS' : "#{$fails} FAILED"
exit($fails.zero? ? 0 : 1)
