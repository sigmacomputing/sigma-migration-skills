#!/usr/bin/env ruby
# frozen_string_literal: true
# verify-kpi-comparison-e2e.rb — LIVE proof (needs creds) that the comparative
# KPI shape (comparisonColumn + comparison:{display:"delta"}) is spec-authorable
# and that bound numbers survive a round-trip. Gate for the kpi_card emitter.
require 'json'
require_relative '../lib/sigma_rest'
require_relative '../lib/export_pool'
require_relative '../lib/code_rep'

conn = ENV.fetch('SIGMA_TEST_CONNECTION_ID')
tbl_id, kpi_id = 'tbl-kpiproof', 'kpi-proof'
# Single-row synthetic source: two known numeric columns (ground truth = literals).
sql = 'SELECT 100 AS current_rev, 60 AS prior_rev'

# POST /v2/workbooks/spec requires name/folderId plus a complete document
# (schemaVersion, metadata-only pages, flat elements, and layout; see
# reference/workflows/crud.md). folderId + schemaVersion are NOT part of the
# comparative-KPI shape under test — fetch them live rather than hardcode, per
# this repo's own rule that schemaVersion must come from a reference GET.
who = Sigma.request(:get, '/v2/whoami')
uid = who['userId'] || who['memberId'] || who['id']
folder_id = Sigma.request(:get, "/v2/members/#{uid}")['homeFolderId']
ref_wbs = Sigma.request(:get, '/v2/workbooks?limit=1')
ref_id = ref_wbs['entries']&.first && ref_wbs['entries'].first['workbookId']
schema_version = if ref_id
                   Sigma::CodeRep.document(
                     Sigma.request(:get, "/v2/workbooks/#{ref_id}/spec", accept: 'application/json')
                   )['schemaVersion']
                 end
schema_version ||= 1

elements = [
  { 'id' => tbl_id, 'kind' => 'table', 'name' => 'KPI Proof Source',
    'source' => { 'kind' => 'sql', 'connectionId' => conn, 'statement' => sql },
    # Custom-SQL source columns use the FIXED '[Custom SQL/ALIAS]' formula
    # prefix (not the element name, not bare) — see sigma-formula-rules.
    'columns' => [
      { 'id' => 'current_rev', 'name' => 'Current Rev', 'formula' => '[Custom SQL/current_rev]' },
      { 'id' => 'prior_rev', 'name' => 'Prior Rev', 'formula' => '[Custom SQL/prior_rev]' }
    ] },
  { 'id' => kpi_id, 'kind' => 'kpi-chart',
    'name' => { 'text' => 'Revenue', 'color' => '#0B3D2E' },
    'source' => { 'kind' => 'table', 'elementId' => tbl_id },
    'columns' => [
      { 'id' => 'current_rev', 'name' => 'Current Rev', 'formula' => '[KPI Proof Source/Current Rev]' },
      { 'id' => 'prior_rev', 'name' => 'Prior Rev', 'formula' => '[KPI Proof Source/Prior Rev]' }
    ],
    'value' => { 'columnId' => 'current_rev' },
    'comparisonColumn' => { 'columnId' => 'prior_rev' },
    'comparison' => { 'display' => 'delta', 'colorGood' => '#1a7f37', 'colorBad' => '#cf222e' } }
]
doc = {
  'schemaVersion' => schema_version,
  'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
  'elements' => elements,
  'layout' => '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">' \
              "<Element elementId=\"#{tbl_id}\" gridColumn=\"1 / 13\" gridRow=\"1 / 13\"/>" \
              "<Element elementId=\"#{kpi_id}\" gridColumn=\"13 / 25\" gridRow=\"1 / 13\"/>" \
              '</Page>'
}
spec = Sigma::CodeRep.wrap(doc, extra: { 'name' => 'KPI comparison E2E proof',
                                         'folderId' => folder_id })

resp = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec), accept: 'application/yaml')
raw = resp.is_a?(String) ? resp : resp.to_s
# POST /v2/workbooks/spec returns YAML, not JSON — scrape workbookId out of the text.
wb = raw[/workbookId:\s*([A-Za-z0-9_-]+)/, 1]
abort "NO-GO: no workbookId in response (comparison shape may be rejected):\n#{raw}" unless wb
puts "posted workbook #{wb}"

# Export the SOURCE TABLE (kpi sub-elements 404 on export); assert the bound numbers.
qid = ExportPool.start_json_export(wb, tbl_id, nil)
status, body = ExportPool.poll_json_download(qid, ExportPool::Deadline.new(60))
abort "NO-GO: export #{status}" unless status == :ok
rows = ExportPool.parse_json_rows(body)
# Export keys by column DISPLAY NAME, and Sigma/Snowflake casing/spacing is not
# guaranteed (e.g. "Current Rev" vs "CURRENT_REV" vs "current_rev") — match by
# normalized (lowercased, non-alnum-stripped) key rather than hardcoding a form.
def find_val(row, normalized_base)
  return nil unless row
  key = row.keys.find { |k| k.to_s.downcase.gsub(/[^a-z0-9]/, '') == normalized_base }
  key && row[key]
end
cur = find_val(rows.first, 'currentrev')
pri = find_val(rows.first, 'priorrev')
ok = cur.to_f == 100.0 && pri.to_f == 60.0
puts "current_rev=#{cur} prior_rev=#{pri}  (expected 100 / 60)"
abort 'NO-GO: bound values did not survive round-trip' unless ok

# Re-GET the spec: confirm the comparisonColumn block is NOT stripped/nulled on
# readback. A loose substring check on the whole response (`include?('comparisonColumn')`)
# would false-positive on a key that survives but is emptied/nulled — parse the
# JSON, find the actual kpi-chart element by id, and assert its comparisonColumn
# still points at prior_rev.
back = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
back = JSON.parse(back) if back.is_a?(String) # defensive: accept:'application/json' already parses, but don't assume
abort "NO-GO: readback spec was not a Hash (got #{back.class}): #{back.inspect}" unless back.is_a?(Hash)
back_doc = Sigma::CodeRep.document(back)
kpi_el = Sigma::CodeRep.workbook_elements(back_doc).find { |e| e['id'] == kpi_id }
abort "NO-GO: kpi-chart element '#{kpi_id}' not found on readback (dropped entirely):\n#{JSON.generate(back)}" unless kpi_el

cc = kpi_el['comparisonColumn']
abort "NO-GO: comparisonColumn stripped/nulled on readback (matches the old kpis.md claim). kpi element:\n#{JSON.generate(kpi_el)}" if cc.nil? || (cc.is_a?(Hash) && cc.empty?)
abort "NO-GO: comparisonColumn is not a Hash on readback: #{cc.inspect}" unless cc.is_a?(Hash)
abort "NO-GO: comparisonColumn.columnId mismatch on readback — expected 'prior_rev', got #{cc['columnId'].inspect}. kpi element:\n#{JSON.generate(kpi_el)}" unless cc['columnId'] == 'prior_rev'

puts "GO: comparisonColumn survives readback. Workbook: #{Sigma.base_url}  id=#{wb}"
