#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate a repaired or hand-authored workbook through the same Phase-6 gate
# as the orchestrator, then run the normal completion check. This does not mint
# a marker itself: assert-phase6-ran.rb remains the only authority that can do
# so after inspecting parity, layout, controls, live columns, and evidence.

require 'json'
require 'optparse'
require 'rbconfig'

split = ARGV.index('--')
gate_args = split ? ARGV.slice!(split + 1, ARGV.length) : []
ARGV.slice!(split) if split

opts = {}
OptionParser.new do |p|
  p.banner = 'usage: ruby scripts/adopt-workbook.rb --workdir DIR --workbook-id ID [-- GATE_ARGS]'
  p.on('--workdir DIR') { |v| opts[:workdir] = File.expand_path(v) }
  p.on('--workbook-id ID') { |v| opts[:workbook_id] = v }
end.parse!

abort 'FATAL: --workdir is required' unless opts[:workdir]
abort 'FATAL: --workbook-id is required' if opts[:workbook_id].to_s.empty?

spec = %w[workbook-spec.json wb-spec.json].map { |name| File.join(opts[:workdir], name) }
                                            .find { |path| File.file?(path) }
abort "FATAL: no workbook-spec.json or wb-spec.json in #{opts[:workdir]}" unless spec

parity = File.join(opts[:workdir], 'parity-final.json')
abort "FATAL: parity-final.json is required before adoption (#{parity})" unless File.file?(parity)
begin
  parsed = JSON.parse(File.read(parity))
  abort 'FATAL: parity-final.json must contain at least one chart' unless parsed['charts_total'].to_i.positive?
rescue JSON::ParserError => e
  abort "FATAL: parity-final.json is invalid JSON: #{e.message}"
end

gate = ENV['PBI_ASSERT_PHASE6'] || File.join(__dir__, 'assert-phase6-ran.rb')
verify = ENV['PBI_VERIFY_COMPLETE'] || File.join(__dir__, 'verify-complete.rb')
cmd = [RbConfig.ruby, gate, '--tableau', opts[:workdir],
       '--workbook-id', opts[:workbook_id], *gate_args]

puts 'Adopting an existing workbook through the standard Phase-6 gate...'
unless system(*cmd)
  warn '⛔ ADOPTION FAILED — Phase-6 evidence did not pass; no completion marker was accepted.'
  exit($? ? $?.exitstatus : 1)
end

exec(RbConfig.ruby, verify, '--workdir', opts[:workdir],
     '--workbook-id', opts[:workbook_id])
