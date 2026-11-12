#!/usr/bin/env ruby
# frozen_string_literal: true

# apply-lod-dim-helpers.rb — build the grouped helper + Lookup for every
# FIXED LOD the workbook spec uses as a DIMENSION (lib/lod_dim_helper.rb),
# then place any element the layout leaves unplaced (helpers → Data page).
# migrate-tableau.rb runs the same pass automatically after the per-page
# master split; this CLI is the offline / re-entry form of it.
#
#   ruby scripts/apply-lod-dim-helpers.rb --workdir <WORK> --spec wb-spec.json [--out PATH]
#
# Reads <WORK>/dashboard-layout-meta.json (parse-twb-layout.rb) for the calc
# formulas. Writes the canonical workbook spec (default: overwrite --spec).
# Exit 0 always on a readable input; prints what it built.

require 'json'
require 'optparse'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'workbook_code'
require 'lod_dim_helper'
require 'layout_merge'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:dir] = v }
  p.on('--spec PATH') { |v| opts[:spec] = v }
  p.on('--out PATH') { |v| opts[:out] = v }
end.parse!
abort('usage: apply-lod-dim-helpers.rb --workdir DIR --spec PATH [--out PATH]') unless opts[:dir] && opts[:spec]

meta = (JSON.parse(File.read(File.join(opts[:dir], 'dashboard-layout-meta.json'), encoding: 'UTF-8')) rescue {})
calcs = (meta['worksheets'] || {}).values.flat_map { |w| Array(w['calculations']) }
spec = WorkbookCode.legacy_view(WorkbookCode.canonicalize(JSON.parse(File.read(opts[:spec], encoding: 'UTF-8'))))
res = LodDimHelper.apply!(spec, LodDimHelper.plans(calcs, meta['columns_by_guid'] || {}))
out = WorkbookCode.canonicalize(spec)
doc = WorkbookCode.document(out)
fill = LayoutMerge.complete_layout(doc['layout'], WorkbookCode.elements(out))
doc['layout'] = fill[:xml] if fill[:xml]
File.write(opts[:out] || opts[:spec], JSON.pretty_generate(out) + "\n")
res[:built].each { |b| puts "built #{b['helper']} for FIXED LOD '#{b['calc']}' → Lookup on #{b['tiles'].join(', ')}" }
fill[:placed].each { |pl| puts "placed #{pl['id']} on #{pl['page']} (#{pl['how']})" }
res[:notes].each { |n| puts "note: #{n}" }
puts 'no FIXED-LOD dimension to build' if res[:built].empty?
