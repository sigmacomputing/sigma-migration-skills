#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the single offline "is this migration actually done?" check.
#
# A Qlik→Sigma conversion is done ONLY when migrate-qlik.rb finished with a
# real, parity-passing workbook — which it records by stamping
# <workdir>/phase6-success.json (workbookId + chartCount + parity-pass) at exit 0.
# An EMPTY / placeholder workbook (pages but no elements — the classic failure
# where a blocked agent hand-builds a shell) never gets that marker, because the
# orchestrator refuses to green a 0-element build. So "done" is a fact on disk,
# not "the pages look right". Run this before claiming success or handing off.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — phase6-success.json present with chartCount > 0 (parity passed)
#   2  NOT DONE — no success marker (conversion didn't complete / was hand-built)
#   3  NOT DONE — marker present but 0 chart elements (empty workbook)
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
  warn '   The conversion did not complete a parity-passing build. If pages exist but are empty,'
  warn '   they were NOT produced by a real migrate-qlik.rb run — re-run the orchestrator'
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

puts '✅ DONE — migrate-qlik.rb built a parity-passing workbook for this run.'
puts "   workbook : #{sj['workbookId']}"
puts "   charts   : #{sj['chartCount']}"
puts "   gates    : #{sj['gates']}"
puts "   stamped  : #{sj['generatedAt']}"
exit 0
