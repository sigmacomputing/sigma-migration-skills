#!/usr/bin/env python3
"""wire-slicer-gate.py - wire page slicers a page fact does not carry, through a union gate.

refs/large-pbix.md ("Slicers on dimensions a page fact does not carry") describes the recipe;
this script applies it to a built workbook spec, for every page fact integrated by
integrate-page-fact.py:

  page copy U (the element the page's charts read)
    source = union( G = the materialized page-fact master filtered to Param Filter Count == 0 ,
                    B = the page-fact SQL with each slicer applied where Power BI applies it )
  G's Param Filter Count = ArrayLength([Ctl1]) + ArrayLength([Ctl2]) + ...
  B: at every /*@slicers fact=... alias=...*/ hook of the page-fact SQL, i.e. on the fact rows
     before any window or ratio:
       AND ({{#formula ArrayLength([Ctl1])}} + ...) > 0            -- closed branch when no slicer is set
       AND (CASE WHEN {{#formula ArrayLength([Ctl])}} = 0 THEN TRUE ELSE <semi-join> END)
     The semi-join follows the ACTIVE relationship path from the slicer's table to the hook's
     fact, with the hook's USERELATIONSHIP activations and Power BI's path-weight rule (so a
     slicer on a bridged dimension reaches the fact through the bridge), one IN (SELECT ...) per
     hop, and the (Blank) member: COALESCE(attr, '(Blank)') IN {{Ctl}} plus fact rows whose key
     is NULL or unmatched.

Each gated control gets a Custom SQL value list (COALESCE(<col>, '(Blank)') plus a '(Blank)' row,
or no blank member for slicers that hide blanks), keeps include-mode saved defaults, and keeps
its existing filter targets only when its column is text. One {{#formula}} template per control
(a long sum inside one template trips Sigma's formula depth limit at POST). U also carries a
"Slicer Filter Count" column that names every gated control, so the control lint sees the
charts in each control's reach (it does not follow union sources).

A slicer in the page-fact grain is wired straight to U's column. A slicer whose table reaches
none of the page fact's hooks, an ambiguous path, or a date/number range control is reported
and left as built.

Usage
  python3 scripts/wire-slicer-gate.py --spec <WORK>/workbook-spec.json --page-facts <DIR> \\
      --model <model.bim> --dm-spec <dm-spec.json> --master-map <master-map.json> --connection <id> \\
      [--control-scope <WORK>/control-scope.json] [--layout-out <WORK>/layout.xml] \\
      [--report <WORK>/slicer-gate.json] [--verify-out <WORK>/slicer-gate-verify.json] [--out <spec>]
  The spec is rewritten in place unless --out. Exit 0 = written (skips are reported), 2 = input error.

--verify-out writes sigma-sql-probe.py queries for refs/large-pbix.md's verification step:
<page>__neutral (B with the gate open and every control empty) and <page>__page_fact (the page
fact itself), each as one row of COUNT(*) and every component's SUM, which must be equal, plus
a parity-from-oracle plan (slicer-gate-verify-plan.json) that compares them.
Python stdlib only; offline.
"""
import argparse
import copy
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
from pbi_page_closure import (  # noqa: E402
    FilterGraph, Model, SourceIndex, Unsupported, describe_path, find_hooks, load_json, norm,
    parse_activations, quote_ident, semi_join, short_hash, sql_literal, text_cast,
)

UNION_COUNT_NAME = "Slicer Filter Count"
GATE_NAME = "Param Filter Count"


def load_page_facts(path):
    out = []
    if os.path.isdir(path):
        for d in sorted(os.listdir(path)):
            f = os.path.join(path, d, "page-fact.json")
            if os.path.exists(f):
                out.append(load_json(f))
        if os.path.exists(os.path.join(path, "page-fact.json")):
            out.append(load_json(os.path.join(path, "page-fact.json")))
    else:
        out.append(load_json(path))
    return out


def document(spec):
    for k in ("document", "contents"):
        if isinstance(spec.get(k), dict) and "elements" in spec[k]:
            return spec[k]
    return spec


def page_blocks(layout):
    """{page id: [element ids in that page's layout block]} (containers included)."""
    out = {}
    for m in re.finditer(r'<Page\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</Page>', layout or "", re.S):
        out.setdefault(m.group(1), []).extend(re.findall(r'elementId="([^"]+)"', m.group(2)))
    return out


def source_id(el):
    s = el.get("source")
    if not isinstance(s, dict):
        return None
    if s.get("kind") == "source" and isinstance(s.get("source"), dict):
        s = s["source"]
    return s.get("elementId")


class Renderer:
    """Renders Sigma templates live, neutral (gate open, every control empty) or filtered."""

    def __init__(self, mode="live", picks=None):
        self.mode, self.picks = mode, picks or {}

    def length(self, ctl):
        if self.mode == "live":
            return "{{#formula ArrayLength([" + ctl + "])}}"
        return str(len(self.picks.get(ctl, [])))

    def values(self, ctl):
        if self.mode == "live":
            return "{{" + ctl + "}}"
        vals = self.picks.get(ctl) or [""]
        return "(" + ", ".join(sql_literal(v if v is None else str(v)) for v in vals) + ")"

    def gate(self, ctls):
        if self.mode == "neutral":
            return "(1) > 0"
        return "(" + " + ".join(self.length(c) for c in ctls) + ") > 0"


def gated_sql(model, src, pf_sql, gated, rnd, dialect):
    """The page-fact SQL with the gate and every gated control's predicate at each hook."""
    hooks = find_hooks(pf_sql)
    if not hooks:
        raise Unsupported("the page-fact SQL has no /*@slicers fact=\"...\" alias=\"...\"*/ hook")
    ctls = [g["control_id"] for g in gated]
    pieces, last = [], 0
    hook_report = []
    for h in hooks:
        fact = model.table(h["fact"])
        if not fact:
            raise Unsupported("hook names fact %r, which is not a model table" % h["fact"])
        acts = parse_activations(model, h["userelationship"])
        graph = FilterGraph(model, acts)
        add = ["AND " + rnd.gate(ctls)]
        hr = {"fact": fact, "activations": len(acts), "predicates": []}
        for g in gated:
            t, c = g["field"]
            path, info = graph.best_path(t, fact)
            if path is None:
                hr["predicates"].append({"control": g["control_id"], "skipped": info.get("reason") or "no path",
                                         "ambiguous": info.get("ambiguous", False)})
                continue
            col_ident, _ = src.column(t, c)
            cond = semi_join(src, path, col_ident, h["alias"], rnd.values(g["control_id"]),
                             blank=g["blank_policy"] == "row", dialect=dialect, refs=h["sources"], typed=g.get("typed", False))
            add.append("AND (CASE WHEN %s = 0 THEN TRUE ELSE %s END)" % (rnd.length(g["control_id"]), cond))
            hr["predicates"].append({"control": g["control_id"], "path": describe_path(path, graph.activated)})
        pieces.append(pf_sql[last:h["span"][1]])
        pieces.append("".join("\n    " + x for x in add))
        last = h["span"][1]
        hook_report.append(hr)
    pieces.append(pf_sql[last:])
    return "".join(pieces), hook_report


def page_fact_sql(pf, src):
    """The page-fact SQL as it sits in the data model (falls back to page-fact.json)."""
    dm_el = next((e for e in src.elements if e.get("name") == pf["name"]), None)
    if dm_el and (dm_el.get("source") or {}).get("statement"):
        return dm_el["source"]["statement"]
    return pf["sql"]


def slicer_unready(model, src, pf_sql, g, dialect):
    """Why this slicer cannot be gated (None when it can): no hook reachable, an unresolvable source
    or column on its path, or no value list. Checked per slicer so one bad slicer skips, not aborts."""
    reached = []
    for h in find_hooks(pf_sql):
        fact = model.table(h["fact"])
        if not fact:
            continue
        graph = FilterGraph(model, parse_activations(model, h["userelationship"]))
        try:
            graph.require_resolved()
        except Unsupported as e:
            return str(e)
        path, info = graph.best_path(g["field"][0], fact)
        if path is None:
            if info.get("ambiguous"):
                return "ambiguous filter path to %s: %s" % (fact, info.get("reason"))
            continue
        try:
            col_ident, _ = src.column(*g["field"])
            semi_join(src, path, col_ident, h["alias"], "{{x}}", blank=not g.get("typed"), dialect=dialect, refs=h["sources"],
                      typed=g.get("typed", False))
        except Unsupported as e:
            return str(e)
        reached.append(fact)
    if not reached:
        return "%s reaches none of the page fact's hooks (no active relationship path)" % g["field"][0]
    if not g.get("typed"):
        try:
            value_list_sql(src, g["field"], g["blank_policy"], dialect)
        except Unsupported as e:
            return "no value list: %s" % e
    return None


def value_list_sql(src, field, policy, dialect):
    t, c = field
    col, _ = src.column(t, c)
    frm = src.from_sql(t)
    if policy == "row":
        return ("SELECT DISTINCT COALESCE(%s, '(Blank)') AS V FROM %s d\nUNION\nSELECT '(Blank)' AS V"
                % (text_cast("d." + col, dialect), frm))
    return "SELECT DISTINCT %s AS V FROM %s d WHERE d.%s IS NOT NULL" % (text_cast("d." + col, dialect), frm, col)


def append_to_data_page(doc, ids):
    lay = doc.get("layout") or ""
    data_pid = next((p["id"] for p in doc.get("pages", []) if p.get("visibility") == "hidden" or p.get("name") == "Data"), None)
    if not data_pid:
        raise Unsupported("the workbook has no hidden Data page to hold the gate elements")
    m = re.search(r'(<Page\b[^>]*\bid="%s"[^>]*>)(.*?)(</Page>)' % re.escape(data_pid), lay, re.S)
    if not m:
        raise Unsupported("the layout has no block for the Data page %s" % data_pid)
    ends = [int(x) for x in re.findall(r'gridRow="\d+\s*/\s*(\d+)"', m.group(2))]
    r0 = max(ends) if ends else 1
    add = "".join('  <Element elementId="%s" gridColumn="1 / 25" gridRow="%d / %d"/>\n' % (eid, r0 + i * 10, r0 + i * 10 + 10)
                  for i, eid in enumerate(ids))
    body = m.group(2)
    if body and not body.endswith("\n"):
        body += "\n"
    doc["layout"] = lay[:m.start(2)] + body + add + lay[m.end(2):]


def repoint(el, old, new, colmap):
    """Move one element (and its formulas) from source `old` to `new`. A control's own value-list
    `source` stays on the master (the unfiltered domain); its filter targets move."""
    txt = json.dumps(el)
    txt = txt.replace('"elementId": "%s"' % old, '"elementId": "%s"' % new).replace("[%s/" % old, "[%s/" % new)
    out = json.loads(txt)
    if out.get("kind") == "control":
        if "source" in el:
            out["source"] = el["source"]
        for f in out.get("filters") or []:
            if (f.get("source") or {}).get("elementId") == new and f.get("columnId") in colmap:
                f["columnId"] = colmap[f["columnId"]]
    return out


def wire_direct(rec, pf, ctl_by_el, target, col_ids, master_id, els=None):
    """In-grain slicers: each control must filter `target` (the element the charts read) on its column."""
    for d in rec["direct"]:
        s = next((x for x in pf.get("slicers") or [] if ctl_by_el.get(x["element_id"], {}).get("controlId") == d["control"]), None)
        if not s:
            continue
        col = next((c["name"] for c in pf["columns"] if c.get("field") == s["field"]), None)
        el = ctl_by_el[s["element_id"]]
        if els is not None:
            el = next((e for e in els if e["id"] == el["id"]), el)
        if not col or col not in col_ids:
            d["note"] = "grain column for %s not found on %s" % (s["field"], target)
            continue
        fl = [f for f in el.get("filters") or [] if (f.get("source") or {}).get("elementId") != master_id or target == master_id]
        if not any((f.get("source") or {}).get("elementId") == target for f in fl):
            fl.append({"source": {"kind": "table", "elementId": target}, "columnId": col_ids[col]})
            d["target"] = target
        el["filters"] = fl


def wire_page(spec_doc, pf, ctx, report):
    model, src, mm, conn, dialect = ctx["model"], ctx["src"], ctx["mm"], ctx["connection"], ctx["dialect"]
    els = spec_doc["elements"]
    E = {e["id"]: e for e in els}
    master = (mm.get("masters") or {}).get(pf["name"])
    rec = {"page": pf["page"], "page_fact": pf["name"], "gated": [], "direct": [], "skipped": [], "unreached": []}
    report["pages"].append(rec)
    if not master or master.get("id") not in E:
        rec["skipped"].append({"reason": "the page-fact master is not in the workbook (integrate it and rebuild first)"})
        return None
    mid = master["id"]
    pid = "page-%s" % pf.get("page_id") if pf.get("page_id") else None
    pages = page_blocks(spec_doc.get("layout"))
    if pid not in pages:
        pid = next((p["id"] for p in spec_doc.get("pages", []) if norm(p.get("name")) == norm(pf["page"])), None)
    if pid not in pages:
        rec["skipped"].append({"reason": "page %r not found in the workbook layout" % pf["page"]})
        return None
    on_page = [E[i] for i in pages[pid] if i in E]
    content = [e for e in on_page if e.get("kind") not in ("control", "container", "text", "image", "button")]
    readers = {source_id(e) for e in content}
    copies = [e for e in els if source_id(e) == mid and e["id"] in readers]
    if copies:
        u = copies[0]
        new_union = False
    elif mid in readers:
        u = None
        new_union = True
    else:
        rec["skipped"].append({"reason": "no chart on the page reads the page-fact master"})
        return None
    mcols = [c["name"] for c in E[mid].get("columns", [])]
    out_of = {c["name"]: c["out"] for c in pf["columns"]}
    missing = [n for n in mcols if n not in out_of]
    if missing:
        rec["skipped"].append({"reason": "master columns %s are not page-fact columns" % missing})
        return None
    if not find_hooks(page_fact_sql(pf, src)):
        rec["skipped"].append({"reason": "the page-fact SQL has no /*@slicers fact=\"...\" alias=\"...\"*/ hook: add one to the "
                                         "WHERE clause of each fact's CTE (scaffold-page-fact.py writes them), then rerun"})
        return rec
    # controls on the page, keyed by element id
    ctl_by_el = {e["id"]: e for e in on_page if e.get("kind") == "control"}
    gated = []
    for s in pf.get("slicers") or []:
        el = ctl_by_el.get(s["element_id"])
        t, _, c = s["field"].rpartition(".")
        field = model.column(t, c)
        if el is None:
            rec["skipped"].append({"slicer": s["title"], "reason": "no control %s on the page (not built or held back)" % s["element_id"]})
            continue
        if el.get("controlType") == "synced":
            rec["skipped"].append({"slicer": s["title"], "reason": "synced copy: its primary control carries the wiring"})
            continue
        if s.get("in_grain"):
            rec["direct"].append({"slicer": s["title"], "control": el.get("controlId")})
            continue
        if el.get("controlType") != "list":
            rec["skipped"].append({"slicer": s["title"], "reason": "%s control: only list controls are gated" % el.get("controlType")})
            continue
        if not field:
            rec["skipped"].append({"slicer": s["title"], "reason": "field %s is not a model column" % s["field"]})
            continue
        ctype = s.get("column_type") or model.column_type(*field)
        typed = ctype != "string"
        cand = {"element": el, "control_id": el["controlId"], "field": field, "title": s["title"],
                "blank_policy": "none" if typed else s.get("blank_policy", "row"), "typed": typed,
                "column_type": ctype, "saved_selection": s.get("saved_selection")}
        if typed and el.get("mode") == "exclude" and el.get("values"):
            rec["skipped"].append({"slicer": s["title"], "reason": "a typed exclude-mode default (%r) cannot be expressed as "
                                                                   "an IN list in the parameterized SQL" % el["values"]})
            continue
        why = slicer_unready(model, src, page_fact_sql(pf, src), cand, ctx["dialect"])
        if why:
            rec["skipped"].append({"slicer": s["title"], "reason": why})
            continue
        gated.append(cand)
    tag = short_hash(pid + "|" + mid, 8)
    if not gated:
        # nothing to gate: only make sure in-grain slicers filter the element the charts read
        reader = u if u is not None else E[mid]
        wire_direct(rec, pf, ctl_by_el, reader["id"], {c["name"]: c["id"] for c in reader.get("columns", [])}, mid)
        rec["note"] = "no slicer needs the gate"
        return rec
    uid = u["id"] if u else "pfu-" + tag
    if u is not None:
        union_col_id = {c["name"]: c["id"] for c in u.get("columns", [])}
    else:
        union_col_id = {c["name"]: "%s-%d" % (uid, i) for i, c in enumerate(E[mid].get("columns", []))}
    colmap = {c["id"]: union_col_id[c["name"]] for c in E[mid].get("columns", [])} if u is None else {}
    pf_sql = page_fact_sql(pf, src)
    ctls = [g["control_id"] for g in gated]
    b_sql, hooks = gated_sql(model, src, pf_sql, gated, Renderer("live"), dialect)
    neutral_sql, _ = gated_sql(model, src, pf_sql, gated, Renderer("neutral"), dialect)
    gid, bid = "pfg-" + tag, "pfp-" + tag
    gate_formula = " + ".join("ArrayLength([%s])" % c for c in ctls)
    G = {"id": gid, "kind": "table", "name": "%s (fast path)" % pf["name"], "source": {"kind": "table", "elementId": mid},
         "columns": [{"id": "%s-%d" % (gid, i), "name": n, "formula": "[%s/%s]" % (mid, n)} for i, n in enumerate(mcols)]
         + [{"id": gid + "-gate", "name": GATE_NAME, "formula": gate_formula}],
         "filters": [{"id": "flt-" + gid, "columnId": gid + "-gate", "kind": "list", "mode": "include", "values": [0]}]}
    B = {"id": bid, "kind": "table", "name": "%s (filtered by slicers)" % pf["name"],
         "source": {"kind": "sql", "connectionId": conn, "statement": b_sql},
         "columns": [{"id": "%s-%d" % (bid, i), "name": n, "formula": "[Custom SQL/%s]" % out_of[n]} for i, n in enumerate(mcols)]}
    union_src = {"kind": "union", "sources": [{"kind": "table", "elementId": gid}, {"kind": "table", "elementId": bid}],
                 "matches": [{"outputColumnName": n, "sourceColumns": ["[%s]" % n, "[%s]" % n]} for n in mcols]}
    ucols = [{"id": union_col_id[n], "name": n, "formula": "[Union of 2 Sources/%s]" % n} for n in mcols]
    ucols.append({"id": uid + "-slicers", "name": UNION_COUNT_NAME, "formula": gate_formula})
    if u is not None:
        old = {c["name"]: c for c in u.get("columns", [])}
        for c in ucols:
            if c["name"] in old and old[c["name"]].get("format"):
                c["format"] = old[c["name"]]["format"]
        u["source"] = union_src
        u["columns"] = ucols
        new_ids = [gid, bid]
    else:
        U = {"id": uid, "kind": "table", "name": "%s (%s)" % (pf["name"], pf["page"]), "source": union_src, "columns": ucols}
        for i, e in enumerate(els):
            if e["id"] in pages[pid] and e["id"] != mid:
                els[i] = repoint(e, mid, uid, colmap)
        els.append(U)
        new_ids = [uid, gid, bid]
    els.extend([G, B])
    wire_direct(rec, pf, ctl_by_el, uid, union_col_id, mid, els)
    # gated controls: value lists, defaults, filter targets
    for g in gated:
        el = next(e for e in els if e["id"] == g["element"]["id"])
        note = {}
        # the page fact does not carry the column: a target on it (a slicer the builder bound to a grain
        # column some fact cannot reach) would drop that fact's rows; the SQL predicate replaces it
        before = el.get("filters") or []
        kept = [f for f in before if (f.get("source") or {}).get("elementId") not in (mid, uid)]
        if len(kept) != len(before):
            note["page_fact_target"] = "removed the direct filter on the page fact (its predicate is in the SQL now)"
        el["filters"] = kept
        if g["typed"]:
            # typed list (number/date/boolean): keep the builder's typed value list, defaults and other targets;
            # the SQL compares the raw column, so there is no (Blank) member
            note["value_list"] = "typed %s list kept; no (Blank) member" % g["column_type"]
        else:
            lid = "pfl-" + short_hash(g["control_id"], 8)
            if not any(e["id"] == lid for e in els):
                els.append({"id": lid, "kind": "table", "name": "%s values" % (el.get("name") or g["title"]),
                            "source": {"kind": "sql", "connectionId": conn,
                                       "statement": value_list_sql(src, g["field"], g["blank_policy"], dialect)},
                            "columns": [{"id": lid + "-v", "name": "Value", "formula": "[Custom SQL/V]"}]})
                new_ids.append(lid)
            el["source"] = {"kind": "source", "source": {"kind": "table", "elementId": lid}, "columnId": lid + "-v"}
            g["value_list"] = lid
            if el.get("mode") == "exclude":
                if el.get("values"):
                    note["default"] = "exclude-mode default %r not representable in parameterized SQL; reset to all" % el["values"]
                el["mode"], el["values"] = "include", []
            else:
                vals = [str(v) for v in el.get("values") or [] if v is not None]
                sel = g.get("saved_selection") or {}
                if vals and sel.get("has_null") and g["blank_policy"] == "row" and str(sel.get("mode")) != "exclude":
                    vals.append("(Blank)")  # the value list carries the blank member the saved selection picked
                el["values"] = vals
        rec["gated"].append(dict({"slicer": g["title"], "control": g["control_id"], "field": "%s[%s]" % g["field"],
                                  "blank_policy": g["blank_policy"], "value_list": g.get("value_list")}, **note))
    rec.update(union=uid, fast_path=gid, parameterized=bid, hooks=hooks, sql_chars=len(b_sql), unreached=[])
    for h in hooks:
        for p in h["predicates"]:
            if "skipped" in p:  # a gated slicer that does not reach THIS fact: it leaves that fact alone, as in Power BI
                rec["unreached"].append({"control": p["control"], "fact": h["fact"], "reason": p["skipped"]})
    ctx["new_layout"].extend(new_ids)
    comps = [c for c in pf["columns"] if c.get("role") == "component"]
    summ = ", ".join(["COUNT(*) AS %s" % quote_ident("ROWS")] + ["SUM(%s) AS %s" % (quote_ident(c["out"]), quote_ident(c["out"]))
                                                            for c in comps])
    key = re.sub(r"[^0-9a-z]+", "-", pf["page"].lower()).strip("-")
    ctx["verify"][key + "__neutral"] = "SELECT %s FROM (\n%s\n) x" % (summ, strip_comments(neutral_sql))
    ctx["verify"][key + "__page_fact"] = "SELECT %s FROM (\n%s\n) x" % (summ, strip_comments(pf_sql))
    ctx["verify_plan"].append({"name": "%s: gated SQL with every control empty = page fact" % pf["page"],
                               "export": "slicer-gate-verify-results.json", "export_key": key + "__neutral",
                               "oracle": "slicer-gate-verify-results.json", "oracle_key": key + "__page_fact", "keys": []})
    readers_of_u = [e["id"] for e in els if e["id"] in pages[pid] and source_id(e) == uid]
    ctx["scope_updates"].append((ctls, readers_of_u))
    return rec


def strip_comments(sql):
    return "\n".join(line for line in sql.split("\n") if not line.lstrip().startswith("--"))


def update_control_scope(path, updates):
    if not path or not os.path.exists(path):
        return 0
    cs = load_json(path)
    n = 0
    for ctls, charts in updates:
        for row in cs.get("controls") or []:
            if row.get("controlId") not in ctls:
                continue
            ex = row.get("excluded") or []
            moved = [x for x in ex if (x.get("element") if isinstance(x, dict) else x) in charts]
            row["excluded"] = [x for x in ex if x not in moved]
            scope = row.get("scope") if isinstance(row.get("scope"), list) else []
            for x in moved:
                eid = x.get("element") if isinstance(x, dict) else x
                if eid not in scope:
                    scope.append(eid)
                    n += 1
            row["scope"] = scope
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cs, f, indent=2)
        f.write("\n")
    return n


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--spec", required=True)
    ap.add_argument("--page-facts", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--dm-spec", required=True)
    ap.add_argument("--master-map", required=True)
    ap.add_argument("--connection", required=True)
    ap.add_argument("--control-scope")
    ap.add_argument("--layout-out")
    ap.add_argument("--report")
    ap.add_argument("--verify-out")
    ap.add_argument("--out")
    ap.add_argument("--dialect", default="snowflake", choices=["snowflake", "databricks", "bigquery"])
    a = ap.parse_args(argv)
    try:
        spec = load_json(a.spec)
        model = Model(load_json(a.model))
        mm = load_json(a.master_map)
        src = SourceIndex(model, load_json(a.dm_spec), mm)
        pfs = load_page_facts(a.page_facts)
    except (OSError, ValueError) as e:
        print("wire-slicer-gate: %s" % e, file=sys.stderr)
        return 2
    doc = document(spec)
    ctx = {"model": model, "src": src, "mm": mm, "connection": a.connection, "dialect": a.dialect,
           "new_layout": [], "verify": {}, "verify_plan": [], "scope_updates": []}
    report = {"generated_by": "wire-slicer-gate.py", "pages": []}
    before = copy.deepcopy(doc)
    try:
        for pf in pfs:
            wire_page(doc, pf, ctx, report)
        if ctx["new_layout"]:
            append_to_data_page(doc, ctx["new_layout"])
    except Unsupported as e:
        print("wire-slicer-gate: %s (nothing written)" % e, file=sys.stderr)
        doc.clear()
        doc.update(before)
        return 2
    out = a.out or a.spec
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(spec, f, indent=1, ensure_ascii=False)
        f.write("\n")
    if a.layout_out:
        with open(a.layout_out, "w", encoding="utf-8", newline="\n") as f:
            f.write(doc.get("layout") or "")
    report["control_scope_promoted"] = update_control_scope(a.control_scope, ctx["scope_updates"])
    if a.report:
        with open(a.report, "w", encoding="utf-8", newline="\n") as f:
            json.dump(report, f, indent=1, ensure_ascii=False)
            f.write("\n")
    if a.verify_out and ctx["verify"]:
        with open(a.verify_out, "w", encoding="utf-8", newline="\n") as f:
            json.dump(ctx["verify"], f, indent=1)
            f.write("\n")
        with open(os.path.join(os.path.dirname(os.path.abspath(a.verify_out)), "slicer-gate-verify-plan.json"), "w", encoding="utf-8", newline="\n") as f:
            json.dump({"charts": ctx["verify_plan"]}, f, indent=1)
            f.write("\n")
    for p in report["pages"]:
        print("page %r: %d slicer(s) gated, %d direct, %d skipped%s%s" % (
            p["page"], len(p["gated"]), len(p["direct"]), len(p["skipped"]),
            (", %d slicer/fact pair(s) unrelated (left alone)" % len(p["unreached"])) if p.get("unreached") else "",
            (" -> %s" % p["union"]) if p.get("union") else ""))
        for s in p["skipped"]:
            print("   skipped %s: %s" % (s.get("slicer") or s.get("control") or "", s["reason"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
