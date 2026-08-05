#!/usr/bin/env python3
"""Live discovery: Looker `GET /looks/{id}` (a saved single-query "Look") -> the
SAME normalized contract as fetch_looker_dashboard.py, but with a SINGLE tile, no
dashboard filters, and no dashboard layout.

A Look's `.query` is structurally identical to a dashboard_element's query, so the
tile normalizes byte-identically via fetch_looker_dashboard.normalize_element() —
the single source of truth for tile normalization.

Adds two Look-only, additive contract features (absent on dashboards, so
build_workbook falls back to its current behavior when they're missing):
  - `fieldMeta`: authoritative dim/measure category per referenced field, pulled
    from the explore metadata API + dynamic_fields hints (build_field_meta). This
    is what lets a Look with ad-hoc/custom measures (or no local LookML checkout)
    classify correctly instead of dropping/misgrouping fields.
  - per-tile `total` / `rowTotal` / `columnLimit` from the Look query.

Auth from ~/.looker/looker.ini (client_credentials, API 4.0).

Usage:
  python3 fetch_looker_look.py <look_id> [out.json]
"""
import json
import sys
import urllib.parse

import fetch_looker_dashboard as fd


def normalize_look(look):
    q = look.get("query") or {}
    # Synthesize a dashboard_element around the Look's query so normalize_element
    # handles it exactly like a dashboard tile. Full-width layout: a lone tile owns
    # the whole page (and avoids build_workbook's auto-flow warning).
    el = {"query": q, "title": look.get("title"), "type": "vis"}
    tile = fd.normalize_element(el, layout={"row": 0, "col": 0, "width": 24, "height": 8})
    elements = [tile] if tile else []
    for t in elements:
        # Look-only fidelity keys — build_workbook reads el.get(...) with a falsy
        # default, so dashboards (which never set these) are unaffected.
        t["total"] = bool(q.get("total"))
        t["rowTotal"] = bool(q.get("row_total"))
        cl = q.get("column_limit")
        t["columnLimit"] = int(cl) if str(cl or "").isdigit() else cl

    contract = {
        "id": str(look.get("id")),
        "title": look.get("title") or ("Look %s" % look.get("id")),
        "layoutMode": "newspaper",
        "source": "api-look",
        "lookmlLinkId": look.get("short_url"),
        "filters": [],
        "elements": elements,
    }
    # Authoritative classification (explore field metadata + dynamic_fields hints).
    # Empty when the API is unreachable -> key omitted -> build_workbook uses the
    # view-.lkml is_measure() path (legacy behavior).
    fm = fd.build_field_meta(elements)
    if fm:
        contract["fieldMeta"] = fm
    return contract


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    lid = sys.argv[1]
    # A single-item GET returns the LookWithQuery (embedded .query). The `fields`
    # selector expands the nested query explicitly in case the default is sparse.
    path = "/looks/%s?fields=%s" % (
        urllib.parse.quote(str(lid), safe=""),
        urllib.parse.quote("id,title,short_url,query"))
    look = fd.get(path)
    if not (look.get("query")):
        # fall back to the plain resource if the fields selector stripped it
        look = fd.get("/looks/%s" % urllib.parse.quote(str(lid), safe=""))
    contract = normalize_look(look)
    out = sys.argv[2] if len(sys.argv) > 2 else None
    txt = json.dumps(contract, indent=2)
    if out:
        with open(out, "w") as f:
            f.write(txt)
        print("wrote %s: %d element(s), fieldMeta=%d field(s), title=%r" % (
            out, len(contract["elements"]), len(contract.get("fieldMeta") or {}),
            contract["title"]))
    else:
        print(txt)


if __name__ == "__main__":
    main()
