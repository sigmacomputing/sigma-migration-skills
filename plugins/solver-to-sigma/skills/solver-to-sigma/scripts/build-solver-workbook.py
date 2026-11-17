#!/usr/bin/env python3
"""Compiled plan + data-model READBACK -> Sigma workbook document (Phase 4, C6; layout included, C7).

    python3 scripts/build-solver-workbook.py --plan plan.json --dm-readback dm-readback.json \
        --name "<Report>" --folder-id <folder-id> --out wb.json

The readback is GET /v2/dataModels/{id}/spec after the POST (Phase 3, C5): every element and control is wired to
the ids and names Sigma returned, never to client-side ids. One page per report sheet: the title, one control per
Solver parameter on the FIRST page only (bound to the data-model control of the same controlId, so the SQL sees
it; a control id must be unique in a workbook and a control's value applies on every page), the report table in
report order, and one table per expanded row. The layout travels in the same document, so the create is a single
write; any later spec PUT must re-send the read-back layout as its LAST write (a bare PUT wipes it).

Writes the standard envelope {"workbook": {"name","folderId","document"}, "stats", "warnings"}. Stdlib only.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import solver_sql as Q  # noqa: E402

VALUE_FORMAT = {"kind": "number", "formatString": ",.2f"}


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-") or "x"


def readback_index(rb):
    els, ctls = {}, {}
    for p in rb.get("pages", []):
        for e in p.get("elements", []):
            if e.get("kind") == "control":
                ctls[e["controlId"]] = e
            else:
                els[e.get("name")] = e
    dm_id = rb.get("dataModelId") or rb.get("id")
    if not dm_id:
        sys.exit("readback has no dataModelId: pass the GET /v2/dataModels/{id}/spec response")
    return dm_id, els, ctls


def control(c, dm_id, page):
    out = {"id": f"{page}-ctl-{slug(c['controlId'])}", "kind": "control", "controlId": c["controlId"], "name": c["param"],
           "controlType": "number" if c["numeric"] else "text",
           "parameters": [{"kind": "data-model", "dataModelId": dm_id, "controlId": c["controlId"]}]}
    if c["numeric"]:
        out.update({"mode": "=", "includeNulls": "when-no-value-is-selected"})      # mode is required on number controls
    else:
        out.update({"mode": "equals", "case": "insensitive", "includeNulls": "when-no-value-is-selected", "showOperators": False})
    if c["default"] is not None:
        out["value"] = c["default"]
    return out


def build(plan, rb, name, folder_id):
    dm_id, els, ctls = readback_index(rb)
    warnings, pages, elements, layout = [], [], [], ['<?xml version="1.0" encoding="utf-8"?>']
    controls = [c for c in Q.controls(plan)]
    missing = [c["controlId"] for c in controls if c["controlId"] not in ctls]
    if missing:
        sys.exit(f"readback lacks data-model controls {missing}: post the data model from convert-solver.py first")
    n_tables = 0
    for s in plan["sheets"]:
        dm_el = els.get(f"{s['name']} lines")
        details = [(d, els.get(f"{s['name']} detail row {d['row']}")) for d in s["details"]]
        if dm_el is None and not any(e for _, e in details):
            warnings.append(f"{s['name']}: no data-model element in the readback; page skipped")
            continue
        pid = f"page-{slug(s['name'])}"
        first = not pages
        pages.append({"id": pid, "name": s["name"]})
        note = "" if first or not controls else f" Set the parameters on the {pages[0]['name']} page; they apply here too."
        rows = [f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{pid}">']
        title = {"id": f"{pid}-title", "kind": "text",
                 "body": f"# {plan.get('title') or name}\n\n{s['name']} (rebuilt from Solver; see the parity report before use).{note}"}
        elements.append(title)
        rows.append(f'  <Element elementId="{title["id"]}" gridColumn="1 / 25" gridRow="1 / 3"/>')
        r = 3
        for i, c in enumerate(controls if first else []):
            ce = control(c, dm_id, pid)
            elements.append(ce)
            col0 = 1 + (i % 4) * 6
            if i and i % 4 == 0:
                r += 2
            rows.append(f'  <Element elementId="{ce["id"]}" gridColumn="{col0} / {col0 + 6}" gridRow="{r} / {r + 2}"/>')
        r += 2 if first and controls else 0
        if dm_el is not None:
            cname = {c["name"]: c for c in dm_el.get("columns", [])}
            _, display = Q.column_names(s)
            cols = [{"id": f"{pid}-row", "name": "Row", "formula": f"[{dm_el['name']}/Row]", "hidden": True},
                    {"id": f"{pid}-line", "name": "Line", "formula": f"[{dm_el['name']}/Line]"}]
            for c in s["columns"]:
                nm = display[c["letter"]]
                if nm not in cname:
                    warnings.append(f"{s['name']}: column {nm!r} missing from the readback")
                    continue
                cols.append({"id": f"{pid}-c-{c['letter'].lower()}", "name": nm, "formula": f"[{dm_el['name']}/{nm}]",
                             "format": VALUE_FORMAT})
            tid = f"{pid}-report"
            elements.append({"id": tid, "kind": "table", "name": s["name"],
                             "source": {"kind": "data-model", "dataModelId": dm_id, "elementId": dm_el["id"]},
                             "columns": cols, "order": [c["id"] for c in cols],
                             "sort": [{"columnId": f"{pid}-row", "direction": "ascending"}]})
            n_tables += 1
            h = max(8, min(30, len(s["lines"]) + 3))
            rows.append(f'  <Element elementId="{tid}" gridColumn="1 / 25" gridRow="{r} / {r + h}"/>')
            r += h
        for d, de in details:
            if de is None:
                warnings.append(f"{s['name']} row {d['row']}: expanded row not in the readback")
                continue
            cols = [{"id": f"{pid}-d{d['row']}-{slug(c['name'])}", "name": c["name"], "formula": f"[{de['name']}/{c['name']}]"}
                    for c in de.get("columns", [])]
            tid = f"{pid}-detail-{d['row']}"
            elements.append({"id": tid, "kind": "table", "name": f"{d['label']} (row {d['row']})",
                             "source": {"kind": "data-model", "dataModelId": dm_id, "elementId": de["id"]},
                             "columns": cols, "order": [c["id"] for c in cols]})
            n_tables += 1
            rows.append(f'  <Element elementId="{tid}" gridColumn="1 / 25" gridRow="{r} / {r + 10}"/>')
            r += 10
        rows.append("</Page>")
        layout += rows
    if not pages:
        sys.exit("nothing to build: no sheet had a data-model element in the readback")
    doc = {"schemaVersion": 1, "kind": "workbook", "pages": pages, "layout": "\n".join(layout), "elements": elements}
    stats = {"pages": len(pages), "tables": n_tables, "controls": len(controls)}
    return {"workbook": {"name": name, "folderId": folder_id, "document": doc}, "stats": stats, "warnings": warnings}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--dm-readback", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    with open(a.plan) as fh:
        plan = json.load(fh)
    with open(a.dm_readback) as fh:
        rb = json.load(fh)
    env = build(plan, rb, a.name, a.folder_id)
    with open(a.out, "w") as fh:
        json.dump(env, fh, indent=1)
        fh.write("\n")
    print(f"workbook: {env['stats']['pages']} pages, {env['stats']['tables']} tables, "
          f"{len(env['warnings'])} warnings -> {a.out}")


if __name__ == "__main__":
    main()
