#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression (2026-11-05 hybrid live proof, rough edge 5): a bar converted to a
# pie keeps its "% of total" label column in the spec, but Sigma's element
# export and MCP `query` return only a pie's plotted channels (color + value).
# The parity plan asked for the label column, so the chart could never be
# collected and needed hand-built actuals + sdk-regate. auto-parity-plan.rb now
# falls back to the pie/donut's encoded columns from the spec.
#
# Fixture: fixtures/sdk-hybrid-live-proof/P939-edit (the live pie element and
# the Tableau view CSV it is checked against).
#
# Usage:  ruby scripts/test-parity-pie-projection.rb
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'minitest/autorun'

class ParityPieProjectionTest < Minitest::Test
  PLAN = File.join(__dir__, 'auto-parity-plan.rb')
  VERIFY = File.join(__dir__, 'verify-parity.rb')
  FIX = File.join(__dir__, 'fixtures', 'sdk-hybrid-live-proof', 'P939-edit')

  def pie_element
    JSON.parse(File.read(File.join(FIX, 'pie-element.json')))
  end

  def build(element, csv = File.read(File.join(FIX, 'tier-view.csv')))
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'get-workbook.json'),
                 JSON.generate('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'RC Revenue by Tier' }] }))
      File.write(File.join(dir, 'chart-provenance.json'),
                 JSON.generate('elements' => { element['id'] => { 'worksheet' => 'RC Revenue by Tier' } }))
      Dir.mkdir(File.join(dir, 'views'))
      File.write(File.join(dir, 'views', 'v1.csv'), csv)
      el = element.merge('source' => { 'kind' => 'data-model', 'dataModelId' => 'dm1', 'elementId' => 'dm-el' })
      File.write(File.join(dir, 'wb.json'), JSON.generate(
        'schemaVersion' => 4, 'kind' => 'workbook',
        'pages' => [{ 'id' => 'pg', 'name' => 'Overview' }],
        'elements' => [el],
        'layout' => %(<Page id="pg"><Element elementId="#{el['id']}"/></Page>)
      ))
      out = File.join(dir, 'plan.json')
      log, status = Open3.capture2e(RbConfig.ruby, PLAN, '--tableau', dir, '--workbook-spec',
                                    File.join(dir, 'wb.json'), '--out', out, '--workbook-id', 'wb-t')
      assert status.success?, "auto-parity-plan failed: #{log}"
      [JSON.parse(File.read(out))['charts'].first, log]
    end
  end

  def verify(chart)
    Dir.mktmpdir do |dir|
      plan = File.join(dir, 'plan.json')
      File.write(plan, JSON.generate('charts' => [chart]))
      out, _err, st = Open3.capture3(RbConfig.ruby, VERIFY, '--plan', plan,
                                     '--score-out', File.join(dir, 'score.json'))
      [st.exitstatus, out]
    end
  end

  def test_pie_plan_uses_only_plotted_columns
    chart, log = build(pie_element)
    assert_equal %w[x-el-rc-revenue-by-tier y-el-rc-revenue-by-tier], chart['sigma_columns']
    assert_equal ['Customer Value Tier', 'Net Revenue'], chart['sigma_column_names']
    assert_equal ['Pct of Net Revenue'], chart['unplotted_columns']
    assert_equal [['Platinum', 81_526.98], ['Silver', 55_467.27], ['Gold', 38_933.31], ['Bronze', 21_748.94]],
                 chart['expected']
    assert_equal [1], chart['measure_indices']
    assert_equal [nil, 2], chart['expected_decimals']
    refute_includes chart['sql_template'], 'lbl-el-rc-revenue-by-tier'
    assert_match(/plots only its color \+ value columns/, log)
  end

  # What the live CSV export of the pie returned (headers Customer Value Tier,
  # Net Revenue) now scores PASS without hand-built actuals.
  def test_pie_export_rows_pass_against_projected_plan
    chart, = build(pie_element)
    chart['actual'] = { 'rows' => [['Bronze', 21_748.94], ['Gold', 38_933.31],
                                   ['Platinum', 81_526.98], ['Silver', 55_467.27]] }
    rc, out = verify(chart)
    assert_equal 0, rc, out
    assert_match(/^PASS/, out)
  end

  def test_donut_gets_same_fallback
    chart, = build(pie_element.merge('kind' => 'donut-chart'))
    assert_equal %w[x-el-rc-revenue-by-tier y-el-rc-revenue-by-tier], chart['sigma_columns']
  end

  # A bar plots every channel it names, so its plan keeps the label column.
  def test_bar_keeps_all_matched_columns
    bar = pie_element.reject { |k, _| %w[color value].include?(k) }
                     .merge('kind' => 'bar-chart',
                            'xAxis' => { 'columnId' => 'x-el-rc-revenue-by-tier' },
                            'yAxis' => { 'columnIds' => ['y-el-rc-revenue-by-tier'] })
    chart, = build(bar)
    assert_equal 3, chart['sigma_columns'].size
    refute chart.key?('unplotted_columns')
  end

  # An unplotted text column after the first CSV column is still a dimension.
  def test_unplotted_text_column_is_not_dropped
    el = pie_element
    el['columns'] << { 'id' => 'seg-el-rc-revenue-by-tier', 'formula' => '[Master/Segment]', 'name' => 'Segment' }
    csv = "Customer Value Tier,Segment,Net Revenue\nPlatinum,Retail,\"81,526.98\"\n"
    chart, = build(el, csv)
    assert_equal 3, chart['sigma_columns'].size
    refute chart.key?('unplotted_columns')
  end

  # Dropping an unplotted DIMENSION would change the grain: keep the full plan.
  def test_unplotted_dimension_is_not_dropped
    el = pie_element
    el['columns'] << { 'id' => 'seg-el-rc-revenue-by-tier', 'formula' => '[Master/Segment]', 'name' => 'Segment' }
    csv = "Segment,Customer Value Tier,Net Revenue\nRetail,Platinum,\"81,526.98\"\n"
    chart, = build(el, csv)
    assert_equal 3, chart['sigma_columns'].size
    refute chart.key?('unplotted_columns')
  end
end
