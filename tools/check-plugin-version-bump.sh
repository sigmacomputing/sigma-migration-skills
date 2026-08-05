#!/usr/bin/env bash
# tools/check-plugin-version-bump.sh — plugin version-bump diff gate (#486).
#
#   bash tools/check-plugin-version-bump.sh <BASE> <HEAD>
#
# Fails (exit 1) when the BASE..HEAD range changes anything under
# plugins/<name>/** without that plugin's
# plugins/<name>/.claude-plugin/plugin.json "version" strictly increasing
# (semver) — UNLESS a `Skip-Version-Bump: <reason>` commit trailer (reason
# required) appears anywhere in the range (a genuinely non-user-facing change).
#
# Also fails when a plugin listed in .claude-plugin/marketplace.json has no
# versionable plugin.json at HEAD (a shipped plugin the update path can never
# refresh — e.g. a missing or deleted manifest), and when a plugin.json's
# version is not valid semver or the file is not valid JSON.
#
# A brand-new plugin (no plugin.json at BASE, one at HEAD) passes: its initial
# version is fine. A removed plugin (gone from marketplace.json at HEAD) passes.
#
# Callers resolve the range (hygiene.yml derives it from the CI event); the
# check is range-parameterized so tools/test-plugin-version-bump.sh can drive
# it against throwaway fixture repos offline.
set -uo pipefail

BASE="${1:?usage: check-plugin-version-bump.sh <BASE> <HEAD>}"
HEAD="${2:?usage: check-plugin-version-bump.sh <BASE> <HEAD>}"

command -v python3 >/dev/null 2>&1 || { echo "python3 missing — plugin-version-bump gate cannot run"; exit 1; }

changed="$(git diff --name-only "$BASE" "$HEAD")" || { echo "git diff $BASE..$HEAD failed — cannot check plugin versions"; exit 1; }

touched="$(printf '%s\n' "$changed" | sed -nE 's#^plugins/([^/]+)/.*#\1#p' | sort -u)"
if [ -z "$touched" ]; then echo "plugin-version-bump gate OK ($BASE..$HEAD): no plugin directories changed"; exit 0; fi

# Escape hatch: a Skip-Version-Bump: <reason> trailer (reason required) in any
# commit's full message across the range.
skip_reason=""; skip_commit=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  reason="$(git log -1 --format=%B "$sha" | sed -nE 's/^[Ss]kip-[Vv]ersion-[Bb]ump:[[:space:]]*(.+[^[:space:]])[[:space:]]*$/\1/p' | head -1)"
  if [ -n "$reason" ]; then skip_reason="$reason"; skip_commit="$sha"; break; fi
done < <(git rev-list "$BASE..$HEAD" 2>/dev/null)

# Print a plugin.json "version" from a ref; empty if the file is absent;
# __BADJSON__ if unparseable, OR valid JSON that is not an object (a dict is
# required for .get("version") to be safe — [1,2,3]/null/a bare string must
# never reach it); __NOVER__ if no non-empty string version.
read_version() { # ref name
  git show "$1:plugins/$2/.claude-plugin/plugin.json" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
if raw == "": sys.exit(0)
try: d = json.loads(raw)
except Exception: d = None
if not isinstance(d, dict): print("__BADJSON__"); sys.exit(0)
v = d.get("version")
print(v if isinstance(v, str) and v else "__NOVER__")
' 2>/dev/null
}

# strict semver-greater: exit 0 if head>base on (major,minor,patch); 1 if not;
# 2 if either side is not semver.
semver_gt() { # base head
  python3 -c '
import sys, re
def core(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", v or "")
    return tuple(int(x) for x in m.groups()) if m else None
b, h = core(sys.argv[1]), core(sys.argv[2])
if b is None or h is None: sys.exit(2)
sys.exit(0 if h > b else 1)
' "$1" "$2"
}

listed_at_head() { # name — is it in marketplace.json at HEAD?
  # An unparseable or non-object marketplace.json is treated as "not listed"
  # (fail-open by design here — marketplace.json's own integrity is outside
  # this gate's remit; it only decides whether the missing-manifest check
  # below applies).
  git show "$HEAD:.claude-plugin/marketplace.json" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = None
if not isinstance(d, dict): sys.exit(1)
sys.exit(0 if sys.argv[1] in [p.get("name") for p in d.get("plugins", [])] else 1)
' "$1" 2>/dev/null
}

fail=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  base_v="$(read_version "$BASE" "$name")"
  head_v="$(read_version "$HEAD" "$name")"

  if [ -z "$head_v" ]; then
    if listed_at_head "$name"; then
      echo "::error file=plugins/$name/.claude-plugin/plugin.json::plugin '$name' is listed in marketplace.json but has no plugin.json version at HEAD — it can never be updated; add a versioned manifest"
      fail=1
    fi
    continue
  fi
  if [ "$head_v" = "__BADJSON__" ]; then
    echo "::error file=plugins/$name/.claude-plugin/plugin.json::plugin.json is not valid JSON"; fail=1; continue
  fi
  if [ "$head_v" = "__NOVER__" ]; then
    echo "::error file=plugins/$name/.claude-plugin/plugin.json::plugin.json has no non-empty string \"version\" field"; fail=1; continue
  fi
  if [ -z "$base_v" ] || [ "$base_v" = "__BADJSON__" ] || [ "$base_v" = "__NOVER__" ]; then
    # New/first manifest: nothing to compare against, but head_v still has to
    # be valid semver — reuse semver_gt's own regex/idiom (a fixed, always-
    # parseable "0.0.0" base means rc=2 can only mean head_v itself doesn't
    # parse) rather than duplicating the semver check.
    semver_gt "0.0.0" "$head_v"; new_rc=$?
    if [ "$new_rc" -eq 2 ]; then
      echo "::error file=plugins/$name/.claude-plugin/plugin.json::version '$head_v' is not valid semver (MAJOR.MINOR.PATCH)"; fail=1; continue
    fi
    echo "plugin-version-bump: '$name' — new/first versioned manifest ($head_v), OK"; continue
  fi
  semver_gt "$base_v" "$head_v"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "plugin-version-bump: '$name' $base_v -> $head_v, OK"; continue; fi
  if [ "$rc" -eq 2 ]; then
    echo "::error file=plugins/$name/.claude-plugin/plugin.json::version '$head_v' (or base '$base_v') is not valid semver (MAJOR.MINOR.PATCH)"; fail=1; continue
  fi
  if [ -n "$skip_reason" ]; then
    echo "plugin-version-bump: '$name' version unchanged ($head_v) but exempted by Skip-Version-Bump in $skip_commit: $skip_reason"; continue
  fi
  echo "::error file=plugins/$name/.claude-plugin/plugin.json::'$name' changed under plugins/$name/** but version did not increase ($base_v -> $head_v). Bump it (strict semver), or add a 'Skip-Version-Bump: <reason>' commit trailer for a genuinely non-user-facing change."
  fail=1
done < <(printf '%s\n' "$touched")

if [ "$fail" -ne 0 ]; then
  echo "plugin-version-bump gate FAILED — see ::error annotations above (#486 release hygiene)."
  exit 1
fi
echo "plugin-version-bump gate OK ($BASE..$HEAD)"
