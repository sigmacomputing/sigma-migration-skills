#!/usr/bin/env python3
"""Look → Sigma migration regression (single saved query → one-tile workbook).

Builds each fixtures/skilltest-looks/look_*.contract.json (exactly what
fetch_looker_look.py emits, incl. `fieldMeta`) through the REAL build_workbook.py
against the vendored demo_thelook demo views, and asserts the CONVERTER decisions
that a Look migration hinges on — with no live warehouse:

  grouped_table  → ONE `table` with groupings{groupBy:[2], calculations:[3]}   (dims+measures grouped)
  measure_only   → a row of `kpi-chart` elements                               (no dims to group)
  dims_only      → a `table` with NO groupings                                 (detail, nothing to aggregate)
  bar            → a vertical `bar-chart` (no `orientation`)                    (looker_column)
  pivot_table    → a `pivot-table` with rowsBy + columnsBy + values            (cross-tab)
  custom_measure → the ad-hoc `fieldMeta` measure lands in `calculations`,      (Item 1: authoritative
                   NOT groupBy, with a Sum(...) formula                          classification)

Every built spec must also pass preflight_lint (T1: a grouped table has groupings).

Run: python3 tests/test_look_migration.py   (exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "skilltest-looks")
VIEWS = os.path.join(FIX, "views")
LINT = os.path.join(SCRIPTS, "lib", "preflight_lint.rb")


def build(name):
    contract = os.path.join(FIX, f"look_{name}.contract.json")
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "wb.json")
        r = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "build_workbook.py"), contract,
             "--views", VIEWS, "--dm-element-name", "Order Fact View", "--out", out],
            capture_output=True, text=True)
        assert r.returncode == 0, f"build_workbook failed for {name}:\n{r.stderr}"
        spec = json.load(open(out))
        # preflight must be clean (T1: grouped table has groupings)
        json.dump(spec, open(out, "w"))
        lr = subprocess.run(["ruby", LINT, out], capture_output=True, text=True)
        assert lr.returncode == 0, f"preflight FAILED for {name}:\n{lr.stdout}{lr.stderr}"
        return spec, (r.stdout + r.stderr)


def tiles(spec):
    """Real content elements (skip the hidden Data master + layout containers)."""
    out = []
    for pg in spec.get("pages", []):
        for e in pg.get("elements", []):
            if e.get("kind") in ("container", "text") or e.get("name") == "Data":
                continue
            out.append(e)
    return out


def _one(spec, kind):
    els = [e for e in tiles(spec) if e.get("kind") == kind]
    assert len(els) == 1, f"expected exactly one {kind}, got {[e.get('kind') for e in tiles(spec)]}"
    return els[0]


def test_grouped_table():
    spec, _ = build("grouped_table")
    t = _one(spec, "table")
    g = (t.get("groupings") or [])
    assert g, "grouped table has no groupings — would render raw detail rows"
    assert len(g[0]["groupBy"]) == 2, f"expected 2 groupBy dims, got {len(g[0]['groupBy'])}"
    assert len(g[0]["calculations"]) >= 3, f"expected >=3 calc measures, got {len(g[0]['calculations'])}"
    print("[ok] grouped_table: table with groupings groupBy=2 calc>=3")


def test_measure_only():
    spec, _ = build("measure_only")
    kpis = [e for e in tiles(spec) if e.get("kind") == "kpi-chart"]
    assert len(kpis) >= 3, f"expected >=3 KPI tiles, got {len(kpis)}"
    assert not [e for e in tiles(spec) if e.get("kind") == "table"], "measure-only must not emit a table"
    print(f"[ok] measure_only: {len(kpis)} kpi-chart tiles (no table)")


def test_dims_only():
    spec, _ = build("dims_only")
    t = _one(spec, "table")
    assert not t.get("groupings"), "dims-only detail table must have NO groupings"
    print("[ok] dims_only: detail table (no groupings)")


def test_bar():
    spec, _ = build("bar")
    b = _one(spec, "bar-chart")
    assert "orientation" not in b, "looker_column → vertical bar (no orientation key)"
    assert b.get("xAxis") and b.get("yAxis"), "bar chart missing x/y axis"
    print("[ok] bar: vertical bar-chart with x/y axes")


def test_pivot_table():
    spec, _ = build("pivot_table")
    p = _one(spec, "pivot-table")
    assert p.get("rowsBy"), "pivot-table missing rowsBy (row shelf)"
    assert p.get("columnsBy"), "pivot-table missing columnsBy (column shelf)"
    assert p.get("values"), "pivot-table missing values (measure cells)"
    print(f"[ok] pivot_table: rowsBy={len(p['rowsBy'])} columnsBy={len(p['columnsBy'])} values={len(p['values'])}")


def test_custom_measure_classification():
    """Item 1: a dynamic_fields custom measure (absent from the view .lkml) must be
    classified as a MEASURE via fieldMeta → a `calculations` column with a Sum(...)
    formula — NOT dropped and NOT forced into groupBy."""
    spec, out = build("custom_measure")
    t = _one(spec, "table")
    g = (t.get("groupings") or [])
    assert g, "custom-measure grouped table has no groupings"
    cols = {c["id"]: c for c in t.get("columns", [])}
    cm = next((c for c in t["columns"] if c["name"] == "Custom Total Profit"), None)
    assert cm, f"custom measure column missing — got {[c['name'] for c in t['columns']]}"
    assert cm["id"] in g[0]["calculations"], "custom measure must be a calculation, not a groupBy dim"
    assert cm["id"] not in g[0]["groupBy"], "custom measure wrongly placed in groupBy"
    assert cm["formula"].startswith("Sum("), f"custom measure should aggregate — got {cm['formula']!r}"
    print(f"[ok] custom_measure: classified as calculation, formula {cm['formula']!r}")


if __name__ == "__main__":
    test_grouped_table()
    test_measure_only()
    test_dims_only()
    test_bar()
    test_pivot_table()
    test_custom_measure_classification()
    print("ALL PASS")
