#!/usr/bin/env ruby
# Regression test for the #417 null-option workaround (DROPPED_BY_API family).
#
# Sigma's `showNullOption:false` on a list control is accepted by
# POST/PUT /v2/workbooks/spec (200) and SILENTLY DROPPED on readback — the live
# control keeps showing "Null" as a selectable value. So the builder must NEVER
# emit it. When the Tableau quick filter explicitly EXCLUDES Null (an
# except-wrapped groupfilter with a `%null%` member), the field-validated
# workaround applies instead: filter nulls at the control's OPTION-SOURCE — a
# hidden helper element sourcing the master with an IsNotNull(<col>) filter,
# and the control's value list pointed at the helper.
#
# Chain under test:
#   parse-twb-layout  → flags the filter excludes_null:true (the %null% member
#                       used to be dropped silently by unquote_member)
#   build-charts      → emits the "<cap> Options" helper (IsNotNull filter) in
#                       data_elements, re-points the control's `source` at it,
#                       and NEVER emits showNullOption
#   a null-free exclude filter stays byte-identical (source = master).
#
# Deterministic + offline + creds-free: synthetic .twb through the ACTUAL
# parser + builder. Neutral fixture names only (Region A/B, TOTALREV).
#
# Usage:  ruby scripts/test-null-option-source-filter.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Team' name='[TEAM]' datatype='string' role='dimension' />
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
      <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
        <groupfilter function='except'>
          <groupfilter function='level-members' level='[none:REGION:nk]' />
          <groupfilter function='union'>
            <groupfilter function='member' level='[none:REGION:nk]' member='%null%' />
            <groupfilter function='member' level='[none:REGION:nk]' member='&quot;Region B&quot;' />
          </groupfilter>
        </groupfilter>
      </filter>
      <filter class='categorical' column='[federated.x].[none:TEAM:nk]'>
        <groupfilter function='except'>
          <groupfilter function='level-members' level='[none:TEAM:nk]' />
          <groupfilter function='union'>
            <groupfilter function='member' level='[none:TEAM:nk]' member='&quot;Team B&quot;' />
          </groupfilter>
        </groupfilter>
      </filter>
    </shared-view>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Region$'        => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Team$'          => { 'id' => 'm-team',   'name' => 'Team' },
  '(?i)^Total Revenue$' => { 'id' => 'm-rev',    'name' => 'Total Revenue' }
}

meta = nil
build_out = nil
data = []
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Rev Sheet' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '') # empty → build from .twb signals
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  meta = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                        '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                        '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                        '--auto-controls', '--title', 'Dash', '--out', out],
                       err: %i[child out], &:read)
  build_log = build_log.to_s.force_encoding('UTF-8')
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
  # Hidden data elements: inline under 'data_elements' (pages modes) or the
  # -data-elements.json sidecar (default flat mode).
  side = out.sub(/\.json$/, '-data-elements.json')
  data = JSON.parse(File.read(side)) if File.exist?(side)
end

# ---- Parser: %null% member in an except tree flags excludes_null -------------
sf_region = (meta['shared_filters'] || []).find { |f| f['column_caption'] == 'Region' }
check(sf_region && sf_region['excludes_null'] == true,
      "parser flags the %null%-excluding filter excludes_null:true (got #{sf_region.inspect})", fails)
check(sf_region && sf_region['members'] == ['Region B'],
      "the %null% sentinel never leaks into members (got #{sf_region && sf_region['members'].inspect})", fails)
sf_team = (meta['shared_filters'] || []).find { |f| f['column_caption'] == 'Team' }
check(sf_team && !sf_team.key?('excludes_null'),
      'a null-free exclude filter carries NO excludes_null key', fails)

els =
  if build_out.is_a?(Array)
    build_out
  elsif build_out.is_a?(Hash)
    (build_out['pages'] || []).flat_map { |p| p['elements'] || [] }
  else
    []
  end
data = build_out['data_elements'] if build_out.is_a?(Hash) && build_out['data_elements']

# ---- Builder: option-source helper with the IsNotNull filter -----------------
helper = data.find { |e| e['name'] == 'Region Options' }
check(!helper.nil?, "hidden 'Region Options' helper emitted in data_elements (got #{data.map { |e| e['name'] }.inspect})", fails)
if helper
  check(helper.dig('source', 'elementId') == 'master', 'helper sources the master', fails)
  nn = (helper['columns'] || []).find { |c| c['formula'].to_s.start_with?('Text(IsNotNull(') }
  check(!nn.nil?, "helper carries a Text(IsNotNull) column (got #{helper['columns'].inspect})", fails)
  hf = (helper['filters'] || []).first
  # S11/K20: string "true" against a Text()-cast column — JSON boolean values
  # against a boolean column render "Invalid filter" and blank the tile.
  check(nn && hf && hf['columnId'] == nn['id'] && hf['values'] == ['true'],
        "helper filters Text(IsNotNull) == 'true' (got #{hf.inspect})", fails)
  # Field report: Sigma's spec verify endpoint 400s element filters without an
  # `id` (`filters[N].id: Invalid string: undefined`) — the helper's filter must
  # carry a deterministic one.
  check(hf && hf['id'].to_s =~ /\Aflt-#{Regexp.escape(helper['id'].to_s)}-\d+\z/,
        "helper filter carries a deterministic id (got #{hf && hf['id'].inspect})", fails)
  check(helper['visibleAsSource'] == false, 'helper is hidden (visibleAsSource:false)', fails)
end

# ---- Builder: the control's value list points at the helper ------------------
ctl = els.find { |e| e['kind'] == 'control' && e['name'] == 'Region' }
check(!ctl.nil?, 'Region control emitted', fails)
if ctl && helper
  check(ctl.dig('source', 'source', 'elementId') == helper['id'],
        "control option-source re-pointed at the helper (got #{ctl['source'].inspect})", fails)
  check(ctl['mode'] == 'exclude' && ctl['values'] == ['Region B'],
        'data-side exclude semantics untouched (mode:exclude, seeded members)', fails)
end

# ---- The silently-dropped field is NEVER emitted -----------------------------
check(!JSON.generate(els + data).include?('showNullOption'),
      'showNullOption never appears anywhere in the built spec', fails)

# ---- Null-free control keeps the plain master option-source ------------------
team_ctl = els.find { |e| e['kind'] == 'control' && e['name'] == 'Team' }
check(team_ctl && team_ctl.dig('source', 'source', 'elementId') == 'master',
      "null-free exclude control keeps the master option-source (got #{team_ctl && team_ctl['source'].inspect})", fails)
check(data.none? { |e| e['name'] == 'Team Options' },
      'no helper emitted for the null-free filter', fails)

# ---- Loud announcement -------------------------------------------------------
check(build_log =~ /showNullOption.*silently dropped|option list sources hidden helper/i,
      'builder loudly announces the option-source workaround', fails)

puts
if fails.empty?
  puts 'ALL PASS — null-excluding Tableau filters get the option-source IsNotNull workaround (#417); showNullOption never emitted'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(30).join
  exit 1
end
