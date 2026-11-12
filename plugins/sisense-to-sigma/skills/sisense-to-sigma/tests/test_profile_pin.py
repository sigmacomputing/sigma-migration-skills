#!/usr/bin/env python3
"""An explicit SIGMA_CLI_PROFILE pins the org in migrate-sisense.py."""

import base64
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent / "scripts"



def _import_migrate():
    """Import migrate-sisense.py under a throwaway HOME, cwd and minimal env.

    The vendored sigma_rest loads the settings file and may read ./auth.json at
    import time; neither may see the caller's real HOME or working directory.
    """
    saved_cwd = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp) / "home"
        home.mkdir()
        try:
            os.chdir(tmp)
            with mock.patch.dict(
                    os.environ, {"HOME": str(home), "PATH": "/usr/bin:/bin"}, clear=True):
                spec = importlib.util.spec_from_file_location(
                    "migrate_sisense_profile_pin_test", SCRIPTS / "migrate-sisense.py")
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
        finally:
            os.chdir(saved_cwd)
    return module


migrate = _import_migrate()
sigma_rest = migrate.sigma_rest

PINNED = (
    "SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET",
    "SIGMA_API_TOKEN", "SIGMA_AUTH_MODE",
)
FILE_BASE = "https://org-a.example.com"
# The token provider refuses non-Sigma hosts, so the fake profile host must look real.
CLI_BASE = "https://aws-api.sigmacomputing.com"
SETTINGS = """\
export SIGMA_BASE_URL='https://org-a.example.com'
export SIGMA_CLIENT_ID='file-client-id'
export SIGMA_CLIENT_SECRET='file-client-secret'
export SIGMA_API_TOKEN='file-api-token'
export SIGMA_AUTH_MODE='client-credentials'
export SIGMA_CLI_PROFILE='file-profile'
export SISENSE_URL='https://sisense.example.com'
"""


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


FAKE_JWT = ".".join(
    b64url(part) for part in (b'{"alg":"none"}', b'{"sub":"test"}', b"signature"))

FAKE_SIGMA = r"""#!/bin/bash
if [ "$1" = auth ] && [ "$2" = --help ]; then echo "Commands: login token status"; exit 0; fi
if [ "$1" = auth ] && [ "$2" = status ]; then
  { echo "Profile:   fake"; echo "Base URL:  ${FAKE_SIGMA_BASE}"; echo "Auth:      OK (token acquired)"; } >&2
  exit 0
fi
if [ "$1" = auth ] && [ "$2" = token ]; then printf '%s\n' "${FAKE_SIGMA_TOKEN}"; exit 0; fi
exit 3
"""


# The real provider verifies the token against the live host (/v2/whoami). This
# wrapper runs the vendored provider unchanged except for that one network call.
PROVIDER_WRAPPER = """\
import importlib.util, sys
spec = importlib.util.spec_from_file_location("get_token", %r)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module._verify_token = lambda result: result
sys.exit(module.main(sys.argv[1:]))
"""


class ProfilePinTest(unittest.TestCase):
    @staticmethod
    def reset_auth():
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()

    def setUp(self):
        self.reset_auth()
        self.addCleanup(self.reset_auth)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = Path(self.tmp.name) / "home"
        (home / ".sigma-migration").mkdir(parents=True)
        self.settings = home / ".sigma-migration" / "env"
        self.settings.write_text(SETTINGS, encoding="utf-8")
        cwd = Path(self.tmp.name) / "cwd"
        cwd.mkdir()
        # Minimal, cleared env: no real key can reach an assertion or a child.
        patcher = mock.patch.dict(
            os.environ, {"HOME": str(home), "PATH": "/usr/bin:/bin"}, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        saved_cwd = os.getcwd()
        os.chdir(cwd)
        self.addCleanup(os.chdir, saved_cwd)
        saved_neutral = sigma_rest.NEUTRAL_ENV
        sigma_rest.NEUTRAL_ENV = str(self.settings)
        self.addCleanup(setattr, sigma_rest, "NEUTRAL_ENV", saved_neutral)

    def assert_pinned(self):
        # Never repr os.environ: a failure message would dump the environment.
        self.assertEqual([k for k in PINNED if k in os.environ], [])
        self.assertEqual(os.environ["SISENSE_URL"], "https://sisense.example.com")

    def assert_loaded(self):
        self.assertEqual(os.environ["SIGMA_BASE_URL"], FILE_BASE)
        self.assertEqual(os.environ["SIGMA_CLIENT_ID"], "file-client-id")
        self.assertEqual(os.environ["SIGMA_CLIENT_SECRET"], "file-client-secret")
        self.assertEqual(os.environ["SIGMA_API_TOKEN"], "file-api-token")
        self.assertEqual(os.environ["SIGMA_AUTH_MODE"], "client-credentials")
        self.assertEqual(os.environ["SISENSE_URL"], "https://sisense.example.com")

    def test_explicit_profile_skips_org_keys(self):
        os.environ["SIGMA_CLI_PROFILE"] = "work (1)"
        migrate.load_local_env()
        self.assert_pinned()
        self.assertEqual(os.environ["SIGMA_CLI_PROFILE"], "work (1)")
        self.assertFalse("SIGMA_CLI_PROFILE_FROM_FILE" in os.environ)

    def test_no_profile_loads_everything_and_marks_origin(self):
        migrate.load_local_env()
        self.assert_loaded()
        self.assertEqual(os.environ["SIGMA_CLI_PROFILE"], "file-profile")
        self.assertEqual(os.environ["SIGMA_CLI_PROFILE_FROM_FILE"], "file-profile")

    def test_profile_equal_to_file_profile_is_not_pinned(self):
        os.environ["SIGMA_CLI_PROFILE"] = "file-profile"
        migrate.load_local_env()
        self.assert_loaded()

    def test_profile_equal_to_from_file_marker_is_not_pinned(self):
        os.environ["SIGMA_CLI_PROFILE"] = "earlier-copy"
        os.environ["SIGMA_CLI_PROFILE_FROM_FILE"] = "earlier-copy"
        migrate.load_local_env()
        self.assert_loaded()

    def test_profile_comparison_is_case_sensitive(self):
        self.settings.write_text(
            SETTINGS.replace("file-profile", "work (1)"), encoding="utf-8")
        os.environ["SIGMA_CLI_PROFILE"] = "Work (1)"
        migrate.load_local_env()
        self.assert_pinned()

    def test_load_sigma_env_resolves_the_pinned_profile_org(self):
        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir()
        fake = bindir / "sigma"
        fake.write_text(FAKE_SIGMA, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        wrapper = Path(self.tmp.name) / "provider.py"
        wrapper.write_text(
            PROVIDER_WRAPPER % str(SCRIPTS / "get_token.py"), encoding="utf-8")
        os.environ["SIGMA_TOKEN_PROVIDER"] = str(wrapper)
        os.environ["PATH"] = str(bindir) + os.pathsep + "/usr/bin:/bin"
        os.environ["FAKE_SIGMA_BASE"] = CLI_BASE
        os.environ["FAKE_SIGMA_TOKEN"] = FAKE_JWT
        os.environ["SIGMA_CLI_PROFILE"] = "work (1)"
        os.environ["SIGMA_AUTH_MODE"] = "sigma-cli"
        workdir = Path(self.tmp.name) / "work"
        workdir.mkdir()
        migrate.load_sigma_env(workdir)
        self.assertEqual(os.environ["SIGMA_BASE_URL"], CLI_BASE)
        self.assertEqual(os.environ["SIGMA_API_TOKEN"], FAKE_JWT)
        self.assertNotEqual(os.environ["SIGMA_BASE_URL"], FILE_BASE)


if __name__ == "__main__":
    unittest.main()
