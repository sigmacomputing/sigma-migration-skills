# frozen_string_literal: true

# layout_reuse.rb — decide whether a `--reuse-workbook` re-entry keeps the
# layout that is ALREADY LIVE on the workbook or regenerates it from the
# Tableau zones.
#
# WHY: iterating a fix with `--reuse-dm <id> --wb-spec <path> --reuse-workbook
# <id>` used to PUT the new spec (no layout) and then regenerate the layout from
# the Tableau zone tree — silently discarding the RCF (render-compare-fix)
# layout fixes already applied to the live workbook. Default is now PRESERVE:
# the live layout is re-applied as the LAST write (layout-last rule). Regenerate
# only on --regenerate-layout, a blank live layout, or a full rebuild that keeps
# under 30% of the live ids.
#
# Pure: ids in, decision out (testable offline).
module LayoutReuse
  # Orchestrator-injected layout chrome: put-layout.rb injects these from a
  # sidecar, so they live in the LIVE spec but not in a rebuilt wb-spec.
  CHROME_RE = /\A(?:(?:tc|syn|band)-|dv-)/.freeze

  module_function

  def chrome?(id)
    id.to_s.match?(CHROME_RE)
  end

  # live_layout      — XML string of the live workbook layout
  # new_ids          — element ids in the NEW spec
  # live_ids         — element ids in the LIVE spec (carriable into the PUT)
  # regenerate       — user passed --regenerate-layout
  # Returns { path: :preserve | :regenerate, reason:, stale: [ids], unplaced: [ids], merge: bool }
  def decide(live_layout:, new_ids:, live_ids:, regenerate: false)
    if regenerate
      return { path: :regenerate, reason: '--regenerate-layout passed', stale: [], unplaced: [] }
    end
    if live_layout.to_s.strip.empty?
      return { path: :regenerate, reason: 'live workbook has no layout to preserve', stale: [], unplaced: [] }
    end
    new_ids = Array(new_ids).map(&:to_s)
    live_ids = Array(live_ids).map(&:to_s)
    refs = live_layout.to_s.scan(/elementId="([^"]+)"/).flatten.uniq
    # A reference is satisfiable when the new spec has it, or it is injected
    # chrome the PUT carries over from the live spec.
    stale = refs.reject { |id| new_ids.include?(id) || (chrome?(id) && live_ids.include?(id)) }
    # Genuinely NEW elements (not live either) have no placement in the live layout.
    unplaced = new_ids.reject { |id| refs.include?(id) || live_ids.include?(id) || chrome?(id) }
    kept = refs.size - stale.size
    # A FULL rebuild re-mints every id: nothing live survives, so there is no
    # layout to keep (same 30% generation floor post-and-readback uses).
    # Injected chrome survives any rebuild, so it does not count.
    content = refs.reject { |id| chrome?(id) }
    survived = content.count { |id| new_ids.include?(id) }
    if content.any? && survived < (content.size * 0.3).ceil
      return { path: :regenerate, stale: stale, unplaced: unplaced,
               reason: "stale generation: only #{survived} of #{content.size} live layout element(s) survive in the new spec (full rebuild)" }
    end
    # Otherwise MERGE: every live placement is kept, removed ids are pruned and
    # new ones are placed into the live layout (lib/layout_merge.rb) — never a
    # whole-layout regeneration for an edit (live proof: one added control
    # reverted 19 RCF placements).
    note = []
    note << "prune #{stale.size} removed: #{stale.first(10).join(', ')}" if stale.any?
    note << "place #{unplaced.size} new: #{unplaced.first(10).join(', ')}" if unplaced.any?
    { path: :preserve, stale: stale, unplaced: unplaced, merge: stale.any? || unplaced.any?,
      reason: "live layout places #{refs.size} element(s); keeping all #{kept} that survive" \
              "#{note.empty? ? '' : " (#{note.join('; ')})"}" }
  end
end
