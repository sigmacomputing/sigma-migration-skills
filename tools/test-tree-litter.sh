#!/usr/bin/env bash
# Offline test for the E0.2/E0.4 tree-litter rules (2026-07-18).
#
# Verifies:
#   Part A — skill-root ignore rules: synthetic workdir-*/, *.log, *.hyper, and
#            *.jsonl paths are ignored; corpus-path .hyper fixtures and
#            non-root .jsonl fixtures are NOT; repo-root hyperd*.log widened
#   Part B — tools/lint-tree-litter.sh passes the real tree, and no tracked
#            file is shadowed by the new ignore rules
#   Part C — the lint fails a fixture repo with a tracked workdir-x/state.json,
#            a tracked skill-tree *.log, a tracked registry .jsonl (any depth),
#            or a tracked skill-root *.jsonl; passes the clean fixture and a
#            tracked non-registry .jsonl below the skill root
#   Part D — CONTRIBUTING.md carries the "Run state stays local" contract
#            (section heading + registry filenames)
#
# Usage:  bash tools/test-tree-litter.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$ROOT/tools/lint-tree-litter.sh"
SKILL="plugins/tableau-to-sigma/skills/tableau-to-sigma"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

cd "$ROOT"

echo "Part A — ignore rules (git check-ignore on synthetic paths; no files created)"
git check-ignore -q "$SKILL/workdir-x/"; check $? "skill-root workdir-x/ is ignored"
git check-ignore -q "$SKILL/workdir-x/state.json"; check $? "file inside a skill-root workdir-*/ is ignored"
git check-ignore -q "$SKILL/x.log"; check $? "skill-root x.log is ignored"
git check-ignore -q "$SKILL/x.hyper"; check $? "skill-root x.hyper is ignored"
git check-ignore -q "$SKILL/scripts/extract-x.hyper"; check $? "nested skill-tree .hyper litter is ignored"
git check-ignore -q "$SKILL/probe-artifacts.jsonl"; check $? "skill-root probe-artifacts.jsonl is ignored"
git check-ignore -q "$SKILL/posted-workbooks.jsonl"; check $? "skill-root posted-workbooks.jsonl is ignored"
git check-ignore -q "$SKILL/offramps.jsonl"; check $? "skill-root offramps.jsonl is ignored"
git check-ignore -q "$SKILL/anything.jsonl"; check $? "any other skill-ROOT .jsonl is ignored"
git check-ignore -q "hyperd.log"; check $? "repo-root hyperd.log is ignored (widened hyperd*.log)"
git check-ignore -q "hyperd_123.log"; check $? "repo-root hyperd_123.log still ignored after widening"
! git check-ignore -q "corpus/tableau/case-x/fixture.hyper"
check $? "repo corpus/ .hyper fixture is NOT ignored (stays trackable)"
! git check-ignore -q "$SKILL/corpus/twin-x/fixture.hyper"
check $? "skill-local corpus/ .hyper fixture is NOT ignored (negation rule)"
! git check-ignore -q "$SKILL/schemas/x.jsonl"
check $? "non-root skill .jsonl (e.g. schemas/) is NOT ignored"

echo "Part B — lint passes the real tree; ignore rules shadow no tracked file"
bash "$LINT" >"$TMP/lint-real.out" 2>&1
check $? "lint-tree-litter exits 0 on the real tree"
shadowed="$(git ls-files -ci --exclude-standard)"
[ -z "$shadowed" ]; check $? "no tracked file is matched by the new ignore rules"

echo "Part C — lint verdicts in a fixture repo"
FIX="$TMP/fixture"
mkdir -p "$FIX" && git -C "$FIX" init -q
mkdir -p "$FIX/plugins/x/skills/y/scripts"
echo "ok" > "$FIX/plugins/x/skills/y/scripts/convert.rb"
git -C "$FIX" add .
( cd "$FIX" && bash "$LINT" ) >"$TMP/clean.out" 2>&1
check $? "clean fixture tree passes"

mkdir -p "$FIX/plugins/x/skills/y/workdir-x"
echo '{}' > "$FIX/plugins/x/skills/y/workdir-x/state.json"
git -C "$FIX" add .
( cd "$FIX" && bash "$LINT" ) >"$TMP/workdir.out" 2>&1
[ $? -ne 0 ]; check $? "tracked workdir-x/state.json fails the lint"
grep -q 'workdir-x/state.json' "$TMP/workdir.out"
check $? "failure names the tracked litter path"
git -C "$FIX" rm -q -r --cached plugins/x/skills/y/workdir-x

echo "log" > "$FIX/plugins/x/skills/y/run.log"
git -C "$FIX" add plugins/x/skills/y/run.log
( cd "$FIX" && bash "$LINT" ) >"$TMP/log.out" 2>&1
[ $? -ne 0 ]; check $? "tracked skill-tree *.log fails the lint"
git -C "$FIX" rm -q --cached plugins/x/skills/y/run.log

# Registries are litter at ANY depth (mirrors the unanchored ignore rules);
# a skill-ROOT .jsonl of any name is litter too, but a non-registry .jsonl
# below the root (e.g. schemas/) is legitimate and must pass.
echo '{}' > "$FIX/plugins/x/skills/y/scripts/probe-artifacts.jsonl"
git -C "$FIX" add plugins/x/skills/y/scripts/probe-artifacts.jsonl
( cd "$FIX" && bash "$LINT" ) >"$TMP/registry.out" 2>&1
[ $? -ne 0 ]; check $? "tracked nested probe-artifacts.jsonl fails the lint"
grep -q 'scripts/probe-artifacts.jsonl' "$TMP/registry.out"
check $? "failure names the tracked registry path"
git -C "$FIX" rm -q --cached plugins/x/skills/y/scripts/probe-artifacts.jsonl

echo '{}' > "$FIX/plugins/x/skills/y/anything.jsonl"
git -C "$FIX" add plugins/x/skills/y/anything.jsonl
( cd "$FIX" && bash "$LINT" ) >"$TMP/rootjsonl.out" 2>&1
[ $? -ne 0 ]; check $? "tracked skill-ROOT anything.jsonl fails the lint"
git -C "$FIX" rm -q --cached plugins/x/skills/y/anything.jsonl

mkdir -p "$FIX/plugins/x/skills/y/schemas"
echo '{}' > "$FIX/plugins/x/skills/y/schemas/shape.jsonl"
git -C "$FIX" add plugins/x/skills/y/schemas/shape.jsonl
( cd "$FIX" && bash "$LINT" ) >"$TMP/nested.out" 2>&1
check $? "tracked non-registry schemas/shape.jsonl still passes"

echo "Part D — CONTRIBUTING.md carries the run-state contract"
grep -q '^## Run state stays local' CONTRIBUTING.md
check $? "section heading 'Run state stays local' present"
for f in probe-artifacts.jsonl posted-workbooks.jsonl offramps.jsonl; do
  grep -q "$f" CONTRIBUTING.md; check $? "registry filename $f pinned"
done
grep -q '~/.tableau-to-sigma/' CONTRIBUTING.md
check $? "machine-local learned-rules home pinned"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
