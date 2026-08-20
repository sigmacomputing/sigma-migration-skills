#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for issue #693: the FIXED-LOD/window-helper raw-SQL builder
# (converter/tableau.mjs) reused a hyphenated Tableau caption's physical
# column name UNQUOTED as the emitted `AS <alias>` in the GROUP-BY helper's
# SELECT list — `"Sub-Category" AS SUB-CATEGORY` — which Snowflake rejects
# (`SQL compilation error: syntax error ... unexpected '-'`, the bare hyphen
# parses as a minus operator). The SOURCE identifier ("Sub-Category",
# correctly resolved and quoted) was never the problem; only the ALIAS was
# left bare. scripts/check-sql-idents.rb's pre-POST gate printed a clean
# "OK ... identifiers resolve" for the exact element that then failed
# compilation, because its old scan only ever validated SOURCE identifiers
# against the catalog — it never checked that an emitted alias was itself
# legal SQL.
#
# Two things this pins:
#   Part A/B — the JS fix: converter/tableau.mjs now double-quotes an emitted
#     alias whenever it is not already a safe bare SQL identifier (any
#     punctuation, not just '-' — "Sub-Category", "Ship-Mode" both covered by
#     one fixture; "Year-over-Year" and a plain spaced alias covered in Part
#     D against the shared oracle directly, since they need no new fixture).
#   Part C/D — the Ruby gate fix: scripts/lib/sql_ident_check.rb's `scan`/
#     `check` now detect an `AS <alias>` clause that is NOT a single legal
#     bare/quoted identifier and flag it (independent of any catalog), so
#     this class fails scripts/check-sql-idents.rb locally instead of at a
#     live POST.
#
# Fixture: scripts/test-fixtures/lod-hyphenated-caption.twb — one Snowflake
# table with two HYPHENATED physical columns ("Sub-Category", "Ship-Mode")
# and a two-dim FIXED LOD grouping by both, forcing the converter to emit a
# GROUP-BY Custom SQL helper whose SELECT list aliases each.
#
# Usage: ruby scripts/test-lod-alias-quoting.rb

require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'
require_relative 'lib/sql_ident_check'

HERE = __dir__
VENDORED = File.expand_path('../converter/tableau.mjs', HERE)
FIXTURE  = File.join(HERE, 'test-fixtures', 'lod-hyphenated-caption.twb')

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

abort "vendored converter missing: #{VENDORED}" unless File.exist?(VENDORED)
abort "fixture missing: #{FIXTURE}" unless File.exist?(FIXTURE)

model = nil
Dir.mktmpdir do |dir|
  conv = MechanicalSpecs.run_converter(
    twb_path: FIXTURE, conn: 'conn-test-1', db: 'ANALYTICS', schema: 'SALES',
    mcp_build: VENDORED, workdir: dir)
  model = conv['model']
end

els = (model['pages'] || []).flat_map { |p| p['elements'] || [] }
sql_els = els.select { |e| e.dig('source', 'kind') == 'sql' }
helper = sql_els.find { |e| e['name'].to_s.include?('FIXED') }
win_helper = sql_els.find { |e| e['name'].to_s.include?('Window') }

puts 'Part A — structure: the FIXED-LOD + window Custom SQL helper elements are emitted'
check(!helper.nil?, 'LOD GROUP-BY SQL helper element emitted', fails)
check(!win_helper.nil?, 'window-helper (WINDOW_SUM) SQL helper element emitted', fails)
exit 1 unless fails.empty?

sql = helper.dig('source', 'statement').to_s
puts "  (emitted SQL: #{sql})"

puts 'Part B — #693: hyphenated aliases are double-quoted, not emitted bare'
check(!sql.nil? && !sql.empty?, 'helper SQL statement is non-empty', fails)
# The BUG signature, byte-for-byte from the live failure: an unquoted alias
# carrying the source hyphen straight through. Must never appear.
check(sql !~ /AS\s+SUB-CATEGORY\b/, 'no unquoted `AS SUB-CATEGORY` (the live #693 bug shape)', fails)
check(sql !~ /AS\s+SHIP-MODE\b/, 'no unquoted `AS SHIP-MODE` (sibling hyphenated caption)', fails)
check(sql.include?('AS "SUB-CATEGORY"'),
      "SUB-CATEGORY alias is double-quoted (got: #{sql})", fails)
check(sql.include?('AS "SHIP-MODE"'),
      "SHIP-MODE alias is double-quoted (got: #{sql})", fails)
# The SOURCE side was never the bug — still correctly quoted/resolved.
check(sql.include?('"Sub-Category"') && sql.include?('"Ship-Mode"'),
      'source columns still correctly quoted', fails)
check(sql =~ /GROUP BY 1,\s*2\b/, 'GROUP BY by ordinal (unaffected by the alias fix)', fails)
# The aggregate alias has no special characters (caption has no hyphen) —
# must stay byte-identical bare, proving the fix is CONDITIONAL, not a
# blanket always-quote (would needlessly change already-correct output and
# regress test-lod-sql-quoting.rb's `AS CUSTOMER_REF_ID` pin).
check(sql =~ /SUM\("Deal Value"\) AS SUB_CATEGORY_SHIP_MODE_TOTAL\b/,
      "already-safe aggregate alias stays bare/unquoted (got: #{sql})", fails)

puts 'Part C — #693: the FIXED (quoted) emission passes check-sql-idents clean'
catalog = { 'DEAL_FACTS' => ['Sub-Category', 'Ship-Mode', 'Deal Value'] }
res = SqlIdentCheck.check(sql, catalog)
check(res[:ok], "the actual emitted (fixed) SQL is clean end-to-end (got: #{res[:unknown].inspect})", fails)

puts 'Part D — #693: check-sql-idents REJECTS the unquoted bug shape (gate coverage gap closed)'
# The exact live failure, reconstructed: source resolves fine (quoted
# "Sub-Category"/"Ship-Mode"), but the alias was left bare with the hyphen —
# this is what the OLD scan mis-tokenized into a passing "OK" (the stray
# "CATEGORY"/"MODE" fragments happened not to collide with real columns
# here, but the OLD alias-defining logic still silently accepted "SUB" as
# THE alias instead of flagging the malformed clause at all).
bug_sql = 'SELECT "Sub-Category" AS SUB-CATEGORY, "Ship-Mode" AS SHIP-MODE, ' \
          'SUM("Deal Value") AS SUB_CATEGORY_SHIP_MODE_TOTAL FROM ANALYTICS.SALES.DEAL_FACTS GROUP BY 1, 2'
bug_res = SqlIdentCheck.check(bug_sql, catalog)
check(!bug_res[:ok], "unquoted-alias bug shape is now REJECTED, not printed OK (got ok=#{bug_res[:ok]})", fails)
bad_names = bug_res[:unknown].select { |u| u[:illegal_alias] }.map { |u| u[:identifier] }
check(bad_names.include?('SUB-CATEGORY'), "SUB-CATEGORY reported as an illegal alias (got #{bad_names.inspect})", fails)
check(bad_names.include?('SHIP-MODE'), "SHIP-MODE reported as an illegal alias (got #{bad_names.inspect})", fails)
suggestions = bug_res[:unknown].select { |u| u[:illegal_alias] }.to_h { |u| [u[:identifier], u[:suggestion]] }
check(suggestions['SUB-CATEGORY'] == '"SUB-CATEGORY"', "quoted-fix suggested for SUB-CATEGORY (got #{suggestions['SUB-CATEGORY'].inspect})", fails)
check(suggestions['SHIP-MODE'] == '"SHIP-MODE"', "quoted-fix suggested for SHIP-MODE (got #{suggestions['SHIP-MODE'].inspect})", fails)
# The FIXED shape (this exact bug quoted, nothing else changed) must be clean —
# proves the finding is precisely the alias, not a false trip on the rest of
# the statement.
fixed_sql = bug_sql.sub('AS SUB-CATEGORY', 'AS "SUB-CATEGORY"').sub('AS SHIP-MODE', 'AS "SHIP-MODE"')
check(SqlIdentCheck.check(fixed_sql, catalog)[:ok],
      "quoting just the two aliases (nothing else) is sufficient to pass clean (got: #{fixed_sql})", fails)

puts 'Part D2 — #693 sibling: the WINDOW-HELPER path (same _tableauExprToSql lowering) also quotes correctly'
# The window-helper statement is a two-level CTE (`WITH base AS (...) SELECT
# ... FROM base`) where the SAME hyphenated name is referenced THREE times —
# unlike the flat, ordinal-GROUP-BY LOD helper above, quoting only the `AS`
# definition and leaving the other two references bare would just move the
# syntax error, not fix it (exactly the risk flagged in the task: "if
# downstream ref resolution expects an unquoted/uppercased identifier,
# quoting will move the failure rather than fix it"). All three must agree:
win_sql = win_helper.dig('source', 'statement').to_s
puts "  (emitted window-helper SQL: #{win_sql})"
check(win_sql.include?('AS "SUB-CATEGORY"'), "(1) base-CTE definition quoted (got: #{win_sql})", fails)
check(win_sql =~ /SELECT\s+"SUB-CATEGORY",/, "(2) outer SELECT list references it quoted (got: #{win_sql})", fails)
check(win_sql.include?('PARTITION BY "SUB-CATEGORY"'), "(3) PARTITION BY references it quoted (got: #{win_sql})", fails)
check(win_sql !~ /\bSUB-CATEGORY\b(?!")/, "no remaining BARE (unquoted) SUB-CATEGORY reference anywhere (got: #{win_sql})", fails)
check(SqlIdentCheck.check(win_sql, catalog)[:ok],
      "the window-helper's actual emitted SQL is clean end-to-end (got: #{SqlIdentCheck.check(win_sql, catalog)[:unknown].inspect})", fails)

puts 'Part E — sibling captions (thoroughness: this is not a hyphen-only fix)'
# "Year-over-Year": a hyphenated caption whose SECOND fragment ("over")
# collides with the real SQL keyword OVER — must still reconstruct and flag
# the WHOLE alias, not truncate at the keyword collision.
yoy_bad = 'SELECT "Revenue" AS REVENUE, SUM("Revenue") AS YEAR-OVER-YEAR FROM ANALYTICS.SALES.DEAL_FACTS'
yoy_res = SqlIdentCheck.check(yoy_bad, { 'DEAL_FACTS' => ['Revenue'] })
check(!yoy_res[:ok], 'Year-over-Year (keyword-colliding fragment) unquoted alias flagged', fails)
yoy_alias = yoy_res[:unknown].find { |u| u[:illegal_alias] }
check(!yoy_alias.nil? && yoy_alias[:identifier] == 'YEAR-OVER-YEAR',
      "full alias reconstructed as YEAR-OVER-YEAR, not truncated at OVER (got #{yoy_alias && yoy_alias[:identifier]})", fails)
check(!yoy_alias.nil? && yoy_alias[:suggestion] == '"YEAR-OVER-YEAR"',
      "quoted-fix suggested for Year-over-Year (got #{yoy_alias && yoy_alias[:suggestion]})", fails)
yoy_fixed = yoy_bad.sub('AS YEAR-OVER-YEAR', 'AS "YEAR-OVER-YEAR"')
check(SqlIdentCheck.check(yoy_fixed, { 'DEAL_FACTS' => ['Revenue'] })[:ok],
      'quoted Year-over-Year alias passes clean', fails)

# A bare alias with an embedded SPACE (no hyphen at all) — same illegality
# class, different punctuation; must not be hyphen-specific.
spaced_bad = 'SELECT "Order Date" AS ORDER DATE FROM ANALYTICS.SALES.DEAL_FACTS'
spaced_res = SqlIdentCheck.check(spaced_bad, { 'DEAL_FACTS' => ['Order Date'] })
check(!spaced_res[:ok], 'a spaced (multi-word) unquoted alias is flagged, not just hyphenated ones', fails)

# Embedded double-quote handling, NOTE ON SCOPE: the converter-side alias
# quoting (_qidIfNeeded in converter/tableau.mjs) delegates to the file's
# PRE-EXISTING _qid helper (`(name) => \`"${String(name).replace(/"/g,
# '""')}"\``, already used by collapseCustomSqlBlend for the identical
# alias-quoting purpose) — so a caption containing '"' is escaped by
# doubling on the EMITTED-SQL side by construction, without new code to
# re-verify here. That is a DIFFERENT concern from the Ruby-side oracle
# below: sql_ident/illegal_reason is the "should this ever be sent to a LIVE
# warehouse at all" gate used by probe-join-keys.rb/join_plan.rb, and its
# established, separately-tested policy (test-sql-ident-check.rb Part J) is
# to REFUSE a name containing an embedded double quote outright (a quote
# inside a purported physical identifier is far more likely mangled/GUID
# corruption than a legitimate name) rather than escape-and-quote it. Confirm
# extending scan/check for #693 left that unrelated, already-pinned refusal
# behavior intact — not weakened into an escape path it was never meant to
# take.
check(SqlIdentCheck.sql_ident('BAD"NAME').nil?,
      'sql_ident still REFUSES an embedded double-quote (unrelated, pre-existing pin — unweakened by the #693 scan/check changes)', fails)
check(SqlIdentCheck.illegal_reason('BAD"NAME').to_s.include?('double quote'),
      'illegal_reason still names the double-quote refusal class', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
