#!/usr/bin/env python3
"""End-to-end offline regression modeled on customer dashboard 7405."""

import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIXTURE = os.path.join(SKILL, "fixtures", "skilltest-course-performance")
CONVERTER = os.path.join(SKILL, "converter", "lookml.mjs")


def converter_result(tmp):
    files = []
    for root, _, names in os.walk(FIXTURE):
        for name in sorted(names):
            if name.endswith(".lkml"):
                path = os.path.join(root, name)
                files.append({"name": name, "content": open(path, encoding="utf-8").read()})
    source = os.path.join(tmp, "files.json")
    result = os.path.join(tmp, "result.json")
    runner = os.path.join(tmp, "runner.mjs")
    json.dump(files, open(source, "w", encoding="utf-8"))
    open(runner, "w", encoding="utf-8").write(
        "import fs from 'node:fs';\n"
        f"import {{ convertLookMLToSigma }} from {json.dumps(pathlib.Path(CONVERTER).resolve().as_uri())};\n"
        f"const files=JSON.parse(fs.readFileSync({json.dumps(source)},'utf8'));\n"
        "const value=convertLookMLToSigma(files,{exploreName:'enrollment_metrics',"
        "connectionId:'fixture',joinStrategy:'relationships'});\n"
        f"fs.writeFileSync({json.dumps(result)},JSON.stringify(value,null,2));\n"
    )
    subprocess.run(["node", runner], check=True, capture_output=True, text=True)
    return json.load(open(result, encoding="utf-8"))


def build_workbook(tmp, converted):
    contract = os.path.join(tmp, "contract.json")
    workbook = os.path.join(tmp, "wb-spec.json")
    dm = os.path.join(tmp, "dm-spec.json")
    dynamic = os.path.join(tmp, "dm-spec-dynamic-parameters.json")
    force_prebuilt = os.environ.get("LOOKER_TEST_FORCE_PREBUILT_CONTRACT") == "1"
    parsed = None if force_prebuilt else subprocess.run(
        [
            sys.executable,
            os.path.join(SCRIPTS, "parse_lookml_dashboard.py"),
            os.path.join(FIXTURE, "course_performance.dashboard.lookml"),
        ],
        capture_output=True,
        text=True,
    )
    if parsed is not None and parsed.returncode == 0:
        open(contract, "w", encoding="utf-8").write(parsed.stdout)
    elif force_prebuilt or "PyYAML required" in parsed.stderr + parsed.stdout:
        # The Windows corpus smoke intentionally installs no Python packages.
        # Linux unit CI still exercises the real parser with PyYAML; Windows
        # continues through converter/builder/hazard/oracle using the committed
        # normalized contract golden instead of skipping the case.
        repo = os.path.abspath(os.path.join(SKILL, "..", "..", "..", ".."))
        golden = os.path.join(
            repo, "corpus", "looker", "skilltest-course-performance",
            "golden", "contract.json",
        )
        value = json.load(open(golden, encoding="utf-8"))["workbook"]
        json.dump(value, open(contract, "w", encoding="utf-8"))
    else:
        raise AssertionError(parsed.stdout + parsed.stderr)
    json.dump(converted["model"], open(dm, "w", encoding="utf-8"))
    json.dump(
        {"version": 1, "parameters": converted["dynamicParameters"]},
        open(dynamic, "w", encoding="utf-8"),
    )
    built = subprocess.run(
        [
            sys.executable,
            os.path.join(SCRIPTS, "build_workbook.py"),
            contract,
            "--views",
            os.path.join(FIXTURE, "views"),
            "--dynamic-parameters",
            dynamic,
            "--out",
            workbook,
        ],
        capture_output=True,
        text=True,
    )
    assert built.returncode == 0, built.stdout + built.stderr
    return contract, dm, workbook


def test_full_fixture_pipeline_and_hazard_gate():
    with tempfile.TemporaryDirectory() as tmp:
        converted = converter_result(tmp)
        params = converted.get("dynamicParameters") or []
        assert {param["name"] for param in params} == {
            "funnel_metric",
            "group_by",
            "time_grain",
        }
        assert all(
            field["deterministic"]
            for param in params
            for field in param["affectedFields"]
        )
        contract, dm, workbook = build_workbook(tmp, converted)
        spec = json.load(open(workbook, encoding="utf-8"))
        controls = [
            element for element in spec["document"]["elements"]
            if element.get("controlType") == "segmented"
        ]
        assert len(controls) == 3
        assert all("parameters" not in control for control in controls)
        assert "[looker-param-enrollment-metrics-funnel-metric]" in json.dumps(spec)

        title = next(
            element for element in spec["document"]["elements"]
            if element.get("name") == "Title Level"
        )
        assert title["filters"][0]["mode"] == "exclude"
        assert title["filters"][0]["values"] == [None]

        hazard = subprocess.run(
            [
                sys.executable,
                os.path.join(SCRIPTS, "detect_modeling_hazards.py"),
                "--workdir",
                tmp,
                "--contract",
                contract,
                "--dm-spec",
                dm,
                "--wb-spec",
                workbook,
            ],
            capture_output=True,
            text=True,
        )
        assert hazard.returncode == 2, hazard.stdout + hazard.stderr
        ledger = json.load(open(os.path.join(tmp, "modeling-hazards.json"), encoding="utf-8"))
        hazards = {entry["hazard"] for entry in ledger["entries"]}
        assert "preaggregated-relationship" in hazards
        assert "unsafe-window-grain" in hazards


def test_sqlite_window_oracle():
    rows = json.load(open(os.path.join(FIXTURE, "warehouse_rows.json"), encoding="utf-8"))
    expected = json.load(open(os.path.join(FIXTURE, "oracle_expected.json"), encoding="utf-8"))
    db = sqlite3.connect(":memory:")
    db.execute(
        "CREATE TABLE funnel(period_date TEXT, content_domain TEXT, country_group TEXT, "
        "enrollments INTEGER, module_1_completions INTEGER, course_completions INTEGER, "
        "freemium_conversions INTEGER, active_days_30 REAL, overall_revenue_rank INTEGER)"
    )
    db.executemany(
        "INSERT INTO funnel VALUES(:period_date,:content_domain,:country_group,:enrollments,"
        ":module_1_completions,:course_completions,:freemium_conversions,:active_days_30,"
        ":overall_revenue_rank)",
        rows,
    )
    actual = [
        {
            "content_domain": row[0],
            "period_date": row[1],
            "enrollments": row[2],
            "prior_enrollments": row[3],
            "rolling_enrollments": round(row[4], 10),
            "module_1_rate": round(row[5], 10),
        }
        for row in db.execute(
            "SELECT content_domain, period_date, enrollments, "
            "LAG(enrollments) OVER (PARTITION BY content_domain ORDER BY period_date), "
            "AVG(enrollments) OVER (PARTITION BY content_domain ORDER BY period_date "
            "ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), "
            "1.0 * module_1_completions / NULLIF(enrollments, 0) "
            "FROM funnel ORDER BY content_domain, period_date"
        )
    ]
    assert actual == expected


if __name__ == "__main__":
    test_full_fixture_pipeline_and_hazard_gate()
    test_sqlite_window_oracle()
    print("course performance fixture: PASS")
