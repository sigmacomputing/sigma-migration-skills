#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-interaction.rb — the vf_ INTERACTION ORACLE (P2 deliverable B).
#
# Cross-system flip test: for ONE quick-filter control per dashboard, apply the
# SAME filter value on both sides — Tableau via a vf_<caption>=<value> view
# filter on the paired view's /data CSV, Sigma via the REST export API's
# "parameters" body (the proven probe-controls.rb channel) — and check that
# the two FILTERED value sets agree. The verdict is VALUE-based, not
# pixel-based: filtered renders are captured only as human evidence; pixels
# differ for legal reasons (fonts, palette, padding), a filtered value set
# either matches or it doesn't.
#
# Checks per probed control (all three recorded):
#   1. tableau_flip_changed — the vf_ flip changed the Tableau CSV (sorted-line
#      signature). FALSE ⇒ the vf_ field name didn't bite (wrong caption /
#      field not in view) → SKIP-INVALID, never FAIL — one retry with the
#      view CSV's exact header spelling when it differs from the caption.
#   2. sigma_flip_changed — the parameters flip changed the Sigma CSV
#      (probe-controls semantics: identical = wired but inert).
#   3. cross_anchor_match — anchors (column max/min/sum) derived from the
#      TABLEAU flipped CSV must appear in the SIGMA flipped CSV under
#      AnchorValues printed-precision matching (found-anywhere; the sum anchor
#      may also match the Sigma column's own sum — grain differences).
# result: PASS when 2 AND 3 pass (1 gates validity, not the verdict);
#         FAIL when 2 or 3 fails on a valid probe.
#
# v1 SCOPE: mechanism=="filters" controls only. Parameter controls
# (mechanism "formula"/"formula+filters") are recorded SKIP — vf_ semantics
# for Tableau *parameters* are unverified (v2). Date/range/slider controls
# SKIP (no auto flip value — mirror probe-controls.rb).
#
# Output: <W>/interaction-oracle.json + <W>/interaction/ CSV/PNG evidence +
# stderr summary. ADVISORY: exit 0 after running; exit 15 on FAIL only under
# --gate; exit 2 when nothing was probeable (stated, never silent).
#
# Usage:
#   eval "$(scripts/get-token.sh)"; eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/verify-interaction.rb --workdir <W> --workbook-id <sigmaWbId> \
#     [--control <controlId>]      # probe only this control (repeatable)
#     [--value <controlId>=<v>]    # explicit flip value (repeatable)
#     [--per-dashboard N]          # controls probed per dashboard (default 1)
#     [--no-renders]               # skip the advisory PNG evidence
#     [--gate]                     # exit 15 on FAIL (default: advisory exit 0)
#     [--timeout SECS]             # per export poll (default 90)
#     [--out PATH]                 # default <W>/interaction-oracle.json
#
# All Tableau image/data fetches stay SEQUENTIAL (VizQL contention rule).

require 'json'
require 'csv'
require 'set'
require 'optparse'
require 'fileutils'
require 'net/http'
require 'uri'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'anchor_values'
require 'control_lint'

# ---------------------------------------------------------------------------
# Pure core — unit-tested offline in test-verify-interaction.rb. No IO.
# ---------------------------------------------------------------------------
module InteractionOracle
  # A column whose values reach this magnitude looks non-additive (already an
  # aggregate / an id) — skip its sum anchor.
  NON_ADDITIVE_ABS = 1e12

  module_function

  # Caption normalizer — SAME as build-charts-from-signals.rb norm_cap.
  def norm_cap(s)
    s.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '')
  end

  # Row-order-insensitive CSV signature (probe-controls.rb semantics).
  def csv_sig(text)
    text.to_s.lines.map(&:chomp).sort
  end

  # Control selection per spec 3.2: candidates = mechanism=="filters" &&
  # status=="emitted" && targets.any?, grouped by zone_dashboards (empty ⇒
  # applies to every dashboard). Everything else lands in skips with a note.
  # Returns { 'by_dashboard' => { dash => [record,...] }, 'skips' => [...] }.
  def select_controls(scope_records, dashboards, only: [])
    dashes = Array(dashboards)
    dashes = [nil] if dashes.empty? # no layout → one implicit dashboard
    skips = []
    candidates = []
    Array(scope_records).each do |r|
      next if only.any? && !only.include?(r['controlId'])
      mech = r['mechanism'].to_s
      if mech != 'filters'
        skips << { 'controlId' => r['controlId'], 'name' => r['name'],
                   'mechanism' => mech, 'result' => 'SKIP',
                   'note' => 'parameter control — vf_ parameter semantics unverified (v2)' }
        next
      end
      unless r['status'].to_s == 'emitted' && Array(r['targets']).any?
        skips << { 'controlId' => r['controlId'], 'name' => r['name'],
                   'mechanism' => mech, 'result' => 'SKIP',
                   'note' => "status=#{r['status'].inspect} with #{Array(r['targets']).size} target(s) — not probeable" }
        next
      end
      candidates << r
    end
    by_dash = {}
    dashes.each do |dname|
      by_dash[dname] = candidates.select do |r|
        zd = Array(r['zone_dashboards'])
        zd.empty? || dname.nil? || zd.include?(dname)
      end
    end
    { 'by_dashboard' => by_dash, 'skips' => skips }
  end

  # Flip value from the paired Tableau view's cached CSV: the control's caption
  # is norm_cap-matched against the CSV header; flip = first distinct value NOT
  # in the Sigma control's saved defaults. Mirrors probe-controls.rb pick_value
  # (switch flips true/false; date/range/slider → no auto value).
  # Returns [value, note, matched_header] (value nil = skip).
  def pick_flip_value(control_name, control_type, view_csv_text, defaults)
    defaults_s = Array(defaults).map(&:to_s)
    case control_type.to_s
    when 'switch'
      return [(defaults_s.first.to_s.downcase == 'true' ? 'false' : 'true'), 'switch flip', nil]
    when 'list', 'segmented', 'text'
      table = parse_csv(view_csv_text)
      return [nil, 'no readable view CSV to pick a flip value from — pass --value', nil] if table.nil?
      hdr = (table.headers || []).compact.find { |h| norm_cap(h) == norm_cap(control_name) }
      return [nil, "column #{control_name.inspect} not in the view CSV headers — pass --value", nil] unless hdr
      distinct = table.map { |row| row[hdr] }.compact.map(&:to_s).reject(&:empty?).uniq
      val = distinct.find { |x| !defaults_s.include?(x) }
      val ? [val, "auto-picked from #{hdr.inspect}", hdr] : [nil, 'no non-default value found — pass --value', hdr]
    else
      [nil, "controlType=#{control_type.inspect} has no auto flip value (date/range/slider) — pass --value", nil]
    end
  end

  # CSV::Table or nil — BOM-stripped, malformed input never raises.
  def parse_csv(text)
    return nil if text.to_s.strip.empty?
    s = text.to_s.dup.force_encoding('UTF-8')
    s = s.encode('UTF-8', invalid: :replace, undef: :replace) unless s.valid_encoding?
    s = s.sub(/\A\uFEFF/, '') # Tableau /data CSVs open with a BOM
    CSV.parse(s, headers: true)
  rescue CSV::MalformedCSVError
    nil
  end

  # header => [raw cell strings] (nil cells dropped later per use).
  def columns_of(text)
    table = parse_csv(text)
    return {} if table.nil?
    cols = {}
    (table.headers || []).compact.each do |h|
      cols[h] = table.map { |row| row[h] }
    end
    cols
  end

  # Full-precision decimal string for a computed sum (NEVER scientific
  # notation — AnchorValues.parse can't read exponents). Two decimals ⇒
  # ±0.005 printed tolerance; match? adds 1e-9-relative slack for float noise.
  def decimal_string(v)
    format('%.2f', v)
  end

  # Anchors from the TABLEAU flipped CSV per spec 3.5.3: for each shared
  # column that is numeric (>=60% of non-empty cells AnchorValues-parseable),
  # emit max + min (as their PRINTED cell forms — tolerance comes from printed
  # precision) and sum (skipped when the column looks non-additive). The sum
  # anchor carries an explicit numeric value+tol: its tolerance must ACCUMULATE
  # the addends' printed precisions (two "$48,210"-precision cells are each
  # ±0.5, so their sum is ±1.0 — a printed-form round-trip would be too tight
  # and false-FAIL honest data).
  # shared = [tableau headers]; returns [{column:, kind:, raw:[, value:, tol:]}].
  def derive_anchors(tab_cols, shared)
    anchors = []
    shared.each do |h|
      cells = Array(tab_cols[h]).compact.map(&:to_s).reject(&:empty?)
      next if cells.empty?
      parsed = cells.map { |c| [c, AnchorValues.parse(c)] }.select { |_, p| p }
      next if parsed.length < cells.length * 0.6
      max_pair = parsed.max_by { |_, p| p[:value] }
      min_pair = parsed.min_by { |_, p| p[:value] }
      anchors << { 'column' => h, 'kind' => 'max', 'raw' => max_pair[0] }
      anchors << { 'column' => h, 'kind' => 'min', 'raw' => min_pair[0] } if min_pair[0] != max_pair[0]
      vals = parsed.map { |_, p| p[:value] }
      unless vals.any? { |x| x.abs >= NON_ADDITIVE_ABS }
        sum = vals.inject(0.0) { |a, b| a + b }
        tol = parsed.map { |_, p| p[:tol] }.inject(0.0) { |a, b| a + b }
        anchors << { 'column' => h, 'kind' => 'sum', 'raw' => decimal_string(sum),
                     'value' => sum, 'tol' => tol + 1e-9 * [sum.abs, 1.0].max }
      end
    end
    anchors
  end

  # The cross-system value oracle: derive anchors from the Tableau flipped CSV,
  # match each anywhere in the Sigma flipped CSV (plus the Sigma column's own
  # sum for sum anchors — Tableau summary grain vs Sigma element grain).
  # Returns [anchors(with 'matched'), cross(true/false/nil), note].
  def cross_anchor_match(tab_flip_csv, sigma_flip_csv)
    tab_cols = columns_of(tab_flip_csv)
    sig_cols = columns_of(sigma_flip_csv)
    shared_map = {} # tableau header => sigma header (norm_cap identity)
    tab_cols.each_key do |th|
      sh = sig_cols.keys.find { |k| norm_cap(k) == norm_cap(th) }
      shared_map[th] = sh if sh
    end
    return [[], nil, 'no shared columns between the two flipped CSVs — anchor check N/A'] if shared_map.empty?

    anchors = derive_anchors(tab_cols, shared_map.keys)
    return [[], nil, 'no shared NUMERIC columns — anchor check N/A'] if anchors.empty?

    # Found-anywhere pool: every parseable numeric value in the Sigma flip CSV.
    pool = sig_cols.values.flatten.compact.map { |c| p = AnchorValues.parse(c.to_s); p && p[:value] }.compact
    hit = lambda do |a, x|
      a['tol'] ? (x - a['value']).abs <= a['tol'] : AnchorValues.match?(a['raw'], x)
    end
    anchors.each do |a|
      matched = pool.any? { |x| hit.call(a, x) }
      if !matched && a['kind'] == 'sum' && (sh = shared_map[a['column']])
        svals = Array(sig_cols[sh]).compact.map { |c| p = AnchorValues.parse(c.to_s); p && p[:value] }.compact
        matched = svals.any? && hit.call(a, svals.inject(0.0) { |x, y| x + y })
      end
      a['matched'] = matched
    end
    matched_n = anchors.count { |a| a['matched'] }
    needed = [2, (anchors.length * 0.5).ceil].max
    [anchors, matched_n >= needed, "#{matched_n}/#{anchors.length} anchors matched (need #{needed})"]
  end

  # Verdict from the four CSVs. Check 1 gates VALIDITY (SKIP-INVALID, never
  # FAIL); checks 2 AND 3 make the verdict. cross==nil (no shared numeric
  # columns) degrades to check-2-only with the note recorded.
  def checks_for(tab_base, tab_flip, sigma_base, sigma_flip)
    unless csv_sig(tab_base) != csv_sig(tab_flip)
      return { 'checks' => { 'tableau_flip_changed' => false,
                             'sigma_flip_changed' => nil, 'cross_anchor_match' => nil },
               'anchors' => [], 'result' => 'SKIP-INVALID',
               'note' => "vf_ flip did not change the Tableau CSV — field caption didn't bite (validity gate, not a Sigma failure)" }
    end
    sflip = csv_sig(sigma_base) != csv_sig(sigma_flip)
    anchors, cross, cross_note = cross_anchor_match(tab_flip, sigma_flip)
    result = if !sflip
               'FAIL'
             elsif cross == false
               'FAIL'
             else
               'PASS'
             end
    note = []
    note << 'sigma export IDENTICAL under the flip — control is wired but inert' unless sflip
    note << cross_note if cross_note
    { 'checks' => { 'tableau_flip_changed' => true, 'sigma_flip_changed' => sflip,
                    'cross_anchor_match' => cross },
      'anchors' => anchors, 'result' => result, 'note' => note.join('; ') }
  end
end

return if $PROGRAM_NAME != __FILE__ && !ENV['VERIFY_INTERACTION_CLI'] # allow `require` in tests

# ---------------------------------------------------------------------------
# CLI — live probing.
# ---------------------------------------------------------------------------
require 'sigma_rest'
require 'code_rep'
require 'workbook_code'
require_relative 'lib/py_resolve'

opts = { values: {}, controls: [], per_dashboard: 1, timeout: 90, renders: true }
OptionParser.new do |p|
  p.on('--workdir DIR')           { |v| opts[:wd] = v }
  p.on('--workbook-id ID')        { |v| opts[:wb] = v }
  p.on('--control CID')           { |v| opts[:controls] << v }
  p.on('--value SPEC', '<controlId>=<value>') do |v|
    cid, val = v.split('=', 2)
    abort "bad --value #{v.inspect} (want <controlId>=<value>)" unless cid && val
    opts[:values][cid] = val
  end
  p.on('--per-dashboard N', Integer) { |v| opts[:per_dashboard] = v }
  p.on('--no-renders')            { opts[:renders] = false }
  p.on('--gate')                  { opts[:gate] = true }
  p.on('--timeout SECS', Integer) { |v| opts[:timeout] = v }
  p.on('--out PATH')              { |v| opts[:out] = v }
end.parse!
%i[wd wb].each { |k| abort("missing --#{k == :wd ? 'workdir' : 'workbook-id'}") unless opts[k] }
W  = opts[:wd]
WB = opts[:wb]
OUT_PATH = opts[:out] || File.join(W, 'interaction-oracle.json')
EVD = File.join(W, 'interaction')
FileUtils.mkdir_p(EVD)

require 'tableau_rest'

# Neutral-env bootstrap: mint a Tableau session when only PAT creds are present
# (same reason as render-baseline.rb — site_id raises before the 401 path).
if ENV['TABLEAU_AUTH_TOKEN'].to_s.empty? && ENV['TABLEAU_PAT_NAME'] && ENV['TABLEAU_PAT_SECRET']
  begin
    Tableau.refresh_token!
  rescue StandardError => e
    warn "WARN: PAT signin failed (#{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 120]}) — Tableau fetches will fail"
  end
end

# --- Sigma plumbing (same shapes as probe-controls.rb; that script is a
# vendored shared artifact, so the two stay independent by design) -----------
def fetch_spec(wb)
  body = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
  spec =
    if body.is_a?(Hash)
      body
    else
      require 'yaml'
      require 'date'
      YAML.safe_load(body.to_s, permitted_classes: [Date, Time]) || {}
    end
  # Workbook code-rep GETs nest pages/schemaVersion under `document` (live
  # since 2026-08); ControlLint.elements/controls_report expect a flat
  # spec['pages'] (same "unwrap at the caller, not in the lib" contract as
  # assert-datasource-filters.rb / other lint-lib callers).
  Sigma::CodeRep.metadata(spec).merge(Sigma::CodeRep.document(spec))
end

def export_csv(wb, element_id, params, timeout)
  body = { 'elementId' => element_id, 'format' => { 'type' => 'csv' } }
  body['parameters'] = params if params && !params.empty?
  res = Sigma.request(:post, "/v2/workbooks/#{wb}/export", body: JSON.generate(body))
  qid = res.is_a?(Hash) && res['queryId']
  raise "export request failed: #{res.inspect}" unless qid
  deadline = Time.now + timeout
  loop do
    uri = URI("#{Sigma.base_url}/v2/query/#{qid}/download")
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{Sigma.auth_token}"
    r = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |h| h.request(req) }
    return r.body if r.code.to_i == 200
    raise "export download failed: HTTP #{r.code} #{r.body.to_s[0, 300]}" if r.code.to_i >= 400 && r.code.to_i != 404
    raise "export timed out after #{timeout}s (queryId=#{qid})" if Time.now > deadline
    sleep 2
  end
end

# --- inputs ------------------------------------------------------------------
scope_path = File.join(W, 'control-scope.json')
unless File.exist?(scope_path)
  warn 'no control-scope.json in the workdir — nothing probeable (run build-charts-from-signals first)'
  exit 2
end
scope = JSON.parse(File.read(scope_path))
scope_records = scope.is_a?(Hash) ? (scope['controls'] || []) : Array(scope)

layout = ((JSON.parse(File.read(File.join(W, 'dashboard-layout.json'))) rescue nil) || [])
dashboards = layout.map { |d| d['dashboard'] }.reject { |n| n.to_s.start_with?('[synthetic]') }

gw = (JSON.parse(File.read(File.join(W, 'get-workbook.json'))) rescue {})
gviews = gw.dig('views', 'view') || []
gviews = [gviews] unless gviews.is_a?(Array)
view_id_by_name = lambda do |vname|
  v = gviews.find { |vv| (vv['name'] || '').strip == vname.to_s.strip } ||
      gviews.find { |vv| (vv['name'] || '').strip.casecmp?(vname.to_s.strip) }
  v && v['id']
end

parity = (JSON.parse(File.read(File.join(W, 'parity-plan.json'))) rescue {})
tableau_view_by_element = {}
Array(parity['charts']).each do |c|
  tableau_view_by_element[c['sigma_element_id']] = c['tableau_view'] if c['sigma_element_id'] && c['tableau_view']
end

wb_ids = (JSON.parse(File.read(File.join(W, 'wb-ids.json'))) rescue {})
page_id_by_name = WorkbookCode.pages(wb_ids).each_with_object({}) { |p, h| h[p['name']] = p['id'] if p['name'] }

spec  = fetch_spec(WB)
elems = ControlLint.elements(spec)
lint_rows = ControlLint.controls_report(spec)
row_by_cid = lint_rows.each_with_object({}) { |r, h| h[r[:control_id]] = r if r[:control_id] }

slugify = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')[0..50] }
png_script = File.join(__dir__, 'sigma-export-png.py')

sel = InteractionOracle.select_controls(scope_records, dashboards, only: opts[:controls])

results = sel['skips'].dup
probed_cids = Set.new
baseline_cache = {}

sel['by_dashboard'].each do |dash, cands|
  taken = 0
  cands.each do |r|
    break if taken >= opts[:per_dashboard]
    cid = r['controlId']
    next if probed_cids.include?(cid)
    rec = { 'controlId' => cid, 'name' => r['name'], 'dashboard' => dash,
            'mechanism' => 'filters' }

    # --- element pairing (spec 3.3): first queryable element in the control's
    # live reach that parity-plan pairs to a Tableau view ---------------------
    row = row_by_cid[cid]
    if row.nil?
      results << rec.merge('result' => 'SKIP', 'note' => 'control not present in the live workbook spec')
      next
    end
    ordered = (row[:page_queryable] & row[:reach].to_a) + (row[:reach].to_a - row[:page_queryable])
    pair = nil
    ordered.each do |eid|
      info = elems[eid]
      next unless info && ControlLint::QUERYABLE.include?(info[:kind])
      tv = tableau_view_by_element[eid]
      next unless tv
      vid = view_id_by_name.call(tv)
      next unless vid
      pair = { eid: eid, tableau_view: tv, vid: vid }
      break
    end
    if pair.nil?
      results << rec.merge('result' => 'SKIP',
                           'note' => 'no pairable element (queryable + in parity-plan with a resolvable Tableau view) in the control reach')
      next
    end
    rec['tableau_view'] = pair[:tableau_view]
    rec['view_id']      = pair[:vid]
    rec['element_id']   = pair[:eid]
    rec['page_id']      = page_id_by_name[dash] if dash

    # --- flip value (spec 3.3): --value wins; else offline from the cached
    # view CSV vs the Sigma control's saved defaults --------------------------
    ctl_el = elems[row[:control_element_id]] && elems[row[:control_element_id]][:el]
    cached_csv_path = File.join(W, 'views', "#{pair[:vid]}.csv")
    tab_base = File.exist?(cached_csv_path) ? File.read(cached_csv_path) : nil
    begin
      tab_base ||= Tableau.view_data_filtered(pair[:vid])
    rescue StandardError => e
      results << rec.merge('result' => 'SKIP', 'note' => "Tableau baseline CSV fetch failed: #{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 120]}")
      next
    end

    matched_header = nil
    if opts[:values].key?(cid)
      value, vnote = opts[:values][cid], 'explicit --value'
    else
      value, vnote, matched_header =
        InteractionOracle.pick_flip_value(r['name'], ctl_el && ctl_el['controlType'],
                                          tab_base, ctl_el && ctl_el['values'])
    end
    if value.nil?
      results << rec.merge('result' => 'SKIP', 'note' => vnote)
      next
    end
    rec['value'] = value

    slug = slugify.call(cid)
    probed_cids << cid
    taken += 1

    begin
      File.write(File.join(EVD, "#{slug}.tableau.base.csv"), tab_base)

      # --- Tableau flip (vf_) with the caption; one retry with the view CSV's
      # exact header spelling when the caption didn't bite ---------------------
      vf_field = r['name'].to_s
      tab_flip = Tableau.view_data_filtered(pair[:vid], filters: { vf_field => value })
      if InteractionOracle.csv_sig(tab_base) == InteractionOracle.csv_sig(tab_flip) &&
         matched_header && matched_header != vf_field
        vf_field = matched_header
        tab_flip = Tableau.view_data_filtered(pair[:vid], filters: { vf_field => value })
        vnote = "#{vnote}; retried vf_ with exact header #{vf_field.inspect}"
      end
      rec['vf_field'] = vf_field
      File.write(File.join(EVD, "#{slug}.tableau.flip.csv"), tab_flip)

      # --- Sigma base + flip (export API parameters — the proven channel) ----
      sigma_base = (baseline_cache[pair[:eid]] ||= export_csv(WB, pair[:eid], nil, opts[:timeout]))
      sigma_flip = export_csv(WB, pair[:eid], { cid => value }, opts[:timeout])
      File.write(File.join(EVD, "#{slug}.sigma.base.csv"), sigma_base)
      File.write(File.join(EVD, "#{slug}.sigma.flip.csv"), sigma_flip)

      verdict = InteractionOracle.checks_for(tab_base, tab_flip, sigma_base, sigma_flip)
      rec.merge!(verdict)
      rec['note'] = [vnote, rec['note']].reject { |x| x.to_s.empty? }.join('; ')

      # --- advisory render evidence (never part of the verdict) --------------
      if opts[:renders] && rec['result'] != 'SKIP-INVALID'
        renders = {}
        begin
          dash_vid = dash && view_id_by_name.call(dash)
          if dash_vid
            File.binwrite(File.join(EVD, "#{slug}.tableau.png"),
                          Tableau.view_image(dash_vid, filters: { vf_field => value }))
            renders['tableau'] = "interaction/#{slug}.tableau.png"
          end
        rescue StandardError
          nil # evidence only — silent
        end
        if rec['page_id']
          ok = system(*PyResolve.argv, PyResolve.winpath(png_script), '--workbook', WB, '--page', rec['page_id'],
                      '--param', "#{cid}=#{value}",
                      '--out', PyResolve.winpath(File.join(EVD, "#{slug}.sigma.png")),
                      out: File::NULL, err: File::NULL)
          renders['sigma'] = "interaction/#{slug}.sigma.png" if ok && File.size?(File.join(EVD, "#{slug}.sigma.png"))
        end
        rec['renders'] = renders unless renders.empty?
      end
    rescue StandardError => e
      rec['result'] = 'SKIP'
      rec['note'] = [rec['note'], "probe error: #{e.class}: #{e.message.to_s.lines.first.to_s.strip[0, 160]}"].compact.join('; ')
    end
    results << rec
  end
end

probed  = results.count { |x| %w[PASS FAIL].include?(x['result']) }
passed  = results.count { |x| x['result'] == 'PASS' }
failed  = results.count { |x| x['result'] == 'FAIL' }
skipped = results.count { |x| x['result'].to_s.start_with?('SKIP') }

out = { 'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'workbook_id' => WB, 'advisory' => !opts[:gate],
        'controls' => results,
        'summary' => { 'probed' => probed, 'passed' => passed,
                       'failed' => failed, 'skipped' => skipped } }
File.write(OUT_PATH, JSON.pretty_generate(out))

warn format('interaction oracle: %d probed / %d passed / %d failed / %d skipped → %s',
            probed, passed, failed, skipped, OUT_PATH)
results.each do |x|
  warn format('  %-7s %-20s %s', x['result'], x['controlId'],
              [x['value'] && "flip=#{x['value'].inspect}", x['note']].compact.join('; ')[0, 160])
end

if probed.zero?
  warn 'NOTHING PROBEABLE: no emitted mechanism=filters control with a resolvable flip value + pairable element.'
  exit 2
end
exit 15 if opts[:gate] && failed.positive?
exit 0
