#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require 'fileutils'

class GeneratedRegressionTest < Minitest::Test
  def run!(*cmd)
    out, status = Open3.capture2e({ 'HOME' => @work, 'USERPROFILE' => @work }, *cmd)
    assert status.success?, out
    out
  end

  def test_generated_workbook_uses_only_displayed_pivot_measure
    Dir.mktmpdir do |work|
      @work = work
      run!('python3', File.join(__dir__, 'dev/generate-regression-workbook.py'), '--out', work)
      run!(RbConfig.ruby, File.join(__dir__, 'parse-twb-layout.rb'), File.join(work, 'synthetic-metrics.twb'), File.join(work, 'layout.json'))
      FileUtils.mkdir_p(File.join(work, 'views'))
      views = ['Area Totals', 'Weekly Units', 'Rate Matrix', 'Metric Switch'].each_with_index.map { |n, i| { 'id' => "v#{i}", 'name' => n } }
      File.write(File.join(work, 'get-workbook.json'), JSON.generate('views' => { 'view' => views }))
      File.write(File.join(work, 'views/v0.csv'), "Area,Units\nNorth,520\nSouth,560\nWest,600\n")
      File.write(File.join(work, 'views/v1.csv'), "Period,Units\n2/3/2025,330\n2/10/2025,390\n")
      File.write(File.join(work, 'views/v2.csv'), "Area,Period,Failure Rate\nNorth,2/3/2025,0.07\nSouth,2/3/2025,0.072727273\n")
      File.write(File.join(work, 'png-read.json'), JSON.generate('verified' => true, 'tiles' => [
        { 'title' => 'Rate Matrix', 'kind' => 'pivot-table', 'display_formats' => { 'Failure Rate' => '0.00000' } }
      ]))
      File.write(File.join(work, 'views/v3.csv'), "Area,Selected Metric\nNorth,520\n")
      map = %w[Period Area Units Failures].to_h { |n| ["(?i)^#{n}$", { 'name' => n, 'id' => "m-#{n.downcase}" }] }
      File.write(File.join(work, 'map.json'), JSON.generate(map))
      out = File.join(work, 'charts.json')
      command = [RbConfig.ruby, File.join(__dir__, 'build-charts-from-signals.rb'),
           '--tableau-dir', work, '--layout', File.join(work, 'layout.json'),
           '--meta', File.join(work, 'layout-meta.json'), '--master-map', File.join(work, 'map.json'),
           '--master-element-id', 'master', '--page-per-dashboard', '--auto-controls',
           '--skip-dashboard-read', 'synthetic offline builder test; no visual attestation', '--out', out]
      run!(*command)
      spec = JSON.parse(File.read(out))
      elements = spec.fetch('pages').flat_map { |p| p.fetch('elements') }
      pivot = elements.find { |e| e['kind'] == 'pivot-table' }
      assert_equal 'Rate Matrix', pivot['name']
      assert_equal 1, pivot.fetch('values').length
      value_id = pivot.fetch('values').first
      value = pivot.fetch('columns').find { |c| c['id'] == value_id }
      assert_equal 'Failure Rate', value['name']
      assert_equal 'Sum([Master/Failures]) / Sum([Master/Units])', value['formula']
      refute JSON.generate(elements).include?('[Master/Failure Rate]')
      switch = elements.find { |e| e['name'] == 'Metric Switch' }
      assert switch['columns'].any? { |c| c['formula'].to_s.include?('Sum([Failures]) / Sum([Units])') }
      refute elements.any? { |e| e['id'].start_with?('title-') }, 'do not invent dashboard titles'
      assert_equal ',.5f', value.dig('format', 'formatString')
      assert_equal 'hidden', pivot.dig('display', 'showLabels')
      assert_equal 'presentation', pivot.dig('tableStyle', 'preset')
      line = elements.find { |e| e['name'] == 'Weekly Units' }
      assert_equal({ 'by' => 'single', 'value' => '#4e79a7' }, line['color'])
      assert_equal 'ordinal', line.dig('xAxis', 'format', 'scale', 'type')
      period = line['columns'].find { |c| c['name'] == 'Period' }
      assert_equal '%-m/%-d/%Y', period.dig('format', 'formatString')
      assert_equal true, line.dig('yAxis', 'format', 'scale', 'hideZeroLine')
      assert_equal 12, line.dig('yAxis', 'format', 'labels', 'fontSize')
      assert_equal 'list', elements.find { |e| e['kind'] == 'control' }['controlType']
      assert_equal 'hidden', elements.find { |e| e['kind'] == 'control' }['clearButton']

      # Source-image formats and styling still apply when no worksheet CSV is
      # exported; legacy hand-written reads may omit verified and vary title case.
      File.delete(File.join(work, 'views/v2.csv'))
      image_read = { 'tiles' => [{ 'title' => ' rate MATRIX ', 'display_formats' => { ' failure rate ' => '0.00000' } }] }
      File.write(File.join(work, 'png-read.json'), JSON.generate(image_read))
      run!(*command)
      rebuilt = JSON.parse(File.read(out))['pages'].flat_map { |p| p['elements'] }
      matrix = rebuilt.find { |e| e['kind'] == 'pivot-table' }
      assert_equal 'presentation', matrix.dig('tableStyle', 'preset')
      assert_equal ',.5f', matrix['columns'].find { |c| c['name'] == 'Failure Rate' }.dig('format', 'formatString')

      prior = File.binread(out)
      image_read['tiles'][0]['display_formats'][' failure rate '] = 'unsupported-format'
      File.write(File.join(work, 'png-read.json'), JSON.generate(image_read))
      output, status = Open3.capture2e({ 'HOME' => work, 'USERPROFILE' => work }, *command)
      refute status.success?
      assert_includes output, 'unsupported source-image display format'
      assert_equal prior, File.binread(out)
      assert_match(/^\s*run!\(build_cmd\)\s*(?:#.*)?$/, File.read(File.join(__dir__, 'migrate-tableau.rb')),
                   'orchestration must stop rather than consume the stale output after any builder failure')
      refute_match(/run!\(build_cmd,\s*allow_fail:\s*true\)/, File.read(File.join(__dir__, 'migrate-tableau.rb')))
      image_read['tiles'][0]['display_formats'] = nil
      File.write(File.join(work, 'png-read.json'), JSON.generate(image_read))
      run!(*command)
    end
  end
end
