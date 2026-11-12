#!/usr/bin/env python3
"""Offline tests for lib/pbi_page_closure.py and scaffold-page-fact.py.

The synthetic retail fixture (fixtures/page-facts: invented names, SQLite seed) has three pages:
a single-fact page, a two-fact pivot, and a USERELATIONSHIP bridge page. Every generated query
is EXECUTED in SQLite, so the page fact is checked against the independent oracle on real rows,
and both against hand-computed values (the bridge path, the (Blank) member, CALCULATE that
replaces a grouping filter, a saved slicer selection).

Run: python3 scripts/test-page-fact-scaffold.py   (exit 0 = pass)
"""
import importlib.util
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "..", "fixtures", "page-facts")
sys.path.insert(0, os.path.join(HERE, "lib"))
import pbi_page_closure as pc  # noqa: E402


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
parity = load("parity_from_oracle", "parity-from-oracle.py")


def fixture(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


def sqlite_db():
    db = sqlite3.connect(":memory:")
    db.create_function("EQUAL_NULL", 2, lambda a, b: 1 if (a is None and b is None) or (a is not None and a == b) else 0,
                       deterministic=True)
    with open(os.path.join(FIX, "seed.sql"), encoding="utf-8") as f:
        db.executescript(f.read())
    return db


def rows(db, sql):
    cur = db.execute(sql)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


class ModelAndPaths(unittest.TestCase):
    def setUp(self):
        self.m = pc.Model(fixture("model.bim"))

    def test_comments_stripped_and_closure_is_dependency_first(self):
        self.assertNotIn("--", self.m.measures["Gross Margin"]["expression"])
        order = self.m.closure(["Margin %"])
        self.assertEqual(order, ["Sales Amount", "Sales Cost", "Gross Margin", "Margin %"])

    def test_measure_info_flags(self):
        info = self.m.measure_info("Rollup Sales")
        self.assertEqual(info["userelationship"], [(("Rollup", "Child Product Key"), ("Sales", "Product Key"))])
        self.assertEqual(self.m.measure_info("Prior Year Amount")["time_intel"], ["SAMEPERIODLASTYEAR"])
        self.assertEqual(self.m.measure_info("Weeks of Cover")["measure_refs"], ["On Hand", "Units"])
        self.assertEqual(self.m.measure_info("Orders")["scans"], ["Sales"])

    def test_query_refs(self):
        self.assertEqual(pc.parse_query_ref(self.m, "Sales.Sales Amount")["kind"], "measure")
        self.assertEqual(pc.parse_query_ref(self.m, "Store.Region")["kind"], "column")
        imp = pc.parse_query_ref(self.m, "Sum(Sales.Qty)")
        self.assertEqual((imp["kind"], imp["agg"], imp["column"]), ("implicit", "SUM", "Qty"))

    def test_direct_path_without_activation(self):
        g = pc.FilterGraph(self.m)
        p, info = g.best_path("Product", "Sales")
        self.assertEqual([h[1] for h in p], ["Product"])  # one hop, the active Product -> Sales relationship
        self.assertEqual(info["candidates"], 1)  # the bridge relationship is inactive

    def test_userelationship_bridge_wins_by_path_weight(self):
        act = [(("Rollup", "Child Product Key"), ("Sales", "Product Key"))]
        g = pc.FilterGraph(self.m, act)
        p, info = g.best_path("Product", "Sales")
        self.assertEqual([h[1] for h in p], ["Product", "Rollup"], "filters go Product -> Rollup -> Sales")
        self.assertEqual((info["candidates"], info["tier"], info["weight"]), (2, 1, 1))
        self.assertTrue(info["chosen_over"], "the direct path is reported as the loser")
        p2, _ = g.best_path("Supplier", "Sales")
        self.assertEqual([h[1] for h in p2], ["Supplier", "Product", "Rollup"])

    def test_two_hop_and_unreachable(self):
        g = pc.FilterGraph(self.m)
        p, _ = g.best_path("Manager", "Stock")
        self.assertEqual([h[1] for h in p], ["Manager", "Store"])
        p, info = g.best_path("Sales", "Manager")
        self.assertIsNone(p)
        self.assertIn("no active relationship path", info["reason"])

    def test_ambiguous_equal_weight_paths_are_refused(self):
        doc = {"model": {"tables": [{"name": n, "columns": [{"name": "K"}, {"name": "A"}, {"name": "B"}]} for n in "DXYF"],
                         "relationships": [
                             {"fromTable": "X", "fromColumn": "A", "toTable": "D", "toColumn": "K"},
                             {"fromTable": "Y", "fromColumn": "A", "toTable": "D", "toColumn": "K"},
                             {"fromTable": "F", "fromColumn": "A", "toTable": "X", "toColumn": "K"},
                             {"fromTable": "F", "fromColumn": "B", "toTable": "Y", "toColumn": "K"}]}}
        p, info = pc.FilterGraph(pc.Model(doc)).best_path("D", "F")
        self.assertIsNone(p)
        self.assertTrue(info["ambiguous"])
        self.assertEqual(len(info["paths"]), 2)

    def test_priority_tiers(self):
        self.assertEqual(pc.FilterGraph.tier(["1:M", "1:M"]), 1)
        self.assertEqual(pc.FilterGraph.tier(["1:M", "M:M"]), 2)
        self.assertEqual(pc.FilterGraph.tier(["M:1"]), 3)
        self.assertEqual(pc.FilterGraph.tier(["1:M", "M:1"]), 4)
        self.assertEqual(pc.FilterGraph.tier(["M:1", "1:M"]), 6)

    def test_source_index_warehouse_path_and_columns(self):
        dm = {"pages": [{"elements": [{"id": "e1", "name": "Store", "source": {"kind": "warehouse-table", "path": ["DB", "Sch", "STORE"]},
                                       "columns": [{"id": "inode-1/STORE_KEY", "formula": "[STORE/Store Key]"}]}]}]}
        src = pc.SourceIndex(self.m, dm)
        self.assertEqual(src.from_sql("Store"), 'DB."Sch".STORE')
        self.assertEqual(src.column("Store", "Store Key"), ('"STORE_KEY"', "exact"))
        self.assertEqual(src.column("Store", "Region")[1], "assumed")

    def test_semi_join_blank_terms_only_on_one_to_many_hops(self):
        src = pc.SourceIndex(self.m, fixture("dm-spec.json"), fixture("master-map.json"))
        p, _ = pc.FilterGraph(self.m).best_path("Manager", "Sales")
        sql = pc.semi_join(src, p, '"MANAGER_NAME"', "f", "{{Ctl}}", blank=True)
        self.assertEqual(sql.count("'(Blank)' IN {{Ctl}}"), 2, "one blank term per one-to-many hop")
        self.assertIn("COALESCE(CAST(sj2.\"MANAGER_NAME\" AS VARCHAR), '(Blank)') IN {{Ctl}}", sql)
        plain = pc.semi_join(src, p, '"MANAGER_NAME"', "f", "{{Ctl}}", blank=False)
        self.assertNotIn("(Blank)", plain)
        self.assertIn("CAST(sj2.\"MANAGER_NAME\" AS STRING)", pc.semi_join(src, p, '"MANAGER_NAME"', "f", "x", False, "databricks"))

    def test_element_id_matches_the_builder(self):
        self.assertEqual(pc.element_id_for_visual("s2_region"), "el-regiondf813b")
        self.assertEqual(pc.element_id_for_visual("v3_bar"), "el-v3bar9e48b7")  # shorter than 6 chars: kept whole


class Decomposition(unittest.TestCase):
    MODEL = {"model": {"tables": [
        {"name": "F", "columns": [{"name": "K", "dataType": "int64"}, {"name": "V", "dataType": "double"},
                                  {"name": "Flag", "dataType": "string"}],
         "measures": [
             {"name": "Total", "expression": "SUM(F[V])"},
             {"name": "Var Ratio", "expression": ["VAR t = [Total]", "VAR n = COUNTROWS(F)", "RETURN DIVIDE(t, n)"]},
             {"name": "Unsafe Var", "expression": 'VAR t = [Total] RETURN CALCULATE(t, D[Name] = "x")'},
             {"name": "Not In", "expression": 'CALCULATE([Total], NOT D[Name] IN {"x", "y"})'},
             {"name": "In And Ge", "expression": 'CALCULATE([Total], D[Name] IN {"x", "y"}, D[K] >= 3)'},
             {"name": "Blank Flag", "expression": "CALCULATE([Total], ISBLANK(F[Flag]))"},
             {"name": "Avg V", "expression": "AVERAGE(F[V])"},
             {"name": "Line", "expression": "SUMX(F, F[V] * RELATED(D[K]))"},
             {"name": "Branch", "expression": "IF([Total] > 0, 1, 0)"},
             {"name": "West", "expression": 'CALCULATE([Total], D[Name] = "west")'},
             {"name": "East Over West", "expression": 'CALCULATE([West], D[Name] = "east")'},
             {"name": "Keep East", "expression": 'CALCULATE([West], KEEPFILTERS(D[Name] = "east"))'},
             {"name": "West Keep", "expression": 'CALCULATE([Total], KEEPFILTERS(D[Name] = "west"))'},
             {"name": "East Then Keep West", "expression": 'CALCULATE([West Keep], D[Name] = "east")'},
             {"name": "Both", "expression": 'CALCULATE([Total], D[Name] = "a", D[Name] = "b")'},
             {"name": "Gap", "expression": "[Total] - [Line]"},
             {"name": "Bad Ur", "expression": "CALCULATE([Total], USERELATIONSHIP(F[Flag], D[Name]))"},
             {"name": "Noted", "expression": "CALCULATE([Total], Notes[N] = 1)"}]},
        {"name": "Notes", "columns": [{"name": "N", "dataType": "int64"}]},
        {"name": "D", "columns": [{"name": "K", "dataType": "int64"}, {"name": "Name", "dataType": "string"}]}],
        "relationships": [{"fromTable": "F", "fromColumn": "K", "toTable": "D", "toColumn": "K"}]}}

    def setUp(self):
        self.m = pc.Model(self.MODEL)
        self.dec = scaffold.Decomposer(self.m, [], "snowflake")

    def comps(self):
        return {self.dec.components[k]["out"]: self.dec.components[k] for k in self.dec.order}

    def test_var_inlining(self):
        sig, _sql, _u = self.dec.measure("Var Ratio")
        self.assertEqual(sig, "If(IsNull(Sum({C:Rows F})) or Sum({C:Rows F}) = 0, Null, Sum({C:Sum V}) / Sum({C:Rows F}))")

    def test_var_names_are_case_insensitive(self):
        self.assertEqual(pc.inline_vars("VAR total = [Total] RETURN DIVIDE(Total, TOTAL)"),
                         "DIVIDE(([Total]), ([Total]))")
        with self.assertRaisesRegex(pc.Unsupported, "inside CALCULATE"):
            pc.inline_vars("VAR total = [Total] RETURN CALCULATE(TOTAL)")

    def test_var_inside_calculate_is_refused(self):
        with self.assertRaisesRegex(pc.Unsupported, "inside CALCULATE"):
            self.dec.measure("Unsafe Var")

    def test_escaped_apostrophe_in_quoted_table_name(self):
        expr = "CALCULATE(SUM('O''Brien, (North)'[V]), USERELATIONSHIP('O''Brien, (North)'[K], D[K]))"
        args = pc.calls(expr, "CALCULATE")
        self.assertEqual(args, [["SUM('O''Brien, (North)'[V])",
                                 "USERELATIONSHIP('O''Brien, (North)'[K], D[K])"]])
        use = "SUM('O''Brien x'[V]) + X"
        self.assertEqual(pc._var_uses(use, "x"), [use.rfind("X")])
        self.assertEqual(pc.inline_vars("VAR total = SUM('O''Brien'[V]) RETURN Total"),
                         "(SUM('O''Brien'[V]))")

    def test_in_lists_not_and_isblank(self):
        self.dec.measure("Not In")
        self.dec.measure("In And Ge")
        self.dec.measure("Blank Flag")
        f = [c["filters"] for c in self.comps().values()]
        self.assertIn(("NOT (UPPER(COALESCE(CAST({T:D|Name} AS VARCHAR), '')) IN (UPPER('x'), UPPER('y')))",), f)
        self.assertIn(("COALESCE({T:D|K}, 0) >= 3", "UPPER(COALESCE(CAST({T:D|Name} AS VARCHAR), '')) IN (UPPER('x'), UPPER('y'))"), f)
        self.assertIn(("{T:F|Flag} IS NULL",), f)

    def filters_of(self, name):
        _sig, _sql, used = self.dec.measure(name)
        return sorted(self.dec.components[k]["filters"] for k in used)

    def test_inner_calculate_replaces_outer_filter_on_the_same_column(self):
        west = "UPPER(COALESCE(CAST({T:D|Name} AS VARCHAR), '')) = UPPER('west')"
        east = "UPPER(COALESCE(CAST({T:D|Name} AS VARCHAR), '')) = UPPER('east')"
        self.assertEqual(self.filters_of("East Over West"), [(west,)], "DAX: the inner West filter wins")
        self.assertEqual(self.filters_of("Keep East"), [(west,)],
                         "an inner non-KEEPFILTERS filter overwrites the column's filter, however it was set")
        self.assertEqual(self.filters_of("East Then Keep West"), [tuple(sorted((east, west)))],
                         "an inner KEEPFILTERS intersects with the outer filter")
        self.assertEqual(len(self.filters_of("Both")[0]), 2, "two filters in ONE CALCULATE intersect")

    def test_calculate_on_a_slicer_or_filter_column_is_a_todo(self):
        dec = scaffold.Decomposer(self.m, [], "snowflake", {("D", "Name"): "the column of the 'Name' slicer"})
        with self.assertRaisesRegex(pc.Unsupported, "the column of the 'Name' slicer"):
            dec.measure("West")

    def test_blank_counts_as_zero_in_plus_and_minus(self):
        sig, sql, _u = self.dec.measure("Gap")
        self.assertTrue(sig.startswith("If(IsNull(Sum({C:Sum V})) and IsNull("), sig)
        self.assertIn("Coalesce(Sum({C:Sum V}), 0) - Coalesce(", sig)
        self.assertIn("ELSE COALESCE(", sql)

    def test_unresolved_userelationship_and_not_prefix(self):
        with self.assertRaisesRegex(pc.Unsupported, "names no relationship"):
            self.dec.measure("Bad Ur")
        f = self.filters_of("Noted")  # a table named Notes... is a column filter, never NOT(...)
        self.assertEqual(f, [("COALESCE({T:Notes|N}, 0) = 1",)])

    def test_average_sumx_and_unsupported(self):
        sig, _s, _u = self.dec.measure("Avg V")
        self.assertIn("Sum({C:Count V})", sig)
        sig, _s, _u = self.dec.measure("Line")
        self.assertTrue(any(c["row"] == "({T:F|V} * {T:D|K})" for c in self.comps().values()))
        with self.assertRaisesRegex(pc.Unsupported, "IF"):
            self.dec.measure("Branch")


class Scaffold(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.d = tempfile.mkdtemp(prefix="pf-scaffold-")
        cls.out = os.path.join(cls.d, "pf")
        rc = scaffold.main(["--model", os.path.join(FIX, "model.bim"), "--signals", os.path.join(FIX, "signals.json"),
                            "--dm-spec", os.path.join(FIX, "dm-spec.json"), "--master-map", os.path.join(FIX, "master-map.json"),
                            "--out-dir", cls.out, "--all-pages", "--scenario", "Supplier.Supplier Name=Acme",
                            "--scenario", "Manager.Manager Name=(Blank)"])
        assert rc == 0
        cls.db = sqlite_db()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.d, ignore_errors=True)

    def j(self, page, name):
        with open(os.path.join(self.out, page, name), encoding="utf-8") as f:
            return json.load(f)

    def test_classification(self):
        s = jload(os.path.join(self.out, "page-closure.json"))
        cls = {p["page"]: p for p in s["pages"]}
        self.assertEqual(cls["Sales Overview"]["classification"], "per-visual")
        self.assertEqual(cls["Stock Cover"]["classification"], "page-fact")
        self.assertIn("several facts", cls["Stock Cover"]["reasons"][0])
        self.assertTrue(any("USERELATIONSHIP" in r for r in cls["Rollup"]["reasons"]))
        self.assertEqual(cls["Stock Cover"]["gated_slicers"], ["Region", "Manager"])

    def test_default_selection_scaffolds_only_page_fact_pages(self):
        out = os.path.join(self.d, "auto")
        scaffold.main(["--model", os.path.join(FIX, "model.bim"), "--signals", os.path.join(FIX, "signals.json"),
                       "--dm-spec", os.path.join(FIX, "dm-spec.json"), "--out-dir", out])
        self.assertEqual(sorted(x for x in os.listdir(out) if os.path.isdir(os.path.join(out, x))), ["rollup", "stock-cover"])

    def test_page_fact_shape(self):
        pf = self.j("stock-cover", "page-fact.json")
        sql = pf["sql"]
        self.assertEqual(sql.count("/*@slicers"), 2, "one hook per fact")
        self.assertIn("UNION ALL", sql)
        self.assertEqual([c["name"] for c in pf["columns"] if c["role"] == "grain"], ["Category", "Store Name"])
        self.assertEqual(pf["fields"]["Stock.Weeks of Cover"]["ref"],
                         "If(IsNull(Sum({C:Sum Qty})) or Sum({C:Sum Qty}) = 0, Null, Sum({C:Sum On Hand}) / Sum({C:Sum Qty}))")
        self.assertEqual(pf["fields"]["Sum(Sales.Qty)"]["ref"], "Sum({C:Sum Qty})", "implicit aggregate shares the component")
        self.assertEqual(pf["dims"], {"Product.Category": "Category", "Store.Store Name": "Store Name"})
        self.assertEqual([s["in_grain"] for s in pf["slicers"]], [False, False])

    def test_userelationship_page_joins_through_the_bridge(self):
        pf = self.j("rollup", "page-fact.json")
        self.assertIn('LEFT JOIN pfs_rollup j1 ON j1."CHILD_PRODUCT_KEY" = f."PRODUCT_KEY"', pf["sql"])
        self.assertIn('LEFT JOIN pfs_product j2 ON j2."PRODUCT_KEY" = j1."PARENT_PRODUCT_KEY"', pf["sql"])
        self.assertIn("userelationship=\"'Rollup'[Child Product Key]|'Sales'[Product Key]\"", pf["sql"])
        self.assertEqual([t["measure"] for t in pf["todo"]], ["Orders"])
        self.assertIn("DISTINCTCOUNT", pf["todo"][0]["reason"])
        self.assertTrue(pf["fields"]["Sales.Orders"]["todo"])

    def test_calculate_over_a_grain_column_is_a_todo(self):
        pf = self.j("sales-overview", "page-fact.json")
        todo = {t["measure"]: t["reason"] for t in pf["todo"]}
        self.assertIn("West Sales", todo)
        self.assertIn("replaces the filter on Store[Region]", todo["West Sales"])

    def test_brief_lists_paths_and_todos(self):
        md = read(os.path.join(self.out, "rollup", "closure.md"))
        self.assertIn("USERELATIONSHIP", md)
        self.assertIn("chose the higher-weight path", md)
        self.assertIn("TODO Orders", md)
        self.assertIn("```dax", md)

    def run_page(self, page):
        res = {}
        for fn in ("check-queries.json", "oracle-queries.json"):
            for k, q in self.j(page, fn).items():
                res.setdefault(fn, {})[k] = {"ok": True, "rows": rows(self.db, q)}
        pdir = os.path.join(self.out, page)
        jdump(res["check-queries.json"], os.path.join(pdir, "check-results.json"))
        jdump(res["oracle-queries.json"], os.path.join(pdir, "oracle-results.json"))
        return res

    def test_page_fact_matches_the_independent_oracle_on_every_page(self):
        for page in ("sales-overview", "stock-cover", "rollup"):
            self.run_page(page)
            od = os.path.join(self.d, "check-" + page)
            rc = parity.main(["--spec", os.path.join(self.out, page, "check-plan.json"), "--out-dir", od])
            final = jload(os.path.join(od, "parity-final.json"))
            self.assertEqual((rc, final["status"]), (0, "PASS"), "%s: %s" % (page, final["fail_names"]))
            self.assertGreater(final["charts_total"], 0)

    def test_hand_computed_values(self):
        o = self.run_page("rollup")["oracle-queries.json"]
        so = self.run_page("sales-overview")["oracle-queries.json"]
        self.assertNotIn(None, [r["Region"] for r in so["sales-overview__el-v1bard1ac7f"]["rows"]],
                         "the bar's own 'Region is not blank' filter reaches the oracle")
        self.assertIn(None, [r["Region"] for r in so["sales-overview__el-1pivot0b579d"]["rows"]], "and only that visual")
        bar = {r["Category"]: r["Rollup Sales"] for r in o["rollup__el-v3bar9e48b7"]["rows"]}
        # through the bridge every Widget/Gadget/Kit sale rolls up to "Kits"; the NULL category and the
        # product missing from the bridge are the (Blank) row. The direct path would give Hardware 165.
        self.assertEqual(bar, {"Kits": 215.0, None: 17.0})
        self.assertEqual(o["rollup__el-3units580f24@Supplier.Supplier Name=Acme"]["rows"], [{"Rollup Units": 14.0}])
        self.assertEqual(o["rollup__el-orders2a2694@Supplier.Supplier Name=Acme"]["rows"], [{"Orders": 4}],
                         "a measure without USERELATIONSHIP keeps the direct path")
        s = self.run_page("sales-overview")["oracle-queries.json"]
        piv = {r["Region"]: r for r in s["sales-overview__el-1pivot0b579d"]["rows"]}
        self.assertEqual(piv["North"]["Sales Amount"], 80.0, "the saved Year = 2026 selection drops the 2025 sale")
        self.assertTrue(all(r["West Sales"] == 100.0 for r in piv.values()), "CALCULATE replaces the Region filter")
        sp = self.run_page("sales-overview")["check-queries.json"]
        north = next(r for r in sp["sales-overview__el-1pivot0b579d"]["rows"] if r["Region"] == "North")
        # check queries carry only the defaults the UNGATED page fact can apply (Year is gated on this page),
        # so North includes its 2025 sale: (90 - 53) / 7
        self.assertAlmostEqual(north["Margin per Unit"], (90.0 - 53.0) / 7.0, msg="VAR m, u inlined into DIVIDE(m, u)")
        sc = self.run_page("stock-cover")["check-queries.json"]
        self.assertEqual(sc["stock-cover__el-signed970db8"]["rows"], [{"Unassigned Stock": 7.0}],
                         "ISBLANK(Store[Manager Key]): the store with no manager; the stock row with no store is "
                         "a product with no supplier, which the page's Supplier filter removes")
        c = self.run_page("stock-cover")["oracle-queries.json"]
        blank_mgr = {r["Category"]: r["On Hand"] for r in c["stock-cover__el-2pivot161ea1@Manager.Manager Name=(Blank)"]["rows"]}
        # (Blank) manager = stores whose manager has no name (12), stores without a manager (13), and
        # stock rows with no store at all (here only the no-supplier "Parts" product, which the page's
        # Supplier filter removes)
        self.assertEqual(blank_mgr, {"Hardware": 15.0, None: 7.0})

    def test_slicer_in_grain_only_when_every_fact_reaches_it(self):
        sig = fixture("signals.json")
        p2 = next(p for p in sig["pages"] if p["page_title"] == "Stock Cover")
        p2["visuals"].append({"visual_id": "v2_parent", "visual_type": "clusteredColumnChart", "sigma_kind": "bar",
                              "title": "Units by Parent", "bindings": {"Category": ["Rollup.Parent Product Key"],
                                                                      "Y": ["Sales.Units"]}})
        p2["visuals"].append({"visual_id": "s2_parent", "visual_type": "slicer", "sigma_kind": "control", "title": "Parent",
                              "bindings": {"Values": ["Rollup.Parent Product Key"]}})
        d = os.path.join(self.d, "grain-reach")
        os.makedirs(d)
        jdump(sig, os.path.join(d, "signals.json"))
        scaffold.main(["--model", os.path.join(FIX, "model.bim"), "--signals", os.path.join(d, "signals.json"),
                       "--dm-spec", os.path.join(FIX, "dm-spec.json"), "--out-dir", d, "--page", "Stock Cover"])
        sl = {s["title"]: s for s in jload(os.path.join(d, "stock-cover", "page-fact.json"))["slicers"]}
        self.assertFalse(sl["Parent"]["in_grain"], "Stock cannot reach Rollup: a direct grain filter would drop its rows")
        self.assertFalse(sl["Region"]["in_grain"])

    def test_calculate_on_a_gated_slicer_column_is_a_todo(self):
        model, sig = fixture("model.bim"), fixture("signals.json")
        stock = next(t for t in model["model"]["tables"] if t["name"] == "Stock")
        stock["measures"].append({"name": "Regionless Stock", "expression": "CALCULATE([On Hand], ISBLANK(Store[Region]))"})
        p2 = next(p for p in sig["pages"] if p["page_title"] == "Stock Cover")
        p2["visuals"].append({"visual_id": "v2_regionless", "visual_type": "card", "sigma_kind": "kpi",
                              "title": "Regionless", "bindings": {"Values": ["Stock.Regionless Stock"]}})
        d = os.path.join(self.d, "slicer-guard")
        os.makedirs(d)
        jdump(model, os.path.join(d, "model.bim"))
        jdump(sig, os.path.join(d, "signals.json"))
        scaffold.main(["--model", os.path.join(d, "model.bim"), "--signals", os.path.join(d, "signals.json"),
                       "--dm-spec", os.path.join(FIX, "dm-spec.json"), "--out-dir", d, "--page", "Stock Cover"])
        todo = {t["measure"]: t["reason"] for t in jload(os.path.join(d, "stock-cover", "page-fact.json"))["todo"]}
        # Power BI: the CALCULATE replaces the Region slicer's filter; the gate would intersect them
        self.assertIn("the column of the 'Region' slicer", todo.get("Regionless Stock", ""))

    def test_check_plan_skips_todo_measures(self):
        plan = self.j("sales-overview", "check-plan.json")
        detail = next(c for c in plan["charts"] if c["name"].startswith("Region Detail"))
        self.assertEqual(detail["measures"], ["Sales Amount", "Gross Margin", "Margin per Unit"])
        pplan = self.j("sales-overview", "parity-plan.json")
        self.assertIn("West Sales", next(c for c in pplan["charts"] if c["name"] == "Region Detail")["measures"],
                      "the workbook parity plan still checks the TODO measure once it is built")

    def test_dialects(self):
        out = os.path.join(self.d, "dbx")
        scaffold.main(["--model", os.path.join(FIX, "model.bim"), "--signals", os.path.join(FIX, "signals.json"),
                       "--dm-spec", os.path.join(FIX, "dm-spec.json"), "--out-dir", out, "--page", "Rollup",
                       "--dialect", "databricks"])
        oq = jload(os.path.join(out, "rollup", "oracle-queries.json"))
        self.assertTrue(oq and all("EQUAL_NULL(" not in q for q in oq.values()))
        out = os.path.join(self.d, "bq")
        scaffold.main(["--model", os.path.join(FIX, "model.bim"), "--signals", os.path.join(FIX, "signals.json"),
                       "--dm-spec", os.path.join(FIX, "dm-spec.json"), "--out-dir", out, "--page", "Rollup",
                       "--dialect", "bigquery"])
        self.assertEqual(jload(os.path.join(out, "rollup", "oracle-queries.json")), {})
        self.assertIn("FLOAT64", read(os.path.join(out, "rollup", "page-fact.sql")))


class WriterLineEndings(unittest.TestCase):
    """The corpus case byte-compares these scripts' outputs with LF goldens. On Windows a text-mode
    open(..., "w") writes CRLF, so every write must pass newline="\\n" (checked in the source: CI's
    Windows job is the only place the difference would show)."""

    def test_every_text_write_is_lf(self):
        import ast
        for name in ("scaffold-page-fact.py", "integrate-page-fact.py", "wire-slicer-gate.py"):
            tree = ast.parse(read(os.path.join(HERE, name)))
            for node in ast.walk(tree):
                if not (isinstance(node, ast.Call) and getattr(node.func, "id", None) == "open"):
                    continue
                mode = node.args[1].value if len(node.args) > 1 and isinstance(node.args[1], ast.Constant) else \
                    next((k.value.value for k in node.keywords if k.arg == "mode"), "r")
                if "w" not in mode or "b" in mode:
                    continue
                nl = next((k.value.value for k in node.keywords if k.arg == "newline" and isinstance(k.value, ast.Constant)), None)
                self.assertEqual(nl, "\n", "%s:%d writes text without newline='\\n'" % (name, node.lineno))


class ParityJsonExport(unittest.TestCase):
    def test_json_export_side(self):
        d = tempfile.mkdtemp()
        try:
            a = os.path.join(d, "a.json")
            jdump({"k": {"ok": True, "rows": [{"K": "x", "V": 1.0}, {"K": None, "V": 2}]}}, a)
            b = os.path.join(d, "b.json")
            jdump({"k": {"ok": True, "rows": [{"K": "x", "V": 1}, {"K": None, "V": 2.0}]}}, b)
            plan = os.path.join(d, "plan.json")
            jdump({"charts": [{"name": "c", "export": "a.json", "export_key": "k", "oracle": "b.json", "oracle_key": "k",
                               "keys": ["K"]}]}, plan)
            self.assertEqual(parity.main(["--spec", plan, "--out-dir", d]), 0)
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
