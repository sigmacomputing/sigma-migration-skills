#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for QUANTITATIVE quick-filter emission (issue #422).
#
# An UNRESTRICTED Tableau quantitative quick-filter (`<filter
# class='quantitative'>` with NO min/max attributes → "all values") used to
# migrate to a Sigma number-range ELEMENT filter carrying `{min:null, max:null}`,
# which 400s the whole workbook POST. The defect recurred across workbooks
# because the builder emitted min/max UNCONDITIONALLY (unlike the guarded
# control paths) and the C7 preflight lint didn't hard-block the shape.
#
# The fix (build-charts-from-signals.rb number-range element-filter branch):
#   - both bounds absent (unrestricted "All") → emit NO element filter (a range
#     that filters nothing is a no-op; mirrors the categorical "All" handling)
#     with a loud warning — never the {min:null,max:null} 400 shape.
#   - a bound present → emit only the non-nil key(s), so no null bound ever ships.
# And preflight_lint C7 now HARD-errors any number-range (control OR element
# filter) whose min AND max are both present-and-null.
#
# Deterministic + offline + creds-free: synthetic .twb through the ACTUAL parser
# + builder, then the built spec through preflight_lint. Neutral fixture names.
#
# Usage:  ruby scripts/test-number-range-filter-emission.rb
require 'json'
require 'tmpdir'
require_relative 'lib/preflight_lint'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Two worksheets: one carries an UNRESTRICTED quantitative filter (no min/max),
# one a BOUNDED quantitative filter (min=10, max=90) — both on Total Revenue.
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Unrestricted Sheet'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
            <filter class='quantitative' column='[federated.x].[none:TOTALREV:qk]' />
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:REGION:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
      <worksheet name='Bounded Sheet'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x' />
            <filter class='quantitative' column='[federated.x].[none:TOTALREV:qk]' min='10' max='90' />
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
          <zone id='1' name='Unrestricted Sheet' x='0' y='0' w='50000' h='100000' />
          <zone id='2' name='Bounded Sheet' x='50000' y='0' w='50000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Region$'        => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Total Revenue$' => { 'id' => 'm-rev',    'name' => 'Total Revenue' }
}

meta = nil
build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [
               { 'id' => 'v1', 'name' => 'Unrestricted Sheet' },
               { 'id' => 'v2', 'name' => 'Bounded Sheet' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '') # empty → build from .twb signals
  File.write(File.join(d, 'views', 'v2.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  meta = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm, '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test', '--auto-controls', '--title', 'Dash', '--out', out], err: %i[child out], &:read)
  build_log = build_log.to_s.force_encoding('UTF-8')
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

# ---- Parser: unrestricted quantitative → number-range with nil bounds --------
uf = (meta.dig('worksheets', 'Unrestricted Sheet', 'filters') || []).find { |f| f['kind'] == 'number-range' }
check(uf && uf['min'].nil? && uf['max'].nil?,
      "parser: unrestricted quantitative filter → number-range min:nil/max:nil (got #{uf.inspect})", fails)
bf = (meta.dig('worksheets', 'Bounded Sheet', 'filters') || []).find { |f| f['kind'] == 'number-range' }
check(bf && !bf['min'].nil? && !bf['max'].nil?,
      "parser: bounded quantitative filter → number-range with min+max (got #{bf.inspect})", fails)

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []
check(!els.empty?, 'builder produced elements', fails)

nr_filters = els.flat_map { |e| (e['filters'] || []).select { |f| f['kind'] == 'number-range' } }

# ---- CORE ASSERTION: no number-range element filter ships null bounds --------
bad = nr_filters.select { |f| f['min'].nil? && f['max'].nil? }
check(bad.empty?, "no number-range element filter carries {min:null,max:null} (got #{bad.inspect})", fails)
partial = nr_filters.select { |f| (f.key?('min') && f['min'].nil?) || (f.key?('max') && f['max'].nil?) }
check(partial.empty?, "no number-range element filter carries a present-but-null bound (got #{partial.inspect})", fails)

# ---- REMEDY: the unrestricted filter is DROPPED (no-op), announced loudly -----
unrestricted_el = els.find { |e| e['name'].to_s.casecmp?('Unrestricted Sheet') }
u_nr = unrestricted_el ? (unrestricted_el['filters'] || []).find { |f| f['kind'] == 'number-range' } : nil
check(u_nr.nil?, "unrestricted quantitative filter emits NO number-range element filter (got #{u_nr.inspect})", fails)
check(build_log =~ /UNRESTRICTED/i && build_log =~ /#422/,
      'builder loudly warns the unrestricted filter was dropped (cites #422)', fails)

# ---- The BOUNDED filter still emits a valid number-range with both bounds -----
bounded_el = els.find { |e| e['name'].to_s.casecmp?('Bounded Sheet') }
b_nr = bounded_el ? (bounded_el['filters'] || []).find { |f| f['kind'] == 'number-range' } : nil
check(b_nr && !b_nr['min'].nil? && !b_nr['max'].nil?,
      "bounded quantitative filter → number-range with concrete min+max (got #{b_nr.inspect})", fails)

# ---- The whole built spec passes preflight_lint C7 (would-be POST is clean) ---
spec_for_lint = build_out.is_a?(Hash) && build_out['pages'] ? build_out : { 'pages' => [{ 'elements' => els }] }
c7 = lint(spec_for_lint).select { |e| e.start_with?('C7 ') }
check(c7.empty?, "preflight_lint C7 clean on the built spec (got #{c7.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — unrestricted quantitative filter drops cleanly (no {min:null,max:null}); bounded still emits; C7 clean'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(40).join
  exit 1
end
