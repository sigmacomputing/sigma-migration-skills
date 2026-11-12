# frozen_string_literal: true

require 'json'
require_relative 'mcp_source'

# coverage_retire.rb — a coverage waiver on a tile that IS covered is not a
# degradation (A+B regression: OEO "OV Revenue Trend", RCC "RC State Map").
#
# The agent waives anchor coverage for a tile that "prints no value labels"
# (a line chart, a filled map) at Phase 1d. The shared degradation ledger then
# turns every source-anchors.json / ground-truth-plan.json `coverage_waivers`
# entry into a `resolution-waived` degradation, and green-offer forfeits GREEN
# — although the tile had a Tableau view CSV, a seeded valued anchor that
# matched in it, and passed strict parity. The waiver excuses nothing then.
#
# retire! moves such a waiver to `coverage_notes` (kept for the record, read by
# no gate or ledger) ONLY when the tile is covered on every count:
#   * source-anchors.json waivers: the tile has a view CSV, a VALUED anchor
#     (view-csv|vds, numeric) matched inside it per anchors-verdict.json, it is
#     not in anchor_coverage.uncovered, and parity-final.json is strict with
#     the tile's Sigma element(s) in pass_names (none in fail_names);
#   * ground-truth-plan.json waivers: the tile has a view CSV, passes strict
#     parity as above, and its numeric_parity stamp is a `match`.
# Anything short of that keeps the waiver — and the degradation.
module CoverageRetire
  module_function

  def read_json(path)
    JSON.parse(File.read(path, encoding: 'UTF-8'))
  rescue StandardError
    nil
  end

  def norm(s)
    s.to_s.strip.downcase
  end

  # Tableau caption → Sigma element names (chart-provenance worksheet/name;
  # the element's spec name when the provenance carries none).
  def sigma_names(wd, caption)
    prov = read_json(File.join(wd, 'chart-provenance.json'))
    list = prov.is_a?(Hash) ? (prov['elements'] || {}) : {}
    list = list.to_a if list.is_a?(Hash)
    spec = read_json(File.join(wd, 'wb-spec.json'))
    doc = spec.is_a?(Hash) ? (spec['document'] || spec['contents'] || spec) : {}
    elements = Array(doc['elements']) + Array(doc['pages']).flat_map { |p| p.is_a?(Hash) ? Array(p['elements']) : [] }
    spec_names = elements.each_with_object({}) { |e, h| h[e['id']] = e['name'] if e.is_a?(Hash) && e['id'] && e['name'] }
    names = Array(list).map do |pair|
      id, p = pair.is_a?(Array) ? pair : [pair['id'], pair]
      next nil unless p.is_a?(Hash) && norm(p['worksheet']) == norm(caption)
      p['name'] || spec_names[id] || caption.to_s
    end.compact
    names.empty? ? [caption.to_s] : names.uniq
  end

  def csv?(wd, caption)
    gw = read_json(File.join(wd, 'get-workbook.json')) || {}
    view = (McpSource.views_for(wd, gw) rescue []).find { |v| v.is_a?(Hash) && norm(v['name']) == norm(caption) }
    path = view && (McpSource.csv_path(wd, view) rescue nil)
    !path.nil? && File.file?(path)
  end

  def strict_pass?(parity, names)
    return false unless parity.is_a?(Hash) && parity['mode'].to_s == 'strict'
    pass = Array(parity['pass_names']).map { |n| norm(n) }
    fail_n = Array(parity['fail_names']).map { |n| norm(n) }
    names.all? { |n| pass.include?(norm(n)) && !fail_n.include?(norm(n)) }
  end

  def anchor_match(verdict, caption, names)
    return nil unless verdict.is_a?(Hash)
    uncovered = Array(verdict.dig('anchor_coverage', 'uncovered')).map { |n| norm(n) }
    return nil if ([caption] + names).any? { |n| uncovered.include?(norm(n)) }
    want = ([caption] + names).map { |n| norm(n) }
    Array(verdict['detail']).find do |d|
      d.is_a?(Hash) && d['valued'] == true && %w[view-csv vds].include?(d['provenance'].to_s) &&
        !d['matched_in'].to_s.empty? && want.include?(norm(d['matched_in']))
    end
  end

  def numeric_match?(parity, wd, names, caption)
    np = parity.is_a?(Hash) ? parity['numeric_parity'] : nil
    np = read_json(File.join(wd, 'numeric-parity.json')) unless np.is_a?(Hash)
    tiles = np.is_a?(Hash) && np['tiles'].is_a?(Hash) ? np['tiles'] : {}
    by = tiles.each_with_object({}) { |(k, v), h| h[norm(k)] = v }
    ([caption] + names).any? { |n| by[norm(n)].is_a?(Hash) && by[norm(n)]['verdict'] == 'match' && !by[norm(n)]['conflict'] }
  end

  # Rewrites the waiver files in place (mtime preserved: only waiver fields
  # change, never an anchor, so no verdict goes stale). Returns
  # { retired: [{file, tile, why}], kept: [{file, tile, why}] }.
  def retire!(wd, write: true)
    out = { retired: [], kept: [] }
    parity = read_json(File.join(wd, 'parity-final.json'))
    verdict = read_json(File.join(wd, 'anchors-verdict.json'))
    %w[source-anchors.json ground-truth-plan.json].each do |file|
      path = File.join(wd, file)
      doc = read_json(path)
      next unless doc.is_a?(Hash) && Array(doc['coverage_waivers']).any?
      keep = []
      notes = Array(doc['coverage_notes'])
      Array(doc['coverage_waivers']).each do |w|
        tile = w.is_a?(Hash) ? w['tile'].to_s : ''
        names = sigma_names(wd, tile)
        why = if tile.empty? then 'no tile named'
              elsif !csv?(wd, tile) then 'no view CSV'
              elsif !strict_pass?(parity, names) then 'not in a strict parity pass'
              elsif file == 'source-anchors.json' && !(a = anchor_match(verdict, tile, names)) then 'no valued anchor matched in it'
              elsif file == 'ground-truth-plan.json' && !numeric_match?(parity, wd, names, tile) then 'no numeric_parity match'
              end
        if why
          keep << w
          out[:kept] << { 'file' => file, 'tile' => tile, 'why' => why }
          next
        end
        cov = file == 'source-anchors.json' ? "anchor #{a['id']} matched in #{a['matched_in']}" : 'numeric_parity match'
        notes << w.merge('retired' => 'covered', 'covered_by' => "view CSV + strict parity pass + #{cov}")
        out[:retired] << { 'file' => file, 'tile' => tile, 'why' => cov }
      end
      next if keep.size == Array(doc['coverage_waivers']).size || !write
      keep.empty? ? doc.delete('coverage_waivers') : doc['coverage_waivers'] = keep
      doc['coverage_notes'] = notes
      st = File.stat(path)
      File.write(path, JSON.pretty_generate(doc))
      File.utime(st.atime, st.mtime, path)
    end
    out
  end
end
