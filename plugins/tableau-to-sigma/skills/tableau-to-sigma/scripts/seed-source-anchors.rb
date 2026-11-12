#!/usr/bin/env ruby
# frozen_string_literal: true

# seed-source-anchors.rb — give every displayed tile a VALUED source anchor
# from its Tableau view CSV, at the source's displayed precision
# (lib/anchor_seed.rb). Before the anchors lock exists it also normalizes
# over-precise agent-written view-csv anchors (0.641016176 → 64.1%).
#
#   ruby scripts/seed-source-anchors.rb --workdir <WORK>
#
# Tiles with no view CSV are listed: those still need a person to transcribe
# a value from the dashboard PNG. Run verify-anchors.rb afterwards (the
# finalize preflight does both automatically).

require 'optparse'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'anchor_seed'

opts = {}
OptionParser.new { |p| p.on('--workdir DIR') { |v| opts[:dir] = v } }.parse!
abort('usage: seed-source-anchors.rb --workdir DIR') unless opts[:dir]
r = AnchorSeed.apply!(opts[:dir])
r[:normalized].each { |n| puts "normalized #{n['id']}: #{n['from']} → #{n['to']} (source display precision)" }
puts "seeded #{r[:seeded].size} valued anchor(s) from view CSVs: #{r[:seeded].join(', ')}" if r[:seeded].any?
puts "NO view CSV (transcribe from the dashboard PNG by hand): #{r[:no_csv].join(', ')}" if r[:no_csv].any?
puts 'every tile already has a valued anchor at display precision' if r.values.all?(&:empty?)
