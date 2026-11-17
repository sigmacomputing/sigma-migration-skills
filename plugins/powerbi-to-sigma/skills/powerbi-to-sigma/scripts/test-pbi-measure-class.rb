#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for lib/pbi_measure_class.rb (Power BI-shaped model mode, task 10): the A/B/C/D class of
# every measure on a visible visual, over the generated sales and inventory fixture models.
# Synthetic names only. No network. Run: ruby scripts/test-pbi-measure-class.rb
require 'json'
require_relative 'lib/pbi_measure_class'

SKILL = File.dirname(__dir__)
FIX   = File.join(SKILL, 'fixtures', 'pbi-shaped')
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def load_json(*parts)
  JSON.parse(File.read(File.join(FIX, *parts)))
end

SALES = load_json('sales', 'model.bim')
INV   = load_json('inventory', 'model.bim')
SALES_RELS = SALES['model']['relationships']
INV_RELS   = INV['model']['relationships']

def cls(table, measure, bim = SALES, rels = SALES_RELS)
  PbiMeasureClass.classify(table: table, measure: measure, tmsl: bim, relationships: rels)
end

def test_sales_amount_is_a
  puts 'test_sales_amount_is_a'
  %w[Sales\ Amount Units Cost Gross\ Margin GM\ % Orders].each do |m|
    r = cls('Sales', m)
    check(r['class'] == 'A' && r['related'] == [] && r['userel'].nil? && r['ti'].nil?, "#{m} is A (#{r['reason']})")
  end
  check(cls('Sales', 'Sales Amount')['home'] == 'Sales', 'home is the fact the measure reads')
end

def test_list_value_is_b_with_three_hop_path
  puts 'test_list_value_is_b_with_three_hop_path'
  r = cls('Sales', 'List Value')
  check(r['class'] == 'B', 'List Value is B')
  check(r['related'] == [{ 'table' => 'Product', 'column' => 'List Price', 'path' => %w[SKU Product] }],
        "related is Product[List Price] via SKU > Product (#{r['related'].inspect})")
  p = cls('Sales', 'Private Label Sales')
  check(p['class'] == 'B' && p['related'].first['path'] == %w[SKU Product] && p['related'].first['column'] == 'Private Label',
        'a CALCULATE filter on a dimension column is B with the same path')
end

def test_sales_by_ship_date_is_b_with_userel
  puts 'test_sales_by_ship_date_is_b_with_userel'
  r = cls('Sales', 'Sales by Ship Date')
  check(r['class'] == 'B' && r['userel'] == 'Date (ShipDateKey)', "B with userel Date (ShipDateKey) (#{r['userel'].inspect})")
end

def test_ytd_qtd_mtd_py_r28_are_c_with_patterns
  puts 'test_ytd_qtd_mtd_py_r28_are_c_with_patterns'
  { 'Sales YTD' => 'ytd', 'Sales QTD' => 'qtd', 'Sales MTD' => 'mtd', 'Sales PY' => 'py', 'Sales R28' => 'rolling' }.each do |m, pat|
    r = cls('Sales', m)
    check(r['class'] == 'C' && r['ti']['pattern'] == pat && r['ti']['base'] == 'Sales Amount', "#{m} is C #{pat} over Sales Amount")
  end
  r28 = cls('Sales', 'Sales R28')['ti']
  check(r28['days'] == 28 && r28['anchor'] == 'axis', 'Sales R28 rolls 28 days on the axis')
  check(cls('Sales', 'Sales YTD (As Of)')['ti']['anchor'] == 'as_of', 'Sales YTD (As Of) anchors on the As Of table')
  check(cls('Sales', 'Sales YTD')['ti']['anchor'] == 'axis', 'Sales YTD anchors on the axis')
  yoy = cls('Sales', 'Sales YoY %')
  check(yoy['class'] == 'C' && yoy['ti']['pattern'] == 'py' && yoy['ti']['base'] == 'Sales Amount',
        'YoY % (C over C) is C py with the plain measure as base')
end

def test_days_of_cover_is_d
  puts 'test_days_of_cover_is_d'
  %w[On\ Hand\ (Latest) Days\ of\ Cover Products\ by\ Cover\ Bucket].each do |m|
    r = cls('Inventory', m, INV, INV_RELS)
    check(r['class'] == 'D' && !r['reason'].empty?, "#{m} is D (#{r['reason']})")
  end
  check(cls('Inventory', 'On Hand (Latest)', INV, INV_RELS)['reason'] =~ /ALL/, 'snapshot ALL(...) named in the reason')
  check(cls('Inventory', 'Products by Cover Bucket', INV, INV_RELS)['reason'] =~ /per-entity/, 'bucketing named in the reason')
  r = cls('Inventory', 'Open PO Units', INV, INV_RELS)
  check(r['class'] == 'A' && r['home'] == 'Purchase Orders', 'Open PO Units is A, homed on Purchase Orders')
end

def visual(id, refs)
  { 'visual_id' => id, 'bindings' => { 'Values' => refs } }
end

def classes_for(bim, rels, refs)
  sig = { 'pages' => [{ 'visuals' => [visual('v', refs)] }] }
  PbiMeasureClass.classify_all(sig, bim, rels)
end

def test_cross_fact_visual_is_class_d
  puts 'test_cross_fact_visual_is_class_d'
  refs = ['Sales.Sales Amount', 'Inventory.Open PO Units']
  classes = classes_for(INV, INV_RELS, refs)
  check(classes.values.all? { |c| c['class'] == 'A' }, 'each measure alone is A')
  check(PbiMeasureClass.classify_visual(visual('x', refs), classes) == 'D', 'Sales + Purchase Orders measures (no shared path) is D')
  same = PbiMeasureClass.classify_visual(visual('y', ['Sales.Sales Amount', 'Sales.Units']), classes_for(SALES, SALES_RELS, ['Sales.Sales Amount', 'Sales.Units']))
  check(same == 'A', 'two measures of one fact stay A')
end

def test_visual_class_follows_the_measures
  puts 'test_visual_class_follows_the_measures'
  sg = load_json('sales', 'signals.json')
  trends = load_json('sales', 'signals-trends.json')
  c = PbiMeasureClass.classify_all(sg, SALES, SALES_RELS)
  v = ->(sig, id) { sig['pages'].flat_map { |p| p['visuals'] }.find { |x| x['visual_id'] == id } }
  check(PbiMeasureClass.classify_visual(v.(sg, 'OvBrandMatrix'), c) == 'B', 'matrix with a related measure is B')
  check(PbiMeasureClass.classify_visual(v.(sg, 'ShByMonth'), c) == 'D', 'order-date and ship-date measures on one Date axis is D')
  check(PbiMeasureClass.classify_visual(v.(sg, 'ShByRegion'), c) == 'B', 'ship-date measure by Store region is B')
  check(PbiMeasureClass.classify_visual(v.(sg, 'ShByChannel'), c) == 'B', 'mixed userel measures with no Date field stay B')
  tc = PbiMeasureClass.classify_all(trends, SALES, SALES_RELS)
  check(PbiMeasureClass.classify_visual(v.(trends, 'TrVsPy'), tc) == 'C', 'A + C measures on one chart is C')
end

def test_measures_table_measure_spanning_facts_is_class_d
  puts 'test_measures_table_measure_spanning_facts_is_class_d'
  tmsl = { 'model' => { 'tables' => [
    { 'name' => 'Orders', 'columns' => [{ 'name' => 'Qty' }, { 'name' => 'Key' }] },
    { 'name' => 'Stock', 'columns' => [{ 'name' => 'Units' }, { 'name' => 'Key' }] },
    { 'name' => 'Item', 'columns' => [{ 'name' => 'Key' }] },
    { 'name' => 'Measures', 'columns' => [], 'measures' => [
      { 'name' => 'Stock minus Orders', 'expression' => 'SUM(Stock[Units]) - SUM(Orders[Qty])' },
      { 'name' => 'Order Qty', 'expression' => 'SUM(Orders[Qty])' }
    ] }
  ] } }
  rels = [{ 'fromTable' => 'Orders', 'fromColumn' => 'Key', 'toTable' => 'Item', 'toColumn' => 'Key' },
          { 'fromTable' => 'Stock', 'fromColumn' => 'Key', 'toTable' => 'Item', 'toColumn' => 'Key' }]
  r = PbiMeasureClass.classify(table: 'Measures', measure: 'Stock minus Orders', tmsl: tmsl, relationships: rels)
  check(r['class'] == 'D' && r['reason'] =~ /no relationship path/, "spanning two facts is D (#{r['reason']})")
  one = PbiMeasureClass.classify(table: 'Measures', measure: 'Order Qty', tmsl: tmsl, relationships: rels)
  check(one['class'] == 'A' && one['home'] == 'Orders', 'a one-fact measures-table measure is A, homed on the fact it reads')
end

def test_visible_measures_and_classify_all
  puts 'test_visible_measures_and_classify_all'
  sig = { 'pages' => [{ 'visuals' => [
    { 'visual_id' => 'a', 'bindings' => { 'Values' => ['Sales.Units', 'Units', 'Category.Category Name'] } },
    { 'visual_id' => 'h', 'hidden' => true, 'bindings' => { 'Values' => ['Sales.Cost'] } },
    { 'visual_id' => 'b', 'bindings' => { 'Y' => ['Sales Amount'] } }
  ] }] }
  vm = PbiMeasureClass.visible_measures(sig, SALES)
  check(vm == [{ 'table' => 'Sales', 'measure' => 'Units' }, { 'table' => 'Sales', 'measure' => 'Sales Amount' }],
        "hidden visuals and fields skipped, bare refs resolved, deduped (#{vm.inspect})")
  all = PbiMeasureClass.classify_all(sig, SALES, SALES_RELS)
  check(all.keys == ['Sales.Units', 'Sales.Sales Amount'], 'classes keyed "<table>.<measure>"')
  sg = load_json('sales', 'signals.json')
  expected = {
    'Sales.Sales Amount' => 'A', 'Sales.Units' => 'A', 'Sales.Gross Margin' => 'A', 'Sales.GM %' => 'A',
    'Sales.Orders' => 'A', 'Sales.Avg Price' => 'A', 'Sales.Cost' => 'A', 'Sales.List Value' => 'B',
    'Sales.Private Label Sales' => 'B', 'Sales.Sales by Ship Date' => 'B'
  }
  got = PbiMeasureClass.classify_all(sg, SALES, SALES_RELS).each_with_object({}) { |(k, v), h| h[k] = v['class'] }
  check(got == expected, "pinned classes for every visible sales measure (#{got.inspect})")
  tr = load_json('sales', 'signals-trends.json')
  exp_t = { 'Sales.Sales Amount' => 'A', 'Sales.Sales YTD' => 'C', 'Sales.Sales QTD' => 'C', 'Sales.Sales MTD' => 'C',
            'Sales.Sales PY' => 'C', 'Sales.Sales YoY %' => 'C', 'Sales.Sales YTD (As Of)' => 'C', 'Sales.Sales R28' => 'C' }
  got_t = PbiMeasureClass.classify_all(tr, SALES, SALES_RELS).each_with_object({}) { |(k, v), h| h[k] = v['class'] }
  check(got_t == exp_t, "pinned classes for every visible trends measure (#{got_t.inspect})")
  iv = load_json('inventory', 'signals.json')
  exp_i = { 'Inventory.On Hand (Latest)' => 'D', 'Inventory.Open PO Units' => 'A', 'Inventory.Sales R28 Units' => 'C',
            'Inventory.Days of Cover' => 'D', 'Inventory.Products by Cover Bucket' => 'D' }
  got_i = PbiMeasureClass.classify_all(iv, INV, INV_RELS).each_with_object({}) { |(k, v), h| h[k] = v['class'] }
  check(got_i == exp_i, "pinned classes for every visible inventory measure (#{got_i.inspect})")
end

def test_circular_and_unparseable_are_d
  puts 'test_circular_and_unparseable_are_d'
  tmsl = { 'model' => { 'tables' => [{ 'name' => 'T', 'columns' => [{ 'name' => 'c' }], 'measures' => [
    { 'name' => 'X', 'expression' => '[Y] + 1' }, { 'name' => 'Y', 'expression' => '[X] + 1' },
    { 'name' => 'Z', 'expression' => 'SUM(T[nope])' }
  ] }] } }
  check(PbiMeasureClass.classify(table: 'T', measure: 'X', tmsl: tmsl, relationships: [])['class'] == 'D', 'circular measures are D')
  check(PbiMeasureClass.classify(table: 'T', measure: 'Z', tmsl: tmsl, relationships: [])['class'] == 'D', 'unknown column is D')
end

def synth(measures)
  { 'model' => { 'tables' => [
    { 'name' => 'Sales', 'columns' => %w[Qty DateKey Channel].map { |n| { 'name' => n } },
      'measures' => [{ 'name' => 'Amt', 'expression' => 'SUM(Sales[Qty])' }] + measures },
    { 'name' => 'Stock', 'columns' => [{ 'name' => 'Units' }] },
    { 'name' => 'Date', 'columns' => %w[DateKey Date].map { |n| { 'name' => n } } },
    { 'name' => 'As Of', 'columns' => [{ 'name' => 'As Of Date' }] }
  ] } }
end
SYN_RELS = [{ 'fromTable' => 'Sales', 'fromColumn' => 'DateKey', 'toTable' => 'Date', 'toColumn' => 'DateKey' }].freeze

def syn(expr)
  PbiMeasureClass.classify(table: 'Sales', measure: 'M', tmsl: synth([{ 'name' => 'M', 'expression' => expr }]), relationships: SYN_RELS)
end

def test_qualified_measure_reference_is_not_a_column_of_another_table
  puts 'test_qualified_measure_reference_is_not_a_column_of_another_table'
  r = cls('Sales', 'Avg Price', INV, INV_RELS)
  check(r['class'] == 'A' && r['home'] == 'Sales', "Avg Price (Sales[Units] is the Sales measure, not Inventory[Units]) is A (#{r['reason']})")
  check(cls('Sales', 'Avg Price')['class'] == 'A', 'Avg Price is A in the sales model too')
  sg = load_json('sales', 'signals.json')
  c = PbiMeasureClass.classify_all(sg, SALES, SALES_RELS)
  v = sg['pages'].flat_map { |p| p['visuals'] }.find { |x| x['visual_id'] == 'OvAvgPrice' }
  check(PbiMeasureClass.classify_visual(v, c) == 'A', 'the visual using Avg Price is A')
  # a same-named column elsewhere is not pulled in
  r = syn('Sales[Units] + 1')
  check(r['class'] == 'D', 'Sales[Units] with no such Sales column or measure stays D')
end

def test_totals_with_extra_arguments_are_d
  puts 'test_totals_with_extra_arguments_are_d'
  ['TOTALYTD([Amt], \'Date\'[Date], "6/30")', 'TOTALYTD([Amt], \'Date\'[Date], Sales[Channel] = "Web")',
   'TOTALQTD([Amt], \'Date\'[Date], Sales[Channel] = "Web")',
   'CALCULATE([Amt], DATESYTD(\'Date\'[Date], "6/30"))', 'CALCULATE([Amt], DATESQTD(\'Date\'[Date], "6/30"))',
   'CALCULATE([Amt], DATESMTD(\'Date\'[Date], "6/30"))'].each do |e|
    r = syn(e)
    check(r['class'] == 'D' && r['reason'] =~ /extra argument/, "#{e} is D (#{r['reason']})")
  end
  check(syn('TOTALYTD([Amt], \'Date\'[Date])')['class'] == 'C', 'plain TOTALYTD stays C')
  check(syn('CALCULATE([Amt], DATESYTD(\'Date\'[Date]))')['ti']['pattern'] == 'ytd', 'plain DATESYTD stays C')
end

def test_shifts_accept_only_one_period_back
  puts 'test_shifts_accept_only_one_period_back'
  d = "'Date'[Date]"
  { "DATEADD(#{d}, -1, YEAR)" => ['py', nil], "PARALLELPERIOD(#{d}, -1, YEAR)" => ['py', nil],
    "DATEADD(#{d}, -1, QUARTER)" => ['pp', 'quarter'], "DATEADD(#{d}, -1, MONTH)" => ['pp', 'month'],
    "PARALLELPERIOD(#{d}, -1, MONTH)" => ['pp', 'month'] }.each do |e, (pat, unit)|
    r = syn("CALCULATE([Amt], #{e})")
    check(r['class'] == 'C' && r['ti']['pattern'] == pat && r['ti']['unit'] == unit, "#{e} is C #{pat} #{unit} (#{r['reason']})")
  end
  ["DATEADD(#{d}, 1, YEAR)", "DATEADD(#{d}, -2, YEAR)", "DATEADD(#{d}, -3, MONTH)", "DATEADD(#{d}, -12, MONTH)",
   "DATEADD(#{d}, -7, DAY)", "PARALLELPERIOD(#{d}, 1, MONTH)", "PARALLELPERIOD(#{d}, -2, QUARTER)"].each do |e|
    r = syn("CALCULATE([Amt], #{e})")
    check(r['class'] == 'D', "#{e} is D (#{r['reason']})")
  end
end

def test_datesinperiod_must_run_backwards_from_max
  puts 'test_datesinperiod_must_run_backwards_from_max'
  d = "'Date'[Date]"
  check(syn("CALCULATE([Amt], DATESINPERIOD(#{d}, MAX(#{d}), -28, DAY))")['ti']['days'] == 28, 'backwards from MAX is rolling 28')
  check(syn("CALCULATE([Amt], DATESINPERIOD(#{d}, MAX(#{d}), 28, DAY))")['class'] == 'D', 'a positive count is D')
  check(syn("CALCULATE([Amt], DATESINPERIOD(#{d}, MIN(#{d}), -28, DAY))")['class'] == 'D', 'an end other than MAX is D')
  check(syn("VAR a = MAX('As Of'[As Of Date]) RETURN CALCULATE([Amt], DATESINPERIOD(#{d}, a, -28, DAY))")['class'] == 'D', 'a VAR anchor is D')
end

def test_datesbetween_rolling_mirrors_datesinperiod
  puts 'test_datesbetween_rolling_mirrors_datesinperiod'
  d = "'Date'[Date]"
  ok = syn("CALCULATE([Amt], DATESBETWEEN(#{d}, MAX(#{d}) - 6, MAX(#{d})))")
  check(ok['class'] == 'C' && ok['ti']['pattern'] == 'rolling' && ok['ti']['days'] == 7, "MAX - 6 .. MAX is rolling 7 (#{ok['reason']})")
  bare = syn("CALCULATE([Amt], DATESBETWEEN(#{d}, [Amt] - 6, [Amt]))")
  check(bare['class'] == 'D', "I5: a bare-measure anchor is D (#{bare['class']} #{bare['reason']})")
  mn = syn("CALCULATE([Amt], DATESBETWEEN(#{d}, MIN(#{d}) - 30, MAX(#{d})))")
  check(mn['class'] == 'D', "I5: MIN(...) - 30 as the start is D (#{mn['class']} #{mn['reason']})")
  end_off = syn("CALCULATE([Amt], DATESBETWEEN(#{d}, MAX(#{d}) - 6, MAX(#{d}) - 1))")
  check(end_off['class'] == 'D', "I5: an end other than MAX is D (#{end_off['class']})")
  other = syn("CALCULATE([Amt], DATESBETWEEN(#{d}, MAX('Other'[Date]) - 6, MAX(#{d})))")
  check(other['class'] == 'D', "I5: MAX over a different column is D (#{other['class']})")
end

def test_tokenizer_edge_cases
  puts 'test_tokenizer_edge_cases'
  r = syn("-- a comment with SUM(Stock[Units]) and ALL(Sales)\nSUM(Sales[Qty]) // trailing ALL(x)\n/* block ) */")
  check(r['class'] == 'A', "comments are ignored (#{r['reason']})")
  r = syn('IF(Sales[Channel] = "a]b)c", SUM(Sales[Qty]), 0)')
  check(r['class'] == 'A', "a string containing ] and ) does not confuse the parser (#{r['reason']})")
  r = syn("VAR asof = MAX('As Of'[As Of Date])\nRETURN\nCALCULATE([Amt], DATESBETWEEN('Date'[Date], DATE(YEAR(asof), 1, 1), asof))")
  check(r['class'] == 'C' && r['ti']['anchor'] == 'as_of' && r['ti']['pattern'] == 'ytd', 'VAR-with-RETURN as-of anchor is C ytd as_of')
end

test_sales_amount_is_a
test_qualified_measure_reference_is_not_a_column_of_another_table
test_totals_with_extra_arguments_are_d
test_shifts_accept_only_one_period_back
test_datesinperiod_must_run_backwards_from_max
test_datesbetween_rolling_mirrors_datesinperiod
test_tokenizer_edge_cases
test_list_value_is_b_with_three_hop_path
test_sales_by_ship_date_is_b_with_userel
test_ytd_qtd_mtd_py_r28_are_c_with_patterns
test_days_of_cover_is_d
test_cross_fact_visual_is_class_d
test_visual_class_follows_the_measures
test_measures_table_measure_spanning_facts_is_class_d
test_visible_measures_and_classify_all
test_circular_and_unparseable_are_d

puts
if $fails.empty?
  puts 'ALL PASS'
else
  puts "#{$fails.length} FAILED:"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
