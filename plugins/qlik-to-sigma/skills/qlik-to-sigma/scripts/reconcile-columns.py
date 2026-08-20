#!/usr/bin/env python3
"""reconcile-columns — auto-derive the Qlik-field → warehouse-column map from the load script.

    python3 reconcile-columns.py --script discovery/script.qvs [--out reconcile.json]

Phase 3 of qlik-to-sigma. The Qlik LOAD script renames warehouse columns
(`ORDER_STORE_KEY AS STORE_KEY`, `REGION AS CUSTOMER_REGION`) — so when you build the
Sigma data model against the real warehouse, you must point columns at the REAL column
while keeping the Qlik field name. This parses the load script's `AS` clauses + the
source table per `LOAD` block and emits that mapping, so the DM build (or the denormalized
SQL element) can use `<real col> AS <qlik name>` faithfully.

Output per Qlik table:
  { qlikTable, sourceTable,
    fields:[{ qlikField, realColumn, renamed, isExpression,
              loadExpression?, expressionColumns? }] }

Handles: `SQL SELECT ... FROM db.schema.TABLE;` (real migration),
`FROM [lib://Conn/FILE.csv]` (CSV fixture), and RESIDENT chains backed by either.
"""
import os, json, argparse, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlik_load_script import parse_reconcile

def parse(qvs):
    return parse_reconcile(qvs)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True)
    ap.add_argument("--out", default="reconcile.json")
    a = ap.parse_args()
    tables = parse(open(a.script).read())
    json.dump(tables, open(a.out, "w"), indent=2)
    print(f"tables={len(tables)} -> {a.out}")
    for t in tables:
        ren = [f for f in t["fields"] if f["renamed"]]
        print(f"  {t['qlikTable']:14} src={t['sourceTable']:30} fields={len(t['fields']):2}  renamed={len(ren)}")
        for f in ren:
            tag = " (EXPR)" if f.get("isExpression") else ""
            print(f"      {f['qlikField']}  <-  {f['realColumn']}{tag}")

if __name__ == "__main__":
    main()
