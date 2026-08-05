#!/usr/bin/env python3
"""discover_platform.py — legacy GoodData *Platform* (classic /gdc) extraction.

The Platform twin of discover.py. Where discover.py pulls a GoodData Cloud
workspace via the declarative /api/v1/layout API + a Bearer token, this pulls a
classic Platform *project* via the /gdc metadata API + the SST/TT flow
(platform_auth.py), and NORMALIZES it into the SAME top-level shape discover.py
emits — so the same downstream (maql.py translator, gap-scout, assessment) works
unchanged.

Key normalization: classic MAQL references objects by URI (`[/gdc/md/<pid>/obj/N]`)
or identifier (`[fact.foo.bar]`). We rewrite each reference into the Cloud-style
typed token maql.py understands — `{fact/N}` / `{attribute/N}` / `{metric/N}` —
resolving display-form (label) refs up to their parent attribute. That lets the
ONE existing translator score both dialects; we do not fork a second scorer.

Usage:
  export GOODDATA_PLATFORM_HOST=https://acme.on.gooddata.com
  export GOODDATA_PLATFORM_USER=...   GOODDATA_PLATFORM_PASSWORD=...
  python3 discover_platform.py --list                       # all accessible projects
  python3 discover_platform.py --project <pid> [--out platform_layout.json]

Status: built from the GoodData Platform metadata-API docs; endpoint SHAPES
(query/entries, objects/get wrappers, metric content.expression) are doc-verified
but NOT yet run against a live Platform org. The summary extractors defend against
shape drift; confirm field paths on first live run (mirrors discover.py's own
"confirm live" posture).
"""
import argparse, json, os, sys
from platform_auth import PlatformClient
from maql import translate

# classic query resources -> our normalized bucket
QUERY = {
    "metrics": "metric",
    "facts": "fact",
    "attributes": "attribute",
    "datasets": "dataSet",
    "reports": "report",
    "projectdashboards": "projectDashboard",
    "analyticaldashboards": "analyticalDashboard",
}


def query_entries(c, pid, resource):
    """GET /gdc/md/{pid}/query/{resource} -> list of entry dicts."""
    data = c.get(f"/gdc/md/{pid}/query/{resource}")
    return (data.get("query", {}) or {}).get("entries", []) or []


def bulk_get(c, pid, uris):
    """POST /gdc/md/{pid}/objects/get -> {uri: object-detail}. Chunked (server caps)."""
    out = {}
    uris = [u for u in uris if u]
    for i in range(0, len(uris), 50):
        chunk = uris[i:i + 50]
        resp = c.post(f"/gdc/md/{pid}/objects/get", {"get": {"items": chunk}})
        for item in ((resp.get("objects", {}) or {}).get("items", []) or []):
            # item is {<wrapperKey>: {content, meta}}
            for _wrapper, obj in item.items():
                uri = (obj.get("meta", {}) or {}).get("uri")
                if uri:
                    out[uri] = obj
    return out


def _last(uri):
    return uri.rstrip("/").split("/")[-1] if uri else None


def build_ref_map(c, pid):
    """Map every fact/attribute/metric (by URI *and* identifier) -> {kind,id,title}.

    Display-form (label) URIs resolve to their PARENT attribute, so any label ref
    in MAQL rewrites to `{attribute/<parentId>}` — exactly what maql.py expects.
    """
    ref = {}          # uri or identifier -> {"kind","id","title"}
    syms = {"fact": {}, "attribute": {}, "metric": {}}

    def add(kind, uri, ident, title):
        oid = _last(uri)
        rec = {"kind": kind, "id": oid, "title": title or oid}
        if uri:   ref[uri] = rec
        if ident: ref[ident] = rec
        if oid:   syms[kind][oid] = rec["title"]

    for res, kind in (("facts", "fact"), ("attributes", "attribute"), ("metrics", "metric")):
        for e in query_entries(c, pid, res):
            add(kind, e.get("link"), e.get("identifier"), e.get("title"))

    # attribute display forms -> parent attribute (so label refs resolve)
    attr_uris = [e.get("link") for e in query_entries(c, pid, "attributes")]
    for uri, obj in bulk_get(c, pid, attr_uris).items():
        parent = ref.get(uri)
        if not parent:
            continue
        for df in (obj.get("content", {}) or {}).get("displayForms", []) or []:
            meta = df.get("meta", {}) or {}
            df_uri, df_ident = meta.get("uri"), meta.get("identifier")
            if df_uri:   ref[df_uri] = parent
            if df_ident: ref[df_ident] = parent
    return ref, syms


def normalize_maql(expr, ref):
    """Rewrite classic `[<uri-or-identifier>]` refs -> Cloud `{kind/id}` tokens."""
    if not expr:
        return expr
    import re

    def sub(m):
        inner = m.group(1).strip()
        rec = ref.get(inner)
        if not rec:
            return m.group(0)          # leave unresolved -> translator tags UNHANDLED
        return f"{{{rec['kind']}/{rec['id']}}}"

    return re.sub(r"\[([^\]]+)\]", sub, expr)


def discover_project(c, pid):
    proj = c.get(f"/gdc/projects/{pid}")
    title = (((proj.get("project") or {}).get("meta") or {}).get("title")) or pid

    ref, syms = build_ref_map(c, pid)

    # --- metrics: pull detail, normalize MAQL ---
    metric_uris = [e.get("link") for e in query_entries(c, pid, "metrics")]
    metrics = []
    for uri, obj in bulk_get(c, pid, metric_uris).items():
        content = obj.get("content", {}) or {}
        meta = obj.get("meta", {}) or {}
        raw = content.get("expression", "")
        metrics.append({
            "id": _last(uri),
            "title": meta.get("title") or _last(uri),
            "content": {
                "maql": normalize_maql(raw, ref),
                "expressionRaw": raw,
                "format": content.get("format"),
            },
        })

    # --- datasets: group attributes/facts (best-effort) ---
    ds_uris = [e.get("link") for e in query_entries(c, pid, "datasets")]
    datasets = []
    for uri, obj in bulk_get(c, pid, ds_uris).items():
        content = obj.get("content", {}) or {}
        meta = obj.get("meta", {}) or {}

        def resolve(uris, kind):
            res = []
            for u in uris or []:
                r = ref.get(u)
                if r and r["kind"] == kind:
                    res.append({"id": r["id"], "title": r["title"]})
            return res
        datasets.append({
            "id": _last(uri),
            "title": meta.get("title") or _last(uri),
            "attributes": resolve(content.get("attributes"), "attribute"),
            "facts": resolve(content.get("facts"), "fact"),
        })
    if not datasets:      # fall back to a flat synthetic dataset so counts survive
        datasets = [{
            "id": "_all",
            "title": "(ungrouped)",
            "attributes": [{"id": i, "title": t} for i, t in syms["attribute"].items()],
            "facts": [{"id": i, "title": t} for i, t in syms["fact"].items()],
        }]

    def simple(res):
        return [{"id": _last(e.get("link")), "title": e.get("title")}
                for e in query_entries(c, pid, res)]

    return {
        "product": "platform",
        "host": c.host,
        "project": {"id": pid, "title": title},
        "ldm": {"datasets": datasets},
        "analytics": {
            "metrics": metrics,
            "reports": simple("reports"),
            "projectDashboards": simple("projectdashboards"),
            "analyticalDashboards": simple("analyticaldashboards"),
        },
        "symbols": syms,
    }


def summarize(layout):
    an = layout["analytics"]
    ds = layout["ldm"]["datasets"]
    nattr = sum(len(d["attributes"]) for d in ds)
    nfact = sum(len(d["facts"]) for d in ds)
    syms = layout["symbols"]
    cats = {}
    for m in an["metrics"]:
        cat = translate(m["content"]["maql"], syms).get("category", "UNHANDLED")
        cats[cat] = cats.get(cat, 0) + 1
    print(f"\n=== {layout['project']['id']}  {layout['project']['title']} ===")
    print(f"  datasets {len(ds)} | attributes {nattr} | facts {nfact} | metrics {len(an['metrics'])}")
    print(f"  reports {len(an['reports'])} | legacy dashboards {len(an['projectDashboards'])}"
          f" | KPI dashboards {len(an['analyticalDashboards'])}")
    print(f"  MAQL coverage (via shared translator): {cats}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="list all accessible projects")
    ap.add_argument("--project", help="project id to extract")
    ap.add_argument("--out", default="platform_layout.json")
    a = ap.parse_args()

    c = PlatformClient()
    if a.list:
        for p in c.projects():
            print(f"{p['id']}\t{p['title']}")
        return
    if not a.project:
        sys.exit("--project <id> or --list required")

    layout = discover_project(c, a.project)
    summarize(layout)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(layout, fh, indent=2)
    print(f"\n  wrote {a.out}")


if __name__ == "__main__":
    main()
