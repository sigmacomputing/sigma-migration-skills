#!/usr/bin/env python3
"""Python twin of the reused-DM relationship evidence route.

Held to the Ruby derivation through the committed expected-map.json goldens
(scripts/test-fixtures/relationship-map/generate.rb --goldens), plus the same
evaluate / route / CLI contracts as the Ruby suites. Creds-free.
"""

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import relationship_map  # noqa: E402
import relationship_route  # noqa: E402

FIXTURES = HERE / "test-fixtures" / "relationship-map"
PROVEN = {"status": "pass", "unique": {"total": 10, "distinct": 10}, "unmatched": 0}


def load_case(name):
    directory = FIXTURES / name
    return {
        "twb_xml": (directory / "workbook-content.twb").read_text(encoding="utf-8-sig"),
        "dm_spec": json.loads((directory / "dm-spec-reused.json").read_text(encoding="utf-8")),
        "dashboards": relationship_map.scoped_dashboards(
            json.loads((directory / "dashboard-scope.json").read_text(encoding="utf-8"))
        ),
        "resolution": json.loads((directory / "resolution.json").read_text(encoding="utf-8"))
        if (directory / "resolution.json").is_file() else None,
    }


def derive(name):
    return relationship_map.derive(**load_case(name))


def with_probes(doc, probe):
    out = copy.deepcopy(doc)
    for edge in out["dm_edges"]:
        edge["probe"] = copy.deepcopy(probe)
    return out


def parity_for(passed, failed=()):
    return {"status": "FAIL" if failed else "PASS", "pass_names": list(passed), "fail_names": list(failed)}


def kinds(result):
    return sorted({b["kind"] for b in result["blockers"]})


def cases():
    return sorted(p.name for p in FIXTURES.iterdir() if p.is_dir())


class DeriveTest(unittest.TestCase):
    def test_every_case_matches_the_ruby_golden(self):
        self.assertGreaterEqual(len(cases()), 11)
        for name in cases():
            with self.subTest(case=name):
                golden = json.loads((FIXTURES / name / "expected-map.json").read_text(encoding="utf-8"))
                self.assertEqual(golden, derive(name))

    def test_write_round_trips(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "relationship-map.json"
            relationship_map.write(path, derive("replaced-key"))
            text = path.read_text(encoding="utf-8")
            self.assertTrue(text.endswith("}\n"))
            self.assertEqual(derive("replaced-key"), json.loads(text))


class SelfJoinTest(unittest.TestCase):
    REL = {"left": "DB.S.EMP", "right": "DB.S.EMP", "tableau_keys": [{"left": "MANAGER_ID", "right": "EMP_ID"}]}
    EDGE = {"edge_id": "e1", "source_element": "emp", "target_element": "mgr",
            "source_table": "DB.S.EMP", "target_table": "DB.S.EMP",
            "keys": [{"source": "EMP_ID", "target": "MANAGER_ID"}]}

    def test_reversed_keys_match_a_self_edge(self):
        self.assertTrue(relationship_map._same_join(self.EDGE, self.REL))
        other = {**self.EDGE, "keys": [{"source": "EMP_ID", "target": "EMP_ID"}]}
        self.assertFalse(relationship_map._same_join(other, self.REL))

    def test_self_join_paths(self):
        path = relationship_map._shortest_path([self.EDGE], {"emp", "mgr"}, {"emp", "mgr"})
        self.assertEqual(["e1"], [e["edge_id"] for e in path or []])
        loop = {**self.EDGE, "edge_id": "e2", "target_element": "emp"}
        path = relationship_map._shortest_path([loop], {"emp"}, {"emp"})
        self.assertEqual(["e2"], [e["edge_id"] for e in path or []])
        self.assertIsNone(relationship_map._shortest_path([], {"emp", "mgr"}, {"emp", "mgr"}))


class FieldUseTest(unittest.TestCase):
    def tableau_entry(self, fixture, disposition=None):
        return next(e for e in derive(fixture)["entries"]
                    if e["kind"] == "tableau" and (disposition is None or e["disposition"] == disposition))

    def test_single_table_deviations_name_parity_worksheets(self):
        o1, o2 = relationship_map.OBJECT + "ds|EMP", relationship_map.OBJECT + "ds|EMP1"
        usage = {"both copies": ["DB.S.EMP", o1, o2], "one copy": ["DB.S.EMP", o1], "other": ["DB.S.DEPT"]}
        self.assertEqual(["both copies"], relationship_map._affected(usage, ["DB.S.EMP"], [o1, o2]))
        self.assertEqual(["both copies", "one copy"], relationship_map._affected(usage, ["DB.S.EMP"]))
        self.assertEqual([], relationship_map._affected(usage, ["DB.S.EMP", "DB.S.DEPT"]))

    def test_self_join_needs_a_worksheet_reading_both_objects(self):
        unused = self.tableau_entry("self-join-unused")
        self.assertEqual("disconnected", unused["disposition"])
        self.assertEqual({"status": "pass", "worksheets": []}, unused["field_use"])
        used = self.tableau_entry("self-join-used")
        self.assertEqual({"status": "fail", "worksheets": ["Org Chart"]}, used["field_use"])

    def test_empty_calc_formula_fails_closed(self):
        entry = self.tableau_entry("dropped-used-by-empty-calc", "dropped")
        self.assertEqual({"status": "fail", "worksheets": ["Revenue by Customer"]}, entry["field_use"])


class TableKeyTest(unittest.TestCase):
    def test_extract_dollar_matches_like_ruby(self):
        # Ruby JoinPlan.object_table_key strips one trailing "$" (Tableau extract
        # names), so a model path still named ORDERS$ maps to the Tableau ORDERS.
        self.assertEqual("ORDERS", relationship_map._object_table_key("ORDERS$"))
        self.assertEqual("ORDER_LINES", relationship_map._object_table_key(" Order Lines$ "))
        self.assertTrue(relationship_map._suffix_match(["ORDERS"], ["DB", "S", "ORDERS$"]))
        self.assertTrue(relationship_map._suffix_match(["S", "ORDERS$"], ["DB", "S", "ORDERS"]))
        self.assertFalse(relationship_map._suffix_match(["ORDERS"], ["DB", "S", "ORDERS$$"]))


class EvaluateTest(unittest.TestCase):
    def evaluate(self, name, doc, **kw):
        return relationship_map.evaluate(doc, **load_case(name), **kw)

    def test_all_matched_passes(self):
        result = self.evaluate("matched-star", derive("matched-star"))
        self.assertEqual("pass", result["status"])
        self.assertEqual({"matched": 2, "replaced": 0, "disconnected": 0, "dropped": 0, "extra": 0}, result["counts"])

    def test_proven_replaced_edge_passes(self):
        doc = with_probes(derive("replaced-key"), PROVEN)
        result = self.evaluate("replaced-key", doc, parity=parity_for([" revenue by customer "]))
        self.assertEqual("pass", result["status"], result["blockers"])

    def test_probe_numbers_are_rechecked(self):
        for probe in (
            dict(PROVEN, status="fail", unmatched=3),
            dict(PROVEN, unmatched=2),
            dict(PROVEN, unique={"total": 10, "distinct": 9}),
        ):
            with self.subTest(probe=probe):
                result = self.evaluate(
                    "replaced-key", with_probes(derive("replaced-key"), probe), parity=parity_for(["Revenue by Customer"])
                )
                self.assertEqual(["probe-failed"], kinds(result))
        err = with_probes(derive("replaced-key"), {"status": "error", "error": "refused"})
        self.assertEqual(["probe-error"], kinds(self.evaluate("replaced-key", err, parity=parity_for(["Revenue by Customer"]))))

    def test_pending_before_finalize(self):
        result = self.evaluate("replaced-key", derive("replaced-key"), final=False)
        self.assertEqual("pending", result["status"])
        self.assertEqual(["parity-missing", "unprobed"], kinds(result))
        self.assertEqual("fail", self.evaluate("replaced-key", derive("replaced-key"))["status"])

    def test_parity_missing_and_failed(self):
        doc = with_probes(derive("replaced-key"), PROVEN)
        self.assertEqual(["parity-missing"], kinds(self.evaluate("replaced-key", doc, parity=parity_for(["Revenue by Product"]))))
        self.assertEqual(["parity-failed"], kinds(self.evaluate("replaced-key", doc, parity=parity_for([], ["Revenue by Customer"]))))

    def test_reason_never_satisfies_evidence_and_edits_are_stale(self):
        bad = with_probes(derive("replaced-key"), dict(PROVEN, unmatched=3))
        for entry in bad["entries"]:
            entry["reason"] = "redesigned on purpose"
        self.assertEqual("fail", self.evaluate("replaced-key", bad, parity=parity_for(["Revenue by Customer"]))["status"])
        edited = with_probes(derive("replaced-key"), PROVEN)
        for entry in edited["entries"]:
            if entry["disposition"] == "replaced":
                entry["disposition"] = "matched"
        self.assertIn("stale-map", kinds(self.evaluate("replaced-key", edited, parity=parity_for(["Revenue by Customer"]))))

    def test_merge_prior_drops_probes_of_changed_edges(self):
        case = load_case("replaced-key")
        probed = with_probes(derive("replaced-key"), PROVEN)
        changed = copy.deepcopy(case["dm_spec"])
        orders = next(e for e in changed["pages"][0]["elements"] if e["id"] == "orders")
        orders["relationships"][0]["keys"][0]["targetColumnId"] = "cust-customer_key"
        fresh = relationship_map.derive(twb_xml=case["twb_xml"], dm_spec=changed, dashboards=case["dashboards"])
        merged = relationship_map.merge_prior(fresh, probed)
        edges = {d["edge_id"]: d for d in merged["dm_edges"]}
        self.assertIsNone(edges["orders->cust"]["probe"])
        self.assertEqual(PROVEN, edges["orders->prod"]["probe"])
        stale = relationship_map.evaluate(probed, twb_xml=case["twb_xml"], dm_spec=changed, dashboards=case["dashboards"],
                                          parity=parity_for(["Revenue by Customer"]))
        self.assertIn("stale-map", kinds(stale))

    def test_dropped_and_ambiguous(self):
        self.assertEqual("pass", self.evaluate("dropped-unused", derive("dropped-unused"))["status"])
        self.assertEqual(["field-use"], kinds(self.evaluate("dropped-used-by-calc", derive("dropped-used-by-calc"))))
        self.assertIn("ambiguous-table", kinds(self.evaluate("short-name-ambiguous", derive("short-name-ambiguous"))))

    def test_normalize_parity(self):
        result = relationship_map.normalize_parity(
            {"status": "FAIL", "match": False, "differences": [{"path": "$.Revenue by Product[2]", "kind": "number"}]},
            {"Revenue by Customer": [[1]], "Revenue by Product": [[2]], "Revenue by Product YoY": [[3]]},
        )
        self.assertEqual(
            {"pass_names": ["Revenue by Customer", "Revenue by Product YoY"], "fail_names": ["Revenue by Product"]}, result
        )
        self.assertEqual({"pass_names": ["A"], "fail_names": []}, relationship_map.normalize_parity({"pass_names": ["A"]}, {"B": []}))
        root = relationship_map.normalize_parity({"match": False, "differences": [{"path": "$"}]}, {"A": [], "B": []})
        self.assertEqual({"pass_names": [], "fail_names": ["A", "B"]}, root)
        plan = {"charts": [{"chart": "Customer Revenue (Top 10)", "tableau_view": "Revenue by Customer"},
                           {"chart": "Product Mix", "tableau_view": "Revenue by Product"},
                           {"chart": "Product Mix Trend", "tableau_view": "Revenue by Product"}]}
        aliased = relationship_map.normalize_parity(
            {"pass_names": ["Customer Revenue (Top 10)", "Product Mix"], "fail_names": ["Product Mix Trend"]}, None, plan)
        self.assertIn("Revenue by Customer", aliased["pass_names"])
        self.assertIn("Revenue by Product", aliased["fail_names"])
        doc = with_probes(derive("replaced-key"), PROVEN)
        result = self.evaluate("replaced-key", doc, parity=relationship_map.normalize_parity(
            {"pass_names": ["Customer Revenue (Top 10)"], "fail_names": []}, None, plan))
        self.assertEqual("pass", result["status"], result["blockers"])
        both = {"pass_names": ["Revenue by Customer"], "fail_names": ["revenue by customer"]}
        self.assertEqual(["parity-failed"], kinds(self.evaluate("replaced-key", doc, parity=both)))


def route_workdir(work, fixture, probe=True, parity=None, route=True, state_file="migrate-state-python.json"):
    for name in ("workbook-content.twb", "dm-spec-reused.json", "dashboard-scope.json"):
        shutil.copy(FIXTURES / fixture / name, work / name)
    doc = derive(fixture)
    if probe:
        doc = with_probes(doc, PROVEN)
    relationship_map.write(work / "relationship-map.json", doc)
    if parity is not None:
        (work / "parity-final.json").write_text(json.dumps(parity_for(parity)), encoding="utf-8")
    state = {"relationship_route": "reused-dm-evidence", "data_model_id": "dm-reused"} if route else {}
    (work / state_file).write_text(json.dumps(state), encoding="utf-8")


def run(script, *args):
    return subprocess.run([sys.executable, "-I", str(HERE / script), *args], capture_output=True, text=True, check=False)


class RouteTest(unittest.TestCase):
    def test_eligibility_and_current(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            self.assertTrue(relationship_route.eligible(work, "dm-123"))
            self.assertFalse(relationship_route.eligible(work, None))
            self.assertFalse(relationship_route.eligible(work, "  "))
            (work / "posted-datamodels.jsonl").write_text(json.dumps({"id": "dm-123"}) + "\nnot json\n", encoding="utf-8")
            self.assertFalse(relationship_route.eligible(work, "dm-123"))
            self.assertTrue(relationship_route.eligible(work, "dm-999"))
            self.assertIsNone(relationship_route.current(work))
            state = work / "migrate-state-python.json"
            state.write_text(json.dumps({"relationship_route": "reused-dm-evidence", "data_model_id": "dm-777"}))
            self.assertEqual("reused-dm-evidence", relationship_route.current(work))
            # Gate-time re-check: the route over a model this workdir posted,
            # or with no recorded model, does not stand.
            state.write_text(json.dumps({"relationship_route": "reused-dm-evidence", "data_model_id": "dm-123"}))
            self.assertIsNone(relationship_route.current(work))
            state.write_text(json.dumps({"relationship_route": "reused-dm-evidence"}))
            self.assertIsNone(relationship_route.current(work))
            state.write_text(json.dumps({"relationship_route": "reused-dm-evidence", "data_model_id": "dm-777"}))
            self.assertIsNone(relationship_route.current(work, state_file="migrate-state.json"))
            (work / "migrate-state-python.json").write_text("{")
            self.assertIsNone(relationship_route.current(work))

    def test_explicit_reuse_survives_re_entry(self):
        # Reuse discovery falls back to the state's data_model_id on re-entry, so
        # a later pass-1 without --data-model-id must keep the evidence route for
        # the model it already chose, not treat the reuse as abandoned.
        ev = relationship_route.EVIDENCE
        pick = relationship_route.explicit_reuse_id
        self.assertEqual("dm-1", pick("dm-1", {}))
        self.assertEqual("dm-1", pick(" dm-1 ", {"relationship_route": ev, "data_model_id": "dm-7"}))
        self.assertEqual("dm-7", pick(None, {"relationship_route": ev, "data_model_id": "dm-7"}))
        self.assertEqual("dm-7", pick("  ", {"relationship_route": ev, "data_model_id": "dm-7"}))
        self.assertIsNone(pick(None, {"data_model_id": "dm-7"}), "a strict-route state never becomes a reuse")
        self.assertIsNone(pick(None, {"relationship_route": ev}))
        self.assertIsNone(pick(None, {}))
        source = (HERE / "migrate-tableau.py").read_text(encoding="utf-8")
        self.assertIn("explicit_dm = relationship_route.explicit_reuse_id(args.data_model_id, state)", source)
        self.assertIn("relationship_route.eligible(workdir, explicit_dm)", source)
        self.assertIn("reused = bool(data_model_id) and data_model_id == explicit_dm", source)
        self.assertIn("reused=reused,", source)
        self.assertNotIn("relationship_route.eligible(workdir, args.data_model_id)", source)

    def test_settle(self):
        ev = relationship_route.EVIDENCE
        self.assertEqual({"route": ev, "stop": False}, relationship_route.settle(ev, reused=True, coverage_deferred=True))
        self.assertEqual({"route": None, "stop": True}, relationship_route.settle(ev, reused=False, coverage_deferred=True))
        self.assertEqual({"route": None, "stop": False}, relationship_route.settle(ev, reused=False, coverage_deferred=False))
        self.assertEqual({"route": None, "stop": False}, relationship_route.settle(None, reused=False, coverage_deferred=False))

    def test_resolution_carries_the_manifest_remap(self):
        # The Python path has no --table-mapping: landed extract tables are
        # renamed by the manifest remap, so the persisted resolution must carry
        # those renames or the map cannot resolve them like the converter does.
        mappings = [{"old_table": "FACT_SALES", "new_name": "SALES_WIDE"},
                    {"old_table": "FACT_ORDERS", "new_name": "SALES_WIDE"},
                    {"old_table": "DIM_CUSTOMER", "new_name": "CUSTOMERS"},
                    {"old_table": "", "new_name": "IGNORED"}]
        expected = json.loads((FIXTURES / "extract-renamed" / "resolution.json").read_text(encoding="utf-8"))
        self.assertEqual(expected, relationship_route.resolution("ANALYTICS", "LANDED", mappings))
        self.assertEqual({"db": "A", "schema": "B", "table_mapping": {}}, relationship_route.resolution("A", "B", None))
        source = (HERE / "migrate-tableau.py").read_text(encoding="utf-8")
        self.assertIn("relationship_route.resolution(args.db, args.schema, extract_table_mappings)", source)

    def test_phase6_gate_judges_the_map_on_the_route(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("assert_phase6_ran", HERE / "assert-phase6-ran.py")
        gate = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = gate  # dataclasses resolve the defining module
        spec.loader.exec_module(gate)
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            route_workdir(work, "replaced-key", parity=["Revenue by Customer"])
            gate.gate_relationship_coverage(work)  # no relationship-coverage.json needed on the route
            route_workdir(work, "replaced-key", probe=False, parity=["Revenue by Customer"])
            with self.assertRaises(gate.GateFailure) as raised:
                gate.gate_relationship_coverage(work)
            self.assertIn("unprobed", str(raised.exception.args))

    def test_emitter_and_annotate(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            for name in ("workbook-content.twb", "dm-spec-reused.json", "dashboard-scope.json"):
                shutil.copy(FIXTURES / "replaced-key" / name, work / name)
            done = run("emit-relationship-map.py", "--workdir", str(work))
            self.assertEqual(0, done.returncode, done.stderr)
            self.assertIn("1 replaced", done.stdout)
            self.assertIn("PENDING", done.stdout)
            self.assertIn("probe-relationship-map.py", done.stdout)
            doc = json.loads((work / "relationship-map.json").read_text(encoding="utf-8"))
            self.assertEqual(derive("replaced-key"), doc)
            index = next(e["index"] for e in doc["entries"] if e["disposition"] == "replaced")
            done = run("emit-relationship-map.py", "--workdir", str(work), "--annotate", str(index), "--reason", "by design")
            self.assertEqual(0, done.returncode, done.stderr)
            run("emit-relationship-map.py", "--workdir", str(work))
            doc = json.loads((work / "relationship-map.json").read_text(encoding="utf-8"))
            self.assertEqual("by design", doc["entries"][index]["reason"])
            self.assertEqual(2, run("emit-relationship-map.py", "--workdir", str(work), "--annotate", "99", "--reason", "x").returncode)
            (work / "dm-spec-reused.json").unlink()
            missing = run("emit-relationship-map.py", "--workdir", str(work))
            self.assertEqual(2, missing.returncode)
            self.assertIn("dm-spec-reused.json", missing.stderr)

    def test_emitter_uses_the_run_resolution(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            for name in ("workbook-content.twb", "dm-spec-reused.json", "dashboard-scope.json"):
                shutil.copy(FIXTURES / "extract-renamed" / name, work / name)
            self.assertIn("0 matched", run("emit-relationship-map.py", "--workdir", str(work)).stdout)
            done = run("emit-relationship-map.py", "--workdir", str(work), "--db", "ANALYTICS", "--schema", "LANDED",
                       "--table-mapping", "FACT_SALES=SALES_WIDE", "--table-mapping", "FACT_ORDERS=SALES_WIDE",
                       "--table-mapping", "DIM_CUSTOMER=CUSTOMERS")
            self.assertEqual(0, done.returncode, done.stderr)
            self.assertIn("2 matched", done.stdout)
            resolution = json.loads((FIXTURES / "extract-renamed" / "resolution.json").read_text(encoding="utf-8"))
            (work / "migrate-state-python.json").write_text(json.dumps({"relationship_resolution": resolution}))
            self.assertIn("2 matched", run("emit-relationship-map.py", "--workdir", str(work)).stdout)

    def test_probe_fixture_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            route_workdir(work, "replaced-key", probe=False)
            fixture = work / "fixture"
            fixture.mkdir()
            (fixture / "edge-orders__cust.json").write_text(json.dumps({"total": 10, "distinct": 10, "unmatched": 0}))
            done = run("probe-relationship-map.py", "--workdir", str(work), "--fixture", str(fixture))
            self.assertEqual(0, done.returncode, done.stdout + done.stderr)
            doc = json.loads((work / "relationship-map.json").read_text(encoding="utf-8"))
            probe = next(d for d in doc["dm_edges"] if d["edge_id"] == "orders->cust")["probe"]
            self.assertEqual("pass", probe["status"])
            self.assertIn("NOT EXISTS", probe["sql"]["unmatched"])
            self.assertIn("COUNT(DISTINCT CUSTOMER_ALT_KEY)", probe["sql"]["totals"])
            self.assertIsNone(next(d for d in doc["dm_edges"] if d["edge_id"] == "orders->prod")["probe"])
            (fixture / "edge-orders__cust.json").write_text(json.dumps({"total": 10, "distinct": 10, "unmatched": 4}))
            for edge in doc["dm_edges"]:
                edge["probe"] = None
            relationship_map.write(work / "relationship-map.json", doc)
            self.assertEqual(2, run("probe-relationship-map.py", "--workdir", str(work), "--fixture", str(fixture)).returncode)
            # a failed edge is re-probed after the warehouse is fixed
            (fixture / "edge-orders__cust.json").write_text(json.dumps({"total": 10, "distinct": 10, "unmatched": 0}))
            self.assertEqual(0, run("probe-relationship-map.py", "--workdir", str(work), "--fixture", str(fixture)).returncode)
            # Custom SQL: aliased subquery, trailing ';' dropped, line comment closed
            dm = json.loads((work / "dm-spec-reused.json").read_text(encoding="utf-8"))
            cust = next(e for e in dm["pages"][0]["elements"] if e["id"] == "cust")
            cust["source"] = {"kind": "sql", "connectionId": "c", "statement": "SELECT CUSTOMER_ALT_KEY FROM X; -- note"}
            (work / "dm-spec-reused.json").write_text(json.dumps(dm), encoding="utf-8")
            doc = json.loads((work / "relationship-map.json").read_text(encoding="utf-8"))
            for edge in doc["dm_edges"]:
                edge["probe"] = None
            relationship_map.write(work / "relationship-map.json", doc)
            run("probe-relationship-map.py", "--workdir", str(work), "--fixture", str(fixture))
            doc = json.loads((work / "relationship-map.json").read_text(encoding="utf-8"))
            sql = next(d for d in doc["dm_edges"] if d["edge_id"] == "orders->cust")["probe"]["sql"]
            self.assertIn("FROM (SELECT CUSTOMER_ALT_KEY FROM X -- note\n) t", sql["totals"])
            self.assertNotIn(";", sql["totals"])

    def test_live_probe_body_is_a_canonical_workbook(self):
        # Live-test regression: Sigma rejected the probe POST with
        # "contents.layout: Invalid array: undefined" (pages[].elements, no layout).
        import importlib.util
        spec = importlib.util.spec_from_file_location("probe_relmap", HERE / "probe-relationship-map.py")
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        import code_rep
        body = code_rep.create_body(probe.probe_workbook_body("conn-1", "folder-1", "SELECT 1 AS X", ["X"]))
        contents = body["contents"]
        self.assertEqual("folder-1", body.get("folderId"))
        self.assertEqual(["probe"], [e["id"] for e in contents["elements"]])
        self.assertIn('elementId="probe"', contents.get("layout") or "")
        self.assertEqual("SELECT 1 AS X", contents["elements"][0]["source"]["statement"])

    def test_live_probe_registers_its_workbook_for_the_sweep(self):
        # A killed or timed-out probe must stay visible to sweep-run-artifacts.rb:
        # the workbook id lands in probe-artifacts.jsonl at creation, and the
        # cleanup outcome is appended after the delete (twin of probe-join-keys.rb).
        import types
        probe = self.load_probe_module()
        calls = []

        class SigmaError(Exception):
            pass

        def request(method, path, **_kw):
            calls.append((method, path))
            if method == "post" and path.endswith("/export"):
                return {"queryId": "q1"}
            if method == "post":
                return {"workbookId": f"wb-probe-{sum(1 for m, p in calls if m == 'post' and not p.endswith('/export'))}"}
            if method == "get":
                return b"UNMATCHED\n0\n"
            if method == "delete" and fail_delete:
                raise SigmaError("500 Internal Server Error")
            return {}

        fake = types.SimpleNamespace(request=request, SigmaError=SigmaError)
        original_sleep, probe.time.sleep = probe.time.sleep, lambda _s: None
        sys.modules["sigma_rest"], saved = fake, sys.modules.get("sigma_rest")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                work = Path(tmp)
                fail_delete = False
                rows = probe.sql_rows("conn-1", "folder-1", "SELECT 0 AS UNMATCHED", ["UNMATCHED"], workdir=work)
                self.assertEqual([{"UNMATCHED": "0"}], rows)
                records = [json.loads(l) for l in (work / "probe-artifacts.jsonl").read_text().splitlines()]
                self.assertEqual("wb-probe-1", records[0]["id"])
                self.assertIn("created_at", records[0])
                self.assertEqual("probe-relationship-map.py", records[0]["script"])
                self.assertEqual({"id": "wb-probe-1", "outcome": "deleted", "via": "ensure"},
                                 {k: records[1][k] for k in ("id", "outcome", "via")})
                fail_delete = True
                probe.sql_rows("conn-1", "folder-1", "SELECT 0 AS UNMATCHED", ["UNMATCHED"], workdir=work)
                records = [json.loads(l) for l in (work / "probe-artifacts.jsonl").read_text().splitlines()]
                self.assertEqual({"id": "wb-probe-2", "outcome": "failed"},
                                 {k: records[-1][k] for k in ("id", "outcome")})
                import probe_registry
                self.assertEqual(["wb-probe-2"], [r["id"] for r in probe_registry.outstanding(work)])
        finally:
            probe.time.sleep = original_sleep
            if saved is None:
                sys.modules.pop("sigma_rest", None)
            else:
                sys.modules["sigma_rest"] = saved

    def load_probe_module(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("probe_relmap", HERE / "probe-relationship-map.py")
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        return probe

    def test_live_counts_never_default_to_zero(self):
        # Review (Bugbot): empty rows / missing columns were coerced to 0 -> pass.
        probe = self.load_probe_module()
        self.assertEqual({"total": 40, "distinct": 40, "unmatched": 0},
                         probe.live_counts([{"TOTAL_ROWS": "40", "DISTINCT_KEYS": "40"}], [{"UNMATCHED": "0"}]))
        for tot, unm in (([], [{"UNMATCHED": "0"}]), ([{"TOTAL_ROWS": "40"}], [{"UNMATCHED": "0"}]),
                         ([{"TOTAL_ROWS": "40", "DISTINCT_KEYS": "40"}], []),
                         ([{"TOTAL_ROWS": "40", "DISTINCT_KEYS": "x"}], [{"UNMATCHED": "0"}])):
            with self.subTest(tot=tot, unm=unm):
                self.assertIn("error", probe.live_counts(tot, unm))

    def test_fixture_with_missing_count_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            route_workdir(work, "replaced-key", probe=False)
            fixture = work / "fixture"
            fixture.mkdir()
            (fixture / "edge-orders__cust.json").write_text(json.dumps({"total": 0, "distinct": 0}))
            self.assertEqual(3, run("probe-relationship-map.py", "--workdir", str(work), "--fixture", str(fixture)).returncode)
            doc = json.loads((work / "relationship-map.json").read_text(encoding="utf-8"))
            self.assertEqual("error", next(d for d in doc["dm_edges"] if d["edge_id"] == "orders->cust")["probe"]["status"])

    def test_folder_id_falls_back_to_the_workdir_specs(self):
        # Review (Bugbot): the Ruby twin walks wb-spec.json / dm-spec.json too.
        probe = self.load_probe_module()
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / "dm-spec-reused.json").write_text(json.dumps({"pages": []}))
            self.assertIsNone(probe.resolve_folder(work, None))
            (work / "wb-spec.json").write_text(json.dumps({"folderId": "folder-from-wb"}))
            self.assertEqual("folder-from-wb", probe.resolve_folder(work, None))
            self.assertEqual("explicit", probe.resolve_folder(work, "explicit"))

    def test_refresh_reused_model(self):
        # Review (Bugbot): Python must re-read the live model before the gate,
        # and a failed re-read must block (pass-1 copy removed).
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            path = work / "dm-spec-reused.json"
            path.write_text(json.dumps({"pages": [{"elements": [{"id": "old"}]}]}))
            ok, _ = relationship_route.refresh_reused_model(work, lambda: {"pages": [{"elements": [{"id": "live"}]}]})
            self.assertTrue(ok)
            self.assertEqual("live", json.loads(path.read_text())["pages"][0]["elements"][0]["id"])

            def boom():
                raise OSError("connection reset")
            ok, msg = relationship_route.refresh_reused_model(work, boom)
            self.assertFalse(ok)
            self.assertFalse(path.exists())
            self.assertIn("connection reset", msg)
            path.write_text("{}")
            ok, _ = relationship_route.refresh_reused_model(work, lambda: {"error": "x"})
            self.assertFalse(ok)
            self.assertFalse(path.exists())

    def test_assert_gate_on_route(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            route_workdir(work, "replaced-key", parity=["Revenue by Customer"])
            done = run("assert-relationship-coverage.py", "--workdir", str(work))
            self.assertEqual(0, done.returncode, done.stderr)
            self.assertIn("PASS (reused-dm evidence)", done.stdout)
            route_workdir(work, "replaced-key", probe=False, parity=["Revenue by Customer"])
            done = run("assert-relationship-coverage.py", "--workdir", str(work))
            self.assertEqual(3, done.returncode)
            self.assertIn("unprobed", done.stderr)
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            route_workdir(work, "replaced-key", parity=["Revenue by Customer"], route=False)
            done = run("assert-relationship-coverage.py", "--workdir", str(work))
            self.assertNotEqual(0, done.returncode)
            self.assertNotIn("reused-dm evidence", done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
