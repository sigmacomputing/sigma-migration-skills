#!/usr/bin/env ruby
# frozen_string_literal: true
# One Lightdash dashboard (+ its charts) -> Sigma workbook spec.
#
#   ruby scripts/build-lightdash-workbook.rb \
#     --dashboard fixtures/jaffle-orders/lightdash/dashboards/jaffle-overview.yml \
#     --charts-dir fixtures/jaffle-orders/lightdash/charts \
#     --dm-envelope dm.json --field-map field-map.json --dm-id <data-model-id> \
#     --out wb.json [--workbook-map-out workbook-map.json] \
#     [--dm-lookup dm-lookup.json] [--folder-id F]
#
# Inputs from convert-dm.rb: the DM envelope (explore element name, metric formulas) and
# field-map.json (Lightdash fieldId -> Sigma column / metric names; never re-derived here).
# --dm-lookup is the post-lightdash-dm.rb lookup (authoring ids -> live ids); without it the
# authoring element id is used and a warning says so.
#
# Output (next to --out):
#   wb.json              {workbook: {name, folderId?, document}, stats, warnings, gaps}
#   workbook-map.json    {"<chartSlug>": {element_id, page_id, kind, fields: [fieldId...], ...}} (parity interface)
#   chart-gaps.json      {gaps: degradation-ledger entries (class/item/reason/source_artifact), notes: [{item, reason}]}
#   control-scope.json   control-lint sidecar (limited-scope controls list the elements they intend to reach)
#
# Charts source from a hidden master table on the Data page (itself sourced from the DM explore element);
# tileTargets-limited controls get hidden base tables (see build_controls) because Sigma rejects control targets that are charts. Dimension columns are `[<source table>/<Column>]`;
# DM metrics are `[Metrics/<name>]` (kpi-chart inlines the
# aggregate instead: preflight K1 rejects a bare-ref value column).
# Layout XML is attached LAST (after every element id is final); a later spec PUT that omits it
# wipes it. Lints (layout, control, preflight) must pass or the script exits non-zero.
#
# Creds-free. Ruby 2.6-compatible, stdlib only.

require 'json'
require 'optparse'
require 'time'
require_relative 'lib/ruby_compat'
require_relative 'lib/degradation_ledger'
require_relative 'lib/lightdash_ledger'
require_relative 'lib/code_rep'
require_relative 'lib/layout_lint'
require_relative 'lib/control_lint'
require_relative 'lib/preflight_lint'
require_relative 'lib/lightdash_formula'
require_relative 'lib/lightdash_export'
require_relative 'lib/lightdash_chart_map'
require_relative 'lib/lightdash_wb_columns'
require_relative 'lib/lightdash_wb_filters'

module LightdashWorkbook
  # Lightdash dashboards are laid out on a 36-column grid. UNVERIFIED upstream (research
  # file marks it "believed"); change it here only.
  LIGHTDASH_GRID_COLS = 36
  SIGMA_GRID_COLS = 24
  # Lightdash's default result row limit; a dimension-sorted chart at the default limit is a
  # safety cap, not an author choice, so a non-applied cap is a warning, not a ledger entry.
  LIGHTDASH_DEFAULT_LIMIT = 500
  SOURCE = 'build-lightdash-workbook'
  # placeholder prefix on chart column formulas; emit rewrites it to the chart's source table
  SRC = '@SRC@'
  MASTER_NAME = 'Lightdash Data'
  LF = LightdashFormula
  CM = LightdashChartMap

  class Missing < StandardError; end

  # A chart element under construction. `columns` is shared with the emitted element hash so
  # filter-only columns appended later (dashboard controls) land in the spec.
  class El
    attr_reader :id, :tile, :chart, :columns, :by_key, :cls
    attr_accessor :hash
    def initialize(id, tile, chart, cls)
      @id = id
      @tile = tile
      @chart = chart
      @cls = cls
      @columns = []
      @by_key = {}
      @hash = nil
    end

    def add(key, col)
      @by_key[key] = col
      @columns << col
      col
    end
  end

  module_function

  def sanitize(s)
    s.to_s.gsub(/[^A-Za-z0-9_-]+/, '-').gsub(/\A-+|-+\z/, '')
  end

  # Lightdash grid x/w -> Sigma 1-based gridColumn span. Both edges go through the same
  # function so neighbouring tiles share boundaries (no rounding gaps/overlaps).
  def scale_cols(x, w)
    edge = ->(v) { (v * SIGMA_GRID_COLS.to_f / LIGHTDASH_GRID_COLS).round }
    c0 = [[edge.call(x), 0].max, SIGMA_GRID_COLS - 1].min
    c1 = [[edge.call(x + w), c0 + 1].max, SIGMA_GRID_COLS].min
    [c0 + 1, c1 + 1]
  end

  class Builder
    include LightdashWbColumns
    include LightdashWbFilters

    attr_reader :gaps, :warnings, :notes

    def initialize(dash, field_map, envelope, dm_id:, dm_lookup: nil, folder_id: nil)
      @dash = dash
      @fm = field_map
      @env = envelope
      @dm_id = dm_id
      @folder_id = folder_id
      @gaps = []
      @notes = []          # presentation/verification caveats: never ledger entries (see note!)
      @warnings = (dash['warnings'] || []).dup
      @els = []            # [El | {text element}] in tile order
      @tile_el = {}        # tile id -> El
      @controls = []
      @control_scope = []
      @map = {}
      @styling_noted = false
      resolve_dm(dm_lookup)
    end

    def sanitize(s)
      LightdashWorkbook.sanitize(s)
    end

    def gap!(cls, item, reason)
      @gaps << DegradationLedger.entry(cls, item, reason, SOURCE)
    end

    # Presentation-only differences and verification caveats: recorded under `notes` in chart-gaps.json and in
    # the warnings, but NOT in the degradation ledger (they never block GREEN). Data, grain, filter, sort,
    # limit, RLS and dropped-item changes stay gap! entries.
    def note!(item, reason)
      @notes << { 'item' => item.to_s, 'reason' => reason.to_s }
      warn!("#{item}: #{reason}")
    end

    def warn!(msg)
      @warnings << msg
    end

    # --- DM addressing ------------------------------------------------------
    def resolve_dm(lookup)
      first = @fm.values.find { |v| v.is_a?(Hash) && v['kind'] != 'skipped' && v['element_id'] }
      @dm_authoring_el = first && first['element_id']
      elements = @env.dig('sigmaDataModel', 'pages', 0, 'elements') || []
      @dm_el = elements.find { |e| e['id'] == @dm_authoring_el } || {}
      @dm_name = @dm_el['name'].to_s
      @dm_live_el = @dm_authoring_el
      key = @dm_authoring_el.to_s.sub(/\Ael-/, '')
      if lookup.is_a?(Hash) && lookup[key].is_a?(Hash)
        @dm_live_el = lookup[key]['elementId'] || @dm_authoring_el
        @dm_name = lookup[key]['name'] || @dm_name
      else
        warn!('no --dm-lookup: using authoring element id; re-run with the post-lightdash-dm.rb lookup to bind the live element id')
      end
      raise Missing, 'field-map has no mapped fields' if @dm_authoring_el.nil?
    end

    def source
      { 'kind' => 'data-model', 'dataModelId' => @dm_id, 'elementId' => @dm_live_el }
    end

    # --- chart building -------------------------------------------------------
    def build
      page_ids = @dash['pages'].map { |p| p['id'] }
      @dash['tiles'].each { |t| build_tile(t) }
      build_controls
      emit(page_ids)
    end

    def build_tile(t)
      case t['kind']
      when 'markdown' then text_tile(t, markdown_body(t), markdown_name(t))
      when 'chart'
        if t['chart'].nil?
          placeholder(t, "chart #{t['chart_slug'].inspect} was not found in the export", 'scope-cut')
        else
          build_chart(t)
        end
      else
        placeholder(t, "Lightdash #{t['type']} tile has no Sigma conversion in this skill", 'scope-cut')
      end
    end

    def markdown_body(t)
      title = t['hide_title'] || t['title'].empty? ? nil : "### #{t['title']}"
      [title, t['content']].compact.join("\n\n")
    end

    # Stable element name for a markdown tile: its title, else "Notes" / "Notes <n>".
    def markdown_name(t)
      return t['title'] unless t['title'].to_s.empty?
      @md_count = (@md_count || 0) + 1
      @md_count == 1 ? 'Notes' : "Notes #{@md_count}"
    end

    def text_tile(t, body, name = nil)
      id = "el-#{sanitize(t['id'])}"
      h = { 'id' => id, 'kind' => 'text', 'body' => body }
      h['name'] = name if name
      @els << { 'tile' => t, 'hash' => h }
    end

    def placeholder(t, reason, cls)
      name = t['chart'] ? t['chart']['name'].to_s : (t['title'].empty? ? t['chart_slug'].to_s : t['title'])
      gap!(cls, "tile #{t['id']} (#{name})", reason)
      body = "**#{name}**\n\n_Not migrated: #{reason}._"
      text_tile(t, body)
      return unless t['chart_slug']
      @map[map_key(t['chart_slug'])] = { 'element_id' => "el-#{sanitize(t['id'])}", 'page_id' => t['page_id'],
                                         'kind' => 'text', 'fields' => [], 'placeholder' => true,
                                         'tile_id' => t['id'], 'chart_name' => name, 'reason' => reason }
    end

    def map_key(slug)
      return slug unless @map.key?(slug)
      n = 2
      n += 1 while @map.key?("#{slug}##{n}")
      "#{slug}##{n}"
    end

    def build_chart(t)
      chart = t['chart']
      slug = t['chart_slug']
      cls = CM.classify(chart)
      return placeholder(t, cls['gap'], 'scope-cut') if cls['kind'].nil?
      mq = CM.metric_query(chart)
      explore = mq['exploreName'] || chart['tableName']
      if explore && @env['explore'] && explore.to_s != @env['explore'].to_s
        return placeholder(t, "chart queries explore #{explore.inspect}, but the data model was built for #{@env['explore'].inspect}", 'scope-cut')
      end

      el = El.new("el-#{sanitize(t['id'])}", t, chart, cls)
      name = !t['title'].empty? && !t['hide_title'] ? t['title'] : chart['name'].to_s
      name = slug.to_s if name.strip.empty?
      t['hide_title'] && warn!("tile #{t['id']}: hideTitle is not carried over (the Sigma element keeps its title)")
      hash =
        case cls['kind']
        when 'kpi-chart' then kpi(el, mq, cls, name)
        when 'table' then table(el, mq, cls, name)
        when 'pivot-table' then pivot(el, mq, cls, name)
        when 'pie-chart', 'donut-chart' then pie(el, mq, cls, name)
        when 'funnel-chart' then funnel(el, mq, name)
        else cartesian(el, mq, cls, name)
        end
      return placeholder(t, hash, 'scope-cut') if hash.is_a?(String)

      el.hash = hash
      hash['columns'] = el.columns
      apply_filters(el, mq, hash, slug)
      apply_limit(el, mq, hash, slug)
      cls['notes'].each { |n| gap!('quality-waiver', "chart #{slug}", n) }
      note_styling if cls['kind'] != 'table' && cls['kind'] != 'pivot-table'
      @els << { 'tile' => t, 'el' => el, 'hash' => hash }
      @tile_el[t['id']] = el
      register(el, mq, slug)
    rescue Missing => e
      placeholder(t, e.message, 'scope-cut')
    end

    def note_styling
      return if @styling_noted
      @styling_noted = true
      note!('ECharts styling', 'series colors, axis titles/labels, legends, smoothing and other ECharts styling are not carried over (Sigma theme defaults apply)')
    end

    def register(el, mq, slug)
      fields = Array(mq['dimensions']) + Array(mq['metrics']) + Array(mq['tableCalculations']).map { |c| c['name'].to_s }
      fields = fields.select { |f| el.by_key.key?(f) }
      cols = {}
      el.by_key.each { |fid, c| cols[fid] = { 'id' => c['id'], 'name' => c['name'] } }
      @map[map_key(slug)] = {
        'element_id' => el.id, 'page_id' => el.tile['page_id'], 'kind' => el.hash['kind'], 'fields' => fields,
        'tile_id' => el.tile['id'], 'chart_name' => el.hash['name'], 'columns' => cols,
        'limit' => mq['limit'], 'sorts' => Array(mq['sorts']).map { |s| { 'fieldId' => s['fieldId'], 'descending' => s['descending'] == true } }
      }
    end

    # y/x channel helpers ------------------------------------------------------
    def cartesian(el, mq, cls, name)
      slug = el.tile['chart_slug']
      dims = Array(mq['dimensions']).map(&:to_s)
      pivot = cls['pivot']
      x_fid = cls['x_field'] || (dims - pivot).first
      return "#{cls['kind']} has no x-axis dimension" if x_fid.nil?
      xcol = try_col(el, x_fid, slug)
      return "x-axis field #{x_fid} could not be mapped" unless xcol
      fm = @fm[x_fid]
      if cls['kind'] == 'scatter-chart' && fm && fm['kind'] == 'metric'
        return 'a scatter with a measure on the x-axis needs a grouped source table (not built)'
      end
      y_fids = cls['y_fields'].empty? ? Array(mq['metrics']).map(&:to_s) + Array(mq['tableCalculations']).map { |c| c['name'].to_s } : cls['y_fields']
      ycols = y_fids.map { |f| [f, try_col(el, f, slug)] }.select { |_, c| c }
      return 'no y-axis measure could be mapped' if ycols.empty?
      color = nil
      pivot.each_with_index do |p, i|
        next if p == x_fid
        if i.zero? || color.nil?
          pc = try_col(el, p, slug)
          color = { 'by' => 'category', 'column' => pc['id'] } if pc
        else
          gap!('quality-waiver', "chart #{slug}", "pivot dimension #{p} dropped (Sigma charts take one category split)")
        end
      end
      (dims - pivot - [x_fid]).each do |d|
        gap!('quality-waiver', "chart #{slug}", "dimension #{d} is in the query grain but is not plotted in the Sigma chart")
      end
      h = { 'id' => el.id, 'kind' => cls['kind'], 'name' => name, 'source' => source }
      ids = ycols.map { |f, c| cls['kind'] == 'combo-chart' ? { 'columnId' => c['id'], 'type' => cls['series_types'][f] || 'bar' } : c['id'] }
      h['xAxis'] = { 'columnId' => xcol['id'] }
      h['yAxis'] = { 'columnIds' => ids }
      if cls['secondary'].any?
        sec = ycols.select { |f, _| cls['secondary'].include?(f) }.map { |_, c| c['id'] }
        h['yAxis2'] = { 'columnIds' => sec } unless sec.empty?
      end
      h['color'] = color if color
      h['stacking'] = cls['stacking'] if cls['stacking']
      h['orientation'] = cls['orientation'] if cls['orientation']
      sorts = Array(mq['sorts'])
      if (s = sorts.first) && (sc = el.by_key[s['fieldId']])
        h['xAxis']['sort'] = { 'by' => sc['id'], 'direction' => s['descending'] == true ? 'descending' : 'ascending' }
      elsif sorts.any?
        gap!('quality-waiver', "chart #{slug}", "sort on #{sorts.first['fieldId']} not applied (field is not plotted)")
      end
      sorts.drop(1).each { |s| gap!('quality-waiver', "chart #{slug}", "secondary sort on #{s['fieldId']} not applied (Sigma charts sort on one column)") }
      h
    end

    def kpi(el, mq, cls, name)
      slug = el.tile['chart_slug']
      cfg = el.chart.dig('chartConfig', 'config') || {}
      fid = cfg['selectedField'].to_s
      fid = (Array(mq['metrics']) + Array(mq['tableCalculations']).map { |c| c['name'].to_s }).first.to_s if fid.empty?
      return 'big number has no selected field' if fid.empty?
      col = try_col(el, fid, slug, inline: true)
      return "big-number field #{fid} could not be mapped" unless col
      label = cfg['label'].to_s.strip
      col['name'] = label unless label.empty?
      note!("chart #{slug}", 'big-number comparison is not carried over') if cfg['showComparison'] == true
      { 'id' => el.id, 'kind' => 'kpi-chart', 'name' => name, 'source' => source, 'value' => { 'columnId' => col['id'] } }
    end

    def pie(el, mq, cls, name)
      slug = el.tile['chart_slug']
      cfg = el.chart.dig('chartConfig', 'config') || {}
      groups = Array(cfg['groupFieldIds']).map(&:to_s)
      groups = Array(mq['dimensions']).map(&:to_s) if groups.empty?
      mid = cfg['metricId'].to_s
      mid = Array(mq['metrics']).first.to_s if mid.empty?
      return 'pie chart has no dimension' if groups.empty?
      return 'pie chart has no metric' if mid.empty?
      cc = try_col(el, groups.first, slug)
      vc = try_col(el, mid, slug)
      return 'pie chart fields could not be mapped' unless cc && vc
      groups.drop(1).each { |g| gap!('quality-waiver', "chart #{slug}", "group field #{g} dropped (Sigma pie/donut takes one category)") }
      color = { 'columnId' => cc['id'] }
      s = Array(mq['sorts']).first
      if s && (sc = el.by_key[s['fieldId']])
        color['sort'] = { 'by' => sc['id'], 'direction' => s['descending'] == true ? 'descending' : 'ascending' }
      end
      { 'id' => el.id, 'kind' => el.cls['kind'], 'name' => name, 'source' => source,
        'value' => { 'columnId' => vc['id'] }, 'color' => color }
    end

    def funnel(el, mq, name)
      slug = el.tile['chart_slug']
      dims = Array(mq['dimensions']).map(&:to_s)
      mets = Array(mq['metrics']).map(&:to_s)
      return 'funnel needs one dimension and one metric' if dims.empty? || mets.empty?
      sc = try_col(el, dims.first, slug)
      vc = try_col(el, mets.first, slug)
      return 'funnel fields could not be mapped' unless sc && vc
      gap!('quality-waiver', "chart #{slug}", 'funnel stage and series taken from the first dimension and metric (Lightdash funnel config is not read)')
      { 'id' => el.id, 'kind' => 'funnel-chart', 'name' => name, 'source' => source,
        'stage' => { 'columnId' => sc['id'] }, 'series' => { 'columnId' => vc['id'] } }
    end

    # Ordered fieldIds for a table/pivot: tableConfig.columnOrder, then anything missing.
    def table_fields(el, mq)
      all = Array(mq['dimensions']).map(&:to_s) + Array(mq['metrics']).map(&:to_s) + Array(mq['tableCalculations']).map { |c| c['name'].to_s }
      order = Array(el.chart.dig('tableConfig', 'columnOrder')).map(&:to_s) & all
      order + (all - order)
    end

    def table_cols(el, mq, slug)
      cfg = el.chart.dig('chartConfig', 'config', 'columns')
      cfg = {} unless cfg.is_a?(Hash)
      table_fields(el, mq).each_with_object([]) do |fid, out|
        col = try_col(el, fid, slug)
        next unless col
        c = cfg[fid]
        if c.is_a?(Hash)
          col['name'] = c['name'].to_s if !c['name'].to_s.empty?
          col['hidden'] = true if c['visible'] == false
        end
        out << [fid, col]
      end
    end

    def sort_entries(el, mq)
      Array(mq['sorts']).map do |s|
        c = el.by_key[s['fieldId']]
        c && { 'columnId' => c['id'], 'direction' => s['descending'] == true ? 'descending' : 'ascending' }
      end.compact
    end

    def table(el, mq, _cls, name)
      slug = el.tile['chart_slug']
      cols = table_cols(el, mq, slug)
      return 'no table column could be mapped' if cols.empty?
      dims = Array(mq['dimensions']).map(&:to_s)
      groupby = cols.select { |f, _| dims.include?(f) }.map { |_, c| c['id'] }
      calcs = cols.reject { |f, _| dims.include?(f) }.map { |_, c| c['id'] }
      h = { 'id' => el.id, 'kind' => 'table', 'name' => name, 'source' => source }
      sorts = sort_entries(el, mq)
      if !groupby.empty?
        # dimensions only (no metric): groupBy without calculations gives the distinct rows
        # Lightdash returns (looker's builder creates groupBy-first groupings the same way)
        g = { 'id' => 'grp-1', 'groupBy' => groupby }
        g['calculations'] = calcs unless calcs.empty?
        g['sort'] = sorts unless sorts.empty?
        h['groupings'] = [g]
      elsif !sorts.empty?
        h['sort'] = sorts
      end
      h
    end

    def pivot(el, mq, cls, name)
      slug = el.tile['chart_slug']
      cols = table_cols(el, mq, slug)
      dims = Array(mq['dimensions']).map(&:to_s)
      pv = cls['pivot']
      rows = cols.select { |f, _| dims.include?(f) && !pv.include?(f) }.map { |_, c| { 'columnId' => c['id'] } }
      cols_by = cols.select { |f, _| pv.include?(f) }.map { |_, c| { 'columnId' => c['id'] } }
      values = cols.reject { |f, _| dims.include?(f) }.map { |_, c| c['id'] }
      return 'pivot table needs a row dimension and a value' if rows.empty? || values.empty?
      s = Array(mq['sorts']).first
      if s && (sc = el.by_key[s['fieldId']]) && (shelf = rows.find { |r| r['columnId'] == sc['id'] })
        shelf['sort'] = { 'direction' => s['descending'] == true ? 'descending' : 'ascending' }
      elsif s
        gap!('quality-waiver', "chart #{slug}", "sort on #{s['fieldId']} not applied to the pivot")
      end
      h = { 'id' => el.id, 'kind' => 'pivot-table', 'name' => name, 'source' => source,
            'values' => values, 'rowsBy' => rows }
      h['columnsBy'] = cols_by unless cols_by.empty?
      h
    end

    # --- dashboard filters -> controls ----------------------------------------------
    # Sigma rejects control `filters[]` targets that are charts/KPIs (400 "Dependency not
    # found", live-verified; looker-to-sigma refs/control-parity.md). So controls target hidden
    # TABLE elements on the Data page:
    #   - one master table (sourced from the DM element) with a passthrough column for every
    #     field the dashboard uses; charts source from it, all-tiles controls target it
    #   - a tileTargets-limited control gets a hidden base table (sourced from the master) shared
    #     by exactly the charts that control targets; those charts are re-sourced through it and
    #     the control targets only that base table. A chart covered by several limited controls
    #     gets one base table per distinct control set (each control targets every base table it
    #     appears in).
    def build_controls
      @pending = []
      @dash['filters'].each_with_index { |f, i| build_control(f, i) }
    end

    def build_control(flt, idx)
      fid = flt['field_id']
      item = "dashboard filter #{fid}"
      if flt['group'] != 'dimensions'
        gap!('scope-cut', item, "#{flt['group']} filters are not translated (they apply after aggregation)")
        return
      end
      fm = @fm[fid]
      if fm.nil? || fm['kind'] == 'skipped' || fm['kind'] == 'metric'
        gap!('scope-cut', item, fm && fm['reason'] ? "field was skipped by the data model (#{fm['reason']})" : "field #{fid} is not a mapped dimension")
        return
      end
      ctype, attrs, why = control_shape(flt, fm)
      if ctype.nil?
        gap!('scope-cut', item, "#{why}; control skipped")
        return
      end
      gap!('quality-waiver', item, "#{why}; control created without a default selection") if why
      tiles = nil
      if flt['target_tiles']
        note!(item, 'tileTargets: tiles not listed are filtered by default and `false` tiles are excluded (Lightdash semantics, not verified against a live instance)')
        tiles = flt['target_tiles'].map { |tid| @tile_el[tid] }
        flt['target_tiles'].each { |tid| warn!("filter #{fid}: target tile #{tid} has no Sigma chart element (placeholder or markdown)") if @tile_el[tid].nil? }
        tiles = tiles.compact
        if tiles.empty?
          gap!('scope-cut', item, 'no chart element could be wired to this filter; control skipped')
          return
        end
      elsif @tile_el.empty?
        gap!('scope-cut', item, 'the dashboard has no chart element to filter; control skipped')
        return
      end
      unless flt['tile_fields'].empty?
        gap!('quality-waiver', item, "per-tile field overrides (#{flt['tile_fields'].inspect}) are not carried; every targeted chart is filtered on #{fid}")
      end
      eid = "ctl-#{sanitize(fid)}"
      eid = "#{eid}-#{idx + 1}" if @pending.any? { |c| c['ctl']['id'] == eid }
      cid = eid.tr('-', '_') # formula handle, distinct from the element id
      ctl = { 'id' => eid, 'kind' => 'control', 'controlId' => cid, 'name' => flt['label'] || fm['name'], 'controlType' => ctype }
      ctl.merge!(attrs)
      @pending << { 'ctl' => ctl, 'tiles' => tiles, 'fname' => fm['name'], 'list' => ctype == 'list', 'limited' => !flt['target_tiles'].nil? }
      entry = { 'controlId' => cid, 'sourceName' => ctl['name'] }
      entry['scope'] = tiles.map(&:id) if tiles
      @control_scope << entry
      record_applied_filter(flt, ctl, tiles)
    end

    # Parity interface: the dashboard filters that reach each chart as a control WITH a default
    # (disabled, gapped and default-less controls are excluded), so the oracle can apply them.
    def record_applied_filter(flt, ctl, tiles)
      has_default = !flt['disabled'] && (Array(ctl['values']).any? || ctl['date'] || ctl['startDate'] || ctl['low'] || ctl['high'])
      return unless has_default
      ids = tiles ? tiles.map(&:id) : @tile_el.values.compact.map(&:id)
      rule = { 'fieldId' => flt['field_id'], 'operator' => flt['operator'], 'values' => Array(flt['values']) }
      @map.each_value do |m|
        next if m['placeholder'] || !ids.include?(m['element_id'])
        (m['applied_filters'] ||= []) << rule
      end
    end

    CTL_COL = ->(prefix, name) { "#{prefix}-#{LightdashWorkbook.sanitize(name)}" }

    # Resolve the source tables, rewrite chart column prefixes, wire controls. Returns the
    # hidden-page table elements.
    def build_tables
      limited = @pending.select { |p| p['limited'] }
      sigs = Hash.new { |h, k| h[k] = [] }   # chart element id -> [control ids]
      limited.each { |p| p["tiles"].each { |el| sigs[el.id] << p["ctl"]["id"] } }
      groups = {}                            # signature -> {id, name, els, ctls}
      sigs.each do |eid, ids|
        key = ids.sort
        g = (groups[key] ||= { 'id' => "tbl-base-#{groups.length + 1}", 'name' => "Lightdash Base #{groups.length + 1}", 'els' => [], 'ctls' => key })
        g['els'] << eid
      end
      master = { 'id' => 'tbl-master', 'name' => MASTER_NAME }
      src_of = {}
      groups.each_value { |g| g['els'].each { |eid| src_of[eid] = g } }
      names = { master['id'] => [] }
      groups.each_value { |g| names[g['id']] = [] }
      @els.each do |e|
        el = e['el']
        next unless el
        src = src_of[el.id] || master
        el.hash['source'] = { 'kind' => 'table', 'elementId' => src['id'] }
        used = []
        el.columns.each do |c|
          c['formula'] = c['formula'].gsub(%r{\[#{Regexp.escape(SRC)}/([^\]]+)\]}) do
            used << Regexp.last_match(1)
            "[#{src['name']}/#{Regexp.last_match(1)}]"
          end
        end
        names[src['id']].concat(used)
        e['source_id'] = src['id']
      end
      tables = []
      # filter columns first so every control column exists on every table it targets
      groups.each_value { |g| g['ctls'].each { |cid| names[g['id']] << @pending.find { |p| p['ctl']['id'] == cid }['fname'] } }
      @pending.reject { |p| p['limited'] }.each { |p| names[master['id']] << p['fname'] }
      base_names = groups.values.flat_map { |g| names[g['id']] }
      names[master['id']].concat(base_names)
      tables << passthrough_table(master, names[master['id']], source, 'm', @dm_name)
      groups.each_value do |g|
        tables << passthrough_table(g, names[g['id']], { 'kind' => 'table', 'elementId' => master['id'] }, g['id'], MASTER_NAME)
      end
      # wire controls
      table_of = ->(tid) { tables.find { |t| t['id'] == tid } }
      @pending.each do |p|
        ctl = p['ctl']
        targets = p['limited'] ? groups.values.select { |g| g['ctls'].include?(ctl['id']) } : [master]
        wired = targets.map do |t|
          tb = table_of.call(t['id'])
          col = tb['columns'].find { |c| c['name'] == p['fname'] }
          { 'source' => { 'kind' => 'table', 'elementId' => tb['id'] }, 'columnId' => col['id'] }
        end
        ctl['filters'] = wired
        if p['list']
          ctl['source'] = { 'kind' => 'source', 'source' => wired.first['source'], 'columnId' => wired.first['columnId'] }
        end
        @controls << ctl
      end
      @base_ids = groups.values.map { |g| g['id'] }
      tables
    end

    # A hidden-page table of passthrough columns over `src` (DM element or the master).
    def passthrough_table(tbl, col_names, src, prefix, src_name)
      cols = col_names.uniq.map do |n|
        { 'id' => CTL_COL.call(prefix, n), 'name' => n, 'formula' => "[#{src_name}/#{n}]" }
      end
      { 'id' => tbl['id'], 'kind' => 'table', 'name' => tbl['name'], 'source' => src, 'columns' => cols }
    end

    # --- emit: pages, layout (LAST), lints ----------------------------------------------
    def emit(page_ids)
      tables = build_tables
      @els.each do |e|
        el = e['el']
        next unless el && el.hash['kind'] == 'table'
        el.hash['order'] = el.columns.map { |c| c['id'] }
      end
      elements = tables + @controls + @els.map { |e| e['hash'] }
      @els.each do |e|
        next unless e['el']
        m = @map.values.find { |v| v['element_id'] == e['hash']['id'] }
        m['source_element_id'] = e['source_id'] if m
      end
      pages = [{ 'id' => 'page-data', 'name' => 'Data', 'hidden' => true }] +
              @dash['pages'].map { |p| { 'id' => p['id'], 'name' => p['name'] } }
      spec = { 'name' => @dash['name'], 'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => pages, 'elements' => elements }
      spec['folderId'] = @folder_id if @folder_id
      spec['layout'] = layout_xml(page_ids, tables)  # LAST write
      spec
    end

    def rect_overlap?(a, b)
      a['c0'] < b['c1'] && b['c0'] < a['c1'] && a['r0'] < b['r1'] && b['r0'] < a['r1']
    end

    def layout_xml(page_ids, tables)
      page_open = ->(pid) { "<Page type=\"grid\" gridTemplateColumns=\"repeat(#{SIGMA_GRID_COLS}, 1fr)\" gridTemplateRows=\"auto\" id=\"#{pid}\">" }
      elem = lambda do |r|
        %(  <Element elementId="#{r['id']}" gridColumn="#{r['c0']} / #{r['c1']}" gridRow="#{r['r0']} / #{r['r1']}"/>)
      end
      th = LayoutLint.min_rows_for('table')
      data_rows = tables.each_with_index.map do |t, i|
        { 'id' => t['id'], 'c0' => 1, 'c1' => SIGMA_GRID_COLS + 1, 'r0' => 1 + i * th, 'r1' => 1 + (i + 1) * th }
      end
      blocks = [([page_open.call('page-data')] + data_rows.map(&elem) + ['</Page>']).join("\n")]
      blocks.concat(page_ids.each_with_index.map do |pid, pi|
        rows = []
        shift = 0
        if pi.zero? && !@controls.empty?
          per_row = [@controls.length, 4].min
          @controls.each_with_index do |c, i|
            width = SIGMA_GRID_COLS / per_row
            col = i % per_row
            r0 = 1 + (i / per_row) * 2
            rows << { 'id' => c['id'], 'c0' => 1 + col * width, 'c1' => 1 + (col + 1) * width, 'r0' => r0, 'r1' => r0 + 2 }
          end
          shift = ((@controls.length + per_row - 1) / per_row) * 2
        end
        placed = []
        @els.select { |e| e['tile']['page_id'] == pid }.sort_by { |e| [e['tile']['y'], e['tile']['x'], e['tile']['index']] }.each do |e|
          t = e['tile']
          c0, c1 = LightdashWorkbook.scale_cols(t['x'], t['w'])
          # rows: Lightdash row units are used 1:1 (same convention as the Omni builder),
          # raised to the Sigma per-kind minimum and pushed down past anything they now overlap
          height = [t['h'], LayoutLint.min_rows_for(e['hash']['kind'])].max
          r0 = t['y'] + 1 + shift
          row = { 'id' => e['hash']['id'], 'c0' => c0, 'c1' => c1, 'r0' => r0, 'r1' => r0 + height }
          loop do
            hit = placed.find { |p| rect_overlap?(p, row) }
            break unless hit
            row['r0'] = hit['r1']
            row['r1'] = row['r0'] + height
          end
          placed << row
        end
        ([page_open.call(pid)] + (rows + placed).map(&elem) + ['</Page>']).join("\n")
      end)
      %(<?xml version="1.0" encoding="utf-8"?>\n) + blocks.join("\n")
    end

    def control_scope_doc
      { 'version' => 1, 'source' => 'lightdash', 'sourceFilterSignals' => @dash['filters'].length, 'controls' => @control_scope }
    end

    def workbook_map
      @map
    end

    def counts
      { 'tiles' => @dash['tiles'].length, 'charts' => @els.count { |e| e['el'] }, 'controls' => @controls.length,
        'placeholders' => @map.values.count { |m| m['placeholder'] }, 'gaps' => @gaps.length }
    end
  end

  # Build everything. Returns {spec, envelope, map, gaps, control_scope, violations, warnings}.
  def build(dash, field_map, dm_envelope, dm_id:, dm_lookup: nil, folder_id: nil)
    b = Builder.new(dash, field_map, dm_envelope, dm_id: dm_id, dm_lookup: dm_lookup, folder_id: folder_id)
    spec = b.build
    scope = b.control_scope_doc
    violations = lint(spec, scope)
    metadata = { 'name' => spec['name'] }
    metadata['folderId'] = spec['folderId'] if spec['folderId']
    document = spec.reject { |k, _| metadata.key?(k) }
    envelope = {
      'workbook' => Sigma::CodeRep.wrap(document, extra: metadata),
      'stats' => b.counts,
      'warnings' => b.warnings,
      'gaps' => b.gaps,
      'notes' => b.notes
    }
    { 'spec' => spec, 'envelope' => envelope, 'map' => b.workbook_map, 'gaps' => b.gaps, 'notes' => b.notes,
      'control_scope' => scope, 'violations' => violations, 'warnings' => b.warnings }
  end

  def lint(spec, scope)
    pre = Object.new
    errs = LayoutLint.lint(spec) + ControlLint.lint(spec, scope: scope) + pre.send(:lint, spec)
    errs.map(&:to_s)
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--dashboard PATH') { |v| opts[:dashboard] = v }
    o.on('--charts-dir DIR') { |v| opts[:charts_dir] = v }
    o.on('--dm-envelope PATH') { |v| opts[:envelope] = v }
    o.on('--field-map PATH') { |v| opts[:field_map] = v }
    o.on('--dm-id ID') { |v| opts[:dm_id] = v }
    o.on('--dm-lookup PATH') { |v| opts[:dm_lookup] = v }
    o.on('--folder-id ID') { |v| opts[:folder_id] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--workbook-map-out PATH') { |v| opts[:map_out] = v }
  end.parse!(ARGV)
  { dashboard: '--dashboard', charts_dir: '--charts-dir', envelope: '--dm-envelope', field_map: '--field-map',
    dm_id: '--dm-id', out: '--out' }.each { |k, flag| abort "missing #{flag}" if opts[k].to_s.empty? }

  dash = LightdashExport.load(opts[:dashboard], opts[:charts_dir])
  envelope = JSON.parse(File.read(opts[:envelope], encoding: 'UTF-8'))
  field_map = JSON.parse(File.read(opts[:field_map], encoding: 'UTF-8'))
  lookup = opts[:dm_lookup] && File.file?(opts[:dm_lookup]) ? JSON.parse(File.read(opts[:dm_lookup], encoding: 'UTF-8')) : nil
  res = LightdashWorkbook.build(dash, field_map, envelope, dm_id: opts[:dm_id], dm_lookup: lookup, folder_id: opts[:folder_id])

  out_dir = File.dirname(File.expand_path(opts[:out]))
  File.write(opts[:out], JSON.pretty_generate(res['envelope']) + "\n")
  File.write(opts[:map_out] || File.join(out_dir, 'workbook-map.json'), JSON.pretty_generate(res['map']) + "\n")
  # Merge (never clobber) ledger entries earlier steps recorded, e.g. the RLS waiver from apply-sigma-rls.rb.
  rls_gaps = File.join(out_dir, 'rls-gaps.json')
  prior = File.file?(rls_gaps) ? (JSON.parse(File.read(rls_gaps, encoding: 'UTF-8')) rescue []) : []
  prior = [] unless prior.is_a?(Array)
  File.write(File.join(out_dir, 'chart-gaps.json'),
             JSON.pretty_generate('gaps' => res['gaps'] + prior.reject { |e| res['gaps'].include?(e) }, 'notes' => res['notes']) + "\n")
  # The artifacts the verdict (DegradationLedger.derive) reads: scope-cuts -> coverage.json, the rest -> offramps.jsonl.
  LightdashLedger.write(out_dir, res['gaps'], origin: 'lightdash-build')
  File.write(File.join(out_dir, 'control-scope.json'), JSON.pretty_generate(res['control_scope']) + "\n")
  st = res['envelope']['stats']
  warn "wrote #{opts[:out]} (#{st['charts']} charts, #{st['controls']} controls, #{st['placeholders']} placeholders, #{st['gaps']} ledger entries)"
  res['warnings'].each { |w| warn "warning: #{w}" }
  unless res['violations'].empty?
    warn "lint violations:\n#{res['violations'].join("\n")}"
    exit 9
  end
end
