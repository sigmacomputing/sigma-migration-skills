# frozen_string_literal: true
# One Lightdash dashboard YAML + the chart YAMLs it references (by chartSlug)
# -> a normalized dashboard contract (same idea as looker-to-sigma's
# refs/dashboard-contract.md): pages, tiles, filters.
#
#   LightdashExport.load(dashboard_yml, charts_dir) ->
#     {
#       'name' => 'Jaffle Overview', 'slug' => 'jaffle-overview', 'description' => '...',
#       'pages' => [{ 'id' => 'page-1', 'name' => 'Overview', 'tab_uuid' => '...', 'order' => 0 }],
#       'tiles' => [{
#         'id' => 'total-orders-kpi',          # tileSlug | chartSlug | markdown-<n>; unique
#         'kind' => 'chart' | 'markdown' | 'sql_chart' | 'other',
#         'type' => 'saved_chart',             # raw Lightdash tile type
#         'chart_slug' => 'total-orders-kpi',  # nil for markdown
#         'chart' => { ...parsed chart YAML... } | nil (missing chart / non-chart tile),
#         'title' => 'About this dashboard', 'hide_title' => false, 'content' => '...',
#         'x' => 0, 'y' => 3, 'w' => 12, 'h' => 5,
#         'page_id' => 'page-1'
#       }],
#       'filters' => [{
#         'id' => '<uuid>', 'group' => 'dimensions' | 'metrics' | 'tableCalculations',
#         'field_id' => 'orders_region', 'table' => 'orders', 'field' => 'region',
#         'label' => nil, 'operator' => 'equals', 'values' => [...], 'settings' => {...},
#         'disabled' => false,
#         'target_tiles' => nil (= all tiles) | ['revenue-by-segment', ...],
#         'tile_fields' => { 'revenue-by-segment' => 'customers_segment' }  # per-tile fieldId overrides
#       }],
#       'warnings' => [...]
#     }
#
# Lightdash tolerance rules (the format drifts daily upstream):
#   - unknown keys are ignored; missing keys default sensibly
#   - tiles with no/unknown tabUuid land on the first page (warning if unknown)
#   - tile ids are made unique if a slug repeats
#   - filter tileTargets follows upstream Lightdash semantics: empty/absent = all tiles; a tile NOT
#     listed is targeted by default; a `false` value excludes the tile; a {fieldId, ...} entry targets
#     it (on another field if fieldId differs). Keys may be tileSlug, tile uuid or chartSlug.
#     target_tiles is nil (all) unless a tile is excluded, else every chart tile minus the excluded.
#
# Ruby 2.6-compatible, stdlib only.

require 'yaml'
require 'date'
require 'time'

module LightdashExport
  class Error < StandardError; end

  module_function

  def read_yaml(path)
    YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [Date, Time], aliases: true)
  rescue Psych::SyntaxError => e
    raise Error, "#{path}: invalid YAML (#{e.message})"
  end

  # { chartSlug => chart hash } for every *.yml / *.yaml under dir (slug key, else file basename).
  def load_charts(dir)
    out = {}
    return out if dir.nil? || !File.directory?(dir)
    Dir.glob(File.join(dir, '**', '*.{yml,yaml}')).sort.each do |path|
      doc = read_yaml(path)
      next unless doc.is_a?(Hash)
      slug = (doc['slug'] || File.basename(path).sub(/\.ya?ml\z/, '')).to_s
      out[slug] = doc
    end
    out
  end

  def load(dashboard_path, charts_dir)
    dash = read_yaml(dashboard_path)
    raise Error, "#{dashboard_path}: not a dashboard mapping" unless dash.is_a?(Hash)
    charts = load_charts(charts_dir)
    warnings = []

    pages = build_pages(dash)
    tiles = build_tiles(dash, charts, pages, warnings)
    filters = build_filters(dash, tiles, warnings)

    {
      'name' => dash['name'].to_s.empty? ? 'Lightdash Dashboard' : dash['name'].to_s,
      'slug' => dash['slug'].to_s,
      'description' => dash['description'].to_s,
      'pages' => pages,
      'tiles' => tiles,
      'filters' => filters,
      'warnings' => warnings
    }
  end

  def build_pages(dash)
    tabs = Array(dash['tabs']).select { |t| t.is_a?(Hash) }
    if tabs.empty?
      return [{ 'id' => 'page-1', 'name' => dash['name'].to_s.empty? ? 'Dashboard' : dash['name'].to_s,
                'tab_uuid' => nil, 'order' => 0 }]
    end
    sorted = tabs.each_with_index.sort_by { |t, i| [t['order'].nil? ? 1_000_000 : t['order'].to_i, i] }.map(&:first)
    sorted.each_with_index.map do |t, i|
      { 'id' => "page-#{i + 1}", 'name' => t['name'].to_s.empty? ? "Tab #{i + 1}" : t['name'].to_s,
        'tab_uuid' => t['uuid'].to_s, 'order' => i }
    end
  end

  def build_tiles(dash, charts, pages, warnings)
    used = {}
    Array(dash['tiles']).each_with_index.map do |raw, idx|
      next nil unless raw.is_a?(Hash)
      props = raw['properties'].is_a?(Hash) ? raw['properties'] : {}
      type = raw['type'].to_s
      kind = case type
             when 'saved_chart' then 'chart'
             when 'markdown' then 'markdown'
             when 'sql_chart' then 'sql_chart'
             else 'other'
             end
      chart_slug = props['chartSlug'].to_s.empty? ? nil : props['chartSlug'].to_s
      base = (raw['tileSlug'] || chart_slug || "#{kind}-#{idx + 1}").to_s
      id = base
      n = 2
      while used[id]
        id = "#{base}-#{n}"
        n += 1
      end
      used[id] = true
      page = pages.find { |p| !raw['tabUuid'].to_s.empty? && p['tab_uuid'] == raw['tabUuid'].to_s }
      if page.nil?
        if !raw['tabUuid'].to_s.empty? && pages.length > 1
          warnings << "tile #{id} references unknown tab #{raw['tabUuid']}; placed on the first page"
        end
        page = pages.first
      end
      chart = chart_slug ? charts[chart_slug] : nil
      if kind == 'chart' && chart.nil?
        warnings << "tile #{id}: chart #{chart_slug.inspect} not found under the charts dir"
      end
      {
        'id' => id, 'kind' => kind, 'type' => type, 'chart_slug' => chart_slug, 'chart' => chart,
        'title' => props['title'].to_s, 'hide_title' => props['hideTitle'] == true,
        'content' => props['content'].to_s,
        'uuid' => raw['uuid'].to_s.empty? ? nil : raw['uuid'].to_s,
        'x' => raw['x'].to_i, 'y' => raw['y'].to_i, 'w' => [raw['w'].to_i, 1].max, 'h' => [raw['h'].to_i, 1].max,
        'page_id' => page['id'], 'index' => idx
      }
    end.compact
  end

  # Resolve a tileTargets key (tileSlug | uuid | chartSlug) to a tile id.
  def resolve_tile(tiles, key)
    k = key.to_s
    t = tiles.find { |x| x['id'] == k } ||
        tiles.find { |x| x['uuid'] == k } ||
        tiles.find { |x| x['chart_slug'] == k }
    t && t['id']
  end

  def build_filters(dash, tiles, warnings)
    f = dash['filters'].is_a?(Hash) ? dash['filters'] : {}
    out = []
    %w[dimensions metrics tableCalculations].each do |group|
      Array(f[group]).each do |raw|
        next unless raw.is_a?(Hash)
        target = raw['target'].is_a?(Hash) ? raw['target'] : {}
        field_id = target['fieldId'].to_s
        field_id = [target['tableName'], target['fieldName']].compact.join('_') if field_id.empty?
        targets = raw['tileTargets']
        target_tiles = nil
        tile_fields = {}
        # Upstream semantics (Lightdash dashboard filters): a tile NOT listed in tileTargets is targeted by
        # default; `false` excludes a tile; a {fieldId, ...} entry targets it (possibly on another field).
        # So target_tiles is nil (every chart tile) unless some tile is explicitly excluded.
        if targets.is_a?(Hash) && !targets.empty?
          excluded = []
          targets.each do |key, val|
            tid = resolve_tile(tiles, key)
            if tid.nil?
              warnings << "filter #{raw['id']}: tileTargets key #{key.inspect} matches no tile"
              next
            end
            if val == false
              excluded << tid
            elsif val.is_a?(Hash) && !val['fieldId'].to_s.empty? && val['fieldId'].to_s != field_id
              tile_fields[tid] = val['fieldId'].to_s
            end
          end
          unless excluded.empty?
            target_tiles = tiles.select { |t| t['kind'] == 'chart' }.map { |t| t['id'] } - excluded
          end
        end
        out << {
          'id' => (raw['id'] || "filter-#{out.length + 1}").to_s, 'group' => group,
          'field_id' => field_id, 'table' => target['tableName'].to_s, 'field' => target['fieldName'].to_s,
          'label' => raw['label'].to_s.empty? ? nil : raw['label'].to_s,
          'operator' => raw['operator'].to_s, 'values' => Array(raw['values']),
          'settings' => raw['settings'].is_a?(Hash) ? raw['settings'] : {},
          'disabled' => raw['disabled'] == true,
          'target_tiles' => target_tiles, 'tile_fields' => tile_fields
        }
      end
    end
    out
  end
end
