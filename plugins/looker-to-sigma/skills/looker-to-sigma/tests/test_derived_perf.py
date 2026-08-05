#!/usr/bin/env python3
"""detect_derived_perf.py regression (offline, creds-free, no network).

Runs the scanner over fixtures/skilltest-derived (synthetic demo views) and
asserts the classifications a migration relies on:

  perf_base        simple ephemeral derived table            → leave-inline (low)
  perf_nested      nested on perf_base + joins + group by     → materialize
  perf_pdt         persisted PDT (datagroup_trigger)          → materialize
  perf_incremental incremental PDT (increment_key/Liquid)     → materialize
  perf_plain       plain sql_table_name view (no derived)     → NOT a finding

Also: --scope-explores demotes out-of-scope tables; an all-plain dir is silent.

Run: python3 tests/test_derived_perf.py   (exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCANNER = os.path.join(SKILL, "scripts", "detect_derived_perf.py")
FIX = os.path.join(SKILL, "fixtures", "skilltest-derived")


def _scan(*args):
    r = subprocess.run([sys.executable, SCANNER, *args, "--json"],
                       capture_output=True, text=True)
    assert r.returncode == 0, f"exit {r.returncode}: {r.stderr}"
    return json.loads(r.stdout)


def test_classification():
    out = _scan(FIX)
    byview = {f["view"]: f for f in out["findings"]}

    assert "perf_plain" not in byview, "a plain sql_table_name view must not be flagged"

    assert byview["perf_base"]["recommendation"] == "leave-inline", byview["perf_base"]
    assert byview["perf_base"]["severity"] == "low"

    n = byview["perf_nested"]
    assert n["recommendation"] == "materialize", n
    assert "perf_base" in n["nested_on"], n
    assert any(s.startswith("nested_dt") for s in n["signals"]), n

    assert byview["perf_pdt"]["recommendation"] == "materialize"
    assert "persisted_pdt" in byview["perf_pdt"]["signals"]

    inc = byview["perf_incremental"]
    assert inc["recommendation"] == "materialize"
    assert "incremental_pdt" in inc["signals"]

    # cost ordering: a nested/complex table outranks the trivial one
    assert n["cost"] > byview["perf_base"]["cost"], (n["cost"], byview["perf_base"]["cost"])
    print("PASS test_classification")


def test_scope_explores():
    # perf_explore = from: perf_nested, join: perf_pdt → only those two in scope
    out = _scan(FIX, "--scope-explores", "perf_explore")
    in_scope = {f["view"] for f in out["findings"]}
    info = {f["view"] for f in out["informational"]}
    assert "perf_nested" in in_scope and "perf_pdt" in in_scope, in_scope
    assert "perf_incremental" in info and "perf_base" in info, info
    print("PASS test_scope_explores")


def test_silent_when_no_derived_tables():
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "plain.view.lkml"), "w") as f:
            f.write("view: only_plain {\n  sql_table_name: DEMO.PUBLIC.T ;;\n"
                    "  dimension: id { sql: ${TABLE}.id ;; }\n}\n")
        out = _scan(d)
        assert out["findings"] == [], out
        assert out["informational"] == [], out
    print("PASS test_silent_when_no_derived_tables")


if __name__ == "__main__":
    test_classification()
    test_scope_explores()
    test_silent_when_no_derived_tables()
    print("ALL PASS")
