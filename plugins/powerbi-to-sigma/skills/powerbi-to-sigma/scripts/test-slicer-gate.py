#!/usr/bin/env python3
"""Offline end-to-end test of the page-fact path: scaffold-page-fact.py -> integrate-page-fact.py
-> build-workbook-from-pbir.rb (master-map page_fields) -> wire-slicer-gate.py.

On the synthetic three-page fixture (fixtures/page-facts) it asserts the workbook shape (union
gate, fast path, parameterized SQL, value lists, retargeted controls), runs the skill's own
preflight, spec and control lints on the result, and EXECUTES the parameterized SQL in SQLite
the way Sigma renders it (control values inlined) for real selections, comparing each against
the independent oracle's filtered scenario: a one-hop slicer, a two-hop slicer with the (Blank)
member, and a slicer that must reach the fact through a USERELATIONSHIP bridge.

Needs ruby on PATH (the builder and lints). No network, no credentials.
Run: python3 scripts/test-slicer-gate.py   (exit 0 = pass)
"""
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "..", "fixtures", "page-facts")
CONN = "00000000-0000-4000-8000-00000000c0de"
ENV = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def jload(path):
    return json.loads(read(path))


def jdump(obj, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f)


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


scaffold = load("scaffold_page_fact", "scaffold-page-fact.py")
integrate = load("integrate_page_fact", "integrate-page-fact.py")
gate = load("wire_slicer_gate", "wire-slicer-gate.py")
parity = load("parity_from_oracle", "parity-from-oracle.py")


def render(sql, picks):
    """Inline control values the way Sigma does: ArrayLength -> count, {{Ctl}} -> quoted list."""
    sql = re.sub(r"\{\{#formula ArrayLength\(\[([^\]]+)\]\)\}\}", lambda m: str(len(picks.get(m.group(1), []))), sql)
    return re.sub(r"\{\{([A-Za-z0-9_]+)\}\}", lambda m: "(" + ", ".join(
        "'%s'" % str(v).replace("'", "''") for v in (picks.get(m.group(1)) or [""])) + ")", sql)


def db():
    con = sqlite3.connect(":memory:")
    con.create_function("EQUAL_NULL", 2, lambda a, b: 1 if (a is None and b is None) or (a is not None and a == b) else 0,
                        deterministic=True)
    con.executescript(read(os.path.join(FIX, "seed.sql")))
    return con


def rows(con, sql):
    cur = con.execute(sql)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def ruby(*args):
    return subprocess.run(["ruby", *args], capture_output=True, text=True, env=ENV, cwd=HERE)


class GatePipeline(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        d = cls.d = tempfile.mkdtemp(prefix="pf-gate-")
        cls.pf = os.path.join(d, "page-facts")
        for f in ("dm-spec.json", "master-map.json"):
            shutil.copy(os.path.join(FIX, f), os.path.join(d, f))
        cls.dm, cls.mm = os.path.join(d, "dm-spec.json"), os.path.join(d, "master-map.json")
        assert scaffold.main(["--model", os.path.join(FIX, "model.bim"), "--signals", os.path.join(FIX, "signals.json"),
                              "--dm-spec", cls.dm, "--master-map", cls.mm, "--out-dir", cls.pf, "--all-pages",
                              "--scenario", "Store.Region=West", "--scenario", "Manager.Manager Name=(Blank)",
                              "--scenario", "Supplier.Supplier Name=Acme"]) == 0
        assert integrate.main([cls.pf, "--dm-spec", cls.dm, "--connection", CONN, "--allow-todo"]) == 0
        assert integrate.main([cls.pf, "--master-map", cls.mm, "--allow-todo"]) == 0
        cls.spec = os.path.join(d, "workbook-spec.json")
        r = ruby("build-workbook-from-pbir.rb", "--signals", os.path.join(FIX, "signals.json"), "--master-map", cls.mm,
                 "--data-model", "dm-fixture", "--name", "Fixture WB", "--model", os.path.join(FIX, "model.bim"),
                 "--control-scope-out", os.path.join(d, "control-scope.json"), "--coverage-out", os.path.join(d, "coverage.json"),
                 "--out", cls.spec, "--layout-out", os.path.join(d, "layout.xml"), "--folder-id", "00000000-0000-4000-8000-0000000f01d0")
        assert r.returncode == 0, r.stderr[-2000:]
        shutil.copy(cls.spec, os.path.join(d, "built.json"))
        cls.report_path = os.path.join(d, "slicer-gate.json")
        rc = gate.main(["--spec", cls.spec, "--page-facts", cls.pf, "--model", os.path.join(FIX, "model.bim"),
                        "--dm-spec", cls.dm, "--master-map", cls.mm, "--connection", CONN,
                        "--control-scope", os.path.join(d, "control-scope.json"), "--layout-out", os.path.join(d, "layout.xml"),
                        "--report", cls.report_path, "--verify-out", os.path.join(d, "slicer-gate-verify.json")])
        assert rc == 0
        cls.doc = jload(cls.spec)["document"]
        cls.E = {e["id"]: e for e in cls.doc["elements"]}
        cls.report = jload(cls.report_path)
        cls.con = db()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.d, ignore_errors=True)

    def page(self, title):
        return next(p for p in self.report["pages"] if p["page"] == title)

    # ---- integration + builder
    def test_dm_and_master_map_integration(self):
        dm = jload(self.dm)
        names = [e["name"] for e in dm["pages"][0]["elements"]]
        self.assertIn("Stock Cover Page Fact", names)
        el = next(e for e in dm["pages"][0]["elements"] if e["name"] == "Stock Cover Page Fact")
        self.assertEqual(el["source"]["connectionId"], CONN)
        self.assertIn({"id": el["columns"][0]["id"], "formula": "[Custom SQL/G_CATEGORY]", "name": "Category"}, el["columns"])
        mm = jload(self.mm)
        pf = mm["page_fields"]["Stock Cover"]
        self.assertEqual(pf["Stock.On Hand"]["ref"], "Sum([master-pf-8a884102/Sum On Hand])")
        self.assertEqual(pf["Product.Category"]["ref"], "[master-pf-8a884102/Category]")
        self.assertEqual(mm["page_fields"]["Rollup"]["Sales.Orders"]["ref"],
                         "Sum([master-pf-26dd4e26/Todo Orders])")
        self.assertEqual(mm["fields"]["Stock.On Hand"]["master"], "Stock", "the global binding is untouched")

    def test_page_fact_masters_are_never_targeted_from_another_page(self):
        built = jload(os.path.join(self.d, "built.json"))["document"]
        pages = gate.page_blocks(built["layout"])
        mm = jload(self.mm)
        own = {m["id"]: m["page_fact"] for m in mm["masters"].values() if m.get("page_fact")}
        page_name = {p["id"]: p["name"] for p in built["pages"]}
        for pid, ids in pages.items():
            for e in built["elements"]:
                if e["id"] in ids and e.get("kind") == "control":
                    for f in e.get("filters") or []:
                        m = f["source"]["elementId"]
                        if m in own:
                            self.assertEqual(own[m].lower(), page_name[pid].lower(), (e["id"], m))

    def test_builder_binds_page_fields_only_on_their_page(self):
        built = jload(os.path.join(self.d, "built.json"))["document"]
        e = {x["id"]: x for x in built["elements"]}
        self.assertEqual(e["el-2pivot161ea1"]["source"]["elementId"], "master-pf-8a884102")
        self.assertEqual(e["el-orders2a2694"]["source"]["elementId"], "master-pf-26dd4e26",
                         "TODO measure: page-fact NULL stub")
        detail = e["el-1pivot0b579d"]
        self.assertIn("West Sales", [c["name"] for c in detail["columns"]])
        cat = e["el-s3cat53d2d4"]
        self.assertEqual(cat["filters"][0]["source"]["elementId"], "master-pf-26dd4e26", "in-grain slicer wired to the page fact")

    def test_integrate_refuses_todo_and_checks(self):
        self.assertEqual(integrate.main([self.pf, "--dm-spec", self.dm, "--connection", CONN]), 1)
        self.assertEqual(integrate.main([self.pf, "--dm-spec", self.dm, "--check", "--allow-todo"]), 0, "already current")
        scratch = os.path.join(self.d, "dm-copy.json")
        shutil.copy(os.path.join(FIX, "dm-spec.json"), scratch)
        self.assertEqual(integrate.main([os.path.join(self.pf, "stock-cover"), "--dm-spec", scratch, "--check"]), 3)
        self.assertEqual(jload(scratch), jload(os.path.join(FIX, "dm-spec.json")), "--check wrote nothing")

    def test_integrate_rejects_unknown_columns(self):
        bad = jload(os.path.join(self.pf, "stock-cover", "page-fact.json"))
        bad["fields"]["Stock.On Hand"]["ref"] = "Sum({C:No Such Column})"
        p = os.path.join(self.d, "bad.json")
        jdump(bad, p)
        mm = os.path.join(self.d, "mm-copy.json")
        shutil.copy(os.path.join(FIX, "master-map.json"), mm)
        self.assertEqual(integrate.main([p, "--master-map", mm]), 1)

    # ---- gate shape
    def test_union_gate_shape(self):
        p = self.page("Stock Cover")
        self.assertEqual([g["control"] for g in p["gated"]], ["RegionFilter", "ManagerNameFilter2"])
        u, g, b = self.E[p["union"]], self.E[p["fast_path"]], self.E[p["parameterized"]]
        self.assertEqual(u["source"]["kind"], "union")
        self.assertEqual([s["elementId"] for s in u["source"]["sources"]], [g["id"], b["id"]])
        self.assertTrue(all(c["formula"].startswith("[Union of 2 Sources/") for c in u["columns"][:-1]))
        self.assertEqual(u["columns"][-1]["formula"], "ArrayLength([RegionFilter]) + ArrayLength([ManagerNameFilter2])")
        self.assertEqual(g["filters"][0]["values"], [0])
        self.assertEqual(g["source"]["elementId"], "master-pf-8a884102")
        sql = b["source"]["statement"]
        self.assertEqual(sql.count("{{#formula ArrayLength([RegionFilter])}}"), 4, "gate + guard at each of the 2 hooks")
        self.assertNotRegex(sql, r"\{\{#formula [^}]*\+", "one template per control (depth limit)")
        for cid in ("el-2pivot161ea1", "el-v2kpib17bc3", "el-v2baree0e6c"):
            self.assertEqual(self.E[cid]["source"]["elementId"], p["union"], cid)
            self.assertNotIn("[master-pf-8a884102/", json.dumps(self.E[cid]))

    def test_controls_rewired(self):
        reg = self.E["el-regiondf813b"]
        lst = self.E[reg["source"]["source"]["elementId"]]
        self.assertIn("UNION\nSELECT '(Blank)' AS V", lst["source"]["statement"])
        self.assertEqual(reg["filters"][0]["source"]["elementId"], "master-store", "text-typed targets are kept")
        year = self.E["el-s1year75a395"]
        self.assertEqual((year["mode"], year["values"]), ("include", [2026]), "a typed control keeps its typed default")
        self.assertEqual(year["filters"][0]["source"]["elementId"], "master-calendar", "and its other filter targets")
        self.assertEqual(year["source"]["source"]["elementId"], "master-calendar", "and the builder's typed value list")
        b = self.E[self.page("Sales Overview")["parameterized"]]["source"]["statement"]
        self.assertIn('sj1."CAL_YEAR" IN {{YearFilter}})', b, "typed compare: no CAST, no (Blank) member")
        self.assertIn("COALESCE(CAST(sj2.\"MANAGER_NAME\" AS VARCHAR), '(Blank)') IN {{ManagerNameFilter}}", b)
        cat = self.E["el-s3cat53d2d4"]
        self.assertEqual([f["source"]["elementId"] for f in cat["filters"]], [self.page("Rollup")["union"]])
        self.assertEqual(cat["source"]["source"]["elementId"], "master-pf-26dd4e26", "value list stays on the unfiltered master")

    def test_unreachable_and_unresolvable_slicers_are_skipped(self):
        # Rollup's page fact scans Sales only: Manager reaches it (Store -> Sales), Calendar too; build a
        # page fact copy whose slicer table has no data-model element, and one that reaches no hook
        pfj = jload(os.path.join(self.pf, "stock-cover", "page-fact.json"))
        model = gate.Model(jload(os.path.join(FIX, "model.bim")))
        src = gate.SourceIndex(model, {"pages": []})
        cand = {"field": ("Manager", "Manager Name"), "blank_policy": "row"}
        self.assertIn("no data-model element", gate.slicer_unready(model, src, pfj["sql"], cand, "snowflake"))
        src = gate.SourceIndex(model, jload(self.dm), jload(self.mm))
        lone = "SELECT 1 AS X FROM s WHERE 1 = 1 /*@slicers fact=\"Calendar\" alias=\"f\"*/"
        self.assertIn("reaches none", gate.slicer_unready(model, src, lone, cand, "snowflake"))
        self.assertIsNone(gate.slicer_unready(model, src, pfj["sql"], cand, "snowflake"))

    def test_bridge_path_in_gated_sql(self):
        b = self.E[self.page("Rollup")["parameterized"]]["source"]["statement"]
        self.assertIn('f."PRODUCT_KEY" IN (SELECT sj1."CHILD_PRODUCT_KEY" FROM pfs_rollup sj1', b)
        hooks = self.page("Rollup")["hooks"]
        self.assertIn("USERELATIONSHIP", hooks[0]["predicates"][0]["path"])

    def test_layout_and_lints(self):
        data = re.search(r'<Page\b[^>]*id="page-data".*?</Page>', self.doc["layout"], re.S).group(0)
        for p in self.report["pages"]:
            for k in ("union", "fast_path", "parameterized"):
                if p.get(k) and p[k].startswith("pfu-") or k != "union":
                    self.assertIn('elementId="%s"' % p[k], data)
        self.assertEqual(read(os.path.join(self.d, "layout.xml")), self.doc["layout"])
        r = ruby("lib/preflight_lint.rb", self.spec)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = ruby("validate-spec.rb", "--type", "workbook", self.spec)
        self.assertEqual(r.returncode, 0, r.stdout[-1500:])
        before = ruby("lib/control_lint.rb", os.path.join(self.d, "built.json"))
        after = ruby("lib/control_lint.rb", self.spec)
        n_before = (before.stdout + before.stderr).count("partial control")
        n_after = (after.stdout + after.stderr).count("partial control")
        self.assertEqual(n_before, 6)
        self.assertEqual(n_after, 0, "TODO visuals stay on the gated page fact")
        r = ruby("lib/control_lint.rb", self.spec, os.path.join(self.d, "control-scope.json"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # ---- executed: the gated SQL answers like the oracle
    def check_scenario(self, page, slug, picks, scenario):
        p = self.page(page)
        b = self.E[p["parameterized"]]["source"]["statement"]
        live = "\n".join(line for line in render(b, picks).split("\n") if not line.startswith("-- "))
        pfj = jload(os.path.join(self.pf, slug, "page-fact.json"))
        base = "\n".join(line for line in pfj["sql"].split("\n") if not line.startswith("-- "))
        checks = jload(os.path.join(self.pf, slug, "check-queries.json"))
        oracle = jload(os.path.join(self.pf, slug, "oracle-queries.json"))
        compared = 0
        for key, q in checks.items():
            okey = "%s@%s" % (key, scenario)
            if okey not in oracle:
                continue
            got = rows(self.con, q.replace(base, live))
            want = rows(self.con, oracle[okey])
            cols = list(want[0].keys()) if want else []
            canon = lambda rs: sorted((tuple(round(r[c], 6) if isinstance(r[c], float) else r[c] for c in cols) for r in rs),
                                      key=repr)
            self.assertEqual(canon(got), canon(want), "%s %s %s" % (page, key, scenario))
            compared += 1
        self.assertGreater(compared, 0)

    def test_gated_control_loses_its_page_fact_target(self):
        # a slicer the builder bound to a grain column that one fact cannot reach is gated instead; its
        # direct filter on the page fact would drop that fact's rows, so the gate removes it
        built = jload(os.path.join(self.d, "built.json"))
        reg = next(e for e in built["document"]["elements"] if e["id"] == "el-regiondf813b")
        reg["filters"].append({"source": {"kind": "table", "elementId": "master-pf-8a884102"}, "columnId": "mc-x"})
        spec = os.path.join(self.d, "target-spec.json")
        jdump(built, spec)
        rep = os.path.join(self.d, "target-report.json")
        self.assertEqual(gate.main(["--spec", spec, "--page-facts", self.pf, "--model", os.path.join(FIX, "model.bim"),
                                    "--dm-spec", self.dm, "--master-map", self.mm, "--connection", CONN, "--report", rep]), 0)
        el = next(e for e in jload(spec)["document"]["elements"] if e["id"] == "el-regiondf813b")
        targets = [f["source"]["elementId"] for f in el["filters"]]
        self.assertNotIn("master-pf-8a884102", targets)
        self.assertFalse([t for t in targets if t.startswith("pfu-") or t.startswith("master-pf-")], targets)
        self.assertIn("master-store", targets, "targets on other masters are kept")
        g = next(x for p in jload(rep)["pages"] for x in p["gated"] if x["control"] == "RegionFilter")
        self.assertIn("page_fact_target", g)

    def test_visual_and_page_filters(self):
        pf = jload(os.path.join(self.pf, "stock-cover", "page-fact.json"))
        self.assertEqual(pf["sql"].count("IN ('Acme', 'Globex')"), 2, "the page's Supplier filter sits in both fact CTEs")
        bar = self.E["el-v1bard1ac7f"]
        self.assertEqual([f["mode"] for f in bar.get("filters") or []], ["exclude"], "the visual filter is on the element")
        checks = jload(os.path.join(self.pf, "sales-overview", "check-queries.json"))
        self.assertIn('NOT COALESCE(("G_REGION" IS NULL), FALSE)', checks["sales-overview__el-v1bard1ac7f"])

    def test_one_hop_slicer_matches_oracle(self):
        self.check_scenario("Stock Cover", "stock-cover", {"RegionFilter": ["West"]}, "Store.Region=West")

    def test_two_hop_blank_member_matches_oracle(self):
        self.check_scenario("Stock Cover", "stock-cover", {"ManagerNameFilter2": ["(Blank)"]}, "Manager.Manager Name=(Blank)")

    def test_bridge_slicer_matches_oracle(self):
        self.check_scenario("Rollup", "rollup", {"SupplierNameFilter2": ["Acme"]}, "Supplier.Supplier Name=Acme")

    def test_neutral_render_equals_page_fact(self):
        v = jload(os.path.join(self.d, "slicer-gate-verify.json"))
        for k in [x for x in v if x.endswith("__neutral")]:
            self.assertEqual(rows(self.con, v[k]), rows(self.con, v[k.replace("__neutral", "__page_fact")]), k)
        res = {k: {"ok": True, "rows": rows(self.con, q)} for k, q in v.items()}
        jdump(res, os.path.join(self.d, "slicer-gate-verify-results.json"))
        self.assertEqual(parity.main(["--spec", os.path.join(self.d, "slicer-gate-verify-plan.json"),
                                      "--out-dir", os.path.join(self.d, "verify-out")]), 0)

    def test_default_view_is_empty_on_the_param_branch(self):
        b = self.E[self.page("Stock Cover")["parameterized"]]["source"]["statement"]
        self.assertEqual(rows(self.con, "\n".join(l for l in render(b, {}).split("\n") if not l.startswith("-- "))), [],
                         "with every control empty the gate closes the parameterized branch")

    def test_page_without_hooks_is_skipped_with_a_reason(self):
        pfj = jload(os.path.join(self.pf, "stock-cover", "page-fact.json"))
        pfj["sql"] = re.sub(r"/\*@slicers.*?\*/", "", pfj["sql"])
        d = os.path.join(self.d, "nohook", "stock-cover")
        os.makedirs(d)
        jdump(pfj, os.path.join(d, "page-fact.json"))
        dm = os.path.join(self.d, "dm-nohook.json")
        shutil.copy(self.dm, dm)
        # the DM still holds the hooked SQL; drop it so the hook-less page-fact SQL is the one used
        spec = jload(dm)
        spec["pages"][0]["elements"] = [e for e in spec["pages"][0]["elements"] if e["name"] != "Stock Cover Page Fact"]
        jdump(spec, dm)
        out = os.path.join(self.d, "nohook-spec.json")
        rep = os.path.join(self.d, "nohook-report.json")
        rc = gate.main(["--spec", os.path.join(self.d, "built.json"), "--page-facts", os.path.dirname(d),
                        "--model", os.path.join(FIX, "model.bim"), "--dm-spec", dm, "--master-map", self.mm,
                        "--connection", CONN, "--out", out, "--report", rep])
        self.assertEqual(rc, 0, "one page without hooks is skipped, not a whole-run abort")
        page = jload(rep)["pages"][0]
        self.assertEqual((page["gated"], len(page["skipped"])), ([], 1))
        self.assertIn("no /*@slicers", page["skipped"][0]["reason"])
        self.assertEqual(jload(out), jload(os.path.join(self.d, "built.json")), "nothing changed on that page")


if __name__ == "__main__":
    unittest.main(verbosity=1)
