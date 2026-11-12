#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'json'
require 'csv'
require 'timeout'
source = File.read(File.join(__dir__, 'collect-parity-actuals.rb'), encoding: 'UTF-8')
%w[parse_cell map_columns collect_chart_json collect_chart].each do |name|
  definition = source.match(/^def #{name}\(.*?\n^end$/m)
  abort "missing #{name}" unless definition
  eval(definition[0]) # rubocop:disable Security/Eval -- exercise first-party collector without network
end
ROW_LIMIT = 100
RENDER_VERIFY_REASON = 'empty export'
SERVER_ERR = /500/
CACHE = Struct.new(:body) { def fetch(*); body; end }.new
module ExportPool
  def self.parse_json_rows(body); JSON.parse(body); end
  def self.truncated?(rows, limit); limit && rows.size > limit; end
end
module Sigma
  class Error < StandardError; end
  class << self; attr_accessor :labels, :delay; end
  def self.list_entries(*)
    sleep(delay || 0)
    Array(labels).map { |name| { 'elementId' => 'element', 'label' => name } }
  end
end

class JsonNullColumnsTest < Minitest::Test
  def collect(rows, labels = %w[Group Amount], seconds: 1, delay: 0)
    CACHE.body = JSON.generate(rows)
    Sigma.labels = labels
    Sigma.delay = delay
    deadline = Object.new
    def deadline.expired?; false; end
    deadline.define_singleton_method(:remaining) { seconds }
    collect_chart_json('element', %w[Group Amount], nil, 'synthetic-workbook', deadline)
  end

  def test_headers_use_all_rows_not_only_the_first
    assert_equal [:ok, [['A', nil], ['B', 3.0]]], collect([{ 'Group' => 'A' }, { 'Group' => 'B', 'Amount' => 3 }])
  end

  def test_independent_inventory_is_bounded_by_collection_deadline
    assert_equal :fail, collect([{ 'Group' => 'A' }], seconds: 0.02, delay: 0.2)[0]
  end

  def test_all_null_column_requires_independent_live_column_evidence
    assert_equal [:ok, [['A', nil]]], collect([{ 'Group' => 'A' }])
    assert_equal :fail, collect([{ 'Group' => 'A' }], %w[Group Different])[0]
    assert_equal :fail, collect([{ 'Other' => 'A' }])[0]
    assert_equal :fail, collect([{ 'Group' => 'A' }], %w[Group Amount amount])[0]
  end

  def test_ambiguous_json_keys_and_ragged_rows_are_not_silently_projected
    assert_equal :fail, collect([{ 'Group' => 'A', 'Amount' => 1, ' Amount ' => 2 }])[0]
    assert_equal :fail, collect([{ 'Group' => 'A', 'Amount' => 1, 'amount' => 2 }])[0]
    assert_equal :fail, map_columns(%w[Group Amount], [['A']], %w[Group Amount])[0]
    assert_equal :fail, map_columns(%w[Group Amount], [['A', 1, 2]], %w[Group Amount])[0]
  end

  def test_binary_utf8_csv_round_trips_and_invalid_encoding_is_refused
    element = { 'columns' => [{ 'id' => 'g', 'name' => 'Group' }, { 'id' => 'a', 'name' => 'Amount' }] }
    chart = { 'sigma_element_id' => 'element', 'sigma_columns' => %w[g a] }
    deadline = Object.new
    def deadline.expired?; false; end
    CACHE.body = "\uFEFFGroup,Amount\nCaf\u00e9,3\n".b
    status, rows = collect_chart(chart, { 'element' => element }, 'synthetic', deadline)
    assert_equal :ok, status
    assert_equal "Caf\u00e9", rows[0][0]
    assert JSON.generate(rows)
    CACHE.body = "Group,Amount\n\xff,3\n".b
    assert_equal :fail, collect_chart(chart, { 'element' => element }, 'synthetic', deadline)[0]
  end
end
