#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/qlik-to-sigma/skills/qlik-to-sigma"

python3 "$SKILL/tests/test_corectl_unbuild.py"
ruby "$SKILL/scripts/test-preflight-warehouse.rb"
