#!/usr/bin/env ruby
# Regression test: coverage must be accounted at the FIELD-BINDING level, and every
# coverage entry must carry role_class.
#
# WHY (measured 2026-07-30 on 4 real Power BI reports, R1–R4): CoverageGate counted
# VISUALS, not FIELDS. A table shipping 3 of its 8 columns is merely 'degraded', and
# 'degraded' counts as CARRIED OVER — so a migration that dropped 33–54% of its field
# bindings reported "12/12 source visual(s) carried over; 0 dropped." Reproduced live:
# one run printed "5/5 ... 0 dropped" while listing two visuals with UNMAPPED queryRefs.
#
# THE LOAD-BEARING ASSERTION is the role_class invariant below. CoverageGate.gate!
# (shipped in #556) fails a run only when a 'dropped' entry's role_class is in
# GATE_ROLES. A live connected run produced TWO genuinely-dropped functional visuals
# (a KPI card and a table) whose entries carried role_class = nil — so the gate would
# have PASSED a migration that dropped a KPI and a table. A gate with that hole is
# worse than no gate, because it reports safety it does not provide.
#
# Usage:  ruby scripts/test-field-binding-coverage.rb
require 'json'

HERE = __dir__
SPEC = '/tmp/fbc-spec.json'
COV  = '/tmp/fbc-cov.json'
FIX  = '/tmp/fbc-fixture'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

require 'fileutils'
FileUtils.mkdir_p(FIX)

# One page. The table binds SIX refs of which only TWO resolve on the master — the
# other four are measures the model never produced (the customer's exact shape).
def visual(id, vtype, kind, role, bindings, title)
  { 'visual_id' => id, 'visual_type' => vtype, 'title' => title,
    'sigma_kind' => kind, 'role_class' => role, 'sigma_target' => nil,
    'viz_guidance' => nil, 'viz_catalog' => 'viz-kind', 'approximate' => false,
    'orientation' => nil, 'x' => 0, 'y' => 0, 'w' => 400, 'h' => 400, 'z' => 0,
    'parent_group' => nil, 'bindings' => bindings, 'sort' => nil, 'stacking' => nil,
    'formats' => {}, 'data_labels' => nil, 'legend' => nil }
end

SIGNALS = { 'source' => 'report.json-classic', 'pages' => [{
  'page_id' => 'p0', 'page_title' => 'P0', 'page_w' => 1280, 'page_h' => 720,
  'interactions' => [],
  'visuals' => [
    visual('p0v0', 'tableEx', 'table', 'table', { 'Values' => [
      'T.Dim', 'T.Amount',                                  # resolve
      'T.Ghost Measure A', 'T.Ghost Measure B',              # do not
      'T.Ghost Measure C', 'T.Ghost Measure D'] }, 'Detail'),
    visual('p0v1', 'card', 'kpi', 'kpi', { 'Values' => ['T.Ghost Measure A'] }, 'Ghost KPI')
  ] }] }.freeze

MASTER_MAP = { 'masters' => { 'T' => {
    'id' => 'master-t', 'element_id' => 'el-t', 'data_model' => 'dm-1', 'metrics' => [],
    'columns' => [{ 'id' => 'mc-dim', 'name' => 'Dim', 'formula' => '[T/Dim]' },
                  { 'id' => 'mc-amt', 'name' => 'Amount', 'formula' => '[T/Amount]' }] } },
  'fields' => {
    'T.Dim'    => { 'master' => 'T', 'ref' => '[master-t/Dim]',    'agg' => nil },
    'T.Amount' => { 'master' => 'T', 'ref' => '[master-t/Amount]', 'agg' => 'Sum' } } }.freeze

File.write("#{FIX}/signals.json", JSON.pretty_generate(SIGNALS))
File.write("#{FIX}/master-map.json", JSON.pretty_generate(MASTER_MAP))

system('ruby', File.join(HERE, 'build-workbook-from-pbir.rb'),
       '--signals', "#{FIX}/signals.json", '--master-map', "#{FIX}/master-map.json",
       '--data-model', 'dm-1', '--out', SPEC, '--coverage-out', COV,
       '--layout-out', '/tmp/fbc-layout.xml', '--name', 'FBC',
       out: '/tmp/fbc.log', err: '/tmp/fbc.err')

unless File.exist?(COV)
  puts '  FAIL  builder wrote no coverage.json'
  puts File.read('/tmp/fbc.err').lines.last(12).join
  exit 1
end
cov  = JSON.parse(File.read(COV))
gaps = cov['unresolved'] || []
summ = cov['summary'] || {}

puts "\n1. summary carries FIELD-BINDING totals (what CoverageGate.binding_totals reads)"
check(summ.key?('sourceBindings'), 'summary.sourceBindings present', fails)
check(summ.key?('resolvedBindings'), 'summary.resolvedBindings present', fails)
check(summ['sourceBindings'].to_i == 7,
      "sourceBindings == 7 (6 table refs + 1 KPI ref; got #{summ['sourceBindings'].inspect})", fails)
check(summ['resolvedBindings'].to_i == 2,
      "resolvedBindings == 2 (only Dim + Amount resolve; got #{summ['resolvedBindings'].inspect})", fails)

puts "\n2. the table visual emits a per-ref field_bindings ledger"
tbl = gaps.find { |u| u['visual'].to_s =~ /Detail/ }
check(!tbl.nil?, 'the degraded table has a coverage entry', fails)
fb = (tbl && tbl['field_bindings']) || []
check(fb.size == 6, "table entry has 6 field_bindings (got #{fb.size})", fails)
check(fb.count { |b| b['status'] == 'dropped' } == 4,
      "4 of them are status 'dropped' (got #{fb.count { |b| b['status'] == 'dropped' }})", fails)
check(fb.count { |b| b['status'] == 'resolved' } == 2,
      "2 of them are status 'resolved' (got #{fb.count { |b| b['status'] == 'resolved' }})", fails)
check(fb.all? { |b| b['queryRef'].to_s.start_with?('T.') },
      'every field_binding names its queryRef', fails)

puts "\n3. CoverageGate reads it end to end"
$LOAD_PATH.unshift File.join(HERE, 'lib')
require 'coverage_gate'
total, resolved = CoverageGate.binding_totals(cov)
check([total, resolved] == [7, 2], "binding_totals == [7, 2] (got #{[total, resolved].inspect})", fails)
check((CoverageGate.binding_loss(cov) - (5.0 / 7)).abs < 0.001,
      'binding_loss == 5/7', fails)
check(CoverageGate.binding_headline(cov).include?('2/7'),
      "headline names 2/7 (got #{CoverageGate.binding_headline(cov).inspect})", fails)

puts "\n4. LOAD-BEARING: every coverage entry carries role_class"
missing = gaps.reject { |u| u.key?('role_class') && !u['role_class'].nil? }
check(missing.empty?,
      "no entry lacks role_class (offenders: #{missing.map { |u| u['visual'] }.first(4)})", fails)
dropped_no_role = gaps.select { |u| u['severity'] == 'dropped' && u['role_class'].to_s.empty? }
check(dropped_no_role.empty?,
      'no DROPPED entry lacks role_class — else gate! silently passes it', fails)

puts "\n4b. STATIC invariant: no record_unresolved call site omits role_class"
# The runtime check above only sees the call sites this fixture happens to reach. The
# realistic regression is someone ADDING a record_unresolved without role_class — a
# silent hole in gate!, in a branch no fixture exercises. So check every call site in
# the source.
#
# This MUST tokenize rather than count raw parens. A naive depth scan is not
# string-aware: a call whose `detail:`/`action:` string contains an unmatched "(" makes
# the counter overrun its real closing paren and swallow the rest of the file — and
# because "role_class" appears somewhere in that swallowed span, a genuinely unstamped
# call reports as STAMPED. That is a false PASS, the dangerous direction, and it would
# defeat this guard entirely (caught in review, 2026-07-30). Ripper classifies string
# bodies as :on_tstring_content and comments as :on_comment, so parens inside them are
# never counted — which also stops a `record_unresolved(` mentioned in a COMMENT from
# being treated as a real call site (the old scanner's false-FAIL).
require 'ripper'
src = File.read(File.join(HERE, 'build-workbook-from-pbir.rb'))
toks = Ripper.lex(src)
sites = []
toks.each_with_index do |(pos, type, val, _st), i|
  next unless type == :on_ident && val == 'record_unresolved'
  # the next significant token must be "(" — otherwise it is the `def`, or a mention
  j = i + 1
  j += 1 while toks[j] && %i[on_sp on_ignored_nl on_nl].include?(toks[j][1])
  next unless toks[j] && toks[j][1] == :on_lparen
  next if i.positive? && toks[i - 1..i - 1].any? { |t| t[1] == :on_kw && t[2] == 'def' }
  depth = 0
  labels = []
  k = j
  while k < toks.length
    t = toks[k][1]
    depth += 1 if t == :on_lparen
    depth -= 1 if t == :on_rparen
    labels << toks[k][2] if t == :on_label
    break if depth.zero?
    k += 1
  end
  sites << { line: pos[0], labels: labels, closed: depth.zero? }
end
check(!sites.empty?, "found record_unresolved call sites to check (#{sites.size})", fails)
check(sites.all? { |x| x[:closed] }, 'every call site parsed to a balanced close', fails)
unstamped = sites.reject { |x| x[:labels].include?('role_class:') }
check(unstamped.empty?,
      "every record_unresolved call passes role_class (unstamped at line(s): " \
      "#{unstamped.map { |x| x[:line] }.join(', ')})", fails)
check(src =~ /def record_unresolved\([^)]*role_class:/m,
      'record_unresolved declares a role_class keyword', fails)

# and prove the scanner itself is string-aware — the exact review repro
probe = <<~RB
  record_unresolved(visual: n, detail: "value (per the report spec", severity: 'dropped')
  record_unresolved(visual: n, role_class: 'kpi', severity: 'dropped')
RB
ptoks = Ripper.lex(probe)
psites = []
ptoks.each_with_index do |(pos, type, val, _st), i|
  next unless type == :on_ident && val == 'record_unresolved'
  j = i + 1
  j += 1 while ptoks[j] && %i[on_sp].include?(ptoks[j][1])
  next unless ptoks[j] && ptoks[j][1] == :on_lparen
  depth = 0; labels = []; k = j
  while k < ptoks.length
    t = ptoks[k][1]
    depth += 1 if t == :on_lparen
    depth -= 1 if t == :on_rparen
    labels << ptoks[k][2] if t == :on_label
    break if depth.zero?
    k += 1
  end
  psites << labels
end
check(psites.size == 2, "scanner finds both probe call sites (got #{psites.size})", fails)
check(psites[0] && !psites[0].include?('role_class:'),
      'an unstamped call with an unmatched "(" inside a string is still detected — no false PASS', fails)
check(psites[1] && psites[1].include?('role_class:'), 'a stamped call is recognised as stamped', fails)

puts "\n5. and the gate actually fires on this run"
st, why = CoverageGate.gate!(cov, min_resolved: 0.95, allow_override: false)
check(st == :fail, "gate! FAILS a run that resolved 2 of 7 bindings (got #{st.inspect})", fails)
check(why.to_s.length > 20, "failure reason is substantive: #{why.to_s[0, 90]}", fails)
st2, why2 = CoverageGate.gate!(cov, min_resolved: 0.95, allow_override: true)
check(st2 == :pass, 'explicit override lets it through', fails)
check(why2.to_s.include?('overridden'), 'override still states the reason', fails)

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
