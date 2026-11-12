#!/usr/bin/env bash
# page-facts-multipage — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
# The page-fact path of powerbi-to-sigma on the synthetic three-page fixture
# (plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/page-facts):
#   1. scaffold-page-fact.py --all-pages: the page classification and each page's page-fact SQL
#      are byte-identical to the pinned goldens;
#   2. integrate-page-fact.py: the integrated DM spec and master-map (page_fields) are pinned;
#   3. build-workbook-from-pbir.rb + wire-slicer-gate.py: the gated workbook spec and the gate
#      report are pinned, and the result passes the skill's preflight, spec and control lints;
#   4. check_sqlite.py: the generated SQL executed in SQLite: page fact = independent oracle on
#      every page, gated SQL with every control empty = page fact, and three slicer picks
#      (one hop, a two-hop (Blank), a USERELATIONSHIP bridge) answer like the oracle.
# Regenerate the goldens after an intended change with: bash checks.sh --update
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/powerbi-to-sigma/skills/powerbi-to-sigma"
S="$SKILL/scripts"
FIX="$SKILL/fixtures/page-facts"
G="$CASE_DIR/golden"
CONN=00000000-0000-4000-8000-00000000c0de
UPDATE="${1:-}"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the builder and lints)"; exit 1; }
command -v python3 >/dev/null || { echo "checks: python3 not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
pin() { # pin <fresh> <golden> <label>
  if [ "$UPDATE" = "--update" ]; then mkdir -p "$(dirname "$2")"; cp "$1" "$2"; echo "     updated $3"; return; fi
  if cmp -s "$1" "$2"; then echo "     ok   $3"; else echo "     FAIL $3 differs from golden:"; diff -u "$2" "$1" | head -40; fail=1; fi
}
run() { # run <label> <cmd...>
  if "${@:2}" >"$TMP/last.out" 2>&1; then :; else echo "     FAIL $1"; tail -20 "$TMP/last.out"; fail=1; fi
}

cp "$FIX/dm-spec.json" "$FIX/master-map.json" "$TMP/"
start=$(python3 -c 'import time; print(time.time())')

run "scaffold-page-fact.py" python3 "$S/scaffold-page-fact.py" --model "$FIX/model.bim" --signals "$FIX/signals.json" \
  --dm-spec "$TMP/dm-spec.json" --master-map "$TMP/master-map.json" --out-dir "$TMP/pf" --all-pages \
  --scenario "Store.Region=West" --scenario "Manager.Manager Name=(Blank)" --scenario "Supplier.Supplier Name=Acme"
pin "$TMP/pf/page-closure.json" "$G/page-closure.json" "page classification (page-closure.json)"
for p in sales-overview stock-cover rollup; do
  pin "$TMP/pf/$p/page-fact.sql" "$G/page-facts/$p/page-fact.sql" "page-fact SQL: $p"
done

run "integrate (DM)" python3 "$S/integrate-page-fact.py" "$TMP/pf" --dm-spec "$TMP/dm-spec.json" --connection "$CONN" --allow-todo
run "integrate (master-map)" python3 "$S/integrate-page-fact.py" "$TMP/pf" --master-map "$TMP/master-map.json" --allow-todo
pin "$TMP/dm-spec.json" "$G/dm-spec.integrated.json" "integrated DM spec (3 page-fact elements)"
pin "$TMP/master-map.json" "$G/master-map.integrated.json" "integrated master-map (page_fields)"

run "build-workbook-from-pbir.rb" ruby "$S/build-workbook-from-pbir.rb" --signals "$FIX/signals.json" --master-map "$TMP/master-map.json" \
  --data-model dm-fixture --name "Page Facts Fixture" --model "$FIX/model.bim" \
  --control-scope-out "$TMP/control-scope.json" --coverage-out "$TMP/coverage.json" --out "$TMP/workbook-spec.json" \
  --layout-out "$TMP/layout.xml" --folder-id 00000000-0000-4000-8000-0000000f01d0
run "wire-slicer-gate.py" python3 "$S/wire-slicer-gate.py" --spec "$TMP/workbook-spec.json" --page-facts "$TMP/pf" \
  --model "$FIX/model.bim" --dm-spec "$TMP/dm-spec.json" --master-map "$TMP/master-map.json" --connection "$CONN" \
  --control-scope "$TMP/control-scope.json" --layout-out "$TMP/layout.xml" --report "$TMP/slicer-gate.json" \
  --verify-out "$TMP/slicer-gate-verify.json"
end=$(python3 -c 'import time; print(time.time())')
pin "$TMP/workbook-spec.json" "$G/workbook-spec.gated.json" "gated workbook spec"
pin "$TMP/slicer-gate.json" "$G/slicer-gate.json" "slicer-gate report"

lint_fail=$fail
run "preflight lint" ruby "$S/lib/preflight_lint.rb" "$TMP/workbook-spec.json"
run "validate-spec (workbook)" ruby "$S/validate-spec.rb" --type workbook "$TMP/workbook-spec.json"
run "control lint (with control-scope sidecar)" ruby "$S/lib/control_lint.rb" "$TMP/workbook-spec.json" "$TMP/control-scope.json"
[ "$fail" -eq "$lint_fail" ] && echo "     ok   preflight, validate-spec and control lint are clean"

python3 "$CASE_DIR/check_sqlite.py" "$FIX/seed.sql" "$TMP/pf" "$TMP" "$S/parity-from-oracle.py" || fail=1
python3 -c "print('     info automated page-fact path (scaffold + integrate + build + gate, 3 pages): %.2fs' % ($end - $start))"
exit "$fail"
