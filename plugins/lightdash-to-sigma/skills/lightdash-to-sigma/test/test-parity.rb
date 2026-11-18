#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for lightdash-query-oracle.rb and verify-lightdash-parity.rb
# (fake Lightdash transport, fake Sigma export; no network).
#
#   ruby test/test-parity.rb

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'
require_relative '../scripts/lightdash-query-oracle'
require_relative '../scripts/verify-lightdash-parity'
require_relative '../scripts/convert-dm'
require_relative '../scripts/build-lightdash-workbook'
require 'fileutils'

class ParityTest < Minitest::Test
  SCRIPTS = File.expand_path('../scripts', __dir__)

  WORKBOOK_MAP = {
    'monthly-revenue' => {
      'element_id' => 'el-monthly-revenue', 'kind' => 'line-chart', 'limit' => 500,
      'fields' => %w[orders_order_date_month orders_total_order_amount],
      'columns' => { 'orders_order_date_month' => { 'id' => 'c1', 'name' => 'Order Date Month' },
                     'orders_total_order_amount' => { 'id' => 'c2', 'name' => 'Total Order Amount' } }
    },
    'total-orders-kpi' => { 'element_id' => 'el-kpi', 'kind' => 'kpi-chart', 'fields' => ['orders_total_orders'],
                            'columns' => { 'orders_total_orders' => { 'id' => 'c3', 'name' => 'Orders' } } },
    'about' => { 'element_id' => 'el-about', 'kind' => 'text', 'placeholder' => true, 'fields' => [] }
  }.freeze
  CHARTS = {
    'monthly-revenue' => { 'tableName' => 'orders', 'metricQuery' => { 'exploreName' => 'orders', 'limit' => 500,
                                                                       'dimensions' => ['orders_order_date_month'], 'metrics' => ['orders_total_order_amount'] } },
    'total-orders-kpi' => { 'tableName' => 'orders', 'metricQuery' => { 'exploreName' => 'orders', 'limit' => 1, 'metrics' => ['orders_total_orders'] } }
  }.freeze
  FIELD_MAP = { 'orders_total_orders' => { 'name' => 'Total Orders' } }.freeze

  def fake_lightdash(calls = [], fail_on: nil)
    t = lambda do |_verb, uri, _headers, body|
      calls << [uri.path, body && JSON.parse(body)]
      next [500, 'boom'] if fail_on && uri.path.include?(fail_on) && uri.path.end_with?('runQuery')
      if uri.path.end_with?('runQuery')
        rows = if body.include?('orders_order_date_month')
                 [{ 'orders_order_date_month' => { 'value' => { 'raw' => '2026-01-01', 'formatted' => 'Jan 2026' } },
                    'orders_total_order_amount' => { 'value' => { 'raw' => 1500.5, 'formatted' => '$1,501' } } },
                  { 'orders_order_date_month' => { 'value' => { 'raw' => '2026-02-01', 'formatted' => 'Feb 2026' } },
                    'orders_total_order_amount' => { 'value' => 20 } }]
               else
                 [{ 'orders_total_orders' => 42 }]
               end
        [200, JSON.generate('status' => 'ok', 'results' => { 'rows' => rows })]
      else
        [200, JSON.generate('status' => 'ok', 'results' => 'SELECT 1 /* compiled */')]
      end
    end
    LightdashRest::Client.new(base_url: 'https://ld.test', api_key: 'k', transport: t)
  end

  def run_oracle(dir, **kw)
    LightdashOracle.run(fake_lightdash(kw[:calls] || [], fail_on: kw[:fail_on]), project: 'p', workbook_map: WORKBOOK_MAP, charts: CHARTS,
                                                                          field_map: FIELD_MAP, out_dir: dir)
  end

  def test_oracle_saves_rows_keyed_by_sigma_column_names_and_compiled_sql
    Dir.mktmpdir do |dir|
      calls = []
      res = run_oracle(dir, calls: calls)
      assert_equal %w[monthly-revenue total-orders-kpi], res['ok']
      assert_equal({ 'about' => 'placeholder element (no data chart)' }, res['skipped'])
      exp = JSON.parse(File.read(File.join(dir, 'monthly-revenue.json'), encoding: 'UTF-8'))
      assert_equal ['Order Date Month', 'Total Order Amount'], exp['columns']
      assert_equal [{ 'Order Date Month' => '2026-01-01', 'Total Order Amount' => 1500.5 },
                    { 'Order Date Month' => '2026-02-01', 'Total Order Amount' => 20 }], exp['rows']
      assert_equal 500, exp['limit']
      assert_equal [{ 'Orders' => 42 }], JSON.parse(File.read(File.join(dir, 'total-orders-kpi.json'), encoding: 'UTF-8'))['rows']
      assert_equal "SELECT 1 /* compiled */\n", File.read(File.join(dir, 'monthly-revenue.sql'), encoding: 'UTF-8')
      run = calls.find { |path, _| path.end_with?('/explores/orders/runQuery') }
      assert_equal 500, run[1]['limit'], 'limit preserved in the runQuery body'
      assert_equal '/api/v1/projects/p/explores/orders/runQuery', run[0]
    end
  end

  def test_oracle_records_failures
    Dir.mktmpdir do |dir|
      res = run_oracle(dir, fail_on: 'orders')
      assert_equal %w[monthly-revenue total-orders-kpi], res['failed'].keys
      assert_match(/HTTP 500/, res['failed']['monthly-revenue'])
      refute File.exist?(File.join(dir, 'monthly-revenue.json'))
    end
  end

  CSV_OK = "Order Date Month,Total Order Amount\n2026-02-01 00:00:00,20\n2026-01-01 00:00:00,\"$1,500.50\"\n"

  def exporter(map)
    ->(id) { map.fetch(id) }
  end

  def verify_with(dir, csvs)
    LightdashParity.verify(WORKBOOK_MAP, dir, exporter(csvs)).each_with_object({}) { |r, h| h[r['chart']] = r }
  end

  def test_pass_fail_and_skip
    Dir.mktmpdir do |dir|
      run_oracle(dir)
      r = verify_with(dir, 'el-monthly-revenue' => CSV_OK, 'el-kpi' => "Orders\n41\n")
      assert_equal 'PASS', r['monthly-revenue']['status'], r['monthly-revenue']['reason']
      assert_equal 'FAIL', r['total-orders-kpi']['status']
      assert_match(/Lightdash 42, Sigma "41"/, r['total-orders-kpi']['reason'])
      assert_equal 'SKIP', r['about']['status']
      assert_match(/gap: placeholder/, r['about']['reason'])
    end
  end

  def test_mismatch_modes
    Dir.mktmpdir do |dir|
      run_oracle(dir)
      r = verify_with(dir, 'el-monthly-revenue' => "Order Date Month,Total Order Amount\n2026-01-01,1500.50\n", 'el-kpi' => "Wrong\n42\n")
      assert_match(/row count: Lightdash 2, Sigma 1/, r['monthly-revenue']['reason'])
      assert_match(/column\(s\) absent.*Orders/, r['total-orders-kpi']['reason'])
      r = verify_with(dir, 'el-monthly-revenue' => "Order Date Month,Total Order Amount\n2026-01-01,1500.50\n2026-02-01,21\n", 'el-kpi' => "Orders\n42\n")
      assert_equal 'FAIL', r['monthly-revenue']['status']
      assert_match(/column Total Order Amount/, r['monthly-revenue']['reason'])
    end
  end

  def test_export_error_is_a_fail_with_reason
    Dir.mktmpdir do |dir|
      run_oracle(dir)
      boom = ->(_id) { raise 'export poll timed out (60s)' }
      r = LightdashParity.verify(WORKBOOK_MAP, dir, boom).first
      assert_equal 'FAIL', r['status']
      assert_match(/timed out/, r['reason'])
    end
  end

  def test_tolerances
    assert LightdashParity.cell_equal?(1500.5, '$1,500.50')
    assert LightdashParity.cell_equal?(100.0, '100.004')
    refute LightdashParity.cell_equal?(100.0, '100.01')
    assert LightdashParity.cell_equal?('2026-03-01T00:00:00.000Z', '2026-03-01 00:00:00')
    assert LightdashParity.cell_equal?(nil, '')
    refute LightdashParity.cell_equal?('a', 'b')
  end

  def test_final_summary_requires_a_pass_and_no_fail
    s = LightdashParity.final_summary([{ 'chart' => 'a', 'status' => 'PASS' }, { 'chart' => 'b', 'status' => 'SKIP' }], workbook_id: 'w', verified_against: 'x')
    assert_equal 'PASS', s['status']
    assert_equal 1, s['charts_total']
    assert_equal ['b'], s['skip_names']
    assert_equal 'FAIL', LightdashParity.final_summary([{ 'chart' => 'a', 'status' => 'SKIP' }], workbook_id: 'w', verified_against: 'x')['status']
    assert_equal 'FAIL', LightdashParity.final_summary([{ 'chart' => 'a', 'status' => 'PASS' }, { 'chart' => 'b', 'status' => 'FAIL' }], workbook_id: 'w', verified_against: 'x')['status']
  end

  def cli(*args, dir)
    Open3.capture3(RbConfig.ruby, File.join(SCRIPTS, 'verify-lightdash-parity.rb'), '--workbook-id', 'wb1',
                   '--workbook-map', File.join(dir, 'workbook-map.json'), '--expected-dir', File.join(dir, 'expected'),
                   '--out', File.join(dir, 'parity-report.json'), '--final-out', File.join(dir, 'parity-final.json'), *args)
  end

  def test_cli_online_writes_report_and_marker
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'workbook-map.json'), JSON.generate(WORKBOOK_MAP))
      run_oracle(File.join(dir, 'expected'))
      File.write(File.join(dir, 'fx.json'), JSON.generate('el-monthly-revenue' => CSV_OK, 'el-kpi' => "Orders\n42\n"))
      _o, _e, st = cli('--fixture', File.join(dir, 'fx.json'), dir)
      assert_equal 0, st.exitstatus
      final = JSON.parse(File.read(File.join(dir, 'parity-final.json'), encoding: 'UTF-8'))
      assert_equal 'PASS', final['status']
      assert_equal 'lightdash_runquery', final['verified_against']
      assert_equal %w[monthly-revenue total-orders-kpi], final['pass_names']
      report = JSON.parse(File.read(File.join(dir, 'parity-report.json'), encoding: 'UTF-8'))
      assert_equal({ 'pass' => 2, 'fail' => 0, 'skip' => 1 }, report['counts'])
      File.write(File.join(dir, 'fx.json'), JSON.generate('el-monthly-revenue' => CSV_OK, 'el-kpi' => "Orders\n1\n"))
      _o, _e, st = cli('--fixture', File.join(dir, 'fx.json'), dir)
      assert_equal 2, st.exitstatus
    end
  end

  def test_cli_offline_without_sql_skips_everything_and_fails_the_marker
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'workbook-map.json'), JSON.generate(WORKBOOK_MAP))
      _o, err, st = cli(dir)
      assert_equal 2, st.exitstatus
      assert_match(/SKIP  monthly-revenue: no Lightdash oracle rows and no compiled SQL/, err)
      final = JSON.parse(File.read(File.join(dir, 'parity-final.json'), encoding: 'UTF-8'))
      assert_equal 'FAIL', final['status']
      assert_equal 'warehouse', final['verified_against']
      assert_equal 0, final['charts_total']
    end
  end

  def test_cli_offline_warehouse_only_delegates_to_verify_warehouse
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'workbook-map.json'), JSON.generate(WORKBOOK_MAP))
      spec = { 'name' => 'W', 'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
        { 'id' => 'el-monthly-revenue', 'kind' => 'visualization', 'columns' => [{ 'id' => 'c1', 'name' => 'Order Date Month' }, { 'id' => 'c2', 'name' => 'Total Order Amount' }] },
        { 'id' => 'el-kpi', 'kind' => 'visualization', 'columns' => [{ 'id' => 'c3', 'name' => 'Orders' }] }
      ] }] }
      File.write(File.join(dir, 'wb-spec.json'), JSON.generate(spec))
      File.write(File.join(dir, 'whfx.json'), JSON.generate('el-monthly-revenue' => CSV_OK, 'el-kpi' => "Orders\n42\n"))
      _o, _e, st = cli('--warehouse-only', '--workbook-spec', File.join(dir, 'wb-spec.json'), '--wh-fixture', File.join(dir, 'whfx.json'), dir)
      assert_equal 0, st.exitstatus
      final = JSON.parse(File.read(File.join(dir, 'parity-final.json'), encoding: 'UTF-8'))
      assert_equal 'warehouse', final['verified_against']
      assert_equal 'PASS', final['status']
      assert_equal 2, final['charts_pass']
      assert_equal ['about'], final['skip_names']
    end
  end

  # ---- review fixes ----------------------------------------------------------

  def test_builder_records_applied_filters_per_chart
    fixture = File.expand_path('../fixtures/jaffle-orders', __dir__)
    env, _s, fm = LightdashDm.build(LightdashModel.load(fixture), 'orders', connection_id: 'c')
    dash = LightdashExport.load(File.join(fixture, 'lightdash/dashboards/jaffle-overview.yml'), File.join(fixture, 'lightdash/charts'))
    map = LightdashWorkbook.build(dash, JSON.parse(JSON.generate(fm)), JSON.parse(JSON.generate(env)), dm_id: 'd')['map']
    region = { 'fieldId' => 'orders_region', 'operator' => 'equals', 'values' => %w[north south] }
    segment = { 'fieldId' => 'customers_segment', 'operator' => 'equals', 'values' => ['Enterprise'] }
    map.each do |slug, e|
      next if e['placeholder']
      expected = %w[monthly-revenue revenue-by-segment].include?(slug) ? [region, segment] : [region]
      assert_equal expected, e['applied_filters'], slug
    end
  end

  def test_oracle_merges_applied_filters_as_and_rules
    Dir.mktmpdir do |dir|
      calls = []
      map = { 'monthly-revenue' => WORKBOOK_MAP['monthly-revenue'].merge('applied_filters' => [
        { 'fieldId' => 'orders_region', 'operator' => 'equals', 'values' => %w[north south] }]) }
      charts = { 'monthly-revenue' => CHARTS['monthly-revenue'].merge(
        'metricQuery' => CHARTS['monthly-revenue']['metricQuery'].merge('filters' => { 'dimensions' => { 'id' => 'x', 'and' => [{ 'id' => 'r1' }] } })) }
      LightdashOracle.run(fake_lightdash(calls), project: 'p', workbook_map: map, charts: charts, field_map: FIELD_MAP, out_dir: dir)
      body = calls.find { |path, _| path.end_with?('runQuery') }[1]
      group = body['filters']['dimensions']
      assert_equal [{ 'id' => 'x', 'and' => [{ 'id' => 'r1' }] }], group['and'].first(1)
      rule = group['and'].last
      assert_equal({ 'fieldId' => 'orders_region' }, rule['target'])
      assert_equal %w[north south], rule['values']
      assert_equal 500, body['limit']
      assert_equal 1, JSON.parse(File.read(File.join(dir, 'monthly-revenue.json'), encoding: 'UTF-8'))['applied_filters'].length
    end
  end

  def test_oracle_skipped_data_chart_is_not_silent
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'workbook-map.json'), JSON.generate(WORKBOOK_MAP))
      File.write(File.join(dir, 'charts.yml'), '')
      res = LightdashOracle.run(fake_lightdash, project: 'p', workbook_map: WORKBOOK_MAP, charts: {}, field_map: FIELD_MAP, out_dir: File.join(dir, 'e'))
      assert_equal 'chart YAML not found', res['skipped']['monthly-revenue']
      # CLI: charts dir without those charts -> exit 3 (needs creds, so run through the library gate in verify instead)
      r = LightdashParity.verify(WORKBOOK_MAP, File.join(dir, 'none'), ->(_) { "" })
      assert_equal %w[FAIL FAIL SKIP], r.map { |x| x['status'] }
    end
  end

  def test_oracle_cli_exits_3_on_skipped_data_chart
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'm.json'), JSON.generate(WORKBOOK_MAP))
      File.write(File.join(dir, 'fm.json'), '{}')
      FileUtils.mkdir_p(File.join(dir, 'charts'))
      env = { 'LIGHTDASH_URL' => 'https://127.0.0.1:9', 'LIGHTDASH_API_KEY' => 'k' }
      _o, err, st = Open3.capture3(env, RbConfig.ruby, File.join(SCRIPTS, 'lightdash-query-oracle.rb'), '--project', 'p',
                                   '--workbook-map', File.join(dir, 'm.json'), '--charts-dir', File.join(dir, 'charts'),
                                   '--field-map', File.join(dir, 'fm.json'), '--out-dir', File.join(dir, 'e'))
      assert_equal 3, st.exitstatus
      assert_match(/FAILED monthly-revenue: data chart skipped/, err)
      refute_match(/FAILED about/, err)
    end
  end

  def test_unsorted_limit_is_skipped_with_reason
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'monthly-revenue.json'), JSON.generate('columns' => ['A'], 'rows' => [{ 'A' => 1 }], 'limit' => 1, 'unsorted_limit' => true))
      map = { 'monthly-revenue' => WORKBOOK_MAP['monthly-revenue'] }
      r = LightdashParity.verify(map, dir, ->(_) { raise 'must not export' }).first
      assert_equal 'SKIP', r['status']
      assert_match(/without a total-order sort/, r['reason'])
      mq = { 'exploreName' => 'orders', 'limit' => 2, 'dimensions' => ['orders_order_date_month'], 'metrics' => ['orders_total_order_amount'], 'sorts' => [] }
      run_oracle(File.join(dir, 'o'))
      LightdashOracle.run(fake_lightdash, project: 'p', workbook_map: map, charts: { 'monthly-revenue' => { 'metricQuery' => mq } },
                                          field_map: FIELD_MAP, out_dir: File.join(dir, 'o2'))
      assert_equal true, JSON.parse(File.read(File.join(dir, 'o2', 'monthly-revenue.json'), encoding: 'UTF-8'))['unsorted_limit']
    end
  end

  # runQuery returns `rows`; compileQuery a stub. For M7 (non-total sorts at the row limit).
  def rows_client(rows)
    t = lambda do |_v, uri, _h, _b|
      [200, JSON.generate('status' => 'ok', 'results' => uri.path.end_with?('runQuery') ? { 'rows' => rows } : 'SELECT 1')]
    end
    LightdashRest::Client.new(base_url: 'https://ld.test', api_key: 'k', transport: t)
  end

  def oracle_flag(mq, rows)
    Dir.mktmpdir do |dir|
      map = { 'monthly-revenue' => WORKBOOK_MAP['monthly-revenue'] }
      LightdashOracle.run(rows_client(rows), project: 'p', workbook_map: map, charts: { 'monthly-revenue' => { 'metricQuery' => mq } },
                                              field_map: FIELD_MAP, out_dir: dir)
      JSON.parse(File.read(File.join(dir, 'monthly-revenue.json'), encoding: 'UTF-8'))['unsorted_limit']
    end
  end

  def test_non_total_order_sorts_at_the_limit_are_flagged_unsorted
    rows = [{ 'orders_order_date_month' => '2026-01-01', 'orders_total_order_amount' => 5 },
            { 'orders_order_date_month' => '2026-02-01', 'orders_total_order_amount' => 5 }]
    base = { 'exploreName' => 'orders', 'limit' => 2, 'dimensions' => %w[orders_order_date_month orders_status], 'metrics' => ['orders_total_order_amount'] }
    # sort on one of two dimensions / a metric with ties among the returned rows: not a total order
    assert_equal true, oracle_flag(base.merge('sorts' => [{ 'fieldId' => 'orders_total_order_amount', 'descending' => true }]), rows)
    # a metric sort whose keys are all distinct is trusted
    distinct = [rows[0], rows[1].merge('orders_total_order_amount' => 6)]
    assert_nil oracle_flag(base.merge('sorts' => [{ 'fieldId' => 'orders_total_order_amount', 'descending' => true }]), distinct)
    # sorting on every dimension is a total order even with equal metrics
    assert_nil oracle_flag(base.merge('sorts' => base['dimensions'].map { |d| { 'fieldId' => d } }), rows)
    # below the limit nothing is cut, so nothing is flagged
    assert_nil oracle_flag(base.merge('limit' => 3, 'sorts' => []), rows)
  end

  def test_percent_and_compact_formats
    assert LightdashParity.cell_equal?(0.125, '12.5%')
    refute LightdashParity.cell_equal?(0.125, '13.5%')
    assert LightdashParity.cell_equal?(1234, '1.2K')
    assert LightdashParity.cell_equal?(2_500_000, '2.5M')
    refute LightdashParity.cell_equal?(1234, '1.5K')
  end
end
