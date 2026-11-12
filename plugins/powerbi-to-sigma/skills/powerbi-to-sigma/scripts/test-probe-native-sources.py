#!/usr/bin/env python3
"""Offline tests for probe-native-sources.py: the pre-POST gate that probes every
Custom SQL element once, verifies every bound [Custom SQL/X] column exists, and
emits the casts needed where the TMSL dataType class differs from the warehouse
type. Synthetic Sales/Orders/Customer model; no network.

Run: python3 scripts/test-probe-native-sources.py   (exit 0 = pass)
"""
import copy
import importlib.util
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


gate = load("probe_native_sources", "probe-native-sources.py")
sibling = load("test_sigma_sql_probe_fixture", "test-sigma-sql-probe.py")  # FakeSigma + TABLES


def sql_el(eid, name, stmt, cols):
    return {"id": eid, "kind": "table", "name": name,
            "source": {"kind": "sql", "connectionId": "conn-1", "statement": stmt},
            "columns": [{"id": f"{eid}_{i}", "name": n, "formula": f"[Custom SQL/{src}]"}
                        for i, (n, src) in enumerate(cols)]}


DM = {"pages": [{"id": "p", "name": "Data", "elements": [
    sql_el("orders_el", "Orders", "SELECT * FROM orders",
           [("Order Id", "ORDER_ID"), ("Status", "STATUS"), ("Is Flagged", "FLAG")]),
    sql_el("cust_el", "Customer", "SELECT * FROM customers",
           [("Customer Id", "CUSTOMER_ID"), ("Name", "NAME")]),
    {"id": "orders_view", "kind": "table", "name": "Orders View",
     "source": {"kind": "table", "elementId": "orders_el"},
     "columns": [{"id": "v1", "name": "Order Id", "formula": "[Orders/Order Id]"}]},
    {"id": "wt", "kind": "table", "name": "Warehouse Thing",
     "source": {"kind": "warehouse-table", "connectionId": "conn-1", "path": ["DB", "S", "T"]},
     "columns": [{"id": "w1", "formula": "[T/A]"}]},
]}]}

TMSL = {"model": {"tables": [
    {"name": "Orders", "columns": [
        {"name": "Order Id", "dataType": "int64", "sourceColumn": "ORDER_ID"},
        {"name": "Status", "dataType": "string", "sourceColumn": "STATUS"},
        {"name": "Is Flagged", "dataType": "boolean", "sourceColumn": "FLAG"}]},
    {"name": "Customer", "columns": [
        {"name": "Customer Id", "dataType": "string", "sourceColumn": "CUSTOMER_ID"},
        {"name": "Name", "dataType": "string", "sourceColumn": "NAME"}]},
]}}

PROBE = {  # what sigma-sql-probe.py --types returns, keyed by gate's probe key
    "orders": {"ok": True, "columns": ["ORDER_ID", "STATUS", "FLAG"],
               "types": {"ORDER_ID": "NUMBER(38,0)[SB8]", "STATUS": "VARCHAR(16777216)[LOB]",
                         "FLAG": "VARCHAR(16)[LOB]"}},
    "customers": {"ok": True, "columns": ["CUSTOMER_ID", "NAME"],
                  "types": {"CUSTOMER_ID": "NUMBER(38,0)[SB8]", "NAME": "VARCHAR(100)[LOB]"}},
}


def by_stmt(results_by_table):
    """Key the fake probe results the way the gate keys its queries (by statement hash)."""
    out = {}
    for table, res in results_by_table.items():
        out[gate.statement_key(f"SELECT * FROM {table}")] = res
    return out


class ClassifyTests(unittest.TestCase):
    def test_snowflake_types(self):
        c = gate.warehouse_class
        self.assertEqual("text", c("VARCHAR(16777216)[LOB]"))
        self.assertEqual("integer", c("NUMBER(38,0)[SB16]"))
        self.assertEqual("decimal", c("NUMBER(10,2)[SB8]"))
        self.assertEqual("float", c("FLOAT"))
        self.assertEqual("date", c("DATE"))
        self.assertEqual("datetime", c("TIMESTAMP_NTZ(9)[SB16]"))
        self.assertEqual("boolean", c("BOOLEAN"))
        self.assertEqual("variant", c("VARIANT"))
        self.assertEqual("binary", c("BINARY(8388608)"))

    def test_databricks_types(self):
        c = gate.warehouse_class
        self.assertEqual("text", c("string"))
        self.assertEqual("integer", c("bigint"))
        self.assertEqual("decimal", c("decimal(18,2)"))
        self.assertEqual("integer", c("decimal(18,0)"))
        self.assertEqual("float", c("double"))
        self.assertEqual("datetime", c("timestamp_ntz"))
        self.assertEqual("variant", c("array<string>"))

    def test_tmsl_classes(self):
        c = gate.tmsl_class
        self.assertEqual("text", c("string"))
        self.assertEqual("integer", c("int64"))
        self.assertEqual("float", c("double"))
        self.assertEqual("decimal", c("decimal"))
        self.assertEqual("datetime", c("dateTime"))
        self.assertEqual("boolean", c("boolean"))
        self.assertIsNone(c("variant"))


class CastTests(unittest.TestCase):
    def test_varchar_true_false_to_boolean_snowflake(self):
        k = gate.cast_kind("boolean", "text")
        self.assertEqual("to_boolean", k)
        self.assertEqual('TRY_TO_BOOLEAN("FLAG")', gate.cast_expression(k, '"FLAG"', "snowflake", "boolean"))

    def test_no_cast_when_compatible(self):
        for t, w in [("text", "text"), ("integer", "integer"), ("integer", "decimal"), ("float", "integer"),
                     ("decimal", "float"), ("datetime", "date"), ("datetime", "datetime"), ("boolean", "boolean")]:
            self.assertIsNone(gate.cast_kind(t, w), (t, w))

    def test_text_to_number_and_timestamp_and_number_to_text(self):
        self.assertEqual("to_integer", gate.cast_kind("integer", "text"))
        self.assertEqual("to_float", gate.cast_kind("float", "text"))
        self.assertEqual("to_decimal", gate.cast_kind("decimal", "text"))
        self.assertEqual("to_timestamp", gate.cast_kind("datetime", "text"))
        self.assertEqual("to_text", gate.cast_kind("text", "integer"))
        self.assertEqual("to_boolean_numeric", gate.cast_kind("boolean", "integer"))
        self.assertEqual("to_boolean_numeric", gate.cast_kind("boolean", "decimal"))
        self.assertEqual("to_boolean", gate.cast_kind("boolean", "text"))

    def test_uncastable_pairs_are_flagged_not_guessed(self):
        self.assertEqual("unresolved", gate.cast_kind("datetime", "integer"))
        self.assertEqual("unresolved", gate.cast_kind("integer", "boolean"))

    def test_dialect_expressions(self):
        e = gate.cast_expression
        self.assertEqual("TRY_CAST(`C` AS BIGINT)", e("to_integer", "`C`", "databricks", "integer"))
        self.assertEqual("SAFE_CAST(`C` AS BOOL)", e("to_boolean", "`C`", "bigquery", "boolean"))
        self.assertEqual('TO_VARCHAR("C")', e("to_text", '"C"', "snowflake", "text"))
        self.assertEqual('TRY_TO_NUMBER("C", 38, 0)', e("to_integer", '"C"', "snowflake", "integer"))


class NumericBooleanCastTests(unittest.TestCase):
    """whole-6: TRY_TO_BOOLEAN takes string input only on Snowflake; a NUMBER 0/1 column needs a
    comparison form, per dialect."""

    def test_numeric_source_never_uses_try_to_boolean(self):
        for d in ("snowflake", "databricks", "bigquery"):
            q = '"F"' if d == "snowflake" else "`F`"
            e = gate.cast_expression("to_boolean_numeric", q, d, "boolean")
            self.assertNotIn("TRY_TO_BOOLEAN", e, (d, e))
        self.assertEqual('IFF("F" IS NULL, NULL, "F" <> 0)',
                         gate.cast_expression("to_boolean_numeric", '"F"', "snowflake", "boolean"))
        self.assertEqual("(`F` <> 0)", gate.cast_expression("to_boolean_numeric", "`F`", "bigquery", "boolean"))
        self.assertEqual("(`F` <> 0)", gate.cast_expression("to_boolean_numeric", "`F`", "databricks", "boolean"))

    def test_text_source_keeps_try_to_boolean(self):
        self.assertEqual('TRY_TO_BOOLEAN("F")', gate.cast_expression("to_boolean", '"F"', "snowflake", "boolean"))

    def test_build_report_emits_the_numeric_form_for_a_number_flag(self):
        pr = json.loads(json.dumps(PROBE))
        pr["orders"]["types"]["FLAG"] = "NUMBER(1,0)[SB1]"
        rep = gate.build_report(DM, TMSL, by_stmt(pr))
        c = [x for x in rep["casts"] if x["column"] == "Is Flagged"][0]
        self.assertEqual("to_boolean_numeric", c["kind"])
        self.assertNotIn("TRY_TO_BOOLEAN", c["expression"])
        self.assertIn("<> 0", rep["patched_statements"]["orders_el"])


class CultureDecimalTests(unittest.TestCase):
    """pipeline-3: comma-decimal is a property of the FULL culture, not the language."""

    def _comma(self, culture):
        e = gate.cast_expression("to_decimal", '"A"', "snowflake", "decimal", culture=culture)
        return "',', '.'" in e

    def test_language_default_comma_decimal(self):
        for c in ("de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "ru-RU", "nl-NL", "de-AT", "de"):
            self.assertTrue(self._comma(c), c)

    def test_dot_decimal_regional_exceptions(self):
        for c in ("de-CH", "de-LI", "it-CH", "es-MX", "es-US", "es-PR", "es-DO", "es-GT", "es-PE", "es-419"):
            self.assertFalse(self._comma(c), c)

    def test_comma_decimal_english_regions(self):
        for c in ("en-ZA", "en-DK", "en-NL", "en-SE", "en-150"):
            self.assertTrue(self._comma(c), c)
        for c in ("en-US", "en-GB", "en-AU", "en-IN", "en-CA"):
            self.assertFalse(self._comma(c), c)

    def test_swiss_apostrophe_grouping_is_stripped(self):
        e = gate.cast_expression("to_decimal", '"A"', "snowflake", "decimal", culture="de-CH")
        self.assertIn("CHR(39)", e)
        self.assertIn("\u2019", e)
        self.assertNotIn("',', '.'", e)

    def test_underscore_and_case_are_tolerated(self):
        self.assertFalse(self._comma("de_ch"))
        self.assertTrue(self._comma("EN_za"))


class CultureNumberParseTests(unittest.TestCase):
    """Power Query's `type number` parses text with the MODEL culture: en-US accepts "$1,234.50 ".
    A bare TRY_TO_DOUBLE returns NULL for it, which silently undercounts every amount stored as text."""

    def test_en_us_strips_currency_grouping_and_spaces(self):
        e = gate.cast_expression("to_float", '"AMT"', "snowflake", "float", culture="en-US")
        self.assertTrue(e.startswith("TRY_TO_DOUBLE("), e)
        for ch in ("'$'", "','", "' '"):
            self.assertIn(ch, e)
        self.assertNotIn("'.'", e)  # the decimal point is kept

    def test_comma_decimal_culture_swaps_separators(self):
        e = gate.cast_expression("to_decimal", '"AMT"', "snowflake", "decimal", culture="de-DE")
        self.assertIn("'.', ''", e)       # grouping dot removed
        self.assertIn("',', '.'", e)      # decimal comma -> point
        self.assertTrue(e.startswith("TRY_TO_DECIMAL("), e)

    def test_dialects_and_integer(self):
        self.assertTrue(gate.cast_expression("to_float", "`A`", "databricks", "float", culture="en-US")
                        .startswith("TRY_CAST(REPLACE("))
        self.assertTrue(gate.cast_expression("to_integer", "`A`", "bigquery", "integer", culture="en-GB")
                        .startswith("SAFE_CAST(REPLACE("))

    def test_no_culture_keeps_the_plain_cast(self):
        self.assertEqual('TRY_TO_DOUBLE("C")', gate.cast_expression("to_float", '"C"', "snowflake", "float"))

    def test_non_numeric_kinds_are_untouched(self):
        self.assertEqual('TRY_TO_BOOLEAN("F")', gate.cast_expression("to_boolean", '"F"', "snowflake", "boolean",
                                                                     culture="en-US"))

    def test_build_report_uses_the_model_culture(self):
        dm = json.loads(json.dumps(DM))
        dm["pages"][0]["elements"][0]["columns"].append(
            {"id": "orders_el-amt", "name": "Amount", "formula": "[Custom SQL/AMOUNT]"})
        tm = json.loads(json.dumps(TMSL))
        tm["model"]["tables"][0]["columns"].append({"name": "Amount", "dataType": "double", "sourceColumn": "AMOUNT"})
        pr = json.loads(json.dumps(PROBE))
        pr["orders"]["columns"].append("AMOUNT")
        pr["orders"]["types"]["AMOUNT"] = "VARCHAR(32)[LOB]"
        tm["model"]["culture"] = "en-US"
        rep = gate.build_report(dm, tm, by_stmt(pr))
        num = [c for c in rep["casts"] if c["column"] == "Amount"]
        self.assertEqual(1, len(num), rep["casts"])
        self.assertIn("REPLACE(", num[0]["expression"])
        del tm["model"]["culture"]  # no culture recorded: Power BI's default is en-US
        rep2 = gate.build_report(dm, tm, by_stmt(pr))
        self.assertIn("REPLACE(", [c for c in rep2["casts"] if c["column"] == "Amount"][0]["expression"])


class GateTests(unittest.TestCase):
    def run_gate(self, dm=DM, tmsl=TMSL, probe=None, **kw):
        return gate.build_report(dm, tmsl, by_stmt(probe if probe is not None else PROBE), **kw)

    def test_clean_model_with_one_cast(self):
        rep = self.run_gate()
        self.assertEqual("PASS", rep["status"])
        self.assertEqual(2, rep["summary"]["elements_probed"])
        self.assertEqual(0, rep["summary"]["missing_columns"])
        casts = {(c["table"], c["column"]): c for c in rep["casts"]}
        self.assertEqual({("Orders", "Is Flagged"), ("Customer", "Customer Id")}, set(casts))
        self.assertEqual("to_boolean", casts[("Orders", "Is Flagged")]["kind"])
        self.assertEqual('TRY_TO_BOOLEAN("FLAG")', casts[("Orders", "Is Flagged")]["expression"])
        self.assertEqual("boolean", casts[("Orders", "Is Flagged")]["tmsl_class"])
        self.assertEqual("text", casts[("Orders", "Is Flagged")]["warehouse_class"])
        self.assertEqual("to_text", casts[("Customer", "Customer Id")]["kind"])

    def test_non_sql_elements_are_ignored(self):
        rep = self.run_gate()
        ids = {e["id"] for e in rep["elements"]}
        self.assertEqual({"orders_el", "cust_el"}, ids)

    def test_patched_statement_keeps_output_names_and_casts_only_what_is_needed(self):
        rep = self.run_gate()
        s = rep["patched_statements"]["orders_el"]
        self.assertIn('"ORDER_ID", "STATUS", TRY_TO_BOOLEAN("FLAG") AS "FLAG"', s)
        self.assertIn("\nSELECT * FROM orders\n", s)

    def test_missing_column_fails_the_gate_with_suggestion(self):
        probe = copy.deepcopy(PROBE)
        probe["orders"]["columns"] = ["ORDER_ID", "STATUS", "FLAGGED"]
        probe["orders"]["types"] = {"ORDER_ID": "NUMBER(38,0)", "STATUS": "VARCHAR(5)", "FLAGGED": "BOOLEAN"}
        rep = self.run_gate(probe=probe)
        self.assertEqual("FAIL", rep["status"])
        self.assertEqual(1, rep["summary"]["missing_columns"])
        el = next(e for e in rep["elements"] if e["id"] == "orders_el")
        self.assertEqual("missing-columns", el["status"])
        miss = [b for b in el["bound"] if b["status"] == "missing"][0]
        self.assertEqual("FLAG", miss["ref"])
        self.assertIn("FLAGGED", miss["suggestions"])

    def test_case_only_difference_passes_with_note_unless_strict(self):
        probe = copy.deepcopy(PROBE)
        probe["customers"]["columns"] = ["Customer_Id", "NAME"]
        probe["customers"]["types"] = {"Customer_Id": "NUMBER(38,0)", "NAME": "VARCHAR(5)"}
        # DM binds [Custom SQL/CUSTOMER_ID]
        rep = self.run_gate(probe=probe)
        self.assertEqual("PASS", rep["status"])
        self.assertEqual(1, rep["summary"]["case_only_matches"])
        rep2 = self.run_gate(probe=probe, strict_case=True)
        self.assertEqual("FAIL", rep2["status"])
        # underscore-different is NOT a case match
        probe["customers"]["columns"] = ["CustomerId", "NAME"]
        probe["customers"]["types"] = {"CustomerId": "NUMBER(38,0)", "NAME": "VARCHAR(5)"}
        self.assertEqual("FAIL", self.run_gate(probe=probe)["status"])

    def test_probe_error_fails_and_carries_text(self):
        probe = copy.deepcopy(PROBE)
        probe["customers"] = {"ok": False, "error": "SQL compilation error: object does not exist"}
        rep = self.run_gate(probe=probe)
        self.assertEqual("FAIL", rep["status"])
        el = next(e for e in rep["elements"] if e["id"] == "cust_el")
        self.assertEqual("probe-error", el["status"])
        self.assertIn("does not exist", el["error"])

    def test_slash_in_bound_output_name_is_ambiguous(self):
        dm = copy.deepcopy(DM)
        dm["pages"][0]["elements"][1]["columns"].append(
            {"id": "x", "name": "Ratio", "formula": "[Custom SQL/A/B]"})
        probe = copy.deepcopy(PROBE)
        probe["customers"]["columns"] = ["CUSTOMER_ID", "NAME", "A/B"]
        probe["customers"]["types"]["A/B"] = "FLOAT"
        rep = self.run_gate(dm=dm, probe=probe)
        self.assertEqual("FAIL", rep["status"])
        self.assertEqual(1, rep["summary"]["ambiguous_names"])

    def test_refs_inside_follow_on_formulas_are_checked_too(self):
        dm = copy.deepcopy(DM)
        dm["pages"][0]["elements"][0]["columns"].append(
            {"id": "y", "name": "Year", "formula": "Year([Custom SQL/ORDER_DATE])"})
        rep = self.run_gate(dm=dm)
        self.assertEqual("FAIL", rep["status"])
        self.assertEqual(1, rep["summary"]["missing_columns"])

    def test_unresolvable_type_pair_is_a_warning_not_a_failure(self):
        tmsl = copy.deepcopy(TMSL)
        tmsl["model"]["tables"][0]["columns"][0]["dataType"] = "dateTime"  # int in the warehouse
        rep = self.run_gate(tmsl=tmsl)
        self.assertEqual("PASS", rep["status"])
        self.assertEqual("Order Id", rep["type_warnings"][0]["column"])
        self.assertNotIn("Order Id", [c["column"] for c in rep["casts"]])

    def test_tmsl_table_missing_is_recorded(self):
        tmsl = {"model": {"tables": [TMSL["model"]["tables"][1]]}}
        rep = self.run_gate(tmsl=tmsl)
        self.assertEqual("PASS", rep["status"])
        self.assertEqual(["Orders"], [u["name"] for u in rep["unmapped_elements"]])

    def test_bare_tmsl_without_model_wrapper_and_case_insensitive_table_name(self):
        tmsl = {"tables": [dict(t, name=t["name"].lower()) for t in TMSL["model"]["tables"]]}
        rep = self.run_gate(tmsl=tmsl)
        self.assertEqual(2, len(rep["casts"]))

    def test_identical_statements_are_probed_once(self):
        dm = copy.deepcopy(DM)
        dm["pages"][0]["elements"].append(
            sql_el("orders_el2", "Orders", "SELECT * FROM orders;", [("Order Id", "ORDER_ID")]))
        self.assertEqual(2, len(gate.unique_queries(gate.sql_elements(dm))))

    def test_databricks_cast_syntax(self):
        probe = copy.deepcopy(PROBE)
        probe["orders"]["types"] = {"ORDER_ID": "bigint", "STATUS": "string", "FLAG": "string"}
        rep = self.run_gate(probe=probe, dialect="databricks")
        c = next(c for c in rep["casts"] if c["column"] == "Is Flagged")
        self.assertEqual("TRY_CAST(`FLAG` AS BOOLEAN)", c["expression"])
        self.assertIn("`ORDER_ID`", rep["patched_statements"]["orders_el"])

    def test_no_types_available_records_note_and_no_casts(self):
        probe = copy.deepcopy(PROBE)
        for v in probe.values():
            v.pop("types")
        rep = self.run_gate(probe=probe)
        self.assertEqual([], rep["casts"])
        self.assertTrue(rep["notes"])


class UnverifiedZeroRowTests(unittest.TestCase):
    """pipeline-1: an ok probe with no output columns (BigQuery zero-row result) is UNVERIFIED,
    never 'every bound column is missing'."""

    def test_empty_columns_is_a_probe_error_not_missing(self):
        pr = {"orders": {"ok": True, "columns": [], "unverified": True, "note": "no rows"},
              "customers": PROBE["customers"]}
        rep = gate.build_report(DM, TMSL, by_stmt(pr), dialect="bigquery")
        o = [e for e in rep["elements"] if e["id"] == "orders_el"][0]
        self.assertEqual("probe-error", o["status"])
        self.assertIn("no rows", o["error"])
        self.assertEqual(0, rep["summary"]["missing_columns"])
        self.assertNotIn("bound", o)

    def test_empty_columns_with_no_note_still_unverified(self):
        pr = {"orders": {"ok": True, "columns": []}, "customers": PROBE["customers"]}
        rep = gate.build_report(DM, TMSL, by_stmt(pr), dialect="bigquery")
        o = [e for e in rep["elements"] if e["id"] == "orders_el"][0]
        self.assertEqual("probe-error", o["status"])


class MainTests(unittest.TestCase):
    def write(self, d, name, obj):
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            json.dump(obj, fh)
        return p

    def test_main_with_precomputed_probe_results(self):
        with tempfile.TemporaryDirectory() as d:
            dm = self.write(d, "dm.json", DM)
            tm = self.write(d, "model.bim", TMSL)
            pr = self.write(d, "probe.json", by_stmt(PROBE))
            out = os.path.join(d, "report.json")
            patched = os.path.join(d, "dm-patched.json")
            rc = gate.main(["--dm", dm, "--tmsl", tm, "--probe-results", pr, "--out", out,
                            "--write-patched-dm", patched])
            self.assertEqual(0, rc)
            with open(out) as fh:
                rep = json.load(fh)
            self.assertEqual("PASS", rep["status"])
            with open(patched) as fh:
                pdm = json.load(fh)
            stmt = pdm["pages"][0]["elements"][0]["source"]["statement"]
            self.assertIn("TRY_TO_BOOLEAN", stmt)
            # untouched element keeps its original statement shape except for the needed cast
            self.assertEqual(DM["pages"][0]["elements"][2], pdm["pages"][0]["elements"][2])

    def test_main_exits_nonzero_on_missing_column(self):
        with tempfile.TemporaryDirectory() as d:
            probe = copy.deepcopy(PROBE)
            probe["customers"]["columns"] = ["CUSTOMER_ID"]
            probe["customers"]["types"] = {"CUSTOMER_ID": "NUMBER(38,0)"}
            rc = gate.main(["--dm", self.write(d, "dm.json", DM), "--tmsl", self.write(d, "m.bim", TMSL),
                            "--probe-results", self.write(d, "p.json", by_stmt(probe)),
                            "--out", os.path.join(d, "r.json")])
            self.assertEqual(1, rc)

    def test_main_unwraps_conv_meta_model_wrapper(self):
        with tempfile.TemporaryDirectory() as d:
            rc = gate.main(["--dm", self.write(d, "conv.json", {"model": DM}),
                            "--tmsl", self.write(d, "m.bim", TMSL),
                            "--probe-results", self.write(d, "p.json", by_stmt(PROBE)),
                            "--out", os.path.join(d, "r.json")])
            self.assertEqual(0, rc)

    def test_main_probes_through_sigma_with_fake_http(self):
        """End to end: gate -> Probe(types) -> fake Sigma -> report."""
        with tempfile.TemporaryDirectory() as d:
            fake = sibling.FakeSigma()
            rc = gate.main(["--dm", self.write(d, "dm.json", DM), "--tmsl", self.write(d, "m.bim", TMSL),
                            "--connection-id", "conn-1", "--folder-id", "folder-1",
                            "--out", os.path.join(d, "r.json"), "--state", os.path.join(d, "s.json")],
                           api=fake.api, sleep=lambda s: None)
            self.assertEqual(0, rc)
            with open(os.path.join(d, "r.json")) as fh:
                rep = json.load(fh)
            self.assertEqual({"Is Flagged", "Customer Id"}, {c["column"] for c in rep["casts"]})

    def _live(self, d, dm=None, extra=(), fake=None, **kw):
        fake = fake or sibling.FakeSigma()
        rc = gate.main(["--dm", self.write(d, "dm.json", dm or DM), "--tmsl", self.write(d, "m.bim", TMSL),
                        "--connection-id", "conn-1", "--folder-id", "folder-1",
                        "--out", os.path.join(d, "r.json"), "--state", os.path.join(d, "s.json"), *extra],
                       api=fake.api, sleep=lambda s: None, **kw)
        return rc, fake

    def test_scratch_workbook_is_deleted_after_a_run(self):
        with tempfile.TemporaryDirectory() as d:
            rc, fake = self._live(d)
            self.assertEqual(0, rc)
            self.assertIn(("DELETE", "/v2/files/wb-1"), fake.calls)
            self.assertIsNone(fake.workbook)

    def test_scratch_workbook_is_deleted_even_when_the_run_fails(self):
        with tempfile.TemporaryDirectory() as d:
            real = gate.build_report
            def boom(*a, **k):
                raise RuntimeError("report exploded")
            gate.build_report = boom
            try:
                fake = sibling.FakeSigma()
                with self.assertRaises(RuntimeError):
                    self._live(d, fake=fake)
            finally:
                gate.build_report = real
            self.assertIn(("DELETE", "/v2/files/wb-1"), fake.calls)
            self.assertIsNone(fake.workbook)

    def test_keep_probe_workbook_flag_skips_the_delete(self):
        with tempfile.TemporaryDirectory() as d:
            rc, fake = self._live(d, extra=["--keep-probe-workbook"])
            self.assertEqual(0, rc)
            self.assertEqual("wb-1", fake.workbook)
            self.assertFalse(any(c[0] == "DELETE" for c in fake.calls))

    def test_stale_state_workbook_id_is_recreated_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "s.json"), "w") as fh:
                json.dump({"version": 1, "workbookId": "wb-gone", "created": True, "results": {}}, fh)
            rc, fake = self._live(d)
            self.assertEqual(0, rc)
            self.assertIn(("POST", "/v2/workbooks"), fake.calls)
            self.assertIn(("DELETE", "/v2/files/wb-1"), fake.calls)

    def test_bigquery_runs_columns_only_and_records_the_skipped_type_checks(self):
        with tempfile.TemporaryDirectory() as d:
            rc, fake = self._live(d, extra=["--dialect", "bigquery"])
            self.assertEqual(0, rc)  # no ProbeError abort after the workbook was created
            with open(os.path.join(d, "r.json")) as fh:
                rep = json.load(fh)
            self.assertEqual("PASS", rep["status"])
            self.assertEqual([], rep["casts"])
            self.assertTrue(any("type checks were skipped" in n and "bigquery" in n.lower() for n in rep["notes"]), rep["notes"])
            self.assertTrue(rep["type_checks_skipped"])
            self.assertIn(("DELETE", "/v2/files/wb-1"), fake.calls)  # and nothing is leaked

    def test_outputs_are_written_0600(self):
        with tempfile.TemporaryDirectory() as d:
            self._live(d, extra=["--write-patched-dm", os.path.join(d, "patched.json")])
            for n in ("r.json", "patched.json"):
                self.assertEqual(0o600, os.stat(os.path.join(d, n)).st_mode & 0o777, n)

    def test_cache_reports_cached_vs_probed_and_no_cache_flag_bypasses(self):
        with tempfile.TemporaryDirectory() as d:
            rc, f1 = self._live(d)
            with open(os.path.join(d, "r.json")) as fh:
                self.assertEqual({"cached": 0, "probed": 2}, json.load(fh)["probe_cache"])
            rc, f2 = self._live(d)
            with open(os.path.join(d, "r.json")) as fh:
                self.assertEqual({"cached": 2, "probed": 0}, json.load(fh)["probe_cache"])
            self.assertEqual(0, f2.writes)
            rc, f3 = self._live(d, extra=["--probe-no-cache"])
            with open(os.path.join(d, "r.json")) as fh:
                self.assertEqual({"cached": 0, "probed": 2}, json.load(fh)["probe_cache"])

    def test_cache_max_age_flag_reprobes_old_entries(self):
        with tempfile.TemporaryDirectory() as d:
            self._live(d)
            cache = os.path.join(d, "r.cache.json")
            with open(cache) as fh:
                doc = json.load(fh)
            self.assertTrue(doc.get("times"), "entries carry a timestamp")
            doc["times"] = {k: v - 48 * 3600 for k, v in doc["times"].items()}
            with open(cache, "w") as fh:
                json.dump(doc, fh)
            rc, f2 = self._live(d)  # default 24h: everything expired
            with open(os.path.join(d, "r.json")) as fh:
                self.assertEqual({"cached": 0, "probed": 2}, json.load(fh)["probe_cache"])
            rc, f3 = self._live(d, extra=["--probe-cache-max-age-hours", "1"])
            with open(os.path.join(d, "r.json")) as fh:
                self.assertEqual({"cached": 2, "probed": 0}, json.load(fh)["probe_cache"])

    def test_missing_column_message_mentions_no_cache_when_results_were_cached(self):
        import contextlib, io
        with tempfile.TemporaryDirectory() as d:
            dm = json.loads(json.dumps(DM))
            dm["pages"][0]["elements"][0]["columns"].append(
                {"id": "ghost", "name": "Ghost", "formula": "[Custom SQL/GHOST]"})
            self._live(d, dm=dm)
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self._live(d, dm=dm)
            self.assertIn("--probe-no-cache", err.getvalue())

    def test_probe_concurrency_flag_is_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            rc, fake = self._live(d, extra=["--probe-concurrency", "3"])
            self.assertEqual(0, rc)
            self.assertEqual(2, fake.writes)  # columns pass + type pass, each ONE workbook write

    def test_main_without_probe_source_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(SystemExit) as cm:
                gate.main(["--dm", self.write(d, "dm.json", DM), "--tmsl", self.write(d, "m.bim", TMSL)])
            self.assertEqual(2, cm.exception.code)


if __name__ == "__main__":
    unittest.main(verbosity=1)
