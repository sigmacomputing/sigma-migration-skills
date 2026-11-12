#!/usr/bin/env python3
"""Offline test: sisense scripts take the Sigma host from the shared client.

A user whose only credential is a signed-in Sigma CLI profile has no exported
SIGMA_BASE_URL. Each case runs a real script in a subprocess with a fake `sigma`
CLI first on PATH, the real get_token.py (its network /v2/whoami check stubbed),
a temp HOME and every SIGMA_* / TABLEAU_* variable cleared. Nothing leaves the
machine: sigma-export-png.py runs through a wrapper that replaces requests.post /
requests.get with recorders.

  sigma-export-png.py   fixed: read os.environ["SIGMA_BASE_URL"] directly
  migrate-sisense.py    regression guard: load_sigma_env() leaves the resolved
                        host and token in the environment for the live preflights
  post-sisense-spec.py  regression guard: Client() with no --base-url resolves it
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent / "scripts"
CLI_HOST = "aws-api.sigmacomputing.com"
FAKE_JWT = ".".join(["eyJhbGciOiJub25lIn0", "eyJzdWIiOiJmaXh0dXJlIn0", "signature"])

PROVIDER = """
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gt", {gt!r})
gt = importlib.util.module_from_spec(spec); spec.loader.exec_module(gt)
gt._verify_token = lambda result: result  # no network in this offline test
sys.exit(gt.main(sys.argv[1:]))
"""

EXPORT_WRAPPER = """
import json, os, runpy, sys
import requests

LOG = os.environ["RECORD_LOG"]
PNG = b"\\x89PNG\\r\\n\\x1a\\n" + b"fixture"


class Resp:
    def __init__(self, status, payload=None, content=b"", ctype="application/json"):
        self.status_code, self._payload = status, payload
        self.content, self.text = content, json.dumps(payload)
        self.headers = {"Content-Type": ctype}

    def json(self):
        return self._payload


def record(method, url, headers):
    with open(LOG, "a") as fh:
        fh.write(json.dumps({"method": method, "url": url,
                             "auth": (headers or {}).get("Authorization")}) + "\\n")


def post(url, headers=None, json=None, **kw):
    record("POST", url, headers)
    return Resp(200, {"queryId": "q1"})


def get(url, headers=None, **kw):
    record("GET", url, headers)
    return Resp(200, content=PNG, ctype="image/png")


requests.post, requests.get = post, get
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
"""

MIGRATE_DRIVER = """
import importlib.util, json, os, sys, tempfile
spec = importlib.util.spec_from_file_location("migrate_sisense", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.load_sigma_env(tempfile.mkdtemp())
print(json.dumps({"base": os.environ.get("SIGMA_BASE_URL"),
                  "token": os.environ.get("SIGMA_API_TOKEN")}))
"""

POST_DRIVER = """
import importlib.util, json, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("post_sisense_spec", sys.argv[2])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(json.dumps({"base": m.Client().base}))
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
        provider.write_text(PROVIDER.format(gt=str(SCRIPTS / "get_token.py")))
        self.record_log = self.dir / "requests.jsonl"
        self.env = {
            k: v for k, v in os.environ.items() if not k.startswith(("SIGMA_", "TABLEAU_"))
        }
        self.env.update(
            HOME=str(self.dir),
            PATH=f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}",
            SIGMA_TOKEN_PROVIDER=str(provider),
            SIGMA_PYTHON=sys.executable,
            FAKE_SIGMA_TOKEN=FAKE_JWT,
            RECORD_LOG=str(self.record_log),
        )

    def tearDown(self):
        self.tmp.cleanup()

    def python(self, code, *args, **extra):
        driver = self.dir / f"driver{abs(hash(code))}.py"
        driver.write_text(code)
        return subprocess.run(
            [sys.executable, str(driver), *map(str, args)],
            env=dict(self.env, **extra), capture_output=True, text=True,
            timeout=60, cwd=str(self.dir),
        )

    def export_png(self, **extra):
        out = self.dir / "out.png"
        done = self.python(
            EXPORT_WRAPPER, SCRIPTS / "sigma-export-png.py",
            "--workbook", "wb-1", "--page", "pg-1", "--out", out, **extra,
        )
        calls = []
        if self.record_log.exists():
            calls = [json.loads(line) for line in self.record_log.read_text().splitlines()]
        return done, calls, out

    # --- sigma-export-png.py (fixed) ---------------------------------------
    def test_export_png_cli_only_user_reaches_cli_host(self):
        done, calls, out = self.export_png()
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertNotIn("KeyError", done.stderr)
        self.assertTrue(calls, "expected export requests")
        for call in calls:
            self.assertTrue(call["url"].startswith(f"https://{CLI_HOST}/v2/"), call)
            self.assertEqual(f"Bearer {FAKE_JWT}", call["auth"])
        self.assertTrue(out.exists())

    def test_export_png_explicit_base_url_wins(self):
        done, calls, _ = self.export_png(
            SIGMA_BASE_URL="https://api.sigmacomputing.com", SIGMA_API_TOKEN="caller-token")
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertTrue(all(c["url"].startswith("https://api.sigmacomputing.com/v2/") for c in calls))
        self.assertTrue(all(c["auth"] == "Bearer caller-token" for c in calls))
        self.assertFalse(self.cli_log.exists(), "the CLI must not be consulted")

    def test_export_png_caller_token_without_base_url_fails_clearly(self):
        done, calls, _ = self.export_png(SIGMA_API_TOKEN="caller-token")
        self.assertNotEqual(0, done.returncode)
        self.assertIn("SIGMA_BASE_URL not set", done.stderr)
        self.assertNotIn("Traceback", done.stderr)
        self.assertEqual([], calls)
        self.assertFalse(self.cli_log.exists())

    # --- migrate-sisense.py (regression guard) -----------------------------
    def test_migrate_sisense_load_sigma_env_resolves_cli_host(self):
        done = self.python(MIGRATE_DRIVER, SCRIPTS / "migrate-sisense.py")
        self.assertEqual(0, done.returncode, done.stderr)
        got = json.loads(done.stdout.strip().splitlines()[-1])
        self.assertEqual(f"https://{CLI_HOST}", got["base"])
        self.assertEqual(FAKE_JWT, got["token"])

    # --- post-sisense-spec.py (regression guard) ---------------------------
    def test_post_sisense_spec_client_resolves_cli_host(self):
        done = self.python(POST_DRIVER, SCRIPTS / "lib", SCRIPTS / "post-sisense-spec.py")
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertEqual(f"https://{CLI_HOST}",
                         json.loads(done.stdout.strip().splitlines()[-1])["base"])


if __name__ == "__main__":
    unittest.main()
