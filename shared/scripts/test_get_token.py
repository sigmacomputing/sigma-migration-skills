#!/usr/bin/env python3
"""Credential-free tests for the canonical Sigma token provider."""

import contextlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import tempfile
import unittest
import urllib.error
from unittest import mock


MODULE_PATH = os.path.join(os.path.dirname(__file__), "get_token.py")
SPEC = importlib.util.spec_from_file_location("sigma_get_token", MODULE_PATH)
get_token = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(get_token)

BASE = "https://api.sigmacomputing.com"
MINTED = "2026-10-05T20:00:00Z"


class JsonResponse(io.BytesIO):
    def __init__(self, payload):
        super().__init__(json.dumps(payload).encode("utf-8"))

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class TokenProviderTest(unittest.TestCase):
    def env(self, **values):
        base = {"SIGMA_BASE_URL": BASE}
        base.update(values)
        return mock.patch.dict(os.environ, base, clear=True)

    def test_auto_prefers_valid_browser_cache_over_client_credentials(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-token": "cached-token",
            "access-expiry": "2000",
            "access-minted-at": MINTED,
        }
        with self.env(SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token.time, "time", return_value=1000), \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda result: result) as verify, \
             mock.patch.object(get_token, "_mint_client_credentials") as client:
            result = get_token.mint_token()

        self.assertEqual("cached-token", result.token)
        self.assertEqual("browser", result.auth_method)
        self.assertEqual(MINTED, result.minted_at)
        verify.assert_called_once_with(result)
        client.assert_not_called()

    def test_explicit_client_mode_skips_browser(self):
        expected = get_token.TokenResult(BASE, "client-token", MINTED, "client-credentials")
        with self.env(
            SIGMA_AUTH_MODE="browser",
            SIGMA_CLIENT_ID="id",
            SIGMA_CLIENT_SECRET="secret",
        ), mock.patch.object(get_token, "_mint_browser_refresh") as browser, \
             mock.patch.object(get_token, "_mint_client_credentials", return_value=expected), \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda result: result) as verify:
            result = get_token.mint_token("client-credentials")

        self.assertEqual(expected, result)
        verify.assert_called_once_with(expected)
        browser.assert_not_called()

    def test_auto_falls_back_to_client_credentials_without_browser_session(self):
        with self.env(SIGMA_CLIENT_ID="client-id", SIGMA_CLIENT_SECRET="client-secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value=None), \
             mock.patch.object(
                 get_token,
                 "_open_https",
                 return_value=JsonResponse({"access_token": "client-token"}),
             ) as urlopen, \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda result: result), \
             mock.patch.object(get_token.time, "time", return_value=1000):
            result = get_token.mint_token()

        self.assertEqual("client-token", result.token)
        self.assertEqual("client-credentials", result.auth_method)
        request = urlopen.call_args.args[0]
        self.assertEqual(f"{BASE}/v2/auth/token", request.full_url)
        self.assertTrue(request.headers["Authorization"].startswith("Basic "))

    def test_auto_falls_back_when_browser_refresh_returns_no_access_token(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-expiry": "0",
            "client-id": "browser-client",
            "token-url": "https://auth.sigmacomputing.com/oauth/token",
        }
        responses = [
            JsonResponse({"error": "invalid_grant"}),
            JsonResponse({"access_token": "fallback-client-token"}),
        ]
        with self.env(SIGMA_CLIENT_ID="client-id", SIGMA_CLIENT_SECRET="client-secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(
                 get_token, "_open_https", side_effect=responses
             ), mock.patch.object(
                 get_token, "_verify_token", side_effect=lambda result: result
             ), contextlib.redirect_stderr(io.StringIO()):
            result = get_token.mint_token()

        self.assertEqual("fallback-client-token", result.token)
        self.assertEqual("client-credentials", result.auth_method)

    def test_whoami_verification_succeeds_with_bearer_header(self):
        result = get_token.TokenResult(BASE, "minted-token", MINTED, "browser")
        opener = mock.Mock()
        opener.open.return_value = JsonResponse(
            {"userId": "user-1", "organizationId": "org-1"}
        )

        with mock.patch.object(
            get_token.urllib.request, "build_opener", return_value=opener
        ) as build_opener:
            verified = get_token._verify_token(result)

        self.assertEqual(result, verified)
        handler = build_opener.call_args.args[0]
        self.assertIsInstance(handler, get_token._RejectRedirects)
        request = opener.open.call_args.args[0]
        self.assertEqual(f"{BASE}/v2/whoami", request.full_url)
        self.assertEqual("GET", request.get_method())
        self.assertEqual("Bearer minted-token", request.headers["Authorization"])

    def test_whoami_verification_rejects_401_and_403_without_leaking_token(self):
        result = get_token.TokenResult(BASE, "secret-bearer", MINTED, "browser")
        for status in (401, 403):
            with self.subTest(status=status):
                opener = mock.Mock()
                opener.open.side_effect = urllib.error.HTTPError(
                    f"{BASE}/v2/whoami", status, "auth failed", {}, None
                )
                with mock.patch.object(
                    get_token.urllib.request, "build_opener", return_value=opener
                ):
                    with self.assertRaisesRegex(
                        get_token.TokenProviderError, str(status)
                    ) as raised:
                        get_token._verify_token(result)
                self.assertNotIn(result.token, str(raised.exception))

    def test_whoami_verification_rejects_non_json_without_leaking_token(self):
        result = get_token.TokenResult(
            BASE, "secret-non-json-bearer", MINTED, "client-credentials"
        )
        opener = mock.Mock()
        opener.open.return_value = io.BytesIO(b"<html>not JSON</html>")

        with mock.patch.object(
            get_token.urllib.request, "build_opener", return_value=opener
        ):
            with self.assertRaisesRegex(
                get_token.TokenProviderError, "not valid JSON"
            ) as raised:
                get_token._verify_token(result)

        self.assertNotIn(result.token, str(raised.exception))

    def test_whoami_verification_refuses_redirect_without_following_it(self):
        result = get_token.TokenResult(
            BASE, "secret-redirect-bearer", MINTED, "client-credentials"
        )
        opener = mock.Mock()
        opener.open.side_effect = urllib.error.HTTPError(
            f"{BASE}/v2/whoami",
            302,
            "Found",
            {"Location": "https://attacker.example/collect"},
            None,
        )

        with mock.patch.object(
            get_token.urllib.request, "build_opener", return_value=opener
        ) as build_opener:
            with self.assertRaisesRegex(
                get_token.TokenProviderError, "refused HTTP 302 redirect"
            ) as raised:
                get_token._verify_token(result)

        self.assertIsInstance(
            build_opener.call_args.args[0], get_token._RejectRedirects
        )
        opener.open.assert_called_once()
        self.assertNotIn(result.token, str(raised.exception))

    def test_browser_refresh_caches_metadata_and_rotates_refresh_token(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-token": "expired-token",
            "access-expiry": "999",
            "client-id": "browser-client",
            "token-url": "https://auth.sigmacomputing.com/oauth/token",
        }
        writes = []

        def set_value(_backend, key, value):
            writes.append((key, value))
            keychain[key] = value
            return True

        payload = {
            "access_token": "fresh-browser-token",
            "refresh_token": "refresh-new",
            "expires_in": 3600,
        }
        with mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token, "_kc_set", side_effect=set_value), \
             mock.patch.object(
                 get_token, "_open_https", return_value=JsonResponse(payload)
             ) as urlopen:
            result = get_token._mint_browser_refresh(BASE, now=1000)

        self.assertEqual("fresh-browser-token", result.token)
        self.assertEqual("browser", result.auth_method)
        self.assertEqual("1970-01-01T00:16:40Z", result.minted_at)
        self.assertEqual(("refresh-token", "refresh-new"), writes[0])
        self.assertEqual(
            ["access-token", "access-minted-at", "access-expiry"],
            [name for name, _value in writes[1:]],
        )
        self.assertEqual("4540", keychain["access-expiry"])
        body = urlopen.call_args.args[0].data.decode("utf-8")
        self.assertIn("grant_type=refresh_token", body)
        self.assertIn("refresh_token=refresh-old", body)

    def test_browser_cache_avoids_network(self):
        keychain = {
            "refresh-token": "refresh",
            "access-token": "cached",
            "access-expiry": "2000",
            "access-minted-at": MINTED,
        }
        with mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token, "_open_https") as urlopen:
            result = get_token._mint_browser_refresh(BASE, now=1000)

        self.assertEqual("cached", result.token)
        urlopen.assert_not_called()

    def test_rotated_refresh_token_must_be_persisted(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-expiry": "0",
            "client-id": "browser-client",
            "token-url": "https://auth.sigmacomputing.com/oauth/token",
        }
        payload = {
            "access_token": "fresh-token",
            "refresh_token": "refresh-new",
        }
        with mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token, "_kc_set", return_value=False), \
             mock.patch.object(
                 get_token, "_open_https", return_value=JsonResponse(payload)
             ):
            with self.assertRaisesRegex(
                get_token.BrowserUnavailable, "replacement could not be stored"
            ):
                get_token._mint_browser_refresh(BASE, now=1000)

    def test_unsafe_base_url_is_rejected_before_auth_resolution(self):
        with self.env(SIGMA_BASE_URL="https://api.sigmacomputing.com.evil.test"), \
             mock.patch.object(get_token, "_keychain_backend") as backend:
            with self.assertRaisesRegex(get_token.SecurityError, "non-Sigma host"):
                get_token.mint_token()
        backend.assert_not_called()

    def test_unknown_sigma_subdomain_is_not_accepted_as_an_api_base(self):
        with self.env(SIGMA_BASE_URL="https://unpublished.sigmacomputing.com"):
            with self.assertRaisesRegex(get_token.SecurityError, "not a published"):
                get_token.mint_token()

    def test_unsafe_stored_token_url_is_rejected_without_client_fallback(self):
        keychain = {
            "refresh-token": "refresh",
            "access-expiry": "0",
            "client-id": "browser-client",
            "token-url": "https://evil.test/oauth/token",
        }
        with self.env(SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token, "_mint_client_credentials") as client:
            with self.assertRaisesRegex(get_token.SecurityError, "non-Sigma host"):
                get_token.mint_token()
        client.assert_not_called()

    def test_invalid_access_token_alphabet_is_rejected(self):
        with self.assertRaisesRegex(get_token.SecurityError, "unexpected characters"):
            get_token._validate_access_token("token;echo-pwned")

    def test_auth_json_is_backward_compatible_private_and_has_metadata(self):
        result = get_token.TokenResult(BASE, "access-token", MINTED, "browser")
        with tempfile.TemporaryDirectory() as workdir:
            path = get_token._write_auth_json(workdir, result)
            with open(path, encoding="utf-8") as handle:
                payload = json.load(handle)

            self.assertEqual("access-token", payload["SIGMA_API_TOKEN"])
            self.assertEqual(BASE, payload["SIGMA_BASE_URL"])
            self.assertEqual(MINTED, payload["SIGMA_TOKEN_MINTED_AT"])
            self.assertEqual("browser", payload["SIGMA_AUTH_METHOD"])
            self.assertNotIn("refresh_token", payload)
            if os.name != "nt":
                self.assertEqual(0o600, stat.S_IMODE(os.stat(path).st_mode))

    def test_existing_caller_token_is_not_treated_as_a_refresh_credential(self):
        with self.env(SIGMA_API_TOKEN="caller-token"), \
             mock.patch.object(get_token, "_keychain_backend", return_value=None):
            with self.assertRaisesRegex(
                get_token.TokenProviderError, "no Sigma authentication"
            ):
                get_token.mint_token()

    def test_neutral_env_supplies_missing_migration_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "env")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "export SIGMA_BASE_URL='https://api.sigmacomputing.com'\n"
                    "export SIGMA_CLIENT_ID='neutral-id'\n"
                    "export SIGMA_CLIENT_SECRET='neutral secret'\n"
                    "export SIGMA_API_TOKEN='must-not-be-loaded'\n"
                )
            with mock.patch.dict(os.environ, {}, clear=True):
                get_token._load_neutral_env(path)
                self.assertEqual(BASE, os.environ["SIGMA_BASE_URL"])
                self.assertEqual("neutral-id", os.environ["SIGMA_CLIENT_ID"])
                self.assertEqual("neutral secret", os.environ["SIGMA_CLIENT_SECRET"])
                self.assertNotIn("SIGMA_API_TOKEN", os.environ)

    def test_explicit_environment_wins_over_neutral_env(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "env")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("export SIGMA_CLIENT_ID='from-file'\n")
            with mock.patch.dict(
                os.environ, {"SIGMA_CLIENT_ID": "from-environment"}, clear=True
            ):
                get_token._load_neutral_env(path)
                self.assertEqual("from-environment", os.environ["SIGMA_CLIENT_ID"])

    def test_platform_selects_only_native_keychain_backend(self):
        def which(command):
            return f"/fake/{command}"

        with mock.patch.object(get_token.shutil, "which", side_effect=which):
            self.assertEqual("macos", get_token._keychain_backend("darwin"))
            self.assertEqual("libsecret", get_token._keychain_backend("linux"))
            self.assertIsNone(get_token._keychain_backend("win32"))

    def test_python_free_shell_fallback_emits_metadata_and_validates_token(self):
        script = os.path.join(os.path.dirname(__file__), "get-token.sh")
        with tempfile.TemporaryDirectory() as bindir:
            tools = {
                "dirname": '#!/bin/sh\n/usr/bin/dirname "$@"\n',
                "base64": "#!/bin/sh\n/bin/cat >/dev/null\nprintf Y3JlZHM=\n",
                "tr": "#!/bin/sh\n/bin/cat\n",
                "curl": '#!/bin/sh\nprintf \'{"access_token":"shell-token"}\\n\'\n',
                "jq": "#!/bin/sh\n/bin/cat >/dev/null\nprintf shell-token\\n\n",
                "date": "#!/bin/sh\nprintf 2026-10-05T20:00:00Z\\n\n",
            }
            for name, contents in tools.items():
                path = os.path.join(bindir, name)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(contents)
                os.chmod(path, 0o755)

            env = {
                "PATH": bindir,
                "SIGMA_BASE_URL": BASE,
                "SIGMA_CLIENT_ID": "id",
                "SIGMA_CLIENT_SECRET": "secret",
                "SIGMA_AUTH_MODE": "auto",
            }
            proc = subprocess.run(
                ["/bin/bash", script],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("export SIGMA_API_TOKEN=shell-token", proc.stdout)
        self.assertIn("export SIGMA_TOKEN_MINTED_AT=2026-10-05T20:00:00Z", proc.stdout)
        self.assertIn("export SIGMA_AUTH_METHOD=client-credentials", proc.stdout)

    def test_browser_shell_helpers_emit_mint_metadata(self):
        scripts = ("browser-login.sh", "refresh-token.sh")
        for name in scripts:
            with self.subTest(name=name):
                path = os.path.join(os.path.dirname(__file__), name)
                with open(path, encoding="utf-8") as handle:
                    source = handle.read()
                self.assertIn("export SIGMA_TOKEN_MINTED_AT=", source)
                self.assertIn("export SIGMA_AUTH_METHOD=", source)
                self.assertIn("^[A-Za-z0-9._~+/=-]+$", source)


FAKE_JWT = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl"
CLI_BASE = "https://aws-api.sigmacomputing.com"

FAKE_SIGMA = r"""#!/bin/bash
# Synthetic stand-in for the Sigma CLI. Behaviour is driven by FAKE_SIGMA_* env.
printf '%s\n' "$*" >> "${FAKE_SIGMA_LOG:-/dev/null}"
if [ "$1" = auth ] && [ "$2" = --help ]; then
  if [ -n "${FAKE_SIGMA_HELP_FAIL:-}" ]; then
    echo "error: unrecognized subcommand 'auth'" >&2
    exit 2
  fi
  echo "Commands: login token status"
  exit 0
fi
if [ "$1" = auth ] && [ "$2" = status ]; then
  {
    echo "Profile:   example-profile"
    echo "Auth type: api_key"
    [ -n "${FAKE_SIGMA_BASE:-}" ] && echo "Base URL:  ${FAKE_SIGMA_BASE}"
    echo "Client ID: abcd...1234"
    echo "Auth:      ${FAKE_SIGMA_AUTH:-OK (token acquired)}"
  } >&2
  exit 0
fi
if [ "$1" = auth ] && [ "$2" = token ]; then
  if [ -n "${FAKE_SIGMA_TOKEN_FAIL:-}" ]; then
    echo "Error: not signed in" >&2
    exit 2
  fi
  printf '%s\n' "${FAKE_SIGMA_TOKEN}"
  [ -n "${FAKE_SIGMA_TOKEN_STDERR:-}" ] && printf '%s\n' "$FAKE_SIGMA_TOKEN_STDERR" >&2
  exit 0
fi
echo "unexpected: $*" >&2
exit 3
"""


class SigmaCliTest(unittest.TestCase):
    """The Sigma CLI source: browser keychain -> Sigma CLI -> client credentials."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = os.path.join(self.tmp.name, "bin")
        self.emptydir = os.path.join(self.tmp.name, "empty")
        os.makedirs(self.bindir)
        os.makedirs(self.emptydir)
        self.log = os.path.join(self.tmp.name, "sigma.log")
        path = os.path.join(self.bindir, "sigma")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(FAKE_SIGMA)
        os.chmod(path, 0o755)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as handle:
            return [line.strip() for line in handle if line.strip()]

    def env(self, with_cli=True, base=BASE, **values):
        merged = {
            "PATH": (self.bindir if with_cli else self.emptydir) + os.pathsep + "/usr/bin:/bin"
            if with_cli
            else self.emptydir,
            "FAKE_SIGMA_LOG": self.log,
            "FAKE_SIGMA_BASE": CLI_BASE,
            "FAKE_SIGMA_TOKEN": FAKE_JWT,
        }
        if base:
            merged["SIGMA_BASE_URL"] = base
        merged.update(values)
        return mock.patch.dict(os.environ, merged, clear=True)

    def mint(self, mode=None):
        with mock.patch.object(get_token, "_keychain_backend", return_value=None), \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda r: r), \
             contextlib.redirect_stderr(io.StringIO()) as err:
            try:
                return get_token.mint_token(mode), err.getvalue()
            except get_token.TokenProviderError as exc:
                exc.stderr = err.getvalue()
                raise

    def test_auth_modes_include_sigma_cli(self):
        self.assertIn("sigma-cli", get_token.AUTH_MODES)

    def test_auto_uses_cli_before_client_credentials(self):
        with self.env(base=CLI_BASE, SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_mint_client_credentials") as client:
            result, _err = self.mint()
        self.assertEqual("sigma-cli", result.auth_method)
        self.assertEqual(FAKE_JWT, result.token)
        self.assertEqual(CLI_BASE, result.base_url)
        client.assert_not_called()

    def test_auto_prefers_browser_session_over_cli(self):
        browser = get_token.TokenResult(CLI_BASE, "browser-token", MINTED, "browser")
        with self.env(base=CLI_BASE), \
             mock.patch.object(get_token, "_mint_browser_refresh", return_value=browser), \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda r: r):
            result = get_token.mint_token()
        self.assertEqual("browser", result.auth_method)
        self.assertEqual([], self.calls())

    def test_base_url_comes_from_cli_status_when_env_unset(self):
        with self.env(base=None):
            result, _err = self.mint()
        self.assertEqual(CLI_BASE, result.base_url)
        self.assertEqual("sigma-cli", result.auth_method)
        self.assertIsNone(result.minted_at)

    def test_env_base_matching_cli_host_is_used(self):
        with self.env(base=CLI_BASE + "/"):
            result, _err = self.mint("sigma-cli")
        self.assertEqual(CLI_BASE, result.base_url)

    def test_host_mismatch_is_refused_in_sigma_cli_mode_without_minting(self):
        with self.env(base="https://api.sigmacomputing.com"):
            with self.assertRaisesRegex(get_token.TokenProviderError, "differs") as raised:
                self.mint("sigma-cli")
        self.assertFalse(any(c.startswith("auth token") for c in self.calls()))
        self.assertNotIn(FAKE_JWT, str(raised.exception))

    def test_host_mismatch_skips_cli_in_auto_and_uses_client_credentials(self):
        expected = get_token.TokenResult(
            "https://api.sigmacomputing.com", "client-token", MINTED, "client-credentials"
        )
        with self.env(base="https://api.sigmacomputing.com",
                      SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_mint_client_credentials", return_value=expected):
            result, err = self.mint()
        self.assertEqual("client-credentials", result.auth_method)
        self.assertFalse(any(c.startswith("auth token") for c in self.calls()))
        self.assertNotIn(FAKE_JWT, err)

    def test_non_sigma_host_from_status_is_refused(self):
        for bad in ("https://api.evil.test", "http://aws-api.sigmacomputing.com",
                    "https://aws-api.sigmacomputing.com/some/path",
                    "https://unpublished.sigmacomputing.com"):
            with self.subTest(base=bad):
                if os.path.exists(self.log):
                    os.unlink(self.log)
                with self.env(base=None, FAKE_SIGMA_BASE=bad):
                    with self.assertRaisesRegex(get_token.TokenProviderError, "Sigma CLI.*Base URL"):
                        self.mint("sigma-cli")
                self.assertFalse(any(c.startswith("auth token") for c in self.calls()))

    def test_status_without_base_url_is_refused(self):
        with self.env(base=CLI_BASE, FAKE_SIGMA_BASE=""):
            with self.assertRaisesRegex(get_token.TokenProviderError, "Base URL"):
                self.mint("sigma-cli")
        self.assertFalse(any(c.startswith("auth token") for c in self.calls()))

    def test_non_jwt_output_is_refused(self):
        for junk in ("not a jwt", "{\"access_token\": \"x.y.z\"}", "a.b", "a.b.c.d", "a b.c.d", ""):
            with self.subTest(output=junk):
                with self.env(base=CLI_BASE, FAKE_SIGMA_TOKEN=junk):
                    with self.assertRaisesRegex(get_token.TokenProviderError, "Sigma CLI.*JWT") as raised:
                        self.mint("sigma-cli")
                if junk:
                    self.assertNotIn(junk, str(raised.exception))

    def test_sigma_cli_mode_errors_cleanly_when_cli_missing(self):
        with self.env(with_cli=False, base=CLI_BASE, SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_mint_client_credentials") as client:
            with self.assertRaisesRegex(get_token.TokenProviderError, "Sigma CLI"):
                self.mint("sigma-cli")
        client.assert_not_called()

    def test_sigmahq_like_binary_is_treated_as_unavailable(self):
        with self.env(base=CLI_BASE, FAKE_SIGMA_HELP_FAIL="1"):
            with self.assertRaisesRegex(get_token.TokenProviderError, "Sigma CLI"):
                self.mint("sigma-cli")
        self.assertEqual(["auth --help"], self.calls())

    def test_sigmahq_like_binary_falls_through_in_auto(self):
        expected = get_token.TokenResult(BASE, "client-token", MINTED, "client-credentials")
        with self.env(base=BASE, FAKE_SIGMA_HELP_FAIL="1",
                      SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_mint_client_credentials", return_value=expected):
            result, _err = self.mint()
        self.assertEqual("client-credentials", result.auth_method)
        self.assertEqual(["auth --help"], self.calls())

    def test_profile_env_is_passed_as_dash_p(self):
        with self.env(base=CLI_BASE, SIGMA_CLI_PROFILE="example-profile"):
            result, _err = self.mint("sigma-cli")
        self.assertEqual("sigma-cli", result.auth_method)
        calls = self.calls()
        self.assertIn("auth status -p example-profile", calls)
        self.assertIn("auth token -p example-profile", calls)

    def test_no_profile_means_no_dash_p(self):
        with self.env(base=CLI_BASE):
            self.mint("sigma-cli")
        self.assertIn("auth status", self.calls())
        self.assertIn("auth token", self.calls())
        self.assertFalse(any("-p" in c.split() for c in self.calls()))

    def test_unsafe_profile_name_is_rejected_before_running_the_cli(self):
        with self.env(base=CLI_BASE, SIGMA_CLI_PROFILE="--format"):
            with self.assertRaisesRegex(get_token.TokenProviderError, "SIGMA_CLI_PROFILE"):
                self.mint("sigma-cli")
        self.assertEqual([], self.calls())

    def test_signed_out_cli_falls_through_in_auto_with_cli_hint(self):
        with self.env(base=CLI_BASE, FAKE_SIGMA_TOKEN_FAIL="1"):
            with self.assertRaisesRegex(get_token.TokenProviderError, "sigma auth login"):
                self.mint()

    def test_failed_status_report_is_not_accepted(self):
        with self.env(base=CLI_BASE, FAKE_SIGMA_AUTH="FAILED (401)"):
            with self.assertRaisesRegex(get_token.TokenProviderError, "not authenticated"):
                self.mint("sigma-cli")
        self.assertFalse(any(c.startswith("auth token") for c in self.calls()))

    def test_unset_base_without_cli_still_requires_base_url(self):
        with self.env(with_cli=False, base=None):
            with self.assertRaisesRegex(get_token.TokenProviderError, "SIGMA_BASE_URL"):
                self.mint()

    def test_cli_profile_can_be_persisted_in_the_neutral_env_file(self):
        path = os.path.join(self.tmp.name, "env")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("export SIGMA_CLI_PROFILE='example-profile'\n")
        with self.env(base=CLI_BASE), \
             mock.patch.object(get_token, "_NEUTRAL_ENV", path):
            result, _err = self.mint("sigma-cli")
        self.assertEqual("sigma-cli", result.auth_method)
        self.assertIn("auth status -p example-profile", self.calls())
        self.assertIn("auth token -p example-profile", self.calls())

    def test_explicit_cli_profile_env_wins_over_the_neutral_env_file(self):
        path = os.path.join(self.tmp.name, "env")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("export SIGMA_CLI_PROFILE='from-file'\n")
        with self.env(base=CLI_BASE, SIGMA_CLI_PROFILE="from-env"), \
             mock.patch.object(get_token, "_NEUTRAL_ENV", path):
            self.mint("sigma-cli")
        self.assertIn("auth status -p from-env", self.calls())
        self.assertFalse(any("from-file" in c for c in self.calls()))

    def test_cli_never_runs_login(self):
        with self.env(base=CLI_BASE):
            self.mint("sigma-cli")
        self.assertFalse(any("login" in c for c in self.calls()))

    def test_main_accepts_sigma_cli_mode_and_prints_derived_base(self):
        out = io.StringIO()
        with self.env(base=None), \
             mock.patch.object(get_token, "_keychain_backend", return_value=None), \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda r: r), \
             contextlib.redirect_stdout(out):
            rc = get_token.main(["--auth-mode", "sigma-cli", "--print-export"])
        self.assertEqual(0, rc)
        text = out.getvalue()
        self.assertIn(f"export SIGMA_API_TOKEN={FAKE_JWT}", text)
        self.assertIn("export SIGMA_AUTH_METHOD=sigma-cli", text)
        self.assertIn(f"export SIGMA_BASE_URL={CLI_BASE}", text)
        self.assertIn("unset SIGMA_TOKEN_MINTED_AT", text)

    def test_sigma_auth_mode_env_selects_sigma_cli(self):
        with self.env(base=CLI_BASE, SIGMA_AUTH_MODE="sigma-cli"), \
             mock.patch.object(get_token, "_mint_browser_refresh") as browser:
            result, _err = self.mint()
        self.assertEqual("sigma-cli", result.auth_method)
        browser.assert_not_called()

    def test_browser_mode_never_consults_cli(self):
        with self.env(base=CLI_BASE):
            with self.assertRaisesRegex(get_token.TokenProviderError, "browser auth unavailable"):
                self.mint("browser")
        self.assertEqual([], self.calls())

    def test_client_credentials_mode_never_consults_cli(self):
        expected = get_token.TokenResult(BASE, "client-token", MINTED, "client-credentials")
        with self.env(base=BASE, SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_mint_client_credentials", return_value=expected):
            result, _err = self.mint("client-credentials")
        self.assertEqual("client-credentials", result.auth_method)
        self.assertEqual([], self.calls())


class SigmaCliShellFallbackTest(unittest.TestCase):
    """get-token.sh on a Python-free host: Sigma CLI first, then client credentials."""

    SCRIPT = os.path.join(os.path.dirname(__file__), "get-token.sh")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(self.bindir)
        self.log = os.path.join(self.tmp.name, "sigma.log")
        # Only the tools the script legitimately needs, so python is absent.
        for name in ("dirname", "date", "mktemp", "rm", "sleep", "cat"):
            for root in ("/usr/bin", "/bin"):
                src = os.path.join(root, name)
                if os.path.exists(src):
                    os.symlink(src, os.path.join(self.bindir, name))
                    break
        path = os.path.join(self.bindir, "sigma")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(FAKE_SIGMA)
        os.chmod(path, 0o755)

    def run_script(self, *args, **env):
        merged = {
            "PATH": self.bindir,
            "FAKE_SIGMA_LOG": self.log,
            "FAKE_SIGMA_BASE": CLI_BASE,
            "FAKE_SIGMA_TOKEN": FAKE_JWT,
        }
        merged.update(env)
        return subprocess.run(
            ["/bin/bash", self.SCRIPT, *args],
            env=merged, capture_output=True, text=True, check=False,
        )

    def test_cli_token_is_emitted_with_derived_base(self):
        proc = self.run_script()
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn(f"export SIGMA_API_TOKEN={FAKE_JWT}", proc.stdout)
        self.assertIn("export SIGMA_AUTH_METHOD=sigma-cli", proc.stdout)
        self.assertIn(f"export SIGMA_BASE_URL={CLI_BASE}", proc.stdout)
        self.assertIn("unset SIGMA_TOKEN_MINTED_AT", proc.stdout)

    def test_cli_token_ignores_status_text_on_stderr(self):
        proc = self.run_script(FAKE_SIGMA_TOKEN_STDERR="Using profile example-profile")
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn(f"export SIGMA_API_TOKEN={FAKE_JWT}", proc.stdout)

    def test_profile_is_passed_as_dash_p(self):
        proc = self.run_script("--auth-mode", "sigma-cli", SIGMA_CLI_PROFILE="example-profile")
        self.assertEqual(0, proc.returncode, proc.stderr)
        with open(self.log, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        self.assertIn("auth token -p example-profile", lines)

    def test_host_mismatch_is_refused_and_token_never_minted(self):
        proc = self.run_script("--auth-mode", "sigma-cli",
                               SIGMA_BASE_URL="https://api.sigmacomputing.com")
        self.assertNotEqual(0, proc.returncode)
        self.assertNotIn(FAKE_JWT, proc.stdout + proc.stderr)
        if os.path.exists(self.log):
            with open(self.log, encoding="utf-8") as handle:
                self.assertNotIn("auth token", handle.read())

    def test_non_sigma_host_and_non_jwt_are_refused(self):
        bad_host = self.run_script("--auth-mode", "sigma-cli", FAKE_SIGMA_BASE="https://api.evil.test")
        self.assertNotEqual(0, bad_host.returncode)
        junk = self.run_script("--auth-mode", "sigma-cli", FAKE_SIGMA_TOKEN="not a jwt")
        self.assertNotEqual(0, junk.returncode)
        self.assertNotIn("export SIGMA_API_TOKEN", junk.stdout)

    def test_missing_or_sigmahq_binary_is_unavailable(self):
        os.unlink(os.path.join(self.bindir, "sigma"))
        proc = self.run_script("--auth-mode", "sigma-cli")
        self.assertNotEqual(0, proc.returncode)
        self.assertIn("Sigma CLI", proc.stderr)

    def test_sigmahq_like_binary_is_unavailable(self):
        proc = self.run_script("--auth-mode", "sigma-cli", FAKE_SIGMA_HELP_FAIL="1")
        self.assertNotEqual(0, proc.returncode)
        self.assertIn("Sigma CLI", proc.stderr)

    def test_usage_lists_sigma_cli_mode(self):
        proc = self.run_script("--bogus")
        self.assertEqual(64, proc.returncode)
        self.assertIn("sigma-cli", proc.stderr)


class TransportSchemeTest(unittest.TestCase):
    """Defense in depth below URL validation: the token transport must never
    open a non-https URL, even if one slips past the validators, and must not
    go through urllib.request.urlopen (whose default opener reads file://)."""

    def test_file_url_is_refused_without_reading(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            handle.write('{"access_token": "LEAKED-FROM-DISK"}')
            path = handle.name
        self.addCleanup(os.unlink, path)
        req = get_token.urllib.request.Request("file://" + path)
        with mock.patch.object(get_token.urllib.request, "urlopen",
                               side_effect=AssertionError("urlopen must not be used")):
            with self.assertRaises(get_token.SecurityError):
                get_token._json_response(req, "token request failed")

    def test_http_url_is_refused(self):
        req = get_token.urllib.request.Request("http://aws-api.sigmacomputing.com/v2/auth/token")
        with self.assertRaises(get_token.SecurityError):
            get_token._json_response(req, "token request failed")

    def test_https_goes_through_the_https_only_opener(self):
        req = get_token.urllib.request.Request("https://aws-api.sigmacomputing.com/v2/auth/token")
        opened = []

        class FakeOpener:
            def open(self, request, timeout=None):
                opened.append((request.full_url, timeout))
                return JsonResponse({"access_token": "ok"})

        with mock.patch.object(get_token, "_https_opener", return_value=FakeOpener()), \
                mock.patch.object(get_token.urllib.request, "urlopen",
                                  side_effect=AssertionError("urlopen must not be used")):
            self.assertEqual({"access_token": "ok"},
                             get_token._json_response(req, "token request failed"))
        self.assertEqual([("https://aws-api.sigmacomputing.com/v2/auth/token", 30)], opened)

    def test_opener_has_no_file_ftp_or_data_handler(self):
        with mock.patch.object(get_token.urllib.request, "getproxies",
                               return_value={"https": "http://proxy.example:8080"}):
            handlers = get_token._https_opener().handlers
        bad = (get_token.urllib.request.FileHandler, get_token.urllib.request.FTPHandler,
               get_token.urllib.request.DataHandler, get_token.urllib.request.HTTPHandler)
        self.assertFalse(any(isinstance(h, bad) for h in handlers))
        self.assertTrue(any(isinstance(h, get_token.urllib.request.ProxyHandler)
                            for h in handlers))


if __name__ == "__main__":
    unittest.main()
