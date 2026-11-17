# frozen_string_literal: true
#
# PbiShapedModel -- helpers for the opt-in `--model-shape pbi` mode of migrate-powerbi.rb.
#
# The mode makes the Sigma data model read like the Power BI model it came from:
#   * no "<X> View" copies, and no converter time-intelligence or window-helper elements
#   * elements named after the Power BI TABLES (not the warehouse tables)
#   * physical columns named after the Power BI COLUMNS
#   * no row- or column-level security (the mode refuses a model that has any)
#
# All functions work on the converter's bare data-model hash (`dm_model`, the `{name, pages: [{elements}]}`
# shape written to dm-raw.json) and mutate it in place (the bang methods). Nothing here talks to Sigma.
#
# NAMING FACTS (probe P17, corpus/powerbi/pbi-shaped-model/probes/LOG.md). A warehouse column's display
# name is its `name`; its `formula` keeps pointing at the physical column (the converter's auto token), and
# the Power BI name used as that token is REJECTED. So renaming a physical column changes `name` only and
# leaves its own formula alone. Every OTHER reference (sibling `[Old]`, `[Element/Old]`, relationship
# paths `[Element/Rel/Old]`, metrics, calc columns) uses the new name. Relationship `keys` use column ids,
# so display names never touch them.
require 'set'
require_relative 'pbi_master_key'

module PbiShapedModel
  module_function

  # View/helper recognition ------------------------------------------------------------------

  WINDOW_HELPER_NAME = /\A(?:Dense Rank|Rank|Running|Group|Window) /.freeze

  # ---------------------------------------------------------------------------------------
  # Security
  # ---------------------------------------------------------------------------------------

  # Names of the roles that carry any table filter or column permission. A role with neither (it only
  # grants model access) is not security the mode would lose, so it is not listed.
  def security_roles(tmsl)
    model = (tmsl || {})['model'] || tmsl || {}
    Array(model['roles']).select { |role| secured_role?(role) }.map { |role| role['name'].to_s }
  end

  def secured_role?(role)
    Array(role['tablePermissions']).any? do |tp|
      # m2: a table hidden outright (table-level object-level security) is security the mode would lose
      !blank?(tp['filterExpression']) || !Array(tp['columnPermissions']).empty? || tp['metadataPermission'].to_s.casecmp('none').zero?
    end || !Array(role['columnPermissions']).empty?
  end

  def blank?(value)
    value = value.join("\n") if value.is_a?(Array)
    value.to_s.strip.empty?
  end

  # ---------------------------------------------------------------------------------------
  # Element helpers
  # ---------------------------------------------------------------------------------------

  def elements_of(dm_model)
    Array(dm_model['pages']).flat_map { |page| Array(page['elements']) }
  end

  def tables_of(tmsl)
    model = (tmsl || {})['model'] || tmsl || {}
    Array(model['tables'])
  end

  # element id => Power BI table name, only for elements the existing master-key matcher can attribute.
  # Compute this BEFORE changing element names: the matcher reads the element order and warehouse paths.
  def table_for_elements(dm_model, tmsl)
    elements = elements_of(dm_model)
    by_index = PbiMasterKey.pbi_table_for_elements(elements, tables_of(tmsl))
    out = {}
    elements.each_with_index do |el, idx|
      table = (by_index[idx] || {})['table']
      out[el['id']] = table if table && el['id']
    end
    out
  end

  # Elements the matcher could not attribute to a Power BI table (they keep the converter name).
  # Entries are {'id','name'}; name is nil for the converter's unnamed Custom SQL elements.
  def unattributed_elements(dm_model, table_for)
    elements_of(dm_model).reject { |el| table_for.key?(el['id']) }.map { |el| { 'id' => el['id'], 'name' => el['name'] } }
  end

  # A converter time-intelligence element: a grouped element built over a parent element.
  def time_intel_element?(el)
    el.dig('source', 'kind') == 'table' && el['groupings'].is_a?(Array) && !el['groupings'].empty?
  end

  # A converter window helper: Custom SQL carrying an OVER (...) clause, named "<Op> <Column>".
  def window_helper_element?(el)
    el.dig('source', 'kind') == 'sql' && el['name'].to_s.match?(WINDOW_HELPER_NAME) &&
      el.dig('source', 'statement').to_s.match?(/\bOVER\s*\(/i)
  end

  def view_element?(el)
    el['name'].to_s.end_with?(' View') && el.dig('source', 'kind') == 'table'
  end

  # drop_views!'s return value: an Array of the removed element names (so it still reads as
  # Array<String>) that also carries what the removal could not resolve cleanly.
  #   retargeted:             ["<element>: source/relationship moved from <View> to <base>", ...]
  #   dropped_relationships:  [{'element','relationship','target'}]  (target was a View with no base keys)
  #   unresolved:             [{'element','ref','reason'}]  refs to a View column that is not a bare ref
  #   dangling:               [{'element','kind','removed','ref'}]  still pointing at a removed helper
  class DropResult < Array
    attr_reader :retargeted, :dropped_relationships, :unresolved, :dangling

    def initialize
      super
      @retargeted = []
      @dropped_relationships = []
      @unresolved = []
      @dangling = []
    end
  end

  # Remove "<X> View" elements and the converter's time-intelligence / window helper elements.
  #   * `[<X> View/<col>]` becomes that View column's OWN formula path (`[X/Col]` or `[X/Rel/Col]`),
  #     since a View column can be a joined-dimension column; a View column that is a calc expression
  #     is recorded as unresolved and the ref is left as it was.
  #   * `source.elementId` and relationship targets that point at a View move to the View's base element
  #     when the keys still resolve there; otherwise the relationship is dropped and recorded.
  #   * anything still pointing at a removed helper is recorded as dangling (not silently left).
  def drop_views!(dm_model)
    result = DropResult.new
    all = elements_of(dm_model)
    views = all.select { |el| view_element?(el) }
    helpers = all.select { |el| !view_element?(el) && (time_intel_element?(el) || window_helper_element?(el)) }
    return result if views.empty? && helpers.empty?
    removed_ids = (views + helpers).map { |el| el['id'] }
    by_id = all.each_with_object({}) { |el, h| h[el['id']] = el }
    base_of = {}
    views.each do |v|
      base = by_id[v.dig('source', 'elementId')]
      base_of[v['id']] = base if base && !removed_ids.include?(base['id'])
    end
    view_by_name = views.each_with_object({}) { |v, h| h[v['name'].downcase] = v }
    helper_names = helpers.each_with_object({}) { |h, m| m[h['name'].to_s.downcase] = h }

    (dm_model['pages'] || []).each do |page|
      page['elements'] = Array(page['elements']).reject { |el| removed_ids.include?(el['id']) }
    end
    (views + helpers).each { |el| result << el['name'].to_s }

    elements_of(dm_model).each do |el|
      retarget_source!(el, by_id, base_of, removed_ids, helpers, result)
      retarget_relationships!(el, by_id, base_of, removed_ids, helpers, result)
      (Array(el['columns']) + Array(el['metrics'])).each do |holder|
        next unless holder['formula'].is_a?(String)
        holder['formula'] = map_refs(holder['formula']) do |segs|
          head = segs[0].to_s.downcase
          if segs.length >= 2 && view_by_name.key?(head)
            resolve_view_ref(segs, el, view_by_name[head], base_of, result)
          else
            result.dangling << { 'element' => el['name'], 'kind' => 'formula', 'removed' => helper_names[head]['name'], 'ref' => "[#{segs.join('/')}]" } if segs.length >= 2 && helper_names.key?(head)
            segs
          end
        end
      end
    end
    result
  end

  def view_column_display(col)
    display_name(col).to_s
  end

  # `[<View>/<col>(/...)]` -> the base element's path for that column.
  def resolve_view_ref(segs, el, view, base_of, result)
    return segs unless base_of.key?(view['id'])
    base_name = base_of[view['id']]['name'] || view['name'].sub(/ View\z/, '')
    return [base_name] + segs[1..-1] if segs.length > 2 # a relationship path read through the View: the base has the same paths
    leaf = segs[1]
    col = Array(view['columns']).find { |c| view_column_display(c).casecmp(leaf).zero? } ||
          Array(view['columns']).find { |c| view_column_display(c).sub(/\s+\([^)]*\)\s*\z/, '').casecmp(leaf).zero? }
    formula = col && col['formula'].to_s
    if formula && formula =~ /\A\[([^\[\]]+)\]\z/
      return Regexp.last_match(1).split('/', -1)
    end
    result.unresolved << { 'element' => el['name'], 'ref' => "[#{segs.join('/')}]",
                           'reason' => col ? "View column #{leaf.inspect} is a calculation, not a bare reference" : "no column #{leaf.inspect} on #{view['name']}" }
    segs
  end

  def retarget_source!(el, by_id, base_of, removed_ids, helpers, result)
    id = el.dig('source', 'elementId')
    return unless id && removed_ids.include?(id)
    if base_of.key?(id)
      base = base_of[id]
      el['source']['elementId'] = base['id']
      result.retargeted << "#{el['name']}: source moved from #{by_id[id]['name']} to #{base['name']}"
    else
      result.dangling << { 'element' => el['name'], 'kind' => 'source', 'removed' => by_id[id]['name'], 'ref' => id }
    end
  end

  def retarget_relationships!(el, by_id, base_of, removed_ids, helpers, result)
    return unless el['relationships'].is_a?(Array)
    el['relationships'] = el['relationships'].reject do |rel|
      tid = rel['targetElementId']
      next false unless tid && removed_ids.include?(tid)
      removed = by_id[tid]
      base = base_of[tid]
      mapped = base && Array(rel['keys']).map do |key|
        vcol = Array(removed['columns']).find { |c| c['id'] == key['targetColumnId'] }
        m = vcol && vcol['formula'].to_s.match(/\A\[[^\/\[\]]+\/([^\/\[\]]+)\]\z/)
        bcol = m && Array(base['columns']).find { |c| display_name(c).to_s.casecmp(m[1]).zero? }
        bcol && key.merge('targetColumnId' => bcol['id'])
      end
      if mapped && !mapped.empty? && mapped.all?
        rel['keys'] = mapped
        rel['targetElementId'] = base['id']
        result.retargeted << "#{el['name']}: relationship #{rel['name'].inspect} moved from #{removed['name']} to #{base['name']}"
        false
      else
        if base
          result.dropped_relationships << { 'element' => el['name'], 'relationship' => rel['name'], 'target' => removed['name'] }
        else
          result.dangling << { 'element' => el['name'], 'kind' => 'relationship', 'removed' => removed['name'], 'ref' => rel['name'] }
        end
        true
      end
    end
  end

  # Yield every column and metric hash (anything with a 'formula') in the model.
  def each_formula_holder(dm_model)
    elements_of(dm_model).each do |el|
      (Array(el['columns']) + Array(el['metrics'])).each { |holder| yield holder }
    end
  end

  # Replace the FIRST path segment of every `[a/b/c]` reference using [[old, new], ...] (exact match).
  def rewrite_prefixes(formula, rewrites)
    map = rewrites.to_h
    map_refs(formula) do |segs|
      segs.length >= 2 && map.key?(segs[0]) ? [map[segs[0]]] + segs[1..-1] : segs
    end
  end

  # ---------------------------------------------------------------------------------------
  # Names
  # ---------------------------------------------------------------------------------------

  # A Power BI name made safe as a Sigma element/column name that formulas can reference:
  # `[` and `]` cannot sit inside a `[ref]`, and leading/trailing spaces do not survive a round trip.
  # ("/" is already replaced upstream by pbi_name_sanitize.)
  def ref_safe(name)
    name.to_s.tr('[]', '()').strip
  end

  # Make `wanted` unique against `taken` (a Set of downcased names), appending " (2)", " (3)", ...
  def unique_name(wanted, taken)
    candidate = wanted
    n = 1
    while taken.include?(candidate.downcase)
      n += 1
      candidate = "#{wanted} (#{n})"
    end
    taken << candidate.downcase
    candidate
  end

  # Rename attributed elements to their Power BI table names. Returns {old name => new name} for the
  # elements whose name changed. Elements that are not attributed keep their name and reserve it.
  def rename_elements!(dm_model, table_for)
    elements = elements_of(dm_model)
    taken = Set.new
    elements.each { |el| taken << el['name'].to_s.downcase if el['name'] && !table_for.key?(el['id']) }
    renames = {}
    elements.each do |el|
      table = table_for[el['id']]
      next unless table
      new_name = unique_name(ref_safe(table), taken)
      new_name = el['name'].to_s if new_name.empty?
      old = el['name']
      next if old == new_name
      el['name'] = new_name
      renames[old] = new_name if old
    end
    renames
  end

  # ---------------------------------------------------------------------------------------
  # Columns
  # ---------------------------------------------------------------------------------------

  def physical_column?(col)
    col['id'].to_s.start_with?('inode-')
  end

  # The warehouse column name behind a physical column: the id's tail (`inode-<x>/ORDER_DATE_KEY`).
  def physical_name(col)
    col['id'].to_s.split('/', 2)[1]
  end

  # The display name a column has now: its `name`, else the leaf of its own formula.
  def display_name(col)
    return col['name'] if col['name'] && !col['name'].to_s.empty?
    col['formula'].to_s[/\A\[(?:[^\]]*\/)?([^\/\]]+)\]\z/, 1]
  end

  def pbi_column_for(table, col)
    phys = physical_name(col).to_s
    columns = Array(table['columns']).reject { |c| c['type'] == 'rowNumber' }
    exact = columns.find { |c| c['sourceColumn'].to_s.casecmp(phys).zero? }
    return exact if exact
    norm = PbiMasterKey.norm_col(phys)
    return nil if norm.empty?
    columns.find { |c| PbiMasterKey.norm_col(c['sourceColumn'] || c['name']) == norm }
  end

  # Rename physical columns to their Power BI column names (the `name` only; see the header).
  # Returns [{'element', 'element_id', 'from', 'to'}, ...] in element and column order. Two converter
  # columns that map to one Power BI name get `X` and `X (2)`; both appear in the result. Every column
  # whose name changes is listed (a column that already has its Power BI name is not).
  # Call rewrite_refs! afterwards to follow the new names in formulas.
  def rename_columns!(dm_model, tmsl, table_for)
    tables = tables_of(tmsl).each_with_object({}) { |t, h| h[t['name']] = t }
    renames = []
    elements_of(dm_model).each do |el|
      table = tables[table_for[el['id']]]
      next unless table
      cols = Array(el['columns'])
      wanted = {}
      cols.each do |col|
        next unless physical_column?(col)
        pbi = pbi_column_for(table, col)
        target = pbi && ref_safe(pbi['name'])
        wanted[col] = target unless target.nil? || target.empty?
      end
      next if wanted.empty?
      # names that stay put (calc columns, unmatched columns) are reserved first
      taken = Set.new
      cols.each { |col| taken << display_name(col).to_s.downcase unless wanted.key?(col) }
      Array(el['metrics']).each { |m| taken << m['name'].to_s.downcase if m['name'] }
      final = {}
      # a column already carrying its Power BI name keeps it before any other column claims it
      wanted.each { |col, target| final[col] = unique_name(target, taken) if display_name(col) == target }
      wanted.each { |col, target| final[col] = unique_name(target, taken) unless final.key?(col) }
      cols.each do |col|
        new_name = final[col]
        old = display_name(col)
        next if new_name.nil? || new_name == old
        col['name'] = new_name
        renames << { 'element' => el['name'], 'element_id' => el['id'], 'from' => old, 'to' => new_name }
      end
    end
    renames
  end

  # ---------------------------------------------------------------------------------------
  # References
  # ---------------------------------------------------------------------------------------

  # Rewrite every `[...]` reference in a formula string. The block receives the path segments
  # (the text between the brackets split on "/") and returns the new segments. String literals
  # ("...") are left alone.
  def map_refs(formula)
    out = +''
    i = 0
    n = formula.length
    while i < n
      ch = formula[i]
      if ch == '"'
        j = i + 1
        j += (formula[j] == '\\' ? 2 : 1) while j < n && formula[j] != '"'
        out << formula[i..j].to_s
        i = j + 1
      elsif ch == '['
        j = formula.index(']', i)
        if j.nil?
          out << formula[i..-1]
          break
        end
        segs = formula[(i + 1)...j].split('/', -1)
        out << '[' << yield(segs).join('/') << ']'
        i = j + 1
      else
        out << ch
        i += 1
      end
    end
    out
  end

  # Follow element and column renames in every formula. element_renames is {old name => new name};
  # column_renames is rename_columns!'s result. Physical columns' own formulas are left alone (they are
  # the binding to the warehouse column, see the header).
  def rewrite_refs!(dm_model, element_renames, column_renames)
    element_renames ||= {}
    elements = elements_of(dm_model)
    by_id = elements.each_with_object({}) { |el, h| h[el['id']] = el }
    new_to_old = element_renames.each_with_object({}) { |(old, new_name), h| h[new_name] = old }
    # formulas were written against the names the elements had BEFORE rename_elements!
    old_to_id = {}
    elements.each do |el|
      old = new_to_old[el['name']] || el['name']
      old_to_id[old.to_s.downcase] ||= el['id'] if old
    end
    renamed_heads = element_renames.each_with_object({}) { |(old, new_name), h| h[old.to_s.downcase] = new_name }
    renames_by_id = Hash.new { |h, k| h[k] = {} }
    Array(column_renames).each do |r|
      id = r['element_id'] || old_to_id[r['element'].to_s.downcase] ||
           elements.find { |el| el['name'] == r['element'] }&.dig('id')
      renames_by_id[id][r['from'].to_s.downcase] = r['to'] if id
    end
    return if renamed_heads.empty? && renames_by_id.empty?

    ctx = { by_id: by_id, old_to_id: old_to_id, heads: renamed_heads, cols: renames_by_id }
    elements.each do |el|
      own = own_tokens(el)
      rels = Array(el['relationships']).each_with_object({}) { |r, h| h[r['name'].to_s.downcase] = r }
      (Array(el['columns']) + Array(el['metrics'])).each do |holder|
        next unless holder['formula'].is_a?(String)
        next if physical_column?(holder)
        holder['formula'] = map_refs(holder['formula']) { |segs| rewrite_segments(segs, el, own, rels, ctx) }
      end
    end
  end

  # Prefixes a physical column of this element uses for its own source (e.g. the converter's `SALES`).
  def own_tokens(el)
    Array(el['columns']).select { |c| physical_column?(c) }.map do |c|
      c['formula'].to_s[/\A\[([^\/\]]+)\//, 1]&.downcase
    end.compact.uniq
  end

  # One `[a/b/.../leaf]` reference seen from element `el`. The head is a relationship name on `el`, an
  # element (by its old name), or the element's own source token; the middle segments are relationship
  # hops; the leaf is a column of the element the path ends on.
  def rewrite_segments(segs, el, own, rels, ctx)
    if segs.length == 1
      to = ctx[:cols][el['id']][segs[0].downcase]
      return to ? [to] : segs
    end
    return segs if segs[0] == 'Metrics'

    head = segs[0].downcase
    new_segs = segs.dup
    if rels.key?(head)
      current = el
      hops = segs[0...-1]
    elsif ctx[:old_to_id].key?(head)
      current = ctx[:by_id][ctx[:old_to_id][head]]
      new_segs[0] = ctx[:heads][head] if ctx[:heads].key?(head)
      hops = segs[1...-1]
    elsif own.include?(head)
      current = el
      hops = segs[1...-1]
    else
      return segs
    end
    hops.each do |hop|
      rel = Array(current['relationships']).find { |r| r['name'].to_s.casecmp(hop).zero? }
      current = rel && ctx[:by_id][rel['targetElementId']]
      break unless current
    end
    to = current && ctx[:cols][current['id']][segs[-1].downcase]
    new_segs[-1] = to if to
    new_segs
  end

  # ---------------------------------------------------------------------------------------
  # Unattributed elements
  # ---------------------------------------------------------------------------------------

  def calculated_tables(tmsl)
    tables_of(tmsl).select do |t|
      Array(t['partitions']).any? { |p| p.dig('source', 'type').to_s.casecmp('calculated').zero? }
    end
  end

  # Column names (normalized) an element exposes: its columns, plus the aliases of a Custom SQL
  # statement (`AS "Name"`), since the converter can emit a Custom SQL element that lists fewer
  # columns than the statement selects.
  def element_column_names(el)
    names = Array(el['columns']).map { |c| PbiMasterKey.norm_col(physical_column?(c) ? c['formula'] || physical_name(c) : display_name(c)) }
    stmt = el.dig('source', 'statement').to_s
    names += stmt.scan(/\bAS\s+"([^"]+)"/i).flatten.map { |a| PbiMasterKey.norm_col(a) }
    names.reject(&:empty?).uniq
  end

  # Name the elements PbiMasterKey could not attribute (e.g. the unnamed Custom SQL element a DATATABLE
  # calculated table becomes) after the Power BI calculated table whose column names they carry.
  # Match: the element's column-name set (case- and space-insensitive) equals the table's; failing that,
  # the element's set is contained in exactly one unclaimed calculated table's set (2+ columns, or half
  # the table's columns; exact matches are settled for all elements first). Anything else (no
  # candidate, or more than one) stays unmatched and keeps its name.
  # Mutates dm_model (element names) and table_for (so rename_columns! sees the element). Returns
  #   {'named' => [{'id','from','to'}], 'unmatched' => [{'id','name'}], 'renames' => {old name => new name}}
  # 'renames' holds only elements that HAD a name; merge it into rename_elements!'s map for rewrite_refs!.
  def name_unattributed!(dm_model, tmsl, table_for)
    candidates = calculated_tables(tmsl).reject { |t| table_for.values.include?(t['name']) }
    cols_of = candidates.each_with_object({}) do |t, h|
      h[t['name']] = Array(t['columns']).reject { |c| c['type'] == 'rowNumber' }.map { |c| PbiMasterKey.norm_col(c['name']) }.reject(&:empty?).uniq
    end
    taken = Set.new(elements_of(dm_model).map { |el| el['name'].to_s.downcase }.reject(&:empty?))
    out = { 'named' => [], 'unmatched' => [], 'renames' => {} }
    pending = unattributed_elements(dm_model, table_for).map do |info|
      el = elements_of(dm_model).find { |e| e['id'] == info['id'] }
      [info, el, el ? element_column_names(el) : []]
    end
    claimed = []
    claim = lambda do |info, el, table|
      claimed << table
      old = el['name']
      taken.delete(old.to_s.downcase) if old
      new_name = unique_name(ref_safe(table), taken)
      el['name'] = new_name
      table_for[el['id']] = table
      out['renames'][old] = new_name if old && old != new_name
      out['named'] << { 'id' => el['id'], 'from' => old, 'to' => new_name, 'table' => table }
      pending.delete_if { |i, _, _| i.equal?(info) }
    end
    # Pass 1: exact column-set matches for every element, so an exact match is never pre-empted by an
    # earlier element that only fits as a subset. Pass 2: subset matches. A subset needs at least 2
    # columns or at least half of the table's columns (a 1-column `Id` element must not claim a table),
    # and only counts when exactly one unclaimed table fits.
    [:exact, :subset].each do |mode|
      pending.dup.each do |info, el, have|
        next if have.empty?
        tables = cols_of.select do |name, cols|
          next false if claimed.include?(name)
          if mode == :exact
            have.sort == cols.sort
          else
            (have - cols).empty? && (have.length >= 2 || have.length * 2 >= cols.length)
          end
        end.keys
        claim.call(info, el, tables[0]) if tables.length == 1
      end
    end
    # Pass 3 (elimination): one element and one calculated table left, and the element's columns fit inside
    # it. This is how a DATATABLE element that lost columns in conversion (1 of 4) is still named.
    left = cols_of.keys - claimed
    if pending.length == 1 && left.length == 1
      info, el, have = pending[0]
      claim.call(info, el, left[0]) if !have.empty? && (have - cols_of[left[0]]).empty?
    end
    pending.each { |info, _, _| out['unmatched'] << info }
    out
  end

  # ---------------------------------------------------------------------------------------
  # Relationships
  # ---------------------------------------------------------------------------------------

  # The Sigma relationship name for a TMSL relationship hash: the target Power BI table for an active
  # relationship, `<toTable> (<fromColumn>)` for an inactive one that a USERELATIONSHIP measure activates.
  def relationship_name(rel)
    to = ref_safe(rel['toTable'].to_s.tr('/', ' '))
    return to unless rel['isActive'] == false
    "#{to} (#{ref_safe(rel['fromColumn'].to_s.tr('/', ' '))})"
  end

  # `[a/b/c]` seen from element `el` -> {hops: [[segment index, owner element, relationship], ...],
  # end: the element the path ends on (nil when a hop did not resolve), leaf: last segment}. nil when the
  # head is neither a relationship of `el`, an element name nor the element's own source token.
  def resolve_path(segs, el, by_name, by_id)
    return nil if segs.length < 2 || segs[0] == 'Metrics'
    head = segs[0].downcase
    find_rel = ->(owner, name) { Array(owner['relationships']).find { |r| r['name'].to_s.casecmp(name).zero? } }
    if find_rel.call(el, segs[0])
      current = el
      start = 0
    elsif by_name.key?(head)
      current = by_name[head]
      start = 1
    elsif own_tokens(el).include?(head)
      current = el
      start = 1
    else
      return nil
    end
    hops = []
    (start...(segs.length - 1)).each do |i|
      rel = find_rel.call(current, segs[i])
      return { hops: hops, end: nil, leaf: segs[-1] } unless rel
      hops << [i, current, rel]
      current = by_id[rel['targetElementId']]
      return { hops: hops, end: nil, leaf: segs[-1] } unless current
    end
    { hops: hops, end: current, leaf: segs[-1] }
  end

  def path_context(dm_model)
    elements = elements_of(dm_model)
    by_name = {}
    elements.each { |e| by_name[e['name'].to_s.downcase] ||= e if e['name'] }
    [by_name, elements.each_with_object({}) { |e, h| h[e['id']] = e }]
  end

  def formula_holders(el)
    (Array(el['columns']) + Array(el['metrics'])).select { |h| h['formula'].is_a?(String) }
  end

  # Every formula reference in the model as [element, holder, segments, resolved path].
  def each_reference(dm_model)
    by_name, by_id = path_context(dm_model)
    elements_of(dm_model).each do |el|
      formula_holders(el).each do |holder|
        map_refs(holder['formula']) do |segs|
          yield el, holder, segs, resolve_path(segs, el, by_name, by_id)
          segs
        end
      end
    end
  end

  def physical_key(source_col_id)
    source_col_id.to_s.split('/', 2)[1].to_s
  end

  def tmsl_rel_matches?(rel, tr)
    from = PbiMasterKey.norm_col(tr['fromColumn'])
    to = PbiMasterKey.norm_col(tr['toColumn'])
    Array(rel['keys']).any? do |k|
      PbiMasterKey.norm_col(physical_key(k['sourceColumnId'])) == from && PbiMasterKey.norm_col(physical_key(k['targetColumnId'])) == to
    end
  end

  # Name the relationships after Power BI's. Returns
  #   {'renamed' => [{'element','from','to'}], 'added' => [], 'not_carried' => [{'relationship','from','to','fromColumn','reason'}],
  #    'conflicts' => [...], 'carried' => [{'relationship' (Power BI name), 'element', 'id', 'name' (Sigma)}]}
  # Formula paths that used a renamed relationship follow it (`[Sales/DATE_VIA_SHIPDATEKEY/Month]` ->
  # `[Sales/Date (ShipDateKey)/Month]`). 'added' stays empty: the mode carries only relationships the
  # converter already built (the role-playing-copy fallback was not needed, probe P6).
  def relationships!(dm_model, tmsl, table_for)
    elements = elements_of(dm_model)
    by_id = elements.each_with_object({}) { |e, h| h[e['id']] = e }
    result = { 'renamed' => [], 'added' => [], 'not_carried' => [], 'conflicts' => [], 'carried' => [] }
    claimed_by = {}.compare_by_identity
    planned = Hash.new { |h, k| h[k] = {} }
    owner_of = {}.compare_by_identity
    model = (tmsl || {})['model'] || tmsl || {}
    Array(model['relationships']).each do |tr|
      active = tr['isActive'] != false
      hits = []
      elements.each do |el|
        next unless table_for[el['id']] == tr['fromTable']
        Array(el['relationships']).each do |rel|
          tgt = by_id[rel['targetElementId']]
          next unless tgt && table_for[tgt['id']] == tr['toTable'] && tmsl_rel_matches?(rel, tr)
          hits << [el, rel]
        end
      end
      if hits.empty?
        unless active
          result['not_carried'] << { 'relationship' => tr['name'], 'from' => tr['fromTable'], 'to' => tr['toTable'],
                                     'fromColumn' => tr['fromColumn'], 'reason' => 'inactive and unused' }
        end
        next
      end
      hits.each do |el, rel|
        if planned[el['id']].key?(rel) # two TMSL relationships claim one Sigma relationship: keep the first, record it
          result['conflicts'] << { 'element' => el['name'], 'relationship' => rel['name'], 'claimed_by' => [claimed_by[rel], tr['name']] }
          next
        end
        planned[el['id']][rel] = relationship_name(tr)
        claimed_by[rel] = tr['name']
        owner_of[rel] = el
      end
    end

    new_names = {}.compare_by_identity
    planned.each do |el_id, rels|
      taken = Set.new(Array(by_id[el_id]['relationships']).reject { |r| rels.key?(r) }.map { |r| r['name'].to_s.downcase })
      rels.each { |rel, wanted| new_names[rel] = unique_name(wanted, taken) }
    end
    # which Power BI relationship each Sigma relationship carries: the report maps by this, never by a name
    # (a uniquified " (2)" name or a numeric fromColumn makes names ambiguous)
    new_names.each do |rel, name|
      result['carried'] << { 'relationship' => claimed_by[rel], 'element' => owner_of[rel]['name'], 'id' => rel['id'], 'name' => name }
    end
    changed = new_names.select { |rel, name| rel['name'] != name }
    return result if changed.empty?

    by_name, = path_context(dm_model)
    elements.each do |el|
      formula_holders(el).each do |holder|
        holder['formula'] = map_refs(holder['formula']) do |segs|
          path = resolve_path(segs, el, by_name, by_id)
          next segs unless path
          out = segs.dup
          path[:hops].each { |i, _owner, rel| out[i] = changed[rel] if changed.key?(rel) }
          out
        end
      end
    end
    changed.each do |rel, name|
      result['renamed'] << { 'element' => owner_of[rel]['name'], 'from' => rel['name'], 'to' => name }
      rel['name'] = name
    end
    result
  end

  # ---------------------------------------------------------------------------------------
  # Key uniqueness
  # ---------------------------------------------------------------------------------------

  def quote_ident(name, dialect)
    case dialect.to_s.downcase
    when 'databricks', 'bigquery' then "`#{name.to_s.gsub('`', '``')}`"
    else "\"#{name.to_s.gsub('"', '""')}\""
    end
  end

  # [relationship key, many-side element, relationship, target element] for every relationship, in
  # element order. The key is "<many-side element>-><relationship name>" (an active relationship is named
  # after its target, so it reads "<from>-><to>"; an activated inactive one stays distinct).
  def relationship_entries(dm_model)
    by_id = elements_of(dm_model).each_with_object({}) { |e, h| h[e['id']] = e }
    out = []
    elements_of(dm_model).each do |el|
      Array(el['relationships']).each do |rel|
        tgt = by_id[rel['targetElementId']]
        out << ["#{el['name']}->#{rel['name']}", el, rel, tgt] if tgt
      end
    end
    out
  end

  # The warehouse name of a target key column: the physical column behind it (the id tail) for a
  # warehouse table; for Custom SQL the alias the statement exposes (the leaf of the column's own formula).
  def key_column_token(target, col)
    return nil unless col && physical_column?(col)
    if target.dig('source', 'kind') == 'sql'
      col['formula'].to_s[/\A\[(?:[^\]]*\/)?([^\/\]]+)\]\z/, 1] || physical_name(col)
    else
      physical_name(col)
    end
  end

  def key_check_source(target, dialect)
    src = target['source'] || {}
    case src['kind']
    when 'warehouse-table' then Array(src['path']).map { |part| quote_ident(part, dialect) }.join('.')
    when 'sql'
      # The alias is required (Spark/Databricks reject an unaliased subquery); the spec's "(<statement>)"
      # was shorthand. A trailing ";" would break the wrapping, so it is stripped.
      "(\n#{src['statement'].to_s.strip.sub(/;+\s*\z/, '').rstrip}\n) AS t"
    end
  end

  # One uniqueness probe per relationship: `SELECT COUNT(*) - COUNT(DISTINCT key) AS dup FROM <target>`
  # (0 means the target key is unique). Returns {"<from>-><relationship>" => sql}. A relationship whose
  # target is not a warehouse table or Custom SQL, or whose key is not a physical column, has no probe.
  def key_check_queries(dm_model, dialect: 'snowflake')
    out = {}
    relationship_entries(dm_model).each do |key, _el, rel, target|
      from = key_check_source(target, dialect)
      cols = Array(rel['keys']).map do |k|
        key_column_token(target, Array(target['columns']).find { |c| c['id'] == k['targetColumnId'] })
      end
      next if from.nil? || cols.empty? || cols.any?(&:nil?)
      quoted = cols.map { |c| quote_ident(c, dialect) }
      out[key] = if quoted.length == 1
                   # COUNT(k) skips NULLs, so a NULL target key is not mistaken for a duplicate
                   "SELECT COUNT(#{quoted[0]}) - COUNT(DISTINCT #{quoted[0]}) AS dup FROM #{from}"
                 else
                   # composite key: duplicated non-NULL tuples (COUNT(DISTINCT a, b) is invalid on BigQuery)
                   "SELECT COUNT(*) AS dup FROM (SELECT #{quoted.join(', ')} FROM #{from} WHERE #{quoted.map { |q| "#{q} IS NOT NULL" }.join(' AND ')} " \
                   "GROUP BY #{quoted.join(', ')} HAVING COUNT(*) > 1) d"
                 end
    end
    out
  end

  # apply_key_results!'s return value: an Array of per-relationship entries that also carries the formulas
  # a dropped relationship leaves without a path.
  #   dangling: [{'element','column','ref','relationship'}]
  class KeyResult < Array
    attr_reader :dangling

    def initialize
      super
      @dangling = []
    end
  end

  def append_description(el, text)
    el['description'] = [el['description'], text].reject { |t| t.to_s.empty? }.join(' ')
  end

  # Every use of `target` other than as the key of the relationships in `group`: sources built on it, other
  # relationships to it, metrics on it, and formula refs that read a column other than the key.
  def key_only_use?(dm_model, target, group, key_names)
    return false if elements_of(dm_model).any? { |e| e.dig('source', 'elementId') == target['id'] }
    return false unless Array(target['metrics']).empty?
    all_rels = relationship_entries(dm_model).select { |_, _, _, t| t['id'] == target['id'] }.map { |_, _, r, _| r }
    return false unless all_rels.all? { |r| group.any? { |g| g.equal?(r) } }
    ok = true
    each_reference(dm_model) do |el, _holder, _segs, path|
      next if el.equal?(target)
      next unless path && path[:end] && path[:end]['id'] == target['id']
      ok = false unless key_names.any? { |n| n.casecmp(path[:leaf]).zero? }
    end
    ok
  end

  def rekey_child!(dm_model, target, keys, dup)
    key_cols = keys.map { |k| Array(target['columns']).find { |c| c['id'] == k['targetColumnId'] } }
    key_names = key_cols.map { |c| display_name(c).to_s }
    page = Array(dm_model['pages']).find { |pg| Array(pg['elements']).any? { |e| e['id'] == target['id'] } }
    taken = Set.new(elements_of(dm_model).map { |e| e['name'].to_s.downcase })
    name = unique_name("#{target['name']} (distinct #{key_names.join(', ')})", taken)
    cols = key_cols.each_with_index.map do |c, i|
      { 'id' => "#{target['id']}dk#{i}", 'name' => key_names[i], 'formula' => "[#{target['name']}/#{key_names[i]}]" }
    end
    child = { 'id' => "#{target['id']}dk", 'kind' => 'table', 'name' => name,
              'description' => "One row per #{key_names.join(', ')} of #{target['name']}. The warehouse key is duplicated in the source table (#{dup} extra rows), so relationships join to this distinct copy.",
              'source' => { 'kind' => 'table', 'elementId' => target['id'] },
              'columns' => cols, 'order' => cols.map { |c| c['id'] },
              'groupings' => [{ 'id' => "#{target['id']}dkg", 'groupBy' => cols.map { |c| c['id'] } }] }
    idx = page['elements'].index { |e| e['id'] == target['id'] }
    page['elements'].insert(idx + 1, child)
    child
  end

  # Act on the key-check results ({"<from>-><relationship>" => dup count, or {'dup' => n}}).
  #   dup 0 (or absent)  -> kept
  #   dup > 0            -> dropped and recorded (default, R33). With `rekey: true`: rekeyed when the target is a warehouse table whose relationship keys are its only
  #                         use: a child "<Target> (distinct <key>)" grouped on the key takes over every
  #                         relationship to that target; otherwise the relationship is dropped.
  # Both are recorded in the target's description. A dropped relationship's formula paths are recorded in
  # the result's `dangling`. Returns KeyResult: [{'relationship','action','dup'}] (rekeyed adds 'child').
  def apply_key_results!(dm_model, results, rekey: false)
    out = KeyResult.new
    results ||= {}
    relationship_entries(dm_model).each do |key, el, rel, target|
      next unless results.key?(key)
      raw = results[key]
      dup = (raw.is_a?(Hash) ? raw['dup'] : raw).to_i
      entry = { 'relationship' => key, 'action' => 'kept', 'dup' => dup }
      out << entry
      next if dup <= 0
      if rel['targetElementId'] != target['id'] # a sibling relationship's re-key already moved this one
        entry['action'] = 'rekeyed'
        entry['child'] = by_id_name(dm_model, rel['targetElementId'])
        next
      end
      keys = Array(rel['keys'])
      key_cols = keys.map { |k| Array(target['columns']).find { |c| c['id'] == k['targetColumnId'] } }
      key_names = key_cols.compact.map { |c| display_name(c).to_s }
      sig = keys.map { |k| k['targetColumnId'] }
      group = relationship_entries(dm_model).select { |_, _, r, t| t['id'] == target['id'] && Array(r['keys']).map { |k| k['targetColumnId'] } == sig }.map { |_, _, r, _| r }
      if rekey && target.dig('source', 'kind') == 'warehouse-table' && key_cols.none?(&:nil?) &&
         key_only_use?(dm_model, target, group, key_names)
        child = dm_model_child_for(dm_model, target, sig) || rekey_child!(dm_model, target, keys, dup)
        group.each do |r|
          r['targetElementId'] = child['id']
          r['keys'] = Array(r['keys']).each_with_index.map { |k, i| k.merge('targetColumnId' => child['columns'][i]['id']) }
        end
        append_description(target, "Key #{key_names.join(', ')} is duplicated (#{dup} extra rows); relationships join to #{child['name']}.")
        entry['action'] = 'rekeyed'
        entry['child'] = child['name']
        next
      end
      each_reference(dm_model) do |rel_el, holder, segs, path|
        next unless path && path[:hops].any? { |_, _, r| r.equal?(rel) }
        out.dangling << { 'element' => rel_el['name'], 'column' => holder['name'] || holder['id'], 'ref' => "[#{segs.join('/')}]", 'relationship' => key }
      end
      el['relationships'] = el['relationships'].reject { |r| r.equal?(rel) }
      append_description(target, "Relationship #{rel['name']} from #{el['name']} was not carried: key #{key_names.join(', ')} is duplicated (#{dup} extra rows).")
      entry['action'] = 'dropped'
    end
    out
  end

  def by_id_name(dm_model, id)
    elements_of(dm_model).find { |e| e['id'] == id }&.dig('name')
  end

  def dm_model_child_for(dm_model, target, _sig)
    elements_of(dm_model).find { |e| e['id'] == "#{target['id']}dk" }
  end

  # ---------------------------------------------------------------------------------------
  # Fact split, Lookup chains, report filters
  # ---------------------------------------------------------------------------------------
  # A metric that reads a related column only works through `Lookup()` calc columns on a CHILD element
  # (probe P4); a relationship-path calc column errors at query time. So a fact that carries a class B
  # metric with related inputs becomes `<Fact> (source)` (columns + relationships, no metrics) plus a child
  # named after the Power BI table: the base's columns re-exposed as `[<Fact> (source)/<Col>]`, the Lookup
  # chain columns, the metrics (moved, not copied), and its own copy of the relationships (P5).
  # Lookup argument order is (value from the other element, local key, the other element's key).

  SOURCE_SUFFIX = ' (source)'

  def norm_name(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def by_id_map(dm_model)
    elements_of(dm_model).each_with_object({}) { |e, h| h[e['id']] = e }
  end

  def column_by_id(el, id)
    Array(el['columns']).find { |c| c['id'] == id }
  end

  def column_named(el, name)
    Array(el['columns']).find { |c| display_name(c).to_s.casecmp(name.to_s).zero? } ||
      Array(el['columns']).find { |c| norm_name(display_name(c)) == norm_name(name) }
  end

  # A relationship of `owner` by its name, else the one whose target element carries that name.
  def find_relationship(owner, name, by_id)
    rels = Array(owner['relationships'])
    rels.find { |r| r['name'].to_s.casecmp(name.to_s).zero? } ||
      rels.find { |r| by_id[r['targetElementId']] && by_id[r['targetElementId']]['name'].to_s.casecmp(name.to_s).zero? }
  end

  def taken_names(el)
    Set.new((Array(el['columns']).map { |c| display_name(c).to_s } + Array(el['metrics']).map { |m| m['name'].to_s }).map(&:downcase))
  end

  def next_id(dm_model, prefix)
    used = Set.new
    elements_of(dm_model).each do |e|
      used << e['id']
      (Array(e['columns']) + Array(e['metrics']) + Array(e['relationships']) + Array(e['filters'])).each { |h| used << h['id'] }
    end
    n = 0
    n += 1 while used.include?("#{prefix}#{n}")
    "#{prefix}#{n}"
  end

  # [[child, base], ...] for every split fact (the child's source is the element named "<child> (source)").
  def split_pairs(dm_model)
    by_id = by_id_map(dm_model)
    elements_of(dm_model).map do |el|
      base = el.dig('source', 'kind') == 'table' ? by_id[el.dig('source', 'elementId')] : nil
      base && base['name'].to_s == "#{el['name']}#{SOURCE_SUFFIX}" ? [el, base] : nil
    end.compact
  end

  # Add (or reuse) the Lookup chain that brings `column` of the element at the end of `path` (relationship
  # names, in order) onto `el`. Returns [display name of the column on el, nil], or [nil, reason].
  #   hop i:  <value> (<Table>) = Lookup([<Table>/<value>], [<local key>], [<Table>/<Table key>])
  # <value> is the next relationship's key column on <Table> for a middle hop, the wanted column for the
  # last one. A hop whose Lookup formula is already on `el` is reused, so chains that share a prefix share
  # its columns (also across calls).
  def lookup_chain!(dm_model, el, path, column)
    by_id = by_id_map(dm_model)
    return [nil, 'empty relationship path'] if path.empty?
    taken = taken_names(el)
    current = el
    local = nil
    result = nil
    path.each_with_index do |rname, i|
      rel = find_relationship(current, rname, by_id)
      return [nil, "relationship #{rname} not found on #{current['name']}"] unless rel
      return [nil, "relationship #{rname} has a composite key"] unless Array(rel['keys']).length == 1
      tgt = by_id[rel['targetElementId']]
      return [nil, "relationship #{rname} has no target element"] unless tgt
      key = rel['keys'][0]
      if i.zero?
        src_col = column_by_id(current, key['sourceColumnId'])
        return [nil, "key column of #{rname} is missing on #{current['name']}"] unless src_col
        local = display_name(src_col)
      end
      tgt_key = column_by_id(tgt, key['targetColumnId'])
      return [nil, "target key of #{rname} is missing on #{tgt['name']}"] unless tgt_key
      if i == path.length - 1
        value_col = column_named(tgt, column)
        return [nil, "column #{column} not found on #{tgt['name']}"] unless value_col
      else
        nxt = find_relationship(tgt, path[i + 1], by_id)
        return [nil, "relationship #{path[i + 1]} not found on #{tgt['name']}"] unless nxt && Array(nxt['keys']).length == 1
        value_col = column_by_id(tgt, nxt['keys'][0]['sourceColumnId'])
        return [nil, "key column of #{path[i + 1]} is missing on #{tgt['name']}"] unless value_col
      end
      value = display_name(value_col)
      formula = "Lookup([#{tgt['name']}/#{value}], [#{local}], [#{tgt['name']}/#{display_name(tgt_key)}])"
      existing = Array(el['columns']).find { |c| c['formula'] == formula }
      if existing
        name = display_name(existing)
      else
        name = unique_name("#{ref_safe(value)} (#{tgt['name']})", taken)
        col = { 'id' => next_id(dm_model, "#{el['id']}l"), 'name' => name, 'formula' => formula }
        el['columns'] = Array(el['columns']) + [col]
        el['order'] = Array(el['order']) + [col['id']] if el['order']
      end
      local = name
      result = name
      current = tgt
    end
    [result, nil]
  end

  def class_b_with_related(classes)
    out = {}
    (classes || {}).each do |key, c|
      next unless c['class'] == 'B' && !Array(c['related']).empty?
      table, measure = key.split('.', 2)
      (out[c['home'] || table] ||= []) << [measure, c]
    end
    out
  end

  # Split every fact that has a class B metric reading a related column. Returns
  #   [{'fact','base','child','lookups' => [{'name','formula'}], 'unresolved' => [{'metric','reason'}]}]
  # A USERELATIONSHIP-only metric (no related inputs) needs no chain and does not by itself split a fact.
  # The result also carries `reclassified` ([{'key','reason'}]): a B metric whose related reads did not all
  # resolve is removed from the child and set to class D in `classes` (a relationship-path formula errors at
  # query time, P4). A fact with no resolvable Lookup is not split at all.
  class SplitResult < Array
    attr_reader :reclassified

    def initialize
      super
      @reclassified = []
    end
  end

  def split_facts!(dm_model, classes)
    out = SplitResult.new
    class_b_with_related(classes).each do |home, entries|
      by_name, by_id = path_context(dm_model)
      base = by_name[home.to_s.downcase]
      next unless base && base['name'] == home && !Array(base['metrics']).empty?
      next if split_pairs(dm_model).any? { |c, b| b.equal?(base) || c.equal?(base) }
      fact_name = base['name']
      page = Array(dm_model['pages']).find { |pg| Array(pg['elements']).any? { |e| e.equal?(base) } }
      next unless page

      # 1. Lookup chains go on the child; build the child shell first so chains resolve against it.
      child_id = next_id(dm_model, "#{base['id']}s")
      colmap = {}
      ccols = Array(base['columns']).each_with_index.map do |c, i|
        cid = "#{child_id}c#{i}"
        colmap[c['id']] = cid
        h = { 'id' => cid, 'name' => display_name(c), 'formula' => "[#{fact_name}#{SOURCE_SUFFIX}/#{display_name(c)}]" }
        %w[hidden format description].each { |k| h[k] = c[k] if c.key?(k) }
        h
      end
      child = { 'id' => child_id, 'kind' => 'table', 'name' => fact_name,
                'source' => { 'kind' => 'table', 'elementId' => base['id'] },
                'columns' => ccols, 'order' => ccols.map { |c| c['id'] } }
      crels = Array(base['relationships']).each_with_index.map do |r, i|
        { 'id' => "#{child_id}r#{i}", 'name' => r['name'], 'targetElementId' => r['targetElementId'],
          'keys' => Array(r['keys']).map { |k| k.merge('sourceColumnId' => colmap.fetch(k['sourceColumnId'], k['sourceColumnId'])) } }
      end
      child['relationships'] = crels unless crels.empty?
      page['elements'].insert(page['elements'].index { |e| e.equal?(base) } + 1, child)

      unresolved = []
      subs = Hash.new { |h, k| h[k] = [] }
      failed = {}
      entries.each do |measure, c|
        next unless Array(base['metrics']).any? { |m| m['name'] == measure }
        Array(c['related']).each do |rel|
          name, reason = lookup_chain!(dm_model, child, Array(rel['path']), rel['column'])
          if name
            subs[measure] << [Array(rel['path']), rel['table'], rel['column'], name]
          else
            unresolved << { 'metric' => measure, 'reason' => reason }
            failed[measure] ||= [c, reason]
          end
        end
      end
      reclass = failed.map do |measure, (c, reason)|
        text = "related read did not resolve: #{reason}"
        c['class'] = 'D'
        c['reason'] = text
        { 'key' => "#{c['home'] || fact_name}.#{measure}", 'reason' => text }
      end
      out.reclassified.concat(reclass)
      failed.each_key { |m| subs.delete(m) }
      if subs.empty?
        page['elements'].delete_if { |e| e.equal?(child) }
        base['metrics'] = Array(base['metrics']).reject { |m| failed.key?(m['name']) }
        next
      end

      # 2. Rewrite each B metric's relationship-path reads to its Lookup column (resolved on the base).
      Array(base['metrics']).each do |m|
        next unless subs.key?(m['name']) && m['formula'].is_a?(String)
        m['formula'] = map_refs(m['formula']) do |segs|
          path = resolve_path(segs, base, by_name, by_id)
          hit = path && path[:end] && !path[:hops].empty? && subs[m['name']].find do |rpath, table, column, _name|
            path[:hops].map { |_i, _o, r| r['name'].to_s.downcase } == rpath.map(&:downcase) &&
              path[:end]['name'].to_s.casecmp(table.to_s).zero? && norm_name(path[:leaf]) == norm_name(column)
          end
          hit ? [hit[3]] : segs
        end
      end

      # 3. Move the metrics, rename the base, insert the child, point later readers of the base at it.
      child['metrics'] = base.delete('metrics').reject { |m| failed.key?(m['name']) }
      old_name = base['name']
      base['name'] = "#{old_name}#{SOURCE_SUFFIX}"
      elements_of(dm_model).each do |el|
        next if el.equal?(base) || el.equal?(child)
        next unless el.dig('source', 'elementId') == base['id']
        formula_holders(el).each { |h| h['formula'] = rewrite_prefixes(h['formula'], [[old_name, base['name']]]) }
      end
      lookups = Array(child['columns']).select { |c| c['id'].to_s.start_with?("#{child_id}l") }
                                       .map { |c| { 'name' => c['name'], 'formula' => c['formula'] } }
      out << { 'fact' => fact_name, 'base' => base['name'], 'child' => child['name'], 'lookups' => lookups,
               'unresolved' => unresolved, 'reclassified' => reclass }
    end
    out
  end

  # Relationship names from `el` to the element named `table`: the path a class B metric of this table
  # used when it names one that resolves from `el`, else the shortest (a relationship named after its
  # target is preferred, which is how an active relationship reads). nil when unreachable.
  def path_to_table(dm_model, el, table, preferred = [])
    by_id = by_id_map(dm_model)
    preferred.each do |p|
      cur = el
      ok = p.all? do |rn|
        rel = cur && find_relationship(cur, rn, by_id)
        cur = rel && by_id[rel['targetElementId']]
        !cur.nil?
      end
      return p if ok && cur['name'].to_s.casecmp(table.to_s).zero?
    end
    queue = [[el, []]]
    seen = Set.new([el['id']])
    until queue.empty?
      cur, path = queue.shift
      rels = Array(cur['relationships']).sort_by do |r|
        t = by_id[r['targetElementId']]
        t && r['name'].to_s.casecmp(t['name'].to_s).zero? ? 0 : 1
      end
      rels.each do |r|
        t = by_id[r['targetElementId']]
        next unless t && !seen.include?(t['id'])
        return path + [r['name']] if t['name'].to_s.casecmp(table.to_s).zero?
        seen << t['id']
        queue << [t, path + [r['name']]]
      end
    end
    nil
  end

  def formula_literal(v)
    case v
    when String then "\"#{v.gsub('\\') { '\\\\' }.gsub('"', '\\"')}\""
    when true, false, Numeric then v.to_s
    else 'Null'
    end
  end

  # Report-level list filters (signals['filters'], scope 'report'; target "Table.Column") go on every
  # element that holds metrics and reaches the table: each split child, or the unsplit element itself, and
  # directly on the table's own element. A related column reaches the element as a Lookup chain, never a
  # relationship path (P13). Exclusions keep NULL: one text value is a `text-match does-not-equal` with
  # includeNulls always; several values or a non-text column use a helper `Keep (<Column>)` =
  # `If(IsNull(x) or Not(In(x, ...)), "keep", "drop")` filtered to "keep". An include list is a plain list
  # filter. Returns {'applied' => [{'element','column','kind','helper'}], 'skipped' => [{'filter','reason'}]}.
  def report_filters!(dm_model, signals, classes)
    result = { 'applied' => [], 'skipped' => [], 'not_reachable' => [], 'dimension_unfiltered' => [] }
    pairs = split_pairs(dm_model)
    bases = pairs.map { |_c, b| b }
    all_filters = Array((signals || {})['filters'])
    all_filters.reject { |f| f['scope'].to_s == 'report' }.each do |f|
      result['skipped'] << { 'filter' => "#{f['target']} #{f['mode']} #{Array(f['values']).inspect}",
                             'reason' => f['scope'].to_s == 'page' ? 'page filter: handled by the workbook builder' : "#{f['scope']} filter: handled by the workbook builder" }
    end
    filters = all_filters.select { |f| f['scope'].to_s == 'report' }
    filters.each do |f|
      label = "#{f['target']} #{f['mode']} #{Array(f['values']).inspect}"
      table, column = f['target'].to_s.split('.', 2)
      unless f['type'].to_s == 'list' && table && column
        result['skipped'] << { 'filter' => label, 'reason' => "only list filters on Table.Column are carried (#{f['type'] || 'no type'})" }
        next
      end
      mode = f['mode'].to_s == 'exclude' ? 'exclude' : 'include'
      values = Array(f['values'])
      if values.empty?
        result['skipped'] << { 'filter' => label, 'reason' => "empty #{mode} list is a no-op" }
        next
      end
      preferred = (classes || {}).values.flat_map { |c| Array(c['related']) }
                                 .select { |r| r['table'].to_s.casecmp(table).zero? }.map { |r| Array(r['path']) }.uniq
      targets = elements_of(dm_model).reject { |e| bases.any? { |b| b.equal?(e) } }
                                     .select { |e| e['name'].to_s.casecmp(table).zero? || !Array(e['metrics']).empty? }
      if targets.empty?
        result['skipped'] << { 'filter' => label, 'reason' => 'no element holds metrics or the filtered table' }
        next
      end
      # The filtered table's own element goes last: a Lookup() into a filtered element returns NULL for the
      # excluded keys instead of dropping the row, and the fact's null-safe filter keeps NULL (live: the
      # excluded category's sales landed in the NULL group). So the table element is filtered only when no
      # fact element carries the filter.
      targets = targets.partition { |e| !e['name'].to_s.casecmp(table).zero? }.flatten(1)
      fact_filtered = false
      targets.each do |el|
        col_id = nil
        path = nil
        if el['name'].to_s.casecmp(table).zero?
          if fact_filtered
            result['dimension_unfiltered'] << { 'filter' => label, 'element' => el['name'],
                                                'reason' => 'a Lookup() into a filtered element returns NULL for the excluded keys instead of dropping the fact rows; the fact elements carry the filter' }
            next
          end
          col = column_named(el, column)
          col_id = col['id'] if col
          reason = "column #{column} not found on #{el['name']}"
        else
          path = path_to_table(dm_model, el, table, preferred)
          unless path
            result['not_reachable'] << { 'filter' => label, 'element' => el['name'], 'reason' => "#{el['name']} does not reach #{table}" }
            next
          end
          name, reason = lookup_chain!(dm_model, el, path, column)
          col_id = Array(el['columns']).find { |c| c['name'] == name }&.dig('id') if name
        end
        unless col_id
          result['skipped'] << { 'filter' => "#{label} on #{el['name']}", 'reason' => reason }
          next
        end
        col = column_by_id(el, col_id)
        shown = display_name(col)
        fid = next_id(dm_model, "#{el['id']}f")
        text = values.all? { |v| v.is_a?(String) }
        # table/source_column/mode/values/path: what a rolling-window SQL needs to carry the same filter (C2)
        entry = { 'element' => el['name'], 'column' => shown, 'table' => table, 'source_column' => column, 'mode' => mode,
                  'values' => values, 'path' => el['name'].to_s.casecmp(table).zero? ? [] : path }
        if mode == 'exclude' && text && values.length == 1
          flt = { 'id' => fid, 'columnId' => col_id, 'kind' => 'text-match', 'mode' => 'does-not-equal',
                  'value' => values[0], 'case' => 'insensitive', 'includeNulls' => 'always' } # m3: VertiPaq/DAX compare text case-insensitively
          entry['kind'] = 'text-match'
        elsif mode == 'exclude'
          concrete = values.compact
          clauses = []
          clauses << "IsNull([#{shown}])" unless values.include?(nil)
          unless concrete.empty?
            # m3: text compares case-insensitively, as form (b) does with Lower()
            clauses << if concrete.all? { |v| v.is_a?(String) }
                         "Not(In(Lower([#{shown}]), #{concrete.map { |v| formula_literal(v.downcase) }.join(', ')}))"
                       else
                         "Not(In([#{shown}], #{concrete.map { |v| formula_literal(v) }.join(', ')}))"
                       end
          end
          formula = values.include?(nil) ? "Not(IsNull([#{shown}]))" + (concrete.empty? ? '' : " and #{clauses.last}") : clauses.join(' or ')
          helper = { 'id' => next_id(dm_model, "#{el['id']}k"), 'name' => unique_name("Keep (#{shown})", taken_names(el)),
                     'formula' => "If(#{formula}, \"keep\", \"drop\")" }
          el['columns'] = Array(el['columns']) + [helper]
          el['order'] = Array(el['order']) + [helper['id']] if el['order']
          flt = { 'id' => fid, 'columnId' => helper['id'], 'kind' => 'list', 'mode' => 'include', 'values' => ['keep'] }
          entry['kind'] = 'list'
          entry['helper'] = helper['name']
        else
          flt = { 'id' => fid, 'columnId' => col_id, 'kind' => 'list', 'mode' => 'include', 'values' => values }
          entry['kind'] = 'list'
        end
        el['filters'] = Array(el['filters']) + [flt]
        fact_filtered = true unless el['name'].to_s.casecmp(table).zero?
        result['applied'] << entry
      end
    end
    result
  end

  # ---------------------------------------------------------------------------------------
  # Metric folders, names, descriptions
  # ---------------------------------------------------------------------------------------

  # The API has no metric folders (P14: metric ids are rejected in folders[].items), so a metric keeps its
  # Power BI name and its description gains "Power BI display folder: <X>". Returns
  # [{'metric','element','folder'}].
  def metric_display_folders!(dm_model, tmsl)
    folders = {}
    tables_of(tmsl).each do |t|
      Array(t['measures']).each { |m| folders[m['name']] = Array(m['displayFolder']).join(' ') if m['displayFolder'] && !Array(m['displayFolder']).join.empty? }
    end
    out = []
    elements_of(dm_model).each do |el|
      Array(el['metrics']).each do |m|
        folder = folders[m['name']]
        next unless folder
        line = "Power BI display folder: #{folder}"
        m['description'] = [m['description'], line].reject { |t| t.to_s.empty? }.join(' ') unless m['description'].to_s.include?(line)
        out << { 'metric' => m['name'], 'element' => el['name'], 'folder' => folder }
      end
    end
    out
  end

  # Power BI forbids duplicate measure names in a model, so the one real collision is a metric and a column
  # sharing a name on ONE element (a Sigma bare reference would be ambiguous). The metric becomes
  # "<Measure> (measure)". Same name on different elements is fine (P7). Returns [{'from','to','element'}].
  def unique_metric_names!(dm_model)
    out = []
    elements_of(dm_model).each do |el|
      cols = Set.new(Array(el['columns']).map { |c| display_name(c).to_s.downcase })
      taken = taken_names(el)
      Array(el['metrics']).each do |m|
        next unless cols.include?(m['name'].to_s.downcase)
        to = unique_name("#{m['name']} (measure)", taken)
        out << { 'from' => m['name'], 'to' => to, 'element' => el['name'] }
        m['name'] = to
      end
    end
    out
  end

  # A metric that reads another metric of the same element must say so: a bare `[Sales Amount]` POSTs and
  # reads back, but the workbook column `[Metrics/<composite>]` then compiles to type error (live-proven; the
  # `[Metrics/Sales Amount]` form works). Returns [{'element','metric','refs'}] for each rewritten metric.
  def qualify_metric_refs!(dm_model)
    out = []
    elements_of(dm_model).each do |el|
      names = Array(el['metrics']).map { |m| m['name'].to_s }.reject(&:empty?)
      next if names.empty?
      Array(el['metrics']).each do |m|
        next unless m['formula'].is_a?(String)
        refs = []
        formula = m['formula'].gsub(/\[([^\[\]\/]+)\]/) do |whole|
          ref = $1
          own = names.find { |n| n.casecmp(ref).zero? } # m16: a case-insensitive match keeps the metric's own spelling
          if own && own != m['name']
            refs << own
            "[Metrics/#{own}]"
          else
            whole
          end
        end
        next if refs.empty?
        m['formula'] = formula
        out << { 'element' => el['name'], 'metric' => m['name'], 'refs' => refs.uniq }
      end
    end
    out
  end

  # I1 (pbi mode): DAX reads a blank sub-measure as 0 in + and - (`5 - BLANK() = 5`) and returns BLANK only when
  # every term is blank; Sigma returns Null as soon as one side is. A metric whose formula has a top-level binary
  # + or - is rewritten as
  #   If(IsNull(a) and IsNull(b), Null, Coalesce(a, 0) - Coalesce(b, 0))
  # (a literal term is never blank, so with one there is no guard). A parenthesised term is rewritten the same way
  # before it is coalesced. Run after qualify_metric_refs!. Returns [{'element','metric','from','to'}].
  def blank_arith_metrics!(dm_model)
    out = []
    elements_of(dm_model).each do |el|
      Array(el['metrics']).each do |m|
        next unless m['formula'].is_a?(String)
        rewritten = blank_arith_formula(m['formula'])
        next if rewritten == m['formula']
        out << { 'element' => el['name'], 'metric' => m['name'], 'from' => m['formula'], 'to' => rewritten }
        m['formula'] = rewritten
      end
    end
    out
  end

  def blank_arith_formula(expr)
    terms = split_additive(expr)
    return expr if terms.nil? || terms.length < 2
    texts = terms.map do |_sign, t|
      g = t.strip
      inner = g.start_with?('(') && g.end_with?(')') && whole_group?(g) ? g[1...-1] : nil
      inner && (re = blank_arith_formula(inner)) != inner ? "(#{re})" : g
    end
    lit = ->(t) { t =~ /\A\d+(?:\.\d+)?\z/ }
    done = ->(t) { (c = whole_call(t)) && c[0].casecmp('COALESCE').zero? } # already blank-safe: never wrapped twice
    vars = texts.reject { |t| lit.call(t) }
    return expr if vars.empty? || vars.all? { |t| done.call(t) }
    body = terms.each_with_index.map do |(sign, _), i|
      t = lit.call(texts[i]) || done.call(texts[i]) ? texts[i] : "Coalesce(#{texts[i]}, 0)"
      i.zero? ? "#{sign == '-' ? '-' : ''}#{t}" : " #{sign} #{t}"
    end.join
    return body if vars.length < texts.length
    "If(#{vars.map { |t| "IsNull(#{t})" }.join(' and ')}, Null, #{body})"
  end

  # [[sign, term text], ...] split on the top-level binary + and - of a formula, or nil when it holds a top-level
  # comparison/logic operator or does not balance (not plain arithmetic).
  def split_additive(expr)
    terms = []
    depth = 0
    quote = nil
    cur = +''
    sign = '+'
    prev = nil
    expr.each_char do |ch|
      if quote
        cur << ch
        quote = nil if ch == quote
        next
      end
      case ch
      when '"' then quote = ch
      when '(', '[' then depth += 1
      when ')', ']' then depth -= 1
      end
      return nil if depth.negative?
      if depth.zero? && ch =~ /[<>=&|]/
        return nil
      end
      if depth.zero? && (ch == '+' || ch == '-') && !prev.nil? && prev !~ /[+\-*\/(,]/
        terms << [sign, cur.strip]
        cur = +''
        sign = ch
        prev = ch
        next
      end
      if depth.zero? && (ch == '+' || ch == '-') && prev.nil?
        sign = ch # a leading unary sign belongs to the first term
        prev = ch
        next
      end
      cur << ch
      prev = ch unless ch =~ /\s/
    end
    return nil unless depth.zero? && quote.nil?
    terms << [sign, cur.strip]
    terms.any? { |_s, t| t.empty? } ? nil : terms
  end

  # True when the parenthesis that opens `text` closes at its last character.
  def whole_group?(text)
    depth = 0
    text.each_char.with_index do |ch, i|
      depth += 1 if ch == '('
      depth -= 1 if ch == ')'
      return i == text.length - 1 if depth.zero?
    end
    false
  end

  def sql_objects(statement)
    statement.to_s.scan(/\b(?:from|join)\s+((?:"[^"]+"|`[^`]+`|[\w$]+)(?:\.(?:"[^"]+"|`[^`]+`|[\w$]+))*)/i)
             .flatten.map { |o| o.delete('"`') }.uniq
  end

  # Descriptions: a restored Power BI query ("Power BI query for <Table>; reads <objects>"), the
  # "(source)" base, and the child's Lookup list. Returns [{'element','description'}].
  def describe!(dm_model, tmsl, native_result)
    out = []
    converted = Array((native_result || {})['converted']).map { |c| c['table'].to_s.downcase }
    elements_of(dm_model).each do |el|
      next unless el.dig('source', 'kind') == 'sql' && converted.include?(el['name'].to_s.downcase)
      objs = sql_objects(el.dig('source', 'statement'))
      text = "Power BI query for #{el['name']}#{objs.empty? ? '' : "; reads #{objs.join(', ')}"}"
      append_description(el, text) unless el['description'].to_s.include?(text)
      out << { 'element' => el['name'], 'description' => text }
    end
    split_pairs(dm_model).each do |child, base|
      fact = child['name']
      look = Array(child['columns']).select { |c| c['formula'].to_s.start_with?('Lookup(') }
      btext = "Source of the Power BI table #{fact}; charts read #{fact}."
      append_description(base, btext) unless base['description'].to_s.include?(btext)
      out << { 'element' => base['name'], 'description' => btext }
      ctext = "Power BI table #{fact}, with the metrics. Related values come in through Lookup()" +
              (look.empty? ? '.' : ": #{look.map { |c| c['name'] }.join(', ')}.")
      append_description(child, ctext) unless child['description'].to_s.include?(ctext)
      out << { 'element' => child['name'], 'description' => ctext }
    end
    out
  end

  # ---------------------------------------------------------------------------------------
  # Class B metrics (the converter drops them)
  # ---------------------------------------------------------------------------------------
  # Narrow DAX forms only; anything else is reclassified D ("B form not translatable: ...").
  #   (a) SUMX/AVERAGEX/MINX/MAXX/COUNTX(<home>, <row expr>), row = own columns, RELATED(T[C]), numbers, + - * / ( )
  #       -> Sum/Avg/Min/Max/Count(<row expr>), RELATED as a relationship-path ref (split_facts! chains it).
  #   (b) CALCULATE(<A measure | single aggregate>, <literal filters>) -> SumIf/AvgIf/MinIf/MaxIf(<row>, <cond>)
  #       (Count: CountIf(<cond>)). Filters: col = lit | col <> lit | col IN {..} | col = TRUE()/FALSE().
  #   (c) CALCULATE(<A measure>, USERELATIONSHIP(..)) alone -> the A measure's formula, unchanged.

  ITERATOR_AGG = { 'SUMX' => 'Sum', 'AVERAGEX' => 'Avg', 'MINX' => 'Min', 'MAXX' => 'Max', 'COUNTX' => 'Count' }.freeze
  PLAIN_AGG = { 'SUM' => 'Sum', 'AVERAGE' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max', 'COUNT' => 'Count' }.freeze
  IF_AGG = { 'Sum' => 'SumIf', 'Avg' => 'AvgIf', 'Min' => 'MinIf', 'Max' => 'MaxIf', 'Count' => 'CountIf' }.freeze
  DAX_COL = /(?:'([^']+)'|([A-Za-z_]\w*))\s*\[([^\]]+)\]/.freeze

  class NotTranslatable < StandardError; end

  # Split `text` on top-level commas (not inside (), {}, [], "" or '').
  def split_top_level(text)
    parts = []
    depth = 0
    cur = +''
    quote = nil
    text.each_char do |ch|
      if quote
        cur << ch
        quote = nil if ch == quote
        next
      end
      case ch
      when '"', "'" then quote = ch; cur << ch
      when '(', '{', '[' then depth += 1; cur << ch
      when ')', '}', ']' then depth -= 1; cur << ch
      when ','
        if depth.zero?
          parts << cur.strip
          cur = +''
        else
          cur << ch
        end
      else cur << ch
      end
    end
    parts << cur.strip
    parts
  end

  # `NAME( ... )` spanning the whole text -> [NAME, inner], else nil.
  def whole_call(text)
    m = text.strip.match(/\A([A-Za-z_]\w*)\s*\((.*)\)\z/m)
    return nil unless m
    depth = 0
    quote = nil
    inner = m[2]
    inner.each_char do |ch|
      if quote then quote = nil if ch == quote; next end
      if ch == '"' || ch == "'" then quote = ch
      elsif ch == '(' then depth += 1
      elsif ch == ')'
        depth -= 1
        return nil if depth < 0
      end
    end
    depth.zero? ? [m[1].upcase, inner] : nil
  end

  # A column reference from DAX (own table or related) as a Sigma ref, using the measure's related entries.
  def dax_column_ref(el, home, by_id, related, table, column)
    if table.casecmp(home).zero?
      col = column_named(el, column)
      raise NotTranslatable, "column #{table}[#{column}] not found on #{el['name']}" unless col
      return "[#{display_name(col)}]"
    end
    rel = related.find { |r| r['table'].to_s.casecmp(table).zero? && norm_name(r['column']) == norm_name(column) }
    raise NotTranslatable, "#{table}[#{column}] has no relationship path in the class entry" unless rel
    cur = el
    Array(rel['path']).each do |rn|
      r = find_relationship(cur, rn, by_id)
      raise NotTranslatable, "relationship #{rn} not found on #{cur['name']}" unless r
      cur = by_id[r['targetElementId']]
      raise NotTranslatable, "relationship #{rn} has no target element" unless cur
    end
    tcol = column_named(cur, column)
    "[#{(Array(rel['path']) + [tcol ? display_name(tcol) : column]).join('/')}]"
  end

  # R50: DAX reads BLANK as 0 in + and -, SQL/Sigma read it as NULL. A row with a binary + or - is only exact
  # for a sum when every column is coalesced to 0 (blank and 0 add the same, and * and / with a blank add
  # nothing in both engines). A non-sum aggregate over two or more columns cannot be made exact.
  def binary_arith?(row)
    row.gsub(/\[[^\]]*\]/, '#').match?(/[#\d)]\s*[+\-]/)
  end

  # A row that divides and also has a binary + or - over two or more columns (R52).
  def division_arith?(row)
    row.gsub(/\[[^\]]*\]/, '#').include?('/') && binary_arith?(row) && row.scan(/\[[^\]]*\]/).length >= 2
  end

  # The same test on a DAX row (Table[Col] tokens instead of [Col]).
  def dax_row_binary_arith?(row)
    row.gsub(DAX_COL, '#').match?(/[#\d)]\s*[+\-]/)
  end

  def blank_safe_row(row)
    binary_arith?(row) ? row.gsub(/(?<!Coalesce\()\[[^\]]*\]/) { |t| "Coalesce(#{t}, 0)" } : row # idempotent
  end

  # `agg` is the Sigma aggregate name the row feeds ('Sum' wraps, others refuse a multi-column + or -).
  def aggregate_row(row, agg)
    # R52: a coalesced divisor is a division-by-zero error in SQL where DAX/NULL gave blank
    raise NotTranslatable, 'blank arithmetic with division' if division_arith?(row)
    return blank_safe_row(row) if agg == 'Sum'
    if binary_arith?(row) && row.scan(/\[[^\]]*\]/).length >= 2
      raise NotTranslatable, 'blank arithmetic in a non-sum iterator'
    end
    row
  end

  def translate_row(row, el, home, by_id, related)
    out = row.gsub(/RELATED\s*\(\s*#{DAX_COL.source}\s*\)/i) do
      dax_column_ref(el, home, by_id, related, ($1 || $2).to_s, $3.to_s).sub(/\A\[/, "\u0001").sub(/\]\z/, "\u0002")
    end
    out = out.gsub(DAX_COL) do
      t = ($1 || $2).to_s
      raise NotTranslatable, "own-column reference to #{t}[#{$3}] outside the home table" unless t.casecmp(home).zero?
      dax_column_ref(el, home, by_id, related, t, $3.to_s).sub(/\A\[/, "\u0001").sub(/\]\z/, "\u0002")
    end
    residue = out.gsub(/\u0001[^\u0002]*\u0002/, '')
    raise NotTranslatable, "row expression has other parts (#{residue.strip[0, 40]})" unless residue =~ /\A[\d\s.+\-*\/()]*\z/
    out.tr("\u0001\u0002", '[]')
  end

  # [kind, value] for a DAX literal: [:str, "text"], [:num, "12"], [:bool, true/false].
  def dax_literal_parts(text)
    t = text.strip
    str = t.match(/\A"((?:[^"]|"")*)"\z/)
    return [:str, str[1].gsub('""', '"')] if str
    return [:num, t] if t =~ /\A-?\d+(?:\.\d+)?\z/
    return [:bool, true] if t =~ /\ATRUE\s*\(\s*\)\z/i
    return [:bool, false] if t =~ /\AFALSE\s*\(\s*\)\z/i
    raise NotTranslatable, "non-literal filter value #{t[0, 30]}"
  end

  def sigma_literal(kind, value)
    case kind
    when :str then "\"#{value.gsub('\\') { '\\\\' }.gsub('"', '\\"')}\""
    when :bool then value ? 'True' : 'False'
    else value
    end
  end

  # DAX treats a blank as equal to 0, "" and FALSE.
  def blank_equal?(kind, value)
    (kind == :num && value.to_f.zero?) || (kind == :str && value.empty?) || (kind == :bool && value == false)
  end

  # One CALCULATE filter -> [Sigma condition, Power BI column name]. DAX string compares ignore case, so a
  # text literal compares through Lower(); `<>` keeps blanks (IsNull or ...); a literal blank equals
  # (0, "", FALSE) matches blanks too.
  def translate_filter(f, el, home, by_id, related)
    m = f.strip.match(/\A#{DAX_COL.source}\s*(=|<>|\bIN\b)\s*(.+)\z/im)
    raise NotTranslatable, "filter #{f.strip[0, 40]} is not a literal comparison" unless m
    colname = m[3].to_s
    ref = dax_column_ref(el, home, by_id, related, (m[1] || m[2]).to_s, colname)
    op = m[4].upcase
    rhs = m[5].strip
    if op == 'IN'
      raise NotTranslatable, 'IN needs a literal set' unless rhs =~ /\A\{(.*)\}\z/m
      lits = split_top_level(Regexp.last_match(1)).map { |v| dax_literal_parts(v) }
      text = lits.all? { |k, _| k == :str }
      list = lits.map { |k, v| sigma_literal(k, text ? v.downcase : v) }.join(', ')
      cond = "In(#{text ? "Lower(#{ref})" : ref}, #{list})"
      return [lits.any? { |k, v| blank_equal?(k, v) } ? "(IsNull(#{ref}) or #{cond})" : cond, colname]
    end
    kind, value = dax_literal_parts(rhs)
    text = kind == :str && !value.empty?
    left = text ? "Lower(#{ref})" : ref
    right = text ? "Lower(#{sigma_literal(kind, value)})" : sigma_literal(kind, value)
    if op == '='
      cond = "#{left} = #{right}"
      cond = "(IsNull(#{ref}) or #{cond})" if blank_equal?(kind, value)
    else
      cond = "#{left} != #{right}"
      cond = "(IsNull(#{ref}) or #{cond})" unless blank_equal?(kind, value) # <> 0 / "" / FALSE() excludes blanks in DAX
    end
    [cond, colname]
  end

  # [aggregate name, row text] for a metric formula that is one aggregate over the whole formula.
  def single_aggregate(formula)
    call = whole_call(formula.to_s)
    return nil unless call && %w[SUM AVG MIN MAX COUNT].include?(call[0])
    [call[0].capitalize, call[1]]
  end

  def translate_b_metric(dax, el, home, by_id, related)
    top = whole_call(dax.strip)
    raise NotTranslatable, 'not a recognised function call' unless top
    fn, inner = top
    if ITERATOR_AGG.key?(fn)
      args = split_top_level(inner)
      raise NotTranslatable, "#{fn} needs two arguments" unless args.length == 2
      raise NotTranslatable, "#{fn} does not iterate #{home}" unless args[0].delete("'").strip.casecmp(home).zero?
      return { 'formula' => "#{ITERATOR_AGG[fn]}(#{aggregate_row(translate_row(args[1], el, home, by_id, related), ITERATOR_AGG[fn])})" }
    end
    if PLAIN_AGG.key?(fn)
      return { 'formula' => "#{PLAIN_AGG[fn]}(#{aggregate_row(translate_row(inner, el, home, by_id, related), PLAIN_AGG[fn])})" }
    end
    raise NotTranslatable, "#{fn} is outside the supported forms" unless fn == 'CALCULATE'
    args = split_top_level(inner)
    raise NotTranslatable, 'CALCULATE needs a filter' if args.length < 2
    first = args[0]
    source = nil
    if first =~ /\A\[([^\]]+)\]\z/
      source = Array(el['metrics']).find { |m| m['name'] == $1 }
      raise NotTranslatable, "measure [#{$1}] has no Sigma metric on #{el['name']}" unless source
      agg = single_aggregate(source['formula'])
      agg = [agg[0], aggregate_row(agg[1], agg[0])] if agg
    elsif (c = whole_call(first)) && PLAIN_AGG.key?(c[0])
      agg = [PLAIN_AGG[c[0]], aggregate_row(translate_row(c[1], el, home, by_id, related), PLAIN_AGG[c[0]])]
    elsif (c = whole_call(first)) && ITERATOR_AGG.key?(c[0])
      iter = split_top_level(c[1])
      raise NotTranslatable, "#{c[0]} needs two arguments" unless iter.length == 2
      raise NotTranslatable, "#{c[0]} does not iterate #{home}" unless iter[0].delete("'").strip.casecmp(home).zero?
      agg = [ITERATOR_AGG[c[0]], aggregate_row(translate_row(iter[1], el, home, by_id, related), ITERATOR_AGG[c[0]])]
    elsif (c = whole_call(first)) && c[0] == 'COUNTROWS' && c[1].delete("'").strip.casecmp(home).zero?
      agg = ['CountRows', nil]
    end
    if args.length == 2 && args[1] =~ /\AUSERELATIONSHIP\s*\(/i
      raise NotTranslatable, 'USERELATIONSHIP needs an A measure' unless source
      return { 'formula' => source['formula'], 'format' => source['format'] }
    end
    raise NotTranslatable, 'the aggregate is not a single Sum/Avg/Min/Max/Count' unless agg
    translated = args[1..-1].map { |f| translate_filter(f, el, home, by_id, related) }
    cond = translated.map(&:first).join(' and ')
    inner_row = agg[1]
    formula = case agg[0]
              when 'CountRows' then "CountIf(#{cond})" # COUNTROWS counts rows
              when 'Count' then "CountIf(#{cond} and Not(IsNull(#{inner_row})))" # COUNT counts non-blank values
              else "#{IF_AGG[agg[0]]}(#{inner_row}, #{cond})"
              end
    cols = translated.map(&:last).uniq
    note = cols.map do |c|
      "Power BI's CALCULATE filter on #{c} overrides slicers on that column; in Sigma a slicer on #{c} still applies."
    end.join(' ')
    { 'formula' => formula, 'format' => source && source['format'], 'description' => note }
  end

  # R51: a class A metric the converter built keeps its id and name but follows the same blank rule as the
  # metrics built here (otherwise Sales Amount drops rows with a NULL discount that the SumIf forms derived
  # from it count). Only a SUMX/SUM-family measure whose row has a binary + or - changes; anything our
  # translator cannot read keeps the converter's formula and is listed in `rebuilt_a_skipped`.
  def rebuild_class_a_metric!(dm_model, el, metric, key, c, measure, home, by_id, result)
    return unless measure
    expr = measure['expression']
    expr = expr.join("\n") if expr.is_a?(Array)
    top = whole_call(expr.to_s.strip)
    return unless top && (ITERATOR_AGG.key?(top[0]) && top[0] == 'SUMX' || top[0] == 'SUM')
    args = ITERATOR_AGG.key?(top[0]) ? split_top_level(top[1])[1].to_s : top[1]
    return unless dax_row_binary_arith?(args)
    built = translate_b_metric(expr.to_s, el, home, by_id, Array(c['related']))
    return unless built['formula'].include?('Coalesce(') && built['formula'] != metric['formula']
    result['rebuilt_a'] << { 'measure' => key, 'from' => metric['formula'], 'to' => built['formula'] }
    metric['formula'] = built['formula']
  rescue NotTranslatable => e
    result['rebuilt_a_skipped'] << { 'measure' => key, 'reason' => e.message }
  end

  # Write each class A or B metric the converter dropped onto its home element (the converter drops class B
  # and complex CALCULATE forms; a class A measure it kept is skipped). Call BEFORE split_facts!.
  # Returns {'built' => ["Table.Measure"], 'reclassified' => [{'key','reason'}]}; reclassified entries are
  # set to class D in `classes` with a reason starting "<A or B> form not translatable:".
  def build_missing_metrics!(dm_model, tmsl, classes)
    result = { 'built' => [], 'reclassified' => [], 'rebuilt_a' => [], 'rebuilt_a_skipped' => [] }
    by_id = by_id_map(dm_model)
    tables = tables_of(tmsl)
    entries = (classes || {}).select { |_k, c| %w[A B].include?(c['class']) }.to_a
    # pass 1 (R51): rebuild the class A metrics the converter built, so a metric that copies one (a
    # USERELATIONSHIP measure) always sees the final formula whatever the order of `classes`
    entries.each do |key, c|
      next unless c['class'] == 'A'
      table, name = key.split('.', 2)
      home = (c['home'] || table).to_s
      el = elements_of(dm_model).find { |e| e['name'].to_s.casecmp(home).zero? }
      existing = el && Array(el['metrics']).find { |m| m['name'] == name }
      next unless existing
      tm = tables.find { |t| t['name'] == table }
      measure = tm && Array(tm['measures']).find { |m| m['name'] == name }
      rebuild_class_a_metric!(dm_model, el, existing, key, c, measure, home, by_id, result)
    end
    # pass 2: build the metrics the converter dropped
    entries.each do |key, c|
      table, name = key.split('.', 2)
      home = (c['home'] || table).to_s
      el = elements_of(dm_model).find { |e| e['name'].to_s.casecmp(home).zero? }
      tm = tables.find { |t| t['name'] == table }
      measure = tm && Array(tm['measures']).find { |m| m['name'] == name }
      next if el && Array(el['metrics']).any? { |m| m['name'] == name }
      begin
        raise NotTranslatable, "home element #{home} not found" unless el
        raise NotTranslatable, 'measure not found in the model' unless measure
        expr = measure['expression']
        expr = expr.join("\n") if expr.is_a?(Array)
        built = translate_b_metric(expr.to_s, el, home, by_id, Array(c['related']))
        metric = { 'id' => next_id(dm_model, "#{el['id']}m"), 'name' => name, 'formula' => built['formula'] }
        metric['format'] = built['format'] if built['format']
        metric['description'] = built['description'] if built['description']
        el['metrics'] = Array(el['metrics']) + [metric]
        result['built'] << key
      rescue NotTranslatable => e
        reason = "#{c['class']} form not translatable: #{e.message}"
        c['class'] = 'D'
        c['reason'] = reason
        result['reclassified'] << { 'key' => key, 'reason' => reason }
      end
    end
    result
  end

  # ---------------------------------------------------------------------------------------
  # Subject-area pages and size
  # ---------------------------------------------------------------------------------------
  # One data model page per fact (probe P9: relationships and Lookup chains work across pages). A fact is an
  # element that holds metrics, or that is the many-side of relationships and no other element points at
  # (a snowflake dimension such as SKU or Product also has relationships, but a fact points at it). Elements
  # built over another element (the "(source)"/child split, time-intelligence and summary elements, a
  # re-keyed copy) follow the element they are built on. A dimension reached by several facts goes on the
  # page of the fact whose visible visuals read it most; on a tie, or when no fact reaches it, on `Shared`.
  # Page names are the fact's Power BI name (without " (source)").
  SHARED_PAGE = 'Shared'

  # {element id => root element}: an element built on another (`source.kind == 'table'`) follows it up to a
  # root. `attach` ({element name => the element name it belongs with}) links elements that have no source
  # link, such as the rolling-window Custom SQL element and its fact.
  def root_map(dm_model, attach = {})
    by_id = by_id_map(dm_model)
    by_name = {}
    elements_of(dm_model).each { |e| by_name[e['name'].to_s.downcase] ||= e }
    parent = {}
    elements_of(dm_model).each do |el|
      up = by_id[el.dig('source', 'elementId')] if el.dig('source', 'kind') == 'table'
      up ||= by_name[(attach || {})[el['name']].to_s.downcase]
      parent[el['id']] = up if up && !up.equal?(el)
    end
    out = {}
    elements_of(dm_model).each do |el|
      cur = el
      seen = Set.new([el['id']])
      cur = parent[cur['id']] while parent[cur['id']] && seen.add?(parent[cur['id']]['id'])
      out[el['id']] = cur
    end
    out
  end

  # The fact roots of the model, in element order.
  def fact_roots(dm_model, roots)
    with_metrics = Set.new
    targeted = Set.new
    with_rels = Set.new
    by_id = by_id_map(dm_model)
    elements_of(dm_model).each do |e|
      root = roots[e['id']]
      with_metrics << root['id'] unless Array(e['metrics']).empty?
      with_rels << root['id'] unless Array(e['relationships']).empty?
      Array(e['relationships']).each { |r| targeted << roots[r['targetElementId']]['id'] if by_id[r['targetElementId']] }
    end
    elements_of(dm_model).select do |e|
      roots[e['id']].equal?(e) && (with_metrics.include?(e['id']) || (with_rels.include?(e['id']) && !targeted.include?(e['id'])))
    end
  end

  # Root ids reachable from `fact` through relationships (any element built on the fact counts).
  def reachable_roots(dm_model, fact, roots, by_id)
    seen = Set.new
    queue = elements_of(dm_model).select { |e| roots[e['id']].equal?(fact) }
    until queue.empty?
      el = queue.shift
      Array(el['relationships']).each do |r|
        tgt = by_id[r['targetElementId']]
        next unless tgt
        root = roots[tgt['id']]
        next if root.equal?(fact) || !seen.add?(root['id'])
        queue.concat(elements_of(dm_model).select { |e| roots[e['id']].equal?(root) })
      end
    end
    seen
  end

  def page_name_for(fact)
    fact['name'].to_s.sub(/#{Regexp.escape(SOURCE_SUFFIX)}\z/, '')
  end

  # Visible-visual reads: {[fact root id, dimension root id] => count}. A visual counts for the home
  # fact(s) of the measures it binds, once per dimension table it reads.
  def visual_reads(dm_model, signals, classes, roots)
    counts = Hash.new(0)
    return counts unless signals && classes
    require_relative 'pbi_measure_class'
    named = {}
    elements_of(dm_model).each { |e| named[e['name'].to_s.downcase] ||= roots[e['id']] }
    Array(signals['pages']).each do |page|
      next if page['hidden']
      Array(page['visuals']).each do |v|
        next if v['hidden']
        homes = []
        tables = []
        (v['bindings'] || {}).each_value do |refs|
          Array(refs).each do |ref|
            hits = classes.keys.select { |k| k.split('.', 2)[1] == ref.to_s }
            key = classes.key?(ref.to_s) ? ref.to_s : (hits.length == 1 ? hits[0] : nil)
            if key
              homes << named[(classes[key]['home'] || key.split('.', 2)[0]).to_s.downcase]
            else
              tables << ref.to_s.split('.', 2)[0]
            end
          end
        end
        homes.compact.uniq.each do |fact|
          tables.uniq.each do |t|
            dim = named[t.to_s.downcase]
            counts[[fact['id'], dim['id']]] += 1 if dim
          end
        end
      end
    end
    counts
  end

  # Rebuild dm_model['pages'] as one page per fact plus `Shared`. Returns [{'name','element_ids'}].
  # `signals` and `classes` (both optional) weigh a shared dimension by the visible visuals that read it
  # with each fact's measures. `attach` links source-less elements to their fact (see root_map).
  # A model with no fact stays as it is; `multi_page: false` (the page probe failed) keeps one page.
  def subject_pages!(dm_model, signals: nil, classes: nil, attach: {}, multi_page: true)
    pages = Array(dm_model['pages'])
    all = elements_of(dm_model)
    roots = root_map(dm_model, attach)
    facts = fact_roots(dm_model, roots)
    unless multi_page && !facts.empty?
      return [{ 'name' => (pages.first || {})['name'], 'element_ids' => all.map { |e| e['id'] } }]
    end
    by_id = by_id_map(dm_model)
    reads = visual_reads(dm_model, signals, classes, roots)
    reach = facts.each_with_object({}) { |f, h| h[f['id']] = reachable_roots(dm_model, f, roots, by_id) }
    home_of = {}
    facts.each { |f| home_of[f['id']] = f['id'] }
    all.map { |e| roots[e['id']] }.uniq.each do |root|
      next if home_of.key?(root['id'])
      users = facts.select { |f| reach[f['id']].include?(root['id']) }
      home_of[root['id']] =
        if users.length == 1 then users[0]['id']
        elsif users.empty? then nil
        else
          counts = users.map { |f| [f, reads[[f['id'], root['id']]]] }
          best = counts.map(&:last).max
          winners = counts.select { |_f, n| n == best }
          winners.length == 1 ? winners[0][0]['id'] : nil
        end
    end
    taken = Set.new(pages.map { |pg| pg['id'] })
    used_names = Set.new
    new_pages = facts.map do |f|
      { 'id' => unique_page_id(taken), 'name' => unique_name(page_name_for(f), used_names), 'elements' => [], 'fact' => f['id'] }
    end
    shared = { 'id' => unique_page_id(taken), 'name' => unique_name(SHARED_PAGE, used_names), 'elements' => [], 'fact' => nil }
    all.each do |el|
      target = home_of[roots[el['id']]['id']]
      (new_pages.find { |pg| pg['fact'] == target } || shared)['elements'] << el
    end
    new_pages << shared unless shared['elements'].empty?
    new_pages.each { |pg| pg.delete('fact') }
    dm_model['pages'] = new_pages
    new_pages.map { |pg| { 'name' => pg['name'], 'element_ids' => pg['elements'].map { |e| e['id'] } } }
  end

  def unique_page_id(taken)
    n = 0
    n += 1 while taken.include?("page#{n}")
    taken << "page#{n}"
    "page#{n}"
  end

  # {'elements','sql_elements','guidance'} against the 30-40 element guidance.
  def size_stats(dm_model)
    els = elements_of(dm_model)
    { 'elements' => els.length, 'sql_elements' => els.count { |e| e.dig('source', 'kind') == 'sql' }, 'guidance' => '30-40' }
  end

  # ---------------------------------------------------------------------------------------
  # The whole model transform
  # ---------------------------------------------------------------------------------------

  # The date table the class C measures read: the one their time-intelligence names, else the TMSL table
  # marked as a date table, else "Date".
  def date_element_for(c_entries, tmsl)
    named = c_entries.map { |_k, c| c.dig('ti', 'date_table') }.compact.uniq
    return named if named.any?
    marked = tables_of(tmsl).find { |t| t['dataCategory'].to_s.casecmp('Time').zero? }
    [marked ? marked['name'] : 'Date']
  end

  # ---------------------------------------------------------------------------------------
  # Flattened child (Task 17, R7 lifted) and materialization targets (R21)
  # ---------------------------------------------------------------------------------------
  # `<Fact> (flattened)` is a child of the fact's source element (the `(source)` base when the fact is split,
  # else the fact element) with no relationships: the fact's own columns, a Lookup-chain calc column for every
  # related field a visible visual reads (P11), the fact's metrics and report filters. Materialized, it needs no
  # dimension joins (3M rows: 137 ms against 309 ms live); live it costs the same as the plain child. Folders are
  # named after the Power BI table each Lookup column reads from; the folder ids go at the end of `order`.

  FLATTENED_SUFFIX = ' (flattened)'

  # Related fields read on the pages where the fact's charts appear: [{table, column, path}] with `path` the
  # relationship names from the fact element. A page counts when a visible visual binds a field of the fact's
  # own table; then every visible visual there counts (slicers and controls included, they filter the fact's
  # charts through the same fields), as do that page's filters and the report filters.
  def fact_related_reads(dm_model, fact_el, fact_name, signals)
    out = []
    seen = Set.new
    by_name = {}
    elements_of(dm_model).each { |e| by_name[e['name'].to_s.downcase] ||= e }
    fact_ref = ->(r) { r.split('.', 2)[0].to_s.casecmp(fact_name.to_s).zero? }
    add = lambda do |ref|
      table, column = ref.to_s.split('.', 2)
      next if table.nil? || column.nil? || table.casecmp(fact_name.to_s).zero?
      target = by_name[table.downcase]
      next unless target && column_named(target, column)
      next unless seen.add?([table.downcase, norm_name(column)])
      path = path_to_table(dm_model, fact_el, table)
      out << { 'table' => target['name'], 'column' => display_name(column_named(target, column)), 'path' => path } if path
    end
    filter_targets = ->(list) { Array(list).map { |f| f.is_a?(Hash) ? f['target'] : nil }.compact }
    fact_pages = false
    Array((signals || {})['pages']).each do |page|
      next if page['hidden']
      visuals = Array(page['visuals']).reject { |v| v['hidden'] }
      refs = visuals.flat_map { |v| (v['bindings'] || {}).values.flatten.compact.map(&:to_s) }
      next unless refs.any?(&fact_ref)
      fact_pages = true
      (refs + filter_targets.call(page['filters'])).each(&add)
    end
    filter_targets.call((signals || {})['filters']).each(&add) if fact_pages
    out
  end

  def lookup_target_table(formula)
    formula.to_s[%r{\ALookup\(\[([^\]/]+)/}, 1]
  end

  # Adds `<Fact> (flattened)` and returns {'element' => name, 'reason' => nil}; a refusal is
  # {'element' => nil, 'reason' => text} and leaves the model untouched. An unknown fact raises.
  def flatten!(dm_model, fact, signals)
    fact_el = elements_of(dm_model).find { |e| e['name'].to_s.casecmp(fact.to_s).zero? && !e['name'].to_s.end_with?(FLATTENED_SUFFIX) }
    raise ArgumentError, "flatten: no element named #{fact.inspect}" unless fact_el
    fact_name = fact_el['name']
    flat_name = "#{fact_name}#{FLATTENED_SUFFIX}"
    return { 'element' => flat_name, 'reason' => 'already flattened' } if elements_of(dm_model).any? { |e| e['name'] == flat_name }
    pair = split_pairs(dm_model).find { |child, _base| child.equal?(fact_el) }
    source_el = pair ? pair[1] : fact_el
    reads = fact_related_reads(dm_model, fact_el, fact_name, signals)
    if reads.empty?
      return { 'element' => nil, 'reason' => "#{fact_name} is join-free: its visuals read no related fields, so a flattened child would add nothing" }
    end
    page = Array(dm_model['pages']).find { |pg| Array(pg['elements']).any? { |e| e.equal?(fact_el) } }
    return { 'element' => nil, 'reason' => "#{fact_name} is on no data model page" } unless page

    flat_id = next_id(dm_model, "#{source_el['id']}f")
    colmap = {}
    cols = Array(fact_el['columns']).each_with_index.map do |c, i|
      cid = "#{flat_id}c#{i}"
      colmap[c['id']] = cid
      formula = pair ? c['formula'] : "[#{fact_name}/#{display_name(c)}]"
      h = { 'id' => cid, 'name' => display_name(c), 'formula' => formula }
      %w[hidden format description].each { |k| h[k] = c[k] if c.key?(k) }
      h
    end
    flat = { 'id' => flat_id, 'kind' => 'table', 'name' => flat_name,
             'source' => { 'kind' => 'table', 'elementId' => source_el['id'] },
             'columns' => cols, 'order' => cols.map { |c| c['id'] } }
    # Relationships are only a scaffold for lookup_chain!; the finished element has none (P11).
    flat['relationships'] = Array(fact_el['relationships']).each_with_index.map do |r, i|
      { 'id' => "#{flat_id}r#{i}", 'name' => r['name'], 'targetElementId' => r['targetElementId'],
        'keys' => Array(r['keys']).map { |k| k.merge('sourceColumnId' => colmap.fetch(k['sourceColumnId'], k['sourceColumnId'])) } }
    end
    page['elements'].insert(page['elements'].index { |e| e.equal?(fact_el) } + 1, flat)

    unresolved = []
    before = Array(flat['columns']).length
    reads.each do |r|
      name, reason = lookup_chain!(dm_model, flat, r['path'], r['column'])
      unresolved << { 'field' => "#{r['table']}.#{r['column']}", 'reason' => reason } unless name
    end
    flat.delete('relationships')
    lookups = Array(flat['columns']).select { |c| lookup_target_table(c['formula']) }
    # a Lookup column the fact already had (a split child's) is not a flattening gain
    if Array(flat['columns']).length == before
      page['elements'].delete_if { |e| e.equal?(flat) }
      return { 'element' => nil, 'reason' => "no related field of #{fact_name} resolved to a Lookup chain (#{unresolved.map { |u| u['reason'] }.uniq.join('; ')})" }
    end

    # Metrics and filters travel with the element so charts that read it keep their measures and the report filters.
    flat['metrics'] = Array(fact_el['metrics']).each_with_index.map do |m, i|
      h = deep_copy_hash(m)
      h['id'] = "#{flat_id}m#{i}"
      h['formula'] = rewrite_prefixes(h['formula'], [[fact_name, flat_name]]) if h['formula'].is_a?(String)
      h
    end
    flat.delete('metrics') if flat['metrics'].empty?
    filters = Array(fact_el['filters']).each_with_index.map do |f, i|
      h = deep_copy_hash(f)
      h['id'] = "#{flat_id}f#{i}"
      h['columnId'] = colmap.fetch(f['columnId'], f['columnId']) if f['columnId']
      h
    end
    # lookup columns copied from a split child keep their ids' mapping for filters on them
    flat['filters'] = filters unless filters.empty?

    folders = []
    lookups.group_by { |c| lookup_target_table(c['formula']) }.each_with_index do |(table, members), i|
      folders << { 'id' => "#{flat_id}fo#{i}", 'name' => table, 'items' => members.map { |c| c['id'] } }
    end
    flat['folders'] = folders
    flat['order'] = Array(flat['order']) + folders.map { |f| f['id'] }
    flat['description'] = "Flattened, materializable copy of the Power BI table #{fact_name}: related columns are Lookup calc columns, so charts need no joins."
    { 'element' => flat_name, 'reason' => nil, 'lookups' => lookups.map { |c| c['name'] }, 'unresolved' => unresolved }
  end

  def deep_copy_hash(h)
    Marshal.load(Marshal.dump(h))
  end

  # Facts whose visible visuals read related fields through two or more relationships:
  #   [{'fact' => name, 'relationships_read' => [relationship names]}]
  # (a flattened child is worth it only when it removes several joins).
  def flatten_recommendations(dm_model, signals)
    out = []
    elements_of(dm_model).each do |el|
      next if Array(el['metrics']).empty? || Array(el['relationships']).empty? || el['name'].to_s.end_with?(FLATTENED_SUFFIX)
      rels = fact_related_reads(dm_model, el, el['name'], signals).flat_map { |r| r['path'] }.uniq
      out << { 'fact' => el['name'], 'relationships_read' => rels } if rels.length >= 2
    end
    out
  end

  # Element names `--materialization-cron` schedules when no `--materialization-elements` is given (R21):
  # Custom SQL elements (the summaries the mode builds and Custom SQL fact sources) and the flattened
  # children. Plain warehouse-table facts and their children are left out: materializing them was not faster.
  def materialize_targets(dm_model, log = nil)
    flat = Array(log && log['flattened']).map { |f| f['element'] }.compact
    elements_of(dm_model).select do |el|
      (el.dig('source', 'kind') == 'sql' && !literal_sql?(el.dig('source', 'statement'))) ||
        flat.include?(el['name']) || el['name'].to_s.end_with?(FLATTENED_SUFFIX)
    end.map { |el| el['name'] }.uniq
  end

  # A statement with no FROM outside string literals and quoted names (a DATATABLE turned into SELECT ... UNION ALL
  # rows) reads no base table; Snowflake refuses a dynamic table over it ("must have at least one base table").
  # Conservative: a FROM found under either reading (A: comments removed first, then literals and quoted names;
  # B: literals and quoted names only) means not literal rows, so an apostrophe inside a comment cannot hide a FROM.
  def literal_sql?(statement)
    s = statement.to_s
    no_comments = s.gsub(%r{--[^\n]*|/\*.*?\*/}m, ' ')
    reading_a = no_comments.gsub(/'(?:[^']|'')*'|"(?:[^"]|"")*"|`[^`]*`/m, ' ')
    reading_b = s.gsub(/'(?:[^']|'')*'|"(?:[^"]|"")*"/m, ' ')
    [reading_a, reading_b].none? { |t| t =~ /\bFROM\b/i }
  end


  def class_counts(classes)
    classes.values.each_with_object(Hash.new(0)) { |c, h| h[c['class']] += 1 }
  end

  # Runs every transform of the Power BI-shaped model in order and returns a JSON-serialisable log.
  #   key_results  {"<from>-><relationship>" => dup} from the warehouse key probe (applied between the
  #                relationship and classification steps); nil when the probe has not run
  #   grains       {"Table.Measure" => 'day'|'month'|'quarter'|'year'} for the axis time-intelligence forms
  #   flatten      Power BI fact names to give a `<Fact> (flattened)` child (an unknown name raises; a join-free fact is refused and logged)
  #   multi_page   false keeps one data model page (page probe P9 failed)
  #   extra_measures / slicer_carry  passed to PbiTimeIntelGen.generate! unchanged (the A/B metrics a chart at a
  #                grain also shows; the slicer-carry decision per fact, PbiSlicerCarry.decide)
  #   time_density  {fact => {grain => {'sparse','expected','present'}}} (PbiShapeRun.density_plan), also passed on: a sparse
  #                time axis moves that fact's grouped class C measures to D
  def apply!(dm_model, tmsl:, signals:, native_result: nil, dialect: 'snowflake', flatten: [], key_results: nil,
             grains: {}, multi_page: true, rekey: false, extra_measures: {}, slicer_carry: {}, time_density: {})
    require_relative 'pbi_measure_class'
    require_relative 'pbi_time_intel_gen'
    log = {}
    table_for = table_for_elements(dm_model, tmsl)
    dropped = drop_views!(dm_model)
    live = elements_of(dm_model).map { |e| e['id'] }
    log['table_for'] = { 'attributed' => table_for.keys.count { |i| live.include?(i) }, 'elements' => elements_of(dm_model).length,
                         'unattributed' => unattributed_elements(dm_model, table_for) }
    log['dropped'] = { 'elements' => dropped.to_a, 'retargeted' => dropped.retargeted,
                       'dropped_relationships' => dropped.dropped_relationships, 'unresolved' => dropped.unresolved,
                       'dangling' => dropped.dangling }
    unattributed = name_unattributed!(dm_model, tmsl, table_for)
    el_renames = rename_elements!(dm_model, table_for).merge(unattributed['renames'])
    col_renames = rename_columns!(dm_model, tmsl, table_for)
    rewrite_refs!(dm_model, el_renames, col_renames)
    log['unattributed'] = { 'named' => unattributed['named'], 'unmatched' => unattributed['unmatched'] }
    log['renames'] = { 'elements' => el_renames, 'columns' => col_renames }
    rels = relationships!(dm_model, tmsl, table_for)
    log['relationships'] = rels
    if key_results
      keys = apply_key_results!(dm_model, key_results, rekey: rekey)
      log['key_decisions'] = keys.to_a
      log['dangling_refs'] = keys.dangling
    else
      log['key_decisions'] = []
      log['dangling_refs'] = []
    end
    model = (tmsl || {})['model'] || tmsl || {}
    classes = PbiMeasureClass.classify_all(signals || {}, tmsl, Array(model['relationships']))
    b = build_missing_metrics!(dm_model, tmsl, classes)
    split = split_facts!(dm_model, classes)
    log['b_metrics'] = b
    log['splits'] = split.to_a
    log['rebuilt_a'] = b['rebuilt_a']
    log['rebuilt_a_skipped'] = b['rebuilt_a_skipped']
    filters = report_filters!(dm_model, signals, classes)
    log['filters'] = filters
    c_entries = classes.select { |_k, c| c['class'] == 'C' }
    ti_records = []
    ti_reclassified = []
    date_element_for(c_entries, tmsl).each do |date_table|
      subset = c_entries.select { |_k, c| c['class'] == 'C' && (c.dig('ti', 'date_table') || date_table) == date_table }
      next if subset.empty?
      begin
        gen = PbiTimeIntelGen.generate!(dm_model, subset, date_element: date_table, dialect: dialect, grains: grains, tmsl: tmsl,
                                     extra_measures: extra_measures, slicer_carry: slicer_carry,
                                     time_density: time_density, report_filters: filters['applied'])
        ti_records.concat(gen.to_a)
        ti_reclassified.concat(gen.reclassified)
      rescue ArgumentError => e
        subset.each do |key, c|
          reason = "C form not buildable: #{e.message}"
          c['class'] = 'D'
          c['reason'] = reason
          ti_reclassified << { 'key' => key, 'reason' => reason }
        end
      end
    end
    log['time_intel'] = ti_records
    log['flattened'] = Array(flatten).map do |name|
      res = flatten!(dm_model, name, signals)
      rec = { 'fact' => name, 'element' => res['element'], 'reason' => res['reason'] }
      rec['lookups'] = res['lookups'] if res['lookups']
      rec['unresolved'] = res['unresolved'] if res['unresolved']
      rec
    end
    log['flatten_recommendations'] = flatten_recommendations(dm_model, signals)
    log['folders'] = metric_display_folders!(dm_model, tmsl)
    log['metric_renames'] = unique_metric_names!(dm_model)
    log['metric_refs'] = qualify_metric_refs!(dm_model)
    log['blank_arith'] = blank_arith_metrics!(dm_model)
    log['descriptions'] = describe!(dm_model, tmsl, native_result)
    log['classes'] = classes
    log['class_counts'] = class_counts(classes)
    log['reclassified'] = { 'b' => b['reclassified'], 'split' => split.reclassified, 'c' => ti_reclassified }
    attach = {}
    ti_records.each do |r|
      home = classes.dig(r['measure'], 'home')
      attach[r['element']] = home if r['form'] == 'rolling_sql' && home
    end
    log['pages'] = subject_pages!(dm_model, signals: signals, classes: classes, attach: attach, multi_page: multi_page)
    log['size_stats'] = size_stats(dm_model)
    log
  end

  alias build_b_metrics! build_missing_metrics!
  module_function :build_b_metrics!
end
