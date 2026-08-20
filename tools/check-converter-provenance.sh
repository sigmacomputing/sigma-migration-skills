#!/usr/bin/env bash
# tools/check-converter-provenance.sh — converter-provenance diff-pairing guard
# (the standing vendoring rule made mechanical, 2026-07-18).
#
#   bash tools/check-converter-provenance.sh <BASE> <HEAD>
#
# A vendored converter bundle (plugins/**/converter/*.mjs) is a GENERATED
# artifact, never hand-edited. This guard makes that rule mechanical: it fails
# (exit 1) when the BASE..HEAD range:
#   1) changes a vendored converter bundle (plugins/**/converter/*.mjs) without
#      its sibling PROVENANCE.json changing in the same range — a regeneration
#      records itself there; an in-place patch records itself in local_patches.
#      In-skill converters (PROVENANCE has a "source" key — a static body
#      their rebuild rewrites byte-identical, so it can never diff) may pair
#      the bundle with a changed converter/*.ts source instead.
#   2) changes a converter PROVENANCE.json that no longer parses as JSON, or
#      whose local_patches entries drop the commit/summary/upstream_pr schema.
#   3) deletes a converter PROVENANCE.json while its bundle remains at HEAD.
#
# Callers resolve the range (hygiene.yml derives it from the CI event); the
# check itself is range-parameterized so tools/test-converter-provenance.sh
# can drive it against throwaway fixture repos offline.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "python3 missing — provenance guard cannot run"; exit 1; }

BASE="${1:?usage: check-converter-provenance.sh <BASE> <HEAD>}"
HEAD="${2:?usage: check-converter-provenance.sh <BASE> <HEAD>}"

# An unresolvable range must fail, not read as an empty (green) change list.
changed="$(git diff --name-only "$BASE" "$HEAD")" || { echo "git diff $BASE..$HEAD failed — cannot check provenance pairing"; exit 1; }
fail=0

# Subprocess-free membership test (#681): the old `printf ... | grep -qxF`
# form re-piped the full $changed list through grep on every lookup. grep -q
# exits the instant it finds a match, closing its end of the pipe; on a long
# list printf/the shell is often still mid-write when that happens, the next
# write() gets SIGPIPE, and `set -uo pipefail` (above) turns that signal into
# a false "not found" — non-deterministic, and it only fires once the list is
# long enough that the writer outlives the reader (latent on small diffs,
# firing on the large ranges #680's force-push bug produces). A case/glob
# match against the newline-delimited list needs no subprocess and can't race.
changed_has() {
  case $'\n'"$changed"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
at_head() { git cat-file -e "$HEAD:$1" 2>/dev/null; }
prov_kind() { # reads the HEAD copy; anything unparsable counts as vendored
  git show "$HEAD:$1" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("in-skill" if "source" in d else "vendored")
'
}

# Pass 1 — every changed bundle pairs with its provenance (or in-skill source).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  dir="$(dirname "$f")"
  sib="$dir/PROVENANCE.json"
  if changed_has "$sib" && at_head "$sib"; then
    continue
  fi
  if at_head "$sib" && [ "$(prov_kind "$sib")" = "in-skill" ]; then
    ts_paired=0
    while IFS= read -r c; do
      case "$c" in "$dir"/*.ts) ts_paired=1 ;; esac
    done <<< "$changed"
    [ "$ts_paired" -eq 1 ] && continue
    echo "::error file=$f::in-skill converter bundle changed without its converter/*.ts source (or PROVENANCE.json) changing — rebuild via tools/vendor-converters.sh from the edited TS source so bundle and source land together"
    fail=1
    continue
  fi
  echo "::error file=$f::vendored converter changed without its sibling PROVENANCE.json — regenerate via tools/vendor-converters.sh or record the in-place patch in local_patches"
  fail=1
done < <(printf '%s\n' "$changed" | grep -E '^plugins/.+/converter/[^/]+\.mjs$' || true)

# Pass 2 — schema-pin every changed converter PROVENANCE.json at HEAD.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! at_head "$p"; then
    if git ls-tree --name-only "$HEAD" "$(dirname "$p")/" 2>/dev/null | grep -q '\.mjs$'; then
      echo "::error file=$p::converter PROVENANCE.json deleted while the vendored bundle remains — restore it (the bundle's origin must stay recorded)"
      fail=1
    fi
    continue
  fi
  err="$(git show "$HEAD:$p" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as exc:
    print("not valid JSON (%s)" % exc); sys.exit(0)
lp = d.get("local_patches")
if lp is None:
    sys.exit(0)
if not isinstance(lp, list):
    print("local_patches must be an array"); sys.exit(0)
for i, entry in enumerate(lp):
    if not isinstance(entry, dict):
        print("local_patches[%d] must be an object" % i); sys.exit(0)
    missing = [k for k in ("commit", "summary", "upstream_pr") if k not in entry]
    if missing:
        print("local_patches[%d] missing key(s): %s" % (i, ", ".join(missing))); sys.exit(0)
')"
  if [ -n "$err" ]; then
    echo "::error file=$p::provenance schema pin failed — $err (every local_patches entry records commit, summary, upstream_pr)"
    fail=1
  fi
done < <(printf '%s\n' "$changed" | grep -E '^plugins/.+/converter/PROVENANCE\.json$' || true)

if [ "$fail" -ne 0 ]; then
  echo "converter-provenance guard FAILED (pair every converter/*.mjs change with its PROVENANCE.json)."
  exit 1
fi
echo "converter-provenance guard OK ($BASE..$HEAD)"
