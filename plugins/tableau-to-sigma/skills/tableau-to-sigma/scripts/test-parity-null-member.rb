#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression: strict parity must treat a blank CSV member (how Tableau's export
# writes NULL), nil, and the Sigma labels "Null" / "NULL" / "%null%" as ONE null
# dimension member — but never conflate a blank MEASURE with zero.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

VERIFY = File.join(__dir__, 'verify-parity.rb')
FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def verify(chart)
  Dir.mktmpdir do |dir|
    plan = File.join(dir, 'plan.json')
    File.write(plan, JSON.generate('charts' => [chart]))
    out, _err, st = Open3.capture3(RbConfig.ruby, VERIFY, '--plan', plan, '--score-out', File.join(dir, 's.json'))
    [st.exitstatus, out]
  end
end

base = { 'chart' => 'Sales by Region', 'extract' => false, 'measure_indices' => [1] }
['Null', 'NULL', '%null%', '', nil].each do |label|
  rc, out = verify(base.merge('expected' => [['East', 10.0], [nil, 5.0]],
                              'actual' => { 'rows' => [['East', 10.0], [label, 5.0]] }))
  check(rc.zero? && out.include?('PASS'), "null dimension member #{label.inspect} == blank Tableau member (exit #{rc})")
end
rc, out = verify(base.merge('expected' => [['East', 10.0], ['', 5.0]],
                            'actual' => { 'rows' => [['East', 10.0], ['Nullable', 5.0]] }))
check(!rc.zero? && out.include?('DIVERGE'), 'a real member merely resembling "Null" still diverges')
rc, out = verify(base.merge('expected' => [['East', 10.0], ['', 5.0]],
                            'actual' => { 'rows' => [['East', 10.0], ['Null', 6.0]] }))
check(!rc.zero? && out.include?('DIVERGE'), 'null member with a different measure value still diverges')
rc, = verify(base.merge('expected' => [['East', nil]], 'actual' => { 'rows' => [['East', 0.0]] }))
check(!rc.zero?, 'blank measure is not zero')

puts
if FAILS.empty?
  puts 'ALL PASS'
  exit 0
end
FAILS.each { |f| puts "  - #{f}" }
exit 1
