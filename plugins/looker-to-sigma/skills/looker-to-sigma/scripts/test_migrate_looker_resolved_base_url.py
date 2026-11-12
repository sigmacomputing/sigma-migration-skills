#!/usr/bin/env python3
"""Offline test: migrate-looker.py's live preflight takes the Sigma host from the
shared client, so a user whose only credential is a signed-in Sigma CLI profile
(no exported SIGMA_BASE_URL) is not refused with "missing env: SIGMA_BASE_URL".

Everything is local: a fake `sigma` CLI first on PATH, the real get_token.py
without its network /v2/whoami check, a temp HOME, every SIGMA_* variable
cleared. The preflight performs no HTTP request itself.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLI_HOST = "aws-api.sigmacomputing.com"
FAKE_JWT = ".".join(["eyJhbGciOiJub25lIn0", "eyJzdWIiOiJmaXh0dXJlIn0", "signature"])

DRIVER = """
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("migrate_looker", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps({"missing": m.sigma_preflight_missing(sys.argv[2] == "reuse")}))
"""

PROVIDER = """
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gt", {gt!r})
gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)
gt._verify_token = lambda result: result  # no network in this offline test
sys.exit(gt.main(sys.argv[1:]))
"""


class ResolvedBaseUrlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        bindir = self.dir / "bin"
        bindir.mkdir()
        self.cli_log = self.dir / "cli.log"
        cli = bindir / "sigma"
        cli.write_text(
            "#!/bin/sh\n"
            f'echo "$*" >> "{self.cli_log}"\n'
            'case "$1 $2" in\n'
            "  'auth --help') echo 'Commands: login status token' ;;\n"
            f"  'auth status') printf 'Profile:  example\\nBase URL: https://{CLI_HOST}\\nAuth:     OK\\n' ;;\n"
            "  'auth token') printf '%s\\n' \"$FAKE_SIGMA_TOKEN\" ;;\n"
            "  *) exit 3 ;;\n"
            "esac\n"
        )
        cli.chmod(0o700)
        provider = self.dir / "provider.py"
        provider.write_text(PROVIDER.format(gt=str(HERE / "get_token.py")))
        self.driver = self.dir / "driver.py"
        self.driver.write_text(DRIVER)
        self.env = {
            k: v for k, v in os.environ.items() if not k.startswith(("SIGMA_", "TABLEAU_"))
        }
        self.env.update(
            HOME=str(self.dir),
            PATH=f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}",
            SIGMA_TOKEN_PROVIDER=str(provider),
            SIGMA_PYTHON=sys.executable,
            FAKE_SIGMA_TOKEN=FAKE_JWT,
            SIGMA_CONNECTION_ID="conn-1",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def run_preflight(self, reuse_dm=True, **extra):
        env = dict(self.env, **extra)
        done = subprocess.run(
            [sys.executable, str(self.driver), str(HERE / "migrate-looker.py"),
             "reuse" if reuse_dm else "new"],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(0, done.returncode, done.stderr)
        return json.loads(done.stdout.strip().splitlines()[-1])["missing"]

    def test_cli_only_user_is_not_refused(self):
        self.assertEqual([], self.run_preflight())
        self.assertTrue(self.cli_log.exists(), "the CLI profile should have been consulted")

    def test_explicit_base_url_wins_and_cli_is_not_consulted(self):
        self.assertEqual([], self.run_preflight(SIGMA_BASE_URL="https://api.sigmacomputing.com"))
        self.assertFalse(self.cli_log.exists())

    def test_caller_token_without_base_url_reports_clear_message(self):
        missing = self.run_preflight(SIGMA_API_TOKEN="caller-token")
        self.assertEqual(1, len(missing), missing)
        self.assertIn("SIGMA_BASE_URL not set", missing[0])
        self.assertFalse(self.cli_log.exists())

    def test_missing_connection_id_still_reported(self):
        self.env.pop("SIGMA_CONNECTION_ID")
        missing = self.run_preflight(reuse_dm=False, SIGMA_BASE_URL="https://api.sigmacomputing.com")
        self.assertEqual(1, len(missing))
        self.assertIn("SIGMA_CONNECTION_ID", missing[0])


if __name__ == "__main__":
    unittest.main()
