#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-master-detail-e2e.rb — LIVE GO/NO-GO proof of "master-detail"
# interactivity (WS3 composition Task 4 — the gate for Task 5's interaction
# emission). Creds-gated: needs a live Sigma org + a warehouse connection, so
# it is NOT part of the offline CI corpus (same class as
# verify-plugin-gauge-e2e.rb, which this script mirrors structurally).
#
# THE DOMAIN QUESTION. "Click a master chart to filter a detail" is largely a
# UI-only construct in Sigma (see reference_sigma_cross_element_filter_spec):
# the click-to-set-a-control-value ACTION has no spec node anywhere. What IS
# spec-authorable is the other half of that construct — a **control** bound
# to the category dimension, with the **detail element filtered by that
# control** (`filters[].source.elementId` on the control, targeting a
# table-kind element — a control filter targeting a viz/chart element 400s,
# see feedback_sigma_control_filter_target_must_be_table). This script proves
# THAT authorable form end-to-end against a live org, then proves a control's
# value can be driven programmatically (the export API's `parameters` map —
# the same channel sigma-export-png.py's `--param` flag and
# probe-controls.rb/verify-interaction.rb already rely on) and that doing so
# actually changes the DETAIL element's exported rows to match the selected
# category. That is the hard, visual-independent signal.
#
# Workbook under test (one page):
#   master-src   (table, kind:sql)      — demo region/category/revenue/
#                                          orders/margin data, unfiltered.
#   master-chart (bar-chart)            — category on the master-src data,
#                                          for REALISM only (not gated).
#   ctrl-category (control, list)       — value list from master-src.category;
#                                          filters[] targets detail-tbl.category.
#   detail-tbl   (table)                — sourced from master-src; the control
#                                          filters THIS element, not master-src
#                                          or master-chart, so the master stays
#                                          unfiltered (a real master surface)
#                                          while the detail responds.
#
# Custom-SQL self-reference formulas ($[Custom SQL/<alias>]) have an
# undocumented, org-observed casing/prefix ambiguity (see
# verify-plugin-gauge-e2e.rb's identical candidate-retry pattern for the same
# reason) — this script retries a small set of candidate prefixes and treats
# only a DATA-VERIFIED read (the detail export actually contains the expected
# category strings) as proof a candidate is correct; a clean POST/PUT 200 is
# NOT proof (formulas.md: a wrong element-name prefix saves 200 and only
# fails at render/query time).
#
# Usage:  ruby shared/scripts/verify-master-detail-e2e.rb
# Env:    SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or
#         ~/.sigma-migration/env — sigma_rest.rb self-bootstraps);
#         SIGMA_TEST_CONNECTION_ID (Snowflake demo connection; defaults to
#         the shared demo test connection).
# Exit:   0 = GO (control-driven master-detail is spec-authorable AND the
#         detail's exported rows actually change to match the selected
#         category). 1 = NO-GO — raw evidence printed above the verdict,
#         never a faked green.

require 'json'
require 'net/http'
require 'uri'
require 'time'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'
require 'export_pool'

RUN_TAG       = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
CONNECTION_ID = ENV.fetch('SIGMA_TEST_CONNECTION_ID', '362d859b-f432-4657-8e58-efc8535aa354')

PAGE_ID          = 'pg-1'
MASTER_SRC_ID    = 'master-src'
MASTER_CHART_ID  = 'master-chart'
CONTROL_EL_ID    = 'ctrl-category'
CONTROL_ID       = 'CategoryFilter' # formula/parameters handle, distinct from CONTROL_EL_ID
DETAIL_ID        = 'detail-tbl'

MASTER_SRC_NAME = 'Regional Category Sales'

# Generic demo data — region/category/revenue/orders/margin, the same shape
# used elsewhere in this workstream. No customer/personal/company names.
DEMO_SQL = <<~SQL.strip
  SELECT 'North' AS region, 'Furniture' AS category, 12000 AS revenue, 120 AS orders, 0.32 AS margin
  UNION ALL SELECT 'South', 'Furniture', 9000, 90, 0.30
  UNION ALL SELECT 'North', 'Technology', 25000, 80, 0.45
  UNION ALL SELECT 'South', 'Technology', 21000, 75, 0.42
  UNION ALL SELECT 'North', 'Office Supplies', 5000, 300, 0.20
  UNION ALL SELECT 'South', 'Office Supplies', 4200, 260, 0.19
SQL

ALIASES = %w[region category revenue orders margin].freeze
DISPLAY = { 'region' => 'Region', 'category' => 'Category', 'revenue' => 'Revenue',
            'orders' => 'Orders', 'margin' => 'Margin' }.freeze
EXPECTED_CATEGORIES = %w[Furniture Technology].freeze # the two values --param is flipped across

def log(msg)
  $stderr.puts("[verify-master-detail-e2e] #{msg}")
end

# ---------------------------------------------------------------------------
# Small helpers duplicated from verify-plugin-gauge-e2e.rb (same self-
# contained-script convention — this is a standalone creds-gated proof, not a
# shared lib).
# ---------------------------------------------------------------------------

def home_folder_id
  me = Sigma.request(:get, '/v2/whoami')
  uid = me && me['userId']
  raise 'could not resolve userId from /v2/whoami' unless uid
  mem = Sigma.request(:get, "/v2/members/#{uid}")
  home = mem && mem['homeFolderId']
  raise 'could not resolve homeFolderId' unless home
  home
end

def reference_schema_version
  wbs = Sigma.request(:get, '/v2/workbooks?limit=10')
  entries = (wbs && (wbs['entries'] || wbs['workbooks'])) || []
  entries.each do |w|
    wid = w['workbookId'] || w['id']
    next unless wid
    spec = (Sigma.request(:get, "/v2/workbooks/#{wid}/spec", accept: 'application/json') rescue nil)
    return spec['schemaVersion'] if spec.is_a?(Hash) && spec['schemaVersion']
  end
  raise 'could not discover schemaVersion from any existing workbook'
end

# POST/PUT /v2/workbooks/spec: response is documented as YAML. Never rely on
# Sigma.request's accept:'application/json' auto-parse here — request a
# non-JSON accept so the raw string always comes back, then self-parse (JSON
# first in case the org actually returns JSON, else scrape `workbookId:` out
# of the YAML text).
def post_or_put_workbook_spec(method, path, spec_hash)
  raw = Sigma.request(method, path, body: JSON.generate(spec_hash),
                                     content_type: 'application/json', accept: 'application/yaml')
  parsed = (JSON.parse(raw) rescue nil)
  return parsed if parsed.is_a?(Hash) && parsed['workbookId']
  m = raw.to_s.match(/^\s*workbookId:\s*"?'?([\w-]+)"?'?\s*$/)
  raise "no workbookId in #{method.upcase} response: #{raw.to_s[0, 500]}" unless m
  { 'workbookId' => m[1], 'raw' => raw }
end

# ---------------------------------------------------------------------------
# Spec construction.
# ---------------------------------------------------------------------------

# master-src's own self-reference formulas are the one ambiguous part (custom
# SQL alias casing/prefix) — everything downstream references master-src by
# its NAME + each column's DISPLAY name (formulas.md: "another workbook
# element: SourceName = that element's `name` field"), which we control
# directly and is NOT ambiguous.
def master_formula_candidates
  [
    { label: 'Custom SQL, Title Case',      fn: ->(a) { "[Custom SQL/#{DISPLAY[a]}]" } },
    { label: 'Custom SQL, UPPER-SNAKE',      fn: ->(a) { "[Custom SQL/#{a.upcase}]" } },
    { label: 'Custom SQL, exact alias (lower)', fn: ->(a) { "[Custom SQL/#{a}]" } },
    { label: 'bare, no prefix (lower)',      fn: ->(a) { "[#{a}]" } },
    { label: 'bare, no prefix (UPPER)',      fn: ->(a) { "[#{a.upcase}]" } },
  ]
end

def build_spec(home, schema_version, master_formula_fn)
  master_cols = ALIASES.map do |a|
    { 'id' => "col-#{a}", 'name' => DISPLAY[a], 'formula' => master_formula_fn.call(a) }
  end

  detail_cols = ALIASES.map do |a|
    { 'id' => "dt-#{a}", 'name' => DISPLAY[a], 'formula' => "[#{MASTER_SRC_NAME}/#{DISPLAY[a]}]" }
  end

  {
    'name' => "WS3 master-detail interactivity — E2E proof (#{RUN_TAG})",
    'folderId' => home,
    'schemaVersion' => schema_version,
    'description' => 'Live proof: control-driven master/detail filter is spec-authorable. Throwaway test artifact.',
    'pages' => [
      {
        'id' => PAGE_ID,
        'name' => 'WS3 Master-Detail E2E',
        'elements' => [
          {
            'id' => MASTER_SRC_ID, 'kind' => 'table', 'name' => MASTER_SRC_NAME,
            'source' => { 'kind' => 'sql', 'connectionId' => CONNECTION_ID, 'statement' => DEMO_SQL },
            'columns' => master_cols,
          },
          {
            'id' => MASTER_CHART_ID, 'kind' => 'bar-chart', 'name' => 'Revenue by Category (master)',
            'source' => { 'kind' => 'table', 'elementId' => MASTER_SRC_ID },
            'columns' => [
              { 'id' => 'mc-cat', 'name' => 'Category', 'formula' => "[#{MASTER_SRC_NAME}/Category]" },
              { 'id' => 'mc-rev', 'name' => 'Revenue', 'formula' => "Sum([#{MASTER_SRC_NAME}/Revenue])" },
            ],
            'xAxis' => { 'columnId' => 'mc-cat' },
            'yAxis' => { 'columnIds' => ['mc-rev'] },
            'stacking' => 'none',
          },
          {
            'id' => CONTROL_EL_ID, 'kind' => 'control', 'controlId' => CONTROL_ID,
            'name' => 'Category', 'controlType' => 'list',
            'mode' => 'include', 'selectionMode' => 'single', 'values' => [],
            'source' => {
              'kind' => 'source',
              'source' => { 'kind' => 'table', 'elementId' => MASTER_SRC_ID },
              'columnId' => 'col-category',
            },
            'filters' => [
              { 'source' => { 'kind' => 'table', 'elementId' => DETAIL_ID }, 'columnId' => 'dt-category' },
            ],
          },
          {
            'id' => DETAIL_ID, 'kind' => 'table', 'name' => 'Category Detail (filtered by control)',
            'source' => { 'kind' => 'table', 'elementId' => MASTER_SRC_ID },
            'columns' => detail_cols,
          },
        ],
      },
    ],
  }
end

# ---------------------------------------------------------------------------
# Export helpers — same "POST export -> poll -> download" flow as
# verify-plugin-gauge-e2e.rb's export_and_check, but able to pass a
# `parameters` map (the proven control-value-for-render channel: see
# sigma-export-png.py's --param and probe-controls.rb/verify-interaction.rb's
# `body['parameters'] = { controlId => value }`).
# ---------------------------------------------------------------------------

def start_json_export_with_params(wb, element_id, params)
  body = { 'elementId' => element_id, 'format' => { 'type' => 'json' } }
  body['parameters'] = params if params && !params.empty?
  r = Sigma.request(:post, "/v2/workbooks/#{wb}/export", body: JSON.generate(body))
  r && r['queryId']
end

def export_rows(wb, element_id, params, deadline_s: 60)
  qid = start_json_export_with_params(wb, element_id, params)
  return { ok: false, reason: 'export POST did not return a queryId' } unless qid
  deadline = ExportPool::Deadline.new(deadline_s)
  status, body = ExportPool.poll_json_download(qid, deadline)
  return { ok: false, reason: "poll status=#{status}", status: status } unless status == :ok
  rows = ExportPool.parse_json_rows(body)
  { ok: true, rows: rows }
end

def category_of(row)
  key = row.keys.find { |k| k.to_s.strip.casecmp('category').zero? }
  key && row[key].to_s
end

def rows_sig(rows)
  rows.map { |r| r.sort.to_h.to_s }.sort
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

verdict = { go: false }

begin
  home = home_folder_id
  schema_version = reference_schema_version
  log "home folder=#{home} schemaVersion=#{schema_version}"

  wb = nil
  resolved = nil
  baseline = nil
  tried = []

  master_formula_candidates.each_with_index do |cand, i|
    spec = build_spec(home, schema_version, cand[:fn])
    method = wb.nil? ? :post : :put
    path = wb.nil? ? '/v2/workbooks/spec' : "/v2/workbooks/#{wb}/spec"
    begin
      resp = post_or_put_workbook_spec(method, path, spec)
    rescue StandardError => e
      tried << { candidate: cand[:label], error: e.message[0, 400] }
      log "#{method.upcase} attempt #{i + 1} (#{cand[:label]}) raised: #{e.message[0, 300]}"
      next
    end
    wb ||= resp['workbookId']
    unless wb
      tried << { candidate: cand[:label], error: "no workbookId in response: #{resp.inspect[0, 300]}" }
      next
    end
    log "workbook #{wb} — attempt #{i + 1} candidate=#{cand[:label]}"

    result = (export_rows(wb, DETAIL_ID, nil) rescue { ok: false, reason: $!.message })
    unless result[:ok]
      tried << { candidate: cand[:label], result: result }
      log "attempt #{i + 1} (#{cand[:label]}): export failed — #{result[:reason]}"
      next
    end
    cats = result[:rows].map { |r| category_of(r) }.compact.reject(&:empty?).uniq
    matched = (cats & (EXPECTED_CATEGORIES + ['Office Supplies'])).size
    if result[:rows].empty? || matched < 2
      tried << { candidate: cand[:label], result: result.merge(distinct_categories: cats) }
      log "attempt #{i + 1} (#{cand[:label]}): resolved but data wrong — rows=#{result[:rows].size} categories=#{cats.inspect} (need >=2 expected categories present)"
      next
    end

    baseline = result
    resolved = { candidate: cand[:label], distinct_categories: cats }
    tried << { candidate: cand[:label], result: 'DATA-VERIFIED', distinct_categories: cats }
    log "attempt #{i + 1} (#{cand[:label]}) DATA-VERIFIED: baseline detail rows=#{result[:rows].size} categories=#{cats.inspect}"
    break
  end

  if resolved.nil?
    verdict = { go: false,
                blocker: 'master-src formula never resolved to real category data for any candidate prefix — ' \
                         'cannot even read the UNFILTERED detail element, so the control-filter test is moot',
                workbook_id: wb, tried: tried }
    log 'NO-GO: master-src / detail-tbl data never resolved (see attempts above).'
  else
    # --- the hard gate: flip the control via export parameters, twice -------
    a_val, b_val = EXPECTED_CATEGORIES # 'Furniture', 'Technology'
    flip_a = (export_rows(wb, DETAIL_ID, { CONTROL_ID => a_val }) rescue { ok: false, reason: $!.message })
    flip_b = (export_rows(wb, DETAIL_ID, { CONTROL_ID => b_val }) rescue { ok: false, reason: $!.message })

    if !flip_a[:ok] || !flip_b[:ok]
      verdict = { go: false,
                  blocker: 'export with --param (parameters map) failed for at least one flip value',
                  workbook_id: wb, resolved: resolved,
                  flip_a: flip_a[:ok] ? { rows: flip_a[:rows] } : flip_a,
                  flip_b: flip_b[:ok] ? { rows: flip_b[:rows] } : flip_b }
      log "NO-GO: #{verdict[:blocker]} — flip_a.ok=#{flip_a[:ok]} flip_b.ok=#{flip_b[:ok]}"
    else
      cats_a = flip_a[:rows].map { |r| category_of(r) }
      cats_b = flip_b[:rows].map { |r| category_of(r) }
      a_nonempty = !flip_a[:rows].empty?
      b_nonempty = !flip_b[:rows].empty?
      a_pure = a_nonempty && cats_a.all? { |c| c == a_val }
      b_pure = b_nonempty && cats_b.all? { |c| c == b_val }
      rows_differ = rows_sig(flip_a[:rows]) != rows_sig(flip_b[:rows])

      ok = a_pure && b_pure && rows_differ

      verdict = {
        go: ok,
        workbook_id: wb,
        workbook_url: "#{ENV['SIGMA_BASE_URL']}/workbook/#{wb}",
        resolved_formula_candidate: resolved[:candidate],
        control_id: CONTROL_ID, control_element_id: CONTROL_EL_ID, detail_element_id: DETAIL_ID,
        baseline_detail_rows: baseline[:rows],
        baseline_distinct_categories: resolved[:distinct_categories],
        checks: {
          "param=#{a_val} rows non-empty" => a_nonempty,
          "param=#{a_val} rows ALL category==#{a_val}" => a_pure,
          "param=#{b_val} rows non-empty" => b_nonempty,
          "param=#{b_val} rows ALL category==#{b_val}" => b_pure,
          'flip_a and flip_b row sets DIFFER' => rows_differ,
        },
        evidence: {
          "detail rows with --param #{CONTROL_ID}=#{a_val}" => flip_a[:rows],
          "detail rows with --param #{CONTROL_ID}=#{b_val}" => flip_b[:rows],
        },
      }
      if ok
        log "GO: detail filtered correctly — #{a_val}: #{flip_a[:rows].size} rows, #{b_val}: #{flip_b[:rows].size} rows, sets differ=#{rows_differ}"
      else
        log "NO-GO: control-driven filter did not produce a pure/differing detail — #{verdict[:checks].inspect}"
        verdict[:blocker] = 'control value changed via --param but detail rows did not purely/correctly filter ' \
                             '(wired but inert, or only a UI-only form works)'
      end
    end
  end
rescue StandardError => e
  verdict = { go: false, blocker: "unhandled error: #{e.class}: #{e.message}", backtrace: e.backtrace&.first(10) }
  log "NO-GO: unhandled error — #{e.class}: #{e.message}"
end

puts
puts '=' * 78
puts verdict[:go] ? 'GO' : 'NO-GO'
puts '=' * 78
puts JSON.pretty_generate(verdict)
exit(verdict[:go] ? 0 : 1)
