# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'

# source_drift.rb — Tableau capture vs live warehouse drift, handled STRICTLY.
#
# WHY: the warehouse loaded between the Tableau view-CSV capture (Phase 1) and
# the Sigma parity query (Phase 6): Net Revenue 197,677 → 198,158, Orders
# 1,298 → 1,302, the current month only. Sigma read the warehouse correctly;
# the expected values were simply older. With extracts=false there is no
# tolerance to apply, so parity failed 6/10 with no hint that the SOURCE
# moved — a customer would debug a correct converter.
#
# Policy (values stay strict — nothing here ever turns a FAIL into a PASS):
#   1. PREVENT: Phase 1 captures view CSVs with maxAge=1 (Tableau's view-data
#      cache otherwise serves an older answer; tableau-discover.{rb,py}).
#   2. DIAGNOSE (assess): when every DIVERGE tile has the same dimension keys
#      on both sides (or Sigma only adds rows) and every TILE's total delta is
#      small (<= 5% relative), the failure is labelled `suspected-source-drift` in
#      source-drift.json with the re-capture command. Status stays FAIL.
#   3. PROVE + RECOVER (recapture!): re-export the diverged views fresh and
#      compare BYTES to the captured CSV. Only a CHANGED source CSV is drift
#      (evidence from the source itself, independent of Sigma): the fresh CSV
#      replaces the capture (the old one archived under views/captures/<ts>/)
#      and parity is re-planned and re-collected against it, strictly. An
#      UNCHANGED CSV means the divergence is real — nothing is swapped.
#   Anchors transcribed from a moved view (Phase 1d, provenance view-csv) are
#   listed as stale; they must be re-read against the fresh capture.
module SourceDrift
  MAX_REL = 0.05
  FILE = 'source-drift.json'
  RECAPTURE = 'source-recapture.json'

  module_function

  def num(v)
    return v.to_f if v.is_a?(Numeric)
    s = v.to_s.strip.delete(',$%')
    return nil if s.empty?
    Float(s)
  rescue ArgumentError
    nil
  end

  # plan: parity-plan.json, actuals: parity-actuals.json ({chart => rows}),
  # fail_names: parity-final.json fail_names. Returns the assessment Hash.
  def assess(plan, actuals, fail_names, max_rel: MAX_REL)
    charts = Array(plan.is_a?(Hash) ? plan['charts'] : nil).each_with_object({}) { |c, h| h[c['chart']] = c }
    tiles = Array(fail_names).map do |name|
      c = charts[name]
      next { 'chart' => name, 'consistent' => false, 'reason' => 'not in parity-plan.json' } unless c
      tile_assessment(name, Array(c['expected']), Array((actuals || {})[name]), c['measure_indices'], max_rel)
    end
    suspected = tiles.any? && tiles.all? { |t| t['consistent'] } && tiles.any? { |t| t['max_rel'].to_f.positive? }
    { 'version' => 1, 'assessed_at' => Time.now.utc.iso8601, 'max_rel' => max_rel,
      'classification' => suspected ? 'suspected-source-drift' : 'divergence',
      'tiles' => tiles,
      'note' => if suspected
                  'Every diverged tile differs only by a small value delta on the same keys — consistent with the ' \
                  'warehouse loading AFTER the Tableau capture. Values stay strict (status FAIL). Re-capture the ' \
                  'source and re-run parity: ruby scripts/recapture-source-views.rb --workdir <WORK>'
                else
                  'Divergence is not a uniform small delta on matching keys — treat it as a real parity failure.'
                end }
  end

  def tile_assessment(name, expected, actual, measure_idx, max_rel)
    width = (expected.first || actual.first || []).size
    m_idx = Array(measure_idx).map(&:to_i)
    if m_idx.empty?
      m_idx = (0...width).select { |i| expected.all? { |r| num(r[i]) } && expected.any? }
      m_idx = [width - 1] if m_idx.empty? && width.positive?
    end
    key = ->(r) { (0...width).reject { |i| m_idx.include?(i) }.map { |i| r[i].to_s.strip.downcase } }
    e_by = expected.group_by(&key)
    a_by = actual.group_by(&key)
    missing = e_by.keys - a_by.keys
    extra = a_by.keys - e_by.keys
    # Tile-level delta: total |change| over total |expected|. A warehouse load
    # lands in the newest rows (live proof: only the current month moved,
    # +18.7% of that month but +0.24% of the tile), so a per-row bound would
    # misread drift; the tile total moves by the loaded fraction.
    row_max = 0.0
    sum_d = 0.0
    sum_e = 0.0
    e_by.each do |k, rows|
      arow = a_by[k]&.first or next
      erow = rows.first
      m_idx.each do |i|
        ev = num(erow[i])
        av = num(arow[i])
        next if ev.nil? || av.nil?
        d = (av - ev).abs
        sum_d += d
        sum_e += ev.abs
        rel = ev.zero? ? (d.zero? ? 0.0 : Float::INFINITY) : d / ev.abs
        row_max = rel if rel > row_max
      end
    end
    tile = sum_e.zero? ? (sum_d.zero? ? 0.0 : Float::INFINITY) : sum_d / sum_e
    consistent = missing.empty? && tile <= max_rel
    { 'chart' => name, 'consistent' => consistent, 'max_rel' => tile.finite? ? tile.round(6) : nil,
      'row_max_rel' => row_max.finite? ? row_max.round(6) : nil,
      'missing_keys' => missing.size, 'extra_keys' => extra.size,
      'reason' => if !missing.empty? then "#{missing.size} source key(s) absent from Sigma"
                  elsif tile > max_rel then "tile delta #{(tile * 100).round(2)}% exceeds #{(max_rel * 100).round}%"
                  else "same keys#{extra.empty? ? '' : " (+#{extra.size} Sigma-only)"}; tile delta #{(tile * 100).round(3)}%"
                  end }
  end

  def norm_csv(text)
    text.to_s.dup.force_encoding(Encoding::UTF_8)
        .encode('UTF-8', invalid: :replace, undef: :replace)
        .sub(/\A\uFEFF/, '').gsub("\r\n", "\n").rstrip
  end

  # Re-export the views of `charts` (parity-plan tableau_view names) through
  # `fetch` (->(view_id) { csv text }) and compare with views/<id>.csv.
  # Swaps in a CHANGED capture (archiving the old), never an unchanged one.
  def recapture!(workdir, charts:, fetch:, plan: nil)
    plan ||= (JSON.parse(File.read(File.join(workdir, 'parity-plan.json'))) rescue {})
    gw = (JSON.parse(File.read(File.join(workdir, 'get-workbook.json'))) rescue {})
    views = Array(gw.dig('views', 'view')) + Array(gw['views'].is_a?(Array) ? gw['views'] : [])
    by_name = views.each_with_object({}) { |v, h| h[v['name'].to_s] = v['id'] if v.is_a?(Hash) }
    pcharts = Array(plan['charts']).each_with_object({}) { |c, h| h[c['chart']] = c }
    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    out = { 'version' => 1, 'recaptured_at' => Time.now.utc.iso8601, 'moved' => [], 'unchanged' => [], 'unavailable' => [] }
    Array(charts).each do |name|
      vname = pcharts.dig(name, 'tableau_view') || name
      vid = by_name[vname.to_s]
      path = vid && File.join(workdir, 'views', "#{vid}.csv")
      unless path && File.file?(path)
        out['unavailable'] << { 'chart' => name, 'view' => vname, 'reason' => 'no captured view CSV' }
        next
      end
      fresh = begin
        fetch.call(vid)
      rescue StandardError => e
        out['unavailable'] << { 'chart' => name, 'view' => vname, 'reason' => "re-export failed: #{e.class}: #{e.message.to_s[0, 120]}" }
        next
      end
      old = File.binread(path)
      rec = { 'chart' => name, 'view' => vname, 'view_id' => vid,
              'old_sha256' => Digest::SHA256.hexdigest(norm_csv(old)), 'new_sha256' => Digest::SHA256.hexdigest(norm_csv(fresh)) }
      if rec['old_sha256'] == rec['new_sha256']
        out['unchanged'] << rec
      else
        arch = File.join(workdir, 'views', 'captures', stamp)
        FileUtils.mkdir_p(arch)
        File.binwrite(File.join(arch, "#{vid}.csv"), old)
        File.write(path, fresh)
        rec['archived'] = File.join(arch, "#{vid}.csv")
        out['moved'] << rec
      end
    end
    out['stale_anchors'] = stale_anchors(workdir, out['moved'].map { |m| m['view'] } + out['moved'].map { |m| m['chart'] })
    File.write(File.join(workdir, RECAPTURE), JSON.pretty_generate(out))
    out
  end

  # Phase 1d anchors whose value came from a now-moved view CSV.
  def stale_anchors(workdir, names)
    doc = (JSON.parse(File.read(File.join(workdir, 'source-anchors.json'))) rescue nil)
    list = doc.is_a?(Hash) ? Array(doc['anchors']) : Array(doc)
    want = names.map { |n| n.to_s.downcase }
    list.select do |a|
      a.is_a?(Hash) && a['provenance'].to_s =~ /view-csv/i &&
        [a['panel'], a['sigma_element_hint'], a['tile'], a['chart'], a['view'], a['title']].any? { |n| want.include?(n.to_s.downcase) }
    end.map { |a| a['id'] || a['label'] || a['tile'] }
  end
end
