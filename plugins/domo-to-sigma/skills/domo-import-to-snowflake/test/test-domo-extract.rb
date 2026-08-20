#!/usr/bin/env ruby
# Unit tests for lib/domo_extract.rb. No network — a stubbed `query` seam
# stands in for Domo.query_dataset.
#   ruby test/test-domo-extract.rb

require_relative '../scripts/lib/domo_extract'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== row_count =="
counter = ->(_id, sql) { ok(sql.include?('COUNT(*)'), 'row_count sends a COUNT(*) query'); { 'rows' => [[42]] } }
eq(DomoExtract.row_count('ds-1', query: counter), 42, 'parses COUNT(*) result out of the rows envelope')

puts "== row_count: error handling =="
begin
  bad_no_rows = ->(_id, _sql) { { 'data' => 'wrong key' } }
  DomoExtract.row_count('ds-1', query: bad_no_rows)
  ok(false, 'missing rows key should raise')
rescue => e
  ok(e.message.include?('malformed COUNT(*)') && e.message.include?('ds-1'), "raises on missing 'rows' key: #{e.message}")
end

begin
  bad_empty_rows = ->(_id, _sql) { { 'rows' => [] } }
  DomoExtract.row_count('ds-1', query: bad_empty_rows)
  ok(false, 'empty rows array should raise')
rescue => e
  ok(e.message.include?('malformed COUNT(*)') && e.message.include?('ds-1'), "raises on empty 'rows' array: #{e.message}")
end

puts "== extract_rows: error handling =="
begin
  bad_missing_rows = ->(_id, _sql) { { 'columns' => %w[A] } }
  DomoExtract.extract_rows('ds-1', query: bad_missing_rows, band_size: 10)
  ok(false, 'missing rows key should raise')
rescue => e
  ok(e.message.include?('malformed page response') && e.message.include?('ds-1') && e.message.include?('offset 0'), "raises on missing 'rows': #{e.message}")
end

begin
  bad_missing_columns = ->(_id, _sql) { { 'rows' => [['x']] } }
  DomoExtract.extract_rows('ds-1', query: bad_missing_columns, band_size: 10)
  ok(false, 'missing columns key should raise')
rescue => e
  ok(e.message.include?('malformed page response') && e.message.include?('ds-1'), "raises on missing 'columns': #{e.message}")
end

begin
  bad_rows_not_array = ->(_id, _sql) { { 'columns' => %w[A], 'rows' => 'not an array' } }
  DomoExtract.extract_rows('ds-1', query: bad_rows_not_array, band_size: 10)
  ok(false, 'non-array rows should raise')
rescue => e
  ok(e.message.include?('malformed page response') && e.message.include?('ds-1'), "raises on rows not Array: #{e.message}")
end

begin
  bad_missing_metadata = ->(_id, _sql) { { 'columns' => %w[A B], 'rows' => [%w[1 2]] } }
  DomoExtract.extract_rows('ds-1', query: bad_missing_metadata, band_size: 10)
  ok(false, 'first page missing metadata key should raise, not silently type columns nil -> VARCHAR')
rescue => e
  ok(e.message.include?('malformed page response') && e.message.include?('ds-1') && e.message.include?('metadata'), "raises on missing 'metadata': #{e.message}")
end

begin
  bad_short_metadata = ->(_id, _sql) { { 'columns' => %w[A B], 'metadata' => [{ 'type' => 'STRING' }], 'rows' => [%w[1 2]] } }
  DomoExtract.extract_rows('ds-1', query: bad_short_metadata, band_size: 10)
  ok(false, 'first page metadata shorter than columns should raise')
rescue => e
  ok(e.message.include?('malformed page response') && e.message.include?('ds-1') && e.message.include?('metadata'), "raises on metadata shorter than columns: #{e.message}")
end

puts "== extract_rows: single page shorter than band_size stops immediately =="
one_page = ->(_id, _sql) { { 'columns' => %w[A B], 'metadata' => [{'type' => 'STRING'}, {'type' => 'LONG'}], 'rows' => [%w[1 2], %w[3 4]] } }
result = DomoExtract.extract_rows('ds-1', query: one_page, band_size: 10)
eq(result['columns'], %w[A B], 'columns captured from the first page')
eq(result['rows'], [%w[1 2], %w[3 4]], 'all rows from the short page returned')
eq(result['schema_cols'], [{'name' => 'A', 'type' => 'STRING'}, {'name' => 'B', 'type' => 'LONG'}], 'schema_cols built from columns and metadata')

puts "== extract_rows: multi-page pagination, full-size pages continue =="
calls = []
paged = ->(_id, sql) {
  calls << sql
  if calls.size == 1
    { 'columns' => %w[A], 'metadata' => [{'type' => 'LONG'}], 'rows' => Array.new(3) { |i| [i.to_s] } }   # full page, size == band_size
  else
    { 'columns' => %w[A], 'metadata' => [{'type' => 'LONG'}], 'rows' => [['3']] }                          # short final page
  end
}
result = DomoExtract.extract_rows('ds-1', query: paged, band_size: 3)
eq(result['rows'].size, 4, 'concatenates every page (3 + 1)')
eq(calls.size, 2, 'stops after the first short page — no unnecessary third call')
ok(calls[0].include?('OFFSET 0'), 'first page requests OFFSET 0')
ok(calls[1].include?('OFFSET 3'), 'second page requests OFFSET band_size')
eq(result['schema_cols'], [{'name' => 'A', 'type' => 'LONG'}], 'schema_cols captured from first page metadata')

puts "== extract_rows: exact multiple of band_size requires final short page to stop =="
exact_multiple = []
exact_paged = ->(_id, sql) {
  exact_multiple << sql
  case exact_multiple.size
  when 1
    { 'columns' => %w[A], 'metadata' => [{'type' => 'STRING'}], 'rows' => Array.new(3) { |i| [i.to_s] } }  # full page, 3 rows
  when 2
    { 'columns' => %w[A], 'metadata' => [{'type' => 'STRING'}], 'rows' => Array.new(3) { |i| [(i + 3).to_s] } }  # full page, 3 more rows
  when 3
    { 'columns' => %w[A], 'metadata' => [{'type' => 'STRING'}], 'rows' => Array.new(3) { |i| [(i + 6).to_s] } }  # full page, 3 more rows
  else
    { 'columns' => %w[A], 'metadata' => [{'type' => 'STRING'}], 'rows' => [] }  # short final page, 0 rows
  end
}
result = DomoExtract.extract_rows('ds-1', query: exact_paged, band_size: 3)
eq(result['rows'].size, 9, 'returns all 9 rows from three full pages + empty final')
eq(exact_multiple.size, 4, 'makes exactly 4 calls (3 full pages + 1 empty final page)')
ok(exact_multiple[2].include?('OFFSET 6'), 'third page requests OFFSET 6')
ok(exact_multiple[3].include?('OFFSET 9'), 'fourth page requests OFFSET 9 (detects empty final)')
eq(result['schema_cols'], [{'name' => 'A', 'type' => 'STRING'}], 'schema_cols from first page despite multiple pages')

puts "== extract_rows: zero-row dataset (empty final page on first call) =="
zero_rows = ->(_id, _sql) { { 'columns' => %w[A B], 'metadata' => [{'type' => 'STRING'}, {'type' => 'DOUBLE'}], 'rows' => [] } }
result = DomoExtract.extract_rows('ds-1', query: zero_rows, band_size: 100)
eq(result['columns'], %w[A B], 'columns captured even from empty first page')
eq(result['rows'], [], 'zero rows returned for empty dataset')
eq(result['schema_cols'], [{'name' => 'A', 'type' => 'STRING'}, {'name' => 'B', 'type' => 'DOUBLE'}], 'schema_cols available even from zero-row dataset')

puts "== extract_rows: legitimate empty final page does not raise =="
# This is covered by the exact_multiple test above (page 4 has empty rows), but verify the concept:
# an empty 'rows' array from extract_rows is valid; only row_count treats empty 'rows' as malformed
ok(true, 'empty rows array on extract_rows per-page response is valid (already tested above)')

puts "== extract_rows: schema_cols explicitly built from columns + metadata =="
schema_explicit = ->(_id, _sql) { { 'columns' => %w[col_a col_b col_c], 'metadata' => [{'type' => 'STRING'}, {'type' => 'LONG'}, {'type' => 'DOUBLE'}], 'rows' => [] } }
result = DomoExtract.extract_rows('ds-1', query: schema_explicit, band_size: 100)
eq(result['schema_cols'], [{'name' => 'col_a', 'type' => 'STRING'}, {'name' => 'col_b', 'type' => 'LONG'}, {'name' => 'col_c', 'type' => 'DOUBLE'}], 'schema_cols matches columns + metadata order exactly')

puts "== extract_with_parity =="
matching = ->(_id, sql) {
  sql.include?('COUNT(*)') ? { 'rows' => [[2]] } : { 'columns' => %w[A], 'metadata' => [{'type' => 'STRING'}], 'rows' => [['x'], ['y']] }
}
parity_result = DomoExtract.extract_with_parity('ds-1', query: matching, band_size: 100)
eq(parity_result['rows'].size, 2, 'row count matches COUNT(*) -> returns extracted rows')
eq(parity_result['schema_cols'], [{'name' => 'A', 'type' => 'STRING'}], 'extract_with_parity returns schema_cols from extract_rows')

mismatched = ->(_id, sql) {
  sql.include?('COUNT(*)') ? { 'rows' => [[99]] } : { 'columns' => %w[A], 'metadata' => [{'type' => 'LONG'}], 'rows' => [['x']] }
}
begin
  DomoExtract.extract_with_parity('ds-1', query: mismatched, band_size: 100)
  ok(false, 'mismatched row count should raise, not return')
rescue DomoExtract::RowCountMismatch => e
  ok(e.message.include?('99') && e.message.include?('1'), "raises RowCountMismatch naming both counts, got: #{e.message}")
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
