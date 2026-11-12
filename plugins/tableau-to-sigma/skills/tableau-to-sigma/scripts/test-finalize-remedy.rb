#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof: two identical gate-13 finalize retries tripped the loop
# breaker (correctly) but the stop never said what to change. The stop now
# prints the failing check's remedy; this pins the mapping and the call site.

require_relative 'lib/finalize_remedy'
$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

l = FinalizeRemedy.lines({ phase6: 0, gate: 13, report: 1 }, error_line: '[FAIL] gate 8b: visual verdict not recorded')
ok(l.first.include?('exit 13') && l.first.include?('record-visual-check.rb') && l.first.include?('re-running'),
   "gate 13 names the blind-grade record step (#{l.first})")
ok(l.any? { |x| x.start_with?('migration report') }, 'a failing report check gets its own remedy')
ok(l.last.include?('visual verdict not recorded'), 'the first error line is echoed')
ok(FinalizeRemedy.lines({ gate: 0 }).empty?, 'nothing failing → no remedy lines')
ok(FinalizeRemedy.lines({ gate: 99 }).first.include?('fix the gate named'), 'unknown gate code falls back')
ok((FinalizeRemedy::GATE.keys - [1, 2, 4, 5, 6, 7, 8, 9, 10, 13, 14, 15, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31]).empty?,
   'remedy table only names documented gate exits (refs/gates.md)')
src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
ok(src.include?('FinalizeRemedy.lines(') && src.include?('CHANGE THIS before the next attempt'), 'finalize LOOP STOP prints the remedy')

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
