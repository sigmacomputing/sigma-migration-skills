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
# ~/.tableau-to-sigma/probe-artifacts.jsonl) immediately after the POST
# response parses — BEFORE the first readback — and the DELETE is armed via
# at_exit at the same point, so a crash anywhere between POST and verdict can
# no longer orphan the scout workbook (the old shape deleted only on the
# success path). --keep-workbook still keeps it (and records nothing as
# cleaned); a process kill is covered by scripts/sweep-run-artifacts.rb
# reading the registry.
#
# BATCH MODE (W2.14): --batch FILE validates N formulas with ONE probe
# workbook and ONE columns readback — 1 POST + 1 DELETE in the registry
# regardless of N (pattern proven at regression-corpus/tableau/
# formula_coverage: 74 formulas / 1 POST). FILE is a JSON array of
# { "label": ..., "formula": ..., "sql": ..., "sql_columns": [...] } (label,
# sql, sql_columns optional; or wrap as {"entries": [...]}). The batch test
# element is ALWAYS kind 'table': chart kinds need wired axes and a per-kind
# singleton probe (the mandatory-placement rule above), so --batch with a
# --chart-kind refuses loudly instead of vacuously passing N series.
# Output: one JSON doc with per-entry results; exit 0 all-ok / 2 any formula
# error / 3 formulas ok but the SQL ground-truth half incomplete.
#
# SQL ground-truth half (optional): entries carrying "sql" also get their
# statement rows fetched via ExportPool.pooled_sql_probe (FROZEN signature —
# cross-lane contract with lane E; transport only, comparisons stay the
# caller's). SEQUENCING GATE (W2.11): the pooled path is refused — loudly,
# BEFORE anything is created — until the export-pool lib itself carries
# ProbeRegistry integration (registry-in-pool). The gate reads the required
# lib's source, so it auto-opens the moment lane E's W2.11 lands; no flag
# flip, no coordination commit.

require 'json'
require 'optparse'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'probe_registry'

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
  p.on('--batch FILE', 'JSON entries — N formulas, ONE probe workbook, one readback (W2.14)') { |v| opts[:batch] = v }
  p.on('--connection-id ID', 'warehouse connection for the optional per-entry SQL ground-truth half') { |v| opts[:conn_id] = v }
  p.on('--pool N', Integer, 'SQL ground-truth export pool width (default 5)') { |v| opts[:pool] = v }
  p.on('--row-limit N', Integer, 'SQL ground-truth export row cap') { |v| opts[:row_limit] = v }
  p.on('--timeout S', Integer, 'SQL ground-truth wall-clock budget in seconds (default 300)') { |v| opts[:timeout] = v }
end.parse!
if opts[:batch]
  abort('--batch and --formula are mutually exclusive (batch entries carry their own formulas)') if opts[:formula]
  # Chart-kind probes need wired axes and stay SINGLETON (see header): a
  # multi-series batch chart would pass/fail vacuously, not per-formula.
  if opts[:chart_kind] != 'table'
    abort("--batch validates on a 'table' element only — chart-kind '#{opts[:chart_kind]}' probes stay " \
          'singleton (wired-axes mandatory-placement rule); run those without --batch')
  end
  %i[dm_id el_id].each { |k| abort("missing --#{k.to_s.tr('_', '-')}") unless opts[k] }
else
  %i[formula dm_id el_id].each { |k| abort("missing --#{k.to_s.tr('_', '-')}") unless opts[k] }
end

# --- Batch entries + the W2.11 sequencing gate (parse-time, pre-POST) -------
batch_entries = nil
if opts[:batch]
  raw = begin
    JSON.parse(File.read(opts[:batch]))
  rescue StandardError => e
    abort("--batch #{opts[:batch]}: unreadable or invalid JSON (#{e.message.lines.first.to_s.strip})")
  end
  raw = raw['entries'] if raw.is_a?(Hash) && raw['entries'].is_a?(Array)
  abort('--batch: expected a JSON array of {"formula": ...} entries (or {"entries": [...]})') unless raw.is_a?(Array)
  abort('--batch: no entries') if raw.empty?
  batch_entries = raw.each_with_index.map do |e, i|
    abort("--batch entry #{i}: not an object") unless e.is_a?(Hash)
    f = e['formula'].to_s
    abort("--batch entry #{i}: missing formula") if f.strip.empty?
    { 'label' => (e['label'].to_s.strip.empty? ? "batch-#{i}" : e['label'].to_s),
      'formula' => f, 'sql' => e['sql'], 'sql_columns' => e['sql_columns'] }
  end
  # Duplicate labels would ambiguate the columns readback — suffix them.
  seen_labels = Hash.new(0)
  batch_entries.each do |e|
    n = (seen_labels[e['label']] += 1)
    e['label'] = "#{e['label']} (#{n})" if n > 1
  end
  if batch_entries.any? { |e| e['sql'] }
    abort('--batch entries carry "sql" but --connection-id is missing') unless opts[:conn_id]
    # W2.11 sequencing gate: pooled_sql_probe's signature is frozen for this
    # consumer, but the pooled workbook must never be created UNREGISTERED
    # (litter red line). Refuse until the export-pool lib itself integrates
    # ProbeRegistry (lane E's registry-in-pool) — checked against the required
    # lib source so the gate auto-opens when W2.11 lands.
    pool_src = File.expand_path('lib/export_pool.rb', __dir__)
    unless File.exist?(pool_src) && File.read(pool_src, encoding: 'UTF-8').include?('ProbeRegistry')
      abort('--batch SQL ground-truth REFUSED: ExportPool.pooled_sql_probe does not yet register its probe ' \
            "workbook (lane E W2.11 registry-in-pool not landed in #{pool_src}). Validating formulas without " \
            'the SQL half is available now: drop "sql" from the entries. NOTHING was created.')
    end
  end
end

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

# --- BATCH: N formulas, ONE probe workbook, one readback (W2.14) ------------
if batch_entries
  test_el = {
    'id'   => 'el-scout-test',
    'kind' => 'table',
    'name' => 'Scout batch test',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => batch_entries.each_with_index.map do |e, i|
      { 'id' => "col-b#{i}", 'name' => e['label'], 'formula' => e['formula'] }
    end
  }
  spec = {
    'name'          => "[scout-test] batch-#{batch_entries.length}-#{Time.now.to_i}",
    'schemaVersion' => 1,
    'pages' => [
      { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master_el] },
      { 'id' => 'page-test', 'name' => 'Test', 'elements' => [test_el] }
    ]
  }
  spec['folderId'] = opts[:folder_id] if opts[:folder_id]

  parsed = begin
    Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec))
  rescue StandardError => e
    { 'raw' => e.message }
  end
  wb_id = parsed.is_a?(Hash) && parsed['workbookId']
  unless wb_id
    puts JSON.pretty_generate('status' => 'error', 'phase' => 'post', 'mode' => 'batch',
                              'workbook_id' => nil, 'error' => parsed, 'spec_used' => spec)
    exit 1
  end

  # Same E7.1 contract as the singleton path below: register BEFORE the first
  # readback, arm the DELETE via at_exit — ONE workbook, ONE registry created
  # entry, ONE delete for the whole batch, whatever N is.
  cleanup = { 'done' => false, 'ok' => false }
  ProbeRegistry.created(wb_id, name: spec['name'], workdir: opts[:workdir],
                        script: 'validate-sigma-formula.rb --batch')
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

  # PAGINATED (same contract as the singleton path below): a batch of >50
  # formulas overflows Sigma's default 50-entry page, and a truncated readback
  # would misreport every formula past the cut as "column missing from
  # readback". Sigma.list_entries follows nextPage to exhaustion.
  col_entries = Sigma.list_entries("/v2/workbooks/#{wb_id}/elements/el-scout-test/columns")
  by_col_id = {}
  by_label  = {}
  col_entries.each do |c|
    cid = c['columnId'] || c['id']
    by_col_id[cid] ||= c if cid
    by_label[c['label']] ||= c if c['label']
  end

  results = batch_entries.each_with_index.map do |e, i|
    col = by_col_id["col-b#{i}"] || by_label[e['label']]
    if col.nil?
      { 'label' => e['label'], 'formula' => e['formula'], 'status' => 'error',
        'err' => 'column missing from readback' }
    else
      t = col['type']
      tt = t.is_a?(Hash) ? t['type'] : t
      if tt == 'error'
        { 'label' => e['label'], 'formula' => e['formula'], 'status' => 'error', 'err' => t }
      else
        { 'label' => e['label'], 'formula' => e['formula'], 'status' => 'ok', 'type' => tt }
      end
    end
  end

  # Optional SQL ground-truth half (W2.11 gate passed at parse time): FROZEN
  # pooled_sql_probe signature; transport only — rows are attached per entry,
  # comparisons stay the caller's (never-verdict-in-the-pool doctrine).
  sql_incomplete = false
  sql_idx = batch_entries.each_index.select { |i| batch_entries[i]['sql'] }
  unless sql_idx.empty?
    require 'export_pool'
    sql_entries = sql_idx.map do |i|
      { 'sql' => batch_entries[i]['sql'].to_s, 'columns' => Array(batch_entries[i]['sql_columns']) }
    end
    deadline = ExportPool::Deadline.new(opts[:timeout] || 300)
    sql_res = begin
      ExportPool.pooled_sql_probe(opts[:conn_id], sql_entries, deadline,
                                  folder_id: opts[:folder_id], pool: opts[:pool] || 5,
                                  row_limit: opts[:row_limit])
    rescue StandardError => e
      e.message.to_s
    end
    if sql_res.is_a?(Array)
      sql_idx.each_with_index do |bi, si|
        st, rows = sql_res[si]
        results[bi]['sql_status'] = st.to_s
        results[bi]['sql_rows'] = rows if st == :ok
        sql_incomplete = true unless st == :ok
      end
    else # pool POST itself failed — nothing was created on the pool side
      sql_idx.each { |bi| results[bi]['sql_status'] = "pool-post-failed: #{sql_res}" }
      sql_incomplete = true
    end
  end

  formula_errors = results.count { |r| r['status'] == 'error' }
  status = formula_errors.zero? ? 'ok' : 'error'
  delete_probe.call('ensure') unless opts[:keep]
  puts JSON.pretty_generate(
    'status' => status, 'phase' => 'columns', 'mode' => 'batch',
    'workbook_id' => wb_id, 'workbook_cleaned' => cleanup['ok'],
    'counts' => { 'total' => results.length, 'ok' => results.length - formula_errors,
                  'error' => formula_errors },
    'sql_incomplete' => sql_incomplete,
    'results' => results,
    'spec_used' => spec
  )
  exit(status == 'ok' ? (sql_incomplete ? 3 : 0) : 2)
end

test_el = {
  'id'   => 'el-scout-test',
  'kind' => opts[:chart_kind],
  'name' => 'Scout test',
  'source' => { 'kind' => 'table', 'elementId' => 'master' },
  'columns' => [
    { 'id' => 'col-scout-test', 'name' => label, 'formula' => formula }
  ]
}
# CHART kinds require wired axes — a bare columns array 400s with
# "yAxis: Invalid object: undefined" REGARDLESS of the candidate formula, so
# every chart-kind probe used to fail vacuously (field-caught: the one
# placement the window-function docs call mandatory was untestable). Wire a
# minimal x dimension (the first master column) + the candidate on yAxis.
if opts[:chart_kind].to_s.end_with?('-chart')
  x_src = master_columns.first
  test_el['columns'].unshift(
    'id' => 'col-scout-x', 'name' => 'Scout X',
    'formula' => "[Master/#{x_src['name']}]"
  )
  series_type = { 'bar-chart' => 'bar', 'line-chart' => 'line', 'area-chart' => 'area',
                  'scatter-chart' => 'scatter', 'combo-chart' => 'line' }.fetch(opts[:chart_kind], 'bar')
  test_el['xAxis'] = { 'columnId' => 'col-scout-x' }
  test_el['yAxis'] = { 'columnIds' => [{ 'columnId' => 'col-scout-test', 'type' => series_type }] }
end

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
  Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec))
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
# PAGINATED via the fleet helper: this script's single auth path is
# lib/sigma_rest (E7.1 port — Sigma.request already does the POST and the
# cleanup DELETE above), so the columns readback goes through
# Sigma.list_entries — limit=1000, follow nextPage to exhaustion, defensive
# loud stop on a repeated token — instead of a bare first-page GET. Sigma's
# server default page size is 50; unpaginated single-page reads reached END OF
# SUPPORT 2026-06-02, and a truncated readback here misgrades every formula
# past the cut. A non-2xx raises Sigma::Error (same semantics as the other
# Sigma.request calls in this script); the armed at_exit still deletes the
# probe workbook on that path.
entries = Sigma.list_entries("/v2/workbooks/#{wb_id}/elements/el-scout-test/columns")
# The spec POSTed above always carries at least the probe column, so an empty
# readback is a protocol failure (non-JSON/non-Hash body defensively swallowed
# by list_entries, or a server-side truncation) — never a gradable "ok". Raise
# before the ensure-delete so the armed at_exit owns the cleanup on this path.
raise Sigma::Error, 'columns readback returned no entries — refusing to grade' if entries.empty?
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
