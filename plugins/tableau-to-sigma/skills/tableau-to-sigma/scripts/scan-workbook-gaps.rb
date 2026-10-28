#!/usr/bin/env ruby
# Scan a customer's Tableau .twb (or .twbx after unzip) and emit a markdown gap
# report listing every workbook feature the skill currently handles vs. doesn't.
#
# This is the FIRST thing a customer should run when starting a migration:
# it sets expectations up front (rather than discovering gaps mid-conversion)
# and gives the agent a concrete plan for what to translate auto vs. by hand
# vs. defer.
#
# Usage:
#   ruby scripts/scan-workbook-gaps.rb /path/to/workbook.twb [out.md]
#
# Output: a markdown file (default: <name>-gaps-report.md) with:
#   - Workbook summary (worksheets, dashboards, datasource count)
#   - Auto-handled features (with count)
#   - Hint-only features (count + brief translation guidance)
#   - Unhandled features (count + escalation path)
#   - Manual-setup features (action filters, ref-marks etc. that need
#     post-publish UI work)
#
# The same data is also written as <name>-gaps.json so the gap-scout subagent
# and other downstream tools can consume it programmatically.
#
# SCOPE: the scan itself is WORKBOOK-WIDE (no scope input — expectations are
# set for the whole file). For SCOPED runs (E9.6), each detected feature
# carries a best-effort `worksheets` attribution (direct worksheet-section
# match, or calc-formula match → the worksheets referencing that calc) so the
# orchestrator's gap STOP can skip gaps belonging entirely to out-of-scope
# dashboards. A feature with NO attribution has no `worksheets` key —
# consumers must FAIL OPEN (treat it as potentially in scope).

require 'json'
require 'set'
require 'csv'
require 'open3'
require 'cgi'
# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files. See lib/twb_xml.rb.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'
require 'calc_coverage' # masked function extraction + official catalog (v5.0)
require_relative 'learned-rules' # validated customer rewrites rescue converter refusals
require 'chart_calc_translate' # build-charts' own chart/pivot calc translators (shared lib)
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

# --- Feature inventory: what the skill handles today ----------------------
# Each entry: { pattern: regex_or_lambda, name: "feature", status: :auto |
# :hint | :manual | :unhandled, blurb: "..." }
INVENTORY = [
  # AUTO — fully translated end-to-end, no manual step needed
  { name: 'Bar / line / area / pie / scatter chart',  pat: /<mark class='(Bar|Line|Area|Pie|Circle|Shape)'/,
    status: :auto, blurb: 'Translated to Sigma bar/line/area/pie/scatter chart with the right marker.' },
  { name: 'Waterfall (GanttBar + running total)',      pat: /<mark class='GanttBar'/,
    status: :hint, blurb: 'A GanttBar worksheet whose calculated fields contain RUNNING_SUM is emitted as native Sigma waterfall-chart. Other GanttBar uses (timeline/gantt/candlestick) remain manual; verify the emitted waterfall y-series is the per-category delta, not an already-cumulative export.' },
  { name: 'Box plot / box-and-whisker',                pat: /box[-_ ]?(?:plot|and[-_ ]whisker)|boxplot/i,
    status: :manual, blurb: 'Sigma box-chart is not published in the workbook spec. Keep this as an explicit fallback: re-author from quartile/reference-mark components or use a table; never emit kind:box-chart.' },
  { name: 'Region / filled map',                       pat: /<mark class='(Multipolygon|Polygon|Filled|Map)'/,
    status: :auto, blurb: 'Translated to Sigma region-map.' },
  { name: 'Point / symbol map',                        pat: /<column[^>]+caption='Latitude'/i,
    status: :auto, blurb: 'Translated to Sigma point-map when lat+long both present.' },
  { name: 'Column aliases (value→display)',            pat: /<column[^>]+(?:caption='[^']+')?[^>]*>\s*<aliases>\s*<alias key=/,
    status: :auto, blurb: 'Aliased dim columns get a Switch() formula on the chart.' },
  { name: 'Tableau format strings',                    pat: /<format\s[^>]*attr='text-format'/,
    status: :auto, blurb: 'p0.0% / C1033% / $#,##0;(...) etc. translated to Sigma d3-format with paren-negative.' },
  { name: 'Shared-view dashboard filters',             pat: /<shared-view[^>]*>\s*<datasources>/,
    status: :hint, blurb: 'Dashboard QUICK-filters become Sigma controls per page (auto). But an always-on DATA-SOURCE filter hosted here (user:ui-domain=database, e.g. an `active` flag) renders nothing on any dashboard, so it must be APPLIED as a workbook-wide default filter on the master — NOT left as an open control. parse-twb-layout tags them (is_datasource_filter); the datasource-filter gate (assert-datasource-filters.rb) blocks GREEN until each is applied. See refs/phase-1-discover.md.' },
  { name: 'Per-worksheet sort',                        pat: /<sort\s+[^>]*direction=/,
    status: :auto, blurb: "Tableau's sort direction carries into the chart's xAxis.sort." },
  { name: 'Parameter (list domain) + CASE-on-param',   pat: /param-domain-type='list'/,
    status: :auto, blurb: "List parameters become segmented controls; CASE/IF-on-param calcs translate to Sigma Switch()." },
  { name: 'Parameter (numeric range)',                 pat: /param-domain-type='range'/,
    status: :auto, blurb: 'Numeric range parameters become number-range controls. Skips orphan params not referenced by any worksheet calc.' },
  { name: 'Dual-axis (synchronized) combo charts',     pat: /synchronized='true'/,
    status: :auto, blurb: 'Synchronized-axis worksheets emit Sigma combo-chart with two yAxis groups.' },
  { name: 'Custom SQL data source',                    pat: /<relation\s[^>]*\btype='text'/,
    status: :auto, blurb: 'Inventory the SQL; prefer equivalent warehouse-table elements and use source.kind="sql" only as the semantics-preserving fallback.' },
  { name: 'Hyper / Tableau extract',                   pat: /<connection\s[^>]*\bclass='hyper'|<extract\s/,
    status: :hint, blurb: 'Workbook has a .hyper extract — Sigma uses live warehouse data. Phase 6 runs in --extract-mode (structural compare) instead of strict-value.' },
  { name: 'Cross-extract drift (live warehouse newer than extract)', pat: /<connection\s[^>]*\bclass='hyper'|<extract\s/,
    status: :manual, blurb: "Tableau extract data range typically lags the live warehouse by months/years (extract has 2023-2024, live warehouse has 2024-2027). Chart actuals WILL diverge on date axes — this is expected, not a converter bug. Tier as YELLOW with error_summary 'extract-vs-live drift'; document the extract refresh date alongside the live warehouse range." },
  { name: 'Table-calc INDEX/LOOKUP/TOTAL/RANK(_UNIQUE/_DENSE/_PERCENTILE)/ZN/IIF', pat: /\b(INDEX\(\)|LOOKUP\(|TOTAL\(|RANK_UNIQUE|RANK_DENSE|RANK_PERCENTILE|RANK\b|\bZN\(|\bIIF\(|\bCOUNTD\()/,
    status: :auto, blurb: 'Auto-translated when plotted (WINPROBE-validated, bead 427; refs/window-functions.md): RANK family → Rank/RankDense/RankPercentile(agg, "desc" — Tableau default direction); RANK_UNIQUE(expr) → RowNumber() (unique rank; verify the element is sorted by the ranked expr); INDEX() → RowNumber(); LOOKUP(agg, ±n) → Lag/Lead(agg, n); standalone TOTAL(agg) → hidden two-level grouped helper; pareto RUNNING_SUM/TOTAL → CumulativeSum(PercentOfTotal(agg, "grand_total")); ZN/IIF/COUNTD → Coalesce/If/CountDistinct. Tableau <computed-sort> carries into xAxis.sort (cumulative/rank follow it).' },
  { name: 'Negative number format (parens)',           pat: /;\s*\([^)]*\)/,
    status: :auto, blurb: 'Parens-on-negative segment translates to Sigma d3-format with ( prefix.' },
  { name: 'Axis range / scale override (log, fixed min/max)', pat: /<encoding\s+attr='space'[^>]*(?:scale='log'|range-type='fixed')/,
    status: :auto, blurb: 'Per-axis log scale and fixed min/max translate to Sigma xAxis/yAxis format.scale (type / domain).' },
  { name: 'Show Mark Labels worksheet toggle',         pat: /<format\s+attr='mark-labels-show'\s+value='true'/,
    status: :auto, blurb: "Worksheet-level Show Mark Labels toggle emits Sigma dataLabel:{labels:shown}." },
  { name: 'Explicit color legend zone',                pat: /type-v2='color'/,
    status: :auto, blurb: 'When the legend can be attributed to one worksheet, its nearest source edge maps to native chart legend.position. Ambiguous shared/free-floating legends remain a visual-verification item.' },
  { name: 'FIXED LOD calc (incl. nested)',             pat: /\{\s*FIXED\b/i,
    status: :auto, blurb: 'Auto-translated when plotted. Single-level {FIXED dims : AGG(m)}: hidden two-level grouped helper element (visibleAsSource:false; inner grouping = FIXED dims computing the LOD aggregate, outer = chart dims computing the 2nd-stage aggregate; chart Max()es the outer calc). Nested {FIXED ... {FIXED ...}}: auto-decomposed into a helper-element chain (innermost first; outer levels source the inner WITH groupingId) via build-charts-from-signals.rb → -lod-chains.json sidecar. ⚠ single-level helper is exact iff carried chart dims are functionally dependent on the FIXED dims — the build emits a per-chart verify warning. Never SumOver/CountOver in master/DM calc columns (silent error).' },

  # HINT — surfaces a translated formula or setup note as a WARN; agent acts
  { name: 'Context filters',                           pat: /\bcontext='true'/,
    status: :hint, blurb: 'Tableau context filters scope FIXED LODs and narrow downstream filter domains. They become Sigma filters/controls, but the SCOPING is not automatic — verify any FIXED-LOD calc that depended on the context still evaluates over the intended row set. High counts (10+) mean filter-order matters.' },
  { name: 'IF/ELSEIF chain calc',                      pat: /\bIF\b[^']+\bELSEIF\b[^']+\bEND\b/i,
    status: :hint, blurb: 'WARN with suggested Sigma If(...) chain or Switch(). Agent adds to master.' },
  { name: 'Ratio calc (SUM/SUM, SUM/COUNT)',           pat: /SUM\s*\([^)]+\)\s*\/\s*(?:SUM|COUNT)\s*\(/i,
    status: :hint, blurb: 'WARN suggests Sum(x) / NullIf(Sum(y), 0) — agent wires on master.' },
  { name: 'INCLUDE/EXCLUDE LOD',                       pat: /\{\s*(INCLUDE|EXCLUDE)\b/i,
    status: :manual, blurb: 'Needs the chart-grouping context: INCLUDE = add the dim to the chart grouping and use the plain aggregate; EXCLUDE = remove it (or OVER(PARTITION BY view-dims-minus-excluded) via Custom SQL). The skill surfaces the formula + suggestion; customer wires it post-publish.' },
  { name: 'Reference lines / bands / trendlines',      pat: /<(reference-line|reference-band|reference-distribution|trendline-model)\b/,
    status: :hint, blurb: 'WARN per chart; agent adds Sigma referenceMarks manually post-publish (see [bead]).' },
  { name: 'Color encoding on measure',                 pat: /<encoding attr='color'[^>]+field-type='quantitative'/,
    status: :hint, blurb: 'WARN; agent adds Sigma colorBy on chart with palette manually (see [bead]).' },

  # MANUAL — non-translatable today; needs customer to do post-publish work
  { name: 'Dashboard filter / highlight / nav actions', pat: /command='tsc:tsl-(filter|highlight|navigate|set-action|parameter-action|url)'/,
    status: :manual, blurb: 'tsl-filter → Sigma cross-element filter. FAITHFUL but ~80% automatable (verified 2026-07-10): the CONTROL half is spec-authorable — emit a list control whose filters bind {source:{kind:table,elementId},columnId} to the target element(s); elements sourcing the filtered element inherit it. The click-to-trigger IS spec-authorable as of 2026-08: an on-select action with a set-control-value effect on the source element, verified live (mark click sets the control, whose filters[] then filter the target: 911 rows -> 319). Filter actions are not yet auto-wired by this converter — see the emitted-actions ledger for what was. GOTCHA: list-control values are STRINGS, so a NUMERIC filter column (period/year/id) 400s ("Expecting string") then 500s at query time — cast the numeric dim to text (Text([…])) in the control value-source column; text columns work as-is. Skill still writes actions.md for the click bindings. See sigma-workbooks controls.md "Cross-element filters".' },
  { name: 'Dashboard buttons (navigate / export / show-hide)', pat: /type-v2='dashboard-object'/,
    status: :hint, blurb: 'v5.0-P2: NAVIGATE buttons auto-emit (dashboard targets = Sigma pages; native kind:button with a navigate action by default, target page repaired by put-layout.rb; in a workspace that gates buttons post-and-readback.rb falls back to a text-pill link whose placeholder URL put-layout.rb rewrites to the live page). EXPORT buttons = recoverable residue (Sigma has a built-in export menu). SHOW/HIDE container toggles = named residue (no spec-authorable visibility toggle) — coverage.json dedupes them per (dashboard, tooltip/icon).' },
  { name: 'Forecast / trendline model',                pat: /<forecast\b/,
    status: :manual, blurb: 'No Sigma forecast primitive; agent emits a note + Custom SQL option ([bead]).' },
  { name: 'Story points (sequential narrative)',       pat: /<story\b/,
    status: :hint, blurb: 'Each story point becomes a separate Sigma page: parse-twb-layout.rb writes story-plan.json, then scripts/build-story-pages.rb emits caption-named pages plus a native in-canvas navigation element and annotation (refs/story-points.md).' },
  { name: 'Drill hierarchies',                         pat: /<drill-paths>|<drill-path /,
    status: :manual, blurb: 'Sigma now publishes controlType:drill (ordered categories + per-target columnIds). Tableau drill paths are detected, but target-column alignment is not safe to infer yet; map them to native drill controls or pivot rowsBy and verify each target.' },

  # UNHANDLED — feature actively used in real workbooks but not surfaced yet
  # (numeric-range param moved to auto in commit 1d3445d — scout discovered the
  # number-range controlType is correct)
  { name: 'WINDOW_* aggregates (SUM/AVG/MIN/MAX/COUNT/STDEV/VAR)', pat: /\bWINDOW_(SUM|AVG|MIN|MAX|COUNT|STDEV|VAR)\b(?!P)/,
    status: :auto, blurb: 'Auto-translated when plotted (WINPROBE-validated, bead 427; refs/window-functions.md): bounded WINDOW_*(agg, -n[, m]) → Moving*(agg, n[, m]) as a chart yAxis viz formula (WINDOW_STDEV→MovingStdDev, WINDOW_VAR→MovingVariance — SAMPLE variants; the population forms WINDOW_STDEVP/VARP stay manual); agg/WINDOW_SUM(agg) share → PercentOfTotal(agg, "grand_total"); unbounded WINDOW_MAX/MIN/SUM → hidden two-level grouped helper (consumer re-aggregates Max/Min, NEVER Sum). One DM base element, zero Custom SQL. Compute-using/addressing overrides beyond Table(Across)/simple partitions stay manual (flagged).' },
  { name: 'RUNNING_* totals',                          pat: /\bRUNNING_(SUM|AVG|COUNT|MIN|MAX)\b/,
    status: :auto, blurb: 'Auto-translated when plotted: RUNNING_* → Sigma Cumulative* as a chart yAxis viz formula (follows the xAxis sort; auto-partitions by chart color/series). Pareto RUNNING_SUM/TOTAL → CumulativeSum(PercentOfTotal(agg, "grand_total")). WINPROBE-validated (bead 427).' },
  { name: 'Window calcs with NO validated Sigma mapping', pat: /\b(WINDOW_(MEDIAN|PERCENTILE|CORR|COVARP?|VARP|STDEVP)|PREVIOUS_VALUE|RANK_MODIFIED)\s*\(|\bSIZE\s*\(\s*\)/,
    status: :manual, blurb: 'WINDOW_MEDIAN/PERCENTILE/CORR/COVAR(P)/VARP/STDEVP (population var/stdev), PREVIOUS_VALUE, SIZE(), RANK_MODIFIED — no validated Sigma chart-formula equivalent; port via a Custom SQL DM element (ANSI OVER(...)) or re-author in Sigma. build-charts flags these, never guesses. (RANK_UNIQUE and sample WINDOW_VAR/STDEV ARE auto — see the table-calc / WINDOW_* rows above.)' },
  { name: 'Tableau SCRIPT_* (R/Python)',               pat: /\bSCRIPT_(REAL|STR|INT|BOOL)\b/,
    status: :unhandled, blurb: 'No Sigma equivalent. Customer rewrites in SQL/Python via Custom SQL or external prep.' },
  { name: 'Phone / mobile-specific layout',            pat: /<device-layout\b|<phone-layout\b/,
    status: :unhandled, blurb: 'Sigma has no separate mobile layout; one responsive layout applies.' },
  { name: 'Show/hide containers',                      pat: /show-hide-container|is-modal='true'/,
    status: :unhandled, blurb: 'Sigma containers can be conditionally hidden via a control; needs manual wiring.' },
  { name: 'Sets (computed / manual)',                  pat: /<groupfilter function='set'|<set\s/,
    status: :unhandled, blurb: 'No Sigma direct equivalent. Approximate with a calculated boolean column.' },

  # DESIGN / COMPOSITION — surfaced so a design-heavy dashboard no longer reports
  # "0 unhandled" (false comfort). See TABLEAU_TO_SIGMA_SKILL_GAPS.md. These are
  # regex-tokenizable; the STRUCTURAL design gaps (repeated per-category small
  # multiples → native trellis, 1-D strip/jitter plots C1) are detected in
  # parse-twb-layout.rb (Phase 1) — a raw-text regex can't reliably spot them.
  { name: 'Container background tint / colored header band', pat: /<format\s+attr='background-color'\s+value='#(?!(?:fff(?:fff)?|FFF(?:FFF)?)')/,
    status: :auto, blurb: 'Dashboard zone fills, borders, and rounded corners are surfaced by parse-twb-layout and emitted on native container.style; full-canvas images map to page backgroundImage. Verify alpha colors and complex per-side border differences visually.' },
  { name: 'Custom categorical color palette (discrete)', pat: /<encoding[^>]+(?:class|attr)='color'[\s\S]{0,400}?<map>/,
    status: :auto, blurb: "Gap D1 (auto since PR-12): a color encoding carries an explicit value→color map. parse-twb-layout extracts it (series_colors) and build-charts pins per-chart color.scheme + themeOverrides.categoricalScheme ORDERED ascending by member (Sigma applies schemes positionally in category-sort order). Verify via formats-emitted.json series_color_maps." },
  { name: 'Viz-in-tooltip (embedded chart in tooltip)', pat: /visual-tooltip|show-viz-in-tooltip/i,
    status: :manual, blurb: 'Gap F3: worksheet embeds a viz inside its tooltip. Sigma has no spec-API path for viz-in-tooltip (no persistence) — recreate manually post-publish or drop. Surfaced here so it is not silently lost.' }
].freeze

def categorize(content)
  results = INVENTORY.map do |entry|
    matches = content.scan(entry[:pat]).length
    entry.merge(count: matches)
  end
  results.select { |r| r[:count] > 0 }
end

# --- Worksheet attribution (E9.6/A2, wave-1 review) -------------------------
# Best-effort per-feature worksheet membership so a SCOPED orchestrator run
# (migrate-tableau.rb --dashboard) can tell an in-scope ❌ gap from one that
# belongs entirely to out-of-scope dashboards. Two hops:
#   1. DIRECT — the feature's pattern matches inside a <worksheet> raw section;
#   2. CALC   — the pattern matches a datasource-level calc FORMULA; the gap
#      then belongs to every worksheet whose section references that column's
#      internal name (formulas live in the datasource block, so hop 1 alone
#      would miss every calc-borne gap).
# A feature matching neither hop (dashboard-/datasource-structural — device
# layouts, multi-datasource collapse, …) gets NO :worksheets key, which
# consumers MUST read as "unknown — fail open". Mutates `results` in place.
def attribute_worksheets!(results, content, xml)
  ws_bodies = content.scan(%r{<worksheet\s[^>]*?name=(?:'([^']*)'|"([^"]*)")[^>]*>(.*?)</worksheet>}m)
                     .each_with_object({}) { |(sq, dq, body), h| h[(sq || dq).to_s] = body.to_s }
  return if ws_bodies.empty?
  calc_defs = {} # internal column name → decoded formula
  begin
    xml&.elements&.to_a('/workbook/datasources/datasource')&.each do |ds|
      ds.elements.each('column') do |col|
        f = col.elements['calculation']&.attributes&.[]('formula')
        calc_defs[col.attributes['name'].to_s] = f if f && !col.attributes['name'].to_s.empty?
      end
    end
  rescue StandardError
    calc_defs = {} # attribution is best-effort — never sink the scan
  end
  results.each do |r|
    pat = r[:pat]
    next unless pat.is_a?(Regexp)
    hits = ws_bodies.select { |_, body| body =~ pat }.keys
    calc_names = calc_defs.select { |_, f| f =~ pat }.keys
    if calc_names.any?
      hits |= ws_bodies.select { |_, body| calc_names.any? { |n| body.include?(n) } }.keys
    end
    r[:worksheets] = hits.sort if hits.any?
  end
rescue StandardError
  nil # never fatal: an unattributed report is still a valid (fail-open) report
end

# Detect point-map worksheets that declare geo-role latitude/longitude on a
# column but where the underlying datasource's column-instance set doesn't
# include both. In practice this surfaces as: a Tableau sheet with `<mark
# class='Circle'/>` and a `<column geo_role='latitude'>` calc, but the warehouse
# table has no LAT/LON columns and the calc was a `MAKEPOINT(...)` derivation
# the conversion skill doesn't translate yet. The chart silently degrades to a
# bar (the build-charts default fallback when geo channels can't be wired) and
# users only notice in Phase 6f.
def detect_point_map_geo_role_gaps(content)
  has_lat = content =~ /geo_role='latitude'/i
  has_lon = content =~ /geo_role='longitude'/i
  has_circle_mark = content =~ /<mark class='(Circle|Shape)'/
  return [] unless has_circle_mark
  # If lat XOR lon is present, point-map cannot render — emit a manual gap.
  return [] if has_lat && has_lon
  return [] unless has_lat || has_lon
  [{
    name:   'Point-map missing lat/long column',
    status: :manual,
    count:  1,
    blurb:  'Tableau declares geo_role=latitude or =longitude but not both. Sigma point-map needs both lat and lon — the chart will silently degrade to a bar. Add the missing column to the warehouse / DM, or accept the bar substitution.'
  }]
end

# ---- Data-blend detection ([bead]) --------------------------------
# A worksheet BLENDS (vs joins) when it pulls fields from 2+ real datasources:
# the worksheet's <view> lists multiple <datasource> refs and carries a
# <datasource-dependencies datasource='<secondary>'> block naming the fields it
# pulls from the secondary. Linking fields are approximated as the captions
# that appear in BOTH the primary's and the secondary's dependency blocks
# (Tableau links blends on same-named fields by default). A <join> inside ONE
# <datasource> is a join, not a blend — it never produces a secondary
# datasource-dependencies block, so it never matches here.
#
# Output: blend-plan.json next to the gaps report + one gap-report row, with a
# per-blend ROUTE picked by comparing the primary/secondary <connection>
# blocks (decision tree in refs/blending.md):
#   same-warehouse-repoint   — same warehouse: ONE DM, two elements + a
#                              relationship on the linking fields; repoint
#                              connectionId by DEEP-WALKING the DM spec
#                              (joins[].left/right nest sources recursively —
#                              a top-level-only swap misses them)
#   materialize-via-vds      — secondary is a file / extract / published
#                              source: land it in the primary's warehouse with
#                              the tableau-vds-to-cdw skill FIRST, then treat
#                              as same-warehouse-repoint
#   flag-unreachable         — secondary is a different live system we can
#                              neither repoint nor land: surface the linking-
#                              field report and leave the blend manual
WAREHOUSE_CONN_CLASSES = %w[
  snowflake redshift bigquery postgres greenplum sqlserver mysql oracle
  databricks azure-sql synapse vertica teradata presto trino athena saphana
].freeze
FILE_CONN_CLASSES = %w[
  textscan csv msexcel excel-direct hyper webdata-direct google-sheets
  googlesheets salesforce sqlproxy
].freeze

def datasource_connections(xml)
  out = {}
  xml.elements.each('/workbook/datasources/datasource') do |ds|
    name = ds.attributes['name'].to_s
    next if name.empty? || name == 'Parameters' || name.start_with?('Parameters ')
    conns = []
    ds.elements.each('.//connection') do |c|
      a = c.attributes
      cls = a['class'].to_s
      next if cls.empty? || cls == 'federated' # wrapper; real conns are nested
      conns << {
        'class'    => cls,
        'server'   => a['server'],
        'dbname'   => a['dbname'],
        'schema'   => a['schema'],
        'filename' => a['filename']
      }.compact
    end
    out[name] = {
      'name'        => name,
      'caption'     => ds.attributes['caption'] || name,
      'connections' => conns.uniq
    }
  end
  out
end

def route_blend(primary_conns, secondary_conns)
  same = primary_conns.any? do |pc|
    secondary_conns.any? do |sc|
      pc['class'] == sc['class'] && pc['server'].to_s == sc['server'].to_s &&
        (pc['dbname'].nil? || sc['dbname'].nil? || pc['dbname'] == sc['dbname'] ||
         pc['dbname'].to_s.casecmp(sc['dbname'].to_s).zero?)
    end
  end
  return 'same-warehouse-repoint' if same
  s_classes = secondary_conns.map { |c| c['class'] }
  return 'materialize-via-vds' if s_classes.any? { |c| FILE_CONN_CLASSES.include?(c) } ||
                                  s_classes.empty?
  return 'materialize-via-vds' unless s_classes.any? { |c| WAREHOUSE_CONN_CLASSES.include?(c) }
  'flag-unreachable'
end

ROUTE_BLURB = {
  'same-warehouse-repoint' => 'both sources resolve to the SAME warehouse — emit ONE DM with both '                               'sources as elements + a relationship on the linking fields; repoint '                               'connectionId by deep-walking the spec (incl. joins[].left/right nesting)',
  'materialize-via-vds'    => 'secondary is not in the warehouse — run the tableau-vds-to-cdw skill '                               'to land it in the primary\'s warehouse FIRST, then convert as a '                               'same-warehouse blend',
  'flag-unreachable'       => 'secondary lives in a different live system — blend stays MANUAL; '                               'use the linking-field report in blend-plan.json to wire it post-publish'
}.freeze

def detect_blends(xml)
  return [[], nil] if xml.nil?
  ds_info = datasource_connections(xml)
  blends = []
  xml.elements.each('//worksheet') do |ws|
    ws_name = ws.attributes['name']
    used = ws.elements.to_a('.//view/datasources/datasource')
             .map { |d| d.attributes['name'] }.compact
             .select { |n| ds_info.key?(n) }
    next unless used.length >= 2
    deps = {}
    ws.elements.each('.//datasource-dependencies') do |dd|
      dsn = dd.attributes['datasource']
      next unless dsn
      caps = dd.elements.to_a('.//column').map do |c|
        c.attributes['caption'] || c.attributes['name'].to_s.gsub(/^\[|\]$/, '')
      end
      deps[dsn] = ((deps[dsn] || []) + caps).uniq
    end
    primary = used.first
    used[1..].each do |sec|
      next unless deps.key?(sec) && !deps[sec].empty? # must pull fields from it
      linking = (deps[primary] || []) & (deps[sec] || [])
      route = route_blend(ds_info[primary]['connections'], ds_info[sec]['connections'])
      blends << {
        'worksheet'        => ws_name,
        'primary'          => primary,
        'primary_caption'  => ds_info[primary]['caption'],
        'secondary'        => sec,
        'secondary_caption'=> ds_info[sec]['caption'],
        'linking_fields'   => linking,
        'secondary_fields' => deps[sec],
        'route'            => route,
        'recommendation'   => ROUTE_BLURB[route]
      }
    end
  end
  return [[], nil] if blends.empty?
  features = blends.group_by { |b| b['route'] }.map do |route, rs|
    {
      name:   "Data blending (#{route})",
      # A secondary that must be landed or cannot be reached is not merely
      # advisory: neither runtime can build faithful Sigma semantics yet.
      status: route == 'same-warehouse-repoint' ? :hint : :unhandled,
      count:  rs.length,
      blurb:  "#{ROUTE_BLURB[route]}. Worksheets: #{rs.map { |b| b['worksheet'] }.uniq.join(', ')}. "               'Full linking-field report in blend-plan.json; decision tree in refs/blending.md ([bead]).',
      worksheets: rs.map { |b| b['worksheet'].to_s }.uniq.sort # E9.6/A2 scope attribution
    }
  end
  [features, { 'datasources' => ds_info.values, 'blends' => blends }]
end

# --- Union datasources (W2.16) ----------------------------------------------
# The converter (converter/tableau.mjs) emits the documented Sigma union
# source for a ROOT-level wildcard union (>=2 derivable member tables + >=1
# metadata output column): one warehouse-table element per member + an
# elementId-sourced union element (auto-named "Union of N Sources" by the
# API). Anything else — a root union missing members/columns, a union with
# any NON-TABLE member (custom-SQL text / nested union: emitting only the
# table members would silently subset the rows), or a union NESTED inside a
# join tree (the join branch refuses via collectTables rather than flatten
# it away) — the converter REFUSES loudly (named warning, NO elements
# emitted). Before W2.16 a unioned datasource converted to NOTHING,
# silently: the worst defect class under the program's rules.
# TWO rows so the handled shape never false-trips the ❌ gate:
#   :hint      — root wildcard union the converter emits (VERIFY matches[])
#   :unhandled — underivable/mixed/nested union (❌ named refusal; drives
#                the orchestrator's exit-11 gap stop, refuse-don't-guess)
# Derivability here MIRRORS the converter's own test (every member a plain
# table && members>=2 && cols>=1 at the connection root) so scan and
# emission can't drift apart silently — the union-wildcard-seed corpus
# checks.sh pins both against the same .twb.
def detect_unions(xml)
  return [] if xml.nil?
  emitted = []
  refused = []
  xml.elements.each('/workbook/datasources/datasource') do |ds|
    ds_name = ds.attributes['name'].to_s
    next if ds_name == 'Parameters' || ds_name.start_with?('Parameters ')
    sheets = []
    xml.elements.each('//worksheet') do |ws|
      used = ws.elements.to_a('.//view/datasources/datasource').map { |d| d.attributes['name'] }
      sheets << ws.attributes['name'].to_s if used.include?(ds_name) && ws.attributes['name']
    end
    # Output columns the converter can derive: unique metadata-record remote
    # names minus Tableau's union-provenance bookkeeping (Sheet / Table Name).
    cols = 0
    seen = Set.new
    ds.elements.each('.//metadata-record') do |mr|
      next unless mr.attributes['class'].to_s == 'column'
      remote = mr.elements['remote-name']&.text.to_s.strip
      next if remote.empty? || seen.include?(remote.upcase)
      next if remote =~ /\A(Sheet|Table Name)\z/i
      seen << remote.upcase
      cols += 1
    end
    ds.elements.each('.//relation') do |rel|
      next unless rel.attributes['type'].to_s == 'union'
      root = rel.parent && rel.parent.name == 'connection'
      kids = rel.elements.to_a('relation')
      members = kids.count do |r|
        r.attributes['type'].to_s == 'table' && !r.attributes['table'].to_s.empty?
      end
      # Fix-pass: members that are NOT plain tables (custom-SQL text, nested
      # union, join). The converter refuses the whole union rather than emit
      # a silent SUBSET of only its table members — mirror that refusal here
      # (a missing type attr defaults to 'table', like the converter's attr()).
      non_table = kids.count do |r|
        t = r.attributes['type'].to_s
        !t.empty? && t != 'table'
      end
      entry = { ds: ds_name, sheets: sheets.uniq.sort,
                nested: !root, members: members, cols: cols, non_table: non_table }
      if root && non_table.zero? && members >= 2 && cols >= 1
        emitted << entry
      else
        refused << entry
      end
    end
  end
  feats = []
  unless emitted.empty?
    f = {
      name:   'Union datasource (wildcard, converter-emitted)',
      status: :hint,
      count:  emitted.length,
      blurb:  'Root-level union → Sigma union source: one warehouse-table element per member + an ' \
              'elementId-sourced union element (auto-named "Union of N Sources" — a spec-set name breaks ' \
              'self-referential column validation; rename in the UI). Emission assumes SAME-NAME columns ' \
              'across members (wildcard union): VERIFY matches[] and hand-edit for renamed/missing member ' \
              'columns (null for a member lacking the column). Datasources: ' +
              emitted.map { |e| e[:ds] }.uniq.join(', ') + '.'
    }
    ws = emitted.flat_map { |e| e[:sheets] }.uniq.sort
    f[:worksheets] = ws unless ws.empty? # empty = unknown → omit key, fail open
    feats << f
  end
  unless refused.empty?
    f = {
      name:   'Union datasource (underivable / nested — NOT converted)',
      status: :unhandled,
      count:  refused.length,
      blurb:  'Union the converter REFUSES loudly (named warning, NO elements emitted — silent loss is ' \
              'dead): emission needs a ROOT-level union of ≥2 derivable member tables and ≥1 metadata ' \
              'column with EVERY member a plain table; non-table members (custom SQL / nested union) and ' \
              'unions nested inside a join tree are refused, never silently subset. Route: model as a ' \
              'Custom SQL UNION ALL element, or convert the member tables and re-point sources ' \
              'post-publish. ' +
              refused.map { |e|
                reason = if e[:nested] then 'nested'
                         elsif e[:non_table].to_i > 0 then "#{e[:non_table]} non-table member(s)"
                         else "#{e[:members]} member(s)/#{e[:cols]} column(s)"
                         end
                "#{e[:ds]} (#{reason})"
              }.join(', ') + '.'
    }
    ws = refused.flat_map { |e| e[:sheets] }.uniq.sort
    f[:worksheets] = ws unless ws.empty?
    feats << f
  end
  feats
end

# Detect the "N independent datasources feeding different worksheets" case —
# DISTINCT from a Tableau blend (2 sources on ONE sheet, handled by
# detect_blends). Here different sheets have different PRIMARY datasources. The
# LOCAL converter (converter/tableau.mjs) collapses every worksheet onto the
# primary datasource and silently drops the other sources' columns/calcs; the
# workbook POST then fails with unresolved [Master/...] refs (see
# a real multi-datasource workbook). Emit an ❌-unhandled gap so migrate-tableau
# HARD-STOPS at the gap gate with the table/sheet breakdown, instead of posting
# a doomed DM. Fixed for real by the multi-element DM path (Tier 2).
#
# Trigger — ALL must hold:
#   - >=2 real datasources (Parameters excluded)
#   - >=2 of them are each the PRIMARY (first <view> datasource — same
#     convention as detect_blends) of at least one worksheet
#   - at least one pair of those primaries is NOT linked by a blend. A
#     workbook whose extra datasources are secondary-only never triggers
#     (they are never primary — that is the blend case, blend-plan.json).
#
# ONE detection pass feeds THREE outputs:
#   - the ❌-unhandled gap-report row (drives the orchestrator's exit-11 stop)
#   - the gaps-JSON `multi_datasource` detail (datasource→worksheet breakdown)
#   - multi-ds-plan.json next to the gaps report (the per-datasource ROUTING
#     table for the multi-element DM path — shape is a CONTRACT, keep stable):
#       { "independent": true,
#         "datasources": [ { "name", "caption", "connection_class",
#                            "table" ("db.schema.table" or null — null for
#                            sqlproxy; hydration resolves published sources
#                            later), "sqlproxy" (true|false),
#                            "worksheets" [...], "dashboards" [...] } ] }

# Best-effort db.schema.table per datasource from its first table relation.
# nil for Custom SQL (type='text') and for published stubs (table='[sqlproxy]').
def datasource_table_refs(xml)
  out = {}
  xml.elements.each('/workbook/datasources/datasource') do |ds|
    name = ds.attributes['name'].to_s
    next if name.empty? || name == 'Parameters' || name.start_with?('Parameters ')
    conn = nil
    ds.elements.each('.//connection') do |c|
      cls = c.attributes['class'].to_s
      next if cls.empty? || cls == 'federated' # wrapper; real conns are nested
      conn ||= c
    end
    rel = nil
    ds.elements.each('.//relation') do |r|
      next unless r.attributes['type'].to_s == 'table' && r.attributes['table']
      next if r.attributes['table'].to_s == '[sqlproxy]' # published-source stub
      rel ||= r
    end
    next out[name] = nil if rel.nil?
    parts = rel.attributes['table'].to_s.scan(/\[([^\]]+)\]/).flatten
    parts = [rel.attributes['table'].to_s.gsub(/[\[\]]/, '')] if parts.empty?
    db  = conn && conn.attributes['dbname']
    sch = conn && conn.attributes['schema']
    full = case parts.length
           when 3 then parts
           when 2 then [db, *parts]           # [SCHEMA].[TABLE] + conn dbname
           else        [db, sch, *parts]      # [TABLE] + conn dbname/schema
           end
    ref = full.compact.reject { |p| p.to_s.empty? }.join('.')
    out[name] = ref.empty? ? nil : ref
  end
  out
end

def detect_multi_datasource(xml, blend_plan = nil)
  return [nil, nil, nil] if xml.nil?
  ds_info = datasource_connections(xml)
  return [nil, nil, nil] if ds_info.size < 2

  # primary per worksheet = FIRST real datasource in its <view> list
  primaries = Hash.new { |h, k| h[k] = [] } # ds name => [worksheet, ...]
  xml.elements.each('//worksheet') do |ws|
    ws_name = ws.attributes['name']
    used = ws.elements.to_a('.//view/datasources/datasource')
             .map { |d| d.attributes['name'] }.compact
             .select { |n| ds_info.key?(n) }
    next if used.empty? || ws_name.nil?
    primaries[used.first] << ws_name unless primaries[used.first].include?(ws_name)
  end
  return [nil, nil, nil] if primaries.size < 2 # single-primary workbook (incl. pure blends) — fine

  # Primaries linked by a blend are NOT independent of each other — a primary
  # set that is fully blend-linked stays on the blend path (blend-plan.json).
  blend_pairs = Set.new
  ((blend_plan && blend_plan['blends']) || []).each do |b|
    blend_pairs << [b['primary'], b['secondary']].sort
  end
  independent = primaries.keys.combination(2).any? { |pair| !blend_pairs.include?(pair.sort) }
  return [nil, nil, nil] unless independent

  # ❌-unhandled detail: the datasource→sheet breakdown the orchestrator's
  # exit-11 gap stop prints (gaps JSON `multi_datasource`).
  detail = primaries.keys.map do |n|
    { 'datasource'  => n,
      'caption'     => ds_info[n]['caption'],
      'connections' => ds_info[n]['connections'],
      'worksheets'  => primaries[n].uniq.sort }
  end

  # Routing plan (multi-ds-plan.json): dashboards containing each worksheet
  # (dashboard zone name refs) + warehouse table refs + published-source flags.
  ws_dashboards = Hash.new { |h, k| h[k] = [] }
  xml.elements.each('/workbook/dashboards/dashboard') do |d|
    dname = d.attributes['name']
    next unless dname
    d.elements.each('.//zone') do |z|
      zn = z.attributes['name']
      ws_dashboards[zn] << dname if zn && !ws_dashboards[zn].include?(dname)
    end
  end
  tables = datasource_table_refs(xml)
  entries = primaries.map do |ds_name, sheets|
    conns = ds_info[ds_name]['connections']
    sqlproxy = conns.any? { |c| c['class'] == 'sqlproxy' }
    {
      'name'             => ds_name,
      'caption'          => ds_info[ds_name]['caption'],
      'connection_class' => (conns.first || {})['class'],
      'table'            => sqlproxy ? nil : tables[ds_name],
      'sqlproxy'         => sqlproxy,
      'worksheets'       => sheets,
      'dashboards'       => sheets.flat_map { |w| ws_dashboards[w] }.uniq
    }
  end

  # The row NAME is a stable scout-ledger key — the vendored converter no
  # longer collapses (it builds one element set per datasource) and
  # build-charts routes outlier-datasource charts onto per-datasource
  # sub-masters. What routing cannot move: charts that need a window / LOD /
  # two-stage helper (they stay on the master — wrong numbers) and sources
  # with no warehouse table to build from. Only those keep the row blocking.
  dominant = entries.max_by { |e| e['worksheets'].size }
  helper_sheets = multi_ds_helper_sheets(xml, entries, dominant['name'])
  file_only = entries.select do |e|
    e['sqlproxy'] || ds_info[e['name']]['connections'].all? { |c| FILE_ONLY_CONNECTION_CLASSES.include?(c['class']) }
  end
  routing_off = ENV['SIGMA_MULTI_DS_ROUTING'] == 'off'
  assigns = detail.map { |d| "#{d['caption']} → #{d['worksheets'].length} sheet(s)" }.join('; ')
  blurb = "Workbook spans #{primaries.size} INDEPENDENT datasources across worksheets (#{assigns}); not a " \
          'Tableau blend. The converter builds a multi-element data model (one element set per datasource) ' \
          "and build-charts routes the non-dominant sources' charts onto per-datasource sub-masters " \
          '(multi-ds-plan.json; route: multi-element DM (refs/multi-datasource.md)).'
  blockers = []
  blockers << 'multi-datasource routing is disabled (SIGMA_MULTI_DS_ROUTING=off)' if routing_off
  if file_only.any?
    blockers << "#{file_only.map { |e| e['caption'] }.join(', ')} " \
                'has no warehouse table to build from (published or file source — land it first)'
  end
  if helper_sheets.any?
    blockers << "these non-dominant-datasource sheets plot window/LOD calcs that routing does not move off " \
                "the master: #{helper_sheets.first(8).join(', ')}#{helper_sheets.length > 8 ? ', …' : ''}"
  end
  if blockers.empty?
    blurb += ' Every chart is routable, so this is a review item, not a stop.'
    feat = { name: MULTI_DS_GAP_NAME, status: :hint, count: primaries.size, blurb: blurb }
  else
    blurb += " Needs work: #{blockers.join('; ')}."
    feat = { name: MULTI_DS_GAP_NAME, status: :unhandled, count: primaries.size, blurb: blurb }
    # Scope attribution only when the helper sheets are the WHOLE problem; a
    # source-level blocker affects every sheet (no key → fail open).
    feat[:worksheets] = helper_sheets if file_only.empty? && !routing_off
  end
  [feat, detail, { 'independent' => true, 'datasources' => entries }]
end

MULTI_DS_GAP_NAME = 'Multiple independent datasources (converter collapses to primary)'
# Every class the extract-landing route already treats as file/SaaS-backed,
# plus the remaining non-warehouse ones.
FILE_ONLY_CONNECTION_CLASSES = (FILE_CONN_CLASSES + %w[msaccess dataengine]).uniq.freeze
# Calcs build-charts translates through a helper / window plan, which it
# never re-sources onto a sub-master.
MULTI_DS_HELPER_RE = /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b|\b(?:LOOKUP|PREVIOUS_VALUE|WINDOW_[A-Z]+|RUNNING_[A-Z]+|RANK(?:_[A-Z]+)?|TOTAL|INDEX|FIRST|LAST|SIZE)\s*\(/i

# Dashboard sheets of the NON-dominant datasources that plot a calc which is,
# or is built on, a window / LOD calc.
def multi_ds_helper_sheets(xml, entries, dominant_name)
  outliers = entries.reject { |e| e['name'] == dominant_name }.each_with_object({}) { |e, h| h[e['name']] = e['worksheets'] }
  return [] if outliers.empty?
  plotted = plotted_calc_contexts(xml)
  sheets = Set.new
  xml.elements.each('/workbook/datasources/datasource') do |ds|
    ds_name = ds.attributes['name'].to_s
    next unless outliers.key?(ds_name)
    formulas = {}
    by_caption = {}
    ds.elements.each('column') do |col|
      f = col.elements['calculation']&.attributes&.[]('formula')
      next unless f
      formulas[col.attributes['name'].to_s.downcase] = f
      by_caption["[#{col.attributes['caption'] || col.attributes['name']}]".downcase] = col.attributes['name'].to_s.downcase
    end
    memo = {}
    needs = lambda do |key, depth = 0|
      return memo[key] if memo.key?(key)
      memo[key] = false # cycle guard
      f = formulas[key].to_s
      memo[key] = f.match?(MULTI_DS_HELPER_RE) ||
                  (depth < 20 && formula_field_refs(f).any? do |ref|
                    dep = formulas.key?(ref.downcase) ? ref.downcase : by_caption[ref.downcase]
                    dep && needs.call(dep, depth + 1)
                  end)
    end
    plotted.each do |pkey, placement|
      pds, internal = pkey.split("\0", 2)
      next unless pds == ds_name && needs.call(internal.to_s.downcase)
      Array(placement['worksheets']).each { |w| sheets << w if outliers[ds_name].include?(w) }
    end
  end
  sheets.to_a.sort
end

# Detect the SINGLE-datasource multi-table relationship model (2020.2+
# <object-graph>, the "noodle") — the shape the field failure proved invisible:
# detect_multi_datasource returns early at ds_info.size < 2, so a 6-table
# one-datasource workbook printed a reassuring "Datasources: 1" and sailed past
# Phase 0 while the converter mis-elected a dimension as the fact and baked
# wrong-FROM helper SQL. ONE detection pass feeds THREE outputs (same contract
# style as detect_multi_datasource):
#   - gap-report row(s): ✅-auto when every relationship carries a wire-able
#     serialized equality key (a fully-wired noodle must NOT stop), ❌-unhandled
#     when any relationship lacks one (no key / computed-only / range-only /
#     unresolved endpoint) or any logical table is untouched by relationships —
#     the DISCONNECTED-TABLES outcome. The ❌ row drives migrate-tableau's
#     exit-11 stop with the per-relationship punch list in the blurb.
#   - gaps-JSON `object_model` detail (per-relationship status).
#   - object-graph-plan.json sidecar next to the report (fact candidate by
#     relationship degree + the relationship wiring table) — the operator's
#     manual-wiring punch list, modeled on multi-ds-plan.json.
# Raw-text based (handles both plain and _.fcp.-wrapped spellings); works on
# the same content string the INVENTORY scan uses.
def detect_object_model(content)
  features = []
  detail = []
  plan_entries = []
  # Split into datasource chunks (same seam dominant_fact_table uses); only
  # real datasource DEFINITIONS carry <object-graph>/<relation type='collection'>.
  content.split(/<datasource\s/).drop(1).each do |chunk|
    attrs = chunk[/\A([^>]*)>/, 1].to_s
    ds_name = attrs[/\bname='([^']*)'/, 1]
    next if ds_name.nil? || ds_name == 'Parameters' || ds_name.start_with?('Parameters ')
    graph_open = chunk[/<((?:[^<>\s]*\.true\.\.\.)?object-graph)[\s>]/, 1]
    next unless graph_open
    graph = chunk[%r{<#{Regexp.escape(graph_open)}[\s>].*?</#{Regexp.escape(graph_open)}>}m] || chunk
    # Logical tables: object-graph <object id=...> entries; fall back to the
    # physical collection children when <objects> is absent.
    object_ids = graph.scan(/<object\s[^>]*\bid='([^']+)'/).flatten
    rel_names = chunk.scan(/<(?:[^<>\s]*\.\.\.)?relation\s[^>]*?\bname='([^']+)'[^>]*?\btype='(?:table|text)'/m).flatten.uniq
    logical = object_ids.any? ? object_ids.map { |o| o.sub(/_[0-9A-Fa-f]{16,}\z/, '') } : rel_names
    logical = logical.uniq
    next if logical.size <= 1 # single object = legacy-migrated join model — flat table, no noodle semantics
    rel_blocks = graph.scan(%r{<relationship>.*?</relationship>}m)
    # Per-relationship wiring status (mirrors what the converter will do).
    rel_rows = rel_blocks.map do |b|
      eps = b.scan(/<(?:[^<>\s]*\.\.\.)?(first|second)-end-point\b[^>]*\bobject-id='([^']+)'/)
      first = eps.find { |k, _| k == 'first' }&.last.to_s
      second = eps.find { |k, _| k == 'second' }&.last.to_s
      base = ->(oid) { oid.sub(/_[0-9A-Fa-f]{16,}\z/, '') }
      resolves = ->(oid) { logical.any? { |l| l == base.call(oid) || oid == l || oid.start_with?("#{l}_") } }
      has_eq = b =~ /<expression\s[^>]*op='='/
      eq_count = b.scan(/<expression\s[^>]*op='='/).size
      phys_ops = b.scan(/<expression\s[^>]*op='\[[^\]']+\]'/).size
      non_eq = b =~ /op='(?:&lt;|&gt;)=?'|op='!='|op='&lt;&gt;'/
      status =
        if first.empty? || second.empty? || !resolves.call(first) || !resolves.call(second)
          'endpoint-unresolved'
        elsif has_eq && phys_ops >= 2 && phys_ops < eq_count * 2
          'partial-computed-key'
        elsif has_eq && phys_ops >= 2
          'wired'
        elsif has_eq
          'computed-only-key'
        elsif non_eq
          'non-equality-key'
        else
          'no-serialized-key'
        end
      keys = b.scan(/<expression\s[^>]*op='\[([^\]']+)\]'/).flatten.each_slice(2).to_a
      { 'first' => base.call(first), 'second' => base.call(second), 'status' => status,
        'keys' => keys }
    end
    degree = Hash.new(0)
    rel_rows.each { |r| degree[r['first']] += 1; degree[r['second']] += 1 }
    ranked = degree.sort_by { |_k, v| -v }
    fact_candidate = ranked[0] && (ranked[1].nil? || ranked[0][1] > ranked[1][1]) ? ranked[0][0] : nil
    untouched = logical.reject { |l| degree.key?(l) }
    unwired = rel_rows.reject { |r| r['status'] == 'wired' }
    caption = attrs[/\bcaption='([^']*)'/, 1] || ds_name
    plan_entries << {
      'datasource' => ds_name,
      'caption' => caption,
      'objects' => logical,
      'fact_candidate' => fact_candidate,
      'relationships' => rel_rows,
      'untouched_objects' => untouched
    }
    detail << { 'datasource' => ds_name, 'caption' => caption, 'objects' => logical.size,
                'relationships' => rel_rows.size, 'unwired' => unwired.size,
                'untouched_objects' => untouched }
    if unwired.any? || untouched.any? || rel_rows.empty?
      punch = []
      punch.concat(unwired.map { |r| "#{r['first']}↔#{r['second']}: #{r['status']}" })
      punch.concat(untouched.map { |t| "#{t}: no relationship touches it" })
      punch = ['ALL: no <relationship> entries serialized'] if rel_rows.empty?
      blurb = "One datasource, #{logical.size} logical tables (2020.2+ relationship/object-model), but the DM " \
              "would contain DISCONNECTED tables: #{punch.join('; ')}. The converter refuses to guess join keys " \
              '(refuse-don\'t-guess) — each listed pair needs MANUAL wiring: add the relationship LEFT from the ' \
              'fact (many) side to the unique dim side on the correct key column pair, then re-validate. ' \
              "Fact candidate by relationship degree: #{fact_candidate || 'AMBIGUOUS — verify'}. Full wiring " \
              'table: object-graph-plan.json (this directory). To proceed after wiring: patch dm-spec.json and ' \
              're-enter the gated spine via --reuse-dm (never hand-POST).'
      features << { name: 'Object-model relationships missing serialized join keys (disconnected tables)',
                    status: :unhandled, count: (unwired.size + untouched.size).clamp(1, 99), blurb: blurb }
    else
      blurb = "One datasource, #{logical.size} logical tables joined by #{rel_rows.size} relationship(s), all " \
              'carrying serialized equality keys — the converter wires them and ELECTS the fact by evidence ' \
              "(relationship degree → measure columns → naming → width; candidate here: #{fact_candidate || 'ambiguous'}). " \
              'VERIFY the "Object-model fact election" line in the converter output names the true fact — every ' \
              'LOD/Top-N/window helper builds FROM it (override: --fact-table). Wiring table: object-graph-plan.json.'
      features << { name: 'Relationship (object-model / noodle) datasource — keys serialized',
                    status: :auto, count: logical.size, blurb: blurb }
    end
  end
  return [[], nil, nil] if plan_entries.empty?
  [features, detail, { 'object_model' => true, 'datasources' => plan_entries }]
end

# --- Field-usage + calc-dependency analysis --------------------------------
# Works purely from the .twb — no VDS/metadata graph needed. Produces field
# statistics (source/calc/param split, used vs dead), calc classification
# (simple vs nested by dependency, LOD, table-calc), orphaned worksheets,
# duplicate captions (Sigma name-collision risk), and a per-object component
# inventory (the migration punch-list). `doc` is the TwbXml tree (field defs +
# worksheet names); `content` is the raw .twb string (used for the reference-
# region scans, since TwbXml exposes no node serializer).
FORMULA_AUDIT_STATUSES = %w[spec verify chart_only rls not_converted unmapped].freeze
FORMULA_AUDIT_TRANSLATED = %w[spec verify chart_only rls].freeze
FORMULA_AUDIT_HELPER = File.expand_path('formula-audit.mjs', __dir__)

def formula_field_refs(formula)
  masked, tokens = CalcCoverage.mask(formula.to_s)
  CalcCoverage.field_refs(masked, tokens)[:fields].uniq
end

# Build one calculation inventory per real datasource. Dependency resolution is
# deliberately restricted to calculated-field definitions in the SAME
# datasource. An ordinary unresolved caption such as [Legacy Revenue] may be a
# physical warehouse field omitted from the Tableau metadata and is therefore
# not called an orphan. Only Tableau's generated [Calculation_*] namespace is
# safe to identify as a missing internal calc definition.
def worksheet_bodies(content)
  content.to_s.scan(%r{<worksheet\s[^>]*?name=(?:'([^']*)'|"([^"]*)")[^>]*>(.*?)</worksheet>}m)
         .each_with_object({}) { |(sq, dq, body), h| h[CGI.unescapeHTML((sq || dq).to_s)] = CGI.unescapeHTML(body.to_s) }
end

# Worksheets whose section references a calc's internal name, in either the
# bracketed column form ([Calculation_1]) or a column-instance form
# ([none:Calculation_1:nk]). Bounded so Calculation_1 never matches
# Calculation_12.
def calc_name_referenced?(text, internal_name)
  bare = internal_name.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
  !bare.empty? && text.match?(/(?<![\w])#{Regexp.escape(bare)}(?![\w])/)
end

def calc_worksheet_refs(calcs, bodies)
  calcs.each_with_object({}) do |calc, h|
    hits = bodies.select { |_, body| calc_name_referenced?(body, calc['internal_name']) }.keys.sort
    h[calc['internal_name']] = hits if hits.any?
  end
end

def datasource_object_usage_text(datasource)
  values = []
  visit = nil
  visit = lambda do |element, inside_usage|
    name = element.name.to_s.split(':').last
    usage = inside_usage || %w[filter extract-filter group groupfilter set].include?(name) ||
            (name == 'calculation' && element.attributes['class'].to_s.match?(/(?:set|group)/i))
    if usage
      if element.respond_to?(:node)
        element.node.attribute_nodes.each { |attribute| values << attribute.value.to_s }
        element.node.xpath('text()').each { |text| values << text.content.to_s }
      else
        element.attributes.each_attribute { |attribute| values << attribute.value.to_s }
        element.texts.each { |text| values << text.value.to_s }
      end
    end
    element.elements.each('*') { |child| visit.call(child, usage) }
  end
  visit.call(datasource, false)
  values.join("\n")
end

def calculation_inventory(doc, content)
  ref_region = CGI.unescapeHTML(content.split('</datasources>', 2)[1] || content)
  bodies = worksheet_bodies(content)
  inputs = []
  datasource_rows = []

  doc.elements.to_a('/workbook/datasources/datasource').each_with_index do |ds, ds_index|
    ds_name = ds.attributes['name'].to_s
    next if ds_name == 'Parameters' || ds_name.start_with?('Parameters ')

    definitions = {}
    calcs = []
    columns_by_guid = {}
    ds.elements.each('column') do |col|
      internal = col.attributes['name'].to_s
      next if internal.empty? || internal.include?('__tableau_internal_object_id__')
      formula = col.elements['calculation']&.attributes&.[]('formula')
      row = {
        'internal_name' => internal,
        'caption' => (col.attributes['caption'] || internal).to_s,
        'formula' => formula
      }
      definitions[internal.downcase] = row
      definitions["[#{row['caption']}]".downcase] = row
      calcs << row if formula
      # Same shape as parse-twb-layout's meta['columns_by_guid'], which the
      # chart translators deref calc refs / resolve GUID refs through.
      cbg = { 'caption' => row['caption'].sub(/\A\[(.*)\]\z/, '\1').strip }
      cbg['formula'] = formula if formula
      columns_by_guid[internal.sub(/\A\[/, '').sub(/\]\z/, '')] = cbg
    end

    by_caption = Hash.new { |h, k| h[k] = [] }
    calcs.each { |calc| by_caption["[#{calc['caption']}]".downcase] << calc }
    calc_by_internal = {}
    calcs.each { |calc| calc_by_internal[calc['internal_name'].downcase] = calc }
    graph = {}
    orphan_refs = []

    calcs.each_with_index do |calc, calc_index|
      key = calc['internal_name']
      graph[key] = []
      formula_field_refs(calc['formula']).each do |ref|
        target = calc_by_internal[ref.downcase]
        target ||= by_caption[ref.downcase].first if by_caption[ref.downcase].length == 1
        if target
          graph[key] << target['internal_name']
        elsif ref =~ /\A\[Calculation[_-]/i && !definitions.key?(ref.downcase)
          orphan_refs << {
            'datasource' => ds_name,
            'calculation' => calc['caption'],
            'internal_name' => key,
            'reference' => ref
          }
        end
      end
      graph[key] = graph[key].uniq.sort
      inputs << {
        'id' => "#{ds_index}:#{calc_index}",
        'datasource_index' => ds_index,
        'datasource' => ds_name,
        'datasource_caption' => (ds.attributes['caption'] || ds_name).to_s,
        'internal_name' => key,
        'caption' => calc['caption'],
        'formula' => calc['formula']
      }
    end

    # Tarjan SCCs: every multi-node SCC is a cycle; a one-node SCC is a cycle
    # only when the calculation directly references itself.
    index = 0
    indices = {}
    low = {}
    stack = []
    on_stack = {}
    components = []
    visit = nil
    visit = lambda do |node|
      indices[node] = index
      low[node] = index
      index += 1
      stack << node
      on_stack[node] = true
      graph.fetch(node, []).each do |neighbor|
        unless indices.key?(neighbor)
          visit.call(neighbor)
          low[node] = [low[node], low[neighbor]].min
        end
        low[node] = [low[node], indices[neighbor]].min if on_stack[neighbor]
      end
      return unless low[node] == indices[node]
      component = []
      loop do
        member = stack.pop
        on_stack.delete(member)
        component << member
        break if member == node
      end
      components << component
    end
    graph.keys.sort.each { |node| visit.call(node) unless indices.key?(node) }
    captions = calcs.each_with_object({}) { |calc, h| h[calc['internal_name']] = calc['caption'] }
    cycles = components.select { |c| c.length > 1 || graph.fetch(c.first, []).include?(c.first) }
                       .map { |c| c.map { |n| captions[n] || n }.sort }
                       .sort_by { |c| c.join("\0") }

    # Bare, bounded name match: a worksheet may carry only the column-instance
    # form ([none:Calculation_1:nk]), never the bracketed [Calculation_1].
    # Now that an unused refusal stops gating, a false "unused" would hide a
    # real stop.
    ds_usage = datasource_object_usage_text(ds)
    usage_text = "#{ref_region}\n#{ds_usage}"
    directly_used = calcs.map { |calc| calc['internal_name'] }
                         .select { |internal| calc_name_referenced?(usage_text, internal) }
                         .to_set
    used = directly_used.dup
    changed = true
    while changed
      changed = false
      used.to_a.each do |node|
        graph.fetch(node, []).each do |dependency|
          next if used.include?(dependency)
          used << dependency
          changed = true
        end
      end
    end
    unused = calcs.reject { |calc| used.include?(calc['internal_name']) }.map do |calc|
      {
        'datasource' => ds_name,
        'calculation' => calc['caption'],
        'internal_name' => calc['internal_name']
      }
    end

    datasource_rows << {
      'datasource_index' => ds_index,
      'name' => ds_name,
      'caption' => (ds.attributes['caption'] || ds_name).to_s,
      'calculation_cycles' => cycles,
      'orphan_internal_calculation_references' => orphan_refs.sort_by { |r| [r['calculation'], r['reference']] },
      'unused_calculations' => unused.sort_by { |r| [r['calculation'], r['internal_name']] },
      'columns_by_guid' => columns_by_guid,
      'dependency_graph' => graph,
      'calc_worksheets' => calc_worksheet_refs(calcs, bodies),
      # Calcs a datasource filter / set / group uses: they shape every sheet.
      'datasource_level_calcs' => calcs.map { |calc| calc['internal_name'] }
                                       .select { |internal| calc_name_referenced?(ds_usage, internal) }
    }
  end

  {
    'inputs' => inputs,
    'plotted' => plotted_calc_contexts(doc),
    'datasources' => datasource_rows,
    'calculation_cycles' => datasource_rows.flat_map do |ds|
      ds['calculation_cycles'].map { |cycle| { 'datasource' => ds['name'], 'calculations' => cycle } }
    end,
    'orphan_internal_calculation_references' => datasource_rows.flat_map { |ds| ds['orphan_internal_calculation_references'] },
    'unused_calculations' => datasource_rows.flat_map { |ds| ds['unused_calculations'] }
  }
end

# Where each calc is PLOTTED, keyed "<datasource name>\0<internal name>". Only
# these placements reach build-charts' calc translators: a chart axis (rows /
# cols → the chart yAxis path), a crosstab text value (encodings/text on a
# Text/Square pivot → the pivot-value path), or a Measure Values
# member (the :Measure Names filter → the multi-measure path). Tooltip, color,
# detail and KPI-only text never run them. Only worksheets placed on a
# dashboard are built (every worksheet when the workbook has no dashboards —
# parse-twb-layout synthesizes one per sheet).
SHELF_MEASURE_PREFIXES = %w[
  sum avg min max count countd cntd cnt ctd median med mdn stdev stdevp var varp attr usr pcto rtot
].freeze

def plotted_calc_contexts(doc)
  out = {}
  zone_names = doc.elements.to_a('/workbook/dashboards/dashboard//zone')
                  .map { |z| z.attributes['name'].to_s }.reject(&:empty?).to_set
  any_dashboard = !doc.elements.to_a('/workbook/dashboards/dashboard').empty?
  instance_re = /\[((?:[^\]]|\]\])+)\]\.\[((?:[^\]]|\]\])+)\]/
  field_name = lambda do |ref|
    token = ref.to_s.scan(/\[([^\]]+)\]/).flatten.last.to_s
    token.sub(/\A(?:[a-z]+:)+/i, '').sub(/:[a-z]{2}(?::\d+)?\z/i, '')
  end
  calc_formulas = {}
  doc.elements.each('/workbook/datasources/datasource') do |ds|
    ds_name = ds.attributes['name'].to_s
    ds.elements.each('.//column[@name]') do |column|
      calc = column.elements['calculation']
      next unless calc
      calc_formulas[[ds_name, field_name.call(column.attributes['name'])]] = calc.attributes['formula'].to_s
    end
  end
  note = lambda do |text, context, ws_name, pivot_scopes = {}, two_stage_text = false|
    text.to_s.scan(instance_re) do |ds, inst|
      body = inst.sub(/\A(?:[a-z]+:)+/i, '').sub(/:[a-z]{2}(?::\d+)?\z/i, '')
      next if body.start_with?(':') || body == 'Multiple Values'
      key = "#{ds}\0[#{body}]"
      entry = (out[key] ||= { 'contexts' => Set.new, 'worksheets' => Set.new })
      entry['contexts'] << context
      entry['worksheets'] << ws_name
      (entry['pivot_scopes'] ||= Set.new) << pivot_scopes[body] if pivot_scopes[body]
      entry['two_stage_text'] = true if two_stage_text
    end
  end
  doc.elements.to_a('/workbook/worksheets/worksheet').each do |ws|
    ws_name = ws.attributes['name'].to_s
    next if any_dashboard && !zone_names.include?(ws_name)
    rows_text = ws.elements['table/rows']&.text.to_s
    cols_text = ws.elements['table/cols']&.text.to_s
    shelves = [rows_text, cols_text]
    shelf_refs = shelves.map do |text|
      text.scan(instance_re).map do |ds, inst|
        role =
          if inst.match?(/\A:(?:Measure Names|Multiple Values|Measure Values)\z/i)
            :placeholder
          elsif SHELF_MEASURE_PREFIXES.include?(inst.split(':', 2).first.to_s.downcase)
            :measure
          else
            :dim
          end
        { 'datasource' => ds, 'instance' => inst, 'role' => role }
      end
    end
    shelf_fields = shelves.map do |text|
      text.scan(instance_re).map { |_ds, inst| field_name.call("[#{inst}]").downcase }.to_set
    end
    pivot_scopes = {}
    ws.elements.each('.//column-instance') do |ci|
      calc = field_name.call(ci.attributes['column'])
      next if calc.empty?
      tc = ci.elements.to_a('table-calc').find { |node| node.attributes['field'].nil? } ||
           ci.elements['table-calc']
      addr = tc && field_name.call(tc.attributes['ordering-field']).downcase
      pivot_scopes[calc] =
        if addr && shelf_fields[1].include?(addr)
          'row'
        elsif addr && shelf_fields[0].include?(addr)
          'column'
        else
          shelf_fields[1].include?(calc.downcase) ? 'column' : 'row'
        end
    end
    mark_class = ws.elements['.//pane/mark']&.attributes&.[]('class').to_s.downcase
    text_mark = %w[text square].include?(mark_class)
    automatic_mark = mark_class.empty? || mark_class == 'automatic'
    dim_counts = shelf_refs.map { |refs| refs.count { |ref| ref['role'] == :dim } }
    measure_names = shelves.any? { |text| text.match?(/\[:Measure Names\]/i) }
    measure_values = shelves.any? { |text| text.match?(/\[(?::)?(?:Multiple|Measure) Values\]/i) }
    worksheet_measure_refs = shelf_refs.flatten.select { |ref| ref['role'] == :measure }
    ws.elements.each('.//*[@column]') do |node|
      node.attributes['column'].to_s.scan(instance_re) do |ds, inst|
        if SHELF_MEASURE_PREFIXES.include?(inst.split(':', 2).first.to_s.downcase)
          worksheet_measure_refs << { 'datasource' => ds, 'instance' => inst, 'role' => :measure }
        end
      end
    end
    ws.elements.each('.//*[@member]') do |node|
      node.attributes['member'].to_s.scan(instance_re) do |ds, inst|
        if SHELF_MEASURE_PREFIXES.include?(inst.split(':', 2).first.to_s.downcase)
          worksheet_measure_refs << { 'datasource' => ds, 'instance' => inst, 'role' => :measure }
        end
      end
    end
    measure_names_crosstab = measure_names && dim_counts.sum >= 1 &&
                             worksheet_measure_refs.map { |ref| [ref['datasource'], ref['instance']] }.uniq.length >= 2
    is_crosstab = (text_mark && (dim_counts.all?(&:positive?) || measure_names_crosstab)) ||
                  (automatic_mark && measure_names_crosstab && !measure_values)
    is_kpi = (text_mark || automatic_mark) && !is_crosstab &&
             dim_counts.sum.zero? && worksheet_measure_refs.any?
    if is_crosstab
      text_encodings = ws.elements.to_a('.//encodings/text')
      shelf_values = shelf_refs.flatten.filter_map do |ref|
        [ref['datasource'], ref['instance']] if ref['role'] == :measure
      end
      value_refs = shelf_values
      if value_refs.empty?
        worksheet_datasources = ws.elements.to_a('.//datasource-dependencies')
                                  .map { |dep| dep.attributes['datasource'].to_s }
        worksheet_datasources += ws.elements.to_a('table/view/datasources/datasource')
                                   .map { |ds| ds.attributes['name'].to_s }
        value_refs = ws.elements.to_a('.//column-instance').each_with_object([]) do |ci, refs|
          derivation = ci.attributes['derivation'].to_s
          next unless ci.attributes['type'] == 'quantitative'
          next if derivation == 'None' || derivation.match?(/\A(?:Year|Quarter|Month|Week|Day|Hour)-Trunc\z/)
          column = field_name.call(ci.attributes['column'])
          next if refs.any? { |_ds, ref| ref == column }
          ds = worksheet_datasources.find { |name| calc_formulas.key?([name, column]) }
          refs << [ds.to_s, column]
        end
      end
      plans = value_refs.map do |ds, inst|
        formula = calc_formulas[[ds, field_name.call("[#{inst}]")]]
        formula && translate_window_calc(formula, {}, {})
      end
      two_stage_text = plans.any? &&
                       plans.all? { |plan| plan && plan['mode'] == 'two-stage' } &&
                       plans.map { |plan| plan['value_formula'] }.uniq.length == 1
      text_encodings.each do |enc|
        note.call(enc.attributes['column'], 'text', ws_name, pivot_scopes, two_stage_text)
      end
      shelf_values.each do |ds, inst|
        note.call("[#{ds}].[#{inst}]", 'text', ws_name, pivot_scopes, two_stage_text)
      end
    elsif !is_kpi && !text_mark
      shelf_refs.flatten.each do |ref|
        next unless ref['role'] == :measure
        note.call("[#{ref['datasource']}].[#{ref['instance']}]", 'axis', ws_name)
      end
    end
    ws.elements.each('.//filter') do |filter|
      next unless filter.attributes['column'].to_s.end_with?('[:Measure Names]')
      filter.elements.each('.//groupfilter') do |member|
        note.call(member.attributes['member'], 'measure_values', ws_name)
      end
    end
  end
  out.transform_values do |v|
    result = { 'contexts' => v['contexts'].to_a.sort, 'worksheets' => v['worksheets'].to_a.sort }
    result['pivot_scopes'] = v['pivot_scopes'].to_a.sort if v['pivot_scopes']&.any?
    result['two_stage_text'] = true if v['two_stage_text']
    result
  end
end

# Window plans each build path emits (anything else — 'manual', top-N filters —
# stays refused). The multi-measure chart path only emits 'inline'.
CHART_WINDOW_MODES = {
  'axis' => %w[inline inline-share two-stage],
  'text' => %w[inline inline-share],
  'measure_values' => %w[inline]
}.freeze

# The build emits whatever [Master/<name>] refs a translator leaves behind; that
# only resolves when <name> is a physical column or a calc the data model
# materializes under that caption. A ref to a refused / chart-only calc, a
# Tableau internal calc name, or a parameter would ship a broken column.
def chart_translation_refs_resolve?(names, calcs)
  names.all? do |name|
    next false if name.to_s.strip.empty? || name =~ /\AParameters?\b/i
    calc = calcs[name.downcase]
    calc.nil? || (calc['status'] == 'spec' && calc['caption'].casecmp?(name))
  end
end

# The build-path translation for one refused row, or nil. Mirrors the dispatch
# in build-charts-from-signals.rb: translate_window_calc first (every plotted
# context), then a single-level FIXED LOD on a chart axis (the two-stage helper;
# the pivot and KPI paths do not build it).
def chart_translation_for(row, placement, cbg, calcs)
  formula = row['formula'].to_s
  contexts = placement['contexts']
  plan = translate_window_calc(formula, {}, cbg)
  if plan
    modes = contexts.flat_map { |context| CHART_WINDOW_MODES.fetch(context, []) }.uniq
    modes << 'two-stage' if placement['two_stage_text']
    return nil unless modes.include?(plan['mode'])
    emitted = case plan['mode']
              when 'inline' then plan['formula']
              when 'inline-share'
                scope = placement.fetch('pivot_scopes', []).first || 'grand_total'
                plan['share_kind'] == 'percent_of_total' ? %(PercentOfTotal(#{plan['inner']}, "#{scope}")) : plan['inner']
              end
    refs = [emitted, plan['value_formula']].compact.join(' ').scan(%r{\[Master/([^\]]+)\]}).flatten
    return nil unless chart_translation_refs_resolve?(refs, calcs)
    return { 'translator' => 'translate_window_calc', 'mode' => plan['mode'], 'sigma_formula' => emitted,
             'note' => plan['note'] }
  end
  return nil unless contexts.include?('axis')
  lod = parse_fixed_lod(formula, cbg)
  inner = lod && lod_inner_ref(lod, {}, cbg)
  return nil unless inner
  refs = lod['dims'] + inner.scan(%r{\[Master/([^\]]+)\]}).flatten
  return nil unless chart_translation_refs_resolve?(refs, calcs)
  { 'translator' => 'parse_fixed_lod', 'mode' => 'two-stage-helper', 'sigma_formula' => nil,
    'note' => "FIXED [#{lod['dims'].join('], [')}] → hidden grouped helper element at chart grain" }
end

# A converter refusal (not_converted/unmapped) that build-charts-from-signals.rb
# translates natively where the calc is plotted is NOT a gap: reclassify it
# chart_only (the converter's "translated, needs chart context" status),
# keeping the converter's status and the chart translator as evidence. Runs
# AFTER learned rules. The Python runtime has no port of these translators, so
# it keeps refusing these (fail closed), like learned rules.
def apply_chart_translators_to_audit!(batch, inventory)
  plotted = inventory['plotted'] || {}
  sources = (inventory['datasources'] || []).each_with_object({}) { |ds, h| h[ds['datasource_index']] = ds }
  formulas = batch.fetch('formulas')
  calcs_by_ds = Hash.new { |h, k| h[k] = {} }
  formulas.each do |row|
    by_name = calcs_by_ds[row['datasource_index']]
    [row['internal_name'], row['caption']].each do |name|
      key = name.to_s.sub(/\A\[/, '').sub(/\]\z/, '').downcase
      by_name[key] ||= { 'status' => row['status'], 'caption' => row['caption'].to_s.sub(/\A\[(.*)\]\z/, '\1') }
    end
  end
  changed = false
  formulas.each do |row|
    next unless %w[not_converted unmapped].include?(row['status'])
    placement = plotted["#{row['datasource']}\0#{row['internal_name']}"]
    next unless placement
    cbg = sources.dig(row['datasource_index'], 'columns_by_guid') || {}
    hit = chart_translation_for(row, placement, cbg, calcs_by_ds[row['datasource_index']])
    next unless hit
    row['converter_status'] = row['status']
    row['status'] = 'chart_only'
    row['sigma_formula'] = hit['sigma_formula'] if hit['sigma_formula']
    row['chart_translator'] = hit.reject { |k, _| k == 'sigma_formula' }.merge(placement)
    changed = true
  end
  recount_formula_audit!(batch) if changed
  batch
end

# Where each still-refused formula actually reaches. A refusal nothing uses
# (the inventory's own transitive unused set) is marked `unused` and never
# gates. Otherwise the calcs built on top of it inherit the break — they pass
# the converter (`spec`) yet carry a dangling ref to the refused calc — so
# they get `blocked_by`, and the refused row records its `dependents` plus
# the worksheets that use it directly or through any dependent (the gate's
# scope filter reads those; a row with none fails open).
def annotate_refusal_reach!(batch, inventory)
  sources = (inventory['datasources'] || []).each_with_object({}) { |ds, h| h[ds['datasource_index']] = ds }
  unused = (inventory['unused_calculations'] || []).map { |u| [u['datasource'], u['internal_name']] }.to_set
  batch.fetch('formulas').group_by { |row| row['datasource_index'] }.each do |ds_index, rows|
    source = sources[ds_index] || {}
    graph = source['dependency_graph'] || {}
    calc_ws = source['calc_worksheets'] || {}
    ds_level = (source['datasource_level_calcs'] || []).to_set
    by_internal = rows.each_with_object({}) { |row, h| h[row['internal_name']] = row }
    reverse = Hash.new { |h, k| h[k] = [] }
    graph.each { |calc, deps| deps.each { |dep| reverse[dep] << calc } }
    rows.each do |row|
      next unless %w[not_converted unmapped].include?(row['status'])
      if unused.include?([row['datasource'], row['internal_name']])
        row['unused'] = true
        next
      end
      seen = Set.new
      queue = [row['internal_name']]
      until queue.empty?
        reverse[queue.shift].each { |dep| queue << dep if seen.add?(dep) }
      end
      seen.delete(row['internal_name'])
      dependents = seen.map { |name| by_internal[name] }.compact
      row['dependents'] = dependents.map { |d| d['caption'] }.uniq.sort if dependents.any?
      reach = [row['internal_name']] + seen.to_a
      if reach.any? { |name| ds_level.include?(name) }
        # A datasource-level use applies to every sheet: leave the row
        # unattributed so a scoped run fails open instead of dropping it.
        row['datasource_level'] = true
      else
        worksheets = reach.flat_map { |name| calc_ws[name] || [] }.uniq.sort
        row['worksheets'] = worksheets if worksheets.any?
      end
      dependents.each do |dep|
        next unless FORMULA_AUDIT_TRANSLATED.include?(dep['status'])
        dep['blocked_by'] = ((dep['blocked_by'] || []) + [row['caption']]).uniq.sort
      end
    end
  end
  batch
end

def recount_formula_audit!(batch)
  formulas = batch.fetch('formulas')
  counts = FORMULA_AUDIT_STATUSES.each_with_object({}) { |name, h| h[name] = 0 }
  formulas.each { |row| counts[row.fetch('status')] += 1 }
  converted = formulas.count { |row| FORMULA_AUDIT_TRANSLATED.include?(row['status']) }
  batch['counts'] = counts
  batch['converted'] = converted
  batch['coverage_pct'] = formulas.empty? ? 100.0 : (1000.0 * converted / formulas.length).round / 10.0
  batch
end

def run_formula_audit(inventory)
  node = ENV['NODE_BIN'].to_s.empty? ? 'node' : ENV['NODE_BIN']
  stdout, stderr, status = Open3.capture3(
    node, FORMULA_AUDIT_HELPER,
    stdin_data: JSON.generate('formulas' => inventory['inputs'])
  )
  unless status.success?
    detail = stderr.to_s.lines.first.to_s.strip
    raise "formula audit helper failed (exit #{status.exitstatus})#{detail.empty? ? '' : ": #{detail}"}"
  end
  batch = JSON.parse(stdout)
  apply_learned_rules_to_audit!(batch)
  apply_chart_translators_to_audit!(batch, inventory)
  annotate_refusal_reach!(batch, inventory)
  results_by_ds = batch.fetch('formulas').group_by { |row| row['datasource_index'] }

  datasources = inventory['datasources'].map do |source|
    rows = results_by_ds[source['datasource_index']] || []
    counts = FORMULA_AUDIT_STATUSES.each_with_object({}) { |name, h| h[name] = 0 }
    rows.each { |row| counts[row.fetch('status')] += 1 }
    converted = rows.count { |row| FORMULA_AUDIT_TRANSLATED.include?(row['status']) }
    {
      'name' => source['name'],
      'caption' => source['caption'],
      'total' => rows.length,
      'counts' => counts,
      'converted' => converted,
      'coverage_pct' => rows.empty? ? 100.0 : (100.0 * converted / rows.length).round(1),
      'calculation_cycles' => source['calculation_cycles'],
      'orphan_internal_calculation_references' => source['orphan_internal_calculation_references'],
      'unused_calculations' => source['unused_calculations'],
      'formulas' => rows
    }
  end

  batch.merge(
    'datasources' => datasources,
    'calculation_cycles' => inventory['calculation_cycles'],
    'orphan_internal_calculation_references' => inventory['orphan_internal_calculation_references'],
    'unused_calculations' => inventory['unused_calculations']
  )
end

# A converter refusal (not_converted/unmapped) that a validated learned rule
# rewrites is NOT a gap: build-charts-from-signals.rb places that same rule's
# formula on the chart column carrying the calc (and WARNs if it cannot). So
# reclassify it as chart_only — the converter's own "translated, needs chart
# context" status — keeping the original status and the rule as evidence, and
# recompute the batch totals. Spec-guidance rules (no pattern/template) never
# match. The Python runtime has no learned-rule loader or placement, so it
# keeps refusing these (fail closed).
def apply_learned_rules_to_audit!(batch)
  rules = LearnedRules.load
  return batch if rules.empty?
  formulas = batch.fetch('formulas')
  formulas.each do |row|
    next unless %w[not_converted unmapped].include?(row['status'])
    translated, hint = LearnedRules.apply(rules, row['formula'].to_s)
    next unless translated
    row['converter_status'] = row['status']
    row['status'] = 'chart_only'
    row['sigma_formula'] = translated
    row['learned_rule'] = hint
  end
  recount_formula_audit!(batch)
end

# One gap row PER refused formula, so the gap-scout gate (one scout per gap id,
# one pattern per scout) tracks each formula on its own: a scout validating
# one formula's rewrite must not clear the others, and one escalation must not
# block them all. Same-named calcs in two datasources stay distinct via the
# internal name.
CONVERTER_REFUSED_GAP_PREFIX = 'Converter-refused calculated field — '

TABLE_SCOPED_FIXED_RE = /\A\s*\{\s*FIXED\s*:/i

def converter_refused_gap_rows(formulas)
  refused = Array(formulas).select { |row| %w[not_converted unmapped].include?(row['status']) && !row['unused'] }
  labels = refused.map { |row| "#{row['datasource_caption'] || row['datasource']}: #{row['caption'] || row['internal_name']}" }
  dupes = labels.group_by(&:itself).select { |_, v| v.length > 1 }.keys
  refused.each_with_index.map do |row, i|
    label = labels[i]
    label = "#{label} (#{row['internal_name']})" if dupes.include?(label)
    blurb = "The vendored converter #{row['status'] == 'unmapped' ? 'could not map' : 'refused'} this formula: " \
            "#{row['formula'].to_s.gsub(/\s+/, ' ')[0, 160]}."
    if row['dependents']
      blurb += " Calcs built on it inherit the break and are what the dashboards plot: " \
               "#{row['dependents'].first(6).join(', ')}#{row['dependents'].length > 6 ? ', …' : ''}."
    end
    if row['formula'].to_s =~ TABLE_SCOPED_FIXED_RE
      blurb += ' Table-scoped FIXED (no dimensions) is one grand-total value over the whole source; ' \
               'the build does not emit it, so build that single value by hand and point the calcs above at it.'
    end
    blurb += ' Scout a validated rewrite (learned rule) or explicitly account for it before conversion; ' \
             'token-only catalog coverage is not accepted.'
    gap = { name: "#{CONVERTER_REFUSED_GAP_PREFIX}#{label}", status: :unhandled, count: 1, blurb: blurb }
    gap[:worksheets] = row['worksheets'] if row['worksheets']
    gap
  end
end

def unused_refused_gap_row(formulas)
  unused = Array(formulas).select { |row| %w[not_converted unmapped].include?(row['status']) && row['unused'] }
  return nil if unused.empty?
  {
    name: 'Converter-refused calculated fields not used on any worksheet',
    status: :hint,
    count: unused.length,
    blurb: "#{unused.length} refused formula(s) that no worksheet uses, directly or through another calc: " \
           "#{unused.first(12).map { |row| "#{row['datasource_caption'] || row['datasource']}: #{row['caption']}" }.join(', ')}. " \
           'Nothing is built from them, so they do not stop the conversion.'
  }
end

def formula_audit_gap_results(audit)
  counts = audit.is_a?(Hash) ? audit['counts'] : {}
  review = counts.to_h['verify'].to_i + counts.to_h['chart_only'].to_i
  rows = converter_refused_gap_rows(audit.is_a?(Hash) ? audit['formulas'] : [])
  unused_row = unused_refused_gap_row(audit.is_a?(Hash) ? audit['formulas'] : [])
  rows << unused_row if unused_row
  if review.positive?
    rows << {
      name: 'Converter-translated formulas requiring contextual verification',
      status: :hint,
      count: review,
      blurb: "#{review} actual workbook formula(s) translated as verify/chart_only. Build them in the required " \
             'element context and prove value parity before GREEN.'
    }
  end
  Array(audit['calculation_cycles']).each do |cycle|
    rows << {
      name: "Circular calculated-field dependency — #{cycle['datasource']}",
      status: :unhandled,
      count: 1,
      blurb: "Cycle: #{Array(cycle['calculations']).join(' ↔ ')}. Break the source dependency cycle; " \
             'the converter cannot produce a queryable Sigma column graph from it.'
    }
  end
  orphan_refs = Array(audit['orphan_internal_calculation_references'])
  if orphan_refs.any?
    rows << {
      name: 'Missing internal calculated-field dependencies',
      status: :unhandled,
      count: orphan_refs.length,
      blurb: orphan_refs.first(12).map { |row|
        "#{row['datasource']}/#{row['calculation']} → #{row['reference']}"
      }.join(', ')
    }
  end
  rows
end

def analyze_fields(doc, content, formula_audit = nil, calc_inventory = nil)
  # 1. Field definitions from primary (non-Parameters) datasources. Skip
  #    Tableau internal object-id columns (plumbing, not user fields).
  defs = {}
  doc.elements.to_a('/workbook/datasources/datasource').each do |ds|
    is_param_ds = ds.attributes['name'].to_s == 'Parameters'
    ds.elements.each('column') do |col|
      name = col.attributes['name']
      next unless name
      next if name.include?('__tableau_internal_object_id__')
      calc = col.elements['calculation']
      formula = calc&.attributes&.[]('formula')
      is_param = is_param_ds || !col.attributes['param-domain-type'].nil?
      defs[name] ||= {
        caption: col.attributes['caption'] || name,
        formula: formula,
        is_calc: !formula.nil? && !is_param,
        is_param: is_param
      }
    end
  end

  # 2. Reference region = everything after the workbook-level </datasources>
  #    (worksheets + dashboards + windows). A field is "directly used" if its
  #    internal name appears there. Splitting the raw string avoids needing an
  #    XML serializer and is robust across parsers.
  ref_region = content.split('</datasources>', 2)[1] || content
  used = defs.keys.select { |name| ref_region.include?(name) }.to_set

  # 3. Transitive closure through calc formulas.
  changed = true
  while changed
    changed = false
    used.to_a.each do |uname|
      f = defs[uname]&.[](:formula)
      next unless f
      defs.each_key do |cand|
        next if used.include?(cand)
        if f.include?(cand)
          used << cand
          changed = true
        end
      end
    end
  end
  unused = defs.keys - used.to_a

  # 4. Calc classification.
  calc_names = defs.select { |_, v| v[:is_calc] }.keys.to_set
  classify = lambda do |name|
    f = defs[name][:formula].to_s
    return :lod       if f =~ /\{\s*(FIXED|INCLUDE|EXCLUDE)\b/i
    return :tablecalc if f =~ /\b(INDEX|LOOKUP|TOTAL|RANK\w*|WINDOW_\w+|RUNNING_\w+|FIRST|LAST|SIZE)\s*\(/
    calc_names.any? { |c| c != name && f.include?(c) } ? :nested : :simple
  end
  calc_kinds = calc_names.each_with_object(Hash.new(0)) { |n, h| h[classify.call(n)] += 1 }

  # 4b. Calc-coverage census (v5.0, tflex-derived): tokenize every calc formula
  #     with the MASKING tokenizer (comments/strings/field-refs masked first, so
  #     'IF(' inside a string literal never false-hits) and extract the function
  #     names actually used. Functions absent from the 187-entry official
  #     catalog are named up front — a typo'd or extension function becomes a
  #     scoping fact here instead of a silent formula error after the build.
  fn_census = Hash.new(0)
  defs.each_value do |v|
    next unless v[:is_calc] && v[:formula]
    CalcCoverage.extract_function_names(v[:formula]).each { |fn| fn_census[fn] += 1 }
  end
  catalog_names = CalcCoverage.catalog_index.keys
  unknown_fns = fn_census.keys.reject { |fn| catalog_names.include?(fn) }.sort

  # 5. Orphaned worksheets (defined but on no dashboard).
  dash_region = content[/<dashboards>.*<\/dashboards>/m] || ''
  orphan_ws = doc.elements.to_a('/workbook/worksheets/worksheet')
                 .map { |w| w.attributes['name'] }
                 .reject { |w| dash_region.include?(w) }

  # 6. Duplicate display captions (collide in Sigma display names).
  dup_caps = defs.values.map { |v| v[:caption] }
                 .group_by(&:itself).select { |_, v| v.size > 1 }.keys

  # 7. Component inventory (per-object punch-list). Impact: LOD=high,
  #    nested/table-calc=medium, simple calc / source=low.
  components = defs.map do |name, v|
    kind = v[:is_param] ? :param : (v[:is_calc] ? classify.call(name) : :source)
    impact = case kind
             when :lod then 'high'
             when :nested, :tablecalc then 'medium'
             else 'low'
             end
    {
      'category' => v[:is_param] ? 'Parameter' : (v[:is_calc] ? 'Calculated Field' : 'Source Field'),
      'name'     => v[:caption],
      'kind'     => kind.to_s,
      'used'     => used.include?(name),
      'impact'   => impact
    }
  end.sort_by { |c| [{ 'high' => 0, 'medium' => 1, 'low' => 2 }[c['impact']], c['category'], c['name'].to_s] }

  n_defs = defs.size
  n_calc = calc_names.size
  n_param = defs.count { |_, v| v[:is_param] }
  stats = {
    'total_fields'       => n_defs,
    'source_fields'      => n_defs - n_calc - n_param,
    'calculated_fields'  => n_calc,
    'parameters'         => n_param,
    'used_fields'        => used.size,
    'unused_fields'      => unused.size,
    'pct_used'           => n_defs.zero? ? 0 : (100.0 * used.size / n_defs).round(1),
    'calc_simple'        => calc_kinds[:simple],
    'calc_nested'        => calc_kinds[:nested],
    'calc_lod'           => calc_kinds[:lod],
    'calc_tablecalc'     => calc_kinds[:tablecalc],
    'orphan_worksheets'  => orphan_ws,
    'duplicate_captions' => dup_caps,
    'unused_field_names' => unused.map { |n| defs[n][:caption] },
    'function_census'    => fn_census.sort_by { |fn, n| [-n, fn] }.to_h,
    'unknown_functions'  => unknown_fns,
    'components'         => components
  }
  if calc_inventory
    stats['calculation_cycles'] = calc_inventory['calculation_cycles']
    stats['orphan_internal_calculation_references'] =
      calc_inventory['orphan_internal_calculation_references']
    stats['unused_calculations'] = calc_inventory['unused_calculations']
  end
  if formula_audit
    stats['formula_status_counts'] = formula_audit['counts']
    stats['formula_coverage_pct'] = formula_audit['coverage_pct']
  end
  stats
end

def render_md(wb_name, summary, results, fields = nil)
  by_status = results.group_by { |r| r[:status] }
  md = String.new
  md << "# Tableau→Sigma gap report — `#{wb_name}`\n\n"
  md << "Generated by `scan-workbook-gaps.rb`. Run BEFORE conversion to set expectations.\n\n"
  md << "## Workbook summary\n\n"
  summary.each { |k, v| md << "- **#{k}:** #{v}\n" }
  md << "\n"

  if fields
    md << "## Field statistics (migration scope)\n\n"
    md << "- **#{fields['total_fields']} fields** — #{fields['source_fields']} source, "
    md << "#{fields['calculated_fields']} calculated, #{fields['parameters']} parameters\n"
    md << "- **#{fields['pct_used']}% used** (#{fields['used_fields']} used / #{fields['unused_fields']} dead)\n"
    md << "- **Calc dependency:** #{fields['calc_simple']} simple, #{fields['calc_nested']} nested, "
    md << "#{fields['calc_lod']} LOD, #{fields['calc_tablecalc']} table-calc\n"
    if (census = fields['function_census']) && !census.empty?
      md << "- **Function usage:** #{census.first(12).map { |fn, n| "#{fn}×#{n}" }.join(', ')}"
      md << " (+#{census.size - 12} more)" if census.size > 12
      md << "\n"
    end
    unless (fields['unknown_functions'] || []).empty?
      md << "- ⚠ **#{fields['unknown_functions'].size} function(s) NOT in the official Tableau catalog** "
      md << "(typo / extension — will not translate): #{fields['unknown_functions'].map { |f| "`#{f}`" }.join(', ')}\n"
    end
    if fields.key?('formula_coverage_pct')
      counts = fields['formula_status_counts'] || {}
      status_text = FORMULA_AUDIT_STATUSES.map { |status| "#{status}=#{counts[status].to_i}" }.join(', ')
      md << "- **Converter formula coverage:** #{fields['formula_coverage_pct']}% (#{status_text})\n"
    end
    unless (fields['calculation_cycles'] || []).empty?
      md << "- ⚠ **#{fields['calculation_cycles'].size} calculated-field cycle(s):** "
      md << fields['calculation_cycles'].map { |cycle|
        "`#{cycle['datasource']}: #{cycle['calculations'].join(' ↔ ')}`"
      }.join(', ') << "\n"
    end
    unless (fields['orphan_internal_calculation_references'] || []).empty?
      md << "- ⚠ **#{fields['orphan_internal_calculation_references'].size} missing internal calc reference(s):** "
      md << fields['orphan_internal_calculation_references'].map { |ref|
        "`#{ref['datasource']}/#{ref['calculation']} → #{ref['reference']}`"
      }.join(', ') << "\n"
    end
    unless (fields['unused_calculations'] || []).empty?
      md << "- **#{fields['unused_calculations'].size} unused calculated field(s):** "
      md << fields['unused_calculations'].map { |calc|
        "`#{calc['datasource']}/#{calc['calculation']}`"
      }.join(', ') << "\n"
    end
    unless fields['orphan_worksheets'].empty?
      md << "- **#{fields['orphan_worksheets'].size} orphaned worksheet(s)** (on no dashboard): "
      md << fields['orphan_worksheets'].map { |w| "`#{w}`" }.join(', ') << "\n"
    end
    unless fields['duplicate_captions'].empty?
      md << "- **#{fields['duplicate_captions'].size} duplicate caption(s)** (Sigma name-collision risk): "
      md << fields['duplicate_captions'].map { |c| "`#{c}`" }.join(', ') << "\n"
    end
    if fields['unused_fields'] > 0
      md << "\n> **Scope tip:** #{fields['unused_fields']} fields are defined but referenced by no "
      md << "worksheet — skip these during conversion. See the `-components.csv` sidecar for the full "
      md << "per-object punch-list (dead flag + impact).\n"
    end
    md << "\n"
  end

  emit = lambda do |status, label, header|
    rows = by_status[status] || []
    md << "## #{header} (#{rows.length})\n\n"
    if rows.empty?
      md << "_None detected._\n\n"
      return
    end
    md << "| Feature | Count | What the skill does |\n|---|---|---|\n"
    rows.sort_by { |r| -r[:count] }.each do |r|
      md << "| #{r[:name]} | #{r[:count]} | #{r[:blurb]} |\n"
    end
    md << "\n"
  end

  emit.call(:auto,      'Auto', '✅ Fully auto-translated')
  emit.call(:hint,      'Hint', '⚠️ Translation suggested, agent action required')
  emit.call(:manual,    'Manual','🛠 Post-publish manual setup required')
  emit.call(:unhandled, 'Unhandled','❌ Not yet handled — escalation path')

  md << "## Suggested next steps\n\n"
  if (by_status[:unhandled] || []).any?
    md << "1. Review the **Unhandled** features above. For each, the agent will either:\n"
    md << "   - Attempt translation via the `gap-scout` subagent (validates against Sigma API)\n"
    md << "   - File an issue at github.com/sigmacomputing/sigma-migration-skills if no translation is possible\n"
  end
  if (by_status[:manual] || []).any?
    md << "2. The **Manual** features need post-publish work. See `<workbook>-actions.md` after conversion for action-filter mappings.\n"
  end
  if (by_status[:hint] || []).any?
    md << "3. The **Hint** features will show as `WARN` lines during conversion with copy-paste-ready Sigma formulas — review each before publishing.\n"
  end
  md << "\n_Generated by tableau-to-sigma skill. Issues: https://github.com/sigmacomputing/sigma-migration-skills/issues_\n"
  md
end

def main
  inp = ARGV[0] || abort('usage: scan-workbook-gaps.rb <workbook.twb> [out.md]')
  out = ARGV[1] || inp.sub(/\.(twbx?|xml)$/i, '-gaps-report.md')
  abort("not found: #{inp}") unless File.exist?(inp)

  content = File.read(inp, encoding: 'utf-8', invalid: :replace)

  # Workbook summary via REXML
  xml = nil
  begin
    xml = TwbXml.parse(content)
    n_dash = xml.elements.to_a('//dashboard').count
    n_ws   = xml.elements.to_a('//worksheet').count
    # Count REAL datasource definitions only — at /workbook/datasources/datasource.
    # The same `<datasource>` tag also appears inside every `<worksheet>` as a
    # REFERENCE to that worksheet's source — counting `//datasource` would
    # multiply by ~(worksheets × datasource-refs-per-worksheet) and over-
    # report by orders of magnitude (one customer saw 482 reported for 28
    # actual sources). Also exclude the synthetic `Parameters` source.
    n_ds = xml.elements.to_a('/workbook/datasources/datasource').count { |d|
      d.attributes['name'] != 'Parameters' && !d.attributes['name'].to_s.start_with?('Parameters ')
    }
  rescue StandardError
    n_dash = n_ws = n_ds = '?'
  end

  summary = {
    'Workbook' => File.basename(inp),
    'Worksheets' => n_ws,
    'Dashboards' => n_dash,
    'Datasources' => n_ds,
    '.twb size' => "#{(File.size(inp) / 1024.0).round(1)} KB"
  }

  results = categorize(content)
  attribute_worksheets!(results, content, xml) # E9.6/A2: best-effort membership
  results.concat(detect_point_map_geo_role_gaps(content))
  blend_features, blend_plan = detect_blends(xml)
  results.concat(blend_features)
  results.concat(detect_unions(xml)) # W2.16: emitted (hint) vs refused (❌)
  multi_ds_feature, multi_ds_detail, multi_ds_plan = detect_multi_datasource(xml, blend_plan)
  results << multi_ds_feature if multi_ds_feature
  object_model_features, object_model_detail, object_model_plan = detect_object_model(content)
  results.concat(object_model_features)
  md_path = out
  json_path = out.sub(/\.md$/, '.json')

  if blend_plan
    blend_plan_path = File.join(File.dirname(File.expand_path(out)), 'blend-plan.json')
    blend_plan['workbook'] = File.basename(inp)
    File.write(blend_plan_path, JSON.pretty_generate(blend_plan))
    warn "wrote #{blend_plan_path} (#{blend_plan['blends'].length} blend(s): " +
         blend_plan['blends'].map { |b| "#{b['worksheet']}→#{b['route']}" }.join(', ') + ')'
  end

  if multi_ds_plan
    multi_ds_plan_path = File.join(File.dirname(File.expand_path(out)), 'multi-ds-plan.json')
    File.write(multi_ds_plan_path, JSON.pretty_generate(multi_ds_plan))
    warn "wrote #{multi_ds_plan_path} (#{multi_ds_plan['datasources'].length} independent datasource(s): " +
         multi_ds_plan['datasources'].map { |d| "#{d['caption']}→#{d['worksheets'].length} worksheet(s)" }.join(', ') + ')'
  end

  if object_model_plan
    object_model_plan_path = File.join(File.dirname(File.expand_path(out)), 'object-graph-plan.json')
    File.write(object_model_plan_path, JSON.pretty_generate(object_model_plan))
    warn "wrote #{object_model_plan_path} (" +
         object_model_plan['datasources'].map { |d|
           "#{d['caption']}: #{d['objects'].length} logical table(s), fact candidate #{d['fact_candidate'] || 'AMBIGUOUS'}"
         }.join('; ') + ')'
  end

  fields = nil
  formula_audit = nil
  if xml
    begin
      calc_inventory = calculation_inventory(xml, content)
      begin
        formula_audit = run_formula_audit(calc_inventory)
        results.concat(formula_audit_gap_results(formula_audit))
      rescue StandardError => e
        formula_audit = {
          'status' => 'ERROR',
          'error' => e.message,
          'formulas' => [],
          'counts' => FORMULA_AUDIT_STATUSES.to_h { |name| [name, 0] },
          'coverage_pct' => 0.0,
          'calculation_cycles' => calc_inventory['calculation_cycles'],
          'orphan_internal_calculation_references' =>
            calc_inventory['orphan_internal_calculation_references'],
          'unused_calculations' => calc_inventory['unused_calculations']
        }
        results << {
          name: 'Converter-backed formula audit unavailable',
          status: :unhandled,
          count: [calc_inventory['inputs'].length, 1].max,
          blurb: "#{e.message}. Restore Node/the vendored converter and re-run; " \
                 'the token-only census cannot authorize conversion.'
        }
        warn "  formula audit FAILED CLOSED: #{e.message}"
      end
      fields = analyze_fields(xml, content, formula_audit, calc_inventory)
    rescue StandardError => e
      results << {
        name: 'Calculated-field dependency analysis unavailable',
        status: :unhandled,
        count: 1,
        blurb: "#{e.message}. Repair the TWB/audit path and re-run before conversion."
      }
      warn "  field analysis FAILED CLOSED: #{e.message}"
    end
  end

  File.write(md_path, render_md(File.basename(inp), summary, results, fields))
  json_payload = {
    'workbook' => summary,
    'detected_features' => results.map { |r| r.transform_keys(&:to_s) }
  }
  json_payload['field_statistics'] = fields.reject { |k, _| k == 'components' } if fields
  json_payload['formula_audit'] = formula_audit if formula_audit
  json_payload['multi_datasource'] = multi_ds_detail if multi_ds_detail
  json_payload['object_model'] = object_model_detail if object_model_detail
  File.write(json_path, JSON.pretty_generate(json_payload))

  if fields && !fields['components'].empty?
    csv_path = out.sub(/-gaps-report\.md$/, '').sub(/\.md$/, '') + '-components.csv'
    CSV.open(csv_path, 'w') do |csv|
      csv << %w[Category Name Kind Used Impact]
      fields['components'].each do |c|
        csv << [c['category'], c['name'], c['kind'], (c['used'] ? 'used' : 'DEAD'), c['impact']]
      end
    end
    warn "wrote #{csv_path}"
  end

  warn "wrote #{md_path}"
  warn "wrote #{json_path}"
  warn ""
  warn "Summary: " + results.group_by { |r| r[:status] }.map { |s, rs| "#{rs.length} #{s}" }.join(', ')
end

main if $PROGRAM_NAME == __FILE__
