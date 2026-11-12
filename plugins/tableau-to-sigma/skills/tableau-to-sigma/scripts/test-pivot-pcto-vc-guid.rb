#!/usr/bin/env ruby
# frozen_string_literal: true

# Live-proof regression (PR #940 holdout): on a VIRTUAL-CONNECTION datasource
# every column's internal name is a GUID, so the share calc's addressing is
#   <table-calc ordering-field='[federated.vc].[none:<guid>:nk]' ordering-type='Field'/>
# and the parser's ordering_field is that GUID, never the caption "Region"
# that the Sigma pivot column carries. Direction resolution compared names and
# fell through to "grand_total" with the NULL header sorted last. The GUID must
# resolve through the datasource caption map → "row", plus a null-first key.

require 'json'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/addressing_canon'

DIR = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
RUBY = RbConfig.ruby
$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

G_CAT = '0a1b2c3d-0000-4000-8000-00000000c001'
G_REG = '0a1b2c3d-0000-4000-8000-00000000c002'
G_REV = '0a1b2c3d-0000-4000-8000-00000000c003'
DS = 'federated.vc0000000000000000000001'

MASTER_MAP = {
  '(?i)^Category$' => { 'id' => 'm-category', 'name' => 'Category' },
  '(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Net Revenue$' => { 'id' => 'm-net-revenue', 'name' => 'Net Revenue' }
}.freeze

COLS = <<~X
  <column caption='Category' datatype='string' name='[#{G_CAT}]' role='dimension' type='nominal' />
  <column caption='Region' datatype='string' name='[#{G_REG}]' role='dimension' type='nominal' />
  <column caption='Net Revenue' datatype='real' name='[#{G_REV}]' role='measure' type='quantitative' />
X

def twb(formula:, ci_tc:, calc_tc: "<table-calc ordering-type='Rows' />")
  calc = "<column caption='Pct of Net Revenue' datatype='real' name='[Calculation_1]' role='measure' type='quantitative'>" \
         "<calculation class='tableau' formula='#{formula}'>#{calc_tc}</calculation></column>"
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='FACT (DB.FACT)+ (New Virtual Connection)' name='#{DS}'>
          #{COLS}#{calc}
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Category x Region Share'>
          <table>
            <view>
              <datasource-dependencies datasource='#{DS}'>
                #{COLS}#{calc}
                <column-instance column='[#{G_CAT}]' derivation='None' name='[none:#{G_CAT}:nk]' pivot='key' type='nominal' />
                <column-instance column='[#{G_REV}]' derivation='Sum' name='[sum:#{G_REV}:qk]' pivot='key' type='quantitative' />
                <column-instance column='[Calculation_1]' derivation='User' name='[usr:Calculation_1:qk]' pivot='key' type='quantitative'>#{ci_tc}</column-instance>
                <column-instance column='[#{G_REG}]' derivation='None' name='[none:#{G_REG}:nk]' pivot='key' type='nominal' />
              </datasource-dependencies>
            </view>
            <panes><pane><mark class='Square' /><encodings><text column='[#{DS}].[usr:Calculation_1:qk]' /></encodings></pane></panes>
            <rows>[#{DS}].[none:#{G_CAT}:nk]</rows>
            <cols>[#{DS}].[none:#{G_REG}:nk]</cols>
          </table>
        </worksheet>
      </worksheets>
      <dashboards><dashboard name='D'><zones><zone h='100000' id='1' name='Category x Region Share' w='100000' x='0' y='0' /></zones></dashboard></dashboards>
    </workbook>
  XML
end

def build(xml)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'workbook-content.twb'), xml)
    lp = File.join(dir, 'dashboard-layout.json')
    mp = File.join(dir, 'master-columns.json')
    op = File.join(dir, 'chart-specs.json')
    File.write(mp, JSON.generate(MASTER_MAP))
    File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
    return [nil, 'parser failed'] unless system(RUBY, PARSER, File.join(dir, 'workbook-content.twb'), lp, out: File::NULL, err: File::NULL)

    log = IO.popen([RUBY, BUILD, '--tableau-dir', dir, '--layout', lp, '--meta', lp.sub(/\.json\z/, '-meta.json'),
                    '--master-map', mp, '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                    '--title', 'T', '--out', op], err: %i[child out], &:read)
    out = File.exist?(op) ? JSON.parse(File.read(op)) : nil
    els = out.is_a?(Array) ? out : Array(out && out['elements']) + Array(out && out['pages']).flat_map { |p| p['elements'] || [] }
    [els.find { |e| e['kind'] == 'pivot-table' }, log]
  end
end

def value_formula(pv)
  pv && Array(pv['columns']).find { |c| Array(pv['values']).include?(c['id']) }&.dig('formula')
end

puts 'AddressingCanon unit'
cbg = { G_REG => { 'caption' => 'Region', 'datatype' => 'string' } }
tree = { 'ws' => { 'calculations' => [{ 'ordering_field' => G_REG }, { 'ordering_field' => 'Segment' }] } }
n = AddressingCanon.canonicalize!(tree, cbg)
ok(n == 1, "one GUID rewritten (got #{n})")
ok(tree['ws']['calculations'][0]['ordering_field'] == 'Region', 'GUID -> caption')
ok(tree['ws']['calculations'][0]['ordering_field_raw'] == G_REG, 'raw GUID kept for audit')
ok(tree['ws']['calculations'][1]['ordering_field'] == 'Segment', 'plain name untouched')
ok(AddressingCanon.caption_for("[#{G_REG}]", cbg) == 'Region', 'bracketed GUID resolves')

field_tc = "<table-calc ordering-field='[#{DS}].[none:#{G_REG}:nk]' ordering-type='Field' />"

puts 'SUM/TOTAL share, GUID addressing on COLUMNS'
pv, log = build(twb(formula: "SUM([#{G_REV}]) / TOTAL(SUM([#{G_REV}]))", ci_tc: field_tc))
f = value_formula(pv)
ok(f.to_s.end_with?('"row")'), "scope row, not grand_total (got #{f.inspect})")
key = pv && Array(pv['columns']).find { |c| c['id'].to_s.end_with?('-nullfirst') }
ok(key && key['formula'] == 'If(IsNull([Master/Region]), "", [Master/Region])', "null-first key on Region (got #{key.inspect})")
ok(pv && Array(pv['columnsBy']).first&.dig('sort', 'by') == key&.dig('id'), 'columnsBy sorts by the null-first key')
ok(pv && Array(pv['rowsBy']).none? { |e| e.dig('sort', 'by').to_s.end_with?('-nullfirst') }, 'Category rows untouched (not addressed)')
puts log.lines.grep(/grand_total|VERIFY/).first(3).join unless f.to_s.end_with?('"row")')

puts 'SUM/WINDOW_SUM share, same shape'
pv, = build(twb(formula: "SUM([#{G_REV}]) / WINDOW_SUM(SUM([#{G_REV}]))", ci_tc: field_tc))
f = value_formula(pv)
ok(f.to_s.end_with?('"row")'), "WINDOW_SUM scope row (got #{f.inspect})")

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
