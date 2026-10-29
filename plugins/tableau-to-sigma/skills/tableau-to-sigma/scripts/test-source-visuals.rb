#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'lib/source_visuals'

class SourceVisualsTest < Minitest::Test
  def test_uniform_source_precision_and_symbols
    cases = [
      [%w[7.0% 6.7%], 'real', '.1%'],
      [%w[$1,234.00 $2,000.00], 'real', '$,.2f'],
      [%w[1,234 5,678], 'integer', ',.0f'],
      [%w[2/3/2025 2/10/2025], 'date', '%-m/%-d/%Y']
    ]
    cases.each do |cells, datatype, expected|
      assert_equal expected, SourceVisuals.csv_format(cells, datatype: datatype, locale: 'en_US')['formatString']
    end
  end

  def test_ambiguous_or_non_numeric_data_is_not_guessed
    [[], %w[0.07000 0.07273], %w[1.0 1.234], %w[1.0 unavailable], %w[1e-5 2e-5]].each do |cells|
      assert_nil SourceVisuals.csv_format(cells, datatype: 'real', locale: 'en_US')
    end
    assert_nil SourceVisuals.csv_format(%w[2/3/2025], datatype: 'date', locale: 'en_GB')
    assert_nil SourceVisuals.csv_format(%w[007], datatype: 'string', locale: 'en_US')
    assert_nil SourceVisuals.csv_format(%w[520 12345], datatype: 'integer', locale: 'en_US')
    assert_nil SourceVisuals.csv_format(%w[7%], datatype: 'integer', locale: 'en_US')
  end

  def test_explicit_format_color_and_background_win
    element = { 'kind' => 'bar-chart', 'columns' => [
      { 'name' => 'Rate', 'format' => { 'kind' => 'number', 'formatString' => '.2%' } }
    ], 'color' => { 'by' => 'single', 'value' => '#ff0000' },
       'yAxis' => { 'columnIds' => ['rate'] },
       'style' => { 'backgroundColor' => '#eeeeee' } }
    meta = { 'columns_by_guid' => { 'rate' => { 'caption' => 'Rate', 'datatype' => 'real' } } }
    SourceVisuals.apply!(element, {}, { 'source_locale' => 'en_US' }, [['Rate'], ['0.07000']], meta,
                         source_formats: { 'Rate' => { 'kind' => 'number', 'formatString' => '.5f' } }) { true }
    assert_equal '.2%', element['columns'].first.dig('format', 'formatString')
    assert_equal '#ff0000', element.dig('color', 'value')
    assert_equal '#eeeeee', element.dig('style', 'backgroundColor')
  end

  def test_verified_image_format_controls_raw_fraction_display
    column = { 'name' => 'Rate', 'format' => { 'kind' => 'number', 'formatString' => '.2%' } }
    element = { 'kind' => 'pivot-table', 'columns' => [column] }
    source_format = { 'kind' => 'number', 'formatString' => ',.5f' }
    SourceVisuals.apply!(element, {}, { 'source_locale' => 'en_US' }, [['Rate'], ['0.066666667']], {},
                         source_formats: { 'Rate' => source_format }) { false }
    assert_equal source_format, column['format']
  end

  def test_declared_theme_is_not_replaced_with_tableau_defaults
    element = { 'kind' => 'line-chart', 'columns' => [], 'xAxis' => { 'format' => { 'labels' => { 'fontSize' => 18 } } } }
    dashboard = { 'source_locale' => 'en_US', 'brand_palette' => %w[#123456 #abcdef],
                  'style_rules' => { 'workbook' => { 'all' => { 'font-size' => '18' } } } }
    SourceVisuals.apply!(element, {}, dashboard, [], {}) { false }
    assert_nil element['color']
    assert_equal 18, element.dig('xAxis', 'format', 'labels', 'fontSize')
  end

  def test_integer_raw_exports_preserve_grouping_and_curated_format
    [%w[520 560], %w[12345 23456]].each do |values|
      column = { 'name' => 'Units', 'format' => { 'kind' => 'number', 'formatString' => ',.0f' } }
      meta = { 'columns_by_guid' => { 'u' => { 'caption' => 'Units', 'datatype' => 'integer' } } }
      SourceVisuals.apply!({ 'columns' => [column] }, {}, { 'source_locale' => 'en_US' },
                           [['Units']] + values.map { |v| [v] }, meta) { false }
      assert_equal ',.0f', column.dig('format', 'formatString')
    end
  end

  def test_date_discreteness_is_not_tied_to_locale_csv_or_format
    %w[rows_shelf cols_shelf].each do |shelf|
      [nil, 'en_GB', 'en_US'].each do |locale|
        column = { 'id' => 'period', 'name' => 'Period', 'format' => { 'kind' => 'datetime', 'formatString' => '%Y-%m-%d' } }
        element = { 'columns' => [column], 'xAxis' => { 'columnId' => 'period', 'format' => { 'scale' => { 'reverse' => true } } } }
        zone = { shelf => { 'fields' => [{ 'role' => 'dim', 'guid' => 'p', 'raw' => '[none:p:nk]' }] } }
        meta = { 'columns_by_guid' => { 'p' => { 'caption' => 'Period', 'datatype' => 'date' } } }
        SourceVisuals.apply!(element, zone, { 'source_locale' => locale }, [], meta) { true }
        assert_equal 'ordinal', element.dig('xAxis', 'format', 'scale', 'type')
        assert_equal true, element.dig('xAxis', 'format', 'scale', 'reverse')
        assert_equal '%Y-%m-%d', column.dig('format', 'formatString')
      end
    end
  end

  def test_continuous_and_hidden_date_axes_are_preserved
    ['qk', 'nk'].each do |suffix|
      element = { 'columns' => [{ 'id' => 'p', 'name' => 'Period' }],
                  'xAxis' => { 'columnId' => 'p', 'format' => { 'visibility' => 'hidden' } } }
      zone = { 'cols_shelf' => { 'fields' => [{ 'role' => 'dim', 'guid' => 'p', 'raw' => "[none:p:#{suffix}]" }] } }
      meta = { 'columns_by_guid' => { 'p' => { 'caption' => 'Period', 'datatype' => 'date' } } }
      SourceVisuals.apply!(element, zone, {}, [], meta) { false }
      assert_equal({ 'visibility' => 'hidden' }, element.dig('xAxis', 'format'))
    end
  end

  def test_parameter_thresholds_and_curated_pickers_keep_their_formats
    format = { 'kind' => 'number', 'formatString' => '$,.2f' }
    threshold = { 'name' => 'Revenue', 'formula' => 'If([ctl-threshold] > 0, Sum([Revenue]), 0)', 'format' => format }
    picker = { 'name' => 'Metric', 'formula' => 'Switch([ctl-metric], "A", Sum([A]), "B", Sum([B]))', 'format' => format }
    SourceVisuals.apply!({ 'columns' => [threshold, picker] }, {}, {}, [], {},
                         source_formats: { 'Metric' => { 'kind' => 'number', 'formatString' => '.1%' } },
                         mapped_formats: { 'Metric' => format }) { false }
    assert_equal format, threshold['format']
    assert_equal format, picker['format']
    SourceVisuals.apply!({ 'columns' => [picker] }, {}, {}, [], {},
                         source_formats: { 'Metric' => { 'kind' => 'number', 'formatString' => '.1%' } }) { false }
    refute picker.key?('format'), 'a current-state image cannot format every picker branch'
  end

  def test_only_single_series_gets_a_default_color_even_without_a_csv
    [1, 2].each do |count|
      element = { 'kind' => 'line-chart', 'columns' => [], 'yAxis' => { 'columnIds' => Array.new(count) { |i| "v#{i}" } } }
      SourceVisuals.apply!(element, {}, { 'source_locale' => 'en_US' }, [], {}) { false }
      count == 1 ? assert_equal('#4e79a7', element.dig('color', 'value')) : assert_nil(element['color'])
      assert_equal 'transparent', element.dig('style', 'backgroundColor')
    end
  end

  def test_ordinal_date_parts_and_visible_continuous_dates
    %w[ok qk].each do |suffix|
      element = { 'columns' => [{ 'id' => 'p', 'name' => 'Period' }], 'xAxis' => { 'columnId' => 'p' } }
      zone = { 'cols_shelf' => { 'fields' => [{ 'role' => 'dim', 'guid' => 'p', 'raw' => "[yr:p:#{suffix}]" }] } }
      meta = { 'columns_by_guid' => { 'p' => { 'caption' => 'Period', 'datatype' => 'date' } } }
      SourceVisuals.apply!(element, zone, {}, [], meta) { false }
      suffix == 'ok' ? assert_equal('ordinal', element.dig('xAxis', 'format', 'scale', 'type')) : assert_nil(element.dig('xAxis', 'format', 'scale', 'type'))
    end
  end

  def test_image_column_names_are_normalized_and_secondary_axis_is_styled
    format = { 'kind' => 'number', 'formatString' => '.5f' }
    element = { 'columns' => [{ 'name' => 'Rate' }], 'yAxis2' => { 'columnIds' => ['right'] } }
    SourceVisuals.apply!(element, {}, { 'source_locale' => 'en_US' }, [], {},
                         source_formats: { ' rate ' => format }) { false }
    assert_equal format, element['columns'].first['format']
    assert_equal 12, element.dig('yAxis2', 'format', 'labels', 'fontSize')
  end

  def test_legacy_string_shelves_do_not_crash
    element = { 'columns' => [{ 'id' => 'p', 'name' => 'Period' }], 'xAxis' => { 'columnId' => 'p' } }
    SourceVisuals.apply!(element, { 'rows_shelf' => '[Period]', 'cols_shelf' => '[Units]' }, {}, [], {}) { false }
    assert_nil element.dig('xAxis', 'format')
  end
end
