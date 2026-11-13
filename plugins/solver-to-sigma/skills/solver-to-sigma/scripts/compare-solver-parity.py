#!/usr/bin/env python3
"""Parity: the Solver EXECUTED run vs the rebuilt values (Phase 6, C8 -- hard gate).

    python3 scripts/compare-solver-parity.py --plan plan.json --run executed-run.xlsx \
        (--values values.json | --sigma-export export.json --sheet <name>) [--abs-tol 0.01] [--rel-tol 1e-6] \
        --out parity.json

Expected values come from the executed-run export (same layout as the template, numbers filled in; the template
itself carries no values). Lines are matched by their label, in order, on both sides, so rows pushed down by an
expanded block still line up and a missing, extra or relabelled row is reported, never paired by position. Expanded
rows are matched member by member on their attribute values, both ways. Actual values come from either the local
evaluator (``--values``) or JSON exports of the rebuilt Sigma tables (``--sigma-export`` for the report table: rows
keyed by column display name, "Line" holding the label; ``--detail-export ROW=file`` for each expanded row). Make
them with ``post-solver.py export``. Untranslated (gap) cells fail the gate unless ``--allow-gaps``.

Writes {"status": "GREEN"|"RED", "compared", "mismatches", "unmatched", "gaps"} and exits 1 on RED. A mismatch is never
"close enough" by eye: widen a tolerance only with a recorded reason. Stdlib only.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import solver_def  # noqa: E402
import solver_sql as Q  # noqa: E402


def norm(s):
    return re.sub(r"\s+", " ", str(s or "")).strip().upper()


def run_rows(cells):
    rows = {}
    for ref, c in cells.items():
        col, r = solver_def._col_letters(ref)
        if col:
            rows.setdefault(r, {})[col] = c["v"]
    return rows


def close(a, b, abs_tol, rel_tol):
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) <= max(abs_tol, rel_tol * max(abs(a), abs(b)))


def actual_from_export(sheet, export):
    """Sigma export rows -> [(label, {letter: value}, {letters present})] in export order (sorted by the Row column)."""
    _, display = Q.column_names(sheet)
    by_display = {v: k for k, v in display.items()}
    return [(row.get("Line"), {by_display[k]: v for k, v in row.items() if k in by_display},
             {by_display[k] for k in row if k in by_display}) for row in export]


def detail_from_export(d, export):
    """A detail element's export (columns named by the data model's labels) -> [{letter: value}]."""
    by_label = {lab: L for L, lab in (d.get("labels") or {}).items()}
    return [{by_label.get(k, k): v for k, v in row.items()} for row in export]


def _num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def compare(plan, run_path, actual, sheet_name=None, abs_tol=0.01, rel_tol=1e-6, export=None, detail_exports=None,
            allow_gaps=False):
    """GREEN needs: every plan line found in the run AND in the actual values (matched by label, in order), every
    compared cell within tolerance, every expanded-row member present on both sides, no actual row the plan does not
    have, no untranslated (gap) cell unless ``allow_gaps``, and a run that is not all zeros."""
    cells_by_sheet = solver_def.read_xlsx_cells(run_path)
    compared, mismatches, unmatched, gaps, expected_nonzero = 0, [], [], [], 0
    detail_exports = detail_exports or {}
    for s in plan["sheets"]:
        if sheet_name and s["name"] != sheet_name:
            continue
        rows = run_rows(cells_by_sheet.get(s["name"], {}))
        if not rows:
            unmatched.append({"sheet": s["name"], "what": "sheet missing from the executed run"})
            continue
        if export is not None:
            act = actual_from_export(s, export)
        else:
            vals = actual[s["name"]]["lines"]
            act = []
            for ln in s["lines"]:
                got = vals.get(str(ln["row"]), vals.get(ln["row"]))
                act.append((ln["label"], got or {}, set(got or {})) if got is not None else None)
        used, act_cursor, run_cursor, hits = set(), 0, 0, {}
        for i, ln in enumerate(s["lines"]):
            # the actual side: --values is keyed by row; an export is matched by its Line label, in order
            if export is None:
                pair = act[i]
            else:
                j = next((k for k in range(act_cursor, len(act)) if k not in used and norm(act[k][0]) == norm(ln["label"])), None)
                pair = None if j is None else act[j]
                if j is not None:
                    used.add(j)
                    act_cursor = j + 1
            if pair is None:
                unmatched.append({"sheet": s["name"], "line": ln["label"], "what": "line missing from the rebuilt values"})
                continue
            _, got, present = pair
            col = ln.get("label_col") or "A"
            hit = next((r for r in sorted(rows) if r > run_cursor and norm(rows[r].get(col)) == norm(ln["label"])), None)
            if hit is None:
                unmatched.append({"sheet": s["name"], "line": ln["label"], "what": "label not found in the run"})
                continue
            run_cursor, hits[ln["row"]] = hit, hit
            for letter, cell in ln["cells"].items():
                if "gap" in cell:
                    gaps.append({"sheet": s["name"], "line": ln["label"], "col": letter, "gap": cell["gap"]})
                    continue
                if letter not in present:
                    unmatched.append({"sheet": s["name"], "line": ln["label"], "col": letter,
                                      "what": "column missing from the rebuilt values"})
                    continue
                exp = rows[hit].get(letter)
                exp = exp if _num(exp) else (0 if exp in (None, "") else None)
                a = got.get(letter)
                compared += 1
                expected_nonzero += bool(exp)
                if exp is None or not close(float(a) if a is not None else 0.0, float(exp), abs_tol, rel_tol):
                    mismatches.append({"sheet": s["name"], "line": ln["label"], "col": letter, "run_row": hit,
                                       "expected": exp, "actual": a})
        if export is not None:
            for k, (label, _, _) in enumerate(act):
                if k not in used:
                    unmatched.append({"sheet": s["name"], "line": label, "what": "row in the rebuilt values that the plan does not have"})
        for d in s["details"]:
            if "gap" in d:
                gaps.append({"sheet": s["name"], "detail_row": d["row"], "gap": d["gap"]})
                continue
            if export is not None:
                if d["row"] not in detail_exports:
                    unmatched.append({"sheet": s["name"], "detail_row": d["row"],
                                      "what": f"expanded row not compared: pass --detail-export {d['row']}=<export.json>"})
                    continue
                got_rows = detail_from_export(d, detail_exports[d["row"]])
            else:
                dv = actual[s["name"]]["details"]
                got_rows = dv.get(str(d["row"]), dv.get(d["row"], []))
            keys = [L for L, c in d["cells"].items() if "attribute" in c]
            if not keys:
                unmatched.append({"sheet": s["name"], "detail_row": d["row"], "what": "expanded row lists no attribute to match members on"})
                continue
            # where the block starts in the run: the template row, moved by the expansion above it
            prior = [(r, h) for r, h in hits.items() if r < d["row"]]
            start = d["row"] + (max(prior)[1] - max(prior)[0] if prior else 0)
            nxt = next((ln for ln in s["lines"] if ln["row"] > d["row"]), None)
            run_members, r = {}, start
            while r in rows and all(norm(rows[r].get(k)) for k in keys):
                if nxt and norm(rows[r].get(nxt.get("label_col") or "A")) == norm(nxt["label"]):
                    break
                run_members[tuple(norm(rows[r].get(k)) for k in keys)] = (r, {k: rows[r].get(k) for k in keys})
                r += 1
            seen = set()
            for g in got_rows:
                key = tuple(norm(g.get(k)) for k in keys)
                member = {k: g.get(k) for k in keys}
                hit = run_members.get(key, (None,))[0]
                if hit is None:
                    unmatched.append({"sheet": s["name"], "detail_row": d["row"], "member": member,
                                      "what": "rebuilt member not in the run"})
                    continue
                seen.add(key)
                for L, c in d["cells"].items():
                    if "gap" in c:
                        gaps.append({"sheet": s["name"], "detail_row": d["row"], "col": L, "gap": c["gap"]})
                        continue
                    if "expr" not in c:
                        continue
                    exp, a = rows[hit].get(L), g.get(L)
                    compared += 1
                    expected_nonzero += bool(exp) if _num(exp) else 0
                    if not _num(exp) or not close(float(a or 0), float(exp), abs_tol, rel_tol):
                        mismatches.append({"sheet": s["name"], "detail_row": d["row"], "member": member,
                                           "col": L, "run_row": hit, "expected": exp, "actual": a})
            for key, (r, member) in run_members.items():
                if key not in seen:
                    unmatched.append({"sheet": s["name"], "detail_row": d["row"], "run_row": r,
                                      "member": member, "what": "member in the run, missing from the rebuild"})
    if compared and not expected_nonzero:
        unmatched.append({"what": "every compared value in the executed run is zero: the run's parameters selected "
                                  "nothing (check them against the parameter screenshot); not a parity oracle"})
    blocking_gaps = gaps if not allow_gaps else []
    status = "GREEN" if compared and not mismatches and not unmatched and not blocking_gaps else "RED"
    return {"status": status, "compared": compared, "mismatches": mismatches, "unmatched": unmatched,
            "gaps": gaps, "gaps_accepted": bool(allow_gaps and gaps), "tolerance": {"abs": abs_tol, "rel": rel_tol}}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--run", required=True, help="executed-run export (.xlsx)")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--values", help="evaluate-solver-local.py output")
    src.add_argument("--sigma-export", help="JSON export of the rebuilt Sigma report table (needs --sheet)")
    ap.add_argument("--sheet")
    ap.add_argument("--detail-export", action="append", default=[], metavar="ROW=JSON",
                    help="export of the expanded-row table built from template row ROW (repeatable; with --sigma-export)")
    ap.add_argument("--allow-gaps", action="store_true",
                    help="report untranslated cells but do not fail on them (record why in the parity notes)")
    ap.add_argument("--abs-tol", type=float, default=0.01)
    ap.add_argument("--rel-tol", type=float, default=1e-6)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    solver_def.refuse_credentials(a.run)
    with open(a.plan) as fh:
        plan = json.load(fh)
    if a.sigma_export and not a.sheet:
        sys.exit("--sigma-export compares one sheet: pass --sheet")
    actual, export, details = None, None, {}
    for spec in a.detail_export:
        row, _, path = spec.partition("=")
        with open(path) as fh:
            d = json.load(fh)
        details[int(row)] = d.get("rows", d) if isinstance(d, dict) else d
    if a.values:
        with open(a.values) as fh:
            actual = json.load(fh)
    else:
        with open(a.sigma_export) as fh:
            export = json.load(fh)
            export = export.get("rows", export) if isinstance(export, dict) else export
    res = compare(plan, a.run, actual, a.sheet, a.abs_tol, a.rel_tol, export, details, a.allow_gaps)
    with open(a.out, "w") as fh:
        json.dump(res, fh, indent=1, default=str)
        fh.write("\n")
    print(f"parity {res['status']}: {res['compared']} cells compared, {len(res['mismatches'])} mismatches, "
          f"{len(res['unmatched'])} unmatched, {len(res['gaps'])} gaps"
          f"{' (accepted)' if res['gaps_accepted'] else ''} -> {a.out}")
    sys.exit(0 if res["status"] == "GREEN" else 1)


if __name__ == "__main__":
    main()
