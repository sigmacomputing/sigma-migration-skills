#!/usr/bin/env ruby
# frozen_string_literal: true
#
# build-punchlist.rb — W2.2 CLI: render <WORK>/PUNCHLIST.md + punchlist.json
# from the SHIPPED degradation-ledger.json (schema frozen; consumed as-is —
# see lib/factory_punchlist.rb). Run automatically at every --finalize
# terminal by migrate-tableau.rb; safe to run standalone on any workdir.
#
#   ruby scripts/build-punchlist.rb --workdir /tmp/<name>
#
# Exit codes:
#   0  rendered (including the clean case: GREEN + empty list)
#   2  INVERSION / corrupt ledger — a non-GREEN verdict with zero items, or a
#      ledger whose counts claim entries it does not present. The punch list
#      REFUSES to understate; fix the ledger (re-run the gate) instead.
#   1  usage / unexpected error

require 'optparse'
require_relative 'lib/cli_encoding'
require_relative 'lib/factory_punchlist'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:dir] = v }
end.parse!
abort 'missing --workdir' unless opts[:dir] && Dir.exist?(opts[:dir])

begin
  built = FactoryPunchlist.write(opts[:dir])
  puts "punch list: #{built['verdict']} — #{built['items'].size} item(s) " \
       "(#{built['counts'].map { |k, v| "#{v} #{k}" }.join(', ')}) → #{File.join(opts[:dir], 'PUNCHLIST.md')}"
  puts "  source: #{built['source']}"
  built['items'].first(10).each { |i| puts "  - [#{i['class']}] #{i['item']}" }
  puts "  … #{built['items'].size - 10} more (see PUNCHLIST.md)" if built['items'].size > 10
rescue ArgumentError => e
  warn "FATAL: #{e.message}"
  warn '       (a punch list must never understate the ledger — re-derive it: re-run the finalize gate)'
  exit 2
end
