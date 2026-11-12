#!/usr/bin/env ruby
# frozen_string_literal: true
# Multi-DS sub-master → posted DM element resolution (submaster_element_candidates
# in migrate-tableau.rb). The sub-master placeholder carries the Tableau
# datasource CAPTION; a caption that is the qualified table
# ("WAREHOUSE_OPS.SHIPMENTS") must resolve to the element the converter named by
# the bare table ("Shipments") — field-caught 2026-10-30, where the length-floored
# containment fallback rejected the pair (9 of 21 normalized chars) and the
# orchestrator aborted FATAL. Deterministic, offline: extracts the def alone.

src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
m = src.match(/^def submaster_element_candidates\b.*?\n^end$/m)
abort 'test bug: could not extract submaster_element_candidates' unless m
o = Object.new
o.instance_eval(m[0])

fails = 0
check = lambda do |ok, label|
  puts "  #{ok ? 'PASS' : 'FAIL'}  #{label}"
  fails += 1 unless ok
end
els = ->(*names) { names.each_with_index.map { |n, i| { 'id' => "e#{i}", 'name' => n } } }
names = ->(cands) { cands.map { |e| e['name'] } }

puts 'submaster_element_candidates'
check.call(names.call(o.submaster_element_candidates('WAREHOUSE_OPS.SHIPMENTS', els.call('Shipments', 'Orders'))) == ['Shipments'],
           'schema-qualified caption → bare-table element')
check.call(names.call(o.submaster_element_candidates('Shipments (WAREHOUSE_OPS.SHIPMENTS)', els.call('Shipments', 'Orders'))) == ['Shipments'],
           'Tableau "Name (SCHEMA.TABLE)" caption → bare-table element')
check.call(names.call(o.submaster_element_candidates('DB.WAREHOUSE_OPS.SHIPMENTS', els.call('Shipments'))) == ['Shipments'],
           'three-part qualified caption → bare-table element')
check.call(names.call(o.submaster_element_candidates('order_fact', els.call('Order Fact', 'Orders'))) == ['Order Fact'],
           'normalized-exact still wins first')
check.call(names.call(o.submaster_element_candidates('Sum Dir Bias by BiLevel Preset',
                                                       els.call('Workbook Sum Dir Bias by Bilevel Preset'))) ==
             ['Workbook Sum Dir Bias by Bilevel Preset'],
           'length-floored containment fallback unchanged')
check.call(o.submaster_element_candidates('WAREHOUSE_OPS.SHIPMENTS', els.call('Orders', 'Carriers')).empty?,
           'no bare-table element → no candidates (caller aborts FATAL as before)')
check.call(o.submaster_element_candidates('Sales', els.call('Sales Region Rollup Extended')).empty?,
           'short generic caption never absorbs an unrelated element')
check.call(o.submaster_element_candidates('A.SHIPMENTS', els.call('Shipments', 'SHIPMENTS ')).size == 2,
           'two bare-table hits are returned so the caller refuses AMBIGUOUS')

puts
puts fails.zero? ? 'ALL PASS' : "#{fails} FAIL"
exit(fails.zero? ? 0 : 1)
