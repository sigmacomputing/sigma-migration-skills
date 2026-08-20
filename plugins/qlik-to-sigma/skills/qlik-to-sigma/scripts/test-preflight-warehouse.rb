#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'preflight-warehouse'

failures = []
check = lambda do |condition, message|
  failures << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

reconcile = [{
  'qlikTable' => 'CountryFacts', 'sourceTable' => 'country_sales',
  'fields' => [
    { 'qlikField' => 'COUNTRY', 'realColumn' => 'country', 'isExpression' => false },
    { 'qlikField' => 'SALES', 'realColumn' => 'sales', 'isExpression' => false },
    { 'qlikField' => 'REGION_GROUP', 'realColumn' => "If(Match(COUNTRY, 'US'), 'North America', 'Other')",
      'loadExpression' => "If(Match(COUNTRY, 'US'), 'North America', 'Other')",
      'expressionColumns' => ['COUNTRY'], 'isExpression' => true }
  ]
}]
paths = [{ 'connectionId' => 'conn-1', 'path' => %w[ANALYTICS PUBLIC COUNTRY_SALES] }]
lookup_calls = []
lookup = lambda do |connection, path|
  lookup_calls << [connection, path]
  { 'inodeId' => 'inode-country', 'kind' => 'table' }
end
columns = lambda do |inode|
  check.call(inode == 'inode-country', 'columns endpoint receives the lookup inode')
  [{ 'name' => 'COUNTRY' }, { 'name' => 'SALES' }]
end

resolved, report = preflight_tables(
  reconcile, connection_id: 'conn-1', database: 'analytics', schema: 'public',
  catalog_paths: paths, lookup: lookup, list_columns: columns
)
check.call(report['errors'].empty?, 'all required physical and calculated-field inputs resolve')
check.call(lookup_calls == [['conn-1', %w[ANALYTICS PUBLIC COUNTRY_SALES]]],
           'connection path inventory canonicalizes case before lookup')
check.call(resolved[0]['sourceTable'] == 'ANALYTICS.PUBLIC.COUNTRY_SALES',
           'resolved reconcile stores the canonical warehouse path')
check.call(resolved[0]['warehouseColumns'] == { 'COUNTRY' => 'COUNTRY', 'SALES' => 'SALES' },
           'resolved reconcile carries exact REST-discovered column names')

aliased = JSON.parse(JSON.generate(reconcile))
aliased[0]['fields'][0]['realColumn'] = 'RAW_COUNTRY'
resolved_alias, report_alias = preflight_tables(
  aliased, connection_id: 'conn-1', database: 'ANALYTICS', schema: 'PUBLIC',
  catalog_paths: paths, lookup: lookup,
  list_columns: ->(_inode) { [{ 'name' => 'RAW_COUNTRY' }, { 'name' => 'SALES' }] }
)
check.call(report_alias['errors'].empty? &&
           resolved_alias[0]['fields'][2]['expressionColumnsResolved'] == ['RAW_COUNTRY'],
           'a calculated field may reference a Qlik alias mapped to a differently named physical column')

_resolved_missing, report_missing = preflight_tables(
  reconcile, connection_id: 'conn-1', database: 'ANALYTICS', schema: 'PUBLIC',
  catalog_paths: paths, lookup: lookup, list_columns: ->(_inode) { [{ 'name' => 'SALES' }] }
)
check.call(report_missing['errors'].any? { |error| error.include?('COUNTRY') },
           'a base column used only inside a LOAD expression is still required')

ambiguous_paths = paths + [{ 'connectionId' => 'conn-1', 'path' => %w[OTHER PUBLIC COUNTRY_SALES] }]
_resolved_ambiguous, report_ambiguous = preflight_tables(
  reconcile, connection_id: 'conn-1', database: 'UNKNOWN', schema: 'PUBLIC',
  catalog_paths: ambiguous_paths, lookup: lookup, list_columns: columns
)
check.call(report_ambiguous['errors'].any? { |error| error.include?('ambiguous') },
           'multiple same-name tables are rejected instead of guessed')

if failures.empty?
  puts 'test-preflight-warehouse.rb: ALL PASS'
else
  warn "test-preflight-warehouse.rb: #{failures.size} FAILURE(S)"
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end
