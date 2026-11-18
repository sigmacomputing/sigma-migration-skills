#!/usr/bin/env python3
"""Live SQL of the page summaries (class D) of a --model-shape pbi workbook.

For each page-fact.json, the summary's own SQL with one guarded predicate per slicer the summary does not carry
(a slicer outside its grain), injected after every `/*@slicers fact="T" alias="f" [userelationship=...]*/` hook.
Each predicate follows the filter path from the slicer's table to THAT hook's fact (a USERELATIONSHIP hook
uses its activated path); a hook whose fact the slicer does not reach is left alone, as in Power BI. No gate and no union:
the caller (PbiDirectSources.live_element!) puts the SQL in one workbook Custom SQL element the page's charts read.

  pbi-live-page-fact.py --spec workbook-spec.json --page-facts DIR --model model.bim --dm-spec dm-spec.json \
      --master-map master-map.json --out live-page-facts.json [--dialect snowflake]

Writes {"summaries": [{"page","summary","sql","controls":[{control_id,title,field}],"skipped":[...],"hooks":[...]}]}.
Python stdlib only; offline.
"""
import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
from pbi_page_closure import (  # noqa: E402
    FilterGraph, Model, SourceIndex, Unsupported, describe_path, find_hooks, load_json, norm, parse_activations, semi_join,
)

_spec = importlib.util.spec_from_file_location("wire_slicer_gate", os.path.join(HERE, "wire-slicer-gate.py"))
wsg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wsg)


def live_sql(model, src, pf_sql, gated, dialect):
    hooks = find_hooks(pf_sql)
    if not hooks:
        raise Unsupported("the page-fact SQL has no /*@slicers fact=\"...\" alias=\"...\"*/ hook")
    rnd = wsg.Renderer("live")
    pieces, last, report = [], 0, []
    for h in hooks:
        fact = model.table(h["fact"])
        if not fact:
            raise Unsupported("hook names fact %r, which is not a model table" % h["fact"])
        graph = FilterGraph(model, parse_activations(model, h["userelationship"]))
        add, hr = [], {"fact": fact, "alias": h["alias"], "activations": len(parse_activations(model, h["userelationship"])), "predicates": []}
        for g in gated:
            t, c = g["field"]
            path, info = graph.best_path(t, fact)
            if path is None:
                hr["predicates"].append({"control": g["control_id"], "skipped": info.get("reason") or "no path"})
                continue
            col_ident, _ = src.column(t, c)
            cond = semi_join(src, path, col_ident, h["alias"], rnd.values(g["control_id"]),
                             blank=g["blank_policy"] == "row", dialect=dialect, refs=h["sources"], typed=g.get("typed", False))
            add.append("AND (CASE WHEN %s = 0 THEN TRUE ELSE %s END)" % (rnd.length(g["control_id"]), cond))
            hr["predicates"].append({"control": g["control_id"], "path": describe_path(path, graph.activated)})
        pieces.append(pf_sql[last:h["span"][1]])
        pieces.append("".join("\n    " + x for x in add))
        last = h["span"][1]
        report.append(hr)
    pieces.append(pf_sql[last:])
    return "".join(pieces), report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for a in ("spec", "page-facts", "model", "dm-spec", "master-map", "out"):
        ap.add_argument("--" + a, required=True)
    ap.add_argument("--dialect", default="snowflake", choices=["snowflake", "databricks", "bigquery"])
    a = ap.parse_args(argv)
    try:
        spec = wsg.document(load_json(a.spec))
        model = Model(load_json(a.model))
        mm = load_json(a.master_map)
        src = SourceIndex(model, load_json(a.dm_spec), mm, follow_children=True)
        pfs = wsg.load_page_facts(getattr(a, "page_facts"))
    except (OSError, ValueError) as e:
        print("pbi-live-page-fact: %s" % e, file=sys.stderr)
        return 2
    E = {e["id"]: e for e in spec["elements"]}
    pages = wsg.page_blocks(spec.get("layout"))
    out = []
    for pf in pfs:
        rec = {"page": pf["page"], "summary": pf["name"], "sql": None, "controls": [], "skipped": [], "hooks": []}
        out.append(rec)
        pid = "page-%s" % pf.get("page_id") if pf.get("page_id") else None
        if pid not in pages:
            pid = next((p["id"] for p in spec.get("pages", []) if norm(p.get("name")) == norm(pf["page"])), None)
        ctl_by_el = {i: E[i] for i in pages.get(pid, []) if i in E and E[i].get("kind") == "control"}
        pf_sql = wsg.page_fact_sql(pf, src)
        if not find_hooks(pf_sql):
            rec["skipped"].append({"reason": "the summary SQL has no /*@slicers*/ hook"})
            continue
        gated = []
        for s in pf.get("slicers") or []:
            el = ctl_by_el.get(s["element_id"])
            t, _, c = s["field"].rpartition(".")
            field = model.column(t, c)
            who = {"slicer": s["title"], "field": s["field"]}
            if el is None:
                rec["skipped"].append(dict(who, reason="no control on the page (not built or held back)"))
                continue
            if s.get("in_grain"):
                continue  # the summary carries it: the builder wired the control to the summary's column
            primary = el
            if el.get("controlType") == "synced":
                primary = next((e for e in spec["elements"] if e.get("kind") == "control" and e.get("controlId") == el.get("controlId")
                                and e.get("controlType") != "synced"), None)
            if primary is None or primary.get("controlType") != "list":
                rec["skipped"].append(dict(who, reason="only list controls can parameterise the live element"))
                continue
            if not field:
                rec["skipped"].append(dict(who, reason="field is not a model column"))
                continue
            ctype = s.get("column_type") or model.column_type(*field)
            typed = ctype != "string"
            cand = {"control_id": el["controlId"], "field": field, "title": s["title"],
                    "blank_policy": "none" if typed else s.get("blank_policy", "row"), "typed": typed}
            why = wsg.slicer_unready(model, src, pf_sql, cand, a.dialect)
            if why:
                rec["skipped"].append(dict(who, reason=why))
                continue
            gated.append(cand)
        if not gated:
            continue
        try:
            sql, hooks = live_sql(model, src, pf_sql, gated, a.dialect)
        except Unsupported as e:
            rec["skipped"].append({"reason": str(e)})
            continue
        rec["sql"] = sql
        rec["controls"] = [{"control_id": g["control_id"], "title": g["title"], "field": "%s.%s" % g["field"]} for g in gated]
        rec["hooks"] = [{"fact": h["fact"], "alias": h["alias"], "activations": h["activations"], "predicates": h["predicates"]} for h in hooks]
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"summaries": out}, f, indent=1, ensure_ascii=False)
        f.write("\n")
    for r in out:
        print("summary %r: %d slicer(s) live, %d skipped" % (r["summary"], len(r["controls"]), len(r["skipped"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
