#!/usr/bin/env ruby
# Build a parity plan automatically by matching Tableau view CSVs to Sigma
# workbook chart elements.
#
# Inputs:
#   --tableau /tmp/<name>           directory with get-workbook.json + views/<viewId>.csv
#   --workbook-spec wb-spec.json    Sigma workbook spec (after Phase 5c readback OR a manual write)
#                                   — used to pull element IDs, kinds, and column IDs
#   --out parity-plan.json          output plan (wrapped: { extract: bool, charts: [...] })
#
# Optional:
#   --rename CHART_FROM=CHART_TO    when the Sigma chart was renamed from the original Tableau title
#                                   (e.g., "Order Channel vs Ship Method=Orders by Category")
#                                   — repeatable
#
# Matching (v5.5): PROVENANCE FIRST — when <tableau-dir>/chart-provenance.json
# exists (written by build-charts-from-signals.rb), each Sigma element id maps
# to its Tableau WORKSHEET name (unique per workbook), an exact collision-free
# join. Only elements ABSENT from the map (hand-added charts) fall back to the
# display-name heuristic: Sigma element name == Tableau view name (exact), then
# loose match (strip punctuation, lowercase) — WITH a warning, because display
# titles are NOT unique across dashboards (the same-title collision class:
# double-mapped + dropped views, and tiles parity-checked against the wrong
# same-named view). Sigma kinds and Tableau chart_kinds are recorded for context.
#
# After running this, the agent fetches Sigma actuals via MCP or REST and edits the plan to
# add an "actual" key per chart, then runs verify-parity.rb.
#
# Or, if the SIGMA_API_TOKEN env path works, this script can pre-fetch Sigma actuals via the
# workbook query API and populate "actual" inline (best-effort; skip silently on failure).

require 'json'
require 'csv'
require 'optparse'
require_relative 'lib/workdir_guard' # refuse a workdir inside the installed plugin
require 'net/http'
require 'uri'
require 'set'
# UTF-8 external encoding for the view CSVs (unicode minus, accented names) even
# when LANG is unset — CSV.read otherwise tags the file US-ASCII and raises.
require_relative 'lib/cli_encoding'
require_relative 'lib/workbook_code'
require_relative 'lib/carried_calc_filters'
require_relative 'lib/tooltip_fields'

opts = { renames: {}, trusted_rename_sources: Set.new }
OptionParser.new do |p|
  p.on('--tableau DIR')          { |v| opts[:tab] = WorkdirGuard.check!(v, '--tableau') }
  p.on('--workbook-spec PATH')   { |v| opts[:wb]  = v }
  p.on('--out PATH')             { |v| opts[:out] = v }
  p.on('--workbook-id ID')       { |v| opts[:wb_id] = v }
  p.on('--master-id ID',
       'Override the master-element ID prefix. Repeatable. ' \
       'Default: auto-detect every element where source.kind=="table" and ' \
       'elementId starts with "master" (handles multi-master specs like ' \
       'master-absences / master-employees / master-time).') { |v| (opts[:master_ids] ||= []) << v }
  p.on('--rename PAIR')          do |v|
    from, to = v.split('=', 2)
    opts[:renames][from] = to
    opts[:trusted_rename_sources] << from
  end
  p.on('--no-fetch')             {     opts[:no_fetch] = true }
  # Per-dashboard parity scoping (large-workbook one-tab-at-a-time gating). When
  # set, only chart elements on the matching workbook PAGE(s) are planned/gated —
  # so parity passes/fails per-tab instead of all-or-nothing across the whole
  # workbook. Page name match is case-insensitive exact OR unique substring (the
  # Sigma page name == the Tableau dashboard name in per-dashboard builds).
  # Repeatable. --page is an alias accepting a page id or name.
  p.on('--dashboard NAME', 'Scope parity to chart tiles on this workbook page only (name: exact or unique substring). Repeatable.') { |v| (opts[:dashboards] ||= []) << v }
  p.on('--page NAME_OR_ID', 'Alias for --dashboard; matches a page by name or id. Repeatable.') { |v| (opts[:dashboards] ||= []) << v }
end.parse!
abort('usage: --tableau DIR --workbook-spec FILE --out FILE [--workbook-id ID] [--rename A=B]') unless opts[:tab] && opts[:wb] && opts[:out]

# Load Tableau side: workbook metadata (for extract flag + view name → view id map) + CSVs
gw = JSON.parse(File.read(File.join(opts[:tab], 'get-workbook.json')))
require_relative 'lib/mcp_source'
views = McpSource.views_for(opts[:tab], gw)

# hasExtracts on the workbook OR on the underlying datasource
extract = false
if gw['hasExtracts'] == true || gw['hasExtracts'] == 'true'
  extract = true
end
# Tableau Cloud often surfaces extracts on the workbook search result, not the get-workbook
# response — caller can re-flag via the --extract-mode CLI flag on verify-parity.rb.

view_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v }

# Load Sigma side
spec = JSON.parse(File.read(opts[:wb]))
workbook_pages = WorkbookCode.pages(spec)
workbook_elements = WorkbookCode.elements(spec)

# Per-dashboard scope: narrow the pages we plan parity over to the matching
# page(s). Workbook pages are metadata-only; layout owns page membership, so
# scoped element selection must use WorkbookCode.elements_for_page rather than
# reading a nonexistent pages[].elements array.
pages = workbook_pages
if opts[:dashboards] && !opts[:dashboards].empty?
  want = opts[:dashboards].map(&:downcase)
  pages = workbook_pages.select do |pg|
    nm = pg['name'].to_s.downcase
    pid = pg['id'].to_s.downcase
    want.any? { |w| !w.empty? && (nm == w || nm.include?(w) || pid == w) }
  end
  abort("--dashboard/--page matched no workbook page in #{opts[:wb]}") if pages.empty?
  warn "scoped parity to page(s): #{pages.map { |p| p['name'] }.join(', ')}"
end
scoped_elements =
  if opts[:dashboards] && !opts[:dashboards].empty?
    pages.flat_map { |page| WorkbookCode.elements_for_page(spec, page) }.uniq { |element| element['id'] }
  else
    workbook_elements
  end

# Build the set of master-element-IDs we should treat as "the master" for
# chart matching. Either explicit via --master-id (repeatable) OR auto-detect
# from the spec: any element with kind=="table" + visibleAsSource==false +
# source.kind=="data-model" is a master. This handles multi-master workbooks
# (e.g. workforce uses master-absences / master-employees / master-time, one
# per Tableau worksheet sourcing different facts) — the previous hardcoded
# `elementId == 'master'` check returned zero matches and an incomprehensible
# "fire 0 queries" message.
master_ids =
  if opts[:master_ids] && !opts[:master_ids].empty?
    opts[:master_ids]
  else
    detected = workbook_elements.each_with_object([]) do |element, out|
      if element['kind'] == 'table' &&
         element['visibleAsSource'] == false &&
         element.dig('source', 'kind') == 'data-model'
        out << element['id']
      end
    end
    # Legacy fallback for specs that pre-date the master/visibleAsSource shape:
    # any element whose ID literally starts with `master`.
    if detected.empty?
      workbook_elements.each { |element| detected << element['id'] if element['id'].to_s.start_with?('master') }
    end
    detected.uniq
  end
master_id_set = master_ids.to_set

# Server readback can drop `visibleAsSource:false` from a hidden grain helper
# even though a KPI/chart still sources that table. Seed every table referenced
# by a scoped non-table visualization as a helper/master candidate. Otherwise a
# valid chart disappears from both parity and tile census (live-caught on the
# dimension-grain Avg Lifetime Revenue KPI).
visual_source_ids = scoped_elements.each_with_object(Set.new) do |element, ids|
  next if %w[table control text image container].include?(element['kind'].to_s)
  source_id = element.dig('source', 'elementId')
  ids << source_id if source_id
end
workbook_elements.each do |element|
  next unless element['kind'] == 'table'
  next unless visual_source_ids.include?(element['id'])
  master_id_set << element['id']
end

if master_id_set.empty?
  # A hand-authored spec may have NO intermediate master tables at all — every
  # chart sources the data model directly. That's a valid documented shape,
  # not an error (the chart loop below matches DM-sourced charts on its own).
  has_dm_charts = scoped_elements.any? do |element|
    element.dig('source', 'kind') == 'data-model' && element['kind'] != 'table'
  end
  abort('auto-parity-plan.rb: no master element(s) detected; pass --master-id explicitly') unless has_dm_charts
  warn 'no master tables detected — matching data-model-sourced charts directly'
else
  warn "matching charts that source from master/helper element(s): #{master_id_set.to_a.join(', ')}"
end

# Transitive: hidden helper tables that THEMSELVES source a master (e.g. the
# scatter grouped-source tables, bead z1d0) count as masters for chart
# matching — the scatter chart sources the helper, not the master.
loop do
  before = master_id_set.size
  workbook_elements.each do |element|
    next unless element['kind'] == 'table' && element['visibleAsSource'] == false
    next unless element['source'] && master_id_set.include?(element['source']['elementId'])
    master_id_set << element['id']
  end
  break if master_id_set.size == before
end
sigma_charts = scoped_elements.each_with_object([]) do |element, out|
  next if master_id_set.include?(element['id'])
  # A chart counts when it sources a detected master — OR sources the data
  # model DIRECTLY (source.kind=='data-model' on the chart itself, the
  # documented hand-authored shape). The master-only check silently produced
  # a "0 CSV tiles" census on every exit-4 workbook, forcing an
  # --allow-missing-tiles waiver for tiles that were fully verifiable
  # (field-caught round 2, two independent runs).
  from_master = element['source'] && master_id_set.include?(element['source']['elementId'])
  from_dm = element.dig('source', 'kind') == 'data-model' &&
            !%w[table control text image container].include?(element['kind'].to_s)
  out << element if from_master || from_dm
end

# Match Sigma chart → Tableau view
# Element display name: put-layout replaces `name` with a visibility hash on
# hidden-title elements — recover text, else the id slug, so Tableau-view
# matching keeps working (and keys stay unique).
def el_display_name(el)
  n = el['name']
  return n.to_s unless n.is_a?(Hash)
  t = n['text'].to_s
  t.empty? ? el['id'].to_s.sub(/\Ael-/, '').tr('-', ' ') : t
end

def normalize(s)
  s.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

# Auto-bridge the display-title rename. Sigma tiles are named by their worksheet
# display_title ("Net Revenue"), but Tableau views are keyed by the worksheet
# caption/nickname ("OV KPI Revenue"). Seed the caption→display_title map from the
# dashboard-layout zones so parity matches WITHOUT a manual --rename (explicit
# --rename still wins). Keeps parity matching in lockstep with the element namer.
_dl_path = File.join(opts[:tab], 'dashboard-layout.json')
if File.exist?(_dl_path)
  begin
    _dl = JSON.parse(File.read(_dl_path))
    (_dl.is_a?(Array) ? _dl : (_dl['dashboards'] || [_dl])).each do |d|
      (d['zones'] || []).each do |z|
        cap = z['caption'].to_s; dt = z['display_title'].to_s.strip
        opts[:renames][cap] ||= dt unless cap.empty? || dt.empty? || cap == dt
      end
    end
  rescue StandardError
    nil # best-effort; fall back to name==name matching
  end
end

# Persisted layout renames are also source→Sigma chart provenance. Manual
# reconstruction commonly creates valid chart elements after the initial
# chart-provenance sidecar was written; without this bridge, those elements
# disappear from both the parity inventory and the tile census on re-entry.
# Explicit --rename flags and dashboard display-title mappings retain priority.
_layout_renames_path = File.join(opts[:tab], 'layout-renames.json')
if File.exist?(_layout_renames_path)
  begin
    _layout_renames = JSON.parse(File.read(_layout_renames_path))
    if _layout_renames.is_a?(Hash)
      _layout_renames.each do |source_name, sigma_name|
        opts[:renames][source_name] ||= sigma_name
        opts[:trusted_rename_sources] << source_name if opts[:renames][source_name] == sigma_name
      end
    end
  rescue JSON::ParserError => e
    warn "layout-renames.json unreadable (#{e.message}) — persisted reconstruction renames ignored"
  end
end

# Build reverse-rename map: tableau-name → sigma-name was the input;
# we want sigma-name → tableau-name for lookup.
# ⚠️ COLLISION-PRONE BY CONSTRUCTION: two worksheets sharing one display_title
# collapse to a single rev_renames entry, so both Sigma charts back-match the
# SAME view and the other view drops (field-verified: 29 charts → 24 views,
# 5 double-mapped + 5 dropped, and 5 tiles value-checked against the WRONG
# same-titled view). This map is therefore only the FALLBACK — the provenance
# join below (element id → worksheet, unique) is consumed first.
rev_renames = opts[:renames].each_with_object({}) { |(k, v), h| h[v] = k }
trusted_rev_renames = opts[:trusted_rename_sources].each_with_object({}) do |source_name, index|
  sigma_name = opts[:renames][source_name]
  index[sigma_name] = source_name if sigma_name
end

# ---- Chart provenance (v5.5 — the collision-free join) ----------------------
# build-charts-from-signals.rb writes <tableau-dir>/chart-provenance.json:
#   { "version": 1, "elements": { "<sigma element id>":
#       { "worksheet": "<Tableau worksheet name>", "dashboard": "...", ... } } }
# Tableau worksheet names are unique within a workbook (Tableau enforces it)
# and ARE the view names get-workbook.json/views key CSVs by — so an id-keyed
# lookup matches each chart to its own view exactly, immune to display-title
# collisions. Element ids are deterministic (el-<worksheet-slug>), so the map
# survives re-POSTs/readbacks. Charts absent from the map (hand-added) fall
# back to the display-name heuristic WITH A WARNING.
prov_path = File.join(opts[:tab], 'chart-provenance.json')
provenance = {}
if File.exist?(prov_path)
  begin
    pj = JSON.parse(File.read(prov_path))
    provenance = pj.is_a?(Hash) && pj['elements'].is_a?(Hash) ? pj['elements'] : {}
  rescue JSON::ParserError => e
    warn "chart-provenance.json unreadable (#{e.message}) — falling back to display-name matching"
  end
end
if provenance.empty?
  warn "no chart provenance at #{prov_path} — matching by DISPLAY NAME, which is " \
       'COLLISION-PRONE when worksheets share display titles; rebuild charts with ' \
       'build-charts-from-signals.rb to emit it (hand-authored specs: verify every ' \
       'tableau_view below and use --rename per renamed tile)'
end

plan_entries = []
chart_inventory = []
sigma_charts.each do |el|
  sigma_name = el_display_name(el)
  prov = provenance[el['id'].to_s]
  if prov && !prov['worksheet'].to_s.strip.empty?
    tableau_name = prov['worksheet'].to_s
    matched_via  = 'provenance'
  elsif trusted_rev_renames.key?(sigma_name)
    tableau_name = trusted_rev_renames[sigma_name]
    matched_via  = 'rename'
  else
    tableau_name = rev_renames[sigma_name] || sigma_name
    matched_via  = 'name-fallback'
    unless provenance.empty?
      warn "provenance MISS for element #{el['id']} (#{sigma_name.inspect}) — falling back to " \
           'display-name matching (hand-added chart?); verify its tableau_view'
    end
  end

  # Structural inventory is deliberately separate from value-parity charts.
  # Composite dashboards often expose only one dashboard-level CSV, so there
  # is no per-worksheet expected-value oracle. The built tile still belongs in
  # the census; omitting it made every reconstructed tile read as missing.
  chart_inventory << {
    'chart' => sigma_name,
    'tableau_view' => tableau_name,
    'sigma_element_id' => el['id'],
    'sigma_kind' => el['kind'],
    'matched_via' => matched_via
  }

  view = view_by_name[tableau_name]
  view ||= view_by_name.find { |n, _| normalize(n) == normalize(tableau_name) }&.last
  if view.nil?
    warn "no Tableau view matched Sigma chart #{sigma_name.inspect} (try --rename '<Tableau title>=#{sigma_name}')"
    next
  end

  csv_path = McpSource.csv_path(opts[:tab], view)
  unless File.exist?(csv_path)
    warn "missing CSV at #{csv_path} for #{sigma_name.inspect}"
    next
  end

  rows = CSV.read(csv_path, encoding: 'bom|utf-8')
  next if rows.empty?
  header = rows.shift

  # Measure Names / Measure Values long-format CSV → pivot WIDE so it compares
  # against the dissolved multi-measure Sigma chart (build-charts emits one
  # yAxis column per measure, NAMED with the verbatim Tableau measure label —
  # the pivoted header below therefore matches by display name).
  mn_i = header.index { |h| h.to_s.strip.casecmp?('Measure Names') }
  mv_i = header.index { |h| h.to_s.strip.casecmp?('Measure Values') }
  if mn_i && mv_i
    dim_indices = header.each_index.reject { |i| i == mn_i || i == mv_i }
    # a table calc's label carries its addressing ("Rank - Mo along Table (Down)"); the
    # Sigma column is named for the calc itself, so pivot under the base name
    tc_base = ->(l) { l.to_s.sub(/\s+along\s+(?:(?:Table|Pane|Cell)\b(?:\s*\([^)]*\))?|[^()\[\]]+)\s*\z/i, '').strip }
    labels = rows.map { |r| r[mn_i] }.compact.map { |l| tc_base.call(l) }.reject(&:empty?).uniq
    wide   = {}
    order  = []
    rows.each do |r|
      k = dim_indices.map { |i| r[i] }
      unless wide.key?(k)
        wide[k] = {}
        order << k
      end
      label = tc_base.call(r[mn_i])
      abort "source export reshape refused for #{sigma_name.inspect}: empty or duplicate measure cell; source grain must be resolved explicitly" if label.empty? || wide[k].key?(label)
      wide[k][label] = r[mv_i]
    end
    header = dim_indices.map { |i| header[i] } + labels
    rows   = order.map { |k| k + labels.map { |l| wide[k][l] } }
    warn "#{sigma_name.inspect}: Measure Names/Values long CSV pivoted to wide (#{labels.size} measure(s)) for the multi-measure chart"
  end

  # Column selection (bead s6fo): align the Sigma SELECT to the Tableau CSV's
  # column order by NAME so 3-channel charts (stacked color / pivot / scatter)
  # compare every channel — not an arbitrary first-2-columns slice.
  all_cols = (el['columns'] || [])
  tc_base = lambda do |h|
    # a table calc's addressing tail ("Rank along Table (Down)") is not part of its name
    h.to_s.sub(/\s+along\s+(?:(?:Table|Pane|Cell)\b(?:\s*\([^)]*\))?|[^()\[\]]+)\s*\z/i, '').strip
  end
  header_base = lambda do |h|
    tc_base.call(h)
     .sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
     .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '')
     .sub(/^(?:second|minute|hour|day|week|month|quarter|year) of /i, '')
     .strip
  end
  # Virtual-connection headers: "<field> (<table> (<schema>.<table>))", possibly
  # repeated. Returns [base_field, [table, ...]]; a plain header returns itself.
  vc_split = lambda do |h|
    cur = h.to_s.strip
    tables = []
    while (m = cur.match(/\A(.*\S)\s*\(([^()]*)\(([^()]*\.[^()]*)\)\s*\)\z/m))
      tables << m[2].strip
      cur = m[1].strip
    end
    [cur, tables]
  end
  # The data model disambiguates a VC field shared by several tables as
  # "<field> (<table>)" while the export header carries the fully qualified
  # "<field> (<table> (<schema>.<table>))" — match the forms BOTH ways. A
  # Sigma-side "(<x>)" suffix is only peeled when <x> is a VC table named by
  # some export header or element column, so "Revenue (USD)" never collapses.
  vc_tables_known = (header + all_cols.map { |c| c['name'] }).flat_map { |x| vc_split.call(x)[1] }
                                                             .map { |t| t.to_s.strip.downcase }.reject(&:empty?).uniq
  col_forms = lambda do |nm|
    forms = [nm, tc_base.call(nm)]
    vb, = vc_split.call(nm)
    forms << vb
    if (m = vb.match(/\A(.*\S)\s*\(([^()]+)\)\z/)) && vc_tables_known.include?(m[2].strip.downcase)
      forms << m[1].strip
    end
    forms.map { |f| f.to_s.strip.downcase }.uniq
  end
  pick = lambda do |h|
    stripped, vc_tables = vc_split.call(h)
    base = header_base.call(stripped)
    hforms = [h.to_s.strip, stripped, base]
    vc_tables.each { |t| hforms << "#{stripped} (#{t})" << "#{base} (#{t})" }
    hforms = hforms.map { |f| f.to_s.strip.downcase }.uniq
    cands = all_cols.select do |c|
      nm = c['name'].to_s.strip
      # A table keeps Tableau's full header ("Rank - Mo along Table (Down)") as its column name
      # while the pivoted CSV header is the base name, so compare the column's base name too.
      nm.casecmp?(h.to_s.strip) || nm.casecmp?(stripped) || nm.casecmp?(base) || tc_base.call(nm).casecmp?(base) ||
        !(col_forms.call(nm) & hforms).empty?
    end
    if cands.size > 1 && !vc_tables.empty?
      # ambiguous base name: the table qualifier disambiguates
      by_table = cands.select do |c|
        hay = [c['name'], c['table'], c['source'], c['id']].map { |x| x.to_s.downcase }.join(' ')
        vc_tables.any? { |t| !t.empty? && hay.include?(t.downcase) }
      end
      cands = by_table unless by_table.empty?
    end
    # Prefer plotted channel columns over hidden filter passthroughs.
    pref = %w[x- c- y- y2- k- p- calc-]
    rank = ->(c) { [c['name'].to_s.strip.casecmp?(h.to_s.strip) ? 0 : 1, pref.index { |px| c['id'].to_s.start_with?(px) } || 99] }
    cands.sort_by!(&rank)
    abort "ambiguous source column #{h.inspect} on #{sigma_name.inspect}; resolve its identity explicitly" if cands.size > 1 && rank.call(cands[0]) == rank.call(cands[1])
    cands.first
  end
  # Columns with no Sigma counterpart that must not abort the plan (never silent:
  # each lands in the entry's skipped_columns with its reason).
  skipped_columns = []
  tooltip_only = TooltipFields.tooltip_only_captions(opts[:tab], tableau_name)
  generated_geo = /\A(?:latitude|longitude|country|state|state\/province|county|city|postcode|zip code|region|continent)\s*\(generated\)\z/i
  flag_values = %w[true false yes no]
  keep_idx = (0...header.length).select do |i|
    h = header[i]
    reason = nil
    if header.length > 1 && pick.call(h).nil?
      vals = rows.map { |r| r[i].to_s.strip }.reject(&:empty?)
      if h.to_s.strip.match?(generated_geo)
        reason = 'Tableau-generated geographic column; no Sigma counterpart'
      elsif tooltip_only.any? { |cap| cap.casecmp?(header_base.call(vc_split.call(h).first)) || cap.casecmp?(h.to_s.strip) }
        reason = 'Tableau tooltip-only field (on the tooltip, no plotted channel); Sigma tooltips are UI-only, so the element has no counterpart column'
      elsif !vals.empty? && vals.all? { |v| flag_values.include?(v.downcase) }
        reason = 'formatting-only flag column (boolean/constant text values, not a plotted field of the Sigma element)'
      end
    end
    skipped_columns << { 'header' => h, 'reason' => reason } if reason
    reason.nil?
  end
  unless skipped_columns.empty?
    skipped_dims = skipped_columns.count { |sc| (header.index(sc['header']) || 0) < (mn_i && mv_i ? dim_indices.size : 1) }
    header = keep_idx.map { |i| header[i] }
    rows   = rows.map { |r| keep_idx.map { |i| r[i] } }
    warn "#{sigma_name.inspect}: skipped #{skipped_columns.size} column(s) with no Sigma counterpart: #{skipped_columns.map { |sc| sc['header'] }.inspect}"
  end

  n_fields = header.length
  dimension_count = mn_i && mv_i ? [dim_indices.size - (skipped_dims || 0), 0].max : (n_fields == 1 ? 0 : 1)

  # Parse a Tableau CSV cell to a comparable value. Measures arrive as
  # formatted strings ("110,788.35" / "$1,234" / "12.3%") — KPI expecteds MUST
  # become floats or the strict compare fails on representation (bead s6fo).
  # Accounting negatives ("($41,000)") and a unicode minus parse as negative.
  # Each column's PRINTED precision is recorded in col_decimals (percent: +2,
  # since the fraction carries two more places than the label) so the comparator
  # can judge Sigma at the precision the source actually exported — a "$#,##0"
  # view carries whole dollars only and can never equal a cent-precision value.
  col_decimals = Array.new(n_fields)
  parse_cell = lambda do |v, i|
    return nil if v.nil? || v.to_s.strip.empty?
    s = v.to_s.strip
    neg = false
    accounting = false
    if (m = s.match(/\A\((.*)\)\z/))
      neg = true
      accounting = true
      s = m[1].strip
    end
    if s.start_with?('-', "\u2212")
      neg = !neg
      s = s[1..].strip
    end
    pct = s.end_with?('%')
    body = s.gsub(/[,$%]/, '')
    f = (Float(body) rescue nil)
    return v if f.nil?
    decimals = body.include?('.') ? body.split('.', 2)[1].length : 0
    decimals += 2 if pct
    # Only formatted cells ($ , % or accounting parens) evidence a printed
    # precision; a bare "3" or "3.5" cell is left to the default comparison.
    col_decimals[i] = [col_decimals[i] || 0, decimals].max if s.match?(/[,$%]/) || accounting
    f = -f if neg
    pct ? f / 100.0 : f
  end
  expected_rows = rows.map do |r|
    r.map.with_index do |v, i|
      if i >= dimension_count
        parse_cell.call(v, i)
      else
        v.nil? || v.to_s.strip.empty? ? nil : v
      end
    end
  end

  matched = header.map { |h| pick.call(h) }
  cols =
    if matched.all? && matched.map { |c| c['id'] }.uniq.length == header.length
      matched.map { |c| c['id'] }
    elsif el['kind'] == 'kpi-chart' && all_cols.length == 1 && n_fields == 1
      [all_cols.first['id']]
    else
      abort "source export column identity is unresolved for #{sigma_name.inspect}: #{header.inspect}. Resolve aliases or source/export grain explicitly; positional guessing is not parity evidence."
    end

  # Pie / donut: Sigma's element export and MCP `query` return only the
  # plotted channels (color dimension + value). A column the plan matched by
  # name but the pie does not plot (e.g. a "% of total" label kept after a
  # bar → pie convert_to) is absent from both, so that chart could never be
  # collected (2026-11-05 live proof, fixtures/sdk-hybrid-live-proof). Fall
  # back to the element's encoded columns from the spec: drop the unplotted
  # MEASURE columns (past the CSV's dimension count, every cell numeric or
  # blank; auto-parity-plan.py applies the same rule) from the plan and the
  # expected rows. An unplotted DIMENSION would change the grain, so that case
  # keeps the full plan.
  projected_out = []
  if %w[pie-chart donut-chart].include?(el['kind'])
    encoded = [el.dig('color', 'columnId'), el.dig('value', 'columnId')].compact
    drop = cols.each_index.reject { |i| encoded.include?(cols[i]) }
    measure_only = expected_rows.any? && drop.all? do |i|
      i >= dimension_count && expected_rows.all? { |r| r[i].nil? || r[i].is_a?(Numeric) }
    end
    if encoded.size == 2 && encoded.all? { |id| cols.include?(id) } && drop.any? && measure_only
      keep = cols.each_index.to_a - drop
      projected_out = drop.map { |i| all_cols.find { |c| c['id'] == cols[i] }&.fetch('name', nil) || cols[i] }
      cols = keep.map { |i| cols[i] }
      expected_rows = expected_rows.map { |r| keep.map { |i| r[i] } }
      col_decimals = keep.map { |i| col_decimals[i] }
      warn "#{sigma_name.inspect}: #{el['kind']} plots only its color + value columns; " \
           "parity compares those (unplotted: #{projected_out.join(', ')})"
    end
  end

  entry = {
    'chart'       => sigma_name,
    'tableau_view' => view['name'] || tableau_name,
    'sigma_element_id' => el['id'],
    'sigma_kind'  => el['kind'],
    'sigma_columns' => cols,
    'sigma_column_names' => cols.map { |id| all_cols.find { |column| column['id'] == id }&.fetch('name', nil) },
    'matched_via' => matched_via,
    'expected'    => expected_rows
  }
  entry['skipped_columns'] = skipped_columns unless skipped_columns.empty?
  measure_ids = Array(el.dig('yAxis', 'columnIds')) + Array(el['values']) +
                [el.dig('value', 'columnId'), el.dig('value', 'id')]
  measure_ids = measure_ids.map { |id| id.is_a?(Hash) ? (id['columnId'] || id['id']) : id }.compact
  measure_indices = cols.each_index.select { |i| measure_ids.include?(cols[i]) }
  entry['measure_indices'] = measure_indices unless measure_indices.empty?
  entry['expected_decimals'] = col_decimals if col_decimals.any?
  entry['unplotted_columns'] = projected_out unless projected_out.empty?
  if opts[:wb_id] && cols.size >= 1
    sel = cols.each_with_index.map { |c, i| %("#{c}" AS f#{i}) }.join(', ')
    entry['sql_template'] = %(SELECT #{sel} FROM "workbook"."#{el['id']}" ORDER BY 1)
    entry['workbookId'] = opts[:wb_id]
  end
  plan_entries << entry
end

# ---- Integrity guard: same-view double-map (LOUD, not silent) ---------------
# Two plan charts on the SAME tableau_view is legitimate only when one
# worksheet is genuinely placed on multiple dashboards (provenance-matched
# copies verify against the same CSV by design). When any of the duplicates
# arrived via the display-name FALLBACK and the workbook has ANOTHER view
# sharing that display title, one chart is being validated against the WRONG
# view — the silent wrong-numbers class (a repeated-name tile with a
# page-specific filter would "pass" against the wrong source). Warn naming
# both sides. The DROPPED view itself is the tile census's job (gate 5) — this
# guard only flags the double-map, so it cannot mask or double-count that.
begin
  # display_title → the worksheet captions that render under it: the rename
  # bridge's cap→display_title pairs, plus any view literally NAMED the title
  # (a worksheet whose display title equals its own name never enters renames).
  title_to_caps = Hash.new { |h, k| h[k] = [] }
  opts[:renames].each { |cap, dt| title_to_caps[normalize(dt)] << cap }
  view_by_name.each_key do |vn|
    key = normalize(vn)
    title_to_caps[key] << vn if title_to_caps.key?(key) && !title_to_caps[key].include?(vn)
  end
  plan_entries.group_by { |e| e['tableau_view'] }.each do |vn, entries|
    next if entries.size < 2
    fb = entries.select { |e| e['matched_via'] == 'name-fallback' }
    next if fb.empty?
    others = fb.flat_map { |e| title_to_caps[normalize(e['chart'])] }
               .uniq.reject { |cap| cap == vn }
    next if others.empty?
    warn "COLLISION: #{entries.size} chart(s) (#{entries.map { |e| e['sigma_element_id'] }.join(', ')}) " \
         "all matched Tableau view #{vn.inspect} by DISPLAY NAME, but the workbook has other view(s) " \
         "with the same display title: #{others.map(&:inspect).join(', ')} — at least one chart is " \
         'validating against the WRONG view. Rebuild charts with build-charts-from-signals.rb so ' \
         'chart-provenance.json disambiguates (or hand-fix tableau_view per chart), then regenerate this plan.'
  end
rescue StandardError => e
  warn "collision guard error (non-fatal): #{e.message}"
end

# Actuals are collected by collect-parity-actuals.rb through Sigma's supported
# workbook export REST endpoints. Sigma MCP remains an OPTIONAL fallback for
# the small remainder the exporter cannot serve (for example an aggregate
# query over a row-limit-bounded pivot); its absence never blocks the normal
# REST/anchors/warehouse path.
puts '  NOTE: collect-parity-actuals.rb uses Sigma REST export first; MCP is optional'
puts '        and is only a fallback for charts the pooled exporter cannot serve.'

# ---- Hidden calc-filter gate -----------------------------------------------
# Worksheet-level filters on calc fields (Calculation_* refs) are invisible in
# CSV exports — they silently reduce row counts and break parity. Parse them
# from the dashboard layout if available; each requires either:
#   status: "translated"  — the filter has been applied to the Sigma source
#   status: "waived"      — explicitly waived with a reason
# Any unresolved filter blocks plan status to "needs_review" (never "green").
#
# The dashboard-layout path is looked up next to the --tableau dir as
# `dashboard-layout.json` (the default parse-twb-layout output location).
hidden_filters_gate = []
# v5.2 (speed): carry RESOLUTIONS forward across plan regenerations. The
# orchestrator re-runs this script on every re-entry, and a hardcoded
# 'unresolved' default silently WIPED the operator's translated/waived
# statuses — round-4 runs burned three identical Phase-6 FATALs re-doing the
# same waive (timeline-proven). Keyed by tile + calc_ref.
prior_hf = {}
if File.exist?(opts[:out])
  begin
    parsed = JSON.parse(File.read(opts[:out]))
    if parsed.is_a?(Hash)
      (parsed['hidden_filters'] || []).each do |hf|
        next unless hf.is_a?(Hash) && %w[translated waived].include?(hf['status'])
        prior_hf[[hf['tile'], hf['calc_ref']]] = hf
      end
    end
  rescue JSON::ParserError, TypeError
    nil
  end
end
# Calc-filters build-charts-from-signals.rb already carried onto a Sigma element
# (<tableau-dir>/carried-calc-filters.json). Absent ledger = [] = today's behaviour.
carried_ledger = CarriedCalcFilters.load(opts[:tab])
dash_layout_path = File.join(opts[:tab], 'dashboard-layout.json')
if File.exist?(dash_layout_path)
  begin
    dash_layout = JSON.parse(File.read(dash_layout_path))
    if dash_layout.is_a?(Array)
      # Collect all tiles in scope (scoped to matched pages/dashboards when
      # --dashboard was given; otherwise everything in the layout).
      scoped_dash_names = opts[:dashboards]&.map(&:downcase)
      dash_layout.each do |d|
        next if scoped_dash_names &&
                !scoped_dash_names.any? { |dn| d['dashboard'].to_s.downcase.include?(dn) }
        # A worksheet filter whose field is ALSO a quick filter on this
        # dashboard is not hidden — it is the visible control's own filter.
        # Left at "All" (a plain member list with no members) it restricts
        # nothing, so it cannot skew the CSV row count. A restrictive one still
        # gates, and so do wildcard, condition and top-N filters, which also
        # carry an empty member list.
        qf_caps = (d['zones'] || []).select { |qz| qz['kind'] == 'filter' }
                                    .map { |qz| qz['filter_column_caption'].to_s.downcase.gsub(/[^a-z0-9]/, '') }
        (d['zones'] || []).each do |z|
          next unless z['kind'] == 'chart'
          hf_list = z['hidden_filters']
          next if hf_list.nil? || hf_list.empty?
          hf_list.each do |hf|
            if hf['filter_type'].to_s == 'categorical' && hf['kind'].to_s == 'list' && !hf['topn'] &&
               Array(hf['members']).empty? && hf['min'].nil? && hf['max'].nil? &&
               qf_caps.include?(hf['caption'].to_s.downcase.gsub(/[^a-z0-9]/, ''))
              warn "hidden_filters gate: [#{z['caption']}] #{hf['caption']} is the dashboard's own quick filter left at All — not a hidden restriction"
              next
            end
            entry = {
              'tile'        => z['caption'],
              'calc_ref'    => hf['calc_ref'],
              'caption'     => hf['caption'],
              'filter_type' => hf['filter_type'],
              'members'     => hf['members'],
              # quantitative bounds ride along so the carry-forward fingerprint
              # (and a human reviewing the plan) can SEE a range change —
              # members-only compared trivially-equal nils (review-caught)
              'min'         => hf['min'],
              'max'         => hf['max'],
              # Default status: unresolved. Caller must set "translated" or "waived".
              'status'      => 'unresolved'
            }.compact
            if (prev = prior_hf[[entry['tile'], entry['calc_ref']]])
              # A resolution only carries when the filter DEFINITION is
              # unchanged — a waive granted for members ["2025"] must not
              # bless the same calc_ref now filtering ["2025","2026"] (the
              # 248→52-row silent wrong-numbers class this gate exists to
              # block; review-caught).
              same_def = prev['filter_type'].to_s == entry['filter_type'].to_s &&
                         Array(prev['members']).map(&:to_s).sort == Array(entry['members']).map(&:to_s).sort &&
                         prev['min'].to_s == entry['min'].to_s && prev['max'].to_s == entry['max'].to_s
              if same_def
                entry['status'] = prev['status']
                %w[waive_reason translation translated_to note].each { |k| entry[k] = prev[k] if prev[k] }
                warn "hidden_filters gate: carried '#{prev['status']}' forward for [#{entry['tile']}] #{entry['calc_ref']} (definition unchanged)"
              else
                warn "hidden_filters gate: DROPPED prior '#{prev['status']}' for [#{entry['tile']}] #{entry['calc_ref']} — " \
                     'the filter definition CHANGED (members/type differ); re-review and re-resolve it'
              end
            end
            # Machine handoff: the builder's carried-calc-filters.json ledger resolves a
            # filter it already put on the element (same tile + calc, SAME definition) —
            # no human `translated` needed. A changed definition never matches.
            if entry['status'] == 'unresolved' && carried_ledger.any?
              if (hit = CarriedCalcFilters.resolve!(entry, carried_ledger, dashboard: d['dashboard']))
                warn "hidden_filters gate: [#{entry['tile']}] #{entry['calc_ref']} translated — carried by " \
                     "build-charts-from-signals.rb (#{hit['mode']}, element #{hit['element_id']})"
              elsif CarriedCalcFilters.match(entry, carried_ledger, dashboard: d['dashboard'], same_def: false)
                warn "hidden_filters gate: [#{entry['tile']}] #{entry['calc_ref']} was carried but its definition " \
                     'CHANGED since the build (members/type/range differ) — NOT auto-resolved; rebuild charts or re-review it'
              end
            end
            hidden_filters_gate << entry
          end
        end
      end
      if hidden_filters_gate.any?
        open_hf = hidden_filters_gate.count { |hf| !%w[translated waived].include?(hf['status']) }
        warn "hidden_filters gate: #{open_hf} unresolved calc-filter(s) " \
             "(#{hidden_filters_gate.size - open_hf} carried resolved)" \
             "#{open_hf.positive? ? " — plan is 'needs_review' until each is translated or waived" : ''}"
        hidden_filters_gate.each do |hf|
          warn "  [#{hf['tile']}] #{hf['calc_ref']} (#{hf['caption']}) filter_type=#{hf['filter_type']} status=#{hf['status']}"
        end
      else
        warn "hidden_filters gate: no hidden calc-filters found in dashboard layout"
      end
    end
  rescue JSON::ParserError => e
    warn "hidden_filters gate: could not parse #{dash_layout_path}: #{e.message}"
  end
else
  warn "hidden_filters gate: no dashboard-layout.json at #{dash_layout_path} (run parse-twb-layout first)"
end

# Derive plan-level status
unresolved_hf = hidden_filters_gate.reject { |hf| %w[translated waived].include?(hf['status']) }
plan_status = unresolved_hf.any? ? 'needs_review' : 'green'
warn "plan status: #{plan_status}" \
     "#{unresolved_hf.any? ? " (#{unresolved_hf.size} unresolved hidden calc-filter(s))" : ''}"

# Wrap output. Stamp freshness (bead: stale-parity-plan): record the newest
# discovery-CSV mtime this plan's expected values were derived from, so a later
# reuse (phase6-parity.rb) can detect a plan built against OLDER data than the
# current CSVs and rebuild instead of shipping a false FAIL.
require 'time'
csv_mtime = Dir.glob(File.join(opts[:tab], 'views', '*.csv'))
               .map { |f| File.mtime(f).to_i }.max || 0
# Composite-dashboard route. Tableau commonly exposes ONE dashboard-level CSV
# while all plotted worksheets remain embedded. Checking `csv_mtime.zero?`
# misclassified that shape because the dashboard CSV made views/*.csv non-empty
# even though ZERO CSVs were usable as per-chart source oracles. Classify CSVs
# by whether they name a scoped dashboard/page. When no worksheet CSV exists,
# keep charts empty and explicitly route the final gate to anchors + warehouse
# exports. Do NOT emit expected:null stubs: empty expected + empty actual rows
# compare equal and can manufacture vacuous 100% parity.
csv_backed_views = views.select do |view|
  File.exist?(McpSource.csv_path(opts[:tab], view))
end
dashboard_names = pages.map { |page| page['name'].to_s }.reject(&:empty?)
if defined?(dash_layout) && dash_layout.is_a?(Array)
  selected = dash_layout
  if opts[:dashboards]&.any?
    wanted = opts[:dashboards].map(&:downcase)
    selected = selected.select do |dashboard|
      wanted.any? { |name| dashboard['dashboard'].to_s.downcase.include?(name) }
    end
  end
  dashboard_names.concat(selected.map { |dashboard| dashboard['dashboard'].to_s })
end
dashboard_norms = dashboard_names.map { |name| normalize(name) }.reject(&:empty?).to_set
dashboard_csv_views, worksheet_csv_views = csv_backed_views.partition do |view|
  dashboard_norms.include?(normalize(view['name']))
end
oracle_mode = nil
if plan_entries.empty? && sigma_charts.any?
  if worksheet_csv_views.empty?
    oracle_mode = 'anchors-warehouse'
    plan_status = 'oracle_required' unless unresolved_hf.any?
    warn "COMPOSITE dashboard: #{dashboard_csv_views.size} dashboard-level CSV(s), " \
         "0 usable worksheet CSVs for #{sigma_charts.size} Sigma chart(s)."
    warn '  Phase 6 source parity routes to exact-target anchors + warehouse exports; MCP is optional.'
    warn '  No expected:null stubs were emitted, so this plan cannot report vacuous empty-plan parity.'
  else
    names = worksheet_csv_views.map { |view| view['name'] }.sort
    abort("auto-parity-plan.rb: matched 0 charts even though worksheet CSV(s) exist: " \
          "#{names.join(', ')}. This is a provenance/rename mismatch, not a composite-dashboard case.")
  end
end

output = {
  'workbook_id'          => opts[:wb_id],
  'extract'              => extract,
  'charts'               => plan_entries,
  'chart_inventory'      => chart_inventory,
  'hidden_filters'       => hidden_filters_gate,
  'plan_status'          => plan_status,
  'composite_stub'       => false,
  'oracle_mode'          => oracle_mode,
  'dashboard_csv_views'  => dashboard_csv_views.map { |view| view['name'] }.sort,
  'worksheet_csv_views'  => worksheet_csv_views.map { |view| view['name'] }.sort,
  'generated_at'         => Time.now.utc.iso8601,
  'source_csv_max_mtime' => csv_mtime
}
File.write(opts[:out], JSON.pretty_generate(output))

puts "wrote #{opts[:out]}"
puts "  charts matched: #{plan_entries.size}"
puts "  extract flag:   #{extract}"
if oracle_mode
  puts '  next: verify exact-target source anchors and live warehouse-backed element exports.'
  puts '        MCP is optional; do not synthesize chart parity without a source worksheet CSV.'
else
  puts '  next: collect chart actuals with collect-parity-actuals.rb (Sigma REST export).'
  puts '        Use Sigma MCP only for any explicitly reported remainder.'
end
