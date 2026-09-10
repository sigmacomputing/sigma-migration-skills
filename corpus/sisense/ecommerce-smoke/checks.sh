#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$ROOT/plugins/sisense-to-sigma/skills/sisense-to-sigma"
MODEL="$SKILL/fixtures/model_ecommerce.json"
DASHBOARDS="$SKILL/fixtures/dashboards.json"
CONVERT="$SKILL/scripts/convert.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Exercise the real CLI entry point while pinning its random client ids. The
# corpus normalizer then rewrites those ids to ordinary corpus tokens.
run_convert() {
  python3 -c \
    'import os,random,runpy,sys; random.seed(0); path=sys.argv.pop(1); sys.path.insert(0,os.path.dirname(path)); runpy.run_path(path,run_name="__main__")' \
    "$CONVERT" "$@"
}

(
  cd "$TMP"
  python3 "$SKILL/scripts/scan_gaps.py" "$DASHBOARDS" \
    --model "$MODEL" --out gap-report.json --rules learned-rules.json

  run_convert model "$MODEL" 00000000-0000-0000-0000-000000000000 \
    SISENSE_ECOMMERCE DEMO_DB --dashboards "$DASHBOARDS"
  fact_id="$(
    python3 -c 'import json; d=json.load(open("sigma_dm_spec.json")); print(next(e["id"] for p in d["pages"] for e in p["elements"] if e["name"] == "Commerce"))'
  )"
  run_convert dashboard "$DASHBOARDS" "$MODEL" dm-corpus "$fact_id" Commerce \
    --dm-spec sigma_dm_spec.json

  python3 "$SKILL/scripts/verify_layout.py" \
    "$DASHBOARDS" sigma_workbook_spec.json
  python3 "$ROOT/corpus/lib/corpus_check.py" normalize \
    sigma_dm_spec.json data-model.json
  python3 "$ROOT/corpus/lib/corpus_check.py" normalize \
    sigma_workbook_spec.json workbook.json

  # The one-command dry-run is the offline integration contract: it must
  # exercise both conversions, structured accounting, blank-risk lint, and
  # layout while explicitly refusing to stamp POST/parity/render success.
  python3 "$SKILL/scripts/migrate-sisense.py" \
    --dry-run --from-discovery "$SKILL/fixtures" --workdir "$TMP/orchestrated"
  python3 - "$TMP/orchestrated" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
state = json.loads((root / "run-state.json").read_text())
assert state["complete"] is False
assert state["post_complete"] is False
assert state["parity_complete"] is False
assert state["render_complete"] is False
assert not (root / "phase6-success.json").exists()
census = json.loads((root / "source-object-census.json").read_text())
assert census["summary"]["total"] == census["summary"]["accounted"] == 56
assert census["summary"]["complete"] is True
PY
)

cmp "$TMP/data-model.json" "$CASE_DIR/golden/data-model.json"
cmp "$TMP/workbook.json" "$CASE_DIR/golden/workbook.json"
cmp "$TMP/gap-report.json" "$CASE_DIR/golden/gap-report.json"
echo "Sisense ecommerce scan, conversion, layout, and deterministic goldens match"
