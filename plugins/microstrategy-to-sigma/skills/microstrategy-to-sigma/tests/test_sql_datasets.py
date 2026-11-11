#!/usr/bin/env python3
"""Offline regression for freeform-SQL ("hand-written SQL") MicroStrategy datasets:
scripts/lib/sql_dataset.py, scripts/extract-sql-dataset.py,
scripts/convert-sql-datasets.py, and the extract.py / convert.py hooks.

Every MicroStrategy response used here is SYNTHETIC (shaped from the REST docs,
not captured live); nothing in this file proves live endpoint behavior.

  1. SELECT ALIASES — final top-level select list: CTEs, TOP, comments, bracket /
     quoted identifiers, AS / bare / dotted aliases, commas inside strings; `*` -> None.
  2. COLUMN MATCHING — object names, "<attr> <form>", DESC -> bare attribute, ambiguity.
  3. SQL GUARD — shared with convert.py --multi-fact-sql; message text unchanged.
  4. CAPTURE — resolve_prompts SQL, never executes unless allowed, sqlView fallback,
     prompts endpoint fallback, raw responses kept.
  5. EXTRACT — extract() routes a freeform dataset into bundle["sqlDatasets"].
  6. CONVERT — golden DM + gaps, column-map precedence, loud blocking gaps, exit codes;
     convert.py refuses a bundle that carries sqlDatasets.

Run: python3 tests/test_sql_datasets.py   (exit 0 = pass)
Regenerate goldens after an intended change: add --update-golden.
"""
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))
FIXTURE = os.path.join(SKILL, "fixtures", "sql-datasets", "desk-coverage-pnl.sql-datasets.json")
GOLDEN_DIR = os.path.join(SKILL, "fixtures", "sql-datasets", "golden")
CONN = "00000000-0000-0000-0000-000000000000"
FOLDER = "11111111-1111-1111-1111-111111111111"

import sql_dataset as sd  # noqa: E402


def load_script(filename, modname):
    spec = importlib.util.spec_from_file_location(modname, os.path.join(SCRIPTS, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- 1. select_aliases
def test_select_aliases():
    f = sd.select_aliases
    assert f("SELECT a, b AS bee, c cee FROM t") == ["a", "bee", "cee"]
    # CTE + TOP + comments + bracket aliases (the SQL-Server shape)
    sql = """-- lead comment, with comma
    WITH x AS (SELECT 1 AS one, 2 AS two FROM dbo.t /* ( unbalanced */),
         y AS (SELECT one FROM x)
    SELECT TOP 1000 x.one AS [Desk ID], y.one [Desk Name], SUM(x.two) AS "Total, PnL"
    FROM x JOIN y ON 1 = 1"""
    assert f(sql) == ["Desk ID", "Desk Name", "Total, PnL"], f(sql)
    assert f("SELECT DISTINCT TOP (5) PERCENT t.col_a, `b c` FROM t") == ["col_a", "b c"]
    assert f("SELECT ALL a FROM t") == ["a"]
    # dotted bare column -> last segment, quoted segments stripped
    assert f('SELECT s.t.col, s."T"."My Col", d.[x y] FROM s.t') == ["col", "My Col", "x y"]
    # commas inside strings / function calls / CASE do not split; END alias handling
    sql = ("SELECT COALESCE(a, 'x, y') AS lbl, CASE WHEN a = 1 THEN 'a,b' ELSE 'c' END grp, "
           "CAST(b AS INT) AS n FROM t")
    assert f(sql) == ["lbl", "grp", "n"], f(sql)
    # a string literal containing keywords/parens/comment markers is opaque
    assert f("SELECT 'FROM -- (' AS s, a FROM t") == ["s", "a"]
    # expression aliased by a trailing quoted identifier (no AS)
    assert f('SELECT SUM(a) "Total" FROM t') == ["Total"]
    # select without FROM
    assert f("SELECT 1 AS one, 'x' AS two") == ["one", "two"]
    # not derivable -> None
    assert f("SELECT * FROM t") is None
    assert f("SELECT t.*, a FROM t") is None
    assert f("SELECT a, b + c FROM t") is None            # unnamed expression
    assert f("SELECT COUNT(*) FROM t") is None
    assert f("not sql at all") is None
    assert f("") is None
    # COUNT(*) with an alias is fine (star is inside parens)
    assert f("SELECT COUNT(*) AS n FROM t") == ["n"]
    print("[ok] select_aliases: CTE/TOP/comments/quoting/AS/bare/dotted; '*' and unnamed -> None")


# ---------------------------------------------------------------- 2. match_columns
def _obj(kind, name, form=None):
    o = {"kind": kind, "id": name.lower().replace(" ", "-"), "name": name, "dataType": "varchar"}
    if kind == "attribute":
        o["form"] = form
    return o


def test_match_columns():
    desk_id, desk_desc = _obj("attribute", "Desk", "ID"), _obj("attribute", "Desk", "DESC")
    cov = _obj("attribute", "Coverage", "DESC")
    code = _obj("attribute", "Coverage", "CODE")
    pnl = _obj("metric", "Total PnL")
    objs = [desk_id, desk_desc, code, pnl]
    mapping, unmatched, unused = sd.match_columns(
        ["desk_id", "DESK", "Coverage-Code", "total_pnl", "spare"], objs)
    assert mapping == {"desk_id": desk_id, "DESK": desk_desc, "Coverage-Code": code,
                       "total_pnl": pnl}, mapping
    assert unmatched == [] and unused == ["spare"], (unmatched, unused)
    # "<attr>_<form>" and "<attr> <form>" both match; ID form matches "<attr> id"
    m, _, _ = sd.match_columns(["Desk_DESC", "Desk Id"], [desk_desc, desk_id])
    assert m == {"Desk_DESC": desk_desc, "Desk Id": desk_id}, m
    # a sole-form attribute matches its bare name; with several forms only DESC does
    m, un, _ = sd.match_columns(["Coverage"], [cov])
    assert m == {"Coverage": cov} and un == []
    m, un, _ = sd.match_columns(["Coverage"], [code, _obj("attribute", "Coverage", "ID")])
    assert m == {} and len(un) == 2, (m, un)
    # ambiguous: two aliases normalize to the same name -> unmatched, both unused
    m, un, unused = sd.match_columns(["Total PnL", "total_pnl"], [pnl])
    assert m == {} and un == [pnl] and unused == ["Total PnL", "total_pnl"], (m, un, unused)
    # ambiguous: two objects claim one alias (metric vs attribute DESC) -> both unmatched
    clash = _obj("metric", "Desk")
    m, un, unused = sd.match_columns(["Desk"], [desk_desc, clash])
    assert m == {} and set(map(id, un)) == {id(desk_desc), id(clash)} and unused == ["Desk"]
    print("[ok] match_columns: name forms, DESC/bare, ID, ambiguity -> unmatched")


# ---------------------------------------------------------------- 3. guard_sql
def _exit_message(fn, *args):
    try:
        fn(*args)
    except SystemExit as e:
        return str(e.code)
    raise AssertionError("expected SystemExit")


def test_guard_sql():
    g = sd.guard_sql
    assert g("  SELECT 1 ;  ", "x") == "SELECT 1"
    assert g("with a as (select 1) select * from a", "x").startswith("with")
    assert _exit_message(g, "  ;", "--flag") == "--flag is empty"
    assert _exit_message(g, "select 1; select 2", "--flag") == (
        "--flag must contain one SELECT/CTE statement; "
        "multi-step or volatile-table plans are not accepted")
    assert _exit_message(g, "update t set a=1", "--flag") == "--flag must start with SELECT or WITH"
    assert _exit_message(g, "select 1 from t where x in (delete from y)", "--flag") == (
        "--flag must be a read-only single query; found 'delete from'")
    assert "unresolved placeholder" in _exit_message(g, "select '{{p}}'", "--flag")
    # leading comments are not part of the statement the guard sees
    f = sd.strip_leading_comments
    assert f("-- a; b\n/* c; */ -- d\n  SELECT 1 -- tail") == "SELECT 1 -- tail"
    assert f("SELECT '--x' /* y */") == "SELECT '--x' /* y */"
    assert f("/* unterminated") == ""
    print("[ok] guard_sql: empty / multi-statement / DDL-DML / placeholder messages; leading comments")


# ---------------------------------------------------------------- 4. capture
class FakeSession:
    """Routes (method, path) -> value or exception; records every call.
    Unknown paths raise RuntimeError like mstr.Session does on an HTTP error."""

    def __init__(self, routes):
        self.routes, self.calls = routes, []

    def _do(self, method, path, body=None):
        self.calls.append((method, path, body))
        if (method, path) not in self.routes:
            raise RuntimeError(f"{method} {path} -> 404: not found")
        r = self.routes[(method, path)]
        if isinstance(r, Exception):
            raise r
        return copy.deepcopy(r)

    def get(self, path, **kw):
        return self._do("GET", path)

    def post(self, path, body=None, **kw):
        return self._do("POST", path, body)

    def posted(self, prefix):
        return [c for c in self.calls if c[0] == "POST" and c[1].startswith(prefix)]


RID = "R1R1R1R1R1R1R1R1R1R1R1R1R1R1R1R1"
STATEMENT = "SELECT d.id AS [Desk ID], d.nm AS [Desk], SUM(p.x) AS [Total PnL] FROM dbo.p p JOIN dbo.d d ON 1=1 GROUP BY d.id, d.nm"
DEFINITION = {"id": RID, "name": "Desk Coverage P&L", "definition": {"availableObjects": {
    "attributes": [{"id": "A1", "name": "Desk", "forms": [
        {"id": "F1", "name": "ID", "dataType": "numeric"},
        {"id": "F2", "name": "DESC", "dataType": {"type": "varchar"}}]}],
    "metrics": [{"id": "M1", "name": "Total PnL", "dataType": "numeric"}]}}}
PROMPTS = [{"key": "K1", "id": "P1", "name": "Trade Date From", "type": "value", "answers": "2026-01-01"}]
RESOLVED = {"id": "I9", "status": 1, "result": {"definition": {"sqlStatement": STATEMENT}}}
R = f"/v2/reports/{RID}"
RESOLVE = ("POST", f"/model/reports/{RID}/instances?executionStage=resolve_prompts")


def _routes(over=None):
    routes = {("GET", R): DEFINITION, ("GET", R + "/prompts"): PROMPTS, RESOLVE: RESOLVED}
    routes.update(over or {})
    return routes


def test_capture_resolve_prompts_never_executes():
    s = FakeSession(_routes())
    rec = sd.capture(s, RID)
    assert rec["format"] == "mstr-sql-dataset/1" and rec["reportId"] == RID
    assert rec["name"] == "Desk Coverage P&L" and rec["sql"] == STATEMENT
    assert rec["provenance"]["sqlSource"] == "resolve_prompts" and rec["provenance"]["retrievedAtUtc"]
    assert rec["objects"] == [
        {"kind": "attribute", "id": "A1", "name": "Desk", "form": "ID", "dataType": "numeric"},
        {"kind": "attribute", "id": "A1", "name": "Desk", "form": "DESC", "dataType": "varchar"},
        {"kind": "metric", "id": "M1", "name": "Total PnL", "dataType": "numeric"}], rec["objects"]
    assert rec["prompts"] == [{"id": "P1", "name": "Trade Date From", "type": "value", "answer": "2026-01-01"}]
    assert rec["columnMap"] is None and rec["warnings"] == []
    assert rec["raw"]["definition"] == DEFINITION and rec["raw"]["prompts"] == PROMPTS
    assert rec["raw"]["sqlResponse"] == RESOLVED
    assert not s.posted("/v2/reports"), "must not execute the report by default"
    assert [c[1] for c in s.posted("/model/reports")] == [RESOLVE[1]]
    print("[ok] capture: SQL via resolve_prompts, objects + prompts normalized, raw kept, no execution")


def test_capture_requires_allow_execute():
    s = FakeSession(_routes({RESOLVE: {"id": "I9", "status": 1}}))
    try:
        sd.capture(s, RID, allow_execute=False)
    except Exception as e:
        assert "--allow-execute" in str(e) and "warehouse" in str(e), str(e)
    else:
        raise AssertionError("expected a clear error")
    assert not s.posted("/v2/reports"), "must not execute without --allow-execute"
    # the resolve_prompts call failing outright is the same story, and names the cause
    s = FakeSession(_routes({RESOLVE: RuntimeError("POST x -> 400: bad stage")}))
    try:
        sd.capture(s, RID)
    except Exception as e:
        assert "--allow-execute" in str(e) and "bad stage" in str(e), str(e)
    else:
        raise AssertionError("expected a clear error")
    assert not s.posted("/v2/reports")
    print("[ok] capture: no SQL + no --allow-execute -> clear error, nothing executed")


def test_capture_sqlview_fallback_when_allowed():
    inst = ("POST", f"/v2/reports/{RID}/instances?limit=1")
    view = ("GET", f"/v2/reports/{RID}/instances/INST1/sqlView")
    s = FakeSession(_routes({RESOLVE: {"id": "I9"}, inst: {"instanceId": "INST1", "data": {}},
                               view: {"sqlStatement": STATEMENT}}))
    rec = sd.capture(s, RID, allow_execute=True)
    assert rec["sql"] == STATEMENT and rec["provenance"]["sqlSource"] == "sqlView"
    assert [c[1] for c in s.posted("/v2/reports")] == [inst[1]]
    assert rec["raw"]["sqlResponse"] == {"sqlStatement": STATEMENT}
    # allowed but resolve_prompts already produced SQL -> still no execution
    s = FakeSession(_routes())
    assert sd.capture(s, RID, allow_execute=True)["provenance"]["sqlSource"] == "resolve_prompts"
    assert not s.posted("/v2/reports")
    print("[ok] capture: sqlView fallback only when --allow-execute and resolve_prompts gave nothing")


def test_capture_prompts_fallback_and_tolerance():
    # first prompts endpoint errors, second answers (dict-wrapped list)
    s = FakeSession({("GET", R): DEFINITION, ("GET", f"/reports/{RID}/prompts"): {"prompts": PROMPTS},
                     RESOLVE: RESOLVED})
    rec = sd.capture(s, RID)
    assert rec["prompts"][0]["id"] == "P1" and rec["warnings"] == []
    # both fail -> [] + warning, capture still succeeds
    s = FakeSession({("GET", R): DEFINITION, RESOLVE: RESOLVED})
    rec = sd.capture(s, RID)
    assert rec["prompts"] == [] and len(rec["warnings"]) == 1 and "prompts" in rec["warnings"][0]
    # definition without availableObjects: fall back to the grid (template metrics unwrapped)
    grid_def = {"name": "Grid Report", "definition": {"grid": {
        "rows": [{"id": "A1", "name": "Desk", "type": "attribute",
                  "forms": [{"id": "F2", "name": "DESC", "dataType": "varchar"}]}],
        "columns": [{"type": "templateMetrics", "elements": [{"id": "M1", "name": "Total PnL"}]}]}}}
    s = FakeSession(_routes({("GET", R): grid_def}))
    rec = sd.capture(s, RID)
    assert rec["name"] == "Grid Report"
    assert [(o["kind"], o["name"], o.get("form")) for o in rec["objects"]] == \
        [("attribute", "Desk", "DESC"), ("metric", "Total PnL", None)], rec["objects"]
    # a definition with nothing recognizable still captures (objects empty), never crashes
    s = FakeSession(_routes({("GET", R): {"id": RID}}))
    rec = sd.capture(s, RID)
    assert rec["objects"] == [] and rec["name"] == RID
    print("[ok] capture: prompts endpoint fallback, warning when both fail, grid fallback, tolerant")


# ---------------------------------------------------------------- 5. extract() routing
def test_extract_routes_freeform_datasets():
    import extract
    ok_report = {"dataSource": {"dataTemplate": {"units": [
        {"type": "attribute", "id": "A1"},
        {"type": "metrics", "elements": [{"id": "M1"}]}]}}}
    routes = {("GET", "/v2/dossiers/D1/definition"): {
        "name": "Dossier", "datasets": [{"id": "OK"}, {"id": "BAD"}, {"id": RID}, {"id": "DEAD"}]},
        ("GET", "/model/reports/OK?showExpressionAs=tokens"): ok_report,
        ("GET", "/model/reports/BAD?showExpressionAs=tokens"): RuntimeError("GET -> 400: no schema"),
        ("GET", f"/model/reports/{RID}?showExpressionAs=tokens"): {"dataSource": {"dataTemplate": {"units": []}}},
        ("GET", "/model/reports/DEAD?showExpressionAs=tokens"): RuntimeError("GET -> 400: nope"),
        ("GET", "/model/attributes/A1?showExpressionAs=tokens"): {"forms": []},
        ("GET", "/model/metrics/M1?showExpressionAs=tokens"): {"expression": {"tokens": []}},
        ("GET", "/v2/reports/BAD"): dict(DEFINITION, id="BAD", name="Bad Report"),
        ("POST", "/model/reports/BAD/instances?executionStage=resolve_prompts"): RESOLVED,
        ("GET", R): DEFINITION,
        RESOLVE: RESOLVED}
    s = FakeSession(routes)
    b = extract.extract(s, "D1")
    assert set(b["reports"]) == {"OK"}, list(b["reports"])
    assert set(b["sqlDatasets"]) == {"BAD", RID, "DEAD"}, list(b["sqlDatasets"])
    assert b["sqlDatasets"]["BAD"]["format"] == "mstr-sql-dataset/1"
    assert b["sqlDatasets"][RID]["sql"] == STATEMENT
    dead = b["sqlDatasets"]["DEAD"]       # capture itself failing must not crash the extract
    assert dead["reportId"] == "DEAD" and dead["error"] and "sql" not in dead, dead
    assert set(b["attributes"]) == {"A1"} and set(b["metrics"]) == {"M1"}
    assert not s.posted("/v2/reports"), "extract must never execute a report"
    # a bundle with only normal datasets still carries an empty sqlDatasets map
    s = FakeSession({k: v for k, v in routes.items() if "BAD" not in k[1] and RID not in k[1]
                     and "DEAD" not in k[1]} | {("GET", "/v2/dossiers/D1/definition"): {"datasets": [{"id": "OK"}]}})
    assert extract.extract(s, "D1")["sqlDatasets"] == {}
    print("[ok] extract: failing / empty-template datasets -> sqlDatasets; capture errors recorded, never fatal")



# ---------------------------------------------------------------- 6. convert-sql-datasets
CSD = load_script("convert-sql-datasets.py", "convert_sql_datasets")


def fixture():
    return json.load(open(FIXTURE, encoding="utf-8"))


def _quiet(fn, *a):
    devnull = open(os.devnull, "w")
    saved = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = devnull
    try:
        return fn(*a)
    finally:
        sys.stdout, sys.stderr = saved
        devnull.close()


def convert(doc, *extra, column_map=None, template=True):
    """Run main() on an in-memory datasets document; return rc, spec, gaps, template
    (parsed + raw text)."""
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "sql-datasets.json")
        with open(src, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        out, gaps_out, tpl = (os.path.join(td, n) for n in ("spec.json", "gaps.json", "tpl.json"))
        argv = ["--datasets", src, "--connection-id", CONN, "--folder-id", FOLDER,
                "--out", out, "--gaps-out", gaps_out]
        if template:
            argv += ["--column-map-template-out", tpl]
        if column_map is not None:
            cm = os.path.join(td, "map.json")
            json.dump(column_map, open(cm, "w", encoding="utf-8"))
            argv += ["--column-map", cm]
        argv += list(extra)
        res = {"rc": _quiet(CSD.main, argv)}
        for key, path in (("spec", out), ("gaps", gaps_out), ("tpl", tpl)):
            exists = os.path.exists(path)
            res[key] = json.load(open(path, encoding="utf-8")) if exists else None
            res[key + "_raw"] = open(path, encoding="utf-8").read() if exists else None
    return res


def element(spec, i=0):
    return spec["pages"][0]["elements"][i]


def constructs(gaps, severity=None):
    return [g["construct"] for g in gaps["gaps"] if severity in (None, g["severity"])]


def test_golden(update):
    r = convert(fixture())
    assert r["rc"] == 0, r["gaps"]
    for name, raw in (("desk-coverage-pnl.dm.json", r["spec_raw"]), ("desk-coverage-pnl.gaps.json", r["gaps_raw"])):
        path = os.path.join(GOLDEN_DIR, name)
        if update:
            os.makedirs(GOLDEN_DIR, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(raw)
            continue
        assert os.path.exists(path), "missing golden %s (run with --update-golden)" % path
        assert open(path, encoding="utf-8").read() == raw, \
            "%s drifted from golden; rerun with --update-golden if intended" % name
    print("[ok] golden: Sigma data model + gaps match%s" % (" (updated)" if update else ""))


def test_dm_shape():
    r = convert(fixture())
    spec = r["spec"]
    assert spec["name"] == "Desk Coverage P&L (MSTR SQL datasets)", spec["name"]
    assert spec["folderId"] == FOLDER and spec["schemaVersion"] == 1
    assert spec["pages"][0]["id"] == "page-1" and spec["pages"][0]["name"] == "Model"
    el = element(spec)
    assert el["id"] == "sql-desk-coverage-p-l" and el["kind"] == "table" and el["name"] == "Desk Coverage P&L"
    assert el["source"]["kind"] == "sql" and el["source"]["connectionId"] == CONN
    sql = fixture()["datasets"][0]["sql"]
    assert sql.startswith("-- ") and el["source"]["statement"] == sql.split("\n", 1)[1].strip(), \
        "statement = captured SQL minus its leading comment"
    cols = [(c["id"], c["name"], c["formula"]) for c in el["columns"]]
    assert cols == [
        ("c-desk-coverage-p-l-desk-id", "Desk ID", "[Custom SQL/Desk ID]"),
        ("c-desk-coverage-p-l-desk", "Desk", "[Custom SQL/Desk Name]"),     # via record columnMap
        ("c-desk-coverage-p-l-coverage", "Coverage", "[Custom SQL/Coverage]"),
        ("c-desk-coverage-p-l-total-pnl-sql-column", "Total PnL (SQL column)", "[Custom SQL/Total PnL]"),
        ("c-desk-coverage-p-l-notional-usd-sql-column", "Notional, USD (SQL column)",
         "[Custom SQL/Notional, USD]")], cols
    mets = [(m["id"], m["name"], m["formula"]) for m in el["metrics"]]
    assert mets == [("m-desk-coverage-p-l-total-pnl", "Total PnL", "Sum([Total PnL (SQL column)])"),
                    ("m-desk-coverage-p-l-notional-usd", "Notional, USD",
                     "Sum([Notional, USD (SQL column)])")], mets
    # Sigma can drop an element's metrics from readback when a metric shares a column's name
    assert not {m["name"] for m in el["metrics"]} & {c["name"] for c in el["columns"]}, \
        "metric names must not collide with column names"
    assert r["gaps"]["blocking"] == 0
    assert constructs(r["gaps"], "review") == ["metric aggregation", "prompt: Trade Date From"], constructs(r["gaps"])
    prompt_gap = next(g for g in r["gaps"]["gaps"] if g["construct"].startswith("prompt"))
    assert "2026-01-01" in prompt_gap["detail"] and "baked" in prompt_gap["detail"]
    assert r["tpl"] is None, "no template without unmatched objects"
    assert convert(fixture(), "--dm-name", "Custom Name")["spec"]["name"] == "Custom Name"
    print("[ok] dm shape: Custom SQL element, ids, display names, Sum metrics, review gaps")


def test_metric_aggregation_from_catalog():
    src = open(os.path.join(SCRIPTS, "convert-sql-datasets.py"), encoding="utf-8").read()
    assert "_cc.load(" in src and '"aggregation"' in src, "aggregation must come from the catalog"
    row = CSD.AGG_CAT.resolve("Sum")
    saved = row["sigma"]
    row["sigma"] = "CatalogSum"
    try:
        r = convert(fixture())
    finally:
        row["sigma"] = saved
    assert [m["formula"] for m in element(r["spec"])["metrics"]] == \
        ["CatalogSum([Total PnL (SQL column)])", "CatalogSum([Notional, USD (SQL column)])"]
    print("[ok] metric aggregation resolves through refs/catalogs/aggregation.json")


def test_column_map_precedence():
    # --column-map beats the record's columnMap (which beats name matching)
    swap = [{"alias": "Desk Name", "object": "Desk", "form": "ID"},
            {"alias": "Desk ID", "object": "Desk", "form": "DESC"}]
    for key in (fixture()["datasets"][0]["reportId"], "Desk Coverage P&L"):   # id or report name
        r = convert(fixture(), column_map={key: swap})
        assert r["rc"] == 0, r["gaps"]
        names = {c["formula"]: c["name"] for c in element(r["spec"])["columns"]}
        assert names["[Custom SQL/Desk Name]"] == "Desk ID" and names["[Custom SQL/Desk ID]"] == "Desk", names
        assert names["[Custom SQL/Total PnL]"] == "Total PnL (SQL column)"   # the rest still name-matched
    # a partial CLI map layers over, rather than replaces, the record map
    r = convert(fixture(), column_map={"Desk Coverage P&L": [
        {"alias": "Total PnL", "object": "Total PnL", "form": None}]})
    assert r["rc"] == 0, r["gaps"]
    names = {c["formula"]: c["name"] for c in element(r["spec"])["columns"]}
    assert names["[Custom SQL/Desk Name]"] == "Desk", names
    # form null resolves the DESC form / a sole form / a metric
    r = convert(fixture(), column_map={"Desk Coverage P&L": [
        {"alias": "Desk Name", "object": "Desk", "form": None}]})
    assert r["rc"] == 0
    assert {c["formula"]: c["name"] for c in element(r["spec"])["columns"]}["[Custom SQL/Desk Name]"] == "Desk"
    # an entry naming an object the record does not have is blocking, not silent
    r = convert(fixture(), column_map={"Desk Coverage P&L": [
        {"alias": "Desk Name", "object": "Nope", "form": None}]})
    assert r["rc"] == 2 and "column map entry unresolved" in constructs(r["gaps"], "blocking")
    print("[ok] column map: --column-map > record columnMap > name matching; bad entry is blocking")


def test_column_map_merges_with_record_map():
    # a filled-in template covers only the unmatched objects: passing it back as
    # --column-map must keep the record's hand-edited entries (Desk Name -> Desk DESC)
    r = convert(fixture(), column_map={"Desk Coverage P&L": [
        {"alias": "Notional, USD", "object": "Notional, USD", "form": None}]})
    assert r["rc"] == 0, r["gaps"]
    names = {c["formula"]: c["name"] for c in element(r["spec"])["columns"]}
    assert names["[Custom SQL/Desk Name]"] == "Desk", names
    print("[ok] column map: --column-map fills in around the record's columnMap, never drops it")


def test_dataset_element_ids_unique():
    doc = fixture()
    base = doc["datasets"][0]
    same_name = copy.deepcopy(base)
    same_name["reportId"] = "RPT-SAME-NAME"
    slug_alike = copy.deepcopy(base)
    slug_alike["reportId"], slug_alike["name"] = "RPT-SLUG-ALIKE", "Desk Coverage P L"
    doc["datasets"] = [base, same_name, slug_alike]
    r = convert(doc)
    assert r["rc"] == 0, r["gaps"]
    els = r["spec"]["pages"][0]["elements"]
    ids = [e["id"] for e in els]
    assert ids == ["sql-desk-coverage-p-l", "sql-desk-coverage-p-l-2", "sql-desk-coverage-p-l-3"], ids
    col_ids = [c["id"] for e in els for c in e["columns"]]
    met_ids = [m["id"] for e in els for m in e["metrics"]]
    assert len(set(col_ids)) == len(col_ids) and len(set(met_ids)) == len(met_ids), (col_ids, met_ids)
    assert [e["name"] for e in els] == ["Desk Coverage P&L", "Desk Coverage P&L (RPT-SAME-NAME)",
                                        "Desk Coverage P L"]
    assert "duplicate dataset name" in constructs(r["gaps"], "review")

    # Hyphens make the dataset-key/field-slug boundary ambiguous, so uniqueness
    # must be enforced globally rather than only within each dataset.
    def metric_dataset(report_id, alias):
        return {"reportId": report_id, "name": "Sales", "sql": "SELECT 1 AS [%s]" % alias,
                "objects": [{"id": report_id, "kind": "metric", "name": alias}]}
    collision_doc = {"format": CSD.FORMAT_ID, "datasets": [
        metric_dataset("RPT-1", "2 Yr Return"),
        metric_dataset("RPT-2", "Yr Return"),
    ]}
    collision_els = convert(collision_doc)["spec"]["pages"][0]["elements"]
    collision_cols = [c["id"] for e in collision_els for c in e["columns"]]
    collision_mets = [m["id"] for e in collision_els for m in e["metrics"]]
    assert len(set(collision_cols)) == len(collision_cols), collision_cols
    assert len(set(collision_mets)) == len(collision_mets), collision_mets
    print("[ok] element / column / metric ids unique across datasets; repeated names suffixed")


def test_unmatched_is_blocking_and_writes_template():
    doc = fixture()
    rid = doc["datasets"][0]["reportId"]
    doc["datasets"][0]["columnMap"] = None           # Desk/DESC no longer maps to [Desk Name]
    r = convert(doc)
    assert r["rc"] == 2, r["gaps"]
    blocking = [g for g in r["gaps"]["gaps"] if g["severity"] == "blocking"]
    assert [g["construct"] for g in blocking] == ["unmatched object"], blocking
    assert "Desk" in blocking[0]["detail"] and "DESC" in blocking[0]["detail"]
    assert "tpl.json" in blocking[0]["detail"] and "Desk Name" in blocking[0]["detail"]
    assert r["gaps"]["blocking"] == 1
    assert r["tpl"] == {rid: [{"alias": None, "object": "Desk", "form": "DESC"}]}, r["tpl"]
    assert "unused SQL alias" in constructs(r["gaps"], "review")         # [Desk Name] has no object
    el = element(r["spec"])                                              # outputs still written
    assert "Desk Name" in [c["name"] for c in el["columns"]]             # unmapped alias keeps its name
    assert [m["name"] for m in el["metrics"]] == ["Total PnL", "Notional, USD"]
    assert convert(doc, "--allow-gaps")["rc"] == 0
    # filling the template in clears the gap (the template is the --column-map shape)
    tpl = r["tpl"]
    tpl[rid][0]["alias"] = "Desk Name"
    assert convert(doc, column_map=tpl)["rc"] == 0
    # without --column-map-template-out nothing is written and the gap says how to get one
    r = convert(doc, template=False)
    assert r["rc"] == 2 and r["tpl"] is None
    assert "--column-map-template-out" in next(g for g in r["gaps"]["gaps"] if g["severity"] == "blocking")["detail"]
    print("[ok] unmatched object -> blocking gap (exit 2), template written, --allow-gaps -> 0")


def test_not_derivable_needs_column_map():
    doc = fixture()
    doc["datasets"][0]["sql"] = "SELECT * FROM dbo.fact_pnl"
    doc["datasets"][0]["columnMap"] = None
    r = convert(doc)
    assert r["rc"] == 2 and "select list not derivable" in constructs(r["gaps"], "blocking")
    assert r["spec"]["pages"][0]["elements"] == [], "no derivable columns -> no element emitted"
    # an explicit map supplies the columns (in map order) and the statement still ships
    cm = {"Desk Coverage P&L": [
        {"alias": "desk_id", "object": "Desk", "form": "ID"},
        {"alias": "pnl_amt", "object": "Total PnL", "form": None}]}
    r = convert(doc, column_map=cm)
    el = element(r["spec"])
    assert [c["formula"] for c in el["columns"]] == ["[Custom SQL/desk_id]", "[Custom SQL/pnl_amt]"]
    assert [c["name"] for c in el["columns"]] == ["Desk ID", "Total PnL (SQL column)"]
    assert [m["name"] for m in el["metrics"]] == ["Total PnL"]
    assert "select list not derivable" not in constructs(r["gaps"], "blocking")
    # the map must cover every object, else the rest are blocking
    assert "unmatched object" in constructs(r["gaps"], "blocking") and r["rc"] == 2
    print("[ok] SELECT * -> blocking until --column-map supplies the aliases")


def test_invalid_input_is_exit_1():
    for bad in ("select 1; select 2", "create volatile table x as (select 1) with data",
                "insert into t select 1", "", "select '{{prompt}}'"):
        doc = fixture()
        doc["datasets"][0]["sql"] = bad
        r = convert(doc)
        assert r["rc"] == 1 and r["spec"] is None, (bad, r["rc"])
    doc = fixture()
    doc["format"] = "mstr-sql-datasets/0"
    assert convert(doc)["rc"] == 1
    doc = fixture()
    del doc["datasets"][0]["sql"]
    assert convert(doc)["rc"] == 1
    print("[ok] unsafe/empty SQL, wrong format, missing sql -> exit 1, nothing written")


def test_captured_error_and_warnings():
    doc = fixture()
    doc["datasets"].append({"reportId": "DEAD", "name": "Dead Dataset", "error": "no SQL available"})
    doc["datasets"][0]["warnings"] = ["prompts unavailable from both prompts endpoints (x)"]
    r = convert(doc)
    assert r["rc"] == 2
    gap = next(g for g in r["gaps"]["gaps"] if g["severity"] == "blocking")
    assert gap["dataset"] == "Dead Dataset" and "no SQL available" in gap["detail"]
    assert len(r["spec"]["pages"][0]["elements"]) == 1, "failed capture emits no element"
    assert "capture warning" in constructs(r["gaps"], "review")
    print("[ok] a record carrying `error` is a blocking gap; capture warnings surface as review gaps")


def test_dataset_ids_are_unique():
    doc = fixture()
    second = json.loads(json.dumps(doc["datasets"][0]))
    second["reportId"] = "SECOND"
    second["name"] = "Desk Coverage P L"
    doc["datasets"].append(second)
    r = convert(doc)
    assert r["rc"] == 0, r["gaps"]
    elements = r["spec"]["pages"][0]["elements"]
    assert [e["id"] for e in elements] == ["sql-desk-coverage-p-l", "sql-desk-coverage-p-l-2"]
    column_ids = [c["id"] for e in elements for c in e["columns"]]
    metric_ids = [m["id"] for e in elements for m in e["metrics"]]
    assert len(column_ids) == len(set(column_ids))
    assert len(metric_ids) == len(set(metric_ids))
    print("[ok] slug-equivalent datasets have unique element, column, and metric ids")



# ---------------------------------------------------------------- 7. extract-sql-dataset.py CLI
def test_extract_cli():
    esd = load_script("extract-sql-dataset.py", "extract_sql_dataset")
    page1 = {"result": [{"id": RID, "name": "Desk Coverage P&L"}], "totalItems": 2}
    page2 = {"result": [{"id": "R2"}], "totalItems": 2}
    routes = _routes({
        ("GET", "/searches/results?usedByObject=DOC1;55&type=3&offset=0&limit=500"): page1,
        ("GET", "/searches/results?usedByObject=DOC1;55&type=3&offset=1&limit=500"): page2,
        ("GET", "/v2/reports/R2"): dict(DEFINITION, id="R2", name="Second"),
        ("POST", "/model/reports/R2/instances?executionStage=resolve_prompts"): RESOLVED,
        ("GET", "/v2/reports/BAD"): RuntimeError("404"),
        ("POST", "/model/reports/BAD/instances?executionStage=resolve_prompts"): {"id": "x"},
    })
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "sql-datasets.json")
        s = FakeSession(routes)
        rc = _quiet(esd.main, [RID, "--document", "DOC1", "--out", out], s)
        assert rc == 0
        doc = json.load(open(out, encoding="utf-8"))
        assert doc["format"] == "mstr-sql-datasets/1" and doc["_extraction"]["retrievedAtUtc"]
        assert doc["_extraction"]["reportIds"] == [RID, "R2"], doc["_extraction"]   # deduped, order kept
        assert doc["_extraction"]["allowExecute"] is False
        assert [d["reportId"] for d in doc["datasets"]] == [RID, "R2"]
        assert all(d["format"] == "mstr-sql-dataset/1" for d in doc["datasets"])
        assert not s.posted("/v2/reports")
        # a report that cannot be captured is recorded, the run still writes its output, exit 2
        s = FakeSession(routes)
        rc = _quiet(esd.main, [RID, "BAD", "--out", out], s)
        doc = json.load(open(out, encoding="utf-8"))
        assert rc == 2 and doc["datasets"][1]["reportId"] == "BAD" and doc["datasets"][1]["error"], doc
        # --allow-execute reaches the sqlView fallback through the same capture()
        inst = ("POST", f"/v2/reports/{RID}/instances?limit=1")
        view = ("GET", f"/v2/reports/{RID}/instances/INST1/sqlView")
        s = FakeSession(_routes({RESOLVE: {"id": "I9"}, inst: {"instanceId": "INST1"}, view: {"sqlStatement": STATEMENT}}))
        assert _quiet(esd.main, [RID, "--allow-execute", "--out", out], s) == 0
        assert json.load(open(out))["datasets"][0]["provenance"]["sqlSource"] == "sqlView"
        # no report ids and no --document is a usage error
        assert _quiet(esd.main, ["--out", out], FakeSession({})) == 1
    print("[ok] extract-sql-dataset.py: ids + --document (paginated), dedupe, errors recorded, --allow-execute")


# ---------------------------------------------------------------- convert.py hooks
def _run_convert(work, bundle, *extra):
    argv = [sys.executable, os.path.join(SCRIPTS, "convert.py"), "--bundle", bundle,
            "--connection-id", "conn-x", "--database", "DB", "--folder-id", "folder-x",
            "--out-dm", os.path.join(work, "dm.json"), "--out-wb", os.path.join(work, "wb.json"),
            "--out-layout", os.path.join(work, "layout.xml"),
            "--control-scope-out", os.path.join(work, "controls.json"),
            "--feature-gaps-out", os.path.join(work, "gaps.json")] + list(extra)
    env = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    return subprocess.run(argv, cwd=work, env=env, capture_output=True, text=True)


def test_convert_multi_fact_guard_messages_unchanged():
    bundle = os.path.join(SKILL, "fixtures", "bundle.json")
    cases = [
        ("", "--multi-fact-sql is empty"),
        ("select 1; select 2", "--multi-fact-sql must contain one SELECT/CTE statement; "
                               "multi-step or volatile-table plans are not accepted"),
        ("update t set a = 1", "--multi-fact-sql must start with SELECT or WITH"),
        ("select 1 from t where a in (delete from b)",
         "--multi-fact-sql must be a read-only single query; found 'delete from'"),
        ("select '{{p}}'", "--multi-fact-sql still contains an unresolved placeholder. "
                           "Resolve prompts/security substitutions from a live report "
                           "instance before conversion."),
    ]
    with tempfile.TemporaryDirectory() as work:
        sql_path = os.path.join(work, "c.sql")
        for sql, expected in cases:
            with open(sql_path, "w", encoding="utf-8") as fh:
                fh.write(sql)
            r = _run_convert(work, bundle, "--multi-fact-sql", sql_path)
            assert r.returncode != 0 and r.stderr.strip().splitlines()[-1] == expected, \
                (sql, r.returncode, r.stderr[-300:])
    print("[ok] convert.py --multi-fact-sql guard: messages byte-identical after the refactor")


def test_convert_refuses_sql_datasets_bundle():
    bundle = json.load(open(os.path.join(SKILL, "fixtures", "bundle.json"), encoding="utf-8"))
    bundle["sqlDatasets"] = {
        "RPT1": {"format": "mstr-sql-dataset/1", "reportId": "RPT1", "name": "Desk Coverage P&L"},
        "RPT2": {"reportId": "RPT2", "name": "Broken One", "error": "boom"},
    }
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "bundle.json")
        json.dump(bundle, open(path, "w", encoding="utf-8"))
        r = _run_convert(work, path)
        assert r.returncode != 0, r.stdout
        msg = r.stderr
        assert "Desk Coverage P&L" in msg and "Broken One" in msg and "RPT1" in msg, msg
        assert "convert-sql-datasets.py" in msg and "not wired" in msg, msg
        assert not os.path.exists(os.path.join(work, "dm.json")), "must stop before writing outputs"
        # a bundle without the key (or with an empty one) is untouched
        bundle["sqlDatasets"] = {}
        json.dump(bundle, open(path, "w", encoding="utf-8"))
        ok = _run_convert(work, path)
        assert ok.returncode == 0, ok.stderr[-500:]
    print("[ok] convert.py: bundle with sqlDatasets stops loudly; empty/absent key unchanged")


# ---------------------------------------------------------------- runner
def main():
    update = "--update-golden" in sys.argv
    test_select_aliases()
    test_match_columns()
    test_guard_sql()
    test_capture_resolve_prompts_never_executes()
    test_capture_requires_allow_execute()
    test_capture_sqlview_fallback_when_allowed()
    test_capture_prompts_fallback_and_tolerance()
    test_extract_routes_freeform_datasets()
    test_golden(update)
    test_dm_shape()
    test_metric_aggregation_from_catalog()
    test_column_map_precedence()
    test_column_map_merges_with_record_map()
    test_dataset_element_ids_unique()
    test_unmatched_is_blocking_and_writes_template()
    test_not_derivable_needs_column_map()
    test_invalid_input_is_exit_1()
    test_captured_error_and_warnings()
    test_dataset_ids_are_unique()
    test_extract_cli()
    test_convert_multi_fact_guard_messages_unchanged()
    test_convert_refuses_sql_datasets_bundle()
    print("ALL PASS")


if __name__ == "__main__":
    main()
