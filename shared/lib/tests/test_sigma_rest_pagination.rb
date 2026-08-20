#!/usr/bin/env ruby
# Regression tests for Sigma.list_entries' dual pagination conventions (bead 0h11).
# No network: Sigma.request is stubbed per-case.
#   ruby shared/lib/tests/test_sigma_rest_pagination.rb

require_relative '../sigma_rest'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

# Replace Sigma.request with a scripted responder that records the paths it saw.
def with_stubbed_request(pages)
  seen = []
  Sigma.singleton_class.send(:alias_method, :__real_request, :request)
  Sigma.define_singleton_method(:request) do |_method, path, **_kw|
    seen << path
    pages.shift || { 'entries' => [] }
  end
  yield seen
ensure
  Sigma.singleton_class.send(:alias_method, :request, :__real_request)
  Sigma.singleton_class.send(:remove_method, :__real_request)
end

puts '== nextPage / page= convention (most /v2 list endpoints) =='
with_stubbed_request([
  { 'entries' => [{ 'name' => 'a' }], 'nextPage' => 'CUR1' },
  { 'entries' => [{ 'name' => 'b' }] }
]) do |seen|
  got = Sigma.list_entries('/v2/things')
  eq(got.map { |e| e['name'] }, %w[a b], 'follows nextPage to exhaustion')
  ok(seen[1].include?('page=CUR1'), "sends the cursor back as page=, got: #{seen[1]}")
  ok(!seen[1].include?('pageToken='), 'does not use pageToken= for a nextPage cursor')
end

puts '== nextPageToken / pageToken= convention (the columns endpoint) =='
# This is the case that silently truncated at 50: nextPage is absent entirely,
# so the pre-fix loop stopped after page 1 with no error.
with_stubbed_request([
  { 'entries' => [{ 'name' => 'c1' }], 'nextPageToken' => 'TOK1' },
  { 'entries' => [{ 'name' => 'c2' }], 'nextPageToken' => 'TOK2' },
  { 'entries' => [{ 'name' => 'c3' }] }
]) do |seen|
  got = Sigma.list_entries('/v2/connections/tables/inode-1/columns')
  eq(got.map { |e| e['name'] }, %w[c1 c2 c3], 'follows nextPageToken to exhaustion (no silent truncation)')
  ok(seen[1].include?('pageToken=TOK1'), "sends the cursor back as pageToken=, got: #{seen[1]}")
  ok(!seen[1].include?('page=TOK1'), 'does not send a token cursor as page= (that re-serves page 1 forever)')
end

puts '== a repeated cursor stops rather than looping forever =='
# Guards the specific half-fix failure mode: reading nextPageToken but sending
# it as page= makes the server re-serve page 1 with the same cursor.
with_stubbed_request(Array.new(50) { { 'entries' => [{ 'name' => 'dup' }], 'nextPageToken' => 'SAME' } }) do |seen|
  got = Sigma.list_entries('/v2/connections/tables/inode-2/columns')
  ok(seen.size < 5, "bails out early on a repeated cursor instead of spinning (requests made: #{seen.size})")
  ok(!got.empty?, 'still returns what it did manage to read')
end

puts '== neither cursor present -> single page =='
with_stubbed_request([{ 'entries' => [{ 'name' => 'only' }] }]) do |seen|
  got = Sigma.list_entries('/v2/things')
  eq(got.size, 1, 'stops after one page when no cursor is returned')
  eq(seen.size, 1, 'makes exactly one request')
end

puts
if $failures.zero? then puts 'ALL PASS'; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
