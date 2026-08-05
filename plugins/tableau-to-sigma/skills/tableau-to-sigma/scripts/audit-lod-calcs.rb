#!/usr/bin/env ruby
# frozen_string_literal: true
# audit-lod-calcs.rb — the post-convert "refuse to guess" audit for Tableau
# LOD calcs (#423). Companion to scripts/lib/lod_audit.rb (classification) and
# assert-phase6-ran.rb gate 17 (exit 24), which refuses GREEN while any ledger
# entry is unresolved.
#
# WHY: {FIXED/INCLUDE/EXCLUDE} has no row-level Sigma equivalent. When the
# documented synthesis (grouped helper element / grouped Custom SQL /
# FIXED-relationship surfacing — refs/phase-3-datamodel.md) does not fire, the
# calc's caption can collide with a look-alike RAW column downstream (the
# emitted measure silently reads an unrelated physical column) or the calc
# vanishes from the build entirely. Field failure: 5 of 12
# {FIXED company: COUNTD(...)} measures aliased to unrelated raw flag columns,
# 7 dropped — zero errors anywhere. This audit makes both classes LOUD.
#
# For every source calc containing an LOD block it verifies the emitted
# dm-spec/wb-spec carries a translation that is (a) LOD-synth output or a
# formula built strictly from the LOD's own reference set, or (b) an explicit
# manual-residues.json entry. Anything else lands in <workdir>/lod-audit.json:
#   suspect-alias    — emitted formula references a base column NOT in the LOD
#                      expression's own reference set (fuzzy-alias, wrong numbers)
#   silently-dropped — no translation, no residue declaration
#
# Usage:
#   ruby scripts/audit-lod-calcs.rb --workdir <WORK>
#     [--calc-fields PATH]      # default <WORK>/calc-fields.json
#     [--twb PATH]              # census fallback when no calc-fields.json
#                               #   (default <WORK>/workbook-content.twb)
#     [--dm-spec PATH]          # default <WORK>/dm-spec.json
#     [--wb-spec PATH]          # default <WORK>/wb-spec.resolved.json,
#                               #   else <WORK>/wb-spec.json
#     [--manual-residues PATH]  # default <WORK>/manual-residues.json
#     [--out PATH]              # default <WORK>/lod-audit.json
#   ruby scripts/audit-lod-calcs.rb --workdir <WORK> --resolve <INDEX> \
#     --how <manual|waived> --reason "<evidence>"
#
# Re-derivation preserves recorded resolutions (matched on calc + formula).
# Sanctioned resolutions (mirrors probe-join-keys.rb):
#   manual — you authored the Sigma translation by hand (name the DM element /
#            column in the reason) or recorded it in manual-residues.json
#            (in which case just re-run the audit: it re-classifies);
#   waived — operator escalation: a named human accepted the missing/wrong
#            measure; the reason must say who and why.
#
# Exit codes: 0 = every entry resolved (or ledger empty); 1 = bad invocation;
#             2 = unresolved suspect-alias / silently-dropped entries remain
#                 (FATAL block printed; gate 17 will refuse GREEN, exit 24).

require 'json'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'lod_audit'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR')         { |v| opts[:workdir] = v }
  p.on('--calc-fields PATH')    { |v| opts[:calc_fields] = v }
  p.on('--twb PATH')            { |v| opts[:twb] = v }
  p.on('--dm-spec PATH')        { |v| opts[:dm_spec] = v }
  p.on('--wb-spec PATH')        { |v| opts[:wb_spec] = v }
  p.on('--manual-residues PATH') { |v| opts[:residues] = v }
  p.on('--out PATH')            { |v| opts[:out] = v }
  p.on('--resolve INDEX', Integer) { |v| opts[:resolve] = v }
  p.on('--how HOW', 'manual|waived') { |v| opts[:how] = v }
  p.on('--reason R')            { |v| opts[:reason] = v }
end.parse!

abort 'usage: audit-lod-calcs.rb --workdir <WORK> [--resolve N --how <manual|waived> --reason R]' unless opts[:workdir]
work = opts[:workdir]
out_path = opts[:out] || File.join(work, 'lod-audit.json')

read_json = lambda do |path|
  return nil unless path && File.exist?(path)
  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue JSON::ParserError => e
  warn "WARN: #{path} unparseable (#{e.message[0, 80]}) — treated as absent"
  nil
end

now_utc = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

if opts[:resolve]
  # ---- record a resolution on an unresolved entry ------------------------
  abort '--resolve requires --how <manual|waived>' unless LodAudit::RESOLUTION_HOWS.include?(opts[:how].to_s)
  abort '--resolve requires a non-empty --reason (the evidence recorded in the ledger)' if opts[:reason].to_s.strip.empty?
  doc = read_json.call(out_path)
  abort "FATAL: #{out_path} not found — run the audit first (no --resolve on a ledger that does not exist)" unless doc
  entries = doc.is_a?(Hash) ? (doc['entries'] || []) : doc
  e = entries[opts[:resolve]]
  abort "FATAL: no ledger entry at index #{opts[:resolve]} (#{entries.size} entr(y/ies))" unless e.is_a?(Hash)
  unless LodAudit::UNRESOLVED_CLASSES.include?(e['class'].to_s)
    abort "FATAL: entry #{opts[:resolve]} has class #{e['class'].inspect} — only suspect-alias/silently-dropped entries take a resolution"
  end
  e['resolution'] = { 'how' => opts[:how], 'reason' => opts[:reason].strip, 'recorded_at' => now_utc }
  if doc.is_a?(Hash)
    doc['entries'] = entries
    File.write(out_path, JSON.pretty_generate(doc))
  else
    File.write(out_path, JSON.pretty_generate(entries))
  end
  puts "entry #{opts[:resolve]} (#{e['class']}: #{e['calc'].inspect}) resolved: #{opts[:how]} — #{opts[:reason].strip}"
else
  # ---- derive (or re-derive) the ledger ----------------------------------
  cf_path = opts[:calc_fields] || File.join(work, 'calc-fields.json')
  cf = read_json.call(cf_path)
  calcs = if cf
            LodAudit.lod_calcs(cf)
          else
            twb = opts[:twb] || File.join(work, 'workbook-content.twb')
            if File.exist?(twb)
              warn "no #{File.basename(cf_path)} — deriving the LOD census from #{File.basename(twb)}"
              LodAudit.lod_calcs_from_twb(File.read(twb, encoding: 'UTF-8'))
            else
              abort "FATAL: neither #{cf_path} nor a .twb (--twb) to census LOD calcs from — " \
                    'run extract-calc-fields.rb first'
            end
          end

  wb_default = File.exist?(File.join(work, 'wb-spec.resolved.json')) ? 'wb-spec.resolved.json' : 'wb-spec.json'
  dm  = read_json.call(opts[:dm_spec] || File.join(work, 'dm-spec.json'))
  wb  = read_json.call(opts[:wb_spec] || File.join(work, wb_default))
  mr  = read_json.call(opts[:residues] || File.join(work, 'manual-residues.json'))
  prior = read_json.call(out_path)

  entries = LodAudit.derive(calcs, dm_spec: dm, wb_spec: wb, manual_residues: mr, prior: prior)
  LodAudit.write(out_path, entries)
  entries.each_with_index do |e, i|
    tag = LodAudit.resolved?(e) ? 'ok    ' : 'BLOCK '
    puts "  #{tag} ##{i} [#{e['class']}] #{e['calc'].inspect} (#{e['lod_kind']})"
  end
end

# ---- summary + FATAL block (both modes) -----------------------------------
doc = read_json.call(out_path) || {}
entries = doc.is_a?(Hash) ? (doc['entries'] || []) : doc
blocking = entries.each_with_index.reject { |e, _i| LodAudit.resolved?(e) }

blocking.each do |e, i|
  warn ''
  warn '==================== LOD TRANSLATION FATAL ===================='
  warn "entry ##{i} (#{e['class']}): #{e['calc'].inspect} — {#{e['lod_kind']} ...} calc"
  warn "  formula: #{e['formula'].to_s.gsub(/\s+/, ' ')[0, 160]}"
  if e['class'] == 'suspect-alias'
    warn "  emitted as #{e.dig('evidence', 'column').inspect} on #{e.dig('evidence', 'element').inspect}" \
         " (#{e.dig('evidence', 'spec')}): #{e.dig('evidence', 'formula')}"
    # Two suspect-alias shapes of the same silent-alias failure: a ref OUTSIDE
    # the LOD's reference set, or a non-aggregating passthrough of a column that
    # is inside it but appears ONLY in the LOD's FILTER CONDITION (#452).
    refs = Array(e['suspect_refs'])
    ref_set_n = Array(e['reference_set']).map { |r| LodAudit.norm(r) }
    if refs.any? { |r| ref_set_n.include?(LodAudit.norm(r)) }
      warn "  reads #{refs.join(', ')} — a column named only in the LOD expression's FILTER CONDITION," \
           " not its aggregated output (#{Array(e['reference_set']).join(', ')}). The numbers are silently WRONG."
    else
      warn "  reads #{refs.join(', ')} — NOT in the LOD expression's own reference set" \
           " (#{Array(e['reference_set']).join(', ')}). The numbers are silently WRONG."
    end
  else
    warn '  no emitted dm-spec/wb-spec translation and no manual-residues.json entry — the calc'
    warn '  was DROPPED with no signal; every tile that plotted it is missing or mis-built.'
  end
  warn '  The translator must not guess. Sanctioned resolutions:'
  warn '    (a) BUILD the documented LOD translation (grouped helper element / grouped Custom SQL'
  warn '        + relationship — refs/phase-3-datamodel.md, refs/window-functions.md), or declare it'
  warn '        in manual-residues.json (gate 15 then polices the build), then RE-RUN this audit;'
  warn '    (b) hand-authored already? record it:'
  warn "          ruby scripts/audit-lod-calcs.rb --workdir <W> --resolve #{i} --how manual --reason \"<DM element/column>\""
  warn '    (c) OPERATOR ESCALATION: a named human accepts the missing/wrong measure:'
  warn "          ruby scripts/audit-lod-calcs.rb --workdir <W> --resolve #{i} --how waived --reason \"<operator>: <why>\""
  warn '==============================================================='
end

if blocking.any?
  warn "audit-lod-calcs: #{blocking.size} unresolved LOD entr(y/ies) — the final gate (exit 24) will refuse GREEN."
  exit 2
end
res_n = entries.count { |e| e['resolution'].is_a?(Hash) }
puts "audit-lod-calcs: #{entries.size} LOD calc(s) — " \
     "#{entries.count { |e| e['class'] == 'lod-synth' }} synth, " \
     "#{entries.count { |e| e['class'] == 'manual-residue' }} manual-residue, " \
     "#{entries.count { |e| e['class'] == 'reference-derived' }} reference-derived" \
     "#{res_n.positive? ? ", #{res_n} resolved-by-hand" : ''}. Ledger: #{out_path}"
exit 0
