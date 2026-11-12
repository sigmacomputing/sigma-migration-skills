# frozen_string_literal: true
#
# pbi_reportbuild.rb — pure helpers for the REPORT-BUILD hardening pass
# (one-base-table-per-page control targeting, boolean-aware controls, friendly
# naming). Plugin-local (powerbi-to-sigma only): NOT a shared/vendored lib.
#
# Why this exists (defects seen on live migrations, all on simple dashboards):
#   * Page controls only filtered the detail TABLE — KPIs/charts on the same
#     page stayed unfiltered. The attempted fix (a filter "passthrough" column
#     per visual) BROKE bar-charts/pivots (the extra column corrupts grouping →
#     "No data"). The real fix is source PROPAGATION: every visual on a page
#     SOURCES one base table and the page control targets THAT base table's
#     column, so the filter flows to every visual for free (the same pattern
#     tableau-to-sigma / qlik-to-sigma already use — one master, all charts
#     source it). No passthrough columns, ever.
#   * Boolean slicers got the string-slicer control template (`include` +
#     `values:[]`). Sigma treats an unset boolean `include` list as "include
#     nothing" → it ZEROES every targeted element. A boolean control must leave
#     the element UNFILTERED when unset.
#   * Reports surfaced RAW warehouse column names as titles/labels
#     ("IS Active IND", "Submission KEY by Level 1 Name"). Labels must read as
#     human display names.
#
# All functions here are pure (no I/O, no globals) so they unit-test directly.
module PbiReportBuild
  module_function

  # Acronyms that must stay upper-cased when Title-Casing a raw label. Anything
  # NOT in this set that arrives ALL-CAPS (e.g. "KEY", "IND", "IS") is a raw
  # warehouse token and gets Capitalized ("Key", "Ind", "Is").
  FRIENDLY_KEEP = %w[
    ID ZIP GL CP YTD MTD QTD WTD KPI US UK EU APAC EMEA SKU URL API UUID
    SSN DOB FTE PII GMV ARR MRR ROI YOY MOM QOQ AOV LTV CAC NPS
  ].freeze

  # Humanize a raw/snake/ALL-CAPS label into a Title-Cased display name, while
  # leaving an already-human label ("Total Sales", "Sales by Region") untouched
  # and preserving real acronyms ("Customer ID", "GL Balance"). Returns the
  # input unchanged when it is already friendly or is not a String.
  #
  #   "IS Active IND"                 -> "Is Active Ind"
  #   "SUBMISSION_KEY"                -> "Submission Key"
  #   "Submission KEY by Level 1 Name"-> "Submission Key by Level 1 Name"
  #   "Customer ID"                   -> "Customer ID"   (acronym preserved)
  #   "Total Sales"                   -> "Total Sales"   (already human)
  def friendly_label(s)
    return s unless s.is_a?(String)
    t = s.strip
    return s if t.empty?
    # "raw" = has an underscore, OR carries no lowercase letter at all, OR
    # contains a bare ALL-CAPS word of 2+ chars (the "IS"/"KEY"/"IND" tell).
    looks_raw = t.include?('_') || t !~ /[a-z]/ || t =~ /(?:\A|\s)[A-Z]{2,}(?:\s|\z)/
    return s unless looks_raw
    words = t.gsub(/_+/, ' ').split(/\s+/)
    words.map do |w|
      up = w.upcase
      if FRIENDLY_KEEP.include?(up) && w == up
        up                                   # real acronym — keep upper
      elsif w =~ /\A[A-Z0-9]+\z/ && w =~ /[A-Z]/
        w.capitalize                         # ALL-CAPS raw token -> Capitalized
      else
        w                                    # already mixed-case / a number
      end
    end.join(' ')
  end

  # The single base master a whole PAGE sources: the master that resolves the
  # MOST of the page's bound fields (aggregated across every visual, controls
  # included so the sliced column counts). `masters_for` maps a queryRef to the
  # list of master names it can resolve on (primary + alts). Ties break toward
  # the FIRST master seen (deterministic). Returns nil when nothing resolves.
  #
  # This is the "one wide base table per page" decision: instead of each visual
  # picking its own narrow master (which left page controls unable to reach the
  # others), every visual on the page is pointed at this one base so a single
  # control target propagates to all of them.
  def page_base_master(visuals, masters_for)
    counts = Hash.new(0)
    order = []
    Array(visuals).each do |v|
      (v['bindings'] || {}).values.flatten.compact.each do |qr|
        Array(masters_for.call(qr)).each do |m|
          next if m.nil?
          order << m unless order.include?(m)
          counts[m] += 1
        end
      end
    end
    return nil if counts.empty?
    best = counts.max_by { |m, c| [c, -order.index(m)] }
    best && best[0]
  end

  # A page-wide base may source a visual only when it can resolve EVERY bound
  # field. Falling back after a partial match lets the visual choose a specialized
  # grouped master (for example Year + Revenue + Prior Year) instead of silently
  # dropping the field that exists only on that master.
  def all_fields_resolve_on?(query_refs, master, masters_for)
    refs = Array(query_refs).compact
    !refs.empty? && refs.all? { |qr| Array(masters_for.call(qr)).include?(master) }
  end

  # Name-shape heuristic for a boolean/indicator slicer when no TMSL dataType is
  # available (the extract carried no --model). Conservative: only true/has
  # prefixes and the ind/indicator/flag suffix — the well-known PBI indicator
  # naming — so a plain categorical ("Region", "Status") is never mistaken for
  # a boolean and force-seeded.
  def boolean_leaf?(leaf)
    s = leaf.to_s
    return false if s.empty?
    s =~ /\A(is|has)\b/i || s =~ /\b(ind|indicator|flag)\z/i || s =~ /\bactive\s+ind\b/i
  end

  # A boolean domain's default control selection = BOTH members, so an "unset"
  # control includes everything (no filter) instead of the empty `include` list
  # that zeroes a boolean-typed target. TMSL boolean columns are true/false.
  def boolean_domain_values
    [true, false]
  end

  # Cross-element reference token extraction. A `[Element/Column]` ref names its
  # source element before the first slash; `[Column]` (no slash) is a same-element
  # column ref and is ignored. Returns the distinct element tokens a formula
  # references via the two-part `[X/...]` form.
  def ref_element_tokens(formula)
    formula.to_s.scan(/\[([^\]\/]+)\/[^\]]*\]/).map { |m| m[0] }.uniq
  end

  # The MASTER element ids a formula references that are NOT the element's own
  # source — i.e. a cross-master leak (an element sourcing master A referencing
  # `[master-B/Col]`, which Sigma compiles to type "error"). `master_ids` is the
  # set of master element ids; `by_name` maps a master DISPLAY NAME -> its id
  # (refs may use either the id or the display name). A token equal to the source
  # (id OR its display name) is the element's own source and is allowed.
  def foreign_master_refs(formula, source_id, master_ids, by_name = {})
    ids = master_ids.respond_to?(:include?) ? master_ids : Array(master_ids)
    src_name = by_name.respond_to?(:key) ? by_name.key(source_id) : nil
    out = []
    ref_element_tokens(formula).each do |tok|
      tid = ids.include?(tok) ? tok : by_name[tok]   # resolve a display-name token to a master id
      next if tid.nil?                                # not a master ref (self-col, [Metrics/..], scatter src, ...)
      next if tok == source_id || tok == src_name || tid == source_id
      out << tid
    end
    out.uniq
  end

  # ---------------------------------------------------------------------------
  # Slicer defaults (F14 consumer / G24 / G27)
  # ---------------------------------------------------------------------------

  # TMSL dataType -> the value family a list-control default must be typed as.
  def value_type(data_type)
    case data_type.to_s.downcase
    when '' then nil
    when /bool|bit/ then :bool
    when /int/ then :int
    when /double|decimal|currency|float|number|single/ then :float
    when /date|time/ then :date
    when /string|text|char/ then :text
    end
  end

  # Parse ONE saved-selection value as the extractor may have left it: a PBIR
  # literal ("2026L", "1.5D", "'O''Brien'", "true", "null") or an already-decoded
  # Ruby value. Returns [family, value] — family is :null/:int/:float/:bool/:text/:raw.
  # `decoded: true` marks a value the extractor already decoded (extract-pbir's typed
  # saved_selection): a Ruby String there is a final text member and is NEVER re-parsed, so a
  # member "True" / "100D" / "null" stays text. Only raw PBIR literal syntax (the legacy
  # `selection` path, or hand-fed literals) is parsed: quoted '...', an L/D/M numeric suffix,
  # bare true/false/null.
  def parse_literal(v, decoded: false)
    case v
    when nil then [:null, nil]
    when true, false then [:bool, v]
    when Integer then [:int, v]
    when Float then [:float, v]
    else
      return [:raw, v.to_s] if decoded
      s = v.to_s.strip
      if s =~ /\A'(.*)'\z/m then [:text, Regexp.last_match(1).gsub("''", "'")]
      elsif s =~ /\A(-?\d+)L\z/ then [:int, Regexp.last_match(1).to_i]
      elsif s =~ /\A(-?\d+(?:\.\d+)?)[DM]\z/ then [:float, Regexp.last_match(1).to_f]
      elsif s =~ /\Atrue\z/i then [:bool, true]
      elsif s =~ /\Afalse\z/i then [:bool, false]
      elsif s =~ /\Anull\z/i then [:null, nil]
      else [:raw, s]
      end
    end
  end

  # Coerce a parsed literal to the column's family. nil = cannot be converted.
  def coerce_literal(fam, val, type)
    case type
    when :int
      return val if fam == :int
      return val.to_i if fam == :float && val == val.floor
      fam == :raw && val =~ /\A-?\d+\z/ ? val.to_i : nil
    when :float
      return val.to_f if %i[int float].include?(fam)
      fam == :raw && val =~ /\A-?\d+(?:\.\d+)?\z/ ? val.to_f : nil
    when :bool
      return val if fam == :bool
      fam == :raw && val =~ /\A(true|false)\z/i ? val.casecmp('true').zero? : nil
    when :text
      return val.to_s if %i[text raw int float].include?(fam) && !val.nil?
      fam == :bool ? val.to_s : nil
    else # unknown column type: keep each literal's own family
      fam == :raw ? val : val
    end
  end

  # Normalize a signals `slicer_state` into the saved-selection contract
  #   {'mode'=>'include'|'exclude', 'column'=>'Table.Col'|nil, 'values'=>[...], 'has_null'=>bool}
  # Prefers the F14 `saved_selection`; still reads the legacy `selection` list
  # signal. G24: a selection scoped `slicer-self` (the slicer's OWN visual-level
  # filter, e.g. "exclude blank" on its member list) is a restriction on the list's
  # MEMBERS, never a default selection — it is never returned.
  def saved_selection(state)
    return nil unless state.is_a?(Hash)
    if state['saved_selection'].is_a?(Hash)
      ss = state['saved_selection']
      return nil if ss['scope'].to_s == 'slicer-self'
      return nil if ss['predicate'].to_s == 'none'
      # extract-pbir already typed these values (JSON types; quotes/suffixes decoded)
      return { 'mode' => ss['mode'].to_s =~ /exclude|not/i ? 'exclude' : 'include', 'decoded' => true,
               'column' => ss['column'], 'values' => Array(ss['values']), 'has_null' => ss['has_null'] ? true : false }
    end
    sel = state['selection']
    return nil unless sel.is_a?(Hash) && sel['type'] == 'list'
    return nil if sel['unsupported'] || sel['predicate'].to_s == 'none' || sel['scope'].to_s == 'slicer-self'
    { 'mode' => sel['mode'].to_s =~ /exclude|not/i ? 'exclude' : 'include',
      'column' => sel['column'], 'values' => Array(sel['values']), 'has_null' => sel['has_null'] ? true : false }
  end

  # Type a saved selection's values from the column. Returns
  #   {'mode', 'values', 'has_null', 'skipped'=>[literals that could not be typed]}.
  # Sigma list controls cannot hold a NULL literal, so nulls leave `values` and are
  # reported through `has_null` for the caller's coverage entry.
  def typed_selection(sel, type)
    values = []
    skipped = []
    has_null = sel['has_null'] ? true : false
    Array(sel['values']).each do |raw|
      fam, val = parse_literal(raw, decoded: sel['decoded'] ? true : false)
      if fam == :null
        has_null = true
        next
      end
      out = coerce_literal(fam, val, type)
      if out.nil?
        skipped << raw
      else
        values << out
      end
    end
    { 'mode' => sel['mode'] == 'exclude' ? 'exclude' : 'include', 'values' => values,
      'has_null' => has_null, 'skipped' => skipped }
  end

  def norm_ref(s)
    s.to_s.downcase.gsub(/[_\s]+/, ' ').strip
  end

  # The default state of a list control. "All" is `include + []` for every column
  # type EXCEPT boolean, where Sigma matches ZERO rows for an empty include list (G27)
  # — there "all" is `exclude + []`. A saved selection (typed from the column) wins,
  # but a boolean control NEVER leaves with include + [].
  #   -> {'mode','values','has_null','skipped','mismatch'(column named by a saved
  #       selection that is not the slicer's own column — not applied)}
  def list_default(is_bool:, type:, state:, qr: nil)
    out = { 'mode' => is_bool ? 'exclude' : 'include', 'values' => [], 'has_null' => false, 'skipped' => [] }
    sel = saved_selection(state)
    return out unless sel
    if sel['column'] && qr && norm_ref(sel['column']) != norm_ref(qr)
      out['mismatch'] = sel['column']
      return out
    end
    typed = typed_selection(sel, is_bool ? :bool : type)
    out.merge!(typed)
    if out['mode'] == 'include' && out['values'].empty? && out['has_null']
      # only (Blank) selected: include [] would mean "all rows" — hold the default back
      out['blank_only'] = true
    end
    out['mode'] = 'exclude' if is_bool && out['mode'] == 'include' && out['values'].empty?
    out
  end

  # ---------------------------------------------------------------------------
  # Cosmetics
  # ---------------------------------------------------------------------------

  # A PBI slicer title that is really a layout CONTAINER name ("Slicer Container 3",
  # "Group 5", a raw id) rather than something the report author wrote. The slicer's
  # label should then be the field display name.
  def container_name?(title)
    t = title.to_s.strip
    return false if t.empty?
    return true if t =~ /container/i
    return true if t =~ /\A[0-9a-f]{8,}\z/i
    return true if t =~ /\A(?:slicer|filter|visual|group|chart|object|shape|rectangle|textbox|card)[\s_-]*\d*\z/i && t =~ /[\d_-]/
    return true if t =~ /\A(?:group|visual|object|shape|rectangle)\s*\d+\z/i
    false
  end

  # True when an axis/slicer column holds dates: the TMSL type is authoritative when
  # known, else the column name decides.
  def date_axis?(leaf, tmsl_type)
    t = tmsl_type.to_s
    return t =~ /date|time/i ? true : false unless t.empty?
    leaf.to_s =~ /\bdate\b/i ? true : false
  end

  # Text period-ish labels (P1..P13, W1.., Q1..Q4, FY24) whose natural order is not
  # alphabetical. Only used to decide where a natural-order sort key is worth adding.
  def period_like?(leaf)
    leaf.to_s =~ /\b(period|week|wk|month|mth|quarter|qtr|fiscal|fy|day|year)\b/i ? true : false
  end

  # A text sort key that orders "P1, P2, ... P13" naturally. The trailing digit run is the
  # period number in every common shape ("P13", "FY24 P13", "2024-01"), so the key is the
  # text before that run plus the run left-padded to a fixed width: a leading year ("FY24",
  # "2024-") stays in the prefix and never collapses the labels onto one key. A label that
  # does not end in digits but holds exactly ONE digit run ("Week 3 Actual") pads that run;
  # anything else sorts by its own text (plain alphabetical, never a tie).
  def natural_sort_formula(ref)
    t = "Text(#{ref})"
    trailing = %(Concat(Coalesce(RegexpExtract(#{t}, "^.*[^0-9]"), ""), ) +
                %(LPad(RegexpExtract(#{t}, "[0-9]+$"), 10, "0")))
    single = %(Concat(Coalesce(RegexpExtract(#{t}, "^[^0-9]*"), ""), ) +
              %(LPad(Coalesce(RegexpExtract(#{t}, "[0-9]+"), ""), 10, "0")))
    %(If(RegexpMatch(#{t}, "[0-9]$"), #{trailing}, If(RegexpCount(#{t}, "[0-9]+") = 1, #{single}, #{t})))
  end

  # Ruby mirror of the natural_sort_formula key (used by the tests to prove ordering).
  def natural_sort_key(label)
    t = label.to_s
    if t =~ /[0-9]\z/
      (t[/\A.*[^0-9]/m] || '') + t[/[0-9]+\z/].rjust(10, '0')
    elsif t.scan(/[0-9]+/).length == 1
      (t[/\A[^0-9]*/] || '') + t[/[0-9]+/].rjust(10, '0')
    else
      t
    end
  end

  # ---------------------------------------------------------------------------
  # Hold-back classification
  # ---------------------------------------------------------------------------

  CHART_AXIS_KINDS = %w[bar-chart line-chart area-chart combo-chart waterfall-chart scatter-chart].freeze

  # What is wrong with a BUILT element's essential bindings, if anything.
  #   [:hold, text]    — it cannot render anything meaningful (a line chart with an empty
  #                      yAxis, a pivot with no values, a KPI with no value ...). The caller
  #                      must NOT emit it; record it dropped.
  #   [:degrade, text] — it renders but lost a role (a chart without its category axis).
  #   nil              — fine.
  # `source_values`: whether the SOURCE visual had a Values binding. A matrix that never had
  # values (a dimension-only member list) is degraded; one whose values failed to bind is held.
  def binding_miss(el, source_values: true)
    kind = el['kind'].to_s
    if CHART_AXIS_KINDS.include?(kind)
      return [:hold, 'has no measure on its yAxis'] if Array(el.dig('yAxis', 'columnIds')).empty?
      if el['xAxis'].nil? || el.dig('xAxis', 'columnId').nil?
        return [:degrade, 'lost its category/dimension (xAxis) — it will aggregate every row into one mark']
      end
    else
      case kind
      when 'kpi-chart', 'pie-chart', 'donut-chart'
        return [:hold, 'has no value binding'] if el.dig('value', 'columnId').nil? && el.dig('value', 'id').nil?
      when 'pivot-table'
        if Array(el['values']).empty?
          # a dimension-only matrix is a member list (it built before this check): degrade, keep it
          return [:degrade, 'has no values (renders the distinct row/column members only)'] if
            !source_values && !(Array(el['rowsBy']).empty? && Array(el['columnsBy']).empty?)
          return [:hold, 'has no values']
        end
      when 'table'
        return [:hold, 'has no columns'] if Array(el['columns']).empty?
      end
    end
    nil
  end

  # ---------------------------------------------------------------------------
  # Per-visual master fallback (page-base mode)
  # ---------------------------------------------------------------------------

  # When the page-wide base cannot resolve a visual's fields, pick the master that
  # binds the visual's MEASURES first (a chart without its measure renders nothing;
  # one without its category still renders), then the one covering the most fields,
  # then the first field's master. `masters_for` : queryRef -> [masters];
  # `measure` : queryRef -> bool.
  def measure_first_master(qrs, masters_for, measure)
    qrs = Array(qrs).compact
    return nil if qrs.empty?
    counts = Hash.new { |h, k| h[k] = [0, 0] }
    qrs.each do |qr|
      Array(masters_for.call(qr)).each do |m|
        counts[m][1] += 1
        counts[m][0] += 1 if measure.call(qr)
      end
    end
    return nil if counts.empty?
    first = qrs.map { |qr| Array(masters_for.call(qr)).first }.compact.first
    counts.max_by { |m, (mc, tc)| [mc, tc, m == first ? 1 : 0] }&.first
  end

  # ---------------------------------------------------------------------------
  # Hidden visuals (G30)
  # ---------------------------------------------------------------------------

  # Bookmark keys that list the visuals a bookmark turns VISIBLE. `shows` is the canonical key
  # extract-pbir.py emits ({name, display_name, hides, shows, ...}); the rest are legacy fallbacks.
  BOOKMARK_SHOW_KEYS = %w[shows shown visible show unhidden].freeze

  # A visual Power BI never shows in its default state. report-extract2 emits `hidden: true`
  # in the signals; `is_hidden` is accepted until then.
  def hidden_visual?(v)
    return false unless v.is_a?(Hash)
    [v['hidden'], v['is_hidden']].any? { |x| x == true || x.to_s.casecmp('true').zero? }
  end

  # visual id -> [bookmark display names] for every visual some bookmark turns into view.
  def bookmark_reveals(bookmarks)
    out = Hash.new { |h, k| h[k] = [] }
    Array(bookmarks).each do |b|
      next unless b.is_a?(Hash)
      label = (b['display_name'] || b['displayName'] || b['name']).to_s
      hidden_here = Array(b['hides']).map(&:to_s)
      BOOKMARK_SHOW_KEYS.each do |k|
        Array(b[k]).each do |vid|
          next if hidden_here.include?(vid.to_s) # the same bookmark hides it: not a reveal
          out[vid.to_s] << label unless out[vid.to_s].include?(label)
        end
      end
    end
    out.to_h
  end

  def slicer_visual?(v)
    v['sigma_kind'].to_s =~ /\A(control|slicer)\z/ || v['visual_type'].to_s =~ /slicer/i ? true : false
  end

  # Split a page's visuals into what Power BI actually shows and what it hides.
  #   'kept'    — visible visuals, plus hidden ones that must stay (see below), in source order
  #   'held'    — hidden visuals to hold back: [[visual, reason]]  (record "hidden in source")
  #   'revealed'— hidden visuals a bookmark toggles into view, kept  [[visual, [bookmark names]]]
  #   'filtering'— hidden SLICERS with a saved selection, kept: a hidden slicer still filters its
  #               page in Power BI, so holding it back would silently change the numbers
  #               [[visual]]
  #   'unverified'— hidden visuals kept because the route carries NO bookmark data at all
  #               (`bookmarks` nil, e.g. the classic Report/Layout route): we cannot tell whether a
  #               bookmark shows them, so they are laid out [[visual]] and a coverage note recorded
  # A hidden visual with bookmark data present, no bookmark showing it and no filtering effect is
  # never laid out. Pass `bookmarks` as an Array (possibly empty) only when the route has bookmark data.
  def partition_hidden(visuals, bookmarks = nil)
    reveals = bookmark_reveals(bookmarks)
    have_bookmark_data = !bookmarks.nil?
    occ = occluded_visuals(visuals)
    out = { 'kept' => [], 'held' => [], 'revealed' => [], 'filtering' => [], 'unverified' => [],
            'occluded_kept' => [] }
    Array(visuals).each do |v|
      hidden = hidden_visual?(v)
      by = occ[v['visual_id'].to_s]
      unless hidden || by
        out['kept'] << v
        next
      end
      why = hidden ? 'hidden in source' : "occluded by #{visual_label(by)} on the default view"
      if reveals.key?(v['visual_id'].to_s)
        out['kept'] << v
        out['revealed'] << [v, reveals[v['visual_id'].to_s]]
        out['occluded_kept'] << [v, by] if !hidden && by
      elsif slicer_visual?(v) && saved_selection(v['slicer_state'])
        out['kept'] << v
        out['filtering'] << [v]
      elsif !have_bookmark_data
        out['kept'] << v
        out['unverified'] << [v]
      else
        out['held'] << [v, why]
      end
    end
    out
  end

  def visual_label(v)
    v['title'].to_s.strip.empty? ? v['visual_id'].to_s : v['title'].to_s.strip
  end

  # Fraction of a's area lying inside b (boxes are absolute x/y/w/h).
  def covered_fraction(a, b)
    aw = a['w'].to_f
    ah = a['h'].to_f
    return 0.0 if aw <= 0 || ah <= 0
    ix = [[a['x'].to_f + aw, b['x'].to_f + b['w'].to_f].min - [a['x'].to_f, b['x'].to_f].max, 0].max
    iy = [[a['y'].to_f + ah, b['y'].to_f + b['h'].to_f].min - [a['y'].to_f, b['y'].to_f].max, 0].max
    (ix * iy) / (aw * ah)
  end

  # Visuals never visible on the default view because ONE later-z, visible visual covers >= 95% of
  # their area (the "view toggle" design: several matrices/charts stacked under button-driven views).
  # Uses ABSOLUTE boxes (extract-pbir resolves group offsets). Decorations, text boxes, images and
  # group containers neither get held nor count as occluders. -> {visual_id => occluding visual}
  OCCLUDE_MIN = 0.95
  def occluded_visuals(visuals)
    all = Array(visuals)
    by_id = all.each_with_object({}) { |v, h| h[v['visual_id'].to_s] = v }
    # PBIR z is RELATIVE within a group: the stacking key is the z chain from the
    # top-level ancestor down to the visual itself, compared lexicographically.
    zkey = lambda do |v|
      chain = []
      seen = {}
      cur = v
      while cur && !seen[cur['visual_id'].to_s]
        seen[cur['visual_id'].to_s] = true
        chain.unshift(cur['z'].to_f)
        cur = by_id[cur['parent_group'].to_s]
      end
      chain
    end
    list = all.reject do |v|
      v['visual_type'].to_s == 'unknown' || v['role_class'].to_s == 'decoration' ||
        %w[text image].include?(v['sigma_kind'].to_s) || hidden_visual?(v)
    end
    keys = list.each_with_object({}) { |v, h| h[v['visual_id'].to_s] = zkey.call(v) }
    out = {}
    list.each do |a|
      ka = keys[a['visual_id'].to_s]
      b = list.select { |o| !o.equal?(a) && (keys[o['visual_id'].to_s] <=> ka) == 1 }
              .sort { |o1, o2| keys[o2['visual_id'].to_s] <=> keys[o1['visual_id'].to_s] }
              .find { |o| covered_fraction(a, o) >= OCCLUDE_MIN }
      out[a['visual_id'].to_s] = b if b
    end
    out
  end

  # TMSL / Excel-style formatString -> Sigma d3 format string, or nil when it cannot be mapped
  # exactly (General, dates, scientific, scaled "0,," ...). "#,##0" -> ",.0f", "#,##0.00" -> ",.2f",
  # "0.0%" -> ".1%", "$#,##0" -> "$,.0f".
  def d3_format(fmt)
    s = fmt.to_s.strip
    return nil if s.empty? || s =~ /\Ageneral\z/i
    s = s.split(';').first.to_s
    # Currency first: Power BI writes the symbol escaped (\$) or quoted ("$"), which the
    # literal stripping below discards. The symbol rides as the d3 prefix.
    cur = s[/[$€£¥]/]
    s = s.gsub(/"[^"]*"|\\./, '')
    return nil if s =~ /[eE][+-]?0/ || s =~ /[yYdDhHsS]/ || s =~ /\bAM\b/i
    percent = s.include?('%')
    num = s.gsub(/[^#0,.]/, '')
    return nil if num.empty? || num =~ /,\z/ || num =~ /,\./ # trailing comma = scaling
    int_part, dec_part = num.split('.', 2)
    comma = int_part.to_s.include?(',')
    decimals = dec_part.to_s.count('0#')
    "#{cur}#{comma ? ',' : ''}.#{decimals}#{percent ? '%' : 'f'}"
  end

  # ---------------------------------------------------------------------------
  # Synced slicer groups (G31)
  # ---------------------------------------------------------------------------

  # A Power BI sync group becomes ONE primary list control (the first member built) plus
  # minimal `controlType: synced` copies on the other pages. Only the primary carries values,
  # so a saved selection found on ANY member is the group's default: when the primary has none,
  # the first member (page order) that has one lends its `slicer_state`. Members must slice the
  # same field as the primary (PBI only syncs identical fields; the builder builds mismatches as
  # independent controls) — `qr_of.call(visual)` returns the sliced queryRef, nil for non-slicers.
  # `pages` = [{'visuals'=>[...]}]. Mutates the primary's `slicer_state`.
  #   -> [{'group','primary','from'(visual id|nil),'conflict'(bool)}] one row per group whose
  #      default was borrowed or whose members disagree
  def sync_group_defaults!(pages, qr_of)
    groups = {}
    Array(pages).each do |pg|
      Array(pg['visuals']).each do |v|
        g = v['sync_group'].to_s.strip
        next if g.empty?
        qr = qr_of.call(v)
        next unless qr
        (groups[g] ||= []) << [v, qr]
      end
    end
    notes = []
    groups.each do |g, members|
      primary, pqr = members.first
      same = members.select { |_v, qr| qr == pqr }.map(&:first)
      with_sel = same.select { |v| saved_selection(v['slicer_state']) }
      next if with_sel.empty?
      sigs = with_sel.map { |v| s = saved_selection(v['slicer_state']); [s['mode'], s['values'].map(&:to_s).sort, s['has_null']] }.uniq
      conflict = sigs.size > 1
      borrowed = nil
      unless saved_selection(primary['slicer_state'])
        borrowed = with_sel.first
        primary['slicer_state'] = borrowed['slicer_state']
      end
      notes << { 'group' => g, 'primary' => primary['visual_id'],
                 'from' => borrowed && borrowed['visual_id'], 'conflict' => conflict } if borrowed || conflict
    end
    notes
  end

  # ---------------------------------------------------------------------------
  # Controls that point at held-back elements (G32)
  # ---------------------------------------------------------------------------

  # Remove every reference to `removed_ids` from the controls in `elements` (an Array of spec
  # elements, mutated): control `filters[]` / `targets[]` entries and `controlScope[]` ids. A
  # control that LOST a reference and is left with no filter and no target (a chart's legend or
  # drill control whose chart was held back) is dropped from `elements`. Returns the dropped
  # controls' elementIds and controlIds: {'elements'=>[...], 'controls'=>[...]}.
  def prune_control_refs!(elements, removed_ids)
    gone = Array(removed_ids)
    out = { 'elements' => [], 'controls' => [] }
    return out if gone.empty?
    hits = lambda { |f| f.is_a?(Hash) && gone.include?(f.dig('source', 'elementId')) }
    elements.reject! do |el|
      next false unless el['kind'] == 'control'
      lost = false
      %w[filters targets].each do |k|
        next unless el[k].is_a?(Array)
        n = el[k].size
        el[k] = el[k].reject(&hits)
        lost ||= el[k].size != n
      end
      if el['controlScope'].is_a?(Array)
        n = el['controlScope'].size
        el['controlScope'] = el['controlScope'] - gone
        lost ||= el['controlScope'].size != n
      end
      drop = lost && Array(el['filters']).empty? && Array(el['targets']).empty?
      if drop
        out['elements'] << el['id']
        out['controls'] << el['controlId'] if el['controlId']
      end
      drop
    end
    out
  end

  # ---------------------------------------------------------------------------
  # Page-local masters (G21)
  # ---------------------------------------------------------------------------

  # Sigma AND-composes every control that targets one shared source element. A PBI
  # slicer only filters ITS page, so when a Data-page master is used by more than one
  # page, each page's controls must not touch the shared master: give every page its own
  # child table of the master, repoint the page's elements at it and retarget the page's
  # controls at it. Masters used by a single page are left alone (nothing to compose).
  #
  # Mutates `content_pages` ([{'id','name','elements'}]) and appends the copies to
  # `data_elements` (the Data page). A copy `pgcopy-<h>-<master id>` has the master's
  # columns under ids `<col id>-<h>` and formulas `[<master id>/<col name>]`.
  #   * elements: `source.elementId` and every `[<master>/` formula token move to the copy
  #   * helper elements (Data-page tables sourcing a master, e.g. scatter sources) follow
  #     the page of the element that consumes them
  #   * list/date controls: `filters[]` retarget to the page copy; a target on a shared
  #     master the control's page does not use is dropped (it could only leak to other pages)
  #   * a synced control's PRIMARY additionally filters the copy on every page that hosts a
  #     synced member (the sync group spans pages); members stay minimal
  #   * a control's value-list `source` stays on the master (the unfiltered domain)
  # Returns {'copies'=>{"<master>|<page id>"=>copy id}, 'emptied'=>[control ids that
  # lost every target], 'retargeted'=>n, 'dropped'=>n}.
  def page_local_masters!(content_pages, data_elements, master_ids)
    require 'digest'
    result = { 'copies' => {}, 'emptied' => [], 'retargeted' => 0, 'dropped' => 0 }
    mset = Array(master_ids).to_a
    by_id = {}
    Array(data_elements).each { |e| by_id[e['id']] = e }
    masters = mset.select { |m| by_id[m] }
    return result if masters.empty?

    src_id = lambda do |el|
      s = el['source']
      next nil unless s.is_a?(Hash)
      s = s['source'] if s['kind'] == 'source' && s['source'].is_a?(Hash)
      s.is_a?(Hash) ? s['elementId'] : nil
    end
    require 'json'
    # which masters a content element's serialized spec mentions as `[<master>/` tokens
    # (controls' own filter targets are not usage — they are retargeted separately)
    mentions = lambda do |el|
      js = JSON.generate(el.reject { |k, _| k == 'filters' && el['kind'] == 'control' })
      masters.select { |m| js.include?("[#{m}/") }
    end

    # helper -> consumer page (a Data-page table whose source is a master and which a
    # content element sources, e.g. a scatter's grouped source)
    helper_page = {}
    content_pages.each do |pg|
      Array(pg['elements']).each do |el|
        next if el['kind'] == 'control'
        h = src_id.call(el)
        helper_page[h] ||= pg['id'] if h && by_id[h] && !masters.include?(h)
      end
    end

    used = Hash.new { |hh, k| hh[k] = [] } # page id -> masters in use
    content_pages.each do |pg|
      Array(pg['elements']).each do |el|
        next if el['kind'] == 'control'
        hit = mentions.call(el)
        hit << src_id.call(el) if masters.include?(src_id.call(el))
        if (h = by_id[src_id.call(el)]) && helper_page[h['id']] == pg['id'] && !masters.include?(h['id'])
          hit.concat(mentions.call(h))
          hit << src_id.call(h) if masters.include?(src_id.call(h))
        end
        hit.uniq.each { |m| used[pg['id']] << m unless used[pg['id']].include?(m) }
      end
    end
    shared = masters.select { |m| used.values.count { |ms| ms.include?(m) } > 1 }
    return result if shared.empty?

    # Not a security use: a short deterministic id tag that must stay stable across runs.
    # nosemgrep: ruby.lang.security.weak-hashes-md5.weak-hashes-md5
    tag = lambda { |pid| Digest::MD5.hexdigest(pid.to_s)[0, 6] }
    copies = {}   # [m, pid] -> copy element id
    colmap = {}   # [m, pid, master col id] -> copy col id
    pages_by_id = content_pages.each_with_object({}) { |pg, h| h[pg['id']] = pg }
    content_pages.each do |pg|
      (used[pg['id']] & shared).each do |m|
        t = tag.call(pg['id'])
        cid = "pgcopy-#{t}-#{m}"
        src = by_id[m]
        cols = Array(src['columns']).map do |c|
          nc = "#{c['id']}-#{t}"
          colmap[[m, pg['id'], c['id']]] = nc
          copy = { 'id' => nc, 'name' => c['name'], 'formula' => "[#{m}/#{c['name']}]" }
          copy['format'] = c['format'] if c['format']
          copy
        end
        el = { 'id' => cid, 'kind' => 'table', 'name' => "#{src['name'] || m} (#{pg['name'] || pg['id']})",
               'source' => { 'kind' => 'table', 'elementId' => m }, 'columns' => cols }
        data_elements << el
        by_id[cid] = el
        copies[[m, pg['id']]] = cid
        result['copies']["#{m}|#{pg['id']}"] = cid
      end
    end

    rewrite = lambda do |node, pid|
      case node
      when Hash
        node.each do |k, v|
          if k == 'elementId' && v.is_a?(String) && copies[[v, pid]]
            node[k] = copies[[v, pid]]
          else
            rewrite.call(v, pid)
          end
        end
      when Array then node.each { |v| rewrite.call(v, pid) }
      end
    end
    swap = lambda do |str, pid|
      out = str
      shared.each { |m| out = out.gsub("[#{m}/", "[#{copies[[m, pid]]}/") if copies[[m, pid]] }
      out
    end
    rewrite_strings = lambda do |node, pid|
      case node
      when Hash then node.each { |k, v| node[k] = v.is_a?(String) ? swap.call(v, pid) : (rewrite_strings.call(v, pid); v) }
      when Array then node.each_with_index { |v, i| node[i] = v.is_a?(String) ? swap.call(v, pid) : (rewrite_strings.call(v, pid); v) }
      end
    end

    # snapshot the controls' ORIGINAL master targets before anything is retargeted
    orig_filters = {}
    content_pages.each do |pg|
      Array(pg['elements']).each { |el| orig_filters[el['id']] = Marshal.load(Marshal.dump(el['filters'])) if el['kind'] == 'control' && el['filters'] }
    end

    content_pages.each do |pg|
      pid = pg['id']
      Array(pg['elements']).each do |el|
        next if el['kind'] == 'control'
        rewrite.call(el, pid)
        rewrite_strings.call(el, pid)
        if (h = by_id[src_id.call(el)]) && helper_page[h['id']] == pid && !masters.include?(h['id']) &&
           !h.key?('_pl_done')
          rewrite.call(h, pid)
          rewrite_strings.call(h, pid)
          h['_pl_done'] = true
        end
      end
    end
    data_elements.each { |e| e.delete('_pl_done') }

    primaries = {}
    content_pages.each do |pg|
      Array(pg['elements']).each do |el|
        primaries[el['controlId']] ||= [el, pg['id']] if el['kind'] == 'control' && el['controlType'].to_s != 'synced' && el['controlId']
      end
    end
    retarget = lambda do |f, pid|
      m = f.dig('source', 'elementId')
      next f unless shared.include?(m)
      c = copies[[m, pid]]
      ncid = c && colmap[[m, pid, f['columnId']]]
      next nil unless ncid
      f.merge('source' => f['source'].merge('elementId' => c), 'columnId' => ncid)
    end
    content_pages.each do |pg|
      pid = pg['id']
      Array(pg['elements']).each do |el|
        next unless el['kind'] == 'control'
        # a control that carries a direct table `source` (a date-range control's inherited one)
        # follows its page; a list control's value-list `source` ({kind: source}) stays on the master
        s = el['source']
        if s.is_a?(Hash) && s['kind'] == 'table' && copies[[s['elementId'], pid]]
          s['elementId'] = copies[[s['elementId'], pid]]
        end
        next unless el['filters'].is_a?(Array)
        before = el['filters'].size
        nf = []
        orig_filters[el['id']].each do |f|
          r = f.is_a?(Hash) ? retarget.call(f, pid) : f
          if r.nil?
            result['dropped'] += 1
          else
            result['retargeted'] += 1 if r != f
            nf << r
          end
        end
        el['filters'] = nf
        result['emptied'] << el['id'] if nf.empty? && before.positive?
      end
    end
    # synced members: extend each primary with the copies of the member pages
    content_pages.each do |pg|
      Array(pg['elements']).each do |el|
        next unless el['kind'] == 'control' && el['controlType'].to_s == 'synced'
        prim, _ppid = primaries[el['controlId']]
        next unless prim && prim['filters'].is_a?(Array)
        orig_filters[prim['id']].each do |f|
          r = f.is_a?(Hash) ? retarget.call(f, pg['id']) : nil
          next unless r
          dup = prim['filters'].any? { |x| x.dig('source', 'elementId') == r.dig('source', 'elementId') && x['columnId'] == r['columnId'] }
          prim['filters'] << r unless dup
          result['emptied'].delete(prim['id'])
        end
      end
    end
    result
  end
end
