#!/usr/bin/env ruby
# test-intake-triage.rb — front-door triage (speed-review #6a): intake.rb
# consumes an assessment migration-plan.json when present.
#
# Guard budget discipline (ratified ≤5% false-stop): the matrix below proves
# BOTH directions — trip tests (a retire-tagged workbook refuses with exit 7;
# the --triage-override / SIGMA_TRIAGE_OVERRIDE arm proceeds AND records the
# offramp — never a silent proceed) and no-false-trip tests (no plan, missing
# --plan file, malformed plan, no --source, unmatched source, ambiguous
# duplicate names, low-rank WARN, blocked WARN, consolidation-member WARN,
# healthy tiers — every one proceeds with exit 0).
#
# Canonical in shared/scripts. Run: ruby scripts/test-intake-triage.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'
require 'open3'

INTAKE = File.join(__dir__, 'intake.rb')
RUBY   = RbConfig.ruby
UUID   = '11111111-2222-3333-4444-555555555555'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# Resolution is via --connection <UUID> (offline); the bootstrap gate is
# waived the same way test-intake.rb does.
def run(dir, *args, env: {})
  base = { 'SIGMA_CONNECTION_ID' => nil, 'SIGMA_TRIAGE_OVERRIDE' => nil,
           'SIGMA_SKIP_BOOTSTRAP_GATE' => 'unit-test' }
  out, err, st = Open3.capture3(base.merge(env), RUBY, INTAKE,
                                '--workdir', dir, '--connection', UUID, *args)
  [st.exitstatus, out, err]
end

def plan_entry(over = {})
  { 'workbookId' => 'wb-legacy-1', 'name' => 'Quarterly Ops Review',
    'recommended_path' => 'tableau-to-sigma', 'priority_tier' => 'migrate-first',
    'score' => 41.5, 'accesses' => 830, 'actors' => 12, 'blockers' => [] }.merge(over)
end

def write_plan(dir, *entries)
  File.write(File.join(dir, 'migration-plan.json'), JSON.generate('workbooks' => entries))
end

def intake_json(dir)
  JSON.parse(File.read(File.join(dir, 'intake.json'))) rescue nil
end

def offramps(dir)
  path = File.join(dir, 'offramps.jsonl')
  return [] unless File.exist?(path)
  File.readlines(path).map { |l| JSON.parse(l) rescue nil }.compact
end

# ── trip tests ──────────────────────────────────────────────────────────────

# 1. retire-tagged (recommended_path) → exit 7, nothing resolved
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'retire', 'priority_tier' => 'retire',
                           'score' => 0.0, 'accesses' => 0, 'actors' => 0,
                           'blockers' => ['no usage (accesses=0)']))
  st, _out, err = run(d, '--source', 'wb-legacy-1')
  ok('retire tag → exit 7', st == 7)
  ok('refusal names the retire evidence', err.include?('RETIRE-tagged') && err.include?('accesses=0'))
  ok('refusal teaches the override arm', err.include?('--triage-override'))
  ok('no connection.json written when refused', !File.exist?(File.join(d, 'connection.json')))
  ok('no intake.json written when refused', !File.exist?(File.join(d, 'intake.json')))
end

# 2. retire via priority_tier alone (tolerant matching) → exit 7
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('priority_tier' => 'retire'))
  st, _out, _err = run(d, '--source', 'wb-legacy-1')
  ok('retire tier alone also refuses', st == 7)
end

# 3. --triage-override → proceeds AND records the offramp (never silent)
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'retire', 'priority_tier' => 'retire', 'accesses' => 0))
  st, _out, err = run(d, '--source', 'wb-legacy-1', '--triage-override', 'ops-lead: exec dashboard, usage tracked elsewhere')
  ok('override → exit 0', st == 0)
  ok('override banner still WARNS', err.include?('converting anyway'))
  rec = offramps(d).find { |r| r['kind'] == 'triage-retire-override' }
  ok('offramp recorded: triage-retire-override', !rec.nil?)
  ok('offramp carries the attributable reason', rec && rec['reason'].to_s.include?('ops-lead'))
  t = intake_json(d) && intake_json(d)['triage']
  ok('intake.json triage verdict retire-overridden', t && t['verdict'] == 'retire-overridden')
end

# 4. SIGMA_TRIAGE_OVERRIDE env twin
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'retire'))
  st, _out, _err = run(d, '--source', 'wb-legacy-1',
                       env: { 'SIGMA_TRIAGE_OVERRIDE' => 'customer: contractual keep' })
  ok('env override also proceeds + records', st == 0 &&
     offramps(d).any? { |r| r['kind'] == 'triage-retire-override' })
end

# ── no-false-trip tests ─────────────────────────────────────────────────────

# 5. no plan anywhere → ONE offer line, exit 0, no triage key
Dir.mktmpdir do |d|
  st, out, _err = run(d, '--source', 'Quarterly Ops Review', '--mode', 'live', '--tool', 'tableau-to-sigma')
  ok('no plan → exit 0 (friction-free)', st == 0)
  ok('one-line assessment offer printed', out.include?('no migration-plan.json') && out.include?('--plan'))
  ok('no triage block in intake.json when no plan', intake_json(d) && !intake_json(d).key?('triage'))
end

# 6. healthy tier → [OK] triage line, verdict proceed
Dir.mktmpdir do |d|
  write_plan(d, plan_entry)
  st, out, _err = run(d, '--source', 'wb-legacy-1')
  ok('migrate-first tier proceeds', st == 0)
  ok('triage OK line cites value/cost', out.include?('triage') && out.include?('score=41.5'))
  t = intake_json(d) && intake_json(d)['triage']
  ok('intake.json triage verdict proceed', t && t['verdict'] == 'proceed' && t['priority_tier'] == 'migrate-first')
end

# 7. low rank (tier moderate, score < 10) → WARN with value/cost, still exit 0
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('priority_tier' => 'moderate', 'score' => 3.2, 'accesses' => 11, 'actors' => 1,
                           'blockers' => ['2 manual-setup feature(s)']))
  st, _out, err = run(d, '--source', 'wb-legacy-1')
  ok('low rank NEVER stops', st == 0)
  ok('low-rank WARN cites the value/cost line', err.include?('ranked LOW') && err.include?('score=3.2') &&
     err.include?('2 manual-setup feature(s)'))
  ok('verdict low-value-warn', intake_json(d)['triage']['verdict'] == 'low-value-warn')
end

# 8. blocked path (cost-side low rank) → WARN, exit 0
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'blocked', 'priority_tier' => 'moderate',
                           'blockers' => ['7 unhandled feature(s)']))
  st, _out, err = run(d, '--source', 'wb-legacy-1')
  ok('blocked path warns but proceeds', st == 0 && err.include?('ranked LOW'))
end

# 9. consolidation member → WARN naming the primary, exit 0
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'consolidate-into-primary', 'consolidate_into' => 'wb-primary-9'))
  st, _out, err = run(d, '--source', 'wb-legacy-1')
  ok('consolidation member warns but proceeds', st == 0 && err.include?('wb-primary-9'))
  ok('verdict consolidation-member-warn', intake_json(d)['triage']['verdict'] == 'consolidation-member-warn')
end

# 10. plan present, no --source → NOTE + skip, exit 0
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'retire'))
  st, _out, err = run(d)
  ok('no --source → triage skipped, no stop', st == 0 && err.include?('triage skipped'))
end

# 11. source not in the plan → NOTE + skip, exit 0 (even with retire rows present)
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'retire'))
  st, _out, err = run(d, '--source', 'Some Unassessed Workbook')
  ok('unmatched source → skip, no stop', st == 0 && err.include?('not found in'))
end

# 12. malformed plan JSON → WARN + skip, exit 0
Dir.mktmpdir do |d|
  File.write(File.join(d, 'migration-plan.json'), '{"workbooks": [half a plan')
  st, _out, err = run(d, '--source', 'wb-legacy-1')
  ok('malformed plan → skip, no stop', st == 0 && err.include?('unreadable'))
end

# 13. ambiguous duplicate names → ONE NOTE + skip, exit 0 (never guesses)
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('workbookId' => 'wb-1', 'recommended_path' => 'retire'),
                plan_entry('workbookId' => 'wb-2'))
  st, _out, err = run(d, '--source', 'Quarterly Ops Review')
  ok('duplicate names → skip with id hint, no stop', st == 7 ? false : (st == 0 && err.include?('share the name')))
  ok('ambiguous match does NOT also claim not-found (one accurate note)', !err.include?('not found in'))
end

# 14. case-insensitive unique name match still triages
Dir.mktmpdir do |d|
  write_plan(d, plan_entry('recommended_path' => 'retire'))
  st, _out, _err = run(d, '--source', 'quarterly ops review')
  ok('case-insensitive name match triages (retire refuses)', st == 7)
end

# 15. --plan pointing at a missing file → WARN + skip, exit 0
Dir.mktmpdir do |d|
  st, _out, err = run(d, '--source', 'wb-legacy-1', '--plan', File.join(d, 'nope.json'))
  ok('missing --plan file → skip, no stop', st == 0 && err.include?('not found'))
end

# 16. explicit --plan from an assessment dir (not the workdir) is honored
Dir.mktmpdir do |d|
  assess = File.join(d, 'assessment'); FileUtils.mkdir_p(assess)
  File.write(File.join(assess, 'migration-plan.json'),
             JSON.generate('workbooks' => [plan_entry('recommended_path' => 'retire')]))
  st, _out, _err = run(d, '--source', 'wb-legacy-1', '--plan', File.join(assess, 'migration-plan.json'))
  ok('external --plan consumed (retire refuses)', st == 7)
end

puts $fail.zero? ? "\nall intake-triage tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
