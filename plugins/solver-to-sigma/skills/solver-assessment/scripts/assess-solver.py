#!/usr/bin/env python3
"""Inventory a folder of Solver report downloads and score each one for migration (read-only, creds-free).

    python3 scripts/assess-solver.py --in <folder of Live Reporting Download .xlsx / decoded .xml> --out <dir>

Writes into --out:
  inventory.json   one record per report: sheets, lines, expanded rows, parameters (incl. bursting / hidden),
                   facts and dimensions read, period functions, untranslated cells, complexity score and bucket
  dashboards.json  the normalized list scripts/dup-dashboards.py reads (near-duplicate report families)
  readout.md       the migration-readiness readout: counts, buckets, the shortlist, what to ask the customer

Buckets: **automatable** (the converter translates every value cell), **iterate** (a person checks a few gaps or
expanded rows), **complex** (several fact tables, expanding columns, bursting, or many untranslated cells).
Value (who uses a report, how often, what decisions hang on it) is not in the files: ask. Files ending in
``.manifest`` are credentials (a Solver session token): they are listed as refused, never opened.
Reuses the converter's parser and compiler from ../solver-to-sigma/scripts (same plugin). Stdlib only.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "solver-to-sigma", "scripts"))
try:
    import solver_compile as C  # noqa: E402
    import solver_def  # noqa: E402
except ImportError:
    sys.exit("solver-assessment needs the solver-to-sigma skill from the same plugin (../solver-to-sigma/scripts)")


def walk_pred(p, acc):
    if not isinstance(p, dict):
        return
    k = p.get("k")
    if k in ("and", "or"):
        for x in p["xs"]:
            walk_pred(x, acc)
    elif k == "not":
        walk_pred(p["x"], acc)
    elif k == "period_fn":
        acc["period_fns"].add(p["fn"])
    elif p.get("dim"):
        acc["fields"].add(f"{p['dim']}.{p['field']}")


def profile(path):
    ir = solver_def.load(path)
    plan = C.compile_report(ir)
    acc = {"period_fns": set(), "fields": set()}
    facts, gaps, cells, lines, details, text = set(), 0, 0, 0, 0, 0
    for s in plan["sheets"]:
        lines += len(s["lines"])
        details += len(s["details"])
        text += s.get("text_cells", 0)
        for b in s["bases"].values():
            facts.add(b["fact"])
            for g in b["groups"].values():
                walk_pred(g, acc)
        for d in s["details"]:
            for b in d["bases"].values():
                facts.add(b["fact"])
                for g in b["groups"].values():             # filters that only an expanded row's cells carry
                    walk_pred(g, acc)
            for g in d["where"].values():
                walk_pred(g, acc)
            cells += max(1, len(d["cells"]))
        for ln in s["lines"]:
            cells += len(ln["cells"])
    failed = plan.get("failed_sheets", [])
    gaps = C.gap_count(plan)
    cells += sum(f.get("formula_cells", 1) or 1 for f in failed)
    params = ir["parameters"]
    expanding_cols = sum(1 for w in plan["warnings"] if "expands (one column per member)" in w)
    bursting = [p["name"] for p in params if p.get("loop")]
    score = (len(plan["sheets"]) * 2 + lines // 10 + details * 3 + len(params) + len(bursting) * 5
             + max(0, len(facts) - 1) * 10 + expanding_cols * 10 + gaps * 2 + len(acc["period_fns"]))
    gap_rate = gaps / cells if cells else 0
    if len(facts) > 1 or expanding_cols or bursting or failed or gap_rate > 0.10:
        bucket = "complex"
    elif gaps or details:
        bucket = "iterate"
    else:
        bucket = "automatable"
    return {"file": os.path.basename(path), "title": ir.get("title"), "author": ir.get("author"),
            "sheets": [s["name"] for s in ir["sheets"]], "lines": lines, "expanded_rows": details,
            "expanding_columns": expanding_cols, "value_cells": cells, "untranslated_cells": gaps, "text_cells": text,
            "failed_sheets": [f["name"] for f in failed],
            "parameters": [{"name": p["name"], "hidden": p.get("hidden"), "bursting": bool(p.get("loop")),
                            "period": p.get("is_period")} for p in params],
            "facts": sorted(facts), "fields": sorted(acc["fields"]), "period_functions": sorted(acc["period_fns"]),
            "integration": sorted({d.get("integration") or "" for d in ir["data_sources"]}),
            "score": score, "bucket": bucket, "warnings": plan["warnings"][:50]}


def readout(inv, refused, errors):
    by = {b: [r for r in inv if r["bucket"] == b] for b in ("automatable", "iterate", "complex")}
    out = ["# Solver migration readout", "",
           f"{len(inv)} reports profiled from their Live Reporting downloads"
           + (f"; {len(errors)} files could not be read" if errors else "")
           + (f"; {len(refused)} `.manifest` files refused (credentials)" if refused else "") + ".", "",
           "| Bucket | Reports | Lines | Untranslated cells |", "|---|---|---|---|"]
    for b, rs in by.items():
        out.append(f"| {b} | {len(rs)} | {sum(r['lines'] for r in rs)} | {sum(r['untranslated_cells'] for r in rs)} |")
    out += ["", "## Shortlist (lowest effort first)", "", "| Report | Bucket | Sheets | Lines | Expanded rows | Facts | Period functions |",
            "|---|---|---|---|---|---|---|"]
    for r in sorted(inv, key=lambda r: (r["score"], r["title"] or "")):
        out.append(f"| {r['title'] or r['file']} | {r['bucket']} | {len(r['sheets'])} | {r['lines']} | {r['expanded_rows']} | "
                   f"{', '.join(r['facts']) or '-'} | {', '.join(r['period_functions']) or '-'} |")
    facts = sorted({f for r in inv for f in r["facts"]})
    fields = sorted({f for r in inv for f in r["fields"]})
    out += ["", "## Data the estate reads", "",
            f"- Fact tables: {', '.join(facts) or 'none'} -- each needs a warehouse home in the source map.",
            f"- Dimension fields: {len(fields)} distinct (`<dimension>.<field>`); UDF fields are customer-defined, "
            "so ask what each one holds.", "",
            "## Ask the customer", "",
            "- Which of these reports are still used, by whom, and how often? (Value is not in the files.)",
            "- For each fact table: where does the same data live in the warehouse today, and which copy is the "
            "source of truth (the ERP's GL, or a replicated Solver feed)? Is it loaded daily?",
            "- One executed run per report for a recent closed period, with its parameter values, for parity.",
            "- Which reports are near-duplicates that should become one Sigma workbook (see the duplicate groups)?",
            "- Is Solver also where budgets are entered, or where any master data (tags, re-codes, manual loads) is "
            "maintained by hand? Each needs a new home and an owner before Solver is switched off.",
            "- Do any reports produce a file for another system (an ERP import) rather than a statement? Those become "
            "workflow apps, not reports (see `../solver-to-sigma/refs/field-notes.md`)."]
    if refused:
        out += ["", "## Refused files", "", "These are `.manifest` files: they carry a Solver session token. They were "
                "not opened. Ask the sender to delete them and send the Live Reporting **Download** instead.", ""]
        out += [f"- {f}" for f in refused]
    if errors:
        out += ["", "## Unreadable files", ""] + [f"- {f}: {e}" for f, e in errors]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    inv, refused, errors = [], [], []
    for name in sorted(os.listdir(a.src)):
        path = os.path.join(a.src, name)
        if name.lower().endswith(".manifest"):
            refused.append(name)
            continue
        if not re.search(r"\.(xlsx|xlsm|xml)$", name, re.I) or name.startswith("~$"):
            continue
        try:
            inv.append(profile(path))
        except (solver_def.NotADefinition, C.Unsupported) as e:
            errors.append((name, str(e).replace(path, name)[:200]))
        except Exception as e:  # a malformed file must not stop the inventory
            errors.append((name, f"{type(e).__name__}: {str(e).replace(path, name)[:160]}"))
    with open(os.path.join(a.out, "inventory.json"), "w") as fh:
        json.dump({"reports": inv, "refused": refused, "errors": errors}, fh, indent=1)
    dash = [{"id": r["file"], "name": r["title"] or r["file"], "sources": r["facts"], "fields": r["fields"],
             "viz": ["statement"] * min(1, r["lines"]) + ["detail"] * min(1, r["expanded_rows"])} for r in inv]
    with open(os.path.join(a.out, "dashboards.json"), "w") as fh:
        json.dump(dash, fh, indent=1)
    with open(os.path.join(a.out, "readout.md"), "w") as fh:
        fh.write(readout(inv, refused, errors))
    print(f"{len(inv)} reports profiled, {len(refused)} manifests refused, {len(errors)} unreadable -> {a.out}")


if __name__ == "__main__":
    main()
