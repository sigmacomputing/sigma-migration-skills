#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-control-lint-gate.rb — proves the gate convert.py (dashboard) now
# enforces: the vendored scripts/lib/control_lint.rb FAILS when a control does
# not reach every same-page queryable element ("control only filters the table,
# not the KPIs/charts"), and PASSES a correctly-wired spec. Synthetic specs.

require 'json'
require 'tmpdir'

HERE = __dir__
CL   = File.join(HERE, 'lib', 'control_lint.rb')

$fail = 0
def check(cond, msg)
  cond ? (puts "  ok  #{msg}") : ($fail += 1; warn "  FAIL #{msg}")
end

def lint(spec)
  Dir.mktmpdir do |d|
    p = File.join(d, 'spec.json')
    File.write(p, JSON.generate(spec))
    system('ruby', CL, p, out: File::NULL, err: File::NULL)
    $?.exitstatus
  end
end

good = {
  'pages' => [{
    'name' => 'P1', 'id' => 'pg1',
    'elements' => [
      { 'id' => 'base', 'kind' => 'table', 'name' => 'Orders',
        'columns' => [{ 'id' => 'c_cat', 'formula' => '[Category]' }] },
      { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Total',
        'source' => { 'kind' => 'source', 'source' => { 'elementId' => 'base' } } },
      { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'cat', 'controlType' => 'list',
        'filters' => [{ 'source' => { 'elementId' => 'base' }, 'columnId' => 'c_cat' }] }
    ]
  }]
}

partial = {
  'pages' => [{
    'name' => 'P1', 'id' => 'pg1',
    'elements' => [
      { 'id' => 'base', 'kind' => 'table', 'name' => 'Orders',
        'columns' => [{ 'id' => 'c_cat', 'formula' => '[Category]' }] },
      { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Total' }, # NOT sourced from base
      { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'cat', 'controlType' => 'list',
        'filters' => [{ 'source' => { 'elementId' => 'base' }, 'columnId' => 'c_cat' }] }
    ]
  }]
}

check(File.exist?(CL), 'control_lint.rb is vendored into sisense scripts/lib')
check(lint(good) == 0, 'correctly-wired control (reaches KPI via source) -> gate PASSES (exit 0)')
check(lint(partial) != 0, 'control that does NOT reach a same-page KPI -> gate FAILS (non-zero)')

cv = File.read(File.join(HERE, 'convert.py'))
check(cv.include?('control_lint.rb') && cv.include?('sys.exit(9)'),
      'convert.py enforces the control lint as a hard gate (exit 9)')

if $fail.zero?
  puts "\ntest-control-lint-gate: ALL PASS"
else
  warn "\ntest-control-lint-gate: #{$fail} FAILURE(S)"
  exit 1
end
