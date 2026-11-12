#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'mechanical-specs'

class FieldMetricDependenciesTest < Minitest::Test
  def model(metrics)
    { 'pages' => [{ 'elements' => [{ 'id' => 'fact', 'name' => 'Fact', 'kind' => 'table',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SC FACT] },
      'columns' => [{ 'id' => 'inode/RAW_AMOUNT' }, { 'id' => 'inode/UNITS', 'name' => 'Units' },
                    { 'id' => 'row', 'name' => 'Row Calc', 'formula' => '[Sum Amount] * 2' }],
      'metrics' => metrics.map.with_index { |(name, formula), i| { 'id' => "metric-#{i}", 'name' => name, 'formula' => formula } }
    }] }] }
  end

  def test_source_names_and_metric_dependencies_survive_fixup
    data = model('Scaled' => '[Ratio] * 100', 'Ratio' => '[Sum Amount] / [Sum Units]',
                 'Sum Amount' => 'Sum([RAW_AMOUNT])', 'Sum Units' => 'Sum([Units])',
                 'Literal' => 'If("[Ratio]" = "x", [Sum Amount], 0)')
    MechanicalSpecs.fixup_dm_spec(data)
    element = data['pages'][0]['elements'][0]
    assert_equal 'RAW_AMOUNT', element['columns'][0]['name']
    metrics = element['metrics'].to_h { |metric| [metric['name'], metric['formula']] }
    assert_equal '((Sum([RAW_AMOUNT])) / (Sum([Units]))) * 100', metrics['Scaled']
    assert_equal 'If("[Ratio]" = "x", (Sum([RAW_AMOUNT])), 0)', metrics['Literal']
    assert_equal '[Sum Amount] * 2', element['columns'].find { |column| column['id'] == 'row' }['formula']
  end

  def test_cycles_fail_and_real_column_names_are_not_expanded
    assert_raises(StandardError) { MechanicalSpecs.fixup_dm_spec(model('A' => '[B]', 'B' => '[A]')) }
    data = model('Units' => 'Sum([Units])')
    MechanicalSpecs.fixup_dm_spec(data)
    assert_equal 'Sum([Units])', data['pages'][0]['elements'][0]['metrics'][0]['formula']
  end

  def test_physical_name_stamp_cannot_create_a_duplicate_label
    data = model({})
    data['pages'][0]['elements'][0]['columns'] << { 'id' => 'calc', 'name' => 'raw_amount', 'formula' => '[Units] * 2' }
    error = assert_raises(ArgumentError) { MechanicalSpecs.fixup_dm_spec(data) }
    assert_match(/collid/, error.message)
  end

  def test_dependents_of_a_refused_metric_are_not_left_dangling
    data = model('Bad' => 'Sum([01234567-89ab-cdef-0123-456789abcdef])',
                 'Ratio' => '[Bad] / [Sum Units]', 'Nested' => '[Ratio] * 100',
                 'Sum Units' => 'Sum([Units])', 'Literal' => 'If("[Bad]" = "x", 1, 0)')
    result = MechanicalSpecs.fixup_dm_spec(data)
    assert_equal %w[Bad Nested Ratio], result[:dropped].sort
    assert_equal ['Sum Units', 'Literal'], data['pages'][0]['elements'][0]['metrics'].map { |metric| metric['name'] }
  end
end
