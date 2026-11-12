#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'

class ParityExportShapeTest < Minitest::Test
  def plan(csv)
    Dir.mktmpdir do |work|
      Dir.mkdir(File.join(work, 'views'))
      File.write(File.join(work, 'views/v.csv'), csv)
      File.write(File.join(work, 'get-workbook.json'), JSON.generate('views' => { 'view' => [{ 'id' => 'v', 'name' => 'Trend' }] }))
      spec = { 'document' => { 'pages' => [{ 'id' => 'p', 'name' => 'Overview' }], 'elements' => [{
        'id' => 'chart', 'kind' => 'line-chart', 'name' => 'Trend',
        'source' => { 'kind' => 'table', 'elementId' => 'master' },
        'columns' => %w[Area Week Sales Profit].map.with_index { |name, i| { 'id' => "c#{i}", 'name' => name } },
        'xAxis' => { 'columnId' => 'c1' }, 'color' => { 'column' => 'c0' }, 'yAxis' => { 'columnIds' => %w[c2 c3] }
      }], 'layout' => '<Page id="p"><Element elementId="chart"/></Page>' } }
      File.write(File.join(work, 'spec.json'), JSON.generate(spec))
      output = File.join(work, 'plan.json')
      text, status = Open3.capture2e({ 'HOME' => work }, RbConfig.ruby, File.join(__dir__, 'auto-parity-plan.rb'),
        '--tableau', work, '--workbook-spec', File.join(work, 'spec.json'), '--master-id', 'master', '--out', output, '--no-fetch')
      [status.exitstatus, File.file?(output) ? JSON.parse(File.read(output)) : nil, text]
    end
  end

  def test_long_export_retains_multiple_dimensions_and_every_measure
    code, result, text = plan("Area,Week,Measure Names,Measure Values\nNorth,W1,Sales,10\nNorth,W1,Profit,3\nSouth,W1,Sales,20\nSouth,W1,Profit,4\n")
    assert_equal 0, code, text
    chart = result['charts'][0]
    assert_equal %w[c0 c1 c2 c3], chart['sigma_columns']
    assert_equal [['North', 'W1', 10.0, 3.0], ['South', 'W1', 20.0, 4.0]], chart['expected']
  end

  def test_duplicate_measure_cells_are_not_overwritten
    code, _, text = plan("Area,Week,Measure Names,Measure Values\nNorth,W1,Sales,10\nNorth,W1,Sales,99\nNorth,W1,Profit,3\n")
    refute_equal 0, code, text
  end

  def test_unknown_source_columns_do_not_trigger_positional_guessing
    code, _, text = plan("Wrong Dimension,Unknown Value\nNorth,10\n")
    refute_equal 0, code, text
  end
end
