#!/usr/bin/env python3
"""Credential-free dual-mode auth tests for sigma_rest.py."""

import base64
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
import unittest
from unittest import mock

import sigma_rest


BASE = "https://api.sigmacomputing.com"
PROVIDER = {
    "SIGMA_API_TOKEN": "browser-refreshed-token",
    "SIGMA_TOKEN_MINTED_AT": "2026-10-05T20:00:00Z",
    "SIGMA_AUTH_METHOD": "browser",
}


class SigmaRestDualAuthTest(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(
            os.environ,
            {"SIGMA_BASE_URL": BASE, "SIGMA_API_TOKEN": "caller-token"},
            clear=True,
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()

    def test_unknown_age_caller_token_waits_for_401_then_refreshes_without_client_id(self):
        responses = [
            sigma_rest._Resp(401, "unauthorized"),
            sigma_rest._Resp(200, '{"ok":true}'),
        ]
        authorizations = []

        def send(_method, _url, headers, _body, _timeout):
            authorizations.append(headers["Authorization"])
            return responses.pop(0)

        with mock.patch.object(sigma_rest, "_send", side_effect=send), mock.patch.object(
            sigma_rest, "token_provider_result", return_value=PROVIDER
        ):
            result = sigma_rest.request("get", "/v2/whoami")

        self.assertEqual({"ok": True}, result)
        self.assertEqual(
            ["Bearer caller-token", "Bearer browser-refreshed-token"],
            authorizations,
        )
        self.assertEqual("browser", os.environ["SIGMA_AUTH_METHOD"])

    def test_known_stale_token_refreshes_proactively_without_client_id(self):
        os.environ["SIGMA_TOKEN_MINTED_AT"] = "2000-01-01T00:00:00Z"
        with mock.patch.object(
            sigma_rest, "token_provider_result", return_value=PROVIDER
        ):
            self.assertEqual("browser-refreshed-token", sigma_rest.auth_token())

    def test_cli_token_never_refreshes_proactively(self):
        os.environ["SIGMA_AUTH_METHOD"] = "sigma-cli"
        os.environ["SIGMA_TOKEN_MINTED_AT"] = "2000-01-01T00:00:00Z"
        with mock.patch.object(sigma_rest, "token_provider_result") as provider:
            self.assertEqual("caller-token", sigma_rest.auth_token())
        provider.assert_not_called()

    def test_cli_401_remint_pins_provider_to_cli_mode(self):
        os.environ["SIGMA_AUTH_METHOD"] = "sigma-cli"
        completed = subprocess.CompletedProcess(
            [],
            0,
            stdout=(
                "export SIGMA_API_TOKEN=cli-refreshed-token\n"
                "export SIGMA_AUTH_METHOD=sigma-cli\n"
            ),
            stderr="",
        )
        with mock.patch.object(subprocess, "run", return_value=completed) as run:
            values = sigma_rest.token_provider_result()

        self.assertEqual("cli-refreshed-token", values["SIGMA_API_TOKEN"])
        self.assertIn(
            ["--auth-mode", "sigma-cli"],
            [run.call_args.args[0][i:i + 2] for i in range(len(run.call_args.args[0]) - 1)],
        )

    def provider_stdout(self, *lines):
        return subprocess.CompletedProcess([], 0, stdout="\n".join(lines) + "\n", stderr="")

    def test_provider_output_without_mint_time_is_rejected_for_non_cli_methods(self):
        for method in ("browser", "client-credentials"):
            with self.subTest(method=method):
                completed = self.provider_stdout(
                    "export SIGMA_API_TOKEN=minted-token",
                    f"export SIGMA_AUTH_METHOD={method}",
                )
                with mock.patch.object(subprocess, "run", return_value=completed):
                    with self.assertRaisesRegex(sigma_rest.SigmaAuthError, "SIGMA_TOKEN_MINTED_AT"):
                        sigma_rest.token_provider_result()

    def test_provider_output_without_mint_time_is_accepted_for_sigma_cli(self):
        completed = self.provider_stdout(
            "export SIGMA_API_TOKEN=cli-token",
            "unset SIGMA_TOKEN_MINTED_AT",
            "export SIGMA_AUTH_METHOD=sigma-cli",
        )
        with mock.patch.object(subprocess, "run", return_value=completed):
            values = sigma_rest.token_provider_result()
        self.assertEqual("cli-token", values["SIGMA_API_TOKEN"])
        self.assertNotIn("SIGMA_TOKEN_MINTED_AT", values)

    def test_refresh_requires_mint_time_unless_sigma_cli(self):
        for incomplete in (
            {"SIGMA_API_TOKEN": "token"},
            {"SIGMA_API_TOKEN": "token", "SIGMA_AUTH_METHOD": "browser"},
        ):
            with self.subTest(result=incomplete):
                with mock.patch.object(sigma_rest, "token_provider_result", return_value=incomplete):
                    with self.assertRaises(sigma_rest.SigmaAuthError):
                        sigma_rest.refresh_token()
        cli = {"SIGMA_API_TOKEN": "cli-token", "SIGMA_AUTH_METHOD": "sigma-cli"}
        os.environ["SIGMA_TOKEN_MINTED_AT"] = "2000-01-01T00:00:00Z"
        with mock.patch.object(sigma_rest, "token_provider_result", return_value=cli):
            self.assertEqual("cli-token", sigma_rest.refresh_token())
        self.assertNotIn("SIGMA_TOKEN_MINTED_AT", os.environ)
        self.assertIsNone(sigma_rest.token_minted_at())

    def test_second_401_is_not_retried(self):
        responses = [
            sigma_rest._Resp(401, "unauthorized"),
            sigma_rest._Resp(401, "still unauthorized"),
        ]
        with mock.patch.object(
            sigma_rest, "_send", side_effect=lambda *_args: responses.pop(0)
        ), mock.patch.object(
            sigma_rest, "token_provider_result", return_value=PROVIDER
        ):
            with self.assertRaises(sigma_rest.SigmaError):
                sigma_rest.request("get", "/v2/whoami")
        self.assertEqual([], responses)

    def test_concurrent_refresh_waits_for_the_same_result_or_failure(self):
        for failure in (None, sigma_rest.SigmaAuthError("synthetic mint failure"), SystemExit("synthetic validation exit")):
            with self.subTest(failure=failure):
                entered, release, waiter_done = threading.Event(), threading.Event(), threading.Event()
                sigma_rest._token_override = "expired-token"

                def provider():
                    entered.set()
                    if not release.wait(3):
                        raise RuntimeError("test release timed out")
                    if failure:
                        raise failure
                    return PROVIDER

                def waiter():
                    try:
                        return sigma_rest.refresh_token()
                    finally:
                        waiter_done.set()

                with mock.patch.object(sigma_rest, "token_provider_result", side_effect=provider) as mint:
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        leader = pool.submit(sigma_rest.refresh_token)
                        self.assertTrue(entered.wait(3))
                        follower = pool.submit(waiter)
                        try:
                            self.assertFalse(waiter_done.wait(0.1), "waiter returned the stale token while minting")
                        finally:
                            release.set()
                        for future in (leader, follower):
                            if failure:
                                with self.assertRaises(type(failure)):
                                    future.result(timeout=3)
                            else:
                                self.assertEqual("browser-refreshed-token", future.result(timeout=3))
                    self.assertEqual(1, mint.call_count)
                with mock.patch.object(sigma_rest, "token_provider_result", return_value=PROVIDER):
                    self.assertEqual("browser-refreshed-token", sigma_rest.refresh_token())

    def test_auth_json_prefers_provider_metadata_over_file_mtime(self):
        with tempfile.TemporaryDirectory() as workdir:
            with open(os.path.join(workdir, "auth.json"), "w", encoding="utf-8") as handle:
                json.dump(
                    {
                        "SIGMA_API_TOKEN": "file-token",
                        "SIGMA_BASE_URL": BASE,
                        "SIGMA_TOKEN_MINTED_AT": "2026-10-05T20:00:00Z",
                        "SIGMA_AUTH_METHOD": "browser",
                    },
                    handle,
                )
            os.environ.pop("SIGMA_API_TOKEN")
            sigma_rest._load_auth_json(cwd=workdir)

        self.assertEqual("2026-10-05T20:00:00Z", os.environ["SIGMA_TOKEN_MINTED_AT"])
        self.assertEqual("browser", os.environ["SIGMA_AUTH_METHOD"])

    def test_cli_auth_json_does_not_infer_token_age_from_file_mtime(self):
        with tempfile.TemporaryDirectory() as workdir:
            with open(os.path.join(workdir, "auth.json"), "w", encoding="utf-8") as handle:
                json.dump(
                    {
                        "SIGMA_API_TOKEN": "cli-token",
                        "SIGMA_BASE_URL": BASE,
                        "SIGMA_AUTH_METHOD": "sigma-cli",
                    },
                    handle,
                )
            os.environ.pop("SIGMA_API_TOKEN")
            sigma_rest._load_auth_json(cwd=workdir)

        self.assertNotIn("SIGMA_TOKEN_MINTED_AT", os.environ)


CLI_BASE = "https://aws-api.sigmacomputing.com"
def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


# Built at runtime (header {"alg":"none"}, payload {"sub":"test"}, signature
# "signature") so no JWT-shaped literal sits in the source.
FAKE_JWT = ".".join(
    _b64url(part) for part in (b'{"alg":"none"}', b'{"sub":"test"}', b"signature")
)
DERIVED_PROVIDER = {
    "SIGMA_API_TOKEN": "browser-refreshed-token",
    "SIGMA_AUTH_METHOD": "sigma-cli",
    "SIGMA_BASE_URL": CLI_BASE,
}

FAKE_SIGMA = """#!/bin/bash
# Synthetic stand-in for the Sigma CLI.
if [ "$1 $2" = "auth --help" ]; then echo "Commands: login token status"; exit 0; fi
if [ "$1 $2" = "auth status" ]; then
  { echo "Profile:   example-profile"; echo "${FAKE_SIGMA_BASE_LABEL:-Base URL}:  ${FAKE_SIGMA_BASE}"; echo "Auth:      OK (token acquired)"; } >&2
  exit 0
fi
if [ "$1 $2" = "auth token" ]; then printf '%s\\n' "${FAKE_SIGMA_TOKEN}"; exit 0; fi
exit 3
"""


def write_executable(path, contents):
    """Create an owner-only executable test stub (mode fixed at creation)."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o700)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(contents)


def _find_provider():
    here = os.path.dirname(os.path.abspath(__file__))
    for rel in ("../get_token.py", "../scripts/get_token.py"):
        path = os.path.abspath(os.path.join(here, rel))
        if os.path.isfile(path):
            return path
    return None


class SigmaRestDerivedBaseTest(unittest.TestCase):
    """CLI-only user: SIGMA_BASE_URL unset, the provider supplies the host."""

    def setUp(self):
        self.env = mock.patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()

    def sent(self):
        urls = []

        def send(_method, url, headers, _body, _timeout):
            urls.append((url, headers["Authorization"]))
            return sigma_rest._Resp(200, '{"ok":true}')

        return urls, send

    def test_request_derives_base_url_from_the_provider_result(self):
        urls, send = self.sent()
        with mock.patch.object(sigma_rest, "_send", side_effect=send), \
             mock.patch.object(sigma_rest, "token_provider_result", return_value=DERIVED_PROVIDER):
            result = sigma_rest.request("get", "/v2/whoami")
        self.assertEqual({"ok": True}, result)
        self.assertEqual([(f"{CLI_BASE}/v2/whoami", "Bearer browser-refreshed-token")], urls)
        self.assertEqual(CLI_BASE, os.environ["SIGMA_BASE_URL"])
        self.assertEqual("sigma-cli", os.environ["SIGMA_AUTH_METHOD"])
        self.assertIsNone(sigma_rest.token_minted_at())

    def test_derived_non_sigma_host_is_refused_before_any_request(self):
        urls, send = self.sent()
        evil = dict(DERIVED_PROVIDER, SIGMA_BASE_URL="https://api.evil.test")
        with mock.patch.object(sigma_rest, "_send", side_effect=send), \
             mock.patch.object(sigma_rest, "token_provider_result", return_value=evil):
            with self.assertRaises(SystemExit):
                sigma_rest.request("get", "/v2/whoami")
        self.assertEqual([], urls)
        self.assertNotIn("SIGMA_BASE_URL", os.environ)
        self.assertNotIn("SIGMA_API_TOKEN", os.environ)

    def test_derived_non_https_host_is_refused(self):
        urls, send = self.sent()
        plain = dict(DERIVED_PROVIDER, SIGMA_BASE_URL="http://aws-api.sigmacomputing.com")
        with mock.patch.object(sigma_rest, "_send", side_effect=send), \
             mock.patch.object(sigma_rest, "token_provider_result", return_value=plain):
            with self.assertRaises(SystemExit):
                sigma_rest.request("get", "/v2/whoami")
        self.assertEqual([], urls)

    def test_explicit_base_url_wins_over_a_derived_one(self):
        os.environ["SIGMA_BASE_URL"] = BASE
        os.environ["SIGMA_API_TOKEN"] = "caller-token"
        urls, send = self.sent()
        responses = [sigma_rest._Resp(401, "no"), sigma_rest._Resp(200, "{}")]

        def send_401(_m, url, headers, _b, _t):
            urls.append(url)
            return responses.pop(0)

        with mock.patch.object(sigma_rest, "_send", side_effect=send_401), \
             mock.patch.object(sigma_rest, "token_provider_result", return_value=DERIVED_PROVIDER):
            sigma_rest.request("get", "/v2/whoami")
        self.assertEqual(BASE, os.environ["SIGMA_BASE_URL"])
        self.assertEqual([f"{BASE}/v2/whoami"] * 2, urls)

    def test_a_caller_token_without_a_base_url_never_triggers_derivation(self):
        os.environ["SIGMA_API_TOKEN"] = "caller-token"
        with mock.patch.object(sigma_rest, "token_provider_result") as provider:
            with self.assertRaisesRegex(sigma_rest.SigmaError, "SIGMA_BASE_URL not set"):
                sigma_rest.request("get", "/v2/whoami")
        provider.assert_not_called()

    def test_provider_without_a_base_url_leaves_the_clear_error(self):
        with mock.patch.object(sigma_rest, "token_provider_result", return_value=PROVIDER):
            with self.assertRaisesRegex(sigma_rest.SigmaError, "SIGMA_BASE_URL"):
                sigma_rest.request("get", "/v2/whoami")

    def test_fake_cli_through_the_real_provider_reaches_the_derived_host(self):
        provider = _find_provider()
        if provider is None:
            self.skipTest("get_token.py is not vendored next to this sigma_rest.py")
        with tempfile.TemporaryDirectory() as tmp:
            bindir = os.path.join(tmp, "bin")
            os.makedirs(bindir)
            write_executable(os.path.join(bindir, "sigma"), FAKE_SIGMA)
            # The real provider, minus its network /v2/whoami verification.
            wrapper = os.path.join(tmp, "provider.py")
            with open(wrapper, "w", encoding="utf-8") as handle:
                handle.write(
                    "import importlib.util, sys\n"
                    f"spec = importlib.util.spec_from_file_location('gt', {provider!r})\n"
                    "gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)\n"
                    "gt._verify_token = lambda r: r\n"
                    "sys.exit(gt.main(sys.argv[1:]))\n"
                )
            os.environ.update({
                "HOME": tmp,
                "PATH": bindir + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
                "SIGMA_TOKEN_PROVIDER": wrapper,
                "SIGMA_PYTHON": sys.executable,
                "FAKE_SIGMA_BASE": CLI_BASE,
                "FAKE_SIGMA_TOKEN": FAKE_JWT,
                "SIGMA_AUTH_MODE": "sigma-cli",
            })
            urls, send = self.sent()
            with mock.patch.object(sigma_rest, "_send", side_effect=send):
                sigma_rest.request("get", "/v2/whoami")
        self.assertEqual([(f"{CLI_BASE}/v2/whoami", f"Bearer {FAKE_JWT}")], urls)
        self.assertEqual("sigma-cli", os.environ["SIGMA_AUTH_METHOD"])
        self.assertEqual(CLI_BASE, os.environ["SIGMA_BASE_URL"])


class SigmaRestExplicitProfileTest(unittest.TestCase):
    """An explicit SIGMA_CLI_PROFILE pins the org; the settings file never overrides it."""

    ORG_A = "https://api.sigmacomputing.com"
    SETTINGS = (
        "export SIGMA_BASE_URL='https://api.sigmacomputing.com'\n"
        "export SIGMA_CLIENT_ID='org-a-id'\n"
        "export SIGMA_CLIENT_SECRET='org-a-secret'\n"
        "export SIGMA_AUTH_MODE='client-credentials'\n"
        "export OTHER_SETTING='kept'\n"
    )

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = os.path.join(self.tmp.name, "env")
        with open(self.settings, "w", encoding="utf-8") as handle:
            handle.write(self.SETTINGS)
        patcher = mock.patch.object(sigma_rest, "NEUTRAL_ENV", self.settings)
        patcher.start()
        self.addCleanup(patcher.stop)

    def load(self, **env):
        values = {}
        values.update(env)
        sigma_rest._load_neutral_env(values)
        return values

    def test_explicit_profile_skips_org_keys_but_loads_other_keys(self):
        loaded = self.load(SIGMA_CLI_PROFILE="work (1)")
        for key in ("SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET",
                    "SIGMA_AUTH_MODE"):
            self.assertNotIn(key, loaded)
        self.assertEqual("kept", loaded["OTHER_SETTING"])
        self.assertEqual("work (1)", loaded["SIGMA_CLI_PROFILE"])

    def test_no_profile_loads_the_settings_file_as_before(self):
        loaded = self.load()
        self.assertEqual(self.ORG_A, loaded["SIGMA_BASE_URL"])
        self.assertEqual("org-a-id", loaded["SIGMA_CLIENT_ID"])
        self.assertEqual("client-credentials", loaded["SIGMA_AUTH_MODE"])

    def test_profile_from_the_settings_file_is_not_explicit(self):
        with open(self.settings, "a", encoding="utf-8") as handle:
            handle.write("export SIGMA_CLI_PROFILE='from-file'\n")
        loaded = self.load()
        self.assertEqual(self.ORG_A, loaded["SIGMA_BASE_URL"])
        self.assertEqual("from-file", loaded["SIGMA_CLI_PROFILE"])
        self.assertEqual("from-file", loaded["SIGMA_CLI_PROFILE_FROM_FILE"])

    def test_explicit_profile_under_a_stale_marker_still_pins(self):
        loaded = self.load(SIGMA_CLI_PROFILE="work (1)",
                           SIGMA_CLI_PROFILE_FROM_FILE="from-file")
        self.assertNotIn("SIGMA_BASE_URL", loaded)
        self.assertNotIn("SIGMA_CLIENT_ID", loaded)

    def test_profile_matching_the_marker_is_not_explicit(self):
        loaded = self.load(SIGMA_CLI_PROFILE="from-file",
                           SIGMA_CLI_PROFILE_FROM_FILE="from-file")
        self.assertEqual(self.ORG_A, loaded["SIGMA_BASE_URL"])

    def test_sourced_file_only_profile_without_marker_is_not_explicit(self):
        # `source ~/.sigma-migration/env`: the file's profile, no FROM_FILE marker.
        with open(self.settings, "a", encoding="utf-8") as handle:
            handle.write("export SIGMA_CLI_PROFILE='from-file'\n")
        loaded = self.load(SIGMA_CLI_PROFILE="from-file")
        self.assertEqual(self.ORG_A, loaded["SIGMA_BASE_URL"])
        loaded = self.load(SIGMA_CLI_PROFILE="work (1)")
        self.assertNotIn("SIGMA_BASE_URL", loaded)

    def test_file_set_profile_keeps_the_provider_fallback(self):
        # The child provider sees the marker this loader set: not explicit.
        provider = _find_provider()
        if provider is None:
            self.skipTest("get_token.py is not vendored next to this sigma_rest.py")
        with open(self.settings, "a", encoding="utf-8") as handle:
            handle.write("export SIGMA_CLI_PROFILE='from-file'\n")
        loaded = self.load()
        spec = importlib.util.spec_from_file_location("gt_marker", provider)
        gt = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gt)
        with mock.patch.dict(os.environ, loaded, clear=True):
            self.assertFalse(gt._profile_is_explicit())
        loaded["SIGMA_CLI_PROFILE"] = "work (1)"
        with mock.patch.dict(os.environ, loaded, clear=True):
            self.assertTrue(gt._profile_is_explicit())

    def test_explicit_profile_reaches_the_cli_host_not_the_settings_file_org(self):
        provider = _find_provider()
        if provider is None:
            self.skipTest("get_token.py is not vendored next to this sigma_rest.py")
        bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(bindir)
        write_executable(os.path.join(bindir, "sigma"), FAKE_SIGMA)
        wrapper = os.path.join(self.tmp.name, "provider.py")
        with open(wrapper, "w", encoding="utf-8") as handle:
            handle.write(
                "import importlib.util, sys\n"
                f"spec = importlib.util.spec_from_file_location('gt', {provider!r})\n"
                "gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)\n"
                "gt._verify_token = lambda r: r\n"
                f"gt._NEUTRAL_ENV = {self.settings!r}\n"
                "def _no_client(*a, **k):\n"
                "    raise SystemExit('client-credentials must not be attempted')\n"
                "gt._mint_client_credentials = _no_client\n"
                "sys.exit(gt.main(sys.argv[1:]))\n"
            )
        env = {
            "HOME": self.tmp.name,
            "PATH": bindir + os.pathsep + "/usr/bin:/bin",
            "SIGMA_TOKEN_PROVIDER": wrapper,
            "SIGMA_PYTHON": sys.executable,
            "FAKE_SIGMA_BASE": CLI_BASE,
            "FAKE_SIGMA_TOKEN": FAKE_JWT,
            "SIGMA_CLI_PROFILE": "work (1)",
        }
        with mock.patch.dict(os.environ, env, clear=True):
            sigma_rest._token_override = None
            sigma_rest._minted_at = None
            sigma_rest._refresh_inflight = False
            sigma_rest._validated_bases.clear()
            sigma_rest.bootstrap_credentials(os.environ, self.tmp.name)
            self.assertNotIn("SIGMA_BASE_URL", os.environ)
            self.assertNotIn("SIGMA_CLIENT_ID", os.environ)
            urls = []

            def send(_method, url, headers, _body, _timeout):
                urls.append((url, headers["Authorization"]))
                return sigma_rest._Resp(200, '{"ok":true}')

            with mock.patch.object(sigma_rest, "_send", side_effect=send):
                sigma_rest.request("get", "/v2/whoami")
        self.assertEqual([(f"{CLI_BASE}/v2/whoami", f"Bearer {FAKE_JWT}")], urls)


if __name__ == "__main__":
    unittest.main()
