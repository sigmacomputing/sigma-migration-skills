#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for OmniFormula (timeframes, groups, bins, CASE WHEN, casts,
# SQL functions, conditional measure filters, and format strings).
#
#   ruby test/test-omni-formula.rb

require_relative '../scripts/lib/omni_formula'

$failures = 0
def eq(a, b, m)
  if a == b
    puts "  ok: #{m}"
  else
    $failures += 1
    puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}"
  end
end

puts '== display_name =='
eq(OmniFormula.display_name('sale_price', nil), 'Sale Price', 'snake_case to Title Case')
eq(OmniFormula.display_name('sale_price', 'Gross Revenue'), 'Gross Revenue', 'explicit label wins')

puts '== sigma_format =='
eq(OmniFormula.sigma_format('usdcurrency_2'),
   { 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' },
   'usdcurrency_2 maps to 2-decimal USD')
eq(OmniFormula.sigma_format('eurcurrency_0'),
   { 'kind' => 'number', 'formatString' => '€,.0f', 'currencySymbol' => '€' },
   'eurcurrency_0 maps to 0-decimal EUR')
eq(OmniFormula.sigma_format('percent_1'),
   { 'kind' => 'number', 'formatString' => '.1%' },
   'percent_1 maps to .1%')
eq(OmniFormula.sigma_format('decimal_2'),
   { 'kind' => 'number', 'formatString' => ',.2f' },
   'decimal_2 maps to ,.2f')

puts '== timeframe_formula =='
eq(OmniFormula.timeframe_formula('month', '[Orders/Created At]'),
   'DateTrunc("month", [Orders/Created At])',
   'month timeframe -> DateTrunc("month", ...)')
eq(OmniFormula.timeframe_formula('date', '[Orders/Created At]'),
   'DateTrunc("day", [Orders/Created At])',
   'date timeframe -> DateTrunc("day", ...)')
eq(OmniFormula.timeframe_formula('fiscal_quarter', '[Orders/Created At]'),
   'DateTrunc("quarter", [Orders/Created At])',
   'fiscal_quarter -> DateTrunc("quarter", ...)')
eq(OmniFormula.timeframe_formula('day_of_week_name', '[Orders/Created At]'),
   'DateFormat([Orders/Created At], "%A")',
   'day_of_week_name -> DateFormat(..., "%A")')
eq(OmniFormula.timeframe_formula('month_num', '[Orders/Created At]'),
   'Month([Orders/Created At])',
   'month_num -> Month(...)')

puts '== groups_formula =='
grp_spec = {
  'groups' => [
    { 'name' => 'Midwest', 'filter' => { 'is' => %w[IL IN MI] } },
    { 'name' => 'Pacific', 'filter' => { 'is' => ['CA'] } }
  ],
  'else' => 'Rest of US'
}
eq(OmniFormula.groups_formula(grp_spec, '[USERS/State]'),
   'If(In([USERS/State], "IL", "IN", "MI"), "Midwest", [USERS/State] = "CA", "Pacific", "Rest of US")',
   'groups: compiles multi-value In(...) and single-value = with else fallback')

grp_raw_else = {
  'groups' => [{ 'name' => 'Completed', 'filter' => { 'is' => ['COMPLETE'] } }],
  'else_raw_value' => true
}
eq(OmniFormula.groups_formula(grp_raw_else, '[ORDERS/Status]'),
   'If([ORDERS/Status] = "COMPLETE", "Completed", [ORDERS/Status])',
   'else_raw_value: true falls back to the base column reference')

puts '== bins_formula =='
bin_spec = { 'bin_boundaries' => [20, 40, 60] }
eq(OmniFormula.bins_formula(bin_spec, '[USERS/Age]'),
   'If([USERS/Age] < 20, "< 20", [USERS/Age] < 40, ">= 20 and < 40", [USERS/Age] < 60, ">= 40 and < 60", "60 and above")',
   'bin_boundaries compiles sorted numeric buckets into Sigma If(...)')

puts '== translate_expr (CASE WHEN, casts, timeframes, SQL functions) =='
resolver = lambda do |v, f|
  map = {
    %w[orders status] => '[Status]',
    %w[orders sale_price] => '[Sale Price]',
    %w[orders created_at] => '[Created At]',
    %w[users first_name] => '[First Name]',
    %w[users last_name] => '[Last Name]'
  }
  map[[v, f]]
end

f1, err1 = OmniFormula.translate_expr(
  "CASE WHEN ${orders.status} = 'COMPLETE' THEN ${orders.sale_price} ELSE 0 END",
  resolver
)
eq([f1, err1], ['If([Status] = "COMPLETE", [Sale Price], 0)', nil],
   'CASE WHEN ... THEN ... ELSE ... END translates to Sigma If(...)')

f2, err2 = OmniFormula.translate_expr('${orders.sale_price}::string', resolver)
eq([f2, err2], ['Text([Sale Price])', nil], '::string cast translates to Text(...)')

f3, err3 = OmniFormula.translate_expr('COALESCE(LOWER(${users.first_name}), \'anon\')', resolver)
eq([f3, err3], ['Coalesce(Lower([First Name]), "anon")', nil], 'COALESCE and LOWER translate to Sigma functions')

f4, err4 = OmniFormula.translate_expr('${created_at[quarter]}', resolver, default_view: 'orders')
eq([f4, err4], ['DateTrunc("quarter", [Created At])', nil], 'intra-view ${field[timeframe]} resolves with default_view')

puts '== untranslatable guards =='
eq(OmniFormula.untranslatable?('omni_dimensionalize(sum(${orders.sale_price}))'),
   'omni_dimensionalize has no Sigma equivalent',
   'omni_dimensionalize fails closed')
eq(OmniFormula.untranslatable?("CASE WHEN {{ omni_attributes.region }} = 'US' THEN 1 END"),
   'Mustache user-attribute SQL is not translated',
   'Mustache user attribute fails closed')
eq(OmniFormula.untranslatable?('-- DO NOT PARSE\nSELECT 1'),
   'DO NOT PARSE dialect escape is not translated',
   'DO NOT PARSE fails closed')

puts '== aggregate_formula & conditional measure filters =='
local_disp = lambda do |f|
  {
    'sale_price' => 'Sale Price',
    'status' => 'Status',
    'user_id' => 'User Id',
    'discount' => 'Discount'
  }[f.to_s]
end

m_sum, e_sum = OmniFormula.aggregate_formula(
  { 'aggregate_type' => 'sum', 'sql' => '${orders.sale_price}',
    'filters' => { 'status' => { 'is' => 'COMPLETE' } } },
  'orders', local_disp
)
eq([m_sum, e_sum], ['SumIf([Sale Price], [Status] = "COMPLETE")', nil],
   'filtered sum compiles to SumIf([Col], predicate)')

m_cnt, e_cnt = OmniFormula.aggregate_formula(
  { 'aggregate_type' => 'count',
    'filters' => { 'status' => { 'is' => %w[COMPLETE SHIPPED] }, 'discount' => { 'greater_than' => 0 } } },
  'orders', local_disp
)
eq([m_cnt, e_cnt], ['CountIf(In([Status], "COMPLETE", "SHIPPED") and [Discount] > 0)', nil],
   'filtered count with multi-value is + greater_than compiles to CountIf(...)')

m_cd, e_cd = OmniFormula.aggregate_formula(
  { 'aggregate_type' => 'count_distinct', 'sql' => '${orders.user_id}',
    'filters' => { 'status' => { 'not' => 'CANCELLED' } } },
  'orders', local_disp
)
eq([m_cd, e_cd], ['CountDistinctIf([User Id], [Status] != "CANCELLED")', nil],
   'filtered count_distinct compiles to CountDistinctIf(...)')

m_pct, e_pct = OmniFormula.aggregate_formula(
  { 'aggregate_type' => 'percentile', 'percentile' => 95, 'sql' => '${orders.sale_price}' },
  'orders', local_disp
)
eq([m_pct, e_pct], ['PercentileCont([Sale Price], 0.95)', nil],
   'percentile measure compiles to PercentileCont([Col], p)')

m_inline, e_inline = OmniFormula.aggregate_formula(
  { 'sql' => 'AVG(${orders.sale_price})' },
  'orders', local_disp
)
eq([m_inline, e_inline], ['Avg([Sale Price])', nil],
   'inline SQL AVG(${view.field}) without aggregate_type compiles to Avg([Col])')

if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
