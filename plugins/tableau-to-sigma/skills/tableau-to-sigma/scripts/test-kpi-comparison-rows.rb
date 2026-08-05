#!/usr/bin/env ruby
# Regression test for the comparative-KPI row-floor fix (PR #511).
#
# A kpi-chart carrying a comparisonColumn renders a ▲/▼ delta badge — but
# Sigma suppresses the badge below ~6 grid rows (diagnosed live on workbook
# 18a56d09-efda-4496-865f-15fe6ade5eed, see
# .superpowers/sdd/fix-detector-header-report.md #3). The converter's shared
# per-kind floor (SigmaLayout::KIND_MIN_ROWS['kpi-chart'] = 4) was sized for
# the single-value era and fits value+title but blanks the delta. This test
# proves the localized fix in build-dashboard-layout.rb
# (`kpi_min_rows`/`enforce_min_rows_els`) end-to-end:
#   - a SINGLE-VALUE kpi-chart (no comparisonColumn) stays at the 4-row floor
#   - a COMPARATIVE kpi-chart (has comparisonColumn) is bumped to >= 6 rows
#
# Runs the ACTUAL parse-twb-layout.rb + build-dashboard-layout.rb pipeline (no
# Tableau/Sigma calls) — same harness shape as test-container-layout.rb. The
# two KPI zones are placed in DIFFERENT y-bands (each with its own body chart
# below it) so neither pairs into a shared "KPI row" — each hits the banded-
# fallback path independently, isolating the per-element floor rather than a
# shared-row max.
#
# Usage:  ruby scripts/test-kpi-comparison-rows.rb

require 'json'
require 'rexml/document'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-dashboard-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Two standalone KPI tiles (no shared row — each sits in its own y-band with a
# body chart beneath it, so structure detection can't group them and each is
# sized independently by the banded fallback). Zone heights (6%) are small
# enough that, absent an E1 floor, neither would clear 4 rows on its own —
# the floor is what decides the final span.
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Revenue' name='[REVENUE]' datatype='real' role='measure' type='quantitative' />
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='KPI Single'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Revenue' name='[REVENUE]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[REVENUE]' derivation='Sum' name='[sum:REVENUE:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane><mark class='Text' /></pane>
        </table>
      </worksheet>
      <worksheet name='KPI Cmp'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Revenue' name='[REVENUE]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[REVENUE]' derivation='Sum' name='[sum:REVENUE:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane><mark class='Text' /></pane>
        </table>
      </worksheet>
      <worksheet name='Sales A'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x'>
              <column caption='Revenue' name='[REVENUE]' datatype='real' role='measure' type='quantitative' />
              <column caption='Region' name='[REGION]' datatype='string' role='dimension' type='nominal' />
            </datasource-dependencies>
            <rows>[federated.x].[sum:REVENUE:qk]</rows>
            <cols>[federated.x].[none:REGION:nk]</cols>
          </view>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
      <worksheet name='Sales B'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x'>
              <column caption='Revenue' name='[REVENUE]' datatype='real' role='measure' type='quantitative' />
              <column caption='Region' name='[REGION]' datatype='string' role='dimension' type='nominal' />
            </datasource-dependencies>
            <rows>[federated.x].[sum:REVENUE:qk]</rows>
            <cols>[federated.x].[none:REGION:nk]</cols>
          </view>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='D'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' name='KPI Single' x='0' y='0' w='40000' h='6000' />
            <zone id='3' name='Sales A' x='0' y='15000' w='100000' h='30000' />
            <zone id='4' name='KPI Cmp' x='0' y='55000' w='40000' h='6000' />
            <zone id='5' name='Sales B' x='0' y='65000' w='100000' h='30000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

layout_xml = nil
xml_doc = nil
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)

  wb_ids = {
    'pages' => [
      { 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] },
      { 'name' => 'D', 'elements' => [
        { 'id' => 'el-kpi-single', 'kind' => 'kpi-chart', 'name' => 'KPI Single' },
        { 'id' => 'el-kpi-cmp', 'kind' => 'kpi-chart', 'name' => 'KPI Cmp',
          'comparisonColumn' => { 'columnId' => 'prior' } },
        { 'id' => 'el-body-a', 'kind' => 'bar-chart', 'name' => 'Sales A' },
        { 'id' => 'el-body-b', 'kind' => 'bar-chart', 'name' => 'Sales B' }
      ] }
    ]
  }
  wbf = File.join(d, 'wb-ids.json')
  out = File.join(d, 'layout.xml')
  File.write(wbf, JSON.dump(wb_ids))
  build_log = IO.popen(['ruby', BUILD, '--layout', lay, '--wb-ids', wbf, '--out', out],
                       err: %i[child out], &:read)
  if File.exist?(out)
    layout_xml = File.read(out)
    body = layout_xml.sub(/\A<\?xml[^>]*\?>\s*/, '')
    xml_doc = REXML::Document.new("<Root>#{body}</Root>")
  end
end

# gridRow="r0 / r1" -> span (r1 - r0), the row count Sigma actually renders.
def row_span(xml_doc, element_id)
  le = xml_doc && xml_doc.elements.to_a("//LayoutElement[@elementId='#{element_id}']").first
  return nil unless le
  m = le.attributes['gridRow'].to_s.match(/(\d+)\s*\/\s*(\d+)/)
  m && (m[2].to_i - m[1].to_i)
end

single_span = row_span(xml_doc, 'el-kpi-single')
cmp_span    = row_span(xml_doc, 'el-kpi-cmp')

check(!xml_doc.nil?, 'build-dashboard-layout.rb produced a layout.xml', fails)
check(single_span == 4,
      "single-value kpi-chart (no comparisonColumn) stays at the 4-row floor (got #{single_span.inspect})", fails)
check(!cmp_span.nil? && cmp_span >= 6,
      "comparative kpi-chart (has comparisonColumn) is allocated >= 6 rows (got #{cmp_span.inspect})", fails)
check(single_span && cmp_span && cmp_span > single_span,
      'the comparative KPI is strictly taller than the single-value KPI', fails)

puts
if fails.empty?
  puts 'ALL PASS — comparative kpi-chart cards get a >= 6-row floor (delta-badge headroom); single-value KPIs unaffected'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- layout.xml ---\n#{layout_xml}"
  puts "\n--- build log (tail) ---\n#{build_log.to_s.lines.last(15).join}"
  exit 1
end
