#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/powerbi-to-sigma/skills/powerbi-to-sigma"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ruby "$SKILL/scripts/build-workbook-from-pbir.rb" \
  --signals "$CASE_DIR/signals.json" \
  --master-map "$CASE_DIR/master-map.json" \
  --data-model dm-release \
  --layout pbi \
  --layout-out "$TMP/layout.xml" \
  --name "Power BI Workbook Code Release" \
  --out "$TMP/workbook.json"

cmp "$CASE_DIR/golden/workbook.json" "$TMP/workbook.json"
ruby "$SKILL/scripts/validate-spec.rb" --type workbook "$TMP/workbook.json"
python3 "$CASE_DIR/check_workbook.py" "$TMP/workbook.json"
