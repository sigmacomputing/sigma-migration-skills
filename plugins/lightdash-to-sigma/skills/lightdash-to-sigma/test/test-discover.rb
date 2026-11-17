#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for lightdash-discover.rb (fake transport) and the compiled-explore model loader.
#
#   ruby test/test-discover.rb

require 'minitest/autorun'
require 'json'
require 'yaml'
require 'tmpdir'
require 'date'
require_relative '../scripts/lightdash-discover'
require_relative '../scripts/lib/lightdash_model'
require_relative '../scripts/lib/lightdash_export'
require_relative '../scripts/convert-dm'

class DiscoverTest < Minitest::Test
  FIXTURE = File.expand_path('../fixtures/jaffle-orders', __dir__)
  PROJECT = 'proj-uuid'

  def yml(path)
    YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [Date, Time], aliases: true)
  end

  def fake_client(calls = [], dashboards: nil, extra_charts: [])
    dash = yml(File.join(FIXTURE, 'lightdash/dashboards/jaffle-overview.yml'))
    charts = Dir.glob(File.join(FIXTURE, 'lightdash/charts/*.yml')).sort.map { |f| yml(f) } + extra_charts
    explore = JSON.parse(File.read(File.join(FIXTURE, 'explores/orders.json')))['results']
    routes = {
      "/api/v1/projects/#{PROJECT}/dashboards/code" => { 'dashboards' => dashboards || [dash] },
      "/api/v1/projects/#{PROJECT}/charts/code" => { 'charts' => charts },
      "/api/v1/projects/#{PROJECT}/explores/orders" => explore,
      '/api/v1/org' => { 'organizationUuid' => 'o', 'name' => 'Acme' }
    }
    t = lambda do |_verb, uri, _headers, _body|
      calls << uri.path
      r = routes[uri.path]
      r ? [200, JSON.generate('status' => 'ok', 'results' => r)] : [404, '{"status":"error","error":{"name":"NotFound"}}']
    end
    LightdashRest::Client.new(base_url: 'https://ld.test', api_key: 'k', transport: t)
  end

  def test_discover_writes_download_layout_and_explores
    Dir.mktmpdir do |out|
      calls = []
      m = LightdashDiscover.discover(fake_client(calls), project: PROJECT, dashboard: 'jaffle-overview', out_dir: out)
      assert_equal 6, m['charts'].length
      assert_equal ['orders'], m['explores']
      assert_empty m['warnings']
      assert File.file?(File.join(out, 'lightdash/dashboards/jaffle-overview.yml'))
      assert_equal 6, Dir.glob(File.join(out, 'lightdash/charts/*.yml')).length
      assert File.file?(File.join(out, 'explores/orders.json'))
      assert File.file?(File.join(out, 'manifest.json'))
      assert(calls.all? { |c| c.start_with?('/api/v1/projects/') }, calls.inspect)
      # the offline converter consumes the written layout unchanged
      dash = LightdashExport.load(File.join(out, 'lightdash/dashboards/jaffle-overview.yml'), File.join(out, 'lightdash/charts'))
      assert_equal 'Jaffle Overview', dash['name']
      refute(dash['tiles'].any? { |t| t['kind'] == 'chart' && t['chart'].nil? }, 'every chart tile resolved')
    end
  end

  def test_discover_filters_charts_to_the_dashboard
    Dir.mktmpdir do |out|
      stray = { 'name' => 'Stray', 'slug' => 'stray', 'tableName' => 'orders', 'metricQuery' => { 'exploreName' => 'orders' } }
      m = LightdashDiscover.discover(fake_client([], extra_charts: [stray]), project: PROJECT, dashboard: 'jaffle-overview', out_dir: out)
      refute_includes m['charts'], 'stray'
      refute File.exist?(File.join(out, 'lightdash/charts/stray.yml'))
    end
  end

  def test_unknown_dashboard_raises_and_missing_chart_warns
    Dir.mktmpdir do |out|
      assert_raises(LightdashDiscover::Error) do
        LightdashDiscover.discover(fake_client, project: PROJECT, dashboard: 'nope', out_dir: out)
      end
      dash = yml(File.join(FIXTURE, 'lightdash/dashboards/jaffle-overview.yml'))
      dash['tiles'] << { 'type' => 'saved_chart', 'properties' => { 'chartSlug' => 'ghost' } }
      m = LightdashDiscover.discover(fake_client([], dashboards: [dash]), project: PROJECT, dashboard: 'jaffle-overview', out_dir: out)
      assert_match(/ghost/, m['warnings'].join)
    end
  end

  def test_probe_and_cli_run
    assert_match(/Acme/, LightdashDiscover.probe(fake_client))
    Dir.mktmpdir do |out|
      codes = nil
      capture_io do
        codes = [LightdashDiscover.run(['--project', PROJECT, '--dashboard', 'jaffle-overview', '--out-dir', out], client: fake_client),
                 LightdashDiscover.run(['--project', PROJECT], client: fake_client)]
      end
      assert_equal [0, 1], codes
    end
  end

  # ---- compiled-explore loader -------------------------------------------

  def test_explore_loader_matches_dbt_path_for_the_fixture
    a = LightdashModel.load(FIXTURE)
    b = LightdashModel.load_explores(File.join(FIXTURE, 'explores'))
    assert_equal 'bigquery', b['dialect']
    assert_empty b['warnings']
    _, _, fm_a = LightdashDm.build(a, 'orders', connection_id: 'c')
    envelope, _, fm_b = LightdashDm.build(b, 'orders', connection_id: 'c')
    assert_equal fm_a.keys.sort, fm_b.keys.sort
    assert_equal fm_a, fm_b
    assert_equal({ 'elements' => 4, 'columns' => 60, 'metrics' => 13 },
                 envelope['stats'].select { |k, _| %w[elements columns metrics].include?(k) })
    assert_equal ['acme-analytics', 'jaffle_shop', 'orders'], b['models']['orders']['relation']
    assert_equal envelope['security']['models'], LightdashDm.build(a, 'orders', connection_id: 'c')[0]['security']['models']
  end

  def write_explore(dir, tables, extra = {})
    ex = { 'name' => 'x', 'baseTable' => 'x', 'warehouse' => 'snowflake', 'joinedTables' => [], 'tables' => tables }.merge(extra)
    File.write(File.join(dir, 'x.json'), JSON.generate(ex))
  end

  def test_loader_falls_back_to_compiled_sql_with_a_warning_and_converts_filter_rules
    Dir.mktmpdir do |dir|
      write_explore(dir, 'x' => {
        'name' => 'x', 'database' => 'DB', 'schema' => 'S',
        'dimensions' => { 'status' => { 'type' => 'string', 'compiledSql' => '"x".status' } },
        'metrics' => { 'paid' => { 'type' => 'sum', 'compiledSql' => 'SUM("x".amount)', 'sql' => '${TABLE}.amount',
                                   'filters' => [{ 'target' => { 'fieldRef' => 'status' }, 'operator' => 'notEquals', 'values' => ['void'] },
                                                 { 'target' => { 'fieldRef' => 'status' }, 'operator' => 'weirdOp', 'values' => ['q'] }] } }
      })
      m = LightdashModel.load_explores(dir)
      assert_match(/status.*only compiledSql/, m['warnings'].join("\n"))
      assert_match(/weirdOp/, m['warnings'].join("\n"))
      x = m['models']['x']
      assert_equal ['DB', 'S', 'x'], x['relation']
      assert x['dimensions'][0]['plain'], 'compiled sql with the table alias is rewritten to ${TABLE}.status'
      assert_equal [{ 'status' => '!void' }, { 'status' => 'unsupportedOperator weirdOp q' }], x['metrics'][0]['filters']
      assert_equal 'snowflake', m['dialect']
    end
  end

  def test_loader_errors_are_explicit
    Dir.mktmpdir do |dir|
      assert_raises(LightdashModel::Error) { LightdashModel.load_explores(dir) } # no explores
      write_explore(dir, 'x' => { 'name' => 'x', 'dimensions' => {}, 'metrics' => {} })
      assert_raises(LightdashModel::Error) { LightdashModel.load_explores(dir) } # no relation
      # snowflake/bigquery/databricks need database.schema.table: a 2-part path is refused, naming the flag
      e = assert_raises(LightdashModel::Error) { LightdashModel.load_explores(dir, default_schema: 'S') }
      assert_match(/3-part.*--default-database/m, e.message)
      m = LightdashModel.load_explores(dir, default_database: 'D', default_schema: 'S')
      assert_equal %w[D S x], m['models']['x']['relation']
    end
    assert_raises(LightdashModel::Error) { LightdashModel.load_explores('/nonexistent/explores') }
  end
end
