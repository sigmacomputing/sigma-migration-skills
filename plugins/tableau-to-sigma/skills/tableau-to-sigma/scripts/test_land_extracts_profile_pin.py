#!/usr/bin/env python3
"""An explicit SIGMA_CLI_PROFILE pins the Sigma org in land-extracts.py.

sigma_sync_tables() used to copy SIGMA_BASE_URL / SIGMA_CLIENT_ID /
SIGMA_CLIENT_SECRET from ~/.sigma-migration/env into the environment whenever
they were empty, undoing the vendored sigma_rest loader's pin. Offline: a temp
HOME, a fake `sigma` CLI on PATH, and a stubbed sigma_rest.request.

Usage:  python3 scripts/test_land_extracts_profile_pin.py
"""
import base64
import importlib.util
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
FILE_HOST = "https://org-a.example.com"
CLI_HOST = "https://aws-api.sigmacomputing.com"  # a CLI host must be a Sigma host
SETTINGS = (
    f"export SIGMA_BASE_URL='{FILE_HOST}'\n"
    "export SIGMA_CLIENT_ID='org-a-id'\n"
    "export SIGMA_CLIENT_SECRET='org-a-secret'\n"
    "export SIGMA_CLI_PROFILE='file-profile'\n"
    "export SNOWFLAKE_ACCOUNT='acct-a'\n"
)
ORG_KEYS = ("SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET")


def _b64(part):
    return base64.urlsafe_b64encode(part).rstrip(b"=").decode()


FAKE_JWT = ".".join(_b64(p) for p in (b'{"alg":"none"}', b'{"sub":"t"}', b"sig"))
FAKE_SIGMA = """#!/bin/bash
if [ "$1 $2" = "auth --help" ]; then echo "Commands: login token status"; exit 0; fi
if [ "$1 $2" = "auth status" ]; then
  { echo "Profile:   work (1)"; echo "Base URL:  ${FAKE_SIGMA_BASE}"; echo "Auth:      OK (token acquired)"; } >&2
  exit 0
fi
if [ "$1 $2" = "auth token" ]; then printf '%s\\n' "${FAKE_SIGMA_TOKEN}"; exit 0; fi
exit 3
"""


def load_modules():
    """Fresh land-extracts + sigma_rest, imported under the current env/HOME."""
    for name in ("sigma_rest", "land_extracts_pin"):
        sys.modules.pop(name, None)
    spec = importlib.util.spec_from_file_location(
        "land_extracts_pin", os.path.join(HERE, "land-extracts.py"))
    le = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(le)
    return le, sys.modules["sigma_rest"]


class ProfilePinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = self.tmp.name
        os.makedirs(os.path.join(self.home, ".sigma-migration"))
        self.settings = os.path.join(self.home, ".sigma-migration", "env")
        # The vendored sigma_rest reads <cwd>/auth.json; keep cwd inside the temp HOME.
        prev_cwd = os.getcwd()
        os.chdir(self.home)
        self.addCleanup(os.chdir, prev_cwd)

    def env(self, **extra):
        base = {"HOME": self.home, "PATH": "/usr/bin:/bin"}
        base.update(extra)
        return mock.patch.dict(os.environ, base, clear=True)

    def write_settings(self):
        with open(self.settings, "w", encoding="utf-8") as fh:
            fh.write(SETTINGS)

    def refill(self, **extra):
        """Import with no settings file (so the shared loader loads nothing),
        then write it: only sigma_sync_tables's own refill can load the org keys."""
        with self.env(**extra):
            le, sr = load_modules()
            self.write_settings()
            with mock.patch.object(sr, "auth_token", return_value="t"), \
                    mock.patch.object(sr, "request", return_value={}):
                le.sigma_sync_tables("conn", [], "DB", "SCH")
            return {k: os.environ.get(k) for k in ORG_KEYS}

    def test_explicit_profile_does_not_refill_org_keys(self):
        # base_url() would raise (no host, no CLI) -> sys.exit; the point is that
        # nothing was copied from the file.
        with self.env(SIGMA_CLI_PROFILE="work (1)"):
            le, sr = load_modules()
            self.write_settings()
            with mock.patch.object(sr, "base_url", side_effect=sr.SigmaError("no host")):
                with self.assertRaises(SystemExit):
                    le.sigma_sync_tables("conn", [], "DB", "SCH")
            self.assertEqual({k: None for k in ORG_KEYS},
                             {k: os.environ.get(k) for k in ORG_KEYS})

    def test_no_profile_refills(self):
        got = self.refill()
        self.assertEqual(FILE_HOST, got["SIGMA_BASE_URL"])
        self.assertEqual("org-a-id", got["SIGMA_CLIENT_ID"])
        self.assertEqual("org-a-secret", got["SIGMA_CLIENT_SECRET"])

    def test_env_profile_equal_to_files_own_refills(self):
        self.assertEqual(FILE_HOST, self.refill(SIGMA_CLI_PROFILE="file-profile")["SIGMA_BASE_URL"])

    def test_env_profile_equal_to_from_file_marker_refills(self):
        got = self.refill(SIGMA_CLI_PROFILE="work (1)", SIGMA_CLI_PROFILE_FROM_FILE="work (1)")
        self.assertEqual(FILE_HOST, got["SIGMA_BASE_URL"])

    def test_case_difference_is_pinned(self):
        with self.env(SIGMA_CLI_PROFILE="Work (1)", SIGMA_CLI_PROFILE_FROM_FILE="work (1)"):
            le, _ = load_modules()
            self.write_settings()
            self.assertTrue(le.sigma_profile_pinned())
        with self.env(SIGMA_CLI_PROFILE="File-Profile"):
            le, _ = load_modules()
            self.write_settings()
            self.assertTrue(le.sigma_profile_pinned())

    def test_non_utf8_settings_file_does_not_crash(self):
        with self.env(SIGMA_CLI_PROFILE="work (1)"):
            # Import first: the vendored shared loader (not under test) is strict
            # UTF-8 at import time. The file turns Latin-1 before the sync runs.
            le, sr = load_modules()
            with open(self.settings, "wb") as fh:
                fh.write(b"export SIGMA_CLI_PROFILE='caf\xe9'\nexport SIGMA_BASE_URL='"
                         + FILE_HOST.encode() + b"'\n")
            # Unreadable-as-UTF-8 file profile is treated as '' -> pinned, no refill.
            self.assertTrue(le.sigma_profile_pinned())
            with mock.patch.object(sr, "base_url", side_effect=sr.SigmaError("no host")):
                with self.assertRaises(SystemExit):
                    le.sigma_sync_tables("conn", [], "DB", "SCH")
            self.assertIsNone(os.environ.get("SIGMA_BASE_URL"))

    def test_pinned_predicate_matrix(self):
        cases = [
            ({}, False),
            ({"SIGMA_CLI_PROFILE": "  "}, False),
            ({"SIGMA_CLI_PROFILE": "work (1)"}, True),
            ({"SIGMA_CLI_PROFILE": "file-profile"}, False),
            ({"SIGMA_CLI_PROFILE": "work (1)", "SIGMA_CLI_PROFILE_FROM_FILE": "work (1)"}, False),
        ]
        for extra, want in cases:
            with self.subTest(extra=extra), self.env(**extra):
                le, _ = load_modules()
                self.write_settings()
                self.assertEqual(want, le.sigma_profile_pinned())

    def test_explicit_profile_resolves_the_cli_host_not_the_files(self):
        provider = os.path.join(HERE, "get_token.py")
        bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(bindir)
        cli = os.path.join(bindir, "sigma")
        with open(cli, "w", encoding="utf-8") as fh:
            fh.write(FAKE_SIGMA)
        # Test fixture: an owner-only (0o700) fake CLI stub in a temp dir, so the test can exec it.
        # nosemgrep: python.lang.security.audit.insecure-file-permissions.insecure-file-permissions
        os.chmod(cli, 0o700)
        wrapper = os.path.join(self.tmp.name, "provider.py")
        with open(wrapper, "w", encoding="utf-8") as fh:
            fh.write(
                "import importlib.util, sys\n"
                f"spec = importlib.util.spec_from_file_location('gt', {provider!r})\n"
                "gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)\n"
                "gt._verify_token = lambda r: r\n"
                f"gt._NEUTRAL_ENV = {self.settings!r}\n"
                "def _no_client(*a, **k):\n"
                "    raise SystemExit('client-credentials must not be attempted')\n"
                "gt._mint_client_credentials = _no_client\n"
                "sys.exit(gt.main(sys.argv[1:]))\n")
        seen = []
        with self.env(PATH=bindir + os.pathsep + "/usr/bin:/bin",
                      SIGMA_CLI_PROFILE="work (1)", SIGMA_TOKEN_PROVIDER=wrapper,
                      SIGMA_PYTHON=sys.executable, FAKE_SIGMA_BASE=CLI_HOST,
                      FAKE_SIGMA_TOKEN=FAKE_JWT):
            le, sr = load_modules()
            self.write_settings()

            def fake_request(method, path, **kw):
                seen.append((sr.base_url(), os.environ.get("SIGMA_CLIENT_ID")))
                return {}

            with mock.patch.object(sr, "request", side_effect=fake_request):
                ok, fail = le.sigma_sync_tables("conn", ["T1"], "DB", "SCH")
            self.assertEqual((1, 0), (ok, fail))
            self.assertEqual([(CLI_HOST, None)], seen)
            self.assertEqual(CLI_HOST, os.environ["SIGMA_BASE_URL"])
            self.assertNotIn("SIGMA_CLIENT_SECRET", os.environ)


if __name__ == "__main__":
    unittest.main()
