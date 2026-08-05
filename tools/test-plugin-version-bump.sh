#!/usr/bin/env bash
# Offline test for tools/check-plugin-version-bump.sh (plugin version-bump gate,
# #486). test-converter-provenance.sh style: throwaway fixture git repos with
# synthetic plugin names (toolx) only — no field-derived identifiers.
#
#   Part A — bump discipline: unbumped plugin change fails; same change + strict
#            bump passes; a version DECREASE fails; a no-plugin-touched range
#            passes trivially
#   Part B — validity: a non-semver version fails; unparseable plugin.json fails
#   Part C — escape hatch: a Skip-Version-Bump:<reason> trailer exempts an
#            unbumped change; an empty-reason trailer does NOT
#   Part D — manifest lifecycle: a new plugin (no manifest at BASE) passes; a
#            marketplace-listed plugin with no manifest at HEAD fails; deleting
#            a manifest while the plugin stays listed fails
#   Part E — string-pin the real repo: every plugin listed in marketplace.json
#            carries a semver plugin.json (satisfied by the Task 1 backfill)
#
# Runs standalone:  bash tools/test-plugin-version-bump.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/check-plugin-version-bump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # expect-rc actual-rc message   (expect: 0=pass wanted, 1=fail wanted)
  if [ "$1" -eq "$2" ]; then printf '  PASS  %s\n' "$3"; else printf '  FAIL  %s (rc=%s)\n' "$3" "$2"; fails=$((fails+1)); fi
}

RC=0
run_guard() { bash "$GUARD" "$1" "$2" >"$TMP/out" 2>&1; RC=$?; }
passed() { [ "$RC" -eq 0 ] && echo 0 || echo 1; }   # 0 when guard passed
failed() { [ "$RC" -ne 0 ] && echo 0 || echo 1; }   # 0 when guard failed

new_repo() { rm -rf "$1"; mkdir -p "$1" && cd "$1" || exit 1; git init -q; git config user.email pvb@example.invalid; git config user.name pvb; git config commit.gpgsign false; }
commit_msg() { git add -A && git commit -q --no-verify -m "$1" >/dev/null && git rev-parse HEAD; }
manifest() { mkdir -p "$1/.claude-plugin"; printf '{ "name": "%s", "version": "%s", "skills": "./skills/" }\n' "$(basename "$1")" "$2" > "$1/.claude-plugin/plugin.json"; }
skill_file() { mkdir -p "plugins/$1/skills/$1"; echo "$2" > "plugins/$1/skills/$1/SKILL.md"; }

echo "Part A — bump discipline"
new_repo "$TMP/a"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'edit skill, no bump')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "unbumped plugin change fails"
grep -q "did not increase" "$TMP/out"; check 0 "$?" "failure names the missing bump"
manifest "plugins/toolx-to-sigma" "1.0.1"
H2="$(commit_msg 'bump to 1.0.1')"
run_guard "$BASE" "$H2"; check 0 "$(passed)" "same change + strict bump passes"

new_repo "$TMP/a_dec"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2; manifest "plugins/toolx-to-sigma" "0.9.0"
H1="$(commit_msg 'edit + decrease')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "version decrease fails"

new_repo "$TMP/a_none"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1; echo root > README.md
BASE="$(commit_msg base)"
echo root2 > README.md
H1="$(commit_msg 'root-only change')"
run_guard "$BASE" "$H1"; check 0 "$(passed)" "range touching no plugin dir passes"

echo "Part B — validity"
new_repo "$TMP/b_semver"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2; manifest "plugins/toolx-to-sigma" "1.0"
H1="$(commit_msg 'non-semver version')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "non-semver version fails"

new_repo "$TMP/b_json"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2; echo '{ not json' > plugins/toolx-to-sigma/.claude-plugin/plugin.json
H1="$(commit_msg 'broken json')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "unparseable plugin.json fails"

new_repo "$TMP/b_nonobject"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2; printf '[1,2,3]\n' > plugins/toolx-to-sigma/.claude-plugin/plugin.json
H1="$(commit_msg 'valid json, not an object')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "valid-but-non-object plugin.json fails"
grep -q "not valid JSON" "$TMP/out"; check 0 "$?" "non-object failure reports not-valid-JSON"
! grep -q "Traceback" "$TMP/out"; check 0 "$?" "non-object JSON does not leak a Python traceback"

echo "Part C — escape hatch"
new_repo "$TMP/c_ok"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'fix typo in a comment

Skip-Version-Bump: comment-only, no shipped behavior change')"
run_guard "$BASE" "$H1"; check 0 "$(passed)" "Skip-Version-Bump trailer with reason exempts"

new_repo "$TMP/c_empty"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'edit skill

Skip-Version-Bump:')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "empty-reason trailer does NOT exempt"

echo "Part D — manifest lifecycle"
new_repo "$TMP/d_new"
echo root > README.md
BASE="$(commit_msg base)"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
H1="$(commit_msg 'add new plugin')"
run_guard "$BASE" "$H1"; check 0 "$(passed)" "new plugin (no manifest at BASE) passes"

new_repo "$TMP/d_new_badver"
echo root > README.md
BASE="$(commit_msg base)"
manifest "plugins/toolx-to-sigma" "banana"; skill_file toolx-to-sigma v1
H1="$(commit_msg 'add new plugin with non-semver version')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "new plugin with non-semver version fails"
grep -q "not valid semver" "$TMP/out"; check 0 "$?" "failure names the non-semver version on a new manifest"

new_repo "$TMP/d_missing"
mkdir -p .claude-plugin
printf '{ "plugins": [ { "name": "toolx-to-sigma" } ] }\n' > .claude-plugin/marketplace.json
skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'edit listed plugin with no manifest')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "marketplace-listed plugin with no manifest fails"

new_repo "$TMP/d_delete"
mkdir -p .claude-plugin
printf '{ "plugins": [ { "name": "toolx-to-sigma" } ] }\n' > .claude-plugin/marketplace.json
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
rm plugins/toolx-to-sigma/.claude-plugin/plugin.json
H1="$(commit_msg 'delete manifest, still listed')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "deleting a manifest while still listed fails"

echo "Part E — string-pin the real repo"
python3 - "$ROOT" <<'PY'
import json, re, sys, pathlib
root = pathlib.Path(sys.argv[1])
mp = json.loads((root/".claude-plugin/marketplace.json").read_text())
bad = [p["name"] for p in mp["plugins"]
       if not re.match(r"^\d+\.\d+\.\d+$",
           (json.loads((root/"plugins"/p["name"]/".claude-plugin"/"plugin.json").read_text()).get("version","")
            if (root/"plugins"/p["name"]/".claude-plugin"/"plugin.json").exists() else ""))]
sys.exit(1 if bad else 0)
PY
check 0 "$?" "every marketplace-listed plugin carries a semver plugin.json"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
