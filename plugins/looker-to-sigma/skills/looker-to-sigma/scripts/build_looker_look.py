#!/usr/bin/env python3
"""TEST-FIXTURE BUILDER (not a migration step). Creates a small matrix of Looker
"Looks" (saved single queries) on demo_thelook/order_fact via the Looker API, to
exercise the Look → Sigma grouped-table / pivot-table / KPI / chart converter.

Each Look = POST /queries (model/view/fields/pivots/vis_config[/dynamic_fields])
then POST /looks {title, query_id, folder_id}. Mirrors build_looker_dashboard.py.
NEVER run against a customer's Looker.

Usage:
  python3 build_looker_look.py [looker_folder_id]
  (folder defaults to the API user's personal folder)
"""
import json
import sys

import looker_api as L

MODEL, EXPLORE = "demo_thelook", "order_fact"

# (title, vis_type, fields, pivots, sorts, limit, dynamic_fields)
LOOKS = [
    # (1) GROUPED TABLE — 2 dims + 3 measures → groupings{groupBy:[2], calculations:[3]}
    ("Skilltest Look — Grouped Table", "looker_grid",
     ["customer_dim.region", "product_dim.category",
      "order_fact.total_net_revenue", "order_fact.distinct_order_count",
      "order_fact.average_order_value"], [], None, None, None),
    # (2) MEASURE-ONLY — no dims → a row of KPI tiles
    ("Skilltest Look — Measure Only", "looker_grid",
     ["order_fact.total_net_revenue", "order_fact.distinct_order_count",
      "order_fact.total_quantity"], [], None, None, None),
    # (3) DIMS-ONLY — detail table (no groupings; nothing to aggregate)
    ("Skilltest Look — Dims Only", "looker_grid",
     ["customer_dim.region", "order_fact.order_channel"], [], None, None, None),
    # (4) BAR — dim + measure, looker_column → vertical bar-chart
    ("Skilltest Look — Bar", "looker_column",
     ["customer_dim.region", "order_fact.total_net_revenue"], [],
     ["order_fact.total_net_revenue desc"], None, None),
    # (5) PIVOT TABLE — region rows × order_channel columns, revenue cells
    ("Skilltest Look — Pivot Table", "looker_grid",
     ["customer_dim.region", "order_fact.total_net_revenue"],
     ["order_fact.order_channel"], ["order_fact.total_net_revenue desc"], None, None),
    # (6) CUSTOM MEASURE (dynamic_fields, absent from the view .lkml) — must classify
    #     as a MEASURE via fieldMeta → calculations, NOT a groupBy dimension.
    ("Skilltest Look — Custom Measure", "looker_grid",
     ["customer_dim.region", "custom_total_profit"], [],
     ["custom_total_profit desc"], None,
     [{"measure": "custom_total_profit", "based_on": "order_fact.net_profit",
       "type": "sum", "label": "Custom Total Profit", "_kind_hint": "measure"}]),
]


def _personal_folder():
    code, me = L.call("GET", "/user")
    fid = (me or {}).get("personal_folder_id") or (me or {}).get("home_folder_id")
    return str(fid) if fid else None


def main(folder_id=None):
    folder_id = str(folder_id) if folder_id else _personal_folder()
    if not folder_id:
        print("FATAL: no folder_id given and could not resolve the personal folder"); sys.exit(1)
    print(f"creating Looks in Looker folder {folder_id} on {MODEL}/{EXPLORE}")
    made = []
    for title, vis, fields, pivots, sorts, limit, dyn in LOOKS:
        qbody = {"model": MODEL, "view": EXPLORE, "fields": fields, "vis_config": {"type": vis}}
        if pivots:
            qbody["pivots"] = pivots
        if sorts:
            qbody["sorts"] = sorts
        if limit:
            qbody["limit"] = str(limit)
        if dyn:
            qbody["dynamic_fields"] = json.dumps(dyn)   # Looker stores this as a JSON string
        code, q = L.call("POST", "/queries", qbody)
        if code >= 300:
            print(f"  query FAILED '{title}': {code} {q}"); continue
        code, look = L.call("POST", "/looks",
                            {"title": title, "query_id": q["id"], "folder_id": folder_id})
        if code >= 300:
            print(f"  look  FAILED '{title}': {code} {look}"); continue
        made.append((look.get("id"), title))
        print(f"  look '{title}': id={look.get('id')}")
    print("\nDONE. Look ids: " + ", ".join(str(i) for i, _ in made))
    return made


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
