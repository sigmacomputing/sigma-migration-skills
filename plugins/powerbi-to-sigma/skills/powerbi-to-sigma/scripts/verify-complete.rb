#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the single offline "is this migration actually done?" check.
#
# A Power BI→Sigma conversion produced a real, non-empty workbook ONLY when
# migrate-powerbi.rb finished and stamped <workdir>/phase6-success.json
# (workbookId + chartCount + gates) at exit 0. An EMPTY / placeholder workbook
# (pages but no elements — the classic failure where a blocked agent hand-builds
# a shell) never gets that marker, because the orchestrator refuses to green a
# 0-element build. So "built" is a fact on disk, not "the pages look right".
#
# IMPORTANT: the one-shot orchestrator's marker proves resolution/non-empty
# structure only. This verifier additionally requires parity-final.json with
# every chart strict-PASS. A stale Import snapshot is useful diagnostic evidence
# but not completion; refresh Power BI and rerun parity before handoff.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — non-empty build marker + parity-final.json proving every chart
#              strict-PASS against the source
#   2  NOT DONE — no success marker (conversion didn't complete / was hand-built)
#   3  NOT DONE — marker present but 0 chart elements (empty workbook)
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked
#   5  NOT DONE — value parity missing, stale-only, divergent, or internally inconsistent

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--workbook-id ID') { |v| opts[:wb] = v }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

succ = File.join(opts[:wd], 'phase6-success.json')
unless File.exist?(succ)
  warn '⛔ NOT DONE — no phase6-success.json in the workdir.'
  warn '   The conversion did not complete a resolution-verified build. If pages exist but are empty,'
  warn '   they were NOT produced by a real migrate-powerbi.rb run — re-run the orchestrator'
  warn "   (never hand-author a workbook). Workdir checked: #{opts[:wd]}"
  exit 2
end

sj = begin
  JSON.parse(File.read(succ))
rescue StandardError
  {}
end

if sj['chartCount'].to_i <= 0
  warn '⛔ NOT DONE — success marker present but 0 chart elements (empty workbook).'
  exit 3
end
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  exit 4
end

# Report VALUE PARITY separately from the build/resolution marker. The value gate
# (assert-phase6-ran.rb / phase6-parity-pbi.rb) writes parity-final.json; surface its
# status honestly rather than implying the one-shot build already value-verified.
pf = File.join(opts[:wd], 'parity-final.json')
pf_doc = begin
  File.exist?(pf) ? JSON.parse(File.read(pf)) : nil
rescue StandardError
  nil
end
unless pf_doc
  warn '⛔ NOT DONE — value parity was not run (parity-final.json missing/unreadable).'
  warn '   Run phase6-parity-pbi.rb and assert-phase6-ran.rb before handoff.'
  exit 5
end
status = pf_doc['status'].to_s.upcase
total = pf_doc['charts_total'].to_i
passed = pf_doc['charts_pass'].to_i
failed = pf_doc['charts_fail'].to_i
unless status == 'PASS' && total.positive? && passed == total && failed.zero?
  warn "⛔ NOT DONE — value parity is #{status.empty? ? 'UNKNOWN' : status}: " \
       "#{passed}/#{total} strict chart matches, #{failed} divergent."
  stale = pf_doc['charts_stale_explained'].to_i
  warn "   #{stale} chart(s) are stale-explained; refresh Power BI and rerun strict parity." if stale.positive?
  exit 5
end

puts '✅ DONE — migrate-powerbi.rb built a resolution-verified workbook for this run.'
puts "   workbook     : #{sj['workbookId']}"
puts "   charts       : #{sj['chartCount']}"
puts "   gates        : #{sj['gates']} (columns resolve + freshness match)"
puts "   value parity : CONFIRMED — #{passed}/#{total} strict matches (parity-final.json)"
puts "   stamped      : #{sj['generatedAt']}"
exit 0
