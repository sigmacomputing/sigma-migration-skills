#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression pin for the FIXED-LOD Custom-SQL dialect-translation bug found by
# the 2026-08-08 regression bisect (see
# .superpowers/sdd/2026-08-08-pr-queue-drain/regression-bisect-report.md):
#
# The general calc translator (tableauFormulaToSigma) correctly maps Tableau
# DATETRUNC -> Sigma's DateTrunc() DM-formula function (verified in
# refs/functions.json). But FIXED-LOD calcs take a SEPARATE, uncataloged path:
# the converter lowers a single-table FIXED LOD's inner aggregate expression
# to a raw Custom-SQL GROUP-BY helper element (_tableauInnerToSql /
# _tableauExprToSql in converter/tableau.mjs), and that lowering copied
# Tableau's function-call text into the SQL string verbatim, with NO dialect
# translation pass — emitting invalid Snowflake SQL like
# `DATETRUNC('month', "Ship Date")` (Snowflake's function is DATE_TRUNC, with
# the underscore).
#
# Fixture: scripts/test-fixtures/lod-datetrunc.twb — one Snowflake table with
# a FIXED LOD calc (`{ FIXED [Ship Date] : AVG(IF DATETRUNC(...) = ... }`)
# that forces the converter to emit a GROUP-BY Custom SQL helper element whose
# source.statement embeds the LOD's inner aggregate expression.
#
# Usage: ruby scripts/test-lod-sql-dialect.rb

require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'

HERE = __dir__
VENDORED = File.expand_path('../converter/tableau.mjs', HERE)
FIXTURE  = File.join(HERE, 'test-fixtures', 'lod-datetrunc.twb')

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
helper = els.find { |e| e.dig('source', 'kind') == 'sql' }

puts 'Part A — structure: the FIXED-LOD Custom SQL helper element is emitted'
check(!helper.nil?, 'LOD GROUP-BY SQL helper element emitted', fails)
exit 1 unless fails.empty?

sql = helper.dig('source', 'statement').to_s

puts 'Part B — DATETRUNC is translated to Snowflake DATE_TRUNC, not copied verbatim'
check(!sql.nil? && !sql.empty?, 'helper SQL statement is non-empty', fails)
# The BUG signature: Tableau's DATETRUNC (no underscore) is not valid
# Snowflake SQL. It must never appear as a bare function call in the emitted
# statement.
check(sql !~ /\bDATETRUNC\s*\(/i,
      "no untranslated DATETRUNC(...) call in the emitted SQL (got: #{sql})", fails)
check(sql.scan(/\bDATE_TRUNC\s*\(/i).size >= 2,
      "both DATETRUNC calls lowered to Snowflake DATE_TRUNC(...) (got: #{sql})", fails)
check(sql.include?("DATE_TRUNC('month'"),
      "DATE_TRUNC keeps the original date-part literal ('month') (got: #{sql})", fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
