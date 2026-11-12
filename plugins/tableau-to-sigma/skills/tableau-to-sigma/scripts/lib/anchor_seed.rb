# frozen_string_literal: true

require 'json'
require 'csv'
require 'time'
require_relative 'mcp_source'

# anchor_seed.rb — valued source anchors for EVERY displayed tile, at the
# source's displayed precision (live re-proof findings 3 + 4).
#
#   * Gate 18 credits a tile only with a VALUED anchor (numeric, provenance
#     view-csv|vds) matched in it. The agent transcribed a few panels; Gross
#     Margin and Category x Region needed hand-added anchors. The Tableau view
#     CSVs are already in the workdir, so a tile with a CSV and no valued anchor
#     gets one seeded from its first non-empty measure cell
#     (`derived_by: seed-source-anchors`). Only a tile with NO CSV still needs
#     a person (reported in `no_csv`).
#   * A bare CSV float carries more precision than the source displays
#     (Gross Margin 0.641016176 vs the displayed 64.1%); the export rounds
#     differently, so the anchor could never match. Values are written with the
#     tile's Tableau display format (p0.0% → "64.1%", n"$"#,##0 → "$198,158");
#     when the format is ambiguous a bare float is capped at 6 decimals — the
#     shared anchor comparator matches at the ANCHOR's printed precision, so a
#     coarser anchor compares at that coarser precision.
#   * Agent-written view-csv anchors are normalized the same way, but ONLY
#     before the anchors lock exists (verify-anchors locks values on first
#     verification; adding anchors later is not tampering, changing one is).
module AnchorSeed
  MAX_DP = 6
  GENERATED_RE = /\(generated\)\s*\z/i.freeze

  module_function

  def read_json(path)
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue StandardError
    nil
  end

  # Tableau format string → { pct:, dp:, sep:, prefix: } (nil when unknown).
  def parse_format(fmt)
    f = fmt.to_s
    return nil if f.empty?
    pct = f.start_with?('p') || f.include?('%')
    body = f.sub(/\A[a-z]/i, '').split(';').first.to_s
    prefix = body[/\A"([^"]*)"/, 1].to_s
    num = body.sub(/\A"[^"]*"/, '')
    dp = num.include?('.') ? num.split('.', 2)[1].to_s.count('0#') : 0
    { pct: pct, dp: dp, sep: num.include?(','), prefix: prefix }
  end

  def bare_float?(s)
    s.to_s.strip.match?(/\A-?\d+\.\d+\z/)
  end

  def number_of(s)
    t = s.to_s.strip
    return nil if t.empty?
    pct = t.end_with?('%')
    v = Float(t.delete(',$%() '))
    v = -v if t.start_with?('(') && t.end_with?(')')
    pct ? v / 100.0 : v
  rescue ArgumentError
    nil
  end

  def group(int_str)
    int_str.reverse.scan(/\d{1,3}/).join(',').reverse
  end

  def render(value, fmt)
    if fmt
      v = fmt[:pct] ? value * 100.0 : value
      neg = v.negative?
      s = format("%.#{fmt[:dp]}f", v.abs)
      int, frac = s.split('.')
      int = group(int) if fmt[:sep]
      out = "#{fmt[:prefix]}#{int}#{frac ? ".#{frac}" : ''}#{fmt[:pct] ? '%' : ''}"
      neg ? "-#{out}" : out
    else
      format("%.#{MAX_DP}f", value).sub(/0+\z/, '').sub(/\.\z/, '')
    end
  end

  # A CSV cell at the tile's displayed precision. Already-formatted strings
  # (commas, %, $) are what Tableau printed — kept verbatim.
  def displayed(cell, header, formats)
    return cell.to_s.strip unless bare_float?(cell)
    v = Float(cell)
    fmts = formats.map { |f| parse_format(f) }.compact.uniq
    fmt = if fmts.size == 1 then fmts.first
          elsif header.to_s =~ /pct|percent|share|%|ratio|rate/i then fmts.find { |x| x[:pct] }
          end
    render(v, fmt)
  end

  def tiles(wd)
    layout = read_json(File.join(wd, 'dashboard-layout.json'))
    gw = read_json(File.join(wd, 'get-workbook.json')) || {}
    views = McpSource.views_for(wd, gw).each_with_object({}) { |v, h| h[v['name'].to_s] = v if v.is_a?(Hash) }
    zones = Array(layout).flat_map { |d| d.is_a?(Hash) ? Array(d['zones']) : [] }
    zones.select { |z| z.is_a?(Hash) && z['caption'] && (z['kind'] == 'chart' || z['is_kpi']) }
         .uniq { |z| z['caption'] }
         .map { |z| { caption: z['caption'].to_s, formats: (z['formats'] || {}).values, view: views[z['caption'].to_s] } }
  end

  def valued?(a)
    %w[view-csv vds].include?(a['provenance'].to_s) && !%w[text roster member].include?(a['kind'].to_s) &&
      !number_of(a['raw']).nil?
  end

  # First non-empty measure cell: the right-most numeric column that is not a
  # Tableau-generated geo column, first row carrying a value there.
  def seed_cell(csv_path, formats)
    rows = CSV.read(csv_path, encoding: 'bom|utf-8')
    header = Array(rows.first)
    body = rows.drop(1)
    return nil if header.empty? || body.empty?
    cols = header.each_index.reject { |i| header[i].to_s =~ GENERATED_RE }
    measure = cols.reverse.find { |i| body.any? { |r| number_of(r[i]) } && body.count { |r| number_of(r[i]) } >= body.count { |r| !r[i].to_s.strip.empty? } }
    return nil unless measure
    others = cols - [measure]
    # Prefer a row whose dimension members are all present (a Null/blank
    # member's label is renderer-specific); any valued row otherwise.
    row = body.find { |r| number_of(r[measure]) && others.all? { |i| !r[i].to_s.strip.empty? } } ||
          body.find { |r| number_of(r[measure]) }
    dims = others.map { |i| row[i].to_s.strip }.reject(&:empty?)
    { raw: displayed(row[measure], header[measure], formats), header: header[measure].to_s.strip, dims: dims,
      kind: displayed(row[measure], header[measure], formats).end_with?('%') ? 'percent' : 'number' }
  end

  # Returns { seeded: [ids], normalized: [{id, from, to}], no_csv: [captions] }.
  # write: false → plan only (the preflight's "is anything to do" check).
  def apply!(wd, normalize: nil, write: true)
    path = File.join(wd, 'source-anchors.json')
    doc = read_json(path)
    doc = { 'anchors' => doc } if doc.is_a?(Array)
    doc ||= { 'anchors' => [] }
    anchors = Array(doc['anchors'])
    normalize = !File.exist?(File.join(wd, 'source-anchors.lock.json')) if normalize.nil?
    out = { seeded: [], normalized: [], no_csv: [] }
    ts = tiles(wd)
    by_cap = ts.each_with_object({}) { |t, h| h[t[:caption].downcase] = t }

    if normalize
      anchors.each do |a|
        next unless a.is_a?(Hash) && a['provenance'].to_s == 'view-csv' && bare_float?(a['raw'])
        t = by_cap[(a['panel'] || a['sigma_element_hint']).to_s.downcase]
        to = displayed(a['raw'], a['label'], t ? t[:formats] : [])
        next if to == a['raw'].to_s
        out[:normalized] << { 'id' => a['id'], 'from' => a['raw'], 'to' => to }
        a['normalized_from'] = a['raw']
        a['raw'] = to
      end
    end

    taken = anchors.map { |a| a['id'].to_s }
    ts.each do |t|
      has = anchors.any? do |a|
        a.is_a?(Hash) && valued?(a) && [a['panel'], a['sigma_element_hint']].any? { |n| n.to_s.casecmp?(t[:caption]) }
      end
      next if has
      csv = t[:view] && McpSource.csv_path(wd, t[:view])
      unless csv && File.file?(csv)
        out[:no_csv] << t[:caption]
        next
      end
      cell = (seed_cell(csv, t[:formats]) rescue nil)
      next unless cell
      n = 1
      n += 1 while taken.include?("s#{n}")
      id = "s#{n}"
      taken << id
      anchors << { 'id' => id, 'panel' => t[:caption], 'sigma_element_hint' => t[:caption],
                   'label' => [cell[:dims].join(' / '), cell[:header]].reject(&:empty?).join(' — '),
                   'raw' => cell[:raw], 'kind' => cell[:kind], 'provenance' => 'view-csv',
                   'derived_by' => 'seed-source-anchors',
                   'source_csv' => t[:view]['csv_path'] || "views/#{t[:view]['id']}.csv" }
      out[:seeded] << id
    end

    if write && (out[:seeded].any? || out[:normalized].any?)
      doc['anchors'] = anchors
      doc['seeded_at'] = Time.now.utc.iso8601 if out[:seeded].any?
      File.write(path, JSON.pretty_generate(doc))
    end
    out
  end
end
