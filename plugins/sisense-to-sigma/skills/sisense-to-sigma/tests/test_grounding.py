#!/usr/bin/env python3
"""Grounding regression for the Sisense->Sigma dashboard classifier ([bead]).

Proves convert.py / jaql_expr.py are documentation-grounded and loud-on-unmapped:
  1. CATALOGS      — all six refs/catalogs/*.json load and are cited. The JAQL
     function rows carry behavior, stable warning ids, and dated verification
     evidence; only SUM/COUNT are stamped from the documented live run.
  2. NO INLINE MAP — the viz/format/aggregation/control maps are DERIVED from the
     catalogs (grep the builders); no residual inline literal bypasses the single
     source of truth, and the specific name-guessing silent default is GONE.
  3. LOUD FALLBACKS — the killed silent default (currency title-substring guess)
     now WARNS on a non-currency mask and no longer fabricates a $ format from a
     'Revenue'/'Cost' title; an unknown widget type and an unmapped agg each warn/
     flag rather than silently emitting a wrong element or a default aggregate.
  4. COVERAGE       — refs/sisense-coverage.md is fresh vs the catalogs.

No byte-golden: convert.py mints random element ids and there is no offline
workbook fixture, so verbatim extraction (asserted in test_convert.py's parity)
plus these unit checks are the contract.

Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import copy, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
FIX = os.path.join(SKILL, "fixtures")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))

DIMS = {"viz-kind", "number-format", "aggregation", "control",
        "workbook-feature", "jaql-function"}


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == DIMS, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows, "empty catalog: " + name
        assert cat.source_tool == "sisense", (name, cat.source_tool)
        assert cat.authoritative_doc.startswith("http"), (name, "authoritative_doc not a URL")
        seen = set()
        for r in cat.rows:
            key = str(r["source"]).lower()
            assert key not in seen, "duplicate source in %s: %s" % (name, key)
            seen.add(key)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"], "doc_ref not a URL")
            assert "sigma" in r, (name, r["source"], "row missing 'sigma' key")
            if name != "jaql-function":
                assert (r.get("sigma_verified") or {}).get("status") == "n", \
                    (name, r["source"], "unexpected live verification stamp")

    funcs = cats["jaql-function"]
    warning_ids = set()
    for r in funcs.rows:
        assert set(("source", "sigma", "behavior", "warning_id", "doc_ref",
                    "sigma_verified", "on_unmapped", "notes")) <= set(r), r
        assert r["behavior"] in {"safe", "flag", "unsupported"}, r
        assert r["warning_id"].startswith("SISENSE-JAQL-FUNC-"), r
        assert r["warning_id"] not in warning_ids, r["warning_id"]
        warning_ids.add(r["warning_id"])
        sv = r["sigma_verified"]
        assert set(("status", "date", "method")) <= set(sv), (r["source"], sv)
        assert sv["status"] in {"y", "n"}, (r["source"], sv)
        assert sv["method"], (r["source"], sv)
    verified = {r["source"] for r in funcs.rows
                if r["sigma_verified"]["status"] == "y"}
    assert verified == {"SUM", "COUNT"}, verified
    assert all(r["sigma_verified"]["date"] == "2026-06-17"
               for r in funcs.rows if r["source"] in verified)
    assert funcs.resolve("<unknown-function>")["behavior"] == "unsupported"
    print("[ok] catalogs: 6 dimensions load; JAQL function evidence and fallback are explicit")


def test_jaql_catalog_runtime_equality():
    import jaql_expr as J
    rows = json.load(open(os.path.join(CATDIR, "jaql-function.json")))["rows"]
    expected_safe = {
        r["source"].upper(): r["sigma"] for r in rows
        if r["behavior"] == "safe"
    }
    expected_flag = {
        r["source"].upper(): r for r in rows
        if r["behavior"] == "flag"
    }
    assert J.SAFE_FUNC == expected_safe
    assert J.FLAG_FUNC == expected_flag
    assert J.UNKNOWN_FUNC == next(
        r for r in rows if r["source"] == "<unknown-function>")
    print("[ok] JAQL runtime: safe/flag/fallback maps equal catalog rows")


def test_no_inline_maps():
    conv = open(os.path.join(SCRIPTS, "convert.py")).read()
    jaql = open(os.path.join(SCRIPTS, "jaql_expr.py")).read()
    # builders load the catalogs
    assert "coverage_catalog" in conv and "_cc.load(" in conv, "convert.py does not load catalogs"
    assert "coverage_catalog" in jaql and "_cc.load(" in jaql, "jaql_expr.py does not load catalogs"
    # every enumerable map is catalog-derived, not an inline literal
    assert "for r in VIZ_CAT.rows" in conv, "WIDGET_MAP/SIGMA_KIND not derived from viz-kind catalog"
    assert "FMT_CAT.target(" in conv, "MONEY not derived from number-format catalog"
    assert "for r in CTRL_CAT.rows" in conv, "_CTRL_KIND not derived from control catalog"
    assert "for r in _AGG_CAT.rows" in jaql, "AGG not derived from aggregation catalog"
    assert '_cc.load(_CAT_DIR, "jaql-function")' in jaql, \
        "JAQL function catalog is not runtime-loaded"
    assert "for k, r in FUNC_ROWS.items()" in jaql, \
        "SAFE_FUNC/FLAG_FUNC are not derived from JAQL function rows"
    # the killed name-guessing silent default must be gone (code, not prose)
    assert '"Revenue" in (jaql' not in conv, "name-guessing 'Revenue' title guess still present"
    assert '"Cost" in (jaql' not in conv, "name-guessing 'Cost' title guess still present"
    # no residual inline widget map literal (old shape: '"indicator": "kpi-chart"')
    assert '"indicator": "kpi-chart"' not in conv, "residual inline SIGMA_KIND literal"
    assert '"indicator":     ("kpi"' not in conv, "residual inline WIDGET_MAP literal"
    print("[ok] no-inline-map: viz/format/agg/control maps derived from catalogs; "
          "title-substring guess removed")


def test_loud_number_format():
    """The killed silent fallback: currency-by-title guessing is GONE, and a
    non-currency mask now WARNS instead of silently dropping the format."""
    import convert as C
    # a 'Revenue'/'Cost'-titled measure with NO currency mask must NOT get $ format
    assert C._money_fmt({"title": "Total Revenue"}) is None, "title-guess still fabricates $"
    assert C._money_fmt({"title": "Cost of Goods Sold"}) is None, "title-guess still fabricates $"
    # a real currency mask still yields the MONEY format (behavior preserved)
    assert C._money_fmt({"title": "x", "format": {"mask": {"currency": True}}}) == C.MONEY
    # a present-but-non-currency mask -> LOUD warn + ship unformatted
    warns = []
    got = C._money_fmt({"title": "Margin %", "format": {"mask": {"percent": True}}}, warns)
    assert got is None and warns and "non-currency" in warns[0], warns
    print("[ok] loud number-format: title guess removed; non-currency mask warns "
          "(ships unformatted)")


def _live_dashboard():
    dashboards = json.load(open(os.path.join(FIX, "dashboards.json")))
    return copy.deepcopy(next(d for d in dashboards
                              if d.get("title") == "ECommerce Overview (Live)"))


def test_loud_unknown_widget():
    """An unknown Sisense widget type -> flagged, no element (never faked)."""
    import convert as C
    model = json.load(open(os.path.join(FIX, "model_ecommerce.json")))
    d = _live_dashboard()
    ghost = copy.deepcopy(d["widgets"][0])
    ghost.update(type="bloxwidget", title="Weird BloX", oid="ghost-1")
    d["widgets"].append(ghost)
    dm_info = {"dataModelId": "dm-x", "factElementId": "fact-x", "factName": "Commerce"}
    spec, flags = C.convert_dashboard([d], model, dm_info)
    names = [e.get("name") for e in C.code_rep.workbook_elements(spec)]
    assert "Weird BloX" not in names, "unmapped widget silently emitted an element"
    assert any(isinstance(f, dict) and f.get("type") == "bloxwidget" for f in flags), flags
    print("[ok] loud viz-kind: unknown widget 'bloxwidget' flagged, no element emitted")


def test_loud_unknown_agg():
    """An unmapped JAQL agg raises Unsupported (which the converter FLAGS) — never
    a silent default aggregate."""
    import jaql_expr as J
    raised = False
    try:
        J.translate_agg({"dim": "[Commerce.Revenue]", "agg": "sum_distinct"})
    except J.Unsupported as e:
        raised = "sum_distinct" in str(e)
    assert raised, "unmapped agg did not raise Unsupported"
    # sanity: a mapped agg still resolves through the catalog-derived dict
    assert J.translate_agg({"dim": "[Commerce.Revenue]", "agg": "sum"}) == "Sum([Revenue])"
    print("[ok] loud aggregation: unmapped agg 'sum_distinct' raises Unsupported (flagged)")


def test_structured_jaql_warning_ids():
    """The converter must retain catalog warning ids as data, not bury them in
    human-readable reason strings."""
    import convert as C
    model = json.load(open(os.path.join(FIX, "model_ecommerce.json")))
    d = _live_dashboard()
    widget = copy.deepcopy(d["widgets"][0])
    widget["title"] = "Unsupported previous value"
    widget["metadata"]["panels"][0]["items"][0]["jaql"] = {
        "formula": "PREV([m])",
        "context": {
            "[m]": {"dim": "[Commerce.Revenue]", "agg": "sum"}
        },
        "title": "Previous Revenue",
    }
    d["widgets"] = [widget]
    dm_info = {"dataModelId": "dm-x", "factElementId": "fact-x",
               "factName": "Commerce"}
    _spec, flags = C.convert_dashboard([d], model, dm_info)
    match = next(f for f in flags if f.get("field") == "Previous Revenue")
    assert match["warning_id"] == "SISENSE-JAQL-FUNC-PREV", match

    classified = C.classify_dashboard([d])[0]
    assert classified["field_flag_details"] == [{
        "warning_id": "SISENSE-JAQL-FUNC-PREV",
        "reason": classified["field_flags"][0],
    }]
    print("[ok] converter flags: stable JAQL warning ids are structural")


def test_jaql_mapping_docs_match_runtime():
    doc = open(os.path.join(SKILL, "refs", "jaql-mapping.md")).read()
    assert "| `RSUM(...)`            | **Flag**" in doc
    assert "| `PREV(...)` / `PAST`   | **Flag**" in doc
    assert "| `GROWTH`, `GROWTHPAST` | **Flag**" in doc
    assert "`RSUM(...)`            | `CumulativeSum(" not in doc
    assert "`PREV(...)` / `PAST`   | `Lag(" not in doc
    assert "`GROWTH`, `GROWTHPAST` | derived" not in doc
    print("[ok] JAQL docs: PREV/PAST/RSUM/GROWTH flag behavior matches runtime")


def test_coverage_matrix_fresh():
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "gen-coverage-matrix.py"),
         "--catalogs", CATDIR, "--skill", "sisense",
         "--out", os.path.join(SKILL, "refs", "sisense-coverage.md"), "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, ("coverage matrix is stale — regenerate:\n" + r.stderr)
    print("[ok] coverage matrix: refs/sisense-coverage.md matches the catalogs")


if __name__ == "__main__":
    test_catalogs_valid()
    test_jaql_catalog_runtime_equality()
    test_no_inline_maps()
    test_loud_number_format()
    test_loud_unknown_widget()
    test_loud_unknown_agg()
    test_structured_jaql_warning_ids()
    test_jaql_mapping_docs_match_runtime()
    test_coverage_matrix_fresh()
    print("ALL PASS")
