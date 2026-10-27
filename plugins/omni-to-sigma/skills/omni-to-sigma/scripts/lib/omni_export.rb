# frozen_string_literal: true
# Normalize an Omni dashboard blob into tiles + layout + filters.
#
# Accepts:
#   * GET /api/unstable/documents/{id}/export (exportVersion 0.1) with
#     queryPresentationCollection.queryPresentationCollectionMemberships
#     and nested query.queryJson
#   * the v2 documents envelope (queryPresentations: {data, order})
#   * the skill fixture shape (dashboard.queryPresentations array + metadata.layouts)
#
# Layout items use react-grid-layout keys i/x/y/w/h. A 12-column board is
# scaled to Sigma's 24-column grid; a board that already spans 24 is kept.

require 'json'

module OmniExport
  module_function

  def load(path)
    normalize(JSON.parse(File.read(path, encoding: 'UTF-8')))
  end

  def normalize(doc)
    doc = {} unless doc.is_a?(Hash)
    tiles = extract_tiles(doc)
    layout = extract_layout(doc)
    filters = extract_filters(doc)
    tile_map = extract_tile_filter_map(doc)
    name = doc.dig('document', 'name') || doc.dig('dashboard', 'name') || doc['name'] || 'Omni dashboard'
    ident = doc.dig('document', 'identifier') || doc.dig('dashboard', 'identifier') || doc['identifier']
    {
      'name' => name,
      'identifier' => ident,
      'exportVersion' => doc['exportVersion'],
      'tiles' => tiles,
      'layout' => layout,
      'filters' => filters,
      'tileFilterMap' => tile_map,
      'workbookModel' => doc['workbookModel'] || {}
    }
  end

  def extract_tiles(doc)
    blobs = []
    dash = doc['dashboard'].is_a?(Hash) ? doc['dashboard'] : {}
    wb = doc['workbook'].is_a?(Hash) ? doc['workbook'] : {}
    candidates = [
      dash.dig('queryPresentationCollection', 'queryPresentationCollectionMemberships'),
      wb.dig('queryPresentationCollection', 'queryPresentationCollectionMemberships'),
      doc.dig('queryPresentationCollection', 'queryPresentationCollectionMemberships'),
      dash['queryPresentations'],
      dash.dig('metadata', 'queryPresentations'),
      wb['queryPresentations'],
      doc['queryPresentations']
    ]
    candidates.each do |node|
      blobs.concat(presentation_list(node))
    end
    blobs.uniq { |t| t['id'] }
  end

  def presentation_list(node)
    return [] if node.nil?
    rows = if node.is_a?(Array)
             node
           elsif node.is_a?(Hash) && node['data'].is_a?(Hash)
             order = node['order'].is_a?(Array) ? node['order'].map(&:to_s) : node['data'].keys
             order.map { |k| node['data'][k] || node['data'][k.to_s] }.compact
           else
             []
           end
    rows.each_with_index.map { |row, i| tile_from(row, i) }.compact
  end

  def infer_chart_type(row, vis, spec, fields)
    explicit = vis['chartType'] || row['chartType']
    return explicit unless explicit.nil? || explicit.to_s.empty?

    vis_type = vis['visType'].to_s
    return 'kpi' if vis_type == 'omni-kpi' || vis_type == 'kpi'
    return 'table' if vis_type == 'omni-table' || vis_type == 'table'
    return 'markdown' if vis_type == 'omni-markdown' || vis_type == 'markdown'

    if row['prefersChart'] == false
      return 'markdown' if fields.empty? && (spec['markdown'] || row['markdown'] || spec['text'])
      return 'table' unless fields.empty?
    end

    if spec['series'].is_a?(Array) && !spec['series'].empty?
      marks = spec['series'].map do |s|
        next nil unless s.is_a?(Hash)
        m = s['mark']
        m.is_a?(Hash) ? m['type'] : (m || s['type'])
      end.compact.map(&:to_s).uniq
      has_bar = marks.any? { |m| %w[bar column].include?(m) }
      has_line = marks.include?('line')
      return 'barLine' if has_bar && has_line
      return marks.first unless marks.empty?
    end

    mark = spec['mark']
    mark_type = mark.is_a?(Hash) ? mark['type'].to_s : mark.to_s
    unless mark_type.empty?
      if mark_type == 'bar'
        return 'columnPercent' if spec['stack'].to_s == 'normalize'
        return 'columnStacked' if spec['stack'] == true || spec['stack'].to_s == 'zero'
      end
      return 'pie' if %w[arc pie donut].include?(mark_type)
      return mark_type
    end

    nil
  end

  def tile_from(raw_row, index)
    return nil unless raw_row.is_a?(Hash)
    row = raw_row['queryPresentation'].is_a?(Hash) ? raw_row['queryPresentation'] : raw_row
    raw_query = row['query'].is_a?(Hash) ? row['query'] : {}
    query = raw_query['queryJson'].is_a?(Hash) ? raw_query['queryJson'] : raw_query
    vis = row['visConfig'].is_a?(Hash) ? row['visConfig'] : {}
    spec = vis['spec'].is_a?(Hash) ? vis['spec'] : {}
    fields = Array(query['fields']).map(&:to_s)
    chart = infer_chart_type(row, vis, spec, fields)
    id = (row['id'] || row['miniUuid'] || row['queryIdentifierMapKey'] || row['key'] || (index + 1)).to_s
    tile = {
      'id' => id,
      'name' => row['name'] || query['name'] || "Tile #{id}",
      'chartType' => chart,
      'visType' => vis['visType'],
      'fields' => fields,
      'query' => query,
      'topic' => query['join_paths_from_topic_name'] || row['topicName']
    }
    tile['miniUuid'] = row['miniUuid'].to_s if row['miniUuid']
    tile['queryIdentifierMapKey'] = row['queryIdentifierMapKey'].to_s if row['queryIdentifierMapKey']
    tile
  end

  def extract_layout(doc)
    dash = doc['dashboard'].is_a?(Hash) ? doc['dashboard'] : {}
    lg = dash.dig('metadata', 'layouts', 'lg') || dash.dig('layouts', 'lg') || doc.dig('layouts', 'lg') || []
    Array(lg).select { |item| item.is_a?(Hash) && item['i'] }
  end

  def extract_filters(doc)
    dash = doc['dashboard'].is_a?(Hash) ? doc['dashboard'] : {}
    raw = doc['filterConfig'] ||
          dash['filterConfig'] ||
          dash.dig('queryPresentationCollection', 'filterConfig') ||
          dash.dig('metadata', 'filterConfig') ||
          {}
    return [] unless raw.is_a?(Hash)
    order = dash.dig('queryPresentationCollection', 'filterOrder') ||
            dash['filterOrder'] ||
            doc['filterOrder']
    keys = if order.is_a?(Array) && !order.empty?
             (order.map(&:to_s) & raw.keys.map(&:to_s)) + (raw.keys.map(&:to_s) - order.map(&:to_s))
           else
             raw.keys.map(&:to_s)
           end
    keys.map do |fid|
      cfg = raw[fid] || raw[fid.to_sym]
      cfg = {} unless cfg.is_a?(Hash)
      {
        'id' => fid.to_s,
        'type' => (cfg['type'] || cfg['kind'] || 'text').to_s,
        'label' => cfg['label'] || cfg['name'] || fid.to_s,
        'field' => (cfg['field'] || cfg['fieldName'] || cfg['column_name']).to_s
      }
    end
  end

  def extract_tile_filter_map(doc)
    dash = doc['dashboard'].is_a?(Hash) ? doc['dashboard'] : {}
    map = dash.dig('metadata', 'tileFilterMap') || doc['tileFilterMap'] || {}
    map.is_a?(Hash) ? map : {}
  end

  # Return [col_start, col_end) on a 24-col grid, 1-indexed exclusive end.
  def grid_span(item, scale)
    x = item['x'].to_i * scale
    w = item['w'].to_i * scale
    w = 24 if w <= 0
    start_col = x + 1
    end_col = start_col + w
    end_col = 25 if end_col > 25
    [start_col, end_col]
  end

  def column_scale(layout)
    return 1 if layout.empty?
    max_edge = layout.map { |item| item['x'].to_i + item['w'].to_i }.max
    max_edge <= 12 ? 2 : 1
  end
end
