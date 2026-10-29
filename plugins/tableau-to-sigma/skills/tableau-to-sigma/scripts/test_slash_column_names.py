"""Python-runtime twin of test-slash-column-names.rb.

A data-model / master column NAMED with "/" (or "[" "]") can never be referenced:
Sigma reads "/" inside a bracketed reference as a path separator, so a master
column `[Order Fact View/Region - East/West]` exports as 'Unknown column' and a
list control over it POSTs as "Invalid value source for list control".

tableau_source.py renames (called by migrate-tableau.py before the DM POST) every such column and metric (and every reference to
it) to Sigma's friendly form ("Region - East/West" -> "Region - East West"), and
build-workbook-from-signals.py names the master column and every reference the
same safe name while the control label keeps the Tableau caption.
"""

import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(module_name, filename):
    spec = importlib.util.spec_from_file_location(module_name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


tableau_source = load("tableau_source_slash", "tableau_source.py")
builder_module = load("build_workbook_slash", "build-workbook-from-signals.py")

SPECIAL = re.compile(r"[/\[\]]")


def dm_model():
    return {
        "pages": [
            {
                "elements": [
                    {
                        "id": "el-base",
                        "name": "Order Fact",
                        "source": {
                            "kind": "warehouse-table",
                            "path": ["SALESDB", "SALES", "ORDER_FACT"],
                        },
                        "columns": [
                            {"id": "inode-1/REGION", "formula": "[ORDER_FACT/Region]"},
                            {
                                "id": "inode-2/COUNTRY_REGION",
                                "formula": "[ORDER_FACT/Country/Region]",
                            },
                            {
                                "id": "c-area",
                                "name": "Area - East/West",
                                "formula": 'If([Region] = "East", "East", "West")',
                            },
                            {
                                "id": "c-tag",
                                "name": "Area Tag",
                                "formula": '[Area - East/West] & " zone"',
                            },
                            {"id": "c-we", "name": "West East", "formula": '"we"'},
                            {"id": "c-we2", "name": "West/East", "formula": '"we2"'},
                        ],
                        "metrics": [
                            {
                                "id": "m-share",
                                "name": "Share E/W",
                                "formula": 'CountIf([Area - East/West] = "East")',
                            }
                        ],
                    },
                    {
                        "id": "el-view",
                        "name": "Order Fact View",
                        "source": {"kind": "table", "elementId": "el-base"},
                        "columns": [
                            {"id": "v-area", "formula": "[Order Fact/Area - East/West]"},
                            {"id": "v-tag", "formula": "[Order Fact/Area Tag]"},
                            {
                                "id": "v-flag",
                                "name": "East Flag",
                                "formula": 'If([Area - East/West] = "East", 1, 0)',
                            },
                        ],
                    },
                ]
            }
        ]
    }


class ConverterRenameTest(unittest.TestCase):
    def setUp(self):
        self.model = dm_model()
        tableau_source.sanitize_bracket_path_captions(self.model)
        self.result = tableau_source.sanitize_slash_column_names(self.model)
        elements = {e["id"]: e for e in self.model["pages"][0]["elements"]}
        self.base, self.view = elements["el-base"], elements["el-view"]

    def item(self, element, item_id):
        return next(
            c
            for c in (element["columns"] + element.get("metrics", []))
            if c["id"] == item_id
        )

    def test_no_name_holds_a_path_character(self):
        names = [
            c.get("name")
            for e in self.model["pages"][0]["elements"]
            for c in e["columns"] + e.get("metrics", [])
            if c.get("name")
        ]
        self.assertEqual([], [n for n in names if SPECIAL.search(n)])

    def test_names_are_the_friendly_form(self):
        self.assertEqual("Area - East West", self.item(self.base, "c-area")["name"])
        self.assertEqual(
            "Country Region", self.item(self.base, "inode-2/COUNTRY_REGION")["name"]
        )
        self.assertEqual("Share E W", self.item(self.base, "m-share")["name"])
        self.assertEqual("West East 2", self.item(self.base, "c-we2")["name"])
        self.assertEqual("West East", self.item(self.base, "c-we")["name"])

    def test_every_internal_reference_is_rewritten(self):
        self.assertEqual(
            '[Area - East West] & " zone"', self.item(self.base, "c-tag")["formula"]
        )
        self.assertEqual(
            'CountIf([Area - East West] = "East")',
            self.item(self.base, "m-share")["formula"],
        )
        self.assertEqual(
            "[Order Fact/Area - East West]", self.item(self.view, "v-area")["formula"]
        )
        self.assertEqual(
            'If([Area - East West] = "East", 1, 0)',
            self.item(self.view, "v-flag")["formula"],
        )
        self.assertEqual("[Order Fact/Area Tag]", self.item(self.view, "v-tag")["formula"])
        self.assertNotIn("East/West", json.dumps(self.model))

    def test_warehouse_passthrough_formula_is_physical_not_a_path(self):
        self.assertEqual(
            "[ORDER_FACT/COUNTRY_REGION]",
            self.item(self.base, "inode-2/COUNTRY_REGION")["formula"],
        )

    def test_one_named_warning_per_rename_and_a_caption_map(self):
        self.assertEqual(
            ["Country/Region", "Area - East/West", "West/East", "Share E/W"],
            [r["from"] for r in self.result["renamed"]],
        )
        for record in self.result["renamed"]:
            self.assertIn(
                "renamed for Sigma: '/' cannot appear in a referenced column name",
                record["warning"],
            )
            self.assertIn(f"'{record['from']}'", record["warning"])
            self.assertIn(f"'{record['to']}'", record["warning"])
        self.assertEqual(
            {
                "Country/Region": "Country Region",
                "Area - East/West": "Area - East West",
                "West/East": "West East 2",
                "Share E/W": "Share E W",
            },
            self.result["map"],
        )

    def test_second_pass_is_a_no_op(self):
        again = tableau_source.sanitize_slash_column_names(self.model)
        self.assertEqual({"renamed": [], "map": {}}, again)

    def test_a_model_without_special_names_is_untouched(self):
        plain = {
            "pages": [
                {
                    "elements": [
                        {
                            "id": "e",
                            "columns": [
                                {"id": "c", "name": "Net Revenue", "formula": "[T/Net Revenue]"}
                            ],
                        }
                    ]
                }
            ]
        }
        before = json.dumps(plain)
        result = tableau_source.sanitize_slash_column_names(plain)
        self.assertEqual(before, json.dumps(plain))
        self.assertEqual([], result["renamed"])


class BuilderReferenceTest(unittest.TestCase):
    def signals(self):
        meta = {
            "columns_by_guid": {
                "Calculation_401": {
                    "caption": "Area - East/West",
                    "datatype": "string",
                },
                "SALES": {"caption": "Sales", "datatype": "real"},
            },
            "column_formats": {},
        }
        layout = [
            {
                "dashboard": "Area Review",
                "emit_page": True,
                "zones": [
                    {"id": "root", "kind": "container", "x_pct": 0, "y_pct": 0, "w_pct": 100, "h_pct": 100},
                    {
                        "id": "area-filter",
                        "kind": "filter",
                        "x_pct": 0,
                        "y_pct": 0,
                        "w_pct": 30,
                        "h_pct": 10,
                        "filter_column_caption": "Area - East/West",
                        "filter_column_datatype": "string",
                    },
                    {
                        "id": "sales-bar",
                        "kind": "chart",
                        "chart_kind": "bar",
                        "caption": "Sales by Area",
                        "x_pct": 0,
                        "y_pct": 10,
                        "w_pct": 60,
                        "h_pct": 40,
                        "rows_shelf": {
                            "fields": [
                                {"guid": "SALES", "role": "measure", "derivation": "sum", "discrete": False}
                            ]
                        },
                        "cols_shelf": {
                            "fields": [{"guid": "Calculation_401", "role": "dim", "derivation": "none"}]
                        },
                        "filters": [],
                    },
                ],
            }
        ]
        return layout, meta

    def test_master_chart_and_control_use_the_safe_name(self):
        layout, meta = self.signals()
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"], report.get("residues"))
        elements = spec["document"]["elements"]
        master = next(e for e in elements if e["id"] == "master")
        master_by_name = {c["name"]: c for c in master["columns"]}
        self.assertEqual([], [n for n in master_by_name if SPECIAL.search(n)])
        self.assertIn("Area - East West", master_by_name)
        self.assertEqual("[FACT/Area - East West]", master_by_name["Area - East West"]["formula"])
        bar = next(e for e in elements if e["kind"] == "bar-chart")
        formulas = [c["formula"] for c in bar["columns"]]
        self.assertIn("[Master/Area - East West]", formulas)
        self.assertEqual([], [f for f in formulas if re.search(r"\[Master/[^\]]*/", f)])
        control = next(e for e in elements if e["kind"] == "control")
        self.assertEqual("Area - East/West", control["name"])  # the label keeps the caption
        target = control["filters"][0]["columnId"]
        self.assertEqual(master_by_name["Area - East West"]["id"], target)

    def test_ref_name_is_identity_for_ordinary_captions(self):
        self.assertEqual("Net Revenue", builder_module.sigma_safe_name("Net Revenue"))
        self.assertEqual("Order Date", builder_module.sigma_safe_name("Order Date"))
        self.assertEqual("Area - East West", builder_module.sigma_safe_name("Area - East/West"))
        self.assertEqual("Pct Net", builder_module.sigma_safe_name("Pct [Net]"))


if __name__ == "__main__":
    unittest.main()
