#!/usr/bin/env python3
"""scaffold-page-fact.py - draft a report page's page-fact SQL and its independent oracle.

refs/large-pbix.md ("Measures: classify the page, then build it") says to build a page whose
measures mix facts, re-aggregate per-entity values or depend on slicer-driven context as ONE
page-fact SQL element: grain = the page's grouping columns, one pre-computed column per
additive measure component, with Sigma only summing and dividing. Each of those pages used
to take hours of hand work: reading the DAX closure, writing the CTEs, the joins along the
right relationship paths, the components, then an oracle written separately to check them.
This script does the mechanical part, offline, from the extracted artifacts:

  per page (output in <out-dir>/<page-slug>/)
    closure.md          the brief: visuals, measures, DAX closure (comments stripped, deps first),
                        tables each measure scans, CALCULATE modifiers, selector and time-intelligence
                        calls, slicers and the relationship path each one takes to each fact
                        (USERELATIONSHIP path weight applied), the page classification, and the TODOs
    page-fact.sql       WITH <one CTE per source table> , <one aggregate CTE per fact (and per
                        USERELATIONSHIP set)> joined to the grain along the chosen paths, grouped at
                        the page grain, UNION ALL'd and re-grouped for multi-fact pages. Each fact CTE
                        carries a /*@slicers ...*/ hook that wire-slicer-gate.py fills in later.
                        A measure the decomposer cannot translate is a NULL "TODO_<name>" column with
                        its DAX quoted in the header comment.
    page-fact.json      the same SQL plus columns (name -> SQL output) and the bindings
                        integrate-page-fact.py folds into the DM and master-map:
                        fields {queryRef: {ref: "<Sigma formula over {C:<column>}>"}}, dims {queryRef: column}
    oracle-queries.json sigma-sql-probe.py --in: one INDEPENDENT oracle query per data visual,
                        compiled from the DAX by lib/pbi_semantic_sql.py's constrained compiler
                        (correlated per-cell evaluation over the raw sources, not the page fact),
                        plus optional --scenario filtered variants. Unsupported measures are listed.
    check-queries.json  sigma-sql-probe.py --in: the page fact rolled up to each visual's grain
                        with the same aggregate expressions the Sigma formulas use
    check-plan.json     parity-from-oracle.py --spec: check-queries vs oracle-queries (run BEFORE any
                        workbook exists: proves the page fact against the oracle in the warehouse)
    parity-plan.json    parity-from-oracle.py --spec: the built workbook's element exports
                        (exports/<element id>.csv) vs the oracle
  <out-dir>/page-closure.json   every page: classification, facts, measures, TODO counts

Usage
  python3 scripts/scaffold-page-fact.py --model <WORK>/model.bim --signals <WORK>/signals.json \\
      --dm-spec <WORK>/dm-spec.json [--master-map <WORK>/master-map.json] --out-dir <WORK>/page-facts \\
      [--page "<page title>"]... [--all-pages] [--classify-only] [--grain "<page>|<Table>.<Column>"]... \\
      [--scenario "<Table>.<Column>=<value>"]... [--dialect snowflake|databricks|bigquery]

  Default page selection: every page classified "page-fact" (several facts, USERELATIONSHIP,
  filter removal, selectors or time intelligence). --page selects by title (repeatable).
  Exit 0 = written (TODOs are reported, not errors), 2 = usage/input error.
Python stdlib only; never contacts Sigma or the warehouse.
"""
import argparse
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))

from pbi_page_closure import (  # noqa: E402
    FLOAT_TYPE, TEXT_TYPE, FilterGraph, Model, SourceIndex, Unsupported, describe_path, hook_marker, matching_paren,
    context_filters, join_chain, literal_filter, load_json, norm, normalize_filter, page_inventory, path_json,
    quote_ident, register_implicit_measures, sql_literal, split_top,
)
from pbi_semantic_sql import Compiler, expression, ident  # noqa: E402
from pbi_semantic_sql import Unsupported as CompilerUnsupported  # noqa: E402



def slug(text):
    s = re.sub(r"[^0-9a-zA-Z]+", "-", str(text)).strip("-").lower()
    return s or "page"


def snake(text):
    s = re.sub(r"[^0-9a-zA-Z]+", "_", str(text)).strip("_").upper()
    return s or "X"


# --------------------------------------------------------------------------- classification

def classify(model, inv):
    meas = [m["name"] for m in inv["measures"]]
    closure = model.closure(meas)
    facts, reasons = [], []
    flags = {"userelationship": [], "filter_removal": [], "selectors": [], "time_intel": [], "treatas": [],
             "iterators": []}
    for n in closure:
        info = model.measure_info(n)
        for t in info["scans"]:
            if t not in facts:
                facts.append(t)
        if info["userelationship"]:
            flags["userelationship"].append(n)
        if info["filter_removal"]:
            flags["filter_removal"].append(n)
        if info["selectors"]:
            flags["selectors"].append(n)
        if info["time_intel"]:
            flags["time_intel"].append(n)
        if info["treatas"]:
            flags["treatas"].append(n)
        if set(info["functions"]) & {"SUMX", "AVERAGEX", "MINX", "MAXX", "COUNTX", "RANKX"} and info["scans"]:
            flags["iterators"].append(n)
    multi = []
    for v in inv["visuals"]:
        vf = {t for x in model.closure([m["name"] for m in v["measures"]]) for t in model.measure_info(x)["scans"]}
        if len(vf) > 1:
            multi.append(v["title"])
    if len(facts) > 1:
        reasons.append("several facts (%s)" % ", ".join(facts))
    if flags["userelationship"]:
        reasons.append("USERELATIONSHIP in %s" % ", ".join(flags["userelationship"]))
    if flags["filter_removal"]:
        reasons.append("filter removal in %s" % ", ".join(flags["filter_removal"]))
    if flags["selectors"]:
        reasons.append("selector functions in %s" % ", ".join(flags["selectors"]))
    if flags["time_intel"]:
        reasons.append("time intelligence in %s" % ", ".join(flags["time_intel"]))
    if flags["treatas"]:
        reasons.append("TREATAS in %s" % ", ".join(flags["treatas"]))
    kind = "page-fact" if reasons else "per-visual"
    return {"page": inv["title"], "page_id": inv["page_id"], "classification": kind, "reasons": reasons,
            "facts": facts, "visual_measures": len(meas), "closure": len(closure), "multi_fact_visuals": multi,
            "slicers": len(inv["slicers"]), "flags": flags}


# --------------------------------------------------------------------------- measure decomposition

class Decomposer:
    """DAX measure -> additive components at the page grain + a Sigma formula over them.

    Supported: SUM/MIN/MAX/AVERAGE/COUNT/COUNTA/COUNTROWS over a fact, SUMX/MINX/MAXX/AVERAGEX
    with a row expression over the fact's columns (RELATED() follows the active path), arithmetic,
    DIVIDE (with a numeric alternate), measure references, and CALCULATE with literal comparison /
    IN filters, KEEPFILTERS and USERELATIONSHIP. Everything else raises Unsupported (a TODO)."""

    AGG_OUTER = {"SUM": "SUM", "COUNT": "SUM", "MIN": "MIN", "MAX": "MAX"}
    SIGMA_AGG = {"SUM": "Sum", "COUNT": "Sum", "MIN": "Min", "MAX": "Max"}

    def __init__(self, model, grain, dialect, guarded=None):
        self.model = model
        self.grain = set(grain)
        # columns whose filter a CALCULATE must not replace: grouping columns of the page, plus slicer and
        # report/page filter columns (their filters are applied at the fact rows, for every component)
        self.guarded = {tuple(g): "a grouping column of this page" for g in grain}
        for f, why in (guarded or {}).items():
            self.guarded.setdefault(tuple(f), why)
        self.dialect = dialect
        self.components = {}  # key -> component
        self.order = []
        self.used = set()  # component keys the current measure uses

    # -- components
    def component(self, fact, agg, row, filters, act, label):
        filters = [f[0] if isinstance(f, tuple) else f for f in filters]
        key = (fact, agg, row, tuple(sorted(filters)), tuple(sorted(act)))
        if key not in self.components:
            base = snake(label)
            out = base
            i = 2
            used = {c["out"] for c in self.components.values()}
            while out in used:
                out = "%s_%d" % (base, i)
                i += 1
            self.components[key] = {"out": out, "name": out.replace("_", " ").title(), "fact": fact, "agg": agg,
                                    "row": row, "filters": tuple(sorted(filters)), "act": tuple(sorted(act)),
                                    "label": label}
            self.order.append(key)
        c = self.components[key]
        self.used.add(key)
        return ("%s({C:%s})" % (self.SIGMA_AGG[agg], c["name"]), "%s(%s)" % (self.AGG_OUTER[agg], quote_ident(c["out"])))

    # -- entry
    def measure(self, name):
        """-> (Sigma formula, SQL twin, component keys used)."""
        self.used = set()
        sig, sq = self.node(expression(self.model.expanded(name)), (), (), (name,))
        return sig, sq, set(self.used)

    def node(self, n, filters, act, stack):
        kind = n[0]
        if kind == "number":
            return n[1], n[1]
        if kind == "ref":
            table, name = n[1], n[2]
            m = self.model.measure(name)
            if m and (not table or self.model.measures[m]["table"] == self.model.table(table)):
                if m in stack:
                    raise Unsupported("measure %s references itself" % m)
                return self.node(expression(self.model.expanded(m)), filters, act, stack + (m,))
            raise Unsupported("a bare column reference %s[%s] in a measure needs row context" % (table, name))
        if kind == "binary":
            a, a2 = self.node(n[2], filters, act, stack)
            b, b2 = self.node(n[3], filters, act, stack)
            if n[1] == "/":
                return ("If(IsNull(%s) or %s = 0, Null, %s / %s)" % (b, b, a, b),
                        "CASE WHEN (%s) IS NULL OR (%s) = 0 THEN NULL ELSE (%s) * 1.0 / (%s) END" % (b2, b2, a2, b2))
            if n[1] in "+-":
                # DAX: BLANK counts as 0 in + and -, and BLANK +/- BLANK is BLANK
                return ("If(IsNull(%s) and IsNull(%s), Null, Coalesce(%s, 0) %s Coalesce(%s, 0))" % (a, b, a, n[1], b),
                        "CASE WHEN (%s) IS NULL AND (%s) IS NULL THEN NULL ELSE COALESCE(%s, 0) %s COALESCE(%s, 0) END"
                        % (a2, b2, a2, n[1], b2))
            return "(%s %s %s)" % (a, n[1], b), "(%s %s %s)" % (a2, n[1], b2)
        _, fn, args = n
        args = rejoin_braces(args)
        if fn == "DIVIDE":
            if len(args) not in (2, 3):
                raise Unsupported("DIVIDE takes 2 or 3 arguments")
            a, a2 = self.node(expression(args[0]), filters, act, stack)
            b, b2 = self.node(expression(args[1]), filters, act, stack)
            alt, alt2 = "Null", "NULL"
            if len(args) == 3:
                al = expression(args[2])
                if al[0] != "number":
                    raise Unsupported("DIVIDE alternate result must be a numeric constant")
                alt, alt2 = al[1], al[1]
            return ("If(IsNull(%s) or %s = 0, %s, %s / %s)" % (b, b, alt, a, b),
                    "CASE WHEN (%s) IS NULL OR (%s) = 0 THEN %s ELSE (%s) * 1.0 / (%s) END" % (b2, b2, alt2, a2, b2))
        if fn in ("SUM", "MIN", "MAX", "AVERAGE", "COUNT", "COUNTA"):
            if len(args) != 1:
                raise Unsupported("%s takes one column" % fn)
            ref = self.model.ref_pair(args[0])
            if not ref:
                raise Unsupported("%s argument %s is not a model column" % (fn, args[0]))
            t, c = ref
            row = "{T:%s|%s}" % (t, c)
            label = "%s %s" % (fn.lower(), c)
            return self.aggregate(fn, t, row, filters, act, label)
        if fn == "COUNTROWS":
            if len(args) != 1:
                raise Unsupported("COUNTROWS takes one table")
            t = self.model.table(args[0].strip().strip("'").replace("''", "'"))
            if not t:
                raise Unsupported("COUNTROWS over a table expression (%s)" % args[0])
            return self.aggregate("COUNTROWS", t, "*", filters, act, "rows %s" % t)
        if fn in ("SUMX", "MINX", "MAXX", "AVERAGEX"):
            if len(args) != 2:
                raise Unsupported("%s takes a table and an expression" % fn)
            t = self.model.table(args[0].strip().strip("'").replace("''", "'"))
            if not t:
                raise Unsupported("%s over a table expression (%s)" % (fn, args[0]))
            row = self.row_expr(expression(args[1]), t)
            base = {"SUMX": "SUM", "MINX": "MIN", "MAXX": "MAX", "AVERAGEX": "AVERAGE"}[fn]
            return self.aggregate(base, t, row, filters, act, "%s %s" % (fn.lower(), short_label(args[1])))
        if fn == "CALCULATE":
            if not args:
                raise Unsupported("empty CALCULATE")
            new, na = [], list(act)
            for mod in args[1:]:
                self.modifier(mod, new, na)
            # an inner CALCULATE filter on a column REPLACES the outer filters on that column (KEEPFILTERS
            # intersects); filters of one CALCULATE on the same column intersect each other
            replaced = {col for _p, col, keep in new if col is not None and not keep}
            nf = [f for f in filters if f[1] not in replaced] + new
            return self.node(expression(args[0]), tuple(nf), tuple(na), stack)
        raise Unsupported("DAX function %s is not decomposed into additive components" % fn)

    def aggregate(self, fn, fact, row, filters, act, label):
        if fn == "AVERAGE":
            s, s2 = self.component(fact, "SUM", row, filters, act, "sum " + label.split(" ", 1)[-1])
            k, k2 = self.component(fact, "COUNT", row, filters, act, "count " + label.split(" ", 1)[-1])
            return ("If(IsNull(%s) or %s = 0, Null, %s / %s)" % (k, k, s, k),
                    "CASE WHEN (%s) IS NULL OR (%s) = 0 THEN NULL ELSE (%s) * 1.0 / (%s) END" % (k2, k2, s2, k2))
        if fn in ("COUNT", "COUNTA"):
            return self.component(fact, "COUNT", row, filters, act, label)
        if fn == "COUNTROWS":
            return self.component(fact, "COUNT", "*", filters, act, label)
        return self.component(fact, fn, row, filters, act, label)

    def row_expr(self, n, fact):
        kind = n[0]
        if kind == "number":
            return n[1]
        if kind == "binary":
            return "(%s %s %s)" % (self.row_expr(n[2], fact), n[1], self.row_expr(n[3], fact))
        if kind == "ref":
            ref = self.model.column(n[1] or fact, n[2])
            if not ref or ref[0] != fact:
                raise Unsupported("row expression column %s[%s] is not on %s (use RELATED)" % (n[1], n[2], fact))
            return "{T:%s|%s}" % ref
        _, fn, args = n
        if fn == "RELATED" and len(args) == 1:
            ref = self.model.ref_pair(args[0])
            if not ref:
                raise Unsupported("RELATED(%s)" % args[0])
            return "{T:%s|%s}" % ref
        raise Unsupported("row expression function %s" % fn)

    def modifier(self, mod, filters, act):
        m = mod.strip()
        neg = re.fullmatch(r"NOT\b\s*(.+)", m, re.I | re.S)
        if neg:
            inner = neg.group(1).strip()
            if inner.startswith("(") and matching_paren(inner, 0) == len(inner) - 1:
                inner = inner[1:-1].strip()
            sub = []
            self.modifier(inner, sub, [])
            if not sub:
                raise Unsupported("NOT over a non-filter modifier (%s)" % mod)
            filters.extend(("NOT (%s)" % p, col, keep_) for p, col, keep_ in sub)
            return
        keep = re.fullmatch(r"KEEPFILTERS\s*\((.*)\)", m, re.I | re.S)
        if keep:
            m = keep.group(1).strip()
        u = re.fullmatch(r"USERELATIONSHIP\s*\((.*)\)", m, re.I | re.S)
        if u:
            parts = split_top(u.group(1))
            a, b = (self.model.ref_pair(parts[0]), self.model.ref_pair(parts[1])) if len(parts) == 2 else (None, None)
            if not a or not b:
                raise Unsupported("USERELATIONSHIP(%s) does not name two model columns" % u.group(1))
            FilterGraph(self.model, [(a, b)]).require_resolved()
            act.append((a, b))
            return
        blank = re.fullmatch(r"ISBLANK\s*\((.+)\)", m, re.I | re.S)
        if blank:
            ref = self.model.ref_pair(blank.group(1))
            if not ref:
                raise Unsupported("CALCULATE filter %s" % mod)
            self.grain_guard(ref, keep)
            filters.append(("{T:%s|%s} IS NULL" % ref, tuple(ref), bool(keep)))
            return
        cmp_ = re.fullmatch(r"(.+?\])\s*(<>|>=|<=|=|>|<)\s*(.+)", m, re.S)
        inn = re.fullmatch(r"(.+?\])\s+IN\s*\{(.*)\}", m, re.S | re.I)
        if inn:
            ref = self.model.ref_pair(inn.group(1))
            lits = [dax_literal(x) for x in split_top(inn.group(2))]
            if not ref or any(x is Unsupported for x in lits):
                raise Unsupported("CALCULATE filter %s" % mod)
            self.grain_guard(ref, keep)
            filters.append((self.predicate(ref, "IN", lits), tuple(ref), bool(keep)))
            return
        if cmp_:
            ref = self.model.ref_pair(cmp_.group(1))
            lit = dax_literal(cmp_.group(3))
            if not ref or lit is Unsupported:
                raise Unsupported("CALCULATE filter %s" % mod)
            self.grain_guard(ref, keep)
            filters.append((self.predicate(ref, cmp_.group(2), [lit]), tuple(ref), bool(keep)))
            return
        raise Unsupported("CALCULATE modifier %s is not a literal column filter, KEEPFILTERS or USERELATIONSHIP" % mod)

    def grain_guard(self, ref, keep):
        why = self.guarded.get(tuple(ref))
        if not keep and why:
            raise Unsupported("CALCULATE replaces the filter on %s[%s], %s: the page fact applies that filter to every "
                              "component, so this measure needs its own handling (add KEEPFILTERS in the source if an "
                              "intersection is meant, or model it by hand)" % (ref[0], ref[1], why))

    def predicate(self, ref, op, lits):
        col = "{T:%s|%s}" % ref
        typ = self.model.column_type(*ref)
        tt = TEXT_TYPE.get(self.dialect, "VARCHAR")
        if typ in ("int64", "double", "decimal"):
            lhs, fmt = "COALESCE(%s, 0)" % col, lambda v: sql_literal(v if v is not None else 0)
        elif typ == "boolean":
            lhs, fmt = "COALESCE(%s, FALSE)" % col, lambda v: sql_literal(bool(v))
        else:
            lhs, fmt = "UPPER(COALESCE(CAST(%s AS %s), ''))" % (col, tt), \
                lambda v: "UPPER(%s)" % sql_literal("" if v is None else str(v))
        if op == "IN":
            return "%s IN (%s)" % (lhs, ", ".join(fmt(v) for v in lits))
        return "%s %s %s" % (lhs, op, fmt(lits[0]))


def rejoin_braces(args):
    """lib/pbi_semantic_sql.split_args splits inside `{...}` table constructors; glue those back."""
    out = []
    for a in args:
        if out and out[-1].count("{") > out[-1].count("}"):
            out[-1] = out[-1] + ", " + a
        else:
            out.append(a)
    return out


def dax_literal(text):
    t = text.strip()
    if re.fullmatch(r'"(?:[^"]|"")*"', t):
        return t[1:-1].replace('""', '"')
    if re.fullmatch(r"-?\d+(?:\.\d+)?", t):
        return float(t) if "." in t else int(t)
    if re.fullmatch(r"TRUE\s*\(\s*\)", t, re.I):
        return True
    if re.fullmatch(r"FALSE\s*\(\s*\)", t, re.I):
        return False
    if re.fullmatch(r"BLANK\s*\(\s*\)", t, re.I):
        return None
    return Unsupported


def short_label(text):
    cols = re.findall(r"\[([^\]]+)\]", text)
    return " ".join(cols[:3]) or "expr"


# --------------------------------------------------------------------------- page-fact SQL

def page_paths(model, tables, fact, act):
    graph = FilterGraph(model, act)
    out, notes = {}, []
    for t in tables:
        if t == fact:
            continue
        p, info = graph.best_path(t, fact)
        if p is None:
            notes.append(info)
        else:
            out[t] = p
            if info.get("chosen_over"):
                notes.append(info)
    return graph, out, notes


def fill(template, aliases, src):
    def rep(m):
        t, c = m.group(1), m.group(2)
        if t not in aliases:
            raise Unsupported("%s is not reachable from the fact" % t)
        ident, _ = src.column(t, c)
        return "%s.%s" % (aliases[t], ident)
    return re.sub(r"\{T:([^|{}]+)\|([^{}]+)\}", rep, template)


def build_page_fact(model, src, inv, cls, grain_fields, dialect, ctx_filters=(), guards=None, ctx_notes=()):
    """ctx_filters: report/page list filters, applied at every fact they reach. guards: {field: why}
    columns (slicers, filters) a CALCULATE may not override without becoming a TODO."""
    dec = Decomposer(model, grain_fields, dialect, guards)
    measures, todo = {}, []
    for m in inv["measures"]:
        name = m["name"]
        try:
            sig, sq, used = dec.measure(name)
            measures[m["query_ref"]] = {"measure": name, "ref": sig, "sql": sq, "uses": used}
        except (Unsupported, CompilerUnsupported) as e:
            todo.append({"measure": name, "query_ref": m["query_ref"], "reason": str(e),
                         "dax": model.measures[name]["expression"] if name in model.measures else None})
    ftype = FLOAT_TYPE.get(dialect, "DOUBLE")
    ttype = TEXT_TYPE.get(dialect, "VARCHAR")
    grain, used_names, seen_out = [], set(), set()
    for (t, c) in grain_fields:
        nm = c if c not in used_names else "%s (%s)" % (c, t)
        nm = nm.replace("/", "\u2215")  # Sigma cannot reference a name containing "/" (see name-sanitize)
        used_names.add(nm)
        out = "G_" + snake(c if nm == c else "%s_%s" % (c, t))
        while out in seen_out:
            out += "_"
        seen_out.add(out)
        grain.append({"field": (t, c), "name": nm, "out": out})
    comp_tables = lambda c: {t for t, _ in re.findall(r"\{T:([^|{}]+)\|([^{}]+)\}", c["row"] + " ".join(c["filters"]))}
    tables_needed = {t for (t, _c) in grain_fields} | {s["field"][0] for s in inv["slicers"]} | \
        {f["field"][0] for f in ctx_filters}
    groups_by_key = {}
    for key in dec.order:
        c = dec.components[key]
        groups_by_key.setdefault((c["fact"], c["act"]), []).append(key)
        tables_needed |= {c["fact"]} | comp_tables(c)
    # resolve every join path first: the tables a path walks through (bridges) get a CTE too
    group_paths = {}
    for (fact, act), keys in groups_by_key.items():
        need = {t for (t, _c) in grain_fields}
        for k in keys:
            need |= comp_tables(dec.components[k])
        group_paths[(fact, act)] = page_paths(model, sorted(need), fact, list(act))
        tables_needed |= {h[1] for p in group_paths[(fact, act)][1].values() for h in p}
        for t_ in [s_["field"][0] for s_ in inv["slicers"]] + [f["field"][0] for f in ctx_filters]:
            p, _info = FilterGraph(model, list(act)).best_path(t_, fact)
            tables_needed |= {h[1] for h in (p or [])}
    cte_names, ctes, missing = {}, [], []
    for t in sorted(tables_needed, key=lambda x: (x not in cls["facts"], x)):
        try:
            body = src.cte_body(t)
        except Unsupported as e:
            missing.append(str(e))
            continue
        name = "pfs_" + (re.sub(r"[^0-9a-z]+", "_", t.lower()).strip("_") or "t")
        while name in cte_names.values():
            name += "_"
        cte_names[t] = name
        ctes.append("%s AS (\n%s\n)" % (name, indent(body, 2)))
    path_notes, agg_ctes, built, failed, context_todo = [], [], [], {}, list(ctx_notes)
    for (fact, act), keys in groups_by_key.items():
        comps = [dec.components[k] for k in keys]
        if fact not in cte_names:
            for k in keys:
                failed[k] = "no data-model element for fact %s" % fact
            continue
        graph, paths, notes = group_paths[(fact, act)]
        for nt in notes:
            path_notes.append(dict(nt, fact=fact))
        try:
            joins, aliases = join_chain(src, fact, paths, "f", cte_names)
        except Unsupported as e:
            for k in keys:
                failed[k] = str(e)
            continue
        sel, gby = [], []
        for g in grain:
            if g["field"][0] in aliases:
                expr = fill("{T:%s|%s}" % g["field"], aliases, src)
                sel.append("%s AS %s" % (expr, quote_ident(g["out"])))
                gby.append(expr)
            else:
                sel.append("NULL AS %s" % quote_ident(g["out"]))
                path_notes.append({"fact": fact, "source": g["field"][0], "target": fact, "reason":
                                   "grouping column %s[%s] does not reach %s: Power BI repeats %s's values on every member; "
                                   "the page fact leaves the column NULL on %s's rows" % (g["field"] + (fact, fact, fact))})
        mine = []
        for k, c in zip(keys, comps):
            try:
                row = "1" if c["row"] == "*" else fill(c["row"], aliases, src)
                conds = [fill(p, aliases, src) for p in c["filters"]]
            except Unsupported as e:
                failed[k] = str(e)
                continue
            if conds:
                row = "CASE WHEN %s THEN %s END" % (" AND ".join(conds), row)
            agg = {"SUM": "SUM(%s)", "COUNT": "NULLIF(COUNT(%s), 0)", "MIN": "MIN(%s)", "MAX": "MAX(%s)"}[c["agg"]]
            sel.append("%s AS %s" % (agg % row, quote_ident(c["out"])))
            mine.append(k)
        if not mine:
            continue
        where = []
        for f in ctx_filters:
            p, info = graph.best_path(f["field"][0], fact)
            if p is None:
                if info.get("ambiguous"):
                    context_todo.append("%s filter on %s[%s]: ambiguous path to %s" % (f["scope"], f["field"][0], f["field"][1], fact))
                continue  # the filter's table does not reach this fact: Power BI leaves its rows alone
            where.append(literal_filter(src, model, p, f["field"], f["values"], f["exclude"], "f", dialect, cte_names))
        tag = re.sub(r"[^0-9a-z]+", "_", fact.lower()).strip("_") + ("_ur%d" % (len(agg_ctes) + 1) if act else "")
        cname = "agg_" + tag
        hook = hook_marker(fact, "f", list(act), {t: n for t, n in cte_names.items() if t != fact})
        agg_ctes.append("%s AS (\n  SELECT\n%s\n  FROM %s f\n%s  WHERE 1 = 1\n%s    %s\n%s)" % (
            cname, ",\n".join("    " + x for x in sel), cte_names[fact], "".join("  %s\n" % j for j in joins),
            "".join("    AND %s\n" % w for w in where), hook,
            ("  GROUP BY %s\n" % ", ".join(gby)) if gby else ""))
        built.append((cname, set(mine)))
    # measures whose components could not be built become TODOs too
    fields, sigma_sql = {}, {}
    for qr, m in measures.items():
        bad = [failed[k] for k in m["uses"] if k in failed]
        if bad:
            todo.append({"measure": m["measure"], "query_ref": qr, "reason": bad[0],
                         "dax": model.measures[m["measure"]]["expression"]})
        else:
            fields[qr] = {"ref": m["ref"]}
            sigma_sql[qr] = m["sql"]
    for why in context_todo:
        todo.append({"measure": None, "context": True, "reason": why})
    live = [k for k in dec.order if any(k in mine for _c, mine in built)]
    comps_all = [dec.components[k] for k in live]
    outs = [c["out"] for c in comps_all]
    todo_cols = []
    for t in todo:
        if not t.get("query_ref"):
            continue
        col = "TODO_" + snake(t["measure"])
        if col not in todo_cols:
            todo_cols.append(col)
    gcols = [quote_ident(g["out"]) for g in grain]
    nulls = ["CAST(NULL AS %s) AS %s" % (ftype, quote_ident(x)) for x in todo_cols]
    if len(built) == 1:
        body = "SELECT\n%s\nFROM %s" % (",\n".join("  " + x for x in gcols + [quote_ident(o) for o in outs] + nulls), built[0][0])
    elif built:
        branches = []
        for cname, mine in built:
            mine_out = {dec.components[k]["out"] for k in mine}
            # a bare NULL takes the other branch's type (a typed NULL would clash with a MIN/MAX over a date)
            cols = gcols + [quote_ident(o) if o in mine_out else "NULL AS %s" % quote_ident(o) for o in outs]
            branches.append("  SELECT %s FROM %s" % (", ".join(cols), cname))
        outer = {c["out"]: Decomposer.AGG_OUTER[c["agg"]] for c in comps_all}
        body = "SELECT\n%s\nFROM (\n%s\n) u%s" % (
            ",\n".join(["  " + x for x in gcols] + ["  %s(%s) AS %s" % (outer[o], quote_ident(o), quote_ident(o)) for o in outs]
                       + ["  " + x for x in nulls]),
            "\n  UNION ALL\n".join(branches), ("\nGROUP BY %s" % ", ".join(gcols)) if gcols else "")
    else:
        body = "SELECT %s" % ", ".join(nulls or ["CAST(NULL AS %s) AS %s" % (ftype, quote_ident("PLACEHOLDER"))])
    header = ["-- page fact for page %r (scaffold-page-fact.py). Edit freely; keep each @slicers hook comment inside its WHERE clause." % inv["title"],
              "-- grain: %s" % (", ".join("%s[%s]" % g["field"] for g in grain) or "(none: one row)")]
    plain = lambda x: x.replace("{T:", "").replace("}", "").replace("|", ".")
    for c in comps_all:
        header.append("-- %s = %s(%s)%s on %s%s" % (c["out"], c["agg"], plain(c["row"]),
                                                  (" WHERE " + plain(" AND ".join(c["filters"]))) if c["filters"] else "",
                                                  c["fact"], " [USERELATIONSHIP]" if c["act"] else ""))
    for t in todo:
        header.append("-- TODO %s: %s" % (t.get("measure") or "(filter context)", t["reason"]))
        for line in (t.get("dax") or "").split("\n"):
            header.append("--     " + line)
    with_part = ("WITH\n" + ",\n".join(ctes + agg_ctes) + "\n") if (ctes or agg_ctes) and built else ""
    sql = "\n".join(header) + "\n" + with_part + body
    for t in todo:
        if t.get("query_ref"):
            fields[t["query_ref"]] = {"ref": "Sum({C:%s})" % ("TODO_" + snake(t["measure"])).replace("_", " ").title(),
                                      "todo": True}
    columns = [{"name": g["name"], "out": g["out"], "role": "grain", "field": "%s.%s" % g["field"]} for g in grain]
    columns += [{"name": c["name"], "out": c["out"], "role": "component", "fact": c["fact"],
                 "aggregate": Decomposer.AGG_OUTER[c["agg"]]} for c in comps_all]
    columns += [{"name": x.replace("_", " ").title(), "out": x, "role": "todo"} for x in todo_cols]
    dims = {}
    for v in inv["visuals"]:
        for g in v["groups"]:
            col = next((x for x in grain if x["field"] == g["field"]), None)
            if col:
                dims[g["query_ref"]] = col["name"]
    for s_ in inv["slicers"]:
        col = next((x for x in grain if x["field"] == tuple(s_["field"])), None)
        if col:
            dims[s_["query_ref"]] = col["name"]
    return {"sql": sql, "columns": columns, "fields": fields, "dims": dims, "todo": todo, "missing_sources": missing,
            "path_notes": path_notes, "sigma_sql": sigma_sql, "grain": grain, "components": comps_all,
            "cte_names": cte_names}


def indent(text, n):
    pad = " " * n
    return "\n".join(pad + line if line.strip() else line for line in text.split("\n"))


# --------------------------------------------------------------------------- oracle

class OracleCompiler(Compiler):
    """lib/pbi_semantic_sql.py's constrained DAX compiler over the RAW sources (no page fact).

    Overrides: sources are the data-model elements' own SQL; columns resolve through SourceIndex;
    joins follow the Power BI filter path (USERELATIONSHIP path weight) to only the tables the
    query needs, instead of the base class's first-found join tree."""

    def __init__(self, model, src):  # deliberately not calling Compiler.__init__ (it rejects whole models)
        self.pmodel = model
        self.src = src
        self.tables = model.tables
        self.measures = {}
        for n, m in model.measures.items():
            try:
                self.measures[n] = model.expanded(n)
            except Unsupported:
                self.measures[n] = m["expression"]  # the compiler rejects it with its own reason
        self.relationships = model.raw.get("relationships", [])
        self.sources = {}
        self.needed = set()

    def column(self, table, column):
        t = self.pmodel.table(table)
        if not t or not self.pmodel.column(t, column):
            raise CompilerUnsupported("Unresolved source column %s.%s" % (table, column))
        try:
            ident, _ = self.src.column(t, column)
        except Unsupported as e:
            raise CompilerUnsupported(str(e))
        return ident

    def source(self, table):
        try:
            return self.src.from_sql(self.pmodel.table(table) or table)
        except Unsupported as e:
            raise CompilerUnsupported(str(e))

    def query(self, groups, measures, filters):
        """Base query() with two changes: each fact's grouping context is taken through every
        USERELATIONSHIP set its measures use (not only the active paths), and a fact that cannot
        reach the grouping adds no context instead of failing (its measure repeats per row, as in
        Power BI)."""
        for table, col in [*groups, *(f["field"] for f in filters)]:
            self.column(table, col)
        nodes = [expression("[" + m + "]") for m in measures]
        facts = set().union(*(self.fact(n) for n in nodes))
        acts = {()}
        for m in self.pmodel.closure(measures):
            ur = self.pmodel.measure_info(m)["userelationship"]
            if ur:
                acts.add(tuple(ur))
        contexts = []
        for fact in sorted(facts):
            for act in sorted(acts):
                source, aliases = self.joins(fact, act)
                if any(table not in aliases for table, _ in groups):
                    continue
                keys = [self.value_ref(t, c, aliases) + " AS " + ident("g" + str(i)) for i, (t, c) in enumerate(groups)]
                conditions = self.predicates(filters, aliases)
                contexts.append("SELECT DISTINCT " + ",".join(keys or ["1 AS singleton"]) + " FROM " + source
                                + " WHERE " + (" AND ".join(conditions) or "TRUE"))
        if groups and not contexts:
            raise CompilerUnsupported("Grouping does not reach any fact in visual")
        if not groups:
            contexts = ["SELECT 1 AS singleton"]
        columns = ["g." + ident("g" + str(i)) for i in range(len(groups))]
        columns += [self.scalar(n, filters, groups) + " AS " + ident("v" + str(i)) for i, n in enumerate(nodes)]
        return "WITH context AS (" + " UNION ".join(contexts) + ") SELECT " + ",\n".join(columns) + " FROM context g"

    def scalar(self, node, filters, groups, ignored=(), extra=(), time_context=None, overrides=(), seen=()):
        """Base scalar() with DAX's BLANK arithmetic for + and -: BLANK counts as 0, BLANK +/- BLANK is BLANK."""
        if node[0] == "binary" and node[1] in "+-":
            a = self.scalar(node[2], filters, groups, ignored, extra, time_context, overrides, seen)
            b = self.scalar(node[3], filters, groups, ignored, extra, time_context, overrides, seen)
            return "(CASE WHEN %s IS NULL AND %s IS NULL THEN NULL ELSE COALESCE(%s,0) %s COALESCE(%s,0) END)" % (
                a, b, a, node[1], b)
        return super().scalar(node, filters, groups, ignored, extra, time_context, overrides, seen)

    def joins(self, fact, overrides=()):
        fact = self.pmodel.table(fact) or fact
        graph = FilterGraph(self.pmodel, overrides)
        try:
            graph.require_resolved()
        except Unsupported as e:
            raise CompilerUnsupported(str(e))
        paths = {}
        for t in sorted(self.needed):
            if t == fact:
                continue
            p, info = graph.best_path(t, fact)
            if p is None:
                if info.get("ambiguous"):
                    raise CompilerUnsupported("ambiguous filter path %s -> %s" % (t, fact))
                continue  # unreachable: predicates on it are skipped, as Power BI ignores them
            paths[t] = p
        try:
            joins, aliases = join_chain(self.src, fact, paths, "f")
        except Unsupported as e:
            raise CompilerUnsupported(str(e))
        return self.source(fact) + " f " + " ".join(joins), TableKeys(self.pmodel, aliases)


class TableKeys(dict):
    """{table: alias} looked up case-insensitively (DAX table names need not match the model's case)."""

    def __init__(self, model, data):
        super().__init__(data)
        self._model = model

    def _k(self, k):
        return self._model.table(k) or k

    def __getitem__(self, k):
        return super().__getitem__(self._k(k))

    def __contains__(self, k):
        return super().__contains__(self._k(k))

    def get(self, k, default=None):
        return super().get(self._k(k), default)


def visual_filters(model, v):
    """A visual's own filters -> (list filters on its grouping columns, notes for the rest). Only a list
    filter on a column the visual groups by survives on a page-fact chart (the builder applies element
    filters to projected columns only)."""
    own = {tuple(g["field"]) for g in v["groups"]}
    out, notes = [], []
    for f in v.get("filters") or []:
        nf, why = normalize_filter(model, f)
        if why:
            notes.append("visual %r: %s" % (v["title"], why))
        elif nf:
            if tuple(nf["field"]) in own:
                out.append(nf)
            else:
                notes.append("visual %r: list filter on %s[%s], a column the visual does not group by, cannot be "
                             "applied to a page-fact chart" % ((v["title"],) + tuple(nf["field"])))
    return out, notes


def build_oracles(model, src, inv, scenarios, grain, ctx=()):
    """Oracle queries per data visual. Keys: <page>__<element> (the page's default context, for the
    workbook parity plan), <page>__<element>@check (only the defaults the UNGATED page fact applies,
    i.e. selections on grain columns, for check-plan.json; omitted when identical) and
    <page>__<element>@<scenario> (an extra --scenario filter on top of the default context)."""
    comp = OracleCompiler(model, src)
    queries, plans, notes = {}, [], []
    saved = default_filters(model, inv)
    base_filters = list(ctx) + saved
    base_check = list(ctx) + [f for f in saved if tuple(f["field"]) in set(grain)]
    for v in inv["visuals"]:
        groups = [g["field"] for g in v["groups"]]
        vf, _vnotes = visual_filters(model, v)
        page_filters, check_filters = base_filters + vf, base_check + vf
        ok, bad = [], []
        for m in [x["name"] for x in v["measures"]]:
            comp.needed = needed_tables(model, groups, page_filters, [m])
            try:
                comp.query(groups, [m], page_filters)
                ok.append(m)
            except (CompilerUnsupported, Unsupported, KeyError) as e:
                bad.append({"measure": m, "reason": str(e)})
        if bad:
            notes.append({"visual": v["title"], "unsupported": bad})
        if not ok:
            continue
        key = "%s__%s" % (slug(inv["title"]), v["element_id"])
        gdisp = [g["display"] for g in v["groups"]]
        mdisp = [next(x["display"] for x in v["measures"] if x["name"] == m) for m in ok]
        variants = [("", page_filters)]
        if check_filters != page_filters:
            variants.append(("check", check_filters))
        variants += [(name, page_filters + extra) for name, extra in scenarios]
        for vname, flt in variants:
            comp.needed = needed_tables(model, groups, flt, ok)
            try:
                q = comp.query(groups, ok, flt)
            except (CompilerUnsupported, Unsupported) as e:
                notes.append({"visual": v["title"], "scenario": vname, "unsupported": [{"reason": str(e)}]})
                continue
            names = ["%s AS %s" % (quote_ident("g%d" % i), quote_ident(d)) for i, d in enumerate(gdisp)]
            names += ["%s AS %s" % (quote_ident("v%d" % i), quote_ident(d)) for i, d in enumerate(mdisp)]
            keep = " OR ".join("%s IS NOT NULL" % quote_ident("v%d" % i) for i in range(len(mdisp)))
            queries[key + (("@" + vname) if vname else "")] = "SELECT %s FROM (\n%s\n) q%s" % (
                ", ".join(names), q, (" WHERE " + keep) if gdisp else "")
        plans.append({"visual": v, "key": key, "check_key": key + ("@check" if check_filters != page_filters else ""),
                      "measures": ok, "groups": groups})
    return queries, plans, notes


def needed_tables(model, groups, filters, measures):
    out = {t for t, _ in groups} | {f["field"][0] for f in filters}
    for m in model.closure(measures):
        info = model.measure_info(m)
        out |= {t for t, _ in info["column_refs"]}
        out |= set(info["scans"])
    return {model.table(t) or t for t in out}


def default_filters(model, inv):
    """The page's default filter context: saved slicer selections (include lists)."""
    out = []
    for s in inv["slicers"]:
        sel = s.get("saved_selection")
        if not sel or not sel.get("values"):
            continue
        vals = list(sel.get("values"))
        if sel.get("has_null"):
            vals.append(None)
        out.append({"field": tuple(s["field"]), "values": vals, "exclude": str(sel.get("mode")) == "exclude"})
    return out


def parse_scenarios(model, specs):
    out = []
    for s in specs or []:
        lhs, _, rhs = s.partition("=")
        t, _, c = lhs.strip().rpartition(".")
        ref = model.column(t, c)
        if not ref:
            raise SystemExit("--scenario %r: %s is not a model column" % (s, lhs))
        vals = [None if x.strip() == "(Blank)" else coerce(model, ref, x.strip()) for x in rhs.split("|")]
        out.append(("%s=%s" % (lhs.strip(), rhs.strip()), [{"field": ref, "values": vals}]))
    return out


def coerce(model, ref, text):
    typ = model.column_type(*ref)
    if typ == "int64" and re.fullmatch(r"-?\d+", text):
        return int(text)
    if typ in ("double", "decimal") and re.fullmatch(r"-?\d+(\.\d+)?", text):
        return float(text)
    return text


# --------------------------------------------------------------------------- outputs

def check_queries(model, inv, pf, page_key):
    """The page fact rolled up to each visual's grain with the Sigma formulas' SQL twins, under the
    saved selections that sit on grain columns (the ones the ungated page fact can apply) and the
    visual's own list filters (report/page filters are already inside the page-fact SQL). A visual
    whose filters cannot be applied to the page fact gets no check query."""
    out = {}
    gfield = {tuple(g["field"]): g for g in pf["grain"]}

    def cond_for(f):
        g = gfield[tuple(f["field"])]
        vals = [x for x in f["values"] if x is not None]
        tests = ["%s IN (%s)" % (quote_ident(g["out"]), ", ".join(sql_literal(x) for x in vals))] if vals else []
        if None in f["values"]:
            tests.append("%s IS NULL" % quote_ident(g["out"]))
        cond = "(" + " OR ".join(tests or ["FALSE"]) + ")"
        return ("NOT COALESCE(%s, FALSE)" % cond) if f.get("exclude") else cond

    base = [cond_for(f) for f in default_filters(model, inv) if tuple(f["field"]) in gfield]
    for v in inv["visuals"]:
        vf, vnotes = visual_filters(model, v)
        if vnotes:
            continue
        where = base + [cond_for(f) for f in vf]
        gcols = []
        for g in v["groups"]:
            col = gfield.get(tuple(g["field"]))
            if col is None:
                gcols = None
                break
            gcols.append((col, g["display"]))
        if gcols is None:
            continue
        mcols = [(m, pf["sigma_sql"][m["query_ref"]]) for m in v["measures"] if m["query_ref"] in pf["sigma_sql"]]
        if not mcols:
            continue
        sel = ["%s AS %s" % (quote_ident(c["out"]), quote_ident(d)) for c, d in gcols]
        sel += ["%s AS %s" % (expr, quote_ident(m["display"])) for m, expr in mcols]
        gb = ", ".join(quote_ident(c["out"]) for c, _ in gcols)
        q = "SELECT %s FROM (\n%s\n) pf%s%s" % (", ".join(sel), strip_header(pf["sql"]),
                                              (" WHERE " + " AND ".join(where)) if where else "",
                                              (" GROUP BY " + gb) if gb else "")
        if gb:
            keep = " OR ".join("%s IS NOT NULL" % quote_ident(m["display"]) for m, _ in mcols)
            q = "SELECT * FROM (\n%s\n) r WHERE %s" % (q, keep)
        out["%s__%s" % (page_key, v["element_id"])] = q
    return out


def strip_header(sql):
    return "\n".join(line for line in sql.split("\n") if not line.startswith("-- "))


def brief(model, inv, cls, pf, oracle_notes, slicer_paths):
    L = ["# Page %r" % inv["title"], "",
         "Classification: **%s**%s" % (cls["classification"], (" (" + "; ".join(cls["reasons"]) + ")") if cls["reasons"] else ""),
         "Facts scanned: %s" % (", ".join(cls["facts"]) or "(none)"), ""]
    L.append("## Visuals")
    for v in inv["visuals"]:
        L.append("- **%s** (%s, element `%s`): by %s; measures %s" % (
            v["title"], v["kind"], v["element_id"], ", ".join("%s[%s]" % g["field"] for g in v["groups"]) or "(none)",
            ", ".join(m["name"] for m in v["measures"]) or "(none)"))
    L += ["", "## DAX closure (dependencies first)"]
    for n in model.closure([m["name"] for m in inv["measures"]]):
        info = model.measure_info(n)
        tags = []
        if info["userelationship"]:
            tags.append("USERELATIONSHIP: " + ", ".join("%s[%s] <-> %s[%s]" % (a + b) for a, b in info["userelationship"]))
        for k, lab in (("filter_removal", "filter removal"), ("selectors", "selectors"), ("time_intel", "time intelligence")):
            if info[k]:
                tags.append("%s: %s" % (lab, ", ".join(str(x) for x in info[k])))
        L.append("### [%s] %s%s" % (info["table"], n, ("  (" + "; ".join(tags) + ")") if tags else ""))
        deep = sorted({t for x in model.closure([n]) for t in model.measure_info(x)["scans"]})
        L.append("scans: %s" % (", ".join(deep) or "-"))
        L += ["```dax", info["expression"], "```"]
    L += ["", "## Slicers and their filter paths",
          "The page fact, its slicer gate and the oracle all use these paths (and the same column mapping), so check "
          "them here: an oracle cannot catch a wrong path it shares."]
    for s in slicer_paths:
        L.append("- **%s** on %s[%s] (blank member: %s)%s" % (s["title"], s["field"][0], s["field"][1], s["blank_policy"],
                                                               " - in the page-fact grain" if s["in_grain"] else ""))
        for p in s["paths"]:
            L.append("  - to %s: %s" % (p["fact"], p["path"] or p.get("reason")))
    if pf:
        L += ["", "## Page fact", "Grain: %s" % (", ".join("%s[%s]" % g["field"] for g in pf["grain"]) or "(one row)"),
              "Components: %d; TODO: %d" % (len(pf["components"]), len(pf["todo"]))]
        for t in pf["todo"]:
            L.append("- TODO %s: %s" % (t.get("measure") or "(filter context)", t["reason"]))
        for n in pf["path_notes"]:
            L.append("- path note (%s -> %s): %s" % (n.get("source"), n.get("target"), n.get("reason") or
                                                     ("chose the higher-weight path over %s" % "; ".join(n.get("chosen_over", [])))))
        for m in pf["missing_sources"]:
            L.append("- missing source: %s" % m)
    if oracle_notes:
        L += ["", "## Oracle gaps (compile these by hand)"]
        for n in oracle_notes:
            for u in n["unsupported"]:
                L.append("- %s%s: %s %s" % (n["visual"], (" @" + n["scenario"]) if n.get("scenario") else "",
                                           u.get("measure", ""), u["reason"]))
    L += ["", "## Next steps",
          "1. Fill every TODO in page-fact.sql (and its page-fact.json `sql`); keep the `/*@slicers*/` hooks.",
          "2. Run check-queries.json and oracle-queries.json through `sigma-sql-probe.py`, then "
          "`parity-from-oracle.py --spec check-plan.json`: the page fact must MATCH the oracle before any workbook build.",
          "3. Rerun `migrate-powerbi.rb ... --page-facts <this folder's parent>`: it adds the element to the data model, "
          "binds these visuals to it, and wires the slicers listed above through `wire-slicer-gate.py`.",
          "4. Export the page's elements to exports/<element id>.csv and run `parity-from-oracle.py --spec parity-plan.json`."]
    return "\n".join(L) + "\n"


def write_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False, default=list)
        f.write("\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--model", required=True)
    ap.add_argument("--signals", required=True)
    ap.add_argument("--dm-spec", required=True)
    ap.add_argument("--master-map")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--page", action="append", default=[])
    ap.add_argument("--all-pages", action="store_true")
    ap.add_argument("--classify-only", action="store_true")
    ap.add_argument("--grain", action="append", default=[], help='"<page>|<Table>.<Column>" extra grain column')
    ap.add_argument("--scenario", action="append", default=[], help='"<Table>.<Column>=<v>[|<v>]" filtered oracle')
    ap.add_argument("--dialect", default="snowflake", choices=["snowflake", "databricks", "bigquery"])
    a = ap.parse_args(argv)
    t0 = time.time()
    try:
        model = Model(load_json(a.model))
        signals = load_json(a.signals)
        src = SourceIndex(model, load_json(a.dm_spec), load_json(a.master_map) if a.master_map else None)
    except (OSError, ValueError) as e:
        print("scaffold-page-fact: %s" % e, file=sys.stderr)
        return 2
    os.makedirs(a.out_dir, exist_ok=True)
    pages = signals.get("pages") or []
    wanted = {norm(p) for p in a.page}
    summary = {"generated_by": "scaffold-page-fact.py", "pages": []}
    extra_grain = {}
    for g in a.grain:
        pg, _, ref = g.partition("|")
        t, _, c = ref.rpartition(".")
        col = model.column(t, c)
        if not col:
            print("scaffold-page-fact: --grain %r: no column %s" % (g, ref), file=sys.stderr)
            return 2
        extra_grain.setdefault(norm(pg), []).append(col)
    scenarios = parse_scenarios(model, a.scenario)
    for page in pages:
        inv = page_inventory(model, page)
        register_implicit_measures(model, inv)
        cls = classify(model, inv)
        entry = dict(cls)
        entry.pop("flags", None)
        pick = (norm(inv["title"]) in wanted) if wanted else (a.all_pages or cls["classification"] == "page-fact")
        entry["scaffolded"] = bool(pick and not a.classify_only and inv["visuals"])
        if entry["scaffolded"]:
            d = os.path.join(a.out_dir, slug(inv["title"]))
            os.makedirs(d, exist_ok=True)
            grain = []
            for g in inv["groups"]:
                if g["field"] not in grain:
                    grain.append(g["field"])
            for g in extra_grain.get(norm(inv["title"]), []):
                if g not in grain:
                    grain.append(g)
            ctx, ctx_notes = context_filters(model, signals, page)
            guards = {tuple(s["field"]): "the column of the %r slicer" % s["title"] for s in inv["slicers"]}
            for f in ctx:
                guards.setdefault(tuple(f["field"]), "the column of a %s filter" % f["scope"])
            vnotes = [n for v in inv["visuals"] for n in visual_filters(model, v)[1]]
            pf = build_page_fact(model, src, inv, cls, grain, a.dialect, ctx, guards,
                                 ["%s (not applied by the page fact)" % n for n in ctx_notes + vnotes])
            hooks = sorted({(c["fact"], c["act"]) for c in pf["components"]}, key=repr) or [(f, ()) for f in cls["facts"]]
            slicer_paths = []
            for s in inv["slicers"]:
                rows = []
                for fact, acts in hooks:
                    graph = FilterGraph(model, list(acts))
                    p, info = graph.best_path(s["field"][0], fact)
                    rows.append({"fact": fact, "userelationship": bool(acts),
                                 "path": describe_path(p, graph.activated) if p is not None else None,
                                 "hops": path_json(graph, p) if p is not None else None,
                                 "reason": info.get("reason"), "ambiguous": info.get("ambiguous", False)})
                # a direct filter on the grain column drops the rows of a fact that cannot reach the slicer's
                # table (their grain column is NULL); Power BI leaves that fact alone, so such a slicer is gated
                in_grain = tuple(s["field"]) in grain and all(r["path"] is not None for r in rows)
                slicer_paths.append(dict(s, in_grain=in_grain, paths=rows,
                                         column_type=model.column_type(*s["field"])))
            page_key = slug(inv["title"])
            oq, oplans, onotes = ({}, [], [{"visual": "(all)", "unsupported": [{"reason": "the oracle compiler is Snowflake/Databricks only"}]}]) \
                if a.dialect == "bigquery" else build_oracles(model, src, inv, scenarios, grain, ctx)
            if a.dialect == "databricks":
                oq = {k: v.replace("EQUAL_NULL(", "equal_null(") for k, v in oq.items()}
            cq = check_queries(model, inv, pf, page_key)
            name = "%s Page Fact" % inv["title"]
            pfj = {"version": 1, "page": inv["title"], "page_id": inv["page_id"], "name": name,
                   "sql": pf["sql"], "columns": pf["columns"], "fields": pf["fields"], "dims": pf["dims"],
                   "facts": cls["facts"], "todo": pf["todo"],
                   "slicers": [{"element_id": s["element_id"], "visual_id": s["visual_id"], "title": s["title"],
                                "field": "%s.%s" % s["field"], "query_ref": s["query_ref"],
                                "blank_policy": s["blank_policy"], "in_grain": s["in_grain"],
                                "column_type": s["column_type"], "saved_selection": s.get("saved_selection")}
                               for s in slicer_paths]}
            with open(os.path.join(d, "page-fact.sql"), "w", encoding="utf-8", newline="\n") as f:
                f.write(pf["sql"] + "\n")
            write_json(os.path.join(d, "page-fact.json"), pfj)
            write_json(os.path.join(d, "oracle-queries.json"), oq)
            write_json(os.path.join(d, "check-queries.json"), cq)
            check_plan, parity_plan = {"charts": []}, {"charts": []}
            for p in oplans:
                v = p["visual"]
                keys = [g["display"] for g in v["groups"]]
                meas = [next(x["display"] for x in v["measures"] if x["name"] == m) for m in p["measures"]]
                built_meas = [next(x["display"] for x in v["measures"] if x["name"] == m) for m in p["measures"]
                              if next(x["query_ref"] for x in v["measures"] if x["name"] == m) in pf["sigma_sql"]]
                if p["key"] in cq and p["check_key"] in oq and built_meas:
                    check_plan["charts"].append({"name": "%s (page fact)" % v["title"], "export": "check-results.json",
                                                 "export_key": p["key"], "oracle": "oracle-results.json",
                                                 "oracle_key": p["check_key"], "keys": keys, "measures": built_meas})
                parity_plan["charts"].append({"name": v["title"], "export": "exports/%s.csv" % v["element_id"],
                                              "oracle": "oracle-results.json", "oracle_key": p["key"], "keys": keys,
                                              "measures": meas})
            write_json(os.path.join(d, "check-plan.json"), check_plan)
            write_json(os.path.join(d, "parity-plan.json"), parity_plan)
            with open(os.path.join(d, "closure.md"), "w", encoding="utf-8", newline="\n") as f:
                f.write(brief(model, inv, cls, pf, onotes, slicer_paths))
            entry.update(dir=os.path.relpath(d, a.out_dir), components=len(pf["components"]), todo=len(pf["todo"]),
                         oracle_queries=len(oq), check_queries=len(cq),
                         gated_slicers=[s["title"] for s in slicer_paths if not s["in_grain"]],
                         ambiguous_paths=[s["title"] for s in slicer_paths for p in s["paths"] if p["ambiguous"]])
            print("page %r: %s -> %s (%d components, %d TODO, %d oracle / %d check queries, %d slicer(s) to gate)"
                  % (inv["title"], cls["classification"], entry["dir"], entry["components"], entry["todo"],
                     len(oq), len(cq), len(entry["gated_slicers"])))
        else:
            print("page %r: %s%s" % (inv["title"], cls["classification"],
                                     (" (" + "; ".join(cls["reasons"]) + ")") if cls["reasons"] else ""))
        summary["pages"].append(entry)
    write_json(os.path.join(a.out_dir, "page-closure.json"), summary)
    print("scaffold-page-fact: %d page(s) in %.2fs" % (len(summary["pages"]), time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
