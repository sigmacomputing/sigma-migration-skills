#!/usr/bin/env python3
"""test_verify_parity_coderep.py — verify_parity.py's workbook code-rep
`document` envelope handling (2026-08, task 3.9).

Before this fix: the report-name -> element-id map built from the workbook
spec readback read `spec["pages"]` straight off the raw response — the live
workbook code-rep surface nests pages under a top-level `document` key, so
this was always a KeyError, and every parity run died before comparing a
single row ("no workbook element named ...").

Offline: monkeypatches api() and export_element() (the module's only network
call sites) and runs the real main() unchanged.

Usage: python3 scripts/test_verify_parity_coderep.py
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "verify_parity.py")

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


os.environ["SIGMA_API_TOKEN"] = "dummy-test-token"
os.environ.setdefault("SIGMA_BASE_URL", "http://stub.invalid")


def _load_module():
    spec = importlib.util.spec_from_file_location("verify_parity_coderep_ut", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


VP = _load_module()

# The LIVE shape: non-metadata fields (pages) nested under `document`.
NESTED_SPEC = {
    "workbookId": "wb-test",
    "name": "Test WB",
    "document": {
        "schemaVersion": 3,
        "kind": "workbook",
        "pages": [{"id": "pg1", "name": "Overview"}],
        "elements": [
            {"id": "e1", "name": "Revenue Report", "kind": "table"},
        ],
        "layout": '<Page id="pg1"><Element elementId="e1"/></Page>',
    },
}

get_calls = {"n": 0}


def fake_api(method, path, body=None, raw=False):
    assert method == "GET" and path == "/v2/workbooks/wb-test/spec", (method, path)
    get_calls["n"] += 1
    return 200, json.dumps(NESTED_SPEC)


def fake_export_element(workbook_id, element_id):
    assert workbook_id == "wb-test" and element_id == "e1", (workbook_id, element_id)
    return "Year,Net Revenue\r\n2024,100\r\n"


VP.api = fake_api
VP.export_element = fake_export_element

with tempfile.TemporaryDirectory() as d:
    expected_path = os.path.join(d, "expected_parity.json")
    json.dump({"Revenue Report": [{"keys": ["2024"], "values": {"Net Revenue": 100}}]},
              open(expected_path, "w"))
    report_path = os.path.join(d, "parity_report.md")
    csv_dir = os.path.join(d, "exports")

    sys.argv = ["verify_parity.py", "--workbook-id", "wb-test",
                "--expected", expected_path, "--report", report_path,
                "--save-csv-dir", csv_dir]
    cwd = os.getcwd()
    os.chdir(d)
    try:
        code = None
        try:
            VP.main()
        except SystemExit as e:
            code = e.code
    finally:
        os.chdir(cwd)

    check(code in (0, None),
          f"main() exits 0 / all_green (got exit code {code!r} — a nested-`document` "
          "regression instead raises 'no workbook element named ...')")
    check(get_calls["n"] == 1, f"exactly one spec GET issued (got {get_calls['n']})")
    report = open(report_path).read() if os.path.exists(report_path) else ""
    check("Revenue Report" in report, "the parity report resolves + names the report")
    check("PASS" in report, f"the report row is PASS (values matched; report: {report!r})")
    final_path = os.path.join(d, "parity-final.json")
    check(os.path.exists(final_path), "parity-final.json gate sentinel written")
    if os.path.exists(final_path):
        final = json.load(open(final_path))
        check(final.get("charts_pass") == 1, f"parity-final.json reports 1 chart passed (got {final})")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
