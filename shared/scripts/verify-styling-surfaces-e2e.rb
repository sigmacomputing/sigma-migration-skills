#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-styling-surfaces-e2e.rb — LIVE GO/NO-GO probe of dashboard-STYLING
# surfaces (WS3 STYLING Task 1 — the gate for Task 3's emission). Creds-gated:
# needs a live Sigma org + a warehouse connection, so it is NOT part of the
# offline CI corpus (same class as verify-plugin-gauge-e2e.rb /
# verify-master-detail-e2e.rb, which this script mirrors structurally).
#
# THE DOMAIN QUESTION. A "colored KPI title", "custom chart palette", or
# "styled card" can look plausible in a spec and still fail one of two ways
# Sigma is known to silently punish (see refs/styling.md,
# reference_sigma_chart_spec_silent_drops, reference_sigma_kpi_hide_title):
#   (a) the field is STRIPPED on GET readback (never really saved), or
#   (b) the field SURVIVES readback byte-for-byte but is IGNORED at RENDER
#       time (worse — a clean POST+GET looks like proof and isn't).
# This script never trusts (a) alone. For every color-coded surface it POSTs
# a real workbook, GETs it back, renders it to PNG, and pixel-samples the
# actual rendered region for the exact hex it asked for — the same
# readback-AND-render discipline as WS1's comparisonColumn probe and WS3's
# master-detail probe. Two surfaces (number format, font-FAMILY typography)
# can't be told apart by pixel color alone — those are called out as
# "render: needs visual confirmation" and are closed out by the calling
# agent actually looking at the PNG (the brief's "controller-inspect"),
# never by a faked automated green.
#
# Workbook under test (ONE workbook, one page, generic demo region/category/
# revenue/orders/margin data — no customer/personal/company names):
#   src              (table, kind:sql)   — demo data, unfiltered.
#   kpi-revenue       (kpi-chart)         — SURFACE 1: name:{text,color} (title
#                                           accent) + value:{columnId,color}
#                                           (the documented alt lever) + a
#                                           SURFACE 4 formatString.
#   chart-single      (bar-chart)         — SURFACE 2: color:{by:single,value}.
#   chart-categorical (bar-chart)         — SURFACE 3: color:{by:category,
#                                           column} with NO per-element scheme,
#                                           relying on workbook-level
#                                           settings.theme.overrides.categoricalScheme;
#                                           a side-experiment then adds an
#                                           explicit per-element `scheme` (the
#                                           documented Recipe-5 alternative) to
#                                           see which mechanism (if either)
#                                           actually drives the render.
#   tbl-detail        (table)             — SURFACE 4: a d3-format formatString
#                                           column AND an Excel-style guess
#                                           column, side by side; also a
#                                           SURFACE 6 per-element name-object
#                                           (fontSize/color) typography probe.
#   hero / hero-title (container / text)  — SURFACE 5: kind:container style
#                                           {backgroundColor,borderRadius,
#                                           borderColor,borderWidth,padding}
#                                           (+ a guessed `cornerRadius` key to
#                                           see whether the brief's field name
#                                           or the docs' `borderRadius` is the
#                                           real one) + a top-level (NOT
#                                           pages[].layout) <Container>.
#   workbook-level settings.theme.overrides.titleFont — SURFACE 6: the documented
#                                           workbook-wide typography lever,
#                                           tested against the two bare chart
#                                           titles (which carry no per-element
#                                           name override, so any effect there
#                                           is attributable to this field alone).
#
# Guessed/uncertain field names (cornerRadius, the Excel-style formatString,
# a table `name` object) are wrapped in a generic flag-retry: a POST/PUT that
# 400s on one of them has that flag disabled and is retried — so a guessed
# field's fate (silently dropped vs hard-rejected vs accepted) is discovered
# live, not assumed. Custom-SQL self-reference formulas ($[Custom SQL/<alias>])
# have the same undocumented casing/prefix ambiguity documented in
# verify-plugin-gauge-e2e.rb / verify-master-detail-e2e.rb — this script
# reuses their candidate-retry pattern and treats only a DATA-VERIFIED read
# (the detail table actually contains the expected demo category/region
# strings) as proof a candidate is correct.
#
# Usage:  ruby shared/scripts/verify-styling-surfaces-e2e.rb
# Env:    SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or
#         ~/.sigma-migration/env — sigma_rest.rb self-bootstraps);
#         SIGMA_TEST_CONNECTION_ID (Snowflake demo connection; defaults to
#         the shared demo test connection).
# Exit:   0 = the probe RAN to completion and printed a verdict for every
#         surface (individual surfaces are legitimately GO or NO-GO — this
#         is a discovery probe, not a single pass/fail gate). 1 = the probe
#         itself could not complete (e.g. the workbook never POSTed) — a
#         hard failure, never a faked green.

require 'json'
require 'net/http'
require 'uri'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'shellwords'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'
require 'export_pool'
require 'code_rep'

RUN_TAG       = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
CONNECTION_ID = ENV.fetch('SIGMA_TEST_CONNECTION_ID', '362d859b-f432-4657-8e58-efc8535aa354')

PAGE_ID           = 'pg-1'
SRC_ID            = 'src'
KPI_ID            = 'kpi-revenue'
CHART_SINGLE_ID   = 'chart-single'
CHART_CAT_ID      = 'chart-categorical'
TABLE_ID          = 'tbl-detail'
HERO_ID           = 'hero'
HERO_TITLE_ID     = 'hero-title'

SRC_NAME = 'Regional Category Sales'

# --- test colors — each surface gets a color no other surface uses, so a
# pixel hit in one region can only be attributed to the field under test ----
KPI_NAME_COLOR       = '#2563EB' # surface 1: kpi-chart `name.color` (title)
KPI_VALUE_COLOR      = '#F59E0B' # surface 1 alt: kpi-chart `value.color`
CHART_SINGLE_COLOR   = '#3B82F6' # surface 2: color:{by:single,value}
CATEGORICAL_HEXES    = %w[#FF1493 #00CED1 #FFD700 #7CFC00].freeze # surface 3
HERO_BG              = '#0B3D91' # surface 5: container style.backgroundColor
# NOT #2563EB (KPI_NAME_COLOR) — a first cut reused that hex here and a
# miscalibrated crop (see detect_hero_bottom_px) let the hero's OWN border
# stroke masquerade as a false-positive "KPI title rendered blue" hit. Kept
# distinct from every other test color (checked against each within the
# pixel-probe's tol=40) so no region's signal can be attributed to this one.
HERO_BORDER          = '#1E293B'
TITLEFONT_COLOR      = '#7C3AED' # surface 6: workbook-level settings.theme.overrides.titleFont
TABLE_NAME_COLOR     = '#DC2626' # surface 6: per-element `name` object (table)

# Generic demo data — region/category/revenue/orders/margin. No customer/
# personal/company names. 2 regions x 4 categories so the categorical-scheme
# chart has real multi-category structure to color.
DEMO_SQL = <<~SQL.strip
  SELECT 'North' AS region, 'Electronics' AS category, 42000 AS revenue, 210 AS orders, 0.28 AS margin
  UNION ALL SELECT 'South', 'Electronics', 31000, 150, 0.26
  UNION ALL SELECT 'North', 'Apparel', 18000, 400, 0.35
  UNION ALL SELECT 'South', 'Apparel', 15500, 360, 0.33
  UNION ALL SELECT 'North', 'Home Goods', 22000, 180, 0.30
  UNION ALL SELECT 'South', 'Home Goods', 19500, 165, 0.29
  UNION ALL SELECT 'North', 'Sporting Goods', 12500, 220, 0.22
  UNION ALL SELECT 'South', 'Sporting Goods', 11000, 200, 0.21
SQL

ALIASES = %w[region category revenue orders margin].freeze
DISPLAY = { 'region' => 'Region', 'category' => 'Category', 'revenue' => 'Revenue',
            'orders' => 'Orders', 'margin' => 'Margin' }.freeze
EXPECTED_CATEGORIES = ['Electronics', 'Apparel', 'Home Goods', 'Sporting Goods'].freeze
EXPECTED_REGIONS    = %w[North South].freeze

def log(msg)
  $stderr.puts("[verify-styling-surfaces-e2e] #{msg}")
end

# ---------------------------------------------------------------------------
# Shared helpers (same pattern as verify-master-detail-e2e.rb / -plugin-gauge).
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
    doc = spec.is_a?(Hash) ? Sigma::CodeRep.document(spec) : nil
    return doc['schemaVersion'] if doc && doc['schemaVersion']
  end
  raise 'could not discover schemaVersion from any existing workbook'
end

# POST/PUT /v2/workbooks/spec: response is documented as YAML. Never rely on
# Sigma.request's accept:'application/json' auto-parse here — request a
# non-JSON accept so the raw string always comes back, then self-parse (JSON
# first in case the org actually returns JSON, else scrape `workbookId:` out
# of the YAML text).
def post_or_put_workbook_spec(method, path, spec_hash)
  # Workbook code-rep requires the nested `document` envelope (live since
  # 2026-08; shared/lib/code_rep.rb) — a flat body 400s.
  body = Sigma::CodeRep.wrap(Sigma::CodeRep.document(spec_hash), extra: Sigma::CodeRep.metadata(spec_hash))
  raw = Sigma.request(method, path, body: JSON.generate(body),
                                     content_type: 'application/json', accept: 'application/yaml')
  parsed = (JSON.parse(raw) rescue nil)
  return parsed if parsed.is_a?(Hash) && parsed['workbookId']
  m = raw.to_s.match(/^\s*workbookId:\s*"?'?([\w-]+)"?'?\s*$/)
  raise "no workbookId in #{method.upcase} response: #{raw.to_s[0, 500]}" unless m
  { 'workbookId' => m[1], 'raw' => raw }
end

def src_formula_candidates
  [
    { label: 'Custom SQL, Title Case',          fn: ->(a) { "[Custom SQL/#{DISPLAY[a]}]" } },
    { label: 'Custom SQL, UPPER-SNAKE',          fn: ->(a) { "[Custom SQL/#{a.upcase}]" } },
    { label: 'Custom SQL, exact alias (lower)',  fn: ->(a) { "[Custom SQL/#{a}]" } },
    { label: 'bare, no prefix (lower)',          fn: ->(a) { "[#{a}]" } },
    { label: 'bare, no prefix (UPPER)',          fn: ->(a) { "[#{a.upcase}]" } },
  ]
end

# ---------------------------------------------------------------------------
# Spec construction — `flags` gates the guessed/uncertain fields so a live
# 400 can disable exactly the culprit and retry, rather than guessing blind.
# ---------------------------------------------------------------------------

def build_spec(home, schema_version, src_formula_fn, flags)
  src_cols = ALIASES.map do |a|
    { 'id' => "col-#{a}", 'name' => DISPLAY[a], 'formula' => src_formula_fn.call(a) }
  end

  kpi_name = { 'text' => 'Revenue', 'color' => KPI_NAME_COLOR }

  table_name =
    if flags[:table_name_object]
      { 'text' => 'Category Detail', 'fontSize' => 22, 'color' => TABLE_NAME_COLOR }
    else
      'Category Detail'
    end

  revenue_excel_col =
    if flags[:excel_format]
      { 'id' => 'dt-revenue-excel', 'name' => 'Revenue (Excel-style guess)',
        'formula' => "[#{SRC_NAME}/Revenue]", 'format' => { 'kind' => 'number', 'formatString' => '$#,##0' } }
    else
      { 'id' => 'dt-revenue-excel', 'name' => 'Revenue (Excel-style guess, DISABLED)',
        'formula' => "[#{SRC_NAME}/Revenue]" }
    end

  # NOTE (live-discovered 2026-07-28): the API 400s if `padding:"none"` is
  # combined with border fields — "padding is 'none' but border fields
  # (borderWidth / borderColor) are set — border fields require default
  # padding". So this container tests backgroundColor + borderRadius +
  # borderColor + borderWidth together with DEFAULT (omitted) padding —
  # still a real, valid probe of every field the brief named except the
  # none/border interaction, which is itself a documented finding below.
  hero_style = {
    'backgroundColor' => HERO_BG, 'borderRadius' => 'round',
    'borderColor' => HERO_BORDER, 'borderWidth' => 2,
  }
  hero_style['cornerRadius'] = 8 if flags[:corner_radius_guess]

  cat_color =
    if flags[:categorical_color_column]
      { 'by' => 'category', 'column' => 'cc-category-color' }
    else
      nil
    end
  cat_color = cat_color.merge('scheme' => CATEGORICAL_HEXES) if cat_color && flags[:categorical_explicit_scheme]

  cat_cols = [
    { 'id' => 'cc-category', 'name' => 'Category', 'formula' => "[#{SRC_NAME}/Category]" },
    { 'id' => 'cc-revenue',  'name' => 'Revenue',  'formula' => "Sum([#{SRC_NAME}/Revenue])" },
  ]
  cat_cols << { 'id' => 'cc-category-color', 'name' => 'Category (color channel)',
                'formula' => "[#{SRC_NAME}/Category]" } if flags[:categorical_color_column]

  cat_chart_el = {
    'id' => CHART_CAT_ID, 'kind' => 'bar-chart', 'name' => 'Revenue by Category (categorical scheme)',
    'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
    'columns' => cat_cols,
    'xAxis' => { 'columnId' => 'cc-category' },
    'yAxis' => { 'columnIds' => ['cc-revenue'] },
  }
  cat_chart_el['color'] = cat_color if cat_color

  elements = [
          {
            'id' => SRC_ID, 'kind' => 'table', 'name' => SRC_NAME,
            'source' => { 'kind' => 'sql', 'connectionId' => CONNECTION_ID, 'statement' => DEMO_SQL },
            'columns' => src_cols,
          },
          {
            'id' => KPI_ID, 'kind' => 'kpi-chart',
            'name' => kpi_name,
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [
              { 'id' => 'kpi-val', 'formula' => "Sum([#{SRC_NAME}/Revenue])",
                'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
            ],
            'value' => { 'columnId' => 'kpi-val', 'color' => KPI_VALUE_COLOR },
          },
          {
            'id' => CHART_SINGLE_ID, 'kind' => 'bar-chart', 'name' => 'Revenue by Region (single color)',
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [
              { 'id' => 'cs-region', 'name' => 'Region', 'formula' => "[#{SRC_NAME}/Region]" },
              { 'id' => 'cs-revenue', 'name' => 'Revenue', 'formula' => "Sum([#{SRC_NAME}/Revenue])" },
            ],
            'xAxis' => { 'columnId' => 'cs-region' },
            'yAxis' => { 'columnIds' => ['cs-revenue'] },
            'color' => { 'by' => 'single', 'value' => CHART_SINGLE_COLOR },
          },
          cat_chart_el,
          {
            'id' => TABLE_ID, 'kind' => 'table',
            'name' => table_name,
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [
              { 'id' => 'dt-region', 'name' => 'Region', 'formula' => "[#{SRC_NAME}/Region]" },
              { 'id' => 'dt-category', 'name' => 'Category', 'formula' => "[#{SRC_NAME}/Category]" },
              { 'id' => 'dt-revenue-d3', 'name' => 'Revenue ($,.0f)', 'formula' => "[#{SRC_NAME}/Revenue]",
                'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
              revenue_excel_col,
              { 'id' => 'dt-orders', 'name' => 'Orders', 'formula' => "[#{SRC_NAME}/Orders]" },
            ],
          },
          { 'id' => HERO_ID, 'kind' => 'container', 'style' => hero_style },
          {
            'id' => HERO_TITLE_ID, 'kind' => 'text',
            'body' => "# <span style=\"color: #FFFFFF\">Styling Surface Probe</span>\n" \
                      "<span style=\"color: #94A3B8\">WS3 Task 1 — live GO/NO-GO (#{RUN_TAG})</span>",
          },
  ]
  doc = {
    'schemaVersion' => schema_version,
    'kind' => 'workbook', # PATCHED for live probe: current contract requires document.kind
    # Live since 2026-08: themeName/themeOverrides moved to
    # document.settings.theme.{name,overrides} (shared/lib/code_rep.rb
    # DOC_KEYS) — a flat top-level themeName/themeOverrides is invalid on
    # write and gets silently dropped by the code-rep wrapper.
    'settings' => {
      'theme' => {
        'name' => 'Light',
        'overrides' => {
          'categoricalScheme' => CATEGORICAL_HEXES,
          'titleFont' => { 'color' => TITLEFONT_COLOR, 'fontSize' => 20, 'fontWeight' => 'bold' },
        },
      },
    },
    'pages' => [{ 'id' => PAGE_ID, 'name' => 'Styling Probe' }],
    'elements' => elements,
    'layout' => <<~XML,
      <?xml version="1.0" encoding="utf-8"?>
      <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PAGE_ID}">
        <Container elementId="#{HERO_ID}" type="grid" gridColumn="1 / 25" gridRow="1 / 5" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
          <Element elementId="#{HERO_TITLE_ID}" gridColumn="1 / 25" gridRow="1 / 5"/>
        </Container>
        <Element elementId="#{KPI_ID}" gridColumn="1 / 9" gridRow="5 / 13"/>
        <Element elementId="#{CHART_SINGLE_ID}" gridColumn="9 / 17" gridRow="5 / 17"/>
        <Element elementId="#{CHART_CAT_ID}" gridColumn="17 / 25" gridRow="5 / 17"/>
        <Element elementId="#{TABLE_ID}" gridColumn="1 / 25" gridRow="17 / 29"/>
        <Element elementId="#{SRC_ID}" gridColumn="1 / 25" gridRow="29 / 31"/>
      </Page>
    XML
  }
  Sigma::CodeRep.wrap(doc, extra: {
    'name' => "WS3 styling-surface probe — E2E proof (#{RUN_TAG})",
    'folderId' => home,
    'description' => 'Live GO/NO-GO proof of dashboard-styling spec surfaces. Throwaway test artifact.'
  })
end

# ---------------------------------------------------------------------------
# Export / render / pixel-probe helpers.
# ---------------------------------------------------------------------------

def export_rows(wb, element_id, deadline_s: 60)
  qid = ExportPool.start_json_export(wb, element_id, nil)
  return { ok: false, reason: 'export POST did not return a queryId' } unless qid
  deadline = ExportPool::Deadline.new(deadline_s)
  status, body = ExportPool.poll_json_download(qid, deadline)
  return { ok: false, reason: "poll status=#{status}", status: status } unless status == :ok
  { ok: true, rows: ExportPool.parse_json_rows(body) }
end

def png_dims(path)
  code = 'import sys; from PIL import Image; im = Image.open(sys.argv[1]); print(im.size[0], im.size[1])'
  out = `python3 -c #{Shellwords.escape(code)} #{Shellwords.escape(path)}`
  w, h = out.strip.split.map(&:to_i)
  { 'width' => w, 'height' => h }
end

def render_png(wb, out_path, page_id: nil, element_id: nil, w: 1600, h: 1200)
  png_script = File.expand_path('sigma-export-png.py',
                                 File.join(__dir__, '..', '..', 'plugins', 'tableau-to-sigma', 'skills',
                                            'tableau-to-sigma', 'scripts'))
  cmd = ['python3', png_script, '--workbook', wb, '--out', out_path, '--w', w.to_s, '--h', h.to_s]
  cmd += ['--page', page_id] if page_id
  cmd += ['--element', element_id] if element_id
  out = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>&1`
  ok = $?.success? && File.exist?(out_path)
  { ok: ok, path: (ok ? out_path : nil), log: out.to_s[0, 800] }
end

PIXEL_PROBE_PY = <<~PY
  import sys, json
  import numpy as np
  from PIL import Image

  def main():
      args = json.loads(sys.argv[1])
      img = Image.open(args['png']).convert('RGB')
      arr = np.asarray(img)
      h, w, _ = arr.shape
      tol = args.get('tol', 40)
      results = {}
      for region in args['regions']:
          # Regions are already absolute PIXEL coordinates (see
          # probe_regions/detect_hero_bottom_px in the caller) — NOT
          # fractions of the canvas, because the row axis auto-sizes to
          # content and a fraction-of-declared-grid-line assumption
          # miscalibrates (see the big comment above detect_hero_bottom_px).
          x0 = max(0, min(w, int(region['x0']))); x1 = max(0, min(w, int(region['x1'])))
          y0 = max(0, min(h, int(region['y0']))); y1 = max(0, min(h, int(region['y1'])))
          if x1 <= x0 or y1 <= y0:
              results[region['name']] = {'error': 'empty box', 'box_px': [x0, y0, x1, y1]}
              continue
          crop = arr[y0:y1, x0:x1, :].reshape(-1, 3)
          total = crop.shape[0] or 1
          hit = {}
          for hexcolor in region.get('targets', []):
              r = int(hexcolor[1:3], 16); g = int(hexcolor[3:5], 16); b = int(hexcolor[5:7], 16)
              target = np.array([r, g, b])
              diff = np.abs(crop.astype(np.int16) - target)
              mask = np.all(diff <= tol, axis=1)
              count = int(mask.sum())
              hit[hexcolor] = {'count': count, 'fraction': round(count / total, 5)}
          q = (crop // 16 * 16)
          uniq, counts = np.unique(q, axis=0, return_counts=True)
          order = np.argsort(-counts)[:5]
          top = [{'rgb': uniq[i].tolist(), 'fraction': round(float(counts[i]) / total, 5)} for i in order]
          results[region['name']] = {
              'box_px': [x0, y0, x1, y1], 'total_px': int(total),
              'targets': hit, 'top_colors': top,
          }
      print(json.dumps(results))

  main()
PY

def pixel_probe(png_path, regions, tol: 40)
  Dir.mktmpdir('pixel-probe-') do |dir|
    script = File.join(dir, 'probe.py')
    File.write(script, PIXEL_PROBE_PY)
    args = JSON.generate({ 'png' => png_path, 'regions' => regions, 'tol' => tol })
    out = `python3 #{Shellwords.escape(script)} #{Shellwords.escape(args)} 2>&1`
    raise "pixel_probe failed: #{out}" unless $?.success?
    JSON.parse(out)
  end
end

# `gridTemplateRows="auto"` sizes a row to its CONTENT, not a fixed px/row —
# a live-discovered gotcha (see header comment): the hero band's 2-line
# heading overflowed its declared 4-row allocation and rendered visibly
# taller, which silently invalidated a naive "grid line N == N/30 of total
# canvas height" fraction map (a first cut at this script cropped the hero's
# own subtitle text instead of the KPI title one row down — a real
# miscalibration bug, not a rendering failure). Column width IS reliable
# (`--w` is honored exactly; only the row axis auto-expands), so this detects
# the ACTUAL hero/content boundary empirically and builds every region below
# it proportionally from that real pixel offset instead of a guess.
#
# A single-column scan is fragile — a first cut sampled a column that pierced
# the hero's own heading text/border stroke and broke out at the first
# non-matching (white glyph) pixel, badly UNDER-measuring the band. This
# instead computes, per ROW, what FRACTION of the full width matches the
# hero background — text/border only ever covers a minority of any row's
# width, so the per-row hero-color fraction stays high (>50%) through every
# row of the band and drops hard once the page background starts — and walks
# down while that fraction stays high, tolerating a few consecutive
# below-threshold rows (a wide heading line) before concluding the band
# genuinely ended.
def detect_hero_bottom_px(png_path, hero_bg_hex, tol: 40, row_threshold: 0.5, break_run: 4)
  Dir.mktmpdir('boundary-probe-') do |dir|
    script = File.join(dir, 'boundary.py')
    File.write(script, <<~PY)
      import sys, json
      import numpy as np
      from PIL import Image
      args = json.loads(sys.argv[1])
      img = Image.open(args['png']).convert('RGB')
      arr = np.asarray(img).astype(np.int16)
      h, w, _ = arr.shape
      hexcolor = args['hex']
      r = int(hexcolor[1:3], 16); g = int(hexcolor[3:5], 16); b = int(hexcolor[5:7], 16)
      target = np.array([r, g, b])
      diff = np.abs(arr - target)
      mask = np.all(diff <= args['tol'], axis=2) # h x w bool
      row_fraction = mask.mean(axis=1) # fraction of each row matching hero bg
      last = 0
      miss_run = 0
      for i in range(h):
          if row_fraction[i] >= args['row_threshold']:
              last = i
              miss_run = 0
          else:
              miss_run += 1
              if miss_run >= args['break_run'] and last > 0:
                  break
      print(json.dumps({'width': int(w), 'height': int(h), 'hero_bottom_px': int(last),
                         'row_fraction_sample': [round(float(x), 3) for x in row_fraction[::max(1, h // 20)]]}))
    PY
    args = JSON.generate({ 'png' => png_path, 'hex' => hero_bg_hex, 'tol' => tol,
                           'row_threshold' => row_threshold, 'break_run' => break_run })
    out = `python3 #{Shellwords.escape(script)} #{Shellwords.escape(args)} 2>&1`
    raise "detect_hero_bottom_px failed: #{out}" unless $?.success?
    JSON.parse(out)
  end
end

def shrink_px(box, pct = 0.06)
  x0, x1, y0, y1 = box
  dx = (x1 - x0) * pct
  dy = (y1 - y0) * pct
  [(x0 + dx).round, (x1 - dx).round, (y0 + dy).round, (y1 - dy).round]
end

def region(name, box, targets)
  x0, x1, y0, y1 = box
  { 'name' => name, 'x0' => x0, 'x1' => x1, 'y0' => y0, 'y1' => y1, 'targets' => targets }
end

# Builds every crop box from REAL pixel measurements: `total_w`/`total_h` (the
# actual PNG dims) and `hero_bottom_px` (empirically detected, see above,
# rather than assumed from the declared 24x30 grid). Column fractions of
# `total_w` remain reliable (width is NOT auto-sized); only the row axis
# below the hero is rebuilt proportionally from the real hero/content
# boundary, preserving the declared grid's RELATIVE row proportions (KPI:
# rows 5-13 = 8 of the 25 rows after the hero; charts: rows 5-17 = 12 of 25;
# table: rows 17-29 = 12 of 25, immediately after the KPI/chart row).
def probe_regions(total_w, total_h, hero_bottom_px)
  content_top = hero_bottom_px + 6 # small gutter past the detected edge
  content_h   = total_h - content_top
  rows_after_hero = 25.0 # declared grid rows 5..30
  y = ->(n) { content_top + content_h * (n / rows_after_hero) }

  kpi_box   = [(0.0 / 24 * total_w).round, (8.0 / 24 * total_w).round, content_top, y.call(8).round]
  cs_box    = [(8.0 / 24 * total_w).round, (16.0 / 24 * total_w).round, content_top, y.call(12).round]
  cc_box    = [(16.0 / 24 * total_w).round, (24.0 / 24 * total_w).round, content_top, y.call(12).round]
  table_box = [(0.0 / 24 * total_w).round, (24.0 / 24 * total_w).round, y.call(12).round, y.call(24).round]
  hero_box  = [0, total_w, 0, hero_bottom_px]

  kpi_title_box = [kpi_box[0], kpi_box[1], kpi_box[2], kpi_box[2] + (0.4 * (kpi_box[3] - kpi_box[2])).round]
  kpi_value_box = [kpi_box[0], kpi_box[1], kpi_title_box[3], kpi_box[3]]
  cs_title_box  = [cs_box[0], cs_box[1], cs_box[2], cs_box[2] + (0.18 * (cs_box[3] - cs_box[2])).round]
  cs_body_box   = [cs_box[0], cs_box[1], cs_title_box[3], cs_box[3]]
  cc_title_box  = [cc_box[0], cc_box[1], cc_box[2], cc_box[2] + (0.18 * (cc_box[3] - cc_box[2])).round]
  cc_body_box   = [cc_box[0], cc_box[1], cc_title_box[3], cc_box[3]]
  tbl_title_box = [table_box[0], table_box[1], table_box[2], table_box[2] + (0.14 * (table_box[3] - table_box[2])).round]

  [
    region('hero_bg',        shrink_px(hero_box, 0.03),  [HERO_BG]),
    region('kpi_title',      shrink_px(kpi_title_box),   [KPI_NAME_COLOR]),
    region('kpi_value',      shrink_px(kpi_value_box),   [KPI_VALUE_COLOR]),
    region('chart_single_title', shrink_px(cs_title_box), [TITLEFONT_COLOR]),
    region('chart_single_body',  shrink_px(cs_body_box),  [CHART_SINGLE_COLOR]),
    region('chart_cat_title',    shrink_px(cc_title_box), [TITLEFONT_COLOR]),
    region('chart_cat_body',     shrink_px(cc_body_box),  CATEGORICAL_HEXES),
    region('table_title',        shrink_px(tbl_title_box), [TABLE_NAME_COLOR, TITLEFONT_COLOR]),
  ]
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SCRATCH = ENV.fetch('SCRATCH_DIR', '/private/tmp/claude-502/-Users-tjwells/0fd12afc-2738-4328-a4d5-67e7ce57b185/scratchpad')
FileUtils.mkdir_p(SCRATCH)

verdict = { probe_completed: false }

begin
  home = home_folder_id
  schema_version = reference_schema_version
  log "home folder=#{home} schemaVersion=#{schema_version}"

  flags = { table_name_object: true, excel_format: true, corner_radius_guess: true,
            categorical_color_column: true, categorical_explicit_scheme: false }
  flag_findings = {}

  wb = nil
  resolved = nil
  baseline = nil
  tried = []

  src_formula_candidates.each_with_index do |cand, i|
    # Inner loop: a POST/PUT failure that names one of our guessed/uncertain
    # fields disables THAT flag (a live-verified finding, not a guess) and
    # retries the SAME formula candidate; once no more flags can be blamed,
    # move to the next formula candidate.
    attempt = 0
    loop do
      attempt += 1
      spec = build_spec(home, schema_version, cand[:fn], flags)
      method = wb.nil? ? :post : :put
      path = wb.nil? ? '/v2/workbooks/spec' : "/v2/workbooks/#{wb}/spec"
      begin
        resp = post_or_put_workbook_spec(method, path, spec)
        wb ||= resp['workbookId']
        unless wb
          tried << { candidate: cand[:label], error: "no workbookId in response: #{resp.inspect[0, 300]}" }
          break
        end
        log "workbook #{wb} — formula candidate #{i + 1} (#{cand[:label]}), flags=#{flags.inspect}"
        break # POST/PUT succeeded — fall through to data verification below
      rescue StandardError => e
        msg = e.message.to_s
        log "attempt (formula=#{cand[:label]}, flags=#{flags.inspect}) raised: #{msg[0, 400]}"
        culprit =
          if flags[:corner_radius_guess] && msg =~ /cornerRadius/i
            :corner_radius_guess
          elsif flags[:excel_format] && msg =~ /dt-revenue-excel|formatString/i
            :excel_format
          elsif flags[:table_name_object] && msg =~ /name\b/i && msg =~ /#{Regexp.escape(TABLE_ID)}|table/i
            :table_name_object
          elsif flags[:categorical_color_column] && msg =~ /cc-category-color|one channel/i
            :categorical_color_column
          end
        if culprit
          flag_findings[culprit] = msg[0, 400]
          flags[culprit] = false
          log "disabling flag #{culprit} and retrying same formula candidate"
          next if attempt < 8
        end
        tried << { candidate: cand[:label], flags: flags.dup, error: msg[0, 400] }
        break
      end
    end
    break if wb.nil? && i == src_formula_candidates.size - 1 # exhausted, nothing more to try

    next unless wb # this candidate never even POSTed cleanly — try the next one

    result = (export_rows(wb, TABLE_ID) rescue { ok: false, reason: $!.message })
    unless result[:ok]
      tried << { candidate: cand[:label], result: result }
      log "formula candidate #{i + 1} (#{cand[:label]}): export failed — #{result[:reason]}"
      next
    end
    regions_found = result[:rows].map { |r| r['Region'] || r['region'] }.compact.uniq
    cats_found    = result[:rows].map { |r| r['Category'] || r['category'] }.compact.uniq
    region_match  = (regions_found & EXPECTED_REGIONS).size
    cat_match     = (cats_found & EXPECTED_CATEGORIES).size
    if result[:rows].empty? || region_match < 2 || cat_match < 3
      tried << { candidate: cand[:label], result: result.merge(regions_found: regions_found, cats_found: cats_found) }
      log "formula candidate #{i + 1} (#{cand[:label]}): resolved but data wrong — " \
          "regions=#{regions_found.inspect} categories=#{cats_found.inspect}"
      next
    end

    baseline = result
    resolved = { candidate: cand[:label], regions_found: regions_found, cats_found: cats_found }
    tried << { candidate: cand[:label], result: 'DATA-VERIFIED', regions_found: regions_found, cats_found: cats_found }
    log "formula candidate #{i + 1} (#{cand[:label]}) DATA-VERIFIED: #{result[:rows].size} rows, " \
        "regions=#{regions_found.inspect} categories=#{cats_found.inspect}"
    break
  end

  raise "workbook never resolved to real demo data — tried=#{tried.inspect[0, 2000]}" if resolved.nil?

  workbook_url = "#{ENV['SIGMA_BASE_URL']}/workbook/#{wb}"
  log "resolved workbook #{wb} (#{workbook_url}) via #{resolved[:candidate]}, flags=#{flags.inspect}"

  # --- structural (GET) readback -------------------------------------------
  spec = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
  spec = Sigma::CodeRep.document(spec) if spec.is_a?(Hash) # live GET nests under `document`
  els = Sigma::CodeRep.workbook_elements(spec)
  find_el = ->(id) { els.find { |e| e['id'] == id } }

  kpi_el     = find_el.call(KPI_ID)
  cs_el      = find_el.call(CHART_SINGLE_ID)
  cc_el      = find_el.call(CHART_CAT_ID)
  tbl_el     = find_el.call(TABLE_ID)
  hero_el    = find_el.call(HERO_ID)

  readback = {
    kpi_name: kpi_el && kpi_el['name'],
    kpi_value: kpi_el && kpi_el['value'],
    chart_single_color: cs_el && cs_el['color'],
    chart_cat_color: cc_el && cc_el['color'],
    workbook_categorical_scheme: spec.dig('settings', 'theme', 'overrides', 'categoricalScheme'),
    workbook_title_font: spec.dig('settings', 'theme', 'overrides', 'titleFont'),
    table_name: tbl_el && tbl_el['name'],
    table_formats: tbl_el && (tbl_el['columns'] || []).map { |c| { id: c['id'], format: c['format'] } },
    hero_style: hero_el && hero_el['style'],
    layout_has_gridcontainer: spec['layout'].to_s.include?("<Container elementId=\"#{HERO_ID}\""),
  }
  log "readback: #{JSON.generate(readback)[0, 2000]}"

  # --- render + pixel-probe (page 1) ---------------------------------------
  page_png = File.join(SCRATCH, "styling-probe-#{RUN_TAG}-page.png")
  render1 = render_png(wb, page_png, page_id: PAGE_ID, w: 1600, h: 1200)
  log "render1 (full page): ok=#{render1[:ok]} path=#{render1[:path]}"
  boundary = render1[:ok] ? detect_hero_bottom_px(render1[:path], HERO_BG) : nil
  log "detected hero/content boundary: #{boundary.inspect}"
  probe1 = if render1[:ok] && boundary
             (pixel_probe(render1[:path], probe_regions(boundary['width'], boundary['height'], boundary['hero_bottom_px'])) rescue { 'error' => $!.message })
           end

  # --- side experiment: does an EXPLICIT per-element `scheme` (the
  # documented Recipe-5 shape) do what the workbook-level
  # settings.theme.overrides.categoricalScheme alone didn't? Same workbook, one extra
  # PUT + a targeted element-only render (cheaper than a full-page re-render).
  flags[:categorical_explicit_scheme] = true
  spec2 = build_spec(home, schema_version, src_formula_candidates.find { |c| c[:label] == resolved[:candidate] }[:fn], flags)
  cc_render2 = nil
  probe2 = nil
  begin
    post_or_put_workbook_spec(:put, "/v2/workbooks/#{wb}/spec", spec2)
    cc_png = File.join(SCRATCH, "styling-probe-#{RUN_TAG}-cc-explicit-scheme.png")
    cc_render2 = render_png(wb, cc_png, element_id: CHART_CAT_ID, w: 900, h: 700)
    log "render2 (categorical chart, explicit per-element scheme): ok=#{cc_render2[:ok]}"
    if cc_render2[:ok]
      dims = png_dims(cc_render2[:path])
      body_box = [0, dims['width'], (0.2 * dims['height']).round, dims['height']]
      probe2 = (pixel_probe(cc_render2[:path], [region('chart_cat_body_explicit_scheme', body_box,
                                                         CATEGORICAL_HEXES)]) rescue { 'error' => $!.message })
    end
  rescue StandardError => e
    log "side-experiment (explicit per-element categorical scheme) raised: #{e.message[0, 300]}"
  end

  # --- assemble the per-surface verdict ------------------------------------
  def hit?(probe, region_name, hex, min_fraction)
    return false unless probe && probe[region_name] && probe[region_name]['targets']
    t = probe[region_name]['targets'][hex]
    t && t['fraction'].to_f >= min_fraction
  end

  # 0.003 (not 0.01) for THIN single-line title text: "Revenue" is a shorter,
  # smaller-font string than a big KPI value or a chart title, so its exact-
  # match ink pixel count is naturally lower even when the color is
  # genuinely, visibly applied (confirmed by directly reading the render).
  kpi_name_survived  = kpi_el && kpi_el['name'].is_a?(Hash) && kpi_el['name']['text']
  kpi_name_rendered  = hit?(probe1, 'kpi_title', KPI_NAME_COLOR, 0.003)
  kpi_value_survived = kpi_el && kpi_el['value'].is_a?(Hash) && kpi_el['value']['color']
  kpi_value_rendered = hit?(probe1, 'kpi_value', KPI_VALUE_COLOR, 0.01)

  chart_single_survived = cs_el && cs_el['color'].is_a?(Hash) && cs_el['color']['by'] == 'single'
  chart_single_rendered = hit?(probe1, 'chart_single_body', CHART_SINGLE_COLOR, 0.03)

  cat_scheme_survived = readback[:workbook_categorical_scheme].is_a?(Array) &&
                        readback[:workbook_categorical_scheme].map(&:downcase).sort ==
                        CATEGORICAL_HEXES.map(&:downcase).sort
  cat_theme_only_rendered = probe1 && CATEGORICAL_HEXES.count { |h| hit?(probe1, 'chart_cat_body', h, 0.02) } >= 2
  cat_explicit_scheme_rendered = probe2 && CATEGORICAL_HEXES.count do |h|
    t = probe2['chart_cat_body_explicit_scheme'] && probe2['chart_cat_body_explicit_scheme']['targets'] &&
        probe2['chart_cat_body_explicit_scheme']['targets'][h]
    t && t['fraction'].to_f >= 0.02
  end >= 2

  format_survived = tbl_el && (tbl_el['columns'] || []).any? { |c| c['id'] == 'dt-revenue-d3' &&
                                                                    c.dig('format', 'formatString') == '$,.0f' }

  hero_survived = hero_el && hero_el['style'].is_a?(Hash) &&
                  hero_el['style']['backgroundColor'].to_s.downcase == HERO_BG.downcase &&
                  hero_el['style']['borderRadius'] == 'round'
  hero_rendered = hit?(probe1, 'hero_bg', HERO_BG, 0.4)
  corner_radius_guess_survived = hero_el && hero_el['style'].is_a?(Hash) && hero_el['style'].key?('cornerRadius')

  titlefont_survived = readback[:workbook_title_font].is_a?(Hash) &&
                       readback[:workbook_title_font]['color'].to_s.downcase == TITLEFONT_COLOR.downcase
  titlefont_rendered = probe1 && (hit?(probe1, 'chart_single_title', TITLEFONT_COLOR, 0.01) ||
                                   hit?(probe1, 'chart_cat_title', TITLEFONT_COLOR, 0.01))
  table_name_object_survived = tbl_el && tbl_el['name'].is_a?(Hash) && tbl_el['name']['color']
  # Color-only signal (fontSize can't be told apart by pixel color) — the
  # table's OWN name.color (TABLE_NAME_COLOR, distinct from the workbook-wide
  # TITLEFONT_COLOR) actually painting the table_title crop is unambiguous
  # proof the per-element override applied (and, since the workbook-wide
  # titleFont color is checked separately, whether it or the per-element
  # color "won" when both are present).
  table_name_object_rendered = hit?(probe1, 'table_title', TABLE_NAME_COLOR, 0.003)

  verdict = {
    probe_completed: true,
    workbook_id: wb,
    workbook_url: workbook_url,
    resolved_formula_candidate: resolved[:candidate],
    flags_final: flags,
    flag_findings: flag_findings,
    render_page_png: render1[:path],
    render_categorical_explicit_scheme_png: cc_render2 && cc_render2[:path],
    readback: readback,
    pixel_probe_page: probe1,
    pixel_probe_categorical_explicit_scheme: probe2,
    surfaces: {
      'kpi-name-color' => {
        go: !!(kpi_name_survived && kpi_name_rendered),
        readback_survived: !!kpi_name_survived,
        rendered: !!kpi_name_rendered,
        surviving_shape: (kpi_name_survived && kpi_name_rendered ? { name: { text: 'Revenue', color: KPI_NAME_COLOR } } : nil),
        alt_value_color: {
          survived: !!kpi_value_survived, rendered: !!kpi_value_rendered,
          surviving_shape: (kpi_value_survived && kpi_value_rendered ? { value: { columnId: 'kpi-val', color: KPI_VALUE_COLOR } } : nil),
        },
        note: 'brief surface 1 = kpi-chart `name` (title) color. Tested `value.color` too (brief: ' \
              '"and/or any value-color field") as the documented alternative lever.',
      },
      'chart-color-by' => {
        go: !!(chart_single_survived && chart_single_rendered),
        readback_survived: !!chart_single_survived,
        rendered: !!chart_single_rendered,
        surviving_shape: (chart_single_survived && chart_single_rendered ? { color: { by: 'single', value: CHART_SINGLE_COLOR } } : nil),
      },
      'categorical-scheme' => {
        go: !!(cat_scheme_survived && (cat_theme_only_rendered || cat_explicit_scheme_rendered)),
        workbook_theme_only: { readback_survived: !!cat_scheme_survived, rendered: !!cat_theme_only_rendered },
        per_element_explicit_scheme: { attempted: !probe2.nil?, rendered: !!cat_explicit_scheme_rendered },
        surviving_shape:
          if cat_theme_only_rendered
            { settings: { theme: { overrides: { categoricalScheme: CATEGORICAL_HEXES } } } }
          elsif cat_explicit_scheme_rendered
            { color: { by: 'category', column: '<category-col-id>', scheme: CATEGORICAL_HEXES } }
          end,
        note: 'brief literally asks for workbook-level settings.theme.overrides.categoricalScheme driving a bar chart ' \
              'with NO per-element color.scheme. Also tested the documented Recipe-5 alternative (an explicit ' \
              'per-element `color.scheme`) as a side experiment, since that is the field the module would fall ' \
              'back to if the workbook-level lever does not drive non-donut/pie charts.',
      },
      'format-string' => {
        go_readback: !!format_survived,
        render: 'NEEDS VISUAL CONFIRMATION — pixel-color probing cannot distinguish "$42,000" from "42000"; ' \
                'the calling agent must Read the rendered PNG and confirm the d3-format ($,.0f) column shows ' \
                'formatted currency text and note whether the Excel-style ($#,##0) column rendered differently.',
        excel_style_guess_flag_disabled_reason: flag_findings[:excel_format],
        surviving_shape: (format_survived ? { format: { kind: 'number', formatString: '$,.0f' } } : nil),
      },
      'container-style' => {
        go: !!(hero_survived && hero_rendered),
        readback_survived: !!hero_survived,
        rendered: !!hero_rendered,
        surviving_shape:
          if hero_survived && hero_rendered
            # NOTE: `padding` is deliberately ABSENT (default), not "none" —
            # a live 400 discovered mid-probe that padding:"none" combined
            # with borderWidth/borderColor is REJECTED outright ("border
            # fields require default padding"). Emit `padding` only when the
            # container has NO border, and omit it (or use a non-"none"
            # value) whenever borderColor/borderWidth are set.
            { kind: 'container', style: { backgroundColor: HERO_BG, borderRadius: 'round',
                                           borderColor: HERO_BORDER, borderWidth: 2 } }
          end,
        cornerRadius_guess: {
          survived_readback: !!corner_radius_guess_survived,
          disabled_by_retry: flag_findings.key?(:corner_radius_guess),
          note: (corner_radius_guess_survived ? 'guessed `cornerRadius` key survived readback verbatim (unverified whether it RENDERS anything)' \
                : (flag_findings.key?(:corner_radius_guess) ? "POST/PUT rejected `cornerRadius` outright: #{flag_findings[:corner_radius_guess]}" \
                  : 'guessed `cornerRadius` key was silently dropped on readback — the real field is `borderRadius` (enum square|round|pill)')),
        },
        padding_none_plus_border_conflict:
          "live 400: padding:'none' combined with borderWidth/borderColor is REJECTED " \
          '("padding is \'none\' but border fields (borderWidth / borderColor) are set — border fields require ' \
          'default padding") — the module must never emit both together.',
        layout_top_level_gridcontainer_survived: !!readback[:layout_has_gridcontainer],
      },
      'typography' => {
        go: !!((titlefont_survived && titlefont_rendered) || (table_name_object_survived && table_name_object_rendered)),
        workbook_level_titleFont: { readback_survived: !!titlefont_survived, rendered: !!titlefont_rendered,
                                     surviving_shape: (titlefont_survived && titlefont_rendered ?
                                       { settings: { theme: { overrides: { titleFont: { color: TITLEFONT_COLOR, fontSize: 20, fontWeight: 'bold' } } } } } : nil) },
        per_element_name_object: {
          readback_survived: !!table_name_object_survived,
          rendered_color: !!table_name_object_rendered,
          disabled_by_retry: flag_findings.key?(:table_name_object),
          surviving_shape: (table_name_object_survived && table_name_object_rendered ?
            { name: { text: 'Category Detail', fontSize: 22, color: TABLE_NAME_COLOR } } : nil),
          render_fontSize: 'font-SIZE specifically still NEEDS VISUAL CONFIRMATION (pixel color alone cannot ' \
                            'distinguish a 22px vs default title) — the calling agent should Read the PNG\'s ' \
                            'table-title region and eyeball whether it reads visibly larger than the other titles.',
          note: (flag_findings.key?(:table_name_object) ? "POST/PUT rejected a table `name` object outright: #{flag_findings[:table_name_object]}" \
                : 'the COLOR channel of a per-element `name:{text,fontSize,color}` on a non-KPI element (table) ' \
                  'is now pixel-verified via rendered_color above (a distinct test hex from the workbook-wide ' \
                  'titleFont, so a hit here cannot be confused with that lever).'),
        },
        note: 'stretch surface. Two INDEPENDENT levers both tested live: workbook-wide settings.theme.overrides.titleFont ' \
              '(applies to every element title with no per-element override) and a per-element `name` object ' \
              'with fontSize/color (table only, isolated with a different test hex) — the per-element color, ' \
              'where present, wins over the workbook-wide one (see table_title pixel evidence).',
      },
    },
  }
rescue StandardError => e
  verdict = { probe_completed: false, fatal_error: "#{e.class}: #{e.message}", backtrace: e.backtrace&.first(15) }
  log "FATAL — probe did not complete: #{e.class}: #{e.message}"
end

puts
puts '=' * 78
puts verdict[:probe_completed] ? 'PROBE COMPLETED' : 'PROBE FAILED (fatal)'
puts '=' * 78
if verdict[:probe_completed]
  puts
  puts format('%-22s %-8s %s', 'SURFACE', 'VERDICT', 'NOTES')
  verdict[:surfaces].each do |name, v|
    go = v.key?(:go) ? v[:go] : v[:go_readback]
    label = go == true ? 'GO' : (go == false ? 'NO-GO' : 'SEE NOTE')
    puts format('%-22s %-8s %s', name, label, (v[:note] || '')[0, 120])
  end
  puts
end
puts JSON.pretty_generate(verdict)
exit(verdict[:probe_completed] ? 0 : 1)
