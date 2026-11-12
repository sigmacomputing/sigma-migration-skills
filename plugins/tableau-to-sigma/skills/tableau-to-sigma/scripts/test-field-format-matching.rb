#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'lib/format_map'
FORMAT_KEY_CAPTIONS = { 'NET_SALES' => 'Net Sales', 'SHARE_NET_SALES' => 'Share Net Sales' }.freeze
COLUMN_DEFAULT_FORMATS = { 'Net Sales' => 'C1033', 'Share Net Sales' => 'p0.0%' }.freeze
source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'), encoding: 'UTF-8')
%w[format_header_keys format_key_match_keys tableau_format_to_sigma pick_tableau_format pick_tableau_format_raw pick_column_default_format_raw].each do |name|
  definition = source.match(/^def #{Regexp.escape(name)}.*?\n^end$/m)
  eval(definition[0]) if definition # rubocop:disable Security/Eval -- first-party function regression
end

class FieldFormatMatchingTest < Minitest::Test
  def test_different_field_cannot_borrow_a_substring_currency_format
    formats = { '[ds].[sum:NET_SALES:qk]' => 'C1033' }
    assert_nil pick_tableau_format(formats, 'Share Net Sales')
    assert_nil pick_tableau_format_raw(formats, 'Share Net Sales')
  end

  def test_exact_field_wins_independent_of_hash_order_and_prefixes
    formats = { '[ds].[sum:NET_SALES:qk]' => 'C1033', '[ds].[usr:SHARE_NET_SALES:qk]' => 'p0.0%' }
    [formats, formats.to_a.reverse.to_h].each do |map|
      assert_equal ',.1%', pick_tableau_format(map, 'Share Net Sales')['formatString']
      assert_equal '$,.2f', pick_tableau_format(map, 'Sum of Net Sales')['formatString']
    end
    assert_equal 'p0.0%', pick_column_default_format_raw('Share Net Sales')
    assert_nil pick_column_default_format_raw('Other Net Sales')
  end
end
