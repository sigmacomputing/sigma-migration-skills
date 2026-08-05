# frozen_string_literal: true
#
# recipe_multimetric.rb — post-process transform that rewrites a built workbook
# spec into the "multi-metric region dashboard" recipe shape (refs/fidelity-
# recipes.md). Runs AFTER build-charts + build_wb_spec assemble the spec, so it
# needs no surgery inside the 5k-line generator — it detects the pattern from
# png-read.json and rewrites the spec in place (the mechanical-specs philosophy,
# applied to the workbook).
#
# The pattern: a list control that FILTERS some tiles (`target_tiles`) but only
# HIGHLIGHTS others (`highlight_tiles`) — e.g. a Region control that filters the
# Trend/Top panels while the Year-on-Year bars show ALL regions with the selected
# one recolored. Left un-transformed, the control collapses every tile to one
# region and "Top" tables show rollup rows (regions) summed across all years.
#
# What apply! does when `applicable?`:
#   1. Clone the control-filtered master → an UNFILTERED `masterAll`.
#   2. Retarget each highlight tile to `masterAll` (rewrites [Master/…] refs) and
#      add a highlight category column + grey/brand color scheme.
#   3. Rewrite point-in-time "Top-N" + magnitude measures to
#      Sum(If([Year]=<latest> And <entity scope>, m, null)) and ensure the Top
#      table is GROUPED by its entity (never ungrouped → 456 rows). The entity
#      scope is Not IsNull([<entity_discriminator>]) by default, or — when
#      png-read point_in_time carries a `rollup_flag`
#      {column, rollup_values[], entity_values[]} (a FLAG-valued discriminator:
#      every row non-null, rollups marked by value) — equality predicates on the
#      flag column. All pit field names resolve against the master columns with
#      caption-variant normalization (upcase + strip non-alphanumerics), so a UI
#      caption, an extract caption, and the landed physical name all match.
#
# Tolerant by design: never raises on an unexpected shape — it skips what it
# can't match and returns a summary of what changed (the caller logs it). Pure
# data transform (no I/O) so it is unit-testable spec-in → spec-out.

require 'json'
require 'set'

module RecipeMultimetric
  module_function

  HL_SCHEME = ['#c9d1d3', '#027b8e'].freeze # unselected grey / selected brand-teal
  # Compact SI number format (17.9T / 1.77T) — matches the clean reference; raw
  # ",.0f" prints 15-digit values that overflow axes/labels.
  SI_FMT = { 'kind' => 'number', 'formatString' => ',.3~s' }.freeze

  # Applicable iff png-read declares at least one control with highlight_tiles.
  def applicable?(png_read)
    fs = (png_read || {})['filter_shelf']
    fs.is_a?(Array) && fs.any? { |f| f.is_a?(Hash) && Array(f['highlight_tiles']).reject { |t| t.to_s.strip.empty? }.any? }
  end

  def norm(s)
    s.to_s.downcase.strip
  end

  # ---- caption-variant field resolution (G9 run-2 misfire) ------------------
  # The same field travels under THREE spellings: the Tableau UI caption
  # ("Entity Group"), the extract caption ("EntityGroup") and the landed
  # physical column (ENTITYGROUP). Exact-string checks broke every consumer in
  # the field run: the retain/WHERE/guard paths each compared a different pair
  # of spellings and each silently skipped. Normalize BOTH sides — upcase +
  # strip all non-alphanumerics — so any variant matches any other.
  def norm_key(s)
    s.to_s.upcase.gsub(/[^0-9A-Z]/, '')
  end

  # The first candidate naming the same field as `name` (exact case-insensitive
  # first, then normalized-key). nil when nothing matches.
  def resolve_field(name, candidates)
    return nil if name.to_s.strip.empty?
    cands = Array(candidates).compact.map(&:to_s).reject(&:empty?)
    exact = cands.find { |c| c.casecmp?(name.to_s) }
    return exact if exact
    want = norm_key(name)
    return nil if want.empty?
    cands.find { |c| norm_key(c) == want }
  end

  # Resolve a png-read scoping column (entity_discriminator / rollup_flag.column)
  # against the LANDED columns so the SQL-side synthesizers (world-by-year, YoY)
  # accept it. real_map = the landing manifest's caption→physical map for the
  # fact table; fact_captions = the projected DM fact's column display names
  # (the no-manifest fallback). Returns
  #   { 'name' => <form to pass downstream>, 'physical' => <landed col or nil>,
  #     'resolved' => bool, 'candidates' => [<landed columns to pick from>] }.
  # A resolved 'name' is either a manifest caption KEY (phys() maps it) or the
  # physical column itself — both survive the synthesizers' sql_usable check.
  # resolved=false means the caller MUST be loud (the run-2 rollup-exclusion
  # WHERE was silently omitted here); never proceed quietly.
  def resolve_scope_column(name, real_map: nil, fact_captions: [])
    n = name.to_s.strip
    return { 'name' => nil, 'physical' => nil, 'resolved' => true, 'candidates' => [] } if n.empty?
    if real_map.is_a?(Hash) && !real_map.empty?
      k = resolve_field(n, real_map.keys)
      return { 'name' => k, 'physical' => real_map[k].to_s, 'resolved' => true, 'candidates' => [] } if k
      v = resolve_field(n, real_map.values)
      return { 'name' => v, 'physical' => v, 'resolved' => true, 'candidates' => [] } if v
      return { 'name' => nil, 'physical' => nil, 'resolved' => false,
               'candidates' => real_map.values.map(&:to_s).uniq }
    end
    caps = Array(fact_captions).compact.map(&:to_s).reject(&:empty?)
    if caps.any?
      c = resolve_field(n, caps)
      return { 'name' => c, 'physical' => nil, 'resolved' => true, 'candidates' => [] } if c
      return { 'name' => nil, 'physical' => nil, 'resolved' => false, 'candidates' => caps }
    end
    # Nothing to check against (no manifest, no projected fact) — pass through;
    # the synthesizers' own guards still apply.
    { 'name' => n, 'physical' => nil, 'resolved' => true, 'candidates' => [] }
  end

  # ---- rollup_flag (flag-valued discriminator; png-read point_in_time) -------
  # IsNull semantics cannot express a FLAG column ('Y' on rollup rows / 'N' on
  # entity rows / NULL on neither): every row is non-null, so Not IsNull keeps
  # the rollups. Optional png-read block:
  #   "rollup_flag": { "column": "<flag col>",
  #                    "rollup_values": ["Y"], "entity_values": ["N"] }
  # entity_values present → keep ONLY those (strict); else rollup_values →
  # exclude those, keeping NULL-flag rows. Falls back to the IsNull
  # entity_discriminator semantics when absent.
  def validate_rollup_flag(pit)
    return [] unless pit.is_a?(Hash) && !pit['rollup_flag'].nil?
    rf = pit['rollup_flag']
    unless rf.is_a?(Hash)
      return ['point_in_time.rollup_flag must be an object { column, rollup_values[], entity_values[] }']
    end
    errs = []
    errs << 'point_in_time.rollup_flag.column is required (the flag column name)' if rf['column'].to_s.strip.empty?
    %w[rollup_values entity_values].each do |k|
      next if rf[k].nil?
      unless rf[k].is_a?(Array) && rf[k].none? { |v| v.is_a?(Hash) || v.is_a?(Array) }
        errs << "point_in_time.rollup_flag.#{k} must be an array of scalar values"
      end
    end
    if errs.empty? &&
       Array(rf['rollup_values']).reject { |v| v.to_s.strip.empty? }.empty? &&
       Array(rf['entity_values']).reject { |v| v.to_s.strip.empty? }.empty?
      errs << 'point_in_time.rollup_flag needs rollup_values and/or entity_values (at least one non-empty)'
    end
    errs
  end

  def rollup_flag_active?(pit)
    pit.is_a?(Hash) && pit['rollup_flag'].is_a?(Hash) &&
      !pit['rollup_flag']['column'].to_s.strip.empty? && validate_rollup_flag(pit).empty?
  end

  # Does the point-in-time block carry ANY real-entity scoping (flag or IsNull)?
  def entity_scope?(pit)
    rollup_flag_active?(pit) ||
      (pit.is_a?(Hash) && pit['entity_discriminator'] && !pit['entity_discriminator'].to_s.strip.empty?)
  end

  # Sigma-formula literal for a flag value.
  def fmla_lit(v)
    v.is_a?(Numeric) ? v.to_s : %("#{v.to_s.gsub('"') { '\"' }}")
  end

  # SQL literal for a flag value (single quotes doubled).
  def sql_lit(v)
    v.is_a?(Numeric) ? v.to_s : "'#{v.to_s.gsub("'", "''")}'"
  end

  # The real-entity condition for the snapshot measures: equality predicates on
  # the rollup flag when declared, else Not IsNull(discriminator), else nil.
  def entity_condition(prefix, pit)
    if rollup_flag_active?(pit)
      rf = pit['rollup_flag']
      col = "[#{prefix}/#{rf['column']}]"
      ev = Array(rf['entity_values']).reject { |v| v.to_s.strip.empty? }
      rv = Array(rf['rollup_values']).reject { |v| v.to_s.strip.empty? }
      if ev.any?
        return "(#{ev.map { |v| "#{col} = #{fmla_lit(v)}" }.join(' Or ')})"
      elsif rv.any?
        # keep NULL-flag rows: only the named rollup values are excluded.
        return "(IsNull(#{col}) Or Not (#{rv.map { |v| "#{col} = #{fmla_lit(v)}" }.join(' Or ')}))"
      end
    end
    discr = pit.is_a?(Hash) && pit['entity_discriminator']
    return "Not IsNull([#{prefix}/#{discr}])" if discr && !discr.to_s.strip.empty?
    nil
  end

  # SQL predicate replacing the synthesizers' `"COL" IS NOT NULL` rollup
  # exclusion when a flag-valued discriminator is declared.
  def rollup_where_sql(flag, col)
    ev = Array(flag['entity_values']).reject { |v| v.to_s.strip.empty? }
    rv = Array(flag['rollup_values']).reject { |v| v.to_s.strip.empty? }
    if ev.any?
      %("#{col}" IN (#{ev.map { |v| sql_lit(v) }.join(', ')}))
    elsif rv.any?
      %(("#{col}" NOT IN (#{rv.map { |v| sql_lit(v) }.join(', ')}) OR "#{col}" IS NULL))
    end
  end

  # The DM-side twin of entity_condition: rewrite the synthesized helper SQL
  # elements' rollup-exclusion WHERE ("COL" IS NOT NULL — emitted by
  # synthesize_fixed_lods!/synthesize_yoy_by_dim! for the discriminator we
  # passed) into the flag equality predicate. Only the two known synthesized
  # helpers are touched. Returns the count of statements rewritten.
  ROLLUP_SQL_HELPER_IDS = %w[el-world-by-year el-yoy-by-dim].freeze
  def apply_rollup_flag_where!(model, flag)
    return 0 unless model.is_a?(Hash) && flag.is_a?(Hash)
    n = 0
    (model['pages'] || []).each do |p|
      (p['elements'] || []).each do |el|
        next unless ROLLUP_SQL_HELPER_IDS.include?(el['id'].to_s)
        src = el['source']
        next unless src.is_a?(Hash) && src['kind'] == 'sql'
        st = src['statement'].to_s
        new_st = st.gsub(/"([^"]+)"\s+IS\s+NOT\s+NULL/i) do
          rollup_where_sql(flag, Regexp.last_match(1)) || Regexp.last_match(0)
        end
        next if new_st == st
        src['statement'] = new_st
        n += 1
      end
    end
    n
  end

  def all_elements(spec)
    (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
  end

  # element whose display name matches a png-read tile title (build-charts sets
  # element['name'] = the chart-zone caption = the tile title).
  def elements_by_title(spec)
    idx = {}
    all_elements(spec).each { |e| idx[norm(e['name'])] = e if e['name'] }
    idx
  end

  # The control-filtered master = the table element a control's filters point at
  # (fallback: the lone data-model-sourced table element).
  def find_master(spec, control)
    fid = (Array(control['filters']).first || {}).dig('source', 'elementId')
    fid ||= control.dig('source', 'source', 'elementId')
    els = all_elements(spec)
    (fid && els.find { |e| e['id'] == fid }) ||
      els.find { |e| e.dig('source', 'kind') == 'data-model' && e['kind'] == 'table' }
  end

  # Main entry — mutate `spec` in place; returns a summary hash. `png_read` is the
  # parsed png-read.json. Never raises.
  def apply!(spec, png_read, world_lod_map: {}, yoy_map: {})
    summary = { applied: false, masters_added: 0, highlight_tiles: 0, top_tables: 0, trends: 0, notes: [] }
    return summary unless spec.is_a?(Hash) && applicable?(png_read)
    world_lod_map ||= {}
    yoy_map ||= {}

    pit = (png_read['point_in_time'] || {}).dup
    by_title = elements_by_title(spec)
    # png-read tiles[].measure = the metric column the tile plots (agent-recorded
    # in Phase 1d) — the reliable source for rebuilding a bar's obscured measure.
    tile_measure = {}
    Array(png_read['tiles']).each do |t|
      next unless t.is_a?(Hash) && t['measure']
      if t['measure'].is_a?(Hash)
        # {"manual_residue": "<calc>"} — the tile plots a requires_custom_sql
        # window/table-calc residue. NOT a rebuildable magnitude: leave the
        # measure alone for the Custom SQL binding (manual-residues.json).
        mr = t['measure']['manual_residue']
        summary[:notes] << "tile '#{t['title']}' measure is a MANUAL residue ('#{mr}') — left for the Custom SQL binding (manual-residues.json)" if mr
        next
      end
      tile_measure[norm(t['title'])] = t['measure']
    end

    # rollup_flag validation FIRST (an invalid block must never half-apply).
    rf_errs = validate_rollup_flag(pit)
    if rf_errs.any?
      rf_errs.each { |e| summary[:notes] << "rollup_flag INVALID: #{e} — rollup_flag IGNORED (IsNull discriminator fallback, if any)" }
      pit.delete('rollup_flag')
    end

    # Discriminator/year/flag guard: the point-in-time rewrite refs [Master/<discr>]
    # and [Master/<year>]. The MECHANICAL data model retains only PLOTTED columns, so
    # a png-read discriminator that the source never plotted is often surfaced onto
    # the master under a VARIANT spelling (retain_columns! adds the LANDED physical
    # name, e.g. ENTITYGROUP for the UI caption "Entity Group"). G9 run-2 misfire:
    # this guard compared exact downcased strings, missed the variant, DELETED the
    # pit fields, and every snapshot measure silently degraded to a raw Sum().
    # Now: resolve each pit field against the master columns with caption-variant
    # normalization (norm_key) and REWRITE the pit field to the master's actual
    # column name so every generated formula refs a real column. A field that
    # STILL doesn't resolve is dropped with a note naming the candidate columns —
    # fabricating [Master/<missing>] would dangle and fail the workbook POST.
    master_probe = find_master(spec, all_elements(spec).find { |e| e['kind'] == 'control' } || {})
    m_disp = master_probe ? (master_probe['columns'] || []).map { |c| col_disp(c) }.compact : nil
    if m_disp
      cand_note = "Master columns: #{m_disp.first(24).join(', ')}"
      d = pit['entity_discriminator']
      if d && !d.to_s.strip.empty?
        hit = resolve_field(d, m_disp)
        if hit
          summary[:notes] << "discriminator '#{d}' resolved to master column '#{hit}' (caption-variant match)" if hit != d
          pit['entity_discriminator'] = hit
        else
          summary[:notes] << "discriminator '#{d}' matches NO master column (case/spacing/punctuation variants checked) — " \
                             "point-in-time real-entity filter SKIPPED; Top/bar measures may include aggregate rows. #{cand_note}"
          pit.delete('entity_discriminator')
        end
      end
      if rollup_flag_active?(pit)
        rc = pit['rollup_flag']['column']
        hit = resolve_field(rc, m_disp)
        if hit
          summary[:notes] << "rollup_flag column '#{rc}' resolved to master column '#{hit}' (caption-variant match)" if hit != rc
          pit['rollup_flag']['column'] = hit
        else
          summary[:notes] << "rollup_flag column '#{rc}' matches NO master column (case/spacing/punctuation variants checked) — " \
                             "rollup_flag SKIPPED (IsNull discriminator fallback, if any). #{cand_note}"
          pit.delete('rollup_flag')
        end
      end
      yc = pit['year_column'] || 'Year'
      if pit['latest_year']
        hit = resolve_field(yc, m_disp)
        if hit
          pit['year_column'] = hit
        else
          summary[:notes] << "year column '#{yc}' matches NO master column (case/spacing/punctuation variants checked) — " \
                             "latest-year point-in-time filter SKIPPED. #{cand_note}"
          pit.delete('latest_year')
        end
      end
    end

    Array(png_read['filter_shelf']).each do |ctl_spec|
      next unless ctl_spec.is_a?(Hash)
      hl_titles = Array(ctl_spec['highlight_tiles']).map { |t| norm(t) }.reject(&:empty?)
      next if hl_titles.empty?

      # Resolve the live control element for this filter_shelf entry (by label).
      control = all_elements(spec).find do |e|
        e['kind'] == 'control' && [norm(e['name']), norm(e['label'])].include?(norm(ctl_spec['label']))
      end
      control ||= all_elements(spec).find { |e| e['kind'] == 'control' }
      next unless control

      master = find_master(spec, control)
      next unless master

      # The point-in-time rewrite refs [Master/<year>] and [Master/<discriminator>];
      # a mechanical master often omits the discriminator (it isn't plotted). Add
      # any missing ones from the DM element BEFORE cloning, so masterAll gets them
      # too and no rewrite produces a dangling ref.
      dm_prefix = master_dm_prefix(master)
      need = [pit['year_column'] || 'Year', pit['entity_discriminator'],
              (rollup_flag_active?(pit) ? pit['rollup_flag']['column'] : nil)]
             .compact.reject { |f| f.to_s.strip.empty? }
      ensure_columns!(master, need, dm_prefix) if dm_prefix && (pit['latest_year'] || entity_scope?(pit))

      master_all = ensure_master_all!(spec, master)
      summary[:masters_added] += 1 if master_all[:added]
      ma_name = master_all[:element]['name']
      master_name = master['name']

      # The dimension the control binds (for the highlight predicate).
      dim_col = (master['columns'] || []).find { |c| c['id'] == control.dig('source', 'columnId') }
      dim_name = dim_col && dim_col['name']
      ctl_ref = control['controlId'] || control['id']

      hl_titles.each do |t|
        el = by_title[t]
        next unless el
        retarget_to_master_all!(el, master_name, ma_name)
        # A data-scoping control has no bound columnId, so dim_name is nil — fall
        # back to the tile's OWN category dimension (a bare [ma/Field] ref) so the
        # selected-region highlight still gets built.
        hl_dim = dim_name || tile_dimension(el)
        add_highlight_column!(el, ma_name, hl_dim, ctl_ref) if hl_dim
        # The bar's measure is often a `(copy)` %-change calc the converter can't
        # decompose (renders literal 0). When png-read records the tile's metric,
        # replace it with the latest-year magnitude (the intentional approximation
        # of the source's proprietary growth measure).
        m = tile_measure[t]
        rewrite_bar_measure!(el, ma_name, m, pit) if m && !m.to_s.strip.empty?
        # The signed YoY % the source prints beside each bar — a REAL measure
        # (pairwise-complete helper surfaced on the master by the DM synthesis),
        # so the anchors gate can verify the printed percentages.
        if m && (yc = yoy_map[m.to_s.downcase])
          add_yoy_column!(el, ma_name, yc)
        end
        summary[:highlight_tiles] += 1
      end
    end

    # Point-in-time Top-N / magnitude tables + bars: rewrite measures + group.
    if entity_scope?(pit) || pit['latest_year']
      all_elements(spec).each do |el|
        next unless top_table?(el) || bar?(el)
        n = rewrite_point_in_time!(el, pit)
        summary[:top_tables] += n
      end
    else
      summary[:notes] << 'no point_in_time in png-read — Top-N/bar measures left as-is (regions may show as entities, all-years sums)'
    end

    # Trend dual-axis: a line/combo tile carrying a synthesized "<M> World" column
    # should plot the region-filtered Country line Sum([Master/<M>]) opposite the
    # World line on a second axis. build-charts often emits only the World measure
    # single-axis (the country line is a copy-calc it can't decompose, or the World
    # column won as the sole measure). Uses world_lod_map (world col -> source
    # metric) to recover the correct metric column (name-inference is unreliable:
    # "Revenue World" != the metric column "Revenue (current US$)").
    unless world_lod_map.empty?
      all_elements(spec).each { |el| summary[:trends] += ensure_dual_axis_trend!(el, world_lod_map) }
    end

    summary[:applied] = summary[:highlight_tiles].positive? || summary[:top_tables].positive? || summary[:trends].positive?
    summary
  end

  # ---- helpers --------------------------------------------------------------

  # The DM element name that a master's base columns reference ([<DMElement>/x]).
  def master_dm_prefix(master)
    (master['columns'] || []).each do |c|
      m = c['formula'].to_s.match(/\A\[([^\/\]]+)\/[^\]]+\]\z/)
      return m[1] if m
    end
    nil
  end

  # Ensure `el` exposes a base column for each field name (case-insensitive),
  # adding [<dm_prefix>/<field>] where missing. Idempotent.
  def ensure_columns!(el, fields, dm_prefix)
    have = (el['columns'] || []).map { |c| c['name'].to_s.downcase }
    fields.each do |f|
      next if have.include?(f.to_s.downcase)
      id = "pit-#{f.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')}"
      (el['columns'] ||= []) << { 'id' => id, 'name' => f, 'formula' => "[#{dm_prefix}/#{f}]" }
      el['order'] << id if el['order'].is_a?(Array)
      have << f.to_s.downcase
    end
  end

  # Add an UNFILTERED clone of `master` (same DM source + columns, new ids/name)
  # to the master's page, once. Returns {element:, added:}.
  def ensure_master_all!(spec, master)
    existing = all_elements(spec).find { |e| e['id'] == 'masterAll' }
    return { element: existing, added: false } if existing

    clone = JSON.parse(JSON.generate(master))
    clone['id'] = 'masterAll'
    clone['name'] = "#{master['name']} All"
    (clone['columns'] || []).each { |c| c['id'] = "ma-#{c['id']}" }
    clone['order'] = clone['order'].map { |id| "ma-#{id}" } if clone['order']
    page = (spec['pages'] || []).find { |p| (p['elements'] || []).any? { |e| e['id'] == master['id'] } }
    (page['elements'] ||= []) << clone if page
    { element: clone, added: true }
  end

  # Retarget an element from `master` to `masterAll`: swap source.elementId and
  # rewrite [<MasterName>/…] formula prefixes to [<MasterAllName>/…].
  def retarget_to_master_all!(el, master_name, ma_name)
    src = el['source'] || {}
    el['source'] = src.merge('elementId' => 'masterAll') if src['elementId']
    pfx = /\[#{Regexp.escape(master_name)}\//
    (el['columns'] || []).each { |c| c['formula'] = c['formula'].to_s.gsub(pfx, "[#{ma_name}/") }
  end

  # Add an "Selected region" category column + grey/brand color scheme so the
  # control drives COLOR (not a filter) on the tile.
  def add_highlight_column!(el, ma_name, dim_name, ctl_ref)
    return if (el['columns'] || []).any? { |c| c['name'] == 'Selected' }
    hid = "hl-#{el['id']}"
    (el['columns'] ||= []) << {
      'id' => hid, 'name' => 'Selected',
      'formula' => %(If([#{ma_name}/#{dim_name}] = [#{ctl_ref}], "Selected region", "Other"))
    }
    el['order'] << hid if el['order'].is_a?(Array)
    el['color'] = { 'by' => 'category', 'column' => hid, 'scheme' => HL_SCHEME }
  end

  # Add the surfaced "<Metric> YoY" master column to a bar tile as a visible
  # signed-percent measure (Max over the per-category rows — the relationship
  # join makes it constant within a category). Idempotent.
  def add_yoy_column!(el, ma_name, yoy_col)
    return if (el['columns'] || []).any? { |c| c['name'] == 'YoY %' }
    id = "yoy-#{el['id']}"
    (el['columns'] ||= []) << {
      'id' => id, 'name' => 'YoY %',
      'formula' => "Max([#{ma_name}/#{yoy_col}])",
      'format' => { 'kind' => 'number', 'formatString' => '+.0%' }
    }
    el['order'] << id if el['order'].is_a?(Array)
  end

  def top_table?(el)
    el['kind'] == 'table' &&
      (Array(el['filters']).any? { |f| f['kind'] == 'top-n' } || norm(el['name']).include?('top'))
  end

  def bar?(el)
    el['kind'] == 'bar-chart'
  end

  # Rewrite the tile's MEASURE column(s) to a latest-year + real-entity
  # conditional, and (tables) ensure a groupBy on the dimension. Returns count of
  # measures rewritten.
  # Resolve the snapshot year for a metric. `latest_year` may be a scalar (one
  # year for all measures) or a per-measure map {metric => year} — UNITS ends 2014
  # while REV/NFI end 2015, so a single year blanks UNITS.
  # Resolve the snapshot year for a measure. Phase 1d records shorthand keys
  # ({"REV"=>2015, "UNITS"=>2014} — the schema's own example) while the measure
  # column is the full caption, and some captions never contain the shorthand
  # at all ("NFI" vs "Net investor inflows, quarterly (BoP, current
  # US$)" — live-caught: that miss shipped an ALL-YEARS sum as a "top" table).
  # Tiered match, longest key wins per tier:
  #   1. exact caption match (case-insensitive)
  #   2. key as a whole WORD of the caption ("REV" ∈ "Revenue (current US$)",
  #      boundary-guarded so "REV" ∉ "REVPP Value")
  #   3. key as a whole word of the TILE TITLE (context — "NFI" ∈ "NFI Top3")
  #   4. key as a word PREFIX of caption or title ("NFI" ∈ "NFIPie")
  def latest_year_for(pit, metric, context: nil)
    ly = pit['latest_year']
    return ly unless ly.is_a?(Hash)
    exact = ly[metric] || ly[metric.to_s] ||
            ly.find { |k, _| k.to_s.downcase == metric.to_s.downcase }&.last
    return exact if exact
    m = metric.to_s.downcase
    ctx = context.to_s.downcase
    word   = ->(k, t) { !t.empty? && t =~ /(\A|[^a-z0-9])#{Regexp.escape(k)}([^a-z0-9]|\z)/ }
    prefix = ->(k, t) { !t.empty? && t =~ /(\A|[^a-z0-9])#{Regexp.escape(k)}/ }
    tiers = [->(k) { word.call(k, m) },
             ->(k) { word.call(k, ctx) },
             ->(k) { prefix.call(k, m) || prefix.call(k, ctx) }]
    tiers.each do |match|
      best = ly.select { |k, _| !k.to_s.empty? && match.call(k.to_s.downcase) }
               .max_by { |k, _| k.to_s.length }
      return best.last if best
    end
    nil
  end

  # The point-in-time conditional Sum(If([Year]=<ly> And <entity scope>, base, null)).
  # Entity scope = rollup_flag equality predicates when declared, else the
  # IsNull discriminator (entity_condition).
  def pit_conditional(prefix, base_field, pit, metric, context: nil)
    ly = latest_year_for(pit, metric, context: context)
    conds = []
    conds << "[#{prefix}/#{pit['year_column'] || 'Year'}] = #{ly}" if ly
    ec = entity_condition(prefix, pit)
    conds << ec if ec
    base = "[#{prefix}/#{base_field}]"
    conds.empty? ? "Sum(#{base})" : "Sum(If(#{conds.join(' And ')}, #{base}, null))"
  end

  def rewrite_point_in_time!(el, pit)
    prefix = measure_prefix(el)
    return 0 unless prefix

    n = 0
    rewritten_ids = []
    (el['columns'] || []).each do |c|
      inner = base_metric_ref(c['formula'], prefix)
      next unless inner # only aggregated base-metric measures
      next unless latest_year_for(pit, inner, context: el['name']) || entity_scope?(pit)
      c['formula'] = pit_conditional(prefix, inner, pit, inner, context: el['name'])
      c['format'] = SI_FMT # compact SI (raw ",.0f" overflows the cell)
      rewritten_ids << c['id']
      n += 1
    end
    # Top-table cleanup to match the reference: drop the spurious Date column
    # build-charts carries onto a point-in-time table (it shows "2015-01-01"),
    # leaving just the entity + value.
    if el['kind'] == 'table' && n.positive?
      # Capture the dropped Date column ids so we can also strip anything that
      # references them. The latest-year snapshot is now INLINED into the measure
      # (Sum(If([Year]=<ly>...))), so build-charts' hidden Date passthrough column
      # (id "f-<el>-date") AND the list filter that referenced it are redundant —
      # and leaving the filter behind dangles a "Dependency not found" ref that
      # 400s the whole PUT/POST (found dogfooding --reuse-workbook, 2026-07-09).
      dropped_ids = (el['columns'] || []).select { |c| col_disp(c).to_s.downcase == 'date' }
                                         .map { |c| c['id'] }.to_set
      unless dropped_ids.empty?
        el['columns'] = (el['columns'] || []).reject { |c| dropped_ids.include?(c['id']) }
        el['order'] = el['order'].reject { |id| dropped_ids.include?(id) } if el['order'].is_a?(Array)
        el['filters'] = Array(el['filters']).reject { |f| dropped_ids.include?(f['columnId']) } if el['filters']
      end
    end

    if el['kind'] == 'table' && n.positive?
      ensure_grouped!(el)
      # A "Top-Countries" table ranks the ENTITY by the point-in-time measure and
      # keeps the top few — so the grouping must sort by the MEASURE (not the
      # dimension the build carried over from Tableau's alpha sort), and a top-n
      # filter (nulls excluded) trims the long tail. Without this the table shows
      # all 47 entities alphabetically with null-metric rows on top instead of the
      # real top-8 by value.
      promote_top_n!(el, rewritten_ids.first)
      # Value-gradient cells (source look: value column shaded light→brand teal,
      # top row darkest). backgroundScale is spec-supported on tables (verified —
      # refs/workbook-layout.md); hex colors only (rgb() trips the WAF).
      unless Array(el['conditionalFormats']).any? { |cf| cf['type'] == 'backgroundScale' }
        (el['conditionalFormats'] ||= []) << {
          'type' => 'backgroundScale', 'columnIds' => rewritten_ids.dup,
          'scheme' => ['#f4f9fa', '#027b8e'], 'includeValues' => true
        }
      end
    end
    n
  end

  # Sort an already-grouped top table by its point-in-time measure (desc) and add
  # a top-8 rank filter (nulls excluded) if none is present. No-op without a
  # measure id or a grouping.
  def promote_top_n!(el, measure_id)
    return unless measure_id
    grp = Array(el['groupings']).first
    grp['sort'] = [{ 'columnId' => measure_id, 'direction' => 'descending' }] if grp
    return if Array(el['filters']).any? { |f| f['kind'] == 'top-n' }
    (el['filters'] ||= []) << {
      'id' => "topn-#{el['id']}", 'columnId' => measure_id, 'kind' => 'top-n',
      'rankingFunction' => 'row-number', 'mode' => 'top-n', 'rowCount' => 8,
      'includeNulls' => 'never'
    }
  end

  # The formula prefix used by this element's columns ([<prefix>/Field]).
  def measure_prefix(el)
    (el['columns'] || []).each do |c|
      m = c['formula'].to_s.match(/\[([^\/\]]+)\//)
      return m[1] if m
    end
    nil
  end

  # If the formula is a single aggregate over one base ref (Sum([P/Metric])),
  # return the inner field name; else nil (leave dimensions / composite calcs).
  def base_metric_ref(formula, prefix)
    m = formula.to_s.match(/\A(?:Sum|Avg|Average|Min|Max|Total)\(\s*\[#{Regexp.escape(prefix)}\/([^\]]+)\]\s*\)\z/i)
    m && m[1]
  end

  # Reshape a trend line/combo tile that carries a synthesized "<M> World" column
  # into a dual-axis Country-vs-World chart: add the region-filtered Country line
  # Sum([<prefix>/<metric>]) (metric recovered from world_lod_map) and put the
  # World line on yAxis2. Returns 1 if reshaped, else 0 (not a candidate, or the
  # full dual-axis structure is already in place — idempotent).
  def ensure_dual_axis_trend!(el, world_lod_map)
    kind = el['kind'].to_s
    return 0 unless %w[line-chart combo-chart area-chart].include?(kind)
    cols = el['columns'] || []
    # The World column: its display name is a world_lod_map key (e.g. "Revenue World").
    # Caption-variant normalized match — a display-name variant ("Revenue world" /
    # "Revenue  World") must not silently exclude one of otherwise-identical trends.
    wmap = {}
    world_lod_map.each { |k, v| wmap[norm_key(k)] = v }
    world_col = cols.find { |c| wmap.key?(norm_key(col_disp(c))) }
    return 0 unless world_col
    metric = wmap[norm_key(col_disp(world_col))]
    return 0 if metric.to_s.empty?
    prefix = (world_col['formula'].to_s[/\[([^\/\]]+)\//, 1]) || 'Master'
    country_col = cols.find { |c| base_metric_ref(c['formula'], prefix) == metric }
    # G9 run-2 misfire (dual-axis emitted for ONE of three structurally identical
    # trends): a tile whose Country line ALREADY existed (build-charts decomposed
    # the measure on some tiles, not others) EARLY-RETURNED here and never got the
    # combo/yAxis2/World-Max treatment its siblings got. Only skip when the FULL
    # dual-axis structure is already in place (idempotent re-run); a pre-existing
    # Country line otherwise just skips the add-column step.
    if country_col && el['kind'] == 'combo-chart' &&
       Array(el.dig('yAxis2', 'columnIds')).include?(world_col['id'])
      return 0
    end

    unless country_col
      country_col = { 'id' => "trend-country-#{el['id']}", 'name' => "Country #{metric}",
                      'formula' => "Sum([#{prefix}/#{metric}])", 'format' => SI_FMT }
      (el['columns'] ||= []) << country_col
      el['order'] << country_col['id'] if el['order'].is_a?(Array)
    end
    country_id = country_col['id']
    # World line: aggregate to one value per x with Max — the per-year global
    # total is constant within a year, so Sum over the (region-filtered) rows the
    # trend rides multiplies it by the row count and inflates the axis. build-charts
    # usually emits it as Sum([P/<M> World]); rewrite the OUTER aggregate to Max
    # (not just the bare no-agg case) so the World line reads its true per-year value.
    wref = world_col['formula'].to_s
    world_col['formula'] =
      if (m = wref.match(/\A(?:Sum|Avg|Average|Min|Max|Total)\((.*)\)\z/m))
        "Max(#{m[1]})"
      else
        "Max(#{wref})"
      end
    world_col['format'] = SI_FMT
    el['kind'] = 'combo-chart'
    # DUAL AXIS, matching the source design: Country on the left, World on the
    # right — separate scales make the two lines TRACK each other (the reading
    # the source composes; one shared axis pins the region to the floor of the
    # world total). Raw 15-digit ticks are prevented by the SI column formats,
    # not by collapsing the axes.
    # Dual-axis spec contract (live-verified): yAxis.columnIds lists ALL series
    # (typed {columnId, type} entries); yAxis2.columnIds is a PLAIN-STRING SUBSET
    # naming which of those series ride the right axis. A yAxis2 id absent from
    # yAxis 400s ("not listed on yAxis.columnIds"); a typed object in yAxis2
    # 400s ("Invalid string: object").
    el['yAxis']  = { 'columnIds' => [{ 'columnId' => country_id, 'type' => 'line' },
                                     { 'columnId' => world_col['id'], 'type' => 'line' }] }
    el['yAxis2'] = { 'columnIds' => [world_col['id']] }
    el.delete('dataLabel') # no per-point value labels smeared across the lines
    # Trim trailing no-data years: the master carries rows for every year ANY
    # metric covers, so a metric that ends earlier (UNITS stops before REV) plots
    # its trailing all-null years as a cliff to 0. Row-level IsNotNull filter
    # (the verified bool-filter shape) ends each trend at ITS metric's last
    # real year — exactly the source's per-tile x-domain.
    nn_id = "nn-trend-#{el['id']}"
    unless cols.any? { |c| c['id'] == nn_id }
      (el['columns'] ||= []) << { 'id' => nn_id, 'name' => "#{metric} Not Null",
                                  'formula' => "IsNotNull([#{prefix}/#{metric}])" }
      (el['filters'] ||= []) << { 'id' => "f-#{nn_id}", 'columnId' => nn_id, 'kind' => 'list',
                                  'mode' => 'include', 'selectionMode' => 'multiple', 'values' => [true] }
    end
    # Integer Year x-axis (build-charts uses a DateTrunc datetime column). Rewrite
    # the bound x column to the plain Year field so ticks read 1960…2014, not "Jan 1960".
    xid = el.dig('xAxis', 'columnId')
    xcol = (el['columns'] || []).find { |c| c['id'] == xid }
    if xcol && xcol['formula'].to_s =~ /DateTrunc|\[[^\]]*Date\]/i
      xcol['formula'] = "[#{prefix}/Year]"
      xcol['name'] = 'Year'
      xcol.delete('format')
    end
    1
  end

  # The tile's category dimension = its first bare [prefix/Field] column (no agg).
  def tile_dimension(el)
    dim = (el['columns'] || []).find { |c| c['formula'].to_s =~ /\A\[[^\]]+\]\z/ }
    dim && col_disp(dim)
  end

  # Replace a bar tile's measure column (the non-dimension, non-"Selected" column)
  # with the latest-year magnitude of `metric`. Handles the (copy)-calc-collapsed
  # measure that renders 0.
  def rewrite_bar_measure!(el, prefix, metric, pit)
    meas = (el['columns'] || []).find do |c|
      c['name'] != 'Selected' && c['formula'].to_s !~ /\A\[[^\]]+\]\z/
    end
    return 0 unless meas
    meas['formula'] = pit_conditional(prefix, metric, pit, metric, context: el['name'])
    # The tile's measure was the source's %-change "(copy)" calc, so its format was
    # a percent (",.0%") — a raw magnitude then renders "$24T" as "…345%". Reset to
    # a compact SI number to match the clean reference.
    meas['format'] = SI_FMT
    # Bar presentation to match the reference: rank bars by VALUE (build-charts
    # sorts by the category NAME → scrambled order), drop per-bar data labels, and
    # clear the broken {min:0,max:0} axis-domain artifact.
    el.delete('dataLabel')
    el['xAxis'] ||= {}
    el['xAxis']['sort'] = { 'by' => meas['id'], 'direction' => 'descending' }
    if (dom = el.dig('xAxis', 'format', 'scale', 'domain')).is_a?(Hash) &&
       dom['min'].to_f.zero? && dom['max'].to_f.zero?
      el['xAxis']['format']['scale'].delete('domain')
    end
    1
  end

  # Display name of a column (explicit name, else the formula's final segment).
  def col_disp(c)
    return c['name'] if c['name'] && !c['name'].to_s.empty?
    m = c['formula'].to_s.match(/\[([^\]]+)\]\s*\z/)
    m && m[1].split('/').last
  end

  # Ensure a table groups by its first dimension column (a non-aggregated
  # [P/Field] ref) with the measure(s) as calculations — never ships ungrouped.
  def ensure_grouped!(el)
    return if Array(el['groupings']).any?
    cols = el['columns'] || []
    dim = cols.find { |c| c['formula'].to_s =~ /\A\[[^\]]+\]\z/ } # bare [P/Field], no agg
    meas = cols.reject { |c| c == dim }.map { |c| c['id'] }
    return unless dim
    el['groupings'] = [{
      'id' => "grp-#{el['id']}", 'groupBy' => [dim['id']], 'calculations' => meas,
      'sort' => (meas.first ? [{ 'columnId' => meas.first, 'direction' => 'descending' }] : [])
    }]
  end
end
