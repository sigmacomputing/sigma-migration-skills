#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/relationship_coverage'

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

metadata = lambda do |entries|
  {
    'relationshipCoverage' => {
      'serialized' => entries.length,
      'wired' => entries.count { |entry| entry['derivedVia'] != 'unwired' },
      'entries' => entries
    }
  }
end

puts 'test-relationship-coverage-gate'

single = '<object-graph><objects><object id="one"/></objects></object-graph>'
check.call(RelationshipCoverage.evaluate({}, source_text: single)['status'] == 'not-applicable',
           'one parsed object with no relationships needs no relationship ledger')
check.call(RelationshipCoverage.evaluate({}, source_text: single.sub('<object id="one"/>', '<object id="one"/><object id="two"/>'))['status'] == 'fail',
           'multiple objects without coverage still fail')
check.call(RelationshipCoverage.evaluate({}, source_text: single.sub('</object-graph>', '<relationships><relationship/></relationships></object-graph>'))['status'] == 'fail',
           'a source edge without coverage still fails')

result = RelationshipCoverage.evaluate({}, source_text: '<workbook/>')
check.call(result['status'] == 'not-applicable',
           'non-object-graph source without a ledger is not applicable')

result = RelationshipCoverage.evaluate({}, source_text: '<object-graph/>')
check.call(result['status'] == 'fail' &&
           result.dig('blockers', 0, 'kind') == 'coverage-missing',
           'object-graph source without converter coverage fails')

result = RelationshipCoverage.evaluate(metadata.call([
  { 'left' => 'FACT', 'right' => 'DIM', 'derivedVia' => 'serialized', 'keyCount' => 1 }
]))
check.call(result['status'] == 'pass' && result['blockers'].empty?,
           'fully wired relationship coverage passes')

result = RelationshipCoverage.evaluate(metadata.call([
  { 'left' => 'FACT', 'right' => 'DIM_A', 'derivedVia' => 'unwired', 'reason' => 'no key' },
  { 'left' => 'FACT', 'right' => 'DIM_B', 'derivedVia' => 'serialized',
    'partial' => true, 'droppedConditions' => 1 }
]))
check.call(result['status'] == 'fail' &&
           result['blockers'].map { |row| row['kind'] } == %w[unwired partial],
           'unwired and partial relationships both block')

complete_meta = metadata.call([
  { 'left' => 'FACT', 'right' => 'DIM', 'derivedVia' => 'serialized', 'keyCount' => 1 }
])
result = RelationshipCoverage.evaluate(
  complete_meta, source_text: '<object-graph/>',
  model: { 'pages' => [{ 'elements' => [] }] }
)
check.call(result['status'] == 'fail' &&
           result['blockers'].any? { |row| row['kind'] == 'model-count-mismatch' },
           'a source relationship missing from the data-model spec/readback blocks')
result = RelationshipCoverage.evaluate(
  complete_meta, source_text: '<object-graph/>',
  model: {
    'pages' => [{ 'elements' => [{
      'relationships' => [{
        'targetElementId' => 'dim',
        'keys' => [{ 'sourceColumnId' => 'fact-key', 'targetColumnId' => 'dim-key' }]
      }]
    }] }]
  }
)
check.call(result['status'] == 'pass',
           'matching data-model relationship count with non-empty keys passes')

generated_meta = complete_meta.merge(
  'sqlProvenance' => [{
    'elementId' => 'window-helper',
    'originType' => 'generated-window'
  }]
)
result = RelationshipCoverage.evaluate(
  generated_meta, source_text: '<object-graph/>',
  model: {
    'pages' => [{ 'elements' => [{
      'relationships' => [
        {
          'targetElementId' => 'dim',
          'keys' => [{ 'sourceColumnId' => 'fact-key', 'targetColumnId' => 'dim-key' }]
        },
        {
          'targetElementId' => 'window-helper',
          'keys' => [{ 'sourceColumnId' => 'fact-key', 'targetColumnId' => 'window-key' }]
        }
      ]
    }] }]
  }
)
check.call(result['status'] == 'pass' &&
           result['model_relationships'] == 1 &&
           result['generated_model_relationships_excluded'] == 1,
           'generated helper relationships are excluded from source relationship coverage')

# computed-key (converter/tableau.mjs computed-key rung): a relationship keyed
# on a calculated join-key column carried Tableau's whole condition, so it is
# wired like a serialized one; only a dropped condition makes it block.
computed_meta = metadata.call([
  { 'left' => 'ORDER_FACT', 'right' => 'DIM_TIME', 'derivedVia' => 'computed-key', 'keyCount' => 1 }
])
result = RelationshipCoverage.evaluate(computed_meta)
check.call(result['status'] == 'pass' && result['wired'] == 1 &&
           result.dig('entries', 0, 'derived_via') == 'computed-key',
           'computed-key relationship coverage passes and keeps its disposition')
result = RelationshipCoverage.evaluate(metadata.call([
  { 'left' => 'FACT', 'right' => 'DIM', 'derivedVia' => 'computed-key', 'keyCount' => 1,
    'partial' => true, 'droppedConditions' => 1 }
]))
check.call(result['status'] == 'fail' && result['blockers'].map { |row| row['kind'] } == %w[partial],
           'a computed-key relationship that still dropped a condition blocks as partial')
# verify-complete re-derives coverage against dm-readback.json, where
# post-and-readback.rb has already stripped derivedVia: the computed-key edge
# must still count as the one data-model relationship for the one source edge.
result = RelationshipCoverage.evaluate(
  computed_meta, source_text: '<object-graph/>',
  model: {
    'pages' => [{ 'elements' => [{
      'relationships' => [{
        'targetElementId' => 'dim-time',
        'keys' => [{ 'sourceColumnId' => 'order-date-join-key', 'targetColumnId' => 'date-key' }]
      }]
    }] }]
  }
)
check.call(result['status'] == 'pass' && result['model_relationships'] == 1,
           'computed-key coverage matches a readback relationship with its provenance fields stripped')

# ---- reused-DM evidence route (relationship-map.json) ----------------------
require 'open3'
require 'tmpdir'
require_relative 'test-fixtures/relationship-map/workdir_helper'
assert_cli = lambda do |work|
  Open3.capture3('ruby', File.join(__dir__, 'assert-relationship-coverage.rb'), '--workdir', work)
end
Dir.mktmpdir('relcov-route') do |work|
  RelationshipMapWorkdir.build(work, 'replaced-key', parity: ['Revenue by Customer'])
  out, err, st = assert_cli.call(work)
  check.call(st.success? && out.include?('PASS (reused-dm evidence) — 1 matched, 1 replaced, 0 dropped, 0 disconnected, 0 extra (all verified)'),
             "evidence route: proven replaced edge passes the gate (exit #{st.exitstatus}: #{(out + err).strip.lines.last})")
end
Dir.mktmpdir('relcov-route') do |work|
  RelationshipMapWorkdir.build(work, 'replaced-key', probe: false, parity: ['Revenue by Customer'])
  _, err, st = assert_cli.call(work)
  check.call(st.exitstatus == 3 && err.include?('unprobed'), "evidence route: an unprobed edge blocks with exit 3 (got #{st.exitstatus})")
end
Dir.mktmpdir('relcov-route') do |work|
  RelationshipMapWorkdir.build(work, 'replaced-key', parity: ['Revenue by Customer'])
  File.delete(File.join(work, 'relationship-map.json'))
  _, err, st = assert_cli.call(work)
  check.call(st.exitstatus == 3 && err.include?('relationship-map.json'), "evidence route: a missing map blocks (got #{st.exitstatus})")
end
Dir.mktmpdir('relcov-route') do |work|
  # A hand-placed map does not switch the rule: without the persisted route the
  # strict object-graph check runs (and fails on its missing artifact).
  RelationshipMapWorkdir.build(work, 'replaced-key', parity: ['Revenue by Customer'], route: false)
  _, err, st = assert_cli.call(work)
  check.call(st.exitstatus == 3 && err.include?('relationship-coverage.json is missing'),
             "a map without the persisted route is ignored: strict rule (got #{st.exitstatus}: #{err.strip.lines.first})")
end

if fails.empty?
  puts 'ALL PASS'
  exit 0
end

warn "#{fails.length} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
