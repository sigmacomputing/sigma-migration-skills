#!/usr/bin/env python3
"""Grounding regression for convert.py ([bead] / microstrategy).

Proves the MicroStrategy dossier classifier is documentation-grounded and
loud-on-unmapped:
  1. CATALOGS      — the JSON catalogs under refs/catalogs/ load, are cited
     (real doc URLs), have unique sources, and name microstrategy as the source.
  2. NO INLINE MAP — the WIRED maps (aggregation FN, number-format, control) are
     LOADED from the catalogs; no residual inline literal bypasses them, and the
     two named silent defaults (name/column-substring format guessing; the
     FN.get(fname, fname.upper()) aggregate passthrough) are GONE.
  3. LOUD FALLBACKS — an unmapped MSTR aggregate function, a metric with no
     explicit MSTR number format (and an explicit-but-unmapped one), and an
     unknown control-bound type each WARN (never a silent wrong default).
  4. COVERAGE MATRIX — refs/microstrategy-coverage.md is regenerated from the
     catalogs (no drift).

No byte-golden: convert.py is deterministic but this pass intentionally CHANGES
format output (the disease cure removes the name-substring guesses), so the
contract is verbatim extraction of the enumerable map + the loud-fallback units
above, plus an end-to-end smoke run on the offline fixture bundle.

Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
CONV = os.path.join(SCRIPTS, "convert.py")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
BUNDLE = os.path.join(SKILL, "fixtures", "bundle.json")
BUNDLE_CHARTS = os.path.join(SKILL, "fixtures", "bundle-charts.json")
AE_WINNERS = os.path.join(SKILL, "fixtures", "ae_winners.json")
COVERAGE = os.path.join(SKILL, "refs", "microstrategy-coverage.md")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))

WIRED_DIMS = {"number-format", "aggregation", "control", "viz-kind",
              "workbook-feature"}


def _new_bundle():
    """A Bundle with __init__ bypassed — enough state for the unit-level
    classifier methods (metric_sql / metric_display_format) without a full
    bundle.json."""
    import convert
    b = convert.Bundle.__new__(convert.Bundle)
    b.warnings = []
    b.metrics = {}
    b.fact_col = {}
    return b


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == WIRED_DIMS, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows, name
        assert cat.source_tool == "microstrategy", (name, cat.source_tool)
        assert cat.authoritative_doc.startswith("http"), (name, cat.authoritative_doc)
        seen = set()
        for r in cat.rows:
            key = str(r["source"]).lower()
            assert key not in seen, "duplicate source in %s: %s" % (name, key)
            seen.add(key)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"])
            assert r.get("sigma") is not None or r.get("no_sigma_equiv") is True, \
                (name, r["source"])
            sv = r.get("sigma_verified") or {}
            assert sv.get("status") in ("y", "n"), (name, r["source"], sv.get("status"))
            assert sv.get("status") != "y" or sv.get("date"), \
                ("live-verified rows must carry a date: %s/%s" % (name, r["source"]))
    # viz-kind is WIRED (bar/line validated; area wired but unverified).
    raw = json.load(open(os.path.join(CATDIR, "viz-kind.json")))
    assert raw.get("wired") is True, "viz-kind.json must be flagged wired:true"
    print("[ok] catalogs: 5 dimensions load, cited, unique sources, valid sigma_verified")


def test_no_inline_maps():
    src = open(CONV).read()
    assert "coverage_catalog" in src and "_cc.load(" in src, "builder does not load catalogs"
    # WIRED maps must be catalog-derived / catalog-resolved, not inline literals
    assert "for r in AGG_CAT.rows" in src, "FN not derived from aggregation catalog"
    assert "AGG_CAT.resolve_or_warn(" in src, "aggregation miss not routed through loud resolver"
    assert "FMT_CAT.resolve_or_warn(" in src, "number-format not resolved via catalog"
    assert "CTRL_CAT.resolve_or_warn(" in src, "control kind not resolved via catalog"
    # viz-kind is now WIRED: loaded + resolved per chapter (chart emission)
    assert '_cc.load(_CAT_DIR, "viz-kind")' in src, "viz-kind must be loaded (now wired)"
    assert '_cc.load(_CAT_DIR, "workbook-feature")' in src, \
        "released workbook features must be cataloged"
    assert "VIZ_CAT.resolve(" in src and "CHART_KINDS" in src, \
        "chapter viz kind must be resolved via VIZ_CAT into chart/table emission"
    assert "FEATURE_CAT.resolve" in src, \
        "released workbook features must resolve through the grounded catalog"
    # the named silent defaults must be GONE (precise code patterns, not prose)
    assert '"Sum": "SUM"' not in src, "inline FN literal still present"
    assert "FN.get(fname, fname.upper())" not in src, "silent aggregate passthrough still present"
    assert 're.search(r"pct' not in src, "name-substring % guess still present"
    assert 're.search(r"REVENUE' not in src, "column-substring $ guess still present"
    print("[ok] no-inline-map: agg/format/control catalog-resolved; name/column guesses removed")


def test_loud_unknown_agg():
    """An unmapped MSTR group function WARNS, then still emits UPPER() SQL as a
    documented degraded fallback (never a silent passthrough)."""
    b = _new_bundle()
    b.metrics = {"m1": {"information": {"name": "Weird Metric"},
                        "expression": {"tokens": [
                            {"type": "function", "value": "Stddev"},
                            {"type": "character", "value": "("},
                            {"type": "object_reference",
                             "target": {"subType": "fact", "objectId": "f1"}},
                            {"type": "character", "value": ")"},
                        ]}}}
    b.fact_col = {"f1": "SOME_COL"}
    sql = b.metric_sql("m1", "FACT")
    assert "STDDEV(FACT.SOME_COL)" in sql, sql
    assert any("aggregation" in w and "Stddev" in w for w in b.warnings), b.warnings
    # a MAPPED function does NOT warn
    b2 = _new_bundle()
    b2.metrics = {"m2": {"information": {"name": "Total"},
                         "expression": {"tokens": [
                             {"type": "function", "value": "Sum"},
                             {"type": "character", "value": "("},
                             {"type": "object_reference",
                              "target": {"subType": "fact", "objectId": "f1"}},
                             {"type": "character", "value": ")"},
                         ]}}}
    b2.fact_col = {"f1": "AMT"}
    assert b2.metric_sql("m2", "F").startswith("SUM("), b2.metric_sql("m2", "F")
    assert not b2.warnings, b2.warnings
    print("[ok] loud agg: unmapped MSTR function -> warn + UPPER() degraded fallback")


def test_loud_unknown_format():
    """No explicit MSTR format -> loud note + None (no name guess). An explicit
    mapped category -> the catalog format. An explicit UNMAPPED category ->
    loud note + None."""
    b = _new_bundle()
    b.metrics = {
        "reserved": {"information": {"name": "Order Count"},
                     "metricFormatType": "reserved",
                     "format": {"header": [], "values": []}},
        "pctname": {"information": {"name": "Profit Margin Pct"},
                    "metricFormatType": "reserved",
                    "format": {"header": [], "values": []}},
        "cur": {"information": {"name": "Revenue"},
                "metricFormatType": "Currency",
                "format": {"header": [], "values": []}},
        "frac": {"information": {"name": "Odd Fmt"},
                 "metricFormatType": "Fraction",
                 "format": {"header": [], "values": []}},
    }
    # reserved (no explicit format) -> loud note, None
    assert b.metric_display_format("reserved") is None
    assert any("no explicit MicroStrategy number format" in w
               and "Order Count" in w for w in b.warnings), b.warnings
    # a metric NAMED "...Pct" no longer triggers a silent % guess
    assert b.metric_display_format("pctname") is None, \
        "name-substring percent guess must be gone"
    # a REAL MSTR format category maps via the catalog
    assert b.metric_display_format("cur") == {"kind": "number", "formatString": "$,.2f"}, \
        b.metric_display_format("cur")
    # an explicit but UNMAPPED category warns loudly and ships unformatted
    n_before = len(b.warnings)
    assert b.metric_display_format("frac") is None
    assert any("number-format" in w and "fraction" in w.lower()
               for w in b.warnings[n_before:]), b.warnings[n_before:]
    print("[ok] loud format: no/unmapped MSTR format -> warn + unformatted; mapped -> catalog format")


def test_control_catalog():
    """Control-bound type resolves to a Sigma control kind via the catalog;
    an unknown kind warns loudly and falls back to the documented default."""
    import convert
    assert convert.CTRL_CAT.target("date") == "date-range"
    assert convert.CTRL_CAT.target("number") == "list"
    assert convert.CTRL_CAT.target("text") == "list"
    warns = []
    assert convert.CTRL_CAT.resolve_or_warn("weird_kind", warns) is None
    assert warns and "control" in warns[0], warns
    print("[ok] control: date->date-range, number/text->list; unknown warns")


def test_coverage_matrix_fresh():
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "gen-coverage-matrix.py"),
         "--catalogs", CATDIR, "--skill", "microstrategy",
         "--out", COVERAGE, "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, ("coverage matrix stale — regenerate:\n" + r.stderr)
    print("[ok] coverage matrix: refs/microstrategy-coverage.md matches the catalogs")


def test_e2e_offline_fixture():
    """End-to-end smoke on the offline fixture bundle: the converter still runs
    deterministically, every metric now ships UNFORMATTED with a LOUD note (the
    fixture carries no explicit MSTR format), and NO guessed format survives."""
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            [sys.executable, CONV, "--bundle", BUNDLE,
             "--connection-id", "conn-x", "--database", "DEMO_DB",
             "--folder-id", "fld-x", "--ae-winners", AE_WINNERS,
             "--out-dm", os.path.join(d, "dm.json"),
             "--out-wb", os.path.join(d, "wb.json"),
             "--out-layout", os.path.join(d, "layout.xml"),
             "--control-scope-out", os.path.join(d, "cs.json")],
            capture_output=True, text=True, cwd=d)
        assert r.returncode == 0, r.stderr
        out = r.stdout + r.stderr
        assert "no explicit MicroStrategy number format" in out, out
        wb = open(os.path.join(d, "wb.json")).read()
        dm = open(os.path.join(d, "dm.json")).read()
        assert "formatString" not in wb and "formatString" not in dm, \
            "a guessed number format survived the disease cure"
        wb_obj = json.loads(wb)
        assert set(wb_obj) >= {"name", "folderId", "document"}, wb_obj.keys()
        doc = wb_obj["document"]
        assert doc.get("kind") == "workbook"
        assert doc.get("layout") and "<Page " in doc["layout"]
        assert "<Element " in doc["layout"] and "<Container " in doc["layout"]
        assert "<LayoutElement" not in doc["layout"]
        assert "<GridContainer" not in doc["layout"]
        assert doc.get("elements") and all("elements" not in p for p in doc["pages"])
        assert doc.get("panels") == [] and doc.get("overlays") == []
        ids = [element["id"] for element in doc["elements"]]
        placed = re.findall(r'\belementId="([^"]+)"', doc["layout"])
        assert sorted(ids) == sorted(placed) and len(placed) == len(set(placed))
        # Data-model code representation deliberately keeps page nesting.
        dm_obj = json.loads(dm)
        assert dm_obj["pages"][0].get("elements") and "document" not in dm_obj
    print("[ok] e2e: fixture builds; metrics ship unformatted + loud; no guessed format")


def test_chart_emission():
    """The wired viz-kind catalog makes a bar_chart/line_chart dossier chapter
    emit the matching Sigma CHART (dim -> xAxis, metrics -> yAxis) instead of a
    table; a grid chapter stays a table. (bundle-charts.json's chart chapters are
    control-free — a chart can't be a list control's value source, so a charted
    chapter WITH a control is kept a table by the ship-safe guard.)"""
    with tempfile.TemporaryDirectory() as d:
        # no --ae-winners: a chart chapter that is ALSO an attribute-element
        # collapse routes through build_ae_page (table) — chart+AE composition is
        # a follow-up, same as chart+control. This matches the LIVE-verified run.
        r = subprocess.run(
            [sys.executable, CONV, "--bundle", BUNDLE_CHARTS,
             "--connection-id", "conn-x", "--database", "DEMO_DB", "--folder-id", "fld-x",
             "--out-wb", os.path.join(d, "wb.json")],
            capture_output=True, text=True, cwd=d)
        assert r.returncode == 0, r.stderr
        wb = json.load(open(os.path.join(d, "wb.json")))
        kinds = {}
        for e in wb["document"]["elements"]:
            if e.get("kind") in ("bar-chart", "line-chart", "area-chart", "table") and e.get("name"):
                kinds[e["name"]] = e
        assert kinds.get("Channel Performance", {}).get("kind") == "bar-chart", kinds
        assert kinds.get("Monthly Revenue Trend", {}).get("kind") == "line-chart", kinds
        assert kinds.get("Revenue by Region and Category", {}).get("kind") == "table", kinds
        # chart yAxis must be metrics only (no DESC-label calc columns)
        bar = kinds["Channel Performance"]
        assert bar.get("xAxis", {}).get("columnId") and bar.get("yAxis", {}).get("columnIds"), bar
        # ship-safe guard code present (chart + control -> table + warn)
        src = open(CONV).read()
        assert "_controlled_chapters" in src, "chart+control ship-safe guard missing"
    print("[ok] chart emission: bar_chart/line_chart -> Sigma chart (dim x, metrics y); grid -> table")


def test_released_workbook_features():
    """Released surfaces emit only from explicit source evidence; box stays gated."""
    import convert
    raw = json.load(open(BUNDLE_CHARTS))
    chapters = raw["dossier"]["chapters"]

    # Waterfall + chart legend + allowlisted literal styling.
    first_viz = chapters[0]["pages"][0]["visualizations"][0]
    first_viz.update({
        "visualizationType": "waterfall",
        "legend": {"visible": True, "position": "bottom"},
        "style": {"backgroundColor": "#112233"},
    })
    chapters[0]["filters"] = []  # keep waterfall chartable (no list-source table needed)
    # Only explicit print intent -> one-row page-break.
    chapters[0]["pages"][0]["pageBreakAfter"] = True
    # Explicit panel stack with concrete visualizations -> tabbed container.
    chapters[0]["pages"][0]["panelStacks"] = [{
        "key": "stack-1",
        "panels": [
            {"key": "panel-1", "name": "Summary", "visualizations": [
                {"key": "panel-viz-1", "name": "Panel Summary",
                 "visualizationType": "grid"}]},
            {"key": "panel-2", "name": "Detail", "visualizations": [
                {"key": "panel-viz-2", "name": "Panel Detail",
                 "visualizationType": "line_chart"}]},
        ],
    }]
    # Selector labels alone do NOT ground released legend/drill controls.
    chapters[1]["pages"][0]["selectors"] = [{
        "key": "legend-selector",
        "name": "Year",
        "selectorType": "legend_selector",
        "source": {"id": "C025482DAE4C4BFDA72E8297D981ABAC"},
        "targets": [{"key": "K121"}],
    }]
    chapters[2]["pages"][0]["selectors"] = [{
        "key": "drill-selector",
        "name": "Order Channel",
        "selectorType": "drill_selector",
        "source": {"id": "E951AA8437BF46BB860E98F0DB349617"},
        "targets": [{"key": "K159"}],
    }]
    chapters[2]["pages"][0]["visualizations"][0]["repeater"] = {
        "field": "Order Channel"}

    with tempfile.TemporaryDirectory() as d:
        bundle = os.path.join(d, "features.json")
        json.dump(raw, open(bundle, "w"))
        wb_path = os.path.join(d, "wb.json")
        gaps_path = os.path.join(d, "gaps.json")
        r = subprocess.run(
            [sys.executable, CONV, "--bundle", bundle,
             "--connection-id", "conn-x", "--database", "DEMO_DB",
             "--folder-id", "fld-x", "--out-wb", wb_path,
             "--feature-gaps-out", gaps_path],
            capture_output=True, text=True, cwd=d)
        assert r.returncode == 0, r.stderr
        wb = json.load(open(wb_path))
        doc = wb["document"]
        elements = doc["elements"]
        by_kind = {}
        for e in elements:
            by_kind.setdefault(e.get("kind"), []).append(e)
        assert by_kind["waterfall-chart"][0]["legend"] == {
            "visibility": "shown", "position": "bottom"}
        assert by_kind["waterfall-chart"][0]["style"]["backgroundColor"] == "#112233"
        assert by_kind["navigation"] and len(by_kind["navigation"]) == len(doc["pages"])
        page_break = by_kind["page-break"][0]
        match = re.search(
            r'elementId="%s"[^>]*gridRow="(\d+) / (\d+)"' %
            re.escape(page_break["id"]), doc["layout"])
        assert match and int(match.group(2)) - int(match.group(1)) == 1
        assert by_kind["tabbed-container"][0]["tabs"] == [
            {"name": "Summary"}, {"name": "Detail"}]
        assert "<TabbedContainer " in doc["layout"]
        assert by_kind["repeated-container"]
        assert any("repeated container/Order Channel" in e.get("body", "")
                   for e in by_kind["text"])
        controls = {e["controlType"] for e in by_kind.get("control", [])}
        assert "legend" not in controls and "drill" not in controls, controls
        ids = [element["id"] for element in elements]
        placed = re.findall(r'\belementId="([^"]+)"', doc["layout"])
        assert sorted(ids) == sorted(placed) and len(placed) == len(set(placed))
        gaps = json.load(open(gaps_path))["gaps"]
        assert any("legend-selector" in gap for gap in gaps), gaps
        assert any("drill-selector" in gap for gap in gaps), gaps

    # Type-only gauge is not enough to invent a value; explicit semantics are.
    assert convert._progress_payload({"visualizationType": "gauge"}) is None
    assert convert._progress_payload({
        "progress": {"value": 72, "min": 0, "max": 100, "mode": "value",
                     "shape": "ring"}}) == {
                         "value": "72", "min": "0", "max": "100",
                         "mode": "value", "shape": "ring"}
    assert convert._progress_payload({"progress": {"value": 72}}) is None

    gauge_raw = json.load(open(BUNDLE_CHARTS))
    gauge_chapter = gauge_raw["dossier"]["chapters"][0]
    gauge_chapter["filters"] = []
    gauge_chapter["pages"][0]["visualizations"][0].update({
        "visualizationType": "gauge",
        "progress": {"value": "Sum([Orders/Total Net Revenue])",
                     "min": 0, "max": 100000, "mode": "value",
                     "shape": "ring"},
    })
    with tempfile.TemporaryDirectory() as d:
        bundle = os.path.join(d, "gauge.json")
        wb_path = os.path.join(d, "gauge-wb.json")
        json.dump(gauge_raw, open(bundle, "w"))
        r = subprocess.run(
            [sys.executable, CONV, "--bundle", bundle,
             "--connection-id", "conn-x", "--database", "DEMO_DB",
             "--folder-id", "fld-x", "--out-wb", wb_path],
            capture_output=True, text=True, cwd=d)
        assert r.returncode == 0, r.stderr
        gauge_elements = json.load(open(wb_path))["document"]["elements"]
        progress = next(e for e in gauge_elements if e.get("kind") == "progress")
        assert progress["value"] == "Sum([Orders/Total Net Revenue])"
        assert progress["min"] == "0" and progress["max"] == "100000"

    # No native box claim without an explicit operator gate.
    row = convert.VIZ_CAT.resolve("box_plot")
    assert row["build"] == "capability-gated"
    print("[ok] released features: waterfall/legend/drill/navigation/tabs/"
          "page-break/progress/panels/styling/repeaters; box gated")


if __name__ == "__main__":
    test_catalogs_valid()
    test_no_inline_maps()
    test_loud_unknown_agg()
    test_loud_unknown_format()
    test_control_catalog()
    test_chart_emission()
    test_released_workbook_features()
    test_coverage_matrix_fresh()
    test_e2e_offline_fixture()
    print("ALL PASS")
