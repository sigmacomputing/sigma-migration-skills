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
end
