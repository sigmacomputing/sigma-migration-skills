# frozen_string_literal: true
#
# dm_column_index.rb — the data-model COLUMN INDEX carried in dm-readback.json.
#
# The workbook builder has to know which columns a data-model element REALLY exposes
# (display labels, which Sigma disambiguates with relationship suffixes on join legs)
# and what type each has (Sigma strips a `list` control bound to a datetime column).
# Both readback paths — the new-model post-and-readback.rb and the --reuse-dm synthesis
# in migrate-quicksight.rb — therefore stamp, per data-model element:
#
#   columnLabels : [label, ...]            display labels in API order (existing contract
#                                          read by build-workbook-from-quicksight.rb)
#   columnTypes  : { label => value_type } Sigma value type — text / number / integer /
#                                          datetime / boolean / variant / link / error
#   columnSources: { label => [key, ...] }  the column's SOURCE reference keys: the last
#                                          segment of a passthrough `[TABLE/COLUMN]` formula
#                                          and the tail of its column id — how a QuickSight
#                                          dataset column is matched to the label the model
#                                          gave it (the display name may be anything)
#
# from GET /v2/dataModels/{id}/columns (entries: elementId, columnId, label, formula,
# type.type). Callers fetch with Sigma.list_entries so every page is read: the default
# page is 50, and a first-page read silently truncates wide models.
#
# QuickSight-local (not a shared/ file).
module DmColumnIndex
  module_function

  # Sigma's column value type for an /columns entry (`type: {type: 'datetime'}`), or nil.
  def entry_type(entry)
    t = entry['type']
    t = t['type'] if t.is_a?(Hash)
    t.is_a?(String) && !t.empty? ? t.downcase : nil
  end

  # Stamp columnLabels / columnTypes onto each readback element that has /columns entries.
  # Mutates and returns `readback`. Entries for elements absent from the readback are
  # ignored; an element with no entries is left exactly as it was.
  def enrich_readback!(readback, entries)
    by_element = Hash.new { |h, k| h[k] = [] }
    Array(entries).each do |e|
      next unless e.is_a?(Hash) && e['elementId'] && e['label'].to_s != ''
      by_element[e['elementId']] << e
    end
    return readback if by_element.empty?
    Array(readback['pages']).each do |page|
      Array(page['elements']).each do |el|
        next unless el.is_a?(Hash) && by_element.key?(el['id'])
        labels = []
        types = {}
        sources = {}
        by_element[el['id']].each do |e|
          label = e['label'].to_s
          next if types.key?(label) # keep the first when a label repeats
          labels << label
          types[label] = entry_type(e)
          keys = source_keys(e)
          sources[label] = keys unless keys.empty?
        end
        el['columnLabels'] = labels
        el['columnTypes'] = types.reject { |_l, t| t.nil? }
        el['columnSources'] = sources unless sources.empty?
      end
    end
    readback
  end

  # Source-reference keys of a /columns entry: last segment of a passthrough `[A/B/COL]`
  # formula, and the tail of the column id (`inode-x/COL` -> COL). Calculated columns have
  # no passthrough source and contribute only their id.
  def source_keys(entry)
    keys = []
    f = entry['formula'].to_s
    if (m = f.match(/\A\s*\[([^\[\]]+)\]\s*\z/))
      keys << m[1].split('/').last
    end
    id = entry['columnId'].to_s
    keys << id.split('/').last unless id.empty?
    keys.compact.map(&:strip).reject(&:empty?).uniq
  end

  # Sigma value type of `label` on a readback element, or nil when the index has none.
  def type_of(element, label)
    types = element.is_a?(Hash) ? element['columnTypes'] : nil
    t = types.is_a?(Hash) ? types[label] : nil
    t.is_a?(String) ? t.downcase : nil
  end

  # Display labels of a readback element: columnLabels plus any named spec columns.
  def labels_of(element)
    return [] unless element.is_a?(Hash)
    ((element['columnLabels'] || []) + (element['columns'] || []).map { |c| c.is_a?(Hash) ? c['name'] : nil }).compact.uniq
  end

  # Resolves a QuickSight dataset column name to the label the data-model element gives
  # that column. NO fuzzy matching — only these exact-after-normalisation rules (normalise =
  # lower-case, drop everything but letters/digits):
  #   1. the column's SOURCE reference / column id equals the name  (the model may have
  #      renamed the column to anything; its source still names the warehouse column)
  #   2. the display label equals the name
  # More than one candidate is narrowed by the caller's preferred label (the converter's own
  # display-name formatting) and otherwise reported :ambiguous. Statuses:
  #   :resolved    -> [label, :resolved]
  #   :missing     -> [nil, :missing]     the index exists and has no such column
  #   :ambiguous   -> [nil, :ambiguous]
  #   :unverified  -> [prefer || raw, :unverified]   the element has NO column index at all
  #                   (legacy readbacks) — the caller keeps its own display-name guess
  class Resolver
    def initialize(element)
      @labels = DmColumnIndex.labels_of(element)
      @by_source = Hash.new { |h, k| h[k] = [] }
      @by_label = Hash.new { |h, k| h[k] = [] }
      el = element.is_a?(Hash) ? element : {}
      (el['columnSources'] || {}).each { |label, keys| Array(keys).each { |k| add_source(k, label) } }
      (el['columns'] || []).each do |c|
        next unless c.is_a?(Hash) && c['name'].to_s != ''
        add_source(c['id'].to_s.split('/').last, c['name'])
        add_source(DmColumnIndex.source_keys('formula' => c['formula']).first, c['name'])
      end
      @labels.each { |l| @by_label[Resolver.norm(l)] << l }
    end

    def self.norm(s)
      s.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end

    def indexed?
      !@labels.empty? || !@by_source.empty?
    end

    def labels
      @labels.dup
    end

    def resolve(raw, prefer: nil)
      return [prefer || raw.to_s, :unverified] unless indexed?
      n = Resolver.norm(raw)
      cands = (@by_source.key?(n) ? @by_source[n] : []).uniq
      if cands.size > 1
        narrowed = cands.select { |l| Resolver.norm(l) == n }
        narrowed = cands.select { |l| l == prefer } if narrowed.size != 1 && prefer
        cands = narrowed if narrowed.size == 1
      end
      return [cands.first, :resolved] if cands.size == 1
      return [nil, :ambiguous] if cands.size > 1
      lab = (@by_label.key?(n) ? @by_label[n] : []).uniq
      return [lab.first, :resolved] if lab.size == 1
      return [nil, :ambiguous] if lab.size > 1
      [nil, :missing]
    end

    private

    def add_source(key, label)
      n = Resolver.norm(key)
      @by_source[n] << label unless n.empty? || @by_source[n].include?(label)
    end
  end
end
