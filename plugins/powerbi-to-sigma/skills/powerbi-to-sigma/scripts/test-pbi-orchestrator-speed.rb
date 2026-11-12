#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline end-to-end test of the migrate-powerbi.rb speed features, run through the REAL
# orchestrator (vendored converter, real extractors) up to the decisions checkpoint -
# which exits 10 before any Sigma object is created, so no network or credentials:
#
#   * rerun cache: a second run with unchanged inputs skips the Phase 0/1 extraction
#     (fingerprint recorded in run-provenance.json), a changed input / --no-reuse-extract
#     re-extracts, --reuse-extract reuses on request, name-sanitize survives a cached rerun
#   * --probe-sources (replaying captured probe results via --probe-results): a bound column
#     missing from the SQL output STOPs the run, --probe-allow-missing proceeds and nulls it,
#     casts are folded into the element SQL, sql-output-names.json feeds the dm-resolver
#   * F8: a SQL output column named "a/b" is aliased and bound via the alias, and the
#     probe then passes (it would flag the raw "a/b" as ambiguous)
#
# Run: ruby scripts/test-pbi-orchestrator-speed.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

SKILL = File.expand_path('..', __dir__)
MIGRATE = File.join(__dir__, 'migrate-powerbi.rb')
PROBE = File.join(__dir__, 'probe-native-sources.py')
CONN = '12345678-1234-1234-1234-123456789012'
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'

def native_m(sql)
  esc = sql.gsub('"', '""')
  ['let', "  Source = Value.NativeQuery(Snowflake.Databases(\"acct\"){[Name=\"DB\"]}[Data], \"#{esc}\", null, [EnableFolding=true])", 'in', '  Source']
end

def model_bim(sql, columns)
  { 'model' => { 'name' => 'T', 'tables' => [{
    'name' => 'Orders', 'columns' => columns,
    'measures' => [{ 'name' => 'Total Amount', 'expression' => 'SUM(Orders[Amount])' }],
    'partitions' => [{ 'name' => 'Orders', 'mode' => 'import', 'source' => { 'type' => 'm', 'expression' => native_m(sql) } }]
  }] } }
end

def visual(name, type, proj)
  JSON.generate('name' => name, 'singleVisual' => { 'visualType' => type,
                                                      'projections' => proj.map { |r, qs| [r, qs.map { |q| { 'queryRef' => q } }] }.to_h })
end

def bundle(title_ref = 'Orders.Total Amount', extra = [])
  vcs = [{ 'x' => 0, 'y' => 0, 'width' => 200, 'height' => 100, 'z' => 0, 'config' => visual('v1', 'card', 'Values' => [title_ref]) }] + extra
  JSON.generate('report.json' => JSON.generate('sections' => [{ 'name' => 'S1', 'displayName' => 'Page', 'width' => 1280, 'height' => 720, 'visualContainers' => vcs }]))
end

def col(name, src, type)
  { 'name' => name, 'sourceColumn' => src, 'dataType' => type }
end

def run_migrate(dir, work, *extra)
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, st = Open3.capture2e(RbConfig.ruby, MIGRATE, '--tmsl', File.join(dir, 'model.bim'), '--pbir', File.join(dir, 'bundle.json'),
                            '--out', work, '--connection', CONN, '--database', 'DB', '--schema', 'SALES', *extra)
  [out, st.exitstatus]
end

def jread(path)
  JSON.parse(File.read(path))
end

def probe_results(dm_path, tmsl_path, dir, outputs_by_sql)
  q = File.join(dir, 'q.json')
  # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  _o, e, st = Open3.capture3('python3', PROBE, '--dm', dm_path, '--tmsl', tmsl_path, '--emit-queries', q)
  raise "emit-queries failed: #{e}" unless st.success?

  keys = jread(q)
  res = {}
  keys.each do |k, sql|
    hit = outputs_by_sql.find { |frag, _| sql.include?(frag) }
    raise "no canned result for #{sql.inspect}" unless hit

    res[k] = { 'ok' => true, 'columns' => hit[1].keys, 'types' => hit[1] }
  end
  File.join(dir, 'res.json').tap { |p| File.write(p, JSON.generate(res)) }
end

ORDERS_SQL = 'SELECT ORDER_ID, IS_ACTIVE, AMOUNT, REGION FROM SALES.ORDERS'
ORDERS_OUT = { 'ORDER_ID' => 'NUMBER(38,0)', 'IS_ACTIVE' => 'VARCHAR(16777216)', 'AMOUNT' => 'NUMBER(18,2)', 'REGION' => 'VARCHAR(16777216)' }.freeze
ORDERS_COLS = [col('Order Id', 'ORDER_ID', 'int64'), col('Is Active', 'IS_ACTIVE', 'boolean'),
               col('Amount', 'AMOUNT', 'decimal'), col('Region', 'REGION', 'string')].freeze

Dir.mktmpdir('pbi-orch-speed') do |dir|
  File.write(File.join(dir, 'model.bim'), JSON.pretty_generate(model_bim(ORDERS_SQL, ORDERS_COLS)))
  File.write(File.join(dir, 'bundle.json'), bundle)
  work = File.join(dir, 'w')

  puts "\n1. rerun cache"
  out, code = run_migrate(dir, work)
  check(code == 10 && out.include?('decisions_needed'), "first run reaches the decisions checkpoint (exit #{code})")
  prov = jread(File.join(work, 'run-provenance.json'))
  fp = prov['extractFingerprint']
  check(fp && fp['route'] == 'tmsl-pbir' && fp['inputs'].keys.sort == %w[pbir tmsl] && fp['extractSeconds'].is_a?(Numeric),
        'the input fingerprint and extraction time are recorded in run-provenance.json')
  check(!out.include?('extract-cache') && !jread(File.join(work, 'timings.json')).key?('extractCache'), 'a first run does not claim a cache hit')
  sig1 = File.read(File.join(work, 'signals.json'))
  FileUtils.rm_rf(File.join(work, 'pbir'))

  out, code = run_migrate(dir, work)
  check(code == 10, "rerun still reaches the checkpoint (exit #{code})")
  check(out.include?('EXTRACT CACHE: input fingerprint matches'), 'rerun announces the cache hit')
  check(!File.exist?(File.join(work, 'pbir')), 'rerun did not re-explode the PBIR bundle (extraction skipped)')
  timing_line = out.lines.find { |l| l.start_with?('PHASE TIMINGS') }.to_s
  check(timing_line.include?('[extract-cache: reused Phase 0/1 extraction (fingerprint'), "PHASE TIMINGS carries the note (got #{timing_line.strip})")
  check(jread(File.join(work, 'timings.json'))['extractCache'].to_s.start_with?('extract-cache: reused'), 'timings.json records the cache use')
  check(File.read(File.join(work, 'signals.json')) == sig1, 'cached rerun works from identical signals')
  check(jread(File.join(work, 'run-provenance.json'))['extractFingerprint'] == fp, 'the recorded fingerprint survives the rerun (provenance is rewritten each run)')

  File.write(File.join(dir, 'bundle.json'), bundle('Orders.Total Amount', [
    { 'x' => 0, 'y' => 120, 'width' => 200, 'height' => 100, 'z' => 1, 'config' => visual('v2', 'card', 'Values' => ['Orders.Total Amount']) }
  ]))
  out, code = run_migrate(dir, work)
  check(code == 10 && out.include?('EXTRACT CACHE: not used - inputs or extractor changed') && File.exist?(File.join(work, 'pbir')) &&
          jread(File.join(work, 'signals.json'))['pages'][0]['visuals'].size == 2,
        'a changed --pbir re-extracts and picks up the new visual')
  check(!out.lines.find { |l| l.start_with?('PHASE TIMINGS') }.to_s.include?('extract-cache'), 'no cache note on a fresh extraction')

  FileUtils.rm_rf(File.join(work, 'pbir'))
  out, _code = run_migrate(dir, work, '--no-reuse-extract')
  check(out.include?('--no-reuse-extract given') && File.exist?(File.join(work, 'pbir')), '--no-reuse-extract forces a fresh extraction')

  FileUtils.rm_rf(File.join(work, 'pbir'))
  File.write(File.join(dir, 'bundle.json'), bundle)
  out, code = run_migrate(dir, work, '--reuse-extract')
  check(code == 10 && out.include?('--reuse-extract (input fingerprint DIFFERS') && !File.exist?(File.join(work, 'pbir')) &&
          jread(File.join(work, 'signals.json'))['pages'][0]['visuals'].size == 2,
        '--reuse-extract reuses the extraction on request even though the input changed (and says so)')

  out, code = run_migrate(dir, File.join(dir, 'fresh'), '--reuse-extract')
  check(code == 10 && out.include?('--reuse-extract given but signals.json not in') && File.exist?(File.join(dir, 'fresh', 'pbir')),
        '--reuse-extract on an empty work dir falls back to extracting')

  puts "\n2. a cached rerun still sanitizes names ('/' in a column name)"
  sdir = File.join(dir, 'san')
  FileUtils.mkdir_p(sdir)
  File.write(File.join(sdir, 'model.bim'), JSON.pretty_generate(model_bim(ORDERS_SQL, ORDERS_COLS + [col('Share/Pct', 'REGION', 'string')])))
  File.write(File.join(sdir, 'bundle.json'), bundle('Orders.Total Amount', [
    { 'x' => 0, 'y' => 120, 'width' => 400, 'height' => 200, 'z' => 1, 'config' => visual('v3', 'tableEx', 'Values' => ['Orders.Share/Pct']) }
  ]))
  swork = File.join(sdir, 'w')
  out, code = run_migrate(sdir, swork)
  check(code == 10 && out.include?('NAME SANITIZE: renamed 1'), "first run sanitizes the slashed name (exit #{code})")
  sig_first = File.read(File.join(swork, 'signals.json'))
  ren_first = jread(File.join(swork, 'name-sanitize.json'))['renames']
  check(!sig_first.include?('Share/Pct') && File.exist?(File.join(swork, 'signals-extracted.json')) &&
          File.read(File.join(swork, 'signals-extracted.json')).include?('Share/Pct'),
        'signals.json is sanitized in place and the pristine extraction is kept beside it')
  out, code = run_migrate(sdir, swork)
  check(code == 10 && out.include?('EXTRACT CACHE: input fingerprint matches') && out.include?('NAME SANITIZE: renamed 1'),
        'the cached rerun sanitizes again from the pristine extraction')
  check(File.read(File.join(swork, 'signals.json')) == sig_first && jread(File.join(swork, 'name-sanitize.json'))['renames'] == ren_first,
        'sanitized signals and the rename map are identical after a cached rerun')

  puts "\n3. --probe-sources"
  out, code = run_migrate(dir, File.join(dir, 'p0'), '--probe-sources')
  check(code != 0 && code != 10 && out.include?('--probe-sources needs --folder'), 'without --folder (or --probe-results) the run refuses up front')
  out, code = run_migrate(dir, File.join(dir, 'p0'), '--probe-results', 'x.json')
  check(code != 0 && out.include?('require --probe-sources'), '--probe-results without --probe-sources is refused')

  ghost_dir = File.join(dir, 'ghost')
  FileUtils.mkdir_p(ghost_dir)
  File.write(File.join(ghost_dir, 'model.bim'), JSON.pretty_generate(model_bim(ORDERS_SQL, ORDERS_COLS + [col('Ghost', 'GHOST', 'string')])))
  File.write(File.join(ghost_dir, 'bundle.json'), bundle)
  gwork = File.join(ghost_dir, 'w')
  run_migrate(ghost_dir, gwork) # plain run: produces dm-raw.json / the scoped model to key the canned results
  res = probe_results(File.join(gwork, 'dm-raw.json'), File.join(gwork, 'model-scoped-normalized.bim'), ghost_dir, 'FROM DB.SALES.ORDERS' => ORDERS_OUT)
  FileUtils.rm_f(File.join(gwork, 'sql-output-names.json'))

  out, code = run_migrate(ghost_dir, gwork, '--probe-sources', '--probe-results', res, '--folder', 'f1')
  check(code == 10 && out.include?('STOP — Custom SQL does not return the columns the model binds') && out.include?('Orders / Ghost'),
        "a bound column missing from the SQL output STOPs the run, naming it (exit #{code})")
  check(!out.include?('decisions_needed') && !File.exist?(File.join(gwork, 'sql-output-names.json')) && File.exist?(File.join(gwork, 'native-source-probe.json')),
        'it stops before the decisions checkpoint and leaves the report (but no sql-output-names.json)')

  out, code = run_migrate(ghost_dir, gwork, '--probe-sources', '--probe-results', res, '--probe-allow-missing')
  check(code == 10 && out.include?('decisions_needed') && !out.include?('STOP — Custom SQL'), '--probe-allow-missing proceeds to the decisions checkpoint')
  names = jread(File.join(gwork, 'sql-output-names.json'))
  check(names == { 'Orders' => ORDERS_OUT.keys }, "sql-output-names.json has the probed output names in the dm-resolver shape (got #{names.inspect})")
  el = jread(File.join(gwork, 'dm-raw.json'))['pages'][0]['elements'][0]
  forms = el['columns'].map { |c| [c['name'], c['formula']] }.to_h
  check(forms['Ghost'] == 'Null', "the unknown [Custom SQL/GHOST] is nulled before any POST (got #{forms['Ghost'].inspect})")
  check(el['source']['statement'].include?('TRY_TO_BOOLEAN("IS_ACTIVE") AS "IS_ACTIVE"') && el['source']['statement'].include?(ORDERS_SQL.sub('FROM SALES', 'FROM DB.SALES')), # the converter qualifies tables with the database
        'the VARCHAR -> boolean cast is folded into the element SQL')
  check(jread(File.join(gwork, 'dm-resolver.json'))['nulled'].any? { |n| n['name'] == 'Ghost' }, 'the nulled binding is audited in dm-resolver.json')
  check(jread(File.join(gwork, 'native-source-probe.json'))['applied_to_dm'].to_a.size == 1, 'the applied cast is recorded in native-source-probe.json')
  check(out.lines.find { |l| l.start_with?('PHASE TIMINGS') }.to_s.include?('2a-probe-sources='), 'the probe has its own phase timing')

  puts "\n3b. whole-8: sql-output-names.json from an earlier --probe-sources run must not go stale"
  stamp = File.join(gwork, 'sql-output-names.stamp.json')
  check(File.exist?(stamp) && jread(stamp).keys == ['Orders'], 'the probe run stamps sql-output-names.json with each statement hash')
  out, code = run_migrate(ghost_dir, gwork)
  nulled = jread(File.join(gwork, 'dm-resolver.json'))['nulled'].map { |n| n['name'] }
  check(code == 10 && nulled.include?('Ghost') && !out.include?('probe names ignored'),
        'a rerun WITHOUT the probe and with unchanged SQL still honors the probed names (Ghost stays nulled)')
  changed_sql = ORDERS_SQL.sub('REGION', 'REGION, GHOST')
  File.write(File.join(ghost_dir, 'model.bim'), JSON.pretty_generate(model_bim(changed_sql, ORDERS_COLS + [col('Ghost', 'GHOST', 'string')])))
  out, code = run_migrate(ghost_dir, gwork)
  gel = jread(File.join(gwork, 'dm-raw.json'))['pages'][0]['elements'][0]
  gforms = gel['columns'].map { |c| [c['name'], c['formula']] }.to_h
  check(code == 10 && out.include?('probe names ignored for Orders') && gforms['Ghost'] == '[Custom SQL/GHOST]',
        "the SQL gained GHOST: the stale probe names are ignored, so the valid ref is NOT nulled (got #{gforms['Ghost'].inspect})")
  check(!jread(File.join(gwork, 'dm-resolver.json'))['nulled'].any? { |n| n['name'] == 'Ghost' }, 'and dm-resolver.json does not list it as nulled')

  puts "\n4. F8: a SQL output named a/b is aliased and bound via the alias"
  slash_sql = 'SELECT ORDER_ID, AMOUNT / TOTAL AS "Pct/Total" FROM SALES.ORDERS'
  fdir = File.join(dir, 'f8')
  FileUtils.mkdir_p(fdir)
  File.write(File.join(fdir, 'model.bim'), JSON.pretty_generate(model_bim(slash_sql, [col('Order Id', 'ORDER_ID', 'int64'), col('Amount', 'AMOUNT', 'decimal'), col('Pct/Total', 'Pct/Total', 'decimal')])))
  File.write(File.join(fdir, 'bundle.json'), bundle)
  fwork = File.join(fdir, 'w')
  run_migrate(fdir, fwork)
  fel = jread(File.join(fwork, 'dm-raw.json'))['pages'][0]['elements'][0]
  check(fel['source']['statement'].start_with?('SELECT * RENAME ("Pct/Total" AS "Pct_Total") FROM (') &&
          fel['columns'].any? { |c| c['formula'] == '[Custom SQL/Pct_Total]' && c['name'].include?("∕") },
        'the orchestrator aliases the slashed output and keeps the display name (sanitized "/")')
  fres = probe_results(File.join(fwork, 'dm-raw.json'), File.join(fwork, 'model-scoped-normalized.bim'), fdir,
                       'SELECT * RENAME' => { 'ORDER_ID' => 'NUMBER(38,0)', 'AMOUNT' => 'NUMBER(18,2)', 'Pct_Total' => 'NUMBER(18,4)' })
  out, code = run_migrate(fdir, fwork, '--probe-sources', '--probe-results', fres)
  check(code == 10 && out.include?('decisions_needed') && out.include?('0 ambiguous') && !out.include?('AMBIGUOUS') && !out.include?('STOP — Custom SQL'),
        "the probe passes on the aliased statement (exit #{code})")

  puts "\n5. --pbix route: the warehouse dialect reaches the extractor and the cache identity"
  # A fake python stands in for pbixray: it logs the extract-model-pbix.py argv, writes a canned model.bim and
  # signals, answers the pbixray version probe, and delegates everything else to the real python3.
  pdir = File.join(dir, 'pbixroute')
  FileUtils.mkdir_p(pdir)
  File.write(File.join(pdir, 'model.bim'), JSON.pretty_generate(model_bim(ORDERS_SQL, ORDERS_COLS)))
  File.write(File.join(pdir, 'signals.canned.json'), File.read(File.join(work, 'signals.json')))
  File.write(File.join(pdir, 'a.pbix'), 'not-a-real-pbix')
  fake_log = File.join(pdir, 'argv.log')
  fake_py = File.join(pdir, 'fakepy')
  File.write(fake_py, <<~SH)
    #!/bin/sh
    case "$*" in
      *--detect-composite*) echo '{"composite":false}'; exit 0;;
      *extract-model-pbix.py*) echo "$*" >> "#{fake_log}"; out=""; prev=""
        for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
        cp "#{File.join(pdir, 'model.bim')}" "$out"; exit 0;;
      *extract-report-classic.py*) out=""; dump=""; prev=""
        for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; [ "$prev" = "--dump-layout" ] && dump="$a"; prev="$a"; done
        cp "#{File.join(pdir, 'signals.canned.json')}" "$out"; echo '{}' > "$dump"; exit 0;;
      *importlib.metadata*) echo 9.9.9; exit 0;;
    esac
    exec python3 "$@"
  SH
  File.chmod(0o755, fake_py)
  pwork = File.join(pdir, 'w')
  run_pbix = lambda do |wh|
    o, st = Open3.capture2e(RbConfig.ruby, MIGRATE, '--pbix', File.join(pdir, 'a.pbix'), '--python', fake_py, '--out', pwork,
                            '--connection', CONN, '--database', 'DB', '--schema', 'SALES', '--warehouse-type', wh)
    [o, st.exitstatus]
  end
  argv_lines = -> { File.exist?(fake_log) ? File.readlines(fake_log) : [] }
  out, code = run_pbix.call('bigquery')
  check(code == 10, "pbix run reaches the checkpoint (exit #{code})#{code == 10 ? '' : "\n#{out}"}")
  check(argv_lines.call.size == 1 && argv_lines.call.last.include?('--dialect bigquery'),
        "extract-model-pbix.py is passed --dialect bigquery (got #{argv_lines.call.last.to_s.strip})")
  pfp = jread(File.join(pwork, 'run-provenance.json'))['extractFingerprint']
  check(pfp && pfp['dialect'] == 'bigquery' && pfp['pbixray'] == '9.9.9', 'the dialect and pbixray version are recorded in the fingerprint')
  out, = run_pbix.call('bigquery')
  check(out.include?('EXTRACT CACHE: input fingerprint matches') && argv_lines.call.size == 1, 'same dialect: the rerun is served from the cache')
  out, = run_pbix.call('databricks')
  check(out.include?('EXTRACT CACHE: not used - inputs or extractor changed') && argv_lines.call.size == 2 &&
          argv_lines.call.last.include?('--dialect databricks'),
        'a different --warehouse-type re-extracts with the new dialect (the cache does not mask it)')
end

puts "\n6. whole-1: --stop-before-post creates NOTHING in Sigma on the DM-reuse path"
# A stub required into EVERY ruby subprocess (RUBYOPT) replaces Net::HTTP.start: it logs each
# request (method + path) and answers canned JSON, so a stray POST/PUT from the orchestrator or
# any script it spawns is caught. No network, no credentials.
Dir.mktmpdir('pbi-stop-before-post') do |sdir|
  stub = File.join(sdir, 'fake_sigma_http.rb')
  log = File.join(sdir, 'http.log')
  File.write(stub, <<~'RUBY')
    require 'net/http'
    require 'json'
    class FakeSigmaConn
      SPEC = { 'dataModelId' => 'dm-fake-1', 'name' => 'Reused DM', 'pages' => [{ 'id' => 'p1', 'name' => 'Data', 'elements' => [
        { 'id' => 'e1', 'name' => 'Orders', 'kind' => 'table',
          'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB SALES ORDERS] },
          'columns' => %w[ORDER_ID IS_ACTIVE AMOUNT REGION].each_with_index.map { |c, i| { 'id' => "c#{i}", 'formula' => "[ORDERS/#{c}]", 'name' => c } } }] }] }.freeze
      def request(req)
        File.open(ENV.fetch('FAKE_SIGMA_LOG'), 'a') { |f| f.flock(File::LOCK_EX); f.puts("#{req.method} #{req.path}") }
        body = if req.path =~ %r{/v2/dataModels/[^/]+/spec}
                 JSON.generate(SPEC)
               elsif req.path =~ %r{\A/v2/dataModels\?}
                 JSON.generate('entries' => [{ 'dataModelId' => 'dm-fake-1', 'name' => 'Orders', 'updatedAt' => '2026-01-01T00:00:00Z' }], 'nextPage' => nil)
               elsif req.path.start_with?('/v2/whoami')
                 JSON.generate('userId' => 'user-1')
               else
                 '{}'
               end
        res = Net::HTTPOK.new('1.1', '200', 'OK')
        res.instance_variable_set(:@body, body)
        res.instance_variable_set(:@read, true)
        res
      end
    end
    class Net::HTTP
      def self.start(*_args, **_opts)
        conn = FakeSigmaConn.new
        block_given? ? yield(conn) : conn
      end
    end
  RUBY
  env = { 'RUBYOPT' => "-r#{stub}", 'FAKE_SIGMA_LOG' => log, 'HOME' => sdir, 'SIGMA_API_TOKEN' => 'tok',
          'SIGMA_BASE_URL' => 'https://api.sigmacomputing.com', 'SIGMA_ALLOW_INSECURE_BASE_URL' => '' }
  File.write(File.join(sdir, 'model.bim'), JSON.pretty_generate(model_bim(ORDERS_SQL, ORDERS_COLS)))
  File.write(File.join(sdir, 'bundle.json'), bundle)
  stop_args = lambda do |work, *extra|
    [RbConfig.ruby, MIGRATE, '--tmsl', File.join(sdir, 'model.bim'), '--pbir', File.join(sdir, 'bundle.json'), '--out', work,
     '--connection', CONN, '--database', 'DB', '--schema', 'SALES', '--folder', 'f1', '--yes', '--stop-before-post', *extra]
  end
  writes = -> { (File.exist?(log) ? File.readlines(log) : []).map(&:strip).select { |l| l =~ /\A(POST|PUT|PATCH|DELETE) / } }
  reqs = -> { File.exist?(log) ? File.readlines(log).map(&:strip) : [] }

  out, st = Open3.capture2e(env, *stop_args.call(File.join(sdir, 'w1'), '--reuse-dm', 'dm-fake-1'))
  check(st.exitstatus == 0 && out.include?('STOP BEFORE POST') && out.include?('would reuse existing data model dm-fake-1'),
        "--stop-before-post with --reuse-dm exits 0 at the stop, naming the DM it would reuse (exit #{st.exitstatus})#{st.exitstatus == 0 ? '' : "\n#{out}"}")
  check(reqs.call.any? { |l| l.start_with?('GET /v2/dataModels/dm-fake-1/spec') }, 'the reuse path really ran (the DM spec was read back)')
  check(writes.call.empty?, "zero POST/PUT/PATCH/DELETE reached Sigma on the reuse path (got #{writes.call.inspect})")
  check(!File.exist?(File.join(sdir, 'w1', 'wb-readback.json')) && !out.include?('Phase 4') && !out.include?('Build workbook'),
        'the workbook phase never started')

  # AUTO-picked reuse: a plain warehouse-table model (not a NativeQuery one, whose signature has no
  # tables) so find-or-pick-dm scores the stubbed DM as a guaranteed-safe match and picks it.
  aw = File.join(sdir, 'w2')
  plain = { 'model' => { 'name' => 'T', 'tables' => [{
    'name' => 'Orders', 'columns' => ORDERS_COLS,
    'measures' => [{ 'name' => 'Total Amount', 'expression' => 'SUM(Orders[Amount])' }],
    'partitions' => [{ 'name' => 'Orders', 'mode' => 'import', 'source' => { 'type' => 'm', 'expression' => [
      'let', '  Source = Snowflake.Databases("acct"){[Name="DB",Kind="Database"]}[Data],', '  S = Source{[Name="SALES",Kind="Schema"]}[Data],',
      '  T = S{[Name="ORDERS",Kind="Table"]}[Data]', 'in', '  T'] } }]
  }] } }
  File.write(File.join(sdir, 'plain.bim'), JSON.pretty_generate(plain))
  File.delete(log) if File.exist?(log)
  out, st = Open3.capture2e(env, *stop_args.call(aw, '--tmsl', File.join(sdir, 'plain.bim')))
  check(out.include?('DM-REUSE (auto)'), "find-or-pick-dm auto-picks the stubbed DM (setup check)#{out.include?('DM-REUSE (auto)') ? '' : "\n#{out.lines.grep(/reuse|score|match/i).first(6).join}"}")
  check(st.exitstatus == 0 && out.include?('STOP BEFORE POST: would reuse existing data model dm-fake-1') && writes.call.empty?,
        "an AUTO-picked reuse also stops before any POST (exit #{st.exitstatus}, writes #{writes.call.inspect})")

  # The build-new path keeps its stop, and creates nothing either.
  File.delete(log) if File.exist?(log)
  out, st = Open3.capture2e(env, *stop_args.call(File.join(sdir, 'w3'), '--no-reuse'))
  check(st.exitstatus == 0 && out.include?('STOP BEFORE POST: data model spec is ready') && writes.call.empty?,
        "the build-new path still stops after validation with no writes (exit #{st.exitstatus}, writes #{writes.call.inspect})#{st.exitstatus == 0 ? '' : "\n#{out.lines.last(15).join}"}")
end

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "#{FAILS.size} FAILED:"
  FAILS.each { |x| puts "  - #{x}" }
  exit 1
end
