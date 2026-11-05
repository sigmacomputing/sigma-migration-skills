#!/usr/bin/env python3
import os
import json
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


if __name__ == "__main__":
    unittest.main()
