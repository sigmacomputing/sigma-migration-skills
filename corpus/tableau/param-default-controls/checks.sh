#!/usr/bin/env bash
# param-default-controls — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. Converter↔golden lockstep (node-guarded): vendored-bundle re-run on the
#      fixture .twb, id-normalized, must byte-match golden/data-model.json.
#   2. W2.17 both-directions pins on the golden itself (python3, always runs):
#      defaults APPLIED where the .twb carries a current value (list West /
#      date 2024-06-01 / number 25 / text ACME — each warning names the
#      source: "from the workbook's current value") and fail-open PRESERVED
#      where it doesn't (range domain → valueless number-range; dateless date
#      param → date-range last-90 + "adjust in Sigma UI" warning). Guards the
#      pre-W2.17 regression class: every param control hardcoded regardless of
#      the workbook's own value (tableau.mjs:6689, src/tableau.ts:4089-4090).
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
BUNDLE="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/tableau.mjs"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. converter lockstep (needs node) --------------------------------------
if command -v node >/dev/null; then
  cat >"$TMP/convert.mjs" <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [bundle, twb, out] = process.argv.slice(2);
const { convertTableauToSigma } = await import(pathToFileURL(bundle).href);
const r = convertTableauToSigma(readFileSync(twb, "utf8"), { connectionId: "", database: "", schema: "", datasourceIndex: 0 });
writeFileSync(out, JSON.stringify({ sigmaDataModel: r.model, stats: r.stats, warnings: r.warnings }, null, 2) + "\n");
MJS
  if node "$TMP/convert.mjs" "$BUNDLE" "$CASE_DIR/workbook-content.twb" "$TMP/fresh.json" \
     && python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff "$CASE_DIR/golden/data-model.json" "$TMP/fresh.json" >/dev/null; then
    note "OK converter↔golden byte-identical after id-normalization"
  else
    echo "FAIL: fresh conversion diverges from golden/data-model.json"; fail=1
  fi
else
  note "SKIP converter lockstep (node not on PATH — structural golden check still ran)"
fi

# -- 2. W2.17 both-directions pins on the golden -----------------------------
python3 - "$CASE_DIR/golden/data-model.json" <<'PY' && note "OK W2.17 pins: 4 defaults applied + 2 fail-open shapes + named warnings" || { echo "FAIL: W2.17 default/fail-open pins"; fail=1; }
import json, sys
d = json.load(open(sys.argv[1]))
els = d["sigmaDataModel"]["pages"][0]["elements"]
controls = [e for e in els if e.get("kind") == "control"]
assert len(controls) == 6, len(controls)
by_type = {}
for c in controls:
    by_type.setdefault(c["controlType"], []).append(c)

# defaults APPLIED (the .twb carries a current value)
lst = by_type["list"][0]
assert lst["values"] == ["West"], lst          # list default from current value
assert lst["source"]["labels"] == ["East", "Western", "North"], lst  # aliases kept
dt = by_type["date"][0]
assert dt["mode"] == "=" and dt["value"] == "2024-06-01", dt
num = by_type["number"][0]
assert num["mode"] == "=" and num["value"] == 25, num
txt = by_type["text"][0]
assert txt.get("value") == "ACME", txt

# fail-open PRESERVED (no current value in the .twb — old shapes unchanged)
nr = by_type["number-range"][0]
assert "value" not in nr and "mode" not in nr, nr
dr = by_type["date-range"][0]
assert dr["mode"] == "last" and dr["value"] == 90 and dr["unit"] == "day", dr

w = "\n".join(d["warnings"])
for needle in ('"Region Pick"', '"As Of Date"', '"Top Limit"', '"Name Match"'):
    assert needle in w, needle
assert w.count("from the workbook's current value") == 4, w
assert "adjust in Sigma UI" in w, w
PY

exit "$fail"
