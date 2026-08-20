#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for issue #685-B (World Indicators cold-run failure, 2026-08-08).
#
# THE BUG: the mechanical converter's base-column passthrough formula embeds a
# Tableau field's raw CAPTION, unescaped, inside a Sigma `[Table/Column]`
# bracket-path formula. Tableau captions routinely contain "/" (a very common
# naming convention — "Country/Region", "State/Province" — present in several
# of Tableau's OWN sample workbooks, not just customer content). When the
# caption itself contains "/", the emitted formula ("[WORLDIND_.../Country/Region]")
# is ambiguous to Sigma's bracket-path parser (it reads as a 3-segment nested
# path, not a 2-segment table/column pair) and compiles server-side to
# `type="error"`.
#
# This ALSO silently corrupted every Ruby-side consumer of the formula that
# recovers the physical column name via `formula.split('/').last`
# (MechanicalSpecs.col_display, and fixup_dm_spec's phantom-column check) —
# for "[T/Country/Region]" that yields "Region" (the wrong, truncated
# segment), which is how `--column-mapping "Country/Region=COUNTRY_REGION"`
# went silently inert in the live run: the phantom-check's `phys` variable
# was already "REGION" (which happened to coincide with an ACTUAL separate
# "Region" column on this table), so the mapping's lookup key never matched
# and colmap was never even consulted.
#
# THE FIX: MechanicalSpecs.sanitize_bracket_path_captions! rewrites every base
# passthrough column's formula to use a SANITIZED (bracket-path-safe) form of
# the caption — "/", "[", "]" folded to "_" — while preserving the ORIGINAL
# caption as the column's display `name`. Runs unconditionally (no manifest /
# catalog / --column-mapping required) as the first step of fixup_dm_spec, so
# every downstream consumer sees an unambiguous formula from the start.
#
# Deterministic + offline: hand-built DM fixture using the real column shape
# from the live run (Tableau's own "World Indicators" sample workbook), no
# network / creds.
#
# Usage:  ruby scripts/test-bracket-path-caption-escape.rb

require_relative 'mechanical-specs'

fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

def base_element(path_last, columns)
  {
    'id' => 'el-fact', 'kind' => 'table', 'name' => nil,
    'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1',
                  'path' => ['DB', 'SCHEMA', path_last] },
    'columns' => columns
  }
end

puts "Part A — a caption containing '/' is desensitized in the FORMULA, preserved as the display name"
model = { 'pages' => [{ 'elements' => [
  base_element('WORLDIND_2F6653_WORLD_INDICATORS', [
    { 'id' => 'c-1', 'name' => nil, 'formula' => '[WORLDIND_2F6653_WORLD_INDICATORS/Country/Region]' },
    { 'id' => 'c-2', 'name' => nil, 'formula' => '[WORLDIND_2F6653_WORLD_INDICATORS/GDP]' }
  ])
] }] }
n = MechanicalSpecs.sanitize_bracket_path_captions!(model)
col1 = model['pages'][0]['elements'][0]['columns'][0]
col2 = model['pages'][0]['elements'][0]['columns'][1]
check(n == 1, "exactly one formula rewritten (got #{n})", fails)
check(col1['formula'] == '[WORLDIND_2F6653_WORLD_INDICATORS/COUNTRY_REGION]',
      "'/' in the caption is folded to '_' in the FORMULA segment (got #{col1['formula']})", fails)
check(col1['name'] == 'Country/Region',
      "original caption 'Country/Region' preserved as the display name (got #{col1['name'].inspect})", fails)
check(col2['formula'] == '[WORLDIND_2F6653_WORLD_INDICATORS/GDP]',
      'a caption with no special characters is left byte-identical', fails)
check(col2['name'].nil?, 'an untouched column is not force-given a name', fails)

puts 'Part B — col_display now recovers the FULL original caption (no more truncation to "Region")'
check(MechanicalSpecs.col_display(col1) == 'Country/Region',
      "col_display returns the preserved display name, not a split-mangled fragment (got #{MechanicalSpecs.col_display(col1).inspect})", fails)

puts "Part C — '[' and ']' are also neutralized (any bracket-path-special character)"
model2 = { 'pages' => [{ 'elements' => [
  base_element('T', [{ 'id' => 'c-3', 'name' => nil, 'formula' => '[T/Weird [Bracket] Name]' }])
] }] }
MechanicalSpecs.sanitize_bracket_path_captions!(model2)
c3 = model2['pages'][0]['elements'][0]['columns'][0]
check(c3['formula'] !~ %r{[\[\]]/?.*[\[\]].*\]\z} || c3['formula'] == '[T/Weird _Bracket_ Name]',
      "embedded brackets in the caption are folded, not left to reopen the path (got #{c3['formula']})", fails)
check(c3['name'] == 'Weird [Bracket] Name', 'original caption (with brackets) preserved as display name', fails)

puts 'Part D — fixup_dm_spec runs the sanitizer unconditionally (no real_columns / column_mapping needed)'
model3 = { 'pages' => [{ 'elements' => [
  base_element('WORLDIND_2F6653_WORLD_INDICATORS', [
    { 'id' => 'c-4', 'name' => nil, 'formula' => '[WORLDIND_2F6653_WORLD_INDICATORS/Country/Region]' }
  ])
] }] }
MechanicalSpecs.fixup_dm_spec(model3)
c4 = model3['pages'][0]['elements'][0]['columns'][0]
check(c4['formula'] == '[WORLDIND_2F6653_WORLD_INDICATORS/COUNTRY_REGION]',
      "fixup_dm_spec (called with NO real_columns/column_mapping — the live-run first-pass call shape) " \
      "still sanitizes the caption (got #{c4['formula']})", fails)
check(c4['name'] == 'Country/Region', 'fixup_dm_spec preserves the display caption', fails)

puts 'Part E — the phantom-column check now sees the CORRECT physical name (COUNTRY_REGION, not REGION)'
# A landed table carrying a genuinely SEPARATE "Region" column (the coincidence
# that masked the bug in the live run) PLUS the real "Country/Region" ->
# COUNTRY_REGION landed column. Post-sanitization, the phantom check must key
# off COUNTRY_REGION and find it real (no false drop, no --column-mapping needed).
model4 = { 'pages' => [{ 'elements' => [
  base_element('WORLDIND_2F6653_WORLD_INDICATORS', [
    { 'id' => 'c-5', 'name' => nil, 'formula' => '[WORLDIND_2F6653_WORLD_INDICATORS/Country/Region]' },
    { 'id' => 'c-6', 'name' => nil, 'formula' => '[WORLDIND_2F6653_WORLD_INDICATORS/Region]' }
  ])
] }] }
real = { 'WORLDIND_2F6653_WORLD_INDICATORS' => %w[COUNTRY_REGION REGION GDP] }
fx = MechanicalSpecs.fixup_dm_spec(model4, real)
check(fx[:dropped].empty?, "no column wrongly dropped as phantom (got #{fx[:dropped].inspect})", fails)
kept = model4['pages'][0]['elements'][0]['columns']
check(kept.size == 2, 'both the slash-caption column and the plain Region column survive, distinct', fails)

puts
if fails.empty?
  puts 'ALL PASS'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
