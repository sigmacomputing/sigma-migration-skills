#!/usr/bin/env ruby
# frozen_string_literal: true
# audit-agg-semantics.rb — the post-convert aggregation-semantics lint
# (PLAN-v3 PR-7). Companion to scripts/lib/agg_semantics_lint.rb
# (classification) and assert-phase6-ran.rb gate 19 (exit 26), which refuses
# GREEN while any ledger entry lacks a recorded resolution.
#
# WHY: additive aggregation over a pre-aggregated column compiles clean in
# every existing gate and ships wrong-looking-right numbers. Field root cause
# #3: a KPI printed 103.3% "% entities with value" — a {FIXED day: COUNTD}
# pre-aggregate consumed with SUM() at a coarser grain double-counts every
# entity appearing on more than one day. Three live runs proved nothing flags
# this. Classes (see the lib header): additive-over-preagg / countd-as-sum /
# preagg-ratio. Severity is WARN-WITH-REQUIRED-RESOLUTION: each hit blocks
# until the run records reaggregated | n/a(reason) | faithful-to-source(reason).
#
# Usage:
#   ruby scripts/audit-agg-semantics.rb --workdir <WORK>
#     [--calc-fields PATH]       # default <WORK>/calc-fields.json
#     [--twb PATH]               # census fallback when no calc-fields.json
#                                #   (default <WORK>/workbook-content.twb)
#     [--dm-spec PATH]           # default <WORK>/dm-spec.json
#     [--wb-spec PATH]           # default <WORK>/wb-spec.resolved.json,
#                                #   else <WORK>/wb-spec.json
#     [--landing-manifest PATH]  # default <WORK>/landing-manifest.json
#                                #   (grain check only when entries carry `grain`)
#     [--out PATH]               # default <WORK>/agg-semantics.json
#   ruby scripts/audit-agg-semantics.rb --workdir <WORK> --resolve <INDEX> \
#     --how <reaggregated|n/a|faithful-to-source> --reason "<evidence>"
#
# Re-derivation preserves recorded resolutions (matched on class + context +
# consumer + pre-aggregate + formula). Sanctioned resolutions:
#   reaggregated       — the consumer was rebuilt at the correct grain (name
#                        the element/column in the reason);
#   n/a                — the hit does not apply; say WHY. First-class: never
#                        fabricate metadata to satisfy the lint;
#   faithful-to-source — the source itself mixes grains and the migration
#                        reproduces it faithfully; the reason documents the
#                        hazard for the report.
#
# Exit codes: 0 = every entry resolved (or ledger empty); 1 = bad invocation;
#             2 = entries without a recorded resolution remain (WARN block
#                 printed; gate 19 will refuse GREEN, exit 26).

require 'json'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'agg_semantics_lint'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR')            { |v| opts[:workdir] = v }
  p.on('--calc-fields PATH')       { |v| opts[:calc_fields] = v }
  p.on('--twb PATH')               { |v| opts[:twb] = v }
  p.on('--dm-spec PATH')           { |v| opts[:dm_spec] = v }
  p.on('--wb-spec PATH')           { |v| opts[:wb_spec] = v }
  p.on('--landing-manifest PATH')  { |v| opts[:landing] = v }
  p.on('--out PATH')               { |v| opts[:out] = v }
  p.on('--resolve INDEX', Integer) { |v| opts[:resolve] = v }
  p.on('--how HOW', 'reaggregated|n/a|faithful-to-source') { |v| opts[:how] = v }
  p.on('--reason R')               { |v| opts[:reason] = v }
end.parse!

abort 'usage: audit-agg-semantics.rb --workdir <WORK> [--resolve N --how <reaggregated|n/a|faithful-to-source> --reason R]' unless opts[:workdir]
work = opts[:workdir]
out_path = opts[:out] || File.join(work, 'agg-semantics.json')

read_json = lambda do |path|
  return nil unless path && File.exist?(path)
  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue JSON::ParserError => e
  warn "WARN: #{path} unparseable (#{e.message[0, 80]}) — treated as absent"
  nil
end

now_utc = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

if opts[:resolve]
  # ---- record a resolution on an entry -----------------------------------
  abort '--resolve requires --how <reaggregated|n/a|faithful-to-source>' unless AggSemanticsLint::RESOLUTION_HOWS.include?(opts[:how].to_s)
  abort '--resolve requires a non-empty --reason (the evidence recorded in the ledger)' if opts[:reason].to_s.strip.empty?
  doc = read_json.call(out_path)
  abort "FATAL: #{out_path} not found — run the lint first (no --resolve on a ledger that does not exist)" unless doc
  entries = doc.is_a?(Hash) ? (doc['entries'] || []) : doc
  e = entries[opts[:resolve]]
  abort "FATAL: no ledger entry at index #{opts[:resolve]} (#{entries.size} entr(y/ies))" unless e.is_a?(Hash)
  e['resolution'] = { 'how' => opts[:how], 'reason' => opts[:reason].strip, 'recorded_at' => now_utc }
  if doc.is_a?(Hash)
    doc['entries'] = entries
    File.write(out_path, JSON.pretty_generate(doc))
  else
    File.write(out_path, JSON.pretty_generate(entries))
  end
  puts "entry #{opts[:resolve]} (#{e['class']}: #{e['consumer'].inspect} over #{e['preagg'].inspect}) resolved: #{opts[:how]} — #{opts[:reason].strip}"
else
  # ---- derive (or re-derive) the ledger ----------------------------------
  cf_path = opts[:calc_fields] || File.join(work, 'calc-fields.json')
  cf = read_json.call(cf_path)
  calcs = if cf
            AggSemanticsLint.calc_census(cf)
          else
            twb = opts[:twb] || File.join(work, 'workbook-content.twb')
            if File.exist?(twb)
              warn "no #{File.basename(cf_path)} — deriving the calc census from #{File.basename(twb)}"
              AggSemanticsLint.calc_census_from_twb(File.read(twb, encoding: 'UTF-8'))
            else
              abort "FATAL: neither #{cf_path} nor a .twb (--twb) to census calcs from — " \
                    'run extract-calc-fields.rb first'
            end
          end

  wb_default = File.exist?(File.join(work, 'wb-spec.resolved.json')) ? 'wb-spec.resolved.json' : 'wb-spec.json'
  dm = read_json.call(opts[:dm_spec] || File.join(work, 'dm-spec.json'))
  wb = read_json.call(opts[:wb_spec] || File.join(work, wb_default))
  lm = read_json.call(opts[:landing] || File.join(work, 'landing-manifest.json'))
  prior = read_json.call(out_path)

  entries = AggSemanticsLint.derive(calcs, dm_spec: dm, wb_spec: wb,
                                    landing_manifest: lm, prior: prior)
  AggSemanticsLint.write(out_path, entries)
  entries.each_with_index do |e, i|
    tag = AggSemanticsLint.resolved?(e) ? 'ok    ' : 'BLOCK '
    puts "  #{tag} ##{i} [#{e['class']}] #{e['consumer'].inspect} over #{e['preagg'].inspect} (#{e['context']})"
  end
end

# ---- summary + WARN block (both modes) ------------------------------------
doc = read_json.call(out_path) || {}
entries = doc.is_a?(Hash) ? (doc['entries'] || []) : doc
blocking = entries.each_with_index.reject { |e, _i| AggSemanticsLint.resolved?(e) }

blocking.each do |e, i|
  warn ''
  warn '=============== AGGREGATION SEMANTICS WARN (RESOLUTION REQUIRED) ==============='
  warn "entry ##{i} (#{e['class']}): #{e['consumer'].inspect} consumes #{e['preagg'].inspect} (#{e['context']}#{e['element'] ? ", element #{e['element'].inspect}" : ''})"
  warn "  formula: #{e['formula'].to_s.gsub(/\s+/, ' ')[0, 160]}"
  warn "  #{e['detail']}"
  warn '  This compiles clean and ships wrong-looking-right numbers (the 103.3%-KPI class).'
  warn '  Record ONE resolution (the ledger is the evidence; there is no skip flag):'
  warn "    (a) REBUILD the consumer to aggregate at the correct grain (grouped helper re-aggregation /"
  warn '        Max-at-own-grain / CountDistinct over the base column), then:'
  warn "          ruby scripts/audit-agg-semantics.rb --workdir <W> --resolve #{i} --how reaggregated --reason \"<element/column>\""
  warn '    (b) the hit does NOT apply (e.g. the tile group-by IS the pre-aggregate grain) — never'
  warn '        fabricate metadata to satisfy the lint:'
  warn "          ruby scripts/audit-agg-semantics.rb --workdir <W> --resolve #{i} --how n/a --reason \"<why it does not apply>\""
  warn '    (c) the SOURCE itself mixes grains and the migration reproduces it faithfully — document'
  warn '        the hazard instead of shipping it silently:'
  warn "          ruby scripts/audit-agg-semantics.rb --workdir <W> --resolve #{i} --how faithful-to-source --reason \"<the hazard>\""
  warn '================================================================================'
end

if blocking.any?
  warn "audit-agg-semantics: #{blocking.size} hit(s) without a recorded resolution — the final gate (exit 26) will refuse GREEN."
  exit 2
end
by_how = Hash.new(0)
entries.each { |e| by_how[e.dig('resolution', 'how').to_s] += 1 if e['resolution'].is_a?(Hash) }
puts "audit-agg-semantics: #{entries.size} hit(s) — " \
     "#{by_how['reaggregated']} reaggregated, #{by_how['n/a']} n/a, " \
     "#{by_how['faithful-to-source']} faithful-to-source. Ledger: #{out_path}"
exit 0
