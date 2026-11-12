#!/usr/bin/env ruby
# frozen_string_literal: true
# test-validate-spec-metrics.rb — BUG 4: validate-spec.rb must accept the
# governed [Metrics/<measure>] reference form (the documented, LIVE-accepted
# way a workbook column references a data-model metric). Previously the prefix
# check false-flagged "Metrics" as an unknown prefix and failed most elements.
# A genuinely unknown prefix must STILL be rejected (the fix widens the allow
# list by exactly one reserved prefix, it does not disable the check).
# Creds-free, network-free, synthetic data only.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'shellwords'

VALIDATE = File.join(__dir__, 'validate-spec.rb')
RUBY = RbConfig.ruby
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def spec_with(formula)
  {
    'name' => 'T',
    'document' => {
      'schemaVersion' => 4,
      'kind' => 'workbook',
      'pages' => [
        { 'id' => 'page-data', 'name' => 'Data' },
        { 'id' => 'page-1', 'name' => 'P' }
      ],
      'elements' => [
        { 'id' => 'master-x', 'kind' => 'table', 'name' => 'X',
          'source' => { 'dataModelId' => 'dm', 'elementId' => 'el', 'kind' => 'data-model' },
          'columns' => [{ 'id' => 'c1', 'name' => 'Region', 'formula' => '[X/Region]' }],
          'visibleAsSource' => false },
        { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Net Revenue',
          'source' => { 'elementId' => 'master-x', 'kind' => 'table' },
          'columns' => [{ 'id' => 'k1', 'name' => 'Net Revenue', 'formula' => formula }],
          'value' => { 'columnId' => 'k1' } }
      ],
      'layout' => '<Page id="page-data"><Element elementId="master-x"/></Page>' \
                  '<Page id="page-1"><Element elementId="kpi1"/></Page>'
    }
  }
end

def run_validate(spec)
  Dir.mktmpdir do |d|
    f = File.join(d, 'spec.json')
    File.write(f, JSON.generate(spec))
    out = `#{RUBY.shellescape} #{VALIDATE.shellescape} --type workbook #{f.shellescape} 2>&1`
    [$?.exitstatus, out]
  end
end

# 1) [Metrics/<measure>] is accepted (exit 0, no unknown-prefix error for Metrics)
code, out = run_validate(spec_with('[Metrics/Net Revenue]'))
ok('[Metrics/Net Revenue] passes validation (exit 0)', code.zero? || (puts("    out: #{out}") && false))
ok('no "Metrics unknown prefix" error is reported', out !~ /"Metrics" unknown/)

# 2) a genuinely unknown prefix is STILL rejected (the check is not disabled)
code2, out2 = run_validate(spec_with('[Bogus/Net Revenue]'))
ok('an unknown prefix [Bogus/...] is still REJECTED (exit non-zero)', !code2.zero?)
ok('the unknown-prefix error names "Bogus"', out2.include?('"Bogus" unknown'))

# 3) a same-source ref [X/Region]... element-id ref still fine (regression guard)
code3, = run_validate(spec_with('[master-x/Region]'))
ok('[master-x/Region] (element-id ref) still passes', code3.zero?)

# 4) donut holeValue.id must not repeat the value.columnId binding.
donut_spec = spec_with('[Metrics/Net Revenue]')
donut = donut_spec.dig('document', 'elements', 1)
donut['kind'] = 'donut-chart'
donut['color'] = { 'columnId' => 'k1' }
donut['holeValue'] = { 'id' => 'k1' }
code4, out4 = run_validate(donut_spec)
ok('donut holeValue matching value.columnId is rejected', !code4.zero?)
ok('the donut silent-drop error names the current value binding', out4.include?('holeValue.id equals value.columnId'))

# 5) The nested-If date guard matches a real If( call, not the tail of SumIf( / CountIf(.
code5, out5 = run_validate(spec_with('SumIf([Region], Year(Today()) = 2026)'))
ok('SumIf over a date function is not a nested-If (exit 0)', code5.zero? || (puts("    out: #{out5}") && false))
code6, out6 = run_validate(spec_with('If(Year([Region]) = 2026, 1, 0)'))
ok('an unguarded If over a date function is still rejected', !code6.zero? && out6.include?('nested-If on date function'))
code7, = run_validate(spec_with('If(IsNull([Region]), 0, Year([Region]))'))
ok('a guarded If over a date function passes', code7.zero?)

# 6) Sigma text bodies accept only #, ## and ### headings (#### -> PUT /contents HTTP 400).
txt_spec = spec_with('[Metrics/Net Revenue]')
txt_spec['document']['elements'] << { 'id' => 'tx1', 'kind' => 'text', 'body' => "#### Too deep\nbody" }
txt_spec['document']['layout'] = txt_spec['document']['layout'].sub(%r{</Page>\z}, '<Element elementId="tx1"/></Page>')
code8, out8 = run_validate(txt_spec)
ok('a #### heading in a text body is rejected', !code8.zero? && out8.include?('heading level'))
ok3 = spec_with('[Metrics/Net Revenue]')
ok3['document']['elements'] << { 'id' => 'tx2', 'kind' => 'text', 'body' => "### Fine\nbody" }
ok3['document']['layout'] = ok3['document']['layout'].sub(%r{</Page>\z}, '<Element elementId="tx2"/></Page>')
code9, = run_validate(ok3)
ok('a ### heading in a text body passes', code9.zero?)

puts($fail.zero? ? "\nall validate-spec metrics tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
