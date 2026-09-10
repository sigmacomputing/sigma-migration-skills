#!/usr/bin/env python3
"""Offline contract tests for scan_gaps.py structured reports."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIXTURES = os.path.join(SKILL, "fixtures")
SCAN = os.path.join(SCRIPTS, "scan_gaps.py")
DASHBOARDS = os.path.join(FIXTURES, "dashboards.json")
MODEL = os.path.join(FIXTURES, "model_ecommerce.json")

passed = failed = 0


def ok(label, condition, extra=""):
    global passed, failed
    passed += int(bool(condition))
    failed += int(not condition)
    print(("  ok  " if condition else "  FAIL ") + label +
          (("  " + extra) if extra and not condition else ""))


def run_scan(directory, dashboards=DASHBOARDS, model=MODEL, strict=False):
    out = os.path.join(directory, "gap-report.json")
    rules = os.path.join(directory, "learned-rules.json")
    command = [
        sys.executable, SCAN, dashboards, "--out", out, "--rules", rules,
    ]
    if model:
        command.extend(["--model", model])
    if strict:
        command.append("--strict")
    result = subprocess.run(command, capture_output=True, text=True)
    report = json.load(open(out, encoding="utf-8")) if os.path.exists(out) else None
    return result, report, out, rules


with tempfile.TemporaryDirectory() as td:
    first, report, first_path, rules = run_scan(td)
    first_bytes = open(first_path, "rb").read()
    second, report_again, second_path, _ = run_scan(td)
    second_bytes = open(second_path, "rb").read()

    ok("structured scan exits zero in report mode", first.returncode == 0,
       first.stdout + first.stderr)
    ok("schema and required top-level sections are present",
       report["schema_version"] == 1 and
       set(report) == {"schema_version", "source", "summary", "objects", "gaps"})
    ok("complete source object census is 56 objects",
       report["summary"]["objects"] == 56, str(report["summary"]))
    ok("complete counts include all model object types",
       report["summary"]["by_type"] == {
           "dashboard": 2,
           "filter": 6,
           "model-column": 17,
           "model-relation": 3,
           "model-table": 4,
           "widget": 24,
       }, str(report["summary"]["by_type"]))

    source = json.load(open(DASHBOARDS, encoding="utf-8"))
    expected_widget_pointers = {
        "/%d/widgets/%d" % (di, wi)
        for di, dashboard in enumerate(source)
        for wi, _widget in enumerate(dashboard.get("widgets") or [])
    }
    expected_filter_pointers = {
        "/%d/filters/%d" % (di, fi)
        for di, dashboard in enumerate(source)
        for fi, _filter in enumerate(dashboard.get("filters") or [])
    }
    expected_filter_pointers.update(
        "/%d/widgets/%d/metadata/panels/%d/items/%d/jaql/filter" %
        (di, wi, pi, ii)
        for di, dashboard in enumerate(source)
        for wi, widget in enumerate(dashboard.get("widgets") or [])
        for pi, panel in enumerate((widget.get("metadata") or {}).get("panels") or [])
        for ii, item in enumerate(panel.get("items") or [])
        if "filter" in (item.get("jaql") or {})
    )
    expected_filter_pointers.update(
        "/%d/widgets/%d/filters/%d" % (di, wi, fi)
        for di, dashboard in enumerate(source)
        for wi, widget in enumerate(dashboard.get("widgets") or [])
        for fi, _filter in enumerate(widget.get("filters") or [])
    )
    got_widget_pointers = {
        obj["source"]["json_pointer"]
        for obj in report["objects"] if obj["type"] == "widget"
    }
    got_filter_pointers = {
        obj["source"]["json_pointer"]
        for obj in report["objects"] if obj["type"] == "filter"
    }
    ok("no source widget is omitted", got_widget_pointers == expected_widget_pointers)
    ok("no source filter is omitted", got_filter_pointers == expected_filter_pointers)

    source_model = json.load(open(MODEL, encoding="utf-8"))
    expected_model_pointers = set()
    for dataset_index, dataset in enumerate(source_model["datasets"]):
        for table_index, table in enumerate(dataset["schema"]["tables"]):
            table_pointer = "/datasets/%d/schema/tables/%d" % (
                dataset_index, table_index
            )
            expected_model_pointers.add(table_pointer)
            expected_model_pointers.update(
                "%s/columns/%d" % (table_pointer, column_index)
                for column_index, _column in enumerate(table["columns"])
            )
    expected_model_pointers.update(
        "/relations/%d" % relation_index
        for relation_index, _relation in enumerate(source_model["relations"])
    )
    got_model_pointers = {
        obj["source"]["json_pointer"]
        for obj in report["objects"] if obj["type"].startswith("model-")
    }
    ok("no source model table, column, or relation is omitted",
       got_model_pointers == expected_model_pointers,
       "missing=%r extra=%r" % (
           sorted(expected_model_pointers - got_model_pointers),
           sorted(got_model_pointers - expected_model_pointers),
       ))
    ok("every object has stable contract fields and provenance",
       all(
           set(obj) == {"type", "id", "name", "status", "evidence", "source"} and
           obj["id"] and obj["name"] and obj["evidence"] and
           obj["status"] in {
               "auto", "hint", "manual", "unhandled", "not-applicable"
           } and obj["source"].get("artifact") and
           "json_pointer" in obj["source"]
           for obj in report["objects"]
       ))
    ok("structured JSON is byte-deterministic", first_bytes == second_bytes)
    ok("learned-rules append remains idempotent",
       len(json.load(open(rules, encoding="utf-8"))) == 2)
    ok("human coverage stdout remains available",
       "Sisense->Sigma coverage" in second.stdout and "AUTO:" in second.stdout)

with tempfile.TemporaryDirectory() as td:
    strict_result, strict_report, _out, _rules = run_scan(td, strict=True)
    ok("--strict fails unresolved manual/flagged gaps",
       strict_result.returncode != 0 and "RED:" in strict_result.stderr,
       strict_result.stdout + strict_result.stderr)
    ok("strict report names manual and flagged categories",
       strict_report["summary"]["gap_categories"]["manual"] == 2 and
       strict_report["summary"]["gap_categories"]["flagged"] == 1)

with tempfile.TemporaryDirectory() as td:
    transformed_model = json.load(open(MODEL, encoding="utf-8"))
    transformed_model["modelingTransformations"] = [
        {"id": "model-transform", "name": "Model transform"}
    ]
    transformed_model["datasets"][0]["modelingTransformations"] = [
        {"id": "dataset-transform", "name": "Dataset transform"}
    ]
    transformed_model_path = os.path.join(td, "model.json")
    json.dump(transformed_model, open(transformed_model_path, "w", encoding="utf-8"))
    transformed_result, transformed_report, _out, _rules = run_scan(
        td, model=transformed_model_path
    )
    transformations = [
        obj for obj in transformed_report["objects"]
        if obj["type"] == "model-transformation"
    ]
    ok("every model and dataset transformation is accounted",
       transformed_result.returncode == 0 and
       {obj["id"] for obj in transformations} ==
       {"model-transform", "dataset-transform"})
    ok("transformations are unresolved strict-gate objects",
       all(obj["status"] == "unhandled" for obj in transformations) and
       transformed_report["summary"]["gap_categories"]["unhandled"] == 2)
    transformed_strict, _strict_report, _out, _rules = run_scan(
        td, model=transformed_model_path, strict=True
    )
    ok("--strict also fails unresolved unhandled model objects",
       transformed_strict.returncode != 0 and "RED:" in transformed_strict.stderr)

with tempfile.TemporaryDirectory() as td:
    clean_dashboards = os.path.join(td, "dashboards.json")
    json.dump([{
        "_id": "clean-dashboard",
        "title": "Clean",
        "filters": [],
        "widgets": [{
            "_id": "clean-widget",
            "oid": "clean-widget-layout",
            "title": "Revenue",
            "type": "indicator",
            "metadata": {"panels": [{
                "name": "value",
                "items": [{"jaql": {
                    "dim": "[Commerce.Revenue]",
                    "agg": "sum",
                    "title": "Revenue",
                }}],
            }]},
        }],
    }], open(clean_dashboards, "w", encoding="utf-8"), indent=2)
    clean_result, clean_report, _out, _rules = run_scan(
        td, dashboards=clean_dashboards, model=None, strict=True
    )
    ok("--strict passes a fully automatic dashboard",
       clean_result.returncode == 0 and clean_report["gaps"] == [],
       clean_result.stdout + clean_result.stderr)

print("\n%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
