#!/usr/bin/env ruby
# phase6-parity-pbi.rb — Power BI executeQueries(DAX) adapter for Phase 6 parity.
#
# tableau-to-sigma's phase6 compares Sigma chart values against Tableau view
# CSVs. For Power BI the source-of-truth values come from the live semantic
# model via executeQueries (DAX). This script is the PBI-side adapter that
# produces the `expected` half of the parity plan; it reuses the shared
# verify-parity.rb comparison engine for the actual diff.
#
# Two passes (mirrors phase6-parity.rb):
#
# PASS 1 (--emit-dax): given a chart→DAX map, run executeQueries for each chart
#   via the Python harness (pbi_exec.py, written next to this script using the
#   cached Fabric/Power BI token) and write a parity plan with `expected` rows.
#   Also prints the per-chart MCP query the agent should run to collect Sigma
#   actuals, then re-invoke with --finalize.
#
# PASS 2 (--finalize --actuals ...): inject the Sigma actuals and run
#   verify-parity.rb. Writes parity-final.json (the assert-phase6-ran sentinel).
#
# chart-dax.json shape (the agent authors this — one DAX EVALUATE per Sigma chart):
#   { "<Sigma chart name>": {
#       "dax": "EVALUATE SUMMARIZECOLUMNS(EMPLOYEES[DEPARTMENT],\"HC\",[Headcount]) ORDER BY [HC] DESC",
#       "dim_col": "EMPLOYEES[DEPARTMENT]",   # which result column is the dimension
#       "val_col": "[HC]"                      # which is the measure
#     }, ... }
# For single-value charts (KPIs) set dim_col to null; the row becomes [["", val]].
#
# Usage:
#   ruby scripts/phase6-parity-pbi.rb --emit-dax \
#     --workspace <wsId> --dataset <datasetId> \
#     --chart-dax /tmp/pbir/chart-dax.json \
#     --workbook-id <sigmaWbId> \
#     --out /tmp/pbir/parity-plan.json
#
#   ruby scripts/phase6-parity-pbi.rb --finalize \
#     --plan /tmp/pbir/parity-plan.json \
#     --actuals /tmp/pbir/parity-actuals.json \
#     --out-dir /tmp/pbir [--extract-mode --extract-tol 0.02]
#
# Env (finalize): SIGMA_BASE_URL + SIGMA_API_TOKEN are NOT needed here (Sigma
# values arrive via --actuals from the agent's MCP queries).

require 'json'
require 'optparse'
require 'open3'
require 'time'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)
require_relative 'lib/pbi_stale_parity'
require_relative 'lib/pbi_report_clock'

opts = { extract: false, tol: 0.02 }
OptionParser.new do |p|
  p.on('--emit-dax')            { opts[:emit] = true }
  p.on('--local-sql', 'OFFLINE oracle: build the plan from warehouse-SQL `expected` rows (--expected) instead of Power BI executeQueries. No api.powerbi.com / Entra / workspace id needed — use for warehouse-backed models.') { opts[:local_sql] = true }
  p.on('--expected PATH', 'warehouse-SQL oracle results { "<chart>": [[dim,val],...] } — produced by running build-oracle-sql.rb output via mcp__sigma-mcp-v2__query (type:connection). Used with --local-sql.') { |v| opts[:expected] = v }
  p.on('--finalize')            { opts[:finalize] = true }
  p.on('--workspace ID')        { |v| opts[:ws] = v }
  p.on('--dataset ID')          { |v| opts[:ds] = v }
  p.on('--chart-dax PATH')      { |v| opts[:cdax] = v }
  p.on('--workbook-id ID')      { |v| opts[:wb] = v }
  p.on('--plan PATH')           { |v| opts[:plan] = v }
  p.on('--actuals PATH')        { |v| opts[:actuals] = v }
  p.on('--out PATH')            { |v| opts[:out] = v }
  p.on('--out-dir DIR')         { |v| opts[:outdir] = v }
  p.on('--extract-mode')        { opts[:extract] = true }
  p.on('--extract-tol F', Float){ |v| opts[:tol] = v }
  p.on('--source-timezone IANA',
       'Power BI report timezone; converts UTC Export API dates before day-grain parity') do |v|
    opts[:source_timezone] = v
  end
  # bead fmte — freshness.json from pbi-freshness.py. When present, the
  # SOURCE-FRESHNESS banner leads both passes, and finalize classifies each
  # chart MATCH / STALE-EXPLAINED / DIVERGENT. STALE is reported honestly but
  # stays non-GREEN until the source model refreshes and strict parity can run.
  p.on('--freshness PATH')      { |v| opts[:fresh] = v }
  # One clock for "today" (lib/pbi_report_clock.rb). A today-relative chart is
  # compared only when Sigma, the oracle and the report name the same day.
  p.on('--oracle-sql PATH', 'with --local-sql: build-oracle-sql.rb output (carries the oracle clock + today_relative flags)') { |v| opts[:oracle_sql] = v }
  p.on('--expected-as-of ISO', 'when the oracle ran (default: --expected file mtime / now)') { |v| opts[:expected_as_of] = v }
  p.on('--actuals-as-of ISO', 'with --finalize: when the Sigma actuals were collected (default: --actuals file mtime)') { |v| opts[:actuals_as_of] = v }
  p.on('--report-clock PATH', 'with --finalize: report-clock.json (default: <workdir>/report-clock.json)') { |v| opts[:report_clock] = v }
  p.on('--workdir DIR', 'with --finalize: migration workdir holding report-clock.json, dm-spec.json, workbook-spec.json, ' \
                        'materialization-*.json (default: --out-dir)') { |v| opts[:workdir] = v }
  p.on('--materialization-freshness PATH', 'with --finalize: check-materialization-freshness.rb output ' \
                                           '(default: <workdir>/materialization-freshness.json)') { |v| opts[:mat_fresh] = v }
end.parse!

def iso_mtime(path)
  File.exist?(path.to_s) ? File.mtime(path).utc.iso8601 : nil
end

FRESH = if opts[:fresh] && File.exist?(opts[:fresh])
          (JSON.parse(File.read(opts[:fresh])) rescue {})
        else
          {}
        end

def freshness_banner
  ok = FRESH['lastSuccessfulRefresh']
  fail1 = (FRESH['failures'] || []).first
  return unless ok || fail1
  sd = FRESH['staleDays']
  puts '── SOURCE FRESHNESS (read this before any side-by-side) ──'
  puts "PBI dataset last refreshed #{ok['endTime']} (#{sd} days ago)" if ok
  if fail1
    tag = FRESH['credsSuspect'] ? ' — dataset credentials look EXPIRED' : ''
    puts "⚠ most recent refresh FAILURE #{fail1['endTime']} (#{fail1['errorCode']})#{tag}"
  end
  if sd && sd >= 1
    puts "⚠ source is ~#{sd.ceil} day(s) stale — Sigma reads the LIVE warehouse and is"
    puts '  EXPECTED to show different data. Shape-safe deltas may report STALE-EXPLAINED,'
    puts '  but the run stays non-GREEN until Power BI refreshes and strict parity passes.'
  end
  puts
end

# true when the snapshot is stale enough (or refreshes are failing) for a
# "Sigma shows more/newer data" delta to be expected rather than suspicious.
def fresh_stale?
  ((FRESH['staleDays'] || 0) >= 1) || FRESH['credsSuspect'] || (FRESH['failures'] || []).any?
end

HERE = File.expand_path(__dir__)
HARNESS = File.join(HERE, 'pbi_exec.py')

# Self-contained Python executeQueries harness (uses the cached Power BI token).
# Written once; idempotent. Power BI-audience scope is mandatory for
# executeQueries (Fabric-audience tokens are rejected by api.powerbi.com).
HARNESS_SRC = <<~PY
  import truststore; truststore.inject_into_ssl()
  import sys, os, json, msal, requests
  _T=os.environ.get("PBI_TENANT","organizations")  # #347: guest/B2B tenant via PBI_TENANT
  CACHE=os.environ.get("PBI_TOKEN_CACHE") or ("/tmp/pbiauth/cache.bin" if _T=="organizations" else f"/tmp/pbiauth/cache-{_T}.bin")
  cache=msal.SerializableTokenCache()
  if os.path.exists(CACHE): cache.deserialize(open(CACHE).read())
  app=msal.PublicClientApplication("ea0616ba-638b-4df5-95b9-636659ae5121",
      authority=f"https://login.microsoftonline.com/{_T}", token_cache=cache)
  SCOPE=["https://analysis.windows.net/powerbi/api/.default"]
  tok=None
  for a in app.get_accounts():
      r=app.acquire_token_silent(SCOPE, account=a)
      if r and "access_token" in r: tok=r["access_token"]; break
  if not tok:
      flow=app.initiate_device_flow(scopes=SCOPE)
      print(">>> "+flow["verification_uri"]+" code "+flow["user_code"], file=sys.stderr)
      tok=app.acquire_token_by_device_flow(flow).get("access_token")
  if cache.has_state_changed: open(CACHE,"w").write(cache.serialize())
  assert tok, "no powerbi token"
  WS, DS = sys.argv[1], sys.argv[2]
  spec=json.load(sys.stdin)   # {name:{dax,dim_col,val_col}}
  # "me" / "My workspace" datasets live outside any group (no /groups/ segment).
  if WS.lower() in ("me", "myorg", "my workspace", "myworkspace"):
      URL=f"https://api.powerbi.com/v1.0/myorg/datasets/{DS}/executeQueries"
  else:
      URL=f"https://api.powerbi.com/v1.0/myorg/groups/{WS}/datasets/{DS}/executeQueries"
  out={}
  for name, q in spec.items():
      r=requests.post(URL, headers={"Authorization":f"Bearer {tok}"},
          json={"queries":[{"query":q["dax"]}],"serializerSettings":{"includeNulls":True}})
      if r.status_code!=200:
          out[name]={"error":r.text[:300]}; continue
      rows=r.json()["results"][0]["tables"][0]["rows"]
      dim, val = q.get("dim_col"), q.get("val_col")
      pairs=[]
      for row in rows:
          d = "" if not dim else row.get(dim)
          v = row.get(val) if val else None
          pairs.append([d, v])
      out[name]=pairs
  json.dump(out, sys.stdout)
PY

def write_harness
  File.write(HARNESS, HARNESS_SRC) unless File.exist?(HARNESS) && File.read(HARNESS) == HARNESS_SRC
end

if opts[:local_sql]
  # OFFLINE warehouse-SQL oracle (no Power BI service). `expected` rows were
  # produced by running build-oracle-sql.rb's SQL via mcp__sigma-mcp-v2__query
  # (type:connection) against the SAME warehouse the data model reads. Build the
  # exact same plan the DAX path produces so --finalize is unchanged.
  %i[expected wb out].each { |k| abort("missing --#{k}") unless opts[k] }
  expected = JSON.parse(File.read(opts[:expected]))
  oracle = opts[:oracle_sql] ? JSON.parse(File.read(opts[:oracle_sql])) : {}
  descriptors = oracle['_charts'] || {}
  charts = expected.keys.map do |name|
    c = { 'chart' => name, 'expected' => expected[name], 'workbook_id' => opts[:wb] }
    d = descriptors[name] || {}
    c['today_relative'] = true if d['today_relative']
    refs = PbiReportClock.session_clock_refs(d['sql'])
    # A statement on the bare warehouse session clock names whatever day the
    # session's TIMEZONE says — not the report clock.
    c['oracle_clock'] = { 'kind' => 'warehouse-session', 'timezone' => nil, 'refs' => refs } if refs.any?
    c
  end
  abort("--expected #{opts[:expected]} has no charts") if charts.empty?
  plan = { 'extract' => opts[:extract], 'source' => 'warehouse-sql-oracle', 'charts' => charts,
           'oracle_clock' => oracle['_clock'] || { 'kind' => 'warehouse-sql', 'timezone' => nil },
           'expected_as_of' => opts[:expected_as_of] || oracle.dig('_clock', 'as_of') ||
                               iso_mtime(opts[:expected]) || Time.now.utc.iso8601 }
  File.write(opts[:out], JSON.pretty_generate(plan))
  warn "[phase6-pbi] wrote plan with WAREHOUSE-SQL `expected` rows (offline oracle, no Power BI) -> #{opts[:out]}"
  freshness_banner
  puts '=' * 70
  puts 'PHASE 6 (warehouse-SQL oracle) — collect Sigma actuals, one MCP query per chart:'
  puts '=' * 70
  charts.each_with_index do |c, i|
    puts "  [#{i + 1}/#{charts.size}] #{c['chart']}  (expected #{c['expected'].size} row(s) from warehouse SQL)"
  end
  puts ''
  puts 'Save actuals to parity-actuals.json: { "<chart name>": [[dim,val],...] }'
  puts "Then: ruby scripts/phase6-parity-pbi.rb --finalize --plan #{opts[:out]} \\"
  puts "        --actuals <actuals> --out-dir <dir>#{opts[:extract] ? ' --extract-mode --extract-tol ' + opts[:tol].to_s : ''}"
  exit 0
end

if opts[:emit]
  # E-11: the workspace + dataset ids needed for DAX parity ARE captured earlier —
  # pbi-freshness.py writes them into freshness.json (keys workspace/dataset). Auto-
  # wire them so the parity gate isn't a dead-end when --workspace/--dataset aren't
  # repeated on the command line. An explicit flag always wins.
  opts[:ws] ||= FRESH['workspace']
  opts[:ds] ||= FRESH['dataset']
  if (opts[:ws].nil? || opts[:ds].nil?) && opts[:fresh].nil?
    warn '[phase6-pbi] tip: pass --freshness <work>/freshness.json to auto-fill --workspace/--dataset'
  end
  %i[ws ds cdax wb out].each { |k| abort("missing --#{k}") unless opts[k] }
  write_harness
  chart_dax = JSON.parse(File.read(opts[:cdax]))
  # Find python (needs truststore+msal): $PBI_PY, else the legacy /tmp/pbiauth
  # venv, else a real system Python via PyResolve (Windows Store-stub safe; bead
  # 7o01 — see scripts/requirements.txt / run.sh bootstrap). py_argv is an array
  # so a multi-token launcher (`py -3`) survives the splat.
  # bead 4alk.4: the venv is POSIX bin/python OR Windows Scripts\python.exe —
  # probe both rather than assuming bin/.
  py = ENV['PBI_PY'] ||
       ['/tmp/pbiauth/bin/python', '/tmp/pbiauth/Scripts/python.exe'].find { |p| File.exist?(p) }
  py_argv = py ? [py] : PyResolve.argv
  out, err, st = Open3.capture3(*py_argv, HARNESS, opts[:ws], opts[:ds], stdin_data: JSON.dump(chart_dax))
  warn err unless err.empty?
  abort('executeQueries harness failed') unless st.success?
  expected = JSON.parse(out)
  charts = chart_dax.keys.map do |name|
    exp = expected[name]
    if exp.is_a?(Hash) && exp['error']
      warn "  [DAX ERROR] #{name}: #{exp['error']}"
      exp = []
    end
    c = { 'chart' => name, 'expected' => exp, 'workbook_id' => opts[:wb] }
    spec = chart_dax[name] || {}
    c['today_relative'] = true if spec['today_relative'] || PbiReportClock.today_relative_dax?(spec['dax'])
    c
  end
  # executeQueries runs in the Power BI service, which evaluates TODAY()/NOW() in UTC.
  plan = { 'extract' => opts[:extract], 'source' => 'powerbi-executequeries', 'charts' => charts,
           'oracle_clock' => { 'kind' => 'powerbi-service', 'timezone' => 'UTC' },
           'expected_as_of' => opts[:expected_as_of] || Time.now.utc.iso8601 }
  File.write(opts[:out], JSON.pretty_generate(plan))
  warn "[phase6-pbi] wrote plan with PBI `expected` rows -> #{opts[:out]}"
  freshness_banner # bead fmte — staleness leads, before any side-by-side
  puts "=" * 70
  puts "PHASE 6 (PBI) — collect Sigma actuals, one MCP query per chart:"
  puts "=" * 70
  charts.each_with_index do |c, i|
    puts "  [#{i + 1}/#{charts.size}] #{c['chart']}  (expected #{c['expected'].size} row(s) from DAX)"
  end
  puts ""
  puts "Save actuals to parity-actuals.json: { \"<chart name>\": [[dim,val],...] }"
  puts "Then: ruby scripts/phase6-parity-pbi.rb --finalize --plan #{opts[:out]} \\"
  puts "        --actuals <actuals> --out-dir <dir>#{opts[:extract] ? ' --extract-mode --extract-tol ' + opts[:tol].to_s : ''}"
  exit 0
end

if opts[:finalize]
  %i[plan actuals outdir].each { |k| abort("missing --#{k}") unless opts[k] }
  plan_mtime = iso_mtime(opts[:plan])
  plan = JSON.parse(File.read(opts[:plan]))
  actuals = JSON.parse(File.read(opts[:actuals]))
  plan['charts'].each do |c|
    a = actuals[c['chart']]
    # executeQueries emits a null dimension for Power BI's blank member, while
    # Sigma renders that same member as "(Blank)". Reconcile only in columns
    # where the source actually contains a null bucket so a literal "(Blank)"
    # category is not silently rewritten.
    blank_columns = (c['expected'] || []).flat_map do |row|
      row.each_index.select { |index| row[index].nil? }
    end.uniq
    if a && blank_columns.any?
      a = a.map do |row|
        row = row.dup
        blank_columns.each do |index|
          value = row[index]
          row[index] = nil if value.is_a?(String) && value.strip.casecmp('(blank)').zero?
        end
        row
      end
    end
    c['actual'] = { 'rows' => a } if a
  end
  File.write(opts[:plan], JSON.pretty_generate(plan))
  freshness_banner # bead fmte — staleness leads, before the side-by-side
  args = ['ruby', File.join(HERE, 'verify-parity.rb'), '--plan', opts[:plan]]
  args.concat(['--extract-mode', '--extract-tol', opts[:tol].to_s]) if opts[:extract]
  args.concat(['--source-timezone', opts[:source_timezone]]) if opts[:source_timezone]
  out, err, st = Open3.capture3(*args)
  puts out
  warn err unless err.empty?
  total = plan['charts'].size
  passed = out.scan(/^PASS\s+\[[^\]]+\]\s+(.+)$/).flatten
  failed = out.scan(/^DIVERGE\s+\[[^\]]+\]\s+(.+)$/).flatten

  # bead fmte — classify every chart MATCH / STALE-EXPLAINED / DIVERGENT.
  # A stale explanation is allowed only when every source dimension bucket is
  # still present at the SAME canonical type/grain. It never excuses schema
  # drift such as integer Year vs ISO date. Even shape-safe stale deltas remain
  # non-GREEN: refresh the source and rerun strict parity.
  classes = plan['charts'].map do |c|
    name = c['chart']
    cls = if passed.include?(name)
            'MATCH'
          elsif fresh_stale? && PbiStaleParity.value_only_stale?(c['expected'], c.dig('actual', 'rows'))
            'STALE-EXPLAINED'
          else
            'DIVERGENT'
          end
    [name, cls]
  end.to_h
  # ---- one clock for "today" (lib/pbi_report_clock.rb) -------------------
  # A today-relative chart is only comparable when Sigma, the oracle and the
  # report evaluate "today" on the same clock AND on the same report day. Values
  # that agree outside the disagreement band prove nothing, so a clock mismatch
  # is refused at ANY hour (CLOCK-SKEW), not just in the band.
  # The migration workdir holds report-clock.json, the built specs and the
  # materialization records. --out-dir is often a sub-directory of it, so when
  # --workdir is not given look in --out-dir, beside the plan, and one level up.
  markers = %w[report-clock.json materialization-actions.json materialization-freshness.json dm-spec.json
               workbook-spec.json wb-readback.json dm-readback.json]
  workdir = opts[:workdir] ||
            [opts[:outdir], File.dirname(File.expand_path(opts[:plan])), File.dirname(File.expand_path(opts[:outdir]))]
            .uniq.find { |d| markers.any? { |m| File.exist?(File.join(d, m)) } } ||
            opts[:outdir]
  if opts[:workdir].nil? && markers.none? { |m| File.exist?(File.join(workdir, m)) }
    warn "[phase6-pbi] note: no migration workdir found beside --out-dir/--plan (no report-clock.json, specs or " \
         'materialization records): the clock and materialization gates only see the plan — pass --workdir <WORK>'
  end
  clock_path = opts[:report_clock] ||
               [File.join(workdir, 'report-clock.json'), File.join(File.dirname(opts[:plan]), 'report-clock.json')]
               .find { |p| File.exist?(p) }
  clock_rec = clock_path && File.exist?(clock_path) ? (JSON.parse(File.read(clock_path)) rescue nil) : nil
  spec_docs = { 'data_model' => %w[dm-spec.json dm-readback.json], 'workbook' => %w[workbook-spec.json wb-readback.json] }
              .transform_values do |names|
                names.map { |n| File.join(workdir, n) }.select { |p| File.exist?(p) }
                     .map { |p| JSON.parse(File.read(p)) rescue nil }.compact
              end
  if clock_rec
    spec_docs.each do |section, docs|
      next if docs.empty?

      sites = docs.flat_map do |d|
        PbiReportClock.scan(d, report_timezone: clock_rec['report_timezone'], dialect: clock_rec['dialect'])
      end.uniq
      clock_rec[section] = (clock_rec[section] || {}).merge('unpinned' => sites)
    end
  end
  metric_formulas = {}
  spec_docs['data_model'].each do |doc|
    PbiReportClock.each_element(doc) do |el|
      Array(el['metrics']).each { |m| metric_formulas[m['name']] = m['formula'].to_s if m.is_a?(Hash) && m['name'] }
    end
  end
  # a metric reads the clock directly or through [Metrics/<other>] (fixed point)
  clock_metrics = metric_formulas.select { |_n, f| PbiReportClock.today_relative_formula?(f) }.keys.to_h { |n| [n, true] }
  loop do
    grown = metric_formulas.reject { |n, _| clock_metrics[n] }
                           .select { |_n, f| f.scan(/\[Metrics\/([^\]]+)\]/).flatten.any? { |r| clock_metrics[r] } }.keys
    break if grown.empty?

    grown.each { |n| clock_metrics[n] = true }
  end
  wb_today = {}
  spec_docs['workbook'].each do |doc|
    PbiReportClock.each_element(doc) do |el|
      PbiReportClock.walk_formulas(el, '') do |holder, key, _path|
        f = holder[key]
        hit = PbiReportClock.today_relative_formula?(f) ||
              f.scan(/\[Metrics\/([^\]]+)\]/).flatten.any? { |n| clock_metrics[n] }
        wb_today[el['name']] = true if hit
      end
    end
  end
  actual_as_of = opts[:actuals_as_of] || iso_mtime(opts[:actuals])
  expected_as_of = plan['expected_as_of'] || plan_mtime
  today_charts = []
  skew = []
  verdicts = []
  plan['charts'].each do |c|
    name = c['chart']
    next unless c['today_relative'] || wb_today[name]

    today_charts << name
    v = PbiReportClock.parity_verdict(clock: clock_rec, oracle_clock: c['oracle_clock'] || plan['oracle_clock'],
                                      expected_as_of: c['expected_as_of'] || expected_as_of, actual_as_of: actual_as_of)
    verdicts << v
    next if v['ok']

    classes[name] = 'CLOCK-SKEW'
    skew << { 'chart' => name, 'reason' => v['reason'] }
  end
  passed -= skew.map { |s| s['chart'] }
  if today_charts.any?
    puts
    puts "report clock: #{clock_rec ? clock_rec['report_timezone'] : 'UNKNOWN (no report-clock.json)'}; " \
         "#{today_charts.size} today-relative chart(s); oracle as of #{expected_as_of || '?'}, Sigma actuals as of #{actual_as_of || '?'}"
    skew.each { |s| puts "  CLOCK-SKEW      #{s['chart']}: #{s['reason']}" }
  end
  first_v = verdicts.find { |v| !v['ok'] } || verdicts.first || {}
  report_clock = (clock_rec.nil? && today_charts.empty?) ? nil : {
    'report_timezone' => clock_rec && clock_rec['report_timezone'],
    'report_timezone_source' => clock_rec && clock_rec['report_timezone_source'],
    'record' => clock_path && File.exist?(clock_path) ? clock_path : nil,
    'sigma_clock' => first_v['sigma_clock'], 'oracle_clock' => first_v['oracle_clock'],
    'oracle_kind' => first_v['oracle_kind'], 'report_day' => first_v['report_day'],
    'expected_as_of' => expected_as_of, 'actual_as_of' => actual_as_of,
    'unpinned_sites' => clock_rec ? (Array(clock_rec.dig('data_model', 'unpinned')) + Array(clock_rec.dig('workbook', 'unpinned'))).size : nil,
    'today_relative_charts' => today_charts, 'clock_skew' => skew
  }

  # ---- materialization freshness (pre-parity gate) -------------------------
  # A materialized element serves its last run; parity against a LIVE oracle is
  # meaningless once an upstream table changed after that run.
  mat_actions_path = File.join(workdir, 'materialization-actions.json')
  mat_actions = File.exist?(mat_actions_path) ? (JSON.parse(File.read(mat_actions_path)) rescue []) : []
  scheduled = Array(mat_actions).select { |a| a.is_a?(Hash) && %w[created updated unchanged].include?(a['status']) }
  mat_path = opts[:mat_fresh] || File.join(workdir, 'materialization-freshness.json')
  mat = File.exist?(mat_path) ? (JSON.parse(File.read(mat_path)) rescue { 'status' => 'UNREADABLE' }) : nil
  mat_refuse = nil
  mat_block = nil
  if mat
    names = ->(st) { Array(mat['elements']).select { |e| e['status'] == st }.map { |e| e['elementName'] || e['elementId'] } }
    mat_block = { 'status' => mat['status'], 'checked_at' => mat['checked_at'], 'path' => mat_path,
                  'stale' => names.call('STALE'), 'unknown' => names.call('UNKNOWN') }
    # UNKNOWN (an upstream view, an unresolvable source) passes only when the check
    # was run with --allow-unknown, and the accepted elements are recorded.
    accepted_unknown = mat['status'] == 'UNKNOWN' && mat['allow_unknown'] == true
    if accepted_unknown
      mat_block['accepted_unknown'] = mat_block['unknown']
      puts
      puts "materialization freshness UNKNOWN accepted (--allow-unknown): #{mat_block['unknown'].join(', ')}"
    end
    unless %w[FRESH NONE].include?(mat['status']) || accepted_unknown
      mat_refuse = "materialization freshness is #{mat['status']} (#{(mat_block['stale'] + mat_block['unknown']).join(', ')}): " \
                   'Sigma serves a materialization older than its upstream tables — re-materialize and wait ' \
                   '(check-materialization-freshness.rb --rematerialize --wait 900), then rerun the oracle and parity'
    end
    # The check must be contemporaneous with BOTH sides (two-sided, 2 h); NONE
    # (no schedules) has nothing to age.
    if mat_refuse.nil? && mat['status'] != 'NONE' && mat['checked_at']
      checked = PbiReportClock.parse_instant(mat['checked_at'])
      far = [['the oracle', expected_as_of], ['the Sigma actuals', actual_as_of]].find do |_label, at|
        at && (PbiReportClock.parse_instant(at) - checked).abs > 7200
      end
      if far
        mat_refuse = "materialization freshness was checked at #{mat['checked_at']}, more than 2h from #{far[0]} " \
                     "(#{far[1]}); rerun check-materialization-freshness.rb right before the oracle and the actuals"
      end
    end
  elsif scheduled.any?
    mat_block = { 'status' => 'NOT-CHECKED', 'path' => mat_path, 'scheduled' => scheduled.map { |a| a['elementName'] } }
    mat_refuse = "#{scheduled.size} materialization schedule(s) exist but freshness was never checked: run " \
                 "ruby scripts/check-materialization-freshness.rb --data-model <dmId> --workdir #{workdir} --wait 900 " \
                 'before parity (never trust a fixed sleep — poll until each run lands)'
  end
  if mat_refuse
    puts
    puts "STALE-MATERIALIZATION: #{mat_refuse}"
  end

  stale_expl = classes.values.count('STALE-EXPLAINED')
  divergent  = classes.values.count('DIVERGENT')
  if FRESH.any? || stale_expl.positive?
    puts
    puts 'classification (STALE-EXPLAINED is shape-safe but remains non-GREEN):'
    classes.each { |name, cls| puts format('  %-15s %s', cls, name) }
    if stale_expl.positive?
      puts "  → #{stale_expl} delta(s) have matching dimension shape and are explained by the stale PBI snapshot" \
           "#{FRESH['credsSuspect'] ? ' (refresh failing — creds)' : ''}; refresh PBI before claiming exact parity."
    end
  end

  status =
    if mat_refuse
      'STALE-MATERIALIZATION'
    elsif total.positive? && passed.size == total
      'PASS'
    elsif divergent.zero? && skew.any?
      'CLOCK-SKEW'
    elsif total.positive? && divergent.zero? && (passed.size + stale_expl) == total
      'STALE'
    else
      'FAIL'
    end
  summary = {
    'workbook_id' => plan.dig('charts', 0, 'workbook_id'),
    'ran_at' => Time.now.utc.iso8601,
    'source' => plan['source'] || 'powerbi-executequeries',
    'mode' => opts[:extract] ? 'extract' : 'strict',
    'source_timezone' => opts[:source_timezone],
    'charts_total' => total, 'charts_pass' => passed.size, 'charts_fail' => divergent,
    'charts_stale_explained' => stale_expl,
    'charts_verified' => passed.size,
    'pass_names' => passed,
    'stale_explained_names' => classes.select { |_name, cls| cls == 'STALE-EXPLAINED' }.keys,
    'fail_names' => classes.select { |_name, cls| cls == 'DIVERGENT' }.keys,
    'classifications' => classes,
    'charts_clock_skew' => skew.size,
    'report_clock' => report_clock,
    'materialization_freshness' => mat_block,
    'freshness' => FRESH.empty? ? nil : {
      'lastSuccessfulRefresh' => FRESH.dig('lastSuccessfulRefresh', 'endTime'),
      'staleDays' => FRESH['staleDays'], 'credsSuspect' => FRESH['credsSuspect'],
      'failures' => (FRESH['failures'] || []).size
    },
    'status' => status
  }
  File.write(File.join(opts[:outdir], 'parity-final.json'), JSON.pretty_generate(summary))
  warn "[phase6-pbi] wrote parity-final.json (status=#{status} " \
       "#{passed.size} match / #{stale_expl} stale-explained / #{divergent} divergent of #{total})"
  exit(status == 'PASS' ? 0 : 2)
end

abort('specify --emit-dax or --finalize')
