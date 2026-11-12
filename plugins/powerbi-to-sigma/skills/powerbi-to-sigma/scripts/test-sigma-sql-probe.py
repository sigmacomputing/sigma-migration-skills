#!/usr/bin/env python3
"""Offline tests for sigma-sql-probe.py (SQL through a Sigma connection via a
scratch workbook + export API). A fake Sigma HTTP layer stands in for the
service: no network, no credentials.

Run: python3 scripts/test-sigma-sql-probe.py   (exit 0 = pass)
"""
import csv
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


probe = load("sigma_sql_probe", "sigma-sql-probe.py")

TABLES = {
    "orders": {
        "cols": [("ORDER_ID", "NUMBER(38,0)[SB8]"), ("STATUS", "VARCHAR(16777216)[LOB]"),
                 ("FLAG", "VARCHAR(16)[LOB]")],
        "rows": [{"ORDER_ID": 1, "STATUS": "OPEN", "FLAG": "True"},
                 {"ORDER_ID": 2, "STATUS": None, "FLAG": "False"}],
    },
    "customers": {
        "cols": [("CUSTOMER_ID", "NUMBER(38,0)[SB8]"), ("NAME", "VARCHAR(100)[LOB]")],
        "rows": [{"CUSTOMER_ID": 7, "NAME": "Acme"}],
    },
    "empty_t": {"cols": [("K", "NUMBER(38,0)[SB8]")], "rows": []},
}


def warehouse(stmt):
    """Interpret the probe's wrapper statements against TABLES."""
    name = next((t for t in TABLES if t in stmt), None)
    if name is None:
        raise RuntimeError("table not found")
    t = TABLES[name]
    if "SYSTEM$TYPEOF" in stmt or "typeof(" in stmt:
        return [{c: ty for c, ty in t["cols"]}]
    if probe.PROBE_ROW_KEY in stmt:  # columns mode (LEFT JOIN, LIMIT 1)
        row = t["rows"][0] if t["rows"] else {c: None for c, _ in t["cols"]}
        return [dict([(probe.PROBE_ROW_KEY, 1)] + list(row.items()))]
    return list(t["rows"])


class FakeSigma:
    """Fake HTTP layer. api() has the (method, path, body, raw) -> (status, payload) contract."""

    def __init__(self, wh=warehouse, pending=0):
        self.wh = wh
        self.lock = threading.Lock()
        self.calls = []
        self.workbook = None
        self.elements = {}
        self.queries = {}
        self.qn = 0
        self.pending = pending
        self.write_failures = []     # statuses returned before a write is accepted
        self.export_failures = []    # statuses returned before an export is accepted
        self.writes = 0
        self.bad_marker = "BADSQL"
        self.delete_status = None          # force a DELETE /v2/files status (e.g. 403)
        self.fail_first_download = False   # the first export's query always fails with 500 "Export failed"
        self.dead_qid = None
        self.active = 0
        self.max_active = 0
        self.created = {}                  # workbook id -> name (every POST /v2/workbooks that landed)
        self.create_lost_response = []     # statuses answered AFTER the create succeeded server-side
        self.list_status = 200

    def api(self, method, path, body=None, raw=False):
        with self.lock:
            self.calls.append((method, path))
            if method in ("POST", "PUT") and path.endswith("/export"):
                if self.export_failures:
                    return self.export_failures.pop(0), "gateway timeout"
                self.qn += 1
                qid = "qid%d" % self.qn
                self.queries[qid] = {"el": body["elementId"], "polls": 0}
                if self.fail_first_download and self.dead_qid is None:
                    self.dead_qid = qid
                return 200, {"queryId": qid}
            if method == "POST" and path == "/v2/workbooks":
                st, payload = self._write(body, create=True)
                if 200 <= st < 300:
                    wid = "wb-%d" % (len(self.created) + 1)
                    self.created[wid] = body["name"]
                    self.workbook = wid
                    payload = {"workbookId": wid}
                    if self.create_lost_response:
                        return self.create_lost_response.pop(0), "gateway timeout"
                return st, payload
            if method == "GET" and path.startswith("/v2/files"):
                if self.list_status != 200:
                    return self.list_status, {"message": "nope"}
                ents = [{"id": "other-%d" % k, "name": n, "type": "workbook"} for k, n in enumerate(getattr(self, "list_filler", []))]
                ents += [{"id": i, "name": n, "type": "workbook"} for i, n in self.created.items()]
                size = getattr(self, "list_page_size", None)
                if not size:
                    return 200, {"entries": ents}
                # the live shape: {entries, total, nextPage} - no hasMore field
                import urllib.parse as _up
                pg = int((_up.parse_qs(_up.urlparse(path).query).get("page") or ["0"])[0])
                chunk = ents[pg * size:(pg + 1) * size]
                nxt = str(pg + 1) if (pg + 1) * size < len(ents) else None
                out = {"entries": chunk, "total": len(ents)}
                if nxt:
                    out["nextPage"] = nxt
                return 200, out
            if method == "PUT" and path.startswith("/v2/workbooks/") and path.endswith("/contents"):
                if path.split("/")[3] != self.workbook:
                    return 404, {"message": "no such workbook"}
                return self._write(body, create=False)
            if method == "DELETE" and path.startswith("/v2/workbooks/"):
                return 404, {"message": "not a delete route"}  # the real delete route is /v2/files/{id}
            if method == "DELETE" and path.startswith("/v2/files/"):
                if self.delete_status:
                    return self.delete_status, {"message": "nope"}
                wid = path.split("/")[3]
                if wid not in self.created and wid != self.workbook:
                    return 404, {"message": "no such file"}
                self.created.pop(wid, None)
                if wid == self.workbook:
                    self.workbook = None
                return 204, ""
            if method == "GET" and path.startswith("/v2/query/") and path.endswith("/download"):
                if path.split("/")[3] == self.dead_qid:
                    return 500, b"Export failed"
                q = self.queries[path.split("/")[3]]
                q["polls"] += 1
                if q["polls"] <= self.pending:
                    return 202, b""
                stmt = self.elements[q["el"]]
                try:
                    rows = self.wh(stmt)
                except Exception as e:  # warehouse error surfaces on download
                    return 400, ("query failed: %s" % e).encode()
                out = io.StringIO()
                w = csv.writer(out)
                w.writerow(["J"])
                for r in rows:
                    w.writerow([json.dumps(r)])
                return 200, out.getvalue().encode()
            return 404, {"message": "unrouted %s %s" % (method, path)}

    def _write(self, body, create):
        self.writes += 1
        if self.write_failures:
            return self.write_failures.pop(0), {"message": "transient"}
        els = body["contents"]["elements"]
        for e in els:
            if self.bad_marker in e["source"]["statement"]:
                return 400, {"message": "Invalid SQL near %s" % self.bad_marker}
        self.elements = {e["id"]: e["source"]["statement"] for e in els}
        if create:
            self.workbook = "wb-1"
            assert body["folderId"] == "folder-1"
            return 200, {"workbookId": "wb-1"}
        return 200, {}


def make_probe(fake, state_path=None, **kw):
    return probe.Probe(fake.api, connection_id="conn-1", folder_id="folder-1",
                       state_path=state_path, sleep=lambda s: None, log=lambda m: None, **kw)


class StatementTests(unittest.TestCase):
    def test_clean_statement_strips_semicolons_and_whitespace(self):
        self.assertEqual("SELECT 1", probe.clean_statement("  SELECT 1 ;\n; "))

    def test_snowflake_rows_wrapper(self):
        s = probe.rows_statement("SELECT * FROM orders", "snowflake")
        self.assertIn("OBJECT_CONSTRUCT_KEEP_NULL(*)", s)
        self.assertTrue(s.rstrip().endswith(")"))
        self.assertIn("\nSELECT * FROM orders\n", s)  # newline guards a trailing line comment

    def test_trailing_line_comment_cannot_swallow_closing_paren(self):
        s = probe.rows_statement("SELECT 1 -- note", "snowflake")
        self.assertIn("SELECT 1 -- note\n)", s)

    def test_databricks_keeps_null_fields(self):
        s = probe.rows_statement("SELECT * FROM orders", "databricks")
        self.assertIn("to_json(struct(*)", s)
        self.assertIn("ignoreNullFields", s)

    def test_bigquery_to_json_string(self):
        s = probe.rows_statement("SELECT * FROM orders", "bigquery")
        self.assertIn("TO_JSON_STRING", s)

    def test_columns_statement_limit_one_and_survives_empty_result(self):
        s = probe.columns_statement("SELECT * FROM orders", "snowflake")
        self.assertIn("LIMIT 1", s)
        self.assertIn("LEFT JOIN", s)  # a zero-row query must still report its columns
        self.assertIn(probe.PROBE_ROW_KEY, s)

    def test_types_statement_snowflake_quotes_each_column(self):
        s = probe.types_statement("SELECT * FROM orders", ["ORDER_ID", 'we"ird'], "snowflake")
        self.assertIn('SYSTEM$TYPEOF(b."ORDER_ID") AS "ORDER_ID"', s)
        self.assertIn('SYSTEM$TYPEOF(b."we""ird") AS "we""ird"', s)

    def test_types_statement_databricks_uses_typeof(self):
        s = probe.types_statement("SELECT * FROM orders", ["A"], "databricks")
        self.assertIn("typeof(b.`A`) AS `A`", s)

    def test_types_unsupported_on_bigquery(self):
        with self.assertRaises(probe.ProbeError):
            probe.types_statement("SELECT 1", ["A"], "bigquery")


class RunTests(unittest.TestCase):
    def test_rows_mode_roundtrip(self):
        fake = FakeSigma()
        res = make_probe(fake).run({"o": "SELECT * FROM orders"})
        self.assertTrue(res["o"]["ok"])
        self.assertEqual(TABLES["orders"]["rows"], res["o"]["rows"])
        self.assertEqual(2, res["o"]["row_count"])
        # created the scratch workbook in the requested folder, then exported
        self.assertEqual(("POST", "/v2/workbooks"), fake.calls[0])
        self.assertTrue(any(c[1].endswith("/export") for c in fake.calls))

    def test_sql_element_uses_connection_and_single_json_column(self):
        fake = FakeSigma()
        captured = {}
        orig = fake.api

        def spy(method, path, body=None, raw=False):
            if method == "POST" and path == "/v2/workbooks":
                captured["body"] = body
            return orig(method, path, body, raw)

        probe.Probe(spy, connection_id="conn-1", folder_id="folder-1", sleep=lambda s: None,
                    log=lambda m: None).run({"o": "SELECT * FROM orders"})
        el = captured["body"]["contents"]["elements"][0]
        self.assertEqual("conn-1", el["source"]["connectionId"])
        self.assertEqual("sql", el["source"]["kind"])
        self.assertEqual(1, len(el["columns"]))
        self.assertIn("<Element elementId=", captured["body"]["contents"]["layout"])

    def test_batching_reuses_workbook(self):
        fake = FakeSigma()
        qs = {"q%d" % i: "SELECT * FROM orders" for i in range(7)}
        res = make_probe(fake, batch=3).run(qs)
        self.assertTrue(all(r["ok"] for r in res.values()))
        writes = [c for c in fake.calls if c[0] in ("POST", "PUT") and not c[1].endswith("/export")]
        self.assertEqual(3, len(writes))
        self.assertEqual(1, sum(1 for c in writes if c == ("POST", "/v2/workbooks")))

    def test_bisect_isolates_bad_statement_and_surfaces_sigma_error(self):
        fake = FakeSigma()
        qs = {"a": "SELECT * FROM orders", "b": "SELECT BADSQL FROM orders",
              "c": "SELECT * FROM customers", "d": "SELECT * FROM orders"}
        res = make_probe(fake, batch=4).run(qs)
        self.assertFalse(res["b"]["ok"])
        self.assertIn("Invalid SQL near BADSQL", res["b"]["error"])
        self.assertEqual("write-rejected", res["b"]["kind"])
        for k in "acd":
            self.assertTrue(res[k]["ok"], k)
        # 4 -> (2,2) -> (1,1) on the failing half: far fewer writes than one-per-statement retries
        self.assertLessEqual(fake.writes, 7)

    def test_retries_transient_write_and_export_errors(self):
        fake = FakeSigma()
        fake.write_failures = [503, 524]
        fake.export_failures = [524, 502]
        res = make_probe(fake).run({"o": "SELECT * FROM orders"})
        self.assertTrue(res["o"]["ok"], res)

    def test_gives_up_after_retries_and_reports_status(self):
        fake = FakeSigma()
        fake.write_failures = [503] * 20
        res = make_probe(fake, retries=2).run({"o": "SELECT * FROM orders"})
        self.assertFalse(res["o"]["ok"])
        self.assertIn("503", res["o"]["error"])

    def test_polls_until_ready(self):
        fake = FakeSigma(pending=3)
        res = make_probe(fake).run({"o": "SELECT * FROM customers"})
        self.assertTrue(res["o"]["ok"])

    def test_warehouse_error_is_reported_per_key(self):
        fake = FakeSigma()
        res = make_probe(fake).run({"ok": "SELECT * FROM orders", "bad": "SELECT * FROM nowhere"})
        self.assertTrue(res["ok"]["ok"])
        self.assertFalse(res["bad"]["ok"])
        self.assertIn("table not found", res["bad"]["error"])

    def test_columns_mode_keys_are_output_names_and_marker_dropped(self):
        fake = FakeSigma()
        res = make_probe(fake).run({"o": "SELECT * FROM orders"}, mode="columns")
        self.assertEqual(["ORDER_ID", "STATUS", "FLAG"], res["o"]["columns"])

    def test_columns_mode_zero_row_table_still_names_columns(self):
        fake = FakeSigma()
        res = make_probe(fake).run({"e": "SELECT * FROM empty_t"}, mode="columns")
        self.assertEqual(["K"], res["e"]["columns"])

    def test_types_mode_two_passes(self):
        fake = FakeSigma()
        res = make_probe(fake).run({"o": "SELECT * FROM orders"}, mode="types")
        self.assertTrue(res["o"]["ok"], res)
        self.assertEqual(["ORDER_ID", "STATUS", "FLAG"], res["o"]["columns"])
        self.assertEqual("VARCHAR(16)[LOB]", res["o"]["types"]["FLAG"])
        self.assertEqual("NUMBER(38,0)[SB8]", res["o"]["types"]["ORDER_ID"])

    def test_types_mode_failed_columns_pass_is_reported(self):
        fake = FakeSigma()
        res = make_probe(fake).run({"bad": "SELECT * FROM nowhere"}, mode="types")
        self.assertFalse(res["bad"]["ok"])


class ResumeTests(unittest.TestCase):
    def test_second_run_is_fully_cached(self):
        with tempfile.TemporaryDirectory() as d:
            sp = os.path.join(d, "state.json")
            fake = FakeSigma()
            qs = {"a": "SELECT * FROM orders", "b": "SELECT * FROM customers"}
            make_probe(fake, state_path=sp).run(qs)
            n = len(fake.calls)
            fake2 = FakeSigma()
            res = make_probe(fake2, state_path=sp).run(qs)
            self.assertEqual([], fake2.calls)
            self.assertTrue(res["a"]["ok"] and res["b"]["ok"])
            self.assertGreater(n, 0)
            self.assertEqual(0o600, os.stat(sp).st_mode & 0o777)

    def test_failed_keys_rerun_and_changed_sql_reruns_on_existing_workbook(self):
        with tempfile.TemporaryDirectory() as d:
            sp = os.path.join(d, "state.json")
            fake = FakeSigma()
            make_probe(fake, state_path=sp).run({"a": "SELECT * FROM orders", "b": "SELECT BADSQL"})
            fake.bad_marker = "NEVER"
            fake.calls.clear()
            res = make_probe(fake, state_path=sp).run(
                {"a": "SELECT * FROM orders", "b": "SELECT * FROM customers"})
            self.assertTrue(res["b"]["ok"])
            posts = [c for c in fake.calls if c == ("POST", "/v2/workbooks")]
            self.assertEqual(0, len(posts))  # the resumed run PUTs into the saved workbook
            self.assertTrue(any(c[0] == "PUT" for c in fake.calls))

    def test_deleted_workbook_is_recreated(self):
        with tempfile.TemporaryDirectory() as d:
            sp = os.path.join(d, "state.json")
            fake = FakeSigma()
            make_probe(fake, state_path=sp).run({"a": "SELECT * FROM orders"})
            fake.workbook = None  # someone deleted the scratch workbook
            res = make_probe(fake, state_path=sp).run({"z": "SELECT * FROM customers"})
            self.assertTrue(res["z"]["ok"])

    def test_force_reruns_cached(self):
        with tempfile.TemporaryDirectory() as d:
            sp = os.path.join(d, "state.json")
            fake = FakeSigma()
            qs = {"a": "SELECT * FROM orders"}
            make_probe(fake, state_path=sp).run(qs)
            fake.calls.clear()
            make_probe(fake, state_path=sp).run(qs, force=True)
            self.assertTrue(fake.calls)

    def test_cleanup_deletes_only_a_workbook_the_probe_created(self):
        with tempfile.TemporaryDirectory() as d:
            sp = os.path.join(d, "state.json")
            fake = FakeSigma()
            p = make_probe(fake, state_path=sp)
            p.run({"a": "SELECT * FROM orders"})
            self.assertTrue(p.cleanup())
            self.assertIn(("DELETE", "/v2/files/wb-1"), fake.calls)
            self.assertNotIn(("DELETE", "/v2/workbooks/wb-1"), fake.calls)
            self.assertIsNone(fake.workbook)

    def test_cleanup_404_means_already_gone(self):
        with tempfile.TemporaryDirectory() as d:
            fake = FakeSigma()
            p = make_probe(fake, state_path=os.path.join(d, "s.json"))
            p.run({"a": "SELECT * FROM orders"})
            fake.workbook = None  # deleted behind our back
            self.assertTrue(p.cleanup())
            self.assertIsNone(p.state["workbookId"])

    def test_cleanup_reports_a_failed_delete_and_keeps_the_id(self):
        with tempfile.TemporaryDirectory() as d:
            fake = FakeSigma()
            logs = []
            p = probe.Probe(fake.api, connection_id="conn-1", folder_id="folder-1",
                            state_path=os.path.join(d, "s.json"), sleep=lambda s: None, log=logs.append)
            p.run({"a": "SELECT * FROM orders"})
            fake.delete_status = 403
            self.assertFalse(p.cleanup())
            self.assertEqual("wb-1", p.state["workbookId"])  # still findable
            self.assertTrue(any("403" in m for m in logs), logs)


class ConcurrencyCacheRetryTests(unittest.TestCase):
    QS = {"a": "SELECT * FROM orders", "b": "SELECT * FROM customers", "c": "SELECT * FROM empty_t",
          "d": "SELECT * FROM orders WHERE 1=1", "e": "SELECT * FROM customers WHERE 1=1",
          "f": "SELECT * FROM orders -- f", "g": "SELECT * FROM customers -- g"}

    def test_single_workbook_write_and_results_match_the_serial_path(self):
        serial_fake = FakeSigma()
        serial = make_probe(serial_fake, workers=1, batch=1).run(self.QS, mode="types")
        fake = FakeSigma()
        res = make_probe(fake, workers=6, batch=10 ** 6).run(self.QS, mode="types")
        self.assertEqual(serial, res)
        self.assertEqual(2, fake.writes)  # columns pass + type pass: ALL statements in ONE write each
        self.assertGreater(serial_fake.writes, 4)
        fake2 = FakeSigma()
        make_probe(fake2, workers=6, batch=10 ** 6).run(self.QS, mode="columns")
        self.assertEqual(1, fake2.writes)

    def test_one_failing_statement_does_not_abort_the_others(self):
        qs = dict(self.QS, bad="SELECT * FROM nowhere")
        res = make_probe(FakeSigma(), workers=6, batch=10 ** 6).run(qs, mode="columns")
        self.assertFalse(res["bad"]["ok"])
        self.assertTrue(all(res[k]["ok"] for k in self.QS))

    def test_an_exception_in_one_export_is_isolated(self):
        fake = FakeSigma()
        p = make_probe(fake, workers=4, batch=10 ** 6)
        real = p._export
        def boom(eid):
            if eid == "q1":
                raise RuntimeError("kaput")
            return real(eid)
        p._export = boom
        res = p.run({"a": "SELECT * FROM orders", "b": "SELECT * FROM customers"}, mode="columns")
        self.assertTrue(res["a"]["ok"])
        self.assertFalse(res["b"]["ok"])
        self.assertIn("kaput", res["b"]["error"])

    def test_state_hits_backfill_the_file_cache(self):
        # A run that resumes from the state file (no file cache yet, e.g. the first run
        # after an upgrade) must still leave every ok result in the file cache. The
        # scratch workbook (and so the state) is deleted after each orchestrated run,
        # so the NEXT run only has the file cache to go on.
        with tempfile.TemporaryDirectory() as d:
            sp = os.path.join(d, "state.json")
            cp = os.path.join(d, "cache.json")
            qs = {"a": "SELECT * FROM orders", "b": "SELECT * FROM customers"}
            make_probe(FakeSigma(), state_path=sp).run(qs, mode="types")  # state only, no cache file
            p2 = make_probe(FakeSigma(), state_path=sp, cache_path=cp)
            p2.run(qs, mode="types")
            p3 = make_probe(FakeSigma(), cache_path=cp)  # state gone: file cache alone
            p3.run(qs, mode="types")
            self.assertEqual({"cached": 2, "probed": 0}, p3.stats)

    def test_cache_hit_miss_and_invalidate_on_sql_change(self):
        with tempfile.TemporaryDirectory() as d:
            cp = os.path.join(d, "cache.json")
            qs = {"a": "SELECT * FROM orders", "b": "SELECT * FROM customers"}
            f1 = FakeSigma()
            p1 = make_probe(f1, cache_path=cp)
            r1 = p1.run(qs, mode="types")
            self.assertEqual({"cached": 0, "probed": 2}, p1.stats)
            self.assertEqual(0o600, os.stat(cp).st_mode & 0o777)
            f2 = FakeSigma()  # a new run, new scratch workbook, no state file
            p2 = make_probe(f2, cache_path=cp)
            self.assertEqual(r1, p2.run(qs, mode="types"))
            self.assertEqual({"cached": 2, "probed": 0}, p2.stats)
            self.assertEqual(0, f2.writes)
            f3 = FakeSigma()
            p3 = make_probe(f3, cache_path=cp)
            p3.run(dict(qs, a="SELECT * FROM orders WHERE 1=1"), mode="types")
            self.assertEqual({"cached": 1, "probed": 1}, p3.stats)  # only the changed statement
            p4 = make_probe(FakeSigma(), cache_path=cp, use_cache=False)
            p4.run(qs, mode="types")
            self.assertEqual({"cached": 0, "probed": 2}, p4.stats)  # --probe-no-cache
            p5 = make_probe(FakeSigma(), cache_path=cp, dialect="databricks")
            p5.run(qs, mode="types")
            self.assertEqual(0, p5.stats["cached"])  # the dialect is part of the key
            p6 = probe.Probe(FakeSigma().api, connection_id="conn-2", folder_id="folder-1", cache_path=cp,
                             sleep=lambda s: None, log=lambda m: None)
            p6.run(qs, mode="types")
            self.assertEqual(0, p6.stats["cached"])  # so is the connection

    def test_failed_results_are_not_cached(self):
        with tempfile.TemporaryDirectory() as d:
            cp = os.path.join(d, "cache.json")
            p = make_probe(FakeSigma(), cache_path=cp)
            p.run({"bad": "SELECT * FROM nowhere"}, mode="columns")
            p2 = make_probe(FakeSigma(), cache_path=cp)
            p2.run({"bad": "SELECT * FROM nowhere"}, mode="columns")
            self.assertEqual(0, p2.stats["cached"])

    def test_transient_export_failure_is_retried_once_then_succeeds(self):
        fake = FakeSigma()
        fake.fail_first_download = True
        res = make_probe(fake, workers=1).run({"a": "SELECT * FROM orders"}, mode="rows")
        self.assertTrue(res["a"]["ok"], res)
        self.assertEqual(2, fake.qn)  # the export was re-issued once

    def test_a_persistent_export_failure_is_recorded_not_retried_forever(self):
        fake = FakeSigma()
        orig = fake.api
        def always_500(method, path, body=None, raw=False):
            if method == "GET" and path.endswith("/download"):
                return 500, b"Export failed"
            return orig(method, path, body, raw)
        p = probe.Probe(always_500, connection_id="conn-1", folder_id="folder-1", sleep=lambda s: None, log=lambda m: None)
        res = p.run({"a": "SELECT * FROM orders"}, mode="rows")
        self.assertFalse(res["a"]["ok"])
        self.assertIn("500", res["a"]["error"])
        self.assertEqual(2, fake.qn)  # exactly one re-export


class CacheAgeTests(unittest.TestCase):
    """pipeline-2 / whole-10: cached results expire; legacy cache files stay readable."""

    def test_entries_older_than_max_age_are_reprobed(self):
        with tempfile.TemporaryDirectory() as d:
            cp = os.path.join(d, "cache.json")
            qs = {"a": "SELECT * FROM orders"}
            clock = [1000000.0]
            now = lambda: clock[0]
            make_probe(FakeSigma(), cache_path=cp, now=now).run(qs, mode="columns")
            clock[0] += 23 * 3600
            p2 = make_probe(FakeSigma(), cache_path=cp, now=now)
            p2.run(qs, mode="columns")
            self.assertEqual({"cached": 1, "probed": 0}, p2.stats)
            clock[0] += 2 * 3600  # 25h old
            p3 = make_probe(FakeSigma(), cache_path=cp, now=now)
            p3.run(qs, mode="columns")
            self.assertEqual({"cached": 0, "probed": 1}, p3.stats)
            # the re-probe refreshed the timestamp
            p4 = make_probe(FakeSigma(), cache_path=cp, now=now)
            p4.run(qs, mode="columns")
            self.assertEqual({"cached": 1, "probed": 0}, p4.stats)

    def test_max_age_is_configurable_and_zero_disables_reuse(self):
        with tempfile.TemporaryDirectory() as d:
            cp = os.path.join(d, "cache.json")
            qs = {"a": "SELECT * FROM orders"}
            clock = [5000000.0]
            now = lambda: clock[0]
            make_probe(FakeSigma(), cache_path=cp, now=now).run(qs, mode="columns")
            clock[0] += 3600
            p = make_probe(FakeSigma(), cache_path=cp, now=now, cache_max_age_hours=0.5)
            p.run(qs, mode="columns")
            self.assertEqual(1, p.stats["probed"])

    def test_legacy_cache_without_timestamps_is_readable(self):
        with tempfile.TemporaryDirectory() as d:
            cp = os.path.join(d, "cache.json")
            qs = {"a": "SELECT * FROM orders"}
            make_probe(FakeSigma(), cache_path=cp).run(qs, mode="columns")
            with open(cp) as fh:
                doc = json.load(fh)
            doc.pop("times", None)  # the pre-timestamp file format
            for v in doc["entries"].values():
                if isinstance(v, dict):
                    v.pop("cached_at", None)
            with open(cp, "w") as fh:
                json.dump(doc, fh)
            p = make_probe(FakeSigma(), cache_path=cp)  # fresh file mtime: still within 24h
            res = p.run(qs, mode="columns")
            self.assertTrue(res["a"]["ok"])
            self.assertEqual({"cached": 1, "probed": 0}, p.stats)
            old = os.stat(cp).st_mtime - 3 * 86400
            os.utime(cp, (old, old))  # an old legacy file expires by its mtime
            p2 = make_probe(FakeSigma(), cache_path=cp)
            p2.run(qs, mode="columns")
            self.assertEqual(1, p2.stats["probed"])

    def test_cli_max_age_flag_is_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            rc = probe.main(["--sql", "SELECT * FROM orders", "--columns", "--out", os.path.join(d, "r.json"),
                             "--connection-id", "conn-1", "--folder-id", "folder-1", "--state", os.path.join(d, "s.json"),
                             "--cache", os.path.join(d, "c.json"), "--cache-max-age-hours", "1"],
                            api=FakeSigma().api, sleep=lambda s: None)
            self.assertEqual(0, rc)


class CreateIdempotencyTests(unittest.TestCase):
    """pipeline-6: POST /v2/workbooks is not idempotent; never leak a duplicate."""

    def test_lost_create_response_is_found_by_name_not_recreated(self):
        fake = FakeSigma()
        fake.create_lost_response = [524]
        p = make_probe(fake)
        res = p.run({"a": "SELECT * FROM orders"}, mode="columns")
        self.assertTrue(res["a"]["ok"], res)
        self.assertEqual(1, len(fake.created), "the retry must not create a second scratch workbook")
        self.assertEqual(1, [c for c in fake.calls if c[0] == "POST" and c[1] == "/v2/workbooks"].__len__())
        self.assertTrue(p.cleanup())
        self.assertEqual({}, fake.created, "the scratch workbook must be deleted")

    def test_lost_create_found_on_a_later_listing_page(self):
        # GET /v2/files pages with nextPage only (no hasMore): the lookup must follow it.
        fake = FakeSigma()
        fake.list_filler = ["unrelated one", "unrelated two", "unrelated three"]
        fake.list_page_size = 2
        fake.create_lost_response = [524]
        p = make_probe(fake)
        res = p.run({"a": "SELECT * FROM orders"}, mode="columns")
        self.assertTrue(res["a"]["ok"], res)
        self.assertEqual(1, len(fake.created), "the workbook on page 2 must be adopted, not re-created")
        self.assertTrue(p.cleanup())
        self.assertEqual({}, fake.created)

    def test_create_that_never_landed_is_retried(self):
        fake = FakeSigma()
        fake.write_failures = [503]
        p = make_probe(fake)
        res = p.run({"a": "SELECT * FROM orders"}, mode="columns")
        self.assertTrue(res["a"]["ok"], res)
        self.assertEqual(1, len(fake.created))
        p.cleanup()
        self.assertEqual({}, fake.created)

    def test_failed_lookup_does_not_blindly_recreate_and_cleanup_still_finds_it(self):
        fake = FakeSigma()
        fake.create_lost_response = [599, 599, 599, 599]
        fake.list_status = 500
        p = make_probe(fake)
        res = p.run({"a": "SELECT * FROM orders"}, mode="columns")
        self.assertFalse(res["a"]["ok"])
        self.assertEqual(1, len(fake.created), "an unverifiable create must not be repeated")
        fake.list_status = 200
        p.cleanup()
        self.assertEqual({}, fake.created, "cleanup looks the scratch workbook up by its unique name")


class BigQueryZeroRowTests(unittest.TestCase):
    def test_empty_bigquery_result_is_flagged_unverified(self):
        r = probe._shape_columns({"ok": True, "rows": []})
        self.assertTrue(r["ok"])
        self.assertEqual([], r["columns"])
        self.assertTrue(r.get("unverified"))
        self.assertIn("note", r)


class HttpAdapterTests(unittest.TestCase):
    """The production adapter over sigma_rest: auth via the shared client, never printed."""

    def setUp(self):
        import sigma_rest
        self.sr = sigma_rest
        self.sent = []
        self._orig = (sigma_rest._send, sigma_rest.auth_token, sigma_rest.base_url)
        sigma_rest._send = self._send
        sigma_rest.auth_token = lambda: "SECRET-TOKEN-123"
        sigma_rest.base_url = lambda: "https://api.example.sigmacomputing.com"
        self.responses = []

    def tearDown(self):
        self.sr._send, self.sr.auth_token, self.sr.base_url = self._orig

    def _send(self, method, url, headers, body, timeout):
        self.sent.append((method, url, dict(headers), body))
        status, payload = self.responses.pop(0)
        return self.sr._Resp(status, payload)

    def test_json_success_and_bearer_header(self):
        self.responses = [(200, b'{"workbookId": "w"}')]
        st, body = probe.SigmaHttp().call("POST", "/v2/workbooks", {"a": 1})
        self.assertEqual((200, {"workbookId": "w"}), (st, body))
        self.assertEqual("Bearer SECRET-TOKEN-123", self.sent[0][2]["Authorization"])
        self.assertEqual({"a": 1}, json.loads(self.sent[0][3]))

    def test_error_status_is_returned_not_raised_and_has_no_token(self):
        self.responses = [(400, b'{"message": "bad sql"}')]
        st, body = probe.SigmaHttp().call("PUT", "/v2/workbooks/x/contents", {"a": 1})
        self.assertEqual(400, st)
        self.assertNotIn("SECRET-TOKEN-123", json.dumps(body))

    def test_raw_download_preserves_202_vs_200(self):
        self.responses = [(202, b""), (200, b"J\n{}\n")]
        h = probe.SigmaHttp()
        self.assertEqual(202, h.call("GET", "/v2/query/q/download", raw=True)[0])
        st, data = h.call("GET", "/v2/query/q/download", raw=True)
        self.assertEqual((200, b"J\n{}\n"), (st, data))

    def test_401_refreshes_once_and_retries(self):
        refreshed = []
        orig = self.sr.refresh_token
        self.sr.refresh_token = lambda: refreshed.append(1) or "NEW"
        try:
            self.responses = [(401, b"expired"), (200, b"{}")]
            st, _ = probe.SigmaHttp().call("GET", "/v2/whoami")
            self.assertEqual(200, st)
            self.assertEqual([1], refreshed)
        finally:
            self.sr.refresh_token = orig

    def test_transport_exception_maps_to_599(self):
        def boom(method, url, headers, body, timeout):
            raise OSError("connection reset")
        self.sr._send = boom
        st, body = probe.SigmaHttp().call("GET", "/v2/whoami")
        self.assertEqual(599, st)
        self.assertIn("connection reset", str(body))


class CliTests(unittest.TestCase):
    def test_cli_writes_out_file_and_exit_code(self):
        with tempfile.TemporaryDirectory() as d:
            qin = os.path.join(d, "q.json")
            out = os.path.join(d, "r.json")
            with open(qin, "w") as fh:
                json.dump({"a": "SELECT * FROM orders", "b": "SELECT * FROM nowhere"}, fh)
            fake = FakeSigma()
            rc = probe.main(["--in", qin, "--out", out, "--connection-id", "conn-1",
                             "--folder-id", "folder-1", "--state", os.path.join(d, "s.json")],
                            api=fake.api, sleep=lambda s: None)
            self.assertEqual(1, rc)  # one query failed
            with open(out) as fh:
                res = json.load(fh)
            self.assertTrue(res["a"]["ok"])
            self.assertFalse(res["b"]["ok"])

    def test_cli_sql_flag_and_columns(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "r.json")
            fake = FakeSigma()
            rc = probe.main(["--sql", "SELECT * FROM orders", "--columns", "--out", out,
                             "--connection-id", "conn-1", "--folder-id", "folder-1",
                             "--state", os.path.join(d, "s.json")],
                            api=fake.api, sleep=lambda s: None)
            self.assertEqual(0, rc)
            with open(out) as fh:
                self.assertEqual(["ORDER_ID", "STATUS", "FLAG"], json.load(fh)["sql"]["columns"])

    def test_cli_requires_connection_and_folder(self):
        with self.assertRaises(SystemExit) as cm:
            probe.main(["--sql", "SELECT 1"], api=FakeSigma().api)
        self.assertEqual(2, cm.exception.code)

    def test_columns_and_types_are_exclusive(self):
        with self.assertRaises(SystemExit):
            probe.main(["--sql", "SELECT 1", "--columns", "--types", "--connection-id", "c",
                        "--folder-id", "f"], api=FakeSigma().api)


if __name__ == "__main__":
    unittest.main(verbosity=1)
