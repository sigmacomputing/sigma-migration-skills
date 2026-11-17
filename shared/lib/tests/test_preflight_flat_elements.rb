require 'minitest/autorun'
require_relative '../preflight_lint'

class TestPreflightFlatElements < Minitest::Test
  def test_lint_reads_flat_workbook_elements
    spec = {
      'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
      'elements' => [{
        'id' => 't1', 'kind' => 'table', 'name' => 'Summary',
        'columns' => [
          { 'id' => 'd', 'name' => 'Region', 'formula' => '[Source/Region]' },
          { 'id' => 'm', 'name' => 'Revenue', 'formula' => 'Sum([Source/Revenue])' }
        ]
      }],
      'layout' => '<Page id="p1"><Element elementId="t1"/></Page>'
    }

    assert lint(spec).any? { |message| message.start_with?('T1 ') }
  end

  def test_legend_and_drill_are_known_control_types
    controls = %w[legend drill].map do |control_type|
      { 'id' => "el-#{control_type}", 'kind' => 'control',
        'controlId' => "ctl-#{control_type}", 'controlType' => control_type }
    end
    spec = {
      'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
      'elements' => controls,
      'layout' => '<Page id="p1"><Element elementId="el-legend"/><Element elementId="el-drill"/></Page>'
    }

    refute lint(spec).any? { |message| message.start_with?('C6 ') }
  end

  def t2_spec(calc_formula)
    {
      'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
      'elements' => [{
        'id' => 't1', 'kind' => 'table', 'name' => 'Weekly Shipments',
        'columns' => [
          { 'id' => 'd', 'name' => 'Region', 'formula' => '[Some Table/Region]' },
          { 'id' => 'm', 'name' => 'Shipment Count', 'formula' => calc_formula }
        ],
        'groupings' => [{ 'groupBy' => ['d'], 'calculations' => ['m'] }]
      }],
      'layout' => '<Page id="p1"><Element elementId="t1"/></Page>'
    }
  end

  def test_t2_exempts_data_model_metric_reference
    refute lint(t2_spec('[Metrics/Shipment Count]')).any? { |message| message.start_with?('T2 ') }
  end

  def test_t2_still_flags_bare_measure_passthrough
    assert lint(t2_spec('[Some Table/Shipment Count]')).any? { |message| message.start_with?('T2 ') }
  end

  def test_t2_allows_aggregate_expression
    refute lint(t2_spec('CountDistinct([Some Table/Shipment Id])')).any? { |message| message.start_with?('T2 ') }
  end
end
