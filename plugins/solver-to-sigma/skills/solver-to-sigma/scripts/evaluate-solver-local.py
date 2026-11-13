#!/usr/bin/env python3
"""Evaluate a compiled Solver plan over a local, Solver-shaped extract (creds-free).

    python3 scripts/evaluate-solver-local.py --plan plan.json --facts GL_F_Trans=gl.csv \
        [--param Period=202609 --param "Budget Scenario=BUD,ADJ"] [--fy-start <month>] --out values.json

Use it twice: as the data-readiness pre-flight (does the extract reproduce the executed run's anchors before
anything is built?) and as an offline parity oracle. The CSV header names columns the way Solver does:
``<dimension>.<field>`` for attributes (``d_Account.Code``, ``Period.PeriodId``) and ``<fact>.<value>`` for amounts
(``GL_F_Trans.Value1``). Parameters default to the report's own defaults. Stdlib only.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import solver_compile as C  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--facts", action="append", required=True, metavar="FACT=CSV")
    ap.add_argument("--param", action="append", default=[], metavar="NAME=VALUE")
    ap.add_argument("--fy-start", type=int, help="fiscal year start month (1-12); default: the plan's, which "
                    "convert-solver.py takes from the source map's fiscal_year_start_month, as the SQL does")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    with open(a.plan) as fh:
        plan = json.load(fh)
    facts = {}
    for spec in a.facts:
        name, _, path = spec.partition("=")
        facts[name] = C.read_facts_csv(path)
    overrides = dict(p.split("=", 1) for p in a.param)
    vals = C.evaluate(plan, facts, overrides, a.fy_start)
    with open(a.out, "w") as fh:
        json.dump(vals, fh, indent=1, sort_keys=True)
        fh.write("\n")
    n = sum(len(c) for s in vals.values() for c in s["lines"].values())
    print(f"evaluated {n} line cells and {sum(len(r) for s in vals.values() for r in s['details'].values())} "
          f"expanded rows -> {a.out}")


if __name__ == "__main__":
    main()
