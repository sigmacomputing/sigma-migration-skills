#!/usr/bin/env bash
# Mint a Sigma bearer token. Browser-keychain auth is preferred, then the Sigma
# CLI (`sigma auth token`), then OAuth client credentials. Existing valid caller
# tokens are intentionally handled by callers rather than re-emitted here.
#
# Usage:
#   eval "$(./get-token.sh)"
#   eval "$(./get-token.sh --auth-mode browser)"
#
# Auth mode: --auth-mode or SIGMA_AUTH_MODE = auto (default), browser,
# sigma-cli, or client-credentials. With Python, the canonical get_token.py
# provider handles every mode. Without Python, this retains safe Sigma CLI and
# client-credentials fallbacks (browser refresh needs Python).
# SIGMA_CLI_PROFILE selects a Sigma CLI profile (-p); unset uses its default.
#
# Prints SIGMA_API_TOKEN, SIGMA_TOKEN_MINTED_AT, and SIGMA_AUTH_METHOD exports
# (plus SIGMA_BASE_URL when the host came from the Sigma CLI profile).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_MODE="${SIGMA_AUTH_MODE:-auto}"
if [ "$#" -gt 0 ]; then
  if [ "$#" -eq 2 ] && [ "$1" = "--auth-mode" ]; then
    AUTH_MODE="$2"
  elif [ "$#" -eq 1 ] && [[ "$1" == --auth-mode=* ]]; then
    AUTH_MODE="${1#--auth-mode=}"
  else
    echo "Usage: get-token.sh [--auth-mode auto|browser|sigma-cli|client-credentials]" >&2
    exit 64
  fi
fi
case "$AUTH_MODE" in
  auto|browser|sigma-cli|client-credentials) ;;
  *) echo "Error: auth mode must be auto, browser, sigma-cli, or client-credentials" >&2; exit 64 ;;
esac

# Prefer the canonical dual-mode provider whenever any common Python launcher
# is available (python3 on POSIX, python/py on Windows Git Bash).
PYTHON=()
if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v python >/dev/null 2>&1; then
  PYTHON=(python)
elif command -v py >/dev/null 2>&1; then
  PYTHON=(py -3)
fi
if [ "${#PYTHON[@]}" -gt 0 ]; then
  exec "${PYTHON[@]}" "$SCRIPT_DIR/get_token.py" \
    --print-export --auth-mode "$AUTH_MODE"
fi

# Browser refresh requires the Python provider. In auto mode, the Sigma CLI and
# client credentials still work on a Python-free host.
if [ "$AUTH_MODE" = "browser" ]; then
  echo "Error: browser auth requires Python 3 for the canonical token provider." >&2
  exit 1
fi

# Pin to known Sigma cloud hosts. The script's stdout is intended to be eval'd,
# so a hostile token-endpoint response could otherwise become RCE on the caller.
SIGMA_DOMAIN="sigma""computing.com"
sigma_published_base() {
  case "$1" in
    https://aws-api.${SIGMA_DOMAIN}|\
    https://api.us-a.aws.${SIGMA_DOMAIN}|\
    https://api.ca.aws.${SIGMA_DOMAIN}|\
    https://api.eu.aws.${SIGMA_DOMAIN}|\
    https://api.au.aws.${SIGMA_DOMAIN}|\
    https://api.uk.aws.${SIGMA_DOMAIN}|\
    https://api.us.azure.${SIGMA_DOMAIN}|\
    https://api.eu.azure.${SIGMA_DOMAIN}|\
    https://api.ca.azure.${SIGMA_DOMAIN}|\
    https://api.uk.azure.${SIGMA_DOMAIN}|\
    https://api.au.azure.${SIGMA_DOMAIN}|\
    https://api.${SIGMA_DOMAIN}|\
    https://api.sa.gcp.${SIGMA_DOMAIN}) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Sigma CLI source (noninteractive: never runs `sigma auth login`) --------
# Run argv with no stdin and a hard time limit (macOS has no `timeout`).
# Combined stdout+stderr lands in CLI_OUT; the exit status is returned.
CLI_OUT=""
cli_run() {
  local limit="$1" tmp pid ticks=0 rc=0
  shift
  tmp="$(mktemp)" || return 1
  "$@" </dev/null >"$tmp" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 10)) ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$tmp"
      CLI_OUT=""
      return 124
    fi
    sleep 0.1 2>/dev/null || sleep 1
    ticks=$((ticks + 1))
  done
  wait "$pid" || rc=$?
  CLI_OUT="$(<"$tmp")"
  rm -f "$tmp"
  return "$rc"
}

# Sets CLI_BASE/CLI_TOKEN on success. On failure sets CLI_ERROR and returns 1.
CLI_BASE=""
CLI_TOKEN=""
CLI_ERROR=""
sigma_cli_token() {
  local bin profile="" status_out base="" auth_ok=0 line re
  local -a pargs=()
  bin="$(command -v sigma 2>/dev/null || true)"
  if [ -z "$bin" ]; then CLI_ERROR="the Sigma CLI (sigma) is not on PATH"; return 1; fi
  profile="${SIGMA_CLI_PROFILE:-}"
  if [ -n "$profile" ]; then
    re='^[A-Za-z0-9_][A-Za-z0-9._@ -]{0,127}$'
    if ! [[ "$profile" =~ $re ]]; then
      CLI_ERROR="SIGMA_CLI_PROFILE must be a profile name (not starting with '-')"; return 1
    fi
    pargs=(-p "$profile")
  fi
  re='(^|[^A-Za-z0-9_])token([^A-Za-z0-9_]|$)'
  if ! cli_run 30 "$bin" auth --help || ! [[ "$CLI_OUT" =~ $re ]]; then
    CLI_ERROR="sigma on PATH is not the Sigma CLI (sigma auth --help failed or does not list token)"; return 1
  fi
  if ! cli_run 30 "$bin" auth status ${pargs[@]+"${pargs[@]}"}; then
    CLI_ERROR="sigma auth status failed; run sigma auth login in an interactive terminal"; return 1
  fi
  status_out="$CLI_OUT"
  local re_auth='^[[:space:]]*Auth:[[:space:]]*[Oo][Kk]' re_base='^[[:space:]]*Base URL:[[:space:]]*([^[:space:]]+)[[:space:]]*$'
  while IFS= read -r line; do
    if [[ "$line" =~ $re_auth ]]; then
      auth_ok=1
    elif [ -z "$base" ] && [[ "$line" =~ $re_base ]]; then
      base="${BASH_REMATCH[1]}"
    fi
  done <<<"$status_out"
  if [ "$auth_ok" -ne 1 ]; then
    CLI_ERROR="the Sigma CLI profile is not authenticated; run sigma auth login in an interactive terminal"; return 1
  fi
  base="${base%/}"
  if [ -z "$base" ] || ! sigma_published_base "$base"; then
    CLI_ERROR="Sigma CLI profile Base URL is missing or not a published Sigma API host"; return 1
  fi
  if [ -n "${SIGMA_BASE_URL:-}" ] && [ "${SIGMA_BASE_URL%/}" != "$base" ]; then
    CLI_ERROR="Sigma CLI profile Base URL differs from SIGMA_BASE_URL; refusing a token minted for a different host"; return 1
  fi
  if ! cli_run 30 "$bin" auth token ${pargs[@]+"${pargs[@]}"}; then
    CLI_ERROR="sigma auth token failed; run sigma auth login in an interactive terminal"; return 1
  fi
  # Strip surrounding whitespace only; anything else must match a JWT exactly.
  CLI_TOKEN="${CLI_OUT#"${CLI_OUT%%[![:space:]]*}"}"
  CLI_TOKEN="${CLI_TOKEN%"${CLI_TOKEN##*[![:space:]]}"}"
  CLI_OUT=""
  if ! [[ "$CLI_TOKEN" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    CLI_TOKEN=""
    CLI_ERROR="Sigma CLI auth token output was not a JWT; refusing it"; return 1
  fi
  CLI_BASE="$base"
  return 0
}

if [ "$AUTH_MODE" = "auto" ] || [ "$AUTH_MODE" = "sigma-cli" ]; then
  if sigma_cli_token; then
    if [ -z "${SIGMA_BASE_URL:-}" ]; then
      printf 'export SIGMA_BASE_URL=%q\n' "$CLI_BASE"
    fi
    printf 'export SIGMA_API_TOKEN=%q\n' "$CLI_TOKEN"
    printf 'export SIGMA_TOKEN_MINTED_AT=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'export SIGMA_AUTH_METHOD=%q\n' "sigma-cli"
    exit 0
  fi
  if [ "$AUTH_MODE" = "sigma-cli" ]; then
    echo "Error: Sigma CLI auth unavailable: $CLI_ERROR" >&2
    exit 1
  fi
fi

: "${SIGMA_BASE_URL:?SIGMA_BASE_URL is not set (or sign in with the Sigma CLI: sigma auth login)}"
: "${SIGMA_CLIENT_ID:?SIGMA_CLIENT_ID is not set (Python is unavailable, so browser auth cannot be used; or sign in with the Sigma CLI: sigma auth login)}"
: "${SIGMA_CLIENT_SECRET:?SIGMA_CLIENT_SECRET is not set (Python is unavailable, so browser auth cannot be used; or sign in with the Sigma CLI: sigma auth login)}"

for bin in curl jq base64; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Error: $bin is required for the Python-free client-credentials fallback" >&2
    exit 1
  }
done

if ! sigma_published_base "$SIGMA_BASE_URL"; then
  echo "Error: SIGMA_BASE_URL must be one of the published Sigma API hosts (see SKILL.md)." >&2
  exit 1
fi

# `printf` (not `echo`) so no trailing newline is encoded into the credentials.
# `tr -d '\n'` strips the wrap base64 inserts at 76 columns by default on both
# BSD and GNU — without it, long id:secret pairs would inject a newline into
# the Authorization header.
CREDENTIALS=$(printf '%s:%s' "$SIGMA_CLIENT_ID" "$SIGMA_CLIENT_SECRET" | base64 | tr -d '\n')

RESPONSE=$(curl -sf --proto '=https' -X POST "${SIGMA_BASE_URL}/v2/auth/token" \
  -H "Authorization: Basic ${CREDENTIALS}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials")

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Error: failed to extract access_token from response:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

# The token will be eval'd by the caller. Reject any character outside the
# OAuth-2 bearer-token alphabet (RFC 6750 §2.1) so a compromised or spoofed
# token endpoint cannot smuggle shell metacharacters into `eval`.
if ! [[ "$TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
  echo "Error: token contains unexpected characters; refusing to emit." >&2
  exit 1
fi

printf 'export SIGMA_API_TOKEN=%q\n' "$TOKEN"
printf 'export SIGMA_TOKEN_MINTED_AT=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'export SIGMA_AUTH_METHOD=%q\n' "client-credentials"
