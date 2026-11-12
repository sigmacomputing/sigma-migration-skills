#!/usr/bin/env bash
# fixed-lod-dimension — executable expectations (offline, creds-free).
#
# A FIXED LOD used as a ROW dimension (Cohort Year = {FIXED [Customer Id] :
# MIN(YEAR([Order Date]))}, rows Cohort Year x cols Loyalty Tier, COUNTD
# Customer Id) stopped EVERY live proof at the exit-4 handoff: no master
# carries "Cohort Year", so the workbook ref gate fails. apply-lod-dim-helpers
# (the pass migrate-tableau runs after the per-page master split) must build:
#   1. a grouped helper on the Data page, right after its master (forward
#      document order), unfiltered (FIXED is computed before dimension filters);
#   2. Lookup([Cohort Year Helper/Cohort Year], [Master/Customer Id], ...) on
#      the pivot row, which stays on its control-filtered master.
# The output then passes validate-spec, the ref gate (the pre spec FAILs it),
# control lint (no partial control) and the LOD audit (lod-synth).
# 3. An AUTHORED helper the layout left unplaced keeps its document position
#    (before its consumer) and is placed on the Data page, not a dashboard.
set -euo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
S="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

cp "$CASE_DIR/workbook-content.twb" "$CASE_DIR/wb-spec.pre.json" "$CASE_DIR/dm-ids.json" \
   "$CASE_DIR/metrics.json" "$CASE_DIR/control-scope.json" "$TMP/"
ruby "$S/parse-twb-layout.rb" "$TMP/workbook-content.twb" "$TMP/dashboard-layout.json" >/dev/null
ruby "$S/apply-lod-dim-helpers.rb" --workdir "$TMP" --spec "$TMP/wb-spec.pre.json" --out "$TMP/wb-spec.json" >/dev/null

python3 - "$TMP/wb-spec.json" "$CASE_DIR/wb-spec.expected.json" <<'PY'
import json, sys
got = json.load(open(sys.argv[1], encoding="utf-8"))
pin = json.load(open(sys.argv[2], encoding="utf-8"))
if got != pin:
    sys.exit("wb-spec.json drifted from wb-spec.expected.json (compare as parsed JSON)")
d = got["document"]
ids = [e["id"] for e in d["elements"]]
h = next(e for e in d["elements"] if e["id"] == "lod-cohort-year-helper")
assert ids.index("master-customers") < ids.index("lod-cohort-year-helper") < ids.index("el-customer-cohorts"), ids
assert h["source"] == {"kind": "data-model", "dataModelId": "dm-fixture", "elementId": "fact-view"}, h["source"]
assert h["groupings"][0]["groupBy"] == ["lod-cohort-year-key"], h["groupings"]
cols = {c["name"]: c["formula"] for c in h["columns"]}
assert cols["Cohort Year"] == "Min([Cohort Year Base])" and cols["Cohort Year Base"] == "Year([Fact View/Order Date])", cols
pv = next(e for e in d["elements"] if e["id"] == "el-customer-cohorts")
assert pv["source"]["elementId"] == "master-customers", pv["source"]
row = next(c for c in pv["columns"] if c["id"] == "p-row-cohort-year")
assert row["formula"] == "Lookup([Cohort Year Helper/Cohort Year], [Master/Customer Id], [Cohort Year Helper/Customer Id])", row
data_page = d["layout"].split('id="page-data"')[1].split("</Page>")[0]
assert 'elementId="lod-cohort-year-helper"' in data_page, "helper not placed on the Data page"
PY

ruby "$S/validate-spec.rb" --type workbook --dm-context "$TMP/dm-ids.json" --metrics "$TMP/metrics.json" "$TMP/wb-spec.json" | grep -q -- '--- 0 errors'
ruby "$S/assert-wb-refs-resolve.rb" --wb-spec "$TMP/wb-spec.json" --dm-ids "$TMP/dm-ids.json" --metrics "$TMP/metrics.json" --workdir "$TMP" | grep -q PASS
if ruby "$S/assert-wb-refs-resolve.rb" --wb-spec "$TMP/wb-spec.pre.json" --dm-ids "$TMP/dm-ids.json" \
     --metrics "$TMP/metrics.json" --workdir "$TMP" >/dev/null 2>&1; then
  echo "the pre-helper spec unexpectedly passed the ref gate (the exit-4 case is gone from the fixture)"; exit 1
fi
ruby "$S/lib/control_lint.rb" "$TMP/wb-spec.json" "$TMP/control-scope.json" | grep -q 'control lint: clean'
ruby "$S/audit-lod-calcs.rb" --workdir "$TMP" --twb "$TMP/workbook-content.twb" >/dev/null
python3 - "$TMP/lod-audit.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
e = next(x for x in (j["entries"] if isinstance(j, dict) else j) if x["calc"] == "Cohort Year")
assert e["class"] == "lod-synth" and e["status"] == "resolved", e
PY

# 3. authored helper left unplaced by the layout
python3 - "$TMP/wb-spec.json" "$TMP/wb-spec.authored.json" <<'PY'
import json, re, sys
j = json.load(open(sys.argv[1]))
j["document"]["layout"] = re.sub(r'\s*<Element elementId="lod-cohort-year-helper"[^>]*/>', "", j["document"]["layout"])
json.dump(j, open(sys.argv[2], "w"))
PY
ruby "$S/apply-lod-dim-helpers.rb" --workdir "$TMP" --spec "$TMP/wb-spec.authored.json" --out "$TMP/wb-spec.authored.out.json" >/dev/null
python3 - "$TMP/wb-spec.authored.out.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["document"]
ids = [e["id"] for e in d["elements"]]
assert ids.index("lod-cohort-year-helper") < ids.index("el-customer-cohorts"), ("helper moved after its consumer", ids)
data_page = d["layout"].split('id="page-data"')[1].split("</Page>")[0]
assert 'elementId="lod-cohort-year-helper"' in data_page, "unplaced helper inferred onto a dashboard page"
PY
ruby "$S/validate-spec.rb" --type workbook --dm-context "$TMP/dm-ids.json" --metrics "$TMP/metrics.json" "$TMP/wb-spec.authored.out.json" | grep -q -- '--- 0 errors'
# 4. The gap scan's formula audit mirrors the helper: the converter refuses the
#    FIXED LOD, but it is a one-dimension FIXED used as a plain Rows dimension on
#    a built sheet, so it is chart_only (translator lod_dim_helper) and raises no
#    converter-refused gap. The census then accounts it migrated (the helper's
#    "Cohort Year" column is built and parity passes) instead of needs-review.
mkdir -p "$TMP/scan"
cp "$CASE_DIR/workbook-content.twb" "$TMP/scan/"
(cd "$TMP/scan" && ruby "$S/scan-workbook-gaps.rb" workbook-content.twb >/dev/null 2>&1)
python3 - "$TMP/scan" <<'PY'
import glob, json, os, sys
d = sys.argv[1]
audit = json.load(open(os.path.join(d, "formula-audit.json"), encoding="utf-8"))
row = next(r for r in audit["formulas"] if r["caption"] == "Cohort Year")
assert row["status"] == "chart_only" and row["converter_status"] == "not_converted", row
assert row["chart_translator"]["translator"] == "lod_dim_helper", row["chart_translator"]
assert row["chart_translator"]["worksheets"] == ["Customer Cohorts"], row["chart_translator"]
report = json.load(open(glob.glob(os.path.join(d, "*gaps-report.json"))[0], encoding="utf-8"))
names = [f.get("name", "") for f in report.get("detected_features", [])]
assert not any(n.startswith("Converter-refused") and n.endswith("Cohort Year") for n in names), names
PY
cp "$TMP/wb-spec.json" "$TMP/scan/wb-spec.json"
echo '{"status":"PASS"}' > "$TMP/scan/parity-final.json"
ruby "$S/build-source-object-census.rb" --workdir "$TMP/scan" >/dev/null
python3 - "$TMP/scan/source-object-census.json" <<'PY'
import json, sys
objs = json.load(open(sys.argv[1], encoding="utf-8"))["objects"]
cy = next(o for o in objs if o["type"] == "calculation" and o["name"] == "Cohort Year")
assert cy["status"] == "migrated", cy
PY
echo "fixed-lod-dimension: ok"
