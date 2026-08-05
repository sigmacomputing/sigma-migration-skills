#!/usr/bin/env ruby
# PR-18 regression test — integer-coded dimension detection + decode-to-text routing.
#
# THE FAILURE CLASS (field: a multi-page session + Twin C): an INTEGER warehouse column
# (STORE_KEY) used as a DISCRETE dimension on a Tableau quick filter. A Sigma
# list/dropdown control sources STRING option values, so a filter target on the
# raw integer column is accepted then SILENTLY stripped (reads back filters:null
# — control-parity.md "list-control targets on NUMERIC columns are silently
# stripped"). The dashboard ships a control that filters nothing.
#
# THE FIX (proven by hand in Twin C, gen-wb-spec.rb; now automatic): a
# `Text([<col>])` decode helper column on the element the control targets, with
# BOTH the control's filter target AND its value-source bound to the decoded
# column.
#
# Chain under test (all offline, creds-free, neutral fixture names):
#   parse-twb-layout → flags the integer categorical filter integer_dim:true
#   build-charts     → routes the list control's filter target + value-source
#                      through a Text() decode column; a master-rooted decode
#                      rides `master_decode_columns` for the orchestrator to add
#                      to the master; stamps control-scope integer_dim/decode.
#   a STRING dim control stays UNCHANGED (no decode, target = raw master column).
#
# Usage:  ruby scripts/test-integer-dim-decode.rb
require 'json'
require 'tmpdir'
require_relative 'lib/integer_dim'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- 0. Pure-lib unit checks -------------------------------------------------
check(IntegerDim.integer_dim_filter?('datatype' => 'integer', 'kind' => 'list'),
      'lib: integer + list filter → integer_dim', fails)
check(IntegerDim.integer_dim_filter?('datatype' => 'integer', 'kind' => 'number-range', 'role' => 'dimension'),
      'lib: integer + role=dimension → integer_dim (even a range shape)', fails)
check(!IntegerDim.integer_dim_filter?('datatype' => 'integer', 'kind' => 'number-range'),
      'lib: integer + quantitative range (no discrete role) → NOT integer_dim', fails)
check(!IntegerDim.integer_dim_filter?('datatype' => 'string', 'kind' => 'list'),
      'lib: string list filter → NOT integer_dim', fails)
check(!IntegerDim.integer_dim_filter?('datatype' => 'real', 'kind' => 'list'),
      'lib: real (continuous measure) list filter → NOT integer_dim', fails)
check(IntegerDim.decode_formula_for('[Store Key]') == 'Text([Store Key])',
      'lib: decode formula is Text([ref])', fails)
check(IntegerDim.decode_formula?('Text([Master/Store Key])') && !IntegerDim.decode_formula?('[Master/Store Key]'),
      'lib: decode_formula? recognises Text() decode, rejects a raw ref', fails)
check(!IntegerDim.decode_formula?('ToText([X])'), 'lib: ToText() is NOT a decode (not a Sigma fn)', fails)

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Store Key' name='[STORE_KEY]' datatype='integer' role='dimension' />
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Rev Sheet'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:REGION:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Rev Sheet' x='0' y='0' w='100000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
    <shared-view name='sv1'>
      <filter class='categorical' column='[federated.x].[none:STORE_KEY:nk]'>
        <groupfilter function='member' level='[none:STORE_KEY:nk]' member='1001' />
        <groupfilter function='member' level='[none:STORE_KEY:nk]' member='1002' />
      </filter>
      <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
        <groupfilter function='member' level='[none:REGION:nk]' member='&quot;East&quot;' />
      </filter>
    </shared-view>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Store Key$'     => { 'id' => 'm-store-key', 'name' => 'Store Key' },
  '(?i)^Region$'        => { 'id' => 'm-region',    'name' => 'Region' },
  '(?i)^Total Revenue$' => { 'id' => 'm-rev',       'name' => 'Total Revenue' }
}.freeze

meta = nil
build_out = nil
build_log = ''
scope = nil
int_sidecar = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Rev Sheet' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  meta = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm, '--master-element-id', 'master', '--page-per-dashboard', '--skip-dashboard-read', 'unit-test', '--auto-controls', '--title', 'Dash', '--out', out], err: %i[child out], &:read).to_s.force_encoding('UTF-8')
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
  sp = File.join(d, 'control-scope.json')
  scope = JSON.parse(File.read(sp)) if File.exist?(sp)
  idp = File.join(d, 'integer-dim-decode.json')
  int_sidecar = JSON.parse(File.read(idp)) if File.exist?(idp)
end

# ---- 1. Parser: integer categorical filter flagged; string filter is NOT -----
sf = meta['shared_filters'] || []
skf = sf.find { |f| f['column_caption'] == 'Store Key' }
check(skf && skf['datatype'] == 'integer' && skf['integer_dim'] == true,
      "parser flags the integer categorical filter integer_dim:true (got #{skf && skf.slice('datatype', 'kind', 'integer_dim').inspect})", fails)
rgf = sf.find { |f| f['column_caption'] == 'Region' }
check(rgf && !rgf.key?('integer_dim'),
      'parser leaves a STRING categorical filter with NO integer_dim key (byte-identical)', fails)

els = build_out.is_a?(Hash) ? (build_out['pages'] || []).flat_map { |p| p['elements'] || [] } : Array(build_out)
mdc = build_out.is_a?(Hash) ? Array(build_out['master_decode_columns']) : []

# ---- 2. Builder: master-rooted decode column emitted -------------------------
dec = mdc.find { |c| c['formula'].to_s =~ /\AText\(\[Store Key\]\)\z/ }
check(!dec.nil?,
      "master_decode_columns carries Text([Store Key]) (got #{mdc.map { |c| c['formula'] }.inspect})", fails)
check(dec && dec['name'] == 'Store Key (Text)', 'decode column named "<col> (Text)" (Twin C naming)', fails)

# ---- 3. Builder: the list control binds filter target + value-source to it ----
sk_ctl = els.find { |e| e['kind'] == 'control' && e['name'] == 'Store Key' }
check(!sk_ctl.nil?, 'Store Key control emitted', fails)
if sk_ctl && dec
  check(sk_ctl['controlType'] == 'list', 'Store Key control is a list', fails)
  tgt = Array(sk_ctl['filters']).first
  check(tgt && tgt['columnId'] == dec['id'],
        "control FILTER target repointed at the decode column (got #{tgt && tgt['columnId']} want #{dec['id']})", fails)
  check(tgt && tgt.dig('source', 'elementId') == 'master', 'filter target still sources the master', fails)
  check(sk_ctl.dig('source', 'columnId') == dec['id'],
        "control VALUE-SOURCE repointed at the decode column (got #{sk_ctl.dig('source', 'columnId')})", fails)
  # The raw integer column id must NOT appear as the control's target/source.
  check(tgt && tgt['columnId'] != 'm-store-key' && sk_ctl.dig('source', 'columnId') != 'm-store-key',
        'the control NEVER binds the raw integer column (which Sigma would silently strip)', fails)
end

# ---- 4. Negative: the STRING control is UNCHANGED (no decode) -----------------
rg_ctl = els.find { |e| e['kind'] == 'control' && e['name'] == 'Region' }
check(!rg_ctl.nil?, 'Region control emitted', fails)
if rg_ctl
  tgt = Array(rg_ctl['filters']).first
  check(tgt && tgt['columnId'] == 'm-region',
        "STRING control still targets the raw master column (got #{tgt && tgt['columnId']})", fails)
  check(rg_ctl.dig('source', 'columnId') == 'm-region', 'STRING control value-source unchanged', fails)
  check(mdc.none? { |c| c['name'] == 'Region (Text)' }, 'no decode column emitted for the STRING dim', fails)
end

# ---- 5. control-scope + sidecar stamp integer_dim/decode ---------------------
csk = scope && Array(scope['controls']).find { |c| c['name'] == 'Store Key' }
check(csk && csk['integer_dim'] == true && csk.dig('decode', 'status') == 'auto-decoded',
      "control-scope stamps integer_dim + decode.status=auto-decoded (got #{csk && csk.slice('integer_dim', 'decode').inspect})", fails)
csr = scope && Array(scope['controls']).find { |c| c['name'] == 'Region' }
check(csr && !csr.key?('integer_dim'), 'control-scope leaves the STRING control unstamped', fails)
check(int_sidecar && Array(int_sidecar['candidates']).any? { |c| c['name'] == 'Store Key' },
      'integer-dim-decode.json sidecar lists the Store Key candidate (for the cardinality probe)', fails)

# ---- 6. Loud announcement ----------------------------------------------------
check(build_log =~ /INTEGER column used as a discrete dimension|auto-decoded via Text\(\)/i,
      'builder loudly announces the integer-dim decode routing', fails)

# ---- 7. Dashboard filter-ZONE promotion (no <shared-view>) --------------------
# The live "a live executive dashboard" shape: the integer quick filter is a
# dashboard filter ZONE, not a <shared-view>. Without promotion the control is
# SILENTLY DROPPED (Twin C hand-authored it). PR-18 promotes ONLY the integer-dim
# zone filter (a STRING zone filter stays unemitted — byte-identical).
ZONE_TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Store Key' name='[STORE_KEY]' datatype='integer' role='dimension' />
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Rev Sheet'>
        <table>
          <view><datasource-dependencies datasource='federated.x' /></view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:REGION:nk]</cols>
          <pane><mark class='Bar' /></pane>
          <filter class='categorical' column='[federated.x].[none:STORE_KEY:nk]'>
            <groupfilter function='member' level='[none:STORE_KEY:nk]' member='1001' />
          </filter>
          <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
            <groupfilter function='member' level='[none:REGION:nk]' member='&quot;East&quot;' />
          </filter>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Rev Sheet' x='0' y='0' w='100000' h='60000' />
          <zone id='2' type-v2='filter' param='[federated.x].[none:STORE_KEY:nk]' mode='checkdropdown' x='0' y='60000' w='100000' h='20000' />
          <zone id='3' type-v2='filter' param='[federated.x].[none:REGION:nk]' mode='checkdropdown' x='0' y='80000' w='100000' h='20000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

zbuild = nil
zscope = nil
zlog = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb'); lay = File.join(d, 'layout.json'); mm = File.join(d, 'mm.json')
  File.write(twb, ZONE_TWB); File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'), JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Rev Sheet' }] }))
  Dir.mkdir(File.join(d, 'views')); File.write(File.join(d, 'views', 'v1.csv'), '')
  abort 'parse failed (zone)' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  zmeta = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
  check((zmeta['shared_filters'] || []).empty?, 'zone case: NO shared-view filters (the promotion path)', fails)
  out = File.join(d, 'specs.json')
  zlog = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm, '--master-element-id', 'master', '--page-per-dashboard', '--skip-dashboard-read', 'unit-test', '--auto-controls', '--title', 'Dash', '--out', out], err: %i[child out], &:read).to_s.force_encoding('UTF-8')
  zbuild = JSON.parse(File.read(out)) if File.exist?(out)
  sp = File.join(d, 'control-scope.json'); zscope = JSON.parse(File.read(sp)) if File.exist?(sp)
end

zels = zbuild.is_a?(Hash) ? (zbuild['pages'] || []).flat_map { |p| p['elements'] || [] } : []
zmdc = zbuild.is_a?(Hash) ? Array(zbuild['master_decode_columns']) : []
zsk = zels.find { |e| e['kind'] == 'control' && e['name'] == 'Store Key' }
zdec = zmdc.find { |c| c['formula'].to_s =~ /\AText\(\[Store Key\]\)\z/ }
check(zlog =~ /promoting it to an auto-control/i, 'zone case: builder announces the integer-dim zone promotion', fails)
check(!zsk.nil? && !zdec.nil?, 'zone case: integer-dim ZONE filter → control auto-emitted + decode column present', fails)
if zsk && zdec
  check(Array(zsk['filters']).first&.dig('columnId') == zdec['id'] && zsk.dig('source', 'columnId') == zdec['id'],
        'zone case: promoted control binds filter target + value-source to the Text() decode', fails)
end
check(zels.none? { |e| e['kind'] == 'control' && e['name'] == 'Region' },
      'zone case: a STRING zone filter is NOT promoted (byte-identical for non-integer dims)', fails)

puts
if fails.empty?
  puts 'ALL PASS — integer-coded dimension list controls auto-decode via Text(); string dims unchanged'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(40).join
  exit 1
end
