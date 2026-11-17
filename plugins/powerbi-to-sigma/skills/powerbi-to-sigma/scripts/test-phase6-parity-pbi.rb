#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract tests for strict Power BI parity versus stale Import snapshots.
# Shape-safe stale deltas are diagnostic STALE, never PASS; dimension/type
# mismatches stay DIVERGENT even when refresh is old.

require 'json'
require 'open3'
require 'tmpdir'

SCRIPT = File.join(__dir__, 'phase6-parity-pbi.rb')
fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

def run_case(expected:, actual:, freshness: nil, source_timezone: nil)
  Dir.mktmpdir do |dir|
    plan = {
      'source' => 'powerbi-executequeries',
      'extract' => false,
      'charts' => [{ 'chart' => 'Chart A', 'expected' => expected, 'workbook_id' => 'wb-1' }]
    }
    plan_path = File.join(dir, 'plan.json')
    actuals_path = File.join(dir, 'actuals.json')
    File.write(plan_path, JSON.generate(plan))
    File.write(actuals_path, JSON.generate('Chart A' => actual))
    args = ['ruby', SCRIPT, '--finalize', '--plan', plan_path,
            '--actuals', actuals_path, '--out-dir', dir]
    if freshness
      freshness_path = File.join(dir, 'freshness.json')
      File.write(freshness_path, JSON.generate(freshness))
      args += ['--freshness', freshness_path]
    end
    args += ['--source-timezone', source_timezone] if source_timezone
    out, err, status = Open3.capture3(*args)
    summary = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
    [status.exitstatus, summary, out + err]
  end
end

puts 'strict match'
code, summary, = run_case(expected: [['East', 10]], actual: [['East', 10]])
check(code.zero? && summary['status'] == 'PASS' && summary['charts_pass'] == 1,
      '1/1 strict match is the only PASS path', fails)

puts 'Power BI blank member'
code, summary, = run_case(expected: [[nil, 10]], actual: [['(Blank)', 10]])
check(code.zero? && summary['status'] == 'PASS' && summary['charts_pass'] == 1,
      'DAX null bucket matches Sigma rendered (Blank) bucket', fails)

puts 'Power BI blank member in later dimension'
code, summary, = run_case(expected: [['East', nil, 10]], actual: [['East', '(Blank)', 10]])
check(code.zero? && summary['status'] == 'PASS' && summary['charts_pass'] == 1,
      'DAX null bucket matches Sigma rendered (Blank) in every dimension', fails)

puts 'shape-safe stale value delta'
stale = { 'staleDays' => 82, 'credsSuspect' => true, 'failures' => [{ 'errorCode' => 'refresh' }] }
code, summary, output = run_case(expected: [['East', 10]], actual: [['East', 12]], freshness: stale)
check(code == 2 && summary['status'] == 'STALE' &&
      summary['charts_stale_explained'] == 1 && summary['charts_fail'].zero?,
      'same dimension shape + stale values reports STALE, not PASS', fails)
check(output.include?('refresh PBI before claiming exact parity'),
      'stale result prints the remediation instead of a green claim', fails)

puts 'additional live bucket on stale source'
code, summary, = run_case(
  expected: [['East', 10]],
  actual: [['East', 12], ['West', 3]],
  freshness: stale
)
check(code == 2 && summary['status'] == 'STALE' &&
      summary['classifications']['Chart A'] == 'STALE-EXPLAINED',
      'Sigma-only bucket extension remains shape-safe STALE', fails)

puts 'dimension type/grain mismatch on stale source'
code, summary, = run_case(
  expected: [[2024, 10]],
  actual: [['2024-01-01T00:00:00.000Z', 12]],
  freshness: stale
)
check(code == 2 && summary['status'] == 'FAIL' &&
      summary['charts_stale_explained'].zero? && summary['charts_fail'] == 1,
      'integer Year versus ISO date is DIVERGENT, never stale-explained', fails)
check(summary['fail_names'] == ['Chart A'],
      'shape-divergent chart is named in fail_names', fails)

puts 'Export API UTC date normalized to the report timezone'
code, summary, = run_case(
  expected: [['2025-12-31', 10]],
  actual: [['2026-01-01T00:00:00Z', 10]],
  source_timezone: 'America/Los_Angeles'
)
check(code.zero? && summary['status'] == 'PASS' &&
      summary['source_timezone'] == 'America/Los_Angeles',
      'UTC export timestamp compares at the source report local calendar day', fails)

puts 'single-label IANA timezone'
code, summary, = run_case(
  expected: [['2026-01-01', 10]],
  actual: [['2026-01-01T00:00:00Z', 10]],
  source_timezone: 'UTC'
)
check(code.zero? && summary['status'] == 'PASS' && summary['source_timezone'] == 'UTC',
      'UTC is accepted as an IANA timezone name', fails)

# ---- one clock for "today" + materialization freshness (offline) ----
NY = 'America/New_York'
PINNED_WB = { 'document' => { 'elements' => [
  { 'id' => 'k1', 'name' => 'Sales L28D', 'columns' => [{ 'id' => 'v', 'formula' =>
    'SumIf([m/Sales], [m/Order Date] > DateAdd("day", -28, DateTrunc("day", ConvertTimezone(Now(), "America/New_York"))))' }] },
  { 'id' => 'k2', 'name' => 'Total Sales', 'columns' => [{ 'id' => 'v', 'formula' => 'Sum([m/Sales])' }] }
] } }.freeze
BARE_WB = { 'document' => { 'elements' => [
  { 'id' => 'k1', 'name' => 'Sales L28D', 'columns' => [{ 'id' => 'v', 'formula' =>
    'SumIf([m/Sales], [m/Order Date] > DateAdd("day", -28, Today()))' }] }
] } }.freeze
CLOCK_NY = { 'report_timezone' => NY, 'sigma_org_timezone' => 'UTC', 'warehouse_session_timezone' => 'UTC',
             'data_model' => { 'unpinned' => [] }, 'workbook' => { 'unpinned' => [] } }.freeze
ORACLE_NY = { 'kind' => 'report-clock', 'timezone' => NY }.freeze

def run_clock_case(charts:, actuals:, files: {}, plan_extra: {}, extra_args: [])
  Dir.mktmpdir do |dir|
    plan = { 'source' => 'warehouse-sql-oracle', 'extract' => false, 'charts' => charts }.merge(plan_extra)
    plan_path = File.join(dir, 'plan.json')
    actuals_path = File.join(dir, 'actuals.json')
    File.write(plan_path, JSON.generate(plan))
    File.write(actuals_path, JSON.generate(actuals))
    files.each { |name, doc| File.write(File.join(dir, name), JSON.generate(doc)) }
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, err, status = Open3.capture3('ruby', SCRIPT, '--finalize', '--plan', plan_path, '--actuals', actuals_path,
                                      '--out-dir', dir, *extra_args)
    summary = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
    [status.exitstatus, summary, out + err]
  end
end

today_chart = { 'chart' => 'Sales L28D', 'expected' => [['', 100]], 'workbook_id' => 'wb', 'today_relative' => true }
same_day = { 'expected_as_of' => '2026-11-17T03:00:00Z', 'oracle_clock' => ORACLE_NY }

puts 'today-relative chart on one pinned clock, inside the New York/UTC band'
code, summary, = run_clock_case(charts: [today_chart], actuals: { 'Sales L28D' => [['', 100]] },
                                files: { 'report-clock.json' => CLOCK_NY, 'workbook-spec.json' => PINNED_WB },
                                plan_extra: same_day, extra_args: ['--actuals-as-of', '2026-11-17T03:10:00Z'])
check(code.zero? && summary['status'] == 'PASS' && summary.dig('report_clock', 'report_timezone') == NY &&
      summary.dig('report_clock', 'today_relative_charts') == ['Sales L28D'],
      'pinned Sigma + report-clock oracle PASS and parity-final.json records the report clock', fails)

puts 'bare Today() on a UTC org vs a New York oracle'
code, summary, output = run_clock_case(charts: [today_chart], actuals: { 'Sales L28D' => [['', 100]] },
                                       files: { 'report-clock.json' => CLOCK_NY, 'workbook-spec.json' => BARE_WB },
                                       plan_extra: same_day.merge('expected_as_of' => '2026-11-16T15:00:00Z'),
                                       extra_args: ['--actuals-as-of', '2026-11-16T15:05:00Z'])
check(code == 2 && summary['status'] == 'CLOCK-SKEW' && summary['classifications']['Sales L28D'] == 'CLOCK-SKEW',
      'values that agree by luck at 15:00Z are still REFUSED: two clocks', fails)
check(output.include?('two clocks') && summary.dig('report_clock', 'sigma_clock') == 'UTC',
      'the refusal names both clocks', fails)

puts 'oracle and actuals straddle report-timezone midnight'
code, summary, = run_clock_case(charts: [today_chart], actuals: { 'Sales L28D' => [['', 100]] },
                                files: { 'report-clock.json' => CLOCK_NY, 'workbook-spec.json' => PINNED_WB },
                                plan_extra: same_day.merge('expected_as_of' => '2026-11-17T04:58:00Z'),
                                extra_args: ['--actuals-as-of', '2026-11-17T05:02:00Z'])
check(code == 2 && summary['status'] == 'CLOCK-SKEW', 'a midnight crossing between the two sides is refused', fails)

puts 'today-relative detected from the built workbook; oracle clock unknown'
plain = { 'chart' => 'Sales L28D', 'expected' => [['', 100]], 'workbook_id' => 'wb' }
code, summary, = run_clock_case(charts: [plain], actuals: { 'Sales L28D' => [['', 100]] },
                                files: { 'report-clock.json' => CLOCK_NY, 'workbook-spec.json' => PINNED_WB },
                                plan_extra: { 'expected_as_of' => '2026-11-16T15:00:00Z' },
                                extra_args: ['--actuals-as-of', '2026-11-16T15:01:00Z'])
check(code == 2 && summary['status'] == 'CLOCK-SKEW' &&
      summary.dig('report_clock', 'today_relative_charts') == ['Sales L28D'],
      'a chart whose Sigma formula reads the clock is today-relative even when the plan does not say so', fails)

puts 'clock-free chart without any clock record (regression)'
code, summary, = run_clock_case(charts: [{ 'chart' => 'Total Sales', 'expected' => [['', 7]], 'workbook_id' => 'wb' }],
                                actuals: { 'Total Sales' => [['', 7]] }, files: { 'workbook-spec.json' => PINNED_WB })
check(code.zero? && summary['status'] == 'PASS', 'a chart that never reads the clock is unaffected', fails)

puts 'materialization freshness gate'
mat_actions = [{ 'elementId' => 'e1', 'elementName' => 'Feed Agg', 'status' => 'created' }]
total = [{ 'chart' => 'Total Sales', 'expected' => [['', 7]], 'workbook_id' => 'wb' }]
code, summary, output = run_clock_case(charts: total, actuals: { 'Total Sales' => [['', 7]] },
                                       files: { 'materialization-actions.json' => mat_actions })
check(code == 2 && summary['status'] == 'STALE-MATERIALIZATION' && output.include?('check-materialization-freshness.rb'),
      'scheduled materializations without a freshness check are refused, with the command to run', fails)
stale_mat = { 'status' => 'STALE', 'checked_at' => '2026-11-16T14:57:00Z',
              'elements' => [{ 'elementName' => 'Feed Agg', 'status' => 'STALE' }] }
code, summary, = run_clock_case(charts: total, actuals: { 'Total Sales' => [['', 7]] },
                                files: { 'materialization-actions.json' => mat_actions,
                                         'materialization-freshness.json' => stale_mat })
check(code == 2 && summary['status'] == 'STALE-MATERIALIZATION' &&
      summary.dig('materialization_freshness', 'status') == 'STALE',
      'a STALE materialization refuses parity even when every value matches', fails)
code, summary, = run_clock_case(charts: total, actuals: { 'Total Sales' => [['', 7]] },
                                files: { 'materialization-actions.json' => mat_actions,
                                         'materialization-freshness.json' => stale_mat.merge('status' => 'FRESH') },
                                plan_extra: { 'expected_as_of' => '2026-11-16T15:00:00Z' },
                                extra_args: ['--actuals-as-of', '2026-11-16T15:05:00Z'])
check(code.zero? && summary['status'] == 'PASS', 'FRESH materializations let parity pass', fails)

puts '--local-sql carries the oracle clock from build-oracle-sql output'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'expected.json'), JSON.generate('Sales L28D' => [['', 100]], 'Report Day' => [['', '2026-11-16']]))
  File.write(File.join(dir, 'oracle.json'), JSON.generate(
    '_clock' => ORACLE_NY,
    '_charts' => { 'Sales L28D' => { 'supported' => true, 'today_relative' => true, 'sql' => 'SELECT 1' },
                   'Report Day' => { 'supported' => true, 'today_relative' => true, 'sql' => 'SELECT CURRENT_DATE' } }
  ))
  _out, _err, st = Open3.capture3('ruby', SCRIPT, '--local-sql', '--expected', File.join(dir, 'expected.json'),
                                  '--oracle-sql', File.join(dir, 'oracle.json'), '--workbook-id', 'wb',
                                  '--expected-as-of', '2026-11-17T03:00:00Z', '--out', File.join(dir, 'plan.json'))
  plan = JSON.parse(File.read(File.join(dir, 'plan.json')))
  by = plan['charts'].to_h { |c| [c['chart'], c] }
  check(st.success? && plan['oracle_clock']['timezone'] == NY && plan['expected_as_of'] == '2026-11-17T03:00:00Z' &&
        by['Sales L28D']['today_relative'] == true,
        'plan records the oracle clock, the as-of time and the today-relative flag', fails)
  check(by['Report Day'].dig('oracle_clock', 'kind') == 'warehouse-session',
        'an oracle statement on the bare warehouse session clock is marked as such', fails)
end

puts 'review fixes'
# 4: an --as-of oracle names its pinned day, not the expected file's mtime
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'expected.json'), JSON.generate('Sales L28D' => [['', 100]]))
  File.write(File.join(dir, 'oracle.json'), JSON.generate(
    '_clock' => ORACLE_NY.merge('as_of' => '2026-11-14T15:00:00Z'),
    '_charts' => { 'Sales L28D' => { 'supported' => true, 'today_relative' => true, 'sql' => 'SELECT 1' } }))
  Open3.capture3('ruby', SCRIPT, '--local-sql', '--expected', File.join(dir, 'expected.json'), '--oracle-sql',
                 File.join(dir, 'oracle.json'), '--workbook-id', 'wb', '--out', File.join(dir, 'plan.json'))
  plan = JSON.parse(File.read(File.join(dir, 'plan.json')))
  check(plan['expected_as_of'] == '2026-11-14T15:00:00Z', 'the oracle as-of pin becomes expected_as_of', fails)
end
code, summary, = run_clock_case(charts: [today_chart], actuals: { 'Sales L28D' => [['', 100]] },
                                files: { 'report-clock.json' => CLOCK_NY, 'workbook-spec.json' => PINNED_WB },
                                plan_extra: { 'oracle_clock' => ORACLE_NY, 'expected_as_of' => '2026-11-14T15:00:00Z' },
                                extra_args: ['--actuals-as-of', '2026-11-16T15:00:00Z'])
check(code == 2 && summary['status'] == 'CLOCK-SKEW', 'an oracle pinned to another report day is refused against live actuals', fails)
# zone-aware scan: a workbook pinned to Los Angeles is not on a New York report clock
LA_WB = { 'document' => { 'elements' => [
  { 'id' => 'k1', 'name' => 'Sales L28D', 'columns' => [{ 'id' => 'v', 'formula' =>
    'SumIf([m/Sales], [m/Order Date] > DateAdd("day", -28, DateTrunc("day", ConvertTimezone(Now(), "America/Los_Angeles"))))' }] }
] } }.freeze
code, summary, = run_clock_case(charts: [today_chart], actuals: { 'Sales L28D' => [['', 100]] },
                                files: { 'report-clock.json' => CLOCK_NY, 'workbook-spec.json' => LA_WB },
                                plan_extra: same_day, extra_args: ['--actuals-as-of', '2026-11-17T03:10:00Z'])
check(code == 2 && summary.dig('report_clock', 'sigma_clock') == 'America/Los_Angeles',
      'a build pinned to another zone is refused (Sigma clock = that zone)', fails)
# nested DM metrics: the chart reads [Metrics/Outer], which reads [Metrics/Inner], which reads the clock
NESTED_DM = { 'pages' => [{ 'elements' => [{ 'id' => 'o', 'name' => 'ORDERS', 'metrics' => [
  { 'name' => 'Outer', 'formula' => '[Metrics/Inner] / Sum([Sales])' },
  { 'name' => 'Inner', 'formula' => 'SumIf([Sales], [Order Date] = DateTrunc("day", ConvertTimezone(Now(), "America/New_York")))' }] }] }] }.freeze
NESTED_WB = { 'document' => { 'elements' => [{ 'id' => 'k', 'name' => 'Share Today',
                                               'columns' => [{ 'id' => 'v', 'formula' => '[Metrics/Outer]' }] }] } }.freeze
code, summary, = run_clock_case(charts: [{ 'chart' => 'Share Today', 'expected' => [['', 1]], 'workbook_id' => 'wb' }],
                                actuals: { 'Share Today' => [['', 1]] },
                                files: { 'report-clock.json' => CLOCK_NY, 'dm-spec.json' => NESTED_DM, 'workbook-spec.json' => NESTED_WB },
                                plan_extra: { 'expected_as_of' => '2026-11-16T15:00:00Z' },
                                extra_args: ['--actuals-as-of', '2026-11-16T15:01:00Z'])
check(summary.dig('report_clock', 'today_relative_charts') == ['Share Today'],
      'a chart reading the clock through two metric hops is today-relative', fails)
# 7: --out-dir is a sub-directory; the gates still find the workdir files beside the plan
Dir.mktmpdir do |work|
  File.write(File.join(work, 'plan.json'), JSON.generate('source' => 'warehouse-sql-oracle', 'charts' => total,
                                                         'expected_as_of' => '2026-11-16T15:00:00Z'))
  File.write(File.join(work, 'actuals.json'), JSON.generate('Total Sales' => [['', 7]]))
  File.write(File.join(work, 'materialization-actions.json'), JSON.generate(mat_actions))
  File.write(File.join(work, 'materialization-freshness.json'), JSON.generate(stale_mat))
  out_dir = File.join(work, 'parity')
  Dir.mkdir(out_dir)
  _o, _e, st = Open3.capture3('ruby', SCRIPT, '--finalize', '--plan', File.join(work, 'plan.json'),
                              '--actuals', File.join(work, 'actuals.json'), '--out-dir', out_dir)
  fin = JSON.parse(File.read(File.join(out_dir, 'parity-final.json')))
  check(st.exitstatus == 2 && fin['status'] == 'STALE-MATERIALIZATION',
        'gates find the migration workdir beside the plan when --out-dir differs', fails)
end
# 11: the freshness-age rule is two-sided and skips NONE; allow_unknown is honored
fresh_late = stale_mat.merge('status' => 'FRESH', 'checked_at' => '2026-11-17T21:00:00Z')
code, summary, = run_clock_case(charts: total, actuals: { 'Total Sales' => [['', 7]] },
                                files: { 'materialization-actions.json' => mat_actions, 'materialization-freshness.json' => fresh_late },
                                plan_extra: { 'expected_as_of' => '2026-11-16T15:00:00Z' },
                                extra_args: ['--actuals-as-of', '2026-11-16T15:05:00Z'])
check(code == 2 && summary['status'] == 'STALE-MATERIALIZATION', 'a check 30 h after the oracle is refused too', fails)
none_old = { 'status' => 'NONE', 'checked_at' => '2026-11-10T00:00:00Z', 'elements' => [] }
code, summary, = run_clock_case(charts: total, actuals: { 'Total Sales' => [['', 7]] },
                                files: { 'materialization-actions.json' => mat_actions, 'materialization-freshness.json' => none_old },
                                plan_extra: { 'expected_as_of' => '2026-11-16T15:00:00Z' })
check(code.zero? && summary['status'] == 'PASS', 'NONE (no schedules) is never refused by age', fails)
unk = { 'status' => 'UNKNOWN', 'checked_at' => '2026-11-16T15:00:00Z', 'allow_unknown' => true,
        'elements' => [{ 'elementName' => 'Calendar', 'status' => 'UNKNOWN' }] }
code, summary, = run_clock_case(charts: total, actuals: { 'Total Sales' => [['', 7]] },
                                files: { 'materialization-actions.json' => mat_actions, 'materialization-freshness.json' => unk },
                                plan_extra: { 'expected_as_of' => '2026-11-16T15:00:00Z' },
                                extra_args: ['--actuals-as-of', '2026-11-16T15:05:00Z'])
check(code.zero? && summary['status'] == 'PASS' && summary.dig('materialization_freshness', 'accepted_unknown') == ['Calendar'],
      'UNKNOWN accepted with --allow-unknown passes, and says which elements were accepted', fails)
code, summary, = run_clock_case(charts: total, actuals: { 'Total Sales' => [['', 7]] },
                                files: { 'materialization-actions.json' => mat_actions,
                                         'materialization-freshness.json' => unk.merge('allow_unknown' => false) },
                                plan_extra: { 'expected_as_of' => '2026-11-16T15:00:00Z' },
                                extra_args: ['--actuals-as-of', '2026-11-16T15:05:00Z'])
check(code == 2 && summary['status'] == 'STALE-MATERIALIZATION', 'UNKNOWN without --allow-unknown is refused', fails)

if fails.empty?
  puts 'ALL PASS'
  exit 0
end

warn "#{fails.size} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
