#!/usr/bin/env ruby
# frozen_string_literal: true
# Guards the --reuse-workbook in-place-update wiring (2026-07-09).
#
# Iterating a fix should EDIT the same dashboard, not orphan it. --reuse-workbook
# <id> must PUT the freshly-built full spec to that workbook via post-and-readback
# --update-id (which preserves layout on re-PUT), instead of POSTing a new one.
# Source-level assertions (a live POST can't be unit-tested), mirroring
# test-fact-pick's threading check.
#
# Usage: ruby scripts/test-reuse-workbook.rb

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

mig = File.read(File.join(__dir__, 'migrate-tableau.rb'))
par = File.read(File.join(__dir__, 'post-and-readback.rb'))

check(mig.include?("opts[:reuse_workbook] = v"), '--reuse-workbook option is parsed', fails)
check(mig.match?(/update_wb\s*=\s*append_update_id\s*\|\|\s*opts\[:reuse_workbook\]/),
      'reuse_workbook falls back after --workbook-target for the update id', fails)
check(mig.include?("par_cmd += ['--update-id', update_wb] if update_wb"),
      'the workbook post-and-readback receives --update-id when reusing', fails)
check(par.include?('--update-id') && par.match?(/PUT .* instead of POST|avoids orphan/i),
      'post-and-readback --update-id PUTs in place (no orphan)', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
