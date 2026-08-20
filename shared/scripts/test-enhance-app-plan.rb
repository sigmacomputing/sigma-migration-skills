#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline contract tests for enhance-app-plan.rb.

require 'json'
require 'open3'
require 'tmpdir'

SCRIPT = File.expand_path('enhance-app-plan.rb', __dir__)
$failures = 0

def check(label, condition, detail = nil)
  if condition
    puts "[ok] #{label}"
  else
    $failures += 1
    puts "[FAIL] #{label}"
    puts "       #{detail}" if detail
  end
end

OPTIONS = [
  {
    'id' => 'option-planning-writeback',
    'archetype' => 'scenario-planning',
    'score' => 10,
    'confidence' => 'high',
    'evidence_items' => ['Actual and Forecast coexist.'],
    'modules' => %w[scenario-library writeback-grid impact-bridge workbook-agent],
    'optional_modules' => %w[status-lifecycle audit-log],
    'requires' => [],
    'manual_refs' => ['sigma-workbooks/reference/workflows/planning-apps.md']
  },
  {
    'id' => 'option-allocation-capacity',
    'archetype' => 'allocation-capacity',
    'score' => 9,
    'confidence' => 'high',
    'evidence_items' => ['Budget and headcount exist.'],
    'modules' => %w[writeback-grid budget-variance workbook-agent],
    'requires' => [],
    'manual_refs' => ['sigma-workbooks/reference/workflows/allocation-apps.md']
  },
  {
    'id' => 'option-approval-workflow',
    'archetype' => 'approval-workflow',
    'score' => 10,
    'confidence' => 'high',
    'evidence_items' => ['Pending/Approved/Rejected states exist.'],
    'modules' => %w[decision-queue status-lifecycle audit-log workbook-agent],
    'requires' => [],
    'manual_refs' => ['sigma-workbooks/reference/workflows/approval-apps.md']
  },
  {
    'id' => 'option-exception-command-center',
    'archetype' => 'exception-command-center',
    'score' => 8,
    'confidence' => 'medium',
    'evidence_items' => ['Stockout Risk members exist.'],
    'modules' => %w[exception-queue recommended-action resolution-log workbook-agent],
    'requires' => [],
    'manual_refs' => ['sigma-workbooks/reference/workflows/exception-apps.md']
  },
  {
    'id' => 'option-parity-only',
    'label' => 'Parity only',
    'candidate_ids' => []
  }
].freeze

FIXTURE = {
  'workbook_id' => 'wb1',
  'signals' => {
    'stable_key_candidates' => ['Month + Line Item'],
    'qualified_archetypes' => %w[scenario-planning approval-workflow]
  },
  'app_options' => OPTIONS
}.freeze

Dir.mktmpdir do |dir|
  enhancements = File.join(dir, 'enhancements.json')
  File.write(enhancements, JSON.pretty_generate(FIXTURE))

  run = lambda do |id, *extra|
    out = File.join(dir, "#{id}.json")
    stdout, stderr, status = Open3.capture3(
      'ruby', SCRIPT, '--enhancements', enhancements, '--option', id,
      '--out', out, *extra
    )
    [File.exist?(out) ? JSON.parse(File.read(out)) : nil,
     stdout, stderr, status]
  end

  planning, _o, _e, st = run.call('option-planning-writeback')
  check('planning plan exits 0', st.success?, st.exitstatus.to_s)
  check('planning default grain is Scenario x Period x Planning Line',
        planning.dig('grain', 'recommended') ==
          ['Scenario', 'Period', 'Planning Line'],
        planning.dig('grain', 'recommended').inspect)
  check('planning defaults to scenarios + approval',
        planning.dig('userChoices', 'scenarios') &&
          planning.dig('userChoices', 'approval'))
  check('stable key candidates copied from scan',
        planning.dig('grain', 'stableKeyCandidates') ==
          ['Month + Line Item'])
  check('optional approval modules merge into selected plan',
        (planning['modules'] & %w[status-lifecycle audit-log]).size == 2,
        planning['modules'].inspect)
  check('published permission manual step is present',
        planning['manualSteps'].any? { |s| s.include?('Set data entry permission') })
  check('cross-document control ownership guard is present',
        planning['manualSteps'].any? { |s| s.include?('data-model controls') })
  check('default writeMode is append',
        planning['writeMode'] == 'append' &&
          planning.dig('userChoices', 'writeMode') == 'append')
  check('unitOfWork defaults from grain',
        planning['unitOfWork'] == 'Scenario × Period × Planning Line',
        planning['unitOfWork'].inspect)
  check('STOP confirmation manual step is present',
        planning['manualSteps'].any? { |s| s.start_with?('STOP:') })
  check('append ledger manual steps are present',
        planning['manualSteps'].any? { |s| s.include?('is_current') } &&
          planning['manualSteps'].any? { |s| s.include?('CURRENT_') })

  allocation, = run.call('option-allocation-capacity',
                         '--approval', 'no', '--agent', 'analyze',
                         '--write-mode', 'overwrite',
                         '--unit-of-work', 'Period × Team')
  check('allocation override choices persist',
        allocation.dig('userChoices', 'approval') == false &&
          allocation.dig('userChoices', 'agent') == 'analyze')
  check('allocation grain is Period x Allocation Dimension',
        allocation.dig('grain', 'recommended') ==
          ['Period', 'Allocation Dimension'])
  check('write-mode and unit-of-work overrides persist',
        allocation['writeMode'] == 'overwrite' &&
          allocation['unitOfWork'] == 'Period × Team')

  approval, = run.call('option-approval-workflow',
                       '--editable', 'line-values')
  check('approval plan includes one-entity status verification',
        approval['verificationGates']
          .any? { |s| s.include?('another entity is unchanged') })
  check('approval plan includes state-history manual step',
        approval['manualSteps'].any? { |s| s.include?('state-history') })

  exception, = run.call('option-exception-command-center')
  check('prerequisites list only the option\'s own requirements',
        exception['prerequisites'] ==
          exception['prerequisites'].uniq.reject(&:empty?),
        exception['prerequisites'].inspect)
  # Guard: the plan contract offers no bulk row-load choice. Row loading is a
  # build-time decision made against supported Sigma surfaces, not a plan field.
  check('userChoices exposes the architecture choices including writeMode',
        exception['userChoices'].keys.sort ==
          %w[agent approval editable scenarios writeMode],
        exception['userChoices'].keys.inspect)

  # L1-before-agent: write-after-approval without write readiness must fail.
  gap_fixture = FIXTURE.dup
  gap_fixture['app_options'] = OPTIONS.map(&:dup)
  gap_opt = gap_fixture['app_options'].find { |o| o['id'] == 'option-planning-writeback' }
  gap_opt['requires'] = ['a write-enabled connection']
  gap_path = File.join(dir, 'enhancements-gap.json')
  File.write(gap_path, JSON.pretty_generate(gap_fixture))
  _stdout, err, bad = Open3.capture3(
    'ruby', SCRIPT, '--enhancements', gap_path,
    '--option', 'option-planning-writeback',
    '--agent', 'write-after-approval',
    '--out', File.join(dir, 'gap.json')
  )
  check('write-after-approval without L1 readiness fails',
        !bad.success? && err.include?('L1 readiness'), err)

  _p, _o, err, bad = run.call('option-parity-only')
  check('non-archetype option is rejected',
        !bad.success? && err.include?('not an app archetype'), err)

  _p, _o, err, bad = run.call('option-approval-workflow',
                              '--approval', 'maybe')
  check('invalid boolean fails loudly',
        !bad.success? && err.include?('expected yes|no'), err)
end

puts($failures.zero? ? "\nOK: app-plan contract tests passed" :
     "\n#{$failures} FAILURE(S)")
exit($failures.zero? ? 0 : 1)
