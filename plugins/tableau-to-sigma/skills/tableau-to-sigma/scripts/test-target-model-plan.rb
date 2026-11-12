#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/target_model_plan'

fails = []
check = lambda do |condition, message|
  puts "#{condition ? '  ok  ' : '  FAIL '}#{message}"
  fails << message unless condition
end

object_plan = {
  'datasources' => [{
    'datasource' => 'labels',
    'caption' => 'Labels',
    'objects' => %w[DIM_COUNTRY FACT_LABEL FACT_ARTIST],
    'fact_candidate' => 'DIM_COUNTRY',
    'role_signals' => {
      'DIM_COUNTRY' => { 'name_role' => 'dimension', 'relationship_degree' => 2 },
      'FACT_LABEL' => { 'name_role' => 'fact', 'relationship_degree' => 1 },
      'FACT_ARTIST' => { 'name_role' => 'fact', 'relationship_degree' => 1 }
    },
    'relationships' => [
      {
        'first' => 'DIM_COUNTRY', 'second' => 'FACT_LABEL', 'status' => 'wired',
        'keys' => [['COUNTRY_CODE', 'COUNTRY_CODE']],
        'first_unique_hint' => true, 'first_db_unique' => true
      },
      {
        'first' => 'DIM_COUNTRY', 'second' => 'FACT_ARTIST', 'status' => 'wired',
        'keys' => [['COUNTRY_CODE', 'COUNTRY_CODE']],
        'first_unique_hint' => true, 'first_db_unique' => true
      }
    ]
  }]
}

profiles = {
  'tables' => [
    { 'name' => 'DIM_COUNTRY', 'row_count' => 63, 'grain_keys' => %w[COUNTRY_CODE], 'unique' => true, 'role' => 'dimension' },
    { 'name' => 'FACT_LABEL', 'row_count' => 2_300_000, 'measures' => %w[STREAMS SHARE], 'role' => 'fact' },
    { 'name' => 'FACT_ARTIST', 'row_count' => 166_000, 'measures' => %w[ARTIST_STREAMS], 'role' => 'fact' },
    {
      'name' => 'DIM_LABEL_SUMMARY', 'row_count' => 9_453,
      'grain_keys' => %w[COUNTRY_CODE LABEL], 'unique_on' => [%w[COUNTRY_CODE LABEL]],
      'role' => 'dimension', 'covers' => %w[FACT_LABEL FACT_ARTIST],
      'precomputed_fields' => %w[LTM_STREAMS NUM_ARTISTS], 'refresh' => 'monthly after artist/track load'
    }
  ]
}

puts 'Part A — a unique hub never becomes the fact'
plan = TargetModelPlan.build(object_plan, profiles: profiles)
ds = plan['datasources'][0]
check.call(ds['primary_fact'] == 'FACT_LABEL', "largest fact elected instead of DIM_COUNTRY (got #{ds['primary_fact']})")
check.call(ds['relationships'].all? { |rel| rel['carrier'].start_with?('FACT_') && rel['target'] == 'DIM_COUNTRY' },
           'both child facts carry many-to-one relationships into the unique country hub')
check.call(ds['shared_hub_candidates'].any? { |hub| hub['table'] == 'DIM_COUNTRY' },
           'existing unique country hub is recognized')
check.call(ds['shared_hub_candidates'].any? { |hub| hub['table'] == 'DIM_LABEL_SUMMARY' },
           'warehouse label-summary candidate is recognized')
summary_profile = profiles['tables'].find { |row| row['name'] == 'DIM_LABEL_SUMMARY' }
check.call(TargetModelPlan.unique_on?(summary_profile, %w[COUNTRY_CODE LABEL]),
           'declared composite unique_on proves the full composite key')
check.call(!TargetModelPlan.unique_on?(summary_profile, %w[COUNTRY_CODE]),
           'composite grain does not falsely prove uniqueness on a subset key')
check.call(plan['mode'] == 'source-faithful' && plan['accepted'] == true,
           'safe source-faithful topology is accepted automatically')

puts 'Part B — many-to-many fails closed and requires acceptance'
m2m = Marshal.load(Marshal.dump(object_plan))
m2m['datasources'][0]['relationships'][0].delete('first_db_unique')
m2m['datasources'][0]['relationships'][0]['first_unique_hint'] = false
m2m_profiles = { 'tables' => profiles['tables'].reject { |row| row['name'] == 'DIM_COUNTRY' } }
blocked = TargetModelPlan.build(m2m, profiles: m2m_profiles)
check.call(blocked['mode'] == 'remodeled-star' && blocked['accepted'] == false,
           'unsafe topology proposes remodeled-star but is not silently accepted')
check.call(blocked['required_proofs'].any? { |proof| proof['kind'] == 'target-uniqueness' },
           'unsafe relationship creates a target-uniqueness proof requirement')
begin
  TargetModelPlan.validate!(blocked)
  check.call(false, 'unaccepted remodel is rejected')
rescue TargetModelPlan::Error => e
  check.call(e.message.include?('not accepted'), 'unaccepted remodel is rejected')
end

puts 'Part C — table substitution requires equivalence and refresh lineage'
substitution_profiles = Marshal.load(Marshal.dump(profiles))
summary = substitution_profiles['tables'].find { |row| row['name'] == 'DIM_LABEL_SUMMARY' }
summary['equivalence_proof'] = {
  'match' => true,
  'before' => { 'total' => 100, 'distinct_grain' => 10, 'sums' => { 'STREAMS' => 500.0 } },
  'after' => { 'total' => 100, 'distinct_grain' => 10, 'sums' => { 'STREAMS' => 500.0 } },
  'grain' => %w[COUNTRY_CODE LABEL],
  'measures' => %w[STREAMS],
  'probed_at' => '2026-11-02T12:00:00Z'
}
substituted = TargetModelPlan.build(
  object_plan,
  profiles: substitution_profiles,
  table_map: { 'FACT_LABEL' => 'DIM_LABEL_SUMMARY' }
)
TargetModelPlan.accept!(substituted, accepted_by: 'test', reason: 'validated target architecture')
check.call(TargetModelPlan.validate!(substituted), 'proven substitution with refresh lineage validates')
semantic_entry = TargetModelPlan.semantic_edit_entries(substituted).first
check.call(semantic_entry['proof']['match'] == true &&
           semantic_entry['edit_description'].include?('FACT_LABEL→DIM_LABEL_SUMMARY'),
           'proven substitution is exported into the existing semantic-edits gate shape')
summary.delete('refresh')
no_refresh = TargetModelPlan.build(
  object_plan,
  profiles: substitution_profiles,
  table_map: { 'FACT_LABEL' => 'DIM_LABEL_SUMMARY' }
)
TargetModelPlan.accept!(no_refresh, accepted_by: 'test', reason: 'negative fixture')
begin
  TargetModelPlan.validate!(no_refresh)
  check.call(false, 'precomputed target without refresh lineage is rejected')
rescue TargetModelPlan::Error => e
  check.call(e.message.include?('refresh lineage'), 'precomputed target without refresh lineage is rejected')
end

puts 'Part D — prior live join probes become cardinality evidence'
probe_graph = Marshal.load(Marshal.dump(m2m))
probe_plan = {
  'entries' => [{
    'left' => 'FACT_LABEL', 'right' => 'DIM_COUNTRY', 'status' => 'unique',
    'keys' => %w[COUNTRY_CODE]
  }]
}
with_probe = TargetModelPlan.build(probe_graph, profiles: m2m_profiles, join_plan: probe_plan)
probed_relation = with_probe['datasources'][0]['relationships'].first
check.call(probed_relation['cardinality'] == 'many-to-one' &&
           probed_relation['carrier'] == 'FACT_LABEL' &&
           probed_relation['target'] == 'DIM_COUNTRY',
           'join-plan status=unique orients the probed target many-to-one')

puts 'Part E — composite grains do not prove prefix uniqueness'
composite_profile = {
  'grain_keys' => %w[COUNTRY_CODE LABEL],
  'unique_on' => [%w[COUNTRY_CODE LABEL]]
}
check.call(!TargetModelPlan.unique_on?(composite_profile, %w[COUNTRY_CODE]),
           'a composite unique key does not make each component unique')
check.call(TargetModelPlan.unique_on?(composite_profile, %w[COUNTRY_CODE LABEL]),
           'the complete composite key remains unique')
check.call(!TargetModelPlan.unique_on?({ 'grain_keys' => %w[COUNTRY_CODE LABEL] }, %w[COUNTRY_CODE LABEL]),
           'grain documentation alone is not uniqueness evidence')

puts 'Part F — one-to-one orientation follows the elected fact, not XML order'
one_to_one_profiles = {
  'tables' => [
    { 'name' => 'FACT_ACCOUNT', 'unique_on' => [%w[ACCOUNT_ID]], 'role' => 'fact' },
    { 'name' => 'DIM_ACCOUNT', 'unique_on' => [%w[ACCOUNT_ID]], 'role' => 'dimension' }
  ]
}
one_to_one_plans = [%w[FACT_ACCOUNT DIM_ACCOUNT], %w[DIM_ACCOUNT FACT_ACCOUNT]].map do |first, second|
  TargetModelPlan.build(
    {
      'datasources' => [{
        'datasource' => 'accounts',
        'objects' => %w[FACT_ACCOUNT DIM_ACCOUNT],
        'fact_candidate' => 'FACT_ACCOUNT',
        'relationships' => [{
          'first' => first, 'second' => second, 'status' => 'wired',
          'keys' => [['ACCOUNT_ID', 'ACCOUNT_ID']]
        }]
      }]
    },
    profiles: one_to_one_profiles
  )
end
check.call(one_to_one_plans.all? do |candidate|
  relationship = candidate['datasources'][0]['relationships'][0]
  relationship['carrier'] == 'FACT_ACCOUNT' && relationship['target'] == 'DIM_ACCOUNT'
end, 'dual-unique relationship is fact-to-dimension in either XML endpoint order')

puts 'Part G — converter options keep datasource facts in the model plan'
converter_options = TargetModelPlan.converter_options(one_to_one_plans.first)
check.call(!converter_options.key?('fact_table') && converter_options['model_plan'] == one_to_one_plans.first,
           'per-datasource primary facts are not promoted to a global factTable override')

puts
if fails.empty?
  puts 'all target-model plan tests passed'
else
  warn "#{fails.size} failure(s): #{fails.join('; ')}"
  exit 1
end
