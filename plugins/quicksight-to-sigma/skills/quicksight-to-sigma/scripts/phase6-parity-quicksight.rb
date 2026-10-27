#!/usr/bin/env ruby
# Phase 7 (MANDATORY) — verify Sigma chart values match the QuickSight source.
#
# QuickSight's describe-*-definition APIs return definitions, not data, so the
# EXPECTED side comes from the warehouse (the same tables the QS dataset reads):
# the agent computes each chart's aggregation with a warehouse SQL query
# (mcp__sigma-mcp-v2__query type=connection) or, when live QS access exists,
# from a QS export. The ACTUAL side is the built Sigma element. This script
# orchestrates both passes and writes the parity-final.json sentinel that
# assert-phase6-ran.rb (the hard gate) requires.
#
# PASS 1 — read the workbook spec, enumerate chart elements, emit per-chart
# fetch instructions:
#
#   ruby scripts/phase6-parity-quicksight.rb --workdir /tmp/<name> \
#     --workbook-id <wb>
#
#   Writes <workdir>/parity-plan.json and prints, per chart:
#     - the mcp__sigma-mcp-v2__query call for the Sigma ACTUAL rows
#     - a reminder to compute EXPECTED rows from the warehouse with the
#       same dimension + aggregation
#
#   The agent then writes two JSON files keyed by chart name, each
#   { "<chart name>": [[dim, val], ...], ... } :
#     <workdir>/parity-expected.json   (warehouse / QS ground truth)
#     <workdir>/parity-actuals.json    (Sigma element rows)
#   KPI charts have no dimension — use [[null, <value>]].
#
# PASS 2 — finalize:
#
#   ruby scripts/phase6-parity-quicksight.rb --workdir /tmp/<name> --finalize \
#     [--expected <workdir>/parity-expected.json] \
#     [--actuals  <workdir>/parity-actuals.json] \
#     [--extract-mode] [--extract-tol 0.30]
#
#   Runs verify-parity.rb, prints the pass/fail summary, writes
#   parity-final.txt + parity-final.json (the hard-gate sentinel).
#
# Plain `table` elements have no single dim/measure axis, so they get a PROFILE
# check instead of value parity (kind `table-profile`): the table's row count plus,
# for every visible column, its non-null and distinct counts. The expected side comes
# from the same warehouse query the QuickSight dataset reads, WITH the QuickSight
# filters applied (dataset filters and FilterGroups), so a filter the builder could not
# migrate shows up as a row-count divergence. A profile is weaker evidence than value
# parity and is labelled as such everywhere (plan, console, parity-final.json).
# Content elements with no plan at all (pivot-table, progress, maps, ...) are listed
# under `not_planned` in parity-plan.json and on the console — never silently skipped.

require 'json'
require 'optparse'
require 'open3'
require 'set'
require 'time'

opts = { extract_mode: false, extract_tol: 0.30, finalize: false }
OptionParser.new do |p|
  p.on('--workdir DIR')          { |v| opts[:dir] = v }
  p.on('--workbook-id ID')       { |v| opts[:wb] = v }
  p.on('--finalize')             { opts[:finalize] = true }
  p.on('--expected PATH')        { |v| opts[:expected] = v }
  p.on('--actuals PATH')         { |v| opts[:actuals] = v }
  p.on('--extract-mode')         { opts[:extract_mode] = true }
  p.on('--extract-tol F', Float) { |v| opts[:extract_tol] = v }
end.parse!
abort('missing --workdir') unless opts[:dir]

plan_path = File.join(opts[:dir], 'parity-plan.json')

def parse_spec(body)
  JSON.parse(body)
rescue JSON::ParserError
  require 'yaml'
  require 'date'
  YAML.safe_load(body, permitted_classes: [Date, Time]) || {}
end

# Resolve the (dim, val) columns for a chart element, by kind. Returns
# [[dim_id, dim_name], [val_id, val_name]] (dim pair nil for KPI) or nil if not
# plannable. The IDs matter: sigma-mcp-v2 workbook queries resolve COLUMN IDS, not
# display labels — SQL emitted against display names fails to resolve.
def chart_columns(el)
  cols = el['columns'] || []
  by_id = cols.each_with_object({}) { |c, h| h[c['id']] = c['name'] }
  case el['kind']
  when 'kpi-chart'
    vid = el.dig('value', 'columnId') || el.dig('value', 'id')
    by_id[vid] && [nil, [vid, by_id[vid]]]
  when 'pie-chart', 'donut-chart'
    did = el.dig('color', 'id') || el.dig('color', 'columnId')
    vid = el.dig('value', 'id') || el.dig('value', 'columnId')
    by_id[did] && by_id[vid] ? [[did, by_id[did]], [vid, by_id[vid]]] : nil
  else # bar-chart, line-chart, combo-chart, scatter-chart, ...
    did = el.dig('xAxis', 'columnId')
    vid = Array(el.dig('yAxis', 'columnIds')).first
    vid = vid['columnId'] if vid.is_a?(Hash) # combo dual-axis object form
    by_id[did] && by_id[vid] ? [[did, by_id[did]], [vid, by_id[vid]]] : nil
  end
end


# Element kinds that carry no data to verify (controls, text, navigation, containers...).
NON_DATA_KIND = /control|\Atext\z|\Aimage\z|\Abutton|container|\Aiframe|\Aembed|\Adivider|\Anavigation\z|\Apage-break\z|\Alegend/i.freeze

PROFILE_CHECK_LABEL = 'PROFILE check (row count + per-column non-null/distinct counts) — not value parity'.freeze

def element_title(el)
  n = el['name']
  n = n['text'] if n.is_a?(Hash) # hidden-title elements carry a visibility hash
  n = n.to_s.strip
  n = el['title'].to_s.strip if n.empty?
  n.empty? ? el['id'].to_s : n
end

# { element_id => page metadata }. Layout XML is authoritative for page membership in
# the flat workbook shape; a legacy page-nested artifact carries it by nesting instead.
def element_pages(doc)
  by_element = Sigma::CodeRep.workbook_page_by_element(doc)
  Array(doc['pages']).each do |pg|
    next unless pg.is_a?(Hash)
    Array(pg['elements']).each { |e| by_element[e['id']] ||= pg if e.is_a?(Hash) && e['id'] }
  end
  by_element
end

# Ids the builder wrote as Data-page elements (master + secondary masters + hidden
# scatter/repeat sources). <workdir>/wb-spec.map.json is local; absent => [].
def builder_data_element_ids(workdir)
  map = JSON.parse(File.read(File.join(workdir, 'wb-spec.map.json'), encoding: 'UTF-8'))
  Array(map['dataElementIds']).to_set
rescue StandardError
  Set.new
end

# Display-name labels for a profile check, in the order the SQL returns them:
# row_count, then "<column>: non_null" and "<column>: distinct" per visible column.
def profile_labels(names)
  seen = Hash.new(0)
  labels = ['row_count']
  names.each do |n|
    seen[n] += 1
    base = seen[n] == 1 ? n : "#{n} (#{seen[n]})"
    labels << "#{base}: non_null"
    labels << "#{base}: distinct"
  end
  labels
end

# One aggregate row: COUNT(*) + COUNT(col) + COUNT(DISTINCT col) per visible column.
# Queried by COLUMN ID like every other plan query (sigma-mcp-v2 cannot resolve labels).
def profile_sql(element_id, ids)
  sel = ['COUNT(*) AS row_count']
  ids.each_with_index do |id, i|
    sel << %(COUNT("#{id}") AS nn_#{i + 1})
    sel << %(COUNT(DISTINCT "#{id}") AS dc_#{i + 1})
  end
  %(SELECT #{sel.join(', ')} FROM "workbook"."#{element_id}")
end

if !opts[:finalize]
  abort('--workbook-id required for pass 1') unless opts[:wb]
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
  require 'code_rep'

  warn "Phase 7 PASS 1: reading workbook spec #{opts[:wb]}"
  # binary:true returns the raw body — the spec endpoint answers in YAML even
  # when asked for JSON, so parse both.
  raw = Sigma.request(:get, "/v2/workbooks/#{opts[:wb]}/spec", binary: true)
  # Live GET nests non-metadata fields under `document` (verified 2026-08-03/04);
  # unwrap so the on-disk wb-readback.json stays the plain document (pages metadata,
  # flat elements, layout) every downstream reader expects.
  spec = Sigma::CodeRep.document(parse_spec(raw))
  File.write(File.join(opts[:dir], 'wb-readback.json'), JSON.pretty_generate(spec))

  # Workbook elements are a FLAT `document.elements` collection; page membership comes
  # from the layout (pages are metadata only). Skip everything on the hidden Data page.
  pages_by_element = element_pages(spec)
  data_ids = builder_data_element_ids(opts[:dir])
  charts = []
  not_planned = []
  taken = Set.new
  unique_name = lambda do |base|
    cand = base
    k = 1
    while taken.include?(cand)
      k += 1
      cand = "#{base} (#{k})"
    end
    taken << cand
    cand
  end
  Sigma::CodeRep.workbook_elements(spec).each do |el|
    page = pages_by_element[el['id']]
    next if page && page['visibility'].to_s == 'hidden'
    next if data_ids.include?(el['id']) || el['visibleAsSource'] == false
    kind = el['kind'].to_s
    next if kind.empty? || kind =~ NON_DATA_KIND
    title = element_title(el)
    if kind.end_with?('-chart')
      pairs = chart_columns(el)
      if pairs.nil?
        not_planned << { 'name' => title, 'sigma_element_id' => el['id'], 'kind' => kind,
                         'reason' => 'chart has no resolvable dimension/value column pair — query-verify manually' }
        next
      end
      charts << { 'chart' => unique_name.call(title), 'sigma_element_id' => el['id'],
                  'kind' => kind,
                  'sigma_columns' => pairs.compact.map { |id_name| id_name[1] },
                  'sigma_column_ids' => pairs.compact.map { |id_name| id_name[0] },
                  'workbook_id' => opts[:wb] }
    elsif kind == 'table'
      visible = (el['columns'] || []).select { |c| c.is_a?(Hash) && c['id'] && c['hidden'] != true }
      if visible.empty?
        not_planned << { 'name' => title, 'sigma_element_id' => el['id'], 'kind' => kind,
                         'reason' => 'table has no visible columns to profile' }
        next
      end
      charts << { 'chart' => unique_name.call(title), 'sigma_element_id' => el['id'],
                  'kind' => 'table-profile', 'source_kind' => 'table',
                  'check' => PROFILE_CHECK_LABEL,
                  'grain' => Array(el['groupings']).empty? ? 'detail' : 'grouped',
                  'sigma_columns' => visible.map { |c| c['name'].to_s },
                  'sigma_column_ids' => visible.map { |c| c['id'] },
                  'workbook_id' => opts[:wb] }
    else
      not_planned << { 'name' => title, 'sigma_element_id' => el['id'], 'kind' => kind,
                       'reason' => "#{kind} has no Phase 6 plan — query-verify it manually and name it in the migration report" }
    end
  end
  abort('no plannable chart or table elements found in the workbook spec') if charts.empty?

  File.write(plan_path, JSON.pretty_generate({ 'charts' => charts, 'not_planned' => not_planned }))

  puts ''
  puts '=' * 70
  puts 'PHASE 7 PASS 1 — fetch ACTUAL (Sigma) and compute EXPECTED (warehouse)'
  puts '=' * 70
  puts ''
  puts 'For each chart: run the mcp__sigma-mcp-v2__query below for the Sigma'
  puts 'ACTUAL rows, and compute the EXPECTED rows by running the equivalent'
  puts 'dimension+aggregation against the warehouse tables the QuickSight'
  puts 'dataset reads (type=connection query, or a live QS export).'
  puts "Write both files, then re-run with --finalize:"
  puts "  #{opts[:dir]}/parity-expected.json  { \"<chart>\": [[dim, val], ...] }"
  puts "  #{opts[:dir]}/parity-actuals.json   { \"<chart>\": [[dim, val], ...] }"
  puts 'KPI charts: a single row [[null, <value>]].'
  puts ''
  charts.each_with_index do |c, i|
    # Query by COLUMN ID (sigma-mcp-v2 can't resolve display labels in workbook
    # queries); the display names ride along in a trailing SQL comment for readability.
    ids = c['sigma_column_ids']
    names = c['sigma_columns']
    if c['kind'] == 'table-profile'
      puts "  [#{i + 1}/#{charts.length}] #{c['chart']} (table-profile, #{c['grain']} table) — PROFILE CHECK, not value parity"
      puts "    mcp__sigma-mcp-v2__query  type=workbook  workbookId=#{opts[:wb]}"
      puts "    sql=#{profile_sql(c['sigma_element_id'], ids).inspect}"
      puts '    The query returns ONE row; write it into parity-actuals.json as [label, value] rows, label order:'
      puts "      #{profile_labels(names).inspect}"
      puts '    EXPECTED: the same counts over the QuickSight dataset rows AFTER its dataset filters and FilterGroups.'
      puts ''
      next
    end
    sql = if ids.length >= 2
            %(SELECT "#{ids[0]}" AS dim, "#{ids[1]}" AS val FROM "workbook"."#{c['sigma_element_id']}" ORDER BY dim NULLS FIRST -- dim: #{names[0]}, val: #{names[1]})
          else
            %(SELECT "#{ids[0]}" AS val FROM "workbook"."#{c['sigma_element_id']}" -- val: #{names[0]})
          end
    puts "  [#{i + 1}/#{charts.length}] #{c['chart']} (#{c['kind']})"
    puts "    mcp__sigma-mcp-v2__query  type=workbook  workbookId=#{opts[:wb]}"
    puts "    sql=#{sql.inspect}"
    puts ''
  end
  unless not_planned.empty?
    puts "NOT PLANNED — #{not_planned.size} content element(s) have no automatic Phase 6 check:"
    not_planned.each { |np| puts "  - #{np['name']} [#{np['kind']}]: #{np['reason']}" }
    puts '  Query-verify each one manually and name it in the migration report.'
    puts ''
  end
  puts '=' * 70
  exit 0
end

# PASS 2 — finalize
abort("plan not found at #{plan_path}; run pass 1 first") unless File.exist?(plan_path)
opts[:expected] ||= File.join(opts[:dir], 'parity-expected.json')
opts[:actuals]  ||= File.join(opts[:dir], 'parity-actuals.json')
abort("expected file missing: #{opts[:expected]}") unless File.exist?(opts[:expected])
abort("actuals file missing: #{opts[:actuals]}")   unless File.exist?(opts[:actuals])

plan = JSON.parse(File.read(plan_path))
expected = JSON.parse(File.read(opts[:expected]))
actuals  = JSON.parse(File.read(opts[:actuals]))

warn "Phase 7 PASS 2: injecting expected (#{expected.size}) + actuals (#{actuals.size}) → #{plan_path}"
plan['charts'].each do |c|
  c['expected'] = expected[c['chart']] if expected[c['chart']]
  c['actual']   = { 'rows' => actuals[c['chart']] } if actuals[c['chart']]
end
File.write(plan_path, JSON.pretty_generate(plan))

missing = plan['charts'].reject { |c| c['expected'] && c['actual'] }
missing.each { |c| warn "WARN: no expected/actual rows supplied for #{c['chart'].inspect} — it will DIVERGE" }

warn "Phase 7 PASS 2: running verifier (#{opts[:extract_mode] ? 'extract-mode' : 'strict'})"
verifier_args = ['ruby', File.join(__dir__, 'verify-parity.rb'), '--plan', plan_path]
verifier_args.concat(['--extract-mode', '--extract-tol', opts[:extract_tol].to_s]) if opts[:extract_mode]
out, err, status = Open3.capture3(*verifier_args)
puts out
warn err unless err.empty?
File.write(File.join(opts[:dir], 'parity-final.txt'), out)

# Hard-gate sentinel consumed by assert-phase6-ran.rb (same contract as the
# tableau-to-sigma Phase 6 sentinel — see [bead] for why it exists).
total  = plan['charts'].size
profile_names = plan['charts'].select { |c| c['kind'] == 'table-profile' }.map { |c| c['chart'] }
passed = out.scan(/^PASS\s+\[[^\]]+\]\s+(.+)$/).flatten.map(&:strip)
failed = out.scan(/^DIVERGE\s+\[[^\]]+\]\s+(.+)$/).flatten.map(&:strip)
summary = {
  'workbook_id'  => plan.dig('charts', 0, 'workbook_id'),
  'ran_at'       => Time.now.utc.iso8601,
  'mode'         => opts[:extract_mode] ? 'extract' : 'strict',
  'extract_tol'  => opts[:extract_mode] ? opts[:extract_tol] : nil,
  'charts_total' => total,
  # `table-profile` checks (row count + non-null/distinct profile) are counted in
  # charts_total/charts_pass like any plan entry, but are NOT value parity — the
  # split is recorded so a report can say how many tiles got real value parity.
  'profile_checks'      => profile_names.size,
  'value_parity_checks' => total - profile_names.size,
  'profile_names'       => profile_names,
  'not_planned'         => Array(plan['not_planned']).map { |np| np['name'] },
  'charts_pass'  => passed.size,
  'charts_fail'  => failed.size,
  'pass_names'   => passed,
  'fail_names'   => failed,
  'status'       => (status.success? && total > 0 && passed.size == total) ? 'PASS' : 'FAIL'
}
summary_path = File.join(opts[:dir], 'parity-final.json')
File.write(summary_path, JSON.pretty_generate(summary))
warn "wrote #{summary_path} (status=#{summary['status']} #{summary['charts_pass']}/#{summary['charts_total']})"
exit(status.success? ? 0 : 2)
