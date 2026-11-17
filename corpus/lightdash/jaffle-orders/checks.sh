#!/usr/bin/env bash
# Offline Lightdash jaffle-orders: DM + workbook goldens, RLS plan, offline dry-run.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/lightdash-to-sigma/skills/lightdash-to-sigma"
FIX="$SKILL/fixtures/jaffle-orders"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ruby "$SKILL/scripts/convert-dm.rb" --source-dir "$FIX" --explore orders \
  --connection-id fixture-connection --out "$TMP/dm.json"
python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff \
  "$CASE_DIR/golden/data-model.json" "$TMP/dm.json"

ruby "$SKILL/scripts/build-lightdash-workbook.rb" \
  --dashboard "$FIX/lightdash/dashboards/jaffle-overview.yml" \
  --charts-dir "$FIX/lightdash/charts" \
  --dm-envelope "$TMP/dm.json" --field-map "$TMP/field-map.json" \
  --dm-id fixture-dm --folder-id fixture-folder \
  --out "$TMP/wb.json" --workbook-map-out "$TMP/workbook-map.json"
python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff \
  "$CASE_DIR/golden/workbook.json" "$TMP/wb.json"

# RLS gate: the fixture carries a sql_filter + required_attributes, so the
# un-acknowledged gate must stop (exit 2) and the acknowledged one must pass.
set +e
ruby "$SKILL/scripts/detect-rls.rb" --envelope "$TMP/dm.json" --out "$TMP/rls-plan.json"
gate=$?
set -e
test "$gate" -eq 2
ruby "$SKILL/scripts/detect-rls.rb" --envelope "$TMP/dm.json" --out "$TMP/rls-plan.json" --ack
ruby "$SKILL/scripts/apply-sigma-rls.rb" --plan "$TMP/rls-plan.json" --out "$TMP/rls-steps.json"

python3 - "$TMP/dm.json" "$TMP/workbook-map.json" "$TMP/rls-plan.json" <<'PY'
import json, sys
dm, wmap, plan = (json.load(open(p)) for p in sys.argv[1:])
assert dm["dialect"] == "bigquery"
assert "orders" in dm["security"]["models"]
assert len(wmap) == 6, "expected one workbook-map entry per chart"
assert plan["row_filters"], "expected a translated row filter"
print("     OK lightdash jaffle-orders DM, workbook, RLS gate")
PY
