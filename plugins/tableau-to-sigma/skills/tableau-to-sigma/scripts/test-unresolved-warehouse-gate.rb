#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for issue #685-A part 2 (Superstore cold-run failure, 2026-08-08).
#
# THE BUG: when the extract-landing manifest remap (MechanicalSpecs.
# remap_from_manifest!) never runs / never attributes an element, the
# converter's placeholder warehouse-table name+path ("UNKNOWN" /
# ["TJ","UNKNOWN"], missing the database segment) survives all the way to a
# live DM POST, which fails late with an unnamed, cryptic error:
#   POST failed: {"errors"=>[{"summary"=>"Source not found: warehouse table
#   'TJ.UNKNOWN' on connection '...'"}]}
#
# THE FIX: MechanicalSpecs.unresolved_warehouse_elements(model) detects any
# warehouse-table element still carrying that placeholder AFTER remap/fixup
# have run, so migrate-tableau.rb can fail loud + named (exit 21) BEFORE the
# POST instead of after it. A broken path reaching a live POST is worse than
# an early, named error.
#
# Deterministic + offline: hand-built DM fixtures, no network / creds.
#
# Usage:  ruby scripts/test-unresolved-warehouse-gate.rb

require_relative 'mechanical-specs'

fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

def wt_element(id, name, path)
  { 'id' => id, 'kind' => 'table', 'name' => name,
    'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1', 'path' => path },
    'columns' => [{ 'id' => "#{id}-c1", 'name' => 'X', 'formula' => "[#{name}/X]" }] }
end

puts "Part A — the exact reported shape: name='UNKNOWN', path=['TJ','UNKNOWN'] (database segment missing)"
model = { 'pages' => [{ 'elements' => [wt_element('el-1', 'UNKNOWN', %w[TJ UNKNOWN])] }] }
bad = MechanicalSpecs.unresolved_warehouse_elements(model)
check(bad.size == 1, "the placeholder element is flagged (got #{bad.size})", fails)
check(bad.first['id'] == 'el-1', 'the correct element is identified', fails)

puts 'Part B — a clean, fully-resolved element is NOT flagged'
clean_model = { 'pages' => [{ 'elements' => [
  wt_element('el-2', 'Superstore Orders', %w[CSA TJ SUPERSTORE_C462BF_ORDERS])
] }] }
check(MechanicalSpecs.unresolved_warehouse_elements(clean_model).empty?,
      'a real, correctly-remapped element passes clean', fails)

puts "Part C — a REAL table that merely happens to be named similarly is not falsely tripped"
# 'Unknown Region' is a legitimate, if unfortunately-named, real business
# dimension — only the EXACT sentinel 'UNKNOWN' (case-insensitive, whole
# segment) trips the gate, never a substring/prefix match.
similar_model = { 'pages' => [{ 'elements' => [
  wt_element('el-3', 'Unknown Region Dim', %w[CSA TJ UNKNOWN_REGION_DIM])
] }] }
check(MechanicalSpecs.unresolved_warehouse_elements(similar_model).empty?,
      "a real table merely CONTAINING 'unknown' as a substring is not a false positive", fails)

puts 'Part D — a kind:sql (Custom SQL) element is never in scope (the placeholder is warehouse-table only)'
sql_model = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-4', 'kind' => 'table', 'name' => 'UNKNOWN',
    'source' => { 'connectionId' => 'c', 'kind' => 'sql', 'statement' => 'SELECT 1' },
    'columns' => [] }
] }] }
check(MechanicalSpecs.unresolved_warehouse_elements(sql_model).empty?,
      'a kind:sql element named UNKNOWN is out of scope for this gate', fails)

puts
if fails.empty?
  puts 'ALL PASS'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
