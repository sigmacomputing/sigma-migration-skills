#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require_relative 'lib/py_resolve'

class MeasureNameAliasesTest < Minitest::Test
  TWB = <<~XML
    <workbook><datasources><datasource name='source-a'>
      <column name='[AREA]' caption='Area' datatype='string' role='dimension'/>
      <column name='[PERIOD]' caption='Period' datatype='string' role='dimension'/>
      <column name='[AMOUNT]' caption='Amount' datatype='real' role='measure'/>
      <column name='[:Measure Names]' datatype='string' role='dimension'><aliases>
        <alias key='[sum:AMOUNT:qk]' value='Revenue Display'/>
      </aliases></column>
    </datasource></datasources><worksheets><worksheet name='Matrix'><table><view>
      <datasource-dependencies datasource='source-a'>
        <column-instance column='[AMOUNT]' derivation='Sum' name='[sum:AMOUNT:qk]' type='quantitative'/>
      </datasource-dependencies></view><rows>[source-a].[none:AREA:nk]</rows>
      <cols>[source-a].[none:PERIOD:nk]/[source-a].[:Measure Names]</cols><pane><mark class='Text'/><encodings><text column='[source-a].[Multiple Values]'/></encodings></pane>
    </table></worksheet></worksheets><dashboards><dashboard name='Overview'><zones>
      <zone id='1' name='Matrix' x='0' y='0' w='100000' h='100000'/>
    </zones></dashboard></dashboards></workbook>
  XML

  def test_both_parsers_preserve_measure_aliases_and_pivot_uses_them
    Dir.mktmpdir do |work|
      source = File.join(work, 'source.twb')
      File.write(source, TWB)
      [[RbConfig.ruby, 'rb'], [*PyResolve.argv, 'py']].each do |command|
        extension = command.pop
        layout = File.join(work, "layout-#{extension}.json")
        text, status = Open3.capture2e({ 'HOME' => work }, *command, File.join(__dir__, "parse-twb-layout.#{extension}"), source, layout)
        assert status.success?, text
        meta = JSON.parse(File.read(File.join(work, "layout-#{extension}-meta.json")))
        assert_equal 'Revenue Display', meta.dig('measure_name_aliases', 'source-a', 'sum:amount')
      end
      File.write(File.join(work, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
      File.write(File.join(work, 'map.json'), JSON.generate(
        '(?i)^Period$' => { 'id' => 'm-period', 'name' => 'Period' },
        '(?i)^Area$' => { 'id' => 'm-area', 'name' => 'Area' }, '(?i)^Amount$' => { 'id' => 'm-amount', 'name' => 'Amount' }))
      output = File.join(work, 'charts.json')
      text, status = Open3.capture2e({ 'HOME' => work }, RbConfig.ruby, File.join(__dir__, 'build-charts-from-signals.rb'),
        '--tableau-dir', work, '--layout', File.join(work, 'layout-rb.json'), '--meta', File.join(work, 'layout-rb-meta.json'),
        '--master-map', File.join(work, 'map.json'), '--master-element-id', 'master', '--skip-dashboard-read', 'synthetic', '--out', output)
      assert status.success?, text
      spec = JSON.parse(File.read(output))
      elements = spec.is_a?(Array) ? spec : spec.fetch('elements')
      pivot = elements.find { |element| element['kind'] == 'pivot-table' }
      assert pivot, text
      value = pivot['columns'].find { |column| pivot['values'].include?(column['id']) }
      assert_equal 'Revenue Display', value['name']
      assert_equal 'Sum([Master/Amount])', value['formula']
    end
  end
end
