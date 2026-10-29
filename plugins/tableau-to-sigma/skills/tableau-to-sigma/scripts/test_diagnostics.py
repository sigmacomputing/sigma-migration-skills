#!/usr/bin/env python3
"""Offline diagnostics contracts. All inputs are invented and temporary."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import diagnostics as diag
from migration_diagnostics import Span, emit


class DiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def write(self, name, value):
        (self.work / name).write_text(json.dumps(value), encoding="utf-8")

    def activity(self, number, start, end, kind="invocation", operation="migrate-tableau.rb", code=12):
        epoch = datetime(2025, 3, 1, tzinfo=timezone.utc)
        common = {"id": f"{number:032x}", "kind": kind, "operation": operation}
        emit(self.work, dict(common, event="start", at=(epoch + timedelta(seconds=start)).isoformat()))
        if end is not None:
            emit(self.work, dict(common, event="end", at=(epoch + timedelta(seconds=end)).isoformat(),
                                 elapsed_s=end - start, clock="monotonic", exit_code=code))

    def test_overlap_gaps_and_completion_are_distinct(self):
        self.activity(1, 0, 10)
        self.activity(2, 2, 8, "script", "build-charts-from-signals.rb", 0)
        self.activity(3, 90, 100)
        self.activity(4, 95, 97, "completion", "verify-complete.rb", 3)
        summary = diag.summarize(diag.collect(self.work))
        timing = summary["timing"]
        self.assertEqual(100, timing["span_s"])
        self.assertEqual(20, timing["measured_union_s"])
        self.assertEqual(28, timing["summed_activity_s"])
        self.assertEqual(80, timing["unmeasured_s"])
        self.assertEqual(80, timing["largest_unmeasured_intervals"][0]["seconds"])
        self.assertEqual(3, summary["last_observed_completion_check"]["exit_code"])
        self.assertEqual(2, summary["observed_activity_counts"]["invocation"])

    def test_missing_or_killed_work_is_not_a_pass_or_zero_duration(self):
        self.activity(1, 0, None)
        summary = diag.summarize(diag.collect(self.work))
        self.assertEqual(1, summary["timing"]["incomplete_or_invalid_activities"])
        self.assertIsNone(summary["timing"]["measured_union_s"])
        self.assertEqual("unknown", summary["last_observed_completion_check"])
        self.assertIsNone(summary["unresolved_fidelity_entries"])

    def test_legacy_phase_intervals_are_labeled_and_never_double_counted(self):
        records = [dict(phase="discover", wall_s=10, at="2025-03-01T00:00:10Z"),
                   dict(phase="build", wall_s=10, at="2025-03-01T00:00:15Z")]
        (self.work / "phase-metrics.jsonl").write_text("\n".join(map(json.dumps, records)), encoding="utf-8")
        timing = diag.summarize(diag.collect(self.work))["timing"]
        self.assertEqual("phase-metrics-reconstructed", timing["source"])
        self.assertEqual(15, timing["measured_union_s"])
        self.assertEqual(20, timing["summed_phase_s"])

    def test_bundle_contains_only_sanitized_projections_and_final_byte_hashes(self):
        secret = "SYNTHETIC-PRIVATE-SENTINEL"
        for name in ("auth.json", ".env", "rows.csv", "source.twb", "migrate-full.log", "image.png"):
            (self.work / name).write_text(secret, encoding="utf-8")
        self.write("workbook-handoff.json", dict(stage="build-charts-from-signals.rb", child_exit=4,
                   error=secret, fields=[secret, "redacted-1"], reason=secret, spec="C:\\private\\source.json"))
        self.write("fidelity-ledger.json", dict(pass_=2, entries=[dict(id=secret, cls="spec-fixable",
                   dimension=secret, delta=secret, fix=secret, resolved=False, rows=[secret])], renders=[{"path": secret}]))
        self.write("parity-final.json", dict(status="PASS", visual_verdict="fail", rows=[secret], workbookId=secret))
        (self.work / "execution-history.jsonl").write_text(json.dumps(dict(
            plugin_version="1.11.3", runtime="ruby 3.3.12", skill_path=secret,
            git_revision="a" * 40, converter=dict(backend="local", sha256="b" * 64, path=secret))), encoding="utf-8")
        output = self.work / "diagnostics.zip"
        diag.export_bundle(self.work, output)
        with zipfile.ZipFile(output) as archive:
            members = {name: archive.read(name) for name in archive.namelist()}
        self.assertNotIn(secret.encode(), b"".join(members.values()))
        self.assertNotIn(b"C:\\\\private", b"".join(members.values()))
        self.assertFalse(set(members) & {"auth.json", ".env", "rows.csv", "source.twb", "migrate-full.log", "image.png"})
        handoff = json.loads(members["workbook-handoff.json"])
        self.assertEqual("build-charts-from-signals.rb", handoff["stage"])
        self.assertEqual(4, handoff["child_exit"])
        self.assertNotEqual(handoff["fields"][0], handoff["fields"][1])
        self.assertEqual(handoff["error"], handoff["fields"][0])
        summary = json.loads(members["SUMMARY.json"])
        self.assertEqual(1, summary["unresolved_fidelity_entries"])
        self.assertEqual(1, summary["recorded_fidelity_renders"])
        self.assertEqual("fail", summary["reported_numeric_and_visual"]["visual_verdict"])
        self.assertEqual("unknown", summary["last_observed_completion_check"])
        manifest = json.loads(members.pop("MANIFEST.json"))["files"]
        self.assertEqual(set(members), set(manifest))
        for name, content in members.items():
            self.assertEqual(hashlib.sha256(content).hexdigest(), manifest[name]["sha256"])
            self.assertEqual(len(content), manifest[name]["bytes"])
        if os.name != "nt":
            self.assertEqual(0o600, output.stat().st_mode & 0o777)

    def test_summary_uses_frozen_packaged_bytes_not_later_source_reads(self):
        self.write("parity-final.json", {"status": "FAIL"})
        original = diag.collect

        def collect_then_change(work):
            payload = original(work)
            self.write("parity-final.json", {"status": "PASS"})
            return payload

        with patch.object(diag, "collect", side_effect=collect_then_change):
            diag.export_bundle(self.work, self.work / "frozen.zip")
        with zipfile.ZipFile(self.work / "frozen.zip") as archive:
            self.assertEqual("FAIL", json.loads(archive.read("parity-final.json"))["status"])
            self.assertEqual("FAIL", json.loads(archive.read("SUMMARY.json"))["reported_numeric_and_visual"]["status"])

    def test_malformed_partial_and_oversized_inputs_are_visible(self):
        (self.work / "phase-metrics.jsonl").write_text('{"phase":"build","wall_s":2}\n{torn\n[]', encoding="utf-8")
        self.write("migration-result.json", [])
        self.write("fidelity-ledger.json", {"entries": [None]})
        payload = diag.collect(self.work)
        inventory = payload["collection.json"]
        self.assertEqual(2, inventory["phase-metrics.jsonl"]["rejected_records"])
        self.assertEqual("unreadable-or-unsafe", inventory["migration-result.json"]["status"])
        self.assertEqual("unreadable-or-unsafe", inventory["fidelity-ledger.json"]["status"])
        self.assertIsNone(diag.summarize(payload)["unresolved_fidelity_entries"])
        with self.assertRaises(ValueError):
            diag.read_regular(self.work / "phase-metrics.jsonl", limit=1)

    @unittest.skipIf(os.name == "nt", "Windows symlink creation needs separate privilege")
    def test_symlinks_and_fifos_are_never_followed(self):
        self.write("outside.json", {"status": "PASS"})
        (self.work / "parity-final.json").symlink_to(self.work / "outside.json")
        os.mkfifo(self.work / "workbook-handoff.json")
        (self.work / "diagnostic-events").symlink_to(self.work)
        inventory = diag.collect(self.work)["collection.json"]
        for name in ("parity-final.json", "workbook-handoff.json", "diagnostic-events"):
            self.assertEqual("unreadable-or-unsafe", inventory[name]["status"])

    def test_output_never_overwrites_an_existing_file(self):
        output = self.work / "existing.zip"
        output.write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            diag.export_bundle(self.work, output)
        self.assertEqual(b"keep", output.read_bytes())

    def test_invalid_numeric_types_clock_jumps_and_duplicate_events(self):
        projection = diag.Projection()
        for value in (True, "12", float("nan"), float("inf"), -1, 10 ** 1000):
            self.assertIsNone(projection.value("elapsed_s", value))
        self.activity(1, 0, 10)
        end = self.work / "diagnostic-events" / (f"{1:032x}-end.json")
        event = json.loads(end.read_text())
        event["elapsed_s"] = 1
        end.write_text(json.dumps(event), encoding="utf-8")
        summary = diag.summarize(diag.collect(self.work))
        self.assertIsNone(summary["timing"]["measured_union_s"])
        self.assertEqual(1, summary["timing"]["incomplete_or_invalid_activities"])

    def test_span_changes_unknown_context_and_failed_writes(self):
        with patch.dict(os.environ, {"SIGMA_DIAGNOSTICS_MODEL": "Bearer SYNTHETIC-SECRET", "SIGMA_DIAGNOSTICS_EFFORT": "SYNTHETIC-SECRET"}):
            span = Span(self.work, "repair", "runtime-repair")
        self.write("wb-spec.json", {"synthetic": True})
        span.finish(4)
        span.finish(0)
        events = diag.collect(self.work)["diagnostic-events.json"]
        self.assertEqual(2, len(events))
        end = next(row for row in events if row["event"] == "end")
        self.assertEqual(["wb-spec.json"], end["changed_artifacts"])
        self.assertEqual("unknown", end["model"])
        self.assertEqual("unknown", end["effort"])
        self.assertEqual(4, end["exit_code"])
        self.assertFalse(emit(self.work, dict(id="../escape", event="end")))
        with patch("migration_diagnostics.os.open", side_effect=OSError("unwritable")):
            Span(self.work, "script", "external-command").finish(7)

    def test_explicit_timer_cli_and_poisoned_id(self):
        command = [sys.executable, str(Path(diag.__file__)), "begin", "--workdir", str(self.work),
                   "--kind", "mcp", "--operation", "mcp-source"]
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        activity_id = result.stdout.strip()
        end = [sys.executable, str(Path(diag.__file__)), "end", "--workdir", str(self.work),
               "--id", activity_id, "--exit-code", "0"]
        subprocess.run(end, capture_output=True, text=True, check=True)
        self.assertEqual(2, subprocess.run(end, capture_output=True).returncode)
        payload = diag.collect(self.work)
        self.assertEqual(1, diag.summarize(payload)["observed_activity_counts"]["mcp"])
        path = self.work / "diagnostic-events" / (activity_id + "-start.json")
        poisoned = json.loads(path.read_text())
        poisoned["id"] = "../escape"
        path.write_text(json.dumps(poisoned), encoding="utf-8")
        self.assertEqual(2, subprocess.run(end, capture_output=True).returncode)
        path.write_text("[]", encoding="utf-8")
        self.assertEqual(2, subprocess.run(end, capture_output=True).returncode)


if __name__ == "__main__":
    unittest.main()
