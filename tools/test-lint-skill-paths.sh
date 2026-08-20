#!/usr/bin/env bash
# Self-test for tools/lint-skill-paths.rb — trip + no-false-trip.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixture tree that mirrors plugins/*/skills/*
skill_dir="$tmp/plugins/fake-to-sigma/skills/fake-to-sigma"
mkdir -p "$skill_dir/refs"

# --- no-false-trip: clean skill + allowed full-clone companion path ----------
cat >"$skill_dir/SKILL.md" <<'MD'
# Fake
Use the companion **sigma-workbooks** skill's `scripts/wb-rep.rb`
(full-clone: `plugins/sigma-authoring/skills/sigma-workbooks/scripts/wb-rep.rb`).
Phase mapping: `docs/phase-schema.md` (full clone only).
From this skill dir: `bash ../../../sigma-authoring/skills/sigma-workbooks/scripts/verify-workbook.sh ID`
MD

# Run lint against the temp tree by copying the linter and monkey-patching ROOT…
# Simpler: drop a throwaway bad file into the real tree under a temp plugin name,
# run, then delete — but that risks pollution. Instead invoke ruby -e that loads
# the rules… Keep it dumb: copy lint script and rewrite ROOT.

lint_copy="$tmp/lint-skill-paths.rb"
sed "s|ROOT = File.expand_path('..', __dir__)|ROOT = '${tmp}'|" \
  tools/lint-skill-paths.rb >"$lint_copy"
# Also neutralize the new-skill.rb scan (that path won't exist under tmp the same way —
# the script still looks for tools/new-skill.rb relative to ROOT; create a clean one.
mkdir -p "$tmp/tools"
echo '# clean' >"$tmp/tools/new-skill.rb"

if ! ruby "$lint_copy" >/tmp/lint-skill-paths-clean.out 2>&1; then
  echo "FAIL: expected clean fixture to pass" >&2
  cat /tmp/lint-skill-paths-clean.out >&2
  exit 1
fi

# --- trip: legacy path -------------------------------------------------------
echo 'see ~/sigma-skills/sigma-workbooks/SKILL.md' >>"$skill_dir/SKILL.md"
if ruby "$lint_copy" >/tmp/lint-skill-paths-trip.out 2>&1; then
  echo "FAIL: expected legacy path to trip the lint" >&2
  cat /tmp/lint-skill-paths-trip.out >&2
  exit 1
fi
grep -q 'legacy-sigma-skills-path' /tmp/lint-skill-paths-trip.out \
  || { echo "FAIL: missing rule id in trip output"; cat /tmp/lint-skill-paths-trip.out; exit 1; }

# --- trip: marketplace-unsafe docs relative ---------------------------------
rm -f "$skill_dir/SKILL.md"
echo '[x](../../../../docs/phase-schema.md)' >"$skill_dir/SKILL.md"
if ruby "$lint_copy" >/tmp/lint-skill-paths-docs.out 2>&1; then
  echo "FAIL: expected deep docs relative to trip" >&2
  exit 1
fi
grep -q 'marketplace-unsafe-docs-relative' /tmp/lint-skill-paths-docs.out

# --- trip: broken single-hop sigma-authoring relative -----------------------
echo 'bash ../sigma-authoring/skills/sigma-workbooks/scripts/x.sh' >"$skill_dir/SKILL.md"
if ruby "$lint_copy" >/tmp/lint-skill-paths-rel.out 2>&1; then
  echo "FAIL: expected ../sigma-authoring to trip" >&2
  exit 1
fi
grep -q 'broken-sigma-authoring-relative' /tmp/lint-skill-paths-rel.out

echo "OK: tools/test-lint-skill-paths.sh"
