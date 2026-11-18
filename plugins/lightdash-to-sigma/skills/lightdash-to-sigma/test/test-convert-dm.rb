#!/usr/bin/env ruby
# frozen_string_literal: true
# Tests for LightdashModel (loader) and convert-dm.rb (LightdashDm.build + CLI)
# against fixtures/jaffle-orders and small inline projects.
#
#   ruby test/test-convert-dm.rb

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'open3'
require_relative '../scripts/convert-dm'

class ConvertDmTest < Minitest::Test
  SKILL = File.expand_path('..', __dir__)
  FIXTURE = File.join(SKILL, 'fixtures', 'jaffle-orders')
  CLI = File.join(SKILL, 'scripts', 'convert-dm.rb')
  CONN = '11111111-2222-3333-4444-555555555555'

  # -> [envelope, field_map]
  def convert(dir = FIXTURE, explore = 'orders', **load_opts)
    env, _sig, fm = convert_all(dir, explore, **load_opts)
    [env, fm]
  end

  # -> [envelope, signature, field_map]
  def convert_all(dir = FIXTURE, explore = 'orders', **load_opts)
    lm = LightdashModel.load(dir, **load_opts)
    LightdashDm.build(lm, explore, connection_id: CONN)
  end

  def test_two_part_path_on_a_three_part_dialect_is_refused_naming_default_database
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src')
      FileUtils.cp_r(FIXTURE, src)
      FileUtils.rm_f(File.join(src, 'dbt/target/manifest.json'))
      e = assert_raises(LightdashModel::Error) { LightdashModel.load(src, dialect: 'bigquery', default_schema: 'jaffle_shop') }
      assert_match(/bigquery needs a 3-part table path.*--default-database/m, e.message)
      lm = LightdashModel.load(src, dialect: 'bigquery', default_database: 'proj', default_schema: 'jaffle_shop')
      assert_equal %w[proj jaffle_shop orders], lm['models']['orders']['relation']
    end
  end

  def elements(env)
    env['sigmaDataModel']['pages'][0]['elements']
  end

  def el(env, id)
    elements(env).find { |e| e['id'] == id }
  end

  def explore_el(env)
    el(env, 'el-explore-orders')
  end

  def metric(env, id)
    explore_el(env)['metrics'].find { |m| m['id'] == id }
  end

  # ---- fixture: elements, relations, dialect ---------------------------------
  def test_element_paths_are_bigquery_three_part_with_original_case
    env, = convert
    paths = elements(env).select { |e| e['source']['kind'] == 'warehouse-table' }.map { |e| e['source']['path'] }
    assert_equal [%w[acme-analytics jaffle_shop orders], %w[acme-analytics jaffle_shop customers],
                  %w[acme-analytics jaffle_shop payments]], paths
    assert_equal 'bigquery', env['dialect']
    elements(env).select { |e| e['source']['kind'] == 'warehouse-table' }.each do |e|
      assert_equal CONN, e['source']['connectionId']
    end
    assert_equal 'orders', el(env, 'el-orders')['name'], 'BigQuery element name keeps the table case'
  end

  def test_relationships_count_and_types
    env, = convert
    rels = el(env, 'el-orders')['relationships']
    assert_equal 2, rels.length
    by_name = rels.each_with_object({}) { |r, h| h[r['name']] = r }
    assert_equal 'N:1', by_name['Customers']['relationshipType']
    assert_equal '1:N', by_name['Payments']['relationshipType']
    assert_equal 'el-customers', by_name['Customers']['targetElementId']
    assert_equal [{ 'sourceColumnId' => 'col-orders-customer_id', 'targetColumnId' => 'col-customers-customer_id' }],
                 by_name['Customers']['keys']
    assert_equal [{ 'sourceColumnId' => 'col-orders-order_id', 'targetColumnId' => 'col-payments-order_id' }],
                 by_name['Payments']['keys']
    assert_equal 2, env['stats']['relationships']
    assert_nil el(env, 'el-customers')['relationships']
  end

  def test_every_relationship_key_is_a_real_column
    env, = convert
    ids = elements(env).each_with_object({}) { |e, h| h[e['id']] = e['columns'].map { |c| c['id'] } }
    el(env, 'el-orders')['relationships'].each do |r|
      r['keys'].each do |k|
        assert_includes ids['el-orders'], k['sourceColumnId']
        assert_includes ids[r['targetElementId']], k['targetColumnId']
      end
    end
  end

  def test_interval_columns_exist_and_resolve_to_datetrunc
    env, = convert
    cols = el(env, 'el-orders')['columns']
    %w[day week month quarter year].each do |iv|
      c = cols.find { |x| x['id'] == "col-orders-order_date_#{iv}" }
      refute_nil c, "interval #{iv}"
      assert_equal "Order Date #{iv.capitalize}", c['name']
      assert_equal %[DateTrunc("#{iv}", [Order Date])], c['formula']
    end
    explore = explore_el(env)['columns']
    refute_nil explore.find { |c| c['name'] == 'Order Date Month' }
  end

  def test_dimension_sql_and_hidden_columns
    env, = convert
    cols = el(env, 'el-orders')['columns']
    channel = cols.find { |c| c['id'] == 'col-orders-channel' }
    assert_equal 'Channel Group', channel['name']
    assert_equal 'If(In([orders/Channel], "web", "app"), "Online", "Offline")', channel['formula']
    yr = cols.find { |c| c['id'] == 'col-orders-order_year_str' }
    assert_equal 'Text(Year([orders/Order Date]))', yr['formula']
    assert cols.find { |c| c['id'] == 'col-orders-customer_id' }['hidden']
    assert cols.find { |c| c['id'] == 'col-orders-internal_notes' }['hidden']
    refute cols.find { |c| c['id'] == 'col-orders-status' }['hidden']
    assert_equal({ 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' },
                 cols.find { |c| c['id'] == 'col-orders-amount' }['format'])
  end

  def test_filtered_and_number_metric_formulas
    env, = convert
    assert_equal 'CountDistinctIf([Order Id], [Status] = "completed")', metric(env, 'met-orders-completed_orders')['formula']
    assert_equal 'SumIf([Amount], [Status] = "completed")', metric(env, 'met-orders-completed_amount')['formula']
    assert_equal 'SumIf([Amount], [Status] != "returned")', metric(env, 'met-orders-kept_amount')['formula']
    rate = metric(env, 'met-orders-completion_rate')
    assert_equal '(CountDistinctIf([Order Id], [Status] = "completed")) / NullIf((CountDistinct([Order Id])), 0)', rate['formula']
    assert_equal({ 'kind' => 'number', 'formatString' => '.1%' }, rate['format'])
    assert_equal 'Sum([Amount])', metric(env, 'met-orders-total_order_amount')['formula']
    assert_equal 'Median([Amount])', metric(env, 'met-orders-median_order_amount')['formula']
    assert_equal 'Count([Order Id])', metric(env, 'met-orders-order_rows')['formula']
    assert_equal 'Sum([Payment Amount])', metric(env, 'met-payments-total_payment_amount')['formula']
  end

  def test_joined_metric_uses_renamed_explore_column
    env, = convert
    assert_equal 'CountDistinct([Customers Customer Id])', metric(env, 'met-customers-customer_count')['formula']
    names = explore_el(env)['columns'].map { |c| c['name'] }
    assert_equal names.uniq.length, names.length, 'explore column names are unique'
  end

  def test_join_fields_allow_list_hides_columns_and_skips_fields
    env, fm = convert
    cols = explore_el(env)['columns']
    seg = cols.find { |c| c['id'] == 'ex-customers-segment' }
    refute seg['hidden']
    assert_equal '[orders/Customers/Customer Segment]', seg['formula']
    assert cols.find { |c| c['id'] == 'ex-customers-signup_date_month' }['hidden']
    assert_equal 'skipped', fm['customers_signup_date_month']['kind']
    assert_match(/join fields/, fm['customers_signup_date_month']['reason'])
    assert_equal 'skipped', fm['customers_customer_id']['kind']
    assert_equal 'dimension', fm['customers_segment']['kind']
    assert_equal 'metric', fm['customers_customer_count']['kind'], 'metric allow-listed by full name'
  end

  def test_percent_of_total_is_a_gap_not_a_metric
    env, fm = convert
    assert_nil metric(env, 'met-orders-pct_of_total_amount')
    assert_equal 'skipped', fm['orders_pct_of_total_amount']['kind']
    assert_equal 'metric', fm['orders_pct_of_total_amount']['was']
    assert_match(/percent_of_total/, fm['orders_pct_of_total_amount']['reason'])
    gap = env['gaps'].find { |g| g['item'] == 'metric orders.pct_of_total_amount' }
    refute_nil gap
    assert_equal 'scope-cut', gap['class']
    assert(env['warnings'].any? { |w| w.include?('pct_of_total_amount') })
    assert_equal env['gaps'].length, env['stats']['gaps']
  end

  def test_security_is_recorded_not_applied
    env, = convert
    sec = env['security']
    assert_equal 'orders', sec['explore']
    assert_includes sec['models']['orders']['sql_filter'], 'lightdash.attributes.region'
    margin = sec['column_required_attributes'].find { |c| c['field'] == 'margin' }
    assert_equal({ 'is_finance' => 'true' }, margin['required_attributes'])
    assert_equal 'ex-orders-margin', margin['column_id']
    refute_includes JSON.generate(env['sigmaDataModel']), 'sql_filter'
  end

  # ---- fixture: field-map ----------------------------------------------------
  def chart_field_ids(chart)
    mq = chart['metricQuery']
    ids = mq['dimensions'] + mq['metrics']
    ids.concat((mq['sorts'] || []).map { |s| s['fieldId'] })
    f = mq['filters']
    rules = if f.is_a?(Array) then f
            elsif f.is_a?(Hash) then f.values.flat_map { |g| g.is_a?(Hash) ? (g['and'] || g['or'] || []) : [] }
            else [] end
    ids.concat(rules.map { |r| r['target']['fieldId'] })
    cfg = chart['chartConfig']['config'] || {}
    if (l = cfg['layout'])
      ids << l['xField']
      ids.concat(Array(l['yField']))
    end
    ((cfg['eChartsConfig'] || {})['series'] || []).each do |s|
      ids << s['encode']['xRef']['field'] << s['encode']['yRef']['field']
    end
    ids.concat(Array(cfg['groupFieldIds']))
    ids << cfg['metricId'] << cfg['selectedField']
    ids.concat((chart['tableConfig'] || {})['columnOrder'] || [])
    calcs = (mq['tableCalculations'] || []).map { |t| t['name'] }
    ids.compact.uniq - calcs
  end

  def test_field_map_covers_every_fixture_chart_field_id
    _, fm = convert
    charts = Dir[File.join(FIXTURE, 'lightdash/charts/*.yml')].sort.map { |f| YAML.safe_load(File.read(f)) }
    assert_equal 6, charts.length
    charts.each do |c|
      chart_field_ids(c).each do |id|
        e = fm[id]
        refute_nil e, "#{c['slug']}: field id #{id} missing from field-map"
        refute_equal 'skipped', e['kind'], "#{c['slug']}: #{id} skipped (#{e['reason']})"
      end
    end
    dash = YAML.safe_load(File.read(File.join(FIXTURE, 'lightdash/dashboards/jaffle-overview.yml')))
    dash['filters']['dimensions'].each do |f|
      refute_nil fm[f['target']['fieldId']], "dashboard filter #{f['target']['fieldId']}"
    end
  end

  def test_field_map_entries_resolve_to_real_columns_and_metrics
    env, fm = convert
    explore = explore_el(env)
    fm.each do |id, e|
      next if e['kind'] == 'skipped'
      assert_equal 'el-explore-orders', e['element_id'], id
      if e['kind'] == 'metric'
        m = explore['metrics'].find { |x| x['id'] == e['column_id'] }
        refute_nil m, id
        assert_equal e['column_id'], e['metric_id']
        assert_equal m['name'], e['name']
      else
        c = explore['columns'].find { |x| x['id'] == e['column_id'] }
        refute_nil c, id
        assert_equal c['name'], e['name']
        src = el(env, e['source_element_id'])['columns'].find { |x| x['id'] == e['source_column_id'] }
        refute_nil src, "#{id} source column"
      end
    end
  end

  def test_field_map_entry_shapes
    _, fm = convert
    d = fm['orders_status']
    assert_equal %w[column_id element_id field format hidden kind model name source_column_id source_element_id table type].sort, d.keys.sort
    assert_equal 'dimension', d['kind']
    assert_equal 'orders', d['model']
    assert_equal 'Status', d['name']
    iv = fm['orders_order_date_month']
    assert_equal 'interval', iv['kind']
    assert_equal 'MONTH', iv['interval']
    assert_equal 'order_date', iv['base_field']
    assert_equal 'ex-orders-order_date_month', iv['column_id']
    m = fm['orders_total_order_amount']
    assert_equal 'metric', m['kind']
    assert_equal 'met-orders-total_order_amount', m['metric_id']
    assert_equal({ 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }, m['format'])
    assert_equal 'Sum', m['derivation']
    assert_nil fm['orders_order_date'], 'a date dimension with intervals has no bare field id'
    assert_equal 'customers', fm['customers_segment']['model']
  end

  def test_both_meta_forms_parsed
    lm = LightdashModel.load(FIXTURE)
    orders = lm['models']['orders']       # dbt >= 1.10 config.meta
    customers = lm['models']['customers'] # legacy meta
    assert_equal 'Orders', orders['label']
    assert_equal 'Customers', customers['label']
    assert(orders['metrics'].any? { |m| m['name'] == 'completion_rate' && m['level'] == 'model' })
    assert(orders['metrics'].any? { |m| m['name'] == 'total_order_amount' && m['level'] == 'column' })
    assert(customers['metrics'].any? { |m| m['name'] == 'customer_count' })
    assert_equal %w[acme-analytics jaffle_shop orders], orders['relation']
    assert_equal 'manifest', orders['relation_source']
    assert_equal 2, orders['joins'].length
    assert_equal %w[first_name last_name segment customer_count], orders['joins'][0]['fields']
  end

  def test_config_meta_wins_over_legacy_meta
    Dir.mktmpdir do |d|
      write(d, 'dbt/dbt_project.yml', "name: p\nversion: '1'\n")
      write(d, 'dbt/models/m.yml', <<~Y)
        version: 2
        models:
          - name: m
            meta: {label: Old}
            config:
              meta: {label: New}
            columns:
              - name: x
                meta: {dimension: {type: string, label: Old X}}
                config: {meta: {dimension: {type: string, label: New X}}}
      Y
      write(d, 'lightdash.config.yml', "warehouse:\n  type: bigquery\n")
      lm = LightdashModel.load(d, default_database: 'p', default_schema: 's')
      assert_equal 'New', lm['models']['m']['label']
      assert_equal 'New X', lm['models']['m']['dimensions'][0]['label']
      assert_equal %w[p s m], lm['models']['m']['relation']
      assert_equal 'default', lm['models']['m']['relation_source']
    end
  end

  def test_unused_model_without_a_relation_does_not_block_selected_explore
    Dir.mktmpdir do |d|
      write(d, 'dbt/dbt_project.yml', "name: p\n")
      write(d, 'lightdash.config.yml', "warehouse:\n  type: bigquery\n")
      write(d, 'dbt/models/models.yml', <<~Y)
        version: 2
        models:
          - name: orders
            config: {database: p, schema: mart}
            columns:
              - name: id
          - name: ephemeral_stage
            columns:
              - name: id
      Y
      lm = LightdashModel.load(d, explore: 'orders')
      env, = LightdashDm.build(lm, 'orders', connection_id: CONN)
      assert_equal %w[p mart orders], lm['models']['orders']['relation']
      refute lm['models']['ephemeral_stage'].key?('relation')
      assert_equal ['el-orders'], elements(env).select { |e| e['source']['kind'] == 'warehouse-table' }.map { |e| e['id'] }
      _stdout, stderr, status = Open3.capture3('ruby', CLI, '--source-dir', d, '--explore', 'orders',
                                              '--connection-id', CONN, '--out', File.join(d, 'dm.json'))
      assert status.success?, stderr
    end
  end

  # ---- signature + CLI ---------------------------------------------------------
  def test_signature_shape
    env, sig, = convert_all
    assert_equal 'Orders', sig['tableau_workbook']
    assert_equal %w[acme-analytics.jaffle_shop.orders acme-analytics.jaffle_shop.customers acme-analytics.jaffle_shop.payments],
                 sig['warehouse_tables']
    assert_includes sig['referenced_columns'], 'Order Date'
    assert_includes sig['referenced_columns'], 'Payment Method'
    total = sig['measures'].find { |m| m['col'] == 'Total Order Amount' }
    assert_equal({ 'col' => 'Total Order Amount', 'derivation' => 'Sum' }, total)
    assert_equal explore_el(env)['metrics'].length, sig['measures'].length
  end

  def test_cli_writes_envelope_signature_and_field_map
    Dir.mktmpdir do |d|
      out = File.join(d, 'dm.json')
      sig = File.join(d, 'sig.json')
      fm = File.join(d, 'fm.json')
      stdout, stderr, st = Open3.capture3('ruby', CLI, '--source-dir', FIXTURE, '--explore', 'orders',
                                          '--connection-id', CONN, '--out', out, '--signature-out', sig,
                                          '--field-map-out', fm)
      assert st.success?, stderr + stdout
      env = JSON.parse(File.read(out))
      assert_equal %w[dialect explore gaps security sigmaDataModel stats warnings], env.keys.sort
      assert_equal 'orders', env['explore']
      assert JSON.parse(File.read(sig))['warehouse_tables']
      assert JSON.parse(File.read(fm)).key?('orders_status')
    end
  end

  def test_cli_default_sidecar_names
    Dir.mktmpdir do |d|
      _, stderr, st = Open3.capture3('ruby', CLI, '--source-dir', FIXTURE, '--explore', 'orders', '--out', File.join(d, 'dm.json'))
      assert st.success?, stderr
      assert File.file?(File.join(d, 'lightdash-signature.json'))
      assert File.file?(File.join(d, 'field-map.json'))
      assert_match(/placeholder/, JSON.parse(File.read(File.join(d, 'dm.json')))['warnings'].join(' '))
    end
  end

  def test_cli_unknown_explore_and_missing_dialect_fail_loudly
    _, stderr, st = Open3.capture3('ruby', CLI, '--source-dir', FIXTURE, '--explore', 'nope', '--out', '/dev/null')
    refute st.success?
    assert_match(/explore.*not found/, stderr)
    Dir.mktmpdir do |d|
      write(d, 'dbt/dbt_project.yml', "name: p\n")
      write(d, 'dbt/models/m.yml', "version: 2\nmodels:\n  - name: m\n    columns:\n      - name: x\n")
      _, stderr, st = Open3.capture3('ruby', CLI, '--source-dir', d, '--explore', 'm', '--out', File.join(d, 'o.json'),
                                     '--default-schema', 's')
      refute st.success?
      assert_match(/dialect unknown/, stderr)
    end
  end

  # ---- dialect + YAML-only -----------------------------------------------------
  def yaml_only_project(dir, warehouse:, sql_from:, extra: '')
    write(dir, 'lightdash.config.yml', "warehouse:\n  type: #{warehouse}\n")
    write(dir, 'models/orders.yml', <<~Y)
      type: model
      name: orders
      label: Orders
      sql_from: #{sql_from}
      joins:
        - join: customers
          sql_on: ${orders.customer_id} = ${customers.id}
          relationship: many-to-one
      dimensions:
        - name: id
          type: string
        - name: customer_id
          type: string
          hidden: true
        - name: created_at
          type: timestamp
          label: Created At
          time_intervals: [DAY, MONTH]
        - name: amount
          type: number
          sql: ${TABLE}.amount_cents / 100
      metrics:
        revenue:
          type: sum
          sql: ${amount}
          format: '[$$]#,##0'
        orders_n:
          type: count
          sql: ${TABLE}.id
      #{extra}
    Y
    write(dir, 'models/customers.yml', <<~Y)
      type: model
      name: customers
      sql_from: #{sql_from.sub(/orders\z/i) { |m| m[0] == 'O' ? 'Customers' : 'customers' }}
      dimensions:
        - name: id
          type: string
        - name: tier
          type: string
    Y
  end

  def test_yaml_only_project_parses_and_converts
    Dir.mktmpdir do |d|
      yaml_only_project(d, warehouse: 'bigquery', sql_from: 'My-Proj.RawData.Orders')
      lm = LightdashModel.load(d)
      assert_equal 'bigquery', lm['dialect']
      assert_equal 'lightdash.config.yml', lm['dialect_source']
      assert_equal %w[My-Proj RawData Orders], lm['models']['orders']['relation']
      assert_equal 'sql_from', lm['models']['orders']['relation_source']
      env, _sig, fm = LightdashDm.build(lm, 'orders', connection_id: CONN)
      assert_equal %w[My-Proj RawData Orders], el(env, 'el-orders')['source']['path']
      assert_equal %w[My-Proj RawData Customers], el(env, 'el-customers')['source']['path']
      cols = el(env, 'el-orders')['columns']
      assert_equal '[Orders/Amount Cents] / 100', cols.find { |c| c['id'] == 'col-orders-amount' }['formula']
      assert cols.find { |c| c['id'] == 'col-orders-created_at_month' }
      assert_nil cols.find { |c| c['id'] == 'col-orders-created_at_week' }
      assert_equal 'Sum([Amount])', explore_el(env)['metrics'].find { |m| m['id'] == 'met-orders-revenue' }['formula']
      assert_equal 'Count([Id])', explore_el(env)['metrics'].find { |m| m['id'] == 'met-orders-orders_n' }['formula']
      assert_equal 'N:1', el(env, 'el-orders')['relationships'][0]['relationshipType']
      assert_equal 'interval', fm['orders_created_at_month']['kind']
      assert_equal 'dimension', fm['customers_tier']['kind']
    end
  end

  def test_identifiers_are_uppercased_only_for_snowflake
    Dir.mktmpdir do |d|
      yaml_only_project(d, warehouse: 'snowflake', sql_from: 'analytics.public.orders')
      env, = convert(d)
      assert_equal %w[ANALYTICS PUBLIC ORDERS], el(env, 'el-orders')['source']['path']
      assert_equal 'ORDERS', el(env, 'el-orders')['name']
      assert_equal '[ORDERS/Amount Cents] / 100', el(env, 'el-orders')['columns'].find { |c| c['id'] == 'col-orders-amount' }['formula']
    end
    Dir.mktmpdir do |d|
      yaml_only_project(d, warehouse: 'bigquery', sql_from: 'analytics.public.orders')
      env, = convert(d)
      assert_equal %w[analytics public orders], el(env, 'el-orders')['source']['path']
    end
    Dir.mktmpdir do |d|
      yaml_only_project(d, warehouse: 'postgres', sql_from: 'analytics.public.orders')
      env, = convert(d)
      assert_equal %w[analytics public orders], el(env, 'el-orders')['source']['path']
    end
  end

  def test_dialect_resolution_order_manifest_then_config_then_flag
    lm = LightdashModel.load(FIXTURE, dialect: 'snowflake')
    assert_equal 'bigquery', lm['dialect'], 'manifest adapter_type wins over the flag'
    assert_equal 'manifest', lm['dialect_source']
    assert(lm['warnings'].any? { |w| w.include?('--dialect snowflake ignored') })
    Dir.mktmpdir do |d|
      yaml_only_project(d, warehouse: 'bigquery', sql_from: 'a.b.orders')
      lm = LightdashModel.load(d, dialect: 'snowflake')
      assert_equal 'bigquery', lm['dialect'], 'config wins over the flag'
    end
    Dir.mktmpdir do |d|
      write(d, 'models/m.yml', "type: model\nname: m\nsql_from: a.b.m\ndimensions:\n  - name: x\n")
      assert_raises(LightdashModel::Error) { LightdashModel.load(d) }
      assert_equal 'snowflake', LightdashModel.load(d, dialect: 'Snowflake')['dialect']
    end
  end

  def test_relation_without_any_source_raises
    Dir.mktmpdir do |d|
      write(d, 'dbt/dbt_project.yml', "name: p\n")
      write(d, 'dbt/models/m.yml', "version: 2\nmodels:\n  - name: m\n    columns:\n      - name: x\n")
      err = assert_raises(LightdashModel::Error) { LightdashModel.load(d, dialect: 'bigquery') }
      assert_match(/physical table.*model m/, err.message)
    end
  end

  # ---- gaps ---------------------------------------------------------------------
  def test_unparseable_sql_on_skips_join_with_ledger_entries
    Dir.mktmpdir do |d|
      yaml_only_project(d, warehouse: 'bigquery', sql_from: 'a.b.orders')
      path = File.join(d, 'models/orders.yml')
      File.write(path, File.read(path).sub('${orders.customer_id} = ${customers.id}', '${orders.customer_id} > ${customers.id}'))
      env, fm = convert(d)
      assert_nil el(env, 'el-orders')['relationships']
      gap = env['gaps'].find { |g| g['item'] == 'join customers' }
      refute_nil gap
      assert_match(/sql_on/, gap['reason'])
      assert_equal 'skipped', fm['customers_tier']['kind']
      assert_match(/join to customers skipped/, fm['customers_tier']['reason'])
    end
  end

  def test_untranslatable_dimension_is_skipped_with_ledger_and_dependents_fail
    Dir.mktmpdir do |d|
      write(d, 'lightdash.config.yml', "warehouse:\n  type: bigquery\n")
      write(d, 'models/m.yml', <<~Y)
        type: model
        name: m
        sql_from: a.b.m
        dimensions:
          - name: id
            type: string
          - name: amount
            type: number
          - name: running
            type: number
            sql: SUM(${TABLE}.amount) OVER (ORDER BY ${TABLE}.id)
          - name: derived
            type: number
            sql: ${running} * 2
          - name: param_dim
            type: string
            sql: ${lightdash.parameters.region}
          - name: ok
            type: string
            sql: CONCAT(${id}, '-', 'x')
        metrics:
          n:
            type: count
            sql: ${TABLE}.id
          bad_pct:
            type: percent_of_previous
            sql: ${n}
          bad_filter:
            type: sum
            sql: ${amount}
            filters:
              - id: 'inThePast 3 days'
          over_derived:
            type: sum
            sql: ${derived}
      Y
      env, fm = convert(d, 'm')
      cols = el(env, 'el-m')['columns'].map { |c| c['id'] }
      assert_equal %w[col-m-id col-m-amount col-m-ok], cols
      assert_match(/window/i, fm['m_running']['reason'])
      assert_match(/depends on \$\{running\}/, fm['m_derived']['reason'])
      assert_match(/parameter/i, fm['m_param_dim']['reason'])
      assert_equal 'dimension', fm['m_ok']['kind']
      assert_equal '([Id] & "-" & "x")', el(env, 'el-m')['columns'].find { |c| c['id'] == 'col-m-ok' }['formula']
      assert_equal 'metric', fm['m_n']['kind']
      assert_match(/post-calculation/, fm['m_bad_pct']['reason'])
      assert_match(/inThePast/, fm['m_bad_filter']['reason'])
      assert_match(/over_derived|derived/, fm['m_over_derived']['reason'])
      items = env['gaps'].map { |g| g['item'] }
      %w[dimension\ m.running dimension\ m.derived dimension\ m.param_dim metric\ m.bad_pct metric\ m.bad_filter
         metric\ m.over_derived].each { |i| assert_includes items, i }
      env['gaps'].each do |g|
        assert_includes DegradationLedger::CLASSES, g['class']
        refute_empty g['reason']
      end
      skipped = fm.values.count { |e| e['kind'] == 'skipped' }
      assert_equal skipped, env['stats']['fields_skipped']
    end
  end

  def test_join_exclusions_and_alias_and_inner_join_gap
    Dir.mktmpdir do |d|
      yaml_only_project(d, warehouse: 'bigquery', sql_from: 'a.b.orders')
      path = File.join(d, 'models/orders.yml')
      File.write(path, File.read(path).sub("- join: customers\n", "- join: customers\n    alias: buyers\n    type: inner\n    exclusions: [tier]\n")
                                  .sub('${customers.id}', '${buyers.id}').sub('${orders.customer_id}', '${orders.customer_id}'))
      env, fm = convert(d)
      assert_equal 'dimension', fm['buyers_id']['kind']
      assert_equal 'skipped', fm['buyers_tier']['kind']
      assert_match(/exclusions/, fm['buyers_tier']['reason'])
      assert fm['buyers_id']['column_id'].start_with?('ex-buyers-')
      assert(env['gaps'].any? { |g| g['class'] == 'quality-waiver' && g['item'] == 'join type of buyers' })
      assert_equal 'rel-orders-buyers', el(env, 'el-orders')['relationships'][0]['id']
    end
  end

  def test_weekly_interval_warns_about_week_start
    env, = convert
    assert(env['warnings'].any? { |w| w.include?('week_start_day') })
  end

  def test_disabled_dimension_and_intervals_are_recorded
    Dir.mktmpdir do |d|
      write(d, 'lightdash.config.yml', "warehouse:\n  type: bigquery\n")
      write(d, 'models/m.yml', <<~Y)
        type: model
        name: m
        sql_from: a.b.m
        dimensions:
          - name: id
            type: string
          - name: seen_at
            type: date
            time_intervals: [DAY, MONTH]
            enabled: false
      Y
      env, fm = convert(d, 'm')
      %w[dimension\ m.seen_at interval\ m.seen_at_day interval\ m.seen_at_month].each do |item|
        assert(env['gaps'].any? { |g| g['item'] == item && g['reason'].include?('enabled: false') }, item)
        assert(env['warnings'].any? { |w| w.include?(item) }, item)
      end
      assert_equal 'skipped', fm['m_seen_at_month']['kind']
      assert_match(/enabled: false/, fm['m_seen_at_month']['reason'])
    end
  end

  def test_hidden_metric_recorded_and_metric_names_unique_against_columns
    Dir.mktmpdir do |d|
      write(d, 'lightdash.config.yml', "warehouse:\n  type: bigquery\n")
      write(d, 'models/m.yml', <<~Y)
        type: model
        name: m
        sql_from: a.b.m
        dimensions:
          - name: amount
            type: number
        metrics:
          total:
            type: sum
            sql: ${amount}
            label: Amount
            hidden: true
      Y
      env, fm = convert(d, 'm')
      assert_equal true, fm['m_total']['hidden']
      assert(env['gaps'].any? { |g| g['item'] == 'hidden flag of metric m.total' && g['class'] == 'quality-waiver' })
      ex = el(env, 'el-explore-m')
      refute_equal 'Amount', ex['metrics'][0]['name']
      assert_equal 'M Amount', ex['metrics'][0]['name']
      assert(env['warnings'].any? { |w| w.include?('collides with a column') })
      assert_equal ex['metrics'][0]['name'], fm['m_total']['name']
    end
  end

  def test_dbt_models_lightdash_subdir_is_read_but_download_dir_is_not
    Dir.mktmpdir do |d|
      write(d, 'dbt/dbt_project.yml', "name: p\n")
      write(d, 'dbt/models/lightdash/m.yml', "version: 2\nmodels:\n  - name: m\n    columns:\n      - name: x\n")
      write(d, 'lightdash/charts/c.yml', "models:\n  - name: not_a_model\n")
      lm = LightdashModel.load(d, dialect: 'bigquery', default_database: 'p', default_schema: 's')
      assert_equal ['m'], lm['models'].keys
    end
  end

  def test_envelope_has_no_dangling_ids
    env, = convert
    ids = elements(env).map { |e| e['id'] }
    assert_equal ids.uniq, ids
    elements(env).each do |e|
      col_ids = e['columns'].map { |c| c['id'] }
      assert_equal col_ids.uniq, col_ids, "#{e['id']} column ids unique"
      names = e['columns'].map { |c| c['name'].downcase }
      assert_equal names.uniq, names, "#{e['id']} column names unique"
      all = names + (e['metrics'] || []).map { |m| m['name'].downcase }
      assert_equal all.uniq, all, "#{e['id']} column + metric names unique"
    end
    assert_equal env['stats']['columns'], elements(env).sum { |e| e['columns'].length }
    assert_equal env['stats']['metrics'], elements(env).sum { |e| (e['metrics'] || []).length }
  end

  private

  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
