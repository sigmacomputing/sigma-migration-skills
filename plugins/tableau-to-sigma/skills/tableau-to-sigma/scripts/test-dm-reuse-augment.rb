#!/usr/bin/env ruby
# Regression test for #691: on the DM-REUSE path, migrate-tableau.rb binds to
# an existing data model but never authors the derived columns a FRESH build
# would have created — the converter's own fact element (conv_fact) can carry
# mechanically-derived columns (date-key synthesis, cross-element Lookups)
# that a fresh build POSTs as real physical columns; reuse skips that POST
# entirely, so a workbook ref to one of those columns dangles against the
# live (reused) DM's actual columns ("no master column matched dim header
# 'Month of Order Date'" / exit 4).
#
# Fixture mirrors the reported shape (business-generic names only — no live
# ids/paths/customer data):
#   conv_fact ("Order Fact") carries 4 mechanically-derived columns:
#     Order Date        <- self-contained: Date(...) over its OWN
#                           "Order Date Key" (int) column
#     Fulfillment Tier   <- self-contained: If() over its OWN
#                           "Days To Ship" column
#     Region             <- cross-element Lookup into "Customer Dim", which
#                           the reuse candidate DOES have (wired)
#     Loyalty Score       <- cross-element Lookup into "Rewards Dim", which
#                           the candidate does NOT have at all — models the
#       fact<->date-dimension class of gap from the live report: a join the
#       run could not auto-create.
#
#   The REUSE CANDIDATE ("Order Fact") is a raw-column superset exactly like
#   the live report (every raw column matched) — it carries every RAW column
#   the converter references and a wired Customer Dim relationship, but NONE
#   of the four derived columns above.
#
# Expected: Order Date, Fulfillment Tier, and Region are CLOSABLE (every ref
# they need already resolves against the candidate at the fact grain).
# Loyalty Score is UNCLOSABLE (its target element/relationship does not exist
# on the candidate and cannot be derived) — a workbook that needs it must
# abandon this reuse candidate and build fresh, not ship a dangling ref.
#
# Usage: ruby scripts/test-dm-reuse-augment.rb

require_relative 'mechanical-specs'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

conv_fact = {
  'name' => 'Order Fact',
  'columns' => [
    { 'id' => 'c1', 'name' => 'Order Date Key' },
    { 'id' => 'c2', 'name' => 'Days To Ship' },
    { 'id' => 'c3', 'name' => 'Customer Key' },
    { 'id' => 'c4', 'name' => 'Order Date',
      'formula' => 'Date(Left(Text([Order Date Key]),4) & "-" & Mid(Text([Order Date Key]),5,2) & "-" & Mid(Text([Order Date Key]),7,2))' },
    { 'id' => 'c5', 'name' => 'Fulfillment Tier',
      'formula' => 'If([Days To Ship] <= 2, "Fast", "Standard")' },
    { 'id' => 'c6', 'name' => 'Region',
      'formula' => 'Lookup([Customer Dim/Region], [Customer Key], [Customer Dim/Customer Key])' },
    { 'id' => 'c7', 'name' => 'Loyalty Score',
      'formula' => 'Lookup([Rewards Dim/Score], [Customer Key], [Rewards Dim/Customer Key])' }
  ]
}

# The reuse candidate never went through THIS conversion's Phase 3 build. It
# has every RAW column the converter references, a wired Customer Dim
# relationship — but none of the derived columns, and no Rewards Dim element.
candidate = {
  'pages' => [{
    'elements' => [
      { 'id' => 'e-fact', 'name' => 'Order Fact',
        'columns' => [
          { 'id' => 'lc1', 'name' => 'Order Date Key' },
          { 'id' => 'lc2', 'name' => 'Days To Ship' },
          { 'id' => 'lc3', 'name' => 'Customer Key' }
        ],
        'relationships' => [
          { 'targetElementId' => 'e-cust' }
        ] },
      { 'id' => 'e-cust', 'name' => 'Customer Dim',
        'columns' => [
          { 'id' => 'lc4', 'name' => 'Customer Key' },
          { 'id' => 'lc5', 'name' => 'Region' }
        ] }
    ]
  }]
}

puts '-- plan_reuse_derived_columns: the pre-fix decision this pins --'
plan = MechanicalSpecs.plan_reuse_derived_columns(conv_fact, candidate, 'Order Fact')
closable_names = plan['closable'].map { |c| c['name'] }
unclosable_names = plan['unclosable'].map { |c| c['name'] }

check(closable_names.sort == ['Order Date', 'Region', 'Fulfillment Tier'].sort,
      "self-contained + wired-cross-element columns are CLOSABLE (got #{closable_names.inspect})", fails)
check(unclosable_names == ['Loyalty Score'],
      "a column needing a relationship the candidate lacks is UNCLOSABLE (got #{unclosable_names.inspect})", fails)

od_plan = plan['closable'].find { |c| c['name'] == 'Order Date' }
check(od_plan && od_plan['formula'] == conv_fact['columns'][3]['formula'],
      'the CLOSABLE plan entry carries the fresh-build formula VERBATIM (reused, not re-derived)', fails)

puts
puts '-- apply_reuse_augmentation!: must splice the fresh-build derivations onto the live element --'
added = MechanicalSpecs.apply_reuse_augmentation!(candidate, 'Order Fact', plan['closable'])
fact_el = candidate['pages'][0]['elements'][0]
authored_names = fact_el['columns'].map { |c| c['name'] }
od = fact_el['columns'].find { |c| c['name'] == 'Order Date' }

check(added == 3, "apply_reuse_augmentation! reports 3 column(s) added (got #{added})", fails)
check(od && od['formula'] == conv_fact['columns'][3]['formula'],
      "authored 'Order Date' formula is IDENTICAL to the fresh-build formula (no parallel derivation engine)", fails)
check(authored_names.include?('Fulfillment Tier') && authored_names.include?('Region'),
      "Fulfillment Tier and Region were also authored onto the live fact (got #{authored_names.inspect})", fails)
check(authored_names.none? { |n| n == 'Loyalty Score' },
      'the UNCLOSABLE Loyalty Score is never authored onto the live DM (would dangle)', fails)

puts
puts '-- reuse_tie_guard: a narrow score tie must not silently auto-pick an arbitrary twin --'
tied_match = {
  'auto_picked' => true,
  'score' => 0.9,
  'tie_count' => 2,
  'candidates' => [
    { 'dm_id' => 'dm-a', 'dm_name' => 'ORDER_FACT (ANALYTICS.ORDER_FACT)+ (New Virtual Connection)' },
    { 'dm_id' => 'dm-b', 'dm_name' => 'ORDER_FACT (ANALYTICS.ORDER_FACT)+ (copy)' }
  ]
}
tie_guard = MechanicalSpecs.reuse_tie_guard(tied_match, 'Regional Sales Summary')
check(tie_guard['auto_picked'] == false && tie_guard['blocked'],
      "a 2-way tie with no source-name match is BLOCKED, not silently auto-picked (got #{tie_guard.inspect})", fails)

name_matched = {
  'auto_picked' => true,
  'score' => 0.9,
  'tie_count' => 2,
  'candidates' => [
    { 'dm_id' => 'dm-a', 'dm_name' => 'Regional Sales Summary' },
    { 'dm_id' => 'dm-b', 'dm_name' => 'ORDER_FACT (ANALYTICS.ORDER_FACT)+ (copy)' }
  ]
}
tie_guard2 = MechanicalSpecs.reuse_tie_guard(name_matched, 'Regional Sales Summary')
check(tie_guard2['auto_picked'] == true && !tie_guard2['blocked'],
      "a tie where the TOP candidate matches the source workbook name still auto-picks (got #{tie_guard2.inspect})", fails)

untied = { 'auto_picked' => true, 'score' => 0.9, 'tie_count' => 1,
           'candidates' => [{ 'dm_id' => 'dm-a', 'dm_name' => 'Something Else' }] }
tie_guard3 = MechanicalSpecs.reuse_tie_guard(untied, 'Regional Sales Summary')
check(tie_guard3['auto_picked'] == true && !tie_guard3['blocked'],
      "no tie (tie_count 1) is unaffected (got #{tie_guard3.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — reuse authors the fresh-build derivations it needs, refuses an unclosable gap, and never silently collapses a tie'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
