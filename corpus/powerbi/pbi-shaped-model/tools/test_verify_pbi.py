#!/usr/bin/env python3
"""Offline tests for verify_pbi.py's query builders and checks (no network, no Snowflake)."""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "src"))
import build_reports  # noqa: E402
import verify_pbi  # noqa: E402

OUT = tempfile.mkdtemp(prefix="pbi-verify-out-")
build_reports.build(OUT, "example-account.snowflakecomputing.com", "EXAMPLE_WH", "SAMPLE_DB")


def vis(report, page_id, name):
    with open(os.path.join(OUT, report, "definition", "pages", page_id, "visuals", name, "visual.json")) as f:
        return json.load(f)


class QueryTests(unittest.TestCase):
    def test_measure_visual_becomes_summarizecolumns_with_report_filter(self):
        with open(os.path.join(OUT, "retail-sales", "definition", "report.json")) as f:
            filters = verify_pbi.report_filters(json.load(f))
        dax, kind, n = verify_pbi.visual_query(vis("retail-sales", "OverviewPage", "OvByCategory"), filters)
        self.assertEqual((kind, n), ("measures", 1))
        self.assertIn("SUMMARIZECOLUMNS('Category'[Category Name]", dax)
        self.assertIn("NOT('Category'[Category Name] IN {\"Discontinued\"})", dax)
        self.assertIn("\"m0\", 'Sales'[Sales Amount]", dax)

    def test_slicer_query_is_distinct_values(self):
        dax, kind, n = verify_pbi.visual_query(vis("retail-sales", "SlicersPage", "SlBrand"), [])
        self.assertEqual((dax, kind, n), ("EVALUATE DISTINCT('Product'[Brand])", "slicer", 0))

    def test_saved_selection_is_read_from_the_page(self):
        page = [vis("retail-sales", "SlicersPage", n) for n in ("SlCustomerRegion", "SlBrand")]
        self.assertEqual(verify_pbi.saved_selections(page),
                         [{"table": "Customer", "column": "Customer Region", "mode": "include", "values": ["West"]}])

    def test_analyse_flags_empty_and_blank(self):
        self.assertFalse(verify_pbi.analyse([], 1, "measures")["ok"])
        self.assertFalse(verify_pbi.analyse([{"[m0]": None}], 1, "measures")["ok"])
        self.assertTrue(verify_pbi.analyse([{"[m0]": None}, {"[m0]": 3}], 1, "measures")["ok"])

    def test_truth_sql_has_no_database_name(self):
        for sql in verify_pbi.truth_sql("S").values():
            self.assertIn("{db}.S.", sql)


import base64  # noqa: E402
import fabric_publish  # noqa: E402
import refresh_pick  # noqa: E402


class RefreshPickTests(unittest.TestCase):
    OLD = {"status": "Completed", "startTime": "2026-11-16T08:00:00Z", "requestId": "old"}
    NEW = {"status": "Unknown", "startTime": "2026-11-16T09:00:05Z", "requestId": "new"}

    def test_stale_completed_is_ignored(self):
        self.assertEqual(refresh_pick.pick_refresh([self.OLD], "2026-11-16T09:00:00"), {})
        self.assertEqual(refresh_pick.pick_refresh([self.NEW, self.OLD], "2026-11-16T09:00:00"), self.NEW)
        self.assertEqual(refresh_pick.pick_refresh([self.OLD]), self.OLD)
        self.assertIs(verify_pbi.pick_refresh, refresh_pick.pick_refresh)
        self.assertIs(fabric_publish.pick_refresh, refresh_pick.pick_refresh)

    def test_request_id_wins_and_skew_applies_only_to_the_time_fallback(self):
        self.assertEqual(refresh_pick.pick_refresh([self.NEW, self.OLD], "2026-11-16T09:30:00", "old"), self.OLD)
        near = {"status": "Completed", "startTime": "2026-11-16T08:59:57Z"}  # 3 s before our request time
        self.assertEqual(refresh_pick.pick_refresh([near], "2026-11-16T09:00:00"), near)
        far = {"status": "Completed", "startTime": "2026-11-16T08:59:50Z"}  # 10 s before: stale
        self.assertEqual(refresh_pick.pick_refresh([far], "2026-11-16T09:00:00"), {})


class FakeResp:
    def __init__(self, body, status=200):
        self.status_code, self._b = status, body
        self.headers, self.text = {}, "x"

    def json(self):
        return self._b


class FakeRequests:
    """get() returns the next scripted refresh listing for the dataset in the URL."""

    def __init__(self, listings):
        self.listings = {k: list(v) for k, v in listings.items()}
        self.calls = 0

    def get(self, url, headers=None):
        self.calls += 1
        for ds, seq in self.listings.items():
            if f"/datasets/{ds}/" in url:
                return FakeResp({"value": seq.pop(0) if len(seq) > 1 else seq[0]})
        raise AssertionError(url)


class PollRefreshTests(unittest.TestCase):
    STALE = {"status": "Completed", "startTime": "2026-11-16T08:00:00Z", "requestId": "old"}
    SINCE = {"m": "2026-11-16T09:00:00"}

    def run_poll(self, listings, rids):
        fabric_publish.requests = FakeRequests(listings)
        try:
            return fabric_publish.poll_refreshes(lambda: "t", "w", {"m": "ds1"}, 60, self.SINCE, rids,
                                                 interval=0, sleep=lambda s: None)
        finally:
            fabric_publish.requests = None

    def test_accepts_only_our_refresh_once_it_completes(self):
        ours = {"requestId": "mine", "startTime": "2026-11-16T09:00:03Z"}
        r = self.run_poll({"ds1": [[self.STALE],                                   # only the stale one
                                   [dict(ours, status="Unknown"), self.STALE],     # ours running
                                   [dict(ours, status="Completed"), self.STALE]]},
                          {"m": "mine"})
        self.assertEqual(r["m"]["states"], ["Unknown", "Completed"])  # never the stale Completed
        self.assertEqual((r["m"]["final"], r["m"]["error"]), ("Completed", None))

    def test_our_failed_run_is_reported_failed(self):
        ours = {"requestId": "mine", "startTime": "2026-11-16T09:00:03Z", "status": "Failed",
                "serviceExceptionJson": "{\"errorCode\":\"boom\"}"}
        r = self.run_poll({"ds1": [[ours, self.STALE]]}, {"m": "mine"})
        self.assertEqual(r["m"]["final"], "Failed")
        self.assertIn("boom", r["m"]["error"])


class PublishTokenTests(unittest.TestCase):
    def test_workspace_and_model_id_are_substituted_after_a_build(self):
        d = tempfile.mkdtemp(prefix="pbi-pub-")
        build_reports.build(d, "example-account.snowflakecomputing.com", "EXAMPLE_WH", "SAMPLE_DB")
        parts = fabric_publish.parts_from_dir(os.path.join(d, "retail-sales"))
        fabric_publish.patch_report_parts(parts, "MODEL-X", "My Workspace")
        pbir = next(p for p in parts if p["path"] == "definition.pbir")
        conn = json.loads(base64.b64decode(pbir["payload"]))["datasetReference"]["byConnection"]["connectionString"]
        self.assertIn("myorg/My Workspace;", conn)
        self.assertIn("semanticmodelid=MODEL-X", conn)
        self.assertNotIn("{", conn)


if __name__ == "__main__":
    unittest.main()
