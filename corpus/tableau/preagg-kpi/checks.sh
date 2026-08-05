#!/usr/bin/env bash
# preagg-kpi — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. audit-lod-calcs.rb against the .twb census + the canned field-shaped
#      dm-spec fixture classifies the two {FIXED day : COUNTD} calcs exactly
#      as the CURRENT code does: "Daily Distinct Buyers" = suspect-alias
#      (emitted formula reads an unrelated raw flag column), "Daily Active
#      Sales" = silently-dropped → exit 2 + FATAL blocks.
#   2. assert-phase6-ran.rb gate 17 (exit 24) BLOCKS on the unresolved ledger
#      and PASSES once resolutions are recorded via --resolve — then gate 19
#      (exit 26) takes over: no agg-semantics.json on a workdir with LOD
#      evidence = the lint never ran.
#   3. THE PR-7 FLIP (this entry's reason to exist): audit-agg-semantics.rb
#      fires on the three SUM(preagg)/SUM(preagg) KPIs — the {FIXED day:
#      COUNTD} calcs consumed additively (class additive-over-preagg) and the
#      ratio KPIs (class preagg-ratio) — exit 2, entries pinned verbatim in
#      agg-semantics.entries.json. Gate 19 blocks until every hit records a
#      resolution (faithful-to-source documents the twin hazard; n/a is the
#      first-class does-not-apply path), then GREEN unblocks.
#   4. parse-twb-layout.rb reads the unsynchronized dual-axis combo worksheet
#      as chart_kind "bar" with dual_axis false — the KNOWN LIMITATION this
#      entry pins (no synchronized='true' in the twin shape); flipping this
#      pin is the acceptance signal for a dual-axis detection fix.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. LOD audit: suspect-alias + silently-dropped, exit 2 ------------------
cp "$CASE_DIR/workbook-content.twb" "$TMP/"
cp "$CASE_DIR/dm-spec.fixture.json" "$TMP/dm-spec.json"
ruby "$SCRIPTS/audit-lod-calcs.rb" --workdir "$TMP" >"$TMP/audit.out" 2>"$TMP/audit.err"
rc=$?
if [ "$rc" -eq 2 ] \
   && /usr/bin/grep -q 'LOD TRANSLATION FATAL' "$TMP/audit.err" \
   && /usr/bin/grep -q 'reads ACTIVE_BUYER_FLAG' "$TMP/audit.err" \
   && /usr/bin/grep -q 'silently-dropped.*Daily Active Sales' "$TMP/audit.err"; then
  note "ok: LOD audit blocks (exit 2): suspect-alias reads ACTIVE_BUYER_FLAG; Daily Active Sales silently-dropped"
else
  note "FAIL: LOD audit expected exit 2 + both FATAL classes (got $rc)"; sed -n '1,15p' "$TMP/audit.err"; fail=1
fi
ruby -rjson -e '
  got = JSON.parse(File.read(File.join(ARGV[0], "lod-audit.json")))["entries"]
  pin = JSON.parse(File.read(ARGV[1]))
  abort "ledger entries drifted from lod-audit.entries.json:\n#{JSON.pretty_generate(got)}" unless got == pin
' "$TMP" "$CASE_DIR/lod-audit.entries.json" \
  && note "ok: ledger classification matches the pinned lod-audit.entries.json (honest current-code output)" \
  || { note "FAIL: LOD ledger drifted from the pin"; fail=1; }

# -- 2. gate 17 blocks unresolved; once resolved, gate 19 takes over ---------
cat > "$TMP/parity-final.json" <<'JSON'
{
  "workbook_id": "wb-corpus-pak", "mode": "strict", "status": "PASS",
  "charts_total": 5, "charts_pass": 5, "charts_fail": 0,
  "pass_names": ["KPI Avg Amount", "KPI Sales per Active", "KPI Pct Earnings", "Amount vs Growth", "Weekly Forecast"],
  "fail_names": [],
  "visual_checked": true, "visual_verdict": "pass",
  "style_checklist": { "element_titles_hidden": "pass", "palette_match": "pass",
    "composition_match": "pass", "chart_shapes_match": "pass",
    "labels_legible": "pass", "numbers_formatted": "pass" },
  "agent_vision": true
}
JSON
{ printf '\x89PNG\r\n\x1a\n'; head -c 6000 /dev/zero; } > "$TMP/sigma-render.png"
# PR-9: gate 8b refuses a self-attested visual pass - install a hash-bound
# blind-grade fixture (source PNG + blind-grade.json + parity-final stamp).
ruby -r "$SCRIPTS/lib/blind_fixture" -e 'BlindFixture.install(ARGV[0])' "$TMP"

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate1.out" 2>"$TMP/gate1.err"
rc=$?
if [ "$rc" -eq 24 ] && /usr/bin/grep -q 'gate 17: LOD translation ledger unresolved' "$TMP/gate1.err"; then
  note "ok: gate 17 (exit 24) blocks GREEN on the unresolved suspect-alias/silently-dropped entries"
else
  note "FAIL: gate 17 expected exit 24 (got $rc)"; sed -n '1,12p' "$TMP/gate1.err"; fail=1
fi

ruby "$SCRIPTS/audit-lod-calcs.rb" --workdir "$TMP" --resolve 0 --how manual \
  --reason 'grouped helper element "Daily Buyer Rollup" (CAL_DATE grain, CountDistinct BUYER_KEY) authored by hand (corpus fixture evidence)' >>"$TMP/resolve.out" 2>&1
rc0=$?
ruby "$SCRIPTS/audit-lod-calcs.rb" --workdir "$TMP" --resolve 1 --how waived \
  --reason 'corpus operator: Daily Active Sales accepted-missing in the frozen fixture; PR-7/PR-5 flip this' >>"$TMP/resolve.out" 2>&1
rc1=$?
if [ "$rc0" -eq 2 ] && [ "$rc1" -eq 0 ]; then
  note "ok: --resolve records evidence (still exit 2 while one entry blocks; exit 0 once both resolved)"
else
  note "FAIL: --resolve sequence expected exits 2 then 0 (got $rc0 then $rc1)"; sed -n '1,10p' "$TMP/resolve.out"; fail=1
fi

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate2.out" 2>"$TMP/gate2.err"
rc=$?
if [ "$rc" -eq 26 ] && /usr/bin/grep -q 'no agg-semantics.json' "$TMP/gate2.err"; then
  note "ok: gate 17 resolved -> gate 19 (exit 26) now blocks: LOD evidence present but the agg-semantics lint never ran"
else
  note "FAIL: expected exit 26 (gate 19 belt-and-braces) after LOD resolutions (got $rc)"; sed -n '1,12p' "$TMP/gate2.err"; fail=1
fi

# -- 3. PR-7 flip: the aggregation-semantics lint fires on the KPI trap ------
# The three SUM(preagg)/SUM(preagg) KPI formulas — the shape that shipped a
# 103.3% ratio KPI in the field — now fire additive-over-preagg (the {FIXED
# day: COUNTD} calcs consumed additively) and preagg-ratio (the ratio KPIs),
# source-side AND on the dm-spec fixture's emitted Sum([preagg]) column.
ruby "$SCRIPTS/audit-agg-semantics.rb" --workdir "$TMP" >"$TMP/agg.out" 2>"$TMP/agg.err"
rc=$?
if [ "$rc" -eq 2 ] \
   && /usr/bin/grep -q 'AGGREGATION SEMANTICS WARN' "$TMP/agg.err" \
   && /usr/bin/grep -q 'additive-over-preagg.*Sales per Active' "$TMP/agg.out" \
   && /usr/bin/grep -q 'preagg-ratio.*Pct Buyers with Earnings' "$TMP/agg.out"; then
  note "ok: agg-semantics lint blocks (exit 2): SUM over the {FIXED day: COUNTD} pre-aggregates + ratio KPIs"
else
  note "FAIL: agg-semantics lint expected exit 2 + both classes (got $rc)"; sed -n '1,15p' "$TMP/agg.err"; fail=1
fi
ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse(File.read(File.join(ARGV[0], "agg-semantics.json")))["entries"])' \
  "$TMP" > "$TMP/agg-derived.json"
if cmp -s <(tr -d "\r" < "$TMP/agg-derived.json") <(tr -d "\r" < "$CASE_DIR/agg-semantics.entries.json"); then
  note "ok: lint hits match the pinned agg-semantics.entries.json verbatim"
else
  note "FAIL: agg-semantics entries drifted from the pin"
  diff <(tr -d "\r" < "$CASE_DIR/agg-semantics.entries.json") <(tr -d "\r" < "$TMP/agg-derived.json") | head -20
  fail=1
fi

# Resolutions: the twin's story is faithful-to-source (the SOURCE workbook
# itself consumes the day-grain pre-aggregates additively; the migration
# reproduces it and the ledger documents the hazard). The dm-spec duplicates
# of the same source hazard exercise the first-class n/a path.
n=$(ruby -rjson -e 'puts JSON.parse(File.read(File.join(ARGV[0], "agg-semantics.json")))["entries"].length' "$TMP")
i=0
agg_res_fail=0
while [ "$i" -lt "$n" ]; do
  ctx=$(ruby -rjson -e 'puts JSON.parse(File.read(File.join(ARGV[0], "agg-semantics.json")))["entries"][ARGV[1].to_i]["context"]' "$TMP" "$i")
  if [ "$ctx" = "source-calc" ]; then
    ruby "$SCRIPTS/audit-agg-semantics.rb" --workdir "$TMP" --resolve "$i" --how faithful-to-source \
      --reason 'source workbook itself sums the day-grain COUNTD pre-aggregates across grains; migrated faithfully — hazard documented (the 103.3%-KPI twin)' \
      >>"$TMP/agg-resolve.out" 2>&1
  else
    ruby "$SCRIPTS/audit-agg-semantics.rb" --workdir "$TMP" --resolve "$i" --how n/a \
      --reason 'duplicate of the source-calc hit on the same formula; hazard documented on the source entry' \
      >>"$TMP/agg-resolve.out" 2>&1
  fi
  rc=$?
  if [ "$i" -lt $((n - 1)) ] && [ "$rc" -ne 2 ]; then agg_res_fail=1; fi
  if [ "$i" -eq $((n - 1)) ] && [ "$rc" -ne 0 ]; then agg_res_fail=1; fi
  i=$((i + 1))
done
if [ "$agg_res_fail" -eq 0 ]; then
  note "ok: all $n hits resolved (faithful-to-source for the source KPIs, n/a for the emitted duplicates) — exit 2 while any blocks, 0 once done"
else
  note "FAIL: agg-semantics --resolve sequence (see $TMP/agg-resolve.out)"; sed -n '1,10p' "$TMP/agg-resolve.out"; fail=1
fi

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate3.out" 2>"$TMP/gate3.err"
rc=$?
if [ "$rc" -eq 0 ] \
   && /usr/bin/grep -q '\[OK\] gate 17: LOD translation ledger resolved' "$TMP/gate3.out" \
   && /usr/bin/grep -q '\[OK\] gate 19: aggregation-semantics ledger resolved' "$TMP/gate3.out"; then
  note "ok: gates 17 + 19 pass once both ledgers carry their resolutions"
else
  note "FAIL: expected exit 0 with gate 17 + gate 19 OK lines (got $rc)"; sed -n '1,12p' "$TMP/gate3.err"; fail=1
fi

# -- 4. dual-axis known-limitation pin ---------------------------------------
ruby "$SCRIPTS/parse-twb-layout.rb" "$CASE_DIR/workbook-content.twb" "$TMP/layout.json" >"$TMP/layout.out" 2>&1 || fail=1
ruby -rjson -e '
  zones = JSON.parse(File.read(ARGV[0])).flat_map { |d| d["zones"] || [] }
  combo = zones.find { |z| z["caption"] == "Amount vs Growth" }
  abort "combo zone missing" unless combo
  # KNOWN LIMITATION (pinned on purpose): the unsynchronized multi-pane
  # dual-axis shape reads as a plain bar with dual_axis false. A dual-axis
  # detection fix MUST flip this assertion.
  abort "combo now reads #{combo["chart_kind"].inspect}/dual_axis=#{combo["dual_axis"].inspect} — the known-limitation pin flipped; update MANIFEST + this check" \
    unless combo["chart_kind"] == "bar" && combo["dual_axis"] == false
  kpis = zones.select { |z| z["is_kpi"] }.map { |z| z["caption"] }.sort
  abort "KPI zones wrong: #{kpis.inspect}" unless kpis == ["KPI Avg Amount", "KPI Pct Earnings", "KPI Sales per Active"]
  forecast = zones.find { |z| z["caption"] == "Weekly Forecast" }
  abort "Weekly Forecast not line" unless forecast && forecast["chart_kind"] == "line"
' "$TMP/layout.json" \
  && note "ok: known-limitation pinned — dual-axis combo reads chart_kind=bar / dual_axis=false (3 KPI zones + line detected)" \
  || { note "FAIL: layout known-limitation pin"; fail=1; }

# -- 5. PR-18 integer-coded dimension detection + cardinality confirmation ----
# THE PR-18 FLIP (this entry's SITE_KEY reason to exist): parse-twb-layout marks
# the integer SITE_KEY quick filter integer_dim:true (was a documented, ungated
# gap), and the OPTIONAL warehouse-cardinality probe confirms it offline.
ruby -rjson -e '
  m = JSON.parse(File.read(ARGV[0]))
  fs = (m["worksheets"] || {}).values.flat_map { |w| w["filters"] || [] }
  sk = fs.find { |f| f["column_caption"] == "SITE_KEY" }
  abort "SITE_KEY filter missing from meta" unless sk
  abort "SITE_KEY not flagged integer_dim (got datatype=#{sk["datatype"].inspect} kind=#{sk["kind"].inspect} integer_dim=#{sk["integer_dim"].inspect})" \
    unless sk["datatype"] == "integer" && sk["integer_dim"] == true
  # a non-integer discrete filter must NOT be flagged (byte-identical guard)
  other = fs.find { |f| f["datatype"] == "string" && (f["kind"] || "") =~ /list/ }
  abort "a STRING list filter was wrongly flagged integer_dim" if other && other["integer_dim"]
' "$TMP/layout-meta.json" \
  && note "ok: PR-18 detection — SITE_KEY integer quick filter flagged integer_dim:true (string filters unflagged)" \
  || { note "FAIL: PR-18 integer_dim detection on SITE_KEY"; fail=1; }

# OPTIONAL cardinality confirmation, fixture (offline) mode — a low
# COUNT(DISTINCT SITE_KEY) corroborates the integer-coded DIMENSION reading.
cat > "$TMP/integer-dim-decode.json" <<'JSON'
{ "version": 1, "source": "tableau",
  "candidates": [ { "controlId": "ctl-site-key", "name": "SITE_KEY", "column": "SITE_KEY",
    "table": "DEMO_DB.ANALYTICS.SITE_DIM", "warehouse_column": "SITE_KEY" } ] }
JSON
ruby "$SCRIPTS/probe-int-dim-cardinality.rb" --workdir "$TMP" \
  --fixture "$CASE_DIR/probe-fixture-intdim" --max-cardinality 1000 >"$TMP/intdim.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ruby -rjson -e '
  c = JSON.parse(File.read(ARGV[0]))["candidates"].first
  abort "not confirmed: #{c.inspect}" unless c["cardinality"] == 12 && c["confirmed"] == true
' "$TMP/integer-dim-decode.json"; then
  note "ok: cardinality probe (fixture) confirms SITE_KEY low-cardinality (12) → integer-coded dimension"
else
  note "FAIL: PR-18 cardinality probe fixture confirmation (got exit $rc)"; sed -n '1,8p' "$TMP/intdim.out"; fail=1
fi

exit "$fail"
