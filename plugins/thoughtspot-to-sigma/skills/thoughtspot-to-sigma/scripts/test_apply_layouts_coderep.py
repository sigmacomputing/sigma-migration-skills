#!/usr/bin/env python3
"""test_apply_layouts_coderep.py — apply_layouts.py's workbook code-rep
`contents` envelope handling (GET /v2/workbooks/{id}?includeContents=true,
PUT /v2/workbooks/{id}/contents).

Guards: apply()'s GET must unwrap the nested `contents` response (read flat,
spec["pages"] is silently empty on a real workbook and the layout synthesis has
nothing to lay out); the PUT must send the working spec wrapped as
{contents: ...} — a flat body is a live 400.

Offline: monkeypatches the module's req() (the only network call site) and
runs the real apply()/build_layout() code unchanged.

Usage: python3 scripts/test_apply_layouts_coderep.py
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "apply_layouts.py")

FAILS = []


def check(cond, msg):
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")
    if not cond:
        FAILS.append(msg)


def _load_module():
    spec = importlib.util.spec_from_file_location("apply_layouts_coderep_ut", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


AL = _load_module()

# The LIVE shape: metadata-only pages, flat elements, required authoritative layout.
NESTED_DOC = {
    "workbookId": "wb-test",
    "name": "Test WB",
    "contents": {
        "schemaVersion": 1,
        "kind": "workbook",
        "pages": [
            {"id": "data1", "name": "Data", "visibility": "hidden"},
            {"id": "pg1", "name": "Dashboard"},
        ],
        "elements": [
            {"id": "d1", "kind": "table", "name": "OFV"},
            {"id": "c1", "kind": "bar-chart", "name": "Chart"},
        ],
        "panels": [{"id": "filters-panel", "type": "sidebar", "name": "Filters"}],
        "overlays": [{"id": "detail-modal", "type": "modal", "name": "Detail"}],
        "settings": {"navigation": {"position": "side"}},
        "agents": [{"id": "agent-1"}],
        "layout": (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="data1">\n'
            '  <Element elementId="d1" gridColumn="1 / 25" gridRow="1 / 21"/>\n'
            '</Page>\n'
            '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg1">\n'
            '  <Element elementId="c1" gridColumn="1 / 25" gridRow="1 / 12"/>\n'
            '</Page>\n'
        ),
    },
}

calls = {"get": 0, "put_body": None}


def fake_req(method, path, body=None):
    if method == "GET":
        assert path == "/v2/workbooks/wb-test?includeContents=true", path
        calls["get"] += 1
        # 1st GET (apply()'s pre-layout read): the live nested readback.
        payload = NESTED_DOC if calls["get"] == 1 else calls["put_body"]
        return json.dumps(payload)
    if method == "PUT":
        assert path == "/v2/workbooks/wb-test/contents", path
        calls["put_body"] = json.loads(body)
        return json.dumps({"workbookId": "wb-test"})
    raise AssertionError(f"unexpected method {method}")


AL.req = fake_req

ok = AL.apply("wb-test")

check(ok is True, f"apply() reports success (got {ok!r})")
put_body = calls["put_body"]
check(put_body is not None, "a PUT was issued")
check(isinstance(put_body, dict) and isinstance(put_body.get("contents"), dict),
      "PUT body carries a top-level `contents` key (the wrap the bug would omit)")
check(put_body is not None and "pages" not in put_body,
      "PUT body has NO top-level `pages` (must be nested, not flat)")
check(put_body is not None and isinstance(put_body["contents"].get("pages"), list)
      and len(put_body["contents"]["pages"]) == 2,
      "wrapped contents carries both pages (Data + Dashboard)")
check(all("elements" not in p for p in put_body["contents"]["pages"]),
      "pages are metadata-only")
check({e["id"] for e in put_body["contents"]["elements"]}.issuperset({"d1", "c1"}),
      "PUT retains the flat workbook element collection")
check(put_body is not None and isinstance(put_body["contents"].get("layout"), str)
      and "<Container" in put_body["contents"]["layout"]
      and "<Element" in put_body["contents"]["layout"],
      "wrapped contents carries canonical live layout XML")
check(set(("panels", "overlays", "settings", "agents")).issubset(put_body["contents"]),
      "full-document PUT preserves panels, overlays, settings, and agents")
check(set(put_body) == {"contents"},
      "PUT sends exactly the contents envelope (no response/create metadata)")
placed = AL._layout_element_ids(put_body["contents"]["layout"])
declared = [e["id"] for e in put_body["contents"]["elements"]]
check(sorted(placed) == sorted(declared) and len(placed) == len(set(placed)),
      "layout places every flat element exactly once")
check(calls["get"] == 1, f"exactly one GET issued by apply() itself (got {calls['get']})")

print()
if FAILS:
    print(f"{len(FAILS)} FAILURE(S):")
    for f in FAILS:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
