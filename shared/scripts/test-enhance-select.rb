#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-enhance-select.rb — offline contract tests for the Phase E design
# interview: the app_options rollup shape that enhance-scan.rb emits, and the
# selection artifact enhance-select.rb records from a human's answer.
#
# No network, no Sigma, no workdir — a fixture enhancements.json only. Run:
#   ruby shared/scripts/test-enhance-select.rb

require 'json'
require 'tmpdir'
require 'open3'

SELECT = File.expand_path('enhance-select.rb', __dir__)
$failures = 0

def ok(label)
  puts "[ok] #{label}"
end

def bad(label, detail)
  $failures += 1
  puts "[FAIL] #{label}\n       #{detail}"
end

def check(label, cond, detail = '')
  cond ? ok(label) : bad(label, detail)
end

FIXTURE = {
  'schemaVersion' => 1,
  'workbook_id' => 'wb-fixture',
  'candidates' => [
    { 'id' => 'interactivity-selection-region', 'category' => 'interactivity-recovery', 'risk' => 'low' },
    { 'id' => 'interactivity-grain-el1', 'category' => 'interactivity-recovery', 'risk' => 'low' },
    { 'id' => 'interactivity-drill-el2', 'category' => 'interactivity-recovery', 'risk' => 'medium' },
    { 'id' => 'comparison-kpi-pair', 'category' => 'comparison-enrichment', 'risk' => 'low' },
    { 'id' => 'polish-title-el3', 'category' => 'fidelity-polish', 'risk' => 'low' }
  ],
  'app_options' => [
    { 'id' => 'option-interactive-dashboard', 'label' => 'Interactive analysis dashboard',
      'risk' => 'low', 'recommended' => true,
      'candidate_ids' => %w[interactivity-selection-region interactivity-grain-el1 interactivity-drill-el2] },
    { 'id' => 'option-exec-kpi-strip', 'label' => 'Executive KPI summary', 'risk' => 'low',
      'recommended' => false, 'candidate_ids' => %w[comparison-kpi-pair] },
    { 'id' => 'option-planning-writeback', 'label' => 'Driver-based planning app',
      'risk' => 'medium', 'recommended' => false, 'candidate_ids' => [],
      'requires' => ['SIGMA_WRITE_CONNECTION_ID'],
      'manual_refs' => ['sigma-workbooks/reference/specification/input-tables.md'] },
    { 'id' => 'option-parity-only', 'label' => 'Keep the parity dashboard as-is', 'risk' => 'low',
      'recommended' => false, 'candidate_ids' => [] }
  ]
}.freeze

Dir.mktmpdir do |dir|
  scan_path = File.join(dir, 'enhancements.json')
  File.write(scan_path, JSON.pretty_generate(FIXTURE))

  # 1. Medium-risk items inside a chosen option must NOT ride along silently.
  out_path = File.join(dir, 'sel1.json')
  _o, _e, st = Open3.capture3('ruby', SELECT, '--enhancements', scan_path,
                              '--option', 'option-interactive-dashboard', '--out', out_path)
  sel = File.exist?(out_path) ? JSON.parse(File.read(out_path)) : {}
  check('exit 0 on a valid option', st.exitstatus.zero?, "got #{st.exitstatus}")
  check('low-risk ids in the option are accepted',
        sel['accepted_candidate_ids'] == %w[interactivity-selection-region interactivity-grain-el1],
        sel['accepted_candidate_ids'].inspect)
  check('unconfirmed medium-risk id is dropped, not applied',
        sel['dropped_unconfirmed_medium'] == %w[interactivity-drill-el2],
        sel['dropped_unconfirmed_medium'].inspect)

  # 2. An explicitly confirmed medium-risk id is honoured.
  out2 = File.join(dir, 'sel2.json')
  Open3.capture3('ruby', SELECT, '--enhancements', scan_path,
                 '--option', 'option-interactive-dashboard',
                 '--confirm-medium', 'interactivity-drill-el2', '--out', out2)
  sel2 = JSON.parse(File.read(out2))
  check('confirmed medium-risk id is accepted',
        sel2['accepted_candidate_ids'].include?('interactivity-drill-el2'),
        sel2['accepted_candidate_ids'].inspect)
  check('nothing left in the dropped list once confirmed',
        sel2['dropped_unconfirmed_medium'].empty?, sel2['dropped_unconfirmed_medium'].inspect)

  # 3. Declining is a first-class outcome and records an empty accept list.
  out3 = File.join(dir, 'sel3.json')
  Open3.capture3('ruby', SELECT, '--enhancements', scan_path,
                 '--option', 'option-parity-only', '--out', out3)
  sel3 = JSON.parse(File.read(out3))
  check('parity-only accepts nothing', sel3['accepted_candidate_ids'].empty?,
        sel3['accepted_candidate_ids'].inspect)
  check('declined options are recorded for the audit trail',
        sel3['declined_option_ids'].include?('option-interactive-dashboard'),
        sel3['declined_option_ids'].inspect)

  # 4. An option that needs a write connection surfaces as manual follow-up
  #    rather than silently applying nothing.
  out4 = File.join(dir, 'sel4.json')
  Open3.capture3('ruby', SELECT, '--enhancements', scan_path,
                 '--option', 'option-planning-writeback', '--out', out4)
  sel4 = JSON.parse(File.read(out4))
  check('write-back option reports its requirement',
        sel4.dig('manual_followups', 0, 'requires') == ['SIGMA_WRITE_CONNECTION_ID'],
        sel4['manual_followups'].inspect)

  # 5. --also may add a candidate outside the chosen option.
  out5 = File.join(dir, 'sel5.json')
  Open3.capture3('ruby', SELECT, '--enhancements', scan_path,
                 '--option', 'option-exec-kpi-strip', '--also', 'polish-title-el3', '--out', out5)
  sel5 = JSON.parse(File.read(out5))
  check('--also is merged into the accept list',
        sel5['accepted_candidate_ids'].sort == %w[comparison-kpi-pair polish-title-el3],
        sel5['accepted_candidate_ids'].inspect)

  # 6. Bad input fails loudly instead of guessing.
  _o, _e, st_bad = Open3.capture3('ruby', SELECT, '--enhancements', scan_path,
                                  '--option', 'option-does-not-exist')
  check('unknown option id exits non-zero', !st_bad.exitstatus.zero?, "got #{st_bad.exitstatus}")
  _o, _e, st_noopt = Open3.capture3('ruby', SELECT, '--enhancements', scan_path)
  check('missing --option exits non-zero', !st_noopt.exitstatus.zero?, "got #{st_noopt.exitstatus}")

  # 7. A scan predating app_options must fail with a clear instruction.
  legacy = File.join(dir, 'legacy.json')
  File.write(legacy, JSON.pretty_generate(FIXTURE.reject { |k, _| k == 'app_options' }))
  _o, err, st_legacy = Open3.capture3('ruby', SELECT, '--enhancements', legacy, '--option', 'x')
  check('legacy enhancements.json is rejected with guidance',
        !st_legacy.exitstatus.zero? && err.include?('app_options'), err[0, 120])

  # 8. --print-accept emits exactly the CLI value and nothing else.
  acc, _e, _st = Open3.capture3('ruby', SELECT, '--enhancements', scan_path,
                                '--option', 'option-exec-kpi-strip', '--print-accept')
  check('--print-accept prints only the accept value', acc.strip == 'comparison-kpi-pair', acc.inspect)
end

puts($failures.zero? ? "\nOK: enhance-select contract tests passed" : "\n#{$failures} FAILURE(S)")
exit($failures.zero? ? 0 : 1)
