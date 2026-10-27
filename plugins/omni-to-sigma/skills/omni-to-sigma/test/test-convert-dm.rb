#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for OmniModel and convert-dm.rb (view/topic extends, aliases,
# workbookModel merge, recursive join trees, topic fields: curation, compound
# join keys, filtered measures, groups, and bins).
#
#   ruby test/test-convert-dm.rb

require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../scripts/convert-dm'

$failures = 0
def eq(a, b, m)
  if a == b
    puts "  ok: #{m}"
  else
    $failures += 1
    puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}"
  end
end

puts '== OmniModel: view extends, topic extends, aliases, fields curation, and workbookModel =='
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'base_events.view'), <<~YAML)
    schema: analytics
    table_name: events
    dimensions:
      id:
        primary_key: true
        sql: '"ID"'
        tags: [core]
      org_id:
        sql: '"ORG_ID"'
        tags: [core]
      event_type:
        sql: '"EVENT_TYPE"'
        aliases: [old_event_type]
        tags: [core]
      secret_token:
        sql: '"SECRET_TOKEN"'
        tags: [pii]
    measures:
      event_count:
        aggregate_type: count
        label: Event Count
        tags: [core]
  YAML

  File.write(File.join(dir, 'product_events.view'), <<~YAML)
    extends: [base_events]
    aliases: [legacy_events]
    dimensions:
      tier_group:
        label: Tier Group
        sql: '"TIER"'
        groups:
          - name: Enterprise
            filter:
              is: [ENT, VIP]
        else: Standard
        tags: [core]
      latency_bucket:
        label: Latency Bucket
        sql: '"LATENCY_MS"'
        bin_boundaries: [100, 500]
        tags: [core]
    measures:
      error_events:
        label: Error Events
        aggregate_type: count
        filters:
          event_type:
            is: ERROR
        tags: [core]
      error_rate:
        label: Error Rate
        sql: ${legacy_events.error_events} / nullif(${product_events.event_count}, 0)
        format: percent_1
        tags: [core]
  YAML

  File.write(File.join(dir, 'orgs.view'), <<~YAML)
    schema: analytics
    table_name: organizations
    dimensions:
      id:
        primary_key: true
        sql: '"ID"'
        tags: [core]
      org_name:
        label: Org Name
        sql: '"ORG_NAME"'
        tags: [core]
      internal_notes:
        sql: '"INTERNAL_NOTES"'
        tags: [pii]
  YAML

  File.write(File.join(dir, 'relationships.yaml'), <<~YAML)
    - join_from_view: product_events
      join_to_view: orgs
      join_type: always_left
      on_sql: ${product_events.org_id} = ${orgs.id} AND ${product_events.id} = ${orgs.id}
      relationship_type: many_to_one
  YAML

  File.write(File.join(dir, 'base_events.topic'), <<~YAML)
    base_view: product_events
    label: Product Events
    joins:
      orgs: {}
  YAML

  File.write(File.join(dir, 'curated_events.topic'), <<~YAML)
    extends: [base_events]
    label: Curated Events
    fields:
      - all_views.*
      - -tag:pii
  YAML

  model = OmniModel.load(dir)
  pe = model['views']['product_events']
  eq(pe['table_name'], 'events', 'child view inherits table_name from extended base_events')
  eq(pe['dimensions'].key?('id'), true, 'child view inherits dimensions from extended base_events')
  eq(pe['dimensions'].key?('tier_group'), true, 'child view retains its own dimensions')
  eq(OmniModel.resolve_alias(model, 'legacy_events', 'old_event_type'),
     %w[product_events event_type],
     'resolve_alias resolves both view aliases and field aliases')

  wb_model = {
    'dimensions' => {
      'product_events.custom_wb_dim' => {
        'label' => 'Custom WB Dim',
        'sql' => "UPPER(${product_events.old_event_type})",
        'tags' => ['core']
      }
    }
  }
  OmniModel.merge_workbook_model!(model, wb_model)

  envelope, sig, explore = build(model, 'curated_events', 'conn-123', 'folder-456')
  dm = envelope['sigmaDataModel']
  eq(dm['name'], 'Curated Events (Omni)', 'DM name uses extended topic label')
  eq(envelope['stats']['relationships'], 1, 'compound AND relationship converted')

  pe_el = dm['pages'].first['elements'].find { |e| e['id'] == 'el-product_events' }
  rel = pe_el['relationships'].first
  eq(rel['keys'].length, 2, 'compound on_sql produces 2 join key pairs')

  col_names = explore['columns'].map { |c| c['name'] }
  eq(col_names.include?('Secret Token'), false, 'fields: [-tag:pii] excludes pii dimension on base view')
  eq(col_names.include?('Internal Notes'), false, 'fields: [-tag:pii] excludes pii dimension on joined view')
  eq(col_names.include?('Tier Group'), true, 'core dimension Tier Group is included in curated explore')
  eq(col_names.include?('Latency Bucket'), true, 'core dimension Latency Bucket is included in curated explore')
  eq(col_names.include?('Custom WB Dim'), true, 'workbookModel dimension merged and included')

  tier_col = pe_el['columns'].find { |c| c['name'] == 'Tier Group' }
  eq(tier_col['formula'],
     'If(In([EVENTS/Tier Group], "ENT", "VIP"), "Enterprise", "Standard")',
     'groups dimension compiled on warehouse table element')

  bin_col = pe_el['columns'].find { |c| c['name'] == 'Latency Bucket' }
  eq(bin_col['formula'],
     'If([EVENTS/Latency Bucket] < 100, "< 100", [EVENTS/Latency Bucket] < 500, ">= 100 and < 500", "500 and above")',
     'bin_boundaries dimension compiled on warehouse table element')

  wb_col = pe_el['columns'].find { |c| c['name'] == 'Custom WB Dim' }
  eq(wb_col['formula'], 'Upper([Event Type])', 'workbookModel dimension resolved field alias old_event_type -> Event Type')

  err_metric = explore['metrics'].find { |m| m['name'] == 'Error Events' }
  eq(err_metric['formula'], 'CountIf([Event Type] = "ERROR")', 'filtered count measure compiled to CountIf')

  rate_metric = explore['metrics'].find { |m| m['name'] == 'Error Rate' }
  eq(rate_metric['formula'], '(CountIf([Event Type] = "ERROR")) / NullIf((Count()), 0)',
     'ratio measure resolved view alias legacy_events and nested filtered measure')
  eq(sig['measures'], ['Event Count', 'Error Events', 'Error Rate'], 'reuse signature captures curated measures')
end

if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
