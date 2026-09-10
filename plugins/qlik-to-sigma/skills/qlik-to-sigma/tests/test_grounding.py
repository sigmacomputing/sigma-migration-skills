#!/usr/bin/env python3
"""Grounding regression for build-sigma-workbook.py ([bead]).

  1. GOLDEN LOCK   — the fixture builds byte-identical to the committed golden
     (build-sigma-workbook.py uses a deterministic id counter, no randomness).
  2. CATALOGS      — every refs/catalogs/*.json loads, cited, unique rows.
  3. NO INLINE MAP — viz/aggregation/control maps LOADED from the catalogs; the
     name-substring currency guess + silent ,.0f default are gone.
  4. FORMAT PARSER — sigma_fmt() reproduces every pinned qNumFormat example in
     number-format.json (parser grounded to documented Qlik semantics).
  5. LOUD FALLBACKS — an unknown vizType warns+skips; an absent qFmt ships the
     value unformatted + a loud note (no name-substring guess, no silent default).
  6. NO-DRIFT      — refs/qlik-coverage.md is regenerated from the catalogs.

Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import importlib.util, json, os, pathlib, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "retail-orders")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
GOLDEN = os.path.join(HERE, "golden", "retail_orders_workbook.spec.json")
BUILDER = os.path.join(SCRIPTS, "build-sigma-workbook.py")
CONVERTER = os.path.join(SKILL, "converter", "qlik.mjs")
NORMALIZER = os.path.join(SCRIPTS, "normalize-qlik-expressions.py")
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))


def _load_builder():
    spec = importlib.util.spec_from_file_location("bsw", BUILDER)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _build(charts=None, denorm=None):
    with tempfile.TemporaryDirectory() as d:
        charts = charts or os.path.join(FIX, "charts.json")
        denorm = denorm or os.path.join(FIX, "denorm.json")
        spec_out = os.path.join(d, "spec.json")
        r = subprocess.run(
            [sys.executable, BUILDER, "--charts", charts, "--layout", os.path.join(FIX, "layout.json"),
             "--denorm", denorm, "--dm-id", "dm-x", "--denorm-element-id", "el-x", "--name", "GOLDEN",
             "--dry-run", "--spec-out", spec_out, "--out", os.path.join(d, "res.json"),
             "--element-map", os.path.join(d, "emap.json"), "--layout-out", os.path.join(d, "l.xml")],
            capture_output=True, text=True)
        assert r.returncode == 0, "builder failed:\n" + r.stderr
        return json.load(open(spec_out)), (r.stdout + r.stderr)


def test_golden():
    spec, _ = _build()
    layout = spec["document"]["layout"]
    assert "<Element " in layout and "<Container " in layout
    assert "<LayoutElement" not in layout and "<GridContainer" not in layout
    got = json.dumps(spec, indent=2)
    want = open(GOLDEN).read()
    assert got == want, "GOLDEN DRIFT — build-sigma-workbook output changed on the fixture."
    print("[ok] golden: fixture builds byte-identical to committed golden")


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == {
        "viz-kind", "number-format", "aggregation", "scalar-function",
        "control", "workbook-feature"
    }, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows and cat.source_tool == "qlik", name
        seen = set()
        for r in cat.rows:
            k = str(r["source"]).lower()
            assert k not in seen, ("dup source in %s: %s" % (name, k)); seen.add(k)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"])
    scalar = cats["scalar-function"]
    required = {
        "row_concat_&", "index", "substringcount", "dual", "minstring",
        "maxstring", "concat", "only", "<unknown-function>",
    }
    assert required <= set(scalar.sources()), sorted(required - set(scalar.sources()))
    for row in scalar.rows:
        assert row.get("translation_status") in {
            "exact", "approximated", "needs-review"
        }, row["source"]
        assert row.get("action") in {"direct", "rename", "remove"}, row["source"]
    assert scalar.resolve("row_concat_&")["translation_status"] == "exact"
    assert scalar.resolve("Concat")["translation_status"] == "needs-review"
    print("[ok] catalogs: 6 dimensions load; scalar risk rows are explicit and cited")


def test_no_inline_maps():
    src = open(BUILDER).read()
    assert "coverage_catalog" in src and "_cc.load(" in src, "builder does not load catalogs"
    assert "for r in VIZ_CAT.rows" in src, "NATIVE not derived from viz-kind catalog"
    assert "_AGG_ALT" in src and "AGG_CAT.rows" in src, "aggregation not catalog-derived"
    assert "CTRL_CAT.target(" in src, "control kind not catalog-derived"
    # the name-substring currency guess + silent default must be gone
    assert "revenue|profit|amount|value|cost|price" not in src, "name-substring currency guess still present"
    assert 'return {"kind": "number", "formatString": ",.0f"}' not in src, "silent ,.0f default still present"
    print("[ok] no-inline-map: maps catalog-derived; name-guess + silent default removed")


def test_format_parser_pinned():
    m = _load_builder()
    cat = json.load(open(os.path.join(CATDIR, "number-format.json")))
    for r in cat["rows"]:
        got = (m.sigma_fmt(r["source"]) or {}).get("formatString")
        assert got == r["sigma"], ("qFmt %r -> %r, catalog says %r" % (r["source"], got, r["sigma"]))
    print("[ok] format parser: reproduces all %d pinned qNumFormat examples" % len(cat["rows"]))


def test_loud_no_qfmt_format():
    m = _load_builder()
    # a revenue-named measure with NO qFmt used to name-guess $,.0f; now None + warn
    w = []
    assert m.sigma_fmt(None, "Net Revenue", w) is None, "absent qFmt must yield no format"
    assert w and "UNFORMATTED" in w[0], w
    assert m.sigma_fmt(None, "Total Profit") is None, "no name-substring currency guess allowed"
    # a real qFmt still parses
    assert m.sigma_fmt("$#,##0")["formatString"] == "$,.0f"
    print("[ok] loud format: absent qFmt -> None + warn (no name guess, no silent default)")


def test_loud_unknown_viz():
    # mutate an EXISTING (layout-referenced) chart's vizType to an unmapped one so
    # it is actually placed + classified — an appended chart absent from layout.json
    # is never built.
    charts = json.load(open(os.path.join(FIX, "charts.json")))
    placed = {"c-cat", "c-seg", "c-mon", "c-tbl"}  # ids referenced by layout.json
    hit = next(i for i, c in enumerate(charts) if c["id"] in placed)
    charts[hit] = json.loads(json.dumps(charts[hit]))
    charts[hit]["vizType"] = "sankey"
    with tempfile.TemporaryDirectory() as d:
        cpath = os.path.join(d, "charts.json"); json.dump(charts, open(cpath, "w"))
        spec, out = _build(charts=cpath)
    assert "sankey" in out and ("no native Sigma kind" in out or "approximated" in out), out
    print("[ok] loud viz: unmapped vizType 'sankey' warns (approximated/skipped, not silent)")


def test_coverage_matrix_fresh():
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "gen-coverage-matrix.py"),
         "--catalogs", CATDIR, "--skill", "qlik",
         "--out", os.path.join(SKILL, "refs", "qlik-coverage.md"), "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, ("coverage matrix stale — regenerate:\n" + r.stderr)
    print("[ok] coverage matrix: refs/qlik-coverage.md matches the catalogs")


def _run_actual_converter(input_path, output_path):
    module_uri = pathlib.Path(CONVERTER).as_uri()
    js = """
import fs from "node:fs";
import { convertQlikToSigma } from %s;
const input = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const output = convertQlikToSigma(input, {
  connectionId: "connection-x", database: "DB", schema: "SCHEMA"
});
fs.writeFileSync(process.argv[2], JSON.stringify(output, null, 2) + "\\n");
""" % json.dumps(module_uri)
    result = subprocess.run(
        ["node", "--input-type=module", "-e", js, input_path, output_path],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, "actual converter failed:\n" + result.stderr


def _run_normalizer(input_path, converter_path, output_path, mapping_path):
    result = subprocess.run(
        [
            sys.executable, NORMALIZER,
            "--input", input_path,
            "--converter-out", converter_path,
            "--out", output_path,
            "--formula-mapping", mapping_path,
        ],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, "normalizer failed:\n" + result.stderr


def _named_formulas(output):
    result = {}
    for page in output["model"]["pages"]:
        for element in page.get("elements", []):
            for item in element.get("metrics", []) + element.get("columns", []):
                if item.get("name"):
                    result[item["name"]] = item.get("formula")
    return result


def test_scalar_actual_converter_path():
    """Exercise the vendored convertQlikToSigma bundle, then the normalizer."""
    source = {
        "appName": "Scalar grounding",
        "tables": [{
            "name": "Facts",
            "fields": [
                {"name": "NAME"}, {"name": "CODE"}, {"name": "AMOUNT"},
                {"name": "ORDER_DATE"},
            ],
        }],
        "masterMeasures": [
            {"title": "Distinct Codes", "qDef": "Count(DISTINCT CODE)"},
            {"title": "Aggregate Concat", "qDef": "Concat(NAME, ',')"},
            {"title": "Only Name", "qDef": "Only(NAME)"},
            {"title": "Minimum String", "qDef": "MinString(NAME)"},
        ],
        "masterDimensions": [
            {"title": "Upper Name", "qFieldDef": "=Upper(NAME)"},
            {"title": "Left Name", "qFieldDef": "=Left(NAME, 2)"},
            {"title": "Indexed Name", "qFieldDef": "=Index(NAME, 'x')"},
            {"title": "Literal Dot Count", "qFieldDef": "=SubStringCount(NAME, '.')"},
            {"title": "Order Year", "qFieldDef": "=Year(ORDER_DATE)"},
            {"title": "Order Month", "qFieldDef": "=Month(ORDER_DATE)"},
            {"title": "Order Day", "qFieldDef": "=Day(ORDER_DATE)"},
            {"title": "Row Concat", "qFieldDef": "=NAME & CODE"},
            {"title": "Dual Name", "qFieldDef": "=Dual(NAME, AMOUNT)"},
            {"title": "Unknown Call", "qFieldDef": "=Mystery(NAME)"},
        ],
    }
    with tempfile.TemporaryDirectory() as directory:
        input_path = os.path.join(directory, "converter-input.json")
        raw_path = os.path.join(directory, "converter-out.json")
        patched_path = os.path.join(directory, "patched.json")
        mapping_path = os.path.join(directory, "formula-mapping.json")
        patched2_path = os.path.join(directory, "patched-2.json")
        mapping2_path = os.path.join(directory, "formula-mapping-2.json")
        with open(input_path, "w", encoding="utf-8") as handle:
            json.dump(source, handle)
        _run_actual_converter(input_path, raw_path)

        raw_formulas = _named_formulas(json.load(open(raw_path)))
        # These assertions prove the test traverses the actual problematic bundle
        # path instead of testing only a hand-authored converter-out fixture.
        assert raw_formulas["Distinct Codes"] == "Count(DISTINCT [Code])"
        assert raw_formulas["Indexed Name"].startswith("IndexOf(")
        assert raw_formulas["Literal Dot Count"].startswith("RegexpCount(")
        assert raw_formulas["Aggregate Concat"].startswith("ListAgg(")
        assert raw_formulas["Dual Name"] == "[Amount]"
        assert raw_formulas["Unknown Call"].startswith("Mystery(")

        _run_normalizer(input_path, raw_path, patched_path, mapping_path)
        _run_normalizer(input_path, raw_path, patched2_path, mapping2_path)
        assert open(patched_path, "rb").read() == open(patched2_path, "rb").read()
        assert open(mapping_path, "rb").read() == open(mapping2_path, "rb").read()
        expected_patched = open(patched_path, "rb").read()
        expected_mapping = open(mapping_path, "rb").read()
        workdir_result = subprocess.run(
            [sys.executable, NORMALIZER, "--workdir", directory],
            capture_output=True, text=True,
        )
        assert workdir_result.returncode == 0, workdir_result.stderr
        assert open(raw_path, "rb").read() == expected_patched
        assert open(mapping_path, "rb").read() == expected_mapping

        patched = json.load(open(patched_path))
        mapping = json.load(open(mapping_path))
        formulas = _named_formulas(patched)
        rows = {row["name"]: row for row in mapping["formulas"]}

    assert formulas["Distinct Codes"] == "CountDistinct([Code])"
    assert rows["Distinct Codes"]["status"] == "exact"
    assert formulas["Upper Name"] == "Upper([Name])"
    assert formulas["Left Name"] == "Left([Name], 2)"
    assert rows["Upper Name"]["status"] == rows["Left Name"]["status"] == "exact"
    assert formulas["Order Year"] == "Year([Order Date])"
    assert formulas["Order Day"] == "Day([Order Date])"
    assert rows["Order Month"]["status"] == "approximated"
    assert rows["Order Month"]["warningIds"]
    assert formulas["Row Concat"] == "[Name] & [Code]"
    assert rows["Row Concat"]["status"] == "exact"

    removed = {
        "Indexed Name": "QLIK-SCALAR-INDEX-BASE",
        "Literal Dot Count": "QLIK-SCALAR-LITERAL-VS-REGEX",
        "Aggregate Concat": "QLIK-SCALAR-AGG-CONCAT-CONTEXT",
        "Only Name": "QLIK-SCALAR-ONLY-CARDINALITY",
        "Minimum String": "QLIK-SCALAR-STRING-AGG-SEMANTICS",
        "Dual Name": "QLIK-SCALAR-DUAL-TEXT-LOSS",
        "Unknown Call": "QLIK-SCALAR-UNKNOWN-FUNCTION",
    }
    for name, warning_code in removed.items():
        assert name not in formulas, "%s must not survive in patched output" % name
        assert rows[name]["status"] == "needs-review", rows[name]
        assert rows[name]["sigmaFormula"] is None
        assert any(warning_code in warning_id for warning_id in rows[name]["warningIds"])
    assert mapping["summary"] == {
        "exact": 6, "approximated": 1, "needs-review": 7, "skipped": 0
    }
    assert all(row["provenance"]["catalog"].endswith("scalar-function.json")
               for row in mapping["formulas"])
    assert all(warning["evidence"] and warning["provenance"]
               for warning in mapping["warnings"])
    assert any("QLIK-SCALAR-UNKNOWN-FUNCTION" in warning
               for warning in patched["warnings"])
    print("[ok] scalar grounding: actual converter path is normalized fail-closed")


def test_retail_count_distinct_golden():
    """The only committed output drift is the proven-safe CountDistinct form."""
    converter_input = os.path.join(FIX, "converter-input.json")
    committed_output = os.path.join(FIX, "converter-out.json")
    corpus_golden = os.path.normpath(os.path.join(
        SKILL, "..", "..", "..", "..", "corpus", "qlik",
        "exec-overview-smoke", "golden", "data-model.json"
    ))
    with tempfile.TemporaryDirectory() as directory:
        patched_path = os.path.join(directory, "patched.json")
        mapping_path = os.path.join(directory, "formula-mapping.json")
        _run_normalizer(
            converter_input, committed_output, patched_path, mapping_path
        )
        assert json.load(open(patched_path)) == json.load(open(committed_output))
        mapping = json.load(open(mapping_path))
        assert mapping["summary"] == {
            "exact": 13, "approximated": 0, "needs-review": 0, "skipped": 0
        }
    for path in (committed_output, corpus_golden):
        text = open(path, encoding="utf-8").read()
        assert "Count(DISTINCT [Order Id])" not in text, path
        assert text.count("CountDistinct([Order Id])") == 2, path
    print("[ok] retail golden: safe CountDistinct normalization is pinned")


def _build_scope(charts_path, synth="auto"):
    """Build with a control-scope sidecar + a --synth-controls mode; return (spec, scope)."""
    with tempfile.TemporaryDirectory() as d:
        spec_out = os.path.join(d, "spec.json"); cs = os.path.join(d, "control-scope.json")
        r = subprocess.run(
            [sys.executable, BUILDER, "--charts", charts_path, "--layout", os.path.join(FIX, "layout.json"),
             "--denorm", os.path.join(FIX, "denorm.json"), "--dm-id", "dm-x", "--denorm-element-id", "el-x",
             "--name", "T", "--dry-run", "--synth-controls", synth,
             "--spec-out", spec_out, "--out", os.path.join(d, "res.json"),
             "--element-map", os.path.join(d, "emap.json"), "--layout-out", os.path.join(d, "l.xml"),
             "--control-scope-out", cs],
            capture_output=True, text=True)
        assert r.returncode == 0, "builder failed:\n" + r.stderr
        return json.load(open(spec_out)), json.load(open(cs))


def _filterless_charts(d):
    """Fixture charts with every filterpane/listbox removed — a Qlik app that
    relied on pure associative click-filtering (the synth-controls gap)."""
    kept = [c for c in json.load(open(os.path.join(FIX, "charts.json")))
            if c.get("vizType") not in ("filterpane", "listbox")]
    p = os.path.join(d, "charts_nofilter.json"); json.dump(kept, open(p, "w"))
    return p


def test_synth_fills_filterless_app():
    with tempfile.TemporaryDirectory() as d:
        spec, scope = _build_scope(_filterless_charts(d), synth="auto")
    assert scope["sourceFilterSignals"] == 0, "no source filters expected"
    assert scope["synthesizedCount"] > 0, "auto must synthesize a control bar when the app has no filters"
    assert any(c.get("synthesized") for c in scope["controls"]), "expected synthesized scope entries"
    for e in (el for el in spec["document"]["elements"] if el.get("kind") == "control"):
        tgt = (e.get("filters") or [{}])[0].get("source", {})
        assert tgt.get("elementId") == "m-master", f"{e.get('controlId')} must filter the shared master"
    assert not any(c["controlId"].upper().endswith(("KEYFILTER", "IDFILTER"))
                   for c in scope["controls"] if c.get("synthesized")), "never synthesize a join/id key"
    print("[ok] synth-controls: filterless app gets a master-filtering control bar")


def test_synth_noop_when_filters_present():
    _, scope = _build_scope(os.path.join(FIX, "charts.json"), synth="auto")
    assert scope["sourceFilterSignals"] > 0
    assert scope["synthesizedCount"] == 0, "auto must NOT synthesize when real filters exist (no regression)"
    print("[ok] synth-controls: auto no-ops when real filters exist (golden safe)")


def test_synth_all_tops_up_and_dedupes():
    _, scope = _build_scope(os.path.join(FIX, "charts.json"), synth="all")
    assert scope["synthesizedCount"] > 0, "all must top up"
    ids = [c["controlId"] for c in scope["controls"]]
    assert len(ids) == len(set(ids)), "controlIds must be unique (synth dedupes against real fields)"
    assert any(not c.get("synthesized") for c in scope["controls"]), "real controls must remain alongside synth"
    print("[ok] synth-controls: --all tops up + dedupes against real filters")


if __name__ == "__main__":
    test_catalogs_valid()
    test_no_inline_maps()
    test_format_parser_pinned()
    test_loud_no_qfmt_format()
    test_loud_unknown_viz()
    test_coverage_matrix_fresh()
    test_scalar_actual_converter_path()
    test_retail_count_distinct_golden()
    test_synth_fills_filterless_app()
    test_synth_noop_when_filters_present()
    test_synth_all_tops_up_and_dedupes()
    test_golden()
    print("ALL PASS")
