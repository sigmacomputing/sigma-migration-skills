#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-control-lint-gate.rb — proves the gate build_workbook.py now enforces:
# the vendored scripts/lib/control_lint.rb FAILS (exit non-zero) when a control
# does not reach every same-page queryable element (the "control only filters
# the table, not the KPIs/charts" bug), and PASSES a correctly-wired spec.
# Synthetic specs — no live API, no GoodData inputs needed.

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

# A page with a base table + a KPI sourced from it, and a control that targets
# the base table. Sigma propagates the filter to the KPI -> full reach -> CLEAN.
good = {
  'pages' => [{
    'name' => 'P1', 'id' => 'pg1',
    'elements' => [
      { 'id' => 'base', 'kind' => 'table', 'name' => 'Orders',
        'columns' => [{ 'id' => 'c_region', 'formula' => '[Region]' }] },
      { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Total',
        'source' => { 'kind' => 'source', 'source' => { 'elementId' => 'base' } } },
      { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'region', 'controlType' => 'list',
        'filters' => [{ 'source' => { 'elementId' => 'base' }, 'columnId' => 'c_region' }] }
    ]
  }]
}

# Same page, but the control targets ONLY the base table; the KPI is sourced
# INDEPENDENTLY (not from base) -> the control does NOT reach it -> PARTIAL -> FAIL.
partial = {
  'pages' => [{
    'name' => 'P1', 'id' => 'pg1',
    'elements' => [
      { 'id' => 'base', 'kind' => 'table', 'name' => 'Orders',
        'columns' => [{ 'id' => 'c_region', 'formula' => '[Region]' }] },
      { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Total' }, # NOT sourced from base
      { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'region', 'controlType' => 'list',
        'filters' => [{ 'source' => { 'elementId' => 'base' }, 'columnId' => 'c_region' }] }
    ]
  }]
}

check(File.exist?(CL), 'control_lint.rb is vendored into gooddata scripts/lib')
check(lint(good) == 0, 'correctly-wired control (reaches KPI via source) -> gate PASSES (exit 0)')
check(lint(partial) != 0, 'control that does NOT reach a same-page KPI -> gate FAILS (non-zero)')

bw = File.read(File.join(HERE, 'build_workbook.py'))
check(bw.include?('control_lint.rb') && bw.include?('sys.exit(9)'),
      'build_workbook.py enforces the control lint as a hard gate (exit 9)')

if $fail.zero?
  puts "\ntest-control-lint-gate: ALL PASS"
else
  warn "\ntest-control-lint-gate: #{$fail} FAILURE(S)"
  exit 1
end
