#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test: the EXIT-4 salvage inventory (migrate-tableau.rb).
#
# Field failure (2026-07): the workbook-layer handoff (exit 4) named the
# untranslatable fields but nothing else — the agent then spent ~90 min
# re-deriving from the .twb what calc-fields.json already carried: each field's
# Tableau formula, its class, and which documented route applies. The banner now
# prints (and persists to salvage-inventory.json) a per-field inventory:
#   window/table calc  → manual-residue SQL route (gate-15 tracked)
#   LOD calc           → --master-col translation (helper-element recipe ref)
#   row-level calc     → --master-col translation
#   unknown            → not-a-calc pointer (column-mapping, not translation)
#
# The def is extracted verbatim from migrate-tableau.rb and eval'd (same
# pattern as test-typed-literal-wiring.rb) so removals/drift fail the test.
#
# Offline, no creds. Usage: ruby scripts/test-salvage-inventory.rb

require 'json'
require 'tmpdir'

SRC = File.join(__dir__, 'migrate-tableau.rb')
src = File.read(SRC, encoding: 'UTF-8')
block = src[/^def salvage_inventory\(work, failed\).*?\n^end$/m]
abort "could not extract salvage_inventory from #{SRC}" unless block
eval(block) # rubocop:disable Security/Eval — trusted first-party source, test-only

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

CALCS = {
  'workbook_luid' => 'wb-1', 'calcs' => [
    { 'name' => 'Running Share', 'formula' => 'RUNNING_SUM(SUM([Sales])) / TOTAL(SUM([Sales]))',
      'is_lod' => false, 'requires_custom_sql' => true,
      'translation_notes' => ['TOTAL() needs a window partition'] },
    { 'name' => 'Region Avg', 'formula' => '{FIXED [Region] : AVG([Sales])}',
      'is_lod' => true, 'requires_custom_sql' => false, 'translation_notes' => [] },
    { 'name' => 'Delivery Tier', 'formula' => "IF [Days] <= 2 THEN 'Fast' ELSE 'Slow' END",
      'is_lod' => false, 'requires_custom_sql' => false, 'translation_notes' => [] }
  ]
}.freeze

Dir.mktmpdir do |work|
  File.write(File.join(work, 'calc-fields.json'), JSON.pretty_generate(CALCS))

  inv = salvage_inventory(work, ['Running Share', 'region avg', 'Delivery Tier', 'TOTALREV'])
  check(inv.length == 4, 'one inventory row per blocked field')

  win = inv[0]
  check(win['class'].include?('window/table calc'), 'window calc classed as STAYS-MANUAL family')
  check(win['formula'].include?('RUNNING_SUM'), 'window row carries the Tableau formula')
  check(win['route'].include?('manual-residues.json') && win['route'].include?('Custom SQL'),
        'window route points at the manual-residue SQL path (gate-15 tracked)')
  check(win['notes'] == ['TOTAL() needs a window partition'], 'translation_notes carried through')

  lod = inv[1]
  check(lod['field'] == 'Region Avg', 'case-insensitive name match resolves the calc entry')
  check(lod['class'].include?('LOD'), 'LOD calc classed as LOD')
  check(lod['route'].include?("--master-col 'Region Avg=") && lod['route'].include?('helper-element'),
        'LOD route is the --master-col translation with the helper-element fallback')

  row = inv[2]
  check(row['class'] == 'row-level calc', 'plain calc classed row-level')
  check(row['route'].include?("--master-col 'Delivery Tier="),
        'row-level route is the --master-col translation naming the field')

  unk = inv[3]
  check(unk['class'].include?('no calc-fields.json entry'), 'unknown field says so')
  check(unk['route'].include?('column-mapping'), 'unknown route points at the column-mapping fix')
end

Dir.mktmpdir do |work|
  # No calc-fields.json at all — never raises; every field routes as unknown.
  inv = salvage_inventory(work, ['Anything'])
  check(inv.length == 1 && inv[0]['class'].include?('no calc-fields.json entry'),
        'missing calc-fields.json degrades to the unknown route (no raise)')
end

# The banner wiring exists: the exit-4 rescue prints the inventory and persists
# salvage-inventory.json (grep-level lock; the behavior is tested above).
check(src.include?('SALVAGE INVENTORY — per blocked field') && src.include?('salvage-inventory.json'),
      'exit-4 banner prints + persists the salvage inventory')

puts
if $fails.empty?
  puts 'ALL PASS — exit-4 salvage inventory'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
