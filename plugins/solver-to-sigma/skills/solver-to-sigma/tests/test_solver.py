#!/usr/bin/env python3
"""Offline tests for solver-to-sigma (stdlib unittest; synthetic fixtures only).

    python3 plugins/solver-to-sigma/skills/solver-to-sigma/tests/test_solver.py
"""
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "pnl-smoke")
sys.path.insert(0, SCRIPTS)

import solver_compile as C  # noqa: E402
import solver_def as S  # noqa: E402
import solver_sql as Q  # noqa: E402


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(SCRIPTS, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


TEMPLATE = os.path.join(FIX, "pnl-template.xlsx")
RUN = os.path.join(FIX, "pnl-executed-run.xlsx")
with open(os.path.join(FIX, "source-map.json")) as _fh:
    SM = json.load(_fh)


def plan():
    return C.compile_report(S.load(TEMPLATE), SM)


def facts():
    return {"GL_F_Trans": C.read_facts_csv(os.path.join(FIX, "gl.csv"))}


def rewrite_xlsx(src, dst, sheet=None, definition=None):
    """Copy an .xlsx, editing the sheet XML and/or the (UTF-16) definition with str -> str functions."""
    with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w", zipfile.ZIP_STORED) as zo:
        for item in zi.infolist():
            data = zi.read(item.filename)
            if sheet and item.filename == "xl/worksheets/sheet1.xml":
                data = sheet(data.decode("utf-8")).encode("utf-8")
            if definition and item.filename == "customXml/item1.xml":
                data = definition(data.decode("utf-16")).encode("utf-16")
            zo.writestr(item, data)


def roundtrip(x):
    return json.loads(json.dumps(x))


def export_rows(p, vals, sheet="Summary"):
    """What a Sigma export of the rebuilt report table looks like: Line + one key per column display name."""
    s = next(x for x in p["sheets"] if x["name"] == sheet)
    _, display = Q.column_names(s)
    return [dict({"Line": ln["label"]}, **{display[L]: v for L, v in vals[sheet]["lines"][str(ln["row"])].items()})
            for ln in s["lines"]]


class Extract(unittest.TestCase):
    def test_manifest_is_refused_without_opening(self):
        with self.assertRaises(S.NotADefinition) as cm:
            S.load("/nonexistent/report.xlsx.manifest")
        self.assertIn("session AuthenticationToken", str(cm.exception))

    def test_definition_and_layout(self):
        ir = S.load(TEMPLATE)
        self.assertEqual([p["name"] for p in ir["parameters"]], ["Period", "Actual Scenario", "Budget Scenario", "Location"])
        self.assertTrue(ir["parameters"][0]["is_period"])
        sh = ir["sheets"][0]
        self.assertEqual(sh["name"], "Summary")
        types = sorted({i["type"] for i in sh["items"]})
        self.assertEqual(types, ["Cell", "Column", "Report", "Row"])
        self.assertEqual(sh["cells"]["B6"]["v"], "Revenue")
        self.assertTrue(any("_xll.OneStop" in (i["formula"] or "") for i in sh["items"]))

    def test_executed_run_carries_no_definition(self):
        with self.assertRaises(S.NotADefinition):
            S.load(RUN)
        self.assertAlmostEqual(S.run_values(RUN)["Summary"]["D6"], 328837.26, places=2)


class Periods(unittest.TestCase):
    def test_windows(self):
        i = C.yyyymm_to_idx(202609)
        w = lambda fn, fy=1: tuple(C.idx_to_yyyymm(x) for x in C.period_window(fn, fy)(i))
        self.assertEqual(w("TPTY"), (202609, 202609))
        self.assertEqual(w("TPLY"), (202509, 202509))
        self.assertEqual(w("YTD"), (202601, 202609))
        self.assertEqual(w("LYTD"), (202501, 202509))
        self.assertEqual(w("QTD"), (202607, 202609))
        self.assertEqual(w("QTDLY"), (202507, 202509))
        self.assertEqual(w("YTD", 7), (202607, 202609))          # fiscal year starting in July
        self.assertEqual(w("QTD", 2), (202608, 202609))          # quarters shift with the fiscal start
        self.assertEqual(w("RBC12M"), (202510, 202609))
        self.assertEqual(w("R3MLY"), (202507, 202509))
        with self.assertRaises(C.Unsupported):
            C.period_window("WTD")

    def test_sql_twin_agrees_with_python(self):
        def run_sql(expr):
            py = expr.replace("FLOOR(", "_floor(").replace("MOD(", "_mod(")
            return eval(py, {"_floor": math.floor, "_mod": lambda a, b: a % b})
        r = Q.Renderer({"sheets": [], "parameters": []}, {})
        for fy in (1, 2, 4, 7, 10, 12):
            r.fy = fy
            for p in (202601, 202602, 202606, 202609, 202612):
                i = C.yyyymm_to_idx(p)
                for fn in ("TPTY", "TPLY", "YTD", "LYTD", "QTD", "QTDLY", "R12M", "RBC6MLY"):
                    lo, hi = r.window(fn, str(i))
                    self.assertEqual((run_sql(lo), run_sql(hi)), C.period_window(fn, fy)(i), (fn, fy, p))


class Conditions(unittest.TestCase):
    params = [{"name": "Scn", "default": "ACT, BUD"}, {"name": "Loc", "default": "*"}, {"name": "Alias", "default": "{@Scn}"}]

    def ok(self, pred, row):
        return C.eval_pred(pred, row, self.params, {})

    def test_list_range_param_wildcard(self):
        g = C.group_pred([{"dim": "d_Account", "field": "Code", "op": "In", "cond": "4000:4999,6100,7*", "logic": None}])
        self.assertTrue(self.ok(g, {"d_Account.Code": "4500"}))
        self.assertTrue(self.ok(g, {"d_Account.Code": "6100"}))
        self.assertTrue(self.ok(g, {"d_Account.Code": "7200"}))
        self.assertFalse(self.ok(g, {"d_Account.Code": "5000"}))
        p = C.group_pred([{"dim": "d_Scenario", "field": "Code", "op": "In", "cond": "{@Alias}", "logic": None}])
        self.assertTrue(self.ok(p, {"d_Scenario.Code": "bud"}))        # parameter chain, case-insensitive, list
        star = C.group_pred([{"dim": "d_dim0", "field": "Code", "op": "In", "cond": "{@Loc}", "logic": None}])
        self.assertTrue(self.ok(star, {"d_dim0.Code": "anything"}))

    def test_logical_operators_left_to_right(self):
        e = lambda cond, logic=None: {"dim": "d_Account", "field": "Code", "op": "In", "cond": cond, "logic": logic}
        g = C.group_pred([e("6000:6999"), e("6900", "AndNot"), e("8000", "Or")])
        self.assertTrue(self.ok(g, {"d_Account.Code": "6100"}))
        self.assertFalse(self.ok(g, {"d_Account.Code": "6900"}))
        self.assertTrue(self.ok(g, {"d_Account.Code": "8000"}))
        n = C.group_pred([e("4000", "Not")])                            # Not on the first expression is unary
        self.assertFalse(self.ok(n, {"d_Account.Code": "4000"}))
        self.assertTrue(self.ok(n, {"d_Account.Code": "4100"}))
        c = C.group_pred([{"dim": "d_dim1", "field": "UDF001", "op": "Contains", "cond": '"fiel"', "logic": None}])
        self.assertTrue(self.ok(c, {"d_dim1.UDF001": "Field Operations"}))

    def test_unknown_operator_is_a_gap(self):
        with self.assertRaises(C.Unsupported):
            C.group_pred([{"dim": "d", "field": "f", "op": "Between", "cond": "1", "logic": None}])


class Formulas(unittest.TestCase):
    def parse(self, f, cells=None):
        cells = cells or {}
        get = lambda t, a: ["base", f"{t}.{a}"]
        cell = lambda col, row: cells.get(f"{col}{row}", C.K(0))
        return C.FormulaParser(C.tokenize(f), get, cell).parse()

    def value(self, f, cells=None, bases=None):
        from fractions import Fraction
        v = C.eval_expr(self.parse(f, cells), {k: Fraction(x) for k, x in (bases or {}).items()})
        return None if v is None else float(v)

    def test_arithmetic_sum_iferror(self):
        cells = {"E10": C.K(10), "E11": C.K(30), "E12": C.K(0)}
        self.assertEqual(self.value("=SUM(E10:E11)", cells), 40)
        self.assertEqual(self.value("=IFERROR(E10/E12,0)", cells), 0)
        self.assertEqual(self.value("=IFERROR(E10/E12,)", cells), 0)            # empty argument reads as 0
        self.assertIsNone(self.value("=E10/E12", cells))                        # error outside IFERROR
        self.assertEqual(self.value("=-(E10-E11)*50%", cells), 10)
        self.assertEqual(self.value('=-_xll.OneStop.ReportPlayer.OSRFunctions.OSRGet("GL","V")', bases={"GL.V": 7}), -7)
        self.assertEqual(self.value("=SUM(OSRRef(E10:E11))", cells), 40)

    def test_unsupported_functions_are_gaps(self):
        for f in ("=VLOOKUP(E10,A1:B2,2)", "=IF(E10>0,1,0)", "=E10:E11"):
            with self.assertRaises(C.Unsupported):
                self.parse(f, {"E10": C.K(1), "E11": C.K(1)})

    def test_text_cells(self):
        for f in ('=TRIM(MID(OSRGet("d_Account","UDF002"),5,50))', '="As of "&TEXT(D4,"mm/dd/yy")',
                  '=IF(J16<-0.0001,"-","+")&TEXT(J16,"0%")', '=OSRGet("d_Account","Description")'):
            self.assertTrue(C.is_text_formula(f), f)
        self.assertFalse(C.is_text_formula('=-OSRGet("GL_F_Trans","Value1")'))
        self.assertFalse(C.is_text_formula("=IFERROR(E10/E12,0)"))


class EndToEnd(unittest.TestCase):
    def test_compile_matches_independent_oracle(self):
        p = plan()
        s = p["sheets"][0]
        self.assertEqual([ln["label"] for ln in s["lines"]],
                         ["Revenue", "Cost of sales", "Gross margin", "Gross margin %", "Operating expenses", "EBITDA", "Field payroll"])
        self.assertEqual([c["letter"] for c in s["columns"]], ["D", "E", "F", "G", "H"])
        self.assertEqual(p["warnings"], [])
        parity = load_script("compare-solver-parity")
        vals = json.loads(json.dumps(C.evaluate(p, facts())))
        res = parity.compare(json.loads(json.dumps(p)), RUN, vals)
        self.assertEqual(res["status"], "GREEN", res["mismatches"][:3] or res["unmatched"][:3])
        self.assertEqual(res["compared"], 39)                          # 35 line cells + 2 members x 2 values

    def test_wrong_parameters_turn_parity_red(self):
        p = plan()
        parity = load_script("compare-solver-parity")
        vals = json.loads(json.dumps(C.evaluate(p, facts(), {"Period": "202608"})))
        self.assertEqual(parity.compare(json.loads(json.dumps(p)), RUN, vals)["status"], "RED")

    def test_convert_envelope_and_mapping_gaps(self):
        conv = load_script("convert-solver")
        env, problems = conv.build(plan(), SM, "Location P&L summary - Data", "fixture-folder")
        self.assertEqual(problems, [])
        els = env["sigmaDataModel"]["pages"][0]["elements"]
        self.assertEqual([e["name"] for e in els if e["kind"] == "table"], ["Summary lines", "Summary detail row 14"])
        ctl = {e["controlId"]: e for e in els if e["kind"] == "control"}
        self.assertEqual(sorted(ctl), ["ActualScenario", "BudgetScenario", "Location", "Period"])
        self.assertEqual((ctl["Period"]["controlType"], ctl["Period"]["mode"], ctl["Period"]["value"]), ("number", "=", 202609))
        sql = els[0]["source"]["statement"]
        self.assertIn("COALESCE({{BudgetScenario}}, 'BUD,ADJ')", sql)
        self.assertNotIn(";", sql)
        broken = dict(SM, attributes={k: v for k, v in SM["attributes"].items() if k != "d_dim1.UDF001"})
        _, problems = conv.build(C.compile_report(S.load(TEMPLATE), broken), broken, "x", "f")
        self.assertTrue(any("d_dim1.UDF001" in p for p in problems))

    def test_workbook_from_readback(self):
        conv, wbm = load_script("convert-solver"), load_script("build-solver-workbook")
        p = plan()
        env, _ = conv.build(p, SM, "Location P&L summary - Data", "fixture-folder")
        rb = dict(env["sigmaDataModel"], dataModelId="00000000-0000-0000-0000-00000000d001")
        wb = wbm.build(json.loads(json.dumps(p)), rb, "Location P&L summary", "fixture-folder")
        doc = wb["workbook"]["document"]
        ctls = [e for e in doc["elements"] if e["kind"] == "control"]
        self.assertTrue(all(c["parameters"][0]["dataModelId"].endswith("d001") for c in ctls))
        self.assertTrue(all("mode" in c for c in ctls))
        tables = [e for e in doc["elements"] if e["kind"] == "table"]
        self.assertEqual(len(tables), 2)
        self.assertEqual(tables[0]["source"]["kind"], "data-model")
        placed = set(re.findall(r'elementId="([^"]+)"', doc["layout"]))
        self.assertEqual(placed, {e["id"] for e in doc["elements"]})


class Assessment(unittest.TestCase):
    def test_inventory_and_manifest_refusal(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "in"), os.path.join(d, "out")
            os.makedirs(src)
            with open(TEMPLATE, "rb") as fh, open(os.path.join(src, "pnl.xlsx"), "wb") as o:
                o.write(fh.read())
            with open(os.path.join(src, "pnl.xlsx.manifest"), "w") as o:
                o.write("never read")
            script = os.path.join(SKILL, "..", "solver-assessment", "scripts", "assess-solver.py")
            subprocess.run([sys.executable, script, "--in", src, "--out", out], check=True, capture_output=True)
            with open(os.path.join(out, "inventory.json")) as fh:
                inv = json.load(fh)
            self.assertEqual(inv["refused"], ["pnl.xlsx.manifest"])
            r = inv["reports"][0]
            self.assertEqual((r["bucket"], r["lines"], r["expanded_rows"]), ("iterate", 7, 1))
            self.assertIn("YTD", r["period_functions"])


class ReviewFixes(unittest.TestCase):
    """Each case reproduces a silent wrong value or false GREEN found in review, and pins the fix."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.parity = load_script("compare-solver-parity")

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def green(self, p, **kw):
        vals = roundtrip(C.evaluate(p, facts()))
        return self.parity.compare(roundtrip(p), RUN, vals, **kw)

    # 1. shared (filled-down) formulas
    def test_shared_formulas_are_expanded(self):
        self.assertEqual(S.shift_formula('D6-$E$6+SUM(D6:D7)+OSRGet("GL_F_Trans","Value1")', 2, 1),
                         'E8-$E$6+SUM(E8:E9)+OSRGet("GL_F_Trans","Value1")')
        for cached in ("", "<v>0</v>"):
            def to_shared(x, cached=cached):
                x = re.sub(r'<c r="F6"><f>D6-E6</f></c>', '<c r="F6"><f t="shared" ref="F6:F12" si="0">D6-E6</f></c>', x)
                return re.sub(r'<c r="F(\d+)"><f>D\1-E\1</f></c>',
                              lambda m: f'<c r="F{m.group(1)}"><f t="shared" si="0"/>{cached}</c>', x)
            t = self.path("shared.xlsx")
            rewrite_xlsx(TEMPLATE, t, sheet=to_shared)
            self.assertEqual(S.read_xlsx_cells(t)["Summary"]["F9"]["f"], "=D9-E9")
            res = self.green(C.compile_report(S.load(t), SM))
            self.assertEqual((res["status"], res["compared"]), ("GREEN", 39), res["mismatches"][:2])

    # 2. one unsupported construct is a gap on its item, not a dropped sheet
    def test_unsupported_operator_is_an_item_gap(self):
        ir = S.load(TEMPLATE)
        row10 = next(i for i in ir["sheets"][0]["items"] if i["type"] == "Row" and i["row"] == 10)
        row10["elements"][0]["filters"][0]["exprs"][1]["op"] = "NotEquals"
        p = C.compile_report(ir, SM)
        self.assertEqual(len(p["sheets"]), 1)
        ln = {l["row"]: l for l in p["sheets"][0]["lines"]}
        self.assertTrue(all("gap" in c for c in ln[10]["cells"].values()))
        self.assertTrue(all("expr" in c for c in ln[6]["cells"].values()))
        self.assertTrue(any("NotEquals" in w for w in p["warnings"]))
        self.assertGreater(C.gap_count(p), 0)
        self.assertEqual(self.green(p)["status"], "RED")                       # gaps fail the gate ...
        self.assertTrue(self.green(p, allow_gaps=True)["gaps_accepted"])       # ... unless accepted on record
        env, problems = load_script("convert-solver").build(p, SM, "x", "f")
        self.assertEqual(problems, [])
        self.assertGreater(env["stats"]["gap_cells"], 0)
        ir = S.load(TEMPLATE)
        col7 = next(i for i in ir["sheets"][0]["items"] if i["type"] == "Column" and i["col"] == 7)
        col7["elements"][0]["filters"][1]["exprs"][0]["cond"] = "{PeriodCalc.GetFunction(WTD, @Period)}"
        p = C.compile_report(ir, SM)
        self.assertTrue(all("gap" in l["cells"]["G"] for l in p["sheets"][0]["lines"]))

    def test_assessment_counts_item_gaps_and_detail_filters(self):
        t = self.path("in")
        os.makedirs(t)
        rewrite_xlsx(TEMPLATE, os.path.join(t, "r.xlsx"), definition=lambda x: x.replace(
            'Condition="6900" LogicalOperator="AndNot"', 'Operator="NotEquals" Condition="6900" LogicalOperator="And"', 1
        ).replace('Operator="In" Operator="NotEquals"', 'Operator="NotEquals"').replace(
            '<DefinitionElement xsi:type="ReferenceElement" Row="14" Column="4" />',
            '<DefinitionElement xsi:type="SelectionElement"><Dimensions /><FilterGroups><FilterGroup Name="Period"><Filters>'
            '<Expression DimensionName="Period" Name="PeriodId" Operator="In" '
            'Condition="{PeriodCalc.GetFunction(QTD, @Period)}" /></Filters></FilterGroup></FilterGroups><Columns />'
            '</DefinitionElement>'))
        assess = importlib.util.spec_from_file_location(
            "assess_solver", os.path.join(SKILL, "..", "solver-assessment", "scripts", "assess-solver.py"))
        mod = importlib.util.module_from_spec(assess)
        assess.loader.exec_module(mod)
        r = mod.profile(os.path.join(t, "r.xlsx"))
        self.assertGreater(r["untranslated_cells"], 0)
        self.assertNotEqual(r["bucket"], "automatable")
        self.assertIn("QTD", r["period_functions"])                             # a filter only an expanded cell carries

    # 3. a value cell that reads a text cell is a gap, and so is everything that reads it
    def test_text_dependency_is_a_gap(self):
        self.assertFalse(C.is_text_formula('=IF(D6>0,D6-D7,"n/a")'))
        self.assertTrue(C.is_text_formula('=IF(D6>0,"up","down")'))
        ir = S.load(TEMPLATE)
        ir["sheets"][0]["cells"]["D8"]["f"] = '=IF(D6>0,D6-D7,"n/a")'
        p = C.compile_report(ir, SM)
        ln = {l["row"]: l for l in p["sheets"][0]["lines"]}
        for row, col in ((8, "D"), (9, "D"), (11, "D"), (8, "F"), (8, "H")):
            self.assertIn("gap", ln[row]["cells"][col], (row, col))
        ir["sheets"][0]["cells"]["D8"]["f"] = '="see note"&D6'                    # a real label: text, and readers gap
        p = C.compile_report(ir, SM)
        ln = {l["row"]: l for l in p["sheets"][0]["lines"]}
        self.assertNotIn("D", ln[8]["cells"])
        self.assertIn("text cell", ln[9]["cells"]["D"]["gap"])

    # 4. parity pairs export rows by label, never by position
    def test_export_rows_are_matched_by_label(self):
        p = plan()
        vals = roundtrip(C.evaluate(p, facts()))
        rows = export_rows(p, vals)
        d = p["sheets"][0]["details"][0]
        members = [{d["labels"][L]: v for L, v in m.items()} for m in vals["Summary"]["details"]["14"]]
        cmp = lambda r: self.parity.compare(roundtrip(p), RUN, None, "Summary", export=r, detail_exports={14: members})
        self.assertEqual(cmp(rows)["status"], "GREEN")
        short = cmp(rows[:4])                                    # a 4-row export of a 7-line plan
        self.assertEqual(short["status"], "RED")
        self.assertEqual(sum(u.get("what") == "line missing from the rebuilt values" for u in short["unmatched"]), 3)
        relabelled = cmp([dict(r, Line=f"x{i}") for i, r in enumerate(rows)])
        self.assertEqual(relabelled["status"], "RED")
        self.assertEqual(sum(u.get("what") == "row in the rebuilt values that the plan does not have"
                             for u in relabelled["unmatched"]), 7)
        no_col = cmp([{k: v for k, v in r.items() if k != "Budget"} for r in rows])
        self.assertTrue(any(u.get("what") == "column missing from the rebuilt values" for u in no_col["unmatched"]))

    # 5. expanded rows are compared on the export path, both ways
    def test_expanded_rows_are_compared_both_ways(self):
        p = plan()
        vals = roundtrip(C.evaluate(p, facts()))
        d = p["sheets"][0]["details"][0]
        members = [{d["labels"][L]: v for L, v in m.items()} for m in vals["Summary"]["details"]["14"]]
        res = self.parity.compare(roundtrip(p), RUN, None, "Summary", export=export_rows(p, vals),
                                  detail_exports={14: members})
        self.assertEqual((res["status"], res["compared"]), ("GREEN", 39), res["unmatched"][:2] or res["mismatches"][:2])
        res = self.parity.compare(roundtrip(p), RUN, None, "Summary", export=export_rows(p, vals))
        self.assertEqual(res["status"], "RED")                                   # no detail export: not compared
        vals["Summary"]["details"]["14"] = vals["Summary"]["details"]["14"][:1]
        res = self.parity.compare(roundtrip(p), RUN, vals)
        self.assertEqual(res["status"], "RED")
        self.assertTrue(any(u["what"] == "member in the run, missing from the rebuild" for u in res["unmatched"]))

    def test_all_zero_run_is_not_an_oracle(self):
        mf = load_fixture_generator()
        zero = {r: {k: 0 for k in "DEFGH"} for r in (6, 7, 8, 9, 10, 11, 12)}
        run = self.path("zero-run.xlsx")
        mf.write_xlsx(run, mf.layout_cells(zero, [{"B": "Product revenue", "C": "4100", "D": 0, "E": 0},
                                                  {"B": "Service revenue", "C": "4200", "D": 0, "E": 0}]))
        p = plan()
        res = self.parity.compare(roundtrip(p), run, roundtrip(C.evaluate(p, facts(), {"Location": "NONE"})))
        self.assertEqual(res["status"], "RED")
        self.assertTrue(any("all zero" in u["what"] or "is zero" in u["what"] for u in res["unmatched"]))

    # 6. NULL attributes compare as '' in SQL, as in the oracle
    def test_null_attribute_compares_as_empty(self):
        self.assertEqual(Q.Renderer.norm("d.DEPT_GROUP"), "UPPER(TRIM(COALESCE(TO_VARCHAR(d.DEPT_GROUP), '')))")
        g = C.group_pred([{"dim": "d_dim1", "field": "UDF001", "op": "In", "cond": "Facilities", "logic": "Not"}])
        self.assertTrue(C.eval_pred(g, {}, [], {}))

    # 13. one control per parameter in the whole workbook
    def test_multi_sheet_controls_are_unique(self):
        ir = S.load(TEMPLATE)
        ir["sheets"].append(json.loads(json.dumps(dict(ir["sheets"][0], name="Second"))))
        p = C.compile_report(ir, SM)
        env, _ = load_script("convert-solver").build(p, SM, "x", "f")
        rb = dict(env["sigmaDataModel"], dataModelId="00000000-0000-0000-0000-00000000d001")
        doc = load_script("build-solver-workbook").build(roundtrip(p), rb, "x", "f")["workbook"]["document"]
        ctls = [e for e in doc["elements"] if e["kind"] == "control"]
        self.assertEqual(len(ctls), 4)
        self.assertEqual(len({c["controlId"] for c in ctls}), 4)
        self.assertEqual(len({e["id"] for e in doc["elements"]}), len(doc["elements"]))
        self.assertEqual(len(doc["pages"]), 2)

    # 14 / 15. chained and list defaults
    def test_chained_and_list_defaults(self):
        params = [{"name": "A", "default": "X", "data_type": "System.String"},
                  {"name": "B", "default": "{@A}", "data_type": "System.String"},
                  {"name": "N", "default": "1,2", "data_type": "System.Decimal"}]
        mk = lambda name, dim: {"k": "in", "dim": dim, "field": "Code", "parts": [{"param": name}]}
        p = {"parameters": params, "sheets": [{"bases": {"B001": {"fact": "GL_F_Trans", "value": "Value1",
             "groups": {"d_dim0": mk("B", "d_dim0"), "d_Account": mk("N", "d_Account")}}}, "details": []}]}
        r = Q.Renderer(p, SM)
        self.assertEqual(r.ctl_ref("B"), "COALESCE({{B}}, COALESCE({{A}}, 'X'))")
        ctl = {c["param"]: c for c in Q.controls(p)}
        self.assertEqual((ctl["B"]["default"], ctl["B"]["follows"]), (None, "A"))
        self.assertEqual((ctl["N"]["numeric"], ctl["N"]["default"]), (False, "1,2"))
        p["parameters"].append({"name": "Per", "default": "202608,202609", "is_period": True})
        p["sheets"][0]["bases"]["B001"]["groups"]["Period"] = {"k": "period_fn", "dim": "Period", "field": "PeriodId",
                                                               "fn": "TPTY", "param": "Per"}
        with self.assertRaises(Q.MappingError):
            Q.controls(p)

    # 16. only a trailing wildcard is translated, the same way in SQL and in the oracle
    def test_wildcards(self):
        for cond in ("*100", "6*00", "6**", "1*:2"):
            with self.assertRaises(C.Unsupported, msg=cond):
                C.leaf("d_Account", "Code", "In", cond)
        lf = C.leaf("d_Account", "Code", "In", "AB_*")
        sql = Q.Renderer({"sheets": [], "parameters": []}, SM).pred(lf, "GL_F_Trans")
        self.assertIn("STARTSWITH(", sql)
        self.assertIn("'AB_'", sql)
        self.assertTrue(C.eval_pred(lf, {"d_Account.Code": "ab_9"}, [], {}))
        self.assertFalse(C.eval_pred(lf, {"d_Account.Code": "ABX9"}, [], {}))

    # date filters are gaps, never text or literal comparisons
    def test_date_filters_are_gaps(self):
        with self.assertRaises(C.Unsupported):
            C.leaf("Date", "Date", "In", "'{Date.AddDays(-7).SqlDate}':{@Date}")
        params = [{"name": "Acquired", "type": "PeriodSelection", "data_type": "OneStop.PeriodInterval",
                   "default": "'2010-01-01':'2024-10-31'"}]
        with self.assertRaises(C.Unsupported):
            C.leaf("d_dim0", "UDF009", "In", "{@Acquired}", params)
        with self.assertRaises(C.Unsupported):
            C.leaf("d_dim0", "UDF009", "In", "'2010-01-01':'2024-10-31'")

    # 17. the fiscal year travels in the plan
    def test_fiscal_year_in_plan(self):
        p = C.compile_report(S.load(TEMPLATE), dict(SM, fiscal_year_start_month=7))
        self.assertEqual(p["fiscal_year_start_month"], 7)
        self.assertEqual(C.evaluate(p, facts()), C.evaluate(p, facts(), fy_start=7))
        self.assertNotEqual(C.evaluate(p, facts()), C.evaluate(p, facts(), fy_start=1))


def load_fixture_generator():
    spec = importlib.util.spec_from_file_location("make_fixtures", os.path.join(FIX, "make_fixtures.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


if __name__ == "__main__":
    unittest.main(verbosity=1)
