#!/usr/bin/env bash
# Offline test for the .githooks/commit-msg hygiene guard (2026-07-18).
#
# Runs the REAL hook script against a throwaway fixture repo with fixture
# pattern files (neutral strings that match nothing in this repo), so no real
# guard pattern ever appears in this file. Verifies:
#   Part A — clean message passes; hook is executable
#   Part B — a planted blocked pattern fails, reporting the pattern-file LINE
#            NUMBER only (matched text withheld), case-insensitively
#   Part C — the gitignored local pattern file is sourced when present
#   Part D — the scissors line bounds the scan (commit --verbose diff stays
#            exempt), but comment-prefixed lines ABOVE it ARE scanned:
#            `git commit -m`/`-F` (cleanup=whitespace) KEEP such lines in the
#            landed message, so a hit fails — flagged with a comment-line
#            caveat since editor-flow template comments get stripped on edit.
#            Honors a custom core.commentChar
#   Part E — graceful skip when no pattern file exists (older checkout)
#   Part F — CONTRIBUTING.md carries the guard doc + the history decision
#            (counts only)
#   Part G — the hook doubles as the CI push-range engine: looping
#            `git rev-list BASE..HEAD` and feeding each commit's %B to the
#            hook flags the planted message, line number only
#
# Usage:  bash tools/test-commit-msg-guard.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/.githooks/commit-msg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

# Fixture repo with fixture patterns: comment on line 1, patterns on lines 2
# and 4 (blank line 3) — line-number reporting is part of the contract.
FIX="$TMP/fixture"
mkdir -p "$FIX/tools" && git -C "$FIX" init -q
{
  echo '# fixture guards (neutral strings, must match nothing real)'
  echo 'zebrafish-9000'
  echo ''
  echo 'quagga-7777'
} > "$FIX/tools/hygiene-patterns.txt"

run_hook() { # msgfile -> hook rc; output in $TMP/hook.out
  ( cd "$FIX" && bash "$HOOK" "$1" ) >"$TMP/hook.out" 2>&1
}

echo "Part A — clean message passes"
[ -x "$HOOK" ]; check $? "hook file is executable (git runs it via core.hooksPath)"
printf 'tableau: add tree-litter lint\n\nDetails here.\n' > "$TMP/clean.msg"
run_hook "$TMP/clean.msg"
check $? "clean message exits 0"

echo "Part B — planted pattern fails with line number only"
printf 'wire the zebrafish-9000 endpoint\n' > "$TMP/hit.msg"
run_hook "$TMP/hit.msg"
[ $? -ne 0 ]; check $? "message with a blocked pattern exits non-zero"
grep -q 'tools/hygiene-patterns.txt:2' "$TMP/hook.out"
check $? "failure cites the pattern file + line number (line 2)"
! grep -qi 'zebrafish' "$TMP/hook.out"
check $? "matched text is withheld from the output"

printf 'WIRE THE ZEBRAFISH-9000 ENDPOINT\n' > "$TMP/upper.msg"
run_hook "$TMP/upper.msg"
[ $? -ne 0 ]; check $? "match is case-insensitive (sweep parity)"

printf 'zebrafish-9000 then quagga-7777\n' > "$TMP/two.msg"
run_hook "$TMP/two.msg"
[ $? -ne 0 ]; check $? "multiple hits exit non-zero"
grep -q 'tools/hygiene-patterns.txt:2' "$TMP/hook.out" && grep -q 'tools/hygiene-patterns.txt:4' "$TMP/hook.out"
check $? "every hit pattern's line number is reported (2 and 4)"

echo "Part C — local pattern file is sourced when present"
echo 'okapi-1234' > "$FIX/tools/hygiene-patterns.local.txt"
printf 'roll out okapi-1234 support\n' > "$TMP/local.msg"
run_hook "$TMP/local.msg"
[ $? -ne 0 ]; check $? "pattern known only to the local file exits non-zero"
grep -q 'tools/hygiene-patterns.local.txt:1' "$TMP/hook.out"
check $? "failure cites the LOCAL file + line number"
! grep -qi 'okapi' "$TMP/hook.out"
check $? "local-guard matched text is withheld (disclosure-safe)"
rm -f "$FIX/tools/hygiene-patterns.local.txt"

echo "Part D — scissors cut applies; comment-prefixed lines ARE scanned"
# `git commit -m`/`-F` (cleanup=whitespace) KEEP '#'-lines in the landed
# message, so a hit on one must fail — with the comment-line caveat, redacted.
printf 'clean subject\n\n# scratch note: zebrafish-9000\n' > "$TMP/comment.msg"
run_hook "$TMP/comment.msg"
[ $? -ne 0 ]; check $? "pattern on a '#' comment line FAILS (-m/-F keeps such lines)"
grep -q 'comment-prefixed line' "$TMP/hook.out"
check $? "comment-line hit is called out as such (false-positive guidance)"
grep -q 'tools/hygiene-patterns.txt:2' "$TMP/hook.out"
check $? "comment-line hit still cites the pattern file + line number"
! grep -qi 'zebrafish' "$TMP/hook.out"
check $? "comment-line hit withholds the matched text"
{
  printf 'clean subject\n\n'
  printf '# ------------------------ >8 ------------------------\n'
  printf 'diff hunk mentioning zebrafish-9000\n'
} > "$TMP/scissors.msg"
run_hook "$TMP/scissors.msg"
check $? "pattern below the scissors line passes (commit --verbose diff)"

# Custom comment char: ';'-lines get the same treatment (kept by -m/-F, so
# scanned + caveat), and literal '#' lines are plain CONTENT under that
# config — a hard failure with no comment-line caveat.
git -C "$FIX" config core.commentChar ';'
printf 'clean subject\n\n; scratch note: zebrafish-9000\n' > "$TMP/semi.msg"
run_hook "$TMP/semi.msg"
[ $? -ne 0 ]; check $? "';' comment line FAILS under commentChar ';'"
grep -q 'comment-prefixed line' "$TMP/hook.out"
check $? "';' hit carries the comment-line caveat"
printf 'clean subject\n\n# heading with zebrafish-9000\n' > "$TMP/hash-content.msg"
run_hook "$TMP/hash-content.msg"
[ $? -ne 0 ]; check $? "'#' line is scanned as content when commentChar is ';'"
! grep -q 'comment-prefixed line' "$TMP/hook.out"
check $? "content '#' hit is a hard failure (no comment-line caveat)"
git -C "$FIX" config core.commentChar auto
printf 'clean subject\n\n# scratch note: zebrafish-9000\n' > "$TMP/auto.msg"
run_hook "$TMP/auto.msg"
[ $? -ne 0 ]; check $? "commentChar=auto falls back to '#' (comment line still scanned)"
git -C "$FIX" config --unset core.commentChar

echo "Part E — graceful skip on an older checkout"
BARE="$TMP/bare-fixture"
mkdir -p "$BARE" && git -C "$BARE" init -q
printf 'any message\n' > "$TMP/any.msg"
( cd "$BARE" && bash "$HOOK" "$TMP/any.msg" ) >/dev/null 2>&1
check $? "no pattern file => exit 0 (nothing to enforce)"

echo "Part F — CONTRIBUTING.md guard doc + history decision (counts only)"
cd "$ROOT"
grep -q '\.githooks/commit-msg' CONTRIBUTING.md
check $? "commit-msg guard documented in CONTRIBUTING.md"
grep -q 'History decision' CONTRIBUTING.md
check $? "history decision note present"
grep -q '25 commits' CONTRIBUTING.md
check $? "decision records the affected-commit COUNT (25, re-measured 2026-07-22)"
grep -q 'do not rewrite history' CONTRIBUTING.md
check $? "decision states the rewrite-vs-accept outcome"

echo "Part G — hook doubles as the CI push-range engine (rev-list %B loop)"
RANGE="$TMP/range-fixture"
mkdir -p "$RANGE/tools" && git -C "$RANGE" init -q
cp "$FIX/tools/hygiene-patterns.txt" "$RANGE/tools/hygiene-patterns.txt"
gitc() { git -C "$RANGE" -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }
gitc commit -q --allow-empty -m 'base commit'
BASE_SHA="$(git -C "$RANGE" rev-parse HEAD)"
gitc commit -q --allow-empty -m 'clean follow-up'
gitc commit -q --allow-empty -m 'wire the zebrafish-9000 endpoint'
range_fail=0
: > "$TMP/range.out"
while IFS= read -r sha; do
  git -C "$RANGE" log -1 --format=%B "$sha" > "$TMP/range-msg.txt"
  ( cd "$RANGE" && bash "$HOOK" "$TMP/range-msg.txt" ) >>"$TMP/range.out" 2>&1 || range_fail=1
done < <(git -C "$RANGE" rev-list "$BASE_SHA..HEAD")
[ "$range_fail" -eq 1 ]; check $? "planted message inside BASE..HEAD fails the range loop"
grep -q 'tools/hygiene-patterns.txt:2' "$TMP/range.out"
check $? "range failure cites the pattern line number"
! grep -qi 'zebrafish' "$TMP/range.out"
check $? "range failure withholds matched text (CI-log safe)"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
