#!/usr/bin/env ruby
# A Tableau source-field ref must resolve to an EMITTED Sigma column, or to
# nothing at all. A guessed columnId ships a schema-valid action that silently
# sets the control to the wrong value.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_column_resolver'

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MMAP = { '(?i)^region$' => { 'name' => 'Region' },
         '(?i)^metric button$' => { 'name' => 'Metric Button' } }.freeze
GUIDS = { 'Calculation_100' => { 'caption' => 'Metric Button' } }.freeze

puts '== Plain federated refs ================================================='
check(ActionColumnResolver.resolve(ref: '[federated.abc].[none:Region:nk]',
                                   mmap: MMAP, columns_by_guid: {}) == 'Region',
      'a none:X:nk qualified federated ref resolves to the mapped column')
check(ActionColumnResolver.resolve(ref: '[Region]', mmap: MMAP, columns_by_guid: {}) == 'Region',
      'a bare bracketed ref resolves')

puts '== Calc refs resolve through columns_by_guid ============================'
check(ActionColumnResolver.resolve(ref: '[federated.f1].[none:Calculation_100:nk]',
                                   mmap: MMAP, columns_by_guid: GUIDS) == 'Metric Button',
      'an internal Calculation_NNN name resolves via columns_by_guid, then the master map')

puts '== Unresolvable refs return nil, never a guess =========================='
check(ActionColumnResolver.resolve(ref: '[federated.f1].[none:Unmapped:nk]',
                                   mmap: MMAP, columns_by_guid: {}).nil?,
      'a field with no master-map entry resolves to nil')
check(ActionColumnResolver.resolve(ref: nil, mmap: MMAP, columns_by_guid: {}).nil?,
      'a nil ref resolves to nil')
check(ActionColumnResolver.resolve(ref: '', mmap: MMAP, columns_by_guid: {}).nil?,
      'an empty ref resolves to nil')

puts '== Degradation: flat-String columns_by_guid does not raise ============='
flat_guids = { 'Calculation_100' => 'Metric Button' }
result = ActionColumnResolver.resolve(ref: '[federated.f1].[none:Calculation_100:nk]',
                                      mmap: MMAP, columns_by_guid: flat_guids)
check(result.nil? || result == 'Calculation_100',
      'flat-String columns_by_guid value degrades to nil or the inner name')

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
