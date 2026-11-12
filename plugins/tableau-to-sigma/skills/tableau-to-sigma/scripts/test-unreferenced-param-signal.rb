#!/usr/bin/env ruby
# frozen_string_literal: true

# Defect 7: a parameter declared but read by no sheet and shown on no dashboard
# must NOT count in control-scope.json sourceFilterSignals (control_lint would
# demand a control for it and exit 4). It is recorded under ignoredSignals.

require 'json'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/degradation_ledger'

DIR = __dir__
RUBY = RbConfig.ruby
$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def twb(param_on_dashboard:)
  zone = param_on_dashboard ? "<zone h='10000' id='2' name='Unused Filter' param='[Parameters].[Parameter 1]' type-v2='paramctrl' w='20000' x='0' y='0' />" : ''
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='Parameters' hasconnection='false' inline='true' name='Parameters'>
          <column caption='Unused Filter' datatype='integer' name='[Parameter 1]' param-domain-type='list' role='measure' type='quantitative' value='2024'>
            <members><member value='2023' /><member value='2024' /></members>
          </column>
        </datasource>
        <datasource caption='Fact' name='federated.ds'>
          <column caption='Region' datatype='string' name='[Region]' role='dimension' type='nominal' />
          <column caption='Sales' datatype='real' name='[Sales]' role='measure' type='quantitative' />
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Sales by Region'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.ds'>
                <column caption='Region' datatype='string' name='[Region]' role='dimension' type='nominal' />
                <column caption='Sales' datatype='real' name='[Sales]' role='measure' type='quantitative' />
                <column-instance column='[Region]' derivation='None' name='[none:Region:nk]' pivot='key' type='nominal' />
                <column-instance column='[Sales]' derivation='Sum' name='[sum:Sales:qk]' pivot='key' type='quantitative' />
              </datasource-dependencies>
            </view>
            <rows>[federated.ds].[sum:Sales:qk]</rows>
            <cols>[federated.ds].[none:Region:nk]</cols>
            <panes><pane><mark class='Bar' /></pane></panes>
          </table>
        </worksheet>
      </worksheets>
      <dashboards>
        <dashboard name='Overview'>
          <zones>
            <zone h='100000' id='1' name='Sales by Region' w='100000' x='0' y='0' />
            #{zone}
          </zones>
        </dashboard>
      </dashboards>
    </workbook>
  XML
end

def run(param_on_dashboard:)
  scope = spec = log = nil
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'workbook-content.twb'), twb(param_on_dashboard: param_on_dashboard))
    lp = File.join(dir, 'dashboard-layout.json')
    mp = File.join(dir, 'master-columns.json')
    op = File.join(dir, 'chart-specs.json')
    File.write(mp, JSON.generate('(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
                                 '(?i)^Sales$' => { 'id' => 'm-sales', 'name' => 'Sales' }))
    File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
    system(RUBY, File.join(DIR, 'parse-twb-layout.rb'), File.join(dir, 'workbook-content.twb'), lp, out: File::NULL, err: File::NULL)
    log = IO.popen([RUBY, File.join(DIR, 'build-charts-from-signals.rb'), '--tableau-dir', dir, '--layout', lp,
                    '--meta', lp.sub(/\.json\z/, '-meta.json'), '--master-map', mp, '--master-element-id', 'master',
                    '--skip-dashboard-read', 'unit-test', '--title', 'T', '--page-per-dashboard', '--out', op],
                   err: %i[child out], &:read)
    sp = File.join(dir, 'control-scope.json')
    scope = JSON.parse(File.read(sp)) if File.exist?(sp)
    spec = JSON.parse(File.read(op)) if File.exist?(op)
    if scope && spec
      lint = IO.popen([RUBY, File.join(DIR, 'lib', 'control_lint.rb'), op, sp], err: %i[child out], &:read)
      lint_code = $?.exitstatus
      cov_path = Dir[File.join(dir, '*-controls-coverage.json')].first
      $cov = cov_path && JSON.parse(File.read(cov_path))
      # the downstream gates that failed on the live proof, run on this workdir
      integ = IO.popen([RUBY, File.join(DIR, 'assert-reconstruction-integrity.rb'), '--workdir', dir], err: %i[child out], &:read)
      $integ = [integ, $?.exitstatus]
      $cuts = DegradationLedger.scope_cuts(dir)
      return [scope, spec, log, lint, lint_code]
    end
  end
  [scope, spec, log, nil, nil]
end

puts 'unreferenced, unplaced parameter'
scope, _spec, log, lint, code = run(param_on_dashboard: false)
if scope.nil?
  # Nothing recorded at all is also a pass for the contract (no signal), but
  # we expect the param to be accounted for under ignoredSignals.
  ok(false, "control-scope.json written (log: #{log.to_s[-400..]})")
else
  ok(scope['sourceFilterSignals'].to_i.zero?, "sourceFilterSignals excludes the parameter (got #{scope['sourceFilterSignals'].inspect})")
  ig = Array(scope['ignoredSignals']).first
  ok(ig && ig['name'] == 'Unused Filter' && ig['reason'].to_s.include?('referenced by no sheet'), "ignoredSignals records it (got #{ig.inspect})")
  ok(Array(scope['dropped']).none? { |d| d['name'] == 'Unused Filter' }, 'not double-reported under dropped')
  ok(code == 0, "control_lint accepts the new key / no 'no controls built' violation (exit #{code.inspect}: #{lint.to_s[0, 300]})")
  ctls = (_spec['pages'] || []).flat_map { |p| p['elements'] || [] }.select { |e| e['kind'] == 'control' }
  ok(ctls.none? { |e| e['name'] == 'Unused Filter' }, "no control emitted for it (got #{ctls.map { |e| e['name'] }.inspect})")
  ok($cov && Array($cov['detail']).none? { |r| r['name'] == 'Unused Filter' } &&
     Array($cov['ignored']).any? { |r| r['name'] == 'Unused Filter' && r['status'] == 'not-applicable' },
     "controls census lists it as ignored, not as a needs-wiring row (#{$cov && $cov.slice('detail', 'ignored').inspect})")
  ok($cov && $cov['needs_wiring'].to_i.zero? && $cov['unaccounted'].empty?, 'census: 0 needs-wiring, 0 unaccounted')
  ok($integ[1] == 0, "reconstruction integrity passes without a waiver (exit #{$integ[1]}: #{$integ[0].lines.grep(/FAIL|PASS/).first})")
  ok(Array($cuts).none? { |c| c['item'].to_s.include?('Unused Filter') }, "no scope-cut entry for it (got #{$cuts.inspect})")
end

puts 'parameter shown on a dashboard stays a counted signal'
scope2, = run(param_on_dashboard: true)
ok(scope2 && scope2['sourceFilterSignals'].to_i == 1 && Array(scope2['ignoredSignals']).empty?,
   "placed parameter still counted, not ignored (got #{scope2 && scope2.values_at('sourceFilterSignals', 'ignoredSignals').inspect})")

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
