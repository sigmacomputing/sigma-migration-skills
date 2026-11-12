#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'lib/workbook_code'

class ComboReadbackTest < Minitest::Test
  def setup
    @chart = { 'id' => 'combo', 'kind' => 'combo-chart',
      'xAxis' => { 'columnId' => 'period' },
      'yAxis' => { 'columnIds' => [
        { 'columnId' => 'sales', 'type' => 'bar' },
        { 'columnId' => 'profit', 'type' => 'bar' },
        { 'columnId' => 'margin', 'type' => 'line' }
      ] }, 'yAxis2' => { 'columnIds' => ['margin'] } }
  end

  def errors(actual)
    WorkbookCode.combo_readback_errors({ 'elements' => [@chart] }, { 'document' => { 'elements' => actual } })
  end

  def test_explicit_marks_and_secondary_axis_survive
    assert_empty errors([@chart])
    normalized = Marshal.load(Marshal.dump(@chart))
    normalized['yAxis']['columnIds'][0] = 'sales'
    assert_empty errors([normalized])
  end

  def test_second_bar_must_not_silently_become_a_line
    changed = Marshal.load(Marshal.dump(@chart))
    changed['yAxis']['columnIds'][1]['type'] = 'line'
    assert_match(/profit.*bar.*line/, errors([changed]).join)
  end

  def test_missing_series_chart_axis_and_secondary_assignment_fail
    assert_match(/missing|ambiguous/, errors([]).join)
    assert_match(/missing|ambiguous/, errors([@chart, @chart]).join)
    %w[xAxis yAxis yAxis2].each do |axis|
      assert errors([@chart.reject { |key, _| key == axis }]).any?, axis
    end
    assert errors([@chart.merge('kind' => 'bar-chart')]).any?
  end
end
