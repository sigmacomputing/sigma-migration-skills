#!/usr/bin/env python3
"""Offline test: --contract (supplied dashboard contract) stays gate-preserving.
The supplied contract is copied, hashed and diffed against the live source
fetch (stubbed here); parity's expected side reads the SOURCE tile; a missing
reason is an argument error; provenance and accepted readiness omissions reach
migration-result.json and MIGRATION_REPORT.md."""
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "lib"))
import looker_contract as lc  # noqa: E402


def tile(name, **over):
    t = {"name": name, "model": "logistics", "explore": "shipments", "tileType": "looker_column",
         "fields": ["depots.depot_name", "shipments.total_weight"], "filters": {},
         "dynamicFields": [], "pivots": [], "sorts": []}
    t.update(over)
    return t


def contract(*tiles):
    return {"id": "7", "title": "Depot throughput", "filters": [], "elements": list(tiles)}


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.wd = self.tmp / "wd"
        self.wd.mkdir()
        self.source = contract(tile("Weight by depot"), tile("Carriers"),
                               tile("Heavy share", filters={"shipments.weight_kg": ">500"}))
        self.supplied = contract(
            tile("Weight by depot", fields=["depots.depot_name", "shipments.n"]),  # changed
            tile("Heavy share", filters={"shipments.weight_kg": ">500"}),          # same
            tile("Added tile"))                                                      # added; Carriers removed
        self.sup_path = self.tmp / "reviewed.json"
        self.sup_path.write_text(json.dumps(self.supplied))

    def fetch(self, dest):
        Path(dest).write_text(json.dumps(self.source))

    def test_missing_reason_errors(self):
        for reason in (None, "", "   "):
            with self.assertRaises(ValueError):
                lc.resolve_phase1_contract(str(self.sup_path), reason, str(self.wd))

    def test_missing_or_invalid_file_errors(self):
        with self.assertRaises(ValueError):
            lc.resolve_phase1_contract(str(self.tmp / "nope.json"), "r", str(self.wd))
        bad = self.tmp / "bad.json"
        bad.write_text(json.dumps({"no": "elements"}))
        with self.assertRaises(ValueError):
            lc.resolve_phase1_contract(str(bad), "r", str(self.wd))

    def test_offline_copy_and_provenance(self):
        path, source, prov = lc.resolve_phase1_contract(str(self.sup_path), "hand-reviewed", str(self.wd))
        self.assertEqual(path, str(self.wd / "contract.json"))
        self.assertEqual(json.load(open(path)), self.supplied)
        self.assertIsNone(source)
        self.assertFalse(prov["sourceFetched"])
        self.assertEqual(prov["changedTiles"] + prov["addedTiles"] + prov["removedTiles"], [])
        self.assertFalse((self.wd / "contract.source.json").exists())
        self.assertEqual(prov["sha256"], hashlib.sha256(self.sup_path.read_bytes()).hexdigest())
        self.assertEqual(json.load(open(self.wd / "contract-provenance.json")), prov)

    def test_source_diff(self):
        path, source, prov = lc.resolve_phase1_contract(
            str(self.sup_path), "hand-reviewed", str(self.wd), self.fetch)
        self.assertTrue(prov["sourceFetched"])
        self.assertEqual(prov["changedTiles"], [{"name": "Weight by depot", "changed": ["fields"]}])
        self.assertEqual(prov["addedTiles"], ["Added tile"])
        self.assertEqual(prov["removedTiles"], ["Carriers"])
        self.assertEqual(json.load(open(self.wd / "contract.source.json")), self.source)
        self.assertEqual(json.load(open(path)), self.supplied)

    def test_expected_lookup_uses_source_tile(self):
        _p, source, _prov = lc.resolve_phase1_contract(
            str(self.sup_path), "r", str(self.wd), self.fetch)
        look = lc.expected_tile_lookup(self.supplied, source)
        # the supplied tile was rewritten to ask for shipments.n; expected must still ask the source's fields
        self.assertEqual(look["Weight by depot"]["fields"], ["depots.depot_name", "shipments.total_weight"])
        self.assertNotIn("Added tile", look)            # no same-named source tile -> no live expected
        # no source fetched -> the working contract is the lookup
        self.assertIn("Added tile", lc.expected_tile_lookup(self.supplied, None))

    def test_annotate_report(self):
        lc.resolve_phase1_contract(str(self.sup_path), "hand-reviewed", str(self.wd), self.fetch)
        (self.wd / "lookml-readiness.json").write_text(json.dumps(
            {"acceptedOmissions": {"reason": "orphan view", "fields": ["fuel_stops.stop_count"]}}))
        (self.wd / "migration-result.json").write_text(json.dumps({"verdict": "YELLOW"}))
        (self.wd / "MIGRATION_REPORT.md").write_text("# Migration Report\n")
        for _ in range(2):  # idempotent
            added = lc.annotate_report(str(self.wd))
            self.assertEqual(added, ["contract_provenance", "accepted_readiness_omissions"])
        doc = json.load(open(self.wd / "migration-result.json"))
        self.assertEqual(doc["verdict"], "YELLOW")
        self.assertEqual(doc["contract_provenance"]["removedTiles"], ["Carriers"])
        self.assertEqual(doc["accepted_readiness_omissions"]["fields"], ["fuel_stops.stop_count"])
        md = (self.wd / "MIGRATION_REPORT.md").read_text()
        self.assertEqual(md.count("## Contract supplied, not fetched"), 1)
        self.assertIn("Accepted readiness omissions", md)
        self.assertIn("fuel_stops.stop_count", md)

    def test_annotate_report_offline_states_no_comparison(self):
        lc.resolve_phase1_contract(str(self.sup_path), "r", str(self.wd))
        (self.wd / "MIGRATION_REPORT.md").write_text("# Migration Report\n")
        lc.annotate_report(str(self.wd))
        self.assertIn("no live source comparison", (self.wd / "MIGRATION_REPORT.md").read_text())

    def test_annotate_report_noop_without_inputs(self):
        self.assertEqual(lc.annotate_report(str(self.wd)), [])


class CliArgsTest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(HERE / "migrate-looker.py"), *args],
                              capture_output=True, text=True, timeout=60)

    def test_contract_requires_reason(self):
        p = self.run_cli("--lookml-dir", ".", "--dashboard-id", "7", "--contract", "x.json")
        self.assertEqual(p.returncode, 2)
        self.assertIn("--contract-reason", p.stderr)

    def test_contract_alone_still_needs_a_source(self):
        p = self.run_cli("--lookml-dir", ".", "--contract", "x.json", "--contract-reason", "r")
        self.assertEqual(p.returncode, 2)
        self.assertIn("required", p.stderr)

    def test_omission_waiver_needs_reason(self):
        p = self.run_cli("--lookml-dir", ".", "--dashboard-id", "7",
                         "--accept-readiness-omission", "fuel_stops.stop_count")
        self.assertEqual(p.returncode, 2)
        self.assertIn("accept-readiness-omission-reason", p.stderr)


if __name__ == "__main__":
    unittest.main()
