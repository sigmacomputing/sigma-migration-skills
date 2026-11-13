#!/usr/bin/env python3
"""Solver report definition + source map -> Sigma data-model spec (Phase 2, C4).

    python3 scripts/convert-solver.py --definition <download.xlsx|definition.xml> --source-map source-map.json \
        --name "<Report> - Data" --folder-id <folder-id> --out dm.json --plan-out plan.json [--sheet <name> ...]

Writes the standard converter envelope {"sigmaDataModel": spec, "stats": {...}, "warnings": [...]} and the compiled
plan (lines, bases, details, parameters) that the workbook builder, the local evaluator and the parity check read.

One SQL element per sheet (one row per report line, one column per report column), one per expanded row, and one
data-model control per Solver parameter the SQL reads. Exit 2 lists EVERY unmapped fact/attribute at once; fix the
source map and rerun. Never invents a mapping. Stdlib only.
"""
import argparse
import json
import re
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import solver_compile as C  # noqa: E402
import solver_def  # noqa: E402
import solver_sql as Q  # noqa: E402


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-") or "x"


def col(cid, name, alias):
    return {"id": cid, "name": name, "formula": f"[Custom SQL/{alias}]"}


def dm_control(c):
    base = {"id": f"ctl-{slug(c['controlId'])}", "kind": "control", "controlId": c["controlId"], "name": c["param"]}
    if c["numeric"]:
        base.update({"controlType": "number", "mode": "=", "includeNulls": "when-no-value-is-selected"})
    else:
        base.update({"controlType": "text", "mode": "equals", "case": "insensitive",
                     "includeNulls": "when-no-value-is-selected", "showOperators": False})
    if c["default"] is not None:
        base["value"] = c["default"]
    return base


def build(plan, source_map, name, folder_id, connection_id=None):
    conn = connection_id or source_map.get("connectionId") or "<connection-id>"
    r = Q.Renderer(plan, source_map)
    elements, problems, warnings = [], [], list(plan["warnings"])
    for s in plan["sheets"]:
        alias, display = Q.column_names(s)
        if s["lines"]:
            try:
                sql = r.sheet_sql(s, alias)
                cols = [col(f"{slug(s['name'])}-row", "Row", "ROW_NUM"), col(f"{slug(s['name'])}-line", "Line", "LINE")]
                cols += [col(f"{slug(s['name'])}-{c['letter'].lower()}", display[c["letter"]], alias[c["letter"]]) for c in s["columns"]]
                elements.append({"id": f"sql-{slug(s['name'])}", "kind": "table", "name": f"{s['name']} lines",
                                 "source": {"kind": "sql", "connectionId": conn, "statement": sql},
                                 "columns": cols, "order": [c["id"] for c in cols]})
            except (Q.MappingError, C.Unsupported) as e:
                problems.append(f"{s['name']}: {e}")
        for d in s["details"]:
            if "gap" in d:
                continue                                   # listed in warnings and counted in gap_cells
            try:
                sql = r.detail_sql(d)
                cols = []
                for letter, cell in sorted(d["cells"].items()):
                    if "gap" in cell:
                        continue
                    label = (d.get("labels") or {}).get(letter) or letter
                    cols.append(col(f"{slug(s['name'])}-d{d['row']}-{letter.lower()}", label, f"C_{letter}"))
                elements.append({"id": f"sql-{slug(s['name'])}-d{d['row']}", "kind": "table",
                                 "name": f"{s['name']} detail row {d['row']}",
                                 "source": {"kind": "sql", "connectionId": conn, "statement": sql},
                                 "columns": cols, "order": [c["id"] for c in cols]})
            except (Q.MappingError, C.Unsupported) as e:
                problems.append(f"{s['name']} row {d['row']}: {e}")
    controls = [dm_control(c) for c in Q.controls(plan)]
    spec = {"name": name, "folderId": folder_id, "schemaVersion": 1,
            "pages": [{"id": "page-1", "name": "Solver report", "elements": elements + controls}]}
    gaps = C.gap_count(plan)
    stats = {"sheets": len(plan["sheets"]), "elements": len(elements), "lines": sum(len(s["lines"]) for s in plan["sheets"]),
             "bases": sum(len(s["bases"]) for s in plan["sheets"]), "details": sum(len(s["details"]) for s in plan["sheets"]),
             "controls": len(controls), "gap_cells": gaps, "text_cells": sum(s.get("text_cells", 0) for s in plan["sheets"])}
    return {"sigmaDataModel": spec, "stats": stats, "warnings": warnings}, problems


def signature(plan, source_map):
    """Input for scripts/find-or-pick-dm.rb (Phase 1.5): the warehouse tables and columns this report reads."""
    tables, cols, measures = set(), set(), []
    for f in (source_map.get("facts") or {}).values():
        tables |= set(re.findall(r"\b[A-Za-z0-9_$]+\.[A-Za-z0-9_$]+\.[A-Za-z0-9_$]+\b", f.get("from", "")))
        for v in (f.get("values") or {}).values():
            c = v.split(".")[-1].strip('"')
            cols.add(c)
            measures.append({"col": c, "derivation": "Sum"})
        if (f.get("period") or {}).get("expr"):
            cols.add(f["period"]["expr"].split(".")[-1].strip('"'))
    used = set()
    for s in plan["sheets"]:
        for b in list(s["bases"].values()) + [b for d in s["details"] for b in d["bases"].values()]:
            for g in b["groups"].values():
                _fields(g, used)
        for d in s["details"]:
            used |= {f"{a}.{b}" for a, b in d["group_by"]}
    attrs = dict(source_map.get("attributes") or {})
    for per in (source_map.get("fact_attributes") or {}).values():
        attrs.update(per)
    cols |= {attrs[k].split(".")[-1].strip('"') for k in used if k in attrs}
    return {"tableau_workbook": plan.get("title"), "warehouse_tables": sorted(tables),
            "referenced_columns": sorted(cols), "measures": measures}


def _fields(p, acc):
    if not isinstance(p, dict):
        return
    if p.get("k") in ("and", "or"):
        for x in p["xs"]:
            _fields(x, acc)
    elif p.get("k") == "not":
        _fields(p["x"], acc)
    elif p.get("dim") and p.get("k") in ("in", "contains"):
        acc.add(f"{p['dim']}.{p['field']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--definition", required=True)
    ap.add_argument("--source-map", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--connection-id")
    ap.add_argument("--sheet", action="append", help="limit to these sheets (repeatable)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--plan-out", required=True)
    ap.add_argument("--signature-out", help="workbook-signature.json for scripts/find-or-pick-dm.rb (Phase 1.5)")
    a = ap.parse_args()
    with open(a.source_map) as fh:
        sm = json.load(fh)
    ir = solver_def.load(a.definition)
    if a.sheet:
        keep = set(a.sheet)
        ir["sheets"] = [s for s in ir["sheets"] if s["name"] in keep]
        if not ir["sheets"]:
            sys.exit(f"no sheet named {sorted(keep)}")
    plan = C.compile_report(ir, sm)
    if plan["failed_sheets"]:
        print("sheets that could not be compiled -- nothing written:", file=sys.stderr)
        for f in plan["failed_sheets"]:
            print(f"  - {f['name']}: {f['error']}", file=sys.stderr)
        sys.exit(2)
    env, problems = build(plan, sm, a.name, a.folder_id, a.connection_id)
    if problems:
        print("source map incomplete -- nothing written:", file=sys.stderr)
        for p in sorted(set(problems)):
            print("  -", p, file=sys.stderr)
        sys.exit(2)
    with open(a.out, "w") as fh:
        json.dump(env, fh, indent=1, sort_keys=False)
        fh.write("\n")
    with open(a.plan_out, "w") as fh:
        json.dump(plan, fh, indent=1)
        fh.write("\n")
    if a.signature_out:
        with open(a.signature_out, "w") as fh:
            json.dump(signature(plan, sm), fh, indent=1)
            fh.write("\n")
    st = env["stats"]
    print(f"data model: {st['elements']} elements ({st['lines']} lines, {st['details']} expanded rows), "
          f"{st['controls']} controls, {st['gap_cells']} gap cells, {len(env['warnings'])} warnings -> {a.out}")


if __name__ == "__main__":
    main()
