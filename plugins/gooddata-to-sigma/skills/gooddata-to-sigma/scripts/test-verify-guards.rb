#!/usr/bin/env ruby
# frozen_string_literal: true
# Guard test for gooddata's empty-workbook protection + THE ONE PATH (2026-07-10).
# verify-warehouse.rb must fail an empty workbook (total > 0 guard), and the SKILL
# must funnel to THE ONE PATH (no hand-author). Source-level assertions.
DIR = __dir__
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end
vw = File.read(File.join(DIR, 'verify-warehouse.rb'))
check(vw.include?('total > 0'), 'verify-warehouse fails an empty workbook (total > 0 guard)', fails)
check(vw.include?("status == 'PASS' ? 0 : 2") || vw.include?('exit(status'), 'verify-warehouse exits non-zero on FAIL', fails)
sk = File.read(File.join(DIR, '..', 'SKILL.md'))
check(sk.include?('THE ONE PATH'), 'SKILL carries THE ONE PATH directive', fails)
check(sk.downcase.include?('never hand-author') && sk.include?('must PASS'),
      'directive forbids hand-authoring + mandates verify-warehouse PASS', fails)
puts
if fails.empty? then puts 'ALL PASS' else puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1 end
