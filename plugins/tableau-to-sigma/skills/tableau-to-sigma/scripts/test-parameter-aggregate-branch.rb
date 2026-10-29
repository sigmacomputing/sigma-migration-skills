#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'lib/chart_calc_translate'

src = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
%w[canonical_switch_value coerce_case_literal remap_param_branch translate_case_on_param].each do |name|
  fn = src[/^def #{name}.*?^end/m] or abort("missing #{name}")
  eval(fn)
end

def map_column(name, mmap)
  (mmap || {})[name]
end

class ParameterAggregateBranchTest < Minitest::Test
  def setup
    @map = %w[UNITS FAILURES AREA].to_h { |name| [name, { 'name' => name.capitalize }] }
    # Metrics have a map entry but do not exist as physical master columns.
    @map['Failure Rate'] = { 'name' => 'Failure Rate', 'formula' => 'Sum([Failures]) / Sum([Units])' }
    @calcs = { 'Failure Rate' => { 'caption' => 'Failure Rate', 'formula' => 'SUM([FAILURES]) / SUM([UNITS])' } }
  end

  def test_aggregate_branch_inlined_without_phantom_master_column
    formula = "CASE [Parameters].[Choice] WHEN 'Units' THEN SUM([UNITS]) WHEN 'Rate' THEN [Failure Rate] END"
    result = translate_case_on_param(formula, ['Choice'], @map, @calcs)
    assert_includes result, "'Rate', Sum([Master/Failures]) / Sum([Master/Units])"
    refute_includes result, '[Master/Failure Rate]'
    assert_includes result, '[ctl-param-choice]'
  end

  def test_internal_name_and_else_branch_are_resolved
    @calcs['Calculation_900'] = @calcs.delete('Failure Rate')
    formula = "CASE [Parameters].[Choice] WHEN 'Units' THEN SUM([UNITS]) ELSE [Calculation_900] END"
    result = translate_case_on_param(formula, ['Choice'], @map, @calcs)
    assert_includes result, 'Sum([Master/Failures]) / Sum([Master/Units])'
    refute_includes result, 'Calculation_900'
  end

  def test_unsupported_aggregate_fails_closed
    @calcs['Failure Rate']['formula'] = 'SUM([FAILURES]) / LOOKUP(SUM([UNITS]), 1)'
    formula = "CASE [Parameters].[Choice] WHEN 'Rate' THEN [Failure Rate] END"
    assert_nil translate_case_on_param(formula, ['Choice'], @map, @calcs)
  end

  def test_ambiguous_caption_does_not_choose_another_datasource_formula
    calcs = { 'Calculation_1' => @calcs['Failure Rate'],
              'Calculation_2' => { 'caption' => 'Failure Rate', 'formula' => 'SUM([FAILURES])' } }
    formula = "CASE [Parameters].[Choice] WHEN 'Rate' THEN [Failure Rate] END"
    assert_nil translate_case_on_param(formula, ['Choice'], @map, calcs)
  end

  def test_dimension_branch_unchanged
    formula = "CASE [Parameters].[Choice] WHEN 'Area' THEN [AREA] ELSE 'All' END"
    result = translate_case_on_param(formula, ['Choice'], @map, {})
    assert_includes result, '[Master/Area]'
    assert_includes result, '"All"'
  end
end
