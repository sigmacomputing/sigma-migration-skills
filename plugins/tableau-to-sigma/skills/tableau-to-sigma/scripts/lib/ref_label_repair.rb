# frozen_string_literal: true
# Global element-ref label repair (v5.4).
#
# The chart builder authors formula refs from RAW Tableau serialization tokens
# (physical column names like NUM_ENROLLED, twb caption casing like
# runner_dir), while the live workbook elements carry Sigma DISPLAY labels
# ("Num Enrolled", "Runner Dir"). The v5.3 repair fixed this for hidden
# grain-helper elements only; every field run since showed the same drift on
# CHART elements referencing the master (and sibling generated sources), which
# the pre-POST ref gate then fails one ref at a time.
#
# This is the general form: given ALL generated workbook elements and a
# registry of live element names -> live column labels, re-case every
# [Element/Column] ref in every element's column formulas —
#   - the ELEMENT segment is matched normalized (case/punct-insensitive) and
#     rewritten to the live element name;
#   - the COLUMN segment is matched against that element's live labels,
#     exact first, then normalized, and rewritten to the exact label.
# Refs whose element segment matches nothing in the registry are left verbatim
# (they may be authored against elements outside this build; the pre-POST ref
# gate remains the authority). Ambiguous normalizations are never guessed:
# they are reported and left untouched.
#
# SINGLE-SEGMENT (same-element) re-casing — opt-in via same_element_recase: true.
# A data-model calc authored from twb tokens carries BARE refs ([Totalrev],
# [Userid]) that mean "a column on THIS element". Snowflake/Sigma read those
# columns back UPPERCASE ([TOTALREV]), so the bare TitleCase ref resolves to
# type=error. When enabled (DM path only — never the workbook path, where a bare
# [ctl-id] bracket is a CONTROL reference, see test), each element's bare refs are
# re-cased against that element's OWN live labels. Two hard guards keep it honest:
#   (1) a bare token is rewritten ONLY if it matches a real column label on the
#       element — a non-column bracket (a control id) never matches and is left
#       verbatim; and
#   (2) if the same normalized column name also exists on ANOTHER element, the
#       bare ref is CROSS-ELEMENT-AMBIGUOUS (the classic collapsed-multi-datasource
#       IFNULL pattern) — it is NOT rewritten (that is a Lookup/relationship fix,
#       not a casing fix), so this pass never silently turns a should-be-cross-
#       element ref into a same-element one and masks a real gap.
# IDENTITY-ALIAS calcs (#457): a calc that is an identity alias of its own raw
# column (`[Foo (copy)] = [Foo]`) surfaces the raw column under warehouse-readback
# casing ("FOO") AND the alias under Sigma's auto-generated title-case display
# label ("Foo"), so on THIS element two live labels collide in normalization. That
# collision would trip the "ambiguous label" refusal even though it is not two
# distinct columns — it is one column name in two casings. When every colliding
# label is a PURE CASE VARIANT (identical under downcase — differs only by case,
# never by punctuation/spacing, so "Ship Mode"/"SHIP_MODE" is NOT included), the
# bare ref is recased to the single mono-case candidate (the raw readback casing —
# never the mixed-case auto-label, which is the alias itself and would self-refer).
# Cross-element collisions are still refused (guard 2 stays authoritative).
module RefLabelRepair
  REF_RE = /\[([^\[\]\/]+)\/([^\[\]]+)\]/.freeze
  BARE_RE = /\[([^\[\]\/]+)\]/.freeze

  def self.norm(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # registry: { live_element_name => [live column label, ...], ... }
  # qualified: run the [Element/Column] pass (default true — the workbook path).
  #   The DM path passes qualified:false: DM formulas reference their own columns
  #   through SOURCE aliases ([Custom SQL/COL], [TABLE_ALIAS/COL]) that are NOT the
  #   element's display name, so rewriting the element segment could break a valid
  #   self-ref; the DM only needs the bare-column casing fix.
  # same_element_recase: also re-case BARE [Column] refs against the owning
  #   element's own live labels (opt-in; DM path only — see module header).
  # Returns { fixed: N, misses: [..], ambiguous: [..] }; mutates elements.
  def self.repair!(elements, registry, qualified: true, same_element_recase: false)
    by_norm_el = {}
    ambiguous_els = {}
    registry.each_key do |name|
      key = norm(name)
      if by_norm_el.key?(key) && by_norm_el[key] != name
        ambiguous_els[key] = true
      else
        by_norm_el[key] = name
      end
    end

    label_maps = {}
    registry.each do |name, labels|
      by_norm = {}
      amb = {}
      Array(labels).map(&:to_s).each do |l|
        key = norm(l)
        if by_norm.key?(key) && by_norm[key] != l
          amb[key] = true
        else
          by_norm[key] = l
        end
      end
      label_maps[name] = { exact: Array(labels).map(&:to_s), by_norm: by_norm, ambiguous: amb }
    end

    # Cross-element column-ownership index: norm(column) => count of DISTINCT
    # elements that carry a column with that normalization. Used only by the
    # bare-ref (same_element_recase) pass to refuse re-casing a column name that
    # lives on more than one element (the collapsed-multi-datasource ambiguity).
    owner_count = Hash.new(0)
    registry.each_value do |labels|
      Array(labels).map { |l| norm(l) }.uniq.each { |k| owner_count[k] += 1 }
    end

    fixed = 0
    misses = []
    ambiguous = []
    Array(elements).each do |el|
      cols = el.is_a?(Hash) ? el['columns'] : nil
      next unless cols.is_a?(Array)
      el_name = el.is_a?(Hash) ? el['name'] : nil
      own_lm = same_element_recase && el_name.is_a?(String) ? label_maps[el_name] : nil
      cols.each do |c|
        next unless c.is_a?(Hash) && c['formula'].is_a?(String)
        c['formula'] = c['formula'].gsub(REF_RE) do
          next Regexp.last_match(0) unless qualified
          el_seg = Regexp.last_match(1)
          col_seg = Regexp.last_match(2)
          el_key = norm(el_seg)
          if ambiguous_els[el_key]
            ambiguous << "[#{el_seg}/#{col_seg}] (element name normalizes ambiguously)"
            "[#{el_seg}/#{col_seg}]"
          elsif (live_el = by_norm_el[el_key])
            lm = label_maps[live_el]
            col_ambiguous = !lm[:exact].include?(col_seg) && lm[:ambiguous][norm(col_seg)]
            live_col =
              if lm[:exact].include?(col_seg)
                col_seg
              elsif col_ambiguous
                nil
              else
                lm[:by_norm][norm(col_seg)]
              end
            if live_col
              fixed += 1 if live_col != col_seg || live_el != el_seg
              "[#{live_el}/#{live_col}]"
            else
              if col_ambiguous
                ambiguous << "[#{el_seg}/#{col_seg}] (label normalizes ambiguously on '#{live_el}')"
              else
                misses << "[#{el_seg}/#{col_seg}] (no matching label on '#{live_el}')"
              end
              "[#{el_seg}/#{col_seg}]"
            end
          else
            "[#{el_seg}/#{col_seg}]"
          end
        end
        # Second pass: BARE [Column] refs → this element's own live labels
        # (opt-in; DM path only). Slash refs are already rewritten above and
        # BARE_RE (no slash inside) will not re-match them.
        next unless own_lm
        c['formula'] = c['formula'].gsub(BARE_RE) do
          tok = Regexp.last_match(1)
          key = norm(tok)
          # IDENTITY-ALIAS same-element casing collision (issue #457) — checked
          # BEFORE the exact-match leave. A calc that is an identity alias of its
          # own raw column (`[Foo (copy)] = [Foo]`) surfaces the raw column under
          # its warehouse-readback casing ("FOO") AND the alias under Sigma's
          # auto-generated display label — and when the alias's "(copy)" decoration
          # is stripped, that display label collapses onto the raw column name in a
          # different casing ("Foo"). So THIS element carries >1 live label that
          # normalizes to `key`, all PURE CASE VARIANTS of one another (identical
          # under downcase — the SAME name in two casings, never two distinct
          # columns like "Ship Mode"/"SHIP_MODE", which differ by punctuation). The
          # bare ref then either matches nothing exactly OR exact-matches the
          # mixed-case auto-label — and leaving it there resolves the ref to the
          # alias itself, a circular self-reference / type=error. Recase it to the
          # raw column's authoritative readback casing: the single mono-case
          # candidate (all-UPPER on Snowflake / all-lower on Databricks; the
          # mixed-case auto-label is never mono-case, so we never pick the alias).
          # HARD GUARDS kept intact: only a single-element collision qualifies
          # (owner_count <= 1 — a cross-element collision is the collapsed-multi-
          # datasource pattern #407 guards, still refused below); every colliding
          # label must be a pure case variant (a genuinely-distinct ambiguity is
          # still refused); and there must be exactly ONE mono-case candidate (no
          # unique raw casing → we don't guess).
          ia_cands = own_lm[:exact].select { |l| norm(l) == key }
          ia_mono = ia_cands.select { |l| l == l.upcase || l == l.downcase }
          if ia_cands.size > 1 && owner_count[key] <= 1 &&
             ia_cands.map { |l| l.downcase }.uniq.size == 1 && ia_mono.size == 1
            fixed += 1 if ia_mono.first != tok
            next "[#{ia_mono.first}]"
          end
          if own_lm[:exact].include?(tok)
            "[#{tok}]"                                   # already exact — leave
          elsif own_lm[:ambiguous][key]
            # >1 live label normalizes to `key` and it is NOT the identity-alias
            # casing shape handled above (genuinely distinct columns, or no unique
            # raw casing) — a real ambiguity we must never guess.
            ambiguous << "[#{tok}] (label normalizes ambiguously on '#{el_name}')"
            "[#{tok}]"
          elsif owner_count[key] > 1
            # column of this normalization lives on >1 element — a cross-element
            # (collapsed multi-datasource) ref, NOT a casing fix. Leave it to the
            # relationship/Lookup path so we never mask a real gap.
            ambiguous << "[#{tok}] (bare ref matches columns on multiple elements — needs a cross-element Lookup, not re-casing)"
            "[#{tok}]"
          elsif (live = own_lm[:by_norm][key])
            fixed += 1 if live != tok
            "[#{live}]"
          else
            "[#{tok}]"                                   # not a column here (e.g. a control id) — leave verbatim
          end
        end
      end
    end
    { fixed: fixed, misses: misses.uniq, ambiguous: ambiguous.uniq }
  end
end
