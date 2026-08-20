#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for issue #685-C (Executive Dashboard cold-run failure, 2026-08-08).
#
# THE BUG: a generated Custom-SQL window/LOD helper element referenced
# DAYS_TO_SHIP as though it were a physical warehouse column:
#
#   SELECT SHIP_DATE AS SHIP_DATE, AVG(CASE WHEN DATETRUNC('month', SHIP_DATE)
#     = DATETRUNC('month',DATE('12/01/2021')) THEN DAYS_TO_SHIP END)
#     AS DAYS_TO_SHIP_CURRENT_MONTH_AVERAGE
#   FROM WHDB.WHSCHEMA.FIXTURE_ORDERS GROUP BY 1
#
# "Days to Ship" is actually a Tableau CALCULATED field —
# DATEDIFF('day',[Order Date],[Ship Date]) — with NO physical counterpart on
# the landed table. The pre-POST check-sql-idents gate correctly caught this
# (exit 20: "DAYS_TO_SHIP -> no catalog match") BEFORE a wasted live POST —
# that gate is CORRECT and must stay exactly as strict (this test proves it
# still fires on a genuinely bad statement, per "verification gates must fail
# first" — Ruby test-driven, not the live gate itself, but the same
# SqlIdentCheck the live gate calls).
#
# THE FIX: MechanicalSpecs.fix_calc_masquerading_as_physical! runs BEFORE the
# gate/POST and removes the phantom reference at the source — when the
# offending name resolves to a KNOWN Tableau calculated field (from
# calc-fields.json) whose formula is a confidently-translatable simple shape
# (DATEDIFF over fields that ARE physical on the statement's FROM table), it
# substitutes the calc's own SQL translation in place of the bare identifier.
# Anything NOT confidently translatable is left completely alone — the gate
# stays the unweakened backstop for every other case.
#
# Deterministic + offline: hand-built DM + calc-fields fixture matching the
# live run's real shape (Tableau's own "Sample - Superstore" sample data),
# no network / creds.
#
# Usage:  ruby scripts/test-calc-as-physical-guard.rb

require_relative 'mechanical-specs'
require_relative 'lib/sql_ident_check'

fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

STATEMENT = <<~SQL.strip
  SELECT SHIP_DATE AS SHIP_DATE, AVG(CASE WHEN DATETRUNC('month', SHIP_DATE) = DATETRUNC('month',DATE('12/01/2021'))
          THEN DAYS_TO_SHIP
          END) AS DAYS_TO_SHIP_CURRENT_MONTH_AVERAGE FROM WHDB.WHSCHEMA.FIXTURE_ORDERS GROUP BY 1
SQL

CALC_FIELDS = [
  { 'name' => 'Days to Ship', 'formula' => "DATEDIFF('day',[Order Date],[Ship Date])",
    'depends_on' => ['Ship Date', 'Order Date'] }
]

REAL_COLUMNS = { 'FIXTURE_ORDERS' => %w[ORDER_ID ORDER_DATE SHIP_DATE SHIP_MODE] }

def build_model(statement)
  {
    'pages' => [{ 'elements' => [
      { 'id' => 'el-helper', 'kind' => 'table', 'name' => 'ORDERS FIXED SHIP_DATE',
        'source' => { 'connectionId' => 'conn-1', 'kind' => 'sql', 'statement' => statement },
        'columns' => [
          { 'id' => 'c-1', 'name' => 'SHIP_DATE', 'formula' => '[Custom SQL/SHIP_DATE]' },
          { 'id' => 'c-2', 'name' => 'Days to Ship | Current Month Average',
            'formula' => '[Custom SQL/DAYS_TO_SHIP_CURRENT_MONTH_AVERAGE]' }
        ] }
    ] }]
  }
end

puts 'Part A — reproduce the live failure: check-sql-idents (unmodified) rejects the raw statement'
raw_check = SqlIdentCheck.check(STATEMENT, REAL_COLUMNS)
check(!raw_check[:ok], 'the unfixed statement fails the identifier gate (DAYS_TO_SHIP has no catalog match)', fails)
check(raw_check[:unknown].any? { |u| u[:identifier] == 'DAYS_TO_SHIP' },
      "the gate names DAYS_TO_SHIP specifically (got #{raw_check[:unknown].map { |u| u[:identifier] }.inspect})", fails)

puts 'Part B — MechanicalSpecs.fix_calc_masquerading_as_physical! substitutes the calc\'s own SQL translation'
model = build_model(STATEMENT)
result = MechanicalSpecs.fix_calc_masquerading_as_physical!(model, CALC_FIELDS, REAL_COLUMNS)
fixed_stmt = model['pages'][0]['elements'][0]['source']['statement']
check(result[:rewritten] == 1, "exactly one identifier substituted (got #{result[:rewritten]})", fails)
check(!fixed_stmt.include?('DAYS_TO_SHIP') || fixed_stmt.include?('DAYS_TO_SHIP_CURRENT_MONTH_AVERAGE'),
      "the bare DAYS_TO_SHIP physical-column reference is gone (kept only as the OUTPUT alias) " \
      "(got #{fixed_stmt.inspect})", fails)
check(fixed_stmt.include?("DATEDIFF('day', ORDER_DATE, SHIP_DATE)"),
      "the calc's own DATEDIFF formula is inlined against REAL physical columns (got #{fixed_stmt.inspect})", fails)

puts 'Part C — the fixed statement now PASSES the SAME (unweakened) identifier gate'
fixed_check = SqlIdentCheck.check(fixed_stmt, REAL_COLUMNS)
check(fixed_check[:ok], "check-sql-idents passes on the fixed statement (unknown: #{fixed_check[:unknown].inspect})", fails)

puts 'Part D — the gate is NOT weakened: a genuinely-unresolvable identifier still fails'
untranslatable_stmt = 'SELECT SOME_TOTALLY_MADE_UP_COLUMN FROM WHDB.WHSCHEMA.FIXTURE_ORDERS'
still_fails = SqlIdentCheck.check(untranslatable_stmt, REAL_COLUMNS)
check(!still_fails[:ok], 'an unrelated, genuinely-unknown identifier still fails the gate after our fixup exists', fails)

puts 'Part E — a calc formula NOT confidently translatable is left completely alone (never guessed)'
weird_calc = [{ 'name' => 'Weird Calc', 'formula' => 'IF [X] THEN [Y] ELSE [Z] END' }]
weird_stmt = 'SELECT CASE WHEN 1=1 THEN WEIRD_CALC END AS W FROM WHDB.WHSCHEMA.FIXTURE_ORDERS'
weird_model = build_model(weird_stmt)
weird_result = MechanicalSpecs.fix_calc_masquerading_as_physical!(weird_model, weird_calc, REAL_COLUMNS)
check(weird_result[:rewritten].zero?, 'no substitution attempted for a non-DATEDIFF calc shape (refuse, never guess)', fails)
check(weird_model['pages'][0]['elements'][0]['source']['statement'] == weird_stmt,
      'statement left byte-identical when the fixup cannot confidently translate it', fails)
still_fails2 = SqlIdentCheck.check(weird_model['pages'][0]['elements'][0]['source']['statement'], REAL_COLUMNS)
check(!still_fails2[:ok], 'the untranslated phantom reference is still caught by the (unweakened) gate', fails)

puts 'Part F — no real_columns supplied (catalog unknown): no-op, never guesses blind'
noop_model = build_model(STATEMENT)
noop_result = MechanicalSpecs.fix_calc_masquerading_as_physical!(noop_model, CALC_FIELDS, nil)
check(noop_result[:rewritten].zero?, 'without a live catalog, the fixup makes no changes', fails)
check(noop_model['pages'][0]['elements'][0]['source']['statement'] == STATEMENT,
      'statement left untouched absent real_columns', fails)

puts
if fails.empty?
  puts 'ALL PASS'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
