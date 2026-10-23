#!/usr/bin/env bash
# Credential-free doctor auth/JSON regression tests.
# Run: bash scripts/test-doctor-json.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() {
  if [ "$1" -eq 0 ]; then
    printf '  PASS  %s\n' "$2"
  else
    printf '  FAIL  %s\n' "$2"
    fails=$((fails+1))
  fi
}

# A developer machine may have a real, signed-in `sigma` on PATH. Shadow it with
# a stub that is not the Sigma CLI so only the cases below that opt in see one.
mkdir -p "$TMP/no-sigma-cli"
printf '#!/bin/sh\nexit 2\n' > "$TMP/no-sigma-cli/sigma"
chmod +x "$TMP/no-sigma-cli/sigma"
export PATH="$TMP/no-sigma-cli:$PATH"

COMMON=(SIGMA_SKIP_VERSION_CHECK=1 SIGMA_SKIP_CRED_SMOKE=1)
BASE=https://api.sigmacomputing.com

echo "Part A — missing auth fails closed and doctor.json remains secret-free"
mkdir -p "$TMP/home-missing"
env HOME="$TMP/home-missing" "${COMMON[@]}" \
  SIGMA_BASE_URL= SIGMA_API_TOKEN= SIGMA_CLIENT_ID= SIGMA_CLIENT_SECRET= \
  bash "$HERE/doctor.sh" --workdir "$TMP/missing" >"$TMP/missing.out" 2>&1
rc=$?
[ "$rc" -ne 0 ]; check $? "missing Sigma auth exits non-zero"
grep -q 'no usable Sigma authentication found (REQUIRED' "$TMP/missing.out"
check $? "failure names the usable-auth requirement"
grep -q 'browser-login.sh' "$TMP/missing.out"
check $? "remediation recommends explicit browser login"
grep -Eq 'setup\.(rb|py)|SIGMA_CLIENT_ID' "$TMP/missing.out"
check $? "remediation retains unattended client fallback"
python3 - "$TMP/missing/doctor.json" "$rc" <<'PY'
import datetime, json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rc = int(sys.argv[2])
required = {
    "os", "shell", "runtimes", "versions", "runtime_profile",
    "sandbox_hint", "cred_smoke", "sigma_auth_method",
    "hyperapi_present", "skill_sha", "behind_count", "days_since_commit",
    "agent_vision", "model_hint", "generated_at", "pass", "failures",
}
assert required <= set(d), required - set(d)
assert set(d["cred_smoke"]) == {"sigma", "tableau", "looker"}
assert d["cred_smoke"]["sigma"] == "skipped"
assert d["sigma_auth_method"] == "none"
assert d["pass"] == (rc == 0) == (not d["failures"])
assert "SIGMA_API_TOKEN" not in d and "SIGMA_CLIENT_SECRET" not in d
datetime.datetime.strptime(d["generated_at"], "%Y-%m-%dT%H:%M:%SZ")
PY
check $? "doctor.json records missing status/method without credential fields"

echo "Part B — client credentials, current tokens, and keychain-only sessions qualify"
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_CLIENT_ID=client-id SIGMA_CLIENT_SECRET=client-secret \
  bash "$HERE/doctor.sh" --workdir "$TMP/client" >"$TMP/client.out" 2>&1
python3 - "$TMP/client/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["cred_smoke"]["sigma"] == "skipped", d
assert d["sigma_auth_method"] == "client-credentials", d
assert not any("Sigma authentication" in value for value in d["failures"])
PY
check $? "client configuration records skipped/client-credentials"

mkdir -p "$TMP/token-keychain-probe"
cat > "$TMP/token-keychain-probe/secret-tool" <<SH
#!/bin/sh
printf probed > "$TMP/token-keychain-probed"
exit 1
SH
chmod +x "$TMP/token-keychain-probe/secret-tool"
env HOME="$TMP/home-missing" PATH="$TMP/token-keychain-probe:$PATH" \
  "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-secret-token SIGMA_CLIENT_ID= SIGMA_CLIENT_SECRET= \
  bash "$HERE/doctor.sh" --workdir "$TMP/token" >"$TMP/token.out" 2>&1
python3 - "$TMP/token/doctor.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
d = json.loads(raw)
assert d["cred_smoke"]["sigma"] == "skipped", d
assert d["sigma_auth_method"] == "api-token", d
assert "current-secret-token" not in raw
PY
check $? "current token records skipped/api-token without the token"
[ ! -e "$TMP/token-keychain-probed" ]
check $? "current token is accepted without probing the keychain"

mkdir -p "$TMP/home-browser/.sigma-migration" "$TMP/keychain-bin"
printf "export SIGMA_BASE_URL='%s'\n" "$BASE" > "$TMP/home-browser/.sigma-migration/env"
# macOS prefers `security` over `secret-tool`, so shim both for a portable test.
cat > "$TMP/keychain-bin/security" <<'SH'
#!/bin/sh
[ "$1" = find-generic-password ] && case " $* " in *" sigma-api:refresh-token "*) exit 0 ;; esac
exit 1
SH
chmod +x "$TMP/keychain-bin/security"
cat > "$TMP/keychain-bin/secret-tool" <<'SH'
#!/bin/sh
[ "$1" = lookup ] && [ "$2 $3 $4 $5" = "service sigma-api key refresh-token" ]
SH
chmod +x "$TMP/keychain-bin/secret-tool"
env HOME="$TMP/home-browser" PATH="$TMP/keychain-bin:$PATH" "${COMMON[@]}" \
  bash "$HERE/doctor.sh" --workdir "$TMP/browser" >"$TMP/browser.out" 2>&1
python3 - "$TMP/browser/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["cred_smoke"]["sigma"] == "skipped", d
assert d["sigma_auth_method"] == "browser", d
assert not any("Sigma authentication" in value for value in d["failures"])
PY
check $? "keychain-only session + base URL records skipped/browser"

echo "Part C — live smoke is GET /v2/whoami through sigma_rest"
mkdir -p "$TMP/fixture/scripts/lib" "$TMP/home-live"
cp "$HERE/doctor.sh" "$TMP/fixture/scripts/doctor.sh"
cp "$HERE/runtime_profile.py" "$TMP/fixture/scripts/runtime_profile.py"
cat > "$TMP/fixture/runtime-capabilities.json" <<'JSON'
{
  "schemaVersion": 1,
  "skill": "doctor-auth-fixture",
  "profiles": {
    "python": {
      "status": "supported",
      "requiredRuntimes": ["python", "node"],
      "entrypoint": ["python", "scripts/runtime_profile.py"]
    }
  }
}
JSON
cat > "$TMP/fixture/scripts/lib/sigma_rest.py" <<'PY'
import os

def request(method, path):
    with open(os.environ["SIGMA_DOCTOR_SMOKE_MARKER"], "w", encoding="utf-8") as handle:
        handle.write(f"{method} {path}")
    os.environ["SIGMA_AUTH_METHOD"] = "browser"
    return {}

def refresh_token():
    raise AssertionError("doctor must verify through request, not direct mint")
PY
env HOME="$TMP/home-live" SIGMA_SKIP_VERSION_CHECK=1 SIGMA_SKIP_CRED_SMOKE= \
  SIGMA_RUNTIME_PROFILE=python \
  SIGMA_BASE_URL="$BASE" SIGMA_API_TOKEN=expired-secret-token \
  SIGMA_DOCTOR_SMOKE_MARKER="$TMP/smoke.marker" \
  bash "$TMP/fixture/scripts/doctor.sh" --workdir "$TMP/live" >"$TMP/live.out" 2>&1
rc=$?
[ "$rc" -eq 0 ]; check $? "fixture live smoke passes"
[ "$(cat "$TMP/smoke.marker" 2>/dev/null)" = "get /v2/whoami" ]
check $? "shared REST request receives GET /v2/whoami"
python3 - "$TMP/live/doctor.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
d = json.loads(raw)
assert d["cred_smoke"]["sigma"] == "pass", d
assert d["sigma_auth_method"] == "browser", d
assert "expired-secret-token" not in raw
PY
check $? "live doctor.json records pass/browser without the token"

echo "Part C2 — the Sigma CLI is an accepted Sigma auth path (noninteractive)"
CLI_BASE=https://aws-api.sigmacomputing.com
CLI_JWT=eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl
mkdir -p "$TMP/cli-bin" "$TMP/home-cli"
# A keychain tool that never has a session, so browser auth cannot mask the CLI.
for t in security secret-tool; do
  printf '#!/bin/sh\nexit 1\n' > "$TMP/cli-bin/$t"; chmod +x "$TMP/cli-bin/$t"
done
cat > "$TMP/cli-bin/sigma" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_SIGMA_LOG:-/dev/null}"
if [ "$1 $2" = "auth --help" ]; then
  [ -n "${FAKE_SIGMA_HELP_FAIL:-}" ] && { echo "error: unrecognized subcommand" >&2; exit 2; }
  echo "Commands: login token status"; exit 0
fi
if [ "$1 $2" = "auth status" ]; then
  { echo "Profile:   example-profile"; echo "Auth type: api_key"
    [ -n "${FAKE_SIGMA_BASE:-}" ] && echo "Base URL:  ${FAKE_SIGMA_BASE}"
    echo "Auth:      ${FAKE_SIGMA_AUTH:-OK (token acquired)}"; } >&2
  exit 0
fi
if [ "$1 $2" = "auth token" ]; then printf '%s\n' "$FAKE_SIGMA_TOKEN"; exit 0; fi
exit 3
SH
chmod +x "$TMP/cli-bin/sigma"
cli_env=(env HOME="$TMP/home-cli" PATH="$TMP/cli-bin:$PATH" "${COMMON[@]}"
  SIGMA_BASE_URL= SIGMA_API_TOKEN= SIGMA_CLIENT_ID= SIGMA_CLIENT_SECRET=
  SIGMA_AUTH_MODE= SIGMA_CLI_PROFILE= FAKE_SIGMA_BASE="$CLI_BASE" FAKE_SIGMA_TOKEN="$CLI_JWT"
  FAKE_SIGMA_LOG="$TMP/cli.log")
cli_method() { # $1 = doctor.json, prints sigma_auth_method or MISSING
  python3 - "$1" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8"))["sigma_auth_method"])
except Exception:
    print("MISSING")
PY
}

"${cli_env[@]}" bash "$HERE/doctor.sh" --workdir "$TMP/cli" >"$TMP/cli.out" 2>&1
rc=$?
[ "$rc" -eq 0 ]; check $? "a signed-in Sigma CLI profile alone satisfies Sigma auth"
[ "$(cli_method "$TMP/cli/doctor.json")" = "sigma-cli" ]
check $? "doctor.json records sigma_auth_method=sigma-cli"
grep -q "$CLI_JWT" "$TMP/cli.out" "$TMP/cli/doctor.json" 2>/dev/null
[ $? -ne 0 ]; check $? "the CLI token is never printed or recorded"
grep -q 'auth token' "$TMP/cli.log" 2>/dev/null
[ $? -ne 0 ]; check $? "doctor never mints a token from the CLI"
grep -Eq 'auth login' "$TMP/cli.log" 2>/dev/null
[ $? -ne 0 ]; check $? "doctor never runs sigma auth login"

"${cli_env[@]}" FAKE_SIGMA_AUTH="FAILED (401)" \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-failed" >"$TMP/cli-failed.out" 2>&1
rc=$?
[ "$rc" -ne 0 ]; check $? "a CLI profile reporting Auth: FAILED is not accepted"
[ "$(cli_method "$TMP/cli-failed/doctor.json")" = "none" ]
check $? "failed CLI profile records sigma_auth_method=none"

"${cli_env[@]}" FAKE_SIGMA_HELP_FAIL=1 \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-hq" >"$TMP/cli-hq.out" 2>&1
[ "$(cli_method "$TMP/cli-hq/doctor.json")" = "none" ]
check $? "a non-Sigma binary named sigma (auth --help fails) is not accepted"

"${cli_env[@]}" FAKE_SIGMA_BASE="https://api.evil.test" \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-evil" >"$TMP/cli-evil.out" 2>&1
[ "$(cli_method "$TMP/cli-evil/doctor.json")" = "none" ]
check $? "a CLI profile on a non-Sigma host is not accepted"

"${cli_env[@]}" SIGMA_BASE_URL=https://api.sigmacomputing.com \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-mismatch" >"$TMP/cli-mismatch.out" 2>&1
[ "$(cli_method "$TMP/cli-mismatch/doctor.json")" = "none" ]
check $? "a CLI profile whose host differs from SIGMA_BASE_URL is not accepted"
grep -q 'differs from SIGMA_BASE_URL' "$TMP/cli-mismatch.out"
check $? "the mismatch is explained"

"${cli_env[@]}" SIGMA_BASE_URL="$CLI_BASE" SIGMA_AUTH_MODE=sigma-cli \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-mode" >"$TMP/cli-mode.out" 2>&1
[ "$(cli_method "$TMP/cli-mode/doctor.json")" = "sigma-cli" ]
check $? "SIGMA_AUTH_MODE=sigma-cli accepts the CLI"

for forbidden in browser client-credentials; do
  "${cli_env[@]}" SIGMA_BASE_URL="$CLI_BASE" SIGMA_AUTH_MODE=$forbidden \
    bash "$HERE/doctor.sh" --workdir "$TMP/cli-$forbidden" >"$TMP/cli-$forbidden.out" 2>&1
  [ "$(cli_method "$TMP/cli-$forbidden/doctor.json")" = "none" ]
  check $? "SIGMA_AUTH_MODE=$forbidden does not accept the CLI"
done

"${cli_env[@]}" SIGMA_BASE_URL="$CLI_BASE" SIGMA_CLIENT_ID=client-id SIGMA_CLIENT_SECRET=client-secret \
  SIGMA_AUTH_MODE=sigma-cli FAKE_SIGMA_AUTH="FAILED" \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-noclient" >"$TMP/cli-noclient.out" 2>&1
[ "$(cli_method "$TMP/cli-noclient/doctor.json")" = "none" ]
check $? "SIGMA_AUTH_MODE=sigma-cli does not fall back to client credentials"

"${cli_env[@]}" SIGMA_BASE_URL="$CLI_BASE" SIGMA_CLIENT_ID=client-id SIGMA_CLIENT_SECRET=client-secret \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-before-client" >"$TMP/cli-before-client.out" 2>&1
[ "$(cli_method "$TMP/cli-before-client/doctor.json")" = "sigma-cli" ]
check $? "the CLI is reported ahead of client credentials"

"${cli_env[@]}" SIGMA_BASE_URL="$CLI_BASE" SIGMA_API_TOKEN=current-token \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-token-first" >"$TMP/cli-token-first.out" 2>&1
[ "$(cli_method "$TMP/cli-token-first/doctor.json")" = "api-token" ]
check $? "a current token is reported ahead of the CLI"

"${cli_env[@]}" SIGMA_CLI_PROFILE=example-profile FAKE_SIGMA_LOG="$TMP/cli-profile.log" \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-profile" >/dev/null 2>&1
grep -qx 'auth status -p example-profile' "$TMP/cli-profile.log"
check $? "SIGMA_CLI_PROFILE is passed to the CLI as -p"

"${cli_env[@]}" FAKE_SIGMA_HELP_FAIL=1 \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-hint" >"$TMP/cli-hint.out" 2>&1
grep -q 'sigma auth login' "$TMP/cli-hint.out" && grep -q 'SIGMA_CLI_PROFILE' "$TMP/cli-hint.out"
check $? "missing-auth remediation recommends sigma auth login and SIGMA_CLI_PROFILE"

# SIGMA_CLI_PROFILE may be persisted in ~/.sigma-migration/env like the other
# settings; an explicit environment value wins over the file.
mkdir -p "$TMP/home-profile/.sigma-migration"
printf "export SIGMA_CLI_PROFILE='example-profile'\n" > "$TMP/home-profile/.sigma-migration/env"
"${cli_env[@]}" HOME="$TMP/home-profile" FAKE_SIGMA_LOG="$TMP/cli-file-profile.log" \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-file-profile" >/dev/null 2>&1
grep -qx 'auth status -p example-profile' "$TMP/cli-file-profile.log"
check $? "SIGMA_CLI_PROFILE persisted in ~/.sigma-migration/env is passed as -p"
"${cli_env[@]}" HOME="$TMP/home-profile" SIGMA_CLI_PROFILE=other-profile \
  FAKE_SIGMA_LOG="$TMP/cli-env-profile.log" \
  bash "$HERE/doctor.sh" --workdir "$TMP/cli-env-profile" >/dev/null 2>&1
grep -qx 'auth status -p other-profile' "$TMP/cli-env-profile.log"
check $? "an explicit SIGMA_CLI_PROFILE wins over the env file"

# Live smoke on the CLI path: the shared REST clients derive the base URL from
# the provider themselves, so the doctor must not inject one (that would mask a
# broken derivation) and only warns about scripts that read the variable.
mkdir -p "$TMP/fixture-cli/scripts/lib"
cp "$TMP/fixture/scripts/doctor.sh" "$TMP/fixture-cli/scripts/doctor.sh"
cp "$TMP/fixture/scripts/runtime_profile.py" "$TMP/fixture-cli/scripts/runtime_profile.py"
cp "$TMP/fixture/runtime-capabilities.json" "$TMP/fixture-cli/runtime-capabilities.json"
cat > "$TMP/fixture-cli/scripts/lib/sigma_rest.py" <<'PY'
import os

def request(method, path):
    with open(os.environ["SIGMA_DOCTOR_SMOKE_MARKER"], "w", encoding="utf-8") as handle:
        handle.write(f"{method} {path} {os.environ.get('SIGMA_BASE_URL', '')}")
    os.environ["SIGMA_AUTH_METHOD"] = "sigma-cli"
    return {}
PY
"${cli_env[@]}" SIGMA_SKIP_CRED_SMOKE= SIGMA_RUNTIME_PROFILE=python \
  SIGMA_DOCTOR_SMOKE_MARKER="$TMP/smoke-cli.marker" \
  bash "$TMP/fixture-cli/scripts/doctor.sh" --workdir "$TMP/live-cli" >"$TMP/live-cli.out" 2>&1
[ "$(cat "$TMP/smoke-cli.marker" 2>/dev/null)" = "get /v2/whoami " ]
check $? "CLI-only live smoke is GET /v2/whoami and leaves base-URL derivation to sigma_rest"
grep -q 'REST clients derive it from the Sigma CLI profile' "$TMP/live-cli.out"
check $? "the unset-SIGMA_BASE_URL note says the REST clients derive it"
grep -q 'converters read SIGMA_BASE_URL' "$TMP/live-cli.out"
[ $? -ne 0 ]; check $? "the stale 'converters read SIGMA_BASE_URL' claim is gone"
python3 - "$TMP/live-cli/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["cred_smoke"]["sigma"] == "pass", d
assert d["sigma_auth_method"] == "sigma-cli", d
PY
check $? "live doctor.json records pass/sigma-cli"

echo "Part D — workdir variants and no-git installs keep the JSON contract"
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-token DOCTOR_WORKDIR="$TMP/env-workdir" \
  bash "$HERE/doctor.sh" >/dev/null 2>&1
python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
  "$TMP/env-workdir/doctor.json"
check $? "DOCTOR_WORKDIR writes valid doctor.json"

mkdir -p "$TMP/plain"
(cd "$TMP/plain" && env HOME="$TMP/home-missing" "${COMMON[@]}" \
  SIGMA_BASE_URL="$BASE" SIGMA_API_TOKEN=current-token \
  bash "$HERE/doctor.sh" >/dev/null 2>&1)
[ ! -e "$TMP/plain/doctor.json" ]
check $? "plain doctor run does not write doctor.json into the CWD"

mkdir -p "$TMP/nogit"
cp "$HERE/doctor.sh" "$TMP/nogit/doctor.sh"
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-token \
  bash "$TMP/nogit/doctor.sh" --workdir "$TMP/nogit-work" >/dev/null 2>&1
python3 - "$TMP/nogit-work/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["skill_sha"] == "unknown (no git — mirror/plugin install)", d
assert d["days_since_commit"] is None, d
PY
check $? "no-git install records the unknown-build fallback"

echo "Part E — an explicitly certified Python profile still waives Ruby"
mkdir -p "$TMP/profile/scripts"
cp "$HERE/doctor.sh" "$TMP/profile/scripts/doctor.sh"
cp "$HERE/runtime_profile.py" "$TMP/profile/scripts/runtime_profile.py"
: > "$TMP/profile/scripts/migrate.py"
cat > "$TMP/profile/runtime-capabilities.json" <<'JSON'
{
  "schemaVersion": 1,
  "skill": "doctor-profile-fixture",
  "profiles": {
    "ruby": {
      "status": "supported",
      "requiredRuntimes": ["ruby", "python", "node", "bash"],
      "entrypoint": ["ruby", "scripts/migrate.rb"]
    },
    "python": {
      "status": "supported",
      "requiredRuntimes": ["python", "node", "bash"],
      "entrypoint": ["python", "scripts/migrate.py"]
    }
  }
}
JSON
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-token \
  bash "$TMP/profile/scripts/doctor.sh" --runtime-profile python \
  --workdir "$TMP/profile-work" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ]; check $? "doctor accepts a certified Python profile"
python3 - "$TMP/profile-work/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rp = d["runtime_profile"]
assert rp["requested"] == "python", rp
assert rp["selected"] == "python", rp
assert "ruby" not in rp["required_runtimes"], rp
assert d["pass"] is True, d["failures"]
PY
check $? "doctor.json records Python selection without a Ruby requirement"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
