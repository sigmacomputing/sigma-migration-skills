#!/usr/bin/env ruby
# frozen_string_literal: true

# Defect 1: percent-of-total across a pivot must pick the matching direction
# scope ("row" when the compute-using field rides the COLUMNS shelf, "column"
# when it rides ROWS), never silently "grand_total" because the addressing
# reference was decorated / unqualified / expressed as Table(Across|Down).

require 'json'
require 'rbconfig'
require 'tmpdir'

DIR = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
RUBY = RbConfig.ruby
$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MASTER_MAP = {
  '(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Segment$' => { 'id' => 'm-segment', 'name' => 'Segment' },
  '(?i)^Sales$' => { 'id' => 'm-sales', 'name' => 'Sales' }
}.freeze

DEPS = <<~X
  <column caption='Region' datatype='string' name='[Region]' role='dimension' type='nominal' />
  <column caption='Segment' datatype='string' name='[Segment]' role='dimension' type='nominal' />
  <column caption='Sales' datatype='real' name='[Sales]' role='measure' type='quantitative' />
  <column-instance column='[Region]' derivation='None' name='[none:Region:nk]' pivot='key' type='nominal' />
  <column-instance column='[Segment]' derivation='None' name='[none:Segment:nk]' pivot='key' type='nominal' />
  <column-instance column='[Sales]' derivation='Sum' name='[sum:Sales:qk]' pivot='key' type='quantitative' />
X

def run_case(rows:, cols:, tc_attrs:, extra_cols: '', calc: nil, enc_col: '[federated.ds].[pcto:sum:Sales:qk]', pill: true)
  calc_def = calc ? "<column caption='Share' datatype='real' name='[Calculation_1]' role='measure' type='quantitative'><calculation class='tableau' formula='#{calc}' /></column>" : ''
  pill_def = pill ? "<column-instance column='[Sales]' derivation='Sum' name='[pcto:sum:Sales:qk]' pivot='key' type='quantitative'><table-calc #{tc_attrs} type='PctTotal' /></column-instance>" : ''
  twb = <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='Fact' name='federated.ds'>
          <column caption='Region' datatype='string' name='[Region]' role='dimension' type='nominal' />
          <column caption='Segment' datatype='string' name='[Segment]' role='dimension' type='nominal' />
          <column caption='Sales' datatype='real' name='[Sales]' role='measure' type='quantitative' />
          #{calc_def}
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Share Matrix'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.ds'>
                #{DEPS}#{calc_def}#{pill_def}#{extra_cols}
              </datasource-dependencies>
            </view>
            <rows>#{rows}</rows>
            <cols>#{cols}</cols>
            <panes><pane><mark class='Square' /><encodings><text column='#{enc_col}' /></encodings></pane></panes>
          </table>
        </worksheet>
      </worksheets>
      <dashboards><dashboard name='D'><zones><zone h='100000' id='1' name='Share Matrix' w='100000' x='0' y='0' /></zones></dashboard></dashboards>
    </workbook>
  XML
  out = nil
  log = ''
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'workbook-content.twb'), twb)
    lp = File.join(dir, 'dashboard-layout.json')
    mp = File.join(dir, 'master-columns.json')
    op = File.join(dir, 'chart-specs.json')
    File.write(mp, JSON.generate(MASTER_MAP))
    File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
    next unless system(RUBY, PARSER, File.join(dir, 'workbook-content.twb'), lp, out: File::NULL, err: File::NULL)
    log = IO.popen([RUBY, BUILD, '--tableau-dir', dir, '--layout', lp, '--meta', lp.sub(/\.json\z/, '-meta.json'),
                    '--master-map', mp, '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                    '--title', 'T', '--out', op], err: %i[child out], &:read)
    out = JSON.parse(File.read(op)) if File.exist?(op)
  end
  els = out.is_a?(Array) ? out : Array(out && out['elements']) + Array(out && out['pages']).flat_map { |p| p['elements'] || [] }
  pv = els.find { |e| e['kind'] == 'pivot-table' }
  vc = pv && Array(pv['columns']).find { |c| Array(pv['values']).include?(c['id']) }
  [vc && vc['formula'], log, pv]
end

def scope_of(f)
  f.to_s[/"(row|column|grand_total)"\)/, 1]
end

ROWS_SEG = '[federated.ds].[none:Segment:nk]'
COLS_REG = '[federated.ds].[none:Region:nk]'

puts 'quick-calc pcto'
f, = run_case(rows: ROWS_SEG, cols: COLS_REG, tc_attrs: "ordering-field='[federated.ds].[none:Region:nk]' ordering-type='Field'")
ok(scope_of(f) == 'row', "Region on COLUMNS, qualified ordering-field -> row (got #{f.inspect})")
f, = run_case(rows: COLS_REG, cols: ROWS_SEG, tc_attrs: "ordering-field='[federated.ds].[none:Region:nk]' ordering-type='Field'")
ok(scope_of(f) == 'column', "Region on ROWS -> column (got #{f.inspect})")
f, = run_case(rows: ROWS_SEG, cols: COLS_REG, tc_attrs: "ordering-field='[none:Region:nk]' ordering-type='Field'")
ok(scope_of(f) == 'row', "unqualified decorated ordering-field -> row (got #{f.inspect})")
f, = run_case(rows: ROWS_SEG, cols: COLS_REG, tc_attrs: "ordering-field='[Region]' ordering-type='Field'")
ok(scope_of(f) == 'row', "bare [Region] ordering-field -> row (got #{f.inspect})")
f, = run_case(rows: ROWS_SEG, cols: COLS_REG, tc_attrs: "ordering-type='Rows'")
ok(scope_of(f) == 'row', "Table(Across) -> row (got #{f.inspect})")
f, = run_case(rows: ROWS_SEG, cols: COLS_REG, tc_attrs: "ordering-type='Columns'")
ok(scope_of(f) == 'column', "Table(Down) -> column (got #{f.inspect})")
f, log, = run_case(rows: ROWS_SEG, cols: COLS_REG, tc_attrs: "ordering-field='[federated.ds].[none:Nowhere:nk]' ordering-type='Field'")
ok(scope_of(f) == 'grand_total', "unresolved addressing -> grand_total (got #{f.inspect})")

puts 'explicit share calc (SUM/TOTAL, SUM/WINDOW_SUM)'
[['SUM([Sales]) / TOTAL(SUM([Sales]))', 'TOTAL'], ['SUM([Sales]) / WINDOW_SUM(SUM([Sales]))', 'WINDOW_SUM']].each do |formula, label|
  ci = "<column-instance column='[Calculation_1]' derivation='User' name='[usr:Calculation_1:qk]' pivot='key' type='quantitative'><table-calc %s /></column-instance>"
  [[ROWS_SEG, COLS_REG, "ordering-field='[federated.ds].[none:Region:nk]' ordering-type='Field'", 'row'],
   [COLS_REG, ROWS_SEG, "ordering-field='[federated.ds].[none:Region:nk]' ordering-type='Field'", 'column'],
   [ROWS_SEG, COLS_REG, "ordering-type='Rows'", 'row'],
   [ROWS_SEG, COLS_REG, "ordering-type='Columns'", 'column'],
   [ROWS_SEG, COLS_REG, "ordering-field='[federated.ds].[none:Nowhere:nk]' ordering-type='Field'", 'grand_total']].each do |r, c, tc, want|
    f, = run_case(rows: r, cols: c, tc_attrs: tc, calc: formula, pill: false,
                  extra_cols: ci % tc, enc_col: '[federated.ds].[usr:Calculation_1:qk]')
    ok(f.to_s.include?('PercentOfTotal') && scope_of(f) == want, "#{label} #{tc[/ordering-\w+='\w+/]} -> #{want} (got #{f.inspect})")
  end
end

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
