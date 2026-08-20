#!/usr/bin/env bash
# orders-report — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. schemaVersion assertion (Critical C2 fix, final-review wave): every
#      spec build-dm.rb / build-mode-workbook.rb assembles for a fresh CREATE
#      must carry schemaVersion: 1 -- omitting it is a guaranteed 400 on the
#      very first live POST ("schemaVersion: Invalid 1: undefined"). A plain
#      MANIFEST goldens counts check (pages/elements/columns/...) can't see
#      this at all -- schemaVersion isn't a page, element, or column -- so
#      this assertion is the only thing standing between a regression here
#      and a silent re-break.
#   2. both scripts reconvert byte-identical (after id-normalization) to the
#      committed goldens -- pins the [Custom SQL/...] DM self-reference
#      formula prefix (build-dm.rb) and the display-name-bound chart
#      formulas (build-mode-workbook.rb, via fixtures/dm-elements.json's
#      columns[] array) so neither C1 fix regresses silently either.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/mode-to-sigma/skills/mode-to-sigma"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

(cd "$SKILL" && ruby scripts/build-dm.rb --report-json test/fixtures/report-fixture.json \
  --connection-id conn-test --folder-id folder-test --out "$TMP/dm-spec.json" --skip-reuse-check) \
  >"$TMP/build-dm.out" 2>&1 || { note "FAIL: build-dm.rb exited non-zero:"; cat "$TMP/build-dm.out"; fail=1; }

(cd "$SKILL" && ruby scripts/build-mode-workbook.rb --report-json test/fixtures/report-fixture.json \
  --dm-elements "$CASE_DIR/fixtures/dm-elements.json" --folder-id folder-test --out "$TMP/wb-spec.json") \
  >"$TMP/build-wb.out" 2>&1 || { note "FAIL: build-mode-workbook.rb exited non-zero:"; cat "$TMP/build-wb.out"; fail=1; }

if [ "$fail" -eq 0 ]; then
  # -- 1. schemaVersion present on both fresh CREATE-path specs --------------
  # The data-model code-rep surface is unchanged (flat, top-level
  # schemaVersion); the workbook surface nests it under `document`
  # (shared workbook-code-release migration, shared/lib/code_rep.rb) --
  # Sigma::CodeRep.wrap is what puts it there.
  v=$(ruby -rjson -e "print JSON.parse(File.read(ARGV[0]))['schemaVersion'].inspect" "$TMP/dm-spec.json")
  if [ "$v" = "1" ]; then
    note "ok: dm-spec.json carries schemaVersion: 1"
  else
    note "FAIL: dm-spec.json schemaVersion is $v, expected 1 (POST /v2/dataModels/spec 400s without it)"
    fail=1
  fi
  v=$(ruby -rjson -e "print JSON.parse(File.read(ARGV[0])).dig('document', 'schemaVersion').inspect" "$TMP/wb-spec.json")
  if [ "$v" = "1" ]; then
    note "ok: wb-spec.json carries document.schemaVersion: 1"
  else
    note "FAIL: wb-spec.json document.schemaVersion is $v, expected 1 (POST /v2/workbooks/spec 400s without it)"
    fail=1
  fi

  # -- 2. byte-stable reconvert against the committed goldens ----------------
  python3 "$REPO_ROOT/corpus/lib/corpus_check.py" normalize "$TMP/dm-spec.json" "$TMP/dm-spec.norm.json" >/dev/null
  python3 "$REPO_ROOT/corpus/lib/corpus_check.py" normalize "$TMP/wb-spec.json" "$TMP/wb-spec.norm.json" >/dev/null
  if cmp -s "$TMP/dm-spec.norm.json" "$CASE_DIR/golden/data-model.json"; then
    note "ok: build-dm.rb reconverts byte-identical to golden/data-model.json (pins [Custom SQL/...] formulas)"
  else
    note "FAIL: build-dm.rb drifted from golden/data-model.json:"
    diff "$CASE_DIR/golden/data-model.json" "$TMP/dm-spec.norm.json" | head -20
    fail=1
  fi
  if cmp -s "$TMP/wb-spec.norm.json" "$CASE_DIR/golden/workbook.json"; then
    note "ok: build-mode-workbook.rb reconverts byte-identical to golden/workbook.json (pins display-name-bound chart formulas)"
  else
    note "FAIL: build-mode-workbook.rb drifted from golden/workbook.json:"
    diff "$CASE_DIR/golden/workbook.json" "$TMP/wb-spec.norm.json" | head -20
    fail=1
  fi
fi

exit "$fail"
