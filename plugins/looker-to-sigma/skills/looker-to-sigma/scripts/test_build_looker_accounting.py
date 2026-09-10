#!/usr/bin/env python3
"""Offline regression tests for build-looker-accounting.py."""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
SCRIPT = HERE / "build-looker-accounting.py"
MIGRATE = HERE / "migrate-looker.py"
AUDIT = HERE / "audit-lookml-readiness.mjs"
FIXTURE = SKILL / "fixtures" / "skilltest-orders"
REPORT = HERE / "build-migration-report.rb"
TERMINAL = {"migrated", "approximated", "needs-review", "skipped", "not-applicable"}


def load(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def dump(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def document(doc):
    return doc.get("document") if isinstance(doc.get("document"), dict) else doc


def elements(doc):
    root = document(doc)
    result = list(root.get("elements") or [])
    for page in root.get("pages") or []:
        result.extend(page.get("elements") or [])
    return result


class LookerAccountingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_tmp = tempfile.TemporaryDirectory(prefix="looker-accounting-base-")
        cls.base = Path(cls.base_tmp.name)
        result = subprocess.run(
            [
                sys.executable, str(MIGRATE),
                "--lookml-dir", str(FIXTURE),
                "--dashboard", str(FIXTURE / "skilltest_orders.dashboard.lookml"),
                "--workdir", str(cls.base),
                "--dry-run", "--yes",
            ],
            cwd=SKILL,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError("fixture migration failed:\n%s\n%s" % (result.stdout, result.stderr))
        # Run the audit producer directly over the parsed contract and actual
        # converter/builder output. This is the same artifact boundary used by
        # the accounting command in an offline end-to-end migration.
        audit = subprocess.run(
            [
                "node", str(AUDIT),
                "--lookml-dir", str(FIXTURE),
                "--explore", "order_fact",
                "--dashboard-contract", str(cls.base / "contract.json"),
                "--out", str(cls.base / "lookml-readiness.json"),
                "--field-census", str(cls.base / "lookml-field-census.json"),
                "--formula-mapping", str(cls.base / "formula-mapping.json"),
            ],
            cwd=SKILL,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if audit.returncode != 0:
            raise RuntimeError("fixture audit failed:\n%s\n%s" % (audit.stdout, audit.stderr))

    @classmethod
    def tearDownClass(cls):
        cls.base_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="looker-accounting-test-")
        self.work = Path(self.tmp.name)
        for source in self.base.iterdir():
            if source.is_file() and source.suffix == ".json":
                shutil.copy2(source, self.work / source.name)
        dump(self.work / "wb-readback.json", load(self.work / "wb-spec.json"))
        contract = load(self.work / "contract.json")
        names = [row["name"] for row in contract["elements"]]
        dump(
            self.work / "parity-final.json",
            {
                "status": "PASS",
                "charts_total": len(names),
                "charts_pass": len(names),
                "charts_fail": 0,
                "pass_names": names,
                "fail_names": [],
            },
        )

    def tearDown(self):
        self.tmp.cleanup()

    def run_accounting(self, *extra):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--workdir", str(self.work), *extra],
            cwd=SKILL,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def set_field_mapping(self, qualified, value):
        view, field = qualified.split(".", 1)
        census = load(self.work / "lookml-field-census.json")
        formula = load(self.work / "formula-mapping.json")
        for row in census["fields"]:
            if row["view"] == view and row["field"] == field:
                row["mapping"] = value
                row["reasons"] = ["test fixture %s mapping" % value]
        for row in formula["formulas"]:
            if row["view"] == view and row["field"] == field:
                row["mapping"] = value
                row["reason"] = "test fixture %s mapping" % value
        dump(self.work / "lookml-field-census.json", census)
        dump(self.work / "formula-mapping.json", formula)

    def remove_sigma_formula(self, qualified):
        view, field = qualified.split(".", 1)
        formulas = load(self.work / "formula-mapping.json")["formulas"]
        target = next(
            row["sigmaFormula"] for row in formulas
            if row["view"] == view and row["field"] == field
        )
        dm = load(self.work / "dm-spec.json")
        for element in elements(dm):
            for key in ("columns", "metrics"):
                element[key] = [
                    row for row in element.get(key) or []
                    if row.get("formula") != target and row.get("name") != field.replace("_", " ").title()
                ]
        dump(self.work / "dm-spec.json", dm)

    def qualify_dimension_group_readback_names(self):
        """Model API readback naming while making formula equality unavailable."""
        dm = load(self.work / "dm-spec.json")
        census = load(self.work / "lookml-field-census.json")
        dimension_groups = {
            row["field"].replace("_", " ").title(): row
            for row in census["fields"]
            if row.get("kind") == "dimension_group"
        }
        seen = set()
        for element in elements(dm):
            source = element.get("source") or {}
            if source.get("kind") == "warehouse-table":
                element.pop("name", None)
            for row in element.get("columns") or []:
                if row.get("name") in dimension_groups:
                    source_row = dimension_groups[row["name"]]
                    seen.add(source_row["field"])
                    row["name"] = "%s (%s)" % (row["name"], source_row["view"])
                    row["formula"] = "[readback/%s]" % row["id"]
        self.assertEqual(
            seen,
            {row["field"] for row in census["fields"] if row.get("kind") == "dimension_group"},
            "real converter output must emit every audited dimension-group timeframe",
        )
        dump(self.work / "dm-spec.json", dm)

    def test_skilltest_orders_accounts_all_audited_fields_and_structure(self):
        self.qualify_dimension_group_readback_names()

        result = self.run_accounting()
        self.assertEqual(result.returncode, 0, result.stderr)
        census = load(self.work / "source-object-census.json")
        audit_fields = {
            "%s.%s" % (row["view"], row["field"])
            for row in load(self.work / "lookml-field-census.json")["fields"]
        }
        census_fields = {
            row["name"]: row for row in census["objects"] if row["type"] == "field"
        }

        self.assertEqual(set(census_fields), audit_fields)
        self.assertEqual(len(census_fields), 19)
        self.assertTrue(all(row["status"] == "migrated" for row in census_fields.values()))
        self.assertEqual(
            {
                name: census_fields[name]["status"]
                for name in sorted(audit_fields)
                if name.startswith("customer_dim.first_order_")
            },
            {
                "customer_dim.first_order_date": "migrated",
                "customer_dim.first_order_month": "migrated",
                "customer_dim.first_order_raw": "migrated",
                "customer_dim.first_order_year": "migrated",
            },
        )
        rows = {(row["type"], row["name"]): row for row in census["objects"]}
        for identity in (
            ("view", "customer_dim"),
            ("view", "order_fact"),
            ("explore", "order_fact"),
            ("join", "customer_dim"),
        ):
            self.assertEqual(rows[identity]["status"], "migrated", identity)
        self.assertEqual(census["diagnostics"], {
            "errors": [], "unaccounted": [], "contradictory": [],
        })

    def test_dimension_group_matching_does_not_accept_an_ordinary_prefix_field(self):
        self.qualify_dimension_group_readback_names()
        census = load(self.work / "lookml-field-census.json")
        census["fields"].append({
            "view": "customer_dim",
            "field": "first_order",
            "kind": "dimension",
            "type": "time",
            "mapping": "exact",
            "reasons": [],
        })
        formula = load(self.work / "formula-mapping.json")
        formula["formulas"].append({
            "view": "customer_dim",
            "field": "first_order",
            "kind": "dimension",
            "sourceFormula": "${TABLE}.NOT_EMITTED",
            "sigmaFormula": "[CUSTOMER_DIM/Not Emitted]",
            "mapping": "exact",
            "dependencies": [],
            "dependencyDepth": 0,
            "unresolvedReferences": [],
        })
        dump(self.work / "lookml-field-census.json", census)
        dump(self.work / "formula-mapping.json", formula)

        result = self.run_accounting()
        self.assertEqual(result.returncode, 1)
        diagnostics = load(self.work / "source-object-census.json")["diagnostics"]
        self.assertIn("field:customer_dim.first_order", diagnostics["contradictory"])

    def test_real_builder_artifacts_with_mixed_terminal_statuses(self):
        # Exercise exact, approximate, omitted, and blocked converter outcomes
        # against the real skilltest-orders audit + DM/workbook builder output.
        self.set_field_mapping("customer_dim.customer_segment", "approximate")
        self.set_field_mapping("customer_dim.loyalty_tier", "omitted")
        self.remove_sigma_formula("customer_dim.loyalty_tier")
        self.set_field_mapping("order_fact.order_status", "blocked")

        contract = load(self.work / "contract.json")
        contract["elements"].append({
            "name": "Unsupported Custom Map",
            "tileType": "looker_map",
            "model": "skilltest_orders",
            "explore": "order_fact",
            "fields": ["customer_dim.region"],
            "pivots": [],
            "filters": {},
            "listen": {},
            "dynamicFields": [],
        })
        dump(self.work / "contract.json", contract)

        # Produce all three control ledger states from the actual builder scope.
        scope = load(self.work / "control-scope.json")
        by_name = {row["name"]: row for row in scope["controls"]}
        order_channel = by_name["Order Channel"]
        first_order = by_name["First Order Date"]
        scope["controls"] = [
            row for row in scope["controls"]
            if row["name"] not in ("Order Channel", "First Order Date")
        ]
        order_channel["status"] = "dropped"
        order_channel["reason"] = "explicit fixture omission"
        scope["dropped"].append(order_channel)
        first_order["status"] = "needs-wiring"
        first_order["reason"] = "explicit fixture follow-up"
        scope["controls"].append(first_order)
        dump(self.work / "control-scope.json", scope)

        readback = load(self.work / "wb-readback.json")
        root = document(readback)
        root["elements"] = [
            row for row in root.get("elements") or []
            if row.get("name") != "Order Channel"
        ]
        dump(self.work / "wb-readback.json", readback)

        result = self.run_accounting()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("34 accounted", result.stdout)

        census = load(self.work / "source-object-census.json")
        coverage = load(self.work / "coverage.json")
        controls = load(self.work / "looker-controls-coverage.json")
        rows = {(row["type"], row["name"]): row for row in census["objects"]}

        self.assertTrue(census["summary"]["complete"])
        self.assertEqual(census["summary"]["accounted"], census["summary"]["total"])
        self.assertTrue(all(row["status"] in TERMINAL and row["evidence"] for row in census["objects"]))
        self.assertEqual(rows[("field", "order_fact.order_id")]["status"], "migrated")
        self.assertEqual(rows[("field", "customer_dim.customer_segment")]["status"], "approximated")
        self.assertEqual(rows[("field", "customer_dim.loyalty_tier")]["status"], "skipped")
        self.assertEqual(rows[("field", "order_fact.order_status")]["status"], "needs-review")
        self.assertEqual(rows[("tile", "Unsupported Custom Map")]["status"], "skipped")

        self.assertEqual(coverage["summary"]["sourceVisuals"], 7)
        self.assertEqual(coverage["summary"]["builtElements"], 6)
        self.assertTrue(any(
            row["visual"] == "Unsupported Custom Map" and row["severity"] == "dropped"
            for row in coverage["unresolved"]
        ))
        census_status = {row["id"]: row["status"] for row in census["objects"]}
        self.assertEqual(
            {row["source_object_id"]: row["status"] for row in coverage["objects"]},
            census_status,
        )

        self.assertEqual(controls["summary"], {
            "sourceFilters": 3, "emitted": 1, "dropped": 1, "needsWiring": 1,
        })
        self.assertEqual(
            {row["name"]: row["status"] for row in controls["detail"]},
            {"Region": "emitted", "Order Channel": "dropped", "First Order Date": "needs-wiring"},
        )

        expected_bytes = {
            name: (self.work / name).read_bytes()
            for name in ("source-object-census.json", "coverage.json", "looker-controls-coverage.json")
        }
        explicit = self.run_accounting(
            "--readiness", "lookml-readiness.json",
            "--field-census", "lookml-field-census.json",
            "--formula-mapping", "formula-mapping.json",
            "--contract", "contract.json",
            "--wb-spec", "wb-spec.json",
            "--wb-readback", "wb-readback.json",
            "--parity-final", "parity-final.json",
            "--control-scope", "control-scope.json",
            "--dm-spec", "dm-spec.json",
            "--dm-warnings", "dm-spec-warnings.json",
        )
        self.assertEqual(explicit.returncode, 0, explicit.stderr)
        self.assertEqual(
            {name: (self.work / name).read_bytes() for name in expected_bytes},
            expected_bytes,
            "auto-discovered and explicit inputs must produce byte-identical artifacts",
        )

        # The shared report consumes both accounting arrays without seeing a
        # contradictory status for any census identity.
        dump(self.work / "render-health.json", {"status": "PASS", "blank_count": 0})
        report = subprocess.run(
            ["ruby", str(REPORT), "--workdir", str(self.work)],
            cwd=SKILL,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertEqual(load(self.work / "migration-result.json")["verdict"], "YELLOW")

    def test_built_objects_without_passing_parity_need_review_but_exit_zero(self):
        parity = load(self.work / "parity-final.json")
        parity.update({
            "status": "FAIL",
            "charts_pass": parity["charts_total"] - 1,
            "charts_fail": 1,
            "pass_names": parity["pass_names"][:-1],
            "fail_names": [parity["pass_names"][-1]],
        })
        dump(self.work / "parity-final.json", parity)

        result = self.run_accounting()
        self.assertEqual(result.returncode, 0, result.stderr)
        census = load(self.work / "source-object-census.json")
        failed = next(row for row in census["objects"] if row["name"] == parity["fail_names"][0])
        self.assertEqual(failed["status"], "needs-review")
        self.assertTrue(any("lacks passing final parity" in item["detail"] for item in failed["evidence"]))

    def test_audit_derived_tables_and_nested_model_filters_are_inventoried(self):
        readiness = load(self.work / "lookml-readiness.json")
        readiness["views"][0]["derivedTable"] = True
        readiness["derivedTables"] = [{"view": "customer_dim", "kind": "native"}]
        readiness["explores"][0]["filters"] = [{
            "filters": [{"field": "order_fact.order_status", "value": "Complete"}],
        }]
        readiness["explores"][0]["accessFilters"] = [{
            "field": "customer_dim.region", "status": "blocked",
        }]
        dump(self.work / "lookml-readiness.json", readiness)
        dm = load(self.work / "dm-spec.json")
        dm["filters"] = [{"field": "order_fact.order_status", "value": "Complete"}]
        dump(self.work / "dm-spec.json", dm)

        result = self.run_accounting()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = {
            (row["type"], row["name"]): row
            for row in load(self.work / "source-object-census.json")["objects"]
        }
        self.assertEqual(rows[("derived-table", "customer_dim")]["status"], "approximated")
        self.assertEqual(rows[("filter", "order_fact.order_status")]["status"], "migrated")
        self.assertEqual(rows[("access-filter", "customer_dim.region")]["status"], "needs-review")

    def test_unaccounted_object_writes_diagnostics_and_exits_one(self):
        census = load(self.work / "lookml-field-census.json")
        census["fields"].append({
            "view": "order_fact", "field": "audit_only_ghost",
            "kind": "dimension", "type": "string", "reasons": [],
        })
        dump(self.work / "lookml-field-census.json", census)

        result = self.run_accounting()
        self.assertEqual(result.returncode, 1)
        output = load(self.work / "source-object-census.json")
        self.assertFalse(output["summary"]["complete"])
        self.assertIn("field:order_fact.audit_only_ghost", output["diagnostics"]["unaccounted"])
        self.assertTrue((self.work / "coverage.json").is_file())
        self.assertTrue((self.work / "looker-controls-coverage.json").is_file())

    def test_contradictory_mapping_writes_diagnostics_and_exits_one(self):
        formula = load(self.work / "formula-mapping.json")
        next(
            row for row in formula["formulas"]
            if row["view"] == "order_fact" and row["field"] == "order_id"
        )["mapping"] = "approximate"
        dump(self.work / "formula-mapping.json", formula)

        result = self.run_accounting()
        self.assertEqual(result.returncode, 1)
        output = load(self.work / "source-object-census.json")
        self.assertIn("field:order_fact.order_id", output["diagnostics"]["contradictory"])
        row = next(row for row in output["objects"] if row["id"] == "field:order_fact.order_id")
        self.assertIn(row["status"], TERMINAL)

    def test_invalid_json_exits_two(self):
        (self.work / "lookml-readiness.json").write_text("{not-json", encoding="utf-8")
        result = self.run_accounting()
        self.assertEqual(result.returncode, 2)
        self.assertIn("malformed JSON", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
