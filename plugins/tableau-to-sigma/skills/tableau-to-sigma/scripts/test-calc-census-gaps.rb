#!/usr/bin/env ruby
# frozen_string_literal: true
#
# The three census objects that held two regression dashboards at YELLOW after
# every value and visual gate passed (Retail Command Center, Migration Stress 4):
#
#   1. A FIXED LOD used as a plain DIMENSION (Cohort Year = {FIXED [Customer Id]
#      : MIN(YEAR([Order Date]))} on a pivot's Rows). The converter refuses it,
#      but apply-lod-dim-helpers.rb builds it (grouped helper + Lookup), and the
#      tile passed parity on exactly that build. The gap scan's formula audit
#      must reclassify it chart_only (translator lod_dim_helper) — the census
#      reads the audit's not_converted as needs-review no matter what was built.
#      Shapes the helper does not build stay refused.
#   2. Calcs the builder emits under a DERIVED column name — a table calc under
#      its Tableau CSV export header ("Revenue Rank along Store Name") and a
#      Color-shelf flag as its hidden conditional-format driver ("Low Margin
#      Flag (flag)"). The census must see them as built.
#   3. A filled map: the basemap style is carried (mapStyle.baseStyle); washout
#      and a stepped ramp are named residuals keyed to candidate catalog ids,
#      retired only by ids the platform-difference catalog actually ships.
#
# Offline, creds-free. Usage: ruby scripts/test-calc-census-gaps.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'fileutils'

DIR = __dir__
RUBY = RbConfig.ruby
SCAN = File.join(DIR, 'scan-workbook-gaps.rb')
CENSUS = File.join(DIR, 'build-source-object-census.rb')
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
CORPUS_TWB = File.expand_path('../../../../../corpus/tableau/fixed-lod-dimension/workbook-content.twb', DIR)

$fails = []
def check(ok, msg)
  puts "  #{ok ? 'PASS' : 'FAIL'}  #{msg}"
  $fails << msg unless ok
end

def scan(twb_text)
  Dir.mktmpdir do |d|
    path = File.join(d, 'workbook-content.twb')
    File.write(path, twb_text)
    out, st = Open3.capture2e(RUBY, SCAN, path, chdir: d)
    audit_path = File.join(d, 'formula-audit.json')
    report = Dir[File.join(d, '*gaps-report.json')].first
    { ok: st.success?, log: out,
      audit: File.file?(audit_path) ? JSON.parse(File.read(audit_path)) : nil,
      report: report ? JSON.parse(File.read(report)) : nil }
  end
end

def row(audit, caption)
  Array(audit && audit['formulas']).find { |r| r['caption'] == caption }
end

def refused_gap?(report, caption)
  features = Array(report && (report['detected_features'] || report['features']))
  features.any? { |f| f['name'].to_s.start_with?('Converter-refused') && f['name'].to_s.end_with?(caption) }
end

base_twb = File.read(CORPUS_TWB, encoding: 'utf-8')

puts 'Part 1 - FIXED LOD as a dimension: the formula audit mirrors apply-lod-dim-helpers'
r = scan(base_twb)
check(r[:ok], "gap scan runs (#{r[:log].lines.last.to_s.strip})")
cy = row(r[:audit], 'Cohort Year')
check(cy && cy['status'] == 'chart_only' && cy['converter_status'] == 'not_converted',
      "Cohort Year: converter refusal reclassified chart_only (got #{cy && cy.values_at('status', 'converter_status').inspect})")
tr = cy && cy['chart_translator']
check(tr && tr['translator'] == 'lod_dim_helper' && tr['mode'] == 'grouped-helper-lookup' &&
        tr['worksheets'] == ['Customer Cohorts'] && tr['contexts'] == ['dimension'],
      "the evidence names the helper translator and the sheet (got #{tr.inspect})")
check(tr && tr['note'].include?('Min(Year([Order Date])) by Customer Id'),
      "the note states the helper's grouping and aggregate (got #{tr && tr['note'].inspect})")
check(!refused_gap?(r[:report], 'Cohort Year'), 'no converter-refused gap row for Cohort Year (the gap gate stops on it no more)')

# Field FORMATTING that restates the pill is styling only (never a formula):
# it must not block the helper.
formatted_twb = base_twb.sub(
  '        <rows>[federated.fixture].[none:Calculation_7700000000000001:ok]</rows>',
  "        <style><style-rule element='cell'><format attr='text-format' " \
  "field='[federated.fixture].[none:Calculation_7700000000000001:ok]' value='n0' /></style-rule></style>\n" \
  '        <rows>[federated.fixture].[none:Calculation_7700000000000001:ok]</rows>'
)
r = scan(formatted_twb)
cy = row(r[:audit], 'Cohort Year')
check(formatted_twb != base_twb && cy && cy['status'] == 'chart_only',
      "a <format> restatement of the dimension pill does not block its helper (got #{cy && cy['status']})")
# Anything else that restates it (title/tooltip text, a sort, a reference line)
# may become a formula the helper does not rewrite: fail closed.
{
  'title text' => "<formatted-text><run>&lt;[federated.fixture].[none:Calculation_7700000000000001:ok]&gt;</run></formatted-text>",
  'sort' => "<sort column='[federated.fixture].[none:Calculation_7700000000000001:ok]' />",
  'reference line' => "<reference-line value-column='[federated.fixture].[none:Calculation_7700000000000001:ok]' />"
}.each do |label, xml|
  twb = base_twb.sub('        <rows>[federated.fixture].[none:Calculation_7700000000000001:ok]</rows>',
                     "        #{xml}\n        <rows>[federated.fixture].[none:Calculation_7700000000000001:ok]</rows>")
  r = scan(twb)
  cy = row(r[:audit], 'Cohort Year')
  check(twb != base_twb && cy && cy['status'] == 'not_converted',
        "a #{label} restating the dimension pill keeps it refused (fail closed; got #{cy && cy['status']})")
end

# A date-part instance (YEAR(Cohort Year) on Rows) is not the bare column the
# helper rewrites: the build would emit Year([Master/Cohort Year]) and nothing
# materializes it — keep refusing.
yr_twb = base_twb.gsub('[none:Calculation_7700000000000001:ok]', '[yr:Calculation_7700000000000001:ok]')
r = scan(yr_twb)
cy = row(r[:audit], 'Cohort Year')
check(cy && cy['status'] == 'not_converted', "a date-part instance on Rows stays refused (got #{cy && cy['status']})")

# Not on a built sheet (no dashboard zone shows the worksheet) → not built → refused.
unplaced = base_twb.sub("name='Customer Cohorts' w='100000'", "name='Something Else' w='100000'")
r = scan(unplaced)
cy = row(r[:audit], 'Cohort Year')
check(cy && cy['status'] == 'not_converted', "a sheet no dashboard shows is not built: stays refused (got #{cy && cy['status']})")

# Two dimensions → outside LodDimHelper's scope (ONE dimension) → refused.
two_dims = base_twb.gsub('{FIXED [Customer Id] : MIN(YEAR([Order Date]))}', '{FIXED [Customer Id], [Region] : MIN(YEAR([Order Date]))}')
r = scan(two_dims)
cy = row(r[:audit], 'Cohort Year')
check(cy && cy['status'] == 'not_converted', "a two-dimension FIXED stays refused (got #{cy && cy['status']})")

# The FIXED key is itself a refused calc → the helper would group on a column
# no master carries → refused.
bad_key = base_twb.sub("<column caption='Cohort Year'",
                       "<column caption='Cust Key' datatype='string' name='[Calculation_7700000000000002]' role='dimension' type='nominal'>" \
                       "<calculation class='tableau' formula='{FIXED [Region] : MIN([Customer Id])}' /></column>\n      <column caption='Cohort Year'")
                  .gsub('{FIXED [Customer Id] : MIN(YEAR([Order Date]))}', '{FIXED [Calculation_7700000000000002] : MIN(YEAR([Order Date]))}')
r = scan(bad_key)
cy = row(r[:audit], 'Cohort Year')
check(cy && cy['status'] == 'not_converted', "a FIXED keyed on a refused calc stays refused (got #{cy && cy['status']})")

# Another calc references the FIXED LOD → the data model ships that calc with
# a dangling ref (the helper rewrites only tile columns): keep refusing, and the
# dependent keeps blocked_by.
dep_twb = base_twb.sub("<column caption='Cohort Year'",
                       "<column caption='Cohort Label' datatype='string' name='[Calculation_7700000000000002]' role='dimension' type='nominal'>" \
                       "<calculation class='tableau' formula='&quot;FY&quot; + STR([Calculation_7700000000000001])' /></column>\n      <column caption='Cohort Year'")
                  .sub('<cols>[federated.fixture].[none:Loyalty Tier:nk]</cols>',
                       '<cols>[federated.fixture].[none:Loyalty Tier:nk] / [federated.fixture].[none:Calculation_7700000000000002:nk]</cols>')
r = scan(dep_twb)
cy = row(r[:audit], 'Cohort Year')
lbl = row(r[:audit], 'Cohort Label')
check(cy && cy['status'] == 'not_converted' && lbl && lbl['blocked_by'] == ['Cohort Year'] && refused_gap?(r[:report], 'Cohort Year'),
      "a FIXED dimension another calc references stays refused; the dependent keeps blocked_by (got #{cy && cy['status']} / #{lbl && lbl['blocked_by'].inspect})")

# Also used some other way on a built sheet (here: a Color encoding) → that use
# is not rewritten by the helper → refused.
color_twb = base_twb.sub("<encodings><text column='[federated.fixture].[ctd:Customer Id:qk]' /></encodings>",
                         "<encodings><text column='[federated.fixture].[ctd:Customer Id:qk]' />" \
                         "<color column='[federated.fixture].[none:Calculation_7700000000000001:ok]' /></encodings>")
r = scan(color_twb)
cy = row(r[:audit], 'Cohort Year')
check(color_twb != base_twb && cy && cy['status'] == 'not_converted',
      "a FIXED dimension also on a Color encoding stays refused (got #{cy && cy['status']})")
agg_twb = base_twb.sub("<encodings><text column='[federated.fixture].[ctd:Customer Id:qk]' /></encodings>",
                       "<encodings><text column='[federated.fixture].[ctd:Customer Id:qk]' />" \
                       "<tooltip column='[federated.fixture].[avg:Calculation_7700000000000001:qk]' /></encodings>")
r = scan(agg_twb)
cy = row(r[:audit], 'Cohort Year')
check(agg_twb != base_twb && cy && cy['status'] == 'not_converted',
      "a FIXED dimension also used aggregated (AVG on a tooltip) stays refused (got #{cy && cy['status']})")

puts
puts 'Part 2 - census: calcs built under derived column names'
src = File.read(CENSUS)
check(src.include?("FLAG_COLUMN_SUFFIX = ' (flag)'"), 'census pins the builder flag-column suffix')
check(File.read(BUILD).include?(%q('name' => "#{label} (flag)")),
      'build-charts still names the Color-shelf flag column "<label> (flag)" (the census suffix must follow it)')

CALC_TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Stores' name='federated.cg'>
        <column caption='Store Name' datatype='string' name='[Store Name]' role='dimension' type='nominal' />
        <column caption='Net Revenue' datatype='real' name='[Net Revenue]' role='measure' type='quantitative' />
        <column caption='Gross Profit' datatype='real' name='[Gross Profit]' role='measure' type='quantitative' />
        <column caption='Revenue Rank' datatype='integer' name='[Calculation_1]' role='measure' type='quantitative'>
          <calculation class='tableau' formula='RANK(SUM([Net Revenue]))' />
        </column>
        <column caption='Low Margin Flag' datatype='boolean' name='[Calculation_2]' role='measure' type='nominal'>
          <calculation class='tableau' formula='SUM([Gross Profit]) / SUM([Net Revenue]) &lt; 0.66' />
        </column>
        <column caption='Margin Watch' datatype='boolean' name='[Calculation_3]' role='measure' type='nominal'>
          <calculation class='tableau' formula='SUM([Gross Profit]) &lt; 0' />
        </column>
      </datasource>
    </datasources>
    <worksheets><worksheet name='Store Rank Table'><table><view><datasources><datasource name='federated.cg' /></datasources></view>
      <rows>[federated.cg].[none:Store Name:nk]</rows><cols /></table></worksheet></worksheets>
    <dashboards><dashboard name='Stores'><zones><zone h='100000' id='1' name='Store Rank Table' w='100000' x='0' y='0' /></zones></dashboard></dashboards>
  </workbook>
XML

def census_statuses(twb, columns, audit_rows)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'workbook-content.twb'), twb)
    File.write(File.join(d, 'wb-spec.json'), JSON.generate(
      'document' => { 'pages' => [{ 'id' => 'p1', 'name' => 'Stores' }],
                      'elements' => [{ 'id' => 'el-rank', 'kind' => 'table', 'name' => 'Store Rank Table',
                                       'columns' => columns.map.with_index do |(n, f), i|
                                         { 'id' => "c#{i}", 'name' => n, 'formula' => f || "[Master/#{n}]" }
                                       end }] }
    ))
    File.write(File.join(d, 'formula-audit.json'), JSON.generate('formulas' => audit_rows))
    File.write(File.join(d, 'parity-final.json'), JSON.generate('status' => 'PASS'))
    out, st = Open3.capture2e(RUBY, CENSUS, '--workdir', d)
    return { ok: st.success?, log: out } unless st.success?
    doc = JSON.parse(File.read(File.join(d, 'source-object-census.json')))
    { ok: true, by: doc['objects'].select { |o| o['type'] == 'calculation' }.to_h { |o| [o['name'], o] } }
  end
end

spec_rows = [
  { 'caption' => 'Revenue Rank', 'internal_name' => '[Calculation_1]', 'status' => 'chart_only' },
  { 'caption' => 'Low Margin Flag', 'internal_name' => '[Calculation_2]', 'status' => 'spec' },
  { 'caption' => 'Margin Watch', 'internal_name' => '[Calculation_3]', 'status' => 'spec' }
]
RANK_F = 'If(IsNull(Sum([Master/Net Revenue])), Null, Rank(-(Sum([Master/Net Revenue])), "asc"))'
FLAG_F = 'Sum([Master/Gross Profit]) / Sum([Master/Net Revenue]) < 0.66'
c = census_statuses(CALC_TWB, ['Store Name', ['Net Revenue', 'Sum([Master/Net Revenue])'],
                               ['Revenue Rank along Store Name', RANK_F], ['Low Margin Flag (flag)', FLAG_F]], spec_rows)
check(c[:ok], "census runs (#{c[:log].to_s.lines.last.to_s.strip})")
by = c[:by] || {}
check(by.dig('Revenue Rank', 'status') == 'migrated',
      "a table calc built under its Tableau CSV header ('... along Store Name') is migrated (got #{by.dig('Revenue Rank', 'status')})")
check(by.dig('Low Margin Flag', 'status') == 'migrated',
      "a Color-shelf flag built as its '(flag)' driver column is migrated (got #{by.dig('Low Margin Flag', 'status')})")
check(by.dig('Margin Watch', 'status') == 'needs-review',
      "a calc with no built column at all stays needs-review (got #{by.dig('Margin Watch', 'status')})")
# The derived-name rule must not read the BASE of an unrelated column as a
# different calc: "Rank along Revenue" is not "Revenue".
c2 = census_statuses(CALC_TWB.sub("caption='Margin Watch'", "caption='Revenue'"), [['Rank along Revenue', RANK_F]],
                     spec_rows.map { |rw| rw['caption'] == 'Margin Watch' ? rw.merge('caption' => 'Revenue') : rw })
check(c2[:ok] && c2[:by].dig('Revenue', 'status') == 'needs-review',
      "only the base name before ' along ' counts (got #{c2[:by] && c2[:by].dig('Revenue', 'status')})")
# A PHYSICAL column (including its chart aggregate) is never a calc under a derived name:
# "Margin Watch along Route" passed straight through from the warehouse does
# not build the calc "Margin Watch".
c4 = census_statuses(CALC_TWB, [['Margin Watch along Route', 'Sum([Master/Margin Watch along Route])'],
                                ['Margin Watch (flag)', 'CountDistinct([Master/Margin Watch (flag)])']], spec_rows)
check(c4[:ok] && c4[:by].dig('Margin Watch', 'status') == 'needs-review',
      "an aggregated physical column never counts as a derived-name calc (got #{c4[:by] && c4[:by].dig('Margin Watch', 'status')})")
# A refusal in the formula audit still wins over a built column of that name.
c3 = census_statuses(CALC_TWB, [['Revenue Rank along Store Name', RANK_F]],
                     [{ 'caption' => 'Revenue Rank', 'internal_name' => '[Calculation_1]', 'status' => 'not_converted' }])
check(c3[:ok] && c3[:by].dig('Revenue Rank', 'status') == 'needs-review',
      "a not_converted audit row still holds needs-review (got #{c3[:by] && c3[:by].dig('Revenue Rank', 'status')})")
# End to end with the gap scan: the reclassified Cohort Year + its built helper column → migrated.
Dir.mktmpdir do |d|
  File.write(File.join(d, 'workbook-content.twb'), base_twb)
  Open3.capture2e(RUBY, SCAN, File.join(d, 'workbook-content.twb'), chdir: d)
  File.write(File.join(d, 'wb-spec.json'), JSON.generate(
    'document' => { 'pages' => [{ 'id' => 'p1', 'name' => 'Customers' }],
                    'elements' => [{ 'id' => 'lod-cohort-year-helper', 'kind' => 'table', 'name' => 'Cohort Year Helper',
                                     'columns' => [{ 'id' => 'a', 'name' => 'Cohort Year' }] },
                                   { 'id' => 'el', 'kind' => 'pivot-table', 'name' => 'Customer Cohorts',
                                     'columns' => [{ 'id' => 'b', 'name' => 'Cohort Year' }] }] }
  ))
  File.write(File.join(d, 'parity-final.json'), JSON.generate('status' => 'PASS'))
  _o, st = Open3.capture2e(RUBY, CENSUS, '--workdir', d)
  obj = st.success? && JSON.parse(File.read(File.join(d, 'source-object-census.json')))['objects']
                           .find { |o| o['type'] == 'calculation' && o['name'] == 'Cohort Year' }
  check(obj && obj['status'] == 'migrated',
        "gap scan + census: the helper-built FIXED dimension is migrated (got #{obj && obj['status']})")
end

puts
puts 'Part 3 - map styling plan'
build_src = File.read(BUILD)
block = build_src[/^# ---- Tableau map styling → Sigma region-map mapStyle -+\n.*?(?=^def platform_difference_ids)/m]
check(!block.nil?, 'the map styling helpers are extractable')
eval(block.to_s) # rubocop:disable Security/Eval
plan = region_map_style_plan('formats' => { 'map-style' => 'light', 'washout' => '0.25' }, 'sources' => ['Tableau'], 'color_steps' => 8)
check(plan[:base_style] == 'light', "light → baseStyle light (got #{plan[:base_style].inspect})")
check(plan[:residuals].map { |x| x[:catalog_id] } == %w[map-basemap-washout map-stepped-color-scale],
      "washout + steps are the two residuals, keyed to candidate catalog ids (got #{plan[:residuals].inspect})")
check(map_open_residuals(plan[:residuals], []).size == 2, 'no catalog ids shipped → both stay open (the map stays approximated)')
check(map_open_residuals(plan[:residuals], %w[map-basemap-washout map-stepped-color-scale]).empty?,
      'both ids catalogued → nothing open (the map is not approximated)')
check(map_open_residuals(plan[:residuals], %w[map-basemap-washout]).map { |x| x[:catalog_id] } == ['map-stepped-color-scale'],
      'only the catalogued residual retires')
%w[dark streets satellite].each do |st|
  check(region_map_style_plan('formats' => { 'map-style' => st })[:base_style] == st, "#{st} → baseStyle #{st}")
end
normal = region_map_style_plan('formats' => { 'map-style' => 'normal' }, 'sources' => ['Tableau'])
check(normal[:base_style].nil? && normal[:residuals].size == 1 && normal[:residuals][0][:catalog_id].nil?,
      "'normal' has no Sigma twin: no baseStyle, one uncatalogued residual (got #{normal.inspect})")
clean = region_map_style_plan('formats' => {}, 'sources' => ['Tableau'], 'color_steps' => nil)
check(clean == { base_style: nil, residuals: [] }, "a default map has nothing to carry or report (got #{clean.inspect})")
zero = region_map_style_plan('formats' => { 'washout' => '0' }, 'sources' => ['Tableau'])
check(zero[:residuals].empty?, 'washout 0 is not a residual')
wms = region_map_style_plan('formats' => { 'map-style' => 'light', 'map-layer-streets' => 'true' }, 'sources' => %w[Tableau MyWMS])
check(wms[:residuals].map { |x| x[:detail] } == ['map setting map-layer-streets=true', "background map source 'MyWMS'"] &&
        wms[:residuals].all? { |x| x[:catalog_id].nil? },
      "an unknown map setting and a non-Tableau map source are named, uncatalogued residuals (got #{wms[:residuals].inspect})")
none = region_map_style_plan(nil)
check(none[:residuals].size == 1 && none[:residuals][0][:detail].include?('not inspected') &&
        none[:residuals][0][:catalog_id].nil?,
      'no map_style signal fails closed (one open residual, never a clean map)')

puts
if $fails.empty?
  puts 'test-calc-census-gaps: ALL PASS'
else
  puts "test-calc-census-gaps: #{$fails.size} FAILURE(S)"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
