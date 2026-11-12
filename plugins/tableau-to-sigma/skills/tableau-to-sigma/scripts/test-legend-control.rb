#!/usr/bin/env ruby
# C14: a separate Tableau colour-legend zone becomes a native Sigma legend control
# (chart legend hidden, control sourced from + targeting the chart colour column,
# customColors = the colours the chart itself shows, otherCategories use-legend-palette so no "Others" row), placed in the
# legend zone's layout cell.
require 'json'
require 'rexml/document'
require 'tmpdir'
require_relative 'lib/builder_test_harness'
require_relative 'lib/control_lint'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end
H = BuilderTestHarness

csv = "Region,Segment,Net Revenue\nEast,Standard,10\nEast,Express,20\nWest,Economy,30\nWest,Slow,40\n"
chart = H.chart_zone(id: '5', caption: 'Seg Chart', extra: {
  'channels' => { 'color' => { 'column' => '[Segment]' } } })
legend = { 'id' => '9', 'kind' => 'legend', 'caption' => 'Seg Chart', 'x_pct' => 75, 'y_pct' => 0,
           'w_pct' => 25, 'h_pct' => 30 }

# ---- builder: shape --------------------------------------------------------
res = H.run([chart, legend], csvs: { 'Seg Chart' => csv }, args: ['--page-per-dashboard'])
check(res[:status].success?, 'builder exits 0', fails)
ch = H.find_chart(res, /Seg Chart/)
ctl = res[:elements].find { |e| e['controlType'] == 'legend' }
check(ch && ch['legend'] == { 'visibility' => 'hidden' }, 'chart legend hidden', fails)
check(ch && ch.dig('color', 'by') == 'category', 'chart colours by category', fails)
check(ctl && ctl['id'] == 'legend-9' && ctl['kind'] == 'control', 'control id legend-<zoneid>', fails)
# Live-proven (plan C live regression R1, probe variants v1-v10): the server accepts a legend control
# only when `source` and `targets` both name a column of the table the chart is sourced from (the
# master); the chart element's own colour column is rejected ("Invalid value source for list
# control" as source, "Invalid legend target on control" as target), and `controlId` must differ
# from `id` ("Duplicate id").
ref = { 'source' => { 'kind' => 'table', 'elementId' => ch && ch.dig('source', 'elementId') },
        'columnId' => 'm-segment' }
check(ch && ch.dig('source', 'kind') == 'table' && ch.dig('source', 'elementId') == 'master',
      'chart is sourced from the master table', fails)
check(ctl && ctl['source'] == ref.merge('kind' => 'source') && ctl['targets'] == [ref],
      'control source + targets name the master column the chart colours by', fails)
check(ctl && ctl['controlId'] != ctl['id'], "controlId differs from id (#{ctl && ctl['controlId'].inspect})", fails)
members = %w[Economy Express Slow Standard]
check(ch && ctl && ctl.dig('colorAssignment', 'customColors') ==
        members.zip(ch.dig('color', 'scheme')).map { |m, c| { 'value' => m, 'color' => c } },
      'customColors = ascending members zipped with the chart scheme', fails)
# Live-probed 2026-11-10 (wb 8793373b): omitting otherCategories still renders a grey "Others" row
# after the listed members; use-legend-palette is the shape that drops it.
check(ctl && ctl['otherCategories'] == { 'mode' => 'use-legend-palette' }, 'otherCategories use-legend-palette (no Others row)', fails)
check(ctl && !ctl.key?('filters'), 'no filters key', fails)
spec = { 'name' => 't', 'pages' => [{ 'id' => 'pd', 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table' }] }] +
          (res[:raw]['pages'] || []).map { |p| { 'id' => 'p1', 'name' => p['name'], 'elements' => p['elements'] } } }
viol = ControlLint.lint(spec)
check(ctl && Array(viol).none? { |v| v.to_s.include?('dead control') && v.to_s.include?('legend-9') },
      "ControlLint does not flag the legend control dead (#{Array(viol).inspect[0, 200]})", fails)

# ---- no legend zone: chart legend as today, no control ---------------------
res2 = H.run([chart], csvs: { 'Seg Chart' => csv }, args: ['--page-per-dashboard'])
check(res2[:elements].none? { |e| e['controlType'] == 'legend' }, 'no legend zone => no legend control', fails)

# ---- non-page mode: no control is built, so the chart keeps its legend.position ----
res3 = H.run([chart, legend], csvs: { 'Seg Chart' => csv })
ch3 = H.find_chart(res3, /Seg Chart/)
check(res3[:elements].none? { |e| e['controlType'] == 'legend' }, 'flat mode: no legend control', fails)
check(ch3 && ch3['legend'].is_a?(Hash) && ch3['legend'].key?('position') && !ch3['legend'].key?('visibility'), "flat mode: chart keeps legend.position (got #{ch3 && ch3['legend'].inspect})", fails)

# ---- layout: control lands in the legend zone's cell -----------------------
DIR = __dir__
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources><datasource caption='Sales' name='federated.x'>
      <column caption='Region' name='[Region]' datatype='string' role='dimension' />
    </datasource></datasources>
    <worksheets><worksheet name='Seg Chart'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet></worksheets>
    <dashboards><dashboard name='Pipe'><zones>
      <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
        <zone id='5' name='Seg Chart' x='0' y='0' w='75000' h='100000' />
        <zone id='9' type-v2='color' param='[federated.x].[none:Region:nk]' x='75000' y='0' w='25000' h='100000' />
      </zone>
    </zones></dashboard></dashboards>
  </workbook>
XML
xml_doc = nil
Dir.mktmpdir do |d|
  File.write("#{d}/wb.twb", TWB)
  abort 'parse failed' unless system('ruby', File.join(DIR, 'parse-twb-layout.rb'), "#{d}/wb.twb", "#{d}/layout.json", out: File::NULL, err: File::NULL)
  wb = { 'pages' => [{ 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] },
                     { 'name' => 'Pipe', 'elements' => [
    { 'id' => 'el-chart', 'kind' => 'bar-chart', 'name' => 'Seg Chart' },
    { 'id' => 'legend-9', 'kind' => 'control', 'controlType' => 'legend', 'controlId' => 'Legend9' },
    { 'id' => 'el-filter', 'kind' => 'control', 'controlType' => 'list', 'name' => 'Region' }] }] }
  File.write("#{d}/wb.json", JSON.dump(wb))
  IO.popen(['ruby', File.join(DIR, 'build-dashboard-layout.rb'), '--layout', "#{d}/layout.json",
            '--wb-ids', "#{d}/wb.json", '--out', "#{d}/l.xml"], err: %i[child out], &:read)
  xml_doc = REXML::Document.new("<Root>#{File.read("#{d}/l.xml").sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>") if File.exist?("#{d}/l.xml")
end
cells = {}
xml_doc && xml_doc.elements.each('//Element') { |e| cells[e.attributes['elementId']] = e.attributes['gridColumn'] }
check(cells['legend-9'], 'layout places the legend control', fails)
lc = cells['legend-9'].to_s.split(' / ').map(&:to_i)
cc = cells['el-chart'].to_s.split(' / ').map(&:to_i)
check(lc.size == 2 && cc.size == 2 && lc[0] >= cc[1] - 1 && lc[0] >= 17,
      "legend sits to the right of the chart in the legend zone's cell (legend #{cells['legend-9']}, chart #{cells['el-chart']})", fails)

# ---- two dashboards, same worksheet: each page's control lands in ITS legend zone ----
legend2 = legend.merge('id' => '7', 'x_pct' => 0, 'w_pct' => 25)
chart2 = chart.merge('x_pct' => 25, 'w_pct' => 75)
resm = H.run([chart, legend], csvs: { 'Seg Chart' => csv }, args: ['--page-per-dashboard'],
             extra_dashboards: [{ 'dashboard' => 'Dash2', 'zones' => [chart2, legend2] }])
pages = resm[:raw].is_a?(Hash) ? resm[:raw]['pages'] : []
ids = pages.map { |pg| pg['elements'].select { |e| e['controlType'] == 'legend' }.map { |e| e['id'] } }
check(pages.size == 2 && ids[0] == ['legend-9'] && ids[1].size == 1 && ids[1][0].start_with?('legend-7'),
      "each page carries its own legend control (#{ids.inspect})", fails)
TWB2 = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources><datasource caption='Sales' name='federated.x'>
      <column caption='Region' name='[Region]' datatype='string' role='dimension' />
    </datasource></datasources>
    <worksheets><worksheet name='Seg Chart'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet></worksheets>
    <dashboards>
      <dashboard name='Dash'><zones><zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
        <zone id='5' name='Seg Chart' x='0' y='0' w='75000' h='100000' />
        <zone id='9' type-v2='color' param='[federated.x].[none:Region:nk]' x='75000' y='0' w='25000' h='100000' />
      </zone></zones></dashboard>
      <dashboard name='Dash2'><zones><zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
        <zone id='5' name='Seg Chart' x='25000' y='0' w='75000' h='100000' />
        <zone id='7' type-v2='color' param='[federated.x].[none:Region:nk]' x='0' y='0' w='25000' h='100000' />
      </zone></zones></dashboard>
    </dashboards>
  </workbook>
XML
cells2 = {}
Dir.mktmpdir do |d|
  File.write("#{d}/wb.twb", TWB2)
  abort 'parse failed' unless system('ruby', File.join(DIR, 'parse-twb-layout.rb'), "#{d}/wb.twb", "#{d}/layout.json", out: File::NULL, err: File::NULL)
  wb = { 'pages' => [{ 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] }] +
         pages.each_with_index.map { |pg, i| { 'id' => "pg#{i}", 'name' => pg['name'], 'elements' => pg['elements'].map { |e|
           { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'], 'controlType' => e['controlType'] }.compact } } } }
  File.write("#{d}/wb.json", JSON.dump(wb))
  lg = IO.popen(['ruby', File.join(DIR, 'build-dashboard-layout.rb'), '--layout', "#{d}/layout.json",
            '--wb-ids', "#{d}/wb.json", '--out', "#{d}/l.xml"], err: %i[child out], &:read)
  puts lg if ENV['DBG']
  if File.exist?("#{d}/l.xml")
    doc = REXML::Document.new("<Root>#{File.read("#{d}/l.xml").sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")
    doc.elements.each('//Element') { |e| cells2[e.attributes['elementId']] = e.attributes['gridColumn'] }
  end
end
c1 = cells2[ids[0] && ids[0][0]].to_s.split(' / ').map(&:to_i)
c2 = cells2[ids[1] && ids[1][0]].to_s.split(' / ').map(&:to_i)
check(c1.size == 2 && c1[0] >= 17, "dashboard 1 legend control in its right-hand cell (#{cells2[ids[0] && ids[0][0]].inspect})", fails)
check(c2.size == 2 && c2[0] == 1 && c2[1] <= 9, "dashboard 2 legend control in its left-hand cell (#{cells2[ids[1] && ids[1][0]].inspect})", fails)

# ---- (final review #1) SAME legend zone id on two dashboards: unique ids + controlIds ----
legend9b = legend.merge('x_pct' => 0, 'w_pct' => 25)            # dashboard 2: same zone id 9, on the left
resd = H.run([chart, legend], csvs: { 'Seg Chart' => csv }, args: ['--page-per-dashboard'],
             extra_dashboards: [{ 'dashboard' => 'Dash2', 'zones' => [chart2, legend9b] }])
dpages = resd[:raw].is_a?(Hash) ? resd[:raw]['pages'] : []
dctls = dpages.map { |pg| pg['elements'].select { |e| e['controlType'] == 'legend' } }
all_ids = dpages.flat_map { |pg| pg['elements'].map { |e| e['id'] } }
check(dctls.map(&:size) == [1, 1], "each page has one legend control (#{dctls.map(&:size).inspect})", fails)
lids = dctls.flatten.map { |c| c['id'] }
lcids = dctls.flatten.map { |c| c['controlId'] }
check(lids.uniq.size == 2 && lcids.uniq.size == 2, "legend ids and controlIds are unique across pages (#{lids.inspect} / #{lcids.inspect})", fails)
# the exact duplicate check post-and-readback runs before the POST
dup_keys = Hash.new(0)
dpages.flat_map { |pg| pg['elements'] }.each do |el|
  dup_keys["element id #{el['id']}"] += 1 if el['id']
  dup_keys["controlId #{el['controlId']}"] += 1 if el['controlId']
end
check(dup_keys.none? { |_, n| n > 1 }, "post-and-readback duplicate-id check passes (#{dup_keys.select { |_, n| n > 1 }.keys.inspect})", fails)
TWB3 = TWB2.sub("<zone id='7' type-v2='color'", "<zone id='9' type-v2='color'")
cells3 = {}
Dir.mktmpdir do |d|
  File.write("#{d}/wb.twb", TWB3)
  abort 'parse failed' unless system('ruby', File.join(DIR, 'parse-twb-layout.rb'), "#{d}/wb.twb", "#{d}/layout.json", out: File::NULL, err: File::NULL)
  wb = { 'pages' => [{ 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] }] +
         dpages.each_with_index.map { |pg, i| { 'id' => "pg#{i}", 'name' => pg['name'], 'elements' => pg['elements'].map { |e|
           { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'], 'controlType' => e['controlType'] }.compact } } } }
  File.write("#{d}/wb.json", JSON.dump(wb))
  IO.popen(['ruby', File.join(DIR, 'build-dashboard-layout.rb'), '--layout', "#{d}/layout.json",
            '--wb-ids', "#{d}/wb.json", '--out', "#{d}/l.xml"], err: %i[child out], &:read)
  if File.exist?("#{d}/l.xml")
    doc = REXML::Document.new("<Root>#{File.read("#{d}/l.xml").sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")
    doc.elements.each('//Element') { |e| cells3[e.attributes['elementId']] = e.attributes['gridColumn'] }
  end
end
d1 = cells3[lids[0]].to_s.split(' / ').map(&:to_i)
d2 = cells3[lids[1]].to_s.split(' / ').map(&:to_i)
check(d1.size == 2 && d1[0] >= 17, "same zone id: dashboard 1 control in its right-hand cell (#{cells3[lids[0]].inspect})", fails)
check(d2.size == 2 && d2[0] == 1 && d2[1] <= 9, "same zone id: dashboard 2 control in its left-hand cell (#{cells3[lids[1]].inspect})", fails)

# ---- (final review #1) two charts matching ONE legend zone: one control only ----
chartB = H.chart_zone(id: '6', caption: 'Seg Chart 2', extra: { 'y_pct' => 40,
  'channels' => { 'color' => { 'column' => '[Segment]' } } })
legendq = legend.merge('caption' => 'Seg Chart 2')   # substring-matches chart A, exactly matches chart B
resq = H.run([chart, chartB, legendq], csvs: { 'Seg Chart' => csv, 'Seg Chart 2' => csv }, args: ['--page-per-dashboard'])
qctls = resq[:elements].select { |e| e['controlType'] == 'legend' }
cA = H.find_chart(resq, /\ASeg Chart\z/)
cB = H.find_chart(resq, /\ASeg Chart 2\z/)
check(qctls.size == 1, "one legend control for one legend zone (got #{qctls.size})", fails)
check(qctls.size == 1 && cA && ((resq[:provenance] || {})['elements'] || {}).dig(cB['id'], 'legend_control_id') == qctls[0]['id'] && ((resq[:provenance] || {})['elements'] || {}).dig(cA['id'], 'legend_control_id').nil?,
      'control belongs to the strongest caption match (exact caption)', fails)
check(cB && cB['legend'] == { 'visibility' => 'hidden' }, 'winner chart legend hidden', fails)
check(cA && cA['legend'].is_a?(Hash) && cA['legend'].key?('position') && !cA['legend'].key?('visibility'),
      "other chart keeps legend.position (got #{cA && cA['legend'].inspect})", fails)

# ---- provenance carries the pre-C14 legend + control id for the layout post-pass ----
pv = (resd[:provenance] || {})['elements'] || {}
dchart = dpages.map { |pg| pg['elements'].find { |e| e['kind'] == 'bar-chart' } }
check(dchart.each_with_index.all? { |c, i| c && pv.dig(c['id'], 'legend_control_id') == dctls[i][0]['id'] &&
      pv.dig(c['id'], 'legend_fallback').is_a?(Hash) && pv.dig(c['id'], 'legend_fallback').key?('position') },
      "provenance records legend_fallback + legend_control_id per page chart (#{pv.inspect[0, 300]})", fails)
check(dpages.flat_map { |pg| pg['elements'] }.none? { |e| e.key?('_legend_fallback') }, 'no internal legend key reaches the spec', fails)

# ---- (R1 fix 1) the control recolours EVERY chart on its master column ----
# Chart A (legend zone) and chart B (no zone) colour by the same master column. Identical final
# member->colour maps: one control. Differing maps: the control would override B, so no control and
# both charts keep legend.position / their own state.
sc = ->(a) { a.map { |m, c| { 'member' => m, 'color' => c } } }
pinA = sc.call([['Economy', '#111111'], ['Express', '#222222'], ['Slow', '#333333'], ['Standard', '#444444']])
pinB = sc.call([['Economy', '#aa0000'], ['Express', '#bb0000'], ['Slow', '#cc0000'], ['Standard', '#dd0000']])
chA = H.chart_zone(id: '5', caption: 'Seg Chart', extra: { 'series_colors' => pinA,
  'channels' => { 'color' => { 'column' => '[Segment]' } } })
mk_b = ->(pins) { H.chart_zone(id: '6', caption: 'Other Chart', extra: { 'y_pct' => 40, 'series_colors' => pins,
  'channels' => { 'color' => { 'column' => '[Segment]' } } }) }
rs = H.run([chA, mk_b.call(pinA), legend], csvs: { 'Seg Chart' => csv, 'Other Chart' => csv }, args: ['--page-per-dashboard'])
check(rs[:elements].count { |e| e['controlType'] == 'legend' } == 1, 'identical schemes on one master column: one legend control', fails)
rd = H.run([chA, mk_b.call(pinB), legend], csvs: { 'Seg Chart' => csv, 'Other Chart' => csv }, args: ['--page-per-dashboard'])
dA = H.find_chart(rd, /\ASeg Chart\z/)
check(rd[:elements].none? { |e| e['controlType'] == 'legend' }, 'differing schemes on one master column: no legend control', fails)
check(dA && dA['legend'].is_a?(Hash) && dA['legend'].key?('position') && !dA['legend'].key?('visibility'),
      "differing schemes: chart keeps legend.position (got #{dA && dA['legend'].inspect})", fails)

# ---- (R1 fix 3) unbindable chart: colour column is not a plain [Master/..] reference ----
# legend_master_ref is the single gate; the page pass gives every chart it rejects the chart-native
# `position` legend and emits no control (same code path as the differing-schemes case above).
src = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
eval(src[/^def legend_master_ref.*?^end\n/m]) # rubocop:disable Security/Eval
mm = { 'x' => { 'id' => 'm-segment', 'name' => 'Segment' } }
mkc = ->(formula, source: { 'kind' => 'table', 'elementId' => 'master' }) {
  { 'source' => source, 'columns' => [{ 'id' => 'c1', 'formula' => formula }], 'color' => { 'by' => 'category', 'column' => 'c1' } } }
check(legend_master_ref(mkc.call('[Master/Segment]'), mm, []) ==
        { 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-segment' }, 'plain [Master/Segment] binds to its master column', fails)
check(legend_master_ref(mkc.call('Upper([Master/Segment])'), mm, []).nil?, 'calc colour column is unbindable (no control)', fails)
check(legend_master_ref(mkc.call('[Master/Other]'), mm, []).nil?, 'colour column absent from the master map is unbindable', fails)
check(legend_master_ref(mkc.call('[Master/Segment]', source: { 'kind' => 'table', 'elementId' => 'helper' }), mm, [{ 'id' => 'helper' }]).nil?,
      'chart sourced from a helper element is unbindable', fails)

# ---- (R1 fix 2) a legend control with no targets is still dead ----
dead = { 'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
  { 'id' => 'master', 'kind' => 'table' }, { 'id' => 'ch', 'kind' => 'bar-chart', 'source' => { 'kind' => 'table', 'elementId' => 'master' } },
  { 'id' => 'legend-1', 'kind' => 'control', 'controlType' => 'legend', 'controlId' => 'legend-1-ctl' }] }] }
check(Array(ControlLint.lint(dead)).any? { |v| v.include?('dead control') && v.include?('legend-1') }, 'legend control with no targets is flagged dead', fails)

puts
if fails.empty?
  puts 'ALL PASS - C14 legend control'
  exit 0
end
puts "#{fails.size} FAILURE(S)"
fails.each { |f| puts "  - #{f}" }
exit 1
