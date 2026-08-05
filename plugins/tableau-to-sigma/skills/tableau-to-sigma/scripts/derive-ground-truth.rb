#!/usr/bin/env ruby
# frozen_string_literal: true
#
# derive-ground-truth.rb — PR-5 part A driver: derive per-tile GROUND-TRUTH
# warehouse SQL (or an honest classification) from the .twb signals, writing
# the COVERAGE LEDGER <workdir>/ground-truth-plan.json.
#
# INDEPENDENCE: inputs are the SOURCE-side artifacts only — parity-plan.json
# (the tile list), dashboard-layout.json + *-meta.json (parse-twb-layout
# output), the raw .twb (join/table specs), calc-fields.json (extracted calc
# formulas). NOTHING is read from the built wb-spec and nothing is imported
# from build-charts-from-signals.rb — see scripts/lib/ground_truth_sql.rb.
#
# Every parity-plan chart gets EXACTLY ONE ledger entry classified
# warehouse-sql | vds | anchor-only | unverifiable(reason). The classification
# IS the coverage ledger; scripts/run-ground-truth.rb executes the
# warehouse-sql entries; PR-6 (comparison + gate) consumes both artifacts —
# this script wires NO gate.
#
# Usage:
#   ruby scripts/derive-ground-truth.rb --workdir <WORK> \
#     [--plan PATH]         # default <WORK>/parity-plan.json
#     [--layout PATH]       # default <WORK>/dashboard-layout.json
#     [--meta PATH]         # default <layout basename>-meta.json
#     [--twb PATH]          # default <WORK>/workbook-content.twb
#     [--calc-fields PATH]  # default <WORK>/calc-fields.json (optional input)
#     [--db DB --schema S]  # complete published-VC table labels (join_plan rule)
#     [--out PATH]          # default <WORK>/ground-truth-plan.json
#
# Exit codes: 0 = ledger written (all classifications are honest outcomes,
#             including unverifiable); 2 = usage / missing required inputs.

require 'json'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'ground_truth_sql'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR')     { |v| opts[:dir] = v }
  p.on('--plan PATH')       { |v| opts[:plan] = v }
  p.on('--layout PATH')     { |v| opts[:layout] = v }
  p.on('--meta PATH')       { |v| opts[:meta] = v }
  p.on('--twb PATH')        { |v| opts[:twb] = v }
  p.on('--calc-fields PATH') { |v| opts[:calc_fields] = v }
  p.on('--db DB')           { |v| opts[:db] = v }
  p.on('--schema SCHEMA')   { |v| opts[:schema] = v }
  p.on('--out PATH')        { |v| opts[:out] = v }
end.parse!
unless opts[:dir] || (opts[:plan] && opts[:layout] && opts[:twb])
  warn 'usage: derive-ground-truth.rb --workdir <WORK> [--plan P] [--layout P] [--twb P] [--calc-fields P] [--db D --schema S] [--out P]'
  exit 2
end

dir         = opts[:dir]
plan_path   = opts[:plan]   || File.join(dir, 'parity-plan.json')
layout_path = opts[:layout] || File.join(dir, 'dashboard-layout.json')
meta_path   = opts[:meta]   || layout_path.sub(/\.json\z/, '-meta.json')
twb_path    = opts[:twb]    || File.join(dir, 'workbook-content.twb')
cf_path     = opts[:calc_fields] || (dir && File.join(dir, 'calc-fields.json'))
out_path    = opts[:out]    || File.join(dir || File.dirname(plan_path), 'ground-truth-plan.json')

read_json = lambda do |path, required|
  unless path && File.exist?(path)
    if required
      warn "FATAL: required input missing: #{path}"
      exit 2
    end
    return nil
  end
  begin
    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "FATAL: #{path} is malformed JSON: #{e.message.lines.first.to_s.strip[0, 120]}"
    exit 2
  end
end

plan = read_json.call(plan_path, true)
charts = plan.is_a?(Hash) ? Array(plan['charts']) : Array(plan)
layout = read_json.call(layout_path, true)
meta = read_json.call(meta_path, false) || {}
calc_fields = read_json.call(cf_path, false)
# join-plan.json (lib/join_plan.rb ledger), when present: a tile whose
# datasource carries a join not proven "unique" must NOT be classified vds —
# VDS reads relationship-culled (un-fanned) data and would false-green a
# dropped/fanned join (Twin-B e2e 2026-07-19). Optional input: absent ledger
# (old workdirs) → no demotion.
jp_path = dir && File.join(dir, 'join-plan.json')
jp = read_json.call(jp_path, false)
join_ledger = jp.is_a?(Hash) ? jp['entries'] : jp
unless File.exist?(twb_path)
  warn "FATAL: required input missing: #{twb_path} (the raw .twb is the join/table source of truth)"
  exit 2
end
twb_xml = File.read(twb_path, encoding: 'UTF-8')

doc = GroundTruthSql.derive(charts, layout, meta, twb_xml, calc_fields,
                            db: opts[:db], schema: opts[:schema], join_ledger: join_ledger)
doc['generated_at'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
doc['inputs'] = { 'plan' => plan_path, 'layout' => layout_path, 'meta' => meta_path,
                  'twb' => twb_path, 'calc_fields' => calc_fields ? cf_path : nil,
                  'join_plan' => join_ledger ? jp_path : nil }
doc['independence_note'] =
  'Derived from .twb signals only (zones + datasource joins/filters + extracted calc formulas); ' \
  'never from the built wb-spec. Calc-formula dependencies are the documented common-mode ' \
  'residue — recorded per tile in provenance.calc_dependencies.'
doc['consumer'] = 'scripts/run-ground-truth.rb (execution) → PR-6 comparison gate (numeric_parity)'
File.write(out_path, JSON.pretty_generate(doc))

doc['entries'].each do |e|
  tag = case e['classification']
        when 'warehouse-sql' then 'SQL     '
        when 'vds'           then 'VDS     '
        when 'anchor-only'   then 'ANCHOR  '
        else 'UNVERIF '
        end
  detail = e['classification'] == 'warehouse-sql' ? "#{Array(e['columns']).size} column(s)" : e['reason'].to_s[0, 110]
  puts "  #{tag} #{e['chart'].to_s.inspect} — #{detail}"
end
s = doc['summary']
puts "derive-ground-truth: #{s['tiles']} tile(s) — warehouse-sql #{s['warehouse_sql']}, " \
     "vds #{s['vds']}, anchor-only #{s['anchor_only']}, unverifiable #{s['unverifiable']} → #{out_path}"
warn "[WARN] coverage incomplete: #{s['tiles']} ledger entr(y/ies) for #{charts.size} plan chart(s)" unless s['coverage_complete']
exit 0
