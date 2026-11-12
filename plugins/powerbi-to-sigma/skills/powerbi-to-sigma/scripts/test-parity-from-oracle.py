#!/usr/bin/env python3
"""Offline tests for parity-from-oracle.py: compare a Sigma element export CSV with
oracle SQL rows by key columns and measure mapping with tolerance, classify each
cell MATCH/DIVERGENT, and write parity-final.json in the shape
phase6-parity-pbi.rb --finalize produces (what assert-phase6-ran.rb reads).
Synthetic Sales/Orders data; no network.

Run: python3 scripts/test-parity-from-oracle.py   (exit 0 = pass)
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


par = load("parity_from_oracle", "parity-from-oracle.py")

PBI_FINAL_KEYS = ["workbook_id", "ran_at", "source", "mode", "source_timezone", "charts_total", "charts_pass",
                  "charts_fail", "charts_stale_explained", "charts_verified", "pass_names",
                  "stale_explained_names", "fail_names", "classifications", "freshness", "status"]


def csv_text(header, rows):
    import csv
    import io
    b = io.StringIO()
    w = csv.writer(b)
    w.writerow(header)
    w.writerows(rows)
    return b.getvalue()


def compare(sigma_header, sigma_rows, oracle_rows, keys, measures=None, **kw):
    s = par.read_csv_rows(csv_text(sigma_header, sigma_rows))
    return par.compare_chart("Chart A", s, oracle_rows, keys=keys, measures=measures, **kw)


class ValueTests(unittest.TestCase):
    def test_parse_number(self):
        p = par.parse_number
        self.assertEqual(1234.5, p("$1,234.50"))
        self.assertEqual(-12.3, p("(12.30)"))
        self.assertEqual(0.125, p("12.5%"))
        self.assertEqual(7.0, p(7))
        self.assertIsNone(p("abc"))
        self.assertIsNone(p(""))
        self.assertEqual(-5.0, p("-5"))
        self.assertEqual(1e3, p("1e3"))

    def test_canonical_key(self):
        k = par.canonical_key
        self.assertEqual(k(2026), k("2026"))
        self.assertEqual(k(2026.0), k("2026"))
        self.assertEqual("2026-01-31", k("2026-01-31T00:00:00.000Z"))
        self.assertEqual("2026-01-31", k("2026-01-31 00:00:00"))
        self.assertEqual("2026-01-31", k("2026-01-31"))
        self.assertEqual("2024-02-04", k("February 4, 2024"))
        self.assertEqual("2026-01", k("January 2026"))
        self.assertEqual("2024-01-01", k("2024 Q1"))
        self.assertEqual("", k(None))
        self.assertEqual("", k("(Blank)"))
        self.assertEqual("null", k("null"))      # literal text, not a NULL marker
        self.assertEqual("None", k("None"))
        self.assertEqual("nan", k("NaN".lower()))
        self.assertEqual("", k(float("nan")))    # a real float NaN is NULL
        self.assertEqual("true", k("True"))
        self.assertEqual("true", k(True))
        self.assertEqual("East", k("  East "))


class CompareTests(unittest.TestCase):
    ORACLE = [{"REGION": "East", "NET": 100.0, "UNITS": 3}, {"REGION": "West", "NET": 250.5, "UNITS": 5}]

    def test_exact_match(self):
        r = compare(["Region", "Net", "Units"], [["East", "100", "3"], ["West", "250.5", "5"]],
                    self.ORACLE, keys=["Region=REGION"], measures=["Net=NET", "Units=UNITS"])
        self.assertEqual("MATCH", r["classification"])
        self.assertEqual(4, r["cells_total"])
        self.assertEqual(4, r["cells_match"])

    def test_default_measures_are_common_non_key_columns(self):
        r = compare(["REGION", "net", "UNITS"], [["East", "100", "3"], ["West", "250.5", "5"]],
                    self.ORACLE, keys=["REGION"])
        self.assertEqual("MATCH", r["classification"])
        self.assertEqual(4, r["cells_total"])

    def test_tolerance_boundaries(self):
        rows = [["East", "100.004", "3"], ["West", "250.5", "5"]]
        ok = compare(["Region", "Net", "Units"], rows, self.ORACLE, keys=["Region=REGION"],
                     measures=["Net=NET", "Units=UNITS"])
        self.assertEqual("MATCH", ok["classification"])
        bad = compare(["Region", "Net", "Units"], [["East", "100.5", "3"], ["West", "250.5", "5"]],
                      self.ORACLE, keys=["Region=REGION"], measures=["Net=NET", "Units=UNITS"])
        self.assertEqual("DIVERGENT", bad["classification"])
        cell = bad["divergent_cells"][0]
        self.assertEqual((["East"], "Net"), (cell["key"], cell["measure"]))
        self.assertEqual("value-mismatch", cell["kind"])
        self.assertAlmostEqual(0.5, cell["delta"])

    def test_relative_tolerance_for_big_numbers(self):
        o = [{"K": "a", "V": 1_000_000_000.0}]
        r = compare(["K", "V"], [["a", "1000000050"]], o, keys=["K"], rel_tol=1e-8, abs_tol=0.0)
        self.assertEqual("DIVERGENT", r["classification"])
        r = compare(["K", "V"], [["a", "1000000050"]], o, keys=["K"], rel_tol=1e-6, abs_tol=0.0)
        self.assertEqual("MATCH", r["classification"])

    def test_formatted_numbers_in_export(self):
        o = [{"K": "a", "V": 1234.5, "P": -12.3}]
        r = compare(["K", "V", "P"], [["a", "$1,234.50", "(12.30)"]], o, keys=["K"])
        self.assertEqual("MATCH", r["classification"])

    def test_percent_formatted_export_matches_fraction_oracle(self):
        r = compare(["K", "Rate"], [["a", "12.5%"]], [{"K": "a", "RATE": 0.125}], keys=["K"])
        self.assertEqual("MATCH", r["classification"])

    def test_missing_in_sigma_is_divergent_per_cell(self):
        r = compare(["Region", "Net"], [["East", "100"]], self.ORACLE, keys=["Region=REGION"],
                    measures=["Net=NET"])
        self.assertEqual("DIVERGENT", r["classification"])
        self.assertEqual(1, r["missing_in_sigma"])
        self.assertTrue(any(c["kind"] == "missing-in-sigma" and c["key"] == ["West"] for c in r["divergent_cells"]))

    def test_extra_sigma_row_empty_ignored_but_nonempty_diverges(self):
        rows = [["East", "100", "3"], ["West", "250.5", "5"], ["North", "", ""]]
        r = compare(["Region", "Net", "Units"], rows, self.ORACLE, keys=["Region=REGION"],
                    measures=["Net=NET", "Units=UNITS"])
        self.assertEqual("MATCH", r["classification"])
        self.assertEqual(1, r["extra_empty_ignored"])
        rows[2] = ["North", "9", ""]
        r = compare(["Region", "Net", "Units"], rows, self.ORACLE, keys=["Region=REGION"],
                    measures=["Net=NET", "Units=UNITS"])
        self.assertEqual("DIVERGENT", r["classification"])
        self.assertEqual(1, r["extra_in_sigma"])
        r = compare(["Region", "Net", "Units"], rows, self.ORACLE, keys=["Region=REGION"],
                    measures=["Net=NET", "Units=UNITS"], ignore_extra_sigma=True)
        self.assertEqual("MATCH", r["classification"])

    def test_blank_vs_value_diverges_and_blank_zero_option(self):
        o = [{"K": "a", "V": 0}]
        self.assertEqual("DIVERGENT", compare(["K", "V"], [["a", ""]], o, keys=["K"])["classification"])
        self.assertEqual("MATCH", compare(["K", "V"], [["a", ""]], o, keys=["K"], blank_is_zero=True)["classification"])
        self.assertEqual("MATCH", compare(["K", "V"], [["a", ""]], [{"K": "a", "V": None}], keys=["K"])["classification"])

    def test_literal_none_member_is_a_real_bucket_distinct_from_null(self):
        """pipeline-5: a dimension with the member 'None' AND genuine NULLs must not collide."""
        o = [{"TIER": "None", "V": 5}, {"TIER": None, "V": 3}, {"TIER": "Gold", "V": 9}]
        r = compare(["Tier", "V"], [["None", "5"], ["", "3"], ["Gold", "9"]], o, keys=["Tier=TIER"])
        self.assertEqual("MATCH", r["classification"], r["issues"])
        self.assertFalse(r["issues"])
        for word in ("null", "nan", "None"):
            o = [{"K": word, "V": 1}]
            self.assertEqual("MATCH", compare(["K", "V"], [[word, "1"]], o, keys=["K"])["classification"], word)
        # a cell that is the TEXT 'None' is not blank: against a blank it diverges
        self.assertEqual("DIVERGENT", compare(["K", "V"], [["a", "None"]], [{"K": "a", "V": None}], keys=["K"])["classification"])
        self.assertTrue(par.is_blank(None) and par.is_blank(float("nan")) and par.is_blank("") and par.is_blank("(Blank)"))
        self.assertFalse(par.is_blank("None") or par.is_blank("null") or par.is_blank("NaN"))

    def test_zero_rows_on_both_sides_is_reported_not_passed(self):
        r = compare(["K", "V"], [], [], keys=["K"])
        self.assertEqual("DIVERGENT", r["classification"])
        self.assertTrue(any(i["kind"] == "empty-both" and "unverified" in i["detail"] for i in r["issues"]), r["issues"])
        self.assertTrue(r.get("unverified"))
        self.assertEqual(0, r["cells_total"])
        fin = par.build_final([r], "wb", "strict")
        self.assertEqual("FAIL", fin["status"])
        # one-sided emptiness is still an ordinary divergence, not 'empty-both'
        r2 = compare(["K", "V"], [], [{"K": "a", "V": 1}], keys=["K"])
        self.assertFalse(any(i["kind"] == "empty-both" for i in r2["issues"]))
        self.assertEqual("DIVERGENT", r2["classification"])

    def test_blank_key_buckets_reconcile(self):
        o = [{"K": None, "V": 5}]
        r = compare(["K", "V"], [["(Blank)", "5"]], o, keys=["K"])
        self.assertEqual("MATCH", r["classification"])

    def test_int_key_vs_string_key_and_date_forms(self):
        o = [{"YR": 2026, "D": "2026-01-31", "V": 1}]
        r = compare(["Yr", "D", "V"], [["2026", "2026-01-31T00:00:00.000Z", "1"]], o, keys=["Yr=YR", "D"])
        self.assertEqual("MATCH", r["classification"])

    def test_month_label_vs_first_of_month_falls_back_to_month_grain(self):
        o = [{"M": "2026-01-01", "V": 4}]
        r = compare(["M", "V"], [["January 2026", "4"]], o, keys=["M"])
        self.assertEqual("MATCH", r["classification"])
        self.assertTrue(any("month grain" in n for n in r["notes"]))

    def test_kpi_without_keys(self):
        r = compare(["Total"], [["1,234.50"]], [{"TOTAL": 1234.5}], keys=[])
        self.assertEqual("MATCH", r["classification"])
        r = compare(["Total"], [["1"], ["2"]], [{"TOTAL": 1}], keys=[])
        self.assertEqual("DIVERGENT", r["classification"])  # duplicate (empty) key on the Sigma side

    def test_duplicate_keys_are_reported_not_summed(self):
        r = compare(["Region", "Net"], [["East", "1"], ["East", "2"]], [{"REGION": "East", "NET": 3}],
                    keys=["Region=REGION"], measures=["Net=NET"])
        self.assertEqual("DIVERGENT", r["classification"])
        self.assertTrue(any(i["kind"] == "duplicate-keys" and i["side"] == "sigma" for i in r["issues"]))

    def test_unknown_column_is_an_issue_not_a_crash(self):
        r = compare(["Region", "Net"], [["East", "1"]], [{"REGION": "East", "NET": 1}],
                    keys=["Region=REGION"], measures=["Gross=GROSS"])
        self.assertEqual("DIVERGENT", r["classification"])
        self.assertTrue(any(i["kind"] == "column-not-found" for i in r["issues"]))

    def test_header_lookup_is_case_and_punctuation_insensitive(self):
        r = compare(["Net Revenue ($)", "Region"], [["5", "East"]], [{"REGION": "East", "NET_REVENUE": 5}],
                    keys=["Region"], measures=["Net Revenue ($)=NET_REVENUE"])
        self.assertEqual("MATCH", r["classification"])

    def test_text_measures_compare_as_strings(self):
        r = compare(["K", "Label"], [["a", "Gold"]], [{"K": "a", "LABEL": "Gold"}], keys=["K"])
        self.assertEqual("MATCH", r["classification"])
        r = compare(["K", "Label"], [["a", "Gold"]], [{"K": "a", "LABEL": "Silver"}], keys=["K"])
        self.assertEqual("DIVERGENT", r["classification"])

    def test_extract_mode_uses_loose_relative_tolerance(self):
        o = [{"K": "a", "V": 100.0}]
        r = compare(["K", "V"], [["a", "101"]], o, keys=["K"], rel_tol=0.02, abs_tol=0.0)
        self.assertEqual("MATCH", r["classification"])

    def test_detail_cells_are_all_classified_on_request(self):
        r = compare(["K", "V"], [["a", "1"]], [{"K": "a", "V": 1}], keys=["K"], all_cells=True)
        self.assertEqual("MATCH", r["cells"][0]["status"])


class OracleLoadTests(unittest.TestCase):
    def test_load_oracle_shapes(self):
        rows = [{"A": 1}]
        self.assertEqual(rows, par.load_oracle_rows(json.dumps(rows), "x.json"))
        self.assertEqual(rows, par.load_oracle_rows(json.dumps({"rows": rows}), "x.json"))
        probe = {"q1": {"ok": True, "rows": rows}, "q2": {"ok": True, "rows": [{"B": 2}]}}
        self.assertEqual(rows, par.load_oracle_rows(json.dumps(probe), "x.json", oracle_key="q1"))
        with self.assertRaises(par.ParityError):
            par.load_oracle_rows(json.dumps(probe), "x.json")  # ambiguous without a key
        with self.assertRaises(par.ParityError):
            par.load_oracle_rows(json.dumps({"q": {"ok": False, "error": "boom"}}), "x.json", oracle_key="q")
        self.assertEqual([{"A": "1", "B": "x"}], par.load_oracle_rows("A,B\n1,x\n", "x.csv"))


class RunTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, True)

    def w(self, name, text):
        p = os.path.join(self.d, name)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)
        return p

    def spec(self, charts):
        return self.w("spec.json", json.dumps({"charts": charts}))

    def test_artifacts_are_written_0600(self):
        exp = self.w("a.csv", csv_text(["Region", "Net"], [["East", "100"]]))
        orc = self.w("a.json", json.dumps([{"REGION": "East", "NET": 100}]))
        par.main(["--out-dir", self.d, "--workbook-id", "wb-1", "--name", "Chart A", "--export", exp,
                  "--oracle", orc, "--keys", "Region=REGION", "--measures", "Net=NET"])
        for n in ("parity-final.json", "parity-oracle-detail.json"):
            self.assertEqual(0o600, os.stat(os.path.join(self.d, n)).st_mode & 0o777, n)

    def test_final_shape_matches_phase6_parity_pbi(self):
        exp = self.w("a.csv", csv_text(["Region", "Net"], [["East", "100"]]))
        orc = self.w("a.json", json.dumps([{"REGION": "East", "NET": 100}]))
        rc = par.main(["--out-dir", self.d, "--workbook-id", "wb-1", "--name", "Chart A", "--export", exp,
                       "--oracle", orc, "--keys", "Region=REGION", "--measures", "Net=NET"])
        self.assertEqual(0, rc)
        with open(os.path.join(self.d, "parity-final.json")) as fh:
            fin = json.load(fh)
        self.assertEqual(PBI_FINAL_KEYS, list(fin.keys()))
        self.assertEqual("PASS", fin["status"])
        self.assertEqual(1, fin["charts_total"])
        self.assertEqual(1, fin["charts_pass"])
        self.assertEqual(1, fin["charts_verified"])
        self.assertEqual(0, fin["charts_fail"])
        self.assertEqual(["Chart A"], fin["pass_names"])
        self.assertEqual({"Chart A": "MATCH"}, fin["classifications"])
        self.assertEqual("strict", fin["mode"])
        self.assertEqual("wb-1", fin["workbook_id"])
        self.assertEqual("warehouse-sql-oracle", fin["source"])
        self.assertIsNone(fin["freshness"])
        self.assertRegex(fin["ran_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    @unittest.skipUnless(shutil.which("ruby"), "ruby not installed")
    def test_same_keys_and_types_as_the_ruby_finalize(self):
        """Run the real phase6-parity-pbi.rb --finalize on an equivalent plan and diff the shape."""
        rb_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, rb_dir, True)
        with open(os.path.join(rb_dir, "plan.json"), "w") as fh:
            json.dump({"source": "warehouse-sql-oracle", "extract": False,
                       "charts": [{"chart": "Chart A", "expected": [["East", 10]], "workbook_id": "wb-1"}]}, fh)
        with open(os.path.join(rb_dir, "act.json"), "w") as fh:
            json.dump({"Chart A": [["East", 10]]}, fh)
        subprocess.run(["ruby", os.path.join(HERE, "phase6-parity-pbi.rb"), "--finalize", "--plan",
                        os.path.join(rb_dir, "plan.json"), "--actuals", os.path.join(rb_dir, "act.json"),
                        "--out-dir", rb_dir], check=True, capture_output=True)
        with open(os.path.join(rb_dir, "parity-final.json")) as fh:
            ruby_final = json.load(fh)
        exp = self.w("a.csv", csv_text(["R", "V"], [["East", "10"]]))
        orc = self.w("a.json", json.dumps([{"R": "East", "V": 10}]))
        par.main(["--out-dir", self.d, "--workbook-id", "wb-1", "--name", "Chart A", "--export", exp,
                  "--oracle", orc, "--keys", "R"])
        with open(os.path.join(self.d, "parity-final.json")) as fh:
            mine = json.load(fh)
        self.assertEqual(list(ruby_final.keys()), list(mine.keys()))
        for k, v in ruby_final.items():
            if k != "ran_at":
                self.assertEqual(v, mine[k], k)

    def test_spec_with_multiple_charts_and_failures(self):
        a_exp = self.w("a.csv", csv_text(["Region", "Net"], [["East", "100"]]))
        a_orc = self.w("a.json", json.dumps([{"REGION": "East", "NET": 100}]))
        b_exp = self.w("b.csv", csv_text(["Region", "Net"], [["East", "90"]]))
        b_orc = self.w("b.json", json.dumps([{"REGION": "East", "NET": 100}]))
        spec = self.spec([
            {"name": "Chart A", "export": "a.csv", "oracle": "a.json", "keys": ["Region=REGION"], "measures": ["Net=NET"]},
            {"name": "Chart B", "export": "b.csv", "oracle": "b.json", "keys": ["Region=REGION"], "measures": ["Net=NET"]},
        ])
        rc = par.main(["--out-dir", self.d, "--workbook-id", "wb-1", "--spec", spec])
        self.assertEqual(2, rc)
        with open(os.path.join(self.d, "parity-final.json")) as fh:
            fin = json.load(fh)
        self.assertEqual("FAIL", fin["status"])
        self.assertEqual((2, 1, 1), (fin["charts_total"], fin["charts_pass"], fin["charts_fail"]))
        self.assertEqual(["Chart B"], fin["fail_names"])
        self.assertEqual({"Chart A": "MATCH", "Chart B": "DIVERGENT"}, fin["classifications"])
        with open(os.path.join(self.d, "parity-oracle-detail.json")) as fh:
            detail = json.load(fh)
        self.assertEqual("DIVERGENT", detail["charts"][1]["classification"])
        self.assertEqual(90.0, detail["charts"][1]["divergent_cells"][0]["sigma"])

    def test_missing_export_file_marks_chart_divergent_not_crash(self):
        spec = self.spec([{"name": "Chart A", "export": "nope.csv", "oracle": "nope.json", "keys": ["K"]}])
        rc = par.main(["--out-dir", self.d, "--spec", spec])
        self.assertEqual(2, rc)
        with open(os.path.join(self.d, "parity-final.json")) as fh:
            self.assertEqual("FAIL", json.load(fh)["status"])

    def test_empty_plan_is_a_usage_error(self):
        spec = self.spec([])
        with self.assertRaises(SystemExit) as cm:
            par.main(["--out-dir", self.d, "--spec", spec])
        self.assertEqual(3, cm.exception.code)

    def test_extract_mode_flag(self):
        exp = self.w("a.csv", csv_text(["K", "V"], [["a", "101"]]))
        orc = self.w("a.json", json.dumps([{"K": "a", "V": 100}]))
        rc = par.main(["--out-dir", self.d, "--name", "C", "--export", exp, "--oracle", orc, "--keys", "K",
                       "--extract-mode", "--extract-tol", "0.02"])
        self.assertEqual(0, rc)
        with open(os.path.join(self.d, "parity-final.json")) as fh:
            self.assertEqual("extract", json.load(fh)["mode"])

    def test_oracle_key_from_probe_results_file(self):
        exp = self.w("a.csv", csv_text(["K", "V"], [["a", "5"]]))
        orc = self.w("probe.json", json.dumps({"q7": {"ok": True, "rows": [{"K": "a", "V": 5}]}}))
        rc = par.main(["--out-dir", self.d, "--name", "C", "--export", exp, "--oracle", orc,
                       "--oracle-key", "q7", "--keys", "K"])
        self.assertEqual(0, rc)


if __name__ == "__main__":
    unittest.main(verbosity=1)
