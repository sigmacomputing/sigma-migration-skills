#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-scope.rb — E9.6 scope threading: a mission.json STATED scope
# constrains the layout parse, the open-questions surface, and build planning
# end-to-end — a scoped mission never fans out to all dashboards, and a scoped
# name matching nothing is a NAMED stop (exit 19), never a silent
# full-workbook (or silent empty) run. Fixture: a multi-dashboard corpus .twb
# (Alpha Overview + Beta Detail) driven through the REAL orchestrator offline.
#
#   T1 scoped:   mission names one dashboard → ONLY its zones surface
#   T2 mismatch: mission names a ghost      → exit 19 listing the dashboards
#   T3 unscoped: no mission.json            → both dashboards (unchanged)
#   T4 override: explicit --dashboard wins; narrowing is ledgered
#   T5 URL:      single-view /#/views/ URL scope resolves to the dashboard
#   T6 inferred: non-stated provenance is WARNed and NOT applied
# Usage: ruby scripts/test-wave1-scope.rb   (~15s, spawns real runs)

require 'json'
require 'tmpdir'
require_relative 'test-wave1-support'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def write_mission(dir, scope)
  File.write(File.join(dir, 'mission.json'), JSON.pretty_generate(
               'source' => { 'value' => 'Wave1 Fixture', 'provenance' => 'stated' },
               'scope' => scope))
end

def question_views(dir)
  oq = JSON.parse(File.read(File.join(dir, 'open-questions.json')))
  oq['open_questions'].select { |q| q['id'] == 'empty_view_csv' }.map { |q| q['viz'] }
end

def layout_dashboards(dir)
  doc = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  (doc.is_a?(Array) ? doc : [doc]).map { |d| d['dashboard'] }.compact
end

puts 'T1 — stated single-dashboard scope surfaces ONLY the target\'s zones'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d) # both views' CSVs are empty → one question per IN-SCOPE zone
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Beta Detail'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(out.include?('mission scope (stated): Beta Detail'), 'mission scope applied loudly', fails)
  check(layout_dashboards(d) == ['Beta Detail'],
        "layout parse scoped to the target (got #{layout_dashboards(d).inspect})", fails)
  qs = question_views(d)
  check(qs == ['Beta Trend'],
        "open-questions surface ONLY the target dashboard's zones (got #{qs.inspect})", fails)
  check(out.include?('outside the stated dashboard scope not surfaced'),
        'out-of-scope empty CSVs are dropped LOUDLY, not silently', fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  check(offr.any? { |r| r['kind'] == 'mission-scope' }, 'mission-scope application offramp-recorded', fails)
end

puts 'T2 — scoped name absent from the workbook → NAMED stop, exit 19'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Nonexistent Dash'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 19, "distinct exit 19 (got #{st.exitstatus})", fails)
  check(out.include?('SCOPE STOP (dashboard not found — exit 19)'), 'named stop banner', fails)
  check(out.include?('"Nonexistent Dash"'), 'the unmatched name is named', fails)
  check(out.include?('"Alpha Overview"') && out.include?('"Beta Detail"'),
        'the workbook\'s dashboards are listed for the fix', fails)
  check(out.include?('No Sigma objects were created.'), 'stop happens before any Sigma write', fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  check(offr.any? { |r| r['kind'] == 'scope-mismatch-stop' }, 'scope-mismatch-stop offramp recorded', fails)
end

puts 'T3 — unscoped mission: output unchanged (both dashboards fan out)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(layout_dashboards(d).sort == ['Alpha Overview', 'Beta Detail'],
        'unscoped parse keeps every dashboard', fails)
  check(question_views(d).sort == ['Alpha Sales', 'Beta Trend'],
        'unscoped questions cover every dashboard\'s zones', fails)
  check(!out.include?('mission scope'), 'no scope lines without a mission scope', fails)
end

puts 'T4 — explicit flags override; narrowing below the mission is ledgered'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Alpha Overview', 'Beta Detail'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--dashboard', 'Beta Detail'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(layout_dashboards(d) == ['Beta Detail'], 'explicit --dashboard wins over mission.json', fails)
  check(out.include?('narrow the mission') || out.include?('scope-narrowed'),
        'narrowing is loud', fails)
  decs = File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) }
  check(decs.any? { |r| r['kind'] == 'scope-narrowed' && r['answer'].to_s.include?('Beta Detail') },
        'scope-narrowed decision ledgered (red-team scope-cut amendment)', fails)
end

puts 'T5 — single-view /#/views/ URL scope resolves via the views list'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['https://tab.example.com/#/site/acme/views/Wave1Fixture/BetaDetail?:iid=2'],
                   'provenance' => 'stated')
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(out.include?('mission scope: single-view URL → dashboard "Beta Detail"'),
        'URL view segment resolved to the dashboard NAME', fails)
  check(layout_dashboards(d) == ['Beta Detail'], 'URL scope threads into the parse', fails)
  check(question_views(d) == ['Beta Trend'], 'URL scope constrains the question surface', fails)
end

puts 'T6 — inferred provenance is never silently acted on'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'inferred',
                   'dashboards' => ['Beta Detail'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(out =~ /provenance "inferred".*NOT applied/m, 'inferred scope WARNed and ignored', fails)
  check(layout_dashboards(d).sort == ['Alpha Overview', 'Beta Detail'],
        'run stays unscoped on inferred provenance', fails)
end

puts 'T7 — A2: ❌ gap attributed ONLY to out-of-scope worksheets does NOT stop a scoped run'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, gaps: [{ 'name' => 'R scripts', 'count' => 1, 'status' => 'unhandled',
                                 'blurb' => 'SCRIPT_REAL has no Sigma equivalent',
                                 'worksheets' => ['Beta Trend'] }]) # Beta Detail only
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Alpha Overview'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10,
        "no gap stop — plain decisions checkpoint, exit 10 not 11 (got #{st.exitstatus})", fails)
  check(out.include?('not stopped for'), 'the drop is LOUD, never silent', fails)
  check(out.include?('workbook-wide gap report still lists them'),
        'the drop line points back at the full report (scan stays workbook-wide)', fails)
  oq = JSON.parse(File.read(File.join(d, 'open-questions.json')))
  check(oq['status'] == 'decisions_needed' && (oq['gap_review'] || []).empty?,
        'no gap_review folded in (the ❌ gap is out of scope)', fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  gos = offr.find { |r| r['kind'] == 'gap-out-of-scope' }
  check(gos && gos['detail'].to_s.include?('R scripts') && gos['detail'].to_s.include?('Beta Trend'),
        'dropped gap ledgered as a gap-out-of-scope off-ramp note', fails)
  check(out.include?('gap stops, and build planning run scoped') &&
        out.include?('gap scan itself is workbook-wide'),
        'scope banner claims exactly what ships (A2 overclaim fix)', fails)
end

puts 'T8 — A2 fail-open: an UNATTRIBUTED ❌ gap still stops a scoped run (never silently skipped)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, gaps: [
                       { 'name' => 'Custom shapes', 'count' => 2, 'status' => 'unhandled',
                         'blurb' => 'no worksheet attribution — must fail OPEN' },
                       { 'name' => 'R scripts', 'count' => 1, 'status' => 'unhandled',
                         'blurb' => 'attributed out of scope', 'worksheets' => ['Beta Trend'] }
                     ])
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Alpha Overview'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 11, "unattributed gap fails OPEN → gap stop, exit 11 (got #{st.exitstatus})", fails)
  check(out.include?('GAP REVIEW (unscouted): 1'),
        'exactly ONE gap review item (the unattributed one; the attributed one dropped)', fails)
  oq = JSON.parse(File.read(File.join(d, 'open-questions.json')))
  names = (oq['gap_review'] || []).map { |g| g['name'] }
  check(names == ['Custom shapes'], "gap_review carries only the fail-open item (got #{names.inspect})", fails)
  # A9: the re-entry hint must NOT append --force (answers-only already
  # proceeds through gaps AND records decided_by 'relayed').
  check(out =~ /re-run this exact command adding:  --answers '<json>'   #/,
        'A9: re-entry hint is answers-only (no --force suffix)', fails)
  check(!out.match?(/--answers '<json>' --force/), 'A9: no --force appended to the hint', fails)
  check(out.include?('--force/--yes'), '--force stays documented for the no-answers acceptance path', fails)
end

puts 'T9 — A2: scan-workbook-gaps.rb attributes worksheets (direct + calc hop; structural stays unattributed)'
Dir.mktmpdir do |d|
  twb = File.join(d, 'attr.twb')
  File.write(twb, <<~XML)
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='F' name='federated.fact1'>
          <column caption='R Score' datatype='real' name='[Calculation_777]' role='measure'>
            <calculation class='tableau' formula='SCRIPT_REAL(&quot;library(x)&quot;, SUM([Sales]))' />
          </column>
          <column caption='Sales' datatype='real' name='[Sales]' role='measure' />
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Gamma Script'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.fact1'>
                <column caption='R Score' name='[Calculation_777]' />
              </datasource-dependencies>
            </view>
            <pane><mark class='Bar' /></pane>
          </table>
        </worksheet>
        <worksheet name='Delta Plain'>
          <table><view><pane><mark class='Bar' /></pane></view></table>
        </worksheet>
      </worksheets>
      <dashboards>
        <dashboard name='D1'>
          <device-layouts><device-layout name='Phone' /></device-layouts>
          <zones><zone name='Gamma Script' /></zones>
        </dashboard>
      </dashboards>
    </workbook>
  XML
  out_md = File.join(d, 'attr-gaps-report.md')
  system(RbConfig.ruby, File.join(Wave1Fixture::SCRIPTS, 'scan-workbook-gaps.rb'), twb, out_md,
         out: File::NULL, err: File::NULL)
  doc = JSON.parse(File.read(File.join(d, 'attr-gaps-report.json')))
  feats = doc['detected_features']
  script_row = feats.find { |f| f['name'].to_s.include?('SCRIPT_') }
  phone_row  = feats.find { |f| f['name'].to_s.include?('mobile-specific layout') }
  check(script_row && script_row['status'] == 'unhandled', 'SCRIPT_* gap detected as unhandled', fails)
  check(script_row && script_row['worksheets'] == ['Gamma Script'],
        "calc-hop attribution: SCRIPT_* gap → the referencing worksheet only (got #{script_row && script_row['worksheets'].inspect})", fails)
  check(phone_row && !phone_row.key?('worksheets'),
        'dashboard-structural gap carries NO worksheets key (consumers fail OPEN)', fails)
end

puts
if fails.empty?
  puts 'test-wave1-scope: ALL PASS'
else
  puts "test-wave1-scope: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
