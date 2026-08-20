#!/usr/bin/env python3
"""Grounding regression for the GoodData->Sigma dashboard classifier ([bead]).

Proves the insight/aggregation classifier is documentation-grounded and loud-on-unmapped:
  1. CATALOGS      — all five refs/catalogs/*.json load, are cited (real http doc refs),
     and have unique source keys. viz-kind FLAGGED rows (sigma:null) are allowed only
     when on_unmapped == "flag".
  2. NO INLINE MAP — the viz (CHART/FLAGGED) and aggregation (AGG) maps are LOADED from
     the catalogs in BOTH build_workbook.py AND maql.py; no residual inline dict literal
     bypasses the single source of truth, and the two AGG copies are byte-equal at runtime
     (the duplicate maql.py/build_workbook.py hardcodes are deduped).
  3. LOUD FALLBACKS — a FLAGGED GoodData viz type and a truly-unknown visualizationUrl each
     WARN (a printed FLAG) and produce NO element — never a silent wrong default / guess.
  4. COVERAGE FRESH — refs/gooddata-coverage.md is regenerated from the catalogs (no drift).

No byte-golden: the builder is deterministic but this pass changes no behavior on already-
mapped inputs (verified separately), so verbatim catalog extraction + these unit checks
suffice. Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import copy, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
FIXTURE = os.path.join(SKILL, "fixtures", "test_workspace_orders.json")
BUILDER = os.path.join(SCRIPTS, "build_workbook.py")
MAQL = os.path.join(SCRIPTS, "maql.py")
COVERAGE_HELPER = os.path.join(HERE, "gooddata_coverage.py")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))

EXPECT_DIMS = {
    "viz-kind", "number-format", "aggregation", "control",
    "workbook-feature",
}


def _run_builder(workspace_path):
    """Run build_workbook.py on a workspace json; return (spec, combined_output)."""
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "wb.json")
        r = subprocess.run(
            [sys.executable, BUILDER, "--workspace", workspace_path,
             "--data-model-id", "dm-x", "--fact-element", "el-x",
             "--fact-name", "ORDER_FACT", "--rel-name", "EL_CUSTOMER",
             "--fact-dataset", "order", "--folder-id", "fld-x", "--out", out],
            capture_output=True, text=True)
        assert r.returncode == 0, "build_workbook failed:\n" + r.stderr
        return json.load(open(out)), (r.stdout + r.stderr)


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == EXPECT_DIMS, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows, name
        assert cat.source_tool == "gooddata", (name, cat.source_tool)
        assert cat.authoritative_doc.startswith("http"), (name, cat.authoritative_doc)
        seen = set()
        for r in cat.rows:
            key = str(r["source"]).lower()
            assert key not in seen, ("duplicate source in %s: %s" % (name, key))
            seen.add(key)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"])
            # a mapped Sigma target must be present, OR the row is an explicit
            # flag row (viz-kind types with no faithful Sigma equivalent).
            assert r.get("sigma") is not None or r.get("on_unmapped") == "flag", \
                (name, r["source"], "null sigma without on_unmapped:flag")
    print("[ok] catalogs: 5 dimensions load, cited (http), unique sources")


def test_no_inline_maps():
    src = open(BUILDER).read()
    mql = open(MAQL).read()
    # builders LOAD the catalogs
    assert "coverage_catalog" in src and "_cc.load(" in src, "build_workbook does not load catalogs"
    assert '_cc.load(_CAT_DIR, "workbook-feature")' in src, \
        "build_workbook does not load the released feature catalog"
    assert "coverage_catalog" in mql and "_cc.load(" in mql, "maql.py does not load the aggregation catalog"
    # the viz + agg maps are catalog-DERIVED, not inline literals
    assert "for r in VIZ_CAT.rows" in src, "CHART/FLAGGED not derived from viz-kind catalog"
    assert "for r in AGG_CAT.rows" in src, "AGG not derived from aggregation catalog"
    assert "_AGG_CAT.rows" in mql, "maql AGG not derived from aggregation catalog"
    # the old inline literals must be GONE from both files
    assert '"local:bar": "bar-chart"' not in src, "inline CHART literal still present in build_workbook"
    assert '"local:funnel", "local:pyramid"' not in src, "inline FLAGGED literal still present in build_workbook"
    assert '{"SUM": "Sum"' not in src, "inline AGG literal still present in build_workbook"
    assert '{"SUM": "Sum"' not in mql, "inline AGG literal still present in maql.py"
    # the two AGG copies must be identical at runtime (dedup: single source of truth)
    import build_workbook as bw
    import maql
    assert bw.AGG == maql.AGG, ("AGG copies drifted", bw.AGG, maql.AGG)
    for k, v in {"SUM": "Sum", "AVG": "Avg", "MIN": "Min", "MAX": "Max", "MEDIAN": "Median"}.items():
        assert bw.AGG[k] == v, ("AGG scalar mapping changed", k, bw.AGG.get(k))
    print("[ok] no-inline-map: CHART/FLAGGED/AGG loaded from catalogs; the duplicate AGG hardcode is deduped")


def test_loud_flagged_and_unknown_viz():
    """A FLAGGED GoodData viz type and a truly-unknown visualizationUrl each WARN + skip."""
    ws = json.load(open(FIXTURE))
    ws = copy.deepcopy(ws)
    ws["analytics"]["visualizationObjects"] = [
        {"id": "fun1", "title": "Conversion Funnel",
         "content": {"visualizationUrl": "local:funnel", "buckets": []}},
        {"id": "unk1", "title": "Mystery Widget",
         "content": {"visualizationUrl": "local:xyz_unknown", "buckets": []}},
    ]
    with tempfile.TemporaryDirectory() as d:
        wp = os.path.join(d, "ws.json")
        json.dump(ws, open(wp, "w"))
        spec, out = _run_builder(wp)
    # FLAGGED type -> loud flag naming the type + "no Sigma equivalent"
    assert "local:funnel" in out and "no Sigma equivalent" in out, out
    # unknown url -> loud "unmapped visualizationUrl" flag
    assert "local:xyz_unknown" in out and "unmapped visualizationUrl" in out, out
    # neither flagged insight produced a workbook element (no silent emit)
    names = re.findall(r'"name":\s*"([^"]*)"', json.dumps(spec))
    assert "Conversion Funnel" not in names, "flagged funnel was silently emitted as an element"
    assert "Mystery Widget" not in names, "unknown viz was silently emitted as an element"
    print("[ok] loud viz: FLAGGED 'local:funnel' + unknown 'local:xyz_unknown' both warn + skip")


def test_coverage_matrix_fresh():
    """refs/gooddata-coverage.md must be regenerated from the catalogs (no drift)."""
    coverage_path = os.path.join(SKILL, "refs", "gooddata-coverage.md")
    r = subprocess.run(
        [sys.executable, COVERAGE_HELPER, "--catalogs", CATDIR,
         "--out", coverage_path, "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, ("coverage matrix is stale — regenerate:\n" + r.stdout + r.stderr)
    coverage = open(coverage_path).read()
    assert "## Released workbook features" in coverage
    assert coverage.index("## Control / filter") < \
        coverage.index("## Released workbook features")
    print("[ok] coverage matrix: refs/gooddata-coverage.md matches the catalogs")


if __name__ == "__main__":
    test_catalogs_valid()
    test_no_inline_maps()
    test_loud_flagged_and_unknown_viz()
    test_coverage_matrix_fresh()
    print("ALL PASS")
