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
  # bead fmte — freshness.json from pbi-freshness.py. When present, the
  # SOURCE-FRESHNESS banner leads both passes, and finalize classifies each
  # chart MATCH / STALE-EXPLAINED / DIVERGENT. STALE is reported honestly but
  # stays non-GREEN until the source model refreshes and strict parity can run.
  p.on('--freshness PATH')      { |v| opts[:fresh] = v }
end.parse!

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
  CACHE=os.environ.get("PBI_TOKEN_CACHE") or ("/tmp/pbiauth/cache.bin" if _T=="organizations" else "/tmp/pbiauth/cache-"+_T+".bin")
  cache=msal.SerializableTokenCache()
  if os.path.exists(CACHE): cache.deserialize(open(CACHE).read())
  app=msal.PublicClientApplication("ea0616ba-638b-4df5-95b9-636659ae5121",
      authority="https://login.microsoftonline.com/"+_T, token_cache=cache)
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
  charts = expected.keys.map do |name|
    { 'chart' => name, 'expected' => expected[name], 'workbook_id' => opts[:wb] }
  end
  abort("--expected #{opts[:expected]} has no charts") if charts.empty?
  plan = { 'extract' => opts[:extract], 'source' => 'warehouse-sql-oracle', 'charts' => charts }
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
    { 'chart' => name, 'expected' => exp, 'workbook_id' => opts[:wb] }
  end
  plan = { 'extract' => opts[:extract], 'source' => 'powerbi-executequeries', 'charts' => charts }
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
  plan = JSON.parse(File.read(opts[:plan]))
  actuals = JSON.parse(File.read(opts[:actuals]))
  plan['charts'].each do |c|
    a = actuals[c['chart']]
    c['actual'] = { 'rows' => a } if a
  end
  File.write(opts[:plan], JSON.pretty_generate(plan))
  freshness_banner # bead fmte — staleness leads, before the side-by-side
  args = ['ruby', File.join(HERE, 'verify-parity.rb'), '--plan', opts[:plan]]
  args.concat(['--extract-mode', '--extract-tol', opts[:tol].to_s]) if opts[:extract]
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
    if total.positive? && passed.size == total
      'PASS'
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
    'charts_total' => total, 'charts_pass' => passed.size, 'charts_fail' => divergent,
    'charts_stale_explained' => stale_expl,
    'charts_verified' => passed.size,
    'pass_names' => passed,
    'stale_explained_names' => classes.select { |_name, cls| cls == 'STALE-EXPLAINED' }.keys,
    'fail_names' => classes.select { |_name, cls| cls == 'DIVERGENT' }.keys,
    'classifications' => classes,
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
