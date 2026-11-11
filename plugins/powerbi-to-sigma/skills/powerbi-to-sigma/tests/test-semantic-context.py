#!/usr/bin/env python3
"""Offline contracts for constrained DAX context and readable layout."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts/lib"))
from pbi_semantic_sql import Compiler, Unsupported, expression, split_args
from pbi_semantic_layout import apply_layout
from code_rep import create_body, update_body


class SemanticContext(unittest.TestCase):
    def setUp(self):
        self.model = {
            "tables": [
                {
                    "name": "Fact",
                    "columns": [],
                    "measures": [
                        {"name": "Amount", "expression": "SUM(Fact[Amount])"},
                        {
                            "name": "Prior",
                            "expression": "CALCULATE([Amount], SAMEPERIODLASTYEAR('Calendar'[Date]))",
                        },
                        {
                            "name": "Override",
                            "expression": 'CALCULATE([Amount], Region[Name] = "East")',
                        },
                        {
                            "name": "Intersect",
                            "expression": 'CALCULATE([Amount], KEEPFILTERS(Region[Name] = "East"))',
                        },
                        {
                            "name": "All Regions",
                            "expression": "CALCULATE([Amount], REMOVEFILTERS(Region))",
                        },
                    ],
                },
                {"name": "Region", "columns": []},
                {"name": "Calendar", "columns": []},
            ],
            "relationships": [
                {
                    "fromTable": "Fact",
                    "fromColumn": "RegionKey",
                    "toTable": "Region",
                    "toColumn": "Key",
                },
                {
                    "fromTable": "Fact",
                    "fromColumn": "Date",
                    "toTable": "Calendar",
                    "toColumn": "Date",
                },
            ],
        }
        self.sources = {
            t: {"name": "Source " + t, "columns": {c: c for c in cols}}
            for t, cols in [
                ("Fact", ["Amount", "RegionKey", "Date"]),
                ("Region", ["Key", "Name"]),
                ("Calendar", ["Date", "Month"]),
            ]
        }
        self.compiler = Compiler(self.model, self.sources)
        self.filters = [{"field": ("Region", "Name"), "control": "region"}]

    def test_override_omits_slicer_but_intersection_keeps_it(self):
        override = self.compiler.query([], ["Override"], self.filters)
        intersect = self.compiler.query([], ["Intersect"], self.filters)
        self.assertNotIn("{{region}}", override)
        self.assertIn("'East'", override)
        self.assertIn("{{region}}", intersect)
        self.assertIn("'East'", intersect)

    def test_remove_dimension_filter(self):
        self.assertNotIn(
            "{{region}}", self.compiler.query([], ["All Regions"], self.filters)
        )

    def test_userelationship_accepts_dimension_column_first(self):
        model = copy.deepcopy(self.model)
        model["tables"][0]["measures"].append(
            {
                "name": "Shipped Amount",
                "expression": "CALCULATE([Amount], USERELATIONSHIP(Calendar[Date], Fact[ShipDate]))",
            }
        )
        model["relationships"].append(
            {
                "fromTable": "Fact",
                "fromColumn": "ShipDate",
                "toTable": "Calendar",
                "toColumn": "Date",
                "isActive": False,
            }
        )
        sources = copy.deepcopy(self.sources)
        sources["Fact"]["columns"]["ShipDate"] = "ShipDate"

        query = Compiler(model, sources).query(
            [("Calendar", "Month")], ["Shipped Amount"], []
        )

        self.assertIn('f."ShipDate" = d2."Date"', query)

    def test_calendar_shift_is_unfiltered_by_selected_year_in_fact(self):
        query = self.compiler.query([("Calendar", "Month")], ["Prior"], self.filters)
        self.assertIn("WITH selected AS", query)
        self.assertIn("LAST_DAY", query)
        self.assertIn("SELECT DISTINCT", query)
        self.assertIn("tm.day", query)
        self.assertIn("{{region}}", query)

    def test_invalid_reference_and_cycles_are_rejected(self):
        with self.assertRaises(Unsupported):
            self.compiler.query([], ["Missing"], [])
        with self.assertRaises(Unsupported):
            self.compiler.query(
                [], ["Amount"], [{"field": ("Region", "Missing"), "values": ["x"]}]
            )
        self.compiler.measures["Cycle"] = "[Cycle]"
        with self.assertRaises(Unsupported):
            self.compiler.query([], ["Cycle"], [])

    def test_unsupported_filter_context_does_not_silently_compile(self):
        for dax in (
            "CALCULATE([Amount],REMOVEFILTERS(Fact))",
            'CALCULATE(CALCULATE([Amount],Region[Name]="West"),Region[Name]="East")',
            "SUMX(Fact,Fact[Amount])",
            "SUM(Fact[Amount],1)",
            'TOTALYTD([Amount],Calendar[Date],"06/30")',
        ):
            self.compiler.measures["Bad"] = dax
            with self.subTest(dax=dax), self.assertRaises(Unsupported):
                self.compiler.query([], ["Bad"], [])

    def test_security_and_bidirectional_models_block(self):
        model = copy.deepcopy(self.model)
        model["roles"] = [{"name": "Restricted"}]
        with self.assertRaises(Unsupported):
            Compiler(model, self.sources)
        model = copy.deepcopy(self.model)
        model["relationships"][0]["crossFilteringBehavior"] = "bothDirections"
        with self.assertRaises(Unsupported):
            Compiler(model, self.sources)

    def test_parser_keeps_nested_calls_and_quoted_commas(self):
        self.assertEqual(
            split_args('[A], Region[Name]="a,b", KEEPFILTERS([B]=1)'),
            ["[A]", 'Region[Name]="a,b"', "KEEPFILTERS([B]=1)"],
        )
        self.assertEqual(expression("([Amount]-[Prior])/[Prior]")[0], "binary")

    def test_nonadditive_pivot_rollups_are_not_assumed_safe(self):
        self.assertTrue(self.compiler.additive("Amount", []))
        self.assertTrue(self.compiler.additive("Prior", []))
        self.assertFalse(self.compiler.additive("Override", [("Region", "Name")]))
        for dax in (
            "AVERAGE(Fact[Amount])",
            "DISTINCTCOUNT(Fact[Amount])",
            "TOTALYTD([Amount],Calendar[Date])",
            "DIVIDE([Amount],[Prior])",
        ):
            self.compiler.measures["Nonadditive"] = dax
            self.assertFalse(self.compiler.additive("Nonadditive", []))

    def test_layout_stacks_hierarchy_levels_and_is_idempotent(self):
        visuals = [
            {
                "visual_id": "hier",
                "visual_type": "slicer",
                "y": 100,
                "x": 0,
                "w": 300,
                "h": 300,
            },
            {
                "visual_id": "matrix",
                "visual_type": "matrix",
                "y": 100,
                "x": 320,
                "w": 900,
                "h": 400,
            },
        ]
        signals = {
            "pages": [
                {"page_id": "page", "page_title": "01 Overview", "visuals": visuals}
            ]
        }
        mapping = [
            {
                "page": "page",
                "visual": "hier",
                "elementIds": ["region", "state", "city"],
            },
            {"page": "page", "visual": "matrix", "elementIds": ["matrix"]},
        ]
        document = {
            "pages": [
                {"id": "data", "name": "Data", "hidden": True},
                {"id": "page", "name": "01 Overview"},
            ],
            "elements": [
                {"id": c, "kind": "control", "controlType": "list", "values": []}
                for c in ("region", "state", "city")
            ]
            + [{"id": "matrix", "kind": "pivot-table", "columns": []}],
            "settings": {"navigation": {}},
        }
        apply_layout(document, signals, mapping, "data")
        root = ET.fromstring("<Layout>" + document["layout"] + "</Layout>")
        controls = [
            n
            for n in root.iter("Element")
            if n.attrib["elementId"] in ("region", "state", "city")
        ]
        self.assertEqual([n.attrib["gridColumn"] for n in controls], ["1 / 6"] * 3)
        self.assertEqual(len({n.attrib["gridRow"] for n in controls}), 3)
        self.assertEqual(document["pages"][0]["visibility"], "hidden")
        self.assertIn("navigation", document["settings"])
        before = copy.deepcopy(document)
        apply_layout(document, signals, mapping, "data")
        self.assertEqual(document, before)
        refs = [n.attrib["elementId"] for n in root.iter() if "elementId" in n.attrib]
        self.assertEqual(len(refs), len(set(refs)))

    def test_layout_handles_data_title_and_overflowing_synced_slicers(self):
        visuals = [
            {
                "visual_id": "hierarchy",
                "visual_type": "slicer",
                "sync_group": "hierarchy",
                "x": 0,
                "y": 0,
                "w": 200,
                "h": 100,
            }
        ] + [
            {
                "visual_id": "sync-" + str(i),
                "visual_type": "slicer",
                "sync_group": "sync-" + str(i),
                "x": 220 * i,
                "y": 120,
                "w": 200,
                "h": 100,
            }
            for i in range(3)
        ]
        signals = {
            "pages": [{"page_id": "source-data", "page_title": "Data", "visuals": visuals}]
        }
        mapping = [
            {
                "page": "source-data",
                "visual": "hierarchy",
                "elementIds": ["country", "region"],
            }
        ] + [
            {
                "page": "source-data",
                "visual": "sync-" + str(i),
                "elementIds": ["sync-" + str(i)],
            }
            for i in range(3)
        ]
        document = {
            "pages": [
                {"id": "helper", "name": "Data"},
                {"id": "content", "name": "Data"},
            ],
            "elements": [
                {"id": eid, "kind": "control", "controlType": "synced"}
                for eid in ("country", "region", "sync-0", "sync-1", "sync-2")
            ],
        }
        apply_layout(document, signals, mapping, "helper")
        self.assertEqual(document["pages"][0]["visibility"], "hidden")
        self.assertNotIn("visibility", document["pages"][1])
        root = ET.fromstring("<Layout>" + document["layout"] + "</Layout>")
        content = next(page for page in root if page.attrib["id"] == "content")
        refs = {node.attrib["elementId"] for node in content.iter("Element")}
        self.assertTrue(
            {"country", "region", "sync-0", "sync-1", "sync-2"} <= refs
        )

    def test_builder_runs_on_source_artifacts_and_refuses_unsupported_dax(self):
        model = copy.deepcopy(self.model)
        masters = {}
        for table in model["tables"]:
            name = table["name"]
            table["columns"] = [
                {"name": c, "dataType": "string"} for c in self.sources[name]["columns"]
            ]
            masters[name] = {
                "id": "master-" + name.lower(),
                "element_id": "dm-" + name.lower(),
                "data_model": "dm-test",
                "columns": [
                    {
                        "id": name.lower() + "-" + str(i),
                        "name": c,
                        "formula": f"[{name}/{c}]",
                    }
                    for i, c in enumerate(self.sources[name]["columns"])
                ],
            }
        signals = {
            "pages": [
                {
                    "page_id": "p1",
                    "page_title": "Test",
                    "page_w": 1000,
                    "visuals": [
                        {
                            "visual_id": "amount",
                            "visual_type": "card",
                            "sigma_kind": "kpi",
                            "title": "Amount",
                            "bindings": {"Values": ["Fact.Amount"]},
                            "x": 0,
                            "y": 0,
                            "w": 250,
                            "h": 100,
                        }
                    ],
                }
            ]
        }
        script = Path(__file__).parents[1] / "scripts/build-semantic-workbook.py"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, content in [
                ("model", {"model": model}),
                ("signals", signals),
                ("masters", {"masters": masters}),
            ]:
                (root / (name + ".json")).write_text(json.dumps(content))
            args = [
                sys.executable,
                str(script),
                "--model",
                str(root / "model.json"),
                "--signals",
                str(root / "signals.json"),
                "--master-map",
                str(root / "masters.json"),
                "--connection",
                "connection-test",
                "--warehouse-type",
                "snowflake",
                "--folder-id",
                "folder-test",
                "--name",
                "Test",
                "--reviewed-no-rls-cls",
                "--out",
                str(root / "workbook.json"),
            ]
            built = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            artifact = json.loads((root / "workbook.json").read_text())
            spec = artifact["document"]
            self.assertEqual(create_body(artifact, dry_run=True)["contents"], spec)
            self.assertEqual(
                update_body(artifact, document_version=7),
                {"contents": spec, "documentVersion": 7},
            )
            self.assertEqual(
                len([e for e in spec["elements"] if e["kind"] == "kpi-chart"]), 1
            )
            self.assertTrue(all(e["id"] == e["id"].lower() for e in spec["elements"]))
            self.assertEqual(spec["pages"][0]["visibility"], "hidden")
            self.assertIn(
                "sigma_element",
                next(e for e in spec["elements"] if e["kind"] == "kpi-chart")["source"][
                    "statement"
                ],
            )
            pivot_signals = copy.deepcopy(signals)
            pivot_signals["pages"][0]["page_title"] = "Data"
            pivot_signals["pages"][0]["visuals"] = [
                {
                    "visual_id": "matrix",
                    "visual_type": "matrix",
                    "sigma_kind": "pivot-table",
                    "title": "Matrix",
                    "bindings": {
                        "Columns": ["Calendar.Month"],
                        "Tooltips": ["Fact.RegionKey"],
                        "Rows": ["Region.Name"],
                        "Values": ["Fact.Amount"],
                    },
                    "x": 0,
                    "y": 0,
                    "w": 750,
                    "h": 400,
                }
            ]
            (root / "signals.json").write_text(json.dumps(pivot_signals))
            pivot_build = subprocess.run(
                args + ["--accept-ui-adaptations"], capture_output=True, text=True
            )
            self.assertEqual(pivot_build.returncode, 0, pivot_build.stderr)
            pivot_spec = json.loads((root / "workbook.json").read_text())["document"]
            pivot = next(
                e for e in pivot_spec["elements"] if e["kind"] == "pivot-table"
            )
            columns = {c["id"]: c["name"] for c in pivot["columns"]}
            self.assertEqual(
                [columns[item["columnId"]] for item in pivot["rowsBy"]], ["Name"]
            )
            self.assertEqual(
                [columns[item["columnId"]] for item in pivot["columnsBy"]], ["Month"]
            )
            self.assertNotIn("RegionKey", columns.values())
            helper, content = pivot_spec["pages"]
            self.assertEqual(helper["visibility"], "hidden")
            self.assertNotIn("visibility", content)
            slicer = {
                "visual_id": "region",
                "visual_type": "slicer",
                "sigma_kind": "control",
                "bindings": {"Values": ["Region.Name"]},
                "sync_group": "region-sync",
                "x": 0,
                "y": 120,
                "w": 250,
                "h": 100,
                "slicer_state": {
                    "mode": "Dropdown",
                    "has_saved_filter": True,
                    "selection": {
                        "type": "list",
                        "mode": "include",
                        "values": ["East"],
                    },
                },
            }
            signals["pages"][0]["visuals"].append(slicer)
            for state in (
                {
                    "mode": "Between",
                    "has_saved_filter": True,
                    "selection": {"type": "list", "values": [1]},
                },
                {"mode": "Dropdown", "has_saved_filter": True},
                {
                    "mode": "Dropdown",
                    "selection": {
                        "type": "list",
                        "mode": "exclude",
                        "values": ["East"],
                    },
                },
            ):
                candidate = copy.deepcopy(signals)
                candidate["pages"][0]["visuals"][-1]["slicer_state"] = state
                (root / "signals.json").write_text(json.dumps(candidate))
                (root / "workbook.json").unlink(missing_ok=True)
                rejected = subprocess.run(args, capture_output=True, text=True)
                self.assertNotEqual(rejected.returncode, 0, state)
                self.assertIn("requires an explicit mapping", rejected.stderr)
                self.assertFalse((root / "workbook.json").exists())
            candidate = copy.deepcopy(signals)
            copy_slicer = copy.deepcopy(slicer)
            copy_slicer["visual_id"] = "region-copy"
            copy_slicer["slicer_state"]["selection"]["values"] = ["West"]
            candidate["pages"].append(
                {"page_id": "p2", "page_title": "Second", "visuals": [copy_slicer]}
            )
            (root / "signals.json").write_text(json.dumps(candidate))
            rejected = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Synced slicers disagree", rejected.stderr)
            (root / "signals.json").write_text(json.dumps(signals))
            built = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            model["tables"][0]["measures"][0]["expression"] = "SUMX(Fact,Fact[Amount])"
            (root / "model.json").write_text(json.dumps({"model": model}))
            (root / "workbook.json").unlink()
            failed = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse((root / "workbook.json").exists())

    def test_drill_selector_stays_on_visible_page_without_a_hierarchy_rail(self):
        signals = {
            "pages": [
                {
                    "page_id": "page",
                    "page_title": "Overview",
                    "visuals": [
                        {
                            "visual_id": "chart",
                            "visual_type": "barChart",
                            "x": 0,
                            "y": 0,
                            "w": 500,
                            "h": 300,
                        }
                    ],
                }
            ]
        }
        mapping = [{"page": "page", "visual": "chart", "elementIds": ["chart"]}]
        doc = {
            "pages": [
                {"id": "data", "name": "Data"},
                {"id": "page", "name": "Overview"},
            ],
            "elements": [
                {"id": "chart", "kind": "bar-chart", "xAxis": {}},
                {"id": "chart-drill", "kind": "control"},
            ],
        }
        apply_layout(doc, signals, mapping, "data")
        root = ET.fromstring("<Layout>" + doc["layout"] + "</Layout>")
        visible = next(p for p in root if p.attrib["id"] == "page")
        refs = [e.attrib.get("elementId") for e in visible.iter()]
        self.assertIn("chart-drill", refs)
        self.assertIn("chart", refs)
        before = copy.deepcopy(doc)
        apply_layout(doc, signals, mapping, "data")
        self.assertEqual(doc, before)


if __name__ == "__main__":
    unittest.main()
