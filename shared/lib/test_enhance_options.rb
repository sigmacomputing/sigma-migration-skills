# frozen_string_literal: true

# Offline tests for the Phase E app-option heuristic.
#
# No Sigma, credentials, workbook, or workdir. The detector output is a plain
# candidate array; EnhanceOptions is deliberately pure so every recommendation
# branch can be pinned here.

require_relative 'enhance_options'

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

def ids(result)
  result['app_options'].map { |o| o['id'] }
end

def option(result, id)
  result['app_options'].find { |o| o['id'] == id }
end

base_candidates = [
  {
    'id' => 'interactivity-selection-region',
    'category' => 'interactivity-recovery',
    'risk' => 'low'
  },
  {
    'id' => 'interactivity-grain-month',
    'category' => 'interactivity-recovery',
    'risk' => 'low'
  },
  {
    'id' => 'interactivity-drill-product',
    'category' => 'interactivity-recovery',
    'risk' => 'medium'
  },
  {
    'id' => 'comparison-kpi-pair',
    'category' => 'comparison-enrichment',
    'risk' => 'low'
  },
  {
    'id' => 'polish-title-revenue',
    'category' => 'fidelity-polish',
    'risk' => 'low'
  }
].freeze

original = Marshal.load(Marshal.dump(base_candidates))

normal = EnhanceOptions.build(
  candidates: base_candidates,
  shared_master_chart_count: 4,
  calc_blob: 'sales dashboard by region and month',
  write_connection_available: false
)

check('interactive option emitted from low-risk recovery candidates',
      ids(normal).include?('option-interactive-dashboard'), ids(normal).inspect)
check('medium-risk recovery is not bundled into the low-risk option',
      option(normal, 'option-interactive-dashboard')['candidate_ids'] ==
        %w[interactivity-selection-region interactivity-grain-month],
      option(normal, 'option-interactive-dashboard').inspect)
check('selection dimension and shared-master evidence is preserved',
      option(normal, 'option-interactive-dashboard')['evidence']
        .include?('1 filterable dimension(s) across 4 chart(s)'),
      option(normal, 'option-interactive-dashboard')['evidence'])
check('KPI option emitted from comparison detector',
      option(normal, 'option-exec-kpi-strip')['candidate_ids'] ==
        ['comparison-kpi-pair'])
check('polish option emitted from low-risk polish detector',
      option(normal, 'option-polish-pack')['candidate_ids'] ==
        ['polish-title-revenue'])
check('largest low-risk bundle is recommended for a reporting dashboard',
      option(normal, 'option-interactive-dashboard')['recommended'])
check('parity-only is always present',
      ids(normal).include?('option-parity-only'))
check('rollup does not mutate detector candidates',
      base_candidates == original)

planning = EnhanceOptions.build(
  candidates: base_candidates,
  shared_master_chart_count: 4,
  calc_blob: 'Forecast assumptions and scenario driver table',
  write_connection_available: false,
  data_profile: {
    'field_names' => ['Period Type', 'Month', 'Line Item', 'Scenario',
                      'Driver', 'Assumption Rate'],
    'member_values' => { 'Period Type' => %w[Actual Forecast] }
  }
)
plan_option = option(planning, 'option-planning-writeback')
check('two or more planning terms emit write-back option',
      !plan_option.nil?, ids(planning).inspect)
check('planning model recommends write-back over patch-count winner',
      plan_option['recommended'])
check('missing write connection is a visible prerequisite',
      plan_option['requires'] == ['SIGMA_WRITE_CONNECTION_ID'],
      plan_option.inspect)
check('planning option routes to the full planning pattern',
      plan_option['manual_refs']
        .include?('sigma-workbooks/reference/workflows/planning-apps.md'))

planning_with_conn = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'budget variance model',
  write_connection_available: true,
  data_profile: {
    'field_names' => ['Period Type', 'Month', 'Line Item', 'Driver'],
    'member_values' => { 'Period Type' => %w[Actual Forecast] }
  }
)
check('configured write connection clears the prerequisite',
      option(planning_with_conn, 'option-planning-writeback')['requires'].empty?)

one_word = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'forecast chart',
  write_connection_available: true
)
check('one planning word alone does not over-classify a dashboard',
      !ids(one_word).include?('option-planning-writeback'), ids(one_word).inspect)

empty = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: '',
  write_connection_available: false
)
check('empty scan emits parity-only and recommends it',
      ids(empty) == ['option-parity-only'] &&
        option(empty, 'option-parity-only')['recommended'],
      empty.inspect)

check('date-trend signal derives from KPI or grain evidence',
      normal.dig('signals', 'has_date_trend') == true)
check('planning vocabulary records exact matched terms',
      planning.dig('signals', 'planning_vocabulary') ==
        %w[forecast assumption driver scenario],
      planning.dig('signals', 'planning_vocabulary').inspect)

# ---------------------------------------------------------------------------
# Archetype fixtures: structural signals + real member values, not keywords.
# ---------------------------------------------------------------------------
allocation = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'workforce allocation and budget plan',
  write_connection_available: true,
  data_profile: {
    'field_names' => ['Employee ID', 'Department', 'Month', 'Current Headcount',
                      'Target Headcount', 'Monthly Budget', 'Loaded Cost']
  }
)
alloc = option(allocation, 'option-allocation-capacity')
check('workforce budget/capacity fixture recommends allocation app',
      alloc && alloc['recommended'], allocation.inspect)
check('allocation option carries budget variance and writeback modules',
      (alloc['modules'] & %w[writeback-grid budget-variance]).size == 2,
      alloc.inspect)
check('allocation readiness detects stable Employee ID',
      allocation.dig('signals', 'stable_key_candidates')
                .any? { |f| f.downcase.include?('employee id') },
      allocation.dig('signals', 'stable_key_candidates').inspect)

approval = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'discount approval policy and reviewer decision',
  write_connection_available: true,
  data_profile: {
    'field_names' => ['Deal ID', 'Approval Status', 'Days Pending',
                      'Approval Tier', 'Discount Pct', 'Rep'],
    'member_values' => {
      'Approval Status' => ['Pending', 'Approved', 'Rejected']
    }
  }
)
approve = option(approval, 'option-approval-workflow')
check('decision states + aging + tier fixture recommends approval workflow',
      approve && approve['recommended'], approval.inspect)
check('approval option proposes lifecycle and audit modules',
      (approve['modules'] & %w[status-lifecycle audit-log]).size == 2,
      approve.inspect)

exception = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'inventory stockout exception risk reorder coverage',
  write_connection_available: true,
  data_profile: {
    'field_names' => ['SKU', 'Exception', 'Coverage Weeks', 'Reorder Point',
                      'On Hand', 'Owner'],
    'member_values' => {
      'Exception' => ['Healthy', 'Stockout Risk', 'Below Reorder Point']
    }
  }
)
except = option(exception, 'option-exception-command-center')
check('risk members + reorder fields fixture recommends exception center',
      except && except['recommended'], exception.inspect)
check('exception option proposes queue, recommendation, and resolution log',
      (except['modules'] &
        %w[exception-queue recommended-action resolution-log]).size == 3,
      except.inspect)

status_only = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'customer status dashboard',
  write_connection_available: true,
  data_profile: {
    'field_names' => ['Customer ID', 'Status', 'Revenue'],
    'member_values' => { 'Status' => ['Active', 'Inactive'] }
  }
)
check('Active/Inactive status alone does not imply approval workflow',
      !ids(status_only).include?('option-approval-workflow'),
      status_only.inspect)

forecast_word_only = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'forecast revenue chart',
  write_connection_available: true,
  data_profile: {
    'field_names' => ['Order Date', 'Region', 'Revenue']
  }
)
check('forecast vocabulary without actual/forecast structure is not planning',
      !ids(forecast_word_only).include?('option-planning-writeback'),
      forecast_word_only.inspect)

hybrid = EnhanceOptions.build(
  candidates: [],
  shared_master_chart_count: 0,
  calc_blob: 'forecast scenario driver approval review',
  write_connection_available: true,
  data_profile: {
    'field_names' => ['Plan Line ID', 'Period Type', 'Month', 'Driver',
                      'Approval Status', 'Days Pending', 'Approval Tier'],
    'member_values' => {
      'Period Type' => %w[Actual Forecast],
      'Approval Status' => %w[Draft Pending Approved Rejected]
    }
  }
)
check('hybrid FP&A fixture qualifies planning and approval',
      (hybrid.dig('signals', 'qualified_archetypes') &
        %w[scenario-planning approval-workflow]).size == 2,
      hybrid.inspect)
plan_hybrid = option(hybrid, 'option-planning-writeback')
check('hybrid planning option exposes approval modules as optional',
      (plan_hybrid['optional_modules'] &
        %w[decision-queue status-lifecycle audit-log]).size == 3,
      plan_hybrid.inspect)

puts($failures.zero? ? "\nOK: enhance option rollup tests passed" :
     "\n#{$failures} FAILURE(S)")
exit($failures.zero? ? 0 : 1)
