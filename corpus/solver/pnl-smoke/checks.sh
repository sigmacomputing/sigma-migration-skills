#!/usr/bin/env bash
# Offline Solver pnl-smoke: DM + workbook goldens, the local evaluator against the executed run (parity GREEN and a
# deliberate RED), the .manifest refusal, and the estate assessment. Synthetic data only; creds-free.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/solver-to-sigma/skills/solver-to-sigma"
ASMT="$REPO_ROOT/plugins/solver-to-sigma/skills/solver-assessment"
FIX="$SKILL/fixtures/pnl-smoke"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 "$SKILL/scripts/convert-solver.py" --definition "$FIX/pnl-template.xlsx" --source-map "$FIX/source-map.json" \
  --name "Location P&L summary - Data" --folder-id fixture-folder --out "$TMP/dm.json" --plan-out "$TMP/plan.json"
python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff "$CASE_DIR/golden/data-model.json" "$TMP/dm.json"

python3 - "$TMP/dm.json" "$TMP/rb.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump(dict(d["sigmaDataModel"], dataModelId="fixture-data-model"), open(sys.argv[2], "w"))
PY
python3 "$SKILL/scripts/build-solver-workbook.py" --plan "$TMP/plan.json" --dm-readback "$TMP/rb.json" \
  --name "Location P&L summary" --folder-id fixture-folder --out "$TMP/wb.json"
python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff "$CASE_DIR/golden/workbook.json" "$TMP/wb.json"

python3 "$SKILL/scripts/evaluate-solver-local.py" --plan "$TMP/plan.json" --facts "GL_F_Trans=$FIX/gl.csv" --out "$TMP/values.json"
python3 "$SKILL/scripts/compare-solver-parity.py" --plan "$TMP/plan.json" --run "$FIX/pnl-executed-run.xlsx" \
  --values "$TMP/values.json" --out "$TMP/parity.json"

python3 "$SKILL/scripts/evaluate-solver-local.py" --plan "$TMP/plan.json" --facts "GL_F_Trans=$FIX/gl.csv" \
  --param Period=202608 --out "$TMP/values-wrong.json"
set +e
python3 "$SKILL/scripts/compare-solver-parity.py" --plan "$TMP/plan.json" --run "$FIX/pnl-executed-run.xlsx" \
  --values "$TMP/values-wrong.json" --out "$TMP/parity-wrong.json"
red=$?
set -e
test "$red" -eq 1

mkdir -p "$TMP/estate"
cp "$FIX/pnl-template.xlsx" "$TMP/estate/"
printf 'not a definition\n' > "$TMP/estate/pnl-template.xlsx.manifest"
python3 "$ASMT/scripts/assess-solver.py" --in "$TMP/estate" --out "$TMP/assess"

python3 - "$TMP/parity.json" "$TMP/assess/inventory.json" <<'PY'
import json, sys
parity, inv = (json.load(open(p)) for p in sys.argv[1:])
assert parity["status"] == "GREEN" and parity["compared"] == 39, parity
assert inv["refused"] == ["pnl-template.xlsx.manifest"]
assert inv["reports"][0]["bucket"] == "iterate"
print("     OK solver pnl-smoke DM, workbook, parity GREEN/RED, manifest refusal, assessment")
PY
