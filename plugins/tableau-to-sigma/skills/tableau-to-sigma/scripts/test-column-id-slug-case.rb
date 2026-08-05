#!/usr/bin/env ruby
# Regression test for the CASE-INSENSITIVE column-id slugifier (#455). Offline +
# deterministic. Guards the master-table builder against a class of spurious
# "Duplicate id" 400s: two SOURCE columns whose names differ ONLY in case
# ("userId" vs "UserID", "Value" vs "value" — legitimately distinct columns from a
# schema that evolved, or a view exposing an original + renamed column) both
# slug to one lowercase base id. Before the fix, `derive_master` either dropped
# the second column (silent data loss, via a downcased dedup) or minted a
# duplicate id that 400s at the DM/workbook POST.
#
# The fix keeps the plain lowercase slug for the FIRST name to claim a base id
# (so already-shipped ids stay stable) and hands every differently-cased sibling a
# DETERMINISTIC, 64-char-clamped suffix — so genuinely-distinct columns always get
# distinct ids, while a genuine same-name duplicate still collapses to one id.
#
# Usage:  ruby scripts/test-column-id-slug-case.rb
require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

def fact(cols)
  { 'id' => 'fact', 'name' => 'Order Fact', 'kind' => 'sql',
    'columns' => cols.each_with_index.map do |nm, i|
      { 'id' => "conv-#{i}", 'name' => nm, 'formula' => "[Order Fact/#{nm}]" }
    end, 'metrics' => [] }
end

puts 'Part A — case-collision helpers (unit)'
# slug still downcases (unchanged — stability contract for non-colliding names).
check(MechanicalSpecs.slug('Region') == 'region', 'slug("Region") == "region" (unchanged)', fails)
check(MechanicalSpecs.slug('UserID') == 'userid', 'slug still downcases (case is lost at the slug layer)', fails)
# mint_id: first claimant keeps the plain slug; a differently-cased sibling is
# disambiguated; the SAME exact name reuses its id.
reg = {}
id_a = MechanicalSpecs.mint_id('m-', 'userId', reg)
id_b = MechanicalSpecs.mint_id('m-', 'UserID', reg)
id_a2 = MechanicalSpecs.mint_id('m-', 'userId', reg)
check(id_a == 'm-userid', 'first claimant keeps the plain slug ("m-userid")', fails)
check(id_b != id_a, 'differently-cased sibling gets a DISTINCT id', fails)
check(id_b.start_with?('m-userid-'), 'disambiguated id keeps the readable base + a suffix', fails)
check(id_a2 == id_a, 'same exact name re-mints the SAME id (deterministic)', fails)
check(MechanicalSpecs.mint_id('m-', 'UserID', {}) == 'm-userid', 'a lone differently-cased name (no prior claim) keeps the plain slug', fails)
# clamp: a disambiguator can never overflow the 64-char id limit (#445 compose).
long = 'A' * 80
long_reg = { "m-#{'a' * 80}" => 'x' } # base already claimed by a different name -> forces the suffix path
long_id = MechanicalSpecs.mint_id('m-', long, long_reg)
check(long_id.length <= 64, 'a disambiguated LONG name still clamps to <= 64 chars', fails)

puts 'Part B — derive_master: two case-differing columns -> two distinct ids'
d = MechanicalSpecs.derive_master(fact(%w[userId UserID Region]), 'Order Fact')
ids = d['master_columns'].map { |c| c['id'] }
names = d['master_columns'].map { |c| c['name'] }
check(ids.size == ids.uniq.size, 'no duplicate master-column ids (would 400 at POST)', fails)
check(names.include?('userId') && names.include?('UserID'), 'BOTH differently-cased columns survive (no silent drop)', fails)
check(ids.include?('m-region'), 'a non-colliding name keeps its stable id ("m-region")', fails)
check(ids.count { |i| i == 'm-userid' } == 1, 'exactly one column owns the plain "m-userid" id', fails)
check(ids.all? { |i| i.length <= 64 }, 'every master-column id is within the 64-char clamp', fails)

puts 'Part C — genuine same-name duplicate still collapses'
d2 = MechanicalSpecs.derive_master(fact(['Region', 'Region', 'Sales']), 'Order Fact')
reg_cols = d2['master_columns'].select { |c| c['name'] == 'Region' }
check(reg_cols.size == 1, 'two identical "Region" columns collapse to ONE master column', fails)
check(d2['master_columns'].map { |c| c['id'] }.uniq.size == d2['master_columns'].size, 'no duplicate ids after collapse', fails)

puts 'Part D — determinism across runs'
r1 = MechanicalSpecs.derive_master(fact(%w[Value value Amount]), 'Order Fact').dig('master_columns').map { |c| c['id'] }
r2 = MechanicalSpecs.derive_master(fact(%w[Value value Amount]), 'Order Fact').dig('master_columns').map { |c| c['id'] }
check(r1 == r2, 'the same source yields the SAME ids on every run', fails)
check(r1.uniq.size == r1.size, '"Value"/"value" get distinct, stable ids', fails)

puts
if fails.empty?
  puts 'ALL PASS'
  exit 0
else
  puts "FAILURES (#{fails.size}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
