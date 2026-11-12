#!/usr/bin/env bash
# dim-unmatched-members — executable expectations (offline, creds-free).
#
# Tableau's relationship model keeps dimension members with NO fact rows: a
# store with 0 orders still lists in a tile keyed by STORE_DIM fields (blank
# revenue, 0 orders). The Sigma master is fact-rooted, so the A+B regression
# lost Phoenix Outlet / AZ from Store Scorecard, Store Rank Table, Store State
# Map and RC State Map. apply-dim-preserve (the pass migrate-tableau runs after
# the FIXED-LOD helper pass) must:
#   1. re-base ONLY the tiles whose dimensions all come from one related table
#      AND whose view CSV shows an unmatched member (Store State Map: AZ blank /
#      0 orders, long Measure Names/Values CSV; Store Scorecard: Phoenix Outlet,
#      wide CSV) on a clone = Store Dim LEFT-OUTER JOIN the fact view, placed
#      right after its master;
#   2. leave a fact-table dimension tile (Ship Method, a 0 row is not an
#      unmatched member) and an all-matched related-dimension tile untouched;
#   3. inline DM metrics on the re-based tiles (metrics do not exist on a join);
#   4. extend the Store Type control to the clone (no partial control);
#   5. be idempotent on re-entry (no second clone, clone stays before readers).
set -euo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
S="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

cp -R "$CASE_DIR/." "$TMP/"
ruby "$S/apply-dim-preserve.rb" --workdir "$TMP" --spec "$TMP/wb-spec.pre.json" --out "$TMP/wb-spec.json" >/dev/null

python3 - "$TMP/wb-spec.json" "$CASE_DIR/wb-spec.expected.json" <<'PY'
import json, sys
got = json.load(open(sys.argv[1], encoding="utf-8"))
pin = json.load(open(sys.argv[2], encoding="utf-8"))
if got != pin:
    sys.exit("wb-spec.json drifted from wb-spec.expected.json (compare as parsed JSON)")
d = got["document"]
by = {e["id"]: e for e in d["elements"]}
ids = [e["id"] for e in d["elements"]]
cl = by["master-stores-keep-store-dim"]
src = cl["source"]
assert src["kind"] == "join" and src["primarySource"]["elementId"] == "store-tbl", src
j = src["joins"][0]
assert j["joinType"] == "left-outer" and j["right"]["elementId"] == "fact-view", j
assert j["columns"] == [{"left": "[Store Key]", "right": "[Order Store Key]"}], j["columns"]
cols = {c["name"]: c["formula"] for c in cl["columns"]}
assert cols["Store Name"] == "[Store Dim (all members)/Store Name]", cols
assert cols["Net Revenue"] == "[Order Fact View/Net Revenue]", cols
assert ids.index("master-stores") < ids.index("master-stores-keep-store-dim") < ids.index("el-store-state-map"), ids
for t in ("el-store-state-map", "el-store-scorecard"):
    assert by[t]["source"] == {"kind": "table", "elementId": cl["id"]}, (t, by[t]["source"])
    assert not any("[Master/" in c["formula"] or "[Metrics/" in c["formula"] for c in by[t]["columns"]), by[t]["columns"]
m = {c["id"]: c["formula"] for c in by["el-store-state-map"]["columns"]}
assert m["y-map"] == "(Sum([Master (all STORE_DIM members)/Net Revenue]))", m
assert m["t-map"] == "(CountDistinct([Master (all STORE_DIM members)/Order Id]))", m
for t in ("el-ship-method-bar", "el-store-type-bar"):
    assert by[t]["source"] == {"kind": "table", "elementId": "master-stores"}, (t, by[t]["source"])
f = by["el-ctl-store-type"]["filters"]
assert any(x["source"]["elementId"] == cl["id"] for x in f), f
PY

ruby "$S/validate-spec.rb" --type workbook --dm-context "$TMP/dm-readback.json" --metrics "$TMP/metrics.json" "$TMP/wb-spec.json" | grep -q -- '--- 0 errors'
ruby "$S/assert-wb-refs-resolve.rb" --wb-spec "$TMP/wb-spec.json" --dm-ids "$TMP/dm-readback.json" --metrics "$TMP/metrics.json" --workdir "$TMP" | grep -q PASS
ruby "$S/lib/control_lint.rb" "$TMP/wb-spec.json" "$TMP/control-scope.json" | grep -q 'control lint: clean'

# 5. re-entry: same output, no second clone
ruby "$S/apply-dim-preserve.rb" --workdir "$TMP" --spec "$TMP/wb-spec.json" --out "$TMP/wb-spec.again.json" | grep -q 'no tile needs'
python3 - "$TMP/wb-spec.json" "$TMP/wb-spec.again.json" <<'PY'
import json, sys
a, b = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:])
assert a == b, "re-running the pass changed the spec"
PY
echo "dim-unmatched-members: ok"
