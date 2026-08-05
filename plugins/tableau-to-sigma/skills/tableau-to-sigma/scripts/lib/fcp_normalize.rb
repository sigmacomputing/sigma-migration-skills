# frozen_string_literal: true
#
# fcp_normalize.rb — normalize Tableau's forward-compatibility (FCP) element
# names in .twb XML BEFORE any parsing.
#
# Tableau serializes newer-feature content behind mangled element names:
#   <_.fcp.DashboardRoundedCorners.true...format attr='corner-radius' value='30'/>
#   <_.fcp.ObjectModelEncapsulateLegacy.false...relation ...>
# Pattern: `_.fcp.<FeatureName>.<true|false>...<CanonicalName>`. The `.true`
# variant carries the MODERN content (for consumers that understand the
# feature); `.false` is the legacy fallback. A parser matching literal element
# names sees NEITHER — which silently hid Tableau's entire native
# rounded-corner surface (2026.1+) from this skill (field-caught: a real
# workbook carried corner-radius 30/20/5 that every run ignored). The official
# TWB schemas (github.com/tableau/tableau-document-schemas) model only the
# canonical names, so normalization also makes schema-driven parsing possible.
#
# Policy: rename `.true` variants to their canonical element name; DROP
# `.false` fallback subtrees entirely (keeping both would duplicate content).
# Pure text-level transform: Tableau emits these names as literal element
# tokens, and `<_.fcp.` cannot appear un-escaped inside attribute values.
module FcpNormalize
  module_function

  TRUE_RE = %r{(</?)_\.fcp\.[A-Za-z0-9_]+\.true\.\.\.}
  FALSE_OPEN_RE = /<_\.fcp\.([A-Za-z0-9_]+)\.false\.\.\.([A-Za-z0-9_-]+)/

  # Any FCP tokens present at all? (cheap pre-check for hot paths)
  def needed?(xml)
    xml.include?('_.fcp.')
  end

  def normalize(xml)
    return xml unless needed?(xml)
    s = xml.dup
    # 1. Drop `.false` fallback subtrees (balanced removal, self-close aware).
    while (m = s.match(FALSE_OPEN_RE))
      feature, name = m[1], m[2]
      open_tag  = "<_.fcp.#{feature}.false...#{name}"
      close_tag = "</_.fcp.#{feature}.false...#{name}>"
      start = m.begin(0)
      tag_end = s.index('>', start)
      break unless tag_end
      if s[tag_end - 1] == '/'
        s.slice!(start..tag_end)
        next
      end
      depth = 1
      pos = tag_end + 1
      while depth.positive?
        nxt_open  = s.index(open_tag, pos)
        nxt_close = s.index(close_tag, pos)
        break if nxt_close.nil?
        if nxt_open && nxt_open < nxt_close
          depth += 1
          pos = s.index('>', nxt_open).to_i + 1
        else
          depth -= 1
          pos = nxt_close + close_tag.length
        end
      end
      break if depth.positive? # unbalanced — leave document usable, stop here
      s.slice!(start...pos)
    end
    # 2. Rename `.true` variants to their canonical element names.
    s.gsub(TRUE_RE, '\1')
  end
end
