#!/usr/bin/env ruby
# frozen_string_literal: true
# Tests for the typed-literal calc lint (v5.5 W2.2, lib/typed_literal_lint.rb).
#
# The failure class: converter calcs comparing a NUMBER column to a STRING
# literal (If([Year] = "2014", [Unit Value]) with warehouse YEAR = NUMBER)
# compile clean and render NULL — 2026-07-13 field run blanked 6 of 9 charts.
# The anti-overfit contract under test: the TYPE MAP is the authority, never
# the name (a TEXT column named Year must not flag), and anything the lint
# cannot resolve is skipped silently — false negatives OK, false positives NOT.
#
# Usage:  ruby scripts/test-typed-literal-lint.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/typed_literal_lint'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Spec skeleton: one page, one element with the given columns/metrics/filters.
def spec_with(el_extra)
  el = { 'id' => 'el-1', 'kind' => 'table', 'name' => 'Trade' }.merge(el_extra)
  { 'pages' => [{ 'name' => 'P1', 'elements' => [el] }] }
end

def col_formula_spec(formula)
  spec_with('columns' => [{ 'id' => 'c-1', 'name' => 'Calc', 'formula' => formula }])
end

# --- 1. the field failure: NUMBER column vs "2014" → FLAG ---------------------
types = { 'TRADE_FACTS' => { 'YEAR' => 'number', 'UNIT_VALUE' => 'float' } }
f = TypedLiteralLint.lint(col_formula_spec('If([Year] = "2014", [Unit Value])'), types)
check(f.length == 1, "NUMBER col vs \"2014\" → exactly 1 finding (got #{f.length})", fails)
if f.length == 1
  check(f[0]['literal'] == '2014', "finding carries literal '2014'", fails)
  check(f[0]['column'] == 'TRADE_FACTS.YEAR', "finding names the resolved column (got #{f[0]['column'].inspect})", fails)
  check(f[0]['column_type'] == 'number', 'finding carries the raw map type', fails)
  check(f[0]['suggestion'] == '[Year] = 2014', "suggestion drops the quotes (got #{f[0]['suggestion'].inspect})", fails)
  check(f[0]['formula_owner'] == 'el-1/c-1', "owner is element/column id (got #{f[0]['formula_owner'].inspect})", fails)
end

# --- 2. anti-overfit: TEXT column literally named Year → NO flag --------------
f = TypedLiteralLint.lint(col_formula_spec('If([Year] = "2014", [Unit Value])'),
                          'LOOKUP' => { 'YEAR' => 'text' })
check(f.empty?, "TEXT col named Year vs \"2014\" → no findings (type map beats the name; got #{f.inspect})", fails)

# --- 3. timestamp col vs ["2015"] list filter → FLAG + DatePart suggestion ----
spec = spec_with(
  'columns' => [{ 'id' => 'c-date', 'name' => 'Order Date' }],
  'filters' => [{ 'id' => 'flt-1', 'columnId' => 'c-date', 'kind' => 'list',
                  'mode' => 'include', 'values' => ['2015'] }]
)
f = TypedLiteralLint.lint(spec, 'ORDERS' => { 'ORDER_DATE' => 'timestamp_ntz' })
check(f.length == 1, "TIMESTAMP col vs [\"2015\"] list filter → 1 finding (got #{f.length})", fails)
if f.length == 1
  check(f[0]['suggestion'].include?('DatePart("year", [Order Date])') && f[0]['suggestion'].include?('2015'),
        "temporal suggestion is a DatePart year predicate (got #{f[0]['suggestion'].inspect})", fails)
  check(f[0]['formula_owner'] == 'el-1/filters[flt-1]', 'filter finding owner names the filter', fails)
end

# non-bare-year string list vs timestamp (a real date string) → skip
spec['pages'][0]['elements'][0]['filters'][0]['values'] = ['2015-01-01']
f = TypedLiteralLint.lint(spec, 'ORDERS' => { 'ORDER_DATE' => 'timestamp_ntz' })
check(f.empty?, 'TIMESTAMP col vs ["2015-01-01"] (not a bare year) → no findings (conservative)', fails)

# --- 4. unresolvable ref → skip silently --------------------------------------
f = TypedLiteralLint.lint(col_formula_spec('If([Mystery] = "42", 1, 0)'), types)
check(f.empty?, 'unresolvable ref → skipped silently (no guessing)', fails)

# ambiguous ref: same normalized name, CONFLICTING types across tables → skip
f = TypedLiteralLint.lint(col_formula_spec('If([Year] = "2014", 1, 0)'),
                          'A' => { 'YEAR' => 'number' }, 'B' => { 'YEAR' => 'text' })
check(f.empty?, 'ambiguous ref (conflicting types across tables) → skipped', fails)

# ...but an element whose SOURCE table disambiguates still resolves
spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'el-a', 'kind' => 'table', 'name' => 'A view',
    'source' => { 'kind' => 'table', 'table' => 'DB.SCH.A' },
    'columns' => [{ 'id' => 'c-1', 'formula' => '[Year] = "2014"' }] }
] }] }
f = TypedLiteralLint.lint(spec, 'A' => { 'YEAR' => 'number' }, 'B' => { 'YEAR' => 'text' })
check(f.length == 1, "owner-scoped resolution via source table disambiguates the conflict (got #{f.length})", fails)

# --- 5. numeric col vs NUMERIC literal → no flag ------------------------------
f = TypedLiteralLint.lint(col_formula_spec('If([Year] = 2014, [Unit Value])'), types)
check(f.empty?, 'numeric col vs unquoted 2014 → no findings', fails)

# --- 6. string col vs string literal → no flag --------------------------------
f = TypedLiteralLint.lint(col_formula_spec('If([Region] = "East", 1, 0)'),
                          'T' => { 'REGION' => 'text' })
check(f.empty?, 'TEXT col vs string literal → no findings', fails)
# the classic: a TEXT zip code compared to a numeric-looking string is FINE
f = TypedLiteralLint.lint(col_formula_spec('If([Zip] = "02134", 1, 0)'),
                          'T' => { 'ZIP' => 'varchar(16)' })
check(f.empty?, 'TEXT zip vs "02134" → no findings (numeric-looking strings on text cols are legit)', fails)

# --- 7. caption-normalized resolution -----------------------------------------
f = TypedLiteralLint.lint(col_formula_spec('If([Revenue (current US$)] > "1000", 1, 0)'),
                          'WDI' => { 'REVENUE_CURRENT_US' => 'number' })
check(f.length == 1, "caption 'Revenue (current US$)' resolves against REVENUE_CURRENT_US (got #{f.length})", fails)
check(f.length == 1 && f[0]['suggestion'] == '[Revenue (current US$)] > 1000',
      'caption finding suggests the unquoted comparison', fails)

# --- 8. In-list mixed literals -------------------------------------------------
f = TypedLiteralLint.lint(col_formula_spec('If(In([Year], "2014", "abc"), [Unit Value], 0)'), types)
check(f.length == 1, "In-list mixed literals → only the numeric string flags (got #{f.length})", fails)
check(f.length == 1 && f[0]['literal'] == '2014', 'In-list finding carries the offending literal', fails)
check(f.length == 1 && f[0]['suggestion'].include?('In([Year], 2014'),
      "In-list suggestion unquotes in place (got #{f.length == 1 ? f[0]['suggestion'].inspect : 'n/a'})", fails)

# In over a TEMPORAL ref → DatePart-wrapped suggestion
f = TypedLiteralLint.lint(col_formula_spec('If(In([Ship Date], "2015", "2016"), 1, 0)'),
                          'T' => { 'SHIP_DATE' => 'timestamp' })
check(f.length == 2, "temporal In-list flags each bare-year literal (got #{f.length})", fails)
check(f.length == 2 && f[0]['suggestion'].include?('DatePart("year", [Ship Date])'),
      'temporal In-list suggestion wraps the ref in DatePart', fails)

# In whose first arg is NOT a single bracketed ref → skipped (conservative)
f = TypedLiteralLint.lint(col_formula_spec('If(In(Year([D]), "2014"), 1, 0)'),
                          'T' => { 'YEAR' => 'number', 'D' => 'date' })
check(f.empty?, 'In() with a computed first arg → skipped (tokenizer, not a parser)', fails)

# --- extra hardening -----------------------------------------------------------
# reversed operand order still flags, order preserved in the suggestion
f = TypedLiteralLint.lint(col_formula_spec('If("2014" = [Year], 1, 0)'), types)
check(f.length == 1 && f[0]['suggestion'] == '2014 = [Year]',
      "reversed literal-first comparison flags with order preserved (got #{f.inspect[0, 120]})", fails)

# temporal binary comparison → DatePart suggestion
f = TypedLiteralLint.lint(col_formula_spec('If([Ship Date] = "2015", 1, 0)'),
                          'T' => { 'SHIP_DATE' => 'datetime' })
check(f.length == 1 && f[0]['suggestion'] == 'DatePart("year", [Ship Date]) = 2015',
      'temporal binary comparison suggests DatePart("year", ...) = 2015', fails)

# escaped quotes in an earlier string must not derail a later real site
f = TypedLiteralLint.lint(
  col_formula_spec('If([Label] = "say \"hi\"", 1, If([Year] = "2014", 2, 0))'),
  'T' => { 'LABEL' => 'text', 'YEAR' => 'number' }
)
check(f.length == 1 && f[0]['literal'] == '2014',
      'escaped-quote string literal tokenizes cleanly; later site still flags', fails)

# qualified [Table/Column] ref resolves through the table part
f = TypedLiteralLint.lint(col_formula_spec('If([Master/Year] = "2014", 1, 0)'),
                          'Master' => { 'YEAR' => 'number' })
check(f.length == 1, 'qualified [Master/Year] ref resolves via the table qualifier', fails)

# metrics[] formulas are scanned too
spec = spec_with('metrics' => [{ 'name' => 'Units 2014',
                                 'formula' => 'SumIf([Unit Value], [Year] = "2014")' }])
f = TypedLiteralLint.lint(spec, types)
check(f.length == 1 && f[0]['formula_owner'] == 'el-1/metrics[Units 2014]',
      'metrics[] formulas are scanned', fails)

# numeric list filter: values ["2014","2015"] on a NUMBER col → per-literal
# findings + a coerced-array suggestion
spec = spec_with(
  'columns' => [{ 'id' => 'c-y', 'name' => 'Year' }],
  'filters' => [{ 'id' => 'flt-y', 'columnId' => 'c-y', 'kind' => 'list',
                  'values' => %w[2014 2015] }]
)
f = TypedLiteralLint.lint(spec, 'T' => { 'YEAR' => 'number' })
check(f.length == 2, "numeric string list filter flags each value (got #{f.length})", fails)
check(f.length == 2 && f[0]['suggestion'] == 'values: [2014, 2015]',
      "numeric filter suggestion is the coerced values array (got #{f.length == 2 ? f[0]['suggestion'].inspect : 'n/a'})", fails)

# filter over a COMPUTED column (non-bare-ref formula) → skipped, no guessing
spec = spec_with(
  'columns' => [{ 'id' => 'c-x', 'name' => 'Year Text', 'formula' => 'Text([Year])' }],
  'filters' => [{ 'id' => 'flt-x', 'columnId' => 'c-x', 'kind' => 'list', 'values' => ['2014'] }]
)
f = TypedLiteralLint.lint(spec, 'T' => { 'YEAR' => 'number' })
check(f.empty?, 'filter on a computed column → skipped (output type unknowable from the map)', fails)

# --- CLI: exit codes 0 / 3 / 2 ---------------------------------------------------
ruby = RbConfig.ruby
cli  = File.expand_path('lint-typed-literals.rb', __dir__)
Dir.mktmpdir do |dir|
  spec_p  = File.join(dir, 'dm-spec.json')
  types_p = File.join(dir, 'types.json')
  out_p   = File.join(dir, 'findings.json')
  File.write(spec_p, JSON.generate(col_formula_spec('If([Year] = "2014", [Unit Value])')))
  File.write(types_p, JSON.generate('TRADE_FACTS' => { 'YEAR' => 'number' }))

  # err: File::NULL — the pre-conversion backtick form discarded stderr
  # (2>/dev/null); keep that so the one-line-per-finding count below stays a
  # STDOUT assertion (lint-typed-literals.rb warns a findings summary to
  # stderr on exactly this path — merging would widen the contract and a
  # future stderr line naming the column would break the ==1 pin falsely).
  out = IO.popen([ruby, cli, '--spec', spec_p, '--types', types_p, '--out', out_p], err: File::NULL, &:read)
  check($?.exitstatus == 3, "CLI exits 3 when findings exist (got #{$?.exitstatus})", fails)
  check(out.lines.count { |l| l.include?('TRADE_FACTS.YEAR') } == 1,
        'CLI prints one line per finding', fails)
  written = JSON.parse(File.read(out_p))
  check(written.length == 1 && written[0]['literal'] == '2014', '--out writes the findings JSON', fails)

  File.write(spec_p, JSON.generate(col_formula_spec('If([Year] = 2014, [Unit Value])')))
  IO.popen([ruby, cli, '--spec', spec_p, '--types', types_p], err: %i[child out], &:read)
  check($?.exitstatus.zero?, "CLI exits 0 when clean (got #{$?.exitstatus})", fails)

  IO.popen([ruby, cli, '--spec', spec_p], err: %i[child out], &:read)
  check($?.exitstatus == 2, "CLI exits 2 on missing --types (got #{$?.exitstatus})", fails)
  IO.popen([ruby, cli, '--spec', spec_p, '--types', File.join(dir, 'nope.json')], err: %i[child out], &:read)
  check($?.exitstatus == 2, "CLI exits 2 on unreadable types file (got #{$?.exitstatus})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS — typed-literal lint flags numeric/temporal-vs-string-literal sites, type map is the authority'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
