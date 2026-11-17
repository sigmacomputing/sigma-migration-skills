#!/usr/bin/env bash
# pbi-shaped-model — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
# The opt-in Power BI-shaped mode (--model-shape pbi) of powerbi-to-sigma on the sales fixture:
#   1. drive.rb runs the real orchestrator with a stub in place of Sigma's HTTP layer (no network, no
#      credentials): shaped data model (PbiShapedModel.apply!), the direct master map (PbiDirectMap.build on a
#      faked readback), the builder with --direct-sources, validate and lint. The key-uniqueness check and the
#      slicer-carry sizes are replayed from fixtures/pbi-shaped/sales/shape-probe-results.json;
#   2. pbi-shaped-report.rb writes pbi-map.json/md and limits.md;
#   3. the data model, master map and workbook spec are normalized (generated ids -> positional tokens) and
#      byte-compared to the goldens; the report files are compared as written (they carry no ids);
#   4. validate-spec.rb on both specs and preflight_lint.rb on the workbook spec are clean.
# Regenerate the goldens after an intended change with: bash checks.sh --update
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/powerbi-to-sigma/skills/powerbi-to-sigma"
S="$SKILL/scripts"
G="$CASE_DIR/golden"
UPDATE="${1:-}"

command -v ruby >/dev/null || { echo "checks: ruby not found"; exit 1; }
command -v python3 >/dev/null || { echo "checks: python3 not found"; exit 1; }
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
# creds-free: nothing in this script may reach a Sigma tenant
for v in $(env | sed -n 's/^\(SIGMA_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
norm() { python3 "$REPO_ROOT/corpus/lib/corpus_check.py" normalize "$1" "$2"; }
pin() { # pin <fresh> <golden> <label>
  if [ "$UPDATE" = "--update" ]; then mkdir -p "$(dirname "$2")"; cp "$1" "$2"; echo "     updated $3"; return; fi
  if cmp -s "$1" "$2"; then echo "     ok   $3"; else echo "     FAIL $3 differs from golden:"; diff -u "$2" "$1" | head -40; fail=1; fi
}
run() { # run <label> <cmd...>
  if "${@:2}" >"$TMP/last.out" 2>&1; then echo "     ok   $1"; else echo "     FAIL $1"; tail -20 "$TMP/last.out"; fail=1; fi
}

# live/ hygiene: tracked live results must not carry Sigma test-org identifiers (ids, write database/schema)
if python3 - "$CASE_DIR/live" <<'PY'
import json, os, re, sys
KEYS = {"sheetId", "elementId", "element_id", "materializationId", "dataModelId", "data_model_id", "workbookId", "workbook_id", "parentId", "inodeId", "connectionId"}
LOCAL = ("el-", "pf-", "e-", "ch-", "ctl-", "g-", "f-")
# value patterns: a real Sigma id (uuid), a Snowflake account host, an email. The all-zero uuid is a placeholder.
ZERO_UUID = "00000000-0000-0000-0000-000000000000"
VALUE_PATTERNS = [
    ("uuid", re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)),
    ("AAAAAAAA", re.compile(r"AAAAAAAA[A-Za-z0-9]{2,}")),
    ("snowflakecomputing", re.compile(r"snowflakecomputing", re.I)),
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
]
TOKEN_DELIM = " \t\r\n\"'`,:;[]{}()<>=\\/|"
def value_hits(txt):
    # placeholders (<...>) are allowed; a match inside a local-id token (el-, pf-, ...) is allowed
    txt = re.sub(r"<[^<>\n]*>", " ", txt)
    found = []
    for name, rx in VALUE_PATTERNS:
        for m in rx.finditer(txt):
            if name == "uuid" and m.group(0).lower() == ZERO_UUID:
                continue
            s, e = m.start(), m.end()
            while s > 0 and txt[s - 1] not in TOKEN_DELIM:
                s -= 1
            token = txt[s:e]
            if token.startswith(LOCAL):
                continue
            found.append("%s (%s)" % (name, m.group(0)))
    return found
bad = []
def walk(o, path):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in KEYS and isinstance(v, str) and not (re.fullmatch(r"<[^<>]+>", v) or v.startswith(LOCAL)):
                bad.append("%s: %s = %r" % (path, k, v))
            walk(v, path)
    elif isinstance(o, list):
        for v in o:
            walk(v, path)
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        p = os.path.join(root, f)
        txt = open(p, encoding="utf-8", errors="replace").read()
        if "SIGMA_WRITE" in txt:
            bad.append("%s: SIGMA_WRITE" % p)
        for hit in value_hits(txt):
            bad.append("%s: value %s" % (p, hit))
        if f.endswith(".json"):
            walk(json.loads(txt), p)
if bad:
    print("\n".join(bad[:20]))
    sys.exit(1)
PY
then echo "     ok   live/: no Sigma ids or write schema in tracked live results"; else echo "     FAIL live/ carries Sigma test-org identifiers (redact to <sheet-n>/<element-n>/<uuid-n>)"; fail=1; fi

if ! ruby "$CASE_DIR/drive.rb" "$TMP/w" >"$TMP/drive.out" 2>&1; then
  echo "     FAIL drive.rb (orchestrator, direct map, builder, report)"; tail -30 "$TMP/drive.out"; exit 1
fi
echo "     ok   drive.rb: orchestrator + direct map + builder + report ran offline"
R="$TMP/w/run"
norm "$R/dm-spec.json" "$TMP/dm-spec.json"
norm "$R/master-map.json" "$TMP/master-map.json"
norm "$R/workbook-spec.json" "$TMP/workbook.json"
pin "$TMP/dm-spec.json" "$G/dm-spec.json" "data model spec (normalized)"
pin "$TMP/master-map.json" "$G/master-map.json" "direct master map (normalized)"
pin "$TMP/workbook.json" "$G/workbook.json" "workbook spec (normalized)"
pin "$R/pbi-map.json" "$G/pbi-map.json" "pbi-map.json"
pin "$R/pbi-map.md" "$G/pbi-map.md" "pbi-map.md"
pin "$R/limits.md" "$G/limits.md" "limits.md"

# the map must find the workbook elements: a regression to "(none)" fails here
if python3 - "$R/pbi-map.json" "$R/workbook-spec.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
wb = json.load(open(sys.argv[2]))["document"]
ids = {e["id"] for e in wb["elements"]}
bad = []
held = []
for sec in ("visuals", "slicers"):
    items = m[sec]
    if not items:
        bad.append(sec + ": empty")
    for i in items:
        if not i["sigma"] and "class D visual held back" in i["reason"]:
            held.append(i["pbi"])  # Task 21x: a visual needing two relationship paths is held back, never built wrong
        elif not i["sigma"]:
            bad.append("%s: %s -> (none): %s" % (sec, i["pbi"], i["reason"]))
        elif i["sigma"]["id"] not in ids:
            bad.append("%s: %s maps to an unknown element" % (sec, i["pbi"]))
if bad:
    print("\n".join(bad[:10]))
    sys.exit(1)
# C1 (Fix A): the Trends chart that binds the as-of YTD with a month axis is held back too (Power BI plots one flat value)
if held != ["Shipping: Sales by ship month and order month", "Trends: Sales YTD and YTD (As Of) by month"]:
    print("held-back class D visuals: %r" % held)
    sys.exit(1)
print("%d visuals, %d slicers mapped to workbook elements (%d class D held back)" % (len(m["visuals"]), len(m["slicers"]), len(held)))
PY
then echo "     ok   pbi-map: every visual and slicer maps to a workbook element (the two class D visuals are held back, with their reasons)"; else echo "     FAIL pbi-map has visuals or slicers with no workbook element"; fail=1; fi
run "validate-spec (data model)" ruby "$S/validate-spec.rb" --type datamodel "$R/dm-spec.json"
run "validate-spec (workbook)" ruby "$S/validate-spec.rb" --type workbook --dm-context "$R/dm-context.json" "$R/workbook-spec.json"
run "preflight lint (workbook)" ruby "$S/lib/preflight_lint.rb" "$R/workbook-spec.json"
grep -q 'Data' <(python3 -c 'import json,sys; print([p["name"] for p in json.load(open(sys.argv[1]))["document"]["pages"]])' "$R/workbook-spec.json") \
  && { echo "     FAIL the workbook has a Data page (it must read the data model directly)"; fail=1; } \
  || echo "     ok   no Data page: the workbook reads the data model directly"
exit "$fail"
