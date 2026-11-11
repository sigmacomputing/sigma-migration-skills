#!/usr/bin/env python3
"""test_resolve_ae_winners_coderep.py — resolve_ae_winners.py's workbook
code-rep `contents` envelope handling.

Guards: clean_groups_via_sigma() must POST its throwaway probe workbook to
/v2/workbooks wrapped under `contents` (a flat body is a live 400) and, on the
GET ...?includeContents=true readback, unwrap the top-level `contents` key
(indexing `["pages"][0]["elements"][0]["id"]` off the raw response is always a
KeyError, so the probe's remapped element id would never be recovered).

Offline: monkeypatches api() and export_element() (imported from
verify_parity, the module's only network call sites) and runs the real
clean_groups_via_sigma() unchanged.

Usage: python3 scripts/test_resolve_ae_winners_coderep.py
"""
import importlib.util
import json
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "resolve_ae_winners.py")

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


os.environ["SIGMA_API_TOKEN"] = "dummy-test-token"
os.environ.setdefault("SIGMA_BASE_URL", "http://stub.invalid")
sys.path.insert(0, HERE)  # resolve_ae_winners.py does `import mstr` / `from convert import ...`
                          # / `from verify_parity import ...` as top-level sibling imports


def _load_module():
    spec = importlib.util.spec_from_file_location("resolve_ae_winners_coderep_ut", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


RAW = _load_module()

calls = {"post_body": None, "get_n": 0}

NESTED_PROBE_READBACK = {
    "workbookId": "wb-probe-1",
    "name": "zz-ae-resolver-probe",
    "contents": {
        "schemaVersion": 1,
        "kind": "workbook",
        "pages": [{"id": "p1", "name": "P"}],
        "elements": [{"id": "t1-remapped"}],
        "layout": '<Page id="p1"><Element elementId="t1-remapped"/></Page>',
    },
}


def fake_api(method, path, body=None, raw=False):
    if method == "POST" and path == "/v2/workbooks":
        calls["post_body"] = body
        return 200, json.dumps({"workbookId": "wb-probe-1"})
    if method == "GET" and path == "/v2/workbooks/wb-probe-1?includeContents=true":
        calls["get_n"] += 1
        return 200, json.dumps(NESTED_PROBE_READBACK)
    if method == "DELETE":
        return 200, ""
    raise AssertionError(f"unexpected call: {method} {path}")


def fake_export_element(workbook_id, element_id):
    assert workbook_id == "wb-probe-1" and element_id == "t1-remapped", (workbook_id, element_id)
    return "key,val\r\nA,1\r\n"


RAW.api = fake_api
RAW.export_element = fake_export_element

args = types.SimpleNamespace(database="DEMO_DB", connection_id="conn-1", folder_id="home-1")


class FakeBundle:
    def build_clean_group_sql(self, database, report):
        return "SELECT 1 AS val"

    def clean_group_aliases(self, report):
        return ["val"]


rows = RAW.clean_groups_via_sigma(FakeBundle(), args, {"id": "r1"}, "quirk-aid", ["p1"])

check(rows == [{"key": "A", "val": "1"}], f"clean_groups_via_sigma returns the exported rows (got {rows})")
post_body = calls["post_body"]
check(post_body is not None, "a POST was issued")
check(isinstance(post_body, dict) and isinstance(post_body.get("contents"), dict),
      "POST body carries a top-level `contents` key (the wrap the bug omitted)")
check(post_body is not None and "pages" not in post_body,
      "POST body has NO top-level `pages` (must be nested, not flat)")
check(post_body is not None and isinstance(post_body["contents"].get("pages"), list),
      "wrapped contents carries the probe's page")
check(post_body is not None and post_body["contents"]["pages"] == [{"id": "p1", "name": "P"}],
      "probe pages are metadata-only")
check(post_body is not None and post_body["contents"].get("elements", [{}])[0].get("id") == "t1",
      "probe workbook elements are flat under contents.elements")
probe_layout = post_body["contents"].get("layout", "") if post_body is not None else ""
check('<Element elementId="t1"' in probe_layout,
      "probe carries required authoritative layout with the canonical Element tag")
check("<LayoutElement" not in probe_layout and "<GridContainer" not in probe_layout,
      "probe layout does not emit rejected legacy tags")
check(post_body is not None and post_body.get("name") == "zz-ae-resolver-probe",
      "name stays OUTSIDE contents as metadata")
check(calls["get_n"] == 1,
      f"exactly one readback GET issued to recover the remapped element id (got {calls['get_n']})")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
