#!/usr/bin/env bash
# Self-test: tools/new-skill.rb stamps plugin.json, marketplace, AGENTS.md.
# Scaffolds a throwaway tool then deletes it and restores index files.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

TOOL="zzfixture"
PLUGIN="plugins/${TOOL}-to-sigma"
abort_cleanup() {
  echo "FAIL: $*" >&2
  rm -rf "$PLUGIN"
  git checkout -- .claude-plugin/marketplace.json AGENTS.md docs/phase-schema.md shared/manifest.json 2>/dev/null || true
  exit 1
}

# Refuse to run if a previous fixture leaked.
if [ -d "$PLUGIN" ]; then
  echo "FAIL: ${PLUGIN} already exists — remove it before running this test" >&2
  exit 1
fi

# Snapshot files the scaffolder mutates (beyond the new plugin tree).
cp .claude-plugin/marketplace.json /tmp/marketplace.json.bak
cp AGENTS.md /tmp/AGENTS.md.bak
cp docs/phase-schema.md /tmp/phase-schema.md.bak
cp shared/manifest.json /tmp/manifest.json.bak

ruby tools/new-skill.rb "$TOOL" "Zz Fixture" >/tmp/new-skill-out.txt \
  || abort_cleanup "new-skill.rb exited non-zero"

# --- assertions --------------------------------------------------------------
[ -f "$PLUGIN/.claude-plugin/plugin.json" ] || abort_cleanup "missing plugin.json"
[ -f "$PLUGIN/skills/${TOOL}-to-sigma/SKILL.md" ] || abort_cleanup "missing converter SKILL.md"
[ -f "$PLUGIN/skills/${TOOL}-assessment/SKILL.md" ] || abort_cleanup "missing assessment SKILL.md"

grep -q "\"name\": \"${TOOL}-to-sigma\"" .claude-plugin/marketplace.json \
  || abort_cleanup "marketplace.json missing plugin entry"
grep -q "\`${TOOL}-to-sigma\`" AGENTS.md \
  || abort_cleanup "AGENTS.md missing converter row"
grep -q "\`${TOOL}-assessment\`" AGENTS.md \
  || abort_cleanup "AGENTS.md missing assessment row"
grep -q "## ${TOOL}-to-sigma (scaffolded" docs/phase-schema.md \
  || abort_cleanup "phase-schema.md missing coverage section"

# Marketplace-unsafe docs relative must not be reintroduced.
if grep -q '\](\.\./\.\./\.\./\.\./docs/' "$PLUGIN/skills/${TOOL}-to-sigma/SKILL.md"; then
  abort_cleanup "scaffold reintroduced marketplace-unsafe docs relative"
fi

# JSON validity
python3 -c "import json; json.load(open('.claude-plugin/marketplace.json'))" \
  || abort_cleanup "marketplace.json is not valid JSON after append"
python3 -c "import json; json.load(open('${PLUGIN}/.claude-plugin/plugin.json'))" \
  || abort_cleanup "plugin.json is not valid JSON"

# --- cleanup -----------------------------------------------------------------
rm -rf "$PLUGIN"
mv /tmp/marketplace.json.bak .claude-plugin/marketplace.json
mv /tmp/AGENTS.md.bak AGENTS.md
mv /tmp/phase-schema.md.bak docs/phase-schema.md
mv /tmp/manifest.json.bak shared/manifest.json

echo "OK: tools/test-new-skill-registry.sh"
