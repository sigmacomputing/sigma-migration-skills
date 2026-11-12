# frozen_string_literal: true
#
# PbiFieldAlts — synthesize a derived field_map entry, applying the SAME transform to
# the primary ref and to every inherited alt.
#
# WHY THIS EXISTS (found 2026-07-30 by reading the rendered dashboard PNG, not by any
# numeric check — every value check was green):
#
# A classic Power BI report binds an aggregated measure as "Sum(TABLE.COL)". No
# field_map key exists in that shape, so migrate-powerbi.rb synthesizes one from the
# plain-column entry. The old code was:
#
#     field_map[r] = base.merge('ref' => "Sum(#{base['ref']})", 'agg' => nil)
#
# `Hash#merge` copies every key — including `alts`, the alternate resolutions of the
# same field on OTHER masters (the joined "View" element, chiefly). Only the top-level
# `ref` was wrapped, so the alts kept their BARE column refs. Under
# one-base-table-per-page the chosen base master is normally the View, so field_spec
# swaps in the alt — and the aggregation silently disappears. Measured:
#
#     'Sum(ABSENCE_RECORDS.HOURS)' -> ref  "Sum([master-06cf9224/Hours])"    correct
#                                     alts [{ref: "[master-e55e899b/Hours]"}]  BARE
#
# A pie chart whose value column is a row-level column cannot compute slice angles:
# Sigma rendered its legend and no slices. The same defect hit the date-hierarchy
# branch (which wraps in DateTrunc), so a chart that should plot by YEAR plotted at DAY
# grain — a dense spiky line on the same dashboard.
#
# `merge` also ALIASES the alts array, so wrapping them in place would corrupt the
# plain-column entry that legitimately wants bare refs. Hence the deep copy.
#
# This bug class is invisible to the field-binding coverage gate: the ref RESOLVES, it
# just resolves to the wrong formula. Numbers-green, render-broken.
module PbiFieldAlts
  module_function

  # base  : the plain-column field_map entry to derive from
  # block : ref String -> wrapped String (e.g. ->(r) { "Sum(#{r})" })
  #
  # Returns a NEW entry whose `ref` is wrapped and whose `alts` are deep-copied with
  # their `ref` (and `formula`, when present — the builder prefers it, so a stale
  # unwrapped formula would reintroduce the bug) wrapped by the same block. `agg` is
  # cleared because the wrapper IS the aggregation now; leaving it set would make the
  # builder aggregate twice.
  def wrapped_entry(base)
    out = base.merge('ref' => yield(base['ref'].to_s), 'agg' => nil)
    alts = base['alts']
    return out unless alts.is_a?(Array) && !alts.empty?
    out['alts'] = alts.map do |a|
      b = a.dup                                  # never mutate the caller's alt
      b['ref'] = yield(a['ref'].to_s) if a['ref']
      b['formula'] = yield(a['formula'].to_s) if a['formula']
      b['agg'] = nil
      b
    end
    out
  end

  CLASSIC_AGGS = { 'sum' => 'Sum', 'avg' => 'Avg', 'average' => 'Avg', 'min' => 'Min', 'max' => 'Max',
                   'count' => 'Count', 'countnonnull' => 'Count',
                   'distinctcount' => 'CountDistinct' }.freeze

  # bead anlb — CLASSIC-report queryRef normalization. The legacy report.json binds
  # measures as "Sum(Entity.Col)" / "Count(Entity.Col)" and date hierarchies as
  # "Entity.Col.Variation.Date Hierarchy.<Level>". Neither key shape exists in the
  # Entity.Field map, so those bindings fell through to a literal bracketed ref ->
  # silent error-typed column. Resolve both shapes via a case/underscore-insensitive
  # lookup against the existing map, wrapping the ALTS too (see wrapped_entry).
  def normalize_classic_refs!(field_map, refs)
    norm_key = ->(k) { k.to_s.downcase.gsub(/[^a-z0-9.]/, '') }
    fm_norm = {}
    field_map.each { |k, v| fm_norm[norm_key.call(k)] ||= v }
    refs.uniq.each do |r|
      next if r.nil? || field_map.key?(r)

      if (m = r.match(/\A([A-Za-z ]+)\((.+)\)\z/)) && CLASSIC_AGGS[m[1].downcase.delete(' ')]
        base = fm_norm[norm_key.call(m[2])]
        next unless base && base['ref'].to_s =~ /\A\[[^\]]+\]\z/

        fn = CLASSIC_AGGS[m[1].downcase.delete(' ')]
        field_map[r] = wrapped_entry(base) { |ref| "#{fn}(#{ref})" }
      elsif (m = r.match(/\A(.+?)\.Variation\..*\.(Year|Quarter|Month|Week|Day)\z/i))
        base = fm_norm[norm_key.call(m[1])]
        next unless base && base['ref'].to_s =~ /\A\[[^\]]+\]\z/

        lvl = m[2].downcase
        field_map[r] = wrapped_entry(base) { |ref| "DateTrunc(\"#{lvl}\", #{ref})" }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # G28 — a field's OWN parenthetical survives the alias to the joined View column.
  #
  # The converter's joined "<FACT> View" names every dimension column
  # "<Leaf> (<ENTITY>)". A Power BI field can itself be named with a parenthetical
  # ("DimDate.Date (Fiscal Month)"), and the alias pass stripped ANY trailing "(...)" off the
  # leaf before looking the View column up, so it resolved to "Date (DimDate)" — the
  # plain Date column — and every monthly chart plotted daily. Only an ENTITY
  # disambiguation suffix may be stripped.
  # ---------------------------------------------------------------------------
  TRAILING_PAREN = /\s+\(([^()]*)\)\s*\z/.freeze

  def norm_name(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # The leaf of `qr` ("Entity.Leaf") to look up on the View, with only a trailing
  # "(<one of entity_names>)" removed (case/punctuation-insensitive).
  def view_lookup_leaf(qr, entity_names)
    leaf = qr.to_s.split('.', 2).last.to_s
    own = leaf[TRAILING_PAREN, 1]
    return leaf unless own
    Array(entity_names).any? { |n| norm_name(n) == norm_name(own) } ? leaf.sub(TRAILING_PAREN, '') : leaf
  end

  # Repair View alts already registered by PbiViewRoute.add_view_alts! for fields whose
  # own name carries a parenthetical. `masters` is the master-map's masters hash
  # (name => {'id','columns'}). A plain-column alt on a master whose column is the
  # stripped alias ("Date (DimDate)") is rewritten to the exact column
  # ("Date (Fiscal Month) (DimDate)") when the View has it; when it does NOT, the alt is REMOVED
  # (a wrong-grain alias must never stay) and reported. Idempotent.
  # Returns {'fixed'=>n, 'dropped'=>[{'field','master','alias','wanted'}]}.
  def repair_view_alts!(field_map, masters)
    out = { 'fixed' => 0, 'dropped' => [] }
    by_name = masters || {}
    field_map.each do |qr, fs|
      alts = fs['alts']
      next unless alts.is_a?(Array) && !alts.empty?
      leaf = qr.to_s.split('.', 2).last.to_s
      own = leaf[TRAILING_PAREN, 1]
      next unless own
      stem = leaf.sub(TRAILING_PAREN, '')
      alts.reject! do |a|
        m = by_name[a['master']]
        next false unless m && a['ref'].to_s =~ /\A\[([^\/\]]+)\/([^\]]+)\]\z/
        col = Regexp.last_match(2)
        next false if col.casecmp(leaf).zero?
        suffix = col[TRAILING_PAREN, 1]
        next false if suffix && norm_name(suffix) == norm_name(own) # the leaf's own entity tag, not a lost one
        base = suffix ? col.sub(TRAILING_PAREN, '') : col
        next false unless base.casecmp(stem).zero?                  # not the stripped alias of THIS field
        wanted = suffix ? "#{leaf} (#{suffix})" : leaf
        hit = Array(m['columns']).find { |c| c['name'].to_s.casecmp(wanted).zero? }
        if hit
          a['ref'] = "[#{m['id']}/#{hit['name']}]"
          out['fixed'] += 1
          false
        else
          out['dropped'] << { 'field' => qr, 'master' => a['master'], 'alias' => col, 'wanted' => wanted }
          true
        end
      end
    end
    out
  end
end
