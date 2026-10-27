#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for detect_multi_datasource in scan-workbook-gaps.rb (Tier 1 #1,
# a real multi-datasource workbook): a workbook whose worksheets have DIFFERENT
# primary datasources is detected. It stays ❌-unhandled only for what the
# multi-element DM + sub-master routing cannot carry (a published/file source,
# routing switched off, or a window/LOD calc plotted on a non-dominant
# datasource); otherwise it is a review hint. Single-primary workbooks and pure
# blends are not flagged at all.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'
# Requiring the script defines its functions without running main
# ($PROGRAM_NAME guard). Silence any load-time noise.
require_relative 'scan-workbook-gaps'

FAILS = []
def check(cond, msg)
  puts((cond ? '  ok  ' : '  FAIL ') + msg)
  FAILS << msg unless cond
end

def detect(xml_str)
  detect_multi_datasource(TwbXml.parse(xml_str))
end

def fires?(xml_str)
  feat, detail = detect(xml_str)
  [!feat.nil?, detail]
end

# --- multi: two datasources, each the primary of a different worksheet -------
multi = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales Funnel'><connection class='snowflake' server='x' dbname='WH'/></datasource>
    <datasource name='sku' caption='SKU Master GA'><connection class='snowflake' server='x' dbname='WH2'/></datasource>
    <datasource name='Parameters'><connection class='sqlproxy'/></datasource>
  </datasources>
  <worksheet name='Funnel'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  <worksheet name='SKUs'><table><view><datasources><datasource name='sku'/></datasources></view></table></worksheet>
  </workbook>
XML
fired, detail = fires?(multi)
check(fired, 'multi-datasource workbook is detected')
feat, = detect(multi)
check(feat && feat[:status] == :hint && !feat.key?(:worksheets),
      "warehouse-only sources with nothing routing can't move are a hint, not a stop (got #{feat && feat[:status]})")
check(feat && feat[:name] == 'Multiple independent datasources (converter collapses to primary)',
      'row name is unchanged (stable scout-ledger key)')
check(feat && feat[:blurb].include?('route: multi-element DM (refs/multi-datasource.md)'),
      'blurb routes to the multi-element DM reference')
check(detail && detail.length == 2, "detail lists both datasources (got #{detail&.length})")
check(detail && detail.map { |d| d['caption'] }.sort == ['SKU Master GA', 'Sales Funnel'],
      'detail carries datasource captions')
check(detail && detail.find { |d| d['caption'] == 'Sales Funnel' }['worksheets'] == ['Funnel'],
      'detail maps each datasource to its worksheet(s)')

# --- published (sqlproxy) source: nothing to build from -> still a stop -------
published = multi.sub("<connection class='snowflake' server='x' dbname='WH2'/>", "<connection class='sqlproxy'/>")
feat, = detect(published)
check(feat && feat[:status] == :unhandled && !feat.key?(:worksheets),
      'a published source keeps the row blocking, unattributed (fails open on scoped runs)')
check(feat && feat[:blurb].include?('SKU Master GA has no warehouse table'), 'blurb names the published source')

# --- file/SaaS source (csv) -> also nothing to build from ----------------------
csv_source = multi.sub("<connection class='snowflake' server='x' dbname='WH2'/>", "<connection class='csv' filename='sku.csv'/>")
feat, = detect(csv_source)
check(feat && feat[:status] == :unhandled, 'a csv source keeps the row blocking (same file classes as extract landing)')
google_sheets = multi.sub("<connection class='snowflake' server='x' dbname='WH2'/>", "<connection class='google-sheets'/>")
feat, = detect(google_sheets)
check(feat && feat[:status] == :unhandled && !feat.key?(:worksheets),
      'a Google Sheets source keeps the row blocking, unattributed (fails open on scoped runs)')

# --- routing switched off -> still a stop -------------------------------------
begin
  ENV['SIGMA_MULTI_DS_ROUTING'] = 'off'
  feat, = detect(multi)
  check(feat && feat[:status] == :unhandled && feat[:blurb].include?('SIGMA_MULTI_DS_ROUTING=off'),
        'SIGMA_MULTI_DS_ROUTING=off keeps the row blocking')
ensure
  ENV.delete('SIGMA_MULTI_DS_ROUTING')
end

# --- window calc plotted on the NON-dominant datasource -> stop, attributed ---
# Sales is dominant (2 sheets). SKU Trend plots a calc built on a LOOKUP; the
# routed sub-master cannot carry it, so the row blocks and names that sheet.
helper = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales Funnel'><connection class='snowflake' server='x' dbname='WH'/></datasource>
    <datasource name='sku' caption='SKU Master GA'><connection class='snowflake' server='x' dbname='WH2'/>
      <column caption='Units Lag' datatype='real' name='[Calculation_7]' role='measure' type='quantitative'>
        <calculation class='tableau' formula='LOOKUP(SUM([Units]), -1)' />
      </column>
      <column caption='Units Change' datatype='real' name='[Calculation_8]' role='measure' type='quantitative'>
        <calculation class='tableau' formula='SUM([Units]) - [Calculation_7]' />
      </column>
    </datasource>
  </datasources>
  <worksheets>
    <worksheet name='Funnel'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
    <worksheet name='Funnel Detail'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
    <worksheet name='SKU Trend'><table><view><datasources><datasource name='sku'/></datasources></view>
      <rows>[sku].[usr:Calculation_8:qk]</rows><cols>[sku].[none:Week:ok]</cols></table></worksheet>
    <worksheet name='SKU List'><table><view><datasources><datasource name='sku'/></datasources></view>
      <rows>[sku].[none:Sku:nk]</rows><cols>[sku].[sum:Units:qk]</cols></table></worksheet>
  </worksheets>
  <dashboards><dashboard name='D'><zones><zone name='Funnel'/><zone name='Funnel Detail'/><zone name='SKU Trend'/><zone name='SKU List'/></zones></dashboard></dashboards>
  </workbook>
XML
feat, = detect(helper)
check(feat && feat[:status] == :unhandled, 'a window calc (via a dependent calc) on the non-dominant datasource keeps the row blocking')
check(feat && feat[:worksheets] == ['SKU Trend'],
      "the row is attributed to only the helper sheet (got #{feat && feat[:worksheets].inspect})")

# --- single primary (two sheets, same source): must NOT fire ----------------
single = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales'><connection class='snowflake' server='x' dbname='WH'/></datasource>
  </datasources>
  <worksheet name='A'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  <worksheet name='B'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  </workbook>
XML
check(!fires?(single)[0], 'single-datasource workbook is NOT flagged')

# --- Parameters-only second source: must NOT fire ---------------------------
param = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales'><connection class='snowflake' server='x' dbname='WH'/></datasource>
    <datasource name='Parameters'><connection class='sqlproxy'/></datasource>
  </datasources>
  <worksheet name='A'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  </workbook>
XML
check(!fires?(param)[0], 'Parameters synthetic source does not count as a second datasource')

# --- pure blend (both sources on ONE sheet → single primary): must NOT fire -
blend = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales'><connection class='snowflake' server='x' dbname='WH'/></datasource>
    <datasource name='sku' caption='SKU'><connection class='snowflake' server='x' dbname='WH'/></datasource>
  </datasources>
  <worksheet name='Blended'><table><view><datasources>
    <datasource name='sales'/><datasource name='sku'/>
  </datasources></view></table></worksheet>
  </workbook>
XML
check(!fires?(blend)[0], 'single-sheet blend (one primary) is left to the blend detector, not flagged here')

puts(FAILS.empty? ? "\nall multi-datasource-gap tests passed" : "\n#{FAILS.length} FAILED")
exit(FAILS.empty? ? 0 : 1)
