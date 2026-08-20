#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$ROOT/plugins/gooddata-to-sigma/skills/gooddata-to-sigma"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 "$SKILL/scripts/build_workbook.py" \
  --workspace "$SKILL/fixtures/test_workspace_orders.json" \
  --data-model-id inode-DM000000 \
  --fact-element inode-ELEMENT00 \
  --fact-name ORDER_FACT \
  --rel-name CUSTOMER_DIM \
  --fact-dataset order \
  --folder-id inode-FOLDER00 \
  --out "$TMP/workbook.json"

cmp "$CASE_DIR/golden/workbook.json" "$TMP/workbook.json"
python3 "$SKILL/tests/test_workbook_code_release.py"
