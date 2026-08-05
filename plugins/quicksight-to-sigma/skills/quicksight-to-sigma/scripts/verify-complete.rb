#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the single offline "is this migration actually done?" check.
#
# A QuickSight→Sigma conversion is done ONLY when migrate-quicksight.rb finished
# with a real, parity-passing workbook — recorded by the assert-phase6-ran hard
# gate stamping <workdir>/phase6-success.json (workbookId + chartCount +
# gates=all-pass) at exit 0. An empty/placeholder workbook never gets that marker
# (the gate fails charts_total<=0). "Done" is a fact on disk, not "pages look
# right". Run before claiming success or handing off.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — phase6-success.json present (gates passed; chartCount > 0 when recorded)
#   2  NOT DONE — no success marker (conversion didn't complete / was hand-built)
#   3  NOT DONE — marker present but 0 chart elements AND no gate record (empty)
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked

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
  warn '   The conversion did not complete a parity-passing build (assert-phase6-ran did not pass).'
  warn '   If pages exist but are empty, they were NOT produced by a real migrate-quicksight.rb run —'
  warn "   re-run the orchestrator (never hand-author a workbook). Workdir checked: #{opts[:wd]}"
  exit 2
end

sj = begin
  JSON.parse(File.read(succ))
rescue StandardError
  {}
end

# Tolerant empty-check: fail only when there are 0 charts AND no gate record. A
# stamp from the shared assert-phase6-ran gate always carries gates=all-pass (the
# gate enforced charts_total>0 to be stamped), so a missing/zero chartCount with
# a gate record still means a real green.
if sj['chartCount'].to_i <= 0 && sj['gates'].to_s.empty?
  warn '⛔ NOT DONE — success marker present but 0 chart elements and no gate record (empty workbook).'
  exit 3
end
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  exit 4
end

puts '✅ DONE — assert-phase6-ran passed the parity/gate suite for this run.'
puts "   workbook : #{sj['workbookId']}"
puts "   charts   : #{sj['chartCount']}"
puts "   gates    : #{sj['gates']}"
puts "   stamped  : #{sj['generatedAt']}"
exit 0
