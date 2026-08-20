#!/usr/bin/env python3
"""test_compare_coderep.py — compare.py's workbook code-rep `document`
envelope handling (2026-08, task 3.9).

Before this fix: the live `/v2/workbooks/{id}/spec` GET nests pages under a
top-level `document` key, but compare.py read `wbspec.get("pages", [])`
straight off the raw response — always empty on a real workbook, so every
ThoughtSpot visualization silently reported as "(no match)"/"✗" in the HTML
report even when the Sigma element existed.

Offline: monkeypatches ts_lib.export_tml / sigma / ts_png / sigma_png (the
module's only external call sites) and runs the real main() unchanged.

Usage: python3 scripts/test_compare_coderep.py
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "compare.py")

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


def _load_module():
    spec = importlib.util.spec_from_file_location("compare_coderep_ut", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


os.environ.setdefault("SIGMA_BASE_URL", "http://stub.invalid")
os.environ.setdefault("SIGMA_API_TOKEN", "dummy-test-token")
os.environ.setdefault("TS_HOST", "http://ts.invalid")
os.environ.setdefault("TS_TOKEN", "dummy-ts-token")

CMP = _load_module()

LIVEBOARD_TML = """
liveboard:
  visualizations:
    - id: viz1
      viz_guid: guid1
      answer:
        name: Revenue by Region
        chart:
          type: COLUMN
"""

# The LIVE shape: non-metadata fields (pages) nested under `document`.
NESTED_WBSPEC = {
    "workbookId": "wb-test",
    "name": "Test WB",
    "document": {
        "pages": [{"id": "pg1", "name": "Dashboard"}],
        "elements": [
            {"id": "c1", "kind": "bar-chart", "name": "Revenue by Region"},
        ],
        "layout": '<Page id="pg1"><Element elementId="c1"/></Page>',
    },
}

CMP.ts_lib.export_tml = lambda identifier, mtype="LIVEBOARD": (LIVEBOARD_TML, None)
CMP.sigma = lambda method, path, body=None, raw=False: (json.dumps(NESTED_WBSPEC), 200)
CMP.ts_png = lambda lb_id, viz_guid: None
CMP.sigma_png = lambda wb, el: None

printed = []


def _capture_print(*args, **kwargs):
    printed.append(" ".join(str(a) for a in args))


CMP.print = _capture_print

with tempfile.TemporaryDirectory() as d:
    out = os.path.join(d, "compare.html")
    sys.argv = ["compare.py", "--liveboard", "lb1", "--workbook", "wb-test", "--out", out]
    CMP.main()
    report = open(out).read() if os.path.exists(out) else ""

joined = "\n".join(printed)
check("Revenue by Region" in joined, "the per-viz match line was printed")
check("(none)" not in joined,
      f"the element resolves (not '(none)') — nested `document.pages` must be unwrapped (got: {joined!r})")
check("✓" in joined, f"chart-kind matches (COLUMN -> bar-chart) => ✓ (got: {joined!r})")
check("Revenue by Region" in report, "the HTML report contains the matched visualization row")
check("(no match)" not in report, "the HTML report does NOT show '(no match)' for a resolvable element")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
