#!/usr/bin/env python3
"""Credentials-free regression tests for Looker tile-filter expressions."""

import json
import os
import subprocess
import sys
import tempfile


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIXTURE = os.path.join(SKILL, "fixtures", "skilltest-orders")
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))

from looker_filter_expr import matches_filter_expr, parse_filter_expr  # noqa: E402


def test_expression_table():
    cases = [
        ("NOT NULL", "exclude", [None]),
        ("is not null", "exclude", [None]),
        ("-NULL", "exclude", [None]),
        ("NULL", "include", [None]),
        ("is null", "include", [None]),
        ("EMPTY", "include", [None, ""]),
        ("-EMPTY", "exclude", [None, ""]),
        ("Complete,Returned", "include", ["Complete", "Returned"]),
        ("-Cancelled,-Pending", "exclude", ["Cancelled", "Pending"]),
    ]
    for expr, mode, values in cases:
        got = parse_filter_expr(expr, "column", "filter")
        assert got["mode"] == mode, (expr, got)
        assert got["values"] == values, (expr, got)
        assert got["id"] == "filter"
    assert parse_filter_expr(">100", "column") is None
    assert parse_filter_expr("30 days", "column") is None
    assert parse_filter_expr("Complete,-Returned", "column") is None


def test_offline_predicate_matches_builder_semantics():
    assert matches_filter_expr(None, "NOT NULL") is False
    assert matches_filter_expr(0, "NOT NULL") is True
    assert matches_filter_expr("", "EMPTY") is True
    assert matches_filter_expr(None, "-EMPTY") is False
    assert matches_filter_expr("Complete", "complete,returned") is True
    assert matches_filter_expr("Pending", "-Cancelled,-Pending") is False
    assert matches_filter_expr("Complete", ">100") is None


def test_builder_never_emits_null_operator_as_literal():
    parse = subprocess.run(
        [
            sys.executable,
            os.path.join(SCRIPTS, "parse_lookml_dashboard.py"),
            os.path.join(FIXTURE, "skilltest_orders.dashboard.lookml"),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    contract = json.loads(parse.stdout)
    table = next(element for element in contract["elements"] if element["tileType"] == "table")
    table["filters"] = {"order_fact.order_status": "NOT NULL"}

    with tempfile.TemporaryDirectory() as tmp:
        contract_path = os.path.join(tmp, "contract.json")
        output_path = os.path.join(tmp, "workbook.json")
        with open(contract_path, "w", encoding="utf-8") as handle:
            json.dump(contract, handle)
        subprocess.run(
            [
                sys.executable,
                os.path.join(SCRIPTS, "build_workbook.py"),
                contract_path,
                "--views",
                os.path.join(FIXTURE, "views"),
                "--out",
                output_path,
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        with open(output_path, encoding="utf-8") as handle:
            spec = json.load(handle)

    built = next(element for element in spec["document"]["elements"] if element["name"] == "Channel Summary")
    assert built["filters"][0]["mode"] == "exclude"
    assert built["filters"][0]["values"] == [None]
    assert "NOT NULL" not in json.dumps(built)


if __name__ == "__main__":
    test_expression_table()
    test_offline_predicate_matches_builder_semantics()
    test_builder_never_emits_null_operator_as_literal()
    print("filter normalization: PASS")
