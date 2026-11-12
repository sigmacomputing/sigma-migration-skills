# frozen_string_literal: true

# pbi_conditional_formats.rb — map extract-pbir's normalized table/matrix
# conditional-formatting records (rec['conditional_formats']) to Sigma
# element-level `conditionalFormats`. Pure + offline (no globals, no API) so it
# is unit-testable; build-workbook-from-pbir.rb requires it and feeds the
# returned coverage entries to record_unresolved.
#
# Mappable modes (emitted as Sigma conditionalFormats):
#   gradient  -> backgroundScale / fontScale (a low->high color scale)
#   dataBars  -> dataBars (sign-colored bars; see feedback_sigma_table_databars_spec)
#   rules     -> one `single` per band (native op+value; a two-sided And range ->
#              condition:formula "[Col] >= lo and [Col] < hi"). Cross-column /
#              compound / else-default cases -> coverage.
# Non-mappable (returned as coverage entries, NEVER silently dropped):
#   fieldValue (a DAX measure returns the hex) — the measure lives in the model,
#              not the report; recoverable once the measure is translated.
require_relative 'pbi_theme'

module PbiConditionalFormats
  module_function

  # Leaf of a PBI queryRef / Sigma ref: strip aggregation wrappers + take the
  # segment after the last '.', matching build-workbook-from-pbir.rb's qr_leaf so
  # an entity-qualified selector.metadata ("ORDER_FACT.Net Revenue $") matches a
  # bound queryRef that differs only by entity prefix.
  def leaf(qr)
    s = qr.to_s.strip
    s = Regexp.last_match(1).strip while s =~ /\A[A-Za-z_][A-Za-z0-9_ ]*\(\s*(.*)\s*\)\z/
    s.split('.').last.to_s.tr('[]', '').tr('/', '-')
  end

  # Resolve a CF target (selector.metadata) to a built column id in qr_cids
  # ({queryRef => columnId}). Exact match first, then a leaf-name fallback.
  def resolve(target, qr_cids)
    return qr_cids[target] if qr_cids[target]
    tl = leaf(target)
    return nil if tl.empty?
    hit = qr_cids.find { |qr, _| leaf(qr).casecmp(tl).zero? }
    hit && hit[1]
  end

  # True when the exact lookup misses and the leaf fallback would match bound queryRefs that map
  # to MORE THAN ONE built column (never guess which one a fill meant).
  def ambiguous_leaf?(target, qr_cids)
    return false if qr_cids[target]
    tl = leaf(target)
    return false if tl.empty?
    qr_cids.select { |qr, _| leaf(qr).casecmp(tl).zero? }.values.uniq.size > 1
  end

  # Merge entries that fill the same column into one style (back from the entry that has it, font
  # from the entry that has it; the later one wins on a shared property, as Power BI applies them in
  # order). Position of the first entry is kept. With `qr_cids`, value-cell entries are keyed by the
  # column they resolve to, so spellings that differ ("Sum(T.A)" / "T.A") or parts flags that differ
  # still become ONE value-cell rule (two always-true rules on one column could paint white on white);
  # the merged entry keeps every chrome part either entry styled. Other entries key on target + flags.
  def merge_column_formats(entries, qr_cids = nil)
    merged = []
    index = {}
    Array(entries).each do |cf|
      cid = qr_cids && cf['values'] && !ambiguous_leaf?(cf['target'], qr_cids) ? resolve(cf['target'], qr_cids) : nil
      key = cid ? [:column, cid] : [cf['target'], cf['header'], cf['values'], cf['subtotals'], cf['total']]
      if (i = index[key])
        m = merged[i]
        m['back'] = cf['back'] unless cf['back'].nil?
        m['font'] = cf['font'] unless cf['font'].nil?
        %w[header subtotals total].each { |f| m[f] = true if cid && cf[f] }
      else
        index[key] = merged.size
        merged << cf.dup
      end
    end
    merged
  end

  # "0.15" -> 0.15, "3" -> 3, "East" -> "East" (a threshold value for a single rule).
  def coerce_val(v)
    return v unless v.is_a?(String)
    return Integer(v) if v =~ /\A-?\d+\z/
    return Float(v) if v =~ /\A-?\d+\.\d+\z/
    v
  end

  # A threshold as a Sigma formula literal: numbers bare, strings double-quoted.
  def fmt_literal(v)
    cv = coerce_val(v)
    cv.is_a?(Numeric) ? cv.to_s : %("#{cv}")
  end

  # A rule's comparison list -> one Sigma `single` conditionalFormat, or nil when
  # the shape isn't a plain op / two-sided range (caller routes nil to coverage).
  # A single comparison uses a native operator condition; a two-sided And range
  # uses `condition: formula` (Sigma `single` has no Between) referencing the
  # column by display name.
  def single_from_comparisons(comps, cid, col_name, color, style_key)
    style = { style_key => color }
    if comps.size == 1
      c = comps[0]
      { 'type' => 'single', 'columnIds' => [cid], 'condition' => c['op'],
        'value' => coerce_val(c['value']), 'style' => style }
    elsif comps.size == 2
      lo = comps.select { |c| ['>', '>='].include?(c['op']) }
      hi = comps.select { |c| ['<', '<='].include?(c['op']) }
      return nil unless lo.size == 1 && hi.size == 1
      formula = "[#{col_name}] #{lo[0]['op']} #{fmt_literal(lo[0]['value'])} and " \
                "[#{col_name}] #{hi[0]['op']} #{fmt_literal(hi[0]['value'])}"
      { 'type' => 'single', 'columnIds' => [cid], 'condition' => 'formula',
        'formula' => formula, 'style' => style }
    end
  end

  # Returns { 'formats' => [Sigma conditionalFormats...], 'coverage' => [entries] }.
  # Each coverage entry is a hash of record_unresolved keyword args.
  def build(cfs, qr_cids, name, kind)
    formats = []
    coverage = []
    Array(cfs).each do |cf|
      cid = resolve(cf['target'], qr_cids)
      unless cid
        coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                      severity: 'degraded', recoverable: false,
                      detail: "conditional format on '#{cf['target']}' — that column is not in the migrated #{kind}" }
        next
      end
      case cf['mode']
      when 'gradient'
        scheme = Array(cf['scheme']).select { |c| c.to_s =~ /\A#/ }
        scheme = %w[#ffffcc #bd0026] if scheme.size < 2
        type = cf['property'] == 'font' ? 'fontScale' : 'backgroundScale'
        formats << { 'type' => type, 'columnIds' => [cid], 'scheme' => scheme }
      when 'dataBars'
        # low->high = negative,positive (Sigma bars are sign-colored, not a value gradient)
        scheme = [cf['negative'], cf['positive']].compact.select { |c| c.to_s =~ /\A#/ }
        scheme = ['#4caf7d'] if scheme.empty?
        formats << { 'type' => 'dataBars', 'columnIds' => [cid], 'scheme' => scheme }
      when 'fieldValue'
        coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                      severity: 'approximated', recoverable: true,
                      detail: "field-value conditional format on '#{cf['target']}' (color driven by measure #{cf['measure']})",
                      action: 'The cell color is computed by a DAX measure; re-create it in Sigma as a conditionalFormat with a `formula` condition once that measure is translated.' }
      when 'rules'
        rules = Array(cf['rules'])
        if rules.empty?
          # a Conditional/FillRule we couldn't model into discrete bands
          coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                        severity: 'degraded', recoverable: true,
                        detail: "rules-based conditional format on '#{cf['target']}' (unmodeled shape)",
                        action: 'Re-create the threshold rules in the Sigma UI (conditionalFormats type:single).' }
        else
          style_key = cf['property'] == 'font' ? 'color' : 'backgroundColor'
          tl = leaf(cf['target'])
          rules.each do |r|
            comps = Array(r['comparisons'])
            color = r['color']
            next if !color || comps.empty?
            # Sigma `single` colors the target column by its OWN value. If a rule
            # tests a DIFFERENT column, it needs a formula condition -> coverage.
            if comps.any? { |c| !c['driver'].to_s.empty? && leaf(c['driver']).casecmp(tl) != 0 }
              coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                            severity: 'degraded', recoverable: true,
                            detail: "cross-column rule on '#{cf['target']}' (driven by #{comps.map { |c| c['driver'] }.compact.uniq.join(', ')})",
                            action: 'Re-create as a conditionalFormat with a `formula` condition referencing the driving column.' }
              next
            end
            sf = single_from_comparisons(comps, cid, leaf(cf['target']), color, style_key)
            if sf
              formats << sf
            else
              coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                            severity: 'degraded', recoverable: true,
                            detail: "compound rule on '#{cf['target']}' (#{comps.size} conditions) not expressible as a single threshold",
                            action: 'Re-create as a conditionalFormat with a `formula` condition in the Sigma UI.' }
            end
          end
          # PBI "else" color has no single-rule form in Sigma.
          if cf['default']
            coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                          severity: 'approximated', recoverable: true,
                          detail: "default/else color on '#{cf['target']}' not carried (Sigma has no else-rule)",
                          action: 'Set the column background/default in the Sigma UI if the else color matters.' }
          end
        end
      end
    end
    { 'formats' => formats, 'coverage' => coverage }
  end

  # A column_formats color ('#hex' or {'theme'=>id,'percent'=>p}) -> uppercase '#RRGGBB'.
  def resolve_color(c, palette)
    case c
    when String then c =~ /\A#[0-9A-Fa-f]{6}\z/ ? c.upcase : nil
    when Hash then PbiTheme.theme_color(c['theme'], c['percent'], palette)
    end
  end

  # Static per-column fills (rec['column_formats'] from extract-pbir) -> Sigma
  # element-level `single` / formula True rules (fills every VALUE cell of the column;
  # `color` styles the font). Sigma cannot fill a per-column header or the grand-total
  # row, so entries that style only those come back as ONE coverage entry per element.
  # Returns { 'formats' => [...], 'coverage' => [record_unresolved kwargs...] }.
  def column_fill_formats(column_formats, qr_cids, name, kind, palette)
    formats = []
    coverage = []
    chrome_only = []
    chrome_too = [] # value cells are filled, but the header/total part of the same fill is lost
    merge_column_formats(column_formats, qr_cids).each do |cf|
      back = resolve_color(cf['back'], palette)
      font = resolve_color(cf['font'], palette)
      # A source back colour that did not resolve must never fall through to the '#FFFFFF' default
      # (white text on white); only a genuinely font-only fill (no back colour in the source) gets it.
      if (back.nil? && font.nil?) || (back.nil? && !cf['back'].nil?)
        unless cf['back'].nil? && cf['font'].nil?
          coverage << { visual: name, pbi_type: 'column-format', sigma_kind: kind,
                        severity: 'approximated', recoverable: false,
                        detail: "column fill on '#{cf['target']}' not reproduced — its source colour " \
                                "(#{[cf['back'], cf['font']].compact.map(&:inspect).join(', ')}) did not resolve to a hex value" +
                                (back.nil? && !cf['back'].nil? && !font.nil? ? " (unresolved back colour #{cf['back'].inspect}; rule not emitted)" : '') }
        end
        next
      end
      # A flat Sigma table has no subtotal rows, so a subtotal fill is chrome only on a matrix.
      chrome = cf['header'] || cf['total'] || (cf['subtotals'] && kind.to_s == 'pivot-table')
      desc = "#{leaf(cf['target'])} (#{[back, font && "font #{font}"].compact.join(', ')})"
      unless cf['values']
        chrome_only << desc if chrome
        next
      end
      if ambiguous_leaf?(cf['target'], qr_cids)
        coverage << { visual: name, pbi_type: 'column-format', sigma_kind: kind,
                      severity: 'approximated', recoverable: false,
                      detail: "column fill on '#{cf['target']}' not reproduced — the target is ambiguous " \
                              "(its name matches more than one bound column in the migrated #{kind})" }
        next
      end
      cid = resolve(cf['target'], qr_cids)
      unless cid
        coverage << { visual: name, pbi_type: 'column-format', sigma_kind: kind,
                      severity: 'degraded', recoverable: false,
                      detail: "column fill on '#{cf['target']}' — that column is not in the migrated #{kind}" }
        next
      end
      # Always explicit: a rule with no backgroundColor makes Sigma paint a default green cell fill
      # (platform verdict table-null-blank). A font-only fill uses white, the repo's table-bg convention.
      if font.nil? && !cf['font'].nil?
        coverage << { visual: name, pbi_type: 'column-format', sigma_kind: kind,
                      severity: 'approximated', recoverable: false,
                      detail: "column fill on '#{cf['target']}': font colour #{cf['font'].inspect} did not resolve " \
                              'to a hex value; background kept, font colour not carried' }
      end
      chrome_too << desc if chrome # only once a value-cell rule is really emitted
      style = { 'backgroundColor' => back || '#FFFFFF' }
      style['color'] = font if font
      formats << { 'type' => 'single', 'columnIds' => [cid], 'condition' => 'formula',
                   'formula' => 'True', 'style' => style }
    end
    unless chrome_only.empty?
      coverage << { visual: name, pbi_type: 'column-format', sigma_kind: kind,
                    severity: 'approximated', recoverable: false,
                    detail: "per-column header/total/subtotal fill not reproduced for #{chrome_only.join('; ')} — " \
                            'Sigma has no per-column header or grand-total fill (header style is element-wide) and cannot fill subtotal rows per column' }
    end
    unless chrome_too.empty?
      coverage << { visual: name, pbi_type: 'column-format', sigma_kind: kind,
                    severity: 'approximated', recoverable: false,
                    detail: "value cells filled, header/total/subtotal part of the fill not reproduced for #{chrome_too.join('; ')}" }
    end
    { 'formats' => formats, 'coverage' => coverage }
  end
end
