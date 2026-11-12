import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "build-migration-report.py"
spec = importlib.util.spec_from_file_location("build_migration_report", SCRIPT)
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class BuildMigrationReportTest(unittest.TestCase):
    def test_report_surfaces_blocking_gate_without_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            fixtures = {
                "mission.json": {
                    "source": {"value": "Fixture", "provenance": "stated"},
                    "sigma_connection": {"value": "Connection", "provenance": "stated"},
                    "destination": {"value": "Folder", "provenance": "stated"},
                    "landing": {"value": "n/a", "provenance": "stated"},
                    "scope": {"value": ["Overview"], "provenance": "stated"},
                },
                "migration-result.json": {
                    "status": "BLOCKED",
                    "dataModelId": "dm-1",
                    "workbookId": "wb-1",
                    "gates": {"numeric_parity": True, "blind_visual_grade": False},
                    "failures": ["blind visual mismatch"],
                },
                "parity-final.json": {"status": "PASS", "differences": []},
                "visual-similarity-final.json": {"pass": True, "score_overall": 0.9},
                "semantic-edits.json": {"match": True},
                "source-object-census.json": {
                    "summary": {"complete": True, "total": 1},
                    "objects": [
                        {
                            "type": "formula",
                            "id": "calc-1",
                            "name": "Metric",
                            "status": "migrated",
                        }
                    ],
                },
                "conv-meta.json": {"warnings": [], "workbookPatterns": [], "security": []},
            }
            for name, value in fixtures.items():
                (workdir / name).write_text(json.dumps(value), encoding="utf-8")
            report = reporter.report(workdir)
            self.assertIn("**Verdict:** BLOCKED", report)
            self.assertIn("PASS — numeric parity", report)
            self.assertIn("FAIL — blind visual grade", report)
            self.assertIn("blind visual mismatch", report)
            self.assertIn("| formula | calc-1 | Metric | migrated |", report)
            self.assertNotIn("oracle substituted", report)

            # A vds tile on an embedded source verified by view-csv anchors is
            # named in the report (a recorded substitution, not a waiver).
            (workdir / "parity-final.json").write_text(json.dumps({
                "status": "PASS", "differences": [],
                "numeric_parity": {"oracle_substitutions": [{
                    "tile": "% of Total Net Revenue by Store Region", "oracle": "anchors",
                    "substituted_for": "vds", "reason": "no published-datasource LUID"}]},
            }), encoding="utf-8")
            report = reporter.report(workdir)
            self.assertIn("Ground-truth oracle substituted: % of Total Net Revenue by Store Region "
                          "(anchors for vds — no published datasource LUID; not a waiver)", report)

    def test_report_names_residuals_and_platform_differences(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            (workdir / "migration-result.json").write_text(json.dumps({
                "verdict": "YELLOW",
                "degradations": [{
                    "kind": "fidelity-residual",
                    "item": "visual residual (major): Tile A: legend moved",
                    "reason": "major fixable gap recorded by the blind visual grade and left in the render (run is divergent)",
                    "source_artifact": "blind-grade.json",
                }],
                "platform_differences": [{
                    "item": "Filter: All placeholder is grey",
                    "catalog_id": "list-control-all-placeholder",
                    "source_artifact": "blind-grade.json",
                }],
            }), encoding="utf-8")
            report = reporter.report(workdir)
            self.assertIn("visual residual (major): Tile A: legend moved", report)
            self.assertIn("## Platform differences", report)
            self.assertIn("**list-control-all-placeholder** — Filter: All placeholder is grey", report)
            self.assertIn("do not affect the verdict", report)

    def test_report_renders_minor_polish_notes_section(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            (workdir / "migration-result.json").write_text(json.dumps({
                "verdict": "GREEN",
                "degradations": [],
                "polish_notes": [
                    {"item": "Tile A: legend moved", "dimension": "composition_match",
                     "source_artifact": "blind-grade.json"},
                    {"item": "Tile B: gap", "dimension": "",
                     "source_artifact": "blind-grade.json"},
                ],
            }), encoding="utf-8")
            report = reporter.report(workdir)
            self.assertIn(
                "## Minor polish notes\n\nNot degradations: the blind visual grade passed, "
                "and these minor differences are optional polish. They do not affect the "
                "verdict.\n\n- Tile A: legend moved [composition_match]\n- Tile B: gap\n",
                report,
            )
            self.assertNotIn("## Fidelity residuals", report)

    def test_report_without_polish_notes_has_no_section(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertNotIn("## Minor polish notes", reporter.report(Path(tmp)))

    def test_report_without_platform_differences_has_no_section(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = reporter.report(Path(tmp))
            self.assertNotIn("## Platform differences", report)


if __name__ == "__main__":
    unittest.main()
