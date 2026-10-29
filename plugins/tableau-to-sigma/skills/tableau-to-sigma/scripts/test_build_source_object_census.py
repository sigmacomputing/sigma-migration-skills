import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "build-source-object-census.py"
spec = importlib.util.spec_from_file_location("build_source_object_census", SCRIPT)
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)


class BuildSourceObjectCensusTest(unittest.TestCase):
    def test_complete_builder_and_formula_artifacts_are_accounted(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            (workdir / "formula-audit.json").write_text(
                json.dumps(
                    {
                        "formulas": [
                            {
                                "internal_name": "calc-1",
                                "calculation": "Revenue",
                                "status": "spec",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            (workdir / "workbook-residues.json").write_text(
                json.dumps(
                    {
                        "status": "complete",
                        "residues": [],
                        "dispositions": [
                            {
                                "dashboard": "Overview",
                                "zoneId": "zone-1",
                                "zoneKind": "chart",
                                "status": "emitted",
                                "elementId": "chart-1",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            result = census.build(workdir)
            self.assertTrue(result["summary"]["complete"])
            self.assertEqual(2, result["summary"]["total"])
            self.assertEqual(
                {"migrated"},
                {item["status"] for item in result["objects"]},
            )

    def test_residue_keeps_census_terminal_but_blocks_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            (workdir / "formula-audit.json").write_text(
                json.dumps({"formulas": []}), encoding="utf-8"
            )
            (workdir / "workbook-residues.json").write_text(
                json.dumps(
                    {
                        "residues": [
                            {
                                "zoneId": "zone-1",
                                "caption": "Unsupported",
                                "reason": "not bound",
                            }
                        ],
                        "dispositions": [],
                    }
                ),
                encoding="utf-8",
            )
            result = census.build(workdir)
            self.assertFalse(result["summary"]["complete"])
            self.assertEqual("needs-review", result["objects"][0]["status"])

    def test_trailing_space_names_keep_distinct_identities(self):
        # Tableau allows dashboards named "X", "X " and "X  ". The Python census
        # keys ids by the exact name (no strip/fold), so they stay three objects;
        # this pins that against a future normalisation (the Ruby census twin
        # once merged them through its id helper).
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            names = ["X", "X ", "X  "]
            (workdir / "dashboard-coverage.json").write_text(
                json.dumps(
                    {
                        "visible_source_dashboards": names,
                        "expected_dashboards": names,
                        "built_pages": names,
                    }
                ),
                encoding="utf-8",
            )
            result = census.build(workdir)
            dashboards = [o for o in result["objects"] if o["type"] == "dashboard"]
            self.assertEqual(names, [o["name"] for o in dashboards])
            self.assertEqual(3, len({o["id"] for o in dashboards}))
            self.assertEqual(
                ["dashboard:X", "dashboard:X ", "dashboard:X  "],
                [o["id"] for o in dashboards],
            )


if __name__ == "__main__":
    unittest.main()
