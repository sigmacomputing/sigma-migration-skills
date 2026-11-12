#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for record-visual-check.rb's vision precondition (§D5) and
# the PR-9 blind-grader precondition.
#
# Gate 8/8b used to prove only that a PNG exists and a verdict was recorded —
# an agent WITHOUT image input could still "record" pass (a blind attestation).
# Now --agent-vision true|false is required (env AGENT_VISION as fallback):
#   - vision=false + pass       → REFUSED, exit nonzero, parity-final untouched
#   - not-executable            → --notes mandatory; stamps visual_checked:false,
#                                 visual_verdict:"not-executable", agent_vision:false
#   - every verdict             → stamps agent_vision
#   - flag omitted entirely     → loud deprecation WARN + assume true (back-compat)
#
# PR-9 (blind visual grader): a pass additionally requires --blind-grade — a
# blind-grade.json from a CONTEXT-FREE subagent, validated (all six dimensions),
# sha256-BOUND to the actual image files (hashes recomputed), cross-checked
# against the mechanical kind census, and REFUSED when the blind verdict is
# fail. The only escape is --no-vision-waiver "<reason>" (budget-counted).
#
# Usage:  ruby scripts/test-record-visual-check.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'digest'
require 'fileutils'
require_relative 'lib/blind_fixture'

SCRIPT = File.join(__dir__, 'record-visual-check.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

CL = 'element_titles_hidden=pass,palette_match=pass,composition_match=pass,' \
     'chart_shapes_match=pass,labels_legible=pass,numbers_formatted=pass'

# Fresh workdir with a minimal parity-final.json per case. blind: :valid
# installs a hash-bound passing blind-grade fixture and appends --blind-grade;
# a Proc receives the dir and returns extra args (custom fixtures/tampering).
def run_case(args, env: {}, blind: nil)
  Dir.mktmpdir('rvc-test') do |dir|
    pf = File.join(dir, 'parity-final.json')
    File.write(pf, JSON.pretty_generate('status' => 'PASS', 'charts_total' => 3, 'charts_pass' => 3))
    extra = []
    case blind
    when :valid
      BlindFixture.install(dir, stamp: false)
      extra = ['--blind-grade', File.join(dir, 'blind-grade.json')]
    when Proc
      extra = Array(blind.call(dir))
    end
    clean_env = { 'AGENT_VISION' => nil }.merge(env)
    out, err, st = Open3.capture3(clean_env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args, *extra)
    [out, err, st, JSON.parse(File.read(pf))]
  end
end

# --- pass + vision true + valid blind grade → exit 0, stamps ------------------
out, _err, st, pf = run_case(%w[--verdict pass --agent-vision true --notes ok] + ['--checklist', CL], blind: :valid)
check(st.success?, 'pass + --agent-vision true + valid blind grade → exit 0', fails)
check(pf['visual_checked'] == true && pf['visual_verdict'] == 'pass', 'pass stamps visual_checked:true', fails)
check(pf['agent_vision'] == true, 'pass stamps agent_vision:true', fails)
check(out.include?('[OK]'), 'pass prints [OK]', fails)
check(pf['blind_grade'].is_a?(Hash) && pf['blind_grade']['verdict'] == 'pass',
      'pass stamps blind_grade metadata', fails)
check(pf['blind_grade']['source_sha256'].to_s =~ /\A[0-9a-f]{64}\z/ &&
        pf['blind_grade']['target_sha256'].to_s =~ /\A[0-9a-f]{64}\z/,
      'blind_grade stamp carries both 64-hex sha256s', fails)
check(BlindFixture::KEYS.all? { |k| pf['blind_grade']['dimensions'][k] == 'pass' },
      'blind_grade stamp carries all six dimension verdicts', fails)
check(out.include?('blind grade: PASS') && out.include?('sha-bound'),
      'pass output names the sha-bound blind grade', fails)

# --- pass + vision false → REFUSED, nothing written --------------------------
_out, err, st, pf = run_case(%w[--verdict pass --agent-vision false --notes blind])
check(!st.success?, 'pass + --agent-vision false → exits NONZERO', fails)
check(err.include?('REFUSED: a pass verdict requires an agent that actually read the render'),
      'refusal message names the vision requirement', fails)
check(err.include?('not-executable') && err.include?('vision-capable session'),
      'refusal points at not-executable + a vision-capable session', fails)
check(!pf.key?('visual_verdict') && !pf.key?('agent_vision'),
      'refusal writes NOTHING into parity-final.json', fails)

# --- env AGENT_VISION=false is honored as the fallback source ----------------
_out, err, st, pf = run_case(%w[--verdict pass --notes blind], env: { 'AGENT_VISION' => 'false' })
check(!st.success? && err.include?('REFUSED'), 'env AGENT_VISION=false + pass → refused', fails)
check(!pf.key?('agent_vision'), 'env-refused run writes nothing', fails)

# ...and the flag beats the env
_out, _err, st, pf = run_case((%w[--verdict pass --agent-vision true] + ['--checklist', CL]),
                              env: { 'AGENT_VISION' => 'false' }, blind: :valid)
check(st.success? && pf['agent_vision'] == true, '--agent-vision flag overrides AGENT_VISION env', fails)

# --- not-executable: notes mandatory, stamps the degradation -----------------
_out, err, st, pf = run_case(%w[--verdict not-executable --agent-vision false])
check(!st.success? && err.include?('--notes'), 'not-executable without --notes → fatal', fails)

_out, err, st, pf = run_case(['--verdict', 'not-executable', '--agent-vision', 'false',
                              '--notes', 'agent lacks image input'])
check(st.success?, 'not-executable + notes → exit 0 (recorded; gate blocks downstream)', fails)
check(pf['visual_checked'] == false, 'not-executable stamps visual_checked:false', fails)
check(pf['visual_verdict'] == 'not-executable', 'not-executable stamps visual_verdict', fails)
check(pf['agent_vision'] == false, 'not-executable stamps agent_vision:false', fails)
check(err.include?('visual gate not executable') || err.include?('vision-capable session'),
      'not-executable output names the gate-8b consequence', fails)

# not-executable forces agent_vision:false even if the caller claims true
_out, _err, st, pf = run_case(['--verdict', 'not-executable', '--agent-vision', 'true',
                               '--notes', 'render loop unavailable'])
check(st.success? && pf['agent_vision'] == false,
      'not-executable stamps agent_vision:false even with --agent-vision true', fails)

# --- divergent + vision false: recordable, stamped ----------------------------
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'false',
                               '--notes', 'cannot confirm'])
check(st.success? && pf['visual_checked'] == false && pf['agent_vision'] == false,
      'divergent + vision false → recorded with agent_vision:false (gate 8b blocks)', fails)

# --- divergent message states the REAL gate consequence (D3 doc/behavior fix) --
# The old message claimed "gate 8b will still BLOCK" — false: a recorded
# divergent verdict passes 8b as RECORDED and is budget-counted instead.
_out, err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true',
                              '--notes', 'Region bar truncated vs source'])
check(st.success? && pf['visual_verdict'] == 'divergent' && pf['visual_checked'] == false,
      'divergent recorded: stamps verdict, visual_checked stays false', fails)
check(err.include?('passes as RECORDED'),
      'divergent message states gate 8b passes as RECORDED (never claims it blocks)', fails)
check(!err.include?('will still BLOCK'),
      'divergent message no longer makes the false will-still-BLOCK claim', fails)
check(!err.include?('BUDGET-COUNTED') && err.include?('not a waiver'),
      'divergent message states it is NOT budget-counted (blind-grade v2: not a waiver)', fails)
check(err.include?('YELLOW') && err.include?('forfeits GREEN'),
      'divergent message states the choice: fix the gaps or accept YELLOW (forfeits GREEN)', fails)

# --- back-compat: omitted flag → loud WARN + assume true ----------------------
_out, err, st, pf = run_case(%w[--verdict pass --notes legacy-caller] + ['--checklist', CL], blind: :valid)
check(st.success?, 'omitted --agent-vision → still exit 0 (back-compat)', fails)
check(pf['agent_vision'] == true && pf['visual_checked'] == true, 'omitted flag assumes agent_vision:true', fails)
check(err.include?('DEPRECATED') && err.include?('--agent-vision'),
      'omitted flag prints the loud deprecation warning', fails)

# --- bad values rejected -------------------------------------------------------
_out, _err, st, _pf = run_case(%w[--verdict pass --agent-vision maybe])
check(!st.success?, '--agent-vision maybe → rejected by the option parser', fails)


# --- v5.3 style checklist contract ---------------------------------------------
_out, err, st, pf = run_case(%w[--verdict pass --agent-vision true --notes x], blind: :valid)
check(!st.success? && err.include?('--checklist'), 'pass WITHOUT checklist → refused naming --checklist', fails)
check(!pf.key?('visual_verdict'), 'checklist refusal writes nothing', fails)
_out, err, st, pf = run_case(['--verdict', 'pass', '--agent-vision', 'true',
                              '--checklist', CL.sub('palette_match=pass', 'palette_match=fail')], blind: :valid)
check(!st.success? && err.include?('palette_match'), 'checklist fail dimension → pass refused, names it', fails)
_out, _err, st, pf = run_case(['--verdict', 'pass', '--agent-vision', 'true', '--checklist',
                               CL.sub('numbers_formatted=pass', 'numbers_formatted=na')], blind: :valid)
check(st.success? && pf['style_checklist']['numbers_formatted'] == 'na',
      'na dimension accepted + checklist stamped', fails)
_out, err, st, _pf = run_case(['--verdict', 'pass', '--agent-vision', 'true',
                               '--checklist', 'palette_match=pass'], blind: :valid)
check(!st.success? && err.include?('missing key'), 'incomplete checklist → fatal naming missing keys', fails)
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true', '--notes', 'gaps',
                               '--checklist', CL.sub('palette_match=pass', 'palette_match=fail')])
check(st.success? && pf['style_checklist']['palette_match'] == 'fail',
      'divergent records a failing checklist for the fix loop', fails)

# =============================================================================
# PR-9 — blind-grader precondition
# =============================================================================
PASS_ARGS = %w[--verdict pass --agent-vision true --notes ok] + ['--checklist', CL]

# pass WITHOUT --blind-grade and WITHOUT the waiver → refused, flow explained
_out, err, st, pf = run_case(PASS_ARGS)
check(!st.success?, 'pass without --blind-grade → REFUSED (exit nonzero)', fails)
check(err.include?('--blind-grade') && err.include?('blind-grader-brief'),
      'refusal explains the blind flow (brief + --blind-grade)', fails)
check(err.include?('CONTEXT-FREE') || err.include?('context-free'),
      'refusal names the context-free grader requirement', fails)
check(err.include?('--no-vision-waiver') && err.include?('waiver budget'),
      'refusal names the only escape + its budget cost', fails)
check(!pf.key?('visual_verdict') && !pf.key?('blind_grade'), 'blind refusal writes nothing', fails)

# hash mismatch: image tampered AFTER grading → refused
tamper = lambda do |dir|
  BlindFixture.install(dir, stamp: false)
  File.binwrite(File.join(dir, 'sigma-render.png'), BlindFixture.png_bytes('X'))
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
end
_out, err, st, pf = run_case(PASS_ARGS, blind: tamper)
check(!st.success? && err.include?('target_sha256 does NOT match'),
      'render changed after grading (sha mismatch) → refused naming the binding', fails)
check(!pf.key?('blind_grade'), 'hash-mismatch refusal writes nothing', fails)

# RCF-bound pass: grade, selected screenshot, and latest budgeted render must
# identify the same pixels. A direct post-budget export or stale intermediate
# grade is not final evidence.
rcf_match = lambda do |dir|
  BlindFixture.install(dir, stamp: false)
  target = File.join(dir, 'sigma-render.png')
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(
    'workbook_id' => 'wb', 'page_id' => 'page', 'pass' => 1,
    'max_passes' => 5,
    'renders' => [{ 'pass' => 1, 'path' => target }],
    'entries' => []
  ))
  ['--blind-grade', File.join(dir, 'blind-grade.json'), '--screenshot', target]
end
_out, _err, st, pf = run_case(PASS_ARGS, blind: rcf_match)
check(st.success? && pf.dig('blind_grade', 'fidelity_render', 'pass') == 1,
      'blind pass stamps the matching latest budgeted fidelity render', fails)

rcf_stale = lambda do |dir|
  BlindFixture.install(dir, stamp: false)
  latest = File.join(dir, 'rcf-pass-2.png')
  File.binwrite(latest, BlindFixture.png_bytes('L'))
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(
    'workbook_id' => 'wb', 'page_id' => 'page', 'pass' => 2,
    'max_passes' => 5,
    'renders' => [
      { 'pass' => 1, 'path' => File.join(dir, 'sigma-render.png') },
      { 'pass' => 2, 'path' => latest }
    ],
    'entries' => []
  ))
  ['--blind-grade', File.join(dir, 'blind-grade.json'), '--screenshot', latest]
end
_out, err, st, pf = run_case(PASS_ARGS, blind: rcf_stale)
check(!st.success? && err.include?('do not identify the same pixels'),
      'stale blind grade over an intermediate render is refused', fails)
check(!pf.key?('blind_grade'), 'stale-render refusal writes nothing', fails)

# fabricated shas (never computed from the files) → refused
fake_sha = lambda do |dir|
  g = BlindFixture.install(dir, stamp: false)
  g['source_sha256'] = 'a' * 64
  File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(g))
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
end
_out, err, st, _pf = run_case(PASS_ARGS, blind: fake_sha)
check(!st.success? && err.include?('source_sha256 does NOT match'),
      'fabricated source sha → refused (hash recomputed, never trusted)', fails)

# missing dimension → refused naming it
drop_dim = lambda do |dir|
  g = BlindFixture.install(dir, stamp: false)
  g['dimensions'].delete('chart_shapes_match')
  File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(g))
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
end
_out, err, st, _pf = run_case(PASS_ARGS, blind: drop_dim)
check(!st.success? && err.include?('chart_shapes_match'),
      'blind grade missing a checklist dimension → refused naming it', fails)

# blind verdict FAIL + builder pass → refused with the top gaps
_out, err, st, pf = run_case(PASS_ARGS, blind: lambda { |dir|
  BlindFixture.install(dir, stamp: false, verdict: 'fail')
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
})
check(!st.success?, 'builder pass over a FAILING blind grade → refused', fails)
check(err.include?("blind grader's verdict is FAIL") && err.include?('chart_shapes_match'),
      'refusal names the blind fail + failing dimension', fails)
check(err.include?('divergent'), 'refusal routes to --verdict divergent + fix loop', fails)
check(!pf.key?('visual_verdict'), 'blind-fail refusal writes nothing', fails)

# ...but the same failing grade is recordable WITH --verdict divergent
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true', '--notes', 'gaps'],
                              blind: lambda { |dir|
                                BlindFixture.install(dir, stamp: false, verdict: 'fail')
                                ['--blind-grade', File.join(dir, 'blind-grade.json')]
                              })
check(st.success? && pf['blind_grade'].is_a?(Hash) && pf['blind_grade']['verdict'] == 'fail',
      'divergent + failing blind grade → recorded (feeds the fix loop)', fails)

# unparseable / missing grade file → refused
_out, err, st, _pf = run_case(PASS_ARGS, blind: lambda { |dir|
  File.write(File.join(dir, 'blind-grade.json'), '{nope')
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
})
check(!st.success? && err.include?('not valid JSON'), 'malformed blind-grade.json → refused', fails)
_out, err, st, _pf = run_case(PASS_ARGS, blind: ->(dir) { ['--blind-grade', File.join(dir, 'nope.json')] })
check(!st.success? && err.include?('not found'), 'missing blind-grade.json → refused', fails)

# --- anti-gaming: family readings vs the mechanical kind census ---------------
# wb-readback census: 1 kpi + 2 bar. Blind grade reads 1 kpi + 1 bar + 1 line
# → 1 mismatch (tolerated). Reading 1 kpi + 2 line → 2 mismatches (refused).
CENSUS_ELEMENTS = [
  { 'id' => 'e1', 'kind' => 'kpi-chart' },
  { 'id' => 'e2', 'kind' => 'bar-chart' },
  { 'id' => 'e3', 'kind' => 'bar-chart' },
  { 'id' => 'e4', 'kind' => 'control' },          # non-chart: never in the census
  { 'id' => 'e5', 'kind' => 'bar-chart', 'visibleAsSource' => false }, # hidden master
  { 'id' => 'e6', 'kind' => 'table' } # readback may drop visibleAsSource on a Data-page helper
].freeze
CENSUS_RB = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'page-data', 'name' => 'Data' },
                { 'id' => 'p1', 'name' => 'Dashboard' }],
    'elements' => CENSUS_ELEMENTS,
    'layout' => '<Page id="page-data"><Element elementId="e5"/><Element elementId="e6"/></Page>' \
                "<Page id=\"p1\">#{CENSUS_ELEMENTS.first(4).map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
  }
}.freeze

census_case = lambda do |families|
  lambda do |dir|
    File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(CENSUS_RB))
    tiles = families.each_with_index.map do |f, i|
      { 'position' => "r#{i + 1}c1", 'source_family' => f, 'target_family' => f }
    end
    BlindFixture.install(dir, stamp: false, per_tile: tiles)
    ['--blind-grade', File.join(dir, 'blind-grade.json')]
  end
end

_out, _err, st, pf = run_case(PASS_ARGS, blind: census_case.call(%w[kpi bar line]))
check(st.success?, 'census disagreement on exactly 1 tile → tolerated (accepted)', fails)
check(pf['blind_grade']['cross_check']['target'].to_s.start_with?('ok'),
      'tolerated cross-check recorded in the stamp', fails)

_out, err, st, pf = run_case(PASS_ARGS, blind: census_case.call(%w[kpi line line]))
check(!st.success?, 'census disagreement on 2 tiles → REFUSED as inconsistent', fails)
check(err.include?('INCONSISTENT') && err.include?('wb-readback.json'),
      'anti-gaming refusal names the census contradiction', fails)
check(err.include?('fabricated') || err.include?('stale'),
      'anti-gaming refusal states the fabrication rationale', fails)
check(!pf.key?('blind_grade'), 'anti-gaming refusal writes nothing', fails)

# --- no-vision waiver: recorded + loud, never silent --------------------------
_out, err, st, pf = run_case(PASS_ARGS + ['--no-vision-waiver', 'Agent tool unavailable in this CI session'])
check(st.success?, 'pass + --no-vision-waiver "<reason>" → exit 0 (recorded escape)', fails)
check(pf['blind_grade_waiver'].is_a?(Hash) &&
        pf['blind_grade_waiver']['reason'] == 'Agent tool unavailable in this CI session' &&
        pf['blind_grade_waiver']['kind'] == 'no-vision-grader',
      'waiver stamps blind_grade_waiver {kind, reason}', fails)
check(err.include?('waiver budget') && err.include?('NO-VISION-GRADER'),
      'waiver output is LOUD and names the budget cost', fails)
check(!pf.key?('blind_grade'), 'waived pass carries no blind_grade stamp (honest degradation)', fails)

# waiver misuse rejected
_out, err, st, _pf = run_case(PASS_ARGS + ['--no-vision-waiver', '   '])
check(!st.success? && err.include?('non-empty reason'), 'blank waiver reason → fatal', fails)
_out, err, st, _pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true', '--notes', 'x',
                               '--no-vision-waiver', 'why'])
check(!st.success? && err.include?('only applies to --verdict pass'),
      '--no-vision-waiver with a non-pass verdict → fatal', fails)
_out, err, st, _pf = run_case(PASS_ARGS + ['--no-vision-waiver', 'why'], blind: :valid)
check(!st.success? && err.include?('mutually exclusive'),
      '--blind-grade + --no-vision-waiver together → fatal', fails)


# =============================================================================
# blind-grade/v2 — computed verdict, second grader, catalog, visual-residuals
# =============================================================================
CATALOG = File.expand_path('../refs/sigma-platform-differences.json', __dir__)
V2_ARGS = %w[--agent-vision true --notes v2]

# Runs the recorder on a v2 fixture workdir; returns [out, err, status, parity-final, residuals|nil].
def v2_with_residuals(args, **kw)
  Dir.mktmpdir('rvc-test') do |dir|
    pf = File.join(dir, 'parity-final.json')
    File.write(pf, JSON.pretty_generate('status' => 'PASS'))
    kw[:pre]&.call(dir)
    BlindFixture.install_v2(dir, catalog_path: CATALOG, score: kw[:score] || 85,
                                 dim_fail: kw[:dim_fail] || [], gaps: kw[:gaps] || [],
                                 per_tile: kw[:per_tile] || BlindFixture::DEFAULT_TILES,
                                 extra: kw[:extra] || {})
    extra = ['--blind-grade', File.join(dir, 'blind-grade.json')]
    if kw[:second]
      BlindFixture.install_v2(dir, catalog_path: CATALOG, name: 'blind-grade-2.json', score: kw[:second])
      extra += ['--blind-grade-2', File.join(dir, 'blind-grade-2.json')]
    end
    extra += kw[:catalog_args] || []
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, err, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir,
                                  *args, *extra)
    res = File.exist?(File.join(dir, 'visual-residuals.json')) ? JSON.parse(File.read(File.join(dir, 'visual-residuals.json'))) : nil
    return [out, err, st, JSON.parse(File.read(pf)), res]
  end
end

# v2 faithful, NO --verdict / --checklist → computed pass + residuals file
out, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 90)
check(st.success? && pf['visual_verdict'] == 'pass' && pf['visual_checked'] == true,
      'v2 faithful records pass (verdict computed, no --verdict/--checklist needed)', fails)
check(!res.nil? && res['schema'] == 'visual-residuals/v1' && res['faithful'] == true,
      'v2 faithful writes visual-residuals.json', fails)
check(pf.dig('blind_grade', 'schema') == 'blind-grade/v2' && pf.dig('blind_grade', 'score') == 90.0 &&
        pf.dig('blind_grade', 'faithful') == true &&
        pf.dig('blind_grade', 'catalog_sha256').to_s =~ /\A[0-9a-f]{64}\z/,
      'v2 stamp carries schema/score/faithful/catalog_sha256', fails)
check(pf['style_checklist'].is_a?(Hash) && BlindFixture::KEYS.all? { |k| pf['style_checklist'][k] == 'pass' },
      'v2 without --checklist derives it from dimensions', fails)
check(pf.dig('blind_grade', 'grades').is_a?(Array) && pf['blind_grade']['grades'].size == 1 &&
        pf['blind_grade']['grades'][0]['path'] == 'blind-grade.json' &&
        pf['blind_grade']['grades'][0]['sha256'].to_s =~ /\A[0-9a-f]{64}\z/ &&
        pf['blind_grade']['grades'][0]['overall_score'] == 90,
      'v2 stamp grades[] = {path, sha256, overall_score}', fails)
check(pf.dig('blind_grade', 'catalog_path') == '../refs/sigma-platform-differences.json' ||
        pf.dig('blind_grade', 'catalog_path').to_s.end_with?('refs/sigma-platform-differences.json'),
      'v2 stamp carries catalog_path', fails)
check(res && res['catalog_sha256'] == pf['blind_grade']['catalog_sha256'] && res['score'] == 90.0 &&
        res['grades'] == pf['blind_grade']['grades'] && res['reasons'] == [] &&
        res['platform_differences'] == [] && res['residuals'] == [],
      'visual-residuals.json shape for a clean pass', fails)

# v2 unfaithful → divergent + reasons
out, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 40, dim_fail: %w[chart_shapes_match],
  gaps: [{ 'tile' => 'r2c1', 'dimension' => 'chart_shapes_match', 'description' => 'bar vs line',
           'severity' => 'major', 'class' => 'fixable' }])
check(st.success? && pf['visual_verdict'] == 'divergent' && pf['visual_checked'] == false &&
        res && res['faithful'] == false && res['reasons'].any?,
      'v2 unfaithful records divergent with reasons', fails)
check(pf['style_checklist']&.fetch('chart_shapes_match') == 'fail', 'v2 divergent derives failing checklist', fails)

# --verdict pass over unfaithful → refused
_o, err, st, pf, res = v2_with_residuals(%w[--verdict pass --agent-vision true --notes x], score: 40,
                                         dim_fail: %w[chart_shapes_match])
check(st.exitstatus == 2 && err.downcase.include?('divergent') && !pf.key?('visual_verdict') && res.nil?,
      '--verdict pass over unfaithful v2 refused exit 2, nothing written', fails)
# --verdict divergent over faithful → refused
_o, err, st, pf, res = v2_with_residuals(%w[--verdict divergent --agent-vision true --notes x], score: 90)
check(st.exitstatus == 2 && err.downcase.include?('computed verdict is pass') && !pf.key?('visual_verdict') && res.nil?,
      '--verdict divergent over faithful v2 refused exit 2, nothing written', fails)
# agreeing explicit verdict ok
_o, _e, st, pf, _r = v2_with_residuals(%w[--verdict pass --agent-vision true --notes x], score: 90)
check(st.success? && pf['visual_verdict'] == 'pass', 'agreeing explicit --verdict accepted for v2', fails)

# borderline single grade
_o, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 78)
check(st.exitstatus == 2 && err.include?('second blind grader required (score within ±5 of 75)') &&
        err.include?('blind-grade-2.json') && err.include?('--blind-grade-2') &&
        !pf.key?('visual_verdict') && res.nil?,
      'borderline single grade refused exit 2 with the exact message, nothing written', fails)

# two grades
out, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 78, second: 82)
check(st.success? && pf['visual_verdict'] == 'pass' && pf['blind_grade']['grades'].size == 2 &&
        pf['blind_grade']['score'] == 80.0,
      'two grades accepted: mean score decides, both shas stamped', fails)
check(res && res['grades'].size == 2, 'residuals lists both grades', fails)
_o, _e, st, pf, _r = v2_with_residuals(V2_ARGS, score: 78, second: 70)
check(st.success? && pf['visual_verdict'] == 'divergent' && pf['blind_grade']['score'] == 74.0,
      'two grades with mean below bar → divergent', fails)

# --- KPI band: the live "Retail Command Center" regression (two faithful grades) --
# Census [kpi,kpi,kpi,line,table,bar,bar,table,bar,map]. Grade 1 lists the KPI
# strip as 3 tiles; grade 2 reads it as ONE kpi tile. Both must be accepted.
RCC_FAMS = %w[kpi kpi kpi line table bar bar table bar map].freeze
RCC_TILE = ->(pos, f) { { 'position' => pos, 'source_family' => f, 'target_family' => f } }
RCC_T1 = [%w[r1c1 text], %w[r1c2 navigation], %w[r1c3 control], %w[r1c4 kpi], %w[r1c5 kpi], %w[r1c6 kpi],
          %w[r2c1 line], %w[r2c2 table], %w[r3c1 bar], %w[r3c2 bar], %w[r4c1 table], %w[r5c1 bar],
          %w[r5c2 map]].map { |pos, f| RCC_TILE.call(pos, f) }
RCC_T2 = [%w[r1c1 text], %w[r1c2 navigation], %w[r1c3 control], %w[r1c4 kpi], %w[r1c5 line], %w[r1c6 table],
          %w[r2c1 bar], %w[r2c2 bar], %w[r2c3 table], %w[r3c1 bar], %w[r3c2 map]].map { |pos, f| RCC_TILE.call(pos, f) }
Dir.mktmpdir('rvc-kpiband') do |dir|
  pf = File.join(dir, 'parity-final.json')
  File.write(pf, JSON.pretty_generate('status' => 'PASS'))
  elements = RCC_FAMS.each_with_index.map { |f, i| { 'id' => "e#{i}", 'kind' => (%w[table map].include?(f) ? f : "#{f}-chart") } }
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(
    'document' => { 'schemaVersion' => 4, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p1', 'name' => 'Dash' }],
                    'elements' => elements,
                    'layout' => "<Page id=\"p1\">#{elements.map { |e| %(<Element elementId="#{e['id']}"/>) }.join}</Page>" }))
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate('tiles' => RCC_FAMS.map { |f| { 'kind' => f } }))
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 77, per_tile: RCC_T1)
  BlindFixture.install_v2(dir, catalog_path: CATALOG, name: 'blind-grade-2.json', score: 80, per_tile: RCC_T2)
  _out, err, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, *V2_ARGS,
                                 '--blind-grade', File.join(dir, 'blind-grade.json'),
                                 '--blind-grade-2', File.join(dir, 'blind-grade-2.json'))
  rec = JSON.parse(File.read(pf))
  check(st.exitstatus == 0 && rec['visual_verdict'] == 'pass',
        "KPI band: RCC grades 77+80 (strip as 3 tiles / as 1 band) accepted, verdict pass (#{err.lines.first&.strip})", fails)
  check(rec.dig('blind_grade', 'cross_check', 'target').to_s.include?('KPI strip read as a band'),
        'KPI band: stamped cross_check mentions the band reading', fails)
end

# --- minor = notes (TJ 2026-11-09): the live OEO regression, end to end ---------
# The OEO executive dashboard graded 85 (faithful), 101/101 values, and finished
# YELLOW only because its 4 minor fixable gaps went into the degradation ledger.
# Fixture: the real grade's gaps/scores/per_tile (fixtures/oeo-2026-11-09-blind-grade.json).
# record -> ledger -> report -> green-offer must now say GREEN with 4 polish notes.
require_relative 'lib/degradation_ledger'
OEO = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'oeo-2026-11-09-blind-grade.json')))
Dir.mktmpdir('rvc-oeo') do |dir|
  pf = File.join(dir, 'parity-final.json')
  File.write(pf, JSON.pretty_generate('status' => 'PASS', 'charts_pass' => 9, 'charts_total' => 9, 'waivers' => []))
  fams = OEO['per_tile'].map { |t| t['source_family'] }.reject { |f| f == 'text' }
  elements = fams.each_with_index.map { |f, i| { 'id' => "e#{i}", 'kind' => "#{f}-chart" } }
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(
    'document' => { 'schemaVersion' => 4, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p1', 'name' => 'Executive Overview' }],
                    'elements' => elements,
                    'layout' => "<Page id=\"p1\">#{elements.map { |e| %(<Element elementId="#{e['id']}"/>) }.join}</Page>" }))
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate('tiles' => fams.map { |f| { 'kind' => f } }))
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: OEO['overall_score'], per_tile: OEO['per_tile'],
                               gaps: OEO['gaps'], extra: { 'scores' => OEO['scores'], 'dimensions' => OEO['dimensions'] })
  _out, err, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, *V2_ARGS,
                                 '--blind-grade', File.join(dir, 'blind-grade.json'))
  rec = JSON.parse(File.read(pf))
  vr = JSON.parse(File.read(File.join(dir, 'visual-residuals.json')))
  check(st.exitstatus == 0 && rec['visual_verdict'] == 'pass' && vr['faithful'] == true,
        "OEO: grade 85 records pass (#{err.lines.first&.strip})", fails)
  check(vr['residuals'].length == 4 && vr['platform_differences'].length == 1 && vr['fixable_major'].empty?,
        'OEO: 4 minor residuals + 1 platform difference, no major', fails)
  derived = DegradationLedger.derive(dir)
  check(derived.none? { |e| e['item'].to_s.start_with?('visual residual') },
        "OEO: no minor gap is a degradation (ledger: #{derived.map { |e| e['item'] }.inspect})", fails)
  check(DegradationLedger.polish_notes(dir).length == 4, 'OEO: the 4 minor gaps are polish notes', fails)
  DegradationLedger.write(dir, derived)
  File.write(File.join(dir, 'inventory.json'), JSON.generate(
    'objects' => [{ 'type' => 'dashboard', 'id' => 'd1', 'name' => 'Executive Overview', 'status' => 'migrated' }]))
  File.write(File.join(dir, 'dashboard-render-health.json'), JSON.generate('status' => 'healthy', 'failed_count' => 0))
  File.write(File.join(dir, 'dashboard-blank-risk.json'), JSON.generate('risk' => false, 'blank_count' => 0))
  File.write(File.join(dir, 'waivers.json'), JSON.generate('waivers' => []))
  md = File.join(dir, 'MIGRATION_REPORT.md')
  _o, rerr, rst = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'build-migration-report.rb'), '--workdir', dir, '--markdown', md)
  res = (JSON.parse(File.read(File.join(dir, 'migration-result.json'))) rescue {})
  check(rst.success? && res['verdict'] == 'GREEN' && res['degradations'] == [],
        "OEO: migration report is GREEN with no degradations (#{res['verdict'].inspect} #{rerr.lines.first&.strip})", fails)
  check(Array(res['polish_notes']).length == 4 && Array(res['platform_differences']).map { |p| p['catalog_id'] } == ['horizontal-axis-title-orientation'],
        'OEO: report lists 4 polish notes and the platform difference', fails)
  check(File.read(md).include?('## Minor polish notes') && File.read(md).include?('Trend line stroke is thinner'),
        'OEO: markdown has the Minor polish notes section', fails)
  fl = File.join(__dir__, 'fidelity-loop.rb')
  Open3.capture3({ 'FIDELITY_LOOP_CLI' => '1' }, RbConfig.ruby, fl, 'init', '--workbook-id', 'WB', '--page-id', 'PG', '--workdir', dir)
  go, = Open3.capture3({ 'FIDELITY_LOOP_CLI' => '1' }, RbConfig.ruby, fl, 'green-offer', '--workdir', dir)
  offer = (JSON.parse(go) rescue {})
  check(offer['realistic'] == false && offer['gaps'] == [] && offer['why_not'] == 'GREEN, optional polish: 4 notes',
        "OEO: green-offer reports 'GREEN, optional polish: 4 notes' (#{offer['why_not'].inspect})", fails)
end

# two grades, different target sha
_o, err, st, pf, res = (lambda do
  Dir.mktmpdir('rvc-test') do |dir|
    File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
    BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 78)
    g2 = JSON.parse(File.read(File.join(dir, 'blind-grade.json')))
    File.binwrite(File.join(dir, 'other.png'), BlindFixture.png_bytes('O'))
    g2['target_png'] = File.join(dir, 'other.png')
    g2['target_sha256'] = Digest::SHA256.file(File.join(dir, 'other.png')).hexdigest
    File.write(File.join(dir, 'blind-grade-2.json'), JSON.pretty_generate(g2))
    o, e, s = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, *V2_ARGS,
                             '--blind-grade', File.join(dir, 'blind-grade.json'),
                             '--blind-grade-2', File.join(dir, 'blind-grade-2.json'))
    [o, e, s, JSON.parse(File.read(File.join(dir, 'parity-final.json'))), File.exist?(File.join(dir, 'visual-residuals.json'))]
  end
end).call
check(st.exitstatus == 2 && err.include?('target_sha256') && !pf.key?('visual_verdict') && res == false,
      'two grades with different target sha refused exit 2', fails)

# --blind-grade-2 with v1 first grade; mixed schemas
_o, err, st, pf = run_case(PASS_ARGS, blind: lambda { |dir|
  BlindFixture.install(dir, stamp: false)
  BlindFixture.install_v2(dir, catalog_path: CATALOG, name: 'blind-grade-2.json')
  ['--blind-grade', File.join(dir, 'blind-grade.json'), '--blind-grade-2', File.join(dir, 'blind-grade-2.json')]
})
check(st.exitstatus == 2 && err.include?('blind-grade-2') && !pf.key?('visual_verdict'),
      '--blind-grade-2 with a v1 first grade refused exit 2', fails)
_o, err, st, pf = run_case(V2_ARGS, blind: lambda { |dir|
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 78)
  BlindFixture.install(dir, stamp: false)
  FileUtils.mv(File.join(dir, 'blind-grade.json'), File.join(dir, 'blind-grade-2.json'))
  BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 78)
  ['--blind-grade', File.join(dir, 'blind-grade.json'), '--blind-grade-2', File.join(dir, 'blind-grade-2.json')]
})
check(st.exitstatus == 2 && !pf.key?('visual_verdict'), 'mixed v2 + v1 grades refused exit 2', fails)

# catalog: unknown id / sha mismatch / load error / valid platform difference
_o, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 90,
  gaps: [{ 'tile' => 'r1c1', 'dimension' => 'palette_match', 'description' => 'd', 'severity' => 'minor',
           'class' => 'no-such-id' }])
check(st.exitstatus == 2 && err.include?('unknown catalog id') && err.include?('no-such-id') &&
        !pf.key?('visual_verdict') && res.nil?,
      'unknown catalog id refused, names the id', fails)
_o, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 90, extra: { 'catalog_sha256' => 'f' * 64 })
check(st.exitstatus == 2 && err.include?('catalog_sha256 mismatch') && !pf.key?('visual_verdict'),
      'catalog sha mismatch refused', fails)
_o, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 90, catalog_args: ['--catalog', CATALOG])
check(st.exitstatus == 2 && err.include?('--catalog was removed') && !pf.key?('visual_verdict') && res.nil?,
      'C2: --catalog is refused exit 2 (the shipped catalog is the only catalog)', fails)
# a gap citing a SHIPPED catalog id (on its own dimension) is a platform difference, never a residual
_o, _e, st, pf, res = v2_with_residuals(V2_ARGS, score: 90,
  gaps: [{ 'tile' => 'r1c1', 'dimension' => 'labels_legible', 'description' => 'typeface', 'severity' => 'major',
           'class' => 'font-family' }])
check(st.success? && pf['visual_verdict'] == 'pass' && res['platform_differences'].size == 1 &&
        res['residuals'].empty? && res['fixable_major'] == [] &&
        pf['blind_grade']['catalog_path'].to_s.end_with?('refs/sigma-platform-differences.json'),
      'shipped catalog-id gap is a platform difference; pass', fails)
# M3: shipped id on the wrong dimension refused
_o, err, st, pf, res = v2_with_residuals(V2_ARGS, score: 90,
  gaps: [{ 'tile' => 'r1c1', 'dimension' => 'palette_match', 'description' => 'typeface', 'severity' => 'minor',
           'class' => 'font-family' }])
check(st.exitstatus == 2 && err.include?('font-family') && err.include?('labels_legible') && err.include?('palette_match') &&
        !pf.key?('visual_verdict') && res.nil?,
      'M3: catalog id on the wrong dimension refused exit 2, nothing written', fails)

# I2: fixable major gaps of a divergent run are named in visual-residuals.json
MAJOR_GAP = { 'tile' => 'r1c1', 'dimension' => 'composition_match', 'description' => 'KPI row missing', 'severity' => 'major',
              'class' => 'fixable' }.freeze
_o, _e, st, pf, res = v2_with_residuals(V2_ARGS, score: 90, gaps: [MAJOR_GAP])
check(st.success? && pf['visual_verdict'] == 'divergent' && res['fixable_major'].map { |g| g['description'] } == ['KPI row missing'] &&
        res['residuals'].empty?,
      'I2: major fixable gap recorded in visual-residuals.json fixable_major (residuals stay minor-only)', fails)

# C1: the second grade cannot be the same grade / a rescue / a sink
_o, err, st, pf, res = (lambda do
  Dir.mktmpdir('rvc-test') do |dir|
    File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
    BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 78)
    g = File.join(dir, 'blind-grade.json')
    o, e, s = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, *V2_ARGS,
                             '--blind-grade', g, '--blind-grade-2', g)
    [o, e, s, JSON.parse(File.read(File.join(dir, 'parity-final.json'))), File.exist?(File.join(dir, 'visual-residuals.json'))]
  end
end).call
check(st.exitstatus == 2 && err.include?('same grade') && !pf.key?('visual_verdict') && res == false,
      'C1: --blind-grade-2 pointing at the same file refused exit 2', fails)
_o, err, st, pf, res = (lambda do
  Dir.mktmpdir('rvc-test') do |dir|
    File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
    BlindFixture.install_v2(dir, catalog_path: CATALOG, score: 78)
    FileUtils.cp(File.join(dir, 'blind-grade.json'), File.join(dir, 'copy.json'))
    o, e, s = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, *V2_ARGS,
                             '--blind-grade', File.join(dir, 'blind-grade.json'), '--blind-grade-2', File.join(dir, 'copy.json'))
    [o, e, s, JSON.parse(File.read(File.join(dir, 'parity-final.json'))), File.exist?(File.join(dir, 'visual-residuals.json'))]
  end
end).call
check(st.exitstatus == 2 && err.include?('same grade') && err.include?('identical bytes') && !pf.key?('visual_verdict') && res == false,
      'C1: a byte-identical copy as the second grade refused exit 2', fails)
[[60, 95], [50, 100], [95, 60], [90, 91]].each do |g1, g2|
  _o, err, st, pf, res = v2_with_residuals(V2_ARGS, score: g1, second: g2)
  check(st.exitstatus == 2 && err.include?('not borderline') && !pf.key?('visual_verdict') && res.nil?,
        "C1: second grade #{g2} refused when grade 1 alone (#{g1}) is not borderline", fails)
end

# M4: an explicit --checklist contradicting the grade is refused; an agreeing one accepted
_o, err, st, pf, res = v2_with_residuals(V2_ARGS + ['--checklist', CL], score: 90, dim_fail: %w[palette_match])
check(st.exitstatus == 2 && err.include?('contradicts') && err.include?('palette_match') && !pf.key?('visual_verdict') && res.nil?,
      'M4: --checklist claiming pass over a failing grade dimension refused exit 2', fails)
_o, _e, st, pf, _r = v2_with_residuals(V2_ARGS + ['--checklist', CL], score: 90)
check(st.success? && pf['style_checklist'].values.all? { |v| v == 'pass' }, 'M4: an agreeing --checklist accepted', fails)

# M7: not-executable takes no grade
_o, err, st, pf, res = v2_with_residuals(%w[--verdict not-executable --agent-vision false --notes nope], score: 90)
check(st.exitstatus == 2 && err.include?('takes no blind grade') && !pf.key?('visual_verdict') && res.nil?,
      'M7: --verdict not-executable with a v2 --blind-grade refused exit 2 with a clear message', fails)

# M2 / I1: stale stamps never survive a later record
stale_res = lambda do |dir|
  File.write(File.join(dir, 'visual-residuals.json'), JSON.generate('schema' => 'visual-residuals/v1', 'faithful' => true))
end
_o, _e, st, pf, res = v2_with_residuals(V2_ARGS, score: 90, pre: lambda { |dir|
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS', 'blind_grade_waiver' => { 'kind' => 'no-vision-grader', 'reason' => 'old' }))
})
check(st.success? && !pf.key?('blind_grade_waiver') && pf['blind_grade']['schema'] == 'blind-grade/v2',
      'M2: the v2 record deletes a stale blind_grade_waiver', fails)
_o, _e, st, pf, _r = run_case(PASS_ARGS + ['--no-vision-waiver', 'no grader'], blind: lambda { |dir|
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS', 'blind_grade' => { 'schema' => 'blind-grade/v2' }))
  stale_res.call(dir)
  []
})
check(st.success? && pf.key?('blind_grade_waiver') && !pf.key?('blind_grade'),
      'M2: the waiver record deletes a stale blind_grade', fails)
Dir.mktmpdir('rvc-test') do |dir|
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
  stale_res.call(dir)
  _o, _e, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, '--agent-vision', 'true',
                              '--verdict', 'pass', '--checklist', CL, '--no-vision-waiver', 'no grader', '--notes', 'w')
  check(st.success? && !File.exist?(File.join(dir, 'visual-residuals.json')), 'I1: a no-vision waiver record deletes a stale visual-residuals.json', fails)
  stale_res.call(dir)
  _o, _e, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, '--agent-vision', 'false',
                              '--verdict', 'not-executable', '--notes', 'no vision')
  check(st.success? && !File.exist?(File.join(dir, 'visual-residuals.json')), 'I1: a not-executable record deletes a stale visual-residuals.json', fails)
end
_o, _e, st, pf, _r = run_case(PASS_ARGS, blind: lambda { |dir|
  stale_res.call(dir)
  BlindFixture.install(dir, stamp: false)
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
})
check(st.success? && pf['visual_verdict'] == 'pass', 'I1: a v1 pass record still succeeds with a stale residuals file present', fails)
Dir.mktmpdir('rvc-test') do |dir|
  File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
  stale_res.call(dir)
  BlindFixture.install(dir, stamp: false)
  _o, _e, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, SCRIPT, '--workdir', dir, '--agent-vision', 'true',
                              '--verdict', 'pass', '--checklist', CL, '--blind-grade', File.join(dir, 'blind-grade.json'), '--notes', 'v1')
  check(st.success? && !File.exist?(File.join(dir, 'visual-residuals.json')), 'I1: a v1 grade record deletes a stale visual-residuals.json', fails)
end

# census: nav buttons are non-chart (2 charts + 9 buttons)
button_rb = lambda do |dir|
  els = [{ 'id' => 'e1', 'kind' => 'kpi-chart' }, { 'id' => 'e2', 'kind' => 'line-chart' }] +
        (1..9).map { |i| { 'id' => "b#{i}", 'kind' => 'button' } }
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(
    'workbookId' => 'wb', 'document' => { 'schemaVersion' => 4, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'p1', 'name' => 'Dashboard' }], 'elements' => els,
      'layout' => "<Page id=\"p1\">#{els.map { |e| %(<Element elementId="#{e['id']}"/>) }.join}</Page>" }))
end
out, err, st, pf, _r = v2_with_residuals(V2_ARGS, score: 90, pre: button_rb)
check(st.success? && pf.dig('blind_grade', 'cross_check', 'target').to_s.start_with?('ok'),
      '2 charts + 9 nav buttons: per_tile of just the charts passes the census', fails)

# v1 grade with no schema key behaves as v1
_o, _e, st, pf = run_case(PASS_ARGS, blind: lambda { |dir|
  g = BlindFixture.install(dir, stamp: false)
  g.delete('schema')
  File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(g))
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
})
check(st.success? && !pf['blind_grade'].key?('schema') && pf['visual_verdict'] == 'pass',
      'schema-less grade follows the v1 path (no v2 fields stamped)', fails)

puts
if fails.empty?
  puts 'ALL PASS — record-visual-check vision precondition (§D5) + PR-9 blind-grader precondition'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
