#!/usr/bin/env ruby
# frozen_string_literal: true

# recapture-source-views.rb — prove (or rule out) source drift for the tiles
# that failed parity, strictly (lib/source_drift.rb).
#
#   ruby scripts/recapture-source-views.rb --workdir <WORK> [--chart NAME ...]
#
# Re-exports each diverged tile's Tableau view CSV FRESH (maxAge=1, bypassing
# Tableau's view-data cache) and byte-compares it with the Phase 1 capture:
#   * unchanged → the divergence is REAL; nothing is swapped (exit 1).
#   * changed   → the source moved after the capture: the fresh CSV replaces
#                 views/<id>.csv (old one archived under views/captures/<ts>/)
#                 and the exact re-plan / re-collect / verify commands print;
#                 parity then re-runs STRICTLY against the fresh capture (exit 0).
# Default charts: parity-final.json fail_names. Needs Tableau REST credentials
# (TABLEAU_* env / ~/.sigma-migration/env, as for discovery). Writes
# <WORK>/source-recapture.json either way.

require 'json'
require 'optparse'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'source_drift'

opts = { charts: [] }
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:dir] = v }
  p.on('--chart NAME', 'a parity chart name (repeatable; default: parity-final.json fail_names)') { |v| opts[:charts] << v }
end.parse!
abort('usage: recapture-source-views.rb --workdir DIR [--chart NAME ...]') unless opts[:dir]

charts = opts[:charts]
if charts.empty?
  pf = (JSON.parse(File.read(File.join(opts[:dir], 'parity-final.json'))) rescue {})
  charts = Array(pf['fail_names'])
end
abort('no failed parity charts to recapture (parity-final.json fail_names is empty)') if charts.empty?

require 'tableau_rest'
res = SourceDrift.recapture!(opts[:dir], charts: charts, fetch: ->(vid) { Tableau.view_data_filtered(vid) })

res['unchanged'].each { |r| puts "UNCHANGED  #{r['chart']} (#{r['view']}) — the fresh Tableau export equals the capture: the divergence is REAL" }
res['unavailable'].each { |r| puts "SKIPPED    #{r['chart']} (#{r['view']}) — #{r['reason']}" }
res['moved'].each { |r| puts "MOVED      #{r['chart']} (#{r['view']}) — fresh capture differs; old CSV archived at #{r['archived']}" }
if res['moved'].any?
  w = opts[:dir]
  wb = (JSON.parse(File.read(File.join(w, 'migrate-state.json')))['workbook_id'] rescue nil) || '<WORKBOOK_ID>'
  puts
  puts "The SOURCE moved after the Phase 1 capture (#{res['moved'].size} view(s)). Parity stays strict — re-run it against the fresh capture:"
  puts "  ruby scripts/phase6-parity.rb --tableau #{w} --workbook-id #{wb} --regen-plan"
  puts "  ruby scripts/collect-parity-actuals.rb --plan #{w}/parity-plan.json --workbook-id #{wb} " \
       "--workbook-spec #{w}/wb-readback.json --out #{w}/parity-actuals.json"
  puts "  ruby scripts/migrate-tableau.rb --out #{w} --finalize"
  if Array(res['stale_anchors']).any?
    puts "Phase 1d anchors transcribed from a moved view are STALE (#{res['stale_anchors'].join(', ')}): re-read their values " \
         'from the fresh views/<id>.csv into source-anchors.json before --finalize.'
  end
  exit 0
end
exit 1
