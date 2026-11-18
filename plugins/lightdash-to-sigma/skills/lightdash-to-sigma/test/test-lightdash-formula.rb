#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for LightdashFormula: SQL -> Sigma translation, metric aggregates,
# metric filters, time intervals, sql_on parsing, formats, and gap detection.
#
#   ruby test/test-lightdash-formula.rb

require 'minitest/autorun'
require_relative '../scripts/lib/lightdash_formula'

class LightdashFormulaTest < Minitest::Test
  LF = LightdashFormula

  # Resolver fixture: own model "orders" (table nil/'orders') + joined "customers".
  def ctx(dialect: 'bigquery', metrics: {})
    fields = {
      [nil, 'status'] => '[Status]',
      [nil, 'amount'] => '[Amount]',
      [nil, 'channel'] => '[Channel Group]',
      [nil, 'order_date'] => '[Order Date]',
      ['orders', 'amount'] => '[Amount]',
      ['customers', 'segment'] => '[Customers Segment]'
    }
    metrics.each { |k, v| fields[[nil, k]] = "(#{v})" }
    {
      dialect: dialect,
      table_column: ->(c) { "[orders/#{LF.titleize(c)}]" },
      field: ->(t, n) { fields[[t, n]] }
    }
  end

  def tr(sql, dialect: 'bigquery', aggregates: false)
    LF.translate_expr(sql, ctx(dialect: dialect), aggregates: aggregates)
  end

  # ---- names / refs -------------------------------------------------------
  def test_titleize_and_display_name
    assert_equal 'Order Date', LF.titleize('order_date')
    assert_equal 'Order Id', LF.titleize('ORDER_ID')
    assert_equal 'Phone1', LF.titleize('phone1')
    assert_equal 'Sub Category', LF.titleize('Sub-Category')
    assert_equal 'Custom Label', LF.display_name('x', 'Custom Label')
    assert_equal 'Total Amount', LF.display_name('total_amount', nil)
  end

  def test_table_column_ref
    f, err = tr('${TABLE}.amount')
    assert_nil err
    assert_equal '[orders/Amount]', f
  end

  def test_table_column_ref_backticked
    f, err = tr('${TABLE}.`order_id`')
    assert_nil err
    assert_equal '[orders/Order Id]', f
  end

  def test_dimension_and_joined_refs
    assert_equal ['[Status]', nil], tr('${status}')
    assert_equal ['[Amount] * 2', nil], tr('${orders.amount} * 2')
    f, err = tr("${customers.segment} = 'VIP'")
    assert_nil err
    assert_equal '[Customers Segment] = "VIP"', f
  end

  def test_unresolved_ref_is_an_error_not_a_guess
    f, err = tr('${nope} + 1')
    assert_nil f
    assert_match(/unresolved.*nope/i, err)
  end

  # ---- translation rules --------------------------------------------------
  def test_case_to_if
    f, err = tr("CASE WHEN ${TABLE}.channel IN ('web', 'app') THEN 'Online' ELSE 'Offline' END")
    assert_nil err
    assert_equal 'If(In([orders/Channel], "web", "app"), "Online", "Offline")', f
  end

  def test_case_multiple_whens_and_no_else
    f, err = tr("CASE WHEN ${amount} > 100 THEN 'big' WHEN ${amount} > 10 AND ${status} <> 'x' THEN 'mid' END")
    assert_nil err
    assert_equal 'If([Amount] > 100, "big", [Amount] > 10 and [Status] != "x", "mid", Null)', f
  end

  def test_simple_case_with_operand
    f, err = tr("CASE ${status} WHEN 'a' THEN 1 WHEN 'b' THEN 2 ELSE 0 END")
    assert_nil err
    assert_equal 'If([Status] = "a", 1, [Status] = "b", 2, 0)', f
  end

  def test_coalesce_nullif
    f, err = tr('COALESCE(${amount}, 0) / NULLIF(${TABLE}.qty, 0)')
    assert_nil err
    assert_equal 'Coalesce([Amount], 0) / NullIf([orders/Qty], 0)', f
  end

  def test_cast_variants
    f, err = tr('CAST(EXTRACT(YEAR FROM ${TABLE}.order_date) AS STRING)')
    assert_nil err
    assert_equal 'Text(Year([orders/Order Date]))', f
    assert_equal ['Number([Status])', nil], tr('CAST(${status} AS INT64)')
    assert_equal ['Number([Status])', nil], tr('${status}::numeric')
  end

  def test_string_concat_pipes_and_concat_fn
    assert_equal ['([Status] & "-" & [Channel Group])', nil], tr("${status} || '-' || ${channel}")
    assert_equal ['([Status] & "-" & [Channel Group])', nil], tr("CONCAT(${status}, '-', ${channel})")
  end

  def test_arithmetic_and_parens
    f, err = tr('(${amount} + 1) * 2 - ${amount} / 4 % 3')
    assert_nil err
    assert_equal '([Amount] + 1) * 2 - [Amount] / 4 % 3', f
  end

  def test_null_checks_between_not_in
    assert_equal ['IsNull([Status])', nil], tr('${status} IS NULL')
    assert_equal ['IsNotNull([Status])', nil], tr('${status} IS NOT NULL')
    assert_equal ['Between([Amount], 1, 5)', nil], tr('${amount} BETWEEN 1 AND 5')
    assert_equal ['not In([Status], "a", "b")', nil], tr("${status} NOT IN ('a','b')")
  end

  def test_boolean_and_null_literals
    assert_equal ['If([Amount] > 1, True, False)', nil], tr('CASE WHEN ${amount} > 1 THEN TRUE ELSE FALSE END')
    assert_equal ['Coalesce([Status], Null)', nil], tr('COALESCE(${status}, NULL)')
  end

  def test_date_trunc_both_dialect_forms
    assert_equal ['DateTrunc("month", [Order Date])', nil], tr("DATE_TRUNC('month', ${order_date})")
    assert_equal ['DateTrunc("month", [Order Date])', nil], tr('DATE_TRUNC(${order_date}, MONTH)')
  end

  def test_string_and_math_functions
    assert_equal ['Upper(Trim([Status]))', nil], tr('UPPER(TRIM(${status}))')
    assert_equal ['Round([Amount], 2)', nil], tr('ROUND(${amount}, 2)')
    assert_equal ['Mid([Status], 1, 3)', nil], tr('SUBSTR(${status}, 1, 3)')
    assert_equal ['Len([Status])', nil], tr('LENGTH(${status})')
    assert_equal ['([Amount] / NullIf([Amount], 0))', nil], tr('SAFE_DIVIDE(${amount}, ${amount})')
  end

  def test_double_quoted_is_string_on_bigquery_gap_on_snowflake
    assert_equal ['"x"', nil], tr('"x"', dialect: 'bigquery')
    f, err = tr('"AMOUNT"', dialect: 'snowflake')
    assert_nil f
    assert_match(/identifier/i, err)
  end

  def test_window_functions_are_gaps
    f, err = tr('SUM(${amount}) OVER (PARTITION BY ${status})', aggregates: true)
    assert_nil f
    assert_match(/window/i, err)
  end

  def test_unmapped_function_is_a_gap
    f, err = tr("REGEXP_EXTRACT(${status}, 'a(.)')")
    assert_nil f
    assert_match(/REGEXP_EXTRACT/, err)
  end

  def test_aggregate_in_dimension_sql_is_a_gap
    f, err = tr('SUM(${amount})')
    assert_nil f
    assert_match(/aggregate/i, err)
  end

  def test_subquery_is_a_gap
    f, err = tr('(SELECT MAX(x) FROM t)')
    assert_nil f
    refute_nil err
  end

  def test_parameters_and_attributes_are_gaps
    _, err = tr('${status} = ${lightdash.parameters.region}')
    assert_match(/parameter/i, err)
    _, err = tr('${status} = ${ld.parameters.region}')
    assert_match(/parameter/i, err)
    _, err = tr("${status} = '${lightdash.attributes.region}'")
    assert_match(/attribute/i, err)
    _, err = tr("${status} = '${ld.attr.region}'")
    assert_match(/attribute/i, err)
  end

  def test_aggregates_allowed_in_number_metric_sql
    f, err = tr('SUM(${amount}) / NULLIF(COUNT(DISTINCT ${status}), 0)', aggregates: true)
    assert_nil err
    assert_equal 'Sum([Amount]) / NullIf(CountDistinct([Status]), 0)', f
    assert_equal ['Count()', nil], tr('COUNT(*)', aggregates: true)
  end

  def test_metric_refs_inline_in_number_metrics
    f, err = LF.translate_expr('${completed} / NULLIF(${total}, 0)',
                               ctx(metrics: { 'completed' => 'CountIf(x)', 'total' => 'Count(y)' }),
                               aggregates: true)
    assert_nil err
    assert_equal '(CountIf(x)) / NullIf((Count(y)), 0)', f
  end

  # ---- aggregates ---------------------------------------------------------
  def agg(type, expr = '[Amount]', pred: nil, percentile: nil)
    LF.aggregate_formula(type, expr, pred: pred, percentile: percentile)
  end

  def test_simple_aggregates
    { 'sum' => 'Sum', 'count_distinct' => 'CountDistinct', 'average' => 'Avg', 'min' => 'Min',
      'max' => 'Max', 'median' => 'Median', 'count' => 'Count' }.each do |type, fn|
      assert_equal ["#{fn}([Amount])", nil], agg(type), type
    end
  end

  def test_filtered_aggregates
    p = '[Status] = "completed"'
    assert_equal ["SumIf([Amount], #{p})", nil], agg('sum', pred: p)
    assert_equal ["AvgIf([Amount], #{p})", nil], agg('average', pred: p)
    assert_equal ["MinIf([Amount], #{p})", nil], agg('min', pred: p)
    assert_equal ["MaxIf([Amount], #{p})", nil], agg('max', pred: p)
    assert_equal ["CountDistinctIf([Amount], #{p})", nil], agg('count_distinct', pred: p)
    assert_equal ["CountIf(IsNotNull([Amount]) and (#{p}))", nil], agg('count', pred: p)
    assert_equal ["Median(If(#{p}, [Amount]))", nil], agg('median', pred: p)
  end

  def test_percentile
    assert_equal ['PercentileCont([Amount], 0.95)', nil], agg('percentile', percentile: 95)
    assert_equal ['PercentileCont(If(x, [Amount]), 0.5)', nil], agg('percentile', pred: 'x', percentile: 50)
    f, err = agg('percentile')
    assert_nil f
    assert_match(/percentile/i, err)
  end

  def test_unsupported_metric_types_are_gaps
    %w[sum_distinct average_distinct percent_of_total percent_of_previous running_total].each do |t|
      f, err = agg(t)
      assert_nil f, t
      assert_match(/#{t}/, err)
    end
  end

  # ---- metric filters -----------------------------------------------------
  def pred(filters)
    cols = { 'status' => '[Status]', 'amount' => '[Amount]', 'is_returned' => '[Is Returned]' }
    LF.filter_predicate(filters, ->(n) { cols[n] }, types: { 'is_returned' => 'boolean' })
  end

  def test_filter_equality_list_negation_null
    assert_equal ['[Status] = "completed"', nil], pred([{ 'status' => 'completed' }])
    assert_equal ['In([Status], "a", "b")', nil], pred([{ 'status' => %w[a b] }])
    assert_equal ['[Status] != "returned"', nil], pred([{ 'status' => '!returned' }])
    assert_equal ['IsNull([Status])', nil], pred([{ 'status' => 'null' }])
    assert_equal ['IsNotNull([Status])', nil], pred([{ 'status' => '!null' }])
  end

  def test_filter_numeric_comparisons_and_numbers
    assert_equal ['[Amount] > 4', nil], pred([{ 'amount' => '> 4' }])
    assert_equal ['[Amount] >= 4.5', nil], pred([{ 'amount' => '>= 4.5' }])
    assert_equal ['[Amount] < 10', nil], pred([{ 'amount' => '<10' }])
    assert_equal ['[Amount] <= 10', nil], pred([{ 'amount' => '<= 10' }])
    assert_equal ['[Amount] = 5', nil], pred([{ 'amount' => 5 }])
  end

  def test_filter_comparisons_on_date_dims_use_date_values_not_text
    cols = { 'created' => '[Created]' }
    types = { 'created' => 'timestamp' }
    assert_equal ['[Created] >= Date("2026-01-01")', nil], LF.filter_predicate([{ 'created' => '>= 2026-01-01' }], ->(n) { cols[n] }, types: types)
    assert_equal ['[Created] = Date("2026-01-01")', nil], LF.filter_predicate([{ 'created' => '2026-01-01' }], ->(n) { cols[n] }, types: { 'created' => 'date' })
    assert_equal ['In([Created], Date("2026-01-01"), Date("2026-02-01"))', nil],
                 LF.filter_predicate([{ 'created' => %w[2026-01-01 2026-02-01] }], ->(n) { cols[n] }, types: types)
  end

  def test_filter_booleans_and_text_operators
    assert_equal ['[Is Returned] = True', nil], pred([{ 'is_returned' => true }])
    assert_equal ['[Is Returned] = False', nil], pred([{ 'is_returned' => 'false' }])
    assert_equal ['StartsWith([Status], "ab")', nil], pred([{ 'status' => 'startsWith ab' }])
    assert_equal ['Contains([Status], "ab")', nil], pred([{ 'status' => 'include ab' }])
  end

  def test_multiple_filters_and_together
    f, err = pred([{ 'status' => 'completed' }, { 'amount' => '> 4' }])
    assert_nil err
    assert_equal '[Status] = "completed" and [Amount] > 4', f
  end

  def test_filter_gaps
    f, err = pred([{ 'status' => 'inThePast 14 months' }])
    assert_nil f
    assert_match(/inThePast/, err)
    f, err = pred([{ 'nope' => 'x' }])
    assert_nil f
    assert_match(/nope/, err)
  end

  # ---- intervals ----------------------------------------------------------
  def test_interval_formulas
    assert_equal ['DateTrunc("day", [D])', nil], LF.interval_formula('DAY', '[D]')
    assert_equal ['DateTrunc("week", [D])', nil], LF.interval_formula('WEEK', '[D]')
    assert_equal ['DateTrunc("month", [D])', nil], LF.interval_formula('MONTH', '[D]')
    assert_equal ['DateTrunc("quarter", [D])', nil], LF.interval_formula('QUARTER', '[D]')
    assert_equal ['DateTrunc("year", [D])', nil], LF.interval_formula('YEAR', '[D]')
    assert_equal ['[D]', nil], LF.interval_formula('RAW', '[D]')
    assert_equal ['Year([D])', nil], LF.interval_formula('YEAR_NUM', '[D]')
    assert_equal ['DateFormat([D], "%B")', nil], LF.interval_formula('MONTH_NAME', '[D]')
    f, err = LF.interval_formula('MILLISECOND', '[D]')
    assert_nil f
    assert_match(/MILLISECOND/, err)
  end

  # ---- sql_on / relationships --------------------------------------------
  def test_parse_sql_on
    keys = LF.parse_sql_on('${orders.customer_id} = ${customers.customer_id}')
    assert_equal [{ 'left_table' => 'orders', 'left_field' => 'customer_id',
                    'right_table' => 'customers', 'right_field' => 'customer_id' }], keys
    assert_equal 2, LF.parse_sql_on('${a.x} = ${b.y} AND ${a.z} = ${b.w}').length
    assert_equal keys, LF.parse_sql_on('(${orders.customer_id} = ${customers.customer_id})')
    assert_equal keys, LF.parse_sql_on('`project`.`dataset`.`orders`.`customer_id` = `project`.`dataset`.`customers`.`customer_id`')
    assert_nil LF.parse_sql_on('${a.x} > ${b.y}')
    assert_nil LF.parse_sql_on('${a.x} = ${b.y} AND ${a.active} = TRUE')
    assert_nil LF.parse_sql_on("${a.x} = ${b.y} OR ${a.z} = 'q'")
    assert_nil LF.parse_sql_on('')
  end

  def test_relationship_type
    assert_equal 'N:1', LF.relationship_type('many-to-one')
    assert_equal '1:N', LF.relationship_type('one-to-many')
    assert_equal '1:1', LF.relationship_type('one-to-one')
    assert_equal 'N:N', LF.relationship_type('many-to-many')
    assert_equal 'N:1', LF.relationship_type(nil)
  end

  # ---- formats ------------------------------------------------------------
  def test_sigma_format_spreadsheet_style
    assert_equal({ 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' }, LF.sigma_format('[$$]#,##0.00'))
    assert_equal({ 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }, LF.sigma_format('[$$]#,##0'))
    assert_equal({ 'kind' => 'number', 'formatString' => '€,.2f', 'currencySymbol' => '€' }, LF.sigma_format('[$€-407]#,##0.00'))
    assert_equal({ 'kind' => 'number', 'formatString' => '.1%' }, LF.sigma_format('0.0%'))
    assert_equal({ 'kind' => 'number', 'formatString' => '.0%' }, LF.sigma_format('0%'))
    assert_equal({ 'kind' => 'number', 'formatString' => ',.0f' }, LF.sigma_format('#,##0'))
    assert_equal({ 'kind' => 'number', 'formatString' => '.2f' }, LF.sigma_format('0.00'))
  end

  def test_sigma_format_object_legacy_and_date
    assert_equal({ 'kind' => 'number', 'formatString' => '.1%' }, LF.sigma_format({ 'type' => 'percent', 'round' => 1 }))
    assert_equal({ 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' },
                 LF.sigma_format({ 'type' => 'currency', 'currency' => 'USD', 'round' => 2 }))
    assert_equal({ 'kind' => 'number', 'formatString' => '.2f' }, LF.sigma_format(nil, round: 2))
    assert_equal({ 'kind' => 'datetime', 'formatString' => '%b %d, %Y' }, LF.sigma_format('mmm dd, yyyy', type: 'date'))
    assert_nil LF.sigma_format(nil)
    assert_nil LF.sigma_format('')
  end

  def test_sigma_format_unparseable_returns_nil
    assert_nil LF.sigma_format('0.0"k"')
  end
end
