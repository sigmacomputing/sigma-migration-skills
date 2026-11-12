# frozen_string_literal: true

# Table-calc addressing ("compute using <dim>") names its field by the
# column's INTERNAL name. On a virtual-connection datasource that name is a
# GUID ([none:d73055c0-…:nk] → "d73055c0-…"), never the caption the Sigma
# columns carry, so every consumer that matches ordering_field against a pivot
# axis or chart dim by name silently fell back to "grand_total". Canonicalize
# once, at builder load: an ordering_field that is a key of the parser's
# columns_by_guid map becomes that column's caption (the raw value is kept as
# ordering_field_raw for audit). Plain-name addressing is left untouched.
module AddressingCanon
  module_function

  # Walks any parsed layout/meta structure in place. Returns the number of
  # ordering_field values rewritten.
  def canonicalize!(obj, columns_by_guid)
    cbg = columns_by_guid || {}
    return 0 if cbg.empty?

    count = 0
    walk = lambda do |node|
      case node
      when Hash
        raw = node['ordering_field']
        if raw.is_a?(String) && !raw.empty?
          cap = caption_for(raw, cbg)
          if cap && cap != raw
            node['ordering_field_raw'] ||= raw
            node['ordering_field'] = cap
            count += 1
          end
        end
        node.each_value { |v| walk.call(v) }
      when Array
        node.each { |v| walk.call(v) }
      end
    end
    walk.call(obj)
    count
  end

  def caption_for(raw, cbg)
    key = raw.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
    info = cbg[key] || cbg["[#{key}]"]
    cap = info.is_a?(Hash) ? info['caption'].to_s.strip : ''
    cap.empty? ? nil : cap
  end
end
