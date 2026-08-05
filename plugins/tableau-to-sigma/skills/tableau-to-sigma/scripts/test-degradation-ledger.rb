#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for scripts/lib/degradation_ledger.rb (PLAN-v3 PR-14) — the
# cumulative-degradation accounting behind the GREEN / YELLOW / PARTIAL
# verdict model. Each artifact class is derived from fixtures in a scratch
# workdir; the verdict matrix is exercised directly. Fully offline.
#
# Usage: ruby scripts/test-degradation-ledger.rb
require 'json'
require 'tmpdir'
require_relative 'lib/degradation_ledger'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def classes(entries)
  entries.map { |e| e['class'] }.sort.uniq
end

def items(entries)
  entries.map { |e| e['item'] }
end

# ---- empty workdir → empty ledger → GREEN ------------------------------------
Dir.mktmpdir do |wd|
  entries = DegradationLedger.derive(wd)
  check(entries == [], 'empty workdir derives an empty ledger', fails)
  check(DegradationLedger.verdict(entries) == 'GREEN', 'empty ledger → GREEN', fails)
end

# ---- scope-cut: coverage.json dropped + degraded (approximated is NOT a cut) -
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'coverage.json'), JSON.pretty_generate(
    'summary' => { 'sourceVisuals' => 3, 'dropped' => 1, 'degraded' => 1, 'approximated' => 1 },
    'unresolved' => [
      { 'visual' => 'Region Map', 'severity' => 'dropped', 'detail' => 'no basemap support' },
      { 'visual' => 'Trend', 'severity' => 'degraded', 'detail' => 'lost column Forecast' },
      { 'visual' => 'Treemap', 'severity' => 'approximated', 'detail' => 'built as bar' }
    ]))
  entries = DegradationLedger.derive(wd)
  cuts = entries.select { |e| e['class'] == 'scope-cut' }
  check(cuts.length == 2, "coverage.json dropped+degraded → 2 scope-cuts (got #{cuts.length})", fails)
  check(items(cuts).any? { |i| i.include?('Region Map') } && items(cuts).any? { |i| i.include?('Trend') },
        'scope-cuts name the dropped visual and the degraded (lost-column) visual', fails)
  check(items(entries).none? { |i| i.include?('Treemap') },
        'an approximated visual (carried over) is NOT a scope cut', fails)
  check(DegradationLedger.verdict(entries) == 'PARTIAL', 'coverage drop → PARTIAL', fails)
end

# ---- scope-cut: distinct degradations under one generic `visual` label -------
# Field-observed (e2e twin B/B3 coverage.json): several degraded rows carry the
# same generic visual label ("field/calc") and differ only in their detail —
# each is a distinct recorded degradation and every one must reach the ledger.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'coverage.json'), JSON.pretty_generate(
    'summary' => { 'sourceVisuals' => 3, 'degraded' => 3 },
    'unresolved' => [
      { 'visual' => 'field/calc', 'severity' => 'degraded',
        'detail' => "no master column matched dim header 'Order Date (Level)' for 'Weekly Deposits Trend'" },
      { 'visual' => 'field/calc', 'severity' => 'degraded',
        'detail' => "no master column matched dim header 'Order Date (Level)' for 'Risk Score Trend'" },
      { 'visual' => 'field/calc', 'severity' => 'degraded',
        'detail' => "no master column matched dim header 'Category' for 'Legend Notes'" }
    ]))
  entries = DegradationLedger.derive(wd)
  cuts = entries.select { |e| e['class'] == 'scope-cut' }
  check(cuts.length == 3,
        "3 degraded rows sharing one generic visual label derive 3 scope-cuts (got #{cuts.length})", fails)
  # True duplicates (same class+item+reason+source) still dedupe to one entry.
  dup = cuts.first
  check(DegradationLedger.derive(wd).uniq { |e| e } .length == 3 &&
        (entries + [dup]).uniq { |e| [e['class'], e['item'], e['reason'], e['source_artifact']] }.length == entries.length,
        'identical entries still dedupe (reason participates in the key)', fails)
end

# ---- scope-cut: tile census unmatched zones, minus the visual-verify oracle --
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'parity-final.json'), JSON.pretty_generate(
    'tile_census' => { 'zones_total' => 3, 'charts_built' => 1, 'zones_unmatched' => 2,
                       'unmatched_zone_names' => ['Lost Tile', 'Oracle Tile'] }))
  Dir.mkdir(File.join(wd, 'visual-verify'))
  File.write(File.join(wd, 'visual-verify', 'manifest.json'), JSON.pretty_generate(
    [{ 'worksheet' => 'Oracle Tile', 'visual_verified' => true }]))
  entries = DegradationLedger.derive(wd)
  check(entries.length == 1 && entries[0]['item'] == 'dropped tile: Lost Tile',
        'tile census → scope-cut per unmatched zone, oracle-matched zones exempt', fails)
  check(DegradationLedger.verdict(entries) == 'PARTIAL', 'dropped tile → PARTIAL', fails)
end

# ---- scope-cut: controls census (dropped-declared + ledger-waived) -----------
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'x-controls-coverage.json'), JSON.pretty_generate(
    'detail' => [{ 'kind' => 'parameter', 'name' => 'Top N', 'status' => 'emitted' },
                 { 'kind' => 'filter', 'name' => 'Region', 'status' => 'unbuilt' },
                 { 'kind' => 'filter', 'name' => 'Segment', 'status' => 'unbuilt' }]))
  File.write(File.join(wd, 'control-scope.json'), JSON.pretty_generate(
    'controls' => [], 'dropped' => [{ 'name' => 'Region', 'reason' => 'unreachable root' }]))
  File.write(File.join(wd, 'controls-waivers.json'), JSON.pretty_generate(
    [{ 'control' => 'filter:Segment', 'reason' => 'single-value in source data' }]))
  entries = DegradationLedger.derive(wd)
  cuts = entries.select { |e| e['class'] == 'scope-cut' }
  check(cuts.length == 2, "controls census → 2 dropped-control scope-cuts (got #{cuts.length})", fails)
  check(items(cuts).none? { |i| i.include?('Top N') }, 'an emitted control is never a scope cut', fails)
  region = cuts.find { |e| e['item'].include?('Region') }
  segment = cuts.find { |e| e['item'].include?('Segment') }
  check(region && region['reason'].include?('unreachable root'),
        'dropped control carries its control-scope.json reason', fails)
  check(segment && segment['reason'].include?('single-value'),
        'waived control carries its controls-waivers.json reason', fails)
end

# ---- scope-cut: declaration files stand alone when no census exists ----------
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'control-scope.json'), JSON.pretty_generate(
    'dropped' => ['Category']))
  File.write(File.join(wd, 'controls-waivers.json'), JSON.pretty_generate(
    'waivers' => [{ 'name' => 'Ship Mode', 'reason' => 'operator waived' }]))
  entries = DegradationLedger.derive(wd)
  check(entries.length == 2 && classes(entries) == ['scope-cut'],
        'control-scope dropped + controls-waivers entries derive without a census', fails)
end

# ---- scope-cut: deferred DM elements -----------------------------------------
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'deferred-elements.json'), JSON.pretty_generate(
    'deferred' => [{ 'name' => 'Broken Element' }]))
  entries = DegradationLedger.derive(wd)
  check(entries.length == 1 && entries[0]['item'] == 'dropped DM element: Broken Element',
        'deferred-elements.json → scope-cut per quarantined element', fails)
end

# ---- quality-waiver: the stamped census, minus policy + derived flags --------
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'parity-final.json'), JSON.pretty_generate(
    'waivers' => ['--skip-anchors-gate',
                  '--skip-visual-comparison', 'visual-divergent', '--force-new-workbook'],
    'waiver_count' => 4,
    'waiver_reasons' => { '--skip-anchors-gate' => 'source PNG untranscribable',
                          '--skip-visual-comparison' => 'verifier session records the verdict' },
    'visual_verdict' => 'divergent'))
  entries = DegradationLedger.derive(wd)
  qw = entries.select { |e| e['class'] == 'quality-waiver' }
  check(qw.length == 1 && qw[0]['item'] == '--skip-anchors-gate',
        'census → quality-waiver entries; verifier-split comparison excluded', fails)
  check(qw[0]['reason'].include?('untranscribable'), 'quality waiver carries its recorded reason', fails)
  fr = entries.select { |e| e['class'] == 'fidelity-residual' }
  check(fr.length == 1 && fr[0]['item'].include?('divergent'),
        'divergent visual verdict → fidelity-residual (not quality-waiver)', fails)
  re = entries.select { |e| e['class'] == 'recorded-escape' }
  check(re.length == 1 && re[0]['item'] == '--force-new-workbook',
        'census run off-ramp flag → recorded-escape', fails)
  check(DegradationLedger.verdict(entries) == 'YELLOW', 'waivers without scope cuts → YELLOW', fails)
end

# ---- recorded-escape: offramps.jsonl (the --skip-ref-check fix) --------------
Dir.mktmpdir do |wd|
  File.open(File.join(wd, 'offramps.jsonl'), 'a') do |f|
    f.puts(JSON.generate('kind' => 'skip-flag-waived', 'reason' => 'refs known-unresolvable',
                         'detail' => '--skip-ref-check'))
    f.puts(JSON.generate('kind' => 'doctor-gate-waived', 'reason' => 'CI'))
    f.puts(JSON.generate('kind' => 'pass1-stop', 'detail' => 'informational — not an escape'))
  end
  entries = DegradationLedger.derive(wd)
  re = entries.select { |e| e['class'] == 'recorded-escape' }
  check(re.length == 2, "escape offramp kinds → recorded-escape entries (got #{re.length})", fails)
  check(items(re).include?('--skip-ref-check'),
        'a skip-flag-waived record surfaces under its flag name (--skip-ref-check is visible)', fails)
  check(items(entries).none? { |i| i.include?('pass1-stop') },
        'observability offramp kinds (pass1-stop) are not escapes', fails)
  check(DegradationLedger.verdict(entries) == 'YELLOW', 'recorded escapes → YELLOW, never GREEN', fails)
end

# ---- fidelity-residual: RCF residuals, arrangement WARNs, kind waivers -------
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'fidelity-ledger.json'), JSON.pretty_generate(
    'pass' => 2, 'entries' => [
      { 'id' => 'f1', 'cls' => 'spec-fixable', 'dimension' => 'palette', 'delta' => 'royal blue vs brand', 'resolved' => false },
      { 'id' => 'f2', 'cls' => 'spec-fixable', 'dimension' => 'kpi', 'delta' => 'fixed', 'resolved' => true }
    ]))
  File.write(File.join(wd, 'layout-arrangement.json'), JSON.pretty_generate(
    'pages' => [{ 'page' => 'Overview', 'violations' => ['controls-shelf class mismatch (top vs sidebar)'] }]))
  File.write(File.join(wd, 'png-read.json'), JSON.pretty_generate(
    'kind_waivers' => [{ 'tile' => 'Donut', 'reason' => 'Sigma pie substitution' }]))
  entries = DegradationLedger.derive(wd)
  fr = entries.select { |e| e['class'] == 'fidelity-residual' }
  check(fr.length == 3, "unresolved RCF + arrangement WARN + kind waiver → 3 fidelity-residuals (got #{fr.length})", fails)
  check(items(fr).any? { |i| i.include?('f1') } && items(entries).none? { |i| i.include?('f2') },
        'resolved RCF entries are excluded; unresolved ride', fails)
  check(DegradationLedger.verdict(entries) == 'YELLOW', 'fidelity residuals → YELLOW', fails)
end

# ---- resolution-waived: lod / join / agg / manual residues / coverage waivers -
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'lod-audit.json'), JSON.pretty_generate(
    'entries' => [
      { 'calc' => 'Entities Fixed', 'class' => 'silently-dropped',
        'resolution' => { 'how' => 'waived', 'reason' => 'not plotted anywhere' } },
      { 'calc' => 'Handled', 'class' => 'suspect-alias',
        'resolution' => { 'how' => 'manual', 'reason' => 'rebuilt by hand' } }
    ]))
  File.write(File.join(wd, 'join-plan.json'), JSON.pretty_generate(
    'entries' => [{ 'left' => 'ORDERS', 'right' => 'RETURNS', 'status' => 'non-unique',
                    'resolution' => { 'how' => 'waived', 'reason' => 'operator accepted' } },
                  { 'left' => 'ORDERS', 'right' => 'DATES', 'status' => 'unique' }]))
  File.write(File.join(wd, 'agg-semantics.json'), JSON.pretty_generate(
    'entries' => [{ 'calc' => 'Pct KPI', 'resolution' => { 'how' => 'faithful-to-source', 'reason' => 'source mixes grains' } },
                  { 'calc' => 'Other', 'resolution' => { 'how' => 'n/a', 'reason' => 'does not apply' } }]))
  File.write(File.join(wd, 'manual-residues.json'), JSON.pretty_generate(
    'residues' => [{ 'calc' => 'Running Total', 'status' => 'unbuilt' },
                   { 'calc' => 'Rank', 'status' => 'built' }]))
  File.write(File.join(wd, 'source-anchors.json'), JSON.pretty_generate(
    'anchors' => [], 'coverage_waivers' => [{ 'tile' => 'Legend Box', 'reason' => 'no printed value' }]))
  File.write(File.join(wd, 'ground-truth-plan.json'), JSON.pretty_generate(
    'coverage_waivers' => [{ 'tile' => 'Static Text', 'reason' => 'non-numeric tile' }]))
  entries = DegradationLedger.derive(wd)
  rw = entries.select { |e| e['class'] == 'resolution-waived' }
  check(rw.length == 6, "waived lod + waived join + faithful agg + unbuilt residue + 2 coverage waivers → 6 (got #{rw.length}: #{items(rw).join(' | ')})", fails)
  check(items(rw).none? { |i| i.include?('Handled') }, 'a manual (fixed) LOD resolution is not a degradation', fails)
  check(items(rw).none? { |i| i.include?('Other') }, "an n/a agg resolution is not a degradation", fails)
  check(items(rw).none? { |i| i.include?('Rank') }, 'a built residue is not a degradation', fails)
  check(DegradationLedger.verdict(entries) == 'YELLOW', 'resolution waivers → YELLOW', fails)
end

# ---- verdict matrix ----------------------------------------------------------
cut  = { 'class' => 'scope-cut', 'item' => 'dropped tile: X', 'reason' => 'r', 'source_artifact' => 'a' }
qw   = { 'class' => 'quality-waiver', 'item' => '--skip-anchors-gate', 'reason' => 'r', 'source_artifact' => 'a' }
check(DegradationLedger.verdict([]) == 'GREEN', 'matrix: clean → GREEN', fails)
check(DegradationLedger.verdict([qw, qw, qw]) == 'YELLOW', 'matrix: quality waivers only → YELLOW', fails)
check(DegradationLedger.verdict([cut]) == 'PARTIAL', 'matrix: 1 dropped tile + 0 waivers → PARTIAL', fails)
check(DegradationLedger.verdict([cut, qw]) == 'PARTIAL+YELLOW', 'matrix: both → PARTIAL+YELLOW (PARTIAL dominant)', fails)
check(DegradationLedger.verdict([], budget_exceeded: true) == 'YELLOW',
      'matrix: budget-exceeded run is always at least YELLOW', fails)
check(DegradationLedger.verdict([cut], budget_exceeded: true) == 'PARTIAL+YELLOW',
      'matrix: budget-exceeded + scope cut → PARTIAL+YELLOW', fails)

# ---- write() round-trips + counts --------------------------------------------
Dir.mktmpdir do |wd|
  DegradationLedger.write(wd, [cut, qw])
  doc = JSON.parse(File.read(DegradationLedger.ledger_path(wd)))
  check(doc['entries'].length == 2 && doc['counts'] == { 'scope-cut' => 1, 'quality-waiver' => 1 },
        'write() persists entries + per-class counts', fails)
  check(DegradationLedger.report_lines([cut]).first.include?('[scope-cut] dropped tile: X'),
        'report_lines renders one line per entry with its class', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — degradation ledger derivation (every artifact class) + verdict matrix'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
