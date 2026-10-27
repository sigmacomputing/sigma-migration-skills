#!/usr/bin/env ruby
# frozen_string_literal: true
#
# emit-pivot-collapse-program.rb — OPTIONAL post-publish step for Tableau drill
# hierarchies shown on a crosstab. Tableau shows such a pivot collapsed to the
# hierarchy's first level with a + per row; Sigma's pivot can do the same, but
# the collapsed state is NOT part of the workbook spec (REST), only of the
# Sigma MCP Code Mode SDK (`PivotTable.add_pivot_row` + `collapse_rows`,
# live-verified 2026-10-27). build-charts-from-signals.rb already put every
# lower level on the pivot as an off-shelf column and listed the pivot in
# <workdir>/auto-interactions.json (kind 'pivot-collapse'); this script turns
# those entries into ONE Code Mode program for the agent to run through the
# Sigma MCP `build_workbook` tool (target: existing workbook).
#
# Run it only after the LAST REST spec write (layout, repairs, finalize): any
# later PUT /v2/workbooks/{id}/spec expands the pivot again, so re-run it after
# one. Without the Sigma MCP, skip it — the post-publish guide keeps the manual
# step.
#
# Usage:
#   ruby scripts/emit-pivot-collapse-program.rb --workdir <workdir> [--workbook-id <id>] [--json]
# Prints the program (or, with --json, {"workbookId", "program", "pivots"}).
# Exit 0 with a note and no program when there is nothing to collapse.

require 'json'
require 'optparse'

def pivot_collapse_entries(sidecar)
  return [] unless sidecar && File.exist?(sidecar)
  data = JSON.parse(File.read(sidecar, encoding: 'utf-8'))
  list = data.is_a?(Hash) ? (data['entries'] || data['interactions'] || []) : data
  Array(list).select do |e|
    e.is_a?(Hash) && e['kind'] == 'pivot-collapse' && e['element_id'] &&
      Array(e['levels']).size >= 2 && Array(e['levels']).all? { |l| l['column_id'] }
  end
rescue JSON::ParserError
  []
end

# JSON string/array literal with non-ASCII escaped (\uXXXX) — byte-identical to the
# Python twin's json.dumps default, so the two emitters print the same program.
def jlit(value)
  JSON.generate(value, ascii_only: true)
end

def program_for(entries)
  lines = ['from sigma.pivotTable import PivotTable']
  entries.each do |e|
    ids = e['levels'].map { |l| l['column_id'] }
    lines << "pt = sigma.workbook.get_element(#{jlit(e['element_id'])})"
    lines << 'if isinstance(pt, PivotTable):'
    lines << "    levels = [pt.get_column(c) for c in #{jlit(ids)}]"
    lines << '    on_rows = [r.name() for r in pt.list_pivot_rows()]'
    lines << '    for col in levels[1:]:'
    lines << '        if col.name() not in on_rows:'
    lines << '            pt.add_pivot_row(col)'
    lines << '    pt.collapse_rows(levels[0])'
    lines << "    print(#{jlit("collapsed #{e['element_id']} at #{e['levels'].first['name']}")})"
    lines << 'else:'
    lines << "    print(#{jlit("MISSING pivot #{e['element_id']}")})"
  end
  lines.join("\n") + "\n"
end

def workbook_id_from(workdir)
  return nil if workdir.nil? || workdir.to_s.empty?
  path = File.join(workdir.to_s, 'migrate-state.json')
  return nil unless File.exist?(path)
  JSON.parse(File.read(path, encoding: 'utf-8'))['workbook_id']
rescue JSON::ParserError
  nil
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |o|
    o.on('--workdir DIR') { |v| opts[:workdir] = v }
    o.on('--sidecar PATH', 'default: <workdir>/auto-interactions.json') { |v| opts[:sidecar] = v }
    o.on('--workbook-id ID') { |v| opts[:workbook_id] = v }
    o.on('--json') { opts[:json] = true }
  end.parse!
  sidecar = opts[:sidecar] || (opts[:workdir] && File.join(opts[:workdir], 'auto-interactions.json'))
  entries = pivot_collapse_entries(sidecar)
  if entries.empty?
    warn "no pivot-collapse entries in #{sidecar || '(no sidecar)'} — nothing to do"
    exit 0
  end
  wb = opts[:workbook_id] || workbook_id_from(opts[:workdir])
  program = program_for(entries)
  if opts[:json]
    puts JSON.pretty_generate({ 'workbookId' => wb, 'program' => program,
                                'pivots' => entries.map { |e| e.slice('worksheet', 'element_id', 'caption') } },
                              ascii_only: true)
  else
    warn "run with the Sigma MCP build_workbook tool, target {type: existing, workbookId: #{wb || '<workbook id>'}}"
    puts program
  end
end
