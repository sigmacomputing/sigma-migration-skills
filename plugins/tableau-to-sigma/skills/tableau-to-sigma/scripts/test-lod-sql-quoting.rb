#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression pin for two hackathon field-report findings against the VENDORED
# converter (converter/tableau.mjs) — deterministic + offline (node, no network):
#
#   F2 — LOD-helper Custom SQL must DOUBLE-QUOTE spaced/mixed-case warehouse
#        identifiers ("Customer Ref ID"), never emit them upper-snaked unquoted
#        (CUSTOMER_REF_ID → Snowflake "invalid identifier" compile error).
#        Fixed by the #313 re-vendor (physToRealQuoted/qFact from
#        metadata-record remote-names); this test keeps it fixed.
#
#   F3 — the derived "<Fact> View" element's `source.elementId` must point at
#        the BASE fact element (warehouse-table), never at the narrow LOD
#        GROUP-BY helper it references through a relationship (the wrong-source
#        binding produced 300+ dependency-not-found errors at DM POST).
#
# Fixture: scripts/test-fixtures/lod-spaced-columns.twb — one Snowflake table
# with spaced/mixed-case physical columns + a MAX({FIXED ...}) calc that forces
# the converter to emit (a) an LOD SQL helper and (b) a derived view element.
#
# Usage:  ruby scripts/test-lod-sql-quoting.rb

require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'

HERE = __dir__
VENDORED = File.expand_path('../converter/tableau.mjs', HERE)
FIXTURE  = File.join(HERE, 'test-fixtures', 'lod-spaced-columns.twb')

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
fact   = els.find { |e| e.dig('source', 'kind') == 'warehouse-table' }
helper = els.find { |e| e.dig('source', 'kind') == 'sql' }
view   = els.find { |e| e.dig('source', 'kind') == 'table' && e.dig('source', 'elementId') }

puts 'Part A — structure: fact + LOD helper + derived view all emitted'
check(!fact.nil?,   'warehouse-table fact element emitted', fails)
check(!helper.nil?, 'LOD GROUP-BY SQL helper element emitted', fails)
check(!view.nil?,   'derived "<Fact> View" element emitted', fails)
exit 1 unless fails.empty?

sql = helper.dig('source', 'statement').to_s

puts 'Part B — F2: spaced/mixed-case identifiers are double-quoted in the helper SQL'
check(sql.include?('"Customer Ref ID" AS CUSTOMER_REF_ID'),
      'GROUP-BY dim emitted as "Customer Ref ID" AS CUSTOMER_REF_ID', fails)
check(sql.include?('"Region View"'), 'agg expr quotes "Region View"', fails)
check(sql.include?('"Deal Value"'),  'agg expr quotes "Deal Value"', fails)
# The BUG signature: an upper-snaked identifier used UNQUOTED as a source
# column (allowed only as an output alias after AS / a table-path segment).
check(sql !~ /SELECT\s+CUSTOMER_REF_ID\b/i,
      'no bare CUSTOMER_REF_ID as a SELECT source identifier', fails)
check(sql !~ /\bREGION_VIEW\b/ && sql !~ /\bDEAL_VALUE\b/,
      'no upper-snaked unquoted REGION_VIEW / DEAL_VALUE anywhere in the SQL', fails)
check(sql.include?('FROM ANALYTICS.SALES.DEAL_FACTS'), 'FROM is the fully-qualified base table', fails)
check(sql =~ /GROUP BY 1\b/, 'GROUP BY by ordinal', fails)

puts 'Part C — F3: derived view sources the BASE fact, not the LOD helper'
check(view.dig('source', 'elementId') == fact['id'],
      "view source.elementId == fact id (got #{view.dig('source', 'elementId').inspect}, fact=#{fact['id'].inspect}, helper=#{helper['id'].inspect})", fails)
check(view.dig('source', 'elementId') != helper['id'],
      'view source.elementId is NOT the LOD helper', fails)
view_formulas = (view['columns'] || []).map { |c| c['formula'] }
check(view_formulas.any? { |f| f =~ %r{\A\[DEAL_FACTS/[^/\]]+\]\z} },
      'view columns reference base-table names ([DEAL_FACTS/...])', fails)
check(view_formulas.any? { |f| f =~ %r{\A\[DEAL_FACTS/FIXED [^/\]]+/} },
      'helper agg surfaced through the relationship path ([DEAL_FACTS/FIXED .../...])', fails)
rel = (fact['relationships'] || []).find { |r| r['targetElementId'] == helper['id'] }
check(!rel.nil? && (rel['keys'] || []).any?, 'fact → helper relationship with keys exists', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
