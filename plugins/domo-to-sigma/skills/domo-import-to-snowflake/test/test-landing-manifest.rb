#!/usr/bin/env ruby
# Unit tests for lib/landing_manifest.rb. No network, no filesystem.
#   ruby test/test-landing-manifest.rb

require_relative '../scripts/lib/landing_manifest'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== ids_to_land =="
ds_map = {
  'ds-1' => { '_source' => 'domo-landed-data' },
  'ds-2' => { '_source' => 'domo-stream-config', 'table' => 'ORDERS' },
  'ds-3' => { '_source' => 'domo-landed-data' }
}
eq(LandingManifest.ids_to_land(ds_map).sort, %w[ds-1 ds-3], 'auto-detects every domo-landed-data entry, skips resolved ones')
eq(LandingManifest.ids_to_land(ds_map, dataset_ids: ['ds-2']), ['ds-2'], 'explicit --dataset-id overrides auto-detection')

puts "== patched_entry =="
existing = { 'connectionId' => '', 'name' => 'Surveys', '_source' => 'domo-landed-data',
             '_note' => 'no connector stream config found...' }
patched = LandingManifest.patched_entry(existing, database: 'DB', schema: 'SCH', table: 'SURVEYS')
eq(patched['database'], 'DB', 'database filled in')
eq(patched['schema'], 'SCH', 'schema filled in')
eq(patched['table'], 'SURVEYS', 'table filled in')
eq(patched['_source'], 'domo-landed-snowflake', 'source rewritten away from the sentinel')
eq(patched.key?('_note'), false, 'stale sentinel note removed')
eq(patched['name'], 'Surveys', 'human-authored name preserved')
eq(patched['connectionId'], '', 'connectionId untouched — never derived')

existing_with_conn = { 'connectionId' => 'conn-abc', '_source' => 'domo-landed-data' }
patched2 = LandingManifest.patched_entry(existing_with_conn, database: 'DB', schema: 'SCH', table: 'X')
eq(patched2['connectionId'], 'conn-abc', "a human-supplied connectionId survives untouched")

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
