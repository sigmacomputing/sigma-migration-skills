#!/usr/bin/env ruby
# frozen_string_literal: true

# Parser for DAX calculated tables that are the distinct values of another
# table's columns (scripts/lib/pbi_calc_table_sql.rb). Pure, no network.
require_relative 'lib/pbi_calc_table_sql'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end
P = PbiCalcTableSql

def cols(parsed)
  parsed && parsed[:columns].map { |c| [c[:name], c[:source_column]] }
end

puts "\n1. recognized shapes"
r = P.parse("VAR UniqueT = DISTINCT('Order History'[SaleDateID])\nReturn UniqueT")
check.call(r && r[:source_table] == 'Order History' && cols(r) == [%w[SaleDateID SaleDateID]], 'VAR x = DISTINCT(col) RETURN x')
r = P.parse("CALCULATETABLE(DISTINCT('Orders'[OrderDate]))")
check.call(r && r[:source_table] == 'Orders' && cols(r) == [%w[OrderDate OrderDate]], 'CALCULATETABLE(DISTINCT(col)) with no filter')
r = P.parse('DISTINCT(Orders[RegionID])')
check.call(r && r[:source_table] == 'Orders' && cols(r) == [%w[RegionID RegionID]], 'DISTINCT(Table[col]) unquoted table')
r = P.parse('values(Orders[RegionID])')
check.call(r && r[:function] == 'VALUES' && cols(r) == [%w[RegionID RegionID]], 'VALUES(Table[col]) is case-insensitive')
r = P.parse('SUMMARIZE(Orders, Orders[Region], Orders[Country])')
check.call(r && r[:source_table] == 'Orders' && cols(r) == [%w[Region Region], %w[Country Country]], 'SUMMARIZE(T, T[a], T[b])')
r = P.parse(%q(DISTINCT(SELECTCOLUMNS(Orders, "Area", Orders[Region], "Nation", Orders[Country]))))
check.call(r && cols(r) == [%w[Area Region], %w[Nation Country]], 'DISTINCT(SELECTCOLUMNS(T, "n", T[c], ...)) keeps the labels')
r = P.parse("VAR u = CALCULATETABLE(VALUES('My ''Orders'''[Id]))\nRETURN u")
check.call(r && r[:source_table] == "My 'Orders'" , "VAR around CALCULATETABLE, escaped quote in table name")

puts "\n2. comments"
dax = <<~DAX
  // Order dates
  /* VAR old = DISTINCT(Orders[Other])
     RETURN old */
  VAR UniqueT = DISTINCT('Orders'[SaleDateID]) -- trailing
  // DISTINCT(Orders[Commented])
  Return UniqueT
DAX
r = P.parse(dax)
check.call(r && cols(r) == [%w[SaleDateID SaleDateID]], 'line and block comments, including commented-out alternatives, are ignored')
check.call(P.parse(%q(DISTINCT(SELECTCOLUMNS(Orders, "A // B", Orders[Region]))))&.dig(:columns, 0, :name) == 'A // B',
           'comment markers inside a string literal are kept')

puts "\n3. everything else is nil"
{
  'a filter argument' => "CALCULATETABLE(DISTINCT(Orders[RegionID]), Orders[Status] = \"Open\")",
  'ADDCOLUMNS' => 'ADDCOLUMNS(DISTINCT(Orders[RegionID]), "X", 1)',
  'a measure reference' => 'DISTINCT([Total Sales])',
  'a measure with a table qualifier call' => 'DISTINCT(CALCULATE([Total Sales]))',
  'a whole table' => 'DISTINCT(Orders)',
  'VALUES of a whole table' => 'VALUES(Orders)',
  'two VARs' => "VAR a = DISTINCT(Orders[A])\nVAR b = DISTINCT(Orders[B])\nRETURN a",
  'a VAR returned under another name' => "VAR a = DISTINCT(Orders[A])\nRETURN b",
  'SUMMARIZE with an expression column' => 'SUMMARIZE(Orders, Orders[Region], "Sales", SUM(Orders[Amt]))',
  'SUMMARIZE across tables' => 'SUMMARIZE(Orders, Orders[Region], Customer[Name])',
  'SELECTCOLUMNS without DISTINCT' => 'SELECTCOLUMNS(Orders, "Region", Orders[Region])',
  'SELECTCOLUMNS with a computed column' => %q(DISTINCT(SELECTCOLUMNS(Orders, "R", UPPER(Orders[Region])))),
  'FILTER' => 'FILTER(DISTINCT(Orders[RegionID]), Orders[RegionID] > 1)',
  'GENERATESERIES' => 'GENERATESERIES(1, 5, 1)',
  'duplicate output names' => 'SUMMARIZE(Orders, Orders[A], Orders[a])',
  'empty text' => '  '
}.each do |label, dax_text|
  check.call(P.parse(dax_text).nil?, "nil for #{label}")
end

puts
if fails.empty?
  puts 'All checks passed'
else
  puts "#{fails.size} check(s) FAILED"
  exit 1
end
