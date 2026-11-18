#!/usr/bin/env python3
"""Derived metrics (a metric built from other metrics inside a report or a
dossier, not a project-schema object). Offline, creds-free.

A report-level derived metric sits in the report template like any metric, but
it is EMBEDDED in the report: `GET /model/metrics/{id}` 404s for it. Before
this fix that one 404 aborted the whole extract. A dossier-level derived metric
is not in any report template at all, so it was silently dropped.

  1. EXTRACT — an embedded metric 404 never aborts; its formula is recovered
     from a Modeling report instance (POST /model/reports/{id}/instances,
     GET /model/reports/{id} with X-MSTR-MS-Instance), never by executing.
  2. EXTRACT — a metric no endpoint resolves lands in bundle["unresolvedMetrics"]
     with its name, report and the error, and the extract still completes.
  3. EXTRACT — dossier-level derived metrics come from GET /model/documents/{id}
     (datasets[].derivedMetrics[]); tokens -> bundle["metrics"], text-only ->
     unresolvedMetrics carrying formulaText. A failing endpoint is recorded.
  4. EXTRACT — compound metrics nested deeper than two levels are all fetched.
  5. CONVERT — a resolved derived metric becomes a DM metric; an unresolved
     one is skipped with a loud warning (convert exits 0, no KeyError).
  6. CONVERT — a derived metric whose tokens the translator cannot handle is
     degraded to unresolved with a warning, not a SystemExit.
  7. REAL SHAPE — fixtures/derived-metrics/model-document.tutorial.json (live
     GET /model/documents/{id} from Strategy's public demo): formulas arrive as
     an expression `tree`; arithmetic trees become DM metrics end to end,
     inline aggregations stay unresolved with their text, auto Row Count
     metrics are skipped.
  8. EXTRACT — isEmbedded / grid-only derived metrics are never sent to
     /model/metrics; a tenant where EVERY metric lookup fails (403) aborts loudly.

Run: python3 tests/test_derived_metrics.py   (exit 0 = pass)
"""
import copy
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
sys.path.insert(0, SCRIPTS)
import extract  # noqa: E402

BUNDLE = json.load(open(os.path.join(SKILL, "fixtures", "bundle.json")))
AE_WINNERS = os.path.join(SKILL, "fixtures", "ae_winners.json")
RID = "5C8ABD78BC4EA7F4AF876E97091E6BA5"       # Revenue by Region and Category
NET = "413D98E4993B4D6ABB2DC440F7B31971"       # Total Net Revenue
ORDERS = "145746BAC65E4BF39E83149A843A3DF7"    # Order Count
MARGIN = "5393F49A94A443E79E38CB3855B0272F"    # Profit Margin Pct (compound)
DER = "D" * 32                                  # report-level derived metric
DOC_DER = "E" * 32                              # dossier-level derived metric
INST = "MSINST-1"


def _ref(oid, name, sub="metric"):
    return {"type": "object_reference", "value": f"[{name}]",
            "target": {"objectId": oid, "subType": sub, "name": name}}


def _div():
    return {"type": "character", "value": "/",
            "target": {"subType": "function", "name": "/"}}


EOT = {"type": "end_of_text", "value": ""}
# Revenue per Order = [Total Net Revenue] / [Order Count]
DER_TOKENS = [_ref(NET, "Total Net Revenue"), _div(), _ref(ORDERS, "Order Count"), EOT]


def _report_with_embedded():
    r = copy.deepcopy(BUNDLE["reports"][RID])
    for u in r["dataSource"]["dataTemplate"]["units"]:
        if u["type"] == "metrics":
            u["elements"].append({"id": DER, "name": "New Metric", "subType": "metric"})
    return r


def _instance_definition():
    """The Modeling definition read through an instance: the embedded metric's
    grid element carries isEmbedded, an alias, and its expression."""
    r = _report_with_embedded()
    r["grid"] = {"viewTemplate": {"columns": {"units": [{"type": "metrics", "elements": [
        {"id": DER, "name": "New Metric", "subType": "metric", "isEmbedded": True,
         "alias": "Revenue per Order",
         "expression": {"text": "[Total Net Revenue] / [Order Count]",
                        "tokens": DER_TOKENS}}]}]}}}
    return r


class FakeSession:
    """Serves the fixture bundle's objects. `routes` overrides (method, path
    without query) -> value | Exception. Unknown objects raise RuntimeError
    like mstr.Session does on an HTTP error."""

    def __init__(self, routes=None, report=None):
        self.routes = routes or {}
        self.report = report or _report_with_embedded()
        self.calls = []
        self.last_headers = {}

    def _do(self, method, path, body=None, headers=None):
        self.calls.append((method, path, headers or {}))
        p = path.split("?")[0]
        key = (method, p, (headers or {}).get("X-MSTR-MS-Instance"))
        for k in (key, (method, p)):
            if k in self.routes:
                v = self.routes[k]
                if isinstance(v, Exception):
                    raise v
                if isinstance(v, tuple):          # (body, response headers)
                    self.last_headers = v[1]
                    return copy.deepcopy(v[0])
                return copy.deepcopy(v)
        if method != "GET":
            raise RuntimeError(f"{method} {path} -> 404: not found")
        if p.endswith("/definition"):
            d = copy.deepcopy(BUNDLE["dossier"])
            d["datasets"] = [ds for ds in d["datasets"] if ds["id"] == RID]
            return d
        if p == f"/model/reports/{RID}":
            return copy.deepcopy(self.report)
        parts = p.split("/")
        kind, oid = parts[2], parts[3] if len(parts) > 3 else None
        if kind == "systemHierarchy":
            return {}
        store = {"attributes": BUNDLE["attributes"], "metrics": BUNDLE["metrics"],
                 "facts": BUNDLE["facts"], "tables": BUNDLE["tables"]}.get(kind, {})
        if oid in store:
            return copy.deepcopy(store[oid])
        raise RuntimeError(f"GET {path} -> 404: "
                           '{"code":"ERR004","message":"object not found"}')

    def get(self, path, headers=None, **kw):
        return self._do("GET", path, headers=headers)

    def post(self, path, body=None, headers=None, **kw):
        return self._do("POST", path, body, headers)

    def delete(self, path, headers=None, **kw):
        return self._do("DELETE", path, headers=headers)

    def did(self, method, prefix):
        return [c for c in self.calls if c[0] == method and c[1].startswith(prefix)]


INSTANCE_ROUTES = {
    # live shape: 201 {"id": <instance>} (the header carries it too)
    ("POST", f"/model/reports/{RID}/instances"): ({"id": INST}, {"x-mstr-ms-instance": INST}),
    ("GET", f"/model/reports/{RID}", INST): _instance_definition(),
    ("DELETE", f"/model/reports/{RID}/instances"): None,
}


# ---------------------------------------------------------------- 1. recover via instance
def test_embedded_metric_recovered_from_report_instance():
    s = FakeSession(dict(INSTANCE_ROUTES))
    b = extract.extract(s, "DOSSIER")
    m = b["metrics"].get(DER)
    assert m, f"derived metric missing; unresolved={b.get('unresolvedMetrics')}"
    assert m["information"]["name"] == "Revenue per Order", m["information"]
    assert m["expression"]["tokens"] == DER_TOKENS
    assert m["_derived"]["scope"] == "report" and m["_derived"]["reportId"] == RID
    assert ORDERS in b["metrics"], "derived metric's base metric must be fetched"
    assert DER not in b.get("unresolvedMetrics", {})
    # a Modeling instance only: never an execution instance, and always cleaned up
    assert not s.did("POST", "/v2/reports"), "extract must never execute a report"
    posts = s.did("POST", f"/model/reports/{RID}/instances")
    assert posts and "executionStage" not in posts[0][1], posts
    dels = s.did("DELETE", f"/model/reports/{RID}/instances")
    assert dels and dels[0][2].get("X-MSTR-MS-Instance") == INST, dels
    print("[ok] extract: embedded metric 404 -> formula from Modeling report instance; instance deleted")


# ---------------------------------------------------------------- 2. unresolved is recorded
def test_unresolvable_metric_never_aborts():
    s = FakeSession()          # no instance routes: every recovery path fails
    b = extract.extract(s, "DOSSIER")
    u = b["unresolvedMetrics"][DER]
    assert u["name"] == "New Metric" and u["reportId"] == RID, u
    assert u["scope"] == "report" and "404" in u["error"], u
    assert DER not in b["metrics"]
    assert NET in b["metrics"] and MARGIN in b["metrics"], "the rest still extracts"
    print("[ok] extract: unresolvable derived metric -> unresolvedMetrics, extract completes")


# ---------------------------------------------------------------- 3. dossier-level
def test_dossier_level_derived_metrics():
    doc = {"datasets": [{"information": {"objectId": RID, "name": "Revenue by Region and Category"},
                         "derivedMetrics": [
                             {"information": {"objectId": DOC_DER, "name": "Rev per Order (dossier)"},
                              "expression": {"text": "[Total Net Revenue] / [Order Count]",
                                             "tokens": DER_TOKENS}},
                             {"information": {"objectId": "F" * 32, "name": "Text Only"},
                              "expression": {"text": "[Total Net Revenue] * 2"}}],
                         "derivedAttributes": [{"information": {"objectId": "A" * 32, "name": "Band"},
                                                "expression": {"text": "not a metric"}}]}]}
    routes = dict(INSTANCE_ROUTES)
    routes[("GET", "/model/documents/DOSSIER")] = doc
    b = extract.extract(FakeSession(routes), "DOSSIER")
    m = b["metrics"][DOC_DER]
    assert m["_derived"] == {"scope": "dossier", "datasetId": RID}, m["_derived"]
    assert m["information"]["name"] == "Rev per Order (dossier)"
    t = b["unresolvedMetrics"]["F" * 32]
    assert t["scope"] == "dossier" and t["formulaText"] == "[Total Net Revenue] * 2", t
    assert "A" * 32 not in b["metrics"] and "A" * 32 not in b["unresolvedMetrics"]
    assert ORDERS in b["metrics"]

    # the documents endpoint is unpublished: a failure is recorded, never fatal
    b2 = extract.extract(FakeSession(dict(INSTANCE_ROUTES)), "DOSSIER")
    assert "404" in b2["_extraction"]["documentModelError"], b2["_extraction"]
    print("[ok] extract: dossier-level derivedMetrics -> metrics / unresolvedMetrics(formulaText); endpoint failure recorded")


# ---------------------------------------------------------------- 4. deep compound chains
def test_compound_chain_deeper_than_two_levels():
    # DER -> MARGIN (compound) -> NET/GROSS (base): three levels below the template
    tokens = [_ref(MARGIN, "Profit Margin Pct"), _div(), _ref(ORDERS, "Order Count"), EOT]
    idef = _instance_definition()
    idef["grid"]["viewTemplate"]["columns"]["units"][0]["elements"][0]["expression"]["tokens"] = tokens
    report = _report_with_embedded()
    for u in report["dataSource"]["dataTemplate"]["units"]:     # MARGIN only via DER
        if u["type"] == "metrics":
            u["elements"] = [e for e in u["elements"] if e["id"] in (NET, DER)]
    routes = dict(INSTANCE_ROUTES)
    routes[("GET", f"/model/reports/{RID}", INST)] = idef
    b = extract.extract(FakeSession(routes, report=report), "DOSSIER")
    for mid in (DER, MARGIN, "653830C2CB684809B7030FBBEA498C8C", ORDERS):
        assert mid in b["metrics"], f"{mid} not fetched"
    print("[ok] extract: compound/derived chains of any depth are fully fetched")


# ---------------------------------------------------------------- 5/6. convert
def _convert(bundle):
    with tempfile.TemporaryDirectory() as d:
        bp = os.path.join(d, "bundle.json")
        json.dump(bundle, open(bp, "w"))
        wb, dm, gaps = (os.path.join(d, n) for n in ("wb.json", "dm.json", "gaps.json"))
        r = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "convert.py"), "--bundle", bp,
             "--connection-id", "conn-x", "--database", "DEMO_DB", "--folder-id", "fld-x",
             "--ae-winners", AE_WINNERS, "--out-dm", dm, "--out-wb", wb,
             "--out-layout", os.path.join(d, "l.xml"),
             "--control-scope-out", os.path.join(d, "cs.json"),
             "--feature-gaps-out", gaps],
            capture_output=True, text=True, cwd=d)
        assert r.returncode == 0, "convert.py failed:\n" + r.stderr[-3000:]
        return (json.load(open(dm)), json.load(open(wb)),
                json.load(open(gaps)) if os.path.exists(gaps) else {}, r.stdout + r.stderr)


def _dm_metrics(dm):
    return {m["name"]: m["formula"] for pg in dm["pages"] for el in pg["elements"]
            for m in (el.get("metrics") or [])}


def _wb_col_names(wb):
    return {c["name"] for el in wb["contents"]["elements"] for c in el.get("columns", [])}


def _bundle_with(metric=None, unresolved=None):
    b = copy.deepcopy(BUNDLE)
    b["reports"][RID] = _report_with_embedded()
    if metric:
        b["metrics"][DER] = metric
    if unresolved:
        b["unresolvedMetrics"] = {DER: unresolved}
    return b


def _derived_metric(tokens):
    return {"information": {"objectId": DER, "subType": "metric", "name": "Revenue per Order"},
            "expression": {"text": "", "tokens": tokens},
            "_derived": {"scope": "report", "reportId": RID}}


def test_convert_emits_resolved_derived_metric():
    dm, wb, _, _ = _convert(_bundle_with(metric=_derived_metric(DER_TOKENS)))
    f = _dm_metrics(dm).get("Revenue per Order")
    assert f == "[Total Net Revenue] / [Order Count]", _dm_metrics(dm)
    assert "Revenue per Order" in _wb_col_names(wb)
    print("[ok] convert: resolved derived metric -> DM metric + workbook column")


def test_ae_uses_recovered_derived_metric_name():
    b = copy.deepcopy(BUNDLE)
    report = next(r for r in b["reports"].values()
                  if r["information"]["name"] == "Monthly Revenue Trend")
    for u in report["dataSource"]["dataTemplate"]["units"]:
        if u["type"] == "metrics":
            u["elements"].append({"id": DER, "name": "New Metric", "subType": "metric"})
    b["metrics"][DER] = _derived_metric(DER_TOKENS)
    dm, wb, _, _ = _convert(b)
    emitted = json.dumps({"dm": dm, "wb": wb})
    assert "Revenue per Order" in emitted, emitted[-3000:]
    assert "New Metric" not in emitted, emitted[-3000:]
    print("[ok] convert: AE SQL and workbook use the recovered derived metric alias")


def test_convert_skips_unresolved_derived_metric_loudly():
    unresolved = {"name": "New Metric", "reportId": RID, "scope": "report",
                  "error": "GET /model/metrics/DDD -> 404"}
    dm, wb, gaps, out = _convert(_bundle_with(unresolved=unresolved))
    assert "New Metric" not in _dm_metrics(dm)
    assert "New Metric" not in _wb_col_names(wb)
    blob = json.dumps(gaps) + out
    assert "derived metric" in blob and "New Metric" in blob, blob[-2000:]
    print("[ok] convert: unresolved derived metric skipped with a loud warning, no KeyError")


def test_convert_degrades_untranslatable_derived_metric():
    # a level/attribute reference the token translator does not handle
    bad = [_ref("B" * 32, "Region", sub="attribute"), EOT]
    dm, wb, gaps, out = _convert(_bundle_with(metric=_derived_metric(bad)))
    assert "Revenue per Order" not in _dm_metrics(dm)
    assert "Total Net Revenue" in _dm_metrics(dm), "other metrics unaffected"
    blob = json.dumps(gaps) + out
    assert "Revenue per Order" in blob and "derived metric" in blob, blob[-2000:]
    print("[ok] convert: untranslatable derived metric degraded to a warning, not a SystemExit")


# ---------------------------------------------------------------- 7. real tree shape
REAL_DOC = json.load(open(os.path.join(SKILL, "fixtures", "derived-metrics",
                                       "model-document.tutorial.json")))
REVENUE = "4C05177011D3E877C000B3B2D86C964F"
FORECAST = "8D7D59C144AB891C57FEFA873ABE1C92"


def _renamed(mid, new_id, name):
    m = copy.deepcopy(BUNDLE["metrics"][mid])
    m["information"].update(objectId=new_id, name=name)
    return m


def _real_doc_bundle():
    doc = copy.deepcopy(REAL_DOC)
    doc["datasets"][0]["information"]["objectId"] = RID     # dataset = our report
    routes = dict(INSTANCE_ROUTES)
    routes[("GET", "/model/documents/DOSSIER")] = doc
    # the real formulas reference Tutorial's Revenue / Revenue Forecast: serve
    # fixture metrics under those ids so the chain resolves offline
    routes[("GET", f"/model/metrics/{REVENUE}")] = _renamed(NET, REVENUE, "Revenue")
    routes[("GET", f"/model/metrics/{FORECAST}")] = _renamed(
        "653830C2CB684809B7030FBBEA498C8C", FORECAST, "Revenue Forecast")
    return extract.extract(FakeSession(routes), "DOSSIER")


def test_real_tree_shape_end_to_end():
    b = _real_doc_bundle()
    by_name = {m["information"]["name"]: m for m in b["metrics"].values()}
    for n in ("Variance", "% Variance Revenue", "Revenue  (K$)"):
        assert by_name[n]["_derived"]["scope"] == "dossier", n
    lit = [t for t in by_name["Revenue  (K$)"]["expression"]["tokens"] if t["type"] == "literal"]
    assert lit and lit[0]["value"] == "1000", lit
    # Sum(Revenue) is an inline aggregation (embedded, not a document derived
    # metric): stays unresolved WITH its formula text, no doomed catalog call
    pct = next(u for u in b["unresolvedMetrics"].values()
               if u["name"] == "Percent to Total (Revenue)")
    assert pct["formulaText"] == "Revenue / Sum(Revenue)" and "embedded" in pct["error"], pct
    assert b["_extraction"]["skippedAutoRowCountMetrics"] == 1
    assert not any(u["name"] == "Row Count" for u in b["unresolvedMetrics"].values())

    full = copy.deepcopy(BUNDLE)          # all fixture reports (ae_winners needs them)
    full["metrics"].update(b["metrics"])
    full["unresolvedMetrics"] = b["unresolvedMetrics"]
    dm, _, gaps, out = _convert(full)
    f = _dm_metrics(dm)
    assert f["Variance"] == "[Revenue] - [Revenue Forecast]", f
    assert f["% Variance Revenue"] == "([Revenue] - [Revenue Forecast]) / [Revenue Forecast]", f
    assert f["Revenue  (K$)"] == "[Revenue] / 1000", f
    assert "Percent to Total (Revenue)" in json.dumps(gaps) + out
    print("[ok] real /model/documents tree shape -> DM metrics end to end; inline agg unresolved; Row Count skipped")


def test_tree_to_tokens_rejects_non_arithmetic():
    case = {"type": "operator", "function": "case", "functionName": "Case", "children": []}
    for tree in (case, {"type": "constant", "variant": {"type": "string", "value": "x"}},
                 {"type": "object_reference", "target": {"objectId": "A" * 32, "subType": "attribute"}}):
        try:
            extract.tree_to_tokens(tree)
        except extract._Untranslatable:
            continue
        raise AssertionError(f"accepted {tree}")
    neg = extract.tree_to_tokens({"type": "operator", "function": "unary_minus", "children": [
        {"type": "object_reference", "target": {"objectId": NET, "subType": "metric", "name": "N"}}]})
    assert [t.get("value") for t in neg][:3] == ["(", "0", "-"], neg
    emb = {"type": "object_reference", "target": {"objectId": DOC_DER, "subType": "metric",
                                                   "name": "Derived", "isEmbedded": True}}
    nested = extract.tree_to_tokens(emb, derived_ids={DOC_DER})   # another doc derived metric
    assert nested[0]["target"]["objectId"] == DOC_DER, nested
    try:
        extract.tree_to_tokens(emb)          # an inline aggregation: not chainable
        raise AssertionError("accepted an embedded non-derived reference")
    except extract._Untranslatable:
        pass
    print("[ok] tree_to_tokens: only arithmetic over metrics/numbers; unary minus -> (0 - x)")


def test_dossier_derived_on_derived_chains():
    # "Margin of Var" = [Variance] / [Revenue], where Variance is itself a
    # dossier derived metric referenced as an embedded object
    doc = copy.deepcopy(REAL_DOC)
    ds = doc["datasets"][0]
    ds["information"]["objectId"] = RID
    var = next(m for m in ds["derivedMetrics"] if m["information"]["name"] == "Variance")
    vid = var["information"]["objectId"]
    ds["derivedMetrics"].insert(0, {
        "information": {"objectId": "C" * 32, "subType": "metric", "name": "Margin of Var",
                        "isEmbedded": True},
        "expression": {"text": "Variance / Revenue", "tree": {
            "type": "operator", "function": "divide", "functionName": "/", "children": [
                {"type": "object_reference",
                 "target": {"objectId": vid, "subType": "metric", "name": "Variance",
                            "isEmbedded": True}},
                {"type": "object_reference",
                 "target": {"objectId": REVENUE, "subType": "metric", "name": "Revenue"}}]}}})
    routes = dict(INSTANCE_ROUTES)
    routes[("GET", "/model/documents/DOSSIER")] = doc
    routes[("GET", f"/model/metrics/{REVENUE}")] = _renamed(NET, REVENUE, "Revenue")
    routes[("GET", f"/model/metrics/{FORECAST}")] = _renamed(
        "653830C2CB684809B7030FBBEA498C8C", FORECAST, "Revenue Forecast")
    s = FakeSession(routes)
    b = extract.extract(s, "DOSSIER")
    assert "C" * 32 in b["metrics"] and vid in b["metrics"], b["unresolvedMetrics"]
    assert not s.did("GET", f"/model/metrics/{vid}"), "a doc derived metric was sent to the catalog"
    full = copy.deepcopy(BUNDLE)
    full["metrics"].update(b["metrics"])
    full["unresolvedMetrics"] = b["unresolvedMetrics"]
    f = _dm_metrics(_convert(full)[0])
    assert f["Margin of Var"] == "[Variance] / [Revenue]", f
    print("[ok] dossier derived-on-derived (embedded ref to a doc derived metric) chains end to end")


# ---------------------------------------------------------------- 8. embedded / permissions
def test_embedded_and_grid_only_never_hit_metric_catalog():
    report = _report_with_embedded()
    for u in report["dataSource"]["dataTemplate"]["units"]:
        if u["type"] == "metrics":
            u["elements"][-1]["isEmbedded"] = True                  # flagged in template
    report["grid"] = {"viewTemplate": {"columns": {"units": [{"type": "metrics", "elements": [
        {"id": "G" * 32, "name": "C=A/B", "subType": "metric", "isEmbedded": True}]}]}}}
    s = FakeSession(report=report)
    b = extract.extract(s, "DOSSIER")
    for mid in (DER, "G" * 32):
        assert not s.did("GET", f"/model/metrics/{mid}"), f"{mid} sent to the catalog"
    assert b["unresolvedMetrics"]["G" * 32]["scope"] == "report-grid"
    assert b["unresolvedMetrics"][DER]["scope"] == "report"
    print("[ok] extract: isEmbedded / grid-only derived metrics skip /model/metrics; grid-only ones are reported")


def test_all_metric_lookups_forbidden_aborts():
    class Forbidden(FakeSession):
        def get(self, path, headers=None, **kw):
            if path.startswith("/model/metrics/"):
                raise RuntimeError(f"GET {path} -> 403: no read access")
            return super().get(path, headers=headers)
    try:
        extract.extract(Forbidden(), "DOSSIER")
    except RuntimeError as e:
        assert "privileges" in str(e), e
        print("[ok] extract: every metric lookup 403 -> loud abort (permissions), not 'derived'")
        return
    raise AssertionError("a tenant-wide 403 was swallowed")


if __name__ == "__main__":
    test_embedded_metric_recovered_from_report_instance()
    test_unresolvable_metric_never_aborts()
    test_dossier_level_derived_metrics()
    test_compound_chain_deeper_than_two_levels()
    test_convert_emits_resolved_derived_metric()
    test_ae_uses_recovered_derived_metric_name()
    test_convert_skips_unresolved_derived_metric_loudly()
    test_convert_degrades_untranslatable_derived_metric()
    test_real_tree_shape_end_to_end()
    test_tree_to_tokens_rejects_non_arithmetic()
    test_dossier_derived_on_derived_chains()
    test_embedded_and_grid_only_never_hit_metric_catalog()
    test_all_metric_lookups_forbidden_aborts()
    print("ALL PASS")
