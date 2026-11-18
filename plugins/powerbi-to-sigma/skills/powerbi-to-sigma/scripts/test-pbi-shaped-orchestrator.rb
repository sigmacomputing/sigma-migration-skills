#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline test of `migrate-powerbi.rb --model-shape pbi` (data model side, Task 18a) through the REAL orchestrator,
# stopped with --stop-before-post. A stub required into every ruby subprocess replaces Net::HTTP (answers whoami and
# the connection's friendlyName, logs every request), so a stray POST/PUT is caught; no network, no credentials.
# The report layout comes from the fixture's signals.json, seeded into the work dir and read with --reuse-extract.
#
#   test_pbi_mode_offline_to_spec    sales fixture + a replay of the key-check and slicer-carry probe results:
#                                    no View element, Power BI names, B metrics on the split child, the time
#                                    intelligence elements, the key decisions and the slicer carry applied, the
#                                    four JSON documents written, nothing written to Sigma
#   test_pbi_mode_without_probe      inventory fixture (class D): the key check and the carry are skipped, said so
#   test_pbi_workbook_direct_sources lib level (Task 18b): the Phase 4 direct master map on a faked readback, the builder with
#                                    --direct-sources: no Data page, data-model sources, carried slicers wired, lint clean
#   test_pbi_live_element_on_the_rolling_page   a replayed slicer-carry.json forcing `live`: one live element, placed once
#   test_pbi_mode_end_to_end_to_the_workbook_spec   the orchestrator past the data model POST (stateful fake), ending at a refused
#                                    workbook POST, after the workbook was built, validated and linted
#   test_pbi_mode_class_d_without_page_facts / _scaffolds_class_d_page_summaries   class D: held back and recorded; drafts and
#                                    --page-facts with --shape pbi
#   test_views_mode_unchanged        the default shape is byte-identical to the golden captured from origin/main
#
# Run: ruby scripts/test-pbi-shaped-orchestrator.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require 'pbi_shape_run'
require 'control_lint'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

MIGRATE = File.join(__dir__, 'migrate-powerbi.rb')
FIX = File.join(File.dirname(__dir__), 'fixtures', 'pbi-shaped')
ENV['LANG'] = ENV['LC_ALL'] = 'en_US.UTF-8'

STUB = <<~'RUBY'
  require 'net/http'
  require 'json'
  class FakeSigmaConn
    def request(req)
      File.open(ENV.fetch('FAKE_SIGMA_LOG'), 'a') { |f| f.flock(File::LOCK_EX); f.puts("#{req.method} #{req.path}") }
      state = ENV['FAKE_SIGMA_STATE']
      code = '200'
      body = if req.path.start_with?('/v2/whoami') then JSON.generate('userId' => 'user-1')
             elsif req.path =~ %r{\A/v2/connections/[^/?]+\z} then JSON.generate('friendlyName' => true)
             elsif state && req.method == 'POST' && req.path == '/v2/dataModels/spec'
               # the end-to-end test: the data model POST succeeds and reads back what was posted (ids as posted)
               File.write(File.join(state, 'dm.json'), req.body)
               JSON.generate('dataModelId' => 'dm-fake')
             elsif state && req.method == 'GET' && req.path.start_with?('/v2/dataModels/dm-fake/spec') then File.read(File.join(state, 'dm.json'))
             elsif state && req.method == 'POST' && req.path.start_with?('/v2/workbooks')
               # ... and the WORKBOOK POST is refused, so a run ends right after the workbook spec is built and validated
               code = '500'
               JSON.generate('message' => 'fake Sigma: workbook POST refused by the test')
             else '{}'
             end
      res = (code == '200' ? Net::HTTPOK.new('1.1', '200', 'OK') : Net::HTTPInternalServerError.new('1.1', code, 'error'))
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

def read_json(*parts)
  path = File.join(*parts)
  File.exist?(path) ? JSON.parse(File.read(path)) : {}
end

def elements(doc)
  (doc['pages'] || []).flat_map { |p| p['elements'] || [] }
end

# The sales report: the overview/slicer pages plus the trend and rolling pages (class A, B and C measures).
def merged_signals(dir)
  a = read_json(FIX, 'sales', 'signals.json')
  b = read_json(FIX, 'sales', 'signals-trends.json')
  a['pages'] += b['pages']
  path = File.join(dir, 'signals-merged.json')
  File.write(path, JSON.generate(a))
  path
end

Dir.mktmpdir('pbi-shaped-orch') do |dir|
  stub = File.join(dir, 'fake_sigma_http.rb')
  log = File.join(dir, 'http.log')
  File.write(stub, STUB)
  File.write(File.join(dir, 'bundle.json'), JSON.generate('report.json' => '{}'))
  state_dir = File.join(dir, 'fake-state')
  FileUtils.mkdir_p(state_dir)
  env = { 'RUBYOPT' => "-r#{stub}", 'FAKE_SIGMA_LOG' => log, 'HOME' => dir, 'SIGMA_API_TOKEN' => 'tok',
          'SIGMA_BASE_URL' => 'https://api.sigmacomputing.com', 'SIGMA_ALLOW_INSECURE_BASE_URL' => '',
          'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil }
  writes = -> { (File.exist?(log) ? File.readlines(log) : []).map(&:strip).grep(/\A(POST|PUT|PATCH|DELETE) /) }

  run = lambda do |work, fixture, signals, *extra|
    wd = File.join(dir, work)
    FileUtils.rm_rf(wd)
    FileUtils.mkdir_p(wd)
    FileUtils.cp(signals, File.join(wd, 'signals.json'))
    File.delete(log) if File.exist?(log)
    full = extra.delete(':full') # end-to-end: no --stop-before-post, a stateful fake data model
    e = full ? env.merge('FAKE_SIGMA_STATE' => state_dir) : env
    fx = File.join(FIX, fixture)
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, st = Open3.capture2e(e, RbConfig.ruby, MIGRATE, '--tmsl', File.join(fx, 'model.bim'), '--pbir', File.join(dir, 'bundle.json'),
                              '--converter-out', File.join(fx, 'dm-raw.json'), '--out', wd, '--folder', 'f1', '--yes',
                              *(full ? [] : ['--stop-before-post']), '--reuse-extract', *extra)
    [out, st, wd]
  end

  puts "\ntest_pbi_mode_offline_to_spec"
  replay = File.join(FIX, 'sales', 'shape-probe-results.json')
  out, st, wd = run.call('pbi-sales', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--shape-probe-results', replay)
  check(st.exitstatus.zero? && out.include?('STOP BEFORE POST: data model spec is ready'),
        "stops after DM validation (exit #{st.exitstatus})#{st.exitstatus.zero? ? '' : "\n#{out.lines.last(15).join}"}")
  check(out.include?('reuse not supported in --model-shape pbi (v1); building a new data model'), 'the reuse scan says it is not supported')
  spec = read_json(wd, 'dm-spec.json')
  els = elements(spec)
  names = els.map { |e| e['name'] }
  check(!els.any? { |e| e['name'].to_s =~ /\bView\z/ }, 'dm-spec.json has no View element')
  check(%w[Date Category Product SKU Customer Store Sales].all? { |n| names.include?(n) } && !names.include?('DIM_DATE'),
        "Power BI table names, not warehouse names (#{names.first(8).join(', ')}...)")
  date = els.find { |e| e['name'] == 'Date' } || {}
  check((date['columns'] || []).any? { |c| c['name'] == 'DateKey' }, 'columns carry their Power BI names (Date[DateKey])')
  sales = els.find { |e| e['name'] == 'Sales' } || {}
  source = els.find { |e| e['name'] == 'Sales (source)' } || {}
  metric_names = (sales['metrics'] || []).map { |m| m['name'] }
  check(%w[List\ Value Private\ Label\ Sales Sales\ by\ Ship\ Date].all? { |m| metric_names.include?(m) } && (source['metrics'] || []).empty?,
        "B metrics sit on the split child (Sales: #{metric_names.join(', ')}); the (source) base has none")
  ti = ['Sales by month', 'Sales by quarter', 'Sales by month (month reset)', 'Sales by quarter (quarter reset)', 'Sales – rolling 28 days by day']
  check(ti.all? { |n| names.include?(n) }, 'the time-intelligence elements are built')
  by_month = els.find { |e| e['name'] == 'Sales by month' } || {}
  check((by_month['columns'] || []).any? { |c| c['name'] == 'Sales Amount' }, 'an A measure that shares a chart with a class C measure is read into the grouped element')
  check((by_month['columns'] || []).map { |c| c['name'] }.first(3) == ['Segment', 'Store Region', 'Customer Region'], 'the slicer fields are carried as the outer levels')
  rolling = els.find { |e| e['name'] == 'Sales – rolling 28 days by day' } || {}
  check(rolling.dig('source', 'statement').to_s.include?('pbi_combos'), 'the rolling summary carries the slicer combinations')
  check(spec['pages'].map { |p| p['name'] } == %w[Sales Shared], "the subject pages survive convert-model.rb (#{spec['pages'].map { |p| p['name'] }.inspect})")

  classes = read_json(wd, 'measure-classes.json')
  check(classes['counts'].values_at('A', 'B', 'C').all? { |n| n.to_i.positive? }, "measure-classes.json holds A, B and C (#{classes['counts'].inspect})")
  keys = read_json(wd, 'relationship-keys.json')
  vendor = (keys['decisions'] || []).find { |d| d['relationship'] == 'Product->Vendor' }
  product = els.find { |e| e['name'] == 'Product' } || {}
  check(keys['queries'].size >= 8 && vendor && vendor['action'] == 'dropped' && (product['relationships'] || []).none? { |r| r['name'].to_s =~ /vendor/i },
        'the key-check decisions are applied (a duplicated Vendor key drops that relationship)')
  carry = read_json(wd, 'slicer-carry.json')
  check(carry.dig('applied', 'Sales', 'carried') == ['Segment', 'Store Region', 'Customer Region'] && carry['applied']['Sales']['live'] == false &&
        carry['summaries'].length == 5 && carry['queries'].keys.any? { |k| k.start_with?('carry:Sales by month:density:') },
        'slicer-carry.json records the measured counts, the decisions and the queries')
  shaped = read_json(wd, 'pbi-shaped-model.json')
  check(shaped['size_stats'] && shaped['classes'] && shaped['pages'].length == 2 && shaped['grains'].values.sort.uniq == %w[day month quarter],
        "pbi-shaped-model.json carries the log (grains: #{shaped['grains'].values.uniq.sort.inspect})")
  check(writes.call.empty?, "zero writes reached Sigma (got #{writes.call.inspect})")
  sales_wd = wd

  puts "\ntest_pbi_mode_without_probe"
  out, st, wd = run.call('pbi-inventory', 'inventory', File.join(FIX, 'inventory', 'signals.json'), '--model-shape', 'pbi',
                          '--allow-incomplete-calculated-tables', 'fixture placeholder calculated table')
  check(st.exitstatus.zero? && out.include?('STOP BEFORE POST'), "inventory fixture runs to the stop (exit #{st.exitstatus})#{st.exitstatus.zero? ? '' : "\n#{out.lines.last(15).join}"}")
  counts = read_json(wd, 'measure-classes.json')['counts'] || {}
  check(%w[A C D].all? { |c| counts[c].to_i.positive? }, "measure-classes.json holds class D (#{counts.inspect})")
  check(out.include?('key check skipped: no --probe-sources') && out.include?('slicer carry skipped'), 'the skipped key check and carry are stated on the console')
  check((read_json(wd, 'pbi-shaped-model.json')['notes'] || []).include?('key check skipped: no --probe-sources'), 'and in the log')
  check(read_json(wd, 'relationship-keys.json')['queries'] == {}, 'no key queries without a probe')
  check(writes.call.empty?, 'zero writes reached Sigma')

  puts "\ntest_probe_failures_are_loud"
  bad = JSON.parse(File.read(replay))
  bad['Sales->Store'] = { 'ok' => false, 'error' => 'SQL compilation error: object does not exist' }
  bad.delete('Sales->Customer') # a key the replay lacks
  bad_path = File.join(dir, 'replay-bad.json')
  File.write(bad_path, JSON.generate(bad))
  out, st, wd = run.call('pbi-bad', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--shape-probe-results', bad_path)
  check(st.exitstatus == 10 && out.include?('Sales->Store') && out.include?('object does not exist') && out.include?('Sales->Customer') &&
        out.include?('--allow-unverified-keys'), "a failed or missing key result aborts with exit 10 naming the keys (exit #{st.exitstatus})")
  check(!File.exist?(File.join(wd, 'dm-spec.json')), 'nothing was built')
  out, st, wd = run.call('pbi-waived', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--shape-probe-results', bad_path, '--allow-unverified-keys')
  waived = read_json(wd, 'pbi-shaped-model.json')['waivers'] || []
  check(st.exitstatus.zero? && waived.length == 1 && waived[0]['flag'] == '--allow-unverified-keys' && waived[0]['relationships'].sort == ['Sales->Customer', 'Sales->Store'],
        "--allow-unverified-keys continues and records the waiver (exit #{st.exitstatus})")
  out, st, wd = run.call('pbi-noconn', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--probe-sources', '--probe-results', File.join(FIX, 'sales', 'shape-probe-results.json'))
  check(out.include?('key check skipped: --probe-sources was given but --connection is missing') &&
        (read_json(wd, 'pbi-shaped-model.json')['notes'] || []).any? { |n| n.include?('--connection is missing') },
        'a --probe-sources run that cannot build the live probe names the missing input')

  puts "\ntest_time_axis_density (Task 21z2)"
  dens = read_json(sales_wd, 'pbi-shaped-model.json')['time_density'] || {}
  check(dens.dig('facts', 'Sales', 'month', 'verified') == true && dens.dig('facts', 'Sales', 'month', 'sparse') == false && dens['sparse'] == [] &&
        dens.dig('facts', 'Sales', 'quarter', 'expected') == 12,
        "a dense replay is recorded in pbi-shaped-model.json and changes nothing (#{dens.inspect[0, 200]})")
  check(read_json(sales_wd, 'slicer-carry.json')['queries'].keys.include?('density:Sales:month') && read_json(sales_wd, 'slicer-carry.json')['queries'].keys.include?('density:Sales:quarter'),
        'the density queries are recorded with the other warehouse SQL (0600 file)')
  sp = JSON.parse(File.read(replay))
  sp['density:Sales:month'] = { 'ok' => true, 'rows' => [{ 'EXPECTED' => 38, 'PRESENT' => 36 }] }
  sp_path = File.join(dir, 'replay-sparse.json')
  File.write(sp_path, JSON.generate(sp))
  out, st, wd = run.call('pbi-sparse', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--shape-probe-results', sp_path)
  check(st.exitstatus.zero?, "a sparse month axis still builds (exit #{st.exitstatus})#{st.exitstatus.zero? ? '' : "\n#{out.lines.last(15).join}"}")
  sl = read_json(wd, 'pbi-shaped-model.json')
  snames = elements(read_json(wd, 'dm-spec.json')).map { |e| e['name'] }
  cls = (sl['classes'] || {})
  held = cls.select { |_k, c| c['class'] == 'D' && c['reason'].to_s.include?('month periods with no Sales rows') }.keys
  check(held.include?('Sales.Sales YTD') && held.include?('Sales.Sales PY') && !snames.include?('Sales by month') && !snames.include?('Sales by month (month reset)'),
        "the month-grain grouped C measures are class D with the reason and no month element is built (#{held.inspect})")
  check(snames.include?('Sales by quarter') && cls.dig('Sales.Sales YTD', 'reason').to_s.include?('page summary over the Date table'), 'the dense quarter grain is still built; the reason names the page summary route')
  check(sl.dig('time_density', 'sparse') == [{ 'fact' => 'Sales', 'grain' => 'month' }] && out.include?('sparse time axis'), 'the sparse (fact, grain) is listed in the log and on the console')
  nd = JSON.parse(File.read(replay))
  nd.delete('density:Sales:month')
  nd['density:Sales:quarter'] = { 'ok' => false, 'error' => 'boom' }
  nd_path = File.join(dir, 'replay-nodensity.json')
  File.write(nd_path, JSON.generate(nd))
  out, st, wd = run.call('pbi-nodens', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--shape-probe-results', nd_path)
  nl = read_json(wd, 'pbi-shaped-model.json')
  check(st.exitstatus.zero? && out.include?('time-axis density not verified') && nl.dig('time_density', 'facts', 'Sales', 'month', 'verified') == false &&
        nl.dig('time_density', 'facts', 'Sales', 'quarter', 'reason').to_s.include?('boom') && elements(read_json(wd, 'dm-spec.json')).any? { |e| e['name'] == 'Sales by month' },
        'a missing or failed density result keeps the grouped build, loudly (console and log)')

  # ---------------------------------------------------------------------------------------------------------
  # Task 18b: the workbook side, at lib level. The shaped model, the log and the carry document are what the
  # orchestrator wrote for the sales run above; the readback is faked from its posted dm-spec.json.
  # ---------------------------------------------------------------------------------------------------------
  puts "\ntest_pbi_workbook_direct_sources"
  tmsl = read_json(FIX, 'sales', 'model.bim')
  shaped_dm = read_json(sales_wd, 'dm-raw.json')
  shaped_log = read_json(sales_wd, 'pbi-shaped-model.json')
  carry_doc = read_json(sales_wd, 'slicer-carry.json')
  posted = read_json(sales_wd, 'dm-spec.json')
  readback = { 'dataModelId' => 'dm-test',
               'pages' => posted['pages'].map { |p| { 'id' => p['id'], 'name' => p['name'], 'elements' => (p['elements'] || []).map { |e|
                 h = { 'id' => "rb-#{e['id']}", 'name' => e['name'] }
                 h['metrics'] = e['metrics'] if e['metrics']
                 h } } } }
  merged = merged_signals(dir)
  merged_doc = read_json(merged)
  dmap = PbiShapeRun.direct_master_map(shaped_dm, readback, tmsl, shaped_log, merged_doc, carry_doc)
  check(dmap['masters'].values.all? { |m| m['direct'] == true && m['element_name'] }, 'every master of the Phase 4 map is a direct data model element')
  check(dmap['fields']['Sales.Sales Amount']['ref'] == '[Metrics/Sales Amount]' && dmap['fields']['Sales.Sales Amount']['master'] == 'Sales', 'a class A measure is bound to its [Metrics/...] ref')
  mid_m = dmap['masters']['Sales by month']['id']
  check(dmap['fields']['Sales.Sales YTD']['formula'] == "Sum(If([#{mid_m}/Month] = Max([#{mid_m}/Month]), [#{mid_m}/Sales YTD], Null))", 'a class C measure reads the carried summary on the latest period (Sum over the carried values)')
  carried = dmap['carried_alts'].select { |a| a['field'] }
  check(carried.map { |a| a['field'] }.uniq.sort == ['Customer.Customer Region', 'Customer.Segment', 'Store.Store Region'] &&
        dmap['fields']['Store.Store Region']['alts'].any? { |a| a['master'] == 'Sales – rolling 28 days by day' },
        "a carried slicer field has an alt on every summary that carries it (#{carried.size} alts)")
  File.write(File.join(dir, 'master-map.json'), JSON.pretty_generate(dmap))
  File.write(File.join(dir, 'dm-context.json'), JSON.generate(readback))
  wbdir = File.join(dir, 'wb')
  FileUtils.mkdir_p(wbdir)
  bout, bst = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'build-workbook-from-pbir.rb'), '--signals', merged, '--master-map', File.join(dir, 'master-map.json'),
                              '--data-model', 'dm-test', '--name', 'T', '--model', File.join(FIX, 'sales', 'model.bim'), '--direct-sources',
                              '--control-scope-out', File.join(wbdir, 'control-scope.json'), '--coverage-out', File.join(wbdir, 'coverage.json'),
                              '--out', File.join(wbdir, 'workbook-spec.json'), '--layout-out', File.join(wbdir, 'layout.xml'))
  check(bst.success?, "the builder runs with --direct-sources (#{bout.lines.last.to_s.strip})")
  spec = read_json(wbdir, 'workbook-spec.json')
  doc = spec['document'] || {}
  wels = doc['elements'] || []
  charts = wels.select { |e| %w[kpi-chart bar-chart line-chart pivot-table table].include?(e['kind']) }
  check(doc['pages'].none? { |p| p['name'] == 'Data' } && !doc['layout'].include?('page-data'), 'no Data page')
  check(!JSON.generate(wels).include?('master-'), 'no master- reference anywhere in the elements')
  check(charts.all? { |e| e.dig('source', 'kind') == 'data-model' && e.dig('source', 'elementId').to_s.start_with?('rb-') }, "every chart, pivot and KPI reads a data model element (#{charts.size})")
  scope = read_json(wbdir, 'control-scope.json')
  roll = (scope['controls'] || []).find { |c| c['sourceName'].to_s.end_with?('Store.Store Region') && Array(c['excluded']).empty? && c['wiredMasters'].to_a.include?('Sales – rolling 28 days by day') }
  check(roll, 'the carried Store Region control targets the charts that read the rolling summary (nothing excluded as cross-grain)')
  lint_out, = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'lib', 'preflight_lint.rb'), File.join(wbdir, 'workbook-spec.json'))
  check(lint_out.lines.grep(/✗/).empty? && lint_out.lines.grep(/[1-9]\d* violation/).empty?, "preflight_lint: zero violations (#{lint_out.lines.last.to_s.strip})")
  vout, vst = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'validate-spec.rb'), '--type', 'workbook', '--dm-context', File.join(dir, 'dm-context.json'), File.join(wbdir, 'workbook-spec.json'))
  check(vst.success?, "validate-spec --type workbook passes (#{vout.lines.last.to_s.strip})")
  cv = ControlLint.lint(spec, scope: scope)
  check(cv.empty?, "the control lint (gate 7) is clean on the built spec: #{cv.first(2).inspect}")

  puts "\ntest_pbi_date_slicer_on_a_non_live_rolling_page"
  rolling_page = doc['pages'].find { |p| p['name'] == 'Rolling' }
  day_spec = JSON.parse(JSON.generate(spec))
  day_scope = JSON.parse(JSON.generate(scope))
  dlog = PbiShapeRun.apply_slicers!(day_spec, day_scope, shaped_dm, posted, dmap, shaped_log, carry_doc, tmsl, 'snowflake')
  ddoc = day_spec['document']
  roll_name = 'Sales – rolling 28 days by day'
  roll_readers = ddoc['elements'].select { |e| e.dig('source', 'elementId') == dmap['masters'][roll_name]['element_id'] && e['kind'] != 'control' }
  fcol = ->(e) { Array(e['columns']).find { |c| c['id'].to_s.include?('-sl-date-YearFilter2') } }
  check(dlog['live'].empty? && dlog['date_filters'].length == 1 && dlog['date_filters'][0]['field'] == 'Date.Year',
        "no live element, one date filter record (#{dlog['date_filters'].map { |d| d['field'] }.inspect})")
  check(roll_readers.length >= 2 && roll_readers.all? { |e| fcol.call(e) && fcol.call(e)['formula'] == "Year([#{roll_name}/Day])" },
        "every chart that reads the rolling summary gets a Year([Day]) filter column (#{roll_readers.map { |e| e['name'] }.inspect})")
  ycontrol = ddoc['elements'].find { |e| e['kind'] == 'control' && e['controlId'] == 'YearFilter2' && e['controlType'] != 'synced' }
  check(roll_readers.all? { |e| ycontrol['filters'].any? { |f| f.dig('source', 'elementId') == e['id'] && f['columnId'] == fcol.call(e)['id'] } },
        'the Year control targets those columns (the plotted days are filtered; the window is not recomputed)')
  check(ControlLint.lint(day_spec, scope: day_scope).empty?, 'the control lint stays clean')
  File.write(File.join(wbdir, 'day-spec.json'), JSON.pretty_generate(day_spec))
  vout, vst = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'validate-spec.rb'), '--type', 'workbook', '--dm-context', File.join(dir, 'dm-context.json'), File.join(wbdir, 'day-spec.json'))
  check(vst.success?, "and validate-spec passes (#{vout.lines.last.to_s.strip})")
  check(PbiShapeRun.date_part_formula('Month Name', '[x]').nil? && PbiShapeRun.date_part_formula('Month Start', '[x]') == 'MakeDate(Year([x]), Month([x]), 1)', 'date_part_formula: a name field has no day expression')

  puts "\ntest_pbi_live_element_on_the_rolling_page"
  # the summary carries no slicer column (as when the carry decision was live): rebuild the map and the workbook that way
  log2 = JSON.parse(JSON.generate(shaped_log))
  log2['time_intel'].each { |r| r.delete('carried') if r['form'] == 'rolling_sql' }
  dmap2 = PbiShapeRun.direct_master_map(shaped_dm, readback, tmsl, log2, merged_doc, carry_doc)
  File.write(File.join(dir, 'master-map2.json'), JSON.pretty_generate(dmap2))
  wbdir2 = File.join(dir, 'wb2')
  FileUtils.mkdir_p(wbdir2)
  _o, bst2 = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'build-workbook-from-pbir.rb'), '--signals', merged, '--master-map', File.join(dir, 'master-map2.json'),
                             '--data-model', 'dm-test', '--name', 'T', '--model', File.join(FIX, 'sales', 'model.bim'), '--direct-sources',
                             '--control-scope-out', File.join(wbdir2, 'control-scope.json'), '--coverage-out', File.join(wbdir2, 'coverage.json'),
                             '--out', File.join(wbdir2, 'workbook-spec.json'), '--layout-out', File.join(wbdir2, 'layout.xml'))
  check(bst2.success?, 'the builder runs on the uncarried map')
  spec2 = read_json(wbdir2, 'workbook-spec.json')
  scope2 = read_json(wbdir2, 'control-scope.json')
  forced = JSON.parse(JSON.generate(carry_doc))
  forced['summaries'].each { |s| s['live'] = true if s['summary'] =~ /rolling/ }
  live_spec = JSON.parse(JSON.generate(spec2))
  live_scope = JSON.parse(JSON.generate(scope2))
  slog = PbiShapeRun.apply_slicers!(live_spec, live_scope, shaped_dm, posted, dmap2, log2, forced, tmsl, 'snowflake')
  ldoc = live_spec['document']
  lives = ldoc['elements'].select { |e| e['name'].to_s.end_with?(PbiSlicerCarry::LIVE_SUFFIX) }
  check(slog['changed'] && lives.length == 1 && slog['live'].length == 1 && slog['live'][0]['page'] == 'Rolling', "exactly one live element, on the Rolling page (#{lives.map { |e| e['name'] }.inspect})")
  live = lives[0] || {}
  placed = ldoc['layout'].scan(/\belementId="([^"]+)"/).flatten
  check(placed.count(live['id']) == 1 && PbiShapeRun.page_elements(ldoc['layout'])[rolling_page['id']].include?(live['id']), 'it is placed once in the layout, on that page')
  check(placed.group_by(&:itself).none? { |_i, r| r.length > 1 } && (ldoc['elements'].map { |e| e['id'] } - placed).empty?, 'every workbook element is placed exactly once')
  readers = ldoc['elements'].select { |e| e.dig('source', 'elementId') == live['id'] }
  check(readers.length >= 2 && readers.none? { |e| e.dig('source', 'kind') == 'data-model' } && readers.all? { |e| e['kind'] != 'control' }, "the page's charts read the live element (#{readers.map { |e| e['name'] }.inspect})")
  stmt = live.dig('source', 'statement').to_s
  check(stmt !~ /\bunion\b/i && %w[SegmentFilter2 StoreRegionFilter2 CustomerRegionFilter2].all? { |c| stmt.include?("{{#formula ArrayLength([#{c}])}}") },
        'its SQL carries one guarded predicate per uncarried slicer and no union')
  check(!stmt.include?('YearFilter2') && !stmt.include?('DIM_DATE" sj'), 'no date predicate on the fact rows: the rolling window is not cut')
  check(readers.all? { |e| Array(e['columns']).any? { |c| c['formula'] == "Year([#{live['id']}/Day])" } }, 'the Year slicer instead filters the plotted days of the live readers')
  check(live['columns'].any? { |c| c['name'] == 'Slicer Filter Count' && c['formula'].include?('[StoreRegionFilter2]') }, 'it names the controls it applies')
  slc = live_scope['controls'].find { |c| c['controlId'] == 'StoreRegionFilter2' } || {}
  check(Array(slc['scope']).any? { |i| readers.map { |e| e['id'] }.include?(i) } && Array(slc['excluded']).none? { |x| readers.map { |e| e['id'] }.include?(x['element']) }, 'the control-scope sidecar lists the live readers for those controls')
  File.write(File.join(wbdir, 'live-spec.json'), JSON.pretty_generate(live_spec))
  lint_out, = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'lib', 'preflight_lint.rb'), File.join(wbdir, 'live-spec.json'))
  check(lint_out.lines.grep(/✗/).empty? && lint_out.lines.grep(/[1-9]\d* violation/).empty?, "the live-element spec passes preflight_lint (#{lint_out.lines.last.to_s.strip})")
  vout, vst = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'validate-spec.rb'), '--type', 'workbook', '--dm-context', File.join(dir, 'dm-context.json'), File.join(wbdir, 'live-spec.json'))
  check(vst.success?, "and validate-spec (#{vout.lines.last.to_s.strip})")
  cv = ControlLint.lint(live_spec, scope: live_scope)
  check(cv.empty?, "and the control lint, with the live readers in the controls' scope: #{cv.first(2).inspect}")
  again = JSON.parse(JSON.generate(live_spec))
  PbiShapeRun.apply_slicers!(again, live_scope, shaped_dm, posted, dmap2, log2, forced, tmsl, 'snowflake')
  check(again['document']['elements'].length == ldoc['elements'].length && again['document']['layout'] == ldoc['layout'], 'applying twice adds no second live element')
  # polish-layout.rb on the spec with the live element: still placed exactly once
  File.write(File.join(wbdir, 'polish-in.json'), JSON.pretty_generate(live_spec))
  pout, pst = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'polish-layout.rb'), '--spec', File.join(wbdir, 'polish-in.json'), '--signals', merged,
                              '--out', File.join(wbdir, 'polished.json'))
  polished = pst.success? ? read_json(wbdir, 'polished.json') : {}
  pl = (polished['document'] || polished)['layout'].to_s.scan(/\belementId="([^"]+)"/).flatten
  check(pst.success? && pl.count(live['id']) == 1 && pl.group_by(&:itself).none? { |_i, r| r.length > 1 } &&
        (((polished['document'] || polished)['elements'] || []).map { |e| e['id'] } - pl).empty?,
        "polish-layout.rb keeps the live element placed exactly once (exit #{pst.exitstatus})#{pst.success? ? '' : "\n#{pout.lines.last(4).join}"}")
  plain_spec = JSON.parse(JSON.generate(spec))
  plog = PbiShapeRun.apply_slicers!(plain_spec, JSON.parse(JSON.generate(scope)), shaped_dm, posted, dmap, shaped_log, carry_doc, tmsl, 'snowflake')
  check(plog['live'].empty? && !plain_spec['document']['elements'].any? { |e| e['name'].to_s.end_with?(PbiSlicerCarry::LIVE_SUFFIX) }, 'without a live decision there is no live element')

  puts "\ntest_i6_not_reached_control_is_listed_as_unreached"
  i6_spec = { 'document' => { 'elements' => [{ 'id' => 'c1', 'name' => 'Direct Chart', 'kind' => 'bar-chart', 'source' => { 'kind' => 'table', 'elementId' => 'm1' } }],
                              'pages' => [{ 'id' => 'p', 'name' => 'P' }], 'layout' => nil } }
  i6_scope = { 'controls' => [{ 'controlId' => 'Region', 'sourceName' => 'slicer Region', 'scope' => [],
                                'excluded' => [{ 'element' => 'c1', 'reason' => 'the element has no column reaching [Dim/Region]', 'not_reached' => true }] }] }
  i6_log = PbiShapeRun.apply_slicers!(i6_spec, i6_scope, {}, {}, { 'masters' => {}, 'fields' => {}, 'page_fields' => {} },
                                      { 'time_intel' => [], 'classes' => {} }, {}, { 'model' => {} }, 'snowflake')
  check(i6_log['unreached'] == [{ 'control' => 'Region', 'source' => 'slicer Region', 'element' => 'Direct Chart', 'reason' => 'the element has no column reaching [Dim/Region]' }],
        "I6: a control that cannot reach a direct element is listed in `unreached` (#{i6_log['unreached'].inspect})")

  puts "\ntest_pbi_class_d_page_summary_live_element"
  pfx = File.join(FIX, '..', 'page-facts')
  pfd = File.join(dir, 'pfx')
  FileUtils.mkdir_p(pfd)
  FileUtils.cp([File.join(pfx, 'dm-spec.json'), File.join(pfx, 'master-map.json')], pfd)
  conn = '00000000-0000-4000-8000-00000000c0de'
  py = ->(*args) { Open3.capture2e('python3', *args) }
  py.call(File.join(__dir__, 'scaffold-page-fact.py'), '--model', File.join(pfx, 'model.bim'), '--signals', File.join(pfx, 'signals.json'), '--dm-spec', File.join(pfd, 'dm-spec.json'),
          '--master-map', File.join(pfd, 'master-map.json'), '--out-dir', File.join(pfd, 'pf'), '--all-pages', '--shape', 'pbi')
  py.call(File.join(__dir__, 'integrate-page-fact.py'), File.join(pfd, 'pf'), '--dm-spec', File.join(pfd, 'dm-spec.json'), '--connection', conn, '--allow-todo', '--shape', 'pbi')
  py.call(File.join(__dir__, 'integrate-page-fact.py'), File.join(pfd, 'pf'), '--master-map', File.join(pfd, 'master-map.json'), '--allow-todo', '--shape', 'pbi')
  _o, pst = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'build-workbook-from-pbir.rb'), '--signals', File.join(pfx, 'signals.json'), '--master-map', File.join(pfd, 'master-map.json'),
                            '--data-model', 'dm-fixture', '--name', 'PF', '--model', File.join(pfx, 'model.bim'), '--direct-sources',
                            '--control-scope-out', File.join(pfd, 'scope.json'), '--coverage-out', File.join(pfd, 'cov.json'),
                            '--out', File.join(pfd, 'wb.json'), '--layout-out', File.join(pfd, 'l.xml'))
  check(pst.success?, 'the builder runs on the integrated page-fact map with --direct-sources')
  pf_wb = read_json(pfd, 'wb.json')
  pf_scope = read_json(pfd, 'scope.json')
  pf_map = read_json(pfd, 'master-map.json')
  runner = lambda do |wdoc|
    File.write(File.join(pfd, 'live-in.json'), JSON.generate(wdoc))
    o, st = py.call(File.join(__dir__, 'pbi-live-page-fact.py'), '--spec', File.join(pfd, 'live-in.json'), '--page-facts', File.join(pfd, 'pf'), '--model', File.join(pfx, 'model.bim'),
                    '--dm-spec', File.join(pfd, 'dm-spec.json'), '--master-map', File.join(pfd, 'master-map.json'), '--out', File.join(pfd, 'live-out.json'))
    raise "pbi-live-page-fact.py failed: #{o}" unless st.success?
    read_json(pfd, 'live-out.json')['summaries']
  end
  plog = PbiShapeRun.apply_slicers!(pf_wb, pf_scope, { 'pages' => [] }, read_json(pfd, 'dm-spec.json'), pf_map, { 'time_intel' => [], 'classes' => {} }, {}, nil, 'snowflake', page_fact_live: runner)
  pdoc = pf_wb['document']
  stock = plog['live'].find { |l| l['summary'] == "Stock Cover \u2013 summary" } || {}
  live = (pdoc['elements'].find { |e| e['id'] == stock['element_id'] }) || {}
  stmt = live.dig('source', 'statement').to_s
  check(stock['page'] == 'Stock Cover' && live['name'] == "Stock Cover \u2013 summary#{PbiSlicerCarry::LIVE_SUFFIX}", "the Stock Cover summary gets one live element (#{live['name']})")
  check(stock['hooks'].length == 2 && stock['hooks'].map { |h| h['fact'] }.sort == %w[Sales Stock], 'its SQL has a hook per fact CTE (Stock and Sales)')
  check(%w[RegionFilter ManagerNameFilter2].all? { |c| stmt.scan("{{#formula ArrayLength([#{c}])}} = 0").length == 2 }, 'each slicer outside the grain has a predicate in each relevant hook')
  check(!stmt.include?('Param Filter Count') && live['columns'].any? { |c| c['name'] == 'Slicer Filter Count' }, 'and no gate branch or union element: just the guarded predicates')
  repointed = pdoc['elements'].select { |e| e.dig('source', 'elementId') == live['id'] && e['kind'] != 'control' }
  summary_id = pf_map.dig('masters', "Stock Cover \u2013 summary", 'element_id')
  stock_ids = PbiShapeRun.page_elements(pdoc['layout'])[pdoc['pages'].find { |p| p['name'] == 'Stock Cover' }['id']]
  check(repointed.any? && pdoc['elements'].none? { |e| stock_ids.include?(e['id']) && e['kind'] != 'control' && e.dig('source', 'elementId') == summary_id },
        "the page's charts read the live element (#{repointed.map { |e| e['name'] }.inspect})")
  placed = pdoc['layout'].scan(/\belementId="([^"]+)"/).flatten
  check(placed.count(live['id']) == 1 && placed.group_by(&:itself).none? { |_i, r| r.length > 1 }, 'the live element is placed once in the layout')
  check(ControlLint.lint(pf_wb, scope: pf_scope).select { |v| v =~ /Stock Cover|RegionFilter|ManagerNameFilter2/ }.empty?, 'the control lint finds nothing on the Stock Cover controls')

  puts "\ntest_pbi_mode_end_to_end_to_the_workbook_spec"
  out, st, wd = run.call('pbi-e2e', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--shape-probe-results', replay, ':full')
  wbs = File.join(wd, 'workbook-spec.json')
  check(File.exist?(wbs) && out.include?('master-map (pbi):') && out.include?('direct sources:'),
        "the orchestrator runs Phase 4 in pbi mode through the builder (exit #{st.exitstatus})#{File.exist?(wbs) ? '' : "\n#{out.lines.last(25).join}"}")
  check(st.exitstatus == 4 && (out.include?('fake Sigma: workbook POST refused') || out.include?('POST failed')), 'and stops at the stubbed workbook POST, after the workbook was built and validated')
  check(!out.include?('wire-slicer-gate'), 'wire-slicer-gate.py is not run in pbi mode')
  e2e = read_json(wbs)['document'] || {}
  mm = read_json(wd, 'master-map.json')
  check(mm['masters'] && mm['masters'].values.all? { |m| m['direct'] == true } && mm['masters']['Sales']['data_model'] == 'dm-fake', 'master-map.json is the direct map built on the readback (dataModelId dm-fake)')
  check((e2e['pages'] || []).none? { |p| p['name'] == 'Data' } && !JSON.generate(e2e['elements'] || []).include?('master-') &&
        (e2e['elements'] || []).select { |e| %w[kpi-chart bar-chart line-chart pivot-table table].include?(e['kind']) }.all? { |e| e.dig('source', 'kind') == 'data-model' },
        'the workbook spec has no Data page and every chart, KPI and pivot reads a data model element')
  sh = read_json(wd, 'pbi-shaped-model.json')
  check(sh['direct_map'] && sh['direct_map']['masters'] == mm['masters'].size && sh['slicers'] && sh['slicers']['carried'].length == 5 && sh['slicers']['live'] == [],
        'pbi-shaped-model.json records direct_map and slicers (carried summaries, no live element: every slicer is carried)')
  check(read_json(wd, 'coverage.json').dig('summary', 'builtElements').to_i.positive?, 'coverage.json is written')
  lim = sh['limits'] || []
  # I2: the quarter-grain elements all carry the integer Year and Quarter columns now, so either of the two reads the visual
  check(lim.any? { |l| l['kind'] == 'mixed_summary' && l['visual'] == 'Quarter: sales, QTD, YoY' && l['dropped'].length == 1 && (l['dropped'] & %w[Sales.Sales QTD Sales.Sales\ YoY\ %]).any? && l['dropped_measures'] == l['dropped'] } &&
        out.include?('[limit] Quarter: sales, QTD, YoY'),
        "pbi-shaped-model.json limits lists the visuals that lost a measure by mixing summaries (#{lim.map { |l| l['visual'] }.inspect})")
  posts = (File.exist?(log) ? File.readlines(log) : []).map(&:strip).grep(/\APOST /)
  check(posts.include?('POST /v2/dataModels/spec') && posts.count { |l| l.start_with?('POST /v2/workbooks') } == 1, "one data model POST and the one refused workbook POST (#{posts.inspect})")

  puts "\ntest_pbi_conflict_visual_held_back_and_listed"
  # Task 21x: "Sales by ship month and order month" reads an order-date measure and a USERELATIONSHIP ship-date measure on one
  # Date axis. Sigma reads one path per element, so it is held back (class D), never built on the active path.
  conflict_title = 'Sales by ship month and order month'
  cov_e2e = read_json(wd, 'coverage.json')
  held_cov = Array(cov_e2e['unresolved']).select { |u| u['severity'] == 'dropped' && u['visual'] == conflict_title }
  check(!(e2e['elements'] || []).any? { |e| e['name'].to_s == conflict_title },
        "no workbook element is built for the conflict visual (#{(e2e['elements'] || []).map { |e| e['name'] }.grep(/ship month/).inspect})")
  check(held_cov.length == 1 && held_cov[0]['detail'] =~ /two relationship paths to Date: .*Sigma reads one path per element/,
        "coverage.json records it as dropped with the reason (#{held_cov.inspect})")
  check((e2e['elements'] || []).any? { |e| e['name'].to_s == 'Sales by Ship Date' } &&
        (e2e['elements'] || []).any? { |e| e['name'].to_s =~ /\AChannel: ship date vs order date/ || e['name'].to_s == 'Sales by Ship Date by Store Region' },
        'the other Shipping visuals still build')
  rep_out, rep_st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'pbi-shaped-report.rb'), '--tmsl', File.join(FIX, 'sales', 'model.bim'),
                                    '--signals', File.join(wd, 'signals.json'), '--dm-spec', File.join(wd, 'dm-spec.json'), '--wb-spec', wbs,
                                    '--classes', File.join(wd, 'measure-classes.json'), '--shaped-log', File.join(wd, 'pbi-shaped-model.json'),
                                    '--out-dir', wd)
  lim_md = File.read(File.join(wd, 'limits.md')) rescue ''
  pmap = read_json(wd, 'pbi-map.json')
  pm_item = Array(pmap['visuals']).find { |i| i['pbi'].to_s.end_with?(conflict_title) }
  check(rep_st.success? && lim_md.include?(conflict_title) && lim_md =~ /two relationship paths to Date: .*Sigma reads one path per element/,
        "limits.md section 1 names the visual with the reason (#{rep_out.lines.last.to_s.strip})")
  check(pm_item && pm_item['sigma'].nil? && pm_item['reason'] =~ /two relationship paths to Date/, "pbi-map names it, with no Sigma element: #{pm_item.inspect}")

  puts "\ntest_pbi_mode_class_d_without_page_facts"
  out, st, wd = run.call('pbi-inv-e2e', 'inventory', File.join(FIX, 'inventory', 'signals.json'), '--model-shape', 'pbi',
                          '--allow-incomplete-calculated-tables', 'fixture placeholder calculated table', ':full')
  cov = read_json(wd, 'coverage.json')
  inv_doc = (read_json(wd, 'workbook-spec.json')['document'] || {})
  check(File.exist?(File.join(wd, 'workbook-spec.json')) && out.include?('class D measure(s)') && out.include?('HELD BACK'),
        "the class D measures are named and their visuals held back (exit #{st.exitstatus})#{File.exist?(File.join(wd, 'workbook-spec.json')) ? '' : "\n#{out.lines.last(25).join}"}")
  held = Array(cov['unresolved']).select { |u| u['severity'] == 'dropped' && u['pbi_type'].to_s != 'slicer' }
  check(held.any? && held.all? { |u| u['detail'].to_s.length.positive? }, "the held-back class D visuals are recorded as dropped in coverage.json (#{held.map { |u| u['visual'] }.first(4).inspect})")
  check((inv_doc['elements'] || []).none? { |e| e['kind'] == 'table' && Array(e['columns']).empty? }, 'no empty element was shipped')

  puts "\ntest_pbi_mode_scaffolds_class_d_page_summaries"
  out, st, wd = run.call('pbi-inv-scaffold', 'inventory', File.join(FIX, 'inventory', 'signals.json'), '--model-shape', 'pbi',
                          '--allow-incomplete-calculated-tables', 'fixture placeholder calculated table', '--scaffold-page-facts')
  pf_json = Dir[File.join(wd, 'page-facts-draft', '*', 'page-fact.json')].map { |f| JSON.parse(File.read(f)) }
  check(st.exitstatus.zero? && out.include?('class D pages: Cover') && pf_json.length == 1, "--scaffold-page-facts defaults to the pages that read a class D measure (exit #{st.exitstatus}; #{pf_json.length} draft(s))")
  check(pf_json[0] && pf_json[0]['name'] == "Cover \u2013 summary" && pf_json[0]['description'].to_s.length.positive?, "the draft is a named, described summary (#{pf_json[0] && pf_json[0]['name']})")
  drafts = File.join(wd, 'page-facts-draft')
  out, st, wd2 = run.call('pbi-inv-pf', 'inventory', File.join(FIX, 'inventory', 'signals.json'), '--model-shape', 'pbi',
                          '--allow-incomplete-calculated-tables', 'fixture placeholder calculated table', '--page-facts', drafts,
                          '--allow-page-fact-todo', '--connection', '11111111-2222-3333-4444-555555555555', ':full')
  pf_dm = elements(read_json(wd2, 'dm-spec.json')).find { |e| e['name'] == "Cover – summary" }
  pf_mm = read_json(wd2, 'master-map.json')
  pf_wb = read_json(wd2, 'workbook-spec.json')['document'] || {}
  check(pf_dm && pf_dm['description'].to_s.length.positive?, "--page-facts (pbi): the DM side adds the named, described summary (exit #{st.exitstatus})#{pf_dm ? '' : "\n#{out.lines.last(20).join}"}")
  check(pf_mm.dig('masters', "Cover – summary", 'direct') == true && pf_mm['page_fields']['Cover'], 'and the master-map side binds the page to it as a direct master')
  pf_id = pf_mm.dig('masters', "Cover \u2013 summary", 'element_id')
  readers = (pf_wb['elements'] || []).select { |e| e.dig('source', 'kind') == 'data-model' && e.dig('source', 'elementId') == pf_id }
  check(!out.include?('wire-slicer-gate') && (pf_wb['pages'] || []).none? { |p| p['name'] == 'Data' } && readers.any?,
        "the Cover charts read the summary directly, no Data page, no slicer gate (#{readers.map { |e| e['name'] }.first(3).inspect})")
  check(read_json(wd2, 'pbi-shaped-model.json')['slicers'].is_a?(Hash), 'the slicer record is written')
  out, st, sc_wd = run.call('pbi-sales-scaffold', 'sales', merged_signals(dir), '--model-shape', 'pbi', '--shape-probe-results', replay, '--scaffold-page-facts')
  check(st.exitstatus.zero? && out.include?('class D pages: Shipping') && !out.include?('class D pages: Shipping,'),
        'a report with no class D measure drafts only the page of its class D visual (Shipping, Task 21x)')

  puts "\ntest_pbi_scaffold_names_base_table_and_both_join_keys"
  ship_dir = File.join(sc_wd, 'page-facts-draft', 'shipping')
  ship_sql = File.exist?(File.join(ship_dir, 'page-fact.sql')) ? File.read(File.join(ship_dir, 'page-fact.sql')) : ''
  ship_brief = File.exist?(File.join(ship_dir, 'closure.md')) ? File.read(File.join(ship_dir, 'closure.md')) : ''
  ship_pf = read_json(ship_dir, 'page-fact.json')
  base_path = elements(read_json(sc_wd, 'dm-spec.json')).find { |e| e['name'] == 'Sales (source)' }.dig('source', 'path')
  check(!ship_sql.include?('no data-model element') && !ship_brief.include?('no data-model element') &&
        Array(ship_pf['todo']).none? { |t| t['reason'].to_s.include?('no data-model element') },
        "the draft has no 'no data-model element' TODO (#{Array(ship_pf['todo']).map { |t| t['reason'] }.first(2).inspect})")
  check(base_path && ship_sql.include?("FROM #{base_path.join('.')}"),
        "the draft reads the (source) base's warehouse path #{base_path.inspect}")
  check(ship_sql =~ /"ORDER_DATE_KEY"|"OrderDateKey"/i && ship_sql =~ /"SHIP_DATE_KEY"|"ShipDateKey"/i,
        'the draft joins Date on both OrderDateKey and ShipDateKey')
  check(ship_brief =~ /Sales Amount.*OrderDateKey/ && ship_brief =~ /Sales by Ship Date.*ShipDateKey/ && ship_brief.include?('## Relationship paths'),
        'the brief states the join for each measure explicitly')
  check(ship_pf['name'] == "Shipping \u2013 summary" && Array(ship_pf['columns']).any? { |c| c['role'] == 'component' },
        'and the summary has component columns for the measures')

  puts "\ntest_freshness_compare_uses_dm_elements_in_pbi_mode"
  fresh_doc = read_json(dir, 'pbi-sales', 'dm-spec.json')
  fresh_tmsl = read_json(FIX, 'sales', 'model.bim')
  fresh_tables = (fresh_tmsl['model'] || fresh_tmsl)['tables'].map { |t| t['name'] }
  snapshot = fresh_tables.each_with_object({}) { |t, h| h[t] = { 'rows' => 100, 'maxDates' => {} } }
  # the fixture's fact has no date column; Sales carries a date-like key, Date carries the calendar date
  snapshot['Sales']['maxDates'] = { 'OrderDateKey' => '2024-03-01' }
  snapshot['Date']['maxDates'] = { 'Date' => '2024-03-01' }
  tcol = lambda { |t, c| (fresh_tmsl['model'] || fresh_tmsl)['tables'].find { |x| x['name'] == t }['columns'].find { |x| x['name'] == c } || {} }
  order_col = tcol.call('Sales', 'OrderDateKey')
  check(order_col['sourceColumn'].to_s != '', "fixture: Sales[OrderDateKey] has a sourceColumn (#{order_col['sourceColumn'].inspect})")
  fq = PbiShapeRun.freshness_queries(fresh_doc, fresh_tmsl, snapshot, 'snowflake')
  skipped = fq.select { |_t, q| q['skip'] }
  # Vendor is the one table with no element (its relationship was dropped by the key check and the table folded away)
  check(skipped.keys == ['Vendor'] && skipped['Vendor']['skip'].include?('no data model element'),
        "no table is SKIPPED for a missing master; only the folded-away Vendor has no element (#{skipped.inspect})")
  check(fq.size == fresh_tables.size, "one entry per Power BI table (#{fq.size} of #{fresh_tables.size})")
  fels = elements(fresh_doc)
  base = fels.find { |e| e['name'].to_s =~ /\ASales \(source\)\z/i }
  check(base && base.dig('source', 'kind') == 'warehouse-table', 'the split fact has a "(source)" base on a warehouse table')
  if base
    root_sql = Array(base.dig('source', 'path')).map { |p| %("#{p}") }.join('.')
    check(fq['Sales']['sql'].include?("FROM #{root_sql}"), "Sales reads the (source) base's path: #{fq['Sales']['sql']}")
  end
  check(fq['Sales']['sql'].start_with?('SELECT COUNT(*) AS "N"'), 'the query leads with COUNT(*) AS "N"')
  check(fq['Sales']['date_sql'].to_s.include?(%(MAX("#{order_col['sourceColumn']}") AS "D0")) && fq['Sales']['date_key'] == 'fresh:Sales:dates',
        "the MAX column is the TMSL sourceColumn, in its own fresh:<table>:dates query (#{fq['Sales']['date_sql']})")
  check(fq['Sales']['sql'] !~ /MAX\(/, 'the count query carries no MAX')
  check(fq['Sales']['date_cols'] == { 'OrderDateKey' => 'D0' }, 'date_cols maps the Power BI column to its alias')
  check(fq['Store']['date_sql'].nil? && fq['Store']['key'] == 'fresh:Store', 'a table without date columns has COUNT only and a fresh:<table> key')
  wrapped = PbiShapeRun.freshness_queries({ 'document' => fresh_doc }, fresh_tmsl, snapshot, 'snowflake')
  check(wrapped == fq, 'a {document: ...} wrapped spec gives the same queries')
  bq = PbiShapeRun.freshness_queries(fresh_doc, fresh_tmsl, snapshot, 'bigquery')
  check(bq['Sales']['date_sql'].include?("MAX(`#{order_col['sourceColumn']}`)"), 'dialect quoting (bigquery backticks)')
  sql_doc = { 'pages' => [{ 'elements' => [{ 'id' => 'e1', 'name' => 'Sales', 'source' => { 'kind' => 'sql', 'statement' => "SELECT 1 AS X;\n" } }] }] }
  sq = PbiShapeRun.freshness_queries(sql_doc, fresh_tmsl, { 'Sales' => { 'rows' => 1, 'maxDates' => {} } }, 'snowflake')
  check(sq['Sales']['sql'].include?("FROM (\nSELECT 1 AS X\n) AS t"), "m1: Custom SQL root is wrapped on its own lines: #{sq['Sales']['sql']}")
  cm_doc = { 'pages' => [{ 'elements' => [{ 'id' => 'e1', 'name' => 'Sales', 'source' => { 'kind' => 'sql', 'statement' => "SELECT 1 AS X -- trailing comment\n" } }] }] }
  cq = PbiShapeRun.freshness_queries(cm_doc, fresh_tmsl, { 'Sales' => { 'rows' => 1, 'maxDates' => {} } }, 'snowflake')
  check(cq['Sales']['sql'].include?("-- trailing comment\n) AS t"), "m1: a trailing -- comment cannot swallow the closing parenthesis: #{cq['Sales']['sql']}")
  missing = PbiShapeRun.freshness_queries(sql_doc, fresh_tmsl, { 'Nope' => { 'rows' => 1, 'maxDates' => {} } }, 'snowflake')
  check(missing['Nope']['skip'].to_s.include?('no data model element'), 'a table with no data model element is skipped with a reason')

  # Snowflake-cased root: UPPER physical columns, mixed-case sourceColumn in the TMSL
  up_doc = { 'pages' => [{ 'elements' => [{ 'id' => 'e1', 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SC FACT] },
                                            'columns' => [{ 'id' => 'inode-e1/ORDER_DATE', 'name' => 'Order Date', 'formula' => '[FACT/Order Date]' }] }] }] }
  up_tmsl = { 'model' => { 'tables' => [{ 'name' => 'Sales', 'columns' => [{ 'name' => 'Order Date', 'sourceColumn' => 'Order_Date' }, { 'name' => 'Ship', 'sourceColumn' => 'Ship' }, { 'name' => 'Bare' }] }] } }
  up_snap = { 'Sales' => { 'rows' => 5, 'maxDates' => { 'Order Date' => '2024-01-01', 'Bare' => '2024-01-01', 'Ship' => '2024-01-01', 'Ghost' => '2024-01-01' } } }
  uq = PbiShapeRun.freshness_queries(up_doc, up_tmsl, up_snap, 'snowflake')['Sales']
  check(uq['date_sql'] == 'SELECT MAX("ORDER_DATE") AS "D0" FROM "DB"."SC"."FACT"', "the MAX uses the warehouse (UPPER) column name (#{uq['date_sql']})")
  check(uq['notes'].grep(/date compare skipped for Bare: no sourceColumn/).any? && uq['notes'].grep(/skipped for Ship: no physical column Ship/).any? &&
        uq['notes'].grep(/skipped for Ghost: no matching model column/).any?, "skipped date columns are noted (#{uq['notes'].inspect})")
  bad_dates = lambda do |_s, qs|
    qs.keys.each_with_object({}) { |k, h| h[k] = k.end_with?(':dates') ? { 'ok' => false, 'error' => 'invalid identifier' } : { 'ok' => true, 'rows' => [{ 'N' => 5 }] } }
  end
  uc = PbiShapeRun.freshness_counts(bad_dates, 'Sales' => uq)['Sales']
  check(uc['rows'] == 5 && uc['notes'].grep(/dates query failed \(invalid identifier\)/).any?, 'a failing dates query still leaves the count, with a note')
  check(PbiShapeRun.classify_freshness('Sales', up_snap['Sales'], uc['rows'], uc['maxDates'], stale_days: 0, creds_suspect: false, failures: [])[0] == 'MATCH',
        'and the table is still classified')

  # a fake probe: Sales has more rows and a newer max date (stale snapshot), Store matches, Product has fewer, Customer errors
  fake = lambda do |_stage, queries|
    queries.keys.each_with_object({}) do |k, h|
      h[k] = case k
             when 'fresh:Sales' then { 'ok' => true, 'rows' => [{ 'N' => 130 }] }
             when 'fresh:Sales:dates' then { 'ok' => true, 'rows' => [{ 'D0' => '2024-03-09' }] }
             when 'fresh:Product' then { 'ok' => true, 'rows' => [{ 'N' => 60 }] }
             when 'fresh:Customer' then { 'ok' => false, 'error' => 'boom: no such table' }
             else { 'ok' => true, 'rows' => [{ 'N' => 100 }] }
             end
    end
  end
  counts = PbiShapeRun.freshness_counts(fake, fq)
  check(counts['Sales'].reject { |k, _| k == 'notes' } == { 'rows' => 130, 'maxDates' => { 'OrderDateKey' => '2024-03-09' } }, "counts carry rows and the max date under the Power BI column (#{counts['Sales'].inspect})")
  check(counts['Vendor']['skip'].to_s.include?('no data model element'), 'a table with no element stays SKIPPED through the counts')
  check(counts['Customer']['skip'].to_s.include?('boom: no such table'), 'a probe error is SKIPPED with the error text, not a zero')
  cls = lambda do |t|
    c = counts[t]
    next ['SKIPPED', t, c['skip']] if c['skip']
    PbiShapeRun.classify_freshness(t, snapshot[t], c['rows'], c['maxDates'], stale_days: 3, creds_suspect: false, failures: [])
  end
  check(cls.call('Store')[0] == 'MATCH', 'equal rows: MATCH')
  check(cls.call('Sales')[0] == 'STALE-EXPLAINED', 'more warehouse rows and a newer date: STALE-EXPLAINED')
  check(cls.call('Product')[0] == 'DIVERGENT', 'fewer warehouse rows: DIVERGENT')
  check(cls.call('Customer')[0] == 'SKIPPED', 'the probe error row is SKIPPED')
  none = PbiShapeRun.freshness_counts(->(_s, qs) { qs.keys.each_with_object({}) { |k, h| h[k] = nil } }, fq)
  check(none['Store']['skip'].to_s.include?('no result'), 'a missing probe result is SKIPPED, not zero')

  puts "\ntest_freshness_classifier_message_strings"
  fc = PbiShapeRun.method(:classify_freshness)
  check(fc.call('T', { 'rows' => 5 }, 5, {}, stale_days: nil, creds_suspect: false, failures: []) == ['MATCH', 'T', 'rows=5 (warehouse == PBI snapshot)'],
        'MATCH message')
  check(fc.call('T', { 'rows' => 5 }, 8, { 'D' => '2024-02-02' }.merge({}), stale_days: 2, creds_suspect: false, failures: []).then { |r| r[0] } == 'STALE-EXPLAINED',
        'STALE-EXPLAINED class')
  r = fc.call('T', { 'rows' => 5, 'maxDates' => { 'D' => '2024-01-01' } }, 8, { 'D' => '2024-02-02' }, stale_days: 2, creds_suspect: false, failures: [])
  check(r[2] == 'Sigma will show more data: warehouse rows=8 vs PBI snapshot=5 (+3); max(D) warehouse=2024-02-02 vs PBI=2024-01-01 — stale/failed-refresh snapshot explains it',
        "STALE-EXPLAINED message with a date note (#{r[2]})")
  r = fc.call('T', { 'rows' => 5 }, 5, {}, stale_days: 0, creds_suspect: false, failures: [])
  check(r[0] == 'MATCH', 'MATCH with no dates')
  r = fc.call('T', { 'rows' => 5, 'maxDates' => { 'D' => '2024-01-01' } }, 5, { 'D' => '2024-01-05' }, stale_days: 0, creds_suspect: false, failures: [])
  check(r[0] == 'STALE-EXPLAINED' && r[2] == 'Sigma will show more data: warehouse rows=5 vs PBI snapshot=5; max(D) warehouse=2024-01-05 vs PBI=2024-01-01 — warehouse moved since the refresh',
        "same rows, newer date, not stale: 'warehouse moved since the refresh' (#{r[2]})")
  r = fc.call('T', { 'rows' => 5 }, 9, {}, stale_days: 0, creds_suspect: true, failures: [])
  check(r[2].end_with?('stale/failed-refresh snapshot explains it'), 'credsSuspect counts as stale')
  r = fc.call('T', { 'rows' => 5 }, 2, {}, stale_days: 9, creds_suspect: false, failures: [])
  check(r == ['DIVERGENT', 'T', 'warehouse rows=2 < PBI snapshot=5 — Sigma shows LESS data than the source snapshot; check the table/path mapping'],
        'DIVERGENT message')

  puts "\ntest_materialization_inputs_pbi_reads_the_posted_spec"
  mdm = { 'pages' => [{ 'elements' => [{ 'id' => 'a', 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table' } }] }] }
  mspec = { 'pages' => [{ 'elements' => [{ 'id' => 'a', 'name' => 'Sales', 'source' => { 'kind' => 'warehouse-table' } },
                                         { 'id' => 'p1', 'name' => 'Shipping \u2013 summary', 'source' => { 'kind' => 'sql', 'statement' => 'select 1 from t' } }] }] }
  els, targets = PbiShapeRun.materialization_inputs('pbi', mdm, mspec, {})
  check(els.map { |e| e['name'] }.include?('Shipping \u2013 summary'), 'pbi: a page summary present only in the posted spec is a spec element')
  check(targets == ['Shipping \u2013 summary'], "pbi: the page summary is selected as a target (#{targets.inspect})")
  els, targets = PbiShapeRun.materialization_inputs('views', mdm, mspec, {})
  check(els.map { |e| e['name'] } == ['Sales'] && targets.nil?, 'views: elements come from dm_model, no pbi targets')

  puts "\ntest_views_mode_unchanged"
  out, st, wd = run.call('views-sales', 'sales', File.join(FIX, 'sales', 'signals.json'))
  check(st.exitstatus.zero?, "default shape runs (exit #{st.exitstatus})")
  golden = File.read(File.join(FIX, 'sales', 'golden-views-dm-spec.json'))
  check(File.exist?(File.join(wd, 'dm-spec.json')) && File.read(File.join(wd, 'dm-spec.json')) == golden,
        'dm-spec.json is byte-identical to the golden captured from origin/main')
  check(%w[pbi-shaped-model measure-classes relationship-keys slicer-carry].none? { |n| File.exist?(File.join(wd, "#{n}.json")) }, 'no pbi-mode documents in views mode')
  check(writes.call.empty?, 'zero writes reached Sigma')
end

# live_probe runs sigma-sql-probe.py once per stage; each run must delete the scratch workbook it created
# (--cleanup) and must never reuse a file cache (--cache), so every rerun probes the live warehouse.
puts "\ntest_live_probe_argv_cleans_up_and_never_caches"
captured = []
orig_capture3 = Open3.method(:capture3)
Open3.define_singleton_method(:capture3) do |*cmd|
  captured << cmd
  ['', '', Struct.new(:exitstatus).new(0)]
end
begin
  Dir.mktmpdir('live-probe') do |wdir|
    probe = PbiShapeRun.live_probe(['python3'], '/x/sigma-sql-probe.py', connection: 'conn-1', folder: 'fold-1',
                                                                          dialect: 'snowflake', work: wdir)
    probe.call('key', { 'k1' => 'select 1' })
  end
ensure
  Open3.define_singleton_method(:capture3, orig_capture3)
end
argv = captured.first || []
check(argv.include?('--cleanup'), "live_probe argv includes --cleanup (#{argv.join(' ')})")
check(!argv.include?('--cache'), "live_probe argv omits --cache (#{argv.join(' ')})")

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "FAILURES (#{FAILS.size}):"
  FAILS.each { |f| puts "  - #{f}" }
  exit 1
end
