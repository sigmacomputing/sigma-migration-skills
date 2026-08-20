#!/usr/bin/env ruby
# test-build-parity-plan.rb — unit test for build-parity-plan.rb (raw-mode helper,
# handoff FIX 1). Offline: reads a synthetic spec via --workbook-spec, never the API.
# Canonical in shared/scripts. Run: ruby scripts/test-build-parity-plan.rb
require 'json'
require 'tmpdir'
require 'rbconfig'

BPP  = File.join(__dir__, 'build-parity-plan.rb')
RUBY = RbConfig.ruby
$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

ELEMENTS = [
  { 'id' => 'el-master', 'kind' => 'table', 'visibleAsSource' => false, 'columns' => [{ 'id' => 'm1', 'name' => 'X' }] },
  { 'id' => 'el-ctl', 'kind' => 'list-control', 'columns' => [{ 'id' => 'c1', 'name' => 'Region' }] },
  { 'id' => 'el-txt', 'kind' => 'text', 'columns' => [] },
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart', 'name' => 'Net Revenue',
    'columns' => [{ 'id' => 'v1', 'name' => 'Net Revenue' }], 'value' => { 'columnId' => 'v1' } },
  { 'id' => 'el-bar', 'kind' => 'bar-chart', 'name' => 'Sales by Region',
    'columns' => [{ 'id' => 'x1', 'name' => 'Region' }, { 'id' => 'y1', 'name' => 'Sales' }, { 'id' => 'h1', 'name' => 'Hidden' }],
    'xAxis' => { 'columnId' => 'x1' }, 'yAxis' => { 'columnIds' => [{ 'columnId' => 'y1' }] } },
].freeze
LAYOUT = "<Page id=\"p1\">#{ELEMENTS.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
SPEC = { 'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
         'elements' => ELEMENTS, 'layout' => LAYOUT }.freeze

Dir.mktmpdir do |d|
  File.write(File.join(d, 'spec.json'), JSON.generate(SPEC))
  out = File.join(d, 'parity-plan.json')
  emit = File.join(d, 'wb-readback.json')
  st = system(RUBY, BPP, '--workbook-id', 'WB', '--workbook-spec', File.join(d, 'spec.json'),
              '--out', out, '--emit-spec', emit, out: File::NULL, err: File::NULL)
  ok('exit 0', st)
  plan = JSON.parse(File.read(out))['charts']
  names = plan.map { |c| c['sigma_element_id'] }.sort
  ok('only the 2 visible charts (master/control/text excluded)', names == %w[el-bar el-kpi])
  bar = plan.find { |c| c['sigma_element_id'] == 'el-bar' }
  ok('plotted channels only (hidden filter h1 excluded)', bar['sigma_columns'].sort == %w[x1 y1])
  kpi = plan.find { |c| c['sigma_element_id'] == 'el-kpi' }
  ok('kpi value column captured', kpi['sigma_columns'] == ['v1'])
  emitted = JSON.parse(File.read(emit))
  ok('emit-spec wrote metadata pages + flat elements', emitted['pages'] == SPEC['pages'] &&
                                                   emitted['elements'] == SPEC['elements'])
end

# zero chartable elements → exit 2
Dir.mktmpdir do |d|
  File.write(File.join(d, 'spec.json'), JSON.generate(
    'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
    'elements' => [{ 'id' => 't', 'kind' => 'text', 'columns' => [] }],
    'layout' => '<Page id="p1"><Element elementId="t"/></Page>'
  ))
  st = system(RUBY, BPP, '--workbook-id', 'WB', '--workbook-spec', File.join(d, 'spec.json'),
              '--out', File.join(d, 'p.json'), out: File::NULL, err: File::NULL)
  ok('zero charts → exit 2', !st && $?.exitstatus == 2)
end

# NESTED document shape (live code-rep API since 2026-08-03/04: GET/POST
# /v2/workbooks/.../spec nests pages/elements/layout under a top-level `document` key).
# The keystone regression this test guards: an envelope-level element read on a
# nested response silently returns [] (exit 2, not a crash) instead of the
# real chart list — and --emit-spec must write the UNWRAPPED document, not a
# double-wrapped {document:{...}} blob, so wb-readback.json stays plain for
# blind_grade.rb / verify-anchors.rb offline mode / record-visual-check.rb.
Dir.mktmpdir do |d|
  nested = { 'workbookId' => 'w1', 'name' => 'N',
             'document' => { 'schemaVersion' => 2, 'kind' => 'workbook',
                             'layout' => SPEC['layout'], 'pages' => SPEC['pages'],
                             'elements' => SPEC['elements'] } }
  File.write(File.join(d, 'nested-spec.json'), JSON.generate(nested))
  out = File.join(d, 'parity-plan.json')
  emit = File.join(d, 'wb-readback.json')
  st = system(RUBY, BPP, '--workbook-id', 'WB', '--workbook-spec', File.join(d, 'nested-spec.json'),
              '--out', out, '--emit-spec', emit, out: File::NULL, err: File::NULL)
  ok('nested document shape: exit 0 (not silently zeroed)', st)
  plan = (JSON.parse(File.read(out))['charts'] rescue [])
  ok('nested document shape: sees the same 2 charts as the flat fixture',
     plan.map { |c| c['sigma_element_id'] }.sort == %w[el-bar el-kpi])
  emitted = JSON.parse(File.read(emit))
  ok('nested document shape: emit-spec is NOT double-wrapped', !emitted.key?('document'))
  ok('nested document shape: emit-spec carries flat elements', emitted['elements'] == SPEC['elements'])
  ok('nested document shape: emit-spec also carries layout/schemaVersion (full document, not just pages)',
     emitted['layout'] == SPEC['layout'] && emitted['schemaVersion'] == 2)
end

puts $fail.zero? ? "\nall build-parity-plan tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
