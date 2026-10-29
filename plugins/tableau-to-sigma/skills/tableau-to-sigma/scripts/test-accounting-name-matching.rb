#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Source-accounting regressions found in a real Tableau run whose verdict was
# RED although the build was fine. Synthetic, creds-free; neutral names only.
#
#   A. The census registered every calculation TWICE: once from the TWB
#      (keyed by internal name) and once from calc-fields.json, whose Metadata-API
#      records often lack internal_name and so keyed by caption.
#   B. Report name matching folded away meaningful whitespace (worksheets "X",
#      "X ", "X  " collapsed to one key / became mutually ambiguous) and could
#      not route a worksheet-vs-dashboard-zone name collision.
#   C. Parameter controls always ended up contradictory / mis-reported:
#      C1 (builder) a control no page carries was still written as "emitted";
#      C2 (report) census "built but not proven by parity" vs controls-coverage
#         "migrated" is not a contradiction, while real conflicts still are.
#
# Usage: ruby scripts/test-accounting-name-matching.rb
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

DIR    = __dir__
CENSUS = File.join(DIR, 'build-source-object-census.rb')
REPORT = File.join(DIR, 'build-migration-report.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')
RUBY   = RbConfig.ruby

$failures = []
def check(condition, message)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  $failures << message unless condition
end

def write_json(dir, name, value)
  path = File.join(dir, name)
  File.write(path, JSON.pretty_generate(value))
  path
end

def run_report(dir)
  # Test harness: runs the fixed report script under test against this file's temp-dir fixture.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  _out, err, _st = Open3.capture3(RUBY, REPORT, '--workdir', dir)
  [JSON.parse(File.read(File.join(dir, 'migration-result.json'))), err]
end

def consistency(result)
  result['checks'].find { |c| c['name'] == 'status-consistency' }
end

def by_id(result)
  result['source_objects'].to_h { |o| [o['id'], o] }
end

# ---------------------------------------------------------------------------
# A + B (census) + C (pipeline): one synthetic workbook through census + report
# ---------------------------------------------------------------------------
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8'?>
  <workbook>
    <datasources>
      <datasource caption='Orders' name='orders'>
        <column caption='Gross Margin' datatype='real' name='[Calculation_123]' role='measure'>
          <calculation class='tableau' formula='SUM([Profit]) / SUM([Sales])' />
        </column>
        <column caption='Net Rev' datatype='real' name='[Calculation_456]' role='measure'>
          <calculation class='tableau' formula='SUM([Sales]) - SUM([Discount])' />
        </column>
      </datasource>
      <datasource caption='Returns' name='returns'>
        <column caption='Gross Margin' datatype='real' name='[Calculation_789]' role='measure'>
          <calculation class='tableau' formula='SUM([Refund])' />
        </column>
      </datasource>
      <datasource name='Parameters'>
        <column caption='Metric' datatype='string' name='[Parameter 1]' param-domain-type='list' value='Sales' />
        <column caption='Unused Picker' datatype='string' name='[Parameter 2]' param-domain-type='list' value='A' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Sales Trend' />
      <worksheet name='X' />
      <worksheet name='X ' />
      <worksheet name='X  ' />
    </worksheets>
    <dashboards>
      <dashboard name='Overview'>
        <zones>
          <zone id='1' name='Sales Trend' />
          <zone id='2' name='X' />
          <zone id='3' name='X ' />
          <zone id='4' name='X  ' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

Dir.mktmpdir('acct-name-match') do |dir|
  twb = File.join(dir, 'workbook-content.twb')
  File.write(twb, TWB)
  calcs = write_json(dir, 'calc-fields.json', 'calcs' => [
    # Metadata-API shapes: no internal_name; caption (+ maybe datasource) only.
    { 'name' => 'Gross Margin', 'datasource' => 'Orders', 'formula' => 'SUM([Profit]) / SUM([Sales])' },
    { 'name' => 'Gross Margin', 'datasource' => 'Returns', 'formula' => 'SUM([Refund])' },
    { 'name' => 'Net Rev', 'formula' => 'SUM([Sales]) - SUM([Discount])' },
    # internal_name only matches (caption drifted).
    { 'name' => 'Margin (renamed)', 'internal_name' => 'Calculation_456', 'datasource' => 'Orders' },
    # Genuinely extra: not in the TWB at all.
    { 'name' => 'Extra Metric', 'datasource' => 'Orders', 'formula' => 'COUNT([Order])' }
  ])
  layout = write_json(dir, 'dashboard-layout.json', [{
    'dashboard' => 'Overview',
    'zones' => [
      { 'id' => '1', 'kind' => 'chart', 'caption' => 'Sales Trend' },
      { 'id' => '2', 'kind' => 'chart', 'caption' => 'X' },
      { 'id' => '3', 'kind' => 'chart', 'caption' => 'X ' },
      { 'id' => '4', 'kind' => 'chart', 'caption' => 'X  ' }
    ]
  }])
  controls = write_json(dir, 'layout-controls-coverage.json', 'detail' => [
    { 'kind' => 'parameter', 'name' => 'Metric', 'status' => 'emitted' },
    { 'kind' => 'parameter', 'name' => 'Unused Picker', 'status' => 'dropped-unused',
      'reason' => 'dead control: no chart formula reads this parameter' }
  ])
  # PARTIAL parity that names only Sales Trend: Metric is built but unproven.
  write_json(dir, 'parity-final.json', 'status' => 'PARTIAL', 'charts_total' => 1, 'charts_pass' => 1,
                                       'pass_names' => ['Sales Trend'], 'fail_names' => [])
  readback = write_json(dir, 'wb-readback.json',
                        'pages' => [{ 'id' => 'p1', 'name' => 'Overview' }],
                        'elements' => [
                          { 'id' => 'metric', 'kind' => 'control', 'name' => 'Metric',
                            'controlId' => 'ctl-metric', 'controlType' => 'list' }
                        ])
  _o, stderr, status = Open3.capture3(RUBY, CENSUS, '--workdir', dir, '--twb', twb,
                                      '--dashboard-layout', layout, '--calc-fields', calcs,
                                      '--controls-census', controls,
                                      '--parity-final', File.join(dir, 'parity-final.json'),
                                      '--wb-readback', readback)
  check(status.success?, "census runs on the synthetic workbook (#{stderr})")
  census = JSON.parse(File.read(File.join(dir, 'source-object-census.json')))
  objects = census['objects']

  puts 'A. one object per calculation'
  calc_objects = objects.select { |o| o['type'] == 'calculation' }
  check(calc_objects.length == 4,
        "3 TWB calcs + 1 genuinely extra Metadata-API calc = 4 objects (got #{calc_objects.length}: " \
        "#{calc_objects.map { |o| o['id'] }.inspect})")
  ids = calc_objects.map { |o| o['id'] }
  check(ids.include?('calculation:Orders:[Calculation_123]') &&
        ids.include?('calculation:Orders:[Calculation_456]') &&
        ids.include?('calculation:Returns:[Calculation_789]'),
        'TWB calcs keep their internal-name ids')
  check(ids.none? { |id| id == 'calculation:Orders:Gross Margin' || id == 'calculation:datasource:Net Rev' },
        'no caption-keyed twin of a TWB calc')
  check(ids.include?('calculation:Orders:Extra Metric'),
        'a Metadata-API calc absent from the TWB is still registered')
  check(calc_objects.map { |o| o['name'] }.count('Gross Margin') == 2,
        'same caption in two datasources stays two objects')

  puts 'B. trailing-space names stay distinct in the census'
  sheets = objects.select { |o| o['type'] == 'worksheet' }
  check(sheets.map { |o| o['name'] }.sort == ['Sales Trend', 'X', 'X ', 'X  '],
        "worksheets X / 'X ' / 'X  ' are three objects (got #{sheets.map { |o| o['name'] }.inspect})")
  check(sheets.map { |o| o['id'] }.uniq.length == sheets.length,
        'worksheet ids are distinct')
  check(sheets.map { |o| o['id'] }.include?('worksheet:X ') && sheets.map { |o| o['id'] }.include?('worksheet:X  '),
        'ids carry the exact name, trailing spaces included')

  puts 'C. built-but-unproven control, unused control (census -> report)'
  param = ->(name) { objects.find { |o| o['type'] == 'parameter' && o['name'] == name } }
  check(param.call('Metric')['status'] == 'needs-review' &&
        param.call('Metric')['evidence'].any? { |e| e['detail'].to_s.include?('does not prove') },
        'census: built control not named by parity is needs-review (unproven)')
  check(param.call('Unused Picker')['status'] == 'skipped',
        "census: a dropped-unused controls-coverage row is skipped (got #{param.call('Unused Picker')['status']})")

  result, err = run_report(dir)
  check(consistency(result)['status'] == 'PASS',
        "report: status-consistency passes on the real census output (#{consistency(result)['message']})")
  check(err.to_s.empty? || !err.include?('duplicate'), 'report: no duplicate inventory identities')
  ro = by_id(result)
  metric = ro.values.find { |o| o['type'] == 'parameter' && o['name'] == 'Metric' }
  check(metric['status'] == 'needs-review' && metric['status_sources'].length >= 2,
        'report: Metric resolves to needs-review and keeps both evidence entries')
  unused = ro.values.find { |o| o['type'] == 'parameter' && o['name'] == 'Unused Picker' }
  check(unused['status'] == 'skipped', 'report: dropped-unused maps to skipped (not migrated)')
  check(result['source_objects'].count { |o| o['type'] == 'worksheet' } == 4,
        'report: all four worksheets (incl. trailing-space names) are inventory objects')
end

# ---------------------------------------------------------------------------
# B (report): exact-before-folded matching, worksheet vs zone routing
# ---------------------------------------------------------------------------
def inventory_objects
  [
    { 'type' => 'dashboard', 'id' => 'dashboard:Overview', 'name' => 'Overview' },
    { 'type' => 'dashboard', 'id' => 'dashboard:Detail', 'name' => 'Detail' },
    # decorative sheets that differ only by trailing spaces
    { 'type' => 'worksheet', 'id' => 'worksheet:X', 'name' => 'X' },
    { 'type' => 'worksheet', 'id' => 'worksheet:X ', 'name' => 'X ' },
    { 'type' => 'worksheet', 'id' => 'worksheet:X  ', 'name' => 'X  ' },
    # names that differ only by case
    { 'type' => 'worksheet', 'id' => 'worksheet:Rev#1', 'name' => 'Rev' },
    { 'type' => 'worksheet', 'id' => 'worksheet:Rev#2', 'name' => 'rev' },
    # a worksheet and the dashboard zone that places it share a name
    { 'type' => 'worksheet', 'id' => 'worksheet:Sales Trend', 'name' => 'Sales Trend' },
    { 'type' => 'dashboard-zone', 'id' => 'dashboard-zone:Overview:1', 'name' => 'Sales Trend' },
    { 'type' => 'worksheet', 'id' => 'worksheet:Margin', 'name' => 'Margin' },
    { 'type' => 'dashboard-zone', 'id' => 'dashboard-zone:Overview:2', 'name' => 'Margin' },
    # one sheet placed on two dashboards: two same-named zones
    { 'type' => 'worksheet', 'id' => 'worksheet:Pair', 'name' => 'Pair' },
    { 'type' => 'dashboard-zone', 'id' => 'dashboard-zone:Overview:3', 'name' => 'Pair' },
    { 'type' => 'dashboard-zone', 'id' => 'dashboard-zone:Detail:3', 'name' => 'Pair' }
  ]
end

Dir.mktmpdir('acct-name-match-report') do |dir|
  write_json(dir, 'source-object-census.json', 'objects' => inventory_objects)
  write_json(dir, 'coverage.json', 'unresolved' => [
    # whitespace: each spelling carries its own, different status
    { 'name' => 'X',   'type' => 'worksheet', 'status' => 'migrated' },
    { 'name' => 'X ',  'type' => 'worksheet', 'status' => 'skipped' },
    { 'name' => 'X  ', 'type' => 'worksheet', 'status' => 'needs-review' },
    # case: exact spelling wins over the ambiguous folded pair
    { 'name' => 'rev', 'type' => 'worksheet', 'status' => 'needs-review' },
    { 'name' => 'Rev', 'type' => 'worksheet', 'status' => 'migrated' },
    # chart record (a type naming neither worksheet nor zone) -> the worksheet
    { 'visual' => 'Sales Trend', 'type' => 'chart', 'status' => 'approximated' },
    # no type at all -> the worksheet
    { 'name' => 'Margin', 'status' => 'needs-review' },
    # explicit zone type + id -> that zone
    { 'name' => 'Margin', 'type' => 'dashboard-zone', 'id' => 'dashboard-zone:Overview:2', 'status' => 'migrated' },
    # zone type but two same-named zones and no id: never guessed
    { 'name' => 'Pair', 'type' => 'dashboard-zone', 'status' => 'migrated' }
  ])
  result, = run_report(dir)
  ro = by_id(result)
  puts 'B. exact name before folded name'
  check(ro['worksheet:X']['status'] == 'migrated' &&
        ro['worksheet:X ']['status'] == 'skipped' &&
        ro['worksheet:X  ']['status'] == 'needs-review',
        "X / 'X ' / 'X  ' each get their own record (got " \
        "#{['worksheet:X', 'worksheet:X ', 'worksheet:X  '].map { |k| ro[k] && ro[k]['status'] }.inspect})")
  check(result['source_objects'].select { |o| o['id'].start_with?('worksheet:X') }.length == 3,
        'three trailing-space worksheets are three inventory objects (not duplicates)')
  check(ro['worksheet:Rev#2']['status'] == 'needs-review' && ro['worksheet:Rev#1']['status'] == 'migrated',
        'exact (case-sensitive) spelling resolves a name that folds ambiguous')
  msgs = consistency(result)['message']
  check(!msgs.include?('refers to unknown worksheet X') && !msgs.include?('refers to unknown worksheet rev'),
        'no "refers to unknown" for whitespace/case variants')

  puts 'B. worksheet vs dashboard-zone routing'
  check(ro['worksheet:Sales Trend']['status'] == 'approximated',
        'a chart-typed record routes to the worksheet')
  check(ro['dashboard-zone:Overview:1']['status'] == 'missing',
        'the same-named zone is left to its own evidence (deterministic: worksheet only)')
  check(ro['worksheet:Margin']['status'] == 'needs-review',
        'a typeless record routes to the worksheet')
  check(ro['dashboard-zone:Overview:2']['status'] == 'migrated',
        'an explicit zone id still reaches the zone')
  check(ro['dashboard-zone:Overview:3']['status'] == 'missing' && ro['dashboard-zone:Detail:3']['status'] == 'missing' &&
        ro['worksheet:Pair']['status'] == 'missing',
        'a zone-typed record with no id among two zones is not guessed')
  check(msgs.include?('refers to unknown dashboard-zone Pair'),
        'the unguessable record is surfaced as unknown, not silently dropped')

  # deterministic: same inputs, byte-identical output
  first = File.binread(File.join(dir, 'migration-result.json'))
  run_report(dir)
  check(File.binread(File.join(dir, 'migration-result.json')) == first,
        'report output is byte-deterministic with fold-equal names')
end

# ---------------------------------------------------------------------------
# C2 (report): migrated vs needs-review pairs
# ---------------------------------------------------------------------------
UNPROVEN = 'matching built object exists, but final parity does not prove this source object'
NOT_BUILT = 'no matching built workbook page, element, control, or column was found'

def census_row(id, name, status, detail)
  { 'type' => 'parameter', 'id' => id, 'name' => name, 'status' => status,
    'evidence' => [{ 'artifact' => 'source-object-census', 'detail' => detail }] }
end

Dir.mktmpdir('acct-name-match-pairs') do |dir|
  write_json(dir, 'source-object-census.json', 'objects' => [
    census_row('parameter:P1', 'P1', 'needs-review', UNPROVEN),     # + migrated  -> needs-review
    census_row('parameter:P2', 'P2', 'needs-review', NOT_BUILT),    # + migrated  -> contradictory
    census_row('parameter:P3', 'P3', 'needs-review', UNPROVEN),     # + skipped   -> contradictory
    census_row('parameter:P4', 'P4', 'migrated', 'parity proves P4'), # + skipped -> contradictory
    census_row('parameter:P5', 'P5', 'needs-review', UNPROVEN),     # + migrated + real needs-review -> contradictory
    census_row('parameter:P6', 'P6', 'needs-review', UNPROVEN)      # + migrated + migrated -> needs-review
  ])
  write_json(dir, 'tableau-controls-coverage.json', 'detail' => [
    { 'name' => 'P1', 'type' => 'parameter', 'status' => 'emitted' },
    { 'name' => 'P2', 'type' => 'parameter', 'status' => 'emitted' },
    { 'name' => 'P3', 'type' => 'parameter', 'status' => 'dropped' },
    { 'name' => 'P4', 'type' => 'parameter', 'status' => 'dropped' },
    { 'name' => 'P5', 'type' => 'parameter', 'status' => 'emitted' },
    { 'name' => 'P6', 'type' => 'parameter', 'status' => 'emitted' }
  ])
  write_json(dir, 'coverage.json', 'unresolved' => [
    { 'name' => 'P5', 'type' => 'parameter', 'status' => 'needs-review', 'detail' => 'unwired filter' },
    { 'name' => 'P6', 'type' => 'parameter', 'status' => 'migrated' }
  ])
  result, = run_report(dir)
  ro = by_id(result)
  puts 'C. migrated vs needs-review pairs'
  check(ro['parameter:P1']['status'] == 'needs-review',
        "built-but-unproven needs-review + migrated resolves to needs-review (got #{ro['parameter:P1']['status']})")
  check(ro['parameter:P1']['status_sources'].map { |s| s['status'] }.sort == %w[migrated needs-review],
        'both evidence entries are kept')
  check(ro['parameter:P6']['status'] == 'needs-review',
        'repeated migrated records do not turn the pair into a contradiction')
  check(ro['parameter:P2']['status'] == 'contradictory',
        'census "no matching built object" vs migrated stays contradictory')
  check(ro['parameter:P3']['status'] == 'contradictory',
        'unproven needs-review vs skipped stays contradictory')
  check(ro['parameter:P4']['status'] == 'contradictory',
        'migrated vs skipped stays contradictory')
  check(ro['parameter:P5']['status'] == 'contradictory',
        'a real needs-review beside the unproven one keeps the conflict')
  msg = consistency(result)['message']
  check(consistency(result)['status'] == 'FAIL' &&
        !msg.include?('parameter:p1 has statuses') && !msg.include?('parameter:p6 has statuses') &&
        msg.include?('parameter:p2 has statuses') && msg.include?('parameter:p4 has statuses'),
        "status-consistency flags only the real conflicts (#{msg})")
end

# only the benign pair -> consistency PASSes
Dir.mktmpdir('acct-name-match-benign') do |dir|
  write_json(dir, 'source-object-census.json',
             'objects' => [census_row('parameter:P1', 'P1', 'needs-review', UNPROVEN)])
  write_json(dir, 'tableau-controls-coverage.json',
             'detail' => [{ 'name' => 'P1', 'type' => 'parameter', 'status' => 'emitted' }])
  result, = run_report(dir)
  check(consistency(result)['status'] == 'PASS',
        "a parameter that is built-but-unproven no longer fails status-consistency (#{consistency(result)['message']})")
  check(result['source_objects'].first['status'] == 'needs-review' && result['verdict'] != 'GREEN',
        'and it stays visible (needs-review, never GREEN)')
end

# ---------------------------------------------------------------------------
# C1 (builder): a control no page carries is not reported as emitted
# ---------------------------------------------------------------------------
zone = {
  'id' => '1', 'kind' => 'chart', 'caption' => 'Metric by Partner', 'chart_kind' => 'bar',
  'mark_class' => 'Bar', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
  'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
  'ref_marks' => [], 'rows_shelf' => '[Partner Name]', 'cols_shelf' => '[Metric]',
  'aggregations' => { '[Partner Name]' => 'None', '[Metric]' => 'Sum' },
  'measures' => [{ 'column' => '[Metric]', 'derivation' => 'Sum' }],
  # The chart reads the Type parameter: its control is a measure-picker Switch.
  'calculations' => [{ 'name' => '[Metric]', 'caption' => 'Metric', 'datatype' => 'real', 'role' => 'measure',
                       'class' => 'tableau',
                       'formula' => 'SUM(CASE [Parameters].[Type] WHEN 0 THEN [Net Revenue] WHEN 1 THEN [Cost] END)' }]
}
layout = [{ 'dashboard' => 'Dash', 'is_story' => false, 'zones' => [zone] }]
meta = {
  # Year Parameter is referenced by a calc somewhere (so its scope record starts
  # out "emitted") but no chart formula reads its control and it has no filter
  # targets: the page pass drops it as a dead control. Unused Picker is not
  # referenced at all (already needs-wiring, a not-emitted status).
  'worksheets' => { 'Metric by Partner' => zone,
                    'Other' => { 'calculations' => [{ 'parameter_refs' => ['Year Parameter', 'Type'] }] } },
  'stories' => [], 'shared_filters' => [], 'column_aliases' => {}, 'columns_by_guid' => {},
  'parameters' => [
    { 'caption' => 'Type', 'name' => '[Type]', 'param_domain' => 'list', 'datatype' => 'real',
      'members' => ['0.', '1.'], 'default_value' => '0.' },
    { 'caption' => 'Year Parameter', 'name' => '[Year Parameter]', 'param_domain' => 'list',
      'datatype' => 'integer', 'default_value' => '2016', 'members' => [] },
    { 'caption' => 'Unused Picker', 'name' => '[Unused Picker]', 'param_domain' => 'list',
      'datatype' => 'string', 'default_value' => 'A', 'members' => %w[A B] }
  ]
}
mmap = {
  '(?i)^Net Revenue$'  => { 'id' => 'm-nr',   'name' => 'Net Revenue' },
  '(?i)^Cost$'         => { 'id' => 'm-cost', 'name' => 'Cost' },
  '(?i)^Partner Name$' => { 'id' => 'm-pn',   'name' => 'Partner Name' }
}

Dir.mktmpdir('acct-name-match-builder') do |d|
  File.write(File.join(d, 'layout.json'), JSON.pretty_generate(layout))
  File.write(File.join(d, 'layout-meta.json'), JSON.pretty_generate(meta))
  File.write(File.join(d, 'master-map.json'), JSON.pretty_generate(mmap))
  File.write(File.join(d, 'get-workbook.json'), JSON.pretty_generate('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Metric by Partner' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), "Partner Name,Metric by Partner\nAcme,1\n")
  out = File.join(d, 'chart-specs.json')
  _o, e, st = Open3.capture3(RUBY, BUILD, '--tableau-dir', d,
                             '--layout', File.join(d, 'layout.json'),
                             '--meta', File.join(d, 'layout-meta.json'),
                             '--master-map', File.join(d, 'master-map.json'),
                             '--master-element-id', 'master',
                             '--skip-dashboard-read', 'unit-test', '--title', 'Dash',
                             '--page-per-dashboard', '--out', out)
  puts 'C. builder reports the real control outcome'
  check(st.success?, "build-charts exits 0 (got #{st.exitstatus}: #{e.lines.first})")
  raw = JSON.parse(File.read(out))
  page_controls = (raw['pages'] || []).flat_map { |p| p['elements'] || [] }.select { |el| el['kind'] == 'control' }
  names = page_controls.map { |el| el['name'] }
  check(names.include?('Type') && !names.include?('Year Parameter') && !names.include?('Unused Picker'),
        "page carries the control a chart reads and neither dead one (got #{names.inspect})")
  cov = JSON.parse(File.read(File.join(d, 'layout-controls-coverage.json')))
  rows = cov['detail'].to_h { |r| [r['name'], r] }
  check(rows['Type'] && rows['Type']['status'] == 'emitted',
        "a control a page carries is emitted (got #{rows['Type'].inspect})")
  check(rows['Year Parameter'] && rows['Year Parameter']['status'] == 'dropped-unused',
        "a parameter control no page carries is NOT emitted (got #{rows['Year Parameter'].inspect})")
  check(rows['Year Parameter'] && rows['Year Parameter']['reason'].to_s.include?('dead control'),
        'and carries a reason string')
  check(rows['Unused Picker'] && rows['Unused Picker']['status'] == 'needs-wiring',
        'an already-gated needs-wiring row keeps its own status')
  check(cov['emitted'] == 1 && cov['dropped_unused'] == 1 && cov['needs_wiring'] == 1,
        "summary counts agree (emitted=#{cov['emitted']}, dropped_unused=#{cov['dropped_unused']}, needs_wiring=#{cov['needs_wiring']})")
  check(e.scan('CONTROL COVERAGE').length == 1 && e.include?('1 dropped-unused'),
        'the coverage warning is written once and states the dropped-unused count')
end

# ---------------------------------------------------------------------------
# E: a gap record's `worksheets` list lands on sheets, never on a same-named
#    parameter (live-caught: a "Store Lookup" parameter beside a "Store Lookup"
#    worksheet took the sheet's converter-refused gap and went contradictory)
# ---------------------------------------------------------------------------
puts 'E. gap records keyed by worksheet do not match a same-named parameter'
Dir.mktmpdir('acct-name-collide') do |dir|
  twb = File.join(dir, 'workbook-content.twb')
  File.write(twb, <<~XML)
    <?xml version='1.0' encoding='utf-8'?>
    <workbook>
      <datasources>
        <datasource name='Parameters'>
          <column caption='Store Lookup' datatype='string' name='[Parameter 2]' param-domain-type='any' value='&quot;&quot;' />
        </datasource>
      </datasources>
      <worksheets><worksheet name='Store Lookup' /></worksheets>
      <dashboards><dashboard name='Board'><zones><zone id='1' name='Store Lookup' /></zones></dashboard></dashboards>
    </workbook>
  XML
  layout = write_json(dir, 'dashboard-layout.json', [{ 'dashboard' => 'Board',
                                                      'zones' => [{ 'id' => '1', 'kind' => 'chart', 'caption' => 'Store Lookup' }] }])
  gaps = write_json(dir, 'workbook-content-gaps-report.json', 'detected_features' => [
    { 'name' => 'Converter-refused or unmapped calculated fields', 'status' => 'unhandled', 'count' => 1,
      'worksheets' => ['Store Lookup'] }
  ])
  _o, stderr, status = Open3.capture3(RUBY, CENSUS, '--workdir', dir, '--twb', twb,
                                      '--dashboard-layout', layout, '--gaps', gaps)
  check(status.success?, "census runs (#{stderr})")
  objs = JSON.parse(File.read(File.join(dir, 'source-object-census.json')))['objects']
  gap_on = ->(type) { objs.select { |o| o['type'] == type && o['name'] == 'Store Lookup' }
                          .flat_map { |o| o['evidence'] }.any? { |e| e['artifact'].to_s.include?('gaps-report') } }
  check(gap_on.call('worksheet'), 'the worksheet carries its gap record')
  check(!gap_on.call('parameter'), 'the same-named parameter does NOT inherit the worksheet\'s gap record')
end

if $failures.empty?
  puts 'test-accounting-name-matching: ALL PASS'
else
  puts "test-accounting-name-matching: #{$failures.size} FAILURE(S)"
  $failures.each { |f| puts "  - #{f}" }
  exit 1
end
