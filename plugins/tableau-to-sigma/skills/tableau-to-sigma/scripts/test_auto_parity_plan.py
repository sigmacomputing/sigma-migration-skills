#!/usr/bin/env python3
"""Creds-free tests for the no-Ruby parity-plan builder."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "auto-parity-plan.py"
SPEC = importlib.util.spec_from_file_location("auto_parity_plan", SCRIPT)
auto_parity_plan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(auto_parity_plan)


class AutoParityPlanTest(unittest.TestCase):
    def fixture(self, csv_body="Region,Sales\nEast,100\nWest,200\n"):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "views").mkdir()
        (root / "get-workbook.json").write_text(
            json.dumps(
                {
                    "hasExtracts": "true",
                    "views": {"view": [{"id": "v1", "name": "Sales Sheet"}]},
                }
            ),
            encoding="utf-8",
        )
        (root / "views" / "v1.csv").write_text(csv_body, encoding="utf-8")
        (root / "dashboard-layout.json").write_text(
            json.dumps(
                [
                    {
                        "dashboard": "Overview",
                        "zones": [
                            {
                                "kind": "chart",
                                "caption": "Sales Sheet",
                                "display_title": "Revenue by Region",
                                "measures": ["Sales"],
                                "rows_shelf": {"dim_count": 1},
                                "cols_shelf": {"measure_count": 1},
                                "hidden_filters": [
                                    {
                                        "calc_ref": "[Calculation_1]",
                                        "caption": "Current",
                                        "filter_type": "categorical",
                                        "members": ["Yes"],
                                    }
                                ],
                            },
                            {"kind": "text", "caption": "Notes"},
                        ],
                    }
                ]
            ),
            encoding="utf-8",
        )
        (root / "chart-provenance.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "elements": {
                        "el-sales": {
                            "worksheet": "Sales Sheet",
                            "dashboard": "Overview",
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        workbook = {
            "workbookId": "wb-1",
            "latestDocumentVersion": 7,
            "document": {
                "schemaVersion": 4,
                "pages": [{"id": "p1", "name": "Overview"}],
                "elements": [
                    {
                        "id": "master",
                        "kind": "table",
                        "visibleAsSource": False,
                        "source": {"kind": "data-model"},
                    },
                    {
                        "id": "el-sales",
                        "kind": "bar-chart",
                        "name": "Revenue by Region",
                        "source": {"kind": "element", "elementId": "master"},
                        "columns": [
                            {"id": "x-region", "name": "Region"},
                            {"id": "y-sales", "name": "Sales"},
                        ],
                        "xAxis": {"columnId": "x-region"},
                        "yAxis": {"columnIds": ["y-sales"]},
                    },
                ],
                "layout": (
                    '<Page id="p1"><Element elementId="master"/>'
                    '<Element elementId="el-sales"/></Page>'
                ),
            },
        }
        spec_path = root / "wb-readback.json"
        spec_path.write_text(json.dumps(workbook), encoding="utf-8")
        return root, spec_path

    def test_builds_complete_existing_plan_contract_from_readback_and_layout(self):
        root, spec_path = self.fixture()
        plan = auto_parity_plan.build_plan(
            root,
            spec_path,
            workbook_id="wb-1",
            dashboards_scope=["overview"],
        )

        self.assertTrue(plan["extract"])
        self.assertEqual("needs_review", plan["plan_status"])
        self.assertFalse(plan["composite_stub"])
        self.assertEqual(["overview"], plan["dashboards_scope"])
        self.assertEqual(1, len(plan["charts"]))
        chart = plan["charts"][0]
        self.assertEqual("Revenue by Region", chart["chart"])
        self.assertEqual("Sales Sheet", chart["tableau_view"])
        self.assertEqual("provenance", chart["matched_via"])
        self.assertEqual(["x-region", "y-sales"], chart["sigma_columns"])
        self.assertEqual(["Region", "Sales"], chart["sigma_column_names"])
        self.assertEqual([["East", 100.0], ["West", 200.0]], chart["expected"])
        self.assertEqual("wb-1", chart["workbookId"])
        self.assertIn('"workbook"."el-sales"', chart["sql_template"])

    def _pie_plan(self, kind):
        root, spec_path = self.fixture("Region,Pct of Sales,Sales\nEast,33.3%,100\nWest,66.7%,200\n")
        workbook = json.loads(spec_path.read_text(encoding="utf-8"))
        element = workbook["document"]["elements"][1]
        element["kind"] = kind
        element.pop("xAxis")
        element.pop("yAxis")
        element["columns"].append({"id": "lbl-pct", "name": "Pct of Sales"})
        element["color"] = {"columnId": "x-region"}
        element["value"] = {"columnId": "y-sales"}
        spec_path.write_text(json.dumps(workbook), encoding="utf-8")
        plan = auto_parity_plan.build_plan(
            root, spec_path, workbook_id="wb-1", dashboards_scope=["overview"]
        )
        return plan["charts"][0]

    def test_pie_and_donut_plan_only_plotted_columns(self):
        # 2026-11-05 live proof: a bar -> pie convert_to keeps its label column,
        # which a pie's export and MCP query never return.
        for kind in ("pie-chart", "donut-chart"):
            chart = self._pie_plan(kind)
            self.assertEqual(["x-region", "y-sales"], chart["sigma_columns"])
            self.assertEqual(["Region", "Sales"], chart["sigma_column_names"])
            self.assertEqual([["East", 100.0], ["West", 200.0]], chart["expected"])
            self.assertEqual(["Pct of Sales"], chart["unplotted_columns"])
            self.assertNotIn("lbl-pct", chart["sql_template"])

    def test_pie_keeps_an_unplotted_text_column(self):
        root, spec_path = self.fixture("Region,Segment,Sales\nEast,Retail,100\nWest,Online,200\n")
        workbook = json.loads(spec_path.read_text(encoding="utf-8"))
        element = workbook["document"]["elements"][1]
        element["kind"] = "pie-chart"
        element.pop("xAxis")
        element.pop("yAxis")
        element["columns"].append({"id": "seg", "name": "Segment"})
        element["color"] = {"columnId": "x-region"}
        element["value"] = {"columnId": "y-sales"}
        spec_path.write_text(json.dumps(workbook), encoding="utf-8")
        chart = auto_parity_plan.build_plan(
            root, spec_path, workbook_id="wb-1", dashboards_scope=["overview"]
        )["charts"][0]
        self.assertEqual(["x-region", "seg", "y-sales"], chart["sigma_columns"])
        self.assertNotIn("unplotted_columns", chart)

    def test_measure_names_values_csv_is_pivoted_to_wide(self):
        root, spec_path = self.fixture(
            "Month,Measure Names,Measure Values\n"
            "Jan,Sales,10\nJan,Profit,2\nFeb,Sales,20\nFeb,Profit,4\n"
        )
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        chart = spec["document"]["elements"][1]
        chart["columns"] = [
            {"id": "x-month", "name": "Month"},
            {"id": "y-sales", "name": "Sales"},
            {"id": "y-profit", "name": "Profit"},
        ]
        spec_path.write_text(json.dumps(spec), encoding="utf-8")

        plan = auto_parity_plan.build_plan(root, spec_path)

        self.assertEqual(
            [["Jan", 10.0, 2.0], ["Feb", 20.0, 4.0]],
            plan["charts"][0]["expected"],
        )
        self.assertEqual(
            ["x-month", "y-sales", "y-profit"],
            plan["charts"][0]["sigma_columns"],
        )

    def test_long_export_preserves_every_dimension_and_rejects_duplicate_cells(self):
        root, _ = self.fixture("Region,Segment,Measure Names,Measure Values\nNorth,007,Sales,10\nNorth,007,Profit,3\n")
        headers, rows = auto_parity_plan.read_expected_csv(root / "views/v1.csv", "Panel")
        self.assertEqual(["Region", "Segment", "Sales", "Profit"], headers)
        self.assertEqual([["North", "007", 10.0, 3.0]], rows)
        (root / "views/v1.csv").write_text("Region,Measure Names,Measure Values\nNorth,Sales,10\nNorth,Sales,20\n")
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "duplicate"):
            auto_parity_plan.read_expected_csv(root / "views/v1.csv", "Panel")

    def test_column_identity_never_falls_back_to_position_or_an_ambiguous_alias(self):
        chart = {"kind": "bar-chart", "id": "panel", "columns": [
            {"id": "x-birth", "name": "Birth"}, {"id": "y-year", "name": "Year of Birth"}],
            "xAxis": {"columnId": "x-birth"}, "yAxis": {"columnIds": ["y-year"]}}
        self.assertEqual(["y-year"], auto_parity_plan.select_columns(chart, ["Year of Birth"]))
        with self.assertRaises(auto_parity_plan.PlanError):
            auto_parity_plan.select_columns(chart, ["Unknown dimension", "Unknown measure"])
        chart["columns"] = [{"id": "y-a", "name": "Value"}, {"id": "y-b", "name": "Value"}]
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "ambiguous"):
            auto_parity_plan.select_columns(chart, ["Value"])

    def _plan(self, csv_body):
        root, spec_path = self.fixture(csv_body)
        return auto_parity_plan.build_plan(
            root, spec_path, workbook_id="wb-1", dashboards_scope=["overview"]
        )["charts"][0]

    def test_virtual_connection_qualified_headers_resolve_to_base_field(self):
        for header in (
            "Region (DIM_A (SCHEMA_A.DIM_A))",
            "Region (DIM_A (SCHEMA_A.DIM_A)) (DIM_B (SCHEMA_A.DIM_B))",
        ):
            chart = self._plan(f"{header},Sales\nEast,100\n")
            self.assertEqual(["x-region", "y-sales"], chart["sigma_columns"])
            self.assertEqual([["East", 100.0]], chart["expected"])
        chart = {"kind": "bar-chart", "id": "panel", "columns": [
            {"id": "x-a", "name": "Region", "table": "DIM_A"},
            {"id": "x-b", "name": "Region", "table": "DIM_B"}]}
        self.assertEqual(["x-b"], auto_parity_plan.select_columns(chart, ["Region (DIM_B (SCHEMA_A.DIM_B))"]))
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "ambiguous"):
            auto_parity_plan.select_columns(chart, ["Region (DIM_C (SCHEMA_A.DIM_C))"])

    def test_vc_suffix_forms_match_both_ways(self):
        # live-proof shape: the DM names the shared VC field "<field> (<table>)"
        dm = {"kind": "bar-chart", "id": "panel", "columns": [
            {"id": "x-state", "name": "State (DIM_A)"}, {"id": "y-sales", "name": "Sales"}]}
        self.assertEqual(["x-state", "y-sales"], auto_parity_plan.select_columns(
            dm, ["State (DIM_A (SCHEMA_A.DIM_A))", "Sales"]))
        # plain header, Sigma suffix is a VC table another header names
        mixed = {"kind": "bar-chart", "id": "panel", "columns": [
            {"id": "x-state", "name": "State (DIM_A)"}, {"id": "c-city", "name": "City"},
            {"id": "y-sales", "name": "Sales"}]}
        self.assertEqual(["x-state", "c-city", "y-sales"], auto_parity_plan.select_columns(
            mixed, ["State", "City (DIM_A (SCHEMA_A.DIM_A))", "Sales"]))
        # a non-table parenthetical is never peeled
        usd = {"kind": "bar-chart", "id": "panel", "columns": [
            {"id": "x-region", "name": "Region"}, {"id": "y-sales", "name": "Sales (USD)"}]}
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "unresolved"):
            auto_parity_plan.select_columns(usd, ["Region", "Sales"])

    def test_vc_qualified_flag_column_is_skipped_with_reason(self):
        element = {"kind": "bar-chart", "id": "panel", "columns": [
            {"id": "x-region", "name": "Region (DIM_A)"}, {"id": "y-sales", "name": "Sales"}]}
        header = ["Region (DIM_A (SCHEMA_A.DIM_A))", "Is Promo (DIM_P (SCHEMA_A.DIM_P))", "Sales"]
        kept, body, skipped = auto_parity_plan.drop_unplotted_columns(
            element, header, [["East", "True", "10"], ["West", "False", "20"]])
        self.assertEqual([header[0], header[2]], kept)
        self.assertEqual([["East", "10"], ["West", "20"]], body)
        self.assertEqual(["Is Promo (DIM_P (SCHEMA_A.DIM_P))"], [s["header"] for s in skipped])
        self.assertIn("formatting-only", skipped[0]["reason"])

    def test_generated_geo_and_flag_columns_are_skipped_with_recorded_reason(self):
        chart = self._plan(
            "Region,Latitude (generated),Longitude (generated),Over Flag,Sales\n"
            "East,1.5,2.5,true,100\nWest,3.5,4.5,false,200\n"
        )
        self.assertEqual(["x-region", "y-sales"], chart["sigma_columns"])
        self.assertEqual([["East", 100.0], ["West", 200.0]], chart["expected"])
        self.assertEqual(
            ["Latitude (generated)", "Longitude (generated)", "Over Flag"],
            [item["header"] for item in chart["skipped_columns"]],
        )
        self.assertTrue(all(item["reason"] for item in chart["skipped_columns"]))

    def test_tooltip_only_field_is_skipped_with_reason(self):
        # Stress 4 "Store State Map": the CSV exports the tooltip-only Orders
        # field; the Sigma region map plots Net Revenue only.
        dashboards = [{"zones": [{"kind": "chart", "caption": "Store State Map",
                                  "channels": {"color": {"column": "[ds].[sum:Sales Rank:qk]"},
                                               "tooltip": {"column": "[ds].[sum:Sales Rank:qk]"}},
                                  "measures": [{"column": "[Sales Rank]"}, {"column": "[Sales]"}],
                                  "tooltip_fields": ["[ds].[sum:Sales Rank:qk]", "[ds].[usr:Sales:qk]"]}]}]
        meta = {"columns_by_guid": {"Sales Rank": {"caption": "Net Revenue"}, "Sales": {"caption": "Orders"}}}
        self.assertEqual(["Orders"], auto_parity_plan.tooltip_only_captions(dashboards, meta, "Store State Map"))
        element = {"kind": "region-map", "id": "map", "columns": [
            {"id": "x-state", "name": "State (STORE_DIM)"}, {"id": "y-rev", "name": "Net Revenue"}]}
        header = ["State (STORE_DIM (DB.STORE_DIM))", "Orders", "Net Revenue"]
        kept, body, skipped = auto_parity_plan.drop_unplotted_columns(
            element, header, [["AZ", "0", ""], ["CA", "107", "15,964.83"]], ["Orders"])
        self.assertEqual([header[0], header[2]], kept)
        self.assertEqual(["Orders"], [s["header"] for s in skipped])
        self.assertIn("tooltip-only", skipped[0]["reason"])
        # a field on a plotted channel is never tooltip-only
        self.assertEqual([], auto_parity_plan.tooltip_only_captions(
            [{"zones": [dict(dashboards[0]["zones"][0], tooltip_fields=["[ds].[sum:Sales Rank:qk]"])]}], meta, "Store State Map"))
        # without the tooltip signal the unmatched column still aborts
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "unresolved"):
            kept, _, _ = auto_parity_plan.drop_unplotted_columns(element, header, [["AZ", "0", ""]])
            auto_parity_plan.select_columns(element, kept)

    def test_unmatched_numeric_column_is_not_skipped(self):
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "unresolved"):
            self._plan("Region,Mystery,Sales\nEast,5,100\nWest,6,200\n")

    def test_unmatched_singleton_text_dimension_is_not_skipped(self):
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "unresolved"):
            self._plan(
                "Region,Mystery,Sales\n"
                "East,Only Member,100\nWest,Only Member,200\n"
            )

    def test_table_calc_addressing_is_stripped_from_measure_names_labels(self):
        root, spec_path = self.fixture(
            "Measure Names,Month,Measure Values\n"
            "Rank - Mo along Table (Down),Jan,1\nVolume,Jan,10\n"
            "Rank - Mo along Table (Down),Feb,2\nVolume,Feb,20\n"
        )
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        chart = spec["document"]["elements"][1]
        chart["columns"] = [
            {"id": "x-month", "name": "Month"},
            {"id": "y-rank", "name": "Rank - Mo"},
            {"id": "y-volume", "name": "Volume"},
        ]
        spec_path.write_text(json.dumps(spec), encoding="utf-8")

        plan = auto_parity_plan.build_plan(root, spec_path)

        self.assertEqual(
            [["Jan", 1.0, 10.0], ["Feb", 2.0, 20.0]], plan["charts"][0]["expected"]
        )
        self.assertEqual(
            ["x-month", "y-rank", "y-volume"], plan["charts"][0]["sigma_columns"]
        )
        self.assertEqual("Rank - Mo", auto_parity_plan.header_base("Rank - Mo along Table (Down)"))
        self.assertEqual("Net Revenue", auto_parity_plan.header_base("Sum of Net Revenue"))

    def test_table_keeps_full_header_as_column_name_and_still_matches(self):
        # A rank table's column carries Tableau's full header; the CSV is pivoted under the
        # base name, so the plan must match the column through its own base name.
        root, spec_path = self.fixture(
            "Measure Names,Month,Measure Values\n"
            "Rank - Mo along Table (Down),Jan,1\nVolume,Jan,10\n"
            "Rank - Mo along Table (Down),Feb,2\nVolume,Feb,20\n"
        )
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        chart = spec["document"]["elements"][1]
        chart["columns"] = [
            {"id": "x-month", "name": "Month"},
            {"id": "y-rank", "name": "Rank - Mo along Table (Down)"},
            {"id": "y-volume", "name": "Volume"},
        ]
        spec_path.write_text(json.dumps(spec), encoding="utf-8")

        plan = auto_parity_plan.build_plan(root, spec_path)

        self.assertEqual(
            ["x-month", "y-rank", "y-volume"], plan["charts"][0]["sigma_columns"]
        )
        self.assertEqual(
            [["Jan", 1.0, 10.0], ["Feb", 2.0, 20.0]], plan["charts"][0]["expected"]
        )

    def test_hidden_filter_resolution_only_carries_when_definition_matches(self):
        root, spec_path = self.fixture()
        prior = {
            "hidden_filters": [
                {
                    "tile": "Sales Sheet",
                    "calc_ref": "[Calculation_1]",
                    "caption": "Current",
                    "filter_type": "categorical",
                    "members": ["Yes"],
                    "status": "translated",
                    "translated_to": "filter-1",
                }
            ]
        }
        plan = auto_parity_plan.build_plan(
            root, spec_path, prior_output=prior
        )
        self.assertEqual("green", plan["plan_status"])
        self.assertEqual("translated", plan["hidden_filters"][0]["status"])
        self.assertEqual("filter-1", plan["hidden_filters"][0]["translated_to"])

        layout = json.loads((root / "dashboard-layout.json").read_text())
        layout[0]["zones"][0]["hidden_filters"][0]["members"] = ["No"]
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        changed = auto_parity_plan.build_plan(
            root, spec_path, prior_output=prior
        )
        self.assertEqual("needs_review", changed["plan_status"])
        self.assertEqual("unresolved", changed["hidden_filters"][0]["status"])

    def write_ledger(self, root, entries):
        (root / "carried-calc-filters.json").write_text(
            json.dumps({"version": 1, "entries": entries}), encoding="utf-8"
        )

    @staticmethod
    def carried(**overrides):
        # A ledger entry as build-charts-from-signals.rb writes it for the
        # fixture's "Current" calc-filter (members ["Yes"]).
        entry = {
            "worksheet": "Sales Sheet",
            "dashboard": "Overview",
            "calc_caption": "Current",
            "calc_ref": "[Calculation_1]",
            "filter_type": "categorical",
            "kind": "list",
            "members": ["Yes"],
            "element_id": "el-sales",
            "sigma_column": "Current Match",
            "sigma_formula": 'Text(Contains([Region], "Yes"))',
            "mode": "boolean-calc",
        }
        entry.update(overrides)
        return entry

    def test_carried_calc_filters_ledger_resolves_matching_hidden_filters(self):
        root, spec_path = self.fixture()
        # Missing ledger: today's behaviour, the filter blocks.
        plan = auto_parity_plan.build_plan(root, spec_path)
        self.assertEqual("needs_review", plan["plan_status"])
        self.assertEqual("unresolved", plan["hidden_filters"][0]["status"])

        # Carried boolean calc -> translated, with the formula and the note.
        self.write_ledger(root, [self.carried()])
        plan = auto_parity_plan.build_plan(root, spec_path)
        hidden = plan["hidden_filters"][0]
        self.assertEqual("green", plan["plan_status"])
        self.assertEqual("translated", hidden["status"])
        self.assertEqual('Text(Contains([Region], "Yes"))', hidden["translated_to"])
        self.assertEqual("carried by build-charts-from-signals.rb", hidden["note"])

        # Carried search filter (members ["true"]) -> translated too.
        layout = json.loads((root / "dashboard-layout.json").read_text())
        layout[0]["zones"][0]["hidden_filters"][0]["members"] = ["true"]
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        self.write_ledger(
            root,
            [self.carried(members=["true"], mode="search-filter", sigma_formula=None)],
        )
        plan = auto_parity_plan.build_plan(root, spec_path)
        self.assertEqual("translated", plan["hidden_filters"][0]["status"])
        self.assertEqual("Current Match", plan["hidden_filters"][0]["translated_to"])

    def test_carried_calc_filters_ledger_never_resolves_a_different_filter(self):
        root, spec_path = self.fixture()
        cases = {
            "uncarried calc filter (ledger names another calc)": self.carried(
                calc_ref="[Calculation_9]", calc_caption="Other"
            ),
            "definition changed since the build": self.carried(members=["No"]),
            "filter type changed": self.carried(filter_type="quantitative"),
            "another worksheet's carry": self.carried(worksheet="Other Sheet"),
            "tile caption whitespace is part of the key": self.carried(
                worksheet="Sales Sheet "
            ),
            "carried on another dashboard only": self.carried(dashboard="Elsewhere"),
        }
        for label, entry in cases.items():
            with self.subTest(label):
                self.write_ledger(root, [entry])
                plan = auto_parity_plan.build_plan(root, spec_path)
                self.assertEqual("needs_review", plan["plan_status"])
                self.assertEqual("unresolved", plan["hidden_filters"][0]["status"])
        # An empty or unparseable ledger changes nothing.
        self.write_ledger(root, [])
        self.assertEqual(
            "needs_review", auto_parity_plan.build_plan(root, spec_path)["plan_status"]
        )
        (root / "carried-calc-filters.json").write_text("{not json", encoding="utf-8")
        self.assertEqual(
            "needs_review", auto_parity_plan.build_plan(root, spec_path)["plan_status"]
        )

    def test_quick_filter_left_at_all_is_not_a_hidden_filter(self):
        root, spec_path = self.fixture()
        layout = json.loads((root / "dashboard-layout.json").read_text())
        layout[0]["zones"][0]["hidden_filters"][0]["members"] = []
        layout[0]["zones"][0]["hidden_filters"][0]["kind"] = "list"
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        # No quick-filter zone for the field: an empty categorical calc
        # filter still gates (it may be an empty inclusive set).
        plan = auto_parity_plan.build_plan(root, spec_path)
        self.assertEqual("needs_review", plan["plan_status"])

        layout[0]["zones"].append({"kind": "filter", "filter_column_caption": "Current"})
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        plan = auto_parity_plan.build_plan(root, spec_path)
        self.assertEqual("green", plan["plan_status"])
        self.assertEqual([], plan["hidden_filters"])

        # Wildcard, condition and top-N filters also carry no members but
        # still restrict rows, so they gate.
        for kind, extra in (("wildcard", {}), ("list+condition", {}), ("list", {"topn": True})):
            with self.subTest(kind=kind, extra=extra):
                hidden = {k: v for k, v in layout[0]["zones"][0]["hidden_filters"][0].items() if k != "topn"}
                hidden.update(kind=kind, **extra)
                layout[0]["zones"][0]["hidden_filters"][0] = hidden
                (root / "dashboard-layout.json").write_text(json.dumps(layout))
                plan = auto_parity_plan.build_plan(root, spec_path)
                self.assertEqual("needs_review", plan["plan_status"])

        # A RESTRICTIVE quick filter (members selected) still gates.
        layout[0]["zones"][0]["hidden_filters"][0] = {
            k: v for k, v in layout[0]["zones"][0]["hidden_filters"][0].items() if k != "topn"
        }
        layout[0]["zones"][0]["hidden_filters"][0].update(kind="list", members=["Yes"])
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        plan = auto_parity_plan.build_plan(root, spec_path)
        self.assertEqual("needs_review", plan["plan_status"])

    def test_missing_or_empty_displayed_tile_csv_fails_closed(self):
        for body in ("Region,Sales\n", ""):
            with self.subTest(body=body):
                root, spec_path = self.fixture(body)
                with self.assertRaisesRegex(
                    auto_parity_plan.PlanError, "empty source CSV|zero source data rows"
                ):
                    auto_parity_plan.build_plan(root, spec_path)

        root, spec_path = self.fixture()
        (root / "views" / "v1.csv").unlink()
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "missing source CSV"):
            auto_parity_plan.build_plan(root, spec_path)

    def test_unmatched_source_or_sigma_displayed_tile_fails_closed(self):
        root, spec_path = self.fixture()
        layout = json.loads((root / "dashboard-layout.json").read_text())
        layout[0]["zones"].append(
            {
                "kind": "chart",
                "caption": "Dropped Sheet",
                "measures": ["Amount"],
                "rows_shelf": {"dim_count": 1},
            }
        )
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "no Sigma parity element"):
            auto_parity_plan.build_plan(root, spec_path)

        root, spec_path = self.fixture()
        provenance = json.loads((root / "chart-provenance.json").read_text())
        provenance["elements"]["el-sales"]["worksheet"] = "Not Displayed"
        (root / "chart-provenance.json").write_text(json.dumps(provenance))
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "no Tableau view matches"):
            auto_parity_plan.build_plan(root, spec_path)

    def test_main_does_not_replace_prior_artifact_with_partial_plan(self):
        root, spec_path = self.fixture("Region,Sales\n")
        out = root / "parity-plan.json"
        out.write_text('{"sentinel":"keep"}\n', encoding="utf-8")

        code = auto_parity_plan.main(
            [
                "--tableau",
                str(root),
                "--workbook-spec",
                str(spec_path),
                "--out",
                str(out),
            ]
        )

        self.assertEqual(1, code)
        self.assertEqual({"sentinel": "keep"}, json.loads(out.read_text()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
