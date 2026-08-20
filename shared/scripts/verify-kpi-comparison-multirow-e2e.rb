#!/usr/bin/env ruby
# frozen_string_literal: true
# verify-kpi-comparison-multirow-e2e.rb — MULTI-ROW live proof (needs creds) for
# the FIXED comparative-KPI builder output. The single-row sibling
# (verify-kpi-comparison-e2e.rb) proved the shape is spec-authorable and
# survives readback, but over ONE row it can't tell an aggregated delta from a
# row-level one. This closes that gap: it mirrors what build_kpi_element now
# emits — BOTH the value AND the comparison column are derived, AGGREGATED,
# source-prefixed columns (Sum([<src>/…])) — over MULTI-ROW data, and proves
# Sigma aggregates them (delta = Sum(current) - Sum(prior), not row-level).
#
# Ground truth: VALUES (60,40),(30,15),(50,5) → Sum(cur)=140, Sum(prior)=60.
#
# Three assertions:
#   1. A GROUPED element carrying the SAME Sum([src/…]) aggregate columns the
#      KPI now emits, collapsed to one row → Sigma-computed totals == 140 / 60
#      (aggregation is correct, NOT row-level — the core fix).
#   2. The raw source table, exported and summed in Ruby → 140 / 60 (ground
#      truth cross-check).
#   3. The actual kpi-chart (value = Sum([src/cur]), comparison = the derived
#      Sum([src/prior]) column) survives readback with its comparisonColumn
#      pointing at the DERIVED aggregate column — not a bare row-level id.
require 'json'
require_relative '../lib/sigma_rest'
require_relative '../lib/export_pool'
require_relative '../lib/code_rep'

conn = ENV.fetch('SIGMA_TEST_CONNECTION_ID')
src_id, agg_id, kpi_id = 'tbl-mr-src', 'tbl-mr-agg', 'kpi-mr-proof'
src_name = 'MR KPI Source'

# Multi-row synthetic source: totals are Sum(cur)=140, Sum(prior)=60.
sql = 'SELECT * FROM VALUES (60,40),(30,15),(50,5) AS t(cur, prior)'

# Derived aggregate column ids (KPI value + comparison) — the FIXED builder's
# k-/kc- pair. Named as they'd appear on the emitted kpi-chart.
val_col_id, cmp_col_id = 'k-mr', 'kc-mr'

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
      # Raw multi-row source (Custom SQL → [Custom SQL/ALIAS] formula prefix).
      { 'id' => src_id, 'kind' => 'table', 'name' => src_name,
        'source' => { 'kind' => 'sql', 'connectionId' => conn, 'statement' => sql },
        'columns' => [
          { 'id' => 'cur',   'name' => 'Cur',   'formula' => '[Custom SQL/cur]' },
          { 'id' => 'prior', 'name' => 'Prior', 'formula' => '[Custom SQL/prior]' }
        ] },
      # GROUPED aggregate: the SAME Sum([src/…]) columns the fixed KPI emits,
      # grouped over a constant so Sigma collapses all rows to one total row.
      # This is the KPI's aggregation made exportable (kpi sub-elements 404).
      { 'id' => agg_id, 'kind' => 'table', 'name' => 'MR Agg',
        'source' => { 'kind' => 'table', 'elementId' => src_id },
        'columns' => [
          { 'id' => 'allrows', 'name' => 'All Rows', 'formula' => '1' },
          { 'id' => 'cur_total',   'name' => 'Cur Total',   'formula' => "Sum([#{src_name}/Cur])" },
          { 'id' => 'prior_total', 'name' => 'Prior Total', 'formula' => "Sum([#{src_name}/Prior])" }
        ],
        'groupings' => [
          { 'id' => 'g-all', 'groupBy' => ['allrows'], 'calculations' => %w[cur_total prior_total] }
        ] },
      # The actual comparative kpi-chart — MIRRORS the fixed build_kpi_element
      # output: value AND comparison are BOTH derived Sum([src/…]) columns, and
      # comparisonColumn points at the derived comparison column (kc-), not a
      # bare row-level master id.
      { 'id' => kpi_id, 'kind' => 'kpi-chart',
        'name' => { 'text' => 'Revenue', 'color' => '#0B3D2E' },
        'source' => { 'kind' => 'table', 'elementId' => src_id },
        'columns' => [
          { 'id' => val_col_id, 'name' => 'Cur',   'formula' => "Sum([#{src_name}/Cur])" },
          { 'id' => cmp_col_id, 'name' => 'Prior', 'formula' => "Sum([#{src_name}/Prior])" }
        ],
        'value' => { 'columnId' => val_col_id },
        'comparisonColumn' => { 'columnId' => cmp_col_id },
        'comparison' => { 'display' => 'delta', 'colorGood' => '#1a7f37', 'colorBad' => '#cf222e' } }
]
doc = {
  'schemaVersion' => schema_version,
  'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
  'elements' => elements,
  'layout' => '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">' \
              "<Element elementId=\"#{src_id}\" gridColumn=\"1 / 9\" gridRow=\"1 / 13\"/>" \
              "<Element elementId=\"#{agg_id}\" gridColumn=\"9 / 17\" gridRow=\"1 / 13\"/>" \
              "<Element elementId=\"#{kpi_id}\" gridColumn=\"17 / 25\" gridRow=\"1 / 13\"/>" \
              '</Page>'
}
spec = Sigma::CodeRep.wrap(doc, extra: { 'name' => 'KPI comparison MULTI-ROW E2E proof',
                                         'folderId' => folder_id })

resp = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec), accept: 'application/yaml')
raw = resp.is_a?(String) ? resp : resp.to_s
wb = raw[/workbookId:\s*([A-Za-z0-9_-]+)/, 1]
abort "NO-GO: no workbookId in response (comparison shape may be rejected):\n#{raw}" unless wb
puts "posted workbook #{wb}"

def find_val(row, normalized_base)
  return nil unless row
  key = row.keys.find { |k| k.to_s.downcase.gsub(/[^a-z0-9]/, '') == normalized_base }
  key && row[key]
end

# --- Assertion 1: Sigma-computed aggregate (grouped element) == 140 / 60 ------
qid = ExportPool.start_json_export(wb, agg_id, nil)
status, body = ExportPool.poll_json_download(qid, ExportPool::Deadline.new(60))
abort "NO-GO: agg export #{status}" unless status == :ok
agg_rows = ExportPool.parse_json_rows(body)
abort "NO-GO: grouped aggregate did not collapse to a single total row (got #{agg_rows.length} rows): #{agg_rows.inspect}" unless agg_rows.length == 1
agg_cur = find_val(agg_rows.first, 'curtotal')
agg_pri = find_val(agg_rows.first, 'priortotal')
puts "AGGREGATED (Sigma-computed):  Sum(cur)=#{agg_cur}  Sum(prior)=#{agg_pri}   (expected 140 / 60)"
agg_ok = agg_cur.to_f == 140.0 && agg_pri.to_f == 60.0

# --- Assertion 2: raw source summed in Ruby == 140 / 60 (ground truth) --------
qid2 = ExportPool.start_json_export(wb, src_id, nil)
status2, body2 = ExportPool.poll_json_download(qid2, ExportPool::Deadline.new(60))
abort "NO-GO: source export #{status2}" unless status2 == :ok
src_rows = ExportPool.parse_json_rows(body2)
raw_cur = src_rows.sum { |r| find_val(r, 'cur').to_f }
raw_pri = src_rows.sum { |r| find_val(r, 'prior').to_f }
puts "RAW ROWS (#{src_rows.length} rows, summed in Ruby):  cur=#{raw_cur}  prior=#{raw_pri}   (expected 140 / 60)"
raw_ok = raw_cur == 140.0 && raw_pri == 60.0

# --- Assertion 3: kpi-chart comparisonColumn survives readback, points at the
#     DERIVED aggregate column (kc-), and that column carries a Sum([…]) formula.
back = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
back = JSON.parse(back) if back.is_a?(String)
abort "NO-GO: readback spec was not a Hash (got #{back.class})" unless back.is_a?(Hash)
back_doc = Sigma::CodeRep.document(back)
kpi_el = Sigma::CodeRep.workbook_elements(back_doc).find { |e| e['id'] == kpi_id }
abort "NO-GO: kpi-chart '#{kpi_id}' not found on readback (dropped):\n#{JSON.generate(back)}" unless kpi_el
cc = kpi_el['comparisonColumn']
abort "NO-GO: comparisonColumn stripped/nulled on readback. kpi element:\n#{JSON.generate(kpi_el)}" if cc.nil? || (cc.is_a?(Hash) && cc.empty?)
abort "NO-GO: comparisonColumn.columnId != derived '#{cmp_col_id}' (got #{cc['columnId'].inspect}). kpi element:\n#{JSON.generate(kpi_el)}" unless cc['columnId'] == cmp_col_id
cmp_col_back = (kpi_el['columns'] || []).find { |c| c['id'] == cmp_col_id }
abort "NO-GO: derived comparison column '#{cmp_col_id}' missing from columns[] on readback" unless cmp_col_back
readback_ok = cc['columnId'] == cmp_col_id && cmp_col_back['formula'].to_s =~ /\ASum\(/
puts "READBACK: kpi comparisonColumn.columnId=#{cc['columnId'].inspect} → derived column formula=#{cmp_col_back['formula'].inspect}"

puts
if agg_ok && raw_ok && readback_ok
  puts "GO: multi-row aggregation is CORRECT — delta = Sum(current) 140 - Sum(prior) 60 = 80, aggregated over #{src_rows.length} rows."
  puts "Workbook: #{Sigma.base_url}  id=#{wb}"
  exit 0
else
  puts "NO-GO: agg_ok=#{agg_ok} raw_ok=#{raw_ok} readback_ok=#{readback_ok} — aggregation NOT proven; report DONE_WITH_CONCERNS."
  exit 1
end
