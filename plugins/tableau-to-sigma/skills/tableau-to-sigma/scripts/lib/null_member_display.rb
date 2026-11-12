# frozen_string_literal: true
#
# null_member_display.rb — plan C1: null cells/members display as Tableau shows
# them, WITHOUT changing any value (display-only; the data stays null so sort,
# filter lists and grouping are unchanged). Verdict `table-null-blank`:
#
#   * numeric measure cells (table calculations, pivot values)
#       -> column format.displayNullAs "" (Tableau renders null measures blank)
#   * numeric group-key columns (table)
#       -> column format.displayNullAs "Null" (Tableau labels null members)
#   * text / date group-key columns (table)
#       -> ONE IsNull conditional format per element; plain column
#          displayNullAs is accepted but IGNORED on text, and the rule paints a
#          default green fill unless backgroundColor is explicit
#   * pivot row/column headers, chart elements: untouched (pivot headers render
#     blank by default; a custom label is a catalog residual)
#
# `kind:"datetime"` formats strip displayNullAs (verdict), so a column carrying
# one is never given a number format.
#
# merge_format! is the reusable helper for any later task that also writes
# column format objects (e.g. C11b): it merges into the existing object and
# never drops keys.
module NullMemberDisplay
  module_function

  NULL_LABEL     = 'Null'
  DEFAULT_BG     = '#FFFFFF'
  DEFAULT_COLOR  = '#333333'
  NUMERIC_TYPES  = %w[integer real number].freeze
  HEX_RE         = /\A#[0-9a-fA-F]{6}\z/.freeze

  # Merge `patch` into col['format'] (existing keys win unless overwrite:true).
  # Returns true when the column now carries every patched key, false when the
  # existing format is of an incompatible kind (left untouched).
  def merge_format!(col, patch, overwrite: false)
    fmt = col['format']
    return (col['format'] = patch.dup) && true if fmt.nil?
    return false unless fmt.is_a?(Hash)
    if patch['kind'] && fmt['kind'] && fmt['kind'] != patch['kind']
      return false
    end
    patch.each { |k, v| fmt[k] = v if overwrite || !fmt.key?(k) }
    true
  end

  # tree: the spec output (Hash with 'pages', or an Array of elements, or one
  # element). datatype_of: optional lambda(col) -> Tableau datatype string.
  # Returns the number of columns/rules touched.
  def apply!(node, datatype_of: nil)
    touched = 0
    case node
    when Hash
      if node['kind'] == 'table' || node['kind'] == 'pivot-table'
        touched += apply_element!(node, datatype_of) unless skip_element?(node)
      end
      node.each do |k, v|
        next if %w[data_elements master_decode_columns master_calc_columns].include?(k)
        touched += apply!(v, datatype_of: datatype_of) if v.is_a?(Hash) || v.is_a?(Array)
      end
    when Array
      node.each { |v| touched += apply!(v, datatype_of: datatype_of) }
    end
    touched
  end

  def skip_element?(el)
    el['hidden'] == true || el['visibleAsSource'] == false || !el['columns'].is_a?(Array)
  end

  def apply_element!(el, datatype_of)
    cols = el['columns'].select { |c| c.is_a?(Hash) }
    by_id = cols.each_with_object({}) { |c, h| h[c['id']] = c }
    measure_ids = []
    dim_ids = []
    if el['kind'] == 'pivot-table'
      measure_ids = Array(el['values'])
    else
      Array(el['groupings']).each do |g|
        dim_ids += Array(g['groupBy'])
        measure_ids += Array(g['calculations'])
      end
    end
    touched = 0
    text_ids = []
    measure_ids.uniq.each do |id|
      c = by_id[id]
      next if c.nil? || c['hidden']
      dt = datatype_of && datatype_of.call(c)
      next unless dt.nil? || dt.to_s.empty? || NUMERIC_TYPES.include?(dt.to_s)
      touched += 1 if merge_format!(c, { 'kind' => 'number', 'displayNullAs' => '' })
    end
    dim_ids.uniq.each do |id|
      c = by_id[id]
      next if c.nil? || c['hidden']
      dt = (datatype_of && datatype_of.call(c)).to_s
      if NUMERIC_TYPES.include?(dt)
        touched += 1 if merge_format!(c, { 'kind' => 'number', 'displayNullAs' => NULL_LABEL })
      else
        text_ids << id
      end
    end
    touched += 1 if add_null_rule!(el, text_ids)
    touched
  end

  # One IsNull rule per element covering the text/date group keys; appended to
  # any existing conditionalFormats, idempotent on re-run.
  def add_null_rule!(el, column_ids)
    return false if column_ids.empty?
    rules = el['conditionalFormats'] ||= []
    return false if rules.any? { |r| r.is_a?(Hash) && r['condition'] == 'IsNull' &&
                                     r.dig('style', 'format', 'displayNullAs') == NULL_LABEL }
    bg = el.dig('style', 'backgroundColor').to_s
    bg = DEFAULT_BG unless bg =~ HEX_RE
    rules << { 'type' => 'single', 'columnIds' => column_ids, 'condition' => 'IsNull',
               'style' => { 'backgroundColor' => bg, 'color' => DEFAULT_COLOR,
                            'format' => { 'kind' => 'number', 'displayNullAs' => NULL_LABEL } } }
    true
  end
end
