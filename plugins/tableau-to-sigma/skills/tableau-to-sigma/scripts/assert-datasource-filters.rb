#!/usr/bin/env ruby
# frozen_string_literal: true
#
# assert-datasource-filters.rb — hard gate: did the built workbook APPLY every
# Tableau DATA-SOURCE-level (always-on) filter the source carried? (#483)
#
# A Tableau data-source filter (a <filter> on a <datasource>/<extract>, or a
# database-domain filter hosted in a virtual-connection <shared-view>, e.g.
# `company_active = true`) row-scopes EVERY worksheet on the datasource and
# renders NOTHING on any dashboard surface. So the Phase-1d "read the PNG" gate
# structurally CANNOT catch a miss: a dropped data-source filter makes the
# migrated workbook query unfiltered data and every aggregate silently
# over-reports (field signature: a uniform ~20-25% inflation across unrelated
# distinct counts). parse-twb-layout.rb tags these in <workdir>/
# dashboard-layout-meta.json (datasource_filters + shared_filters
# is_datasource_filter). This gate fetches the LIVE posted spec and FAILS
# (exit 1) unless each tagged filter is APPLIED as a workbook-wide default
# filter on the master (an always-on `active` flag MUST be applied, not left as
# a user-widenable control) or — for a non-flag filter — at least surfaced as a
# control. No token / non-200 → stated SKIP (exit 0; never a silent pass), same
# as assert-phase6-ran's live sub-gates.
#
# Kept a STANDALONE tableau-local gate (not a block inside the SHARED
# assert-phase6-ran.rb) so this plugin-specific check ships in one plugin PR
# without forking shared infra. migrate-tableau.rb --finalize runs it and folds
# its result into the GREEN decision; run it standalone per SKILL.md Phase 6.
#
# Usage:
#   ruby assert-datasource-filters.rb --workdir <WORK> [--workbook-id <id>] \
#        [--skip-datasource-filters "<reason>"]
require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require_relative 'lib/datasource_filter_check'

opts = {}
OptionParser.new do |p|
  p.on('--workdir PATH', '--tableau PATH') { |v| opts[:work] = v }
  p.on('--workbook-id ID')                 { |v| opts[:wb] = v }
  p.on('--skip-datasource-filters REASON') { |v| opts[:skip] = v }
end.parse!(ARGV)

work = opts[:work]
abort 'usage: assert-datasource-filters.rb --workdir <WORK> [--workbook-id <id>]' if work.nil? || work.empty?

if opts[:skip]
  puts "[WAIVED] datasource-filter gate — --skip-datasource-filters: #{opts[:skip]}"
  puts '         (name this waiver in your migration report; an always-on data-source filter left'
  puts '          unapplied means every aggregate over-reports.)'
  begin
    $LOAD_PATH.unshift File.expand_path('lib', __dir__)
    require 'offramp'
    Offramp.log(work, kind: 'skip-flag-waived', reason: opts[:skip],
                detail: '--skip-datasource-filters')
  rescue LoadError
    warn '       WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
  end
  exit 0
end

meta_path = File.join(work, 'dashboard-layout-meta.json')
unless File.exist?(meta_path)
  puts "[SKIP] datasource-filter gate: no dashboard-layout-meta.json in #{work} — census unavailable"
  exit 0
end
meta = JSON.parse(File.read(meta_path)) rescue nil
ds = []
if meta.is_a?(Hash)
  ds.concat(Array(meta['datasource_filters']))
  ds.concat(Array(meta['shared_filters']).select { |f| f.is_a?(Hash) && f['is_datasource_filter'] })
end
ds = ds.select { |f| f.is_a?(Hash) && !f['is_action'] && !f['column_caption'].to_s.strip.empty? }
if ds.empty?
  puts '[OK] datasource-filter gate: source carried no always-on data-source filters — nothing to apply'
  exit 0
end

wb_id = opts[:wb]
if wb_id.nil?
  wbp = File.join(work, 'wb-ids.json')
  wb_id = (JSON.parse(File.read(wbp))['workbookId'] rescue nil) if File.exist?(wbp)
end
base = ENV['SIGMA_BASE_URL']
tok  = ENV['SIGMA_API_TOKEN']
if wb_id.nil? || wb_id.to_s.empty?
  puts "[SKIP] datasource-filter gate: no workbook ID resolvable — cannot verify #{ds.size} data-source filter(s)"
  exit 0
elsif base.nil? || base.empty? || tok.nil? || tok.empty?
  puts "[SKIP] datasource-filter gate: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec to verify #{ds.size} data-source filter(s)"
  exit 0
end

uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
req = Net::HTTP::Get.new(uri)
req['Authorization'] = "Bearer #{tok}"
req['Accept'] = 'application/json'
res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
unless res.is_a?(Net::HTTPSuccess)
  puts "[SKIP] datasource-filter gate: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot verify"
  exit 0
end
spec =
  begin
    JSON.parse(res.body)
  rescue JSON::ParserError
    require 'yaml'
    require 'date'
    YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
  end

filter_shelf = []
pr = File.join(work, 'png-read.json')
if File.exist?(pr)
  pj = JSON.parse(File.read(pr)) rescue nil
  filter_shelf = Array(pj['filter_shelf']) if pj.is_a?(Hash)
end

violations = DatasourceFilterCheck.violations(
  datasource_filters: ds, filter_shelf: filter_shelf, spec: spec, master_id: 'master'
)
if violations.any?
  warn "[FAIL] datasource-filter gate: #{violations.length} always-on data-source filter(s) not applied on workbook #{wb_id}:"
  violations.each { |v| warn "         - #{v}" }
  warn '       These render nothing on any dashboard, so a visual check cannot catch the miss — every'
  warn '       aggregate silently over-reports until they are applied. Apply each as a workbook-wide'
  warn '       default filter on the master element (element filters {id, columnId, kind:"list", values:[...]} —'
  warn '       the id is required; the spec API rejects filters without it),'
  warn '       re-PUT, and re-run. Escape hatch: --skip-datasource-filters "<reason>" (name it in your report).'
  exit 1
end
puts "[OK] datasource-filter gate: all #{ds.size} always-on data-source filter(s) applied (or surfaced as controls) on workbook #{wb_id}"
exit 0
