#!/usr/bin/env ruby
# frozen_string_literal: true
# Compare each built Sigma chart's exported values against the Lightdash oracle rows
# (expected/<slug>.json from lightdash-query-oracle.rb). Per-chart PASS / FAIL / SKIP, written to
# parity-report.json, plus parity-final.json (the marker assert-phase6-ran.rb requires).
#
#   ruby scripts/verify-lightdash-parity.rb --workbook-id <id> --workbook-map workbook-map.json \
#     --expected-dir expected --out parity-report.json --final-out parity-final.json [--workbook-spec wb-spec.json] [--warehouse-only]
#
# Compares against the VISIBLE chart element (workbook-map element_id) via the Sigma element export
# (POST /v2/workbooks/{id}/export, poll GET /v2/query/{id}/download), like verify-omni-parity.rb.
# Tolerances: numbers within 1e-6 relative or 0.005 absolute; currency symbols and thousands separators
# in the export are stripped; `12.5%` and compact `1.2K/M/B` exports compare as numbers (compact ones within half
# a unit of the last shown digit); dates compare on the calendar day; rows are compared order-insensitively.
# TEST-ONLY flags (never use in a real run): --fixture (fake Sigma export CSVs), --wh-fixture (forwarded to
# verify-warehouse.rb --fixture).
# Oracle mode: a non-placeholder chart with no expected/<slug>.json is a FAIL (it must not leave the gate); a
# chart whose oracle result was flagged `unsorted_limit` (limit, dimensions, sort not a total order) is a SKIP with that reason.
#
# SKIP(gap): placeholder elements (chart-gaps.json explains them).
# Offline (no expected/*.json = no Lightdash credentials): delegates to verify-warehouse.rb for charts
# that have a compiled expected/<slug>.sql (every chart with --warehouse-only), which only proves each
# element evaluates against the warehouse and returns data (verified_against=warehouse); other charts SKIP
# with a reason. Exit 0 PASS, 2 FAIL (or nothing verified), 1 bad invocation.

require 'optparse'
require 'json'
require 'csv'
require 'time'
require 'open3'
require 'fileutils'
require 'rbconfig'

module LightdashParity
  module_function

  ABS_TOL = 0.005
  REL_TOL = 1e-6

  SUFFIX = { '%' => 0.01, 'k' => 1e3, 'm' => 1e6, 'b' => 1e9 }.freeze

  # [value, tolerance] or nil. `12.5%` -> 0.125, `1.2K` -> 1200. A suffixed (rounded) display is
  # accurate only to half a unit of its last shown digit, so its tolerance widens accordingly.
  def numeric_tol(v)
    return [v.to_f, nil] if v.is_a?(Numeric)
    s = v.to_s.strip
    s = s.delete('$€£,') if s =~ /\A[$€£]?-?[\d,]+(\.\d+)?\s*[%KMBkmb]?\z/
    if (m = /\A(-?\d+(\.\d+)?)\s*([%KMBkmb])\z/.match(s))
      mult = SUFFIX[m[3].downcase]
      return [m[1].to_f * mult, 0.5 * (10**-(m[2] ? m[2].length - 1 : 0)) * mult]
    end
    s =~ /\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z/ ? [s.to_f, nil] : nil
  end

  def numeric(v)
    (numeric_tol(v) || [nil]).first
  end

  def day(v)
    s = v.to_s.strip
    return nil unless s =~ /\A\d{4}-\d{2}-\d{2}|\A\d{1,2}\/\d{1,2}\/\d{4}/
    Time.parse(s).utc.strftime('%Y-%m-%d')
  rescue ArgumentError
    nil
  end

  def cell_equal?(exp, act)
    return act.to_s.strip.empty? if exp.nil?
    a, = numeric_tol(exp)
    b, btol = numeric_tol(act)
    return (a - b).abs <= [ABS_TOL, REL_TOL * a.abs, btol || 0].max if a && b
    ed = day(exp)
    ad = day(act)
    return ed == ad if ed && ad
    exp.to_s.strip == act.to_s.strip
  end

  def sort_key(row, cols)
    cols.map { |c| numeric(row[c]) ? [1, format('%020.4f', numeric(row[c]) + 1e12)] : [0, row[c].to_s.strip] }
  end

  # -> [pass?, reason]
  def compare(expected, csv_text)
    table = CSV.parse(csv_text.to_s, headers: true)
    headers = table.headers.compact.map { |h| h.to_s.strip }
    cols = expected['columns']
    missing = cols.reject { |c| headers.any? { |h| h.casecmp?(c) } }
    return [false, "column(s) absent from the Sigma export: #{missing.join(', ')}"] unless missing.empty?
    pick = ->(c) { headers.find { |h| h.casecmp?(c) } }
    actual = table.map { |r| cols.each_with_object({}) { |c, h| h[c] = r[pick.call(c)] } }
    exp_rows = expected['rows']
    if exp_rows.length != actual.length
      return [false, "row count: Lightdash #{exp_rows.length}, Sigma #{actual.length}"]
    end
    ea = exp_rows.sort_by { |r| sort_key(r, cols) }
    aa = actual.sort_by { |r| sort_key(r, cols) }
    ea.each_with_index do |er, i|
      cols.each do |c|
        next if cell_equal?(er[c], aa[i][c])
        return [false, "row #{i + 1} column #{c}: Lightdash #{er[c].inspect}, Sigma #{aa[i][c].inspect}"]
      end
    end
    [true, "#{exp_rows.length} row(s) match"]
  end

  TRANSIENT = /\b(429|408|50[234])\b|Too Many Requests|timed? ?out/i.freeze

  def sigma_export_csv(workbook_id, element_id, timeout: 60)
    require_relative 'lib/sigma_rest'
    attempts = 0
    begin
      attempts += 1
      r = Sigma.request(:post, "/v2/workbooks/#{workbook_id}/export",
                        body: JSON.generate(elementId: element_id, format: { type: 'csv' }))
      qid = r && r['queryId']
      raise Sigma::Error, "export POST returned no queryId: #{r.inspect[0, 120]}" unless qid
      t0 = Time.now
      loop do
        raise Sigma::Error, "export poll timed out (#{timeout}s)" if Time.now - t0 > timeout
        sleep 1.0
        body = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        return body if body && !body.to_s.empty?
      end
    rescue Sigma::Error => e
      if attempts < 4 && e.message.lines.first.to_s =~ TRANSIENT
        sleep(1.5 * (2**(attempts - 1)))
        retry
      end
      raise
    end
  end

  def load_expected(dir, slug)
    path = File.join(dir.to_s, "#{slug.tr('#', '_')}.json")
    File.file?(path) ? JSON.parse(File.read(path, encoding: 'UTF-8')) : nil
  end

  # Online leg: results = [{chart, element_id, status, reason}]. `exporter` is (element_id) -> csv text.
  def verify(workbook_map, expected_dir, exporter)
    workbook_map.map do |slug, entry|
      row = { 'chart' => slug, 'element_id' => entry['element_id'] }
      if entry['placeholder']
        next row.merge('status' => 'SKIP', 'reason' => 'gap: placeholder element (see chart-gaps.json)')
      end
      exp = load_expected(expected_dir, slug)
      # oracle mode: a data chart with no oracle rows must not leave the gate silently
      next row.merge('status' => 'FAIL', 'reason' => 'no oracle rows for this data chart (oracle skipped or failed; see lightdash-query-oracle.rb output)') unless exp
      if exp['unsorted_limit']
        next row.merge('status' => 'SKIP', 'reason' => "row limit #{exp['limit']} without a total-order sort: which rows Lightdash returns is not deterministic, so values were not compared")
      end
      begin
        ok, why = compare(exp, exporter.call(entry['element_id']))
        row.merge('status' => ok ? 'PASS' : 'FAIL', 'reason' => why)
      rescue StandardError => e # export/parse failure is a FAIL for this chart, with the reason recorded
        row.merge('status' => 'FAIL', 'reason' => e.message.lines.first.to_s.strip[0, 160])
      end
    end
  end

  def final_summary(results, workbook_id:, verified_against:)
    pass = results.select { |r| r['status'] == 'PASS' }
    fail = results.select { |r| r['status'] == 'FAIL' }
    {
      'workbook_id' => workbook_id, 'ran_at' => Time.now.utc.iso8601, 'verified_against' => verified_against,
      'charts_total' => pass.size + fail.size, 'charts_pass' => pass.size, 'charts_fail' => fail.size,
      'charts_skipped' => results.count { |r| r['status'] == 'SKIP' },
      'pass_names' => pass.map { |r| r['chart'] }, 'fail_names' => fail.map { |r| r['chart'] },
      'skip_names' => results.select { |r| r['status'] == 'SKIP' }.map { |r| r['chart'] },
      'status' => fail.empty? && !pass.empty? ? 'PASS' : 'FAIL'
    }
  end

  # Offline leg: builds the verify-warehouse.rb plan for `slugs` and runs it; returns results rows.
  def warehouse_leg(workbook_map, slugs, workbook_id, spec_path, final_out, fixture: nil)
    plan = slugs.map do |slug|
      e = workbook_map[slug]
      { 'chart' => slug, 'sigma_element_id' => e['element_id'], 'sigma_kind' => e['kind'],
        'sigma_columns' => (e['columns'] || {}).values.map { |c| c['id'] } }
    end
    plan_path = File.join(File.dirname(File.expand_path(final_out)), 'parity-plan.json')
    File.write(plan_path, JSON.pretty_generate(plan) + "\n")
    # Fixed sibling script, argv list, no shell.
    args = ['--plan', plan_path, '--workbook-id', workbook_id.to_s, '--workbook-spec', spec_path.to_s, '--out', final_out]
    args += ['--fixture', fixture] if fixture
    _out, err, = Open3.capture3(RbConfig.ruby, File.expand_path('verify-warehouse.rb', __dir__), *args)
    warn err unless err.empty?
    wf = File.file?(final_out) ? JSON.parse(File.read(final_out, encoding: 'UTF-8')) : {}
    slugs.map do |slug|
      st = Array(wf['pass_names']).include?(slug) ? 'PASS' : 'FAIL'
      { 'chart' => slug, 'element_id' => workbook_map[slug]['element_id'], 'status' => st,
        'reason' => st == 'PASS' ? 'element evaluates against the warehouse and returns data (not diffed against Lightdash)' : 'warehouse leg failed (see verify-warehouse output)' }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = { expected: 'expected', out: 'parity-report.json', final: 'parity-final.json', spec: 'wb-spec.json' }
  OptionParser.new do |o|
    o.on('--workbook-id ID') { |v| opts[:wb] = v }
    o.on('--workbook-map PATH') { |v| opts[:map] = v }
    o.on('--expected-dir DIR') { |v| opts[:expected] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--final-out PATH') { |v| opts[:final] = v }
    o.on('--workbook-spec PATH') { |v| opts[:spec] = v }
    o.on('--warehouse-only') { opts[:wh_only] = true }
    o.on('--fixture PATH', 'TEST ONLY: {"<element_id>": "<csv>"} instead of the Sigma export API') { |v| opts[:fixture] = v }
    o.on('--wh-fixture PATH', 'TEST ONLY: forwarded to verify-warehouse.rb --fixture') { |v| opts[:wh_fixture] = v }
  end.parse!(ARGV)
  { wb: '--workbook-id', map: '--workbook-map' }.each { |k, f| abort "missing #{f}" if opts[k].to_s.empty? }
  wmap = JSON.parse(File.read(opts[:map], encoding: 'UTF-8'))
  fixture = opts[:fixture] && JSON.parse(File.read(opts[:fixture], encoding: 'UTF-8'))
  oracle = wmap.keys.any? { |s| LightdashParity.load_expected(opts[:expected], s) }

  if oracle
    exporter = fixture ? ->(id) { fixture.fetch(id) } : ->(id) { LightdashParity.sigma_export_csv(opts[:wb], id) }
    results = LightdashParity.verify(wmap, opts[:expected], exporter)
    against = 'lightdash_runquery'
  else
    slugs = wmap.reject { |_, e| e['placeholder'] }.keys.select do |s|
      opts[:wh_only] || File.file?(File.join(opts[:expected], "#{s.tr('#', '_')}.sql"))
    end
    ran = slugs.empty? ? [] : LightdashParity.warehouse_leg(wmap, slugs, opts[:wb], opts[:spec], opts[:final], fixture: opts[:wh_fixture])
    results = wmap.map do |slug, e|
      ran.find { |r| r['chart'] == slug } ||
        { 'chart' => slug, 'element_id' => e['element_id'], 'status' => 'SKIP',
          'reason' => e['placeholder'] ? 'gap: placeholder element (see chart-gaps.json)' :
                      'no Lightdash oracle rows and no compiled SQL; run lightdash-query-oracle.rb (live) or pass --warehouse-only to verify the element evaluates' }
    end
    against = 'warehouse'
  end

  final = LightdashParity.final_summary(results, workbook_id: opts[:wb], verified_against: against)
  File.write(opts[:out], JSON.pretty_generate('workbook_id' => opts[:wb], 'verified_against' => against, 'charts' => results,
                                              'counts' => { 'pass' => final['charts_pass'], 'fail' => final['charts_fail'], 'skip' => final['charts_skipped'] }) + "\n")
  if against == 'warehouse'
    final['mode'] = 'warehouse'
    final['note'] = 'Offline mode: each element verified to evaluate against the warehouse and return data. NOT diffed against Lightdash.'
  end
  File.write(opts[:final], JSON.pretty_generate(final) + "\n")
  results.each { |r| warn "  #{r['status']}  #{r['chart']}: #{r['reason']}" }
  warn "parity: #{final['charts_pass']} pass, #{final['charts_fail']} fail, #{final['charts_skipped']} skip -> #{final['status']} (#{against})"
  exit(final['status'] == 'PASS' ? 0 : 2)
end
