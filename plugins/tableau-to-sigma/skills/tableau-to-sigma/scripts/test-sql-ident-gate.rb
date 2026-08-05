#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for the pre-POST Custom-SQL identifier GATE (wave-2 §6.5).
#
# The field failure class this locks: an object-model workbook with a
# mis-elected fact bakes helper SQL like
#   SELECT DATE_MONTH, SUM(VISIT_REVENUE) FROM <db>.<schema>.DIM_DATES
# — VISIT_REVENUE does not live on DIM_DATES, so the POST fails with opaque
# "invalid identifier" errors. check-sql-idents.rb caught this whole class
# when run BY HAND, but the orchestrator only PRINTED it as a hint. It is now
# a real gate: fetch/reuse the referenced tables' catalogs, run the check,
# stop (exit 20) on verified unknown identifiers, waive only via
# --skip-sql-ident-gate REASON (recorded on the off-ramp trail).
#
# Part A drives check-sql-idents.rb as a subprocess (the exact class the gate
# runs); Part B pins the orchestrator wiring at source level (same pattern as
# test-rls-wiring.rb Part C — a full migrate-tableau run needs live creds).
require 'json'
require 'tmpdir'

HERE = __dir__
CLI  = File.join(HERE, 'check-sql-idents.rb')
FAILS = []
def check(cond, msg)
  puts((cond ? '  ok  ' : '  FAIL ') + msg)
  FAILS << msg unless cond
end

def dm_spec(statement)
  { 'pages' => [{ 'name' => 'Model', 'elements' => [
    { 'id' => 'el-helper', 'kind' => 'table', 'name' => 'Monthly Revenue Helper',
      'source' => { 'kind' => 'sql', 'statement' => statement },
      'columns' => [] }
  ] }] }
end

DIM_DATES_CATALOG = { 'columns' => [
  { 'name' => 'DATE_KEY' }, { 'name' => 'DATE_MONTH' }, { 'name' => 'DATE_YEAR' }
] }.freeze

def run_cli(spec, catalogs)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'dm-spec.json'), JSON.generate(spec))
    args = ['ruby', CLI, '--dm-spec', File.join(d, 'dm-spec.json')]
    catalogs.each do |t, doc|
      p = File.join(d, "columns-#{t}.json")
      File.write(p, JSON.generate(doc))
      args += ['--columns', "#{t}=#{p}"]
    end
    out = IO.popen(args, err: %i[child out], &:read)
    [$?.exitstatus, out]
  end
end

puts 'Part A — check-sql-idents catches the wrong-FROM class the gate runs against'

# The mis-election signature: a fact measure selected FROM the date dim.
rc, out = run_cli(dm_spec('SELECT DATE_MONTH, SUM(VISIT_REVENUE) AS MONTHLY_REVENUE ' \
                          'FROM ANALYTICS.PUBLIC.DIM_DATES GROUP BY 1'),
                  'DIM_DATES' => DIM_DATES_CATALOG)
check(rc == 1, "wrong-FROM helper SQL (fact measure off the date dim) exits 1 (got #{rc})")
check(out.include?('VISIT_REVENUE'), 'the off-table identifier is named in the fix list')

# Clean statement → exit 0 (no false trip).
rc, = run_cli(dm_spec('SELECT DATE_MONTH FROM ANALYTICS.PUBLIC.DIM_DATES GROUP BY 1'),
              'DIM_DATES' => DIM_DATES_CATALOG)
check(rc == 0, 'clean helper SQL exits 0 — the gate cannot false-trip a correct FROM')

# Spec with no kind:"sql" elements → exit 0 (gate is a no-op, never a stop).
rc, out = run_cli({ 'pages' => [{ 'elements' => [
  { 'id' => 'e1', 'kind' => 'table', 'name' => 'Fact',
    'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB PUBLIC FACT_VISITS] } }
] }] }, {})
check(rc == 0 && out.include?('nothing to preflight'), 'no Custom-SQL elements → exit 0, nothing to preflight')

puts 'Part B — orchestrator gate wiring (source-level pins)'
mig = File.read(File.join(HERE, 'migrate-tableau.rb'), encoding: 'UTF-8')

check(mig.include?('SQL IDENTIFIER GATE (exit 20)') && mig.match?(/^\s*exit 20\s*$/),
      'migrate-tableau STOPS (exit 20) when check-sql-idents finds unknown identifiers')
# The gate sits immediately before the DM POST — slice source from its header
# comment to the post-and-readback call that follows it.
gate_src = mig[/# 🚧 Custom-SQL identifier GATE.*?post-and-readback\.rb/m].to_s
check(!gate_src.empty?, 'the gate block replaces the old printed-hint block (and precedes the DM POST)')
check(gate_src.include?("'check-sql-idents.rb'") && gate_src.include?('--columns'),
      'the gate RUNS check-sql-idents (not just a printed hint)')
check(gate_src.include?("'discover-columns.rb'") && gate_src.include?('cols-'),
      'the gate fetches catalogs inline and reuses Phase-2 cols-<TABLE>.json when present')
check(gate_src.include?("detail: '--skip-sql-ident-gate'") && gate_src.include?('skip-flag-waived'),
      'the waiver leaves a skip-flag-waived off-ramp record (budget-counted like siblings)')
check(gate_src.include?('_si_unfetched') && gate_src.include?('unverified'),
      'an unfetchable catalog DEGRADES to a WARN + hand-run hint — never a false stop')
check(gate_src.include?('--fact-table NAME'),
      'the stop banner routes the wrong-FROM cause to the --fact-table re-election fix')
check(mig.include?("o.on('--skip-sql-ident-gate REASON'"),
      'the --skip-sql-ident-gate REASON flag is declared')
# The stop must fire ONLY on the verified-unknown exit (1) — exit 2 (usage /
# malformed inputs) and fetch failures must not stop the run.
check(gate_src.include?('_si_st.exitstatus == 1'),
      'only check-sql-idents exit 1 (verified unknown identifiers) triggers the stop')

puts(FAILS.empty? ? "\nall sql-ident gate tests passed" : "\n#{FAILS.length} FAILED")
exit(FAILS.empty? ? 0 : 1)
