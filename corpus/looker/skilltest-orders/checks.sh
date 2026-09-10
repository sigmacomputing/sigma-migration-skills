#!/usr/bin/env bash
# Offline readiness + full source-accounting regression for the canonical
# skilltest-orders LookML project.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/looker-to-sigma/skills/looker-to-sigma"
S="$SKILL/scripts"
FIXTURE="$SKILL/fixtures/skilltest-orders"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The synthetic fixture pins multi-hop dependencies, aliases, and extends
# cycles; the canonical fixture pins the clean path.
node "$S/test-audit-lookml-readiness.mjs"

# The Windows corpus job is a portability/path smoke and intentionally does not
# install optional PyYAML. The Linux corpus and unit jobs run the full dashboard
# parse/build/accounting path below.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "     SKIP dashboard accounting smoke (PyYAML unavailable; readiness audit passed)"
  exit 0
fi

node "$S/audit-lookml-readiness.mjs" \
  --lookml-dir "$FIXTURE" --explore order_fact \
  --out "$TMP/lookml-readiness.json" \
  --field-census "$TMP/lookml-field-census.json" \
  --formula-mapping "$TMP/formula-mapping.json"

LOOKML_DIR="$FIXTURE" CONVERTER_SRC="$SKILL/converter/lookml.mjs" \
  node "$S/convert_dm.mjs" order_fact "$TMP/dm-spec.json"
python3 "$S/parse_lookml_dashboard.py" \
  "$FIXTURE/skilltest_orders.dashboard.lookml" --out "$TMP/contract.json"
python3 "$S/build_workbook.py" "$TMP/contract.json" \
  --views "$FIXTURE/views" --dm-id fixture-dm --element-id fixture-element \
  --dm-element-name "Order Fact" --folder-id fixture-folder --out "$TMP/wb-spec.json"

cat >"$TMP/parity-final.json" <<'JSON'
{"status":"PASS","charts_total":6,"charts_pass":6,"visual_checked":true,"visual_verdict":"pass"}
JSON
cat >"$TMP/render-health.json" <<'JSON'
{"status":"PASS","width":1200,"height":900,"ink_ratio":0.2,"entropy":4.0,"reasons":[]}
JSON

ruby "$S/lint-render-integrity.rb" --spec "$TMP/wb-spec.json" \
  --out "$TMP/blank-risk-elements.json"
python3 "$S/build-looker-accounting.py" --workdir "$TMP"
ruby "$S/build-migration-report.rb" --workdir "$TMP"

python3 - "$TMP/lookml-readiness.json" "$TMP/lookml-field-census.json" \
  "$TMP/source-object-census.json" "$TMP/migration-result.json" <<'PY'
import json, sys
readiness, fields, census, result = (json.load(open(path)) for path in sys.argv[1:])
assert readiness["readiness"] in ("clean", "caveat")
assert readiness["summary"]["omitted"] == 0
assert fields["fields"] and all(row["mapping"] in ("exact", "approximate") for row in fields["fields"])
assert census["summary"]["complete"] is True
assert census["summary"]["accounted"] == census["summary"]["total"] == len(census["objects"])
types = {row["type"] for row in census["objects"]}
assert {"view", "field", "explore", "join", "dashboard", "tile", "dashboard-filter"} <= types
assert result["verdict"] != "RED"
assert result["summary"]["complete"] is True
assert result["summary"]["accounted"] == result["summary"]["total"]
assert {(row["type"], row["id"], row["status"]) for row in census["objects"]} == {
    (row["type"], row["id"], row["status"]) for row in result["source_objects"]
}
PY

echo "     OK LookML readiness + ledger-complete migration report"
