#!/usr/bin/env bash
# Offline pin: percent-of-total across Region (Region on COLUMNS) must scope
# "row" (never grand_total), and a running sum ordered by Region — and each
# directional share's Region headers — carry a hidden null-first sort key. Regenerates chart-specs.json and byte-compares
# it to the pinned copy.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
S="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

cp "$CASE_DIR/workbook-content.twb" "$CASE_DIR/get-workbook.json" "$CASE_DIR/master-columns.json" "$TMP/"
ruby "$S/parse-twb-layout.rb" "$TMP/workbook-content.twb" "$TMP/dashboard-layout.json" >/dev/null
ruby "$S/build-charts-from-signals.rb" --tableau-dir "$TMP" --layout "$TMP/dashboard-layout.json" \
  --meta "$TMP/dashboard-layout-meta.json" --master-map "$TMP/master-columns.json" \
  --master-element-id master --skip-dashboard-read corpus-fixture --page-per-worksheet \
  --title "Pivot Fixture" --out "$TMP/chart-specs.json" >/dev/null 2>&1

# Compare parsed JSON, not bytes: on Windows the builder's text-mode write
# emits CRLF, which a byte diff reports as every line drifting.
python3 - "$TMP/chart-specs.json" "$CASE_DIR/chart-specs.json" <<'PY'
import json, sys
got = json.load(open(sys.argv[1], encoding="utf-8"))
pin = json.load(open(sys.argv[2], encoding="utf-8"))
def first_diff(a, b, path="$"):
    if type(a) != type(b):
        return f"{path}: type {type(a).__name__} != {type(b).__name__}"
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return f"{path}.{k}: present only in {'pin' if k not in a else 'output'}"
            d = first_diff(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}: length {len(a)} != {len(b)}"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, f"{path}[{i}]")
            if d:
                return d
        return None
    return None if a == b else f"{path}: {a!r} != {b!r}"
d = first_diff(got, pin)
if d:
    sys.exit(f"chart-specs.json drifted from the pin (output vs pin): {d}")
PY

python3 - "$TMP/chart-specs.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
els = [e for p in d["pages"] for e in p["elements"] if e.get("kind") == "pivot-table"]
by = {e["name"]: e for e in els}
def val(e):
    return next(c for c in e["columns"] if c["id"] in e["values"])
assert val(by["Quick Pct Across Region"])["formula"].endswith('"row")'), val(by["Quick Pct Across Region"])
assert val(by["Share Calc Across Region"])["formula"].endswith('"row")'), val(by["Share Calc Across Region"])
run = by["Running Sum Across Region"]
key = next(c for c in run["columns"] if c["id"].endswith("-nullfirst"))
assert key["formula"] == 'If(IsNull([Master/Region]), "", [Master/Region])', key
assert run["columnsBy"][0]["sort"] == {"direction": "ascending", "by": key["id"], "aggregation": "min"}, run["columnsBy"]
assert 'grand_total' not in json.dumps(els)
# No <table-calc> at all (explicit SUM/TOTAL, never re-addressed — the
# "Sales Matrix" shape): Tableau's default Table (Across) → "row".
assert val(by["Share Calc Default Addressing"])["formula"].endswith('"row")'), val(by["Share Calc Default Addressing"])
# directional shares lay Region out as headers: NULL header first, as in Tableau
for name in ("Quick Pct Across Region", "Share Calc Across Region"):
    e = by[name]
    k = next(c for c in e["columns"] if c["id"].endswith("-nullfirst"))
    assert e["columnsBy"][0]["sort"]["by"] == k["id"], e["columnsBy"]
PY
echo "pivot-pcto-direction: ok"
