#!/usr/bin/env ruby
# frozen_string_literal: true
# test-metrics-namespace.rb — W2.8: validate-spec.rb resolves the governed
# [Metrics/<name>] pseudo-namespace against the DM METRICS CENSUS.
#
# The field failure: metric_binding.rb (the DEFAULT emission path since #501)
# binds matching chart/KPI measures as [Metrics/<Metric Name>], but the
# validator knew only element prefixes — every governed-metrics workbook died
# with `prefix "Metrics" unknown` (a guaranteed exit-4 re-entry, field-
# measured). BOTH DIRECTIONS are pinned here:
#   admit  — a census metric name resolves (census from --dm-context element
#            metrics, the metrics.json sidecar, an explicit --metrics FILE,
#            the workbook's own local element metrics, or — for --type
#            datamodel — the DM spec's own metrics arrays);
#   reject — a bogus prefix ([Bogus/X]) still errors; a MISSING metric name
#            ([Metrics/Not A Metric], [Metrics/]) is a hard ERROR when the
#            census is present (adjudicated: error-when-checkable); and with
#            NO census anywhere the prefix stays unknown and errors exactly
#            as before (with a routing hint naming --metrics).
#
# Six-trajectory matrix:
#   T1 trip:     census present, name missing → hard ERROR listing the census
#                (Part E; empty-name variant Part F)
#   T2 trip:     bogus prefix [Bogus/X] unchanged near-miss (Part G)
#   T3 no-trip:  census names resolve via context / sidecar / --metrics /
#                local element metrics (Parts A-D)
#   T4 clear:    --type datamodel self-census admit + reject (Part I)
#   T5 contract: NO census anywhere → the pre-W2.8 unknown-prefix ERROR is
#                byte-compatible, plus a routing hint (Part H)
#   T6 degrade:  unparseable sidecar → WARN, never abort; validation proceeds
#                census-less (Part J)
#
# Usage:  ruby scripts/test-metrics-namespace.rb

require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

VALIDATE = File.join(__dir__, 'validate-spec.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A minimal workbook spec: one chart-ish table element sourcing a (DM-backed)
# master by elementId, with one measure column whose formula is `formula`.
def wb_spec(formula, extra_metrics: nil)
  el = {
    'id' => 'tbl-1', 'kind' => 'table', 'name' => 'Revenue Tile',
    'source' => { 'kind' => 'table', 'elementId' => 'master-1' },
    'columns' => [{ 'id' => 'c0', 'name' => 'Margin' },
                  { 'id' => 'c1', 'name' => 'Bound Measure', 'formula' => formula }]
  }
  el['metrics'] = extra_metrics if extra_metrics
  { 'schemaVersion' => 1, 'name' => 'metrics-ns-test', 'folderId' => 'folder-test',
    'pages' => [{ 'id' => 'pg-1', 'name' => 'P1', 'elements' => [el] }] }
end

# dm-context shaped like post-and-readback output; per-element metrics arrays
# are OPTIONAL (today's id-maps carry none — the sidecar covers that path).
def dm_context(with_metrics: nil)
  el = { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Rev Master' }
  el['metrics'] = with_metrics if with_metrics
  { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'dp1', 'name' => 'Data', 'elements' => [el] }] }
end

def run_validate(dir, spec, ctx: nil, args: [], type: 'workbook')
  spec_path = File.join(dir, 'wb-spec.json')
  File.write(spec_path, JSON.pretty_generate(spec))
  argv = [RbConfig.ruby, VALIDATE, '--type', type]
  if ctx
    ctx_path = File.join(dir, 'dm-ids.json')
    File.write(ctx_path, JSON.pretty_generate(ctx))
    argv += ['--dm-context', ctx_path]
  end
  out, err, st = Open3.capture3(*(argv + args + [spec_path]))
  [out + err, st.exitstatus]
end

GOV = [{ 'name' => 'Gross Revenue', 'formula' => 'Sum([Gross Revenue])' },
       { 'name' => 'Order Count',   'formula' => 'CountDistinct([Order Id])' }].freeze

puts 'Part A — ADMIT: census via --dm-context element metrics'
Dir.mktmpdir do |dir|
  out, code = run_validate(dir, wb_spec('[Metrics/Gross Revenue]'), ctx: dm_context(with_metrics: GOV))
  check(code == 0, "governed ref resolves against the context census (exit #{code})", fails)
  check(out.include?('0 errors'), 'zero errors reported', fails)
end

puts 'Part B — ADMIT: census via the metrics.json SIDECAR beside --dm-context (the orchestrated layout)'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'metrics.json'), JSON.pretty_generate(GOV))
  out, code = run_validate(dir, wb_spec('[Metrics/Order Count]'), ctx: dm_context) # id-map WITHOUT metrics
  check(code == 0, "sidecar census admits the governed ref (exit #{code})", fails)
  check(out.include?('0 errors'), 'zero errors with sidecar census', fails)
end

puts 'Part C — ADMIT: census via an explicit --metrics FILE'
Dir.mktmpdir do |dir|
  mpath = File.join(dir, 'my-metrics.json')
  File.write(mpath, JSON.pretty_generate('metrics' => GOV)) # wrapped shape accepted too
  _out, code = run_validate(dir, wb_spec('[Metrics/Gross Revenue]'), ctx: dm_context, args: ['--metrics', mpath])
  check(code == 0, "--metrics census admits the governed ref (exit #{code})", fails)
end

puts 'Part D — ADMIT: the workbook element\'s own local metrics count toward the census'
Dir.mktmpdir do |dir|
  spec = wb_spec('[Metrics/Local Margin]', extra_metrics: [{ 'name' => 'Local Margin', 'formula' => 'Avg([Margin])' }])
  _out, code = run_validate(dir, spec, ctx: dm_context)
  check(code == 0, "local element metric resolves (exit #{code})", fails)
end

puts 'Part E — REJECT: census present, metric name NOT in it → hard ERROR naming the census'
Dir.mktmpdir do |dir|
  out, code = run_validate(dir, wb_spec('[Metrics/Not A Metric]'), ctx: dm_context(with_metrics: GOV))
  check(code == 1, "census miss exits 1 (got #{code})", fails)
  check(out.include?('not in the DM metrics census'), 'error names the census miss', fails)
  check(out.include?('Gross Revenue') && out.include?('Order Count'), 'error lists the known metric names', fails)
end

puts 'Part F — REJECT: empty metric name ([Metrics/]) with census present'
Dir.mktmpdir do |dir|
  out, code = run_validate(dir, wb_spec('[Metrics/]'), ctx: dm_context(with_metrics: GOV))
  check(code == 1, "empty metric name exits 1 (got #{code})", fails)
  check(out.include?('(empty name)'), 'error states the empty name', fails)
end

puts 'Part G — REJECT: bogus prefix unchanged (near-miss trajectory)'
Dir.mktmpdir do |dir|
  out, code = run_validate(dir, wb_spec('[Bogus/Gross Revenue]'), ctx: dm_context(with_metrics: GOV))
  check(code == 1, "[Bogus/X] still exits 1 (got #{code})", fails)
  check(out.include?('prefix "Bogus" unknown'), 'bogus prefix still errors as unknown', fails)
end

puts 'Part H — NO census anywhere → unchanged unknown-prefix ERROR, with the routing hint'
Dir.mktmpdir do |dir|
  out, code = run_validate(dir, wb_spec('[Metrics/Gross Revenue]'), ctx: dm_context) # no metrics, no sidecar
  check(code == 1, "no census → still exit 1 (got #{code})", fails)
  check(out.include?('prefix "Metrics" unknown'), 'unknown-prefix error preserved', fails)
  check(out.include?('--metrics'), 'error hints at the census routing (--metrics / sidecar)', fails)
end

puts 'Part I — --type datamodel: the DM spec\'s OWN metrics arrays are the census'
Dir.mktmpdir do |dir|
  dm = { 'schemaVersion' => 1, 'name' => 'dm-metrics-test', 'folderId' => 'folder-test',
         'pages' => [{ 'id' => 'pg-1', 'name' => 'Data', 'elements' => [
           { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Rev Master',
             'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB S REV_MASTER] },
             'metrics' => [{ 'name' => 'Net Revenue', 'formula' => 'Sum([Net Revenue])' }],
             'columns' => [{ 'id' => 'c1', 'name' => 'NR Ref', 'formula' => '[Metrics/Net Revenue]' }] }
         ] }] }
  _out, code = run_validate(dir, dm, type: 'datamodel')
  check(code == 0, "DM self-census admits [Metrics/Net Revenue] (exit #{code})", fails)
  dm['pages'][0]['elements'][0]['columns'][0]['formula'] = '[Metrics/Ghost Metric]'
  out, code = run_validate(dir, dm, type: 'datamodel')
  check(code == 1 && out.include?('not in the DM metrics census'), 'DM self-census rejects a ghost metric', fails)
end

puts 'Part J — sidecar present but UNPARSEABLE → WARN (not abort), census-less behavior'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'metrics.json'), '{not json')
  out, code = run_validate(dir, wb_spec('[Metrics/Gross Revenue]'), ctx: dm_context)
  check(code == 1, "bad sidecar → validation still runs, ref still errors (exit #{code})", fails)
  check(out.include?('WARN') && out.include?('metrics sidecar'), 'bad sidecar surfaced as a WARN', fails)
end

# ── F4 (wave-2 measurement): same-element column/metric NAME COLLISION ──────
# A collision-shaped element (a governed metric named identically to one of
# the element's own columns) POSTs fine, but the live readback omits its
# metrics WHOLESALE — so NONE of them are census-admissible: the validator
# must agree with the binder (lib/metric_binding.rb withholds the same set)
# and reject a [Metrics/<name>] ref to any of them PRE-POST, naming the
# collision. Structural detection only (exact same-element name equality).

puts 'Part K — F4 REJECT: dm-context element carries a column/metric name collision → its metrics are NOT census-admissible'
Dir.mktmpdir do |dir|
  ctx = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'dp1', 'name' => 'Data', 'elements' => [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Freight Fact',
      'columns' => [{ 'id' => 'fc1', 'name' => 'Linehaul Cost' }, { 'id' => 'fc2', 'name' => 'Depot' }],
      'metrics' => [{ 'name' => 'Linehaul Cost', 'formula' => 'Sum([Linehaul Cost])' },
                    { 'name' => 'Blended Fill Rate', 'formula' => 'Sum([Filled Lines]) / Count([Order Lines])' }] }
  ] }] }
  # the ratio metric does NOT itself collide — it rides the collision-shaped
  # element, which is exactly the field-caught F4 casualty shape
  out, code = run_validate(dir, wb_spec('[Metrics/Blended Fill Rate]'), ctx: ctx)
  check(code == 1, "ref to a metric riding a collision-shaped element exits 1 (got #{code})", fails)
  check(out.include?('F4 collision shape'), 'error names the F4 collision shape', fails)
  check(out.include?('Freight Fact'), 'error names the collision-shaped element', fails)
  check(out =~ /WARN.*collision/i, 'census exclusion surfaced as a WARN too', fails)
end

puts 'Part L — F4 REJECT: the workbook\'s OWN local element with a collision → local metrics not admissible'
Dir.mktmpdir do |dir|
  el = {
    'id' => 'tbl-1', 'kind' => 'table', 'name' => 'Damage Tile',
    'source' => { 'kind' => 'table', 'elementId' => 'master-1' },
    'columns' => [{ 'id' => 'c0', 'name' => 'Damaged Units' },
                  { 'id' => 'c1', 'name' => 'Bound Measure', 'formula' => '[Metrics/Damaged Units]' }],
    'metrics' => [{ 'name' => 'Damaged Units', 'formula' => 'Sum([Damaged Units])' }]
  }
  spec = { 'schemaVersion' => 1, 'name' => 'metrics-ns-test', 'folderId' => 'folder-test',
           'pages' => [{ 'id' => 'pg-1', 'name' => 'P1', 'elements' => [el] }] }
  out, code = run_validate(dir, spec, ctx: dm_context(with_metrics: GOV))
  check(code == 1 && out.include?('F4 collision shape'),
        "local collision-shaped element's metric rejected with the F4 error (exit #{code})", fails)
end

puts 'Part M — F4 NO-TRIP: disjoint column/metric names on the same element stay admissible'
Dir.mktmpdir do |dir|
  ctx = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'dp1', 'name' => 'Data', 'elements' => [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Freight Fact',
      'columns' => [{ 'id' => 'fc1', 'name' => 'Linehaul Cost' }, { 'id' => 'fc2', 'name' => 'Depot' }],
      'metrics' => [{ 'name' => 'Total Linehaul', 'formula' => 'Sum([Linehaul Cost])' }] }
  ] }] }
  out, code = run_validate(dir, wb_spec('[Metrics/Total Linehaul]'), ctx: ctx)
  check(code == 0, "clean element (columns present, names disjoint) still admits its metrics (exit #{code})", fails)
  check(!out.match?(/WARN.*collision/i), 'no collision WARN on a clean element', fails)
end

puts 'Part N — F4 on --type datamodel: the DM spec\'s own collision shape is surfaced pre-POST'
Dir.mktmpdir do |dir|
  dm = { 'schemaVersion' => 1, 'name' => 'dm-metrics-test', 'folderId' => 'folder-test',
         'pages' => [{ 'id' => 'pg-1', 'name' => 'Data', 'elements' => [
           { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Freight Fact',
             'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB S FREIGHT_FACT] },
             'columns' => [{ 'id' => 'c1', 'name' => 'Linehaul Cost' }],
             'metrics' => [{ 'name' => 'Linehaul Cost', 'formula' => 'Sum([Linehaul Cost])' }] }
         ] }] }
  out, code = run_validate(dir, dm, type: 'datamodel')
  check(code == 0, "collision shape alone (nothing references it) is a WARN, not an error (exit #{code})", fails)
  check(out =~ /WARN.*collision/i, 'DM self-validation WARNs about the collision shape', fails)
  dm['pages'][0]['elements'][0]['columns'] << { 'id' => 'c2', 'name' => 'LC Ref', 'formula' => '[Metrics/Linehaul Cost]' }
  out, code = run_validate(dir, dm, type: 'datamodel')
  check(code == 1 && out.include?('F4 collision shape'),
        'a DM-internal ref to the collision-shaped metric errors pre-POST', fails)
end

puts 'Part O — F4 PRECEDENCE: a STALE metrics.json sidecar cannot re-admit a withheld name (structural exclusion wins)'
Dir.mktmpdir do |dir|
  ctx = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'dp1', 'name' => 'Data', 'elements' => [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Freight Fact',
      'columns' => [{ 'id' => 'fc1', 'name' => 'Linehaul Cost' }],
      'metrics' => [{ 'name' => 'Linehaul Cost', 'formula' => 'Sum([Linehaul Cost])' },
                    { 'name' => 'Blended Fill Rate', 'formula' => 'Sum([Filled Lines]) / Count([Order Lines])' }] }
  ] }] }
  # Every PRE-fix workdir carries exactly this hazard: the binder wrote ALL of
  # the element's metric names to the sidecar before it learned to withhold
  # the collision shape. The flat census hit must NOT beat the structural
  # exclusion (review-demonstrated: it used to — exit 0 with the sidecar
  # present, exit 1 with it removed).
  File.write(File.join(dir, 'metrics.json'),
             JSON.pretty_generate([{ 'name' => 'Linehaul Cost', 'formula' => 'Sum([Linehaul Cost])' },
                                   { 'name' => 'Blended Fill Rate', 'formula' => 'Sum([Filled Lines]) / Count([Order Lines])' }]))
  out, code = run_validate(dir, wb_spec('[Metrics/Blended Fill Rate]'), ctx: ctx)
  check(code == 1, "stale sidecar census does NOT re-admit the withheld ref (exit #{code})", fails)
  check(out.include?('F4 collision shape'), 'the F4-specific error wins over the flat-census hit', fails)
end

puts 'Part P — F4 SCOPE (orchestrated shape): dm-ids readback context carries no columns/metrics → prevention rides the binder-FILTERED sidecar (census MISS, not the F4 branch)'
Dir.mktmpdir do |dir|
  # The orchestrator passes post-and-readback's id-map as --dm-context; its
  # elements carry id/name/kind/columnLabels ONLY, so structural collision
  # detection has nothing to see BY DESIGN. In that flow the fixed binder
  # writes metrics.json already filtered — a withheld name is simply absent,
  # and a ref to it is a census MISS (generic message, still a hard error);
  # the post-POST ref gate stays fail-closed behind it.
  ctx = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'dp1', 'name' => 'Data', 'elements' => [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Freight Fact',
      'columnLabels' => ['Linehaul Cost', 'Depot'] }
  ] }] }
  File.write(File.join(dir, 'metrics.json'),
             JSON.pretty_generate([{ 'name' => 'Depot Count', 'formula' => 'CountDistinct([Depot])' }]))
  out, code = run_validate(dir, wb_spec('[Metrics/Blended Fill Rate]'), ctx: ctx)
  check(code == 1, "withheld ref against the filtered sidecar is still a hard error (exit #{code})", fails)
  check(out.include?('not in the DM metrics census') && !out.include?('F4 collision shape'),
        'errors as a census MISS (the F4 branch cannot see readback-shaped contexts)', fails)
  out2, code2 = run_validate(dir, wb_spec('[Metrics/Depot Count]'), ctx: ctx)
  check(code2 == 0 && out2.include?('0 errors'), "binder-admitted name still validates clean (exit #{code2})", fails)
end

puts 'Part Q — F4 NO-TRIP: a name excluded on one element but carried by a CLEAN element stays admissible (binder parity)'
Dir.mktmpdir do |dir|
  ctx = { 'dataModelId' => 'dm-1', 'pages' => [{ 'id' => 'dp1', 'name' => 'Data', 'elements' => [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Freight Fact',
      'columns' => [{ 'id' => 'fc1', 'name' => 'Linehaul Cost' }],
      'metrics' => [{ 'name' => 'Linehaul Cost', 'formula' => 'Sum([Linehaul Cost])' },
                    { 'name' => 'Blended Fill Rate', 'formula' => 'Sum([Filled Lines]) / Count([Order Lines])' }] },
    { 'id' => 'el-view', 'kind' => 'table', 'name' => 'Lane View',
      'columns' => [{ 'id' => 'vc1', 'name' => 'Depot' }],
      'metrics' => [{ 'name' => 'Blended Fill Rate', 'formula' => 'Sum([Filled Lines]) / Count([Order Lines])' }] }
  ] }] }
  out, code = run_validate(dir, wb_spec('[Metrics/Blended Fill Rate]'), ctx: ctx)
  check(code == 0, "clean element's same-named metric keeps the ref admissible (exit #{code})", fails)
  check(out =~ /WARN.*collision/i, 'the collision-shaped element is still WARNed', fails)
  out2, code2 = run_validate(dir, wb_spec('[Metrics/Linehaul Cost]'), ctx: ctx)
  check(code2 == 1 && out2.include?('F4 collision shape'),
        'a name riding ONLY the collision-shaped element still hard-errors', fails)
end

puts
if fails.empty?
  puts 'test-metrics-namespace: ALL PASS'
else
  puts "test-metrics-namespace: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
