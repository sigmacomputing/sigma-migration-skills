#!/usr/bin/env python3
"""test_migrate_post_workbook_coderep.py — migrate.py's post_workbook()
workbook code-rep `contents` envelope handling.

Guards: post_workbook() must POST to /v2/workbooks with the workbook nested
under `contents` — the live workbook code-rep surface 400s on a flat body.
The local spec may still carry the on-disk `document` wrapper; it is
converted to `contents` at the API boundary.

Offline: monkeypatches the module's sigma() (the only network call site in
post_workbook) and runs the real function unchanged.

Usage: python3 scripts/test_migrate_post_workbook_coderep.py
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "migrate.py")

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


def _load_module():
    spec = importlib.util.spec_from_file_location("migrate_coderep_ut", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MIG = _load_module()

calls = {"post_body": None}


def fake_sigma(method, path, body=None):
    assert method == "POST" and path == "/v2/workbooks", (method, path)
    calls["post_body"] = body
    return json.dumps({"workbookId": "11111111-1111-4111-8111-111111111111"})


MIG.sigma = fake_sigma

FLAT_SPEC = {
    "name": "Test WB",
    "folderId": "home-1",
    "document": {
        "schemaVersion": 1,
        "kind": "workbook",
        "pages": [{"id": "pg1", "name": "Dashboard"}],
        "elements": [{"id": "c1", "kind": "bar-chart"}],
        "layout": (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            'gridTemplateRows="auto" id="pg1">\n'
            '  <Element elementId="c1" gridColumn="1 / 25" gridRow="1 / 12"/>\n'
            '</Page>\n'
        ),
    },
}

with tempfile.TemporaryDirectory() as wd:
    wb = MIG.post_workbook(FLAT_SPEC, wd)

    check(wb == "11111111-1111-4111-8111-111111111111", f"post_workbook returns the posted workbookId (got {wb!r})")
    posted = calls["post_body"]
    check(posted is not None, "a POST was issued")
    check(isinstance(posted, dict) and isinstance(posted.get("contents"), dict),
          "POST body carries a top-level `contents` key (the wrap the bug omitted)")
    check(posted is not None and "pages" not in posted,
          "POST body has NO top-level `pages` (must be nested, not flat)")
    check(posted is not None and posted["contents"].get("pages") == FLAT_SPEC["document"]["pages"],
          "wrapped contents carries metadata-only pages unchanged")
    check(posted is not None and posted["contents"].get("elements") == FLAT_SPEC["document"]["elements"],
          "wrapped contents carries the flat element collection")
    check(posted is not None and posted["contents"].get("kind") == "workbook"
          and posted["contents"].get("layout"),
          "posted contents includes required kind and authoritative layout")
    check(posted is not None and posted.get("name") == "Test WB",
          "name stays OUTSIDE contents as metadata")
    check(posted is not None and posted.get("folderId") == "home-1",
          "folderId stays OUTSIDE contents as metadata")

    ledger_path = os.path.join(wd, "posted-workbooks.jsonl")
    check(os.path.exists(ledger_path), "posted-workbooks.jsonl written")
    if os.path.exists(ledger_path):
        with open(ledger_path) as f:
            line = json.loads(f.readline())
        check(line == {"id": wb, "name": "Test WB"},
              f"ledger entry unaffected by the wrap (records the original flat spec's name; got {line})")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
