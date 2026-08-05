#!/usr/bin/env python3
"""Grounding regression for ts_common.py (beads-sigma-kvza).

Proves the ThoughtSpot->Sigma dashboard classifier is documentation-grounded and
loud-on-unmapped:
  1. CATALOGS      — all four refs/catalogs/*.json load, are cited (real doc URLs),
     have unique sources, and every row carries a Sigma target.
  2. NO INLINE MAP — the viz/number-format/aggregation/control maps are DERIVED
     from the catalogs; no residual inline literal bypasses the single source of
     truth, and the three named silent-default strings are gone.
  3. LOUD FALLBACKS — a genuinely unknown chart type, an unmapped aggregation
     token, and an unknown filter operator each WARN loudly (and do an explicit
     degrade / fallback), never a silent wrong default (silent bar-chart / silent
     Sum / silent include). Known inputs stay silent (behavior preserved).
  4. COVERAGE MATRIX — refs/thoughtspot-coverage.md is fresh vs the catalogs.

ts_common.py is a non-deterministic builder library (element ids from `secrets`)
with no offline Liveboard-build fixture, so this is a UNIT test over the classifier
functions + verbatim-extraction checks — no byte-golden (per the handoff).

Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
COVERAGE = os.path.join(SKILL, "refs", "thoughtspot-coverage.md")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))

DIMS = {"viz-kind", "number-format", "aggregation", "control"}


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == DIMS, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows, "empty catalog: " + name
        assert cat.source_tool == "thoughtspot", (name, cat.source_tool)
        assert cat.authoritative_doc.startswith("http"), (name, "no authoritative_doc")
        seen = set()
        for r in cat.rows:
            key = str(r["source"]).lower()
            assert key not in seen, "duplicate source in %s: %s" % (name, key)
            seen.add(key)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"], "doc_ref not a URL")
            assert r.get("sigma") is not None, (name, r["source"], "no Sigma target")
    print("[ok] catalogs: 4 dimensions load, cited (real URLs), unique sources, targeted")


def test_no_inline_maps():
    src = open(os.path.join(SCRIPTS, "ts_common.py")).read()
    # catalogs are loaded
    assert "coverage_catalog" in src and "_cc.load(" in src, "builder does not load catalogs"
    # every enumerable map is catalog-derived (not an inline literal)
    assert "for r in VIZ_CAT.rows" in src, "KIND/_NO_SIGMA_EQUIV not derived from viz-kind catalog"
    assert "for r in AGG_CAT.rows" in src, "TS_AGG_TO_SIGMA not derived from aggregation catalog"
    assert "for r in FMT_CAT.rows" in src, "_CUR not derived from number-format catalog"
    assert "for r in CTRL_CAT.rows" in src, "_TS_FILTER_OP not derived from control catalog"
    # the three named silent-default strings must be gone
    assert 'KIND.get(chart, "bar-chart")' not in src, "silent viz->bar-chart default still present"
    assert "TS_AGG_TO_SIGMA.get(" not in src, "silent TS_AGG_TO_SIGMA.get(...,'Sum') still present"
    assert "_TS_FILTER_OP.get(" not in src, "silent _TS_FILTER_OP.get(op,'include') still present"
    # the old inline literals must be gone (verbatim extraction, not a copy)
    assert '"KPI": "kpi-chart"' not in src, "KIND inline literal still present"
    assert '_NO_SIGMA_EQUIV = {"WATERFALL"' not in src, "_NO_SIGMA_EQUIV inline literal still present"
    assert '{"USD": "$"' not in src, "_CUR inline literal still present"
    print("[ok] no-inline-map: viz/agg/format/control maps catalog-derived; 3 silent defaults removed")


def _fresh():
    import ts_common
    ts_common.drain_warnings()
    return ts_common


def test_loud_unknown_viz():
    """A genuinely unknown chart string -> loud warn + flagged table, NOT silent bar."""
    t = _fresh()
    spec = {"name": "Bogus Tile", "chart": "ZZZ_BOGUS_CHART",
            "dims": ["Category"], "measures": ["Revenue"], "mtypes": {}}
    el = t.sigma_element(spec, {})
    warns = t.drain_warnings()
    assert el["kind"] == "table", "unknown viz was NOT degraded to a table (silent bar?): " + el["kind"]
    assert "ZZZ_BOGUS_CHART" in el["name"], "degraded table not flagged with the source chart type"
    assert any("viz-kind" in w and "ZZZ_BOGUS_CHART" in w for w in warns), \
        "unknown viz type did not warn loudly: %r" % warns
    # a KNOWN chart type stays silent (behavior preserved)
    t.drain_warnings()
    t.sigma_element({"name": "Bars", "chart": "COLUMN", "dims": ["Category"],
                     "measures": ["Revenue"], "mtypes": {}}, {})
    assert not t.drain_warnings(), "a known chart type must not warn"
    print("[ok] loud viz: unknown chart 'ZZZ_BOGUS_CHART' warns + degrades to flagged table")


def test_loud_unknown_agg():
    """An unmapped aggregation token -> loud warn + EXPLICIT Sum, NOT a silent Sum."""
    t = _fresh()
    spec = {"name": "KPI", "chart": "KPI", "dims": [], "measures": ["Revenue"],
            "mtypes": {"Revenue": {"agg": "BOGUS_AGG"}}}
    el = t.sigma_element(spec, {})
    warns = t.drain_warnings()
    assert el["columns"][0]["formula"].startswith("Sum("), "explicit fallback should be Sum(...)"
    assert any("aggregation" in w and "BOGUS_AGG" in w for w in warns), \
        "unmapped aggregation token did not warn loudly: %r" % warns
    # a KNOWN token stays silent and resolves correctly (behavior preserved)
    t.drain_warnings()
    el2 = t.sigma_element({"name": "KPI", "chart": "KPI", "dims": [], "measures": ["Revenue"],
                           "mtypes": {"Revenue": {"agg": "AVERAGE"}}}, {})
    assert el2["columns"][0]["formula"].startswith("Avg(") and not t.drain_warnings(), \
        "a known aggregation token must map (AVERAGE->Avg) with no warning"
    print("[ok] loud agg: unmapped token 'BOGUS_AGG' warns + explicit Sum (no silent Sum)")


def test_loud_unknown_control_op():
    """An unknown filter operator -> loud warn + EXPLICIT include, NOT a silent include."""
    t = _fresh()
    fs = t.parse_liveboard_filters({"filters": [{"column": "Region",
                                                  "operator": "BOGUS_OP", "values": ["West"]}]})
    warns = t.drain_warnings()
    assert fs and fs[0]["mode"] == "include", "unknown op should fall back to include explicitly"
    assert any("control" in w and "BOGUS_OP" in w for w in warns), \
        "unknown filter operator did not warn loudly: %r" % warns
    # a KNOWN operator stays silent and maps correctly (behavior preserved)
    t.drain_warnings()
    fs2 = t.parse_liveboard_filters({"filters": [{"column": "Region",
                                                  "operator": "NOT_IN", "values": ["West"]}]})
    assert fs2[0]["mode"] == "exclude" and not t.drain_warnings(), \
        "a known operator must map (NOT_IN->exclude) with no warning"
    print("[ok] loud control: unknown op 'BOGUS_OP' warns + explicit include (no silent include)")


def test_coverage_matrix_fresh():
    """refs/thoughtspot-coverage.md must be regenerated from the catalogs (no drift)."""
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "gen-coverage-matrix.py"),
         "--catalogs", CATDIR, "--skill", "thoughtspot", "--out", COVERAGE, "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, "coverage matrix is stale — regenerate:\n" + r.stderr
    print("[ok] coverage matrix: refs/thoughtspot-coverage.md matches the catalogs")


if __name__ == "__main__":
    test_catalogs_valid()
    test_no_inline_maps()
    test_coverage_matrix_fresh()
    test_loud_unknown_viz()
    test_loud_unknown_agg()
    test_loud_unknown_control_op()
    print("ALL PASS")
