#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for lib/pbi_probe_gate.rb: the glue between `migrate-powerbi.rb --probe-sources`
# and scripts/probe-native-sources.py. The REAL probe script is run in its replay mode
# (--probe-results), so the report shape consumed here is the one the script writes, and the
# sql-output-names it yields is fed to the REAL dm-resolver.
#
# Run: ruby scripts/test-pbi-probe-gate.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/pbi_probe_gate'
require_relative 'lib/pbi_dm_resolver'
require_relative 'lib/pbi_extract_notes'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

PROBE = File.join(__dir__, 'probe-native-sources.py')
PY = ENV['PBI_PY'] || 'python3'

sql_el = lambda do |id, name, sql, cols|
  { 'id' => id, 'name' => name,
    'source' => { 'kind' => 'sql', 'connectionId' => 'conn', 'statement' => sql },
    'columns' => cols.map { |cn, ref| { 'id' => "#{id}-#{cn}", 'name' => cn, 'formula' => "[Custom SQL/#{ref}]" } } }
end

dm = { 'pages' => [{ 'elements' => [
  sql_el.call('el1', 'Orders', 'SELECT ID, IS_ACTIVE, AMT, Region FROM S.ORDERS',
              [['Order Id', 'ID'], ['Is Active', 'IS_ACTIVE'], ['Amount', 'AMT'], ['Region', 'REGION'], ['Ghost', 'GHOST']]),
  sql_el.call('el2', 'Customers', 'SELECT CID FROM S.CUST', [['Cid', 'CID']]),
  { 'id' => 'el3', 'name' => 'Plain', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB S T] },
    'columns' => [{ 'id' => 'p1', 'name' => 'X', 'formula' => '[T/X]' }] }
] }] }
tmsl = { 'model' => { 'tables' => [
  { 'name' => 'Orders', 'columns' => [
    { 'name' => 'Order Id', 'sourceColumn' => 'ID', 'dataType' => 'int64' },
    { 'name' => 'Is Active', 'sourceColumn' => 'IS_ACTIVE', 'dataType' => 'boolean' },
    { 'name' => 'Amount', 'sourceColumn' => 'AMT', 'dataType' => 'decimal' },
    { 'name' => 'Region', 'sourceColumn' => 'REGION', 'dataType' => 'string' },
    { 'name' => 'Ghost', 'sourceColumn' => 'GHOST', 'dataType' => 'string' }] },
  { 'name' => 'Customers', 'columns' => [{ 'name' => 'Cid', 'sourceColumn' => 'CID', 'dataType' => 'int64' }] }
] } }

puts "\n1. which elements are probed"
check(PbiProbeGate.sql_elements(dm).map { |e| e['name'] } == %w[Orders Customers], 'only Custom SQL elements with [Custom SQL/X] bindings are probed')
check(PbiProbeGate.sql_elements('pages' => [{ 'elements' => [dm['pages'][0]['elements'][2]] }]).empty?, 'a model with no Custom SQL has nothing to probe')

puts "\n2. dialect mapping"
{ nil => 'snowflake', '' => 'snowflake', 'snowflake' => 'snowflake', 'Databricks' => 'databricks',
  'spark' => 'databricks', 'bigquery' => 'bigquery', 'redshift' => 'snowflake' }.each do |wh, want|
  check(PbiProbeGate.dialect_for(wh) == want, "#{wh.inspect} -> #{want}")
end

puts "\n3. command"
argv = PbiProbeGate.command('probe.py', dm_path: 'dm.json', tmsl_path: 'm.bim', out_path: 'o.json', state_path: 's.json',
                                        connection: 'c1', folder: 'f1', dialect: 'snowflake')
check(argv.each_cons(2).to_a.include?(['--connection-id', 'c1']) && argv.each_cons(2).to_a.include?(['--folder-id', 'f1']) &&
        argv.include?('--state') && !argv.include?('--probe-results'), 'live probe: connection, folder and resumable state')
argv = PbiProbeGate.command('probe.py', dm_path: 'dm.json', tmsl_path: 'm.bim', out_path: 'o.json', state_path: 's.json',
                                        connection: 'c1', folder: 'f1', dialect: 'snowflake', probe_results: 'r.json')
check(argv.include?('--probe-results') && !argv.include?('--connection-id') && !argv.include?('--state'), 'replay: no connection, folder or state')

Dir.mktmpdir('pbi-probe-gate') do |dir|
  w = ->(n, obj) { File.join(dir, n).tap { |p| File.write(p, JSON.pretty_generate(obj)) } }
  dm_path = w.call('dm.json', dm)
  tmsl_path = w.call('m.bim', tmsl)
  qpath = File.join(dir, 'q.json')
  _o, e, st = Open3.capture3(PY, PROBE, '--dm', dm_path, '--tmsl', tmsl_path, '--emit-queries', qpath)
  check(st.success?, "probe script emits the statement keys#{st.success? ? '' : ": #{e}"}")
  keys = JSON.parse(File.read(qpath))
  key = ->(sql) { keys.key(sql) }
  results = {
    key.call('SELECT ID, IS_ACTIVE, AMT, Region FROM S.ORDERS') => {
      'ok' => true, 'columns' => %w[ID IS_ACTIVE AMT Region],
      'types' => { 'ID' => 'NUMBER(38,0)', 'IS_ACTIVE' => 'VARCHAR(16777216)', 'AMT' => 'NUMBER(18,2)', 'Region' => 'VARCHAR(16777216)' }
    },
    key.call('SELECT CID FROM S.CUST') => { 'ok' => true, 'columns' => %w[CID], 'types' => { 'CID' => 'NUMBER(38,0)' } }
  }
  rpath = w.call('res.json', results)
  out = File.join(dir, 'report.json')
  _o, e, st = Open3.capture3(PY, PROBE, '--dm', dm_path, '--tmsl', tmsl_path, '--probe-results', rpath, '--out', out)
  report = JSON.parse(File.read(out))
  check(st.exitstatus == 1 && report['status'] == 'FAIL', 'the real probe script reports FAIL (exit 1) for the missing column')

  puts "\n4. sql-output-names.json (the dm-resolver input)"
  names = PbiProbeGate.sql_output_names(report)
  check(names == { 'Orders' => %w[ID IS_ACTIVE AMT Region], 'Customers' => %w[CID] }, "element name -> SQL output names (got #{names.inspect})")
  failed = { 'elements' => [{ 'name' => 'Broken', 'status' => 'probe-error', 'error' => 'boom' }, report['elements'][0]] }
  check(PbiProbeGate.sql_output_names(failed).keys == ['Orders'], 'an element whose probe failed contributes no names (its refs stay unverified)')
  check(PbiProbeGate.probe_errors(failed) == [{ 'element' => 'Broken', 'error' => 'boom' }], 'probe errors are listed for the run log')

  puts "\n5. the resolver consumes it: unknown [Custom SQL/X] is nulled pre-POST, case-only rewrites to the exact name"
  d2 = JSON.parse(JSON.generate(dm))
  log = PbiDmResolver.resolve!(d2, sql_names: names)
  cols = d2['pages'][0]['elements'][0]['columns'].map { |c| [c['name'], c['formula']] }.to_h
  check(cols['Ghost'] == 'Null', "unknown output GHOST is nulled (got #{cols['Ghost'].inspect})")
  check(cols['Region'] == '[Custom SQL/Region]', "case-only difference (REGION vs Region) is rewritten to the probed name (got #{cols['Region'].inspect})")
  check(cols['Order Id'] == '[Custom SQL/ID]', 'a ref that exists is untouched')
  check(log['nulled'].any? { |n| n['name'] == 'Ghost' && n['unresolved_refs'].to_a.join.include?('GHOST') }, 'the nulled formula and its unresolved ref are recorded in dm-resolver.json')

  puts "\n6. the run STOPS on a bound column missing from the SQL output"
  blocks = PbiProbeGate.blockers(report)
  check(blocks.size == 1 && blocks[0]['element'] == 'Orders' && blocks[0]['column'] == 'Ghost' && blocks[0]['ref'] == 'GHOST' && blocks[0]['status'] == 'missing',
        "one blocker: Orders / Ghost (got #{blocks.inspect})")
  check(PbiProbeGate.blockers(report, allow_missing: true).empty?, '--probe-allow-missing lifts a missing-column blocker')
  amb = { 'elements' => [{ 'name' => 'E', 'bound' => [{ 'column' => 'C', 'ref' => 'a/b', 'status' => 'ambiguous-slash' }] }] }
  check(PbiProbeGate.blockers(amb, allow_missing: true).size == 1, 'an output name still containing "/" blocks even with --probe-allow-missing')
  check(PbiProbeGate.blockers({ 'elements' => [{ 'name' => 'E', 'bound' => [{ 'ref' => 'x', 'status' => 'case-insensitive' }, { 'ref' => 'y', 'status' => 'ok' }] }] }).empty?,
        'case-only and exact matches never block')
  msg = PbiProbeGate.stop_message(blocks, '/w/native-source-probe.json')
  check(msg.include?('Orders / Ghost') && msg.include?('[Custom SQL/GHOST]') && msg.include?('--probe-allow-missing') && msg.include?('/w/native-source-probe.json'),
        'the stop message names the element, column, bound ref, the override and the report')

  puts "\n7. casts for TMSL-vs-warehouse type mismatches are folded into the element SQL"
  d3 = JSON.parse(JSON.generate(dm))
  applied = PbiProbeGate.apply_casts!(d3, report)
  check(applied.size == 1 && applied[0]['element'] == 'Orders' && applied[0]['column'] == 'Is Active' &&
          applied[0]['expression'] == 'TRY_TO_BOOLEAN("IS_ACTIVE")', "VARCHAR -> boolean gets TRY_TO_BOOLEAN (got #{applied.inspect})")
  stmt = d3['pages'][0]['elements'][0]['source']['statement']
  check(stmt.start_with?('SELECT "ID", TRY_TO_BOOLEAN("IS_ACTIVE") AS "IS_ACTIVE", "AMT", "Region" FROM (') && stmt.include?('SELECT ID, IS_ACTIVE, AMT, Region FROM S.ORDERS'),
        "the original SQL is wrapped, output names unchanged (got #{stmt.inspect})")
  check(d3['pages'][0]['elements'][1]['source']['statement'] == 'SELECT CID FROM S.CUST', 'an element with no mismatch keeps its SQL')
  check(PbiProbeGate.apply_casts!(JSON.parse(JSON.generate(dm)), { 'patched_statements' => {} }) == [], 'no casts -> nothing applied')
  line = PbiProbeGate.summary_line(report, applied)
  check(line.include?('2 Custom SQL element(s)') && line.include?('1 missing') && line.include?('1 cast(s) applied'), "summary line (got #{line.inspect})")
end

puts "\n8. refs the resolver can fix (nk match to exactly one output name) do not block"
fx = { 'elements' => [{ 'name' => 'E', 'output_columns' => %w[ORDER_ID AMT AMT_2 REGION],
                        'bound' => [{ 'column' => 'Order Id', 'ref' => 'Order Id', 'status' => 'missing' },
                                    { 'column' => 'Amt', 'ref' => 'Amt!', 'status' => 'missing' },
                                    { 'column' => 'Pct', 'ref' => 'Pct %', 'status' => 'missing' },
                                    { 'column' => 'Ghost', 'ref' => 'GHOST', 'status' => 'missing' }] }] }
bl = PbiProbeGate.blockers(fx)
check(bl.map { |b| b['column'] }.sort == %w[Amt Ghost Pct], "only unfixable refs block (got #{bl.map { |b| b['column'] }.inspect})")
rf = PbiProbeGate.resolver_fixable(fx)
check(rf.size == 1 && rf[0]['column'] == 'Order Id' && rf[0]['status'] == 'resolver-fixable' && rf[0]['fixes_to'] == 'ORDER_ID', "the fixable ref is reported as resolver-fixable (got #{rf.inspect})")
amb2 = { 'elements' => [{ 'name' => 'E', 'output_columns' => %w[A_B AB], 'bound' => [{ 'column' => 'C', 'ref' => 'a b', 'status' => 'missing' }] }] }
check(PbiProbeGate.blockers(amb2).size == 1, 'two nk candidates is not resolver-fixable')

puts "\n8. refs the resolver can fix (nk match to exactly one output name) do not block"
fx = { 'elements' => [{ 'name' => 'E', 'output_columns' => %w[ORDER_ID AMT AMT_2 REGION],
                        'bound' => [{ 'column' => 'Order Id', 'ref' => 'Order Id', 'status' => 'missing' },
                                    { 'column' => 'Amt', 'ref' => 'Amt!', 'status' => 'missing' },
                                    { 'column' => 'Pct', 'ref' => 'Pct %', 'status' => 'missing' },
                                    { 'column' => 'Ghost', 'ref' => 'GHOST', 'status' => 'missing' }] }] }
bl = PbiProbeGate.blockers(fx)
check(bl.map { |b| b['column'] }.sort == %w[Amt Ghost Pct], "only unfixable refs block (got #{bl.map { |b| b['column'] }.inspect})")
rf = PbiProbeGate.resolver_fixable(fx)
check(rf.size == 1 && rf[0]['column'] == 'Order Id' && rf[0]['status'] == 'resolver-fixable' && rf[0]['fixes_to'] == 'ORDER_ID', "the fixable ref is reported as resolver-fixable (got #{rf.inspect})")
amb2 = { 'elements' => [{ 'name' => 'E', 'output_columns' => %w[A_B AB], 'bound' => [{ 'column' => 'C', 'ref' => 'a b', 'status' => 'missing' }] }] }
check(PbiProbeGate.blockers(amb2).size == 1, 'two nk candidates is not resolver-fixable')

puts "\n9. sql-output-names.json staleness (whole-8): per-element statement stamps"
stamps = PbiProbeGate.statement_stamps(dm)
check(stamps.keys.sort == %w[Customers Orders] && stamps.values.all? { |v| v =~ /\A\h{16}\z/ }, "stamps cover each Custom SQL element only (got #{stamps.inspect})")
names = { 'Orders' => %w[ID AMT], 'Customers' => %w[CID], 'Gone' => %w[X] }
kept, dropped = PbiProbeGate.fresh_sql_names(names, stamps, dm)
check(kept == { 'Orders' => %w[ID AMT], 'Customers' => %w[CID] } && dropped == ['Gone'], "an unchanged statement keeps its probed names; an element no longer present is dropped (got #{kept.inspect} / #{dropped.inspect})")
dm2 = JSON.parse(JSON.generate(dm))
dm2['pages'][0]['elements'][0]['source']['statement'] += ', REGION'
kept, dropped = PbiProbeGate.fresh_sql_names(names, stamps, dm2)
check(kept == { 'Customers' => %w[CID] } && dropped.sort == %w[Gone Orders], "a CHANGED statement invalidates only its own names (got #{kept.inspect} / #{dropped.inspect})")
kept, dropped = PbiProbeGate.fresh_sql_names(names, nil, dm2)
check(kept == names && dropped.empty?, 'with no stamp file the names are a hand-supplied input and are honored as before')
kept, dropped = PbiProbeGate.fresh_sql_names(names, stamps.merge('Orders' => 'x' * 16), dm)
check(!kept.key?('Orders'), 'a stamp that does not match drops the element')

puts "\n10. STOP message names the cache escape hatch (pipeline-2 / whole-10)"
msg = PbiProbeGate.stop_message([{ 'element' => 'E', 'column' => 'C', 'ref' => 'C', 'status' => 'missing', 'suggestions' => [] }], 'r.json')
check(msg.include?('--probe-no-cache') && msg.include?('--probe-cache-max-age-hours'), 'the STOP box tells the user how to re-probe after a warehouse fix')

puts "\n11. command() forwards the cache max-age"
argv = PbiProbeGate.command('s.py', dm_path: 'd', tmsl_path: 't', out_path: 'o', state_path: 'st', connection: 'c', folder: 'f', dialect: 'snowflake', cache_max_age_hours: 2)
check(argv.each_cons(2).include?(['--probe-cache-max-age-hours', '2']), 'argv carries --probe-cache-max-age-hours')
argv = PbiProbeGate.command('s.py', dm_path: 'd', tmsl_path: 't', out_path: 'o', state_path: 'st', connection: 'c', folder: 'f', dialect: 'snowflake')
check(!argv.include?('--probe-cache-max-age-hours'), 'the flag is omitted when not given (the script default of 24h applies)')

puts "\n12. dialect_for / ANSI fallback (Enter-data SQL)"
check(PbiProbeGate.dialect_for('snowflake') == 'snowflake' && PbiProbeGate.dialect_for('databricks') == 'databricks' && PbiProbeGate.dialect_for('bigquery') == 'bigquery', 'the three probe dialects are unchanged')
check(PbiProbeGate.dialect_for('postgres') == 'snowflake', 'the PROBE still defaults unknown warehouses to snowflake (it only runs on a Sigma connection)')
check(PbiProbeGate.extract_dialect_for('snowflake') == 'snowflake' && PbiProbeGate.extract_dialect_for('bigquery') == 'bigquery' && PbiProbeGate.extract_dialect_for(nil) == 'snowflake', 'known warehouses and the unset default map as before')
%w[postgres redshift amazon_redshift postgresql].each do |w|
  check(PbiProbeGate.extract_dialect_for(w) == 'ansi', "#{w} Enter-data SQL uses the generic ANSI dialect, not Snowflake")
end
%w[azure_synapse synapse mysql sqlserver oracle].each do |w|
  check(PbiProbeGate.extract_dialect_for(w) == 'unsupported', "#{w}: Enter-data SQL is refused rather than emitted in Snowflake syntax")
end

puts "\n13. extraction notes that mean data was lost are surfaced (whole-5 / whole-11)"
tm = { 'model' => { 'culture' => 'en-US',
                    'annotations' => [{ 'name' => 'SigmaMigration.CultureAssumed', 'value' => 'en-US is assumed' }],
                    'tables' => [
                      { 'name' => 'Targets', 'annotations' => [
                        { 'name' => 'SigmaMigration.ExtractNote1', 'value' => 'Enter-data rows (2) decoded to a SQL SELECT' },
                        { 'name' => 'SigmaMigration.ExtractNote2', 'value' => "Enter data: Date (row 2): '1/15/24' does not fit dateTime; loaded as NULL" }] },
                      { 'name' => 'Other', 'annotations' => [{ 'name' => 'SigmaMigration.ExtractNote1', 'value' => 'Enter-data SQL NOT generated: dialect unsupported' }] },
                      { 'name' => 'Clean' }] } }
notes = PbiExtractNotes.collect(tm)
check(notes.map { |n| [n['where'], n['kind']] } == [%w[model culture-assumed], %w[Targets enter-data], %w[Other enter-data]],
      "only loss notes are collected, informational ones are not (got #{notes.map { |n| n['where'] }.inspect})")
check(PbiExtractNotes.collect(tm['model']).size == 3 && PbiExtractNotes.collect({}).empty? && PbiExtractNotes.collect(nil).empty?, 'a bare model and empty input are tolerated')
check(PbiExtractNotes.lines(notes).all? { |l| l.include?('extract:') } && PbiExtractNotes.lines(notes * 6, 4).last.include?('more'), 'printable lines, capped with a pointer to the file')

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "#{FAILS.size} FAILED:"
  FAILS.each { |x| puts "  - #{x}" }
  exit 1
end
