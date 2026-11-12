import importlib.util
import hashlib
import json
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import blind_grade_v2 as bg  # noqa: E402
SCRIPT = HERE / "verify-complete.py"
spec = importlib.util.spec_from_file_location("verify_complete", SCRIPT)
verify_complete = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_complete)


class VerifyCompleteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tmp.name)
        self.blind = self.workdir / "blind.json"
        self.source_png = self.workdir / "source.png"
        self.target_png = self.workdir / "target.png"
        self.source_png.write_bytes(b"source pixels")
        self.target_png.write_bytes(b"target pixels")
        self.docs = {
            "mission.json": {
                key: {"value": key, "provenance": "stated"}
                for key in (
                    "source",
                    "sigma_connection",
                    "destination",
                    "landing",
                    "scope",
                )
            },
            "datamodel-readback-verdict.json": {"pass": True},
            "workbook-readback-verdict.json": {"pass": True},
            "parity-final.json": {"match": True},
            "anchors-verdict.json": {"pass": True},
            "visual-similarity-final.json": {
                "pass": True,
                "source_health": {"path": str(self.source_png)},
                "render_health": {"path": str(self.target_png)},
            },
            "semantic-edits.json": {"match": True},
            "reconstruction-integrity.json": {
                "status": "PASS",
                "unresolved_controls": [],
                "renamed_chart_family_mismatches": [],
            },
            "source-object-census.json": {
                "summary": {"complete": True, "total": 0},
                "objects": [],
            },
            "security-decision.json": {
                "decision": "not-required",
                "rules_detected": 0,
            },
            "dm-ids.json": {"dataModelId": "dm-1"},
            "wb-ids.json": {"workbookId": "wb-1"},
        }
        for name, value in self.docs.items():
            (self.workdir / name).write_text(json.dumps(value), encoding="utf-8")
        (self.workdir / "conv-meta.json").write_text(
            json.dumps({"security": []}), encoding="utf-8"
        )
        (self.workdir / "workbook-content.twb").write_text(
            "<workbook/>", encoding="utf-8"
        )
        (self.workdir / "dashboard-scope.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "mode": "full",
                    "provenance": "full-workbook",
                    "dashboards": [],
                }
            ),
            encoding="utf-8",
        )
        (self.workdir / "wb-spec-python.json").write_text(
            json.dumps(
                {
                    "name": "Fixture",
                    "document": {
                        "schemaVersion": 1,
                        "pages": [],
                        "elements": [],
                        "layout": "",
                    },
                }
            ),
            encoding="utf-8",
        )
        (self.workdir / "relationship-coverage.json").write_text(
            json.dumps(
                verify_complete.relationship_coverage_lib.from_files(
                    self.workdir / "conv-meta.json",
                    self.workdir / "workbook-content.twb",
                )
            ),
            encoding="utf-8",
        )
        (self.workdir / "dashboard-coverage.json").write_text(
            json.dumps(
                verify_complete.dashboard_coverage_lib.evaluate(
                    self.workdir / "workbook-content.twb",
                    self.workdir / "wb-spec-python.json",
                    json.loads(
                        (self.workdir / "dashboard-scope.json").read_text(
                            encoding="utf-8"
                        )
                    ),
                )
            ),
            encoding="utf-8",
        )
        (self.workdir / "dm-raw.json").write_text(
            json.dumps(
                {"schemaVersion": 1, "pages": [{"id": "model", "elements": []}]}
            ),
            encoding="utf-8",
        )
        (self.workdir / "sql-provenance.json").write_text(
            json.dumps(
                verify_complete.sql_provenance_lib.evaluate(
                    self.workdir / "dm-raw.json",
                    self.workdir / "conv-meta.json",
                    self.workdir / "workbook-content.twb",
                    self.workdir / "custom-sql.json",
                    self.workdir / "sql-provenance-overrides.json",
                )
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def write_blind(self, verdict):
        self.blind.write_text(
            json.dumps(
                {
                    "verdict": verdict,
                    "source_png": str(self.source_png),
                    "target_png": str(self.target_png),
                    "source_sha256": hashlib.sha256(self.source_png.read_bytes()).hexdigest(),
                    "target_sha256": hashlib.sha256(self.target_png.read_bytes()).hexdigest(),
                    "dimensions": {
                        "composition_match": {
                            "verdict": verdict,
                            "evidence": "fixture",
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

    def use_relationship_route(self, parity_failures=()):
        import shutil
        fixtures = HERE / "test-fixtures" / "relationship-map" / "replaced-key"
        rm = verify_complete.relationship_map_lib
        for name in ("workbook-content.twb", "dm-spec-reused.json"):
            shutil.copy(fixtures / name, self.workdir / name)
        doc = rm.derive(
            twb_xml=(self.workdir / "workbook-content.twb").read_text(encoding="utf-8-sig"),
            dm_spec=json.loads((self.workdir / "dm-spec-reused.json").read_text(encoding="utf-8")),
            dashboards=rm.scoped_dashboards(json.loads((self.workdir / "dashboard-scope.json").read_text(encoding="utf-8"))),
        )
        for edge in doc["dm_edges"]:
            edge["probe"] = {"status": "pass", "unique": {"total": 3, "distinct": 3}, "unmatched": 0}
        rm.write(self.workdir / "relationship-map.json", doc)
        (self.workdir / "parity-expected.json").write_text(
            json.dumps({"Revenue by Customer": [["a", 1]], "Revenue by Product": [["b", 2]]}), encoding="utf-8")
        parity = json.loads((self.workdir / "parity-final.json").read_text(encoding="utf-8"))
        parity["differences"] = [{"path": f"$.{name}[0]", "kind": "number"} for name in parity_failures]
        (self.workdir / "parity-final.json").write_text(json.dumps(parity), encoding="utf-8")
        (self.workdir / "relationship-coverage.json").unlink()
        (self.workdir / "migrate-state-python.json").write_text(
            json.dumps({"relationship_route": "reused-dm-evidence", "data_model_id": "dm-reused"}), encoding="utf-8")

    def relationship_failures(self, result):
        return [f for f in result["failures"] if f.startswith("relationship_coverage")]

    def test_reused_dm_evidence_route_replaces_relationship_coverage(self):
        self.write_blind("pass")
        self.use_relationship_route()
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual([], self.relationship_failures(result), result["failures"])

    def test_reused_dm_evidence_route_blocks_unproven_deviation(self):
        self.write_blind("pass")
        self.use_relationship_route(parity_failures=["Revenue by Customer"])
        result = verify_complete.evaluate(self.workdir, self.blind)
        failures = self.relationship_failures(result)
        self.assertEqual(1, len(failures), result["failures"])
        self.assertIn("parity-failed", failures[0])

    def write_v2(self, overall=90, gaps=None, fail_dims=(), name="blind.json"):
        catalog = bg.shipped_catalog()
        doc = {
            "schema": bg.SCHEMA_V2,
            "source_png": str(self.source_png),
            "target_png": str(self.target_png),
            "source_sha256": hashlib.sha256(self.source_png.read_bytes()).hexdigest(),
            "target_sha256": hashlib.sha256(self.target_png.read_bytes()).hexdigest(),
            "catalog_sha256": catalog["sha256"],
            "dimensions": {
                k: {"verdict": "fail" if k in fail_dims else "pass", "evidence": "f"}
                for k in bg.DIMENSION_KEYS
            },
            "per_tile": [{"position": 1, "source_family": "bar", "target_family": "bar"}],
            "scores": {k: 9 for k in bg.DIMENSION_KEYS},
            "overall_score": overall,
            "gaps": gaps or [],
        }
        (self.workdir / name).write_text(json.dumps(doc), encoding="utf-8")
        return catalog

    def gap(self, **kw):
        base = {"tile": "Tile A", "dimension": "composition_match",
                "description": "legend moved", "severity": "minor", "class": "fixable"}
        base.update(kw)
        return base

    def test_v2_unfaithful_is_yellow_not_blocked(self):
        self.write_v2(overall=90, gaps=[self.gap(severity="major")])
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual([], result["failures"])
        self.assertTrue(result["complete"])
        self.assertEqual("YELLOW", result["verdict"])
        visual = result["visual_fidelity"]
        self.assertFalse(visual["faithful"])
        self.assertEqual(1, len(visual["fixable_major"]))
        self.assertTrue(visual["reasons"])
        items = [d["item"] for d in result["degradations"]]
        self.assertIn("visual residual (major): Tile A: legend moved", items)

    def test_v2_low_score_is_yellow_not_blocked(self):
        self.write_v2(overall=40)
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("YELLOW", result["verdict"])
        self.assertTrue(result["complete"])

    def test_v2_faithful_green(self):
        catalog = self.write_v2(overall=90)
        entry = catalog["entries"][0]
        doc = json.loads(self.blind.read_text())
        doc["gaps"] = [self.gap(**{"class": entry["id"], "dimension": entry["dimension"]})]
        self.blind.write_text(json.dumps(doc))
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual([], result["failures"])
        self.assertEqual("GREEN", result["verdict"])
        self.assertTrue(result["visual_fidelity"]["faithful"])
        self.assertEqual(entry["id"], result["platform_differences"][0]["catalog_id"])
        self.assertEqual([], result["degradations"])

    def test_v2_faithful_minor_only_is_green_with_polish_notes(self):
        self.write_v2(overall=90, gaps=[self.gap()])
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("GREEN", result["verdict"])
        self.assertTrue(result["visual_fidelity"]["faithful"])
        self.assertEqual([], result["degradations"])
        self.assertEqual(
            [{"item": "Tile A: legend moved", "dimension": "composition_match",
              "source_artifact": "blind.json"}],
            result["polish_notes"],
        )
        self.assertEqual(1, len(result["visual_fidelity"]["residuals"]))

    def test_v2_faithful_minor_plus_platform_difference_is_green_with_both(self):
        catalog = self.write_v2(overall=90)
        entry = catalog["entries"][0]
        doc = json.loads(self.blind.read_text())
        doc["gaps"] = [
            self.gap(),
            self.gap(**{"class": entry["id"], "dimension": entry["dimension"]}),
        ]
        self.blind.write_text(json.dumps(doc))
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("GREEN", result["verdict"])
        self.assertEqual([], result["degradations"])
        self.assertEqual(1, len(result["polish_notes"]))
        self.assertEqual(1, len(result["platform_differences"]))

    def test_v2_major_gap_makes_minor_a_degradation_not_polish(self):
        self.write_v2(overall=90, gaps=[self.gap(severity="major", description="bad"), self.gap()])
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("YELLOW", result["verdict"])
        items = [d["item"] for d in result["degradations"]]
        self.assertIn("visual residual (major): Tile A: bad", items)
        self.assertIn("visual residual (minor): Tile A: legend moved", items)
        self.assertEqual([], result["polish_notes"])

    def test_v2_low_score_minor_only_is_degradation(self):
        self.write_v2(overall=40, gaps=[self.gap()])
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("YELLOW", result["verdict"])
        self.assertIn("visual residual (minor): Tile A: legend moved",
                      [d["item"] for d in result["degradations"]])
        self.assertEqual([], result["polish_notes"])

    def test_v2_faithful_minor_with_security_skip_is_yellow_minors_stay_notes(self):
        self.write_v2(overall=90, gaps=[self.gap()])
        decision = self.workdir / "security-decision.json"
        doc = json.loads(decision.read_text())
        doc["decision"] = "skip"
        decision.write_text(json.dumps(doc))
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("YELLOW", result["verdict"])
        self.assertEqual([], result["degradations"])
        self.assertEqual(1, len(result["polish_notes"]))

    def end_to_end(self):
        """evaluate -> report -> assert-phase6 gate_report, as run_gates would."""
        import importlib.util as iu
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual([], result["failures"])
        (self.workdir / "migration-result.json").write_text(json.dumps(result))
        def load(name, path):
            # Register before exec: @dataclass resolves cls.__module__ via
            # sys.modules (Python 3.12 raises on an unregistered module).
            spec = iu.spec_from_file_location(name, path)
            module = iu.module_from_spec(spec)
            sys.modules[name] = module
            try:
                spec.loader.exec_module(module)
            except BaseException:
                sys.modules.pop(name, None)
                raise
            return module

        rmod = load("vc_e2e_build_migration_report", HERE / "build-migration-report.py")
        (self.workdir / "MIGRATION_REPORT.md").write_text(rmod.report(self.workdir))
        gmod = load("vc_e2e_assert_phase6_ran", HERE / "assert-phase6-ran.py")
        verdict, _dm, _wb = gmod.gate_report(self.workdir)
        return result, verdict

    def test_v2_low_score_no_gaps_completes_yellow_through_gate_report(self):
        self.write_v2(overall=40)
        result, verdict = self.end_to_end()
        self.assertEqual("YELLOW", verdict)
        self.assertIn("visual verdict: divergent", [d["item"] for d in result["degradations"]])

    def test_v2_hard_dimension_fail_no_gaps_completes_yellow_through_gate_report(self):
        self.write_v2(overall=90, fail_dims=("numbers_formatted",))
        result, verdict = self.end_to_end()
        self.assertEqual("YELLOW", verdict)
        self.assertIn("visual verdict: divergent", [d["item"] for d in result["degradations"]])

    def test_v2_faithful_minor_completes_green_through_gate_report_with_notes_section(self):
        self.write_v2(overall=90, gaps=[self.gap()])
        result, verdict = self.end_to_end()
        self.assertEqual("GREEN", verdict)
        self.assertEqual(1, len(result["polish_notes"]))
        report = (self.workdir / "MIGRATION_REPORT.md").read_text()
        self.assertIn("## Minor polish notes", report)
        self.assertIn("- Tile A: legend moved [composition_match]", report)
        self.assertNotIn("## Fidelity residuals", report)

    def set_census_status(self, status):
        path = self.workdir / "source-object-census.json"
        statuses = ("migrated", "approximated", "needs-review", "skipped", "not-applicable")
        doc = {
            "summary": {"complete": True, "total": 1, "accounted": 1,
                        "counts": {k: int(k == status) for k in statuses}},
            "objects": [{"type": "dashboard", "id": "dashboard:Sales", "name": "Sales",
                         "status": status,
                         "evidence": [{"artifact": "wb-readback.json", "detail": "fixture"}]}],
        }
        path.write_text(json.dumps(doc))

    def test_rcc_shape_polish_only_needs_review_is_yellow_everywhere(self):
        # 2026-11-09 RCC: empty degradations, polish notes only, census
        # needs-review=1 -> verify-complete, the report and the gate all YELLOW.
        self.write_v2(overall=90, gaps=[self.gap()])
        self.set_census_status("needs-review")
        result, verdict = self.end_to_end()
        self.assertEqual("YELLOW", result["verdict"])
        self.assertEqual("YELLOW", verdict)
        self.assertEqual([], result["degradations"])
        self.assertEqual(1, len(result["polish_notes"]))
        self.assertIn("**Verdict:** YELLOW", (self.workdir / "MIGRATION_REPORT.md").read_text())

    def test_oeo_shape_polish_only_clean_census_is_green_everywhere(self):
        self.write_v2(overall=90, gaps=[self.gap()])
        self.set_census_status("migrated")
        result, verdict = self.end_to_end()
        self.assertEqual("GREEN", result["verdict"])
        self.assertEqual("GREEN", verdict)
        self.assertEqual(1, len(result["polish_notes"]))

    def test_v2_faithful_completes_green_through_gate_report(self):
        self.write_v2(overall=90)
        _result, verdict = self.end_to_end()
        self.assertEqual("GREEN", verdict)

    def test_v2_single_borderline_blocks(self):
        self.write_v2(overall=72)
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("BLOCKED", result["verdict"])
        self.assertTrue(any("second blind grader required" in f for f in result["failures"]))

    def test_v2_borderline_with_second_grade_uses_mean(self):
        self.write_v2(overall=72)
        self.write_v2(overall=84, name="blind-grade-2.json")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual([], result["failures"])
        self.assertEqual("GREEN", result["verdict"])
        self.assertEqual(78.0, result["visual_fidelity"]["score"])

    def test_v2_unknown_catalog_id_blocks(self):
        self.write_v2(overall=90, gaps=[self.gap(**{"class": "invented-difference"})])
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("BLOCKED", result["verdict"])
        self.assertTrue(any("invented-difference" in f for f in result["failures"]))

    def test_v2_catalog_sha_mismatch_blocks(self):
        self.write_v2(overall=90)
        doc = json.loads(self.blind.read_text())
        doc["catalog_sha256"] = "0" * 64
        self.blind.write_text(json.dumps(doc))
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("BLOCKED", result["verdict"])
        self.assertTrue(any("catalog_sha256 mismatch" in f for f in result["failures"]))

    def test_v1_rule_unchanged(self):
        self.write_blind("fail")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("BLOCKED", result["verdict"])
        self.assertNotIn("visual_fidelity", result)
        self.write_blind("pass")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertEqual("GREEN", result["verdict"])
        self.assertNotIn("visual_fidelity", result)

    def test_green_requires_every_gate(self):
        self.write_blind("pass")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertTrue(result["complete"])
        self.assertEqual("GREEN", result["status"])

    def test_blind_visual_failure_blocks_completion(self):
        self.write_blind("fail")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertIn("blind_grade: visual fidelity failed", result["failures"][0])

    def test_current_verifier_failure_overrides_passing_blind_and_numeric_evidence(self):
        self.write_blind("pass")
        for body in ('{"verdict":"RED"}', '{"verdict":"YELLOW"}', '{', '{}', '{"verdict":"GREEN","divergences":{}}'):
            with self.subTest(body=body):
                (self.workdir / "verification-result.json").write_text(body, encoding="utf-8")
                result = verify_complete.evaluate(self.workdir, self.blind)
                self.assertFalse(result["complete"])
                self.assertTrue(any("verification" in failure for failure in result["failures"]))
        (self.workdir / "verification-result.json").write_text('{"verdict":"GREEN"}', encoding="utf-8")
        self.assertTrue(verify_complete.evaluate(self.workdir, self.blind)["complete"])

    def test_bom_cosmetic_and_contradictory_green_findings(self):
        self.write_blind("pass")
        for severity in ("number", "structural", "cosmetic", None, {}):
            with self.subTest(severity=severity):
                document = {"verdict": "GREEN", "divergences": [{"severity": severity}]}
                (self.workdir / "verification-result.json").write_text("\ufeff" + json.dumps(document), encoding="utf-8")
                result = verify_complete.evaluate(self.workdir, self.blind)
                self.assertEqual(severity == "cosmetic", result["complete"])

    def test_deeply_nested_verification_blocks_without_losing_source_accounting(self):
        self.write_blind("pass")
        (self.workdir / "source-object-census.json").write_text(json.dumps({
            "summary": {"complete": True, "total": 1},
            "objects": [{"id": "panel-1", "type": "worksheet", "status": "migrated"}],
        }), encoding="utf-8")
        prior = verify_complete.evaluate(self.workdir, self.blind)
        (self.workdir / "verification-result.json").write_text("[" * 2000 + "0" + "]" * 2000, encoding="utf-8")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertEqual(prior["source_objects"], result["source_objects"])
        self.assertEqual(prior["summary"]["counts"], result["summary"]["counts"])

    def test_failed_completion_run_archives_old_result(self):
        output = self.workdir / "migration-result.json"
        output.write_text('{"verdict":"GREEN"}', encoding="utf-8")
        with mock.patch.object(verify_complete, "evaluate", side_effect=ValueError("synthetic failure")), mock.patch(
            "sys.argv", [str(SCRIPT), "--workdir", str(self.workdir), "--blind-grade", str(self.blind)]
        ):
            self.assertEqual(2, verify_complete.main())
        self.assertFalse(output.exists())
        history = list((self.workdir / "report-history").glob("migration-result-*.json"))
        self.assertEqual(1, len(history))
        self.assertEqual('{"verdict":"GREEN"}', history[0].read_text(encoding="utf-8"))

    def test_inferred_mission_field_blocks_completion(self):
        mission = self.docs["mission.json"]
        mission["destination"]["provenance"] = "inferred"
        (self.workdir / "mission.json").write_text(
            json.dumps(mission), encoding="utf-8"
        )
        self.write_blind("pass")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertTrue(any("destination" in item for item in result["failures"]))

    def test_reconstruction_integrity_failure_blocks_completion(self):
        (self.workdir / "reconstruction-integrity.json").write_text(
            json.dumps(
                {
                    "status": "FAIL",
                    "unresolved_controls": [
                        {
                            "kind": "parameter",
                            "name": "Date Grain",
                            "status": "needs-wiring",
                        }
                    ],
                    "renamed_chart_family_mismatches": [],
                }
            ),
            encoding="utf-8",
        )
        self.write_blind("pass")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertTrue(
            any("reconstruction_integrity" in item for item in result["failures"])
        )

    def test_stale_blind_grade_hash_blocks_completion(self):
        self.write_blind("pass")
        self.target_png.write_bytes(b"changed pixels")
        result = verify_complete.evaluate(self.workdir, self.blind)
        self.assertFalse(result["complete"])
        self.assertTrue(any("stale target_png hash" in item for item in result["failures"]))


if __name__ == "__main__":
    unittest.main()
