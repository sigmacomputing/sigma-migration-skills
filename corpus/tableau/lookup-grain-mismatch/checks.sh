#!/usr/bin/env bash
# lookup-grain-mismatch — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. lib/join_plan.rb derivation on the synthetic .twb yields EXACTLY the
#      pinned federated-join entries (compound self-join keys resolved via
#      GUID captions; W2.9 strips the role-parenthetical fold from the dim
#      probe keys — ITEM_KEY/BUYER_KEY, no more _(DIM) garble; the VC
#      self-join right_table stays the unprobeable inode FQN — the honest
#      current-code output, warts recorded on purpose).
#   2. probe-join-keys.rb --fixture (the offline seam): the clean dim keys
#      probe unique; the self-join entry is REFUSED by the W2.9 identifier
#      legality oracle (inode FQN never reaches SQL) → status error, exit 3.
#   2b. FATAL coverage kept: with the self-join right_table legalized to the
#      physical FQN, the fixture proves it NON-UNIQUE → exit 2 + FATAL block.
#   3. assert-phase6-ran.rb gate 16 (exit 23) BLOCKS on the refused-entry
#      ledger and PASSES once the resolution evidence is recorded.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. join-plan derivation matches the pin ---------------------------------
ruby -rjson -I "$SCRIPTS/lib" -r join_plan -e '
  xml = File.read(ARGV[0], encoding: "UTF-8")
  entries = JoinPlan.derive(nil, xml, db: "DEMO_DB", schema: "ANALYTICS")
  File.write(ARGV[1], JSON.pretty_generate(entries) + "\n")
' "$CASE_DIR/workbook-content.twb" "$TMP/derived.json" || fail=1
if cmp -s <(tr -d "\r" < "$TMP/derived.json") <(tr -d "\r" < "$CASE_DIR/join-plan.entries.json"); then
  note "ok: join-plan derivation matches join-plan.entries.json (3 federated joins; W2.9-stripped dim keys; compound self-join keys BUYER_KEY+SALE_DATE)"
else
  note "FAIL: join-plan derivation drifted from join-plan.entries.json:"
  diff <(tr -d "\r" < "$CASE_DIR/join-plan.entries.json") <(tr -d "\r" < "$TMP/derived.json") | head -30
  fail=1
fi

# -- 2. offline probe: clean dims unique, VC self-join REFUSED (W2.9) --------
ruby -rjson -I "$SCRIPTS/lib" -r join_plan -e '
  entries = JSON.parse(File.read(ARGV[0]))
  JoinPlan.write(ARGV[1], entries)
' "$CASE_DIR/join-plan.entries.json" "$TMP/join-plan.json" || fail=1
probe_err="$TMP/probe.err"
ruby "$SCRIPTS/probe-join-keys.rb" --workdir "$TMP" --fixture "$CASE_DIR/probe-fixture" >"$TMP/probe.out" 2>"$probe_err"
rc=$?
if [ "$rc" -eq 3 ] \
   && /usr/bin/grep -q 'refused by the identifier legality oracle' "$TMP/probe.out" \
   && /usr/bin/grep -q 'could not be probed' "$probe_err"; then
  note "ok: probe refuses the VC-inode self-join FQN (W2.9 legality oracle, no SQL emitted) → exit 3"
else
  note "FAIL: probe expected exit 3 + legality refusal on the self-join (got exit $rc)"; sed -n '1,20p' "$probe_err"; fail=1
fi
ruby -rjson -e '
  e = JSON.parse(File.read(ARGV[0]))["entries"]
  ok = e[0]["status"] == "unique" && e[1]["status"] == "unique" && e[2]["status"] == "error" &&
       e[2]["probe_error"].to_s =~ /not legal/ && !e[2].key?("probe_sql") &&
       e[0]["counts"] == { "total" => 240, "distinct" => 240 } &&
       e[1]["counts"] == { "total" => 180, "distinct" => 180 }
  abort "ledger statuses wrong: #{e.map { |x| x["status"] }.inspect}" unless ok
' "$TMP/join-plan.json" && note "ok: ledger records unique/unique/error — refusal named, no probe_sql on the refused entry" \
  || { note "FAIL: probed ledger state wrong"; fail=1; }

# -- 2b. FATAL coverage kept: legalized FQN → non-unique → exit 2 + FATAL ----
TMP2="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP2"' EXIT
ruby -rjson -I "$SCRIPTS/lib" -r join_plan -e '
  entries = JSON.parse(File.read(ARGV[0]))
  entries[2]["right_table"] = "ANALYTICS.SALES_FACT"
  JoinPlan.write(ARGV[1], entries)
' "$CASE_DIR/join-plan.entries.json" "$TMP2/join-plan.json" || fail=1
probe2_err="$TMP2/probe.err"
ruby "$SCRIPTS/probe-join-keys.rb" --workdir "$TMP2" --fixture "$CASE_DIR/probe-fixture" >"$TMP2/probe.out" 2>"$probe2_err"
rc=$?
if [ "$rc" -eq 2 ] \
   && /usr/bin/grep -q 'JOIN-CARDINALITY FATAL' "$probe2_err" \
   && /usr/bin/grep -q 'Sale Lines.*Buyer Day Detail.*BUYER_KEY, SALE_DATE' "$probe2_err" \
   && /usr/bin/grep -q 'BUYER_KEY=1017' "$probe2_err"; then
  note "ok: legalized-FQN probe drives exit 2 FATAL on the non-unique compound self-join (5000 rows over 1400 keys)"
else
  note "FAIL: legalized probe expected exit 2 + FATAL naming the self-join (got exit $rc)"; sed -n '1,20p' "$probe2_err"; fail=1
fi
ruby -rjson -e '
  e = JSON.parse(File.read(ARGV[0]))["entries"]
  ok = e[2]["status"] == "non-unique" &&
       e[2]["duplicates"].length == 5 && e[2]["counts"] == { "total" => 5000, "distinct" => 1400 }
  abort "ledger statuses wrong: #{e.map { |x| x["status"] }.inspect}" unless ok
' "$TMP2/join-plan.json" && note "ok: legalized ledger records non-unique with counts + sample duplicates" \
  || { note "FAIL: legalized probed ledger state wrong"; fail=1; }

# -- 3. gate 16 blocks the unresolved ledger, passes the resolved one --------
# Baseline workdir that satisfies every other offline gate (same shape as
# scripts/test-assert-phase6-gates.rb): passing parity, valid PNG.
cat > "$TMP/parity-final.json" <<'JSON'
{
  "workbook_id": "wb-corpus-lgm", "mode": "strict", "status": "PASS",
  "charts_total": 4, "charts_pass": 4, "charts_fail": 0,
  "pass_names": ["Amount Trend", "Buyer Detail", "Group Mix", "KPI Unified Amount"],
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
if [ "$rc" -eq 23 ] && /usr/bin/grep -q 'gate 16: join-cardinality ledger unresolved' "$TMP/gate1.err"; then
  note "ok: gate 16 (exit 23) blocks GREEN on the unresolved refused entry (UNPROVEN)"
else
  note "FAIL: gate 16 expected exit 23 on the unresolved ledger (got $rc)"; sed -n '1,12p' "$TMP/gate1.err"; fail=1
fi

ruby "$SCRIPTS/probe-join-keys.rb" --workdir "$TMP" --resolve 2 --how preaggregated \
  --reason 'grouped helper "Buyer Day Rollup" at buyer x sale-date grain; Lookup repointed (corpus fixture evidence)' \
  >"$TMP/resolve.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'resolved: preaggregated' "$TMP/resolve.out"; then
  note "ok: --resolve preaggregated records the evidence and clears the probe failure"
else
  note "FAIL: --resolve expected exit 0 (got $rc)"; sed -n '1,8p' "$TMP/resolve.out"; fail=1
fi

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate2.out" 2>"$TMP/gate2.err"
rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q '\[OK\] gate 16: join-cardinality ledger resolved' "$TMP/gate2.out"; then
  note "ok: gate 16 passes once the resolution evidence is in the ledger (2 unique, 1 resolved)"
else
  note "FAIL: gate 16 expected exit 0 on the resolved ledger (got $rc)"; sed -n '1,12p' "$TMP/gate2.err"; fail=1
fi

exit "$fail"
