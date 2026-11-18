#!/usr/bin/env ruby
# frozen_string_literal: true
# Tests for LightdashExport, LightdashChartMap and build-lightdash-workbook.rb against
# fixtures/jaffle-orders (convert-dm runs first, into a tmpdir) plus small inline charts.
#
#   ruby test/test-build-workbook.rb

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'open3'
require_relative '../scripts/convert-dm'
require_relative '../scripts/build-lightdash-workbook'
require_relative '../scripts/lib/degradation_ledger'

class BuildWorkbookTest < Minitest::Test
  SKILL = File.expand_path('..', __dir__)
  FIXTURE = File.join(SKILL, 'fixtures', 'jaffle-orders')
  LD = File.join(FIXTURE, 'lightdash')
  DASH = File.join(LD, 'dashboards', 'jaffle-overview.yml')
  CHARTS = File.join(LD, 'charts')
  CONN = '11111111-2222-3333-4444-555555555555'
  BUILD_CLI = File.join(SKILL, 'scripts', 'build-lightdash-workbook.rb')
  DM_CLI = File.join(SKILL, 'scripts', 'convert-dm.rb')

  def self.dm
    @dm ||= begin
      lm = LightdashModel.load(FIXTURE)
      env, _sig, fm = LightdashDm.build(lm, 'orders', connection_id: CONN)
      [JSON.parse(JSON.generate(env)), JSON.parse(JSON.generate(fm))]
    end
  end

  def dm
    self.class.dm
  end

  def build(dash_path = DASH, charts_dir = CHARTS, dm_id: 'dm-test')
    dash = LightdashExport.load(dash_path, charts_dir)
    LightdashWorkbook.build(dash, dm[1], dm[0], dm_id: dm_id)
  end

  def elements(res)
    res['spec']['elements']
  end

  def el(res, id)
    elements(res).find { |e| e['id'] == id }
  end

  def col(element, id)
    element['columns'].find { |c| c['id'] == id }
  end

  # Build a throwaway dashboard (no tabs) over inline chart YAML hashes -> result.
  def build_inline(charts, opts = {})
    tiles = opts[:tiles]
    filters = opts[:filters]
    tabs = opts[:tabs]
    Dir.mktmpdir do |tmp|
      cdir = File.join(tmp, 'charts')
      FileUtils.mkdir_p(cdir)
      charts.each { |slug, c| File.write(File.join(cdir, "#{slug}.yml"), YAML.dump(c.merge('slug' => slug))) }
      tiles ||= charts.keys.each_with_index.map do |slug, i|
        { 'x' => 0, 'y' => i * 10, 'w' => 36, 'h' => 10, 'type' => 'saved_chart', 'tileSlug' => slug,
          'properties' => { 'chartSlug' => slug, 'title' => '' } }
      end
      dash = { 'name' => 'Inline', 'slug' => 'inline', 'tiles' => tiles, 'filters' => filters || { 'dimensions' => [] } }
      dash['tabs'] = tabs if tabs
      File.write(File.join(tmp, 'd.yml'), YAML.dump(dash))
      return build(File.join(tmp, 'd.yml'), cdir)
    end
  end

  def base_chart(overrides = {})
    {
      'name' => 'Inline Chart', 'tableName' => 'orders',
      'metricQuery' => { 'exploreName' => 'orders', 'dimensions' => ['orders_region'], 'metrics' => ['orders_total_order_amount'],
                         'filters' => {}, 'sorts' => [], 'limit' => 500, 'tableCalculations' => [], 'additionalMetrics' => [] },
      'chartConfig' => { 'type' => 'cartesian', 'config' => { 'layout' => { 'xField' => 'orders_region', 'yField' => ['orders_total_order_amount'] },
                                                              'eChartsConfig' => { 'series' => [{ 'type' => 'bar', 'encode' => { 'yRef' => { 'field' => 'orders_total_order_amount' } } }] } } }
    }.merge(overrides)
  end

  def deep(h)
    Marshal.load(Marshal.dump(h))
  end

  # ---- normalization --------------------------------------------------------
  def test_export_pages_follow_tab_order_and_tiles_resolve
    dash = LightdashExport.load(DASH, CHARTS)
    assert_equal ['Overview', 'Details'], dash['pages'].map { |p| p['name'] }
    assert_equal 7, dash['tiles'].length
    md = dash['tiles'].find { |t| t['kind'] == 'markdown' }
    assert_equal 'page-1', md['page_id']
    assert_equal 'markdown-1', md['id']
    assert_equal 'page-2', dash['tiles'].find { |t| t['id'] == 'payments-by-method' }['page_id']
    assert dash['tiles'].select { |t| t['kind'] == 'chart' }.all? { |t| t['chart'].is_a?(Hash) }
  end

  def test_export_filters_resolve_tile_targets
    dash = LightdashExport.load(DASH, CHARTS)
    region, segment = dash['filters']
    assert_nil region['target_tiles'], 'empty tileTargets = all tiles'
    assert_equal %w[monthly-revenue revenue-by-segment], segment['target_tiles'].sort
    assert_equal 'customers_segment', segment['field_id']
    assert_equal %w[north south], region['values']
  end

  def test_export_false_target_excluded_and_unknown_tile_warned
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, 'd.yml'), YAML.dump(
                                            'name' => 'D', 'tiles' => [{ 'x' => 0, 'y' => 0, 'w' => 6, 'h' => 4, 'type' => 'saved_chart', 'tileSlug' => 'a',
                                                                         'properties' => { 'chartSlug' => 'a' } },
                                                                       { 'x' => 6, 'y' => 0, 'w' => 6, 'h' => 4, 'type' => 'saved_chart', 'tileSlug' => 'b',
                                                                         'properties' => { 'chartSlug' => 'b' } }],
                                            'filters' => { 'dimensions' => [{ 'id' => 'f1', 'target' => { 'fieldId' => 'orders_region' }, 'operator' => 'equals',
                                                                              'values' => ['n'], 'tileTargets' => { 'a' => { 'fieldId' => 'orders_region' }, 'b' => false, 'zzz' => { 'fieldId' => 'x' } } }] }
                                          ))
      dash = LightdashExport.load(File.join(tmp, 'd.yml'), tmp)
      assert_equal ['a'], dash['filters'][0]['target_tiles']
      assert(dash['warnings'].any? { |w| w.include?('zzz') })
      assert_equal 1, dash['pages'].length, 'no tabs -> one page'
    end
  end

  # ---- fixture build ----------------------------------------------------------
  def test_fixture_build_is_lint_clean
    res = build
    assert_equal [], res['violations']
  end

  def test_page_count_equals_tab_count
    res = build
    pages = res['spec']['pages']
    assert_equal %w[page-data page-1 page-2], pages.map { |p| p['id'] }
    assert_equal [true], pages.select { |p| p['hidden'] }.map { |p| p['hidden'] }, 'only the Data page is hidden'
    assert_equal 'page-data', pages.find { |p| p['hidden'] }['id']
    assert_equal 2, pages.reject { |p| p['hidden'] }.length, 'visible pages = tab count'
    assert_equal 3, res['spec']['layout'].scan('<Page ').length
  end

  def test_element_kinds_per_chart_map
    res = build
    kinds = res['map'].each_with_object({}) { |(slug, m), h| h[slug] = m['kind'] }
    assert_equal({ 'total-orders-kpi' => 'kpi-chart', 'monthly-revenue' => 'line-chart', 'revenue-by-segment' => 'bar-chart',
                   'orders-by-region-table' => 'table', 'payments-by-method' => 'donut-chart',
                   'completed-revenue-by-region' => 'bar-chart' }, kinds)
    assert_equal 6, elements(res).count { |e| e['id'].start_with?('el-') && e['kind'] != 'text' }
    assert_equal %w[tbl-base-1 tbl-master], elements(res).select { |e| e['id'].start_with?('tbl-') }.map { |e| e['id'] }.sort
    assert_equal 1, elements(res).count { |e| e['kind'] == 'text' }
    assert_equal 2, elements(res).count { |e| e['kind'] == 'control' }
  end

  def test_horizontal_bar_detected_and_vertical_default
    res = build
    assert_equal 'horizontal', el(res, 'el-completed-revenue-by-region')['orientation']
    assert_nil el(res, 'el-revenue-by-segment')['orientation']
  end

  def test_kpi_inlines_the_aggregate_with_dm_prefix
    res = build
    k = el(res, 'el-total-orders-kpi')
    vcol = col(k, k['value']['columnId'])
    assert_equal 'CountDistinct([Lightdash Data/Order Id])', vcol['formula']
    assert col(el(res, 'tbl-master'), 'm-Order-Id'), 'master carries the column the inline aggregate needs'
    refute_match(/\A\s*\[[^\]]+\]\s*\z/, vcol['formula'], 'preflight K1: no bare ref')
  end

  def test_column_filter_and_element_ids_are_unique_workbook_wide
    res = build
    els = elements(res)
    el_ids = els.map { |e| e['id'] }
    assert_equal el_ids.uniq.length, el_ids.length, 'element ids unique'
    col_ids = els.flat_map { |e| (e['columns'] || []).map { |c| c['id'] } }
    dup = col_ids.group_by { |i| i }.select { |_, v| v.length > 1 }.keys
    assert_empty dup, 'column ids unique across every element (Sigma requires it)'
    flt_ids = els.reject { |e| e['kind'] == 'control' }.flat_map { |e| (e['filters'] || []).map { |f| f['id'] } }
    assert_operator flt_ids.length, :>=, 2, 'fixture exercises element filters on several elements'
    assert_equal flt_ids.uniq.length, flt_ids.length, 'element-filter ids unique'
    # the workbook map points at the same (now element-prefixed) ids
    res['map'].each_value do |m|
      next unless m['columns']
      m['columns'].each_value { |c| assert_includes col_ids, c['id'] }
    end
  end

  def test_charts_source_through_hidden_master_and_base_tables
    res = build
    bar = el(res, 'el-revenue-by-segment')
    assert_equal '[Metrics/Total Order Amount]', col(bar, 'el-revenue-by-segment-c-orders_total_order_amount')['formula']
    assert_equal '[Lightdash Base 1/Customer Segment]', col(bar, 'el-revenue-by-segment-c-customers_segment')['formula']
    assert_equal({ 'kind' => 'table', 'elementId' => 'tbl-base-1' }, bar['source'])
    assert_equal({ 'kind' => 'table', 'elementId' => 'tbl-base-1' }, el(res, 'el-monthly-revenue')['source'])
    donut = el(res, 'el-payments-by-method')
    assert_equal({ 'kind' => 'table', 'elementId' => 'tbl-master' }, donut['source'])
    assert_equal '[Lightdash Data/Payment Method]', col(donut, 'el-payments-by-method-c-payments_payment_method')['formula']
    master = el(res, 'tbl-master')
    assert_equal({ 'kind' => 'data-model', 'dataModelId' => 'dm-test', 'elementId' => 'el-explore-orders' }, master['source'])
    assert_equal 'table', master['kind']
    assert_equal '[Orders (Explore)/Customer Segment]', col(master, 'm-Customer-Segment')['formula']
    base = el(res, 'tbl-base-1')
    assert_equal({ 'kind' => 'table', 'elementId' => 'tbl-master' }, base['source'], 'base is sourced from the master')
    assert_equal '[Lightdash Data/Customer Segment]', col(base, 'tbl-base-1-Customer-Segment')['formula']
    # every chart column ref resolves to a column on that chart's source table
    elements(res).select { |e| e['id'].start_with?('el-') && e['columns'] }.each do |e|
      tbl = el(res, e['source']['elementId'])
      e['columns'].each do |c|
        c['formula'].scan(%r{\[([^\]/]+)/([^\]]+)\]}).each do |pfx, name|
          next if pfx == 'Metrics'
          assert_equal tbl['name'], pfx, "#{e['id']} #{c['formula']}"
          assert(tbl['columns'].any? { |x| x['name'] == name }, "#{tbl['id']} lacks #{name}")
        end
      end
    end
  end

  def test_axis_sort_donut_channels_and_stacking_absent
    res = build
    bar = el(res, 'el-revenue-by-segment')
    assert_equal 'el-revenue-by-segment-c-customers_segment', bar['xAxis']['columnId']
    assert_equal({ 'by' => 'el-revenue-by-segment-c-orders_total_order_amount', 'direction' => 'descending' }, bar['xAxis']['sort'])
    donut = el(res, 'el-payments-by-method')
    assert_equal 'el-payments-by-method-c-payments_total_payment_amount', donut['value']['columnId']
    assert_equal 'el-payments-by-method-c-payments_payment_method', donut['color']['columnId']
    assert_nil bar['stacking']
  end

  def test_markdown_tile_becomes_text_with_content_preserved
    res = build
    t = el(res, 'el-markdown-1')
    assert_equal 'text', t['kind']
    assert_includes t['body'], 'Revenue figures exclude nothing'
    assert_includes t['body'], 'About this dashboard'
  end

  def test_running_total_table_calc_is_a_gap_with_original_sql_quoted
    res = build
    gap = res['gaps'].find { |g| g['item'].include?('running_total_amount') }
    refute_nil gap
    assert_equal 'scope-cut', gap['class']
    assert_includes gap['reason'], 'SUM(${orders.total_order_amount}) OVER (PARTITION BY ${orders.region}'
    table = el(res, 'el-orders-by-region-table')
    refute(table['columns'].any? { |c| c['name'] =~ /running/i })
  end

  def test_table_is_grouped_by_dimensions_with_metric_calculations
    t = el(build, 'el-orders-by-region-table')
    g = t['groupings'][0]
    assert_equal %w[el-orders-by-region-table-c-orders_order_date_month el-orders-by-region-table-c-orders_region], g['groupBy']
    assert_equal %w[el-orders-by-region-table-c-orders_total_order_amount el-orders-by-region-table-c-orders_completion_rate], g['calculations']
    assert_equal [{ 'columnId' => 'el-orders-by-region-table-c-orders_order_date_month', 'direction' => 'descending' }], g['sort']
  end

  def test_chart_level_filter_becomes_list_element_filter
    bar = el(build, 'el-completed-revenue-by-region')
    f = bar['filters'].find { |x| x['kind'] == 'list' }
    assert_equal %w[completed], f['values']
    assert_equal 'include', f['mode']
    assert_equal 'el-completed-revenue-by-region-c-orders_status', f['columnId']
    assert col(bar, 'el-completed-revenue-by-region-c-orders_status'), 'filter column is declared on the element'
  end

  def test_limit_becomes_top_n_only_for_metric_sorted_charts
    res = build
    bar = el(res, 'el-completed-revenue-by-region')
    top = bar['filters'].find { |x| x['kind'] == 'top-n' }
    assert_equal 10, top['rowCount']
    assert_equal 'top-n', top['mode']
    assert_equal 'el-completed-revenue-by-region-c-orders_total_order_amount', top['columnId']
    # dimension-sorted at the default cap: warning, not a ledger entry
    assert(res['warnings'].any? { |w| w.include?('monthly-revenue') && w.include?('500') })
    assert_nil el(res, 'el-monthly-revenue')['filters']
    # dimension-sorted below the default cap: ledgered
    assert(res['gaps'].any? { |g| g['item'] == 'chart orders-by-region-table' && g['reason'].include?('row limit 100') })
  end

  def test_echarts_styling_noted_once_and_is_not_a_ledger_gap
    res = build
    assert_equal 1, res['notes'].count { |g| g['item'] == 'ECharts styling' }
    assert_empty res['gaps'].select { |g| g['item'] == 'ECharts styling' }
  end

  def test_notes_alone_derive_an_empty_ledger_but_a_data_waiver_does_not
    Dir.mktmpdir do |tmp|
      res = build_inline('c1' => base_chart('chartConfig' => base_chart['chartConfig']))
      assert_empty res['gaps'], res['gaps'].inspect
      refute_empty res['notes'], 'styling is recorded as a note'
      LightdashLedger.write(tmp, res['gaps'], origin: 'lightdash-build')
      assert_empty DegradationLedger.derive(tmp), 'presentation notes never reach the ledger'
      assert_equal 'GREEN', DegradationLedger.verdict(DegradationLedger.derive(tmp))
      data = DegradationLedger.entry('quality-waiver', 'chart c1', 'row limit 5 not applied', 'build-lightdash-workbook')
      LightdashLedger.write(tmp, res['gaps'] + [data], origin: 'lightdash-build')
      refute_empty DegradationLedger.derive(tmp), 'a data-affecting waiver still blocks GREEN'
    end
  end

  # ---- controls -----------------------------------------------------------------
  def test_controls_count_and_wiring
    res = build
    ctls = elements(res).select { |e| e['kind'] == 'control' }
    assert_equal 2, ctls.length
    region = ctls.find { |c| c['name'] == 'Region' }
    segment = ctls.find { |c| c['name'] == 'Customer Segment' }
    assert_equal 'list', region['controlType']
    assert_equal %w[north south], region['values']
    assert_equal 'include', region['mode']
    assert_equal ['tbl-master'], region['filters'].map { |f| f['source']['elementId'] }, 'all-tiles control targets the master table'
    assert_equal ['tbl-base-1'], segment['filters'].map { |f| f['source']['elementId'] }, 'limited control targets only its base table'
    ctls.each do |c|
      c['filters'].each { |f| assert_equal 'table', el(res, f['source']['elementId'])['kind'], 'control targets are table elements' }
    end
    members = elements(res).select { |e| e['id'].start_with?('el-') && e['source'] == { 'kind' => 'table', 'elementId' => 'tbl-base-1' } }
    assert_equal %w[el-monthly-revenue el-revenue-by-segment], members.map { |e| e['id'] }.sort
    refute(elements(res).any? { |e| e['kind'] == 'kpi-chart' && e['columns'].any? { |c| c['name'] == 'Customer Segment' } })
    assert_equal ['Enterprise'], segment['values']
    # each control filter column is declared on its target element
    ctls.each do |c|
      c['filters'].each do |f|
        target = el(res, f['source']['elementId'])
        assert col(target, f['columnId']), "#{c['name']} -> #{f['source']['elementId']}"
      end
    end
  end

  def test_limited_control_declares_scope_sidecar
    res = build
    seg = res['control_scope']['controls'].find { |c| c['sourceName'] == 'Customer Segment' }
    assert_equal %w[el-monthly-revenue el-revenue-by-segment], seg['scope'].sort
    refute res['control_scope']['controls'].find { |c| c['sourceName'] == 'Region' }.key?('scope')
    assert_equal 2, res['control_scope']['sourceFilterSignals']
  end

  def test_dashboard_filter_operators
    charts = { 'c1' => base_chart }
    f = lambda do |id, field, op, vals|
      { 'id' => id, 'target' => { 'fieldId' => field }, 'operator' => op, 'values' => vals, 'tileTargets' => {} }
    end
    res = build_inline(charts, filters: { 'dimensions' => [
                         f.call('a', 'orders_status', 'notEquals', ['returned']),
                         f.call('b', 'orders_amount', 'inBetween', [10, 20]),
                         f.call('c', 'orders_order_date_month', 'greaterThan', ['2026-01-01']),
                         f.call('d', 'orders_region', 'startsWith', ['n']),
                         f.call('e', 'orders_order_date_month', 'inThePast', [3]),
                         f.call('f', 'orders_status', 'isNull', [])
                       ], 'metrics' => [{ 'id' => 'm', 'target' => { 'fieldId' => 'orders_total_orders' }, 'operator' => 'greaterThan', 'values' => [1] }] })
    assert_equal [], res['violations']
    ctls = elements(res).select { |e| e['kind'] == 'control' }
    by = ctls.each_with_object({}) { |c, h| h[c['name']] = c }
    statuses = ctls.select { |c| c['name'] == 'Status' }
    assert_equal 2, statuses.length
    assert_equal 'exclude', statuses.find { |c| c['values'] == ['returned'] }['mode']
    assert_equal [], statuses.find { |c| c['values'] != ['returned'] }['values']
    assert_equal({ 'low' => 10, 'high' => 20 }, by['Amount'].select { |k, _| %w[low high].include?(k) })
    assert_equal 'number-range', by['Amount']['controlType']
    assert_equal 'date-range', by['Order Date Month']['controlType']
    assert_equal 'after', by['Order Date Month']['mode']
    assert_equal '2026-01-01T00:00:00Z', by['Order Date Month']['date']
    # startsWith on a string -> unfiltered list control + ledger; inThePast on a date -> skipped; isNull -> unfiltered list
    assert_equal [], by['Region']['values']
    assert_equal ['tbl-master'], by['Region']['filters'].map { |f| f['source']['elementId'] }
    assert(res['gaps'].any? { |g| g['item'] == 'dashboard filter orders_region' })
    assert(res['gaps'].any? { |g| g['item'] == 'dashboard filter orders_order_date_month' && g['reason'].include?('control skipped') })
    assert(res['gaps'].any? { |g| g['item'] == 'dashboard filter orders_total_orders' })
    assert_equal 5, ctls.length, 'a, b, c, d(unfiltered list), f(unfiltered list); e skipped'
  end

  # ---- layout ---------------------------------------------------------------------
  def layout_rows(res, page)
    block = res['spec']['layout'][%r{<Page[^>]*id="#{page}">(.*?)</Page>}m, 1]
    block.scan(/elementId="([^"]+)" gridColumn="(\d+) \/ (\d+)" gridRow="(\d+) \/ (\d+)"/).each_with_object({}) do |(id, c0, c1, r0, r1), h|
      h[id] = { c0: c0.to_i, c1: c1.to_i, r0: r0.to_i, r1: r1.to_i }
    end
  end

  def test_layout_scales_36_to_24_columns
    res = build
    p1 = layout_rows(res, 'page-1')
    assert_equal 24, p1['el-markdown-1'][:c1] - p1['el-markdown-1'][:c0], 'w:36 -> full width'
    assert_equal [1, 25], [p1['el-markdown-1'][:c0], p1['el-markdown-1'][:c1]]
    assert_equal 8, p1['el-total-orders-kpi'][:c1] - p1['el-total-orders-kpi'][:c0], 'w:12 -> 8'
    assert_equal 16, p1['el-monthly-revenue'][:c1] - p1['el-monthly-revenue'][:c0], 'w:24 -> 16'
    p2 = layout_rows(res, 'page-2')
    assert_equal 12, p2['el-payments-by-method'][:c1] - p2['el-payments-by-method'][:c0], 'w:18 -> 12'
    assert_equal [13, 25], [p2['el-completed-revenue-by-region'][:c0], p2['el-completed-revenue-by-region'][:c1]]
  end

  def test_scale_cols_helper_clamps_and_never_collapses
    assert_equal [1, 25], LightdashWorkbook.scale_cols(0, 36)
    assert_equal [1, 13], LightdashWorkbook.scale_cols(0, 18)
    assert_equal [13, 25], LightdashWorkbook.scale_cols(18, 18)
    c0, c1 = LightdashWorkbook.scale_cols(35, 1)
    assert c1 > c0 && c1 <= 25
    assert_equal [1, 25], LightdashWorkbook.scale_cols(0, 99), 'wider than the grid is clamped'
  end

  def test_layout_preserves_row_order_with_controls_shifted_above_page_one
    res = build
    p1 = layout_rows(res, 'page-1')
    ctl_bottom = %w[ctl-orders_region ctl-customers_segment].map { |c| p1[c][:r1] }.max
    assert_equal ctl_bottom, p1['el-markdown-1'][:r0]
    assert p1['el-markdown-1'][:r1] <= p1['el-total-orders-kpi'][:r0]
    assert p1['el-total-orders-kpi'][:r1] <= p1['el-revenue-by-segment'][:r0]
    # layout is a sibling of pages, last key written
    assert_equal 'layout', res['spec'].keys.last
  end

  def test_layout_lists_every_element_exactly_once
    res = build
    ids = res['spec']['layout'].scan(/elementId="([^"]+)"/).flatten
    assert_equal elements(res).map { |e| e['id'] }.sort, ids.sort
  end

  # ---- workbook-map -----------------------------------------------------------------
  def test_workbook_map_covers_all_chart_slugs
    res = build
    slugs = Dir.glob(File.join(CHARTS, '*.yml')).map { |f| File.basename(f, '.yml') }.sort
    assert_equal 6, slugs.length
    assert_equal slugs, res['map'].keys.sort
    ids = elements(res).map { |e| e['id'] }
    res['map'].each do |slug, m|
      assert_includes ids, m['element_id'], slug
      assert_includes %w[page-1 page-2], m['page_id']
      refute_empty m['fields'], slug
      m['fields'].each { |f| assert m['columns'][f], "#{slug} #{f}" }
    end
    assert_equal %w[orders_order_date_month orders_total_order_amount], res['map']['monthly-revenue']['fields']
    assert_equal 'page-2', res['map']['payments-by-method']['page_id']
    assert_equal 'tbl-base-1', res['map']['revenue-by-segment']['source_element_id']
    assert_equal 'tbl-master', res['map']['payments-by-method']['source_element_id']
    assert_equal 'el-revenue-by-segment', res['map']['revenue-by-segment']['element_id'], 'element_id stays the visible chart'
  end

  # ---- inline charts -------------------------------------------------------------------
  def test_stacked_area_and_combo_and_pivot_series_split
    area = base_chart
    area['chartConfig']['config']['eChartsConfig']['series'] = [{ 'type' => 'line', 'areaStyle' => {}, 'stack' => 'total',
                                                                  'encode' => { 'yRef' => { 'field' => 'orders_total_order_amount' } } }]
    area['metricQuery']['pivotDimensions'] = ['orders_status']
    area['metricQuery']['dimensions'] = %w[orders_region orders_status]
    combo = base_chart
    combo['metricQuery']['metrics'] = %w[orders_total_order_amount orders_completion_rate]
    combo['chartConfig']['config']['layout']['yField'] = %w[orders_total_order_amount orders_completion_rate]
    combo['chartConfig']['config']['eChartsConfig']['series'] = [
      { 'type' => 'bar', 'encode' => { 'yRef' => { 'field' => 'orders_total_order_amount' } } },
      { 'type' => 'line', 'yAxisIndex' => 1, 'encode' => { 'yRef' => { 'field' => 'orders_completion_rate' } } }
    ]
    res = build_inline('area1' => area, 'combo1' => combo)
    assert_equal [], res['violations']
    a = el(res, 'el-area1')
    assert_equal 'area-chart', a['kind']
    assert_equal 'stacked', a['stacking']
    assert_equal({ 'by' => 'category', 'column' => 'el-area1-c-orders_status' }, a['color'])
    c = el(res, 'el-combo1')
    assert_equal 'combo-chart', c['kind']
    assert_equal [{ 'columnId' => 'el-combo1-c-orders_total_order_amount', 'type' => 'bar' }, { 'columnId' => 'el-combo1-c-orders_completion_rate', 'type' => 'line' }], c['yAxis']['columnIds']
    assert_equal ['el-combo1-c-orders_completion_rate'], c['yAxis2']['columnIds']
  end

  def test_pivot_table_from_pivot_dimensions
    t = base_chart
    t['metricQuery']['dimensions'] = %w[orders_region orders_status]
    t['metricQuery']['pivotDimensions'] = ['orders_status']
    t['chartConfig'] = { 'type' => 'table', 'config' => { 'columns' => {} } }
    res = build_inline('p1' => t)
    assert_equal [], res['violations']
    p = el(res, 'el-p1')
    assert_equal 'pivot-table', p['kind']
    assert_equal [{ 'columnId' => 'el-p1-c-orders_region' }], p['rowsBy']
    assert_equal [{ 'columnId' => 'el-p1-c-orders_status' }], p['columnsBy']
    assert_equal ['el-p1-c-orders_total_order_amount'], p['values']
  end

  def test_unsupported_chart_types_become_placeholders_with_ledger_gaps
    charts = %w[treemap gauge map sankey custom data_app_viz].each_with_object({}) do |type, h|
      c = deep(base_chart)
      c['name'] = "A #{type}"
      c['chartConfig'] = { 'type' => type, 'config' => {} }
      h["x-#{type}"] = c
    end
    sql = { 'name' => 'SQL one', 'contentType' => 'sql_chart', 'sql' => 'select 1', 'chartKind' => 'table' }
    charts['x-sql'] = sql
    res = build_inline(charts)
    assert_equal [], res['violations']
    assert_equal 7, elements(res).count { |e| e['kind'] == 'text' }
    assert_equal 7, res['gaps'].count { |g| g['class'] == 'scope-cut' && g['item'].start_with?('tile x-') }
    t = el(res, 'el-x-treemap')
    assert_includes t['body'], 'A treemap'
    assert res['map']['x-treemap']['placeholder']
    assert_equal 'text', res['map']['x-treemap']['kind']
  end

  def test_sql_chart_tile_and_missing_chart_are_placeholders
    tiles = [{ 'x' => 0, 'y' => 0, 'w' => 18, 'h' => 6, 'type' => 'sql_chart', 'tileSlug' => 's1', 'properties' => { 'title' => 'SQL tile', 'chartSlug' => 's1' } },
             { 'x' => 18, 'y' => 0, 'w' => 18, 'h' => 6, 'type' => 'saved_chart', 'tileSlug' => 'gone', 'properties' => { 'chartSlug' => 'gone' } }]
    res = build_inline({ 'c1' => base_chart }, tiles: tiles)
    assert_equal 2, elements(res).count { |e| e['kind'] == 'text' }
    assert_equal 2, res['gaps'].count { |g| g['class'] == 'scope-cut' }
  end

  def test_other_explore_chart_is_a_placeholder
    c = base_chart
    c['metricQuery']['exploreName'] = 'something_else'
    res = build_inline('c1' => c)
    assert_equal 'text', el(res, 'el-c1')['kind']
    assert(res['gaps'].any? { |g| g['reason'].include?('something_else') })
  end

  def test_simple_arithmetic_table_calc_is_translated
    t = base_chart
    t['metricQuery']['dimensions'] = ['orders_region']
    t['metricQuery']['metrics'] = %w[orders_total_order_amount orders_total_orders]
    t['metricQuery']['tableCalculations'] = [
      { 'name' => 'aov', 'displayName' => 'Avg Order Value', 'sql' => '${orders.total_order_amount} / ${orders.total_orders}', 'type' => 'number' },
      { 'name' => 'ranked', 'displayName' => 'Rank', 'formula' => '=RANK(${orders.total_order_amount})', 'type' => 'number' },
      { 'name' => 'tmpl', 'displayName' => 'Pct', 'template' => { 'type' => 'percent_of_column_total', 'fieldId' => 'orders_total_orders' }, 'type' => 'number' }
    ]
    t['chartConfig'] = { 'type' => 'table', 'config' => {} }
    res = build_inline('t1' => t)
    assert_equal [], res['violations']
    tbl = el(res, 'el-t1')
    calc = tbl['columns'].find { |c| c['name'] == 'Avg Order Value' }
    assert_equal '[Metrics/Total Order Amount] / [Metrics/Total Orders]', calc['formula']
    assert_includes tbl['groupings'][0]['calculations'], calc['id']
    assert_equal 2, res['gaps'].count { |g| g['item'].include?('ranked') || g['item'].include?('tmpl') }
    assert(res['gaps'].any? { |g| g['reason'].include?('formula-type') })
    assert(res['gaps'].any? { |g| g['reason'].include?('template') })
  end

  def test_custom_metric_and_period_over_period
    c = base_chart
    c['metricQuery']['metrics'] = %w[orders_big_orders orders_prior]
    c['metricQuery']['additionalMetrics'] = [
      { 'table' => 'orders', 'name' => 'big_orders', 'label' => 'Big Orders', 'type' => 'sum', 'sql' => '${TABLE}.amount',
        'baseDimensionName' => 'amount', 'filters' => [{ 'target' => { 'fieldRef' => 'status' }, 'operator' => 'equals', 'values' => ['completed'] }] },
      { 'table' => 'orders', 'name' => 'prior', 'type' => 'sum', 'sql' => '${TABLE}.amount', 'baseDimensionName' => 'amount',
        'generationType' => 'periodOverPeriod' }
    ]
    c['chartConfig']['config']['layout']['yField'] = %w[orders_big_orders orders_prior]
    c['chartConfig']['config']['eChartsConfig']['series'] = []
    res = build_inline('c1' => c)
    assert_equal [], res['violations']
    e = el(res, 'el-c1')
    big = e['columns'].find { |x| x['name'] == 'Big Orders' }
    assert_equal 'SumIf([Lightdash Data/Amount], [Lightdash Data/Status] = "completed")', big['formula']
    assert_equal [big['id']], e['yAxis']['columnIds']
    assert(res['gaps'].any? { |g| g['reason'].include?('period-over-period') })
  end

  def test_chart_filter_operators
    c = base_chart
    c['metricQuery']['filters'] = { 'dimensions' => { 'id' => 'g', 'and' => [
      { 'id' => 'r1', 'target' => { 'fieldId' => 'orders_status' }, 'operator' => 'notEquals', 'values' => ['returned'] },
      { 'id' => 'r2', 'target' => { 'fieldId' => 'orders_amount' }, 'operator' => 'inBetween', 'values' => [5, 50] },
      { 'id' => 'r3', 'target' => { 'fieldId' => 'orders_channel' }, 'operator' => 'startsWith', 'values' => ['x'] },
      { 'id' => 'r4', 'target' => { 'fieldId' => 'orders_order_date_day' }, 'operator' => 'lessThan', 'values' => ['2026-06-01'] }
    ] }, 'metrics' => { 'id' => 'mm', 'and' => [{ 'id' => 'r5', 'target' => { 'fieldId' => 'orders_total_orders' }, 'operator' => 'greaterThan', 'values' => [3] }] } }
    res = build_inline('c1' => c)
    assert_equal [], res['violations']
    fs = el(res, 'el-c1')['filters'].each_with_object({}) { |f, h| h[f['columnId']] = f }
    assert_equal({ 'kind' => 'list', 'mode' => 'exclude', 'values' => ['returned'] }, fs['el-c1-c-orders_status'].reject { |k, _| %w[id columnId].include?(k) })
    assert_equal [5, 50], [fs['el-c1-c-orders_amount']['min'], fs['el-c1-c-orders_amount']['max']]
    assert_equal 'before', fs['el-c1-c-orders_order_date_day']['mode']
    assert_equal '2026-06-01T00:00:00Z', fs['el-c1-c-orders_order_date_day']['date']
    assert_nil fs['el-c1-c-orders_channel'], 'startsWith is a ledger gap'
    assert(res['gaps'].any? { |g| g['item'].include?('orders_channel') })
    assert(res['gaps'].any? { |g| g['item'].include?('metric filter') })
  end

  def test_flat_chart_filters_are_applied_and_unsupported_groups_are_ledgered
    c = base_chart
    c['metricQuery']['filters'] = {
      'dimensions' => [
        { 'target' => { 'fieldId' => 'orders_status' }, 'operator' => 'equals', 'values' => ['completed'] }
      ],
      'metrics' => [
        { 'target' => { 'fieldId' => 'orders_total_orders' }, 'operator' => 'greaterThan', 'values' => [3] }
      ],
      'tableCalculations' => [
        { 'target' => { 'fieldId' => 'calc' }, 'operator' => 'greaterThan', 'values' => [1] }
      ]
    }
    res = build_inline('c1' => c)
    filter = el(res, 'el-c1')['filters'].find { |f| f['columnId'] == 'el-c1-c-orders_status' }
    assert_equal ['completed'], filter['values']
    assert(res['gaps'].any? { |g| g['item'] == 'chart c1: metric filter' })
    assert(res['gaps'].any? { |g| g['item'] == 'chart c1: table calculation filter' })
  end

  def test_unmapped_field_makes_the_chart_a_placeholder_and_is_ledgered
    c = base_chart
    c['metricQuery']['dimensions'] = ['customers_signup_date_month']
    c['chartConfig']['config']['layout']['xField'] = 'customers_signup_date_month'
    res = build_inline('c1' => c)
    assert_equal 'text', el(res, 'el-c1')['kind']
    assert(res['gaps'].any? { |g| g['class'] == 'scope-cut' && g['item'].include?('customers_signup_date_month') })
  end

  def test_no_tabs_dashboard_builds_one_page
    res = build_inline('c1' => base_chart)
    visible = res['spec']['pages'].reject { |p| p['hidden'] }
    assert_equal 1, visible.length
    assert_equal 'Inline', visible[0]['name']
  end

  def test_tall_minimum_rows_do_not_overlap
    tiles = [{ 'x' => 0, 'y' => 0, 'w' => 36, 'h' => 2, 'type' => 'saved_chart', 'tileSlug' => 'a', 'properties' => { 'chartSlug' => 'a' } },
             { 'x' => 0, 'y' => 2, 'w' => 36, 'h' => 2, 'type' => 'saved_chart', 'tileSlug' => 'b', 'properties' => { 'chartSlug' => 'b' } }]
    res = build_inline({ 'a' => base_chart, 'b' => base_chart }, tiles: tiles)
    rows = layout_rows(res, 'page-1')
    assert rows['el-a'][:r1] <= rows['el-b'][:r0], rows.inspect
    assert rows['el-a'][:r1] - rows['el-a'][:r0] >= 8, 'chart minimum rows enforced'
  end


  # ---- review fixes -------------------------------------------------------------------------
  def test_overlapping_limited_controls_get_one_base_table_per_control_set
    charts = { 'a' => base_chart, 'b' => base_chart, 'c' => base_chart }
    mk = lambda do |id, field, tiles|
      { 'id' => id, 'target' => { 'fieldId' => field }, 'operator' => 'equals', 'values' => ['x'],
        # upstream semantics: unlisted tiles are targeted by default, so limit with explicit `false` entries
        'tileTargets' => (%w[a b c] - tiles).each_with_object({}) { |t, h| h[t] = false } }
    end
    res = build_inline(charts, filters: { 'dimensions' => [mk.call('f1', 'orders_status', %w[a b]), mk.call('f2', 'orders_channel', %w[b c])] })
    assert_equal [], res['violations']
    src = %w[a b c].each_with_object({}) { |s, h| h[s] = el(res, "el-#{s}")['source']['elementId'] }
    assert_equal 3, src.values.uniq.length, 'a only f1, b both, c only f2'
    f1 = elements(res).find { |e| e['kind'] == 'control' && e['name'] == 'Status' }
    f2 = elements(res).find { |e| e['kind'] == 'control' && e['name'] == 'Channel Group' }
    assert_equal [src['a'], src['b']].sort, f1['filters'].map { |f| f['source']['elementId'] }.sort
    assert_equal [src['b'], src['c']].sort, f2['filters'].map { |f| f['source']['elementId'] }.sort
    # the chart covered by both sits on a base table carrying both filter columns
    both = el(res, src['b'])
    assert_equal ['Channel Group', 'Status'], (both['columns'].map { |c| c['name'] } & ['Channel Group', 'Status']).sort
  end

  def test_tile_targets_default_semantics_are_ledgered
    res = build
    assert(res['notes'].any? { |g| g['item'] == 'dashboard filter customers_segment' && g['reason'] =~ /not listed are filtered by default/ })
    refute(res['gaps'].any? { |g| g['item'] == 'dashboard filter customers_segment' && g['reason'] =~ /not listed are filtered by default/ })
  end

  def test_false_only_tile_targets_filter_every_other_tile
    Dir.mktmpdir do |tmp|
      File.write(File.join(tmp, 'd.yml'), YAML.dump(
                                            'name' => 'D', 'tiles' => %w[a b c].each_with_index.map { |s, i| { 'x' => i * 6, 'y' => 0, 'w' => 6, 'h' => 4, 'type' => 'saved_chart', 'tileSlug' => s, 'properties' => { 'chartSlug' => s } } },
                                            'filters' => { 'dimensions' => [{ 'id' => 'f1', 'target' => { 'fieldId' => 'orders_region' }, 'operator' => 'equals',
                                                                              'values' => ['n'], 'tileTargets' => { 'b' => false } }] }
                                          ))
      %w[a b c].each { |s| File.write(File.join(tmp, "#{s}.yml"), YAML.dump('slug' => s, 'name' => s, 'tableName' => 'orders', 'metricQuery' => {})) }
      dash = LightdashExport.load(File.join(tmp, 'd.yml'), tmp)
      assert_equal %w[a c], dash['filters'][0]['target_tiles'], '{b: false} = every chart tile except b'
    end
  end

  def test_null_filters_and_ascending_limit_are_ledgered_not_guessed
    c = base_chart
    c['metricQuery']['filters'] = { 'dimensions' => { 'id' => 'g', 'and' => [
      { 'id' => 'r1', 'target' => { 'fieldId' => 'orders_status' }, 'operator' => 'isNull', 'values' => [] },
      { 'id' => 'r2', 'target' => { 'fieldId' => 'orders_channel' }, 'operator' => 'notNull', 'values' => [] }
    ] } }
    c['metricQuery']['sorts'] = [{ 'fieldId' => 'orders_total_order_amount', 'descending' => false }]
    c['metricQuery']['limit'] = 5
    res = build_inline('c1' => c)
    assert_nil el(res, 'el-c1')['filters'], 'no null-valued list filter and no bottom-n are emitted'
    assert_equal 2, res['gaps'].count { |g| g['item'].start_with?('chart c1: filter on') }
    assert(res['gaps'].any? { |g| g['item'] == 'chart c1' && g['reason'].include?('row limit 5') })
  end

  def test_dimension_only_table_is_grouped_for_distinct_rows
    t = base_chart
    t['metricQuery']['metrics'] = []
    t['chartConfig'] = { 'type' => 'table', 'config' => {} }
    res = build_inline('t1' => t)
    assert_equal [], res['violations']
    g = el(res, 'el-t1')['groupings'][0]
    assert_equal ['el-t1-c-orders_region'], g['groupBy']
    refute g.key?('calculations')
  end

  # ---- CLI -------------------------------------------------------------------------------
  def test_cli_end_to_end_writes_all_artifacts
    Dir.mktmpdir do |tmp|
      _o, e1, s1 = Open3.capture3('ruby', DM_CLI, '--source-dir', FIXTURE, '--explore', 'orders', '--connection-id', CONN,
                                  '--out', File.join(tmp, 'dm.json'))
      assert s1.success?, e1
      out = File.join(tmp, 'wb.json')
      _o, e2, s2 = Open3.capture3('ruby', BUILD_CLI, '--dashboard', DASH, '--charts-dir', CHARTS,
                                  '--dm-envelope', File.join(tmp, 'dm.json'), '--field-map', File.join(tmp, 'field-map.json'),
                                  '--dm-id', 'dm-cli', '--out', out, '--workbook-map-out', File.join(tmp, 'map.json'))
      assert s2.success?, e2
      wb = JSON.parse(File.read(out))
      assert_equal 'Jaffle Overview', wb['workbook']['name']
      assert wb['workbook']['document']['layout'].include?('<Page')
      assert_equal 6, wb['stats']['charts']
      assert_equal 6, JSON.parse(File.read(File.join(tmp, 'map.json'))).length
      assert File.file?(File.join(tmp, 'chart-gaps.json'))
      assert File.file?(File.join(tmp, 'control-scope.json'))
      # control_lint standalone accepts the scope sidecar
      spec = wb['workbook']['document']
      assert_empty ControlLint.lint(spec, scope: JSON.parse(File.read(File.join(tmp, 'control-scope.json'))))
    end
  end

  def test_dm_lookup_binds_live_element_id
    dash = LightdashExport.load(DASH, CHARTS)
    lookup = { 'explore-orders' => { 'elementId' => 'live-el-9', 'name' => 'Orders (Explore)' } }
    res = LightdashWorkbook.build(dash, dm[1], dm[0], dm_id: 'dm-x', dm_lookup: lookup)
    assert_equal 'live-el-9', el(res, 'tbl-master')['source']['elementId']
    refute(res['warnings'].any? { |w| w.include?('--dm-lookup') })
  end

  def test_chart_map_classification
    cm = LightdashChartMap
    assert_equal 'bar-chart', cm.classify(base_chart)['kind']
    flipped = deep(base_chart)
    flipped['chartConfig']['config']['layout']['flipAxes'] = true
    assert_equal 'horizontal', cm.classify(flipped)['orientation']
    scatter = deep(base_chart)
    scatter['chartConfig']['config']['eChartsConfig']['series'][0]['type'] = 'scatter'
    assert_equal 'scatter-chart', cm.classify(scatter)['kind']
    funnel = deep(base_chart)
    funnel['chartConfig'] = { 'type' => 'funnel', 'config' => {} }
    assert_equal 'funnel-chart', cm.classify(funnel)['kind']
    assert_nil cm.classify('chartConfig' => { 'type' => 'brand_new' })['kind']
  end
end
