#!/usr/bin/env python3
"""Offline tests for probe_lib. Invented identifiers only; no network."""
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_lib  # noqa: E402


class CompareTests(unittest.TestCase):
    def test_compare_reports_mismatch_and_missing(self):
        truth = [{"k": "a", "v": 1}, {"k": "b", "v": 2}]
        actual = [{"k": "a", "v": 1.0000001}, {"k": "c", "v": 3}]
        r = probe_lib.compare(actual, truth, ["k"])
        self.assertEqual(r["matched"], 1)
        self.assertEqual(r["missing"], ["b"])
        self.assertEqual(r["extra"], ["c"])
        self.assertEqual(r["mismatched"], [])

    def test_compare_flags_value_mismatch(self):
        r = probe_lib.compare([{"k": "a", "v": 5}], [{"k": "a", "v": 1}], ["k"])
        self.assertEqual(r["matched"], 0)
        self.assertEqual(len(r["mismatched"]), 1)


class RedactTests(unittest.TestCase):
    def test_redact_removes_identifiers(self):
        terms = ["conn-zz-0001", "acme-test-org", "XY12345.us-east-1"]
        obj = {
            "conn-zz-0001": "k",
            "a": {"b": ["see https://app.example.com/acme-test-org/x", {"c": "XY12345.us-east-1"}]},
            "n": 3,
        }
        out = probe_lib.redact(obj, terms)
        flat = repr(out)
        for t in terms:
            self.assertNotIn(t, flat)
        self.assertIn("<redacted>", flat)
        self.assertEqual(out["n"], 3)

    def test_redact_uuids_stable_placeholders(self):
        a, b = "00000000-0000-4000-8000-00000000000a", "00000000-0000-4000-8000-00000000000B"
        obj = {a: {"k": [f"id {a} and {b}", {b.lower(): a}]}, "n": 3}
        out = probe_lib.redact(obj, [])
        flat = json.dumps(out)
        self.assertNotIn(a, flat)
        self.assertNotIn(b.lower(), flat.lower())
        self.assertEqual(out["<uuid-1>"]["k"][0], "id <uuid-1> and <uuid-2>")
        self.assertEqual(out["<uuid-1>"]["k"][1], {"<uuid-2>": "<uuid-1>"})
        self.assertEqual(out["n"], 3)

    def test_redact_terms_collects_env_and_cli(self):
        env = {"PROBE_REDACT_TERMS": "alpha-zz, beta-zz", "PROBE_CONNECTION_ID": "conn-zz-9"}
        status = "Profile: p\nOrg URL: https://app.example.com/invented-slug\nAuth: OK\n"
        with mock.patch.dict(os.environ, env, clear=False), \
                mock.patch.object(probe_lib, "_cli_status", return_value=status):
            terms = probe_lib.redact_terms()
        for t in ("alpha-zz", "beta-zz", "conn-zz-9", "invented-slug"):
            self.assertIn(t, terms)

    def test_redact_terms_survives_missing_cli(self):
        with mock.patch.dict(os.environ, {"PROBE_CONNECTION_ID": "c-1"}, clear=False), \
                mock.patch.object(probe_lib, "_cli_status", return_value=""):
            self.assertIn("c-1", probe_lib.redact_terms())


class CleanupTests(unittest.TestCase):
    def test_cleanup_reads_back_is_archived(self):
        calls = []
        state = {"id1": False, "id2": False}

        def fake(method, path, body=None, **kw):
            calls.append((method, path))
            iid = path.rsplit("/", 1)[-1]
            if method == "delete":
                if iid == "id1":
                    state[iid] = True
                return None
            return {"inodeId": iid, "isArchived": state[iid]}

        with mock.patch.object(probe_lib.sigma_rest, "request", side_effect=fake):
            res = probe_lib.cleanup(["id1", "id2"])
        self.assertEqual(res, {"id1": True, "id2": False})
        self.assertIn(("delete", "/v2/files/id1"), calls)
        self.assertIn(("get", "/v2/files/id2"), calls)

    def test_cleanup_continues_after_delete_error(self):
        def fake(method, path, body=None, **kw):
            if method == "delete":
                raise probe_lib.sigma_rest.SigmaError("boom")
            return {"isArchived": False}

        with mock.patch.object(probe_lib.sigma_rest, "request", side_effect=fake):
            self.assertEqual(probe_lib.cleanup(["x"]), {"x": False})


class PostTests(unittest.TestCase):
    def test_post_dm_returns_readback(self):
        def fake(method, path, body=None, **kw):
            if method == "post":
                self.assertEqual(path, "/v2/dataModels/spec")
                return {"dataModelId": "dm1"}
            self.assertEqual(path, "/v2/dataModels/dm1/spec")
            return {"name": "n", "pages": []}

        with mock.patch.object(probe_lib.sigma_rest, "request", side_effect=fake):
            rb = probe_lib.post_dm({"name": "n"})
        self.assertEqual(rb["dataModelId"], "dm1")
        self.assertEqual(rb["name"], "n")


ENV = {"PROBE_CONNECTION_ID": "conn-zz-1", "PROBE_FOLDER_ID": "folder-zz-1"}


class PostWbTests(unittest.TestCase):
    def test_post_wb_envelope_shape(self):
        seen = {}

        def fake(method, path, body=None, **kw):
            if method == "post":
                seen["path"], seen["body"] = path, json.loads(body)
                return {"workbookId": "wb1"}
            return {"contents": {}}

        doc = {"schemaVersion": 1, "kind": "workbook", "pages": [], "layout": {}}
        with mock.patch.dict(os.environ, ENV), \
                mock.patch.object(probe_lib.sigma_rest, "request", side_effect=fake):
            rb = probe_lib.post_wb(doc, name="zz t")
        self.assertEqual(seen["path"], "/v2/workbooks")
        self.assertEqual(seen["body"]["name"], "zz t")
        self.assertEqual(seen["body"]["folderId"], "folder-zz-1")
        self.assertEqual(seen["body"]["contents"]["kind"], "workbook")
        self.assertEqual(rb["workbookId"], "wb1")


class ExportTests(unittest.TestCase):
    def _run(self, download):
        def fake(method, path, body=None, **kw):
            if method == "post":
                return {"queryId": "q1"}
            return download()

        with mock.patch.object(probe_lib.sigma_rest, "request", side_effect=fake), \
                mock.patch.object(probe_lib.time, "sleep"):
            return probe_lib.export_rows("wb1", "el1", {"p": 1})

    def test_parses_csv_and_coerces(self):
        rows = self._run(lambda: b"k,v,z,e\n007,1.5,x,\n2,3,y,4\n")
        self.assertEqual(rows[0], {"k": "007", "v": 1.5, "z": "x", "e": None})
        self.assertEqual(rows[1]["k"], 2.0)

    def test_retries_not_ready_statuses(self):
        err = probe_lib.sigma_rest.SigmaError
        seq = [err("GET /x -> 202 Accepted\n"), err("GET /x -> 204 No\n"),
               err("GET /x -> 404 Not Found\n"), b"a\n1\n"]

        def dl():
            r = seq.pop(0)
            if isinstance(r, Exception):
                raise r
            return r

        self.assertEqual(self._run(dl), [{"a": 1.0}])

    def test_other_errors_raise(self):
        def dl():
            raise probe_lib.sigma_rest.SigmaError("GET /x -> 500 Server Error\n")

        with self.assertRaises(probe_lib.sigma_rest.SigmaError):
            self._run(dl)


class RunSqlTests(unittest.TestCase):
    def _go(self, stdout, archived=True, state_wb="scratch-1"):
        deleted = []

        def fake_run(cmd, **kw):
            sp = cmd[cmd.index("--state") + 1]
            self.assertNotIn("--cleanup", cmd)
            self.state_path = sp
            if state_wb:
                with open(sp, "w") as fh:
                    json.dump({"workbookId": state_wb}, fh)
            return mock.Mock(stdout=stdout, stderr="", returncode=0)

        def fake_req(method, path, body=None, **kw):
            if method == "delete":
                deleted.append(path)
                return None
            return {"isArchived": archived}

        with mock.patch.dict(os.environ, ENV), \
                mock.patch.object(probe_lib.subprocess, "run", side_effect=fake_run), \
                mock.patch.object(probe_lib.sigma_rest, "request", side_effect=fake_req):
            try:
                return probe_lib.run_sql("select 1"), deleted
            finally:
                self.assertFalse(os.path.exists(self.state_path))

    def test_parses_rows_and_deletes_scratch(self):
        rows, deleted = self._go(json.dumps({"sql": {"ok": True, "rows": [{"A": 1}]}}))
        self.assertEqual(rows, [{"A": 1}])
        self.assertEqual(deleted, ["/v2/files/scratch-1"])

    def test_failure_path(self):
        with self.assertRaises(RuntimeError):
            self._go(json.dumps({"sql": {"ok": False, "error": "bad"}}))

    def test_unparseable_output(self):
        with self.assertRaises(RuntimeError):
            self._go("not json")

    def test_unarchived_scratch_raises(self):
        with self.assertRaises(RuntimeError):
            self._go(json.dumps({"sql": {"ok": True, "rows": []}}), archived=False)


class KeyIdentityTests(unittest.TestCase):
    def test_numeric_key_identity(self):
        r = probe_lib.compare([{"k": 1.0, "v": 1}, {"k": " x ", "v": 2}],
                              [{"k": 1, "v": 1}, {"k": "x", "v": 2}], ["k"])
        self.assertEqual((r["matched"], r["missing"], r["extra"]), (2, [], []))

    def test_leading_zero_not_merged(self):
        r = probe_lib.compare([{"k": "007"}], [{"k": "7"}], ["k"])
        self.assertEqual((r["missing"], r["extra"]), (["7"], ["007"]))

    def test_duplicates_reported(self):
        r = probe_lib.compare([{"k": "a", "v": 1}, {"k": "a", "v": 2}],
                              [{"k": "b", "v": 1}, {"k": "b", "v": 1}], ["k"])
        self.assertEqual(r["duplicates"], {"actual": ["a"], "truth": ["b"]})


if __name__ == "__main__":
    unittest.main()
