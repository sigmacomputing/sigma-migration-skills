#!/usr/bin/env ruby
# frozen_string_literal: true
# Parity oracle: run each built chart's Lightdash metricQuery against Lightdash itself and save the
# expected rows keyed by Sigma column name. UNVALIDATED against a real instance (coded from the
# documented REST API; tests use a fake transport). Needs LIGHTDASH_URL + LIGHTDASH_API_KEY.
#
#   ruby scripts/lightdash-query-oracle.rb --project <uuid> --workbook-map workbook-map.json \
#     --charts-dir discovery/lightdash/charts --field-map field-map.json --out-dir expected
#
# Per chart slug in workbook-map.json (placeholders skipped):
#   POST /api/v1/projects/{p}/explores/{explore}/runQuery      body = the chart's metricQuery (limit kept)
#   POST /api/v1/projects/{p}/explores/{explore}/compileQuery  body = same (optional; failure only warns)
# Writes expected/<slug>.json  {chart, element_id, explore, columns, rows: [{<Sigma column> => value}], limit}
#        expected/<slug>.sql   compiled warehouse SQL (feeds the offline warehouse leg)
# Rows are {fieldId: {value: {raw, formatted}}} (also accepted: {fieldId: {raw,formatted}} or plain
# values); the RAW value is used. The dashboard filters the workbook builder applied as defaulted controls
# (workbook-map `applied_filters`) are merged into metricQuery.filters.dimensions as AND rules, so the
# oracle sees the same filtered data as the Sigma chart. Exit 3 when any runQuery fails OR a data chart
# (non-placeholder) is skipped (no chart YAML / no metricQuery): it must never leave the parity gate silently.
# A chart with a limit and dimensions whose result hits the limit and whose sort is not a total order (no sort,
# or a sort with ties among the returned rows, e.g. on one of several dimensions) is flagged `unsorted_limit`
# (row selection is not deterministic; verify-lightdash-parity SKIPs it with that reason).

require 'optparse'
require 'json'
require 'fileutils'
require_relative 'lib/lightdash_rest'
require_relative 'lib/lightdash_export'

module LightdashOracle
  module_function

  def cell_value(cell)
    return cell unless cell.is_a?(Hash)
    v = cell.key?('value') ? cell['value'] : cell
    return v unless v.is_a?(Hash)
    v.key?('raw') ? v['raw'] : v['formatted']
  end

  # [columns, rows] with rows keyed by Sigma column name (workbook-map column name, then field-map
  # name, then the Lightdash fieldId).
  def normalize(raw_rows, entry, field_map)
    ids = Array(entry['fields'])
    names = ids.each_with_object({}) do |fid, h|
      h[fid] = (entry.dig('columns', fid) || {})['name'] || (field_map[fid] || {})['name'] || fid
    end
    rows = Array(raw_rows).map do |r|
      next {} unless r.is_a?(Hash)
      ids.each_with_object({}) { |fid, h| h[names[fid]] = cell_value(r[fid]) if r.key?(fid) }
    end
    [names.values, rows]
  end

  # True when the query's sort fully determines WHICH rows survive the limit: the sort fields cover every
  # dimension (a grouped query has one row per dimension tuple), or the sort-key tuples are all distinct in
  # the returned rows. No sort, or a sort with ties among the returned rows (e.g. a sort on one of
  # several dimensions), leaves the cutoff row-selection undefined.
  def total_order?(mq, raw_rows)
    sort_ids = Array(mq['sorts']).map { |s| s.is_a?(Hash) ? s['fieldId'].to_s : nil }.compact
    return false if sort_ids.empty?
    return true if Array(mq['dimensions']).map(&:to_s).all? { |d| sort_ids.include?(d) }
    keys = Array(raw_rows).map { |r| r.is_a?(Hash) ? sort_ids.map { |f| cell_value(r[f]) } : nil }
    keys.compact.uniq.length == keys.length
  end

  def sql_of(compiled)
    return compiled if compiled.is_a?(String)
    return nil unless compiled.is_a?(Hash)
    compiled['query'] || compiled['sql'] || compiled['compiledSql']
  end

  # metricQuery + the dashboard filters the workbook applied, as AND rules on filters.dimensions.
  def with_applied_filters(mq, applied)
    return mq if applied.nil? || applied.empty?
    rules = applied.each_with_index.map do |f, i|
      { 'id' => "oracle-dashboard-filter-#{i}", 'target' => { 'fieldId' => f['fieldId'] },
        'operator' => f['operator'], 'values' => f['values'] }
    end
    existing = (mq['filters'] || {})['dimensions']
    group = { 'id' => 'oracle-dashboard-filters', 'and' => (existing.nil? || existing.empty? ? [] : [existing]) + rules }
    mq.merge('filters' => (mq['filters'] || {}).merge('dimensions' => group))
  end

  # Returns { 'ok' => [slugs], 'failed' => { slug => reason }, 'skipped' => { slug => reason } }.
  def run(client, project:, workbook_map:, charts:, field_map:, out_dir:)
    FileUtils.mkdir_p(out_dir)
    res = { 'ok' => [], 'failed' => {}, 'skipped' => {} }
    workbook_map.each do |slug, entry|
      next res['skipped'][slug] = 'placeholder element (no data chart)' if entry['placeholder']
      chart = charts[slug.sub(/#\d+\z/, '')]
      next res['skipped'][slug] = 'chart YAML not found' unless chart
      mq = chart['metricQuery']
      explore = (mq.is_a?(Hash) && mq['exploreName']) || chart['tableName']
      next res['skipped'][slug] = 'chart has no metricQuery/explore' unless mq.is_a?(Hash) && explore
      path = "/api/v1/projects/#{project}/explores/#{explore}"
      mq = with_applied_filters(mq, entry['applied_filters'])
      begin
        results = client.post("#{path}/runQuery", mq)
      rescue LightdashRest::Error => e
        res['failed'][slug] = e.message[0, 200]
        next
      end
      raw_rows = results.is_a?(Hash) ? results['rows'] : results
      cols, rows = normalize(raw_rows, entry, field_map)
      doc = { 'chart' => slug, 'element_id' => entry['element_id'], 'explore' => explore, 'columns' => cols,
              'rows' => rows, 'limit' => mq['limit'], 'applied_filters' => entry['applied_filters'] || [] }
      if mq['limit'] && rows.length >= mq['limit'].to_i && Array(mq['dimensions']).any? && !total_order?(mq, raw_rows)
        doc['unsorted_limit'] = true
      end
      File.write(File.join(out_dir, "#{slug.tr('#', '_')}.json"), JSON.pretty_generate(doc) + "\n")
      begin
        sql = sql_of(client.post("#{path}/compileQuery", mq))
        File.write(File.join(out_dir, "#{slug.tr('#', '_')}.sql"), sql.to_s.strip + "\n") if sql
      rescue LightdashRest::Error => e
        warn "warning: compileQuery failed for #{slug} (#{e.message[0, 120]}); no .sql for the warehouse leg"
      end
      res['ok'] << slug
    end
    res
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = { out_dir: 'expected' }
  OptionParser.new do |o|
    o.on('--project UUID') { |v| opts[:project] = v }
    o.on('--workbook-map PATH') { |v| opts[:map] = v }
    o.on('--charts-dir DIR') { |v| opts[:charts] = v }
    o.on('--field-map PATH') { |v| opts[:field_map] = v }
    o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
  end.parse!(ARGV)
  { project: '--project', map: '--workbook-map', charts: '--charts-dir', field_map: '--field-map' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end
  begin
    client = LightdashRest::Client.from_env
    res = LightdashOracle.run(client, project: opts[:project],
                              workbook_map: JSON.parse(File.read(opts[:map], encoding: 'UTF-8')),
                              charts: LightdashExport.load_charts(opts[:charts]),
                              field_map: JSON.parse(File.read(opts[:field_map], encoding: 'UTF-8')),
                              out_dir: opts[:out_dir])
  rescue LightdashRest::Error, LightdashExport::Error => e
    abort "error: #{e.message}"
  end
  res['skipped'].each { |s, why| warn "skipped #{s}: #{why}" }
  res['failed'].each { |s, why| warn "FAILED #{s}: #{why}" }
  # Placeholder skips are builder gaps (ledgered); any other skip would leak out of the parity gate.
  leaks = res['skipped'].keys.reject { |s| JSON.parse(File.read(opts[:map], encoding: 'UTF-8'))[s]['placeholder'] }
  leaks.each { |s| warn "FAILED #{s}: data chart skipped by the oracle (#{res['skipped'][s]})" }
  warn "oracle: #{res['ok'].length} chart(s) saved to #{opts[:out_dir]}, #{res['failed'].length} failed, #{res['skipped'].length} skipped"
  exit(res['failed'].empty? && leaks.empty? ? 0 : 3)
end
