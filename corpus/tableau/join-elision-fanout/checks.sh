#!/usr/bin/env bash
# join-elision-fanout — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. scan-workbook-gaps.rb detects the INDEPENDENT multi-datasource shape
#      (fact datasource + the published Reference Notes stub) and writes the
#      multi-ds-plan.json routing table — the converter would collapse to the
#      primary and silently drop the second source.
#   2. lib/join_plan.rb captures the LEFT JOIN in the ledger (join_type left,
#      flag key) — the "looks removable" join is ON RECORD before anyone
#      considers deleting it.
#   3. probe-join-keys.rb --fixture proves the flag key NON-UNIQUE (6 rows
#      over 2 keys) → exit 2 FATAL: the LEFT JOIN is NOT a provable no-op;
#      eliding it (or keeping it) without measurement risks fan-out.
#   4. parse-twb-layout.rb preserves the two trend worksheets as chart_kind
#      "line" in the layout signals (the field regression shipped bars).
#   5. probe-equivalence.rb (PR-8) measures the elision itself: before (join
#      kept, fanned out to 26 rows over 8 grain keys) vs after (join dropped,
#      8 rows) → match:false, exit 2 FATAL naming BOTH sides' numbers, and a
#      semantic-edits.json entry that blocks GREEN via gate 20 (exit 27).
#      The field agent's "provably no-op" claim is mechanically REFUTED.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. gap scan: independent multi-datasource detected ----------------------
ruby "$SCRIPTS/scan-workbook-gaps.rb" "$CASE_DIR/workbook-content.twb" "$TMP/gaps-report.md" >"$TMP/gaps.out" 2>&1 || fail=1
ruby -rjson -e '
  plan = JSON.parse(File.read(File.join(ARGV[0], "multi-ds-plan.json")))
  abort "multi-ds-plan not independent" unless plan["independent"] == true
  ds = plan["datasources"]
  abort "expected 2 datasources, got #{ds.length}" unless ds.length == 2
  fact  = ds.find { |d| d["caption"] == "Channel Activity Monitor" }
  notes = ds.find { |d| d["caption"] == "Reference Notes" }
  abort "fact datasource missing/mis-routed" unless fact && fact["table"] == "DEMO_DB.ANALYTICS.SALES_FACT" && fact["worksheets"].length == 4
  abort "published stub missing/mis-flagged" unless notes && notes["sqlproxy"] == true && notes["worksheets"] == ["Reference Notes"]
  gaps = JSON.parse(File.read(File.join(ARGV[0], "gaps-report.json")))
  abort "gaps JSON lacks multi_datasource detail" unless gaps["multi_datasource"].is_a?(Array) && gaps["multi_datasource"].length == 2
' "$TMP" && note "ok: gap scan detects 2 INDEPENDENT datasources (fact + published stub) and writes multi-ds-plan.json" \
  || { note "FAIL: multi-datasource detection wrong"; fail=1; }

# -- 2. join ledger captures the LEFT JOIN -----------------------------------
ruby -rjson -I "$SCRIPTS/lib" -r join_plan -e '
  xml = File.read(ARGV[0], encoding: "UTF-8")
  entries = JoinPlan.derive(nil, xml)
  File.write(ARGV[1], JSON.pretty_generate(entries) + "\n")
' "$CASE_DIR/workbook-content.twb" "$TMP/derived.json" || fail=1
if cmp -s <(tr -d "\r" < "$TMP/derived.json") <(tr -d "\r" < "$CASE_DIR/join-plan.entries.json"); then
  note "ok: join ledger pins the LEFT JOIN (SALES_FACT -> SEGMENT_DIM on CURRENT_FLAG, join_type left)"
else
  note "FAIL: join-plan derivation drifted from join-plan.entries.json:"
  diff <(tr -d "\r" < "$CASE_DIR/join-plan.entries.json") <(tr -d "\r" < "$TMP/derived.json") | head -20
  fail=1
fi

# -- 3. probe: the flag key is NON-UNIQUE → deletion is NOT provably no-op ---
ruby -rjson -I "$SCRIPTS/lib" -r join_plan -e '
  JoinPlan.write(ARGV[1], JSON.parse(File.read(ARGV[0])))
' "$CASE_DIR/join-plan.entries.json" "$TMP/join-plan.json" || fail=1
ruby "$SCRIPTS/probe-join-keys.rb" --workdir "$TMP" --fixture "$CASE_DIR/probe-fixture" >"$TMP/probe.out" 2>"$TMP/probe.err"
rc=$?
if [ "$rc" -eq 2 ] \
   && /usr/bin/grep -q 'JOIN-CARDINALITY FATAL' "$TMP/probe.err" \
   && /usr/bin/grep -q 'SALES_FACT.*SEGMENT_DIM.*CURRENT_FLAG' "$TMP/probe.err" \
   && /usr/bin/grep -q 'CURRENT_FLAG=1  -> 4 rows' "$TMP/probe.err"; then
  note "ok: probe fixture proves the flag key non-unique (6 rows over 2 keys) -> exit 2 FATAL; join elision is unproven"
else
  note "FAIL: probe expected exit 2 + FATAL naming SEGMENT_DIM/CURRENT_FLAG (got exit $rc)"; sed -n '1,15p' "$TMP/probe.err"; fail=1
fi

# -- 4. chart kinds preserved as line in the layout signals ------------------
ruby "$SCRIPTS/parse-twb-layout.rb" "$CASE_DIR/workbook-content.twb" "$TMP/layout.json" >"$TMP/layout.out" 2>&1 || fail=1
ruby -rjson -e '
  zones = JSON.parse(File.read(ARGV[0])).flat_map { |d| d["zones"] || [] }
  kinds = zones.select { |z| z["kind"] == "chart" }.map { |z| [z["caption"], z["chart_kind"]] }.to_h
  abort "Amount Trend not line: #{kinds.inspect}" unless kinds["Amount Trend"] == "line"
  abort "Earn Ratio Trend not line: #{kinds.inspect}" unless kinds["Earn Ratio Trend"] == "line"
  abort "Channel Crosstab not pivot-table: #{kinds.inspect}" unless kinds["Channel Crosstab"] == "pivot-table"
' "$TMP/layout.json" && note "ok: layout signals keep both trend worksheets chart_kind=line (crosstab stays pivot-table)" \
  || { note "FAIL: chart kinds not preserved in layout signals"; fail=1; }

# -- 5. equivalence probe: the elision is measurably NOT a no-op -------------
EQTMP="$TMP/equiv-workdir"
mkdir -p "$EQTMP"
ruby "$SCRIPTS/probe-equivalence.rb" --workdir "$EQTMP" \
  --edit "drop LEFT JOIN SALES_FACT->SEGMENT_DIM (ACTIVE_FLAG=CURRENT_FLAG)" \
  --claim "joined table contributes no shelf column; elision is a no-op" \
  --grain ORDER_ID --measures AMOUNT \
  --before-sql "SELECT f.*, d.SEGMENT_NAME FROM DEMO_DB.ANALYTICS.SALES_FACT f LEFT JOIN DEMO_DB.ANALYTICS.SEGMENT_DIM d ON f.ACTIVE_FLAG = d.CURRENT_FLAG" \
  --after-sql "SELECT f.* FROM DEMO_DB.ANALYTICS.SALES_FACT f" \
  --fixture "$CASE_DIR/equiv-fixture" >"$TMP/equiv.out" 2>"$TMP/equiv.err"
rc=$?
if [ "$rc" -eq 2 ] \
   && /usr/bin/grep -q 'SEMANTIC-EDIT EQUIVALENCE FATAL' "$TMP/equiv.err" \
   && tr -d "\r" < "$TMP/equiv.err" | /usr/bin/grep -q 'TOTAL_ROWS      before 26  vs  after 8' \
   && tr -d "\r" < "$TMP/equiv.err" | /usr/bin/grep -q 'SUM_AMOUNT  before 9575.0  vs  after 2950.0' \
   && ruby -rjson -e '
        e = JSON.parse(File.read(File.join(ARGV[0], "semantic-edits.json")))["entries"].first
        abort "no match:false proof" unless e && e["proof"] && e["proof"]["match"] == false
        abort "row-count mismatch not recorded" unless e["proof"]["mismatches"].any? { |m|
          m["metric"] == "TOTAL_ROWS" && m["before"] == 26 && m["after"] == 8 }
      ' "$EQTMP"; then
  note "ok: equivalence probe REFUTES the elision (26 rows with the join vs 8 without) -> exit 2 FATAL; semantic-edits.json blocks GREEN (gate 20)"
else
  note "FAIL: equivalence probe expected exit 2 + FATAL naming 26 vs 8 rows (got exit $rc)"; sed -n '1,15p' "$TMP/equiv.err"; fail=1
fi

exit "$fail"
