#!/usr/bin/env python3
"""Offline tests for build_reports.py. Placeholder Snowflake coordinates only; no network."""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_reports  # noqa: E402

SKILL = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "..", "plugins", "powerbi-to-sigma", "skills", "powerbi-to-sigma"))
EXTRACT = os.path.join(SKILL, "scripts", "extract-pbir.py")

HOST = "example-account.snowflakecomputing.com"
WH = "EXAMPLE_WH"
DB = "SAMPLE_DB"

_OUT = None


def out_dir():
    global _OUT
    if _OUT is None:
        _OUT = tempfile.mkdtemp(prefix="pbi-shaped-out-")
        build_reports.build(_OUT, HOST, WH, DB)
    return _OUT


def read(*parts):
    with open(os.path.join(out_dir(), *parts)) as f:
        return json.load(f)


def bim(slug):
    return read(slug, "model.bim")


def extract(report_slug):
    d = tempfile.mkdtemp(prefix="pbi-signals-")
    sig = os.path.join(d, "signals.json")
    r = subprocess.run([sys.executable, "-I", EXTRACT, "--pbir-dir", os.path.join(out_dir(), report_slug),
                        "--out", sig], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    with open(sig) as f:
        return json.load(f)


def measures(model):
    return {m["name"]: (t["name"], m) for t in model["model"]["tables"] for m in t.get("measures", [])}


class ModelTests(unittest.TestCase):
    def test_bim_has_userelationship_and_inactive_rel(self):
        m = bim("retail-sales-model")
        inactive = [r for r in m["model"]["relationships"] if r.get("isActive") is False]
        self.assertEqual(len(inactive), 1)
        self.assertEqual((inactive[0]["fromTable"], inactive[0]["fromColumn"]), ("Sales", "ShipDateKey"))
        self.assertEqual(inactive[0]["toTable"], "Date")
        _, ship = measures(m)["Sales by Ship Date"]
        self.assertIn("USERELATIONSHIP", ship["expression"])

    def test_four_models_and_three_reports(self):
        man = read("manifest.json")
        self.assertEqual(sorted(i["displayName"] for i in man["models"]),
                         ["Retail Inventory Model", "Retail Sales Model", "Retail Sales Model (RLS)",
                          "Retail Sales Trends Model"])
        self.assertEqual(sorted(i["displayName"] for i in man["reports"]),
                         ["Inventory and Purchasing", "Retail Sales", "Sales Trends"])

    def test_every_partition_is_snowflake_import_m(self):
        for slug in ("retail-sales-model", "retail-inventory-model", "retail-sales-trends-model",
                     "retail-sales-model-rls"):
            for t in bim(slug)["model"]["tables"]:
                for p in t["partitions"]:
                    src = p["source"]
                    if src["type"] == "calculated":
                        continue
                    self.assertEqual(p["mode"], "import")
                    text = "\n".join(src["expression"])
                    self.assertIn(f'Snowflake.Databases("{HOST}", "{WH}", [', text)
                    self.assertIn('Implementation = "2.0"', text)
                    self.assertIn(f'Name = "{DB}", Kind = "Database"', text)
                    self.assertIn('Name = "ZZ_CLAUDE_PBI_SHAPED", Kind = "Schema"', text)

    def test_names_differ_from_warehouse(self):
        m = bim("retail-sales-model")
        cust = next(t for t in m["model"]["tables"] if t["name"] == "Customer")
        cols = {c["name"]: c["sourceColumn"] for c in cust["columns"]}
        self.assertEqual(cols["Customer Region"], "CUSTOMER_REGION")
        sales = next(t for t in m["model"]["tables"] if t["name"] == "Sales")
        self.assertEqual({c["name"]: c["sourceColumn"] for c in sales["columns"]}["OrderDateKey"], "ORDER_DATE_KEY")

    def test_date_is_marked_date_table(self):
        d = next(t for t in bim("retail-sales-model")["model"]["tables"] if t["name"] == "Date")
        self.assertEqual(d["dataCategory"], "Time")
        self.assertTrue(next(c for c in d["columns"] if c["name"] == "Date").get("isKey"))

    def test_display_folders_and_classes(self):
        ms = measures(bim("retail-inventory-model"))
        folder = {n: m.get("displayFolder") for n, (_, m) in ms.items()}
        for n in ("Sales Amount", "Cost", "Gross Margin", "GM %", "Orders", "Avg Price"):
            self.assertEqual(folder[n], "Sales", n)
        for n in ("List Value", "Private Label Sales"):
            self.assertEqual(folder[n], "Product", n)
        self.assertEqual(folder["Sales by Ship Date"], "Shipping")
        for n in ("Sales YTD", "Sales QTD", "Sales MTD", "Sales PY", "Sales YoY %", "Sales R28",
                  "Sales YTD (As Of)"):
            self.assertEqual(folder[n], "Time", n)
        for n in ("On Hand (Latest)", "Open PO Units", "Sales R28 Units", "Days of Cover",
                  "Products by Cover Bucket"):
            self.assertEqual(folder[n], "Inventory", n)

    def test_units_name_is_shared_by_a_sales_measure_and_an_inventory_column(self):
        # Power BI rejects two measures with one name in a model ("Could not add Measure with the name
        # 'Units' because a Measure with the same name already exists"), so the collision is a
        # measure on Sales against a column on Inventory.
        m = bim("retail-inventory-model")
        meas = [t["name"] for t in m["model"]["tables"] for x in t.get("measures", []) if x["name"] == "Units"]
        cols = [t["name"] for t in m["model"]["tables"] for x in t["columns"] if x["name"] == "Units"]
        self.assertEqual(meas, ["Sales"])
        self.assertEqual(cols, ["Inventory"])

    def test_as_of_in_both_main_models_and_no_roles(self):
        for slug in ("retail-sales-model", "retail-inventory-model", "retail-sales-trends-model"):
            m = bim(slug)
            self.assertIn("As Of", [t["name"] for t in m["model"]["tables"]])
            self.assertFalse(m["model"].get("roles"), slug)

    def test_rls_model_has_exactly_one_role(self):
        m = bim("retail-sales-model-rls")
        self.assertEqual(len(m["model"]["roles"]), 1)

    def test_no_tracked_secret_shapes_in_out(self):
        bad = re.compile(r"y" r"mb|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
        for root, _, files in os.walk(out_dir()):
            for fn in files:
                if fn.endswith(".json") or fn.endswith(".bim") or fn.endswith(".pbir") or fn.endswith(".pbism"):
                    with open(os.path.join(root, fn), errors="replace") as f:
                        self.assertIsNone(bad.search(f.read()), os.path.join(root, fn))


class BuildSafetyTests(unittest.TestCase):
    def test_unrelated_subdirectory_survives_and_workspace_is_a_token(self):
        d = tempfile.mkdtemp(prefix="pbi-safe-")
        os.makedirs(os.path.join(d, "unrelated"))
        keep = os.path.join(d, "unrelated", "keep.txt")
        open(keep, "w").write("x")
        build_reports.build(d, HOST, WH, DB)
        build_reports.build(d, HOST, WH, DB)  # a rebuild replaces only owned dirs
        self.assertTrue(os.path.exists(keep))
        with open(os.path.join(d, "retail-sales", "definition.pbir")) as f:
            conn = json.load(f)["datasetReference"]["byConnection"]["connectionString"]
        self.assertIn("myorg/{WORKSPACE};", conn)
        self.assertIn("semanticmodelid={MODEL_ID}", conn)


class ReportTests(unittest.TestCase):
    def pages(self, sig):
        return [p.get("title") or p.get("page_name") or p.get("display_name") for p in sig["pages"]]

    def test_pbir_parses_with_extract_pbir(self):
        expected = {"retail-sales": ["Overview", "Shipping", "Slicers"],
                    "sales-trends": ["Trends", "Rolling"],
                    "inventory-and-purchasing": ["Cover"]}
        for slug, names in expected.items():
            sig = extract(slug)
            got = [json.dumps(p) for p in sig["pages"]]
            for n in names:
                self.assertTrue(any(f'"{n}"' in g for g in got), (slug, n))
            self.assertEqual(len(sig["pages"]), len(names), slug)

        sig = extract("retail-sales")
        slicers_page = next(p for p in sig["pages"] if '"Slicers"' in json.dumps(p))
        slicers = [v for v in slicers_page["visuals"] if v["visual_type"] == "slicer"]
        self.assertEqual(len(slicers), 10)
        saved = [v for v in slicers if (v.get("slicer_state") or {}).get("saved_selection")]
        self.assertEqual(len(saved), 1)
        sel = saved[0]["slicer_state"]["saved_selection"]
        self.assertEqual(sel["values"], ["West"])
        self.assertEqual(sel["mode"], "include")

    def test_slicers_page_has_two_boolean_slicers(self):
        m = bim("retail-sales-model")
        bools = {(t["name"], c["name"]) for t in m["model"]["tables"] for c in t["columns"]
                 if c["dataType"] == "boolean"}
        sig = extract("retail-sales")
        page = next(p for p in sig["pages"] if '"Slicers"' in json.dumps(p))
        hit = 0
        for v in page["visuals"]:
            if v["visual_type"] != "slicer":
                continue
            ref = json.dumps(v["bindings"])
            for ent, col in bools:
                if f"{ent}.{col}" in ref:
                    hit += 1
        self.assertEqual(hit, 2)

    def test_rolling_has_four_slicers_and_inventory_has_three(self):
        sig = extract("sales-trends")
        rolling = next(p for p in sig["pages"] if '"Rolling"' in json.dumps(p))
        self.assertEqual(sum(v["visual_type"] == "slicer" for v in rolling["visuals"]), 4)
        sig = extract("inventory-and-purchasing")
        self.assertEqual(sum(v["visual_type"] == "slicer" for v in sig["pages"][0]["visuals"]), 3)

    def test_retail_sales_has_report_wide_not_discontinued_filter(self):
        rep = read("retail-sales", "definition", "report.json")
        flt = rep["filterConfig"]["filters"][0]
        self.assertEqual(flt["field"]["Column"]["Property"], "Category Name")
        self.assertIn("Not", flt["filter"]["Where"][0]["Condition"])

    def test_every_visual_field_exists_in_its_model(self):
        man = read("manifest.json")
        model_of = {r["slug"]: r["model"] for r in man["reports"]}
        slug_of = {i["displayName"]: i["slug"] for i in man["models"]}
        for rslug, mname in model_of.items():
            m = bim(slug_of[mname])
            cols = {(t["name"], c["name"]) for t in m["model"]["tables"] for c in t["columns"]}
            meas = {(t["name"], x["name"]) for t in m["model"]["tables"] for x in t.get("measures", [])}
            root = os.path.join(out_dir(), rslug, "definition", "pages")
            for dp, _, fns in os.walk(root):
                for fn in fns:
                    if fn != "visual.json":
                        continue
                    with open(os.path.join(dp, fn)) as f:
                        v = json.load(f)
                    for blk in v["visual"]["query"]["queryState"].values():
                        for p in blk["projections"]:
                            fld = p["field"]
                            if "Column" in fld:
                                k = (fld["Column"]["Expression"]["SourceRef"]["Entity"], fld["Column"]["Property"])
                                self.assertIn(k, cols, (rslug, k))
                            else:
                                k = (fld["Measure"]["Expression"]["SourceRef"]["Entity"], fld["Measure"]["Property"])
                                self.assertIn(k, meas, (rslug, k))


if __name__ == "__main__":
    unittest.main()
