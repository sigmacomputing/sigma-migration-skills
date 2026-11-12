# frozen_string_literal: true

# Test-only harness: hand-builds the dashboard-layout the parser would emit,
# runs the ACTUAL build-charts-from-signals.rb offline, and returns the output.
# Used by the C-batch recipe tests (data-label anchor, refline caption, control
# placeholder, axis titles).
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

module BuilderTestHarness
  BUILD = File.join(__dir__, '..', 'build-charts-from-signals.rb')

  MMAP = {
    '(?i)^Region$'      => { 'id' => 'm-region', 'name' => 'Region' },
    '(?i)^Segment$'     => { 'id' => 'm-segment', 'name' => 'Segment' },
    '(?i)^Net Revenue$' => { 'id' => 'm-rev', 'name' => 'Net Revenue' },
    '(?i)^Order Date$'  => { 'id' => 'm-od', 'name' => 'Order Date' }
  }.freeze

  # A minimal bar/line chart zone: one dimension, one measure. `dim_on_rows`
  # makes the bar horizontal. `extra` is merged over the zone.
  def self.chart_zone(id:, caption:, chart_kind: 'bar', mark_class: 'Bar', dim: 'Region',
                      measure: 'Net Revenue', dim_on_rows: false, extra: {})
    dim_f = { 'caption' => dim, 'role' => 'dim' }
    meas_f = { 'caption' => measure, 'role' => 'measure' }
    {
      'id' => id, 'kind' => 'chart', 'caption' => caption, 'chart_kind' => chart_kind,
      'mark_class' => mark_class, 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 50, 'h_pct' => 30,
      'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
      'ref_marks' => [], 'aggregations' => { "[#{dim}]" => 'None', "[#{measure}]" => 'Sum' },
      'rows_shelf' => { 'fields' => [dim_on_rows ? dim_f : meas_f] },
      'cols_shelf' => { 'fields' => [dim_on_rows ? meas_f : dim_f] },
      'measures' => [{ 'column' => "[#{measure}]", 'derivation' => 'Sum' }], 'calculations' => []
    }.merge(extra)
  end

  # `csvs` maps a view caption to literal CSV text (multi-member fixtures).
  # Returns { elements:, data_elements:, log:, raw: } ; `meta` is merged over the
  # empty worksheet meta (e.g. 'shared_filters' for quick-filter controls).
  def self.run(zones, meta: {}, captions: nil, csvs: {}, args: [], extra_dashboards: [], canvas_px: nil, zone_tree: nil, files: {}, mmap: MMAP)
    first = { 'dashboard' => 'Dash', 'zones' => zones }
    first['zone_tree'] = zone_tree if zone_tree
    first['canvas_px'] = canvas_px if canvas_px
    layout = [first] + extra_dashboards
    full_meta = { 'worksheets' => {}, 'shared_filters' => [], 'parameters' => [], 'column_aliases' => {},
                  'columns_by_guid' => {} }.merge(meta)
    result = { elements: [], data_elements: [], log: '', raw: nil }
    Dir.mktmpdir do |d|
      File.write("#{d}/layout.json", JSON.dump(layout))
      File.write("#{d}/meta.json", JSON.dump(full_meta))
      File.write("#{d}/mm.json", JSON.dump(mmap))
      charts = zones.select { |z| z['caption'] }
      views = (captions || charts.map { |z| z['caption'] }).each_with_index.map do |c, i|
        { 'id' => "v#{i}", 'name' => c }
      end
      File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => views }))
      files.each { |name, body| File.write("#{d}/#{name}", body) }
      Dir.mkdir("#{d}/views")
      views.each_with_index do |v, i|
        shelf = ->(k) { Array(charts[i] && charts[i].dig(k, 'fields')).map { |f| f['caption'] } }
        cols = (shelf.call('cols_shelf') + shelf.call('rows_shelf')).uniq
        cols = %w[Region Net\ Revenue] if cols.empty?
        next File.write("#{d}/views/#{v['id']}.csv", csvs[v['name']]) if csvs[v['name']]
        File.write("#{d}/views/#{v['id']}.csv", "#{cols.join(',')}\n#{cols.map { |c| c =~ /Revenue/ ? '100' : 'West' }.join(',')}\n")
      end
      out = "#{d}/specs.json"
      o, e, st = Open3.capture3(RbConfig.ruby, BUILD, '--tableau-dir', d, '--layout', "#{d}/layout.json",
                                '--meta', "#{d}/meta.json", '--master-map', "#{d}/mm.json",
                                '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                                '--out', out, *args)
      result[:log] = o + e
      result[:status] = st
      if File.exist?(out)
        raw = JSON.parse(File.read(out))
        result[:raw] = raw
        result[:elements] = raw.is_a?(Array) ? raw : (raw['elements'] || (raw['pages'] || []).flat_map { |p| p['elements'] || [] })
        result[:data_elements] = raw.is_a?(Hash) ? (raw['data_elements'] || []) : []
      end
      prov = "#{d}/chart-provenance.json"
      result[:provenance] = JSON.parse(File.read(prov)) if File.exist?(prov)
    end
    result
  end

  def self.find_chart(res, name_re)
    res[:elements].find { |e| e['name'].to_s =~ name_re && e['kind'].to_s != 'text' }
  end
end
