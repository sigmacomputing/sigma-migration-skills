#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test for lib/ref_label_repair.rb — the v5.4 GLOBAL ref-label repair.
# Field failure class (rounds 5+6, every run): the chart builder authors
# formula refs from raw twb serialization tokens ([Master/NUM_ENROLLED],
# [Master/runner_dir]) while the live workbook elements carry Sigma display
# labels ("Num Enrolled", "Runner Dir"); the v5.3 repair fixed helpers
# only, so chart elements failed the pre-POST ref gate one ref at a time.
# Usage: ruby scripts/test-ref-label-repair.rb
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'ref_label_repair'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

registry = {
  'Master' => ['Num Enrolled', 'Published Date', 'Level Pct', 'Course Title'],
  'Trend Source' => ['Year', 'Total Value']
}

els = [
  { 'kind' => 'bar-chart', 'columns' => [
    { 'id' => 'c1', 'formula' => 'Sum([Master/NUM_ENROLLED])' },              # raw physical name
    { 'id' => 'c2', 'formula' => '[Master/level_pct] * 100' },                   # twb snake_case
    { 'id' => 'c3', 'formula' => 'Sum([Master/Num Enrolled])' },              # already exact
    { 'id' => 'c4', 'formula' => 'CountDistinct([MASTER/COURSE-TITLE])' }        # element seg case + punct drift
  ] },
  { 'kind' => 'line-chart', 'columns' => [
    { 'id' => 'c5', 'formula' => 'Sum([trend source/TOTAL_VALUE])' },            # cross-element drift
    { 'id' => 'c6', 'formula' => 'Sum([Unknown Element/foo])' },                 # unknown element: untouched
    { 'id' => 'c7', 'formula' => '[Master/No Such Column] + 1' }                 # miss: untouched + reported
  ] },
  { 'kind' => 'text' }                                                           # no columns: skipped
]

rep = RefLabelRepair.repair!(els, registry)

f = ->(i, j) { els[i]['columns'][j]['formula'] }
check(f[0, 0] == 'Sum([Master/Num Enrolled])', "raw physical name re-cased (got #{f[0, 0]})", fails)
check(f[0, 1] == '[Master/Level Pct] * 100', 'snake_case token re-cased', fails)
check(f[0, 2] == 'Sum([Master/Num Enrolled])', 'exact ref untouched', fails)
check(f[0, 3] == 'CountDistinct([Master/Course Title])', 'element segment AND punct-drifted column re-cased', fails)
check(f[1, 0] == 'Sum([Trend Source/Total Value])', 'cross-element ref repaired against sibling labels', fails)
check(f[1, 1] == 'Sum([Unknown Element/foo])', 'ref to unregistered element left verbatim', fails)
check(f[1, 2] == '[Master/No Such Column] + 1', 'label miss left verbatim', fails)
check(rep[:misses].any? { |m| m.include?('No Such Column') }, 'label miss is reported', fails)
check(rep[:fixed] == 4, "fixed count is 4 — the exact ref is not counted (got #{rep[:fixed]})", fails)

# Ambiguity is never guessed — element level and label level.
amb_reg = {
  'Master' => ['Ship Mode', 'SHIP_MODE'],   # two labels, one normalization
  'Total$' => ['A'], 'Total' => ['A']       # two elements, one normalization
}
amb_els = [{ 'columns' => [
  { 'formula' => 'Sum([Master/ship mode])' },
  { 'formula' => 'Sum([total/A])' }
] }]
rep2 = RefLabelRepair.repair!(amb_els, amb_reg)
check(amb_els[0]['columns'][0]['formula'] == 'Sum([Master/ship mode])', 'ambiguous label left untouched', fails)
check(amb_els[0]['columns'][1]['formula'] == 'Sum([total/A])', 'ambiguous element name left untouched', fails)
check(rep2[:ambiguous].size == 2, "both ambiguities reported (got #{rep2[:ambiguous].inspect})", fails)

# Control refs / non-slash brackets must never be touched.
ctl = [{ 'columns' => [{ 'formula' => 'If([ctl-year] = [Master/Published Date], 1, 0)' }] }]
RefLabelRepair.repair!(ctl, registry)
check(ctl[0]['columns'][0]['formula'] == 'If([ctl-year] = [Master/Published Date], 1, 0)',
      'bare control ref untouched, slash ref still repaired in same formula', fails)

# ── BARE [Column] same-element re-casing (opt-in; DM path) ──────────────────
# DM calc columns author bare TitleCase refs ([Totalrev]) that Snowflake reads
# back UPPERCASE ([TOTALREV]) → type=error. same_element_recase re-cases them
# against the OWNING element's own live labels, with two honesty guards.
dm_reg = {
  'Fact Primary'   => %w[TOTALREV TOTALVOL USERID SRCDATE],
  'Contra Secondary' => %w[USERID PLANLINE CONTRA]   # USERID also here → cross-element
}
dm_els = [
  { 'name' => 'Fact Primary', 'columns' => [
    { 'id' => 'p1', 'formula' => '[Totalrev]' },                          # bare, re-case → TOTALREV
    { 'id' => 'p2', 'formula' => 'Sum([Totalrev]) / NullIf(Sum([Totalvol]), 0)' }, # two bare
    { 'id' => 'p3', 'formula' => '[TOTALREV]' },                          # already exact → leave
    { 'id' => 'p4', 'formula' => 'Coalesce([Userid], [USERID])' },        # USERID on 2 elements → DON'T re-case
    { 'id' => 'p5', 'formula' => 'If([ctl-region] = 1, [Totalrev], 0)' }, # control id left, bare col re-cased
    { 'id' => 'p6', 'formula' => '[Custom SQL/Totalrev]' }                # qualified:false → element-alias ref untouched
  ] },
  { 'name' => 'Contra Secondary', 'columns' => [
    { 'id' => 's1', 'formula' => '[Planline]' }                         # bare, re-case → PLANLINE
  ] }
]

# Default (workbook path): bare refs are NEVER touched — control refs are bare.
wb_check = [{ 'name' => 'Fact Primary', 'columns' => [{ 'formula' => '[Totalrev]' }] }]
RefLabelRepair.repair!(wb_check, dm_reg)
check(wb_check[0]['columns'][0]['formula'] == '[Totalrev]',
      'bare ref left verbatim when same_element_recase is OFF (workbook path safe)', fails)

# DM path call signature: qualified:false (don't touch element-alias segments) +
# same_element_recase:true (fix bare column casing).
rep3 = RefLabelRepair.repair!(dm_els, dm_reg, qualified: false, same_element_recase: true)
g = ->(i, j) { dm_els[i]['columns'][j]['formula'] }
check(g[0, 0] == '[TOTALREV]', "bare ref re-cased to own live label (got #{g[0, 0]})", fails)
check(g[0, 1] == 'Sum([TOTALREV]) / NullIf(Sum([TOTALVOL]), 0)', 'two bare refs in a metric re-cased', fails)
check(g[0, 2] == '[TOTALREV]', 'already-exact bare ref untouched', fails)
check(g[0, 3] == 'Coalesce([Userid], [USERID])',
      'cross-element bare ref (col on 2 elements) NOT re-cased — left for Lookup', fails)
check(g[0, 4] == 'If([ctl-region] = 1, [TOTALREV], 0)',
      'non-column bare token (control id) left verbatim; real bare col re-cased', fails)
check(g[0, 5] == '[Custom SQL/Totalrev]',
      'qualified:false leaves element-alias (slash) refs untouched on the DM path', fails)
check(g[1, 0] == '[PLANLINE]', 'bare ref re-cased on the secondary element too', fails)
check(rep3[:ambiguous].any? { |m| m.include?('multiple elements') },
      'cross-element bare ref is reported as ambiguous', fails)

# ── IDENTITY-ALIAS same-element bare-ref recase (issue #457) ─────────────────
# A calc that is an identity alias of its own raw column (`[Foo (copy)] = [Foo]`)
# surfaces the raw column under warehouse-readback casing (UPPERCASE "TOTALREV")
# AND the alias under Sigma's auto-generated display label — with the "(copy)"
# decoration stripped, that label collapses onto the raw column name in a different
# casing ("Totalrev"), so the two collide in normalization on THIS element. The
# alias's bare ref `[Totalrev]` then exact-matches the mixed-case auto-label and
# resolves to the alias ITSELF — a circular self-reference / type=error — and
# pre-#457 the exact-match short-circuit left it there. It must now recase to the
# raw readback casing (the mono-case candidate), never the mixed-case auto-label.
ia_reg = {
  'Rev Fact' => ['TOTALREV', 'Totalrev', 'USERID'] # raw UPPER + identity-alias title-case collide on norm(totalrev)
}
ia_els = [
  { 'name' => 'Rev Fact', 'columns' => [
    { 'id' => 'ia1', 'name' => 'Totalrev (copy)', 'formula' => '[Totalrev]' },        # bare identity-alias ref
    { 'id' => 'ia2', 'name' => 'Rev Share', 'formula' => 'Sum([Totalrev]) / 100' }    # same collision inside a metric
  ] }
]
rep4 = RefLabelRepair.repair!(ia_els, ia_reg, qualified: false, same_element_recase: true)
h = ->(j) { ia_els[0]['columns'][j]['formula'] }
check(h[0] == '[TOTALREV]',
      "identity-alias bare ref recased to raw readback casing, not the title-case auto-label (got #{h[0]})", fails)
check(h[1] == 'Sum([TOTALREV]) / 100',
      'identity-alias collision recased inside a metric too', fails)
check(rep4[:fixed] == 2, "both identity-alias refs counted as fixed (got #{rep4[:fixed]})", fails)
check(rep4[:ambiguous].empty?, "identity-alias recase is not left reported-ambiguous (got #{rep4[:ambiguous].inspect})", fails)
# Idempotent: re-running on the already-recased spec recases nothing and leaves the
# now-mono-case ref untouched (the raw candidate matches its own casing → no churn).
rep4b = RefLabelRepair.repair!(ia_els, ia_reg, qualified: false, same_element_recase: true)
check(h[0] == '[TOTALREV]' && rep4b[:fixed].zero?,
      "identity-alias recase is idempotent — second pass is a no-op (got #{h[0]}, fixed=#{rep4b[:fixed]})", fails)

# GUARD A — a GENUINE same-element ambiguity (two DISTINCT columns whose names
# collapse to one normalization but are NOT pure case variants — they differ by
# punctuation) is still refused: "Ship Mode" vs "SHIP_MODE" must never be guessed.
gd_reg = { 'Dim El' => ['Ship Mode', 'SHIP_MODE'] }
gd_els = [{ 'name' => 'Dim El', 'columns' => [{ 'id' => 'g1', 'formula' => '[ship mode]' }] }]
rep5 = RefLabelRepair.repair!(gd_els, gd_reg, qualified: false, same_element_recase: true)
check(gd_els[0]['columns'][0]['formula'] == '[ship mode]',
      'punct-differing distinct columns are NOT recased (real ambiguity preserved)', fails)
check(rep5[:ambiguous].any? { |m| m.include?('normalizes ambiguously') },
      'genuine same-element ambiguity is still reported', fails)

# GUARD B — pure-case collision but NO single mono-case candidate (both a raw-ish
# UPPER and a lower variant exist): we cannot tell which is authoritative, so refuse.
mc_reg = { 'Two El' => %w[FOO foo] }
mc_els = [{ 'name' => 'Two El', 'columns' => [{ 'id' => 'm1', 'formula' => '[Foo]' }] }]
rep6 = RefLabelRepair.repair!(mc_els, mc_reg, qualified: false, same_element_recase: true)
check(mc_els[0]['columns'][0]['formula'] == '[Foo]',
      'pure-case collision with no unique mono-case candidate is left untouched', fails)

# GUARD C — a same-element casing collision that ALSO exists cross-element stays a
# cross-element refusal (#407 multi-datasource-collapse guard wins over the #457
# recase): never silently collapse a should-be-Lookup ref into a same-element one.
xe_reg = {
  'Fact A' => ['SHARED', 'Shared'],  # pure-case collision on this element …
  'Fact B' => ['SHARED']             # … but the column also lives on another element
}
xe_els = [{ 'name' => 'Fact A', 'columns' => [{ 'id' => 'x1', 'formula' => '[Shared]' }] }]
rep7 = RefLabelRepair.repair!(xe_els, xe_reg, qualified: false, same_element_recase: true)
check(xe_els[0]['columns'][0]['formula'] == '[Shared]',
      'cross-element collision refused even when same-element labels are pure case variants', fails)

if fails.empty?
  puts 'test-ref-label-repair: ALL PASS'
else
  puts "test-ref-label-repair: #{fails.size} FAILURE(S)"
  fails.each { |f2| puts "  - #{f2}" }
  exit 1
end
