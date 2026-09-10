#!/usr/bin/env python3
"""extract-cube.py — Path B (super-cube / Quick Cube rehost) data extractor.

A MicroStrategy super-cube (subtype 779 — a file/Quick-Cube import) has no
warehouse semantic model, so the classic ``extract.py`` / ``convert.py`` path
does not apply (see SKILL.md Phase 0.5 and ``refs/path-b-rehost.md``). This
pulls the cube's DATA, one CSV per source table, ready to COPY into the
warehouse the Sigma connection reaches.

It handles three things a naive "pull the whole cube into one table" does NOT:

  1. **A multi-sheet import is MANY tables in one cube.** Requesting every
     attribute + metric at once cross-joins them and MSTR aborts with
     ``Cartesian Join Governing``. The auto-generated ``Row Count - <name>``
     metrics enumerate the source tables; each is extracted at its own grain.
  2. **Element lists in each instance response are PAGE-SCOPED.** Header rows
     are element *indices* into that page's own ``definition.grid.rows[i].
     elements`` — resolve labels per page while paging, never across pages.
  3. **Fan-out guard.** A conformed dimension grouped with the wrong table's
     measure silently duplicates rows. After extracting each table we assert
     ``SUM(row-count) == table total`` and ``SUM(measure) == measure grand
     total`` (both pulled with NO attributes) so a fan-out fails loudly instead
     of shipping inflated numbers.

Membership (which attributes / measures belong to a table) is inferred by the
**grand-total invariant**, not a bare compatibility probe: an object is native
to a table only when grouping that table's Row Count by it *preserves the
total*. A conformed dimension from another sheet may not Cartesian-abort but it
REPEATS rows (the grouped Row Count sums to a multiple of the table total), so
compatibility alone is not enough — the sum has to match. Attributes and
measures that inflate the total are excluded (logged), which is what keeps each
extracted CSV at the table's true grain. Cross-check the kept set against the
dossier's viz groupings (execute each viz; see ``refs/path-b-rehost.md``).

Usage:
  python3 scripts/extract-cube.py <cubeId> <outDir> [--limit 1000]

Creds via mstr.py (MSTR_BASE_URL/USERNAME/PASSWORD or ~/.sigma-migration/env).
Writes <outDir>/<SAFE_TABLE_NAME>.csv per table + <outDir>/cube_manifest.json.
"""
import argparse
import csv
import json
import os
import re
import sys

import mstr


def _instance(s, cube, attr_ids, metric_ids, offset, limit):
    body = {"requestedObjects": {
        "attributes": [{"id": a} for a in attr_ids],
        "metrics": [{"id": m} for m in metric_ids]}}
    return s.post(f"/v2/cubes/{cube}/instances?offset={offset}&limit={limit}", body)


def _page(resp):
    """(attr names, metric names, rows) for one instance page; labels resolved
    against THIS page's own (page-scoped) element lists."""
    grid = resp["definition"]["grid"]
    data = resp["data"]
    attr_units = grid.get("rows", []) or []
    met_names = []
    for u in grid.get("columns", []) or []:
        if u.get("type") == "templateMetrics":
            met_names = [e.get("name") for e in u.get("elements", []) or []]
    hrows = data["headers"]["rows"]
    raw = data["metricValues"]["raw"]
    rows = []
    for ri, hr in enumerate(hrows):
        labels = [(attr_units[i]["elements"][idx].get("formValues") or [None])[0]
                  for i, idx in enumerate(hr)]
        rows.append(labels + (raw[ri] if ri < len(raw) else []))
    return [u.get("name") for u in attr_units], met_names, rows


def _grand(s, cube, metric_ids):
    """Metric grand totals with NO attributes (the fan-out oracle)."""
    r = _instance(s, cube, [], metric_ids, 0, 1)
    return r["data"]["metricValues"]["raw"][0]


def _preserves_total(s, cube, attr_ids, metric_ids, metric_pos, grand, limit=100000):
    """True iff grouping `metric_ids` by `attr_ids` keeps the metric at
    `metric_pos` summing to `grand` (i.e. the attribute set partitions the
    table's rows rather than repeating them). Cartesian abort => False."""
    try:
        _, _, rows, _ = _extract(s, cube, attr_ids, metric_ids, limit)
    except Exception as e:  # noqa: BLE001 — RuntimeError text carries the code
        if "cartesian" in str(e).lower():
            return False
        raise
    col = len(attr_ids) + metric_pos
    got = sum(r[col] for r in rows if isinstance(r[col], (int, float)))
    return abs(got - grand) < max(1e-3, abs(grand) * 1e-9)


def _extract(s, cube, attr_ids, metric_ids, limit):
    r = _instance(s, cube, attr_ids, metric_ids, 0, limit)
    iid = r["instanceId"]
    total = r["data"]["paging"]["total"]
    anames, mnames, rows = _page(r)
    off = limit
    while len(rows) < total:
        r2 = s.get(f"/v2/cubes/{cube}/instances/{iid}?offset={off}&limit={limit}")
        _, _, more = _page(r2)
        rows += more
        off += limit
    return anames, mnames, rows, total


def _safe(name):
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").upper() or "TABLE"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cube", help="cube / dataset object id (subtype 779)")
    ap.add_argument("outDir")
    ap.add_argument("--limit", type=int, default=1000)
    a = ap.parse_args()
    os.makedirs(a.outDir, exist_ok=True)
    s = mstr.Session()

    ao = s.get(f"/v2/cubes/{a.cube}")["definition"]["availableObjects"]
    attrs = {x["name"]: x["id"] for x in ao.get("attributes", [])}
    metrics = {x["name"]: x["id"] for x in ao.get("metrics", [])}

    # Source tables = the auto "Row Count - <name>" metrics. A cube with none is
    # single-table: the whole grid is one table.
    rc_by_table = {n.split("Row Count -", 1)[1].strip(): mid
                   for n, mid in metrics.items() if n.startswith("Row Count -")}
    if not rc_by_table:
        rc_by_table = {"cube": None}
    measures = {n: mid for n, mid in metrics.items() if not n.startswith("Row Count -")}
    print(f"cube {a.cube}: {len(attrs)} attributes, {len(measures)} measures, "
          f"{len(rc_by_table)} source table(s): {list(rc_by_table)}")

    manifest = {"cube": a.cube, "tables": {}}
    for tname, rc in rc_by_table.items():
        if rc is None:  # single-table cube — no Row Count metric to anchor on
            member_attrs = list(attrs.items())
            member_meas = list(measures.items())
        else:
            g_rc = _grand(s, a.cube, [rc])[0]
            # native attributes: grouping this table's Row Count by the attribute
            # PRESERVES the total (a foreign/joined dim would repeat rows).
            member_attrs = [(an, aid) for an, aid in attrs.items()
                            if _preserves_total(s, a.cube, [aid], [rc], 0, g_rc)]
            attr_ids = [x[1] for x in member_attrs]
            # native measures: at the native-attr grain, SUM(measure) still equals
            # its own grand total (foreign measures Cartesian-abort or inflate).
            member_meas = []
            for mn, mid in measures.items():
                g_m = _grand(s, a.cube, [mid])[0]
                if g_m is None:
                    continue
                # anchor the grain to THIS table with its Row Count, so a foreign
                # measure joined only through a conformed dim is rejected (it will
                # Cartesian-abort or sum to the wrong total at the table's grain).
                if _preserves_total(s, a.cube, attr_ids, [mid, rc], 0, g_m):
                    member_meas.append((mn, mid))

        metric_ids = [m[1] for m in member_meas] + ([rc] if rc else [])
        anames, mnames, rows, total = _extract(
            s, a.cube, [x[1] for x in member_attrs], metric_ids, a.limit)

        # fan-out guard (re-assert at the final combined grain)
        checks = {}
        if rc is not None:
            grand = _grand(s, a.cube, metric_ids)
            rc_idx = len(member_meas)  # rc is last metric
            got_rc = sum(r[len(anames) + rc_idx] for r in rows
                         if isinstance(r[len(anames) + rc_idx], (int, float)))
            checks["row_count"] = {"got": got_rc, "expected": grand[rc_idx],
                                   "ok": abs(got_rc - grand[rc_idx]) < 1e-6}
            for mi, (mn, _) in enumerate(member_meas):
                got = sum(r[len(anames) + mi] for r in rows
                          if isinstance(r[len(anames) + mi], (int, float)))
                checks[mn] = {"got": got, "expected": grand[mi],
                              "ok": abs(got - grand[mi]) < 1e-3}

        header = anames + mnames
        path = os.path.join(a.outDir, _safe(tname) + ".csv")
        with open(path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(rows)
        manifest["tables"][tname] = {
            "csv": os.path.basename(path), "rows": len(rows), "paging_total": total,
            "attributes": anames, "measures": [m[0] for m in member_meas],
            "verification": checks}
        bad = [k for k, v in checks.items() if not v.get("ok", True)]
        status = "FAN-OUT/ MISMATCH: " + ",".join(bad) if bad else "verified"
        print(f"  [{tname}] {len(rows)} rows -> {os.path.basename(path)}  ({status})")

    json.dump(manifest, open(os.path.join(a.outDir, "cube_manifest.json"), "w"), indent=2)
    print(f"wrote cube_manifest.json to {a.outDir}")
    any_bad = any(not v.get("ok", True)
                  for t in manifest["tables"].values() for v in t["verification"].values())
    sys.exit(1 if any_bad else 0)


if __name__ == "__main__":
    main()
