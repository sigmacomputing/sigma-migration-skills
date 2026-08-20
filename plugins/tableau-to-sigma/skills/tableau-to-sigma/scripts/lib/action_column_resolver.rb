# frozen_string_literal: true

# Resolve a Tableau action's `source-field` ref to the Sigma column NAME that
# the converter actually emitted.
#
# Why this is its own unit: field_caption() in build-postpublish-guide.rb
# answers a different question (what should a human read?) and its answer is
# lossy on purpose — it strips the derivation qualifier and tidies the name.
# Emission needs the opposite: an exact join to a column that exists on the
# host element. Mixing the two is what made parameter actions unbuildable.
#
# Returns nil rather than guessing. A guessed column ships a schema-valid
# action that silently sets the control to the wrong value — worse than
# residue, which at least tells the customer to wire it by hand.
module ActionColumnResolver
  module_function

  # ref:             raw Tableau ref, e.g. "[federated.f1].[none:Calculation_100:nk]"
  # mmap:            the master map (regex string => {'name' => <sigma column>})
  # columns_by_guid: internal calc name => { 'caption' => <friendly caption>, ... }
  def resolve(ref:, mmap:, columns_by_guid:)
    inner = strip_qualifier(ref)
    return nil if inner.nil?

    # An internal calc name (Calculation_NNN, optionally blend-suffixed " 1")
    # is never a master-map key — bridge it to its friendly caption first.
    caption = (columns_by_guid[inner].is_a?(Hash) && columns_by_guid[inner]['caption']) ||
              (columns_by_guid[inner.sub(/\s+\d+\z/, '')].is_a?(Hash) && columns_by_guid[inner.sub(/\s+\d+\z/, '')]['caption']) ||
              inner

    info = match_column(caption, mmap)
    info && info['name']
  end

  # "[federated.f1].[none:Calculation_100:nk]" -> "Calculation_100"
  # "[Region]"                                 -> "Region"
  # "[Parameters].[Parameter 1]"               -> "Parameter 1"
  def strip_qualifier(ref)
    return nil if ref.nil? || ref.to_s.empty?
    inner = ref[/\.\[([^\[\]]+)\]\s*\z/, 1] || ref[/\A\[([^\[\]]+)\]\z/, 1] || ref.to_s
    # none:X:nk, usr:X:qk, and the 4-segment usr:X:nk:1 instance-numbered shape.
    inner = Regexp.last_match(1) if inner =~ /\A[a-z]+:(.+?):[a-z]+(?::\d+)?\z/i
    inner = inner.sub(/\A:/, '')
    inner.strip.empty? ? nil : inner.strip
  end

  # Mirrors build-charts-from-signals.rb's map_column so a ref resolves to the
  # same column the chart build emitted — first regex wins, same as there.
  def match_column(caption, mmap)
    h = caption.to_s.strip
    mmap.each { |pat, info| return info if Regexp.new(pat).match?(h) }
    nil
  end
end
