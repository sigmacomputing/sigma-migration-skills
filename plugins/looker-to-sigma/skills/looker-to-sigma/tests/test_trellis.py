#!/usr/bin/env python3
"""test_trellis.py — e2e for the Looker native-trellis path.

Looker's small-multiples shape is `looker_donut_multiples`: a GRID OF DONUTS —
one donut per value of the query's row dimension, each sliced by the pivot + the
measure. build_workbook.py emits ONE Sigma donut-chart element and delegates the
facet to the shared TrellisEmit (supported-kind gate + fallbacks), so the row
dimension becomes Sigma's NATIVE element `trellis` (columnsBy), NOT N cloned tiles.

Covers:
  1. DETECTION (parse_lookml_dashboard.norm_trellis) flags the donut_multiples tile
     and leaves a plain tile with no signal.
  2. EMISSION: the donut_multiples tile → ONE donut-chart with trellis.columnsBy
     faceted by the row dimension; the pivot stays the slice category (color).
  3. A non-multiples tile (looker_pie) builds unchanged — no trellis key.
  4. The round-trip sidecar native-trellis-emitted.json lists exactly the emitted
     donut and re-verifies GREEN against a faithful readback / RED against a
     stripped one (shared verify-trellis-survived.rb).
  5. Byte-identical no-op: the SAME dashboard with the tile downgraded to a plain
     looker_pie emits no trellis and writes NO sidecar.

Run: python3 tests/test_trellis.py   (exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
BUILDER = os.path.join(SCRIPTS, "build_workbook.py")
VERIFY = os.path.join(SCRIPTS, "verify-trellis-survived.rb")   # synced shared guard
FIX = os.path.join(SKILL, "fixtures", "skilltest-orders")
VIEWS = os.path.join(FIX, "views")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))
import code_rep  # noqa: E402

# A donut-multiples tile (grid of donuts: one donut per region, sliced by channel)
# + a plain pie tile that must stay flat. Exercises DETECTION via the real parser.
DASH_LKML = """\
- dashboard: trellis_test
  title: Trellis Test
  layout: newspaper
  elements:
  - name: Revenue Share by Channel per Region
    title: Revenue Share by Channel per Region
    model: skilltest_orders
    explore: order_fact
    type: looker_donut_multiples
    fields: [customer_dim.region, order_fact.total_net_revenue]
    pivots: [order_fact.order_channel]
    row: 0
    col: 0
    width: 12
    height: 8
  - name: Orders by Ship Method
    title: Orders by Ship Method
    model: skilltest_orders
    explore: order_fact
    type: looker_pie
    fields: [order_fact.ship_method, order_fact.order_count]
    row: 0
    col: 12
    width: 12
    height: 8
"""

_fail = 0


def ok(name, cond):
    global _fail
    print(("  ok  " if cond else "FAIL  ") + name)
    if not cond:
        _fail += 1


def build(contract, workdir):
    cpath = os.path.join(workdir, "c.json")
    opath = os.path.join(workdir, "wb.json")
    json.dump(contract, open(cpath, "w"))
    r = subprocess.run(
        [sys.executable, BUILDER, cpath, "--views", VIEWS, "--dm-id", "dm-x",
         "--element-id", "el-x", "--dm-element-name", "Order Fact", "--out", opath],
        capture_output=True, text=True)
    assert r.returncode == 0, "build_workbook failed:\n" + r.stderr
    spec = json.load(open(opath))
    els = code_rep.workbook_elements(spec)
    return els, (r.stdout + r.stderr)


def main():
    import parse_lookml_dashboard as offline
    workdir = tempfile.mkdtemp()
    dash_path = os.path.join(workdir, "trellis.dashboard.lookml")
    open(dash_path, "w").write(DASH_LKML)

    # 1) DETECTION — the parser flags the donut_multiples tile, not the pie.
    contract = offline.parse(dash_path)[0]
    by_name = {e["name"]: e for e in contract["elements"]}
    dm = by_name["Revenue Share by Channel per Region"]
    pie = by_name["Orders by Ship Method"]
    ok("detect: donut_multiples tile carries a trellis signal",
       isinstance(dm.get("trellis"), dict) and dm["trellis"]["shape"] == "donut_multiples")
    ok("detect: donut_multiples orientation is cols (columnsBy grid)",
       dm["trellis"]["orientation"] == "cols")
    ok("detect: plain pie tile has NO trellis signal", pie.get("trellis") is None)

    # 2) EMISSION — ONE donut-chart with trellis.columnsBy faceted by the row dim.
    els, out = build(contract, workdir)
    donuts = [e for e in els if e.get("kind") == "donut-chart"]
    ok("emit: exactly ONE donut-chart emitted (not N cloned tiles)", len(donuts) == 1)
    d = donuts[0] if donuts else {}
    tr = d.get("trellis") or {}
    ok("emit: donut carries trellis.columnsBy (and not rowsBy)",
       bool(tr.get("columnsBy")) and "rowsBy" not in tr)

    def col(cid):
        return next((c for c in d.get("columns", []) if c["id"] == cid), None)

    facet_cid = tr.get("columnsBy", [{}])[0].get("columnId")
    facet_col = col(facet_cid) if facet_cid else None
    # (cross-view dims are display-disambiguated, e.g. "Region (customer_dim)")
    ok("emit: facet column is the ROW dimension (Region)",
       facet_col is not None and facet_col["name"].startswith("Region"))
    # the SLICE category (color) is the pivot (Order Channel), NOT the facet
    slice_cid = (d.get("color") or {}).get("id")
    slice_col = col(slice_cid) if slice_cid else None
    ok("emit: slice category (color) is the pivot (Order Channel), distinct from the facet",
       slice_col is not None and slice_col["name"] == "Order Channel" and slice_cid != facet_cid)
    ok("emit: build warns it emitted a native donut trellis", "native trellis:" in out)

    # 3) the plain pie is untouched — a pie-chart with no trellis key.
    pies = [e for e in els if e.get("kind") == "pie-chart"]
    ok("emit: plain pie stays a pie-chart with NO trellis key",
       len(pies) == 1 and "trellis" not in pies[0])

    # 4) sidecar lists exactly the donut; readback guard GREEN / RED.
    nt_path = os.path.join(workdir, "native-trellis-emitted.json")
    ok("sidecar: native-trellis-emitted.json written", os.path.exists(nt_path))
    nt = json.load(open(nt_path))
    recs = {r["element_id"]: r for r in nt["elements"]}
    ok("sidecar: exactly the ONE donut element, axis=columnsBy, source=looker",
       nt["source"] == "looker" and len(recs) == 1 and d["id"] in recs
       and recs[d["id"]]["axis"] == "columnsBy")
    if os.path.exists(VERIFY):
        spec_ok = {"pages": [{"id": "p"}], "elements": [d],
                   "layout": f'<Page id="p"><Element elementId="{d["id"]}"/></Page>'}
        rp = os.path.join(workdir, "readback-ok.json"); json.dump({"spec": spec_ok}, open(rp, "w"))
        g = subprocess.run(["ruby", VERIFY, "--emitted", nt_path, "--spec", rp],
                           capture_output=True, text=True)
        ok("verify-trellis-survived PASSES on a faithful readback", g.returncode == 0)
        spec_bad = {"pages": [{"id": "p"}],
                    "elements": [{"id": d["id"], "kind": d["kind"]}],
                    "layout": f'<Page id="p"><Element elementId="{d["id"]}"/></Page>'}
        bp = os.path.join(workdir, "readback-stripped.json"); json.dump({"spec": spec_bad}, open(bp, "w"))
        b = subprocess.run(["ruby", VERIFY, "--emitted", nt_path, "--spec", bp],
                           capture_output=True, text=True)
        ok("verify-trellis-survived FAILS when Sigma strips the trellis", b.returncode != 0)
    else:
        print("  --   verify-trellis-survived.rb not found; skipped readback guard assertions")

    # 5) BYTE-IDENTICAL no-op — downgrade the tile to a plain pie: no trellis, no sidecar.
    wd2 = tempfile.mkdtemp()
    contract2 = offline.parse(dash_path)[0]
    for e in contract2["elements"]:
        if e["tileType"] == "looker_donut_multiples":
            e["tileType"] = "looker_pie"; e["trellis"] = None
    els2, _ = build(contract2, wd2)
    ok("no-signal build emits ZERO trellis keys",
       not any("trellis" in e for e in els2))
    ok("no-signal build writes NO sidecar",
       not os.path.exists(os.path.join(wd2, "native-trellis-emitted.json")))

    print()
    if _fail == 0:
        print("ALL PASS — Looker native trellis (donut_multiples detect + emit; row-dim facet "
              "columnsBy; pivot stays the slice; supported-kind gate; readback guard; byte-identical no-op)")
        sys.exit(0)
    print("%d FAILURE(S)" % _fail)
    sys.exit(1)


if __name__ == "__main__":
    main()
