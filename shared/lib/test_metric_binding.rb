#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test for metric_binding.rb. Run: ruby shared/lib/test_metric_binding.rb
#
# Kept in lockstep with shared/lib/test_metric_binding.py — same cases, same
# semantics (this is the Ruby mirror of the shared binder).

require_relative 'metric_binding'

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "  [ok] #{desc}" : "  [FAIL] #{desc}")
  $failures += 1 unless ok
end

METRICS = [
  { 'name' => 'Net Revenue', 'formula' => 'Sum([Net Revenue])' },
  { 'name' => 'Orders', 'formula' => 'CountDistinct([Order Id])' }
].freeze

# --- metric_ref_or_inline ---------------------------------------------------
check('matched aggregate binds to metric') do
  MetricBinding.metric_ref_or_inline('Sum([Data/Net Revenue])', 'Data', METRICS) == '[Metrics/Net Revenue]' &&
    MetricBinding.metric_ref_or_inline('CountDistinct([Data/Order Id])', 'Data', METRICS) == '[Metrics/Orders]'
end

check('whitespace-insensitive match') do
  MetricBinding.metric_ref_or_inline('Sum( [Data/Net Revenue] )', 'Data', METRICS) == '[Metrics/Net Revenue]'
end

check('strips EVERY master prefix (gsub, not sub)') do
  mets = [{ 'name' => 'AOV', 'formula' => 'Sum([Net Revenue]) / Sum([Order Id])' }]
  MetricBinding.metric_ref_or_inline('Sum([Data/Net Revenue]) / Sum([Data/Order Id])', 'Data', mets) == '[Metrics/AOV]'
end

check('ratio without a matching metric falls back to inline') do
  inline = '1.0 * Sum([Data/Net Revenue]) / Count([Data/Order Id])'
  MetricBinding.metric_ref_or_inline(inline, 'Data', METRICS) == inline
end

check('non-matching metric ignored (no false positive)') do
  mets = [{ 'name' => 'Unrelated', 'formula' => 'Sum([Something Else])' }]
  MetricBinding.metric_ref_or_inline('Sum([Data/Net Revenue])', 'Data', mets) == 'Sum([Data/Net Revenue])'
end

check('empty / nil metrics is a no-op') do
  MetricBinding.metric_ref_or_inline('Sum([Data/x])', 'Data', []) == 'Sum([Data/x])' &&
    MetricBinding.metric_ref_or_inline('Sum([Data/x])', 'Data', nil) == 'Sum([Data/x])'
end

check('non-string inline passes through') do
  MetricBinding.metric_ref_or_inline(nil, 'Data', METRICS).nil? &&
    MetricBinding.metric_ref_or_inline(42, 'Data', METRICS) == 42
end

check('metric missing name/formula is skipped') do
  mets = [{ 'name' => 'NoFormula' }, { 'formula' => 'Sum([Data/x])' },
          { 'name' => 'Good', 'formula' => 'Sum([x])' }]
  MetricBinding.metric_ref_or_inline('Sum([Data/x])', 'Data', mets) == '[Metrics/Good]'
end

# --- available_metrics ------------------------------------------------------
check('own metrics') do
  els = { 'a' => { 'metrics' => [{ 'name' => 'M1', 'formula' => 'Sum([x])' }] } }
  MetricBinding.available_metrics('a', els) == [{ 'name' => 'M1', 'formula' => 'Sum([x])' }]
end

check('inherited via source.elementId chain') do
  els = {
    'view' => { 'metrics' => [], 'source' => { 'elementId' => 'fact' } },
    'fact' => { 'metrics' => [{ 'name' => 'Net Revenue', 'formula' => 'Sum([Net Revenue])' }] }
  }
  MetricBinding.available_metrics('view', els) == [{ 'name' => 'Net Revenue', 'formula' => 'Sum([Net Revenue])' }]
end

check('nearest wins on name collision') do
  els = {
    'view' => { 'metrics' => [{ 'name' => 'M', 'formula' => 'OWN' }], 'source' => { 'elementId' => 'fact' } },
    'fact' => { 'metrics' => [{ 'name' => 'M', 'formula' => 'INHERITED' }] }
  }
  MetricBinding.available_metrics('view', els) == [{ 'name' => 'M', 'formula' => 'OWN' }]
end

check('skips metrics missing fields') do
  els = { 'a' => { 'metrics' => [{ 'name' => 'OnlyName' }, { 'formula' => 'OnlyFormula' },
                                  { 'name' => 'Ok', 'formula' => 'Sum([x])' }] } }
  MetricBinding.available_metrics('a', els) == [{ 'name' => 'Ok', 'formula' => 'Sum([x])' }]
end

check('cycle-safe') do
  els = { 'a' => { 'metrics' => [{ 'name' => 'A', 'formula' => 'f' }], 'source' => { 'elementId' => 'b' } },
          'b' => { 'metrics' => [{ 'name' => 'B', 'formula' => 'g' }], 'source' => { 'elementId' => 'a' } } }
  MetricBinding.available_metrics('a', els).map { |m| m['name'] } == %w[A B]
end

check('missing element and nil id return empty') do
  MetricBinding.available_metrics('nope', { 'a' => {} }) == [] &&
    MetricBinding.available_metrics(nil, { 'a' => {} }) == []
end

# --- column_metric_collisions / collision_exclusions (F4 collision shape) ---
check('clean element: no collisions (different names, non-hash input)') do
  el = { 'columns' => [{ 'name' => 'Carton Count' }],
         'metrics' => [{ 'name' => 'Total Cartons', 'formula' => 'Sum([Carton Count])' }] }
  MetricBinding.column_metric_collisions(el) == [] &&
    MetricBinding.column_metric_collisions(nil) == [] &&
    MetricBinding.column_metric_collisions('not an element') == []
end

check('same-element column/metric name pair collides (exact names only)') do
  el = { 'columns' => [{ 'name' => 'Freight Cost' }, { 'name' => 'Lane' }],
         'metrics' => [{ 'name' => 'Freight Cost', 'formula' => 'Sum([Freight Cost])' }] }
  MetricBinding.column_metric_collisions(el) == ['Freight Cost'] &&
    MetricBinding.column_metric_collisions(
      'columns' => [{ 'name' => 'freight cost' }],
      'metrics' => [{ 'name' => 'Freight Cost', 'formula' => 'x' }]
    ) == []
end

check('formula-less metric still collides (the POSTed shape is what live drops on)') do
  el = { 'columns' => [{ 'name' => 'Pallet Count' }], 'metrics' => [{ 'name' => 'Pallet Count' }] }
  MetricBinding.column_metric_collisions(el) == ['Pallet Count']
end

check('collision-shaped element contributes NO metrics — even non-colliding names') do
  els = { 'fact' => {
    'columns' => [{ 'name' => 'Freight Cost' }, { 'name' => 'Shipment Id' }],
    'metrics' => [{ 'name' => 'Freight Cost', 'formula' => 'Sum([Freight Cost])' },
                  { 'name' => 'Fill Rate Pct', 'formula' => 'Sum([Filled Lines]) / Count([Order Lines])' }]
  } }
  MetricBinding.available_metrics('fact', els) == []
end

check('collision_exclusions reports the withheld chain element + names') do
  els = { 'view' => { 'source' => { 'elementId' => 'fact' } },
          'fact' => { 'name' => 'Freight Fact',
                      'columns' => [{ 'name' => 'Freight Cost' }],
                      'metrics' => [{ 'name' => 'Freight Cost', 'formula' => 'Sum([Freight Cost])' },
                                    { 'name' => 'Fill Rate Pct', 'formula' => 'Sum([Filled Lines]) / Count([Order Lines])' }] } }
  ex = MetricBinding.collision_exclusions('view', els)
  ex.size == 1 && ex[0]['element_id'] == 'fact' && ex[0]['element_name'] == 'Freight Fact' &&
    ex[0]['collisions'] == ['Freight Cost'] &&
    ex[0]['excluded_metrics'] == ['Freight Cost', 'Fill Rate Pct'] &&
    MetricBinding.available_metrics('view', els) == [] &&
    MetricBinding.collision_exclusions('solo', 'solo' => { 'metrics' => [{ 'name' => 'M', 'formula' => 'f' }] }) == []
end

check('unnamed collision-shaped element: audit label falls back to the element ID') do
  # Converter-model BASE elements carry no 'name' key (field-caught: the run
  # NOTE + decision ledger otherwise render "DM element ''"). Blank '' too.
  els = { 'view' => { 'source' => { 'elementId' => 'el-77fq02' } },
          'el-77fq02' => { 'columns' => [{ 'name' => 'Freight Cost' }],
                           'metrics' => [{ 'name' => 'Freight Cost', 'formula' => 'Sum([Freight Cost])' }] } }
  ex = MetricBinding.collision_exclusions('view', els)
  blank = MetricBinding.collision_exclusions(
    'b1', 'b1' => { 'name' => '', 'columns' => [{ 'name' => 'Lane' }], 'metrics' => [{ 'name' => 'Lane' }] })
  ex.size == 1 && ex[0]['element_id'] == 'el-77fq02' && ex[0]['element_name'] == 'el-77fq02' &&
    blank.size == 1 && blank[0]['element_name'] == 'b1'
end

check('clean chain element still contributes past a collision-shaped one') do
  els = { 'view' => { 'metrics' => [{ 'name' => 'Depot Count', 'formula' => 'CountDistinct([Depot])' }],
                      'source' => { 'elementId' => 'fact' } },
          'fact' => { 'columns' => [{ 'name' => 'Freight Cost' }],
                      'metrics' => [{ 'name' => 'Freight Cost', 'formula' => 'Sum([Freight Cost])' }] } }
  MetricBinding.available_metrics('view', els) ==
    [{ 'name' => 'Depot Count', 'formula' => 'CountDistinct([Depot])' }]
end

puts($failures.zero? ? 'ALL PASS' : "#{$failures} FAILURE(S)")
exit($failures.zero? ? 0 : 1)
