#!/usr/bin/env python3
"""test_trellis_emit.py — unit test for TrellisEmit (the shared native-trellis
emitter), the Python side. Byte-for-byte behavioural mirror of the Ruby
test-trellis-emit.rb: identical cases, identical expected shapes, results as the
mirrored STRINGS (Ruby returns symbols). Converter-agnostic, pure, no network.
Canonical in shared/scripts; edit there, run tools/sync-shared.rb.
Run: python3 scripts/test_trellis_emit.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import trellis_emit as TE  # noqa: E402

_fail = 0


def ok(name, cond):
    global _fail
    print(("  ok  " if cond else "FAIL  ") + name)
    if not cond:
        _fail += 1


def el(kind, cols=None):
    return {"id": "el-1", "kind": kind, "columns": cols if cols is not None else [{"id": "c-cat"}]}


# ---- supported kinds -> trellis set, right axis per orientation --------------
for k in ("bar-chart", "line-chart", "area-chart", "combo-chart", "scatter-chart", "donut-chart"):
    e = el(k)
    r = TE.apply(e, "c-cat", "rows")
    ok("%s: rows -> trellised + trellis.rowsBy" % k,
       r == "trellised" and e["trellis"] == {"rowsBy": [{"columnId": "c-cat"}]})

    e2 = el(k)
    r2 = TE.apply(e2, "c-cat", "cols")
    ok("%s: cols -> trellis.columnsBy (and NOT rowsBy)" % k,
       r2 == "trellised" and e2["trellis"] == {"columnsBy": [{"columnId": "c-cat"}]})

# ---- pie-chart -> donut + trellis (fallback) --------------------------------
e = el("pie-chart")
r = TE.apply(e, "c-cat", "cols")
ok("pie-chart -> fallback_donut", r == "fallback_donut")
ok("pie-chart kind flipped to donut-chart", e["kind"] == "donut-chart")
ok("pie->donut carries the native trellis", e["trellis"] == {"columnsBy": [{"columnId": "c-cat"}]})
ok("pie-chart trellises() is true (converts)", TE.trellises("pie-chart"))

# ---- kpi-chart -> needs-sibling signal, element untouched -------------------
e = el("kpi-chart")
r = TE.apply(e, "c-cat", "cols")
ok("kpi-chart -> needs_sibling_fanout", r == "needs_sibling_fanout")
ok("kpi-chart left UNTOUCHED (no trellis, kind unchanged)",
   "trellis" not in e and e["kind"] == "kpi-chart")
ok("kpi-chart trellises() is false", not TE.trellises("kpi-chart"))

# ---- pivot-table -> needs-shelves signal, untouched -------------------------
e = el("pivot-table")
r = TE.apply(e, "c-cat", "rows")
ok("pivot-table -> needs_pivot_shelves", r == "needs_pivot_shelves")
ok("pivot-table left UNTOUCHED", "trellis" not in e and e["kind"] == "pivot-table")

# ---- table -> flat no-op ----------------------------------------------------
e = el("table")
r = TE.apply(e, "c-cat", "cols")
ok("table -> flat", r == "flat")
ok("table left UNTOUCHED", "trellis" not in e)

# ---- unknown kind -> flat (default fallback) --------------------------------
e = el("funnel-chart")
ok("unknown kind -> flat disposition", TE.disposition("funnel-chart") == "flat")
r = TE.apply(e, "c-cat", "cols")
ok("unknown kind -> flat + untouched", r == "flat" and "trellis" not in e)

# ---- 2-D grid -> BOTH keys, two different columns ---------------------------
e = el("bar-chart", [{"id": "c-row"}, {"id": "c-col"}])
r = TE.apply(e, ["c-row", "c-col"], "grid")
ok("grid + two facet ids -> trellised", r == "trellised")
ok("grid -> rowsBy AND columnsBy on the two distinct columns",
   e["trellis"] == {"rowsBy": [{"columnId": "c-row"}], "columnsBy": [{"columnId": "c-col"}]})

# A single-field grid wraps into a tile grid -> columnsBy only (tableau parity).
e = el("bar-chart")
TE.apply(e, "c-cat", "grid")
ok("grid + single facet id -> columnsBy only (single-field tile grid)",
   e["trellis"] == {"columnsBy": [{"columnId": "c-cat"}]})

# ---- disposition is the single source of truth (non-mutating) ---------------
ok("disposition(bar-chart) == trellised", TE.disposition("bar-chart") == "trellised")
ok("disposition(pie-chart) == fallback_donut", TE.disposition("pie-chart") == "fallback_donut")
ok("disposition(kpi-chart) == needs_sibling_fanout",
   TE.disposition("kpi-chart") == "needs_sibling_fanout")
ok("disposition(pivot-table) == needs_pivot_shelves",
   TE.disposition("pivot-table") == "needs_pivot_shelves")
ok("disposition(table) == flat", TE.disposition("table") == "flat")
ok("SUPPORTED_KINDS is the documented readback-safe set",
   list(TE.SUPPORTED_KINDS) == ["bar-chart", "line-chart", "area-chart",
                                "combo-chart", "scatter-chart", "donut-chart"])

print()
if _fail == 0:
    print("ALL PASS — TrellisEmit (supported->trellis by orientation; pie->donut; "
          "kpi/pivot/table fallbacks; 2-D grid -> both keys)")
    sys.exit(0)
else:
    print("%d FAILURE(S)" % _fail)
    sys.exit(1)
