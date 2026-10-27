#!/usr/bin/env python3
"""emit-pivot-collapse-program.py - Python twin of emit-pivot-collapse-program.rb.

OPTIONAL post-publish step for Tableau drill hierarchies shown on a crosstab.
Tableau shows such a pivot collapsed to the hierarchy's first level with a +
per row; Sigma's pivot can do the same, but the collapsed state is NOT part of
the workbook spec (REST), only of the Sigma MCP Code Mode SDK
(`PivotTable.add_pivot_row` + `collapse_rows`, live-verified 2026-10-27).
build-charts-from-signals already put every lower level on the pivot as an
off-shelf column and listed the pivot in <workdir>/auto-interactions.json (kind
'pivot-collapse'); this script turns those entries into ONE Code Mode program
for the agent to run through the Sigma MCP `build_workbook` tool (target:
existing workbook).

Run it only after the LAST REST spec write (layout, repairs, finalize): any
later PUT /v2/workbooks/{id}/spec expands the pivot again, so re-run it after
one. Without the Sigma MCP, skip it - the post-publish guide keeps the manual
step.

Usage:
  python3 scripts/emit-pivot-collapse-program.py --workdir <workdir> [--workbook-id <id>] [--json]
Prints the program (or, with --json, {"workbookId", "program", "pivots"}).
Exit 0 with a note and no program when there is nothing to collapse.
"""

import argparse
import json
import os
import sys


def pivot_collapse_entries(sidecar):
    if not sidecar or not os.path.exists(sidecar):
        return []
    try:
        with open(sidecar, encoding="utf-8") as fh:
            data = json.load(fh)
    except ValueError:
        return []
    items = (data.get("entries") or data.get("interactions") or []) if isinstance(data, dict) else data
    out = []
    for e in items or []:
        if not isinstance(e, dict) or e.get("kind") != "pivot-collapse" or not e.get("element_id"):
            continue
        levels = e.get("levels") or []
        if len(levels) >= 2 and all(lv.get("column_id") for lv in levels):
            out.append(e)
    return out


def program_for(entries):
    lines = ["from sigma.pivotTable import PivotTable"]
    for e in entries:
        ids = [lv["column_id"] for lv in e["levels"]]
        lines.append(f"pt = sigma.workbook.get_element({json.dumps(e['element_id'])})")
        lines.append("if isinstance(pt, PivotTable):")
        lines.append(f"    levels = [pt.get_column(c) for c in {json.dumps(ids, separators=(',', ':'))}]")
        lines.append("    on_rows = [r.name() for r in pt.list_pivot_rows()]")
        lines.append("    for col in levels[1:]:")
        lines.append("        if col.name() not in on_rows:")
        lines.append("            pt.add_pivot_row(col)")
        lines.append("    pt.collapse_rows(levels[0])")
        done = f"collapsed {e['element_id']} at {e['levels'][0]['name']}"
        lines.append(f"    print({json.dumps(done)})")
        lines.append("else:")
        lines.append(f"    print({json.dumps('MISSING pivot ' + e['element_id'])})")
    return "\n".join(lines) + "\n"


def workbook_id_from(workdir):
    path = os.path.join(workdir or "", "migrate-state.json")
    if not workdir or not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh).get("workbook_id")
    except ValueError:
        return None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir")
    ap.add_argument("--sidecar", help="default: <workdir>/auto-interactions.json")
    ap.add_argument("--workbook-id")
    ap.add_argument("--json", action="store_true")
    opts = ap.parse_args(argv)
    sidecar = opts.sidecar or (os.path.join(opts.workdir, "auto-interactions.json") if opts.workdir else None)
    entries = pivot_collapse_entries(sidecar)
    if not entries:
        print(f"no pivot-collapse entries in {sidecar or '(no sidecar)'} - nothing to do", file=sys.stderr)
        return 0
    wb = opts.workbook_id or workbook_id_from(opts.workdir)
    program = program_for(entries)
    if opts.json:
        pivots = [{k: e[k] for k in ("worksheet", "element_id", "caption") if k in e} for e in entries]
        print(json.dumps({"workbookId": wb, "program": program, "pivots": pivots}, indent=2))
    else:
        print(f"run with the Sigma MCP build_workbook tool, target {{type: existing, workbookId: {wb or '<workbook id>'}}}",
              file=sys.stderr)
        sys.stdout.write(program)
    return 0


if __name__ == "__main__":
    sys.exit(main())
