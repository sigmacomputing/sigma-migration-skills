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
end
