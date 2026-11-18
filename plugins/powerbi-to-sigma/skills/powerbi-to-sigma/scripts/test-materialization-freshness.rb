#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline tests for lib/materialization_freshness.rb and
# check-materialization-freshness.rb (replay mode). Zero network calls.

require 'json'
require 'tmpdir'
require 'stringio'
require_relative 'lib/materialization_freshness'

MF = MaterializationFreshness

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

puts "\n1. table_refs"
r = MF.table_refs('select * from db.sch.tbl t join "My DB"."s"."My Table" m on 1=1')
check.call(r == [%w[DB SCH TBL], ['My DB', 's', 'My Table']], '3-part + quoted identifiers keep case rules')
r = MF.table_refs('select 1 from sch.tbl', default_db: 'DD')
check.call(r == [%w[DD SCH TBL]], '2-part name takes default db')
r = MF.table_refs('select 1 from tbl', default_db: 'DD', default_schema: 'SS')
check.call(r == [%w[DD SS TBL]], '1-part name takes default db+schema')
r = MF.table_refs('select 1 from tbl')
check.call(r == [[nil, nil, 'TBL']], 'incomplete name keeps nil parts for the caller')
r = MF.table_refs('select "n" N from WRITEBACK_DB.WRITEBACK."t_mat_0123456789abcdef0123456789abcdef_0" Q1 limit 1000')
check.call(r == [['WRITEBACK_DB', 'WRITEBACK', 't_mat_0123456789abcdef0123456789abcdef_0']], 'quoted lower-case t_mat table')
r = MF.table_refs('with a as (select * from d.s.base), b (x) as (select 1 from d.s.other) select * from a join b on 1=1')
check.call(r == [%w[D S BASE], %w[D S OTHER]], 'CTE names excluded, CTE bodies scanned')
r = MF.table_refs('select seq4() from table(generator(rowcount => 10)) g, lateral flatten(input => x) f, d.s.t')
check.call(r == [%w[D S T]], 'GENERATOR / TABLE() / LATERAL FLATTEN excluded; comma list continues')
r = MF.table_refs("-- from d.s.commented\nselect 'from d.s.str' x, /* from d.s.block */ 1 from d.s.real")
check.call(r == [%w[D S REAL]], 'comments and string literals ignored')
r = MF.table_refs('select * from (select a from d.s.inner_t) sub join d.s.outer_t o on 1=1, d.s.third')
check.call(r == [%w[D S INNER_T], %w[D S OUTER_T], %w[D S THIRD]], 'subquery alias skipped, JOIN and comma list after subquery')
r = MF.table_refs("select extract(year from d) y, trim(both ' ' from c) from d.s.t where a is distinct from b")
check.call(r == [%w[D S T]], 'EXTRACT/TRIM FROM and IS DISTINCT FROM are not table refs')
r = MF.table_refs('select * from (values (1,2)) v(a,b)')
check.call(r.empty?, 'VALUES excluded')
r = MF.table_refs('select a, b from d.s.t1 where x in (select y from d.s.t2) group by a, b')
check.call(r == [%w[D S T1], %w[D S T2]], 'select/group-by commas are not FROM-list commas')

puts "\n2. materialized_table_in"
sql = 'select "n" N from WRITEBACK_DB.WRITEBACK."t_mat_0123456789abcdef0123456789abcdef_0" Q1 limit 1000'
check.call(MF.materialized_table_in(sql) == ['WRITEBACK_DB', 'WRITEBACK', 't_mat_0123456789abcdef0123456789abcdef_0'],
           'finds the t_mat table')
check.call(MF.materialized_table_in('select * from DB.S.ORDERS').nil?, 'ordinary table is not materialized')
check.call(MF.materialized_table_in('select * from DB.S.T_MAT_0123456789ABCDEF0123456789ABCDEF_0').nil?,
           'unquoted (upper-cased) lookalike does not match')

puts "\n3. upstream_tables"
spec = {
  'pages' => [{ 'elements' => [
    { 'id' => 'wh', 'name' => 'WH', 'kind' => 'table',
      'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB S ORDERS] } },
    { 'id' => 'sq', 'name' => 'SQL', 'kind' => 'table',
      'source' => { 'kind' => 'sql', 'connectionId' => 'c', 'statement' => 'select * from DB.S.A join DB.S.B using (id)' } },
    { 'id' => 'top', 'name' => 'Top', 'kind' => 'table', 'source' => { 'kind' => 'table', 'elementId' => 'mid' } },
    { 'id' => 'mid', 'name' => 'Mid', 'kind' => 'table',
      'source' => { 'kind' => 'join', 'left' => { 'kind' => 'table', 'elementId' => 'wh' },
                    'right' => { 'kind' => 'table', 'elementId' => 'sq' } } },
    { 'id' => 'loose', 'name' => 'Loose', 'kind' => 'table',
      'source' => { 'kind' => 'sql', 'connectionId' => 'c', 'statement' => 'select * from unqualified' } }
  ] }]
}
up = MF.upstream_tables(spec, 'top')
check.call(up[:tables].sort == [%w[DB S A], %w[DB S B], %w[DB S ORDERS]], 'resolves through element-on-element + join to warehouse tables')
check.call(up[:unresolved].empty?, 'no unresolved reasons for a fully qualified chain')
up = MF.upstream_tables(spec, 'loose')
check.call(up[:tables].empty? && up[:unresolved].size == 1, 'unqualified SQL table is reported unresolved')
up = MF.upstream_tables(spec, 'nope')
check.call(up[:unresolved].first.include?('not found'), 'unknown element id reported unresolved')

puts "\n4. evaluate"
mat = ['SW', 'SCH', 't_mat_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0']
mk = ->(name, mt, ups, unres = []) { { elementId: name, elementName: name, sheetId: 's', materialized_table: mt, upstream: ups, unresolved: unres } }
times = {
  'SW.SCH.t_mat_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0' => { 'last_altered' => '2026-11-16T14:55:00Z', 'type' => 'BASE TABLE' },
  'DB.S.OLD' => { 'last_altered' => '2026-11-16T10:00:00Z', 'type' => 'BASE TABLE' },
  'DB.S.NEW' => { 'last_altered' => '2026-11-16T14:56:10Z', 'type' => 'BASE TABLE' },
  'DB.S.VW' => { 'last_altered' => '2026-11-01T00:00:00Z', 'type' => 'VIEW' }
}
res = MF.evaluate(elements: [mk.call('fresh', mat, [%w[DB S OLD]])], table_times: times)
check.call(res['status'] == 'FRESH' && res['elements'][0]['status'] == 'FRESH', 'FRESH when t_mat is newer than upstream')
res = MF.evaluate(elements: [mk.call('stale', mat, [%w[DB S OLD], %w[DB S NEW]])], table_times: times)
e = res['elements'][0]
check.call(res['status'] == 'STALE' && e['status'] == 'STALE', 'STALE when an upstream is 70s newer than the t_mat table')
check.call(e['stale_upstream'].size == 1 && e['stale_upstream'][0]['table'] == 'DB.S.NEW' &&
           e['stale_upstream'][0]['last_altered'] == '2026-11-16T14:56:10Z' &&
           e['materialized_last_altered'] == '2026-11-16T14:55:00Z', 'STALE lists the offending table with both timestamps')
res = MF.evaluate(elements: [mk.call('v', mat, [%w[DB S VW]])], table_times: times)
check.call(res['status'] == 'UNKNOWN', 'UNKNOWN for a VIEW upstream')
res = MF.evaluate(elements: [mk.call('m', mat, [%w[DB S MISSING]])], table_times: times)
check.call(res['status'] == 'UNKNOWN', 'UNKNOWN for a missing upstream table')
res = MF.evaluate(elements: [mk.call('u', mat, [%w[DB S OLD]], ['unqualified'])], table_times: times)
check.call(res['status'] == 'UNKNOWN', 'UNKNOWN when refs are unresolved')
res = MF.evaluate(elements: [mk.call('t', ['SW', 'SCH', 't_mat_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_0'], [%w[DB S OLD]])], table_times: times)
check.call(res['status'] == 'UNKNOWN', 'UNKNOWN when the t_mat table time is missing')
res = MF.evaluate(elements: [mk.call('s', mat, [%w[DB S NEW], %w[DB S VW]])], table_times: times)
check.call(res['status'] == 'STALE', 'a proven STALE wins over UNKNOWN on the same element')
res = MF.evaluate(elements: [mk.call('live', nil, [%w[DB S NEW]])], table_times: times)
check.call(res['elements'][0]['status'] == 'NOT_MATERIALIZED' && res['status'] == 'FRESH', 'NOT_MATERIALIZED element reads live')
res = MF.evaluate(elements: [mk.call('a', mat, [%w[DB S OLD]]), mk.call('b', mat, [%w[DB S VW]])], table_times: times)
check.call(res['status'] == 'UNKNOWN', 'overall UNKNOWN beats FRESH')
res = MF.evaluate(elements: [], table_times: {})
check.call(res['status'] == 'NONE', 'NONE with no scheduled elements')

puts "\n5. information_schema_sql"
sqls = MF.information_schema_sql([%w[DB S A], ["DB", "S", "o'brien"], %w[DB T B], ['SW', 'SCH', 't_mat_cccccccccccccccccccccccccccccccc_0']])
check.call(sqls.keys.sort == %w[DB SW], 'one statement per database')
check.call(sqls['DB'].include?("TABLE_NAME IN ('A', 'o''brien')") && sqls['DB'].include?("TABLE_SCHEMA = 'T'") &&
           sqls['DB'].include?('FROM DB.INFORMATION_SCHEMA.TABLES') && sqls['DB'].include?(' OR '), 'schemas grouped, quotes escaped')
check.call(sqls['SW'].include?("'t_mat_cccccccccccccccccccccccccccccccc_0'"), 't_mat name kept lower-case')
tt = MF.table_times_from_rows([{ 'TABLE_CATALOG' => 'DB', 'TABLE_SCHEMA' => 'S', 'TABLE_NAME' => 'A', 'TABLE_TYPE' => 'VIEW', 'LAST_ALTERED' => 'x' }])
check.call(tt == { 'DB.S.A' => { 'last_altered' => 'x', 'type' => 'VIEW' } }, 'rows map to table_times')

puts "\n6. wait_until_fresh (fake clock, wall-clock deadline)"
now = 1000.0
clock = -> { now }
sleeps = []
sleeper = ->(s) { sleeps << s; now += s }
polls = 0
res = MF.wait_until_fresh(evaluate_once: -> { polls += 1; { 'status' => polls >= 3 ? 'FRESH' : 'STALE' } },
                          deadline_s: 100, poll_s: 10, clock: clock, sleeper: sleeper)
check.call(res['result']['status'] == 'FRESH' && !res['timed_out'] && sleeps.size == 2 && res['waited_s'] == 20.0,
           'stops as soon as FRESH and never sleeps after it')
now = 1000.0
sleeps = []
polls = 0
oversleeper = ->(s) { sleeps << s; now += 500 } # host slept: far longer than the poll interval
res = MF.wait_until_fresh(evaluate_once: -> { polls += 1; { 'status' => 'STALE' } },
                          deadline_s: 100, poll_s: 10, clock: clock, sleeper: oversleeper)
check.call(res['timed_out'] && sleeps.size == 1 && polls == 2, 'oversleep: stops at the wall-clock deadline after one final evaluation')
check.call(res['waited_s'] >= 100, 'waited_s reflects wall-clock time, not sleeps requested')
now = 0.0
sleeps = []
res = MF.wait_until_fresh(evaluate_once: -> { { 'status' => 'UNKNOWN' } }, deadline_s: 25, poll_s: 10, clock: clock, sleeper: sleeper)
check.call(res['timed_out'] && sleeps == [10.0, 10.0, 5.0], 'last sleep is clipped to the remaining time')
now = 0.0
sleeps = []
res = MF.wait_until_fresh(evaluate_once: -> { { 'status' => 'NONE' } }, deadline_s: 25, poll_s: 10, clock: clock, sleeper: sleeper)
check.call(sleeps.empty? && !res['timed_out'], 'NONE returns immediately without sleeping')

puts "\n7. CLI end-to-end via --replay (offline)"
cli_path = File.expand_path('check-materialization-freshness.rb', __dir__)
check.call(File.executable?(cli_path), 'CLI is executable')
MATN = 't_mat_0123456789abcdef0123456789abcdef_0'
fixture = lambda do |mat_time, up_time, extra = {}|
  {
    'schedules' => [{ 'sheetId' => 'sheet1', 'elementId' => 'el1', 'elementName' => 'Orders',
                      'schedule' => { 'cronSpec' => '0 2 * * *' }, 'paused' => false }],
    'dm_spec' => { 'pages' => [{ 'elements' => [{ 'id' => 'el1', 'name' => 'Orders', 'kind' => 'table',
                                                  'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB S ORDERS] },
                                                  'columns' => [{ 'id' => 'c1', 'name' => 'N', 'formula' => '[Orders/N]' }] }] }] },
    'queries' => { 'entries' => [{ 'elementId' => 'pe0', 'name' => 'Orders',
                                   'sql' => %(select "n" N from SW.SCH."#{MATN}" Q1 limit 1000) }] },
    'table_times' => { "SW.SCH.#{MATN}" => { 'last_altered' => mat_time, 'type' => 'BASE TABLE' },
                       'DB.S.ORDERS' => { 'last_altered' => up_time, 'type' => (extra[:type] || 'BASE TABLE') } }
  }.merge(extra.reject { |k, _| k == :type })
end
run_cli = lambda do |fx, extra_args = []|
  Dir.mktmpdir('freshness-test') do |dir|
    fx_path = File.join(dir, 'fixture.json')
    File.write(fx_path, JSON.generate(fx))
    out = StringIO.new
    err = StringIO.new
    argv = ['--replay', fx_path, '--workdir', dir] + extra_args
    argv += ['--poll', '0.01'] unless extra_args.include?('--poll')
    code = load_cli_run(argv, out, err)
    report_path = File.join(dir, 'materialization-freshness.json')
    report = File.exist?(report_path) ? JSON.parse(File.read(report_path)) : nil
    mode = File.exist?(report_path) ? File.stat(report_path).mode & 0o777 : nil
    [code, report, mode, out.string, err.string]
  end
end
def load_cli_run(argv, out, err)
  require File.expand_path('check-materialization-freshness.rb', __dir__)
  FreshnessCLI.run(argv, out: out, err: err)
end

code, report, mode, text, = run_cli.call(fixture.call('2026-11-16T14:56:00Z', '2026-11-16T10:00:00Z'))
check.call(code == 0 && report['status'] == 'FRESH', 'FRESH -> exit 0')
check.call(mode == 0o600, 'report written mode 0600')
check.call(report['data_model_id'] == 'replay' && report['checked_at'] =~ /\A\d{4}-\d\d-\d\dT[\d:]+Z\z/,
           'report carries data_model_id and UTC checked_at')
check.call(report['elements'][0]['materialized_table'] == "SW.SCH.#{MATN}", 'element -> t_mat mapping from compiled query')
check.call(text.include?('FRESH'), 'human summary printed')

code, report, = run_cli.call(fixture.call('2026-11-16T14:55:00Z', '2026-11-16T14:56:10Z'))
check.call(code == 3 && report['status'] == 'STALE' && report['elements'][0]['stale_upstream'][0]['table'] == 'DB.S.ORDERS',
           'STALE (live-case timestamps) -> exit 3')

code, report, = run_cli.call(fixture.call('2026-11-16T14:56:00Z', '2026-11-16T10:00:00Z', type: 'VIEW'))
check.call(code == 4 && report['status'] == 'UNKNOWN', 'UNKNOWN (view upstream) -> exit 4')
code, report, = run_cli.call(fixture.call('2026-11-16T14:56:00Z', '2026-11-16T10:00:00Z', type: 'VIEW'), ['--allow-unknown'])
check.call(code == 0 && report['status'] == 'UNKNOWN', '--allow-unknown -> exit 0')
fx = fixture.call('2026-11-16T14:56:00Z', '2026-11-16T10:00:00Z')
fx['dm_spec']['pages'][0]['elements'][0].delete('columns')
fx['queries']['entries'] = []
code, report, = run_cli.call(fx)
check.call(code == 4 && report['status'] == 'UNKNOWN' &&
           report['elements'][0]['reasons'].any? { |r| r.include?('no compiled query') },
           'an unprobeable scheduled element is UNKNOWN, never treated as live data')

fx = fixture.call('2026-11-16T14:55:00Z', '2026-11-16T14:56:10Z')
fx['schedules'] = []
code, report, = run_cli.call(fx)
check.call(code == 0 && report['status'] == 'NONE', 'no schedules -> NONE, exit 0')

fx = fixture.call('2026-11-16T14:55:00Z', '2026-11-16T14:56:10Z')
fx['table_times_sequence'] = [fx['table_times'], fx['table_times'],
                              { "SW.SCH.#{MATN}" => { 'last_altered' => '2026-11-16T15:00:00Z', 'type' => 'BASE TABLE' },
                                'DB.S.ORDERS' => { 'last_altered' => '2026-11-16T14:56:10Z', 'type' => 'BASE TABLE' } }]
code, report, = run_cli.call(fx, ['--wait', '30', '--poll', '0.01'])
check.call(code == 0 && report['status'] == 'FRESH' && report['timed_out'] == false, '--wait polls until the warehouse shows fresh data')
code, report, = run_cli.call(fixture.call('2026-11-16T14:55:00Z', '2026-11-16T14:56:10Z'), ['--wait', '0.05', '--poll', '0.01'])
check.call(code == 3 && report['timed_out'] == true, '--wait that never freshens times out -> exit 3')
code, report, = run_cli.call(fixture.call('2026-11-16T14:55:00Z', '2026-11-16T14:56:10Z'), ['--rematerialize', '--wait', '0.05', '--poll', '0.01'])
check.call(code == 3 && report['rematerialize'] && report['rematerialize'][0]['result'] == 'replay-skipped',
           '--rematerialize records the refresh attempt (replay does not POST)')
puts "\nreport day: a materialized element that reads the clock is frozen at its run"
day_fixture = lambda do |mat_time|
  fx = fixture.call(mat_time, '2026-11-16T03:00:00Z')
  el = fx['dm_spec']['pages'][0]['elements'][0]
  el['source'] = { 'kind' => 'sql', 'connectionId' => 'c',
                   'statement' => "SELECT COUNT(*) AS N FROM DB.S.ORDERS WHERE D = CAST(CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP()) AS DATE)" }
  fx
end
run_day = lambda do |fx, now|
  Dir.mktmpdir('freshness-day') do |dir|
    File.write(File.join(dir, 'report-clock.json'), JSON.generate('report_timezone' => 'America/New_York'))
    fx_path = File.join(dir, 'fixture.json')
    File.write(fx_path, JSON.generate(fx))
    o = StringIO.new
    e = StringIO.new
    c = FreshnessCLI.run(['--replay', fx_path, '--workdir', dir, '--now', now], out: o, err: e)
    [c, JSON.parse(File.read(File.join(dir, 'materialization-freshness.json')))]
  end
end
code, report = run_day.call(day_fixture.call('2026-11-16T04:00:00Z'), '2026-11-16T15:00:00Z')
check.call(code == 3 && report['status'] == 'STALE' &&
           report['elements'][0]['reasons'].any? { |r| r.include?('report day 2026-11-15') && r.include?('2026-11-16') },
           'run at 23:00 New York on 15 Nov, checked on 16 Nov -> STALE (today moved on)')
check.call(!MF.waitable?(report), 'report-day aging alone is not polled without a rematerialization request')
check.call(MF.waitable?(report, report_day_stale: true), 'report-day aging is polled after requesting rematerialization')
code, report = run_day.call(day_fixture.call('2026-11-16T06:00:00Z'), '2026-11-16T15:00:00Z')
check.call(code.zero? && report['status'] == 'FRESH', 'run on the current report day stays FRESH')
plain = fixture.call('2026-11-16T04:00:00Z', '2026-11-16T03:00:00Z')
code, report = run_day.call(plain, '2026-11-16T15:00:00Z')
check.call(code.zero? && report['status'] == 'FRESH', 'a clock-free element is not aged by the report day')

puts "\nreview fixes"
table_less = lambda do |mat_time|
  fx = fixture.call(mat_time, '2026-11-16T03:00:00Z')
  el = fx['dm_spec']['pages'][0]['elements'][0]
  el['source'] = { 'kind' => 'sql', 'connectionId' => 'c',
                   'statement' => "SELECT CAST(CONVERT_TIMEZONE('America/New_York', CURRENT_TIMESTAMP()) AS DATE) AS \"Value\"" }
  fx['table_times'].delete('DB.S.ORDERS')
  fx
end
code, report = run_day.call(table_less.call('2026-11-16T06:00:00Z'), '2026-11-16T15:00:00Z')
check.call(code.zero? && report['status'] == 'FRESH', "a table-less TODAY() element run today is FRESH, not UNKNOWN (#{report['status']})")
code, report = run_day.call(table_less.call('2026-11-16T04:00:00Z'), '2026-11-16T15:00:00Z')
check.call(code == 3 && report['status'] == 'STALE', 'a table-less TODAY() element run on the previous report day is STALE')
view_clock = day_fixture.call('2026-11-16T04:00:00Z')
view_clock['table_times']['DB.S.ORDERS']['type'] = 'VIEW'
code, report = run_day.call(view_clock, '2026-11-16T15:00:00Z')
check.call(code == 3 && report['status'] == 'STALE', 'report-day aging applies even when an upstream view makes it UNKNOWN')
t0 = Time.now
code, report, = run_cli.call(fixture.call('2026-11-16T14:56:00Z', '2026-11-16T10:00:00Z', type: 'VIEW'), ['--wait', '30', '--poll', '0.01'])
check.call(code == 4 && (Time.now - t0) < 5 && report['waited_s'].nil?, 'UNKNOWN from a view is not waited on (no materialization run can fix it)')
code, report, = run_cli.call(fixture.call('2026-11-16T14:56:00Z', '2026-11-16T10:00:00Z', type: 'VIEW'), ['--allow-unknown'])
check.call(code.zero? && report['allow_unknown'] == true, '--allow-unknown is recorded in the report (finalize honours it)')
missing = fixture.call('2026-11-16T14:56:00Z', '2026-11-16T10:00:00Z')
missing['table_times_sequence'] = [missing['table_times'].reject { |k, _| k.include?('t_mat') }, missing['table_times']]
code, report, = run_cli.call(missing, ['--wait', '30', '--poll', '0.01'])
check.call(code.zero? && report['status'] == 'FRESH', 'a t_mat table not visible yet IS waited on until it lands')
Dir.mktmpdir('freshness-state') do |dir|
  state = File.join(dir, 'probe.state.json')
  File.write(state, JSON.generate('workbookId' => 'wb-orphan', 'created' => true))
  deleted = []
  FreshnessCLI.cleanup_probe_state(state, ->(id) { deleted << id })
  check.call(deleted == ['wb-orphan'] && !File.exist?(state), 'a scratch SQL workbook left in the probe state is deleted and the state removed')
  FreshnessCLI.cleanup_probe_state(state, ->(id) { deleted << id })
  check.call(deleted == ['wb-orphan'], 'no state file -> nothing to delete')
end

src = File.read(File.expand_path('check-materialization-freshness.rb', __dir__))
check.call(src.include?('PyResolve.argv') && !src.match?(/\[\s*'python3'/), 'sigma-sql-probe.py runs via PyResolve (no bare python3)')
check.call(src.include?('--scratch-name'), 'scratch workbook name is configurable')

out = StringIO.new
err = StringIO.new
code = FreshnessCLI.run(['--workdir', '/tmp'], out: out, err: err)
check.call(code == 2 && err.string.include?('--data-model'), 'missing --data-model -> exit 2')
check.call($LOADED_FEATURES.none? { |f| f.end_with?('lib/sigma_rest.rb') }, 'replay path never loaded sigma_rest (no network)')

puts "\n7. probe workbook ids (two scheduled elements)"
# A probe workbook with >= 2 scheduled elements used the element id "p1" for the second element AND for its page
# ("Duplicate id: 'p1'", HTTP 400), so the freshness poll never ran when a model had two materialized elements.
probe = FreshnessCLI::LiveBackend.new(dm: 'dm1')
probe.instance_variable_set(:@dm_spec, 'pages' => [{ 'elements' => %w[el1 el2 el3].map do |id|
  { 'id' => id, 'name' => "N #{id}", 'kind' => 'table', 'columns' => [{ 'id' => 'c1', 'name' => 'C', 'formula' => "[N #{id}/C]" }] }
end }])
contents, pmap = probe.send(:probe_contents, %w[el1 el2 el3].map { |id| { 'elementId' => id } })
ids = contents['elements'].map { |e| e['id'] } + contents['pages'].map { |pg| pg['id'] }
check.call(ids.uniq.length == ids.length, 'probe workbook element and page ids are unique')
check.call(pmap.values == %w[el1 el2 el3] && pmap.keys.length == 3, 'probe ids still map back to the data model elements')

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILED:"
  fails.each { |f| puts "  - #{f}" }
end
exit(fails.empty? ? 0 : 1)
