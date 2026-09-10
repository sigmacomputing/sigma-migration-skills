#!/usr/bin/env python3
"""Offline LookML-parameter → workbook-local control regression."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIXTURE = os.path.join(SKILL, "fixtures", "skilltest-orders-dynamic")
CONVERTER = os.path.join(SKILL, "converter", "lookml.mjs")


def convert(tmp):
    files = []
    for root, _, names in os.walk(FIXTURE):
        for name in sorted(names):
            if name.endswith(".lkml"):
                path = os.path.join(root, name)
                files.append({"name": name, "content": open(path, encoding="utf-8").read()})
    files_path = os.path.join(tmp, "files.json")
    result_path = os.path.join(tmp, "converted.json")
    runner_path = os.path.join(tmp, "convert.mjs")
    json.dump(files, open(files_path, "w", encoding="utf-8"))
    open(runner_path, "w", encoding="utf-8").write(
        "import fs from 'node:fs';\n"
        f"import {{ convertLookMLToSigma }} from {json.dumps(pathlib.Path(CONVERTER).resolve().as_uri())};\n"
        f"const files = JSON.parse(fs.readFileSync({json.dumps(files_path)}, 'utf8'));\n"
        "const result = convertLookMLToSigma(files, {exploreName:'order_fact', "
        "connectionId:'fixture', joinStrategy:'relationships'});\n"
        f"fs.writeFileSync({json.dumps(result_path)}, JSON.stringify(result, null, 2));\n"
    )
    subprocess.run(["node", runner_path], check=True, capture_output=True, text=True)
    return json.load(open(result_path, encoding="utf-8"))


def build(tmp, metadata):
    contract_path = os.path.join(tmp, "contract.json")
    workbook_path = os.path.join(tmp, "workbook.json")
    metadata_path = os.path.join(tmp, "dynamic-parameters.json")
    parsed = subprocess.run(
        [
            sys.executable,
            os.path.join(SCRIPTS, "parse_lookml_dashboard.py"),
            os.path.join(FIXTURE, "skilltest_orders.dashboard.lookml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    open(contract_path, "w", encoding="utf-8").write(parsed.stdout)
    json.dump({"version": 1, "parameters": metadata}, open(metadata_path, "w", encoding="utf-8"))
    run = subprocess.run(
        [
            sys.executable,
            os.path.join(SCRIPTS, "build_workbook.py"),
            contract_path,
            "--views",
            os.path.join(FIXTURE, "views"),
            "--dynamic-parameters",
            metadata_path,
            "--out",
            workbook_path,
        ],
        capture_output=True,
        text=True,
    )
    return run, workbook_path


def test_dynamic_parameters_are_structured_and_workbook_local():
    with tempfile.TemporaryDirectory() as tmp:
        converted = convert(tmp)
        params = converted.get("dynamicParameters") or []
        assert {param["name"] for param in params} == {"metric_basis", "revenue_column"}, params
        assert all(param["allowedValues"] for param in params)
        assert all(
            field["deterministic"]
            for param in params
            for field in param["affectedFields"]
        )

        run, workbook_path = build(tmp, params)
        assert run.returncode == 0, run.stdout + run.stderr
        workbook = json.load(open(workbook_path, encoding="utf-8"))
        controls = [
            element for element in workbook["document"]["elements"]
            if element.get("kind") == "control" and element.get("controlType") == "segmented"
        ]
        assert {control["controlId"] for control in controls} == {
            "looker-param-order-fact-metric-basis",
            "looker-param-order-fact-revenue-column",
        }
        assert all("parameters" not in control for control in controls)
        serialized = json.dumps(workbook)
        assert "[looker-param-order-fact-metric-basis]" in serialized
        assert "[looker-param-order-fact-revenue-column]" in serialized

        dynamic = json.load(open(os.path.join(tmp, "dynamic-controls.json"), encoding="utf-8"))
        assert all(row["status"] == "emitted" for row in dynamic["parameters"])
        scope = json.load(open(os.path.join(tmp, "control-scope.json"), encoding="utf-8"))
        formula_controls = [row for row in scope["controls"] if row.get("mechanism") == "formula"]
        assert len(formula_controls) == 2
        assert all(row["mustReach"] for row in formula_controls)


def test_unresolved_parameter_fails_closed():
    with tempfile.TemporaryDirectory() as tmp:
        converted = convert(tmp)
        params = converted["dynamicParameters"]
        params[0]["affectedFields"][0]["deterministic"] = False
        run, _ = build(tmp, params)
        assert run.returncode != 0
        assert "dynamic-parameter gate" in run.stderr + run.stdout


if __name__ == "__main__":
    test_dynamic_parameters_are_structured_and_workbook_local()
    test_unresolved_parameter_fails_closed()
    print("dynamic parameters: PASS")
