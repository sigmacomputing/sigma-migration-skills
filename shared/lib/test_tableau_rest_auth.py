#!/usr/bin/env python3
import os
import json
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

with mock.patch.dict(os.environ, {"TABLEAU_PAT_SECRET": "synthetic-secret"}):
    import tableau_rest


class TableauRefreshTest(unittest.TestCase):
    def test_malformed_signin_preserves_cached_credentials(self):
        env = {"TABLEAU_SERVER_URL": "https://tableau.example", "TABLEAU_PAT_NAME": "synthetic",
               "TABLEAU_PAT_SECRET": "synthetic-secret", "TABLEAU_SITE_CONTENT_URL": ""}
        with mock.patch.dict(os.environ, env, clear=True):
            tableau_rest._token_override = "prior-token"
            tableau_rest._site_id_override = "prior-site"
            for body in ({}, [], {"credentials": {"token": "new-token"}},
                         {"credentials": {"token": "", "site": {"id": "new-site"}}}):
                with self.subTest(body=body), mock.patch.object(
                    tableau_rest, "_send", return_value=tableau_rest._Resp(200, json.dumps(body))
                ), self.assertRaises(tableau_rest.TableauAuthError):
                    tableau_rest.refresh_token()
                self.assertEqual("prior-token", tableau_rest._token_override)
                self.assertEqual("prior-site", tableau_rest.site_id())

    def test_concurrent_signin_shares_success_or_failure(self):
        env = {"TABLEAU_SERVER_URL": "https://tableau.example", "TABLEAU_PAT_NAME": "synthetic",
               "TABLEAU_PAT_SECRET": "synthetic-secret", "TABLEAU_SITE_CONTENT_URL": ""}
        for failure in (None, tableau_rest.TableauAuthError("synthetic failure"), SystemExit("synthetic exit")):
            with self.subTest(failure=failure), mock.patch.dict(os.environ, env, clear=True):
                entered, release, completed = threading.Event(), threading.Event(), threading.Event()
                tableau_rest._token_override = "expired-token"
                tableau_rest._refresh_inflight = False

                def send(*_args):
                    entered.set()
                    if not release.wait(3):
                        raise RuntimeError("test release timed out")
                    if failure:
                        raise failure
                    return tableau_rest._Resp(200, b'{"credentials":{"token":"fresh-token","site":{"id":"site-new"}}}')

                def waiter():
                    try:
                        return tableau_rest.refresh_token()
                    finally:
                        completed.set()

                with mock.patch.object(tableau_rest, "_send", side_effect=send) as transport:
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        leader = pool.submit(tableau_rest.refresh_token)
                        self.assertTrue(entered.wait(3))
                        follower = pool.submit(waiter)
                        try:
                            self.assertFalse(completed.wait(0.1), "concurrent caller returned a stale token")
                        finally:
                            release.set()
                        for future in (leader, follower):
                            if failure:
                                with self.assertRaises(type(failure)):
                                    future.result(timeout=3)
                            else:
                                self.assertEqual("fresh-token", future.result(timeout=3))
                                self.assertEqual("site-new", tableau_rest.site_id())
                    self.assertEqual(1, transport.call_count)


class TableauExplicitProfileTest(unittest.TestCase):
    """The settings-file loader follows the Sigma REST clients' explicit-profile rule."""

    SETTINGS = (
        "export TABLEAU_PAT_NAME='pat'\n"
        "export SIGMA_BASE_URL='https://api.sigmacomputing.com'\n"
        "export SIGMA_CLIENT_ID='org-a-id'\n"
        "export SIGMA_CLIENT_SECRET='org-a-secret'\n"
        "export SIGMA_API_TOKEN='org-a-token'\n"
        "export SIGMA_AUTH_MODE='client-credentials'\n"
    )

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = os.path.join(tmp.name, "env")
        self.write(self.SETTINGS)
        patcher = mock.patch.object(tableau_rest, "NEUTRAL_ENV", self.path)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, body):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(body)

    def load(self, **env):
        values = dict(env)
        tableau_rest._load_neutral_env(values)
        return values

    def test_explicit_profile_skips_sigma_org_keys_but_loads_tableau_keys(self):
        loaded = self.load(SIGMA_CLI_PROFILE="work (1)")
        for key in ("SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET",
                    "SIGMA_API_TOKEN", "SIGMA_AUTH_MODE"):
            self.assertNotIn(key, loaded)
        self.assertEqual("pat", loaded["TABLEAU_PAT_NAME"])
        self.assertNotIn("SIGMA_CLI_PROFILE_FROM_FILE", loaded)

    def test_no_profile_loads_everything_as_before(self):
        loaded = self.load()
        self.assertEqual("org-a-id", loaded["SIGMA_CLIENT_ID"])
        self.assertEqual("https://api.sigmacomputing.com", loaded["SIGMA_BASE_URL"])

    def test_file_set_profile_is_marked_and_not_explicit(self):
        self.write(self.SETTINGS + "export SIGMA_CLI_PROFILE='from-file'\n")
        loaded = self.load()
        self.assertEqual("from-file", loaded["SIGMA_CLI_PROFILE"])
        self.assertEqual("from-file", loaded["SIGMA_CLI_PROFILE_FROM_FILE"])
        self.assertEqual("org-a-id", loaded["SIGMA_CLIENT_ID"])

    def test_explicit_profile_under_a_stale_marker_still_pins(self):
        loaded = self.load(SIGMA_CLI_PROFILE="work (1)", SIGMA_CLI_PROFILE_FROM_FILE="from-file")
        self.assertNotIn("SIGMA_CLIENT_ID", loaded)

    def test_sourced_file_only_profile_without_marker_is_not_explicit(self):
        self.write(self.SETTINGS + "export SIGMA_CLI_PROFILE='from-file'\n")
        loaded = self.load(SIGMA_CLI_PROFILE="from-file")
        self.assertEqual("org-a-id", loaded["SIGMA_CLIENT_ID"])
        loaded = self.load(SIGMA_CLI_PROFILE="work (1)")
        self.assertNotIn("SIGMA_CLIENT_ID", loaded)

    def test_profile_matching_the_marker_is_not_explicit(self):
        loaded = self.load(SIGMA_CLI_PROFILE="from-file", SIGMA_CLI_PROFILE_FROM_FILE="from-file")
        self.assertEqual("org-a-id", loaded["SIGMA_CLIENT_ID"])


if __name__ == "__main__":
    unittest.main()
