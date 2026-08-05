#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-control-lint-gate.rb — proves the gate migrate-cognos.mjs now enforces:
# the vendored scripts/lib/control_lint.rb FAILS when a control does not reach
# every same-page queryable element ("control only filters the table, not the
# KPIs/charts"), and PASSES a correctly-wired spec. Synthetic specs.

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
      { 'id' => 'base', 'kind' => 'table', 'name' => 'Report',
        'columns' => [{ 'id' => 'c_dim', 'formula' => '[Dim]' }] },
      { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Total',
        'source' => { 'kind' => 'source', 'source' => { 'elementId' => 'base' } } },
      { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'dim', 'controlType' => 'list',
        'filters' => [{ 'source' => { 'elementId' => 'base' }, 'columnId' => 'c_dim' }] }
    ]
  }]
}

partial = {
  'pages' => [{
    'name' => 'P1', 'id' => 'pg1',
    'elements' => [
      { 'id' => 'base', 'kind' => 'table', 'name' => 'Report',
        'columns' => [{ 'id' => 'c_dim', 'formula' => '[Dim]' }] },
      { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Total' }, # NOT sourced from base
      { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'dim', 'controlType' => 'list',
        'filters' => [{ 'source' => { 'elementId' => 'base' }, 'columnId' => 'c_dim' }] }
    ]
  }]
}

check(File.exist?(CL), 'control_lint.rb is vendored into cognos scripts/lib')
check(lint(good) == 0, 'correctly-wired control (reaches KPI via source) -> gate PASSES (exit 0)')
check(lint(partial) != 0, 'control that does NOT reach a same-page KPI -> gate FAILS (non-zero)')

mj = File.read(File.join(HERE, 'migrate-cognos.mjs'))
check(mj.include?('control_lint.rb') && mj.include?('gate 7 (control lint)'),
      'migrate-cognos.mjs enforces the control lint as a hard gate (die on non-zero)')

if $fail.zero?
  puts "\ntest-control-lint-gate: ALL PASS"
else
  warn "\ntest-control-lint-gate: #{$fail} FAILURE(S)"
  exit 1
end
