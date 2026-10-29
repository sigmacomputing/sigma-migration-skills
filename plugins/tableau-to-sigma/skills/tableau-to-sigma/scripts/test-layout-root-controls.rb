#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'rexml/document'
require 'tmpdir'
require_relative 'lib/layout_lint'

class RootControlLayoutTest < Minitest::Test
  def test_root_and_collapsed_controls_keep_geometry_inside_containers
    [false, true].each do |wrapped|
      control = { 'id' => 'control-zone', 'kind' => 'parameter', 'caption' => 'Metric',
                  'x_pct' => 50, 'y_pct' => 0, 'w_pct' => 50, 'h_pct' => 10 }
      chart = { 'id' => 'chart-zone', 'kind' => 'chart', 'caption' => 'Totals',
                'x_pct' => 0, 'y_pct' => 25, 'w_pct' => 100, 'h_pct' => 75,
                'chart_kind' => 'bar', 'measures' => [{ 'column' => '[Units]' }] }
      root = wrapped ? control.merge('id' => 'wrapper', 'kind' => 'container', 'children' => [control]) : control
      dashboard = { 'dashboard' => 'Overview', 'zones' => [control, chart], 'zone_tree' => [root, chart],
                    'canvas_px' => { 'w' => 1100, 'h' => 700, 'sizing_mode' => 'fixed' } }
      elements = [{ 'id' => 'metric', 'kind' => 'control', 'name' => 'Metric' },
                  { 'id' => 'totals', 'kind' => 'bar-chart', 'name' => 'Totals' }]
      wb = { 'pages' => [
        { 'id' => 'data', 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table' }] },
        { 'id' => 'overview', 'name' => 'Overview', 'elements' => elements }
      ] }
      Dir.mktmpdir do |work|
        layout = File.join(work, 'dashboard-layout.json')
        ids = File.join(work, 'wb-ids.json')
        out = File.join(work, 'layout.xml')
        File.write(layout, JSON.generate([dashboard]))
        File.write(ids, JSON.generate(wb))
        output, status = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'build-dashboard-layout.rb'),
                                         '--layout', layout, '--wb-ids', ids, '--out', out)
        assert status.success?, output
        xml = File.read(out)
        doc = REXML::Document.new('<Root>' + xml.sub(/\A<\?xml[^>]*\?>\s*/, '') + '</Root>')
        nodes = REXML::XPath.match(doc, '//Element[@elementId="metric"]')
        assert_equal 1, nodes.size
        node = nodes.first
        assert_equal 'Container', node.parent.name
        assert_equal '13 / 25', node.parent.attributes['gridColumn']
        assert_equal '4 / 6', node.parent.attributes['gridRow']
        assert_equal '1 / 25', node.attributes['gridColumn']
        assert_equal '1 / 3', node.attributes['gridRow']
        extras = JSON.parse(File.read("#{out}.elements.json")).values.flatten
        wrapper = extras.find { |e| e['id'] == node.parent.attributes['elementId'] }
        assert_equal 'transparent', wrapper.dig('style', 'backgroundColor')
        assert_equal 'none', wrapper.dig('style', 'padding')
        spec = { 'document' => { 'schemaVersion' => 4, 'kind' => 'workbook',
                 'pages' => wb['pages'].map { |p| p.reject { |k, _| k == 'elements' } },
                 'elements' => wb['pages'].flat_map { |p| p['elements'] }, 'layout' => xml } }
        assert_empty LayoutLint.lint(spec)
      end
    end
  end

  def test_title_suppression_does_not_force_nested_or_responsive_trees
    [['fixed', false, true], ['range', false, false], ['fixed', true, false]].each do |sizing, nested, tree_expected|
      zone = { 'id' => 'z1', 'kind' => 'chart', 'caption' => 'Totals', 'chart_kind' => 'bar',
               'x_pct' => 0, 'y_pct' => 10, 'w_pct' => 100, 'h_pct' => 90,
               'measures' => [{ 'column' => '[Units]' }] }
      root = nested ? zone.merge('id' => 'root', 'kind' => 'container', 'children' => [zone]) : zone
      dashboard = { 'dashboard' => 'Overview', 'show_dashboard_title' => false,
                    'zones' => [zone], 'zone_tree' => [root],
                    'canvas_px' => { 'w' => 1100, 'h' => 700, 'sizing_mode' => sizing } }
      wb = { 'pages' => [
        { 'id' => 'data', 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table' }] },
        { 'id' => 'overview', 'name' => 'Overview', 'elements' => [{ 'id' => 'totals', 'kind' => 'bar-chart', 'name' => 'Totals' }] }
      ] }
      Dir.mktmpdir do |work|
        File.write(File.join(work, 'layout.json'), JSON.generate([dashboard]))
        File.write(File.join(work, 'ids.json'), JSON.generate(wb))
        output, status = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'build-dashboard-layout.rb'),
                                         '--layout', File.join(work, 'layout.json'), '--wb-ids', File.join(work, 'ids.json'),
                                         '--out', File.join(work, 'layout.xml'))
        assert status.success?, output
        assert_equal tree_expected, output.include?('container-tree layout'), output
        refute_includes File.read(File.join(work, 'layout.xml')), '-hdrtext'
      end
    end
  end
end
