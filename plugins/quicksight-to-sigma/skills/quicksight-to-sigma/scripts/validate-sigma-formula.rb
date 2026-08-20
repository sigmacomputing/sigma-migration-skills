#!/usr/bin/env ruby
# Validate that a candidate Sigma formula resolves cleanly against a given
# Sigma data-model context. The primitive used by the gap-scout subagent to
# decide whether a proposed translation actually works.
#
# Usage:
#   ruby scripts/validate-sigma-formula.rb \
#     --formula 'MovingAvg(Sum([Master/Sales]), -10, 10)' \
#     --data-model-id <dm-id> \
#     --master-element-id <element-id>  \
#     [--folder-id <folder-id>] \
#     [--chart-kind bar-chart|line-chart|table]
#
# What it does:
#   1. Builds a tiny Sigma workbook spec with:
#      - Data page: a master table pulling from the supplied DM element
#      - Test page: a single chart that uses the candidate formula as a column
#   2. POSTs to /v2/workbooks/spec
#   3. Reads /v2/workbooks/{id}/elements/{el}/columns and checks for
#      type.type == "error"
#   4. Emits a JSON result to stdout (machine-parseable):
#        { "status": "ok" | "error",
#          "workbook_id": "...",
#          "error_columns": [{ "label": "...", "err": {...} }],
#          "spec_used": {...} }
#
# Env: SIGMA_BASE_URL + SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (or a live
# SIGMA_API_TOKEN) — auth + retry now live in lib/sigma_rest (E7.1 port off
# raw Net::HTTP so the SIGMA_STUB test seam applies here too).
#
# Cleanup contract (PLAN-v4 E7.1): the workbook id is REGISTERED in the local
# probe registry (<workdir>/probe-artifacts.jsonl via --workdir, else
# ~/.quicksight-to-sigma/probe-artifacts.jsonl) immediately after the POST
# response parses — BEFORE the first readback — and the DELETE is armed via
# at_exit at the same point, so a crash anywhere between POST and verdict can
# no longer orphan the scout workbook (the old shape deleted only on the
# success path). --keep-workbook still keeps it (and records nothing as
# cleaned); a process kill leaves the id outstanding in the registry for a
# crash-recovery sweep (shared registry format — see lib/probe_registry.rb).

require 'json'
require 'optparse'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'probe_registry'
require 'code_rep'

opts = {
  chart_kind: 'table',
  folder_id: nil
}
OptionParser.new do |p|
  p.on('--formula F')             { |v| opts[:formula] = v }
  p.on('--data-model-id ID')      { |v| opts[:dm_id] = v }
  p.on('--master-element-id ID')  { |v| opts[:el_id] = v }
  p.on('--folder-id ID')          { |v| opts[:folder_id] = v }
  p.on('--chart-kind K')          { |v| opts[:chart_kind] = v }
  p.on('--label L')               { |v| opts[:label] = v }
  p.on('--workdir DIR', 'conversion workdir — homes the probe-artifact registry') { |v| opts[:workdir] = v }
  p.on('--keep-workbook')         { opts[:keep] = true }
end.parse!
%i[formula dm_id el_id].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

# --- Build the test spec ---------------------------------------------------
formula = opts[:formula]
label   = opts[:label] || 'scout-test-col'

# Master needs at least one column to be valid — use a passthrough on whatever
# the DM element exposes. We don't know its specific columns up front; the
# scout caller should already know that [Master/X] refs in the formula resolve
# against the DM's columns. To validate, we POST and read back the chart's
# column types.

# Auto-discover the DM element's columns so test formulas that reference real
# data columns (e.g., `[Master/Gross Revenue]`) resolve cleanly. Without this,
# the test master only exposes a synthetic PassThrough column and any candidate
# touching real data fails with a misleading "dependency not found" error.
dm_spec = begin
  Sigma.request(:get, "/v2/dataModels/#{opts[:dm_id]}/spec")
rescue StandardError
  {}
end
dm_spec = {} unless dm_spec.is_a?(Hash)
dm_element   = (dm_spec['pages'] || []).flat_map { |p| p['elements'] || [] }
                                       .find { |e| e['id'] == opts[:el_id] }
dm_element_name = dm_element && dm_element['name']
dm_cols = (dm_element && dm_element['columns']) || []

# Build passthrough master columns from the DM element. Prefer the element-
# level `name` (which respects any renames the DM author did) over parsing
# the underlying-table name out of `[SOURCE/Col]` formulas — those two can
# differ when the DM renames a column.
master_columns = []
dm_cols.each do |c|
  display_name = c['name']
  if (display_name.nil? || display_name.empty?) && (m = c['formula'].to_s.match(/^\[[^\/]+\/([^\]]+)\]$/))
    display_name = m[1]
  end
  next if display_name.nil? || display_name.empty?
  next unless dm_element_name
  slug = display_name.downcase.gsub(/\W+/, '-').sub(/-$/, '')
  master_columns << {
    'id'      => "m-#{slug}",
    'name'    => display_name,
    'formula' => "[#{dm_element_name}/#{display_name}]"
  }
end
master_columns << { 'id' => 'm-passthrough', 'name' => 'PassThrough', 'formula' => 'RowNumber()' } if master_columns.empty?

master_el = {
  'id'              => 'master',
  'kind'            => 'table',
  'name'            => 'Master',
  'source'          => { 'kind' => 'data-model', 'dataModelId' => opts[:dm_id], 'elementId' => opts[:el_id] },
  'columns'         => master_columns,
  'visibleAsSource' => false
}

test_el = {
  'id'   => 'el-scout-test',
  'kind' => opts[:chart_kind],
  'name' => 'Scout test',
  'source' => { 'kind' => 'table', 'elementId' => 'master' },
  'columns' => [
    { 'id' => 'col-scout-test', 'name' => label, 'formula' => formula }
  ]
}

spec = {
  'name'           => "[scout-test] #{label}-#{Time.now.to_i}",
  'schemaVersion'  => 1,
  'pages' => [
    { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master_el] },
    { 'id' => 'page-test', 'name' => 'Test', 'elements' => [test_el] }
  ]
}
spec['folderId'] = opts[:folder_id] if opts[:folder_id]

# --- POST + readback -------------------------------------------------------
parsed = begin
  # Workbook code-rep POSTs require the nested `document` envelope (verified
  # live 2026-08-03/04: a flat body 400s) — wrap the throwaway singleton probe spec.
  post_body = Sigma::CodeRep.wrap(Sigma::CodeRep.document(spec), extra: Sigma::CodeRep.metadata(spec))
  Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(post_body))
rescue StandardError => e
  { 'raw' => e.message }
end

wb_id = parsed.is_a?(Hash) && parsed['workbookId']
unless wb_id
  puts JSON.pretty_generate({
    'status' => 'error',
    'phase'  => 'post',
    'workbook_id' => nil,
    'error'  => parsed,
    'spec_used' => spec
  })
  exit 1
end

# The workbook now exists in the customer org: register it BEFORE the first
# readback and arm the DELETE via at_exit, so ANY exit path from here on —
# readback raise, non-JSON body, later abort — still cleans up (E7.1). The
# state hash keeps the delete idempotent (at_exit fires on the success path
# too, after the explicit cleanup below has already run).
cleanup = { 'done' => false, 'ok' => false }
ProbeRegistry.created(wb_id, name: spec['name'], workdir: opts[:workdir],
                      script: 'validate-sigma-formula.rb')
delete_probe = lambda do |via|
  next if cleanup['done']
  cleanup['done'] = true
  begin
    Sigma.request(:delete, "/v2/files/#{wb_id}")
    cleanup['ok'] = true
    ProbeRegistry.cleaned(wb_id, workdir: opts[:workdir], via: via)
  rescue StandardError => e
    outcome = e.message.lines.first.to_s =~ /\b404\b/ ? '404' : 'failed'
    cleanup['ok'] = true if outcome == '404' # already gone = cleaned
    ProbeRegistry.cleaned(wb_id, workdir: opts[:workdir], via: via, outcome: outcome)
  end
end
at_exit { delete_probe.call('at_exit') unless opts[:keep] }

# Walk both elements; we mostly care about the test element
cols_data = Sigma.request(:get, "/v2/workbooks/#{wb_id}/elements/el-scout-test/columns")
cols_data = JSON.parse(cols_data) if cols_data.is_a?(String) # tolerate a raw body
entries = cols_data['entries'] || []
error_cols = entries.select do |c|
  t = c['type']
  tt = t.is_a?(Hash) ? t['type'] : t
  tt == 'error'
end

status = error_cols.empty? ? 'ok' : 'error'

# Clean up the throwaway test workbook (unless --keep-workbook). The scout only
# needs the column-type verdict; leaving the workbook behind orphans one file per
# attempt in the customer's folder.
delete_probe.call('ensure') unless opts[:keep]
cleaned = cleanup['ok']

puts JSON.pretty_generate({
  'status'        => status,
  'phase'         => 'columns',
  'workbook_id'   => wb_id,
  'workbook_cleaned' => cleaned,
  'error_columns' => error_cols.map { |c| { 'label' => c['label'], 'formula' => c['formula'], 'err' => c['type'] } },
  'all_columns'   => entries.map { |c| { 'label' => c['label'], 'type' => (c['type'].is_a?(Hash) ? c['type']['type'] : c['type']) } },
  'spec_used'     => spec
})

exit(status == 'ok' ? 0 : 2)
