#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'set'
require_relative 'lib/dim_canon'
source = File.read(File.join(__dir__, 'verify-ground-truth.rb'), encoding: 'UTF-8')
%w[exported_decimal_precision compare_tile].each do |name|
  eval(source.match(/^def #{name}\(.*?\n^end$/m)[0]) # rubocop:disable Security/Eval -- isolated first-party comparator
end

class GroundTruthColumnIdentityTest < Minitest::Test
  def entry
    { 'columns' => [{ 'alias' => 'Area', 'role' => 'dim' }, { 'alias' => 'Period', 'role' => 'dim' },
                    { 'alias' => 'Amount (sum)', 'role' => 'measure' }],
      'sigma_column_names' => ['Period', 'Area', 'Amount'] }
  end

  def test_reordering_is_proven_by_column_identity_not_values
    result = compare_tile(entry, { 'rows' => [['North', 'Week 1', 5]] }, [['Week 1', 'North', 5]], 1e-6)
    assert_equal 'match', result['verdict']
    ambiguous = entry.merge('sigma_column_names' => ['Area', 'Area', 'Amount'])
    assert_equal 'unverified', compare_tile(ambiguous, { 'rows' => [['A', 'A', 5]] }, [['A', 'A', 5]], 1e-6)['verdict']
    different = entry.merge('sigma_column_names' => ['Unrelated', 'Period', 'Amount'])
    assert_equal 'unverified', compare_tile(different, { 'rows' => [['A', 'A', 5]] }, [['A', 'A', 5]], 1e-6)['verdict']
  end

  def test_missing_or_null_measure_cannot_manufacture_a_pass
    shape = { 'columns' => [{ 'alias' => 'Area', 'role' => 'dim' }, { 'alias' => 'Amount', 'role' => 'measure' }] }
    assert_equal 'diverge', compare_tile(shape, { 'rows' => [['A', 7]] }, [['A', nil]], 1e-6)['verdict']
    shape['columns'] << { 'alias' => 'Units', 'role' => 'measure' }
    assert_equal 'unverified', compare_tile(shape, { 'rows' => [['A', 7, 10]] }, [['A', 7]], 1e-6)['verdict']
  end

  def test_duplicate_rows_must_match_multiplicity
    shape = { 'columns' => [{ 'alias' => 'Area', 'role' => 'dim' }, { 'alias' => 'Amount', 'role' => 'measure' }] }
    assert_equal 'diverge', compare_tile(shape, { 'rows' => [['A', 7], ['A', 7]] }, [['A', 7]], 1e-6)['verdict']
  end
end
