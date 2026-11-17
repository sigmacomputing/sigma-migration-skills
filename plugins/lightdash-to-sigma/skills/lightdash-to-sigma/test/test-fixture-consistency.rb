#!/usr/bin/env ruby
# frozen_string_literal: true
# Verifies fixtures/jaffle-orders is internally consistent per
# refs/lightdash-source-contract.md (field ids, explores, tiles, relations).
#
#   ruby test/test-fixture-consistency.rb

require 'minitest/autorun'
require 'yaml'
require 'json'
require 'set'

class FixtureConsistencyTest < Minitest::Test
  ROOT = File.expand_path('../fixtures/jaffle-orders', __dir__)
  DEFAULT_INTERVALS = %w[DAY WEEK MONTH QUARTER YEAR].freeze

  def load_yaml(path)
    YAML.safe_load(File.read(path))
  end

  def meta_of(node)
    ((node['config'] || {})['meta']) || node['meta'] || {}
  end

  def models
    @models ||= Dir[File.join(ROOT, 'dbt/models/**/*.yml')].sort.flat_map { |f| load_yaml(f)['models'] || [] }
                                                         .each_with_object({}) { |m, h| h[m['name']] = m }
  end

  def charts
    @charts ||= Dir[File.join(ROOT, 'lightdash/charts/*.yml')].sort.map { |f| load_yaml(f) }
  end

  def dashboards
    @dashboards ||= Dir[File.join(ROOT, 'lightdash/dashboards/*.yml')].sort.map { |f| load_yaml(f) }
  end

  def manifest
    @manifest ||= JSON.parse(File.read(File.join(ROOT, 'dbt/target/manifest.json')))
  end

  # { field_name => kind } for one model, ignoring join allow-lists.
  # Date dims with intervals are only addressable by interval.
  def own_fields(model)
    out = {}
    meta_of(model)['metrics']&.each_key { |m| out[m] = :metric }
    model['columns'].each do |col|
      cm = meta_of(col)
      if (d = cm['dimension'])
        if %w[date timestamp].include?(d['type'])
          (d['time_intervals'] || DEFAULT_INTERVALS).each { |i| out["#{col['name']}_#{i.downcase}"] = :dimension }
        else
          out[col['name']] = :dimension
        end
      end
      (cm['additional_dimensions'] || {}).each_key { |n| out[n] = :dimension }
      (cm['metrics'] || {}).each_key { |n| out[n] = :metric }
    end
    out
  end

  # { field_id => kind } for an explore (base model + joined models).
  def explore_fields(name)
    base = models.fetch(name)
    ids = {}
    own_fields(base).each { |f, k| ids["#{name}_#{f}"] = k }
    (meta_of(base)['joins'] || []).each do |j|
      jm = models.fetch(j['join'])
      allow = j['fields']
      jm_fields = own_fields(jm)
      jm_cols = jm['columns'].map { |c| c['name'] }
      jm_fields.each do |f, k|
        base_name = jm_cols.find { |c| f == c || f.start_with?("#{c}_") } || f
        next if allow && !(allow.include?(f) || allow.include?(base_name))
        ids["#{j['join']}_#{f}"] = k
      end
    end
    ids
  end

  def filter_rules(filters)
    return [] if filters.nil? || filters.empty?
    return filters if filters.is_a?(Array)
    filters.values.flat_map { |grp| grp.is_a?(Hash) ? (grp['and'] || grp['or'] || []) : [] }
  end

  def test_chart_explores_are_models
    refute_empty charts
    charts.each do |c|
      assert models.key?(c['metricQuery']['exploreName']), "#{c['slug']}: unknown explore"
      assert_equal c['tableName'], c['metricQuery']['exploreName'], "#{c['slug']}: tableName != exploreName"
    end
  end

  def test_chart_field_ids_resolve
    charts.each do |c|
      mq = c['metricQuery']
      fields = explore_fields(mq['exploreName'])
      calcs = (mq['tableCalculations'] || []).map { |t| t['name'] }
      ids = []
      ids.concat(mq['dimensions'] + mq['metrics'])
      ids.concat((mq['sorts'] || []).map { |s| s['fieldId'] })
      filter_rules(mq['filters']).each { |r| ids << r['target']['fieldId'] }
      cfg = c['chartConfig']['config'] || {}
      if (l = cfg['layout'])
        ids << l['xField']
        ids.concat(Array(l['yField']))
      end
      ((cfg['eChartsConfig'] || {})['series'] || []).each do |s|
        ids << s['encode']['xRef']['field'] << s['encode']['yRef']['field']
      end
      ids.concat(Array(cfg['groupFieldIds']))
      ids << cfg['metricId'] << cfg['selectedField']
      ids.concat((c['tableConfig'] || {})['columnOrder'] || [])
      ids.compact.each do |id|
        assert fields.key?(id) || calcs.include?(id), "#{c['slug']}: field id #{id} does not resolve"
      end
      (mq['dimensions']).each { |d| assert_equal :dimension, fields[d], "#{c['slug']}: #{d} not a dimension" }
      (mq['metrics']).each { |m| assert_equal :metric, fields[m], "#{c['slug']}: #{m} not a metric" }
      mq['tableCalculations']&.each do |t|
        t['sql'].scan(/\$\{([a-z_]+)\.([a-z_]+)\}/).each do |tbl, f|
          assert fields.key?("#{tbl}_#{f}"), "#{c['slug']}: calc #{t['name']} refs ${#{tbl}.#{f}}"
        end
      end
    end
  end

  POST_CALC_TYPES = %w[percent_of_total percent_of_previous running_total].freeze

  # Model-level and column-level metrics; number and post-calc metrics may
  # reference other metrics (post-calc `sql` is `${other_metric}`).
  def test_metric_sql_references_resolve
    models.each_value do |m|
      names = own_fields(m)
      all = (meta_of(m)['metrics'] || {}).to_a
      m['columns'].each { |c| all.concat((meta_of(c)['metrics'] || {}).to_a) }
      all.each do |n, d|
        if POST_CALC_TYPES.include?(d['type'])
          assert d['sql'], "#{m['name']}.#{n}: post-calc metric needs sql: ${other_metric}"
        end
        (d['sql'] || '').scan(/\$\{([a-z_]+)\}/).flatten.each do |ref|
          assert_equal :metric, names[ref], "#{m['name']}.#{n}: ${#{ref}} is not a metric"
          assert((%w[number] + POST_CALC_TYPES).include?(d['type']),
                 "#{m['name']}.#{n}: only number/post-calc metrics reference metrics")
        end
      end
    end
  end

  def test_metric_filters_reference_dimensions
    models.each_value do |m|
      names = own_fields(m)
      m['columns'].each do |col|
        (meta_of(col)['metrics'] || {}).each do |n, d|
          (d['filters'] || []).each do |f|
            f.each_key { |k| assert_equal :dimension, names[k], "#{m['name']}.#{n}: filter on unknown dim #{k}" }
          end
        end
      end
    end
  end

  def test_slugs_unique_and_dashboard_tiles_resolve
    slugs = charts.map { |c| c['slug'] }
    assert_equal slugs.uniq, slugs
    all_fields = charts.flat_map { |c| explore_fields(c['metricQuery']['exploreName']).keys }.to_set
    dashboards.each do |d|
      tab_ids = d['tabs'].map { |t| t['uuid'] }
      assert_equal 2, tab_ids.size
      chart_tiles = d['tiles'].select { |t| t['type'] == 'saved_chart' }
      assert_equal slugs.sort, chart_tiles.map { |t| t['properties']['chartSlug'] }.sort, 'every chart is tiled'
      assert d['tiles'].any? { |t| t['type'] == 'markdown' }
      d['tiles'].each do |t|
        assert_includes tab_ids, t['tabUuid']
        assert_operator t['x'] + t['w'], :<=, 36, 'tile exceeds 36-col grid'
        next unless t['type'] == 'saved_chart'
        assert_includes slugs, t['properties']['chartSlug']
        assert_equal t['properties']['chartSlug'], t['tileSlug']
      end
      tile_slugs = chart_tiles.map { |t| t['tileSlug'] }
      filters = d['filters']['dimensions']
      assert filters.any? { |f| (f['tileTargets'] || {}).empty? }, 'need an all-tiles filter'
      assert filters.any? { |f| !(f['tileTargets'] || {}).empty? }, 'need a tileTargets filter'
      filters.each do |f|
        assert_includes all_fields, f['target']['fieldId']
        (f['tileTargets'] || {}).each do |slug, tgt|
          assert_includes tile_slugs, slug
          assert_includes all_fields, tgt['fieldId'] if tgt.is_a?(Hash)
        end
      end
    end
  end

  def test_manifest_has_relation_for_every_model
    assert_equal 'bigquery', manifest['metadata']['adapter_type']
    models.each_key do |n|
      node = manifest['nodes']["model.jaffle_shop.#{n}"]
      refute_nil node, "manifest missing #{n}"
      assert_equal "`#{node['database']}`.`#{node['schema']}`.`#{node['alias']}`", node['relation_name']
    end
    assert_equal 'jaffle_shop', load_yaml(File.join(ROOT, 'dbt/dbt_project.yml'))['name']
  end

  def test_fixture_covers_required_features
    orders = models.fetch('orders')
    assert orders['config']['meta'], 'orders uses config.meta'
    assert models.fetch('customers')['meta'], 'customers uses legacy meta'
    assert meta_of(orders)['sql_filter'].include?('lightdash.attributes.region')
    rels = meta_of(orders)['joins'].map { |j| [j['join'], j['relationship']] }
    assert_equal [%w[customers many-to-one], %w[payments one-to-many]], rels
    types = orders['columns'].flat_map { |c| (meta_of(c)['metrics'] || {}).values.map { |m| m['type'] } }
    %w[sum count count_distinct average min max median percent_of_total].each { |t| assert_includes types, t }
    assert_equal 'number', meta_of(orders)['metrics']['completion_rate']['type']
    dims = orders['columns'].map { |c| meta_of(c)['dimension'] }.compact
    assert dims.any? { |d| d['hidden'] }
    assert dims.any? { |d| d['sql'] }
    assert dims.any? { |d| d['required_attributes'] }
    assert orders['columns'].any? { |c| meta_of(c)['additional_dimensions'] }
    kinds = charts.map { |c| c['chartConfig']['type'] }
    %w[cartesian table big_number pie].each { |k| assert_includes kinds, k }
    assert charts.any? { |c| c['chartConfig']['config'].dig('layout', 'flipAxes') }
    assert charts.any? { |c| !(c['metricQuery']['tableCalculations'] || []).empty? }
  end
end
