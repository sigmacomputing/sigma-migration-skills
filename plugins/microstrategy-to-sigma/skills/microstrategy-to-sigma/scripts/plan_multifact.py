#!/usr/bin/env python3
"""Inspect a bundle's report → metric → fact → table topology.

Usage:
  python3 scripts/plan_multifact.py bundle.json [--out multi_fact_plan.json]
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from multifact import analyze_bundle  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle")
    parser.add_argument("--out", default="multi_fact_plan.json")
    args = parser.parse_args()

    with open(args.bundle, encoding="utf-8") as handle:
        plan = analyze_bundle(json.load(handle))
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(plan, handle, indent=1)
        handle.write("\n")

    print(f"wrote {args.out}: {plan['factTableCount']} fact table(s)")
    for report in plan["reports"]:
        names = ", ".join(report["tableNames"]) or "(none)"
        selected = report.get("selectedTableId")
        suffix = f"; elected={selected}" if selected else ""
        print(f"{report['classification']}: {report['name']} -> {names}{suffix}")
    if plan["requiresConformedSource"]:
        print("recovery: provide one executable conformed SELECT to "
              "convert.py --multi-fact-sql <file>")
    elif plan.get("automaticTableId"):
        print("recovery: no conformed SQL required; converter will use "
              f"logical-size election {plan['automaticTableId']} and require "
              "sqlView/parity verification")


if __name__ == "__main__":
    main()
