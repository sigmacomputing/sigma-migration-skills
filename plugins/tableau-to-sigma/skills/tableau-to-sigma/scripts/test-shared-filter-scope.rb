#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require_relative 'lib/py_resolve'

class SharedFilterScopeTest < Minitest::Test
  SOURCE = <<~XML
    <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
      <datasources>
        <datasource name='alpha' caption='Alpha Source'>
          <column name='[REGION]' caption='Region' datatype='string' role='dimension'/>
          <column name='[TIER]' caption='Tier' datatype='string' role='dimension'/>
          <column name='[SALES]' caption='Sales' datatype='real' role='measure'/>
        </datasource>
        <datasource name='beta' caption='Beta Source'>
          <column name='[STATE]' caption='State' datatype='string' role='dimension'/>
        </datasource>
      </datasources>
      <shared-views>
        <shared-view name='alpha'>
          <filter class='categorical' column='[alpha].[none:REGION:nk]'><groupfilter function='member' member='&quot;West&quot;'/></filter>
          <filter class='categorical' column='[alpha].[none:TIER:nk]'><groupfilter function='member' member='&quot;Gold&quot;'/></filter>
        </shared-view>
        <shared-view name='beta'><filter class='categorical' column='[beta].[none:STATE:nk]'><groupfilter function='member' member='&quot;Open&quot;'/></filter></shared-view>
      </shared-views>
      <worksheets><worksheet name='Sales Sheet'><table>
        <view><datasources><datasource name='alpha' caption='Alpha Source'/></datasources><datasource-dependencies datasource='alpha'/></view>
        <rows>[alpha].[sum:SALES:qk]</rows><cols>[alpha].[none:REGION:nk]</cols><pane><mark class='Bar'/></pane>
      </table></worksheet></worksheets>
      <dashboards><dashboard name='Overview'><zones>
        <zone id='1' name='Sales Sheet' x='0' y='0' w='90000' h='100000'/>
        <zone id='2' type-v2='filter' param='[alpha].[none:REGION:nk]' x='90000' y='0' w='10000' h='100000'/>
      </zones></dashboard></dashboards>
    </workbook>
  XML

  def test_both_parsers_preserve_source_scoped_shared_filters_and_saved_members
    Dir.mktmpdir do |work|
      source = File.join(work, 'source.twb')
      File.write(source, SOURCE)
      [[RbConfig.ruby, 'rb'], [*PyResolve.argv, 'py']].each do |command|
        extension = command.pop
        output = File.join(work, "layout-#{extension}.json")
        text, status = Open3.capture2e(*command, File.join(__dir__, "parse-twb-layout.#{extension}"), source, output, '--dashboard', 'Overview')
        assert status.success?, text
        meta = JSON.parse(File.read(File.join(work, "layout-#{extension}-meta.json")))
        filters = meta['shared_filters'].to_h { |item| [item['column_caption'], item] }
        assert_equal %w[Region Tier], filters.keys.sort, extension
        assert_equal ['West'], filters['Region']['members']
        refute filters['Region']['is_datasource_filter'], 'visible shared-view card is not an immutable datasource filter'
        assert_equal true, filters['Tier']['is_datasource_filter']
      end
    end
  end

  def test_both_parsers_preserve_included_null_member_without_turning_it_into_all
    Dir.mktmpdir do |work|
      source = File.join(work, 'source.twb')
      File.write(source, SOURCE.sub('member=\'&quot;West&quot;\'', "member='%null%'"))
      [[RbConfig.ruby, 'rb'], [*PyResolve.argv, 'py']].each do |command|
        extension = command.pop
        output = File.join(work, "layout-#{extension}.json")
        text, status = Open3.capture2e(*command, File.join(__dir__, "parse-twb-layout.#{extension}"), source, output)
        assert status.success?, text
        meta = JSON.parse(File.read(File.join(work, "layout-#{extension}-meta.json")))
        filter = meta.fetch('shared_filters').find { |item| item['column_caption'] == 'Region' }
        assert_equal true, filter['includes_null'], extension
        assert_empty filter['members']
      end
    end
  end

  def test_builder_seeds_visible_include_and_applies_hidden_shared_filter
    Dir.mktmpdir do |work|
      source = File.join(work, 'source.twb')
      layout = File.join(work, 'layout.json')
      File.write(source, SOURCE.sub("member='&quot;West&quot;'/>", "member='&quot;West&quot;'/><groupfilter function='member' member='%null%'/>")
                               .sub("member='&quot;Gold&quot;'", "member='%null%'"))
      File.write(File.join(work, 'get-workbook.json'), JSON.generate('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Sales Sheet' }] }))
      Dir.mkdir(File.join(work, 'views'))
      File.write(File.join(work, 'views/v1.csv'), '')
      mapping = %w[Region Tier Sales].to_h { |name| ["(?i)^#{name}$", { 'id' => "m-#{name.downcase}", 'name' => name }] }
      File.write(File.join(work, 'map.json'), JSON.generate(mapping))
      text, status = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'parse-twb-layout.rb'), source, layout, '--dashboard', 'Overview')
      assert status.success?, text
      [false, true].each do |no_controls|
        output = File.join(work, 'charts.json')
        command = [RbConfig.ruby, File.join(__dir__, 'build-charts-from-signals.rb'), '--tableau-dir', work,
                   '--layout', layout, '--meta', File.join(work, 'layout-meta.json'), '--master-map', File.join(work, 'map.json'),
                   '--master-element-id', 'master', '--skip-dashboard-read', 'synthetic-test', '--out', output]
        command << '--no-auto-controls' if no_controls
        text, status = Open3.capture2e(*command)
        assert status.success?, text
        document = JSON.parse(File.read(output))
        elements = document.is_a?(Array) ? document : document.fetch('elements')
        chart = elements.find { |element| element['name'] == 'Sales Sheet' }
        assert chart, text
        assert chart.fetch('filters', []).any? { |filter| filter['values'] == [nil] }, chart.inspect
        refute elements.any? { |element| element['kind'] == 'control' && element['name'] == 'Tier' }
        unless no_controls
          control = elements.find { |element| element['kind'] == 'control' && element['name'] == 'Region' }
          assert_equal ['West', nil], control && control['values']
        end
      end
    end
  end

  def test_pie_default_mark_labels_explicitly_request_slice_values
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'source.twb'), SOURCE.sub("<mark class='Bar'/>", "<mark class='Pie'/>")
        .sub('</pane>', "<style><style-rule element='mark'><format attr='mark-labels-show' value='true'/></style-rule></style></pane>"))
      File.write(File.join(work, 'get-workbook.json'), '{"views":{"view":[]}}')
      File.write(File.join(work, 'map.json'), JSON.generate(%w[Region Tier Sales].to_h { |name| ["(?i)^#{name}$", { 'id' => name.downcase, 'name' => name }] }))
      text, status = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'parse-twb-layout.rb'), File.join(work, 'source.twb'), File.join(work, 'layout.json'))
      assert status.success?, text
      text, status = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'build-charts-from-signals.rb'),
        '--tableau-dir', work, '--layout', File.join(work, 'layout.json'), '--meta', File.join(work, 'layout-meta.json'),
        '--master-map', File.join(work, 'map.json'), '--master-element-id', 'master',
        '--skip-dashboard-read', 'synthetic fixture', '--out', File.join(work, 'charts.json'))
      assert status.success?, text
      document = JSON.parse(File.read(File.join(work, 'charts.json')))
      elements = document.is_a?(Array) ? document : document.fetch('elements')
      pie = elements.find { |element| element['kind'] == 'pie-chart' }
      assert pie, text
      assert_equal 'value', pie.dig('dataLabel', 'labelDisplay')
      assert_equal 'as-label', pie.dig('dataLabel', 'donutLabelDisplay')
    end
  end
end
