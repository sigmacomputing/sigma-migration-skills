#!/usr/bin/env python3
"""Offline tests: a divergent / not-executable visual verdict is YELLOW, not RED."""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
BUILDER = SCRIPTS / "build-migration-report.py"
sys.path.insert(0, str(SCRIPTS / "lib"))
import degradation_ledger  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[4]


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def build(parity_extra, *, ledger=True, render=True, blank=True, health=True):
    with tempfile.TemporaryDirectory() as tmp:
        wd = Path(tmp)
        write_json(wd / "inventory.json", {"objects": [
            {"type": "dashboard", "id": "d1", "name": "Sales", "status": "migrated"}]})
        write_json(wd / "parity-final.json", {
            "status": "PASS", "charts_pass": 2, "charts_total": 2, "waivers": [],
            **parity_extra})
        if ledger:
            write_json(wd / "degradation-ledger.json", {"entries": [], "counts": {}})
        if render:
            write_json(wd / "dashboard-render-health.json",
                       {"status": "healthy", "failed_count": 0} if health
                       else {"status": "failed", "errors": ["blank page"]})
        if blank:
            write_json(wd / "dashboard-blank-risk.json", {"risk": False, "blank_count": 0})
        proc = subprocess.run(
            [sys.executable, str(BUILDER), "--workdir", str(wd),
             "--inventory", str(wd / "inventory.json")],
            capture_output=True, text=True)
        result = json.loads((wd / "migration-result.json").read_text(encoding="utf-8"))
        return result, proc.returncode


def build_evidence(similarity=None, anchors=True, blank_artifact=None, png=True, waivers=None):
    """Real-run shape: no render-health / blank-risk artifacts, divergent verdict."""
    with tempfile.TemporaryDirectory() as tmp:
        wd = Path(tmp)
        write_json(wd / "inventory.json", {"objects": [
            {"type": "dashboard", "id": "d1", "name": "Sales", "status": "migrated"}]})
        if png:
            (wd / "rcf-pass-3.png").write_bytes(b"png")
        write_json(wd / "parity-final.json", {
            "status": "PASS", "charts_pass": 2, "charts_total": 2,
            "waivers": waivers or [],
            "visual_checked": False, "visual_verdict": "divergent",
            "visual_notes": "legend differs",
            "screenshot_path": str(wd / "rcf-pass-3.png")})
        write_json(wd / "degradation-ledger.json", {"entries": [], "counts": {}})
        if similarity != "absent":
            doc = {"pass": True, "tiles_measured": 0, "tiles_blank": [],
                   "render_health": {"path": str(wd / "rcf-pass-3.png"),
                                     "status": "PASS", "reasons": []},
                   "source_health": {"status": "PASS"}}
            for key, value in (similarity or {}).items():
                if key == "render_health" and isinstance(value, dict):
                    doc[key] = {**doc[key], **value}
                else:
                    doc[key] = value
            write_json(wd / "visual-similarity.json", doc)
        if anchors is not None:
            write_json(wd / "anchors-verdict.json", {"tiles_all_nonempty": anchors})
        if blank_artifact is not None:
            write_json(wd / "blank-risk-elements.json", blank_artifact)
        proc = subprocess.run(
            [sys.executable, str(BUILDER), "--workdir", str(wd),
             "--inventory", str(wd / "inventory.json")],
            capture_output=True, text=True)
        result = json.loads((wd / "migration-result.json").read_text(encoding="utf-8"))
        return result, proc.returncode


def check_named(result, name):
    return next(c for c in result["checks"] if c["name"] == name)


DIVERGENT = {"visual_checked": False, "visual_verdict": "divergent",
             "visual_notes": "legend differs", "screenshot_path": "shot.png"}


class VisualVerdictReportTest(unittest.TestCase):
    def test_divergent_is_yellow(self):
        result, code = build(DIVERGENT, ledger=False)
        self.assertEqual(result["verdict"], "YELLOW")
        self.assertEqual(code, 0)
        self.assertEqual(check_named(result, "render-health")["status"], "PASS")
        self.assertEqual(result["degradations"], [{
            "class": "fidelity-residual", "item": "visual verdict: divergent",
            "reason": "recorded source-vs-target visual gaps ship in the render",
            "source_artifact": "parity-final.json"}])

    def test_not_executable_is_yellow_with_notes(self):
        result, _ = build({"visual_checked": False, "visual_verdict": "not-executable",
                           "visual_notes": "no browser"}, ledger=False)
        self.assertEqual(result["verdict"], "YELLOW")
        self.assertIn({"class": "fidelity-residual",
                       "item": "visual verdict: not-executable", "reason": "no browser",
                       "source_artifact": "parity-final.json"}, result["degradations"])

    def test_ledger_present_not_duplicated_but_still_yellow(self):
        result, _ = build(DIVERGENT)
        self.assertEqual(result["verdict"], "YELLOW")
        self.assertEqual(result["degradations"], [])

    def test_divergent_is_not_render_evidence(self):
        result, _ = build(DIVERGENT, render=False, blank=False)
        render = check_named(result, "render-health")
        self.assertEqual(render["status"], "FAIL")
        self.assertIn("no healthy render evidence", render["message"])
        self.assertEqual(check_named(result, "blank-risk")["status"], "PASS")

    def test_pass_without_screenshot_covers_blank_risk(self):
        result, _ = build({"visual_checked": False, "visual_verdict": "pass"},
                          render=False, blank=False)
        self.assertEqual(check_named(result, "blank-risk")["status"], "PASS")

    def test_divergent_without_screenshot_does_not_cover_blank_risk(self):
        parity = {k: v for k, v in DIVERGENT.items() if k != "screenshot_path"}
        result, _ = build(parity, render=False, blank=False)
        self.assertEqual(check_named(result, "blank-risk")["status"], "FAIL")

    def test_broken_render_stays_red(self):
        result, _ = build({"visual_checked": True, "visual_verdict": "pass"}, health=False)
        self.assertEqual(result["verdict"], "RED")

    def test_visual_pass_stays_green(self):
        result, _ = build({"visual_checked": True, "visual_verdict": "pass"})
        self.assertEqual(result["verdict"], "GREEN")


class RenderEvidenceTest(unittest.TestCase):
    def test_tile_census_run_is_yellow(self):
        result, code = build_evidence()
        self.assertEqual((result["verdict"], code), ("YELLOW", 0))
        self.assertEqual(check_named(result, "render-health")["status"], "PASS")
        blank = check_named(result, "blank-risk")
        self.assertEqual(blank["status"], "PASS")
        self.assertIn("anchors tile census", blank["message"])
        self.assertTrue(any(a["kind"] == "visual-similarity" and a["present"]
                            for a in result["artifacts"]))

    def test_clear_blank_risk_artifact_composes(self):
        result, code = build_evidence(blank_artifact={
            "status": "PASS", "elements_checked": 13, "blank_risk_count": 0, "elements": []})
        self.assertEqual((result["verdict"], code), ("YELLOW", 0))

    def test_failed_render_health_is_red(self):
        for status in ("FAIL", "ERROR"):
            result, _ = build_evidence({"render_health": {"status": status}})
            self.assertEqual(result["verdict"], "RED")
            self.assertEqual(check_named(result, "render-health")["status"], "FAIL")

    def test_blank_tiles_follow_artifact_pass_threshold(self):
        result, _ = build_evidence({"tiles_blank": ["t1"], "pass": True})
        self.assertEqual(result["verdict"], "YELLOW")
        self.assertEqual(check_named(result, "render-health")["status"], "PASS")

    def test_composite_pass_false_does_not_fail_render_health(self):
        result, _ = build_evidence({"tiles_blank": ["t1"], "pass": False})
        self.assertEqual(check_named(result, "render-health")["status"], "PASS")
        self.assertEqual(result["verdict"], "YELLOW")

    def test_majority_blank_tiles_fail_render_health(self):
        result, _ = build_evidence({"tiles_blank": ["t1", "t2", "t3"], "tiles_measured": 4, "pass": False})
        render = check_named(result, "render-health")
        self.assertEqual(render["status"], "FAIL")
        self.assertRegex(render["message"], r"3 of 4 tiles blank")
        self.assertEqual(result["verdict"], "RED")

    def test_two_of_two_blank_tiles_fail_render_health(self):
        # Armed at any measured count: png_health only fails all-white/solid/
        # near-empty images, so chrome plus 2-of-2 blank tiles passes it.
        result, _ = build_evidence({"tiles_blank": ["t1", "t2"], "tiles_measured": 2, "pass": True})
        render = check_named(result, "render-health")
        self.assertEqual(render["status"], "FAIL")
        self.assertRegex(render["message"], r"2 of 2 tiles blank")
        self.assertEqual(result["verdict"], "RED")

    def test_one_of_one_blank_tile_fails_render_health(self):
        result, _ = build_evidence({"tiles_blank": ["t1"], "tiles_measured": 1, "pass": True})
        render = check_named(result, "render-health")
        self.assertEqual(render["status"], "FAIL")
        self.assertRegex(render["message"], r"1 of 1 tiles blank")
        self.assertEqual(result["verdict"], "RED")

    def test_minority_blank_tiles_pass_render_health(self):
        result, _ = build_evidence({"tiles_blank": ["t1"], "tiles_measured": 4})
        self.assertEqual(check_named(result, "render-health")["status"], "PASS")
        self.assertEqual(result["verdict"], "YELLOW")

    def test_half_blank_tiles_is_not_a_majority(self):
        result, _ = build_evidence({"tiles_blank": ["t1", "t2"], "tiles_measured": 4})
        self.assertEqual(check_named(result, "render-health")["status"], "PASS")

    def test_empty_census_is_red(self):
        result, _ = build_evidence(anchors=False)
        self.assertEqual(result["verdict"], "RED")
        blank = check_named(result, "blank-risk")
        self.assertEqual(blank["status"], "FAIL")
        self.assertIn("anchors tile census found empty displayed tiles", blank["message"])

    def test_empty_census_waiver_is_yellow(self):
        result, code = build_evidence(anchors=False, waivers=["--allow-empty-tiles"])
        self.assertEqual((result["verdict"], code), ("YELLOW", 0))
        self.assertEqual(check_named(result, "blank-risk")["status"], "PASS")

    def test_empty_census_beats_clear_artifact(self):
        result, _ = build_evidence(anchors=False, blank_artifact={
            "status": "PASS", "blank_risk_count": 0})
        self.assertEqual(check_named(result, "blank-risk")["status"], "FAIL")

    def test_missing_render_image_is_red(self):
        result, _ = build_evidence(png=False)
        self.assertEqual(result["verdict"], "RED")
        message = check_named(result, "render-health")["message"]
        self.assertRegex(message, r"visual-similarity\.json.*missing")

    def test_similarity_alone_covers_blank_risk(self):
        result, _ = build_evidence(anchors=None)
        self.assertEqual(check_named(result, "blank-risk")["status"], "PASS")
        self.assertEqual(result["verdict"], "YELLOW")

    def test_no_similarity_keeps_no_evidence_fail(self):
        result, _ = build_evidence("absent", anchors=None)
        self.assertIn("no healthy render evidence", check_named(result, "render-health")["message"])

    def test_similarity_without_render_health_contributes_nothing(self):
        result, _ = build_evidence({"render_health": None})
        self.assertIn("no healthy render evidence", check_named(result, "render-health")["message"])


MINORS = [
    {"tile": "Revenue KPI", "severity": "minor", "dimension": "typography",
     "description": "title weight differs"},
    {"tile": "Region bar", "severity": "minor", "dimension": "color",
     "description": "palette shade differs"},
]
MAJOR = {"tile": "Trend line", "severity": "major", "dimension": "chart_shapes",
         "description": "area rendered as bars"}


def write_visual_workdir(wd, verdict="pass", residuals=None, faithful=True,
                         fixable_major=None, platform_differences=None,
                         waivers=None, charts_pass=2):
    write_json(wd / "inventory.json", {"objects": [
        {"type": "dashboard", "id": "d1", "name": "Sales", "status": "migrated"}]})
    write_json(wd / "parity-final.json", {
        "status": "PASS", "charts_pass": charts_pass, "charts_total": 2,
        "waivers": waivers or [], "visual_checked": True, "visual_verdict": verdict})
    write_json(wd / "visual-residuals.json", {
        "faithful": faithful, "residuals": residuals if residuals is not None else [],
        "fixable_major": fixable_major or [],
        "platform_differences": platform_differences or []})
    write_json(wd / "dashboard-render-health.json", {"status": "healthy", "failed_count": 0})
    write_json(wd / "dashboard-blank-risk.json", {"risk": False, "blank_count": 0})
    degradation_ledger.write(wd, degradation_ledger.derive(wd))


def build_visual(**kwargs):
    with tempfile.TemporaryDirectory() as tmp:
        wd = Path(tmp)
        write_visual_workdir(wd, **kwargs)
        proc = subprocess.run(
            [sys.executable, str(BUILDER), "--workdir", str(wd),
             "--inventory", str(wd / "inventory.json")],
            capture_output=True, text=True)
        result = json.loads((wd / "migration-result.json").read_text(encoding="utf-8"))
        markdown = wd / "MIGRATION_REPORT.md"
        text = markdown.read_text(encoding="utf-8") if markdown.exists() else ""
        return result, text, proc.returncode


class PolishNotesTest(unittest.TestCase):
    NOTES = [
        {"item": "Revenue KPI: title weight differs", "dimension": "typography",
         "source_artifact": "visual-residuals.json"},
        {"item": "Region bar: palette shade differs", "dimension": "color",
         "source_artifact": "visual-residuals.json"},
    ]

    def test_pass_with_minors_is_green_with_polish_notes(self):
        result, text, code = build_visual(residuals=MINORS)
        self.assertEqual((result["verdict"], code), ("GREEN", 0))
        self.assertEqual(result["degradations"], [])
        self.assertEqual(result["polish_notes"], self.NOTES)
        self.assertEqual(result["platform_differences"], [])
        self.assertIn("## Minor polish notes", text)
        self.assertIn("- Revenue KPI: title weight differs [typography]", text)

    def test_recorded_pass_but_not_faithful_makes_minors_degradations(self):
        result, text, _ = build_visual(residuals=MINORS, faithful=False,
                                       fixable_major=[MAJOR])
        self.assertEqual(result["verdict"], "YELLOW")
        self.assertEqual(result["polish_notes"], [])
        items = [d["item"] for d in result["degradations"]]
        self.assertIn("visual residual (major): Trend line: area rendered as bars", items)
        self.assertIn("visual residual (minor): Revenue KPI: title weight differs", items)
        self.assertIn("visual residual (minor): Region bar: palette shade differs", items)
        self.assertNotIn("## Minor polish notes", text)

    def test_divergent_makes_minors_degradations(self):
        result, _, _ = build_visual(verdict="divergent", residuals=MINORS)
        self.assertEqual(result["verdict"], "YELLOW")
        self.assertEqual(result["polish_notes"], [])
        minors = [d for d in result["degradations"]
                  if d["item"].startswith("visual residual (minor)")]
        self.assertEqual(len(minors), 2)

    def test_waiver_makes_yellow_but_minors_stay_notes(self):
        result, _, _ = build_visual(residuals=MINORS, waivers=[
            {"flag": "--skip-x", "reason": "r"}])
        self.assertEqual(result["verdict"], "YELLOW")
        self.assertEqual(len(result["polish_notes"]), 2)
        self.assertFalse(any(d["class"] == "fidelity-residual"
                             for d in result["degradations"]))

    def test_parity_miss_is_red(self):
        result, _, code = build_visual(residuals=MINORS, charts_pass=1)
        self.assertEqual(result["verdict"], "RED")
        self.assertEqual(len(result["polish_notes"]), 2)

    def test_catalog_platform_difference_is_recorded_not_degraded(self):
        ids = degradation_ledger._catalog_ids()
        self.assertTrue(ids, "shipped catalog must be readable")
        gap = {"tile": "Map", "class": ids[0], "description": "no basemap"}
        result, text, _ = build_visual(platform_differences=[gap])
        self.assertEqual(result["verdict"], "GREEN")
        self.assertEqual(result["platform_differences"], [
            {"item": "Map: no basemap", "catalog_id": ids[0],
             "source_artifact": "visual-residuals.json"}])
        self.assertIn("## Platform differences", text)


def _ruby_ledger_path():
    vendored = SCRIPTS / "lib" / "degradation_ledger.rb"
    if "def polish_notes" in vendored.read_text(encoding="utf-8"):
        return vendored
    return REPO_ROOT / "shared" / "lib" / "degradation_ledger.rb"


@unittest.skipUnless(shutil.which("ruby"), "ruby not on PATH")
class RubyPythonLedgerAgreementTest(unittest.TestCase):
    def ruby_view(self, wd):
        script = ('require ARGV[1]; require "json"; '
                  'puts JSON.generate({"e"=>DegradationLedger.derive(ARGV[0]),'
                  '"p"=>DegradationLedger.polish_notes(ARGV[0])})')
        env = {**__import__("os").environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
        proc = subprocess.run(["ruby", "-e", script, str(wd), str(_ruby_ledger_path())],
                              capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def assert_agree(self, **kwargs):
        with tempfile.TemporaryDirectory() as tmp:
            wd = Path(tmp)
            write_visual_workdir(wd, **kwargs)
            ruby = self.ruby_view(wd)
            self.assertEqual(degradation_ledger.derive(wd), ruby["e"])
            self.assertEqual(degradation_ledger.polish_notes(wd), ruby["p"])
            return ruby

    def test_pass_with_minors(self):
        ruby = self.assert_agree(residuals=MINORS)
        self.assertEqual(len(ruby["p"]), 2)

    def test_divergent_with_minor_and_major(self):
        ruby = self.assert_agree(verdict="divergent", residuals=MINORS,
                                 fixable_major=[MAJOR], faithful=False)
        self.assertEqual(ruby["p"], [])
        self.assertTrue(any("visual residual (major)" in e["item"] for e in ruby["e"]))

    def test_unknown_catalog_id_platform_difference(self):
        ruby = self.assert_agree(platform_differences=[
            {"tile": "Map", "class": "not-in-catalog", "description": "x"}])
        self.assertTrue(any("not in the shipped catalog" in e["reason"] for e in ruby["e"]))

    def test_fidelity_ledger_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            wd = Path(tmp)
            write_visual_workdir(wd, residuals=MINORS)
            ids = degradation_ledger._catalog_ids()
            write_json(wd / "fidelity-ledger.json", {"entries": [
                {"id": "a1", "dimension": "color", "cls": "spec-fixable", "delta": "off"},
                {"id": "a2", "cls": "spec-fixable"},
                {"id": "a3", "cls": "sigma-capability", "catalog_id": ids[0], "delta": "pd"},
                {"id": "a4", "cls": "sigma-capability", "catalog_id": "nope"}]})
            ruby = self.ruby_view(wd)
            self.assertEqual(degradation_ledger.derive(wd), ruby["e"])


    def test_ruby_truthiness_on_malformed_input(self):
        # review m4: Array(hash) is pairs (no gaps); 0 and "" are truthy in Ruby.
        with tempfile.TemporaryDirectory() as tmp:
            wd = Path(tmp)
            write_visual_workdir(wd, residuals=MINORS)
            write_json(wd / "visual-residuals.json", {
                "faithful": True, "residuals": MINORS, "fixable_major": {},
                "platform_differences": []})
            write_json(wd / "fidelity-ledger.json", {"entries": [
                {"id": "z1", "cls": "spec-fixable", "resolved": 0, "delta": "zero is truthy"},
                {"id": "z2", "cls": "spec-fixable", "resolved": "", "delta": "empty is truthy"},
                {"id": "z3", "cls": "spec-fixable", "dimension": "", "delta": "blank dim"}]})
            ruby = self.ruby_view(wd)
            self.assertEqual(degradation_ledger.derive(wd), ruby["e"])
            self.assertEqual(degradation_ledger.polish_notes(wd), ruby["p"])
            self.assertEqual(len(ruby["p"]), 2)


class StaleResidualsTest(unittest.TestCase):
    def test_v1_python_record_removes_stale_visual_residuals(self):
        sys.path.insert(0, str(SCRIPTS))
        import record_visual_check  # noqa: E402
        with tempfile.TemporaryDirectory() as tmp:
            wd = Path(tmp)
            write_visual_workdir(wd, residuals=MINORS)
            self.assertTrue((wd / "visual-residuals.json").is_file())
            code = record_visual_check.main(["--workdir", str(wd), "--verdict", "not-executable",
                                             "--notes", "no browser", "--agent-vision", "false"])
            self.assertEqual(code, 0)
            self.assertFalse((wd / "visual-residuals.json").exists())
            self.assertEqual(degradation_ledger.polish_notes(wd), [])


class FinalizeGatesAndFloorExemptionTest(unittest.TestCase):
    def run_report(self, wd):
        subprocess.run([sys.executable, str(BUILDER), "--workdir", str(wd),
                        "--inventory", str(wd / "inventory.json")], capture_output=True, text=True)
        return json.loads((wd / "migration-result.json").read_text(encoding="utf-8"))

    def test_failed_finalize_gate_makes_report_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            wd = Path(tmp)
            write_visual_workdir(wd, residuals=MINORS)
            write_json(wd / "finalize-gates.json", {"gates": {
                "assert-phase6-ran": {"status": "FAIL", "exit": 20}, "cleanup": {"status": "PASS"}}})
            result = self.run_report(wd)
            self.assertEqual("RED", result["verdict"])
            check = next(c for c in result["checks"] if c["name"] == "finalize-gates")
            self.assertIn("assert-phase6-ran (exit 20)", check["message"])

    def test_passing_finalize_gates_keep_green(self):
        with tempfile.TemporaryDirectory() as tmp:
            wd = Path(tmp)
            write_visual_workdir(wd, residuals=MINORS)
            write_json(wd / "finalize-gates.json", {"gates": {"assert-phase6-ran": {"status": "PASS"}}})
            self.assertEqual("GREEN", self.run_report(wd)["verdict"])

    def test_floor_exemption_is_a_platform_difference_matching_ruby(self):
        with tempfile.TemporaryDirectory() as tmp:
            wd = Path(tmp)
            write_visual_workdir(wd, residuals=MINORS)
            write_json(wd / "visual-similarity-exemptions.json", {"exemptions": [
                {"component": "band_balance", "value": 0.0, "floor": 0.1,
                 "catalog_id": "pivot-row-height-fixed", "rcf_id": "e0"}]})
            rows = degradation_ledger.platform_differences(wd)
            self.assertIn({"item": "visual-similarity floor: band_balance 0.0 below 0.1 (RCF e0)",
                           "catalog_id": "pivot-row-height-fixed",
                           "source_artifact": "visual-similarity-exemptions.json"}, rows)
            if shutil.which("ruby"):
                script = ('require ARGV[1]; require "json"; '
                          'puts JSON.generate(DegradationLedger.platform_differences(ARGV[0]))')
                env = {**__import__("os").environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
                proc = subprocess.run(["ruby", "-e", script, str(wd), str(_ruby_ledger_path())],
                                      capture_output=True, text=True, env=env)
                self.assertEqual(json.loads(proc.stdout), rows, proc.stderr)


if __name__ == "__main__":
    unittest.main()
