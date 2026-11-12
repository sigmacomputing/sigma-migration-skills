# frozen_string_literal: true

require 'json'

# lod_dim_helper.rb — a FIXED LOD used as a DIMENSION, built mechanically.
#
#   Cohort Year = {FIXED [Customer Id] : MIN(YEAR([Order Date]))}
#   sheet: rows Cohort Year × cols Loyalty Tier, COUNTD(Customer Id)
#
# WHY: every live proof stopped at the exit-4 handoff on this calc (the
# converter refuses cross-table FIXED grain, so no master carries "Cohort
# Year" and the workbook ref gate fails), and the agent hand-built a grouped
# helper. This pass emits the same shape the round-1 proof validated:
#   * a hidden grouped helper on the Data page, right AFTER its master
#     (forward-in-document-order), sourced from the master's own data-model
#     element — UNFILTERED, because Tableau computes a FIXED LOD before
#     dimension (quick) filters: wiring Region / Order Channel into the helper
#     would let those filters shift each customer's cohort;
#       groupBy  [<key>]   calculations  [<Cap> = <AGG>([<base>])]
#   * the tile's column rewritten to
#       Lookup([<Helper>/<Cap>], [<Master>/<key>], [<Helper>/<key>])
#     so the tile stays on its (control-filtered) master and the page's
#     controls keep full reach.
# Scope: ONE dimension, ONE aggregate (MIN/MAX/SUM/AVG/COUNT/COUNTD) over a
# bare field or a YEAR/QUARTER/MONTH/DAY of one. Anything else is left for
# the existing handoff (never guessed).
module LodDimHelper
  module_function

  FIXED_RE = /\A\s*\{\s*FIXED\s+\[([^\]]+)\]\s*:\s*(MIN|MAX|SUM|AVG|COUNTD|COUNT)\s*\(\s*(.+?)\s*\)\s*\}\s*\z/im.freeze
  INNER_RE = /\A(?:(YEAR|QUARTER|MONTH|DAY)\s*\(\s*\[([^\]]+)\]\s*\)|\[([^\]]+)\])\z/im.freeze
  AGG = { 'MIN' => 'Min', 'MAX' => 'Max', 'SUM' => 'Sum', 'AVG' => 'Avg', 'COUNT' => 'Count', 'COUNTD' => 'CountDistinct' }.freeze
  PART = { 'YEAR' => 'Year', 'QUARTER' => 'Quarter', 'MONTH' => 'Month', 'DAY' => 'Day' }.freeze

  # caption → { key:, agg:, part:, field: } for every qualifying FIXED calc.
  # calcs: [{ 'caption', 'formula' }]; columns_by_guid: { guid => { 'caption' } }.
  def plans(calcs, columns_by_guid = {})
    cbg = columns_by_guid || {}
    cap_of = ->(raw) { ((cbg[raw.to_s] || cbg["[#{raw}]"] || {})['caption'] || raw.to_s).strip }
    Array(calcs).each_with_object({}) do |c, out|
      next unless c.is_a?(Hash)
      cap = (c['caption'] || c['name']).to_s.gsub(/\A\[|\]\z/, '').strip
      m = c['formula'].to_s.match(FIXED_RE)
      next if cap.empty? || m.nil? || out.key?(cap)
      inner = m[3].strip.match(INNER_RE)
      next unless inner
      out[cap] = { key: cap_of.call(m[1]), agg: AGG[m[2].upcase], part: inner[1] && PART[inner[1].upcase],
                   field: cap_of.call(inner[2] || inner[3]) }
    end
  end

  # spec: legacy view ({ 'pages' => [{ 'elements' => [...] }] }). Mutates it.
  # Returns { built: [{ 'calc', 'helper', 'tiles' }], notes: [String] }.
  def apply!(spec, plans)
    out = { built: [], notes: [] }
    return out if plans.nil? || plans.empty?
    pages = Array(spec['pages'])
    all = pages.flat_map { |p| Array(p['elements']) }
    by_id = all.each_with_object({}) { |e, h| h[e['id']] = e }
    helpers = {}
    pages.each do |page|
      Array(page['elements']).each do |el|
        next unless el.is_a?(Hash) && el.dig('source', 'kind') == 'table'
        master = by_id[el.dig('source', 'elementId')]
        next unless master && master['name']
        mname = master['name']
        Array(el['columns']).each do |col|
          m = col['formula'].to_s.match(/\A\[#{Regexp.escape(mname)}\/([^\]]+)\]\z/)
          next unless m
          cap = m[1]
          plan = plans[cap]
          next unless plan
          next if Array(master['columns']).any? { |c| c['name'].to_s.casecmp?(cap) } # already materialized

          key_col = find_column(all, master, plan[:key])
          field_col = find_column(all, master, plan[:field])
          unless key_col && field_col
            out[:notes] << "FIXED LOD '#{cap}' used as a dimension on '#{el['name']}': key '#{plan[:key]}' or field " \
                           "'#{plan[:field]}' not found on a master over the same data-model element — left for the handoff"
            next
          end
          hk = [master['source'], cap]
          helper = helpers[hk] ||= existing_helper(all, master, cap) ||
                                   build_helper!(pages, master, cap, plan, key_col, field_col, out)
          ensure_key_on_master!(master, plan[:key], key_col)
          lookup = "Lookup([#{helper['name']}/#{cap}], [#{mname}/#{plan[:key]}], [#{helper['name']}/#{plan[:key]}])"
          # Every reference to the calc in this element — the dimension column
          # AND derived columns (the pivot null-dim exclusion's
          # Text(IsNotNull([Master/<Cap>])), a null-first sort key) — or the
          # derived ones dangle and fail the ref gate.
          ref = "[#{mname}/#{cap}]"
          Array(el['columns']).each do |other|
            other['formula'] = other['formula'].gsub(ref, lookup) if other['formula'].to_s.include?(ref)
          end
          rec = out[:built].find { |b| b['helper'] == helper['id'] }
          (rec['tiles'] << el['id']).uniq! if rec
        end
      end
    end
    out
  end

  # A column named `caption` on the master, or on any other element reading
  # the same data-model element (masters split per page carry different
  # columns); returns { 'name', 'formula' } or nil.
  def find_column(all, master, caption)
    want = caption.to_s.strip.downcase
    same = all.select { |e| e.is_a?(Hash) && e['source'] == master['source'] }
    [master, *same].each do |e|
      c = Array(e['columns']).find { |x| x['name'].to_s.strip.downcase == want && x['formula'].to_s =~ /\A\[[^\]]+\]\z/ }
      return c if c
    end
    prefix = dm_prefix(master)
    prefix ? { 'name' => caption, 'formula' => "[#{prefix}/#{caption}]" } : nil
  end

  def dm_prefix(el)
    Array(el['columns']).each do |c|
      m = c['formula'].to_s.match(/\A\[([^\/\]]+)\/[^\]]+\]\z/)
      return m[1] if m
    end
    nil
  end

  def slug(s)
    s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
  end

  def existing_helper(all, master, cap)
    source = slug(master.dig('source', 'elementId'))
    source = slug(master['id']) if source.empty?
    names = ["#{cap} Helper", "#{cap} Helper (#{source})"]
    all.find do |el|
      el.is_a?(Hash) && el['kind'] == 'table' && el['source'] == master['source'] &&
        names.include?(el['name'].to_s)
    end
  end

  def build_helper!(pages, master, cap, plan, key_col, field_col, out)
    s = slug(cap)
    source = slug(master.dig('source', 'elementId'))
    source = slug(master['id']) if source.empty?
    prefix = "lod-#{s}"
    prefix = "lod-#{source}-#{s}" if pages.any? { |page|
      Array(page['elements']).any? { |el| el['id'] == "#{prefix}-helper" }
    }
    helper_name = prefix == "lod-#{s}" ? "#{cap} Helper" : "#{cap} Helper (#{source})"
    base_name = "#{cap} Base"
    base_formula = plan[:part] ? "#{plan[:part]}(#{field_col['formula']})" : field_col['formula']
    helper = {
      'id' => "#{prefix}-helper", 'kind' => 'table', 'name' => helper_name,
      'source' => JSON.parse(JSON.generate(master['source'])),
      'columns' => [
        { 'id' => "#{prefix}-key", 'name' => plan[:key], 'formula' => key_col['formula'] },
        { 'id' => "#{prefix}-base", 'name' => base_name, 'formula' => base_formula, 'hidden' => true },
        { 'id' => "#{prefix}-value", 'name' => cap, 'formula' => "#{plan[:agg]}([#{base_name}])" }
      ],
      'groupings' => [{ 'id' => "#{prefix}-grain", 'groupBy' => ["#{prefix}-key"],
                        'calculations' => ["#{prefix}-value"] }]
    }
    page = pages.find { |p| Array(p['elements']).include?(master) }
    els = page['elements']
    els.insert(els.index(master) + 1, helper) # right after its master: forward-in-document-order
    out[:built] << { 'calc' => cap, 'helper' => helper['id'], 'tiles' => [] }
    helper
  end

  def ensure_key_on_master!(master, key_caption, key_col)
    return if Array(master['columns']).any? { |c| c['name'].to_s.casecmp?(key_caption) }
    source = slug(master.dig('source', 'elementId'))
    source = slug(master['id']) if source.empty?
    id = "lod-key-#{source}-#{slug(key_caption)}"
    (master['columns'] ||= []) << { 'id' => id, 'name' => key_caption, 'formula' => key_col['formula'] }
    master['order'] << id if master['order'].is_a?(Array)
  end
end
