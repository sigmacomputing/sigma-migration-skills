"""pbi_page_closure.py - page-level DAX closure, Power BI filter paths and SQL helpers.

Shared by scaffold-page-fact.py, wire-slicer-gate.py and integrate-page-fact.py. Python
stdlib only, offline (no Sigma, no warehouse).

What it answers, for one report page:
  * which measures the page's visuals bind, and their full DAX dependency closure (deps
    first), with the tables each one scans, its CALCULATE modifiers (USERELATIONSHIP,
    ALL/REMOVEFILTERS, TREATAS), selector functions (SELECTEDVALUE, ISFILTERED) and
    time-intelligence calls;
  * which columns the visuals group by, which slicers the page has and on which field;
  * which relationship path a filter takes from a slicer (or grouping) table to each fact,
    following Power BI's ambiguity rules: active relationships only, USERELATIONSHIP
    activates an inactive one and deactivates the other relationships between the same two
    tables, paths are ranked by priority tier and then by path weight (a path holding an
    activated relationship weighs more). "Model relationships in Power BI Desktop" ->
    "Resolve relationship path ambiguity" (Microsoft Learn) is the reference;
  * how to write that path as SQL: a LEFT JOIN chain from the fact outward (for grouping)
    or a nested semi-join from the fact key inward (for a slicer predicate), with Power BI's
    (Blank) member semantics.

Names here are generic. Nothing in this module knows any report.
"""

import hashlib
import json
import re

TIME_INTEL = {
    "DATEADD", "SAMEPERIODLASTYEAR", "TOTALYTD", "TOTALQTD", "TOTALMTD", "DATESYTD", "DATESQTD",
    "DATESMTD", "DATESINPERIOD", "DATESBETWEEN", "PARALLELPERIOD", "PREVIOUSYEAR", "PREVIOUSQUARTER",
    "PREVIOUSMONTH", "PREVIOUSDAY", "NEXTYEAR", "NEXTQUARTER", "NEXTMONTH", "NEXTDAY", "OPENINGBALANCEYEAR",
    "CLOSINGBALANCEYEAR", "OPENINGBALANCEMONTH", "CLOSINGBALANCEMONTH", "STARTOFYEAR", "ENDOFYEAR",
    "STARTOFMONTH", "ENDOFMONTH", "LASTDATE", "FIRSTDATE",
}
FILTER_REMOVAL = {"ALL", "ALLEXCEPT", "ALLSELECTED", "REMOVEFILTERS", "ALLNOBLANKROW", "ALLCROSSFILTERED"}
SELECTORS = {"SELECTEDVALUE", "ISFILTERED", "ISCROSSFILTERED", "HASONEVALUE", "HASONEFILTER", "ISINSCOPE",
             "FILTERS", "VALUES"}
ITERATORS = {"SUMX", "AVERAGEX", "MINX", "MAXX", "COUNTX", "COUNTAX", "PRODUCTX", "RANKX", "CONCATENATEX",
             "MEDIANX", "PERCENTILEX.INC", "PERCENTILEX.EXC"}
COLUMN_AGGS = {"SUM", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "COUNTBLANK", "DISTINCTCOUNT",
               "DISTINCTCOUNTNOBLANK", "MEDIAN"}
DAX_KEYWORDS = {"VAR", "RETURN", "IN", "NOT", "AND", "OR", "TRUE", "FALSE", "ASC", "DESC", "DEFINE",
                "EVALUATE", "MEASURE", "ORDER", "BY", "START", "AT", "COLUMN", "TABLE"}

# Binding roles whose plain columns Power BI aggregates (implicit measures). Every other role
# groups by its columns. A flat table visual groups by every plain column, whatever the role.
VALUE_ROLES = {"Values", "Y", "Y2", "Size", "Tooltips", "Target", "TargetValue", "MinValue", "MaxValue",
               "Indicator", "Goal", "Gradient", "ColumnValues", "Data", "Value"}
NON_GROUP_ROLES = {"Tooltips"}
SLICER_ROLES = ("Values", "Category", "Fields")
_AGG_WRAPPER = re.compile(r"^\s*(Sum|Avg|Average|Min|Max|Count|CountNonNull|DistinctCount|Median)\((.+)\)\s*$", re.I)
_IMPLICIT_FN = {"sum": "SUM", "avg": "AVERAGE", "average": "AVERAGE", "min": "MIN", "max": "MAX",
                "count": "COUNTA", "countnonnull": "COUNTA", "distinctcount": "DISTINCTCOUNT", "median": "MEDIAN"}


class Unsupported(ValueError):
    """A DAX or model shape this module does not translate. Callers turn it into a TODO."""


# --------------------------------------------------------------------------- small helpers

def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def expr_text(value):
    if isinstance(value, list):
        return "\n".join(str(x) for x in value)
    return "" if value is None else str(value)


def norm(s):
    """case-, space- and punctuation-insensitive key."""
    return re.sub(r"[^0-9a-z]", "", str(s).lower())


def short_hash(text, n=8):
    # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1
    return hashlib.sha1(str(text).encode("utf-8")).hexdigest()[:n]


def element_id_for_visual(visual_id):
    """The workbook element id build-workbook-from-pbir.rb gives a visual (`el-#{short(vid)}`)."""
    clean = re.sub(r"[^a-zA-Z0-9]", "", str(visual_id)).lower()
    return "el-" + (clean[-6:] if len(clean) >= 6 else clean) + short_hash(visual_id, 6)


def strip_comments(expr):
    """Remove DAX comments (-- and // to end of line, /* */ blocks) outside string literals."""
    out, i, n = [], 0, len(expr)
    while i < n:
        ch = expr[i]
        if ch == '"':
            j = i + 1
            while j < n:
                if expr[j] == '"':
                    if j + 1 < n and expr[j + 1] == '"':
                        j += 2
                        continue
                    break
                j += 1
            out.append(expr[i:j + 1])
            i = j + 1
        elif ch == "'":  # quoted table name
            j = expr.find("'", i + 1)
            while j != -1 and j + 1 < n and expr[j + 1] == "'":
                j = expr.find("'", j + 2)
            j = n - 1 if j == -1 else j
            out.append(expr[i:j + 1])
            i = j + 1
        elif ch == "[":
            j = expr.find("]", i + 1)
            j = n - 1 if j == -1 else j
            out.append(expr[i:j + 1])
            i = j + 1
        elif expr.startswith("--", i) or expr.startswith("//", i):
            j = expr.find("\n", i)
            i = n if j == -1 else j
        elif expr.startswith("/*", i):
            j = expr.find("*/", i + 2)
            i = n if j == -1 else j + 2
        else:
            out.append(ch)
            i += 1
    return "\n".join(line.rstrip() for line in "".join(out).split("\n") if line.strip())


def quoted_name_end(text, i):
    """Index of a quoted table name's closing apostrophe, skipping doubled apostrophes."""
    j, n = i + 1, len(text)
    while j < n:
        if text[j] == "'":
            if j + 1 < n and text[j + 1] == "'":
                j += 2
                continue
            return j
        j += 1
    return -1


def matching_paren(text, i):
    """text[i] == '(' -> index of its ')' (skips strings, quoted names and [refs])."""
    depth, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and not (text[i] == '"' and (i + 1 >= n or text[i + 1] != '"')):
                i += 2 if text[i] == '"' else 1
        elif ch == "'":
            i = quoted_name_end(text, i)
            if i == -1:
                break
        elif ch == "[":
            i = text.find("]", i + 1)
            if i == -1:
                break
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise Unsupported("unbalanced parentheses in DAX")


def split_top(text, sep=","):
    """Split on `sep` at depth 0 (outside parens, braces, strings, quoted names, [refs])."""
    parts, depth, start, i, n = [], 0, 0, 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and not (text[i] == '"' and (i + 1 >= n or text[i + 1] != '"')):
                i += 2 if text[i] == '"' else 1
        elif ch == "'":
            j = quoted_name_end(text, i)
            i = n if j == -1 else j
        elif ch == "[":
            j = text.find("]", i + 1)
            i = n if j == -1 else j
        elif ch in "({":
            depth += 1
        elif ch in ")}":
            depth -= 1
        elif ch == sep and depth == 0:
            parts.append(text[start:i].strip())
            start = i + 1
        i += 1
    parts.append(text[start:].strip())
    return parts


def calls(expr, fname):
    """Every call of `fname` in expr -> list of argument lists (top-level split)."""
    out = []
    for m in re.finditer(r"(?<![\w.])" + re.escape(fname) + r"\s*\(", expr, re.I):
        o = expr.index("(", m.start())
        try:
            c = matching_paren(expr, o)
        except Unsupported:
            continue
        out.append(split_top(expr[o + 1:c]))
    return out


def functions_in(expr):
    scrub = re.sub(r'"(?:[^"]|"")*"', '""', expr)
    scrub = re.sub(r"'(?:[^']|'')*'", "''", scrub)
    scrub = re.sub(r"\[[^\]]*\]", "[]", scrub)
    return sorted({m.group(1).upper() for m in re.finditer(r"(?<![\w.])([A-Za-z][A-Za-z0-9_.]*)\s*\(", scrub)})


def _top_level_words(text):
    """(start, end, WORD) of identifiers at paren depth 0, outside strings / quoted names / [refs]."""
    out, depth, i, n = [], 0, 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and not (text[i] == '"' and (i + 1 >= n or text[i + 1] != '"')):
                i += 2 if text[i] == '"' else 1
        elif ch == "'":
            j = quoted_name_end(text, i)
            i = n if j == -1 else j
        elif ch == "[":
            j = text.find("]", i + 1)
            i = n if j == -1 else j
        elif ch in "({":
            depth += 1
        elif ch in ")}":
            depth -= 1
        elif (ch.isalpha() or ch == "_") and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] in "_.")):
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            if depth == 0:
                out.append((i, j, text[i:j].upper()))
            i = j - 1
        i += 1
    return out


def _var_uses(expr, name):
    """Positions of the bare identifier `name` in expr (outside strings, quoted names, [refs])."""
    pos, i, n = [], 0, len(expr)
    while i < n:
        ch = expr[i]
        if ch == '"':
            i += 1
            while i < n and not (expr[i] == '"' and (i + 1 >= n or expr[i + 1] != '"')):
                i += 2 if expr[i] == '"' else 1
        elif ch == "'":
            j = quoted_name_end(expr, i)
            i = n if j == -1 else j
        elif ch == "[":
            j = expr.find("]", i + 1)
            i = n if j == -1 else j
        elif expr[i:i + len(name)].lower() == name.lower() and \
                (i == 0 or not (expr[i - 1].isalnum() or expr[i - 1] in "_.")) and \
                (i + len(name) >= n or not (expr[i + len(name)].isalnum() or expr[i + len(name)] == "_")):
            pos.append(i)
            i += len(name) - 1
        i += 1
    return pos


CONTEXT_CALLS = ("CALCULATE", "CALCULATETABLE", "FILTER", "TOTALYTD", "TOTALQTD", "TOTALMTD",
                 "OPENINGBALANCEYEAR", "OPENINGBALANCEQUARTER", "OPENINGBALANCEMONTH", "CLOSINGBALANCEYEAR",
                 "CLOSINGBALANCEQUARTER", "CLOSINGBALANCEMONTH") + tuple(sorted(ITERATORS))


def inline_vars(expr):
    """`VAR a = <x> VAR b = <y> RETURN <z>` -> <z> with each variable replaced by its (definition).

    DAX evaluates a VAR once, where it is defined. Inlining keeps that meaning only while every use
    sits outside a context transition, so a variable used inside CALCULATE / FILTER / an iterator
    raises Unsupported instead of being moved into the new filter context. Expressions without a
    top-level VAR are returned unchanged."""
    words = _top_level_words(expr)
    if not any(w == "VAR" for _s, _e, w in words):
        return expr
    marks = [(s, e, w) for s, e, w in words if w in ("VAR", "RETURN")]
    if not marks or marks[-1][2] != "RETURN" or marks[0][2] != "VAR":
        raise Unsupported("VAR without a top-level RETURN")
    defs = []
    for k, (s, e, w) in enumerate(marks[:-1]):
        if w != "VAR":
            raise Unsupported("RETURN before the last VAR")
        body = expr[e:marks[k + 1][0]]
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)\Z", body, re.S)
        if not m:
            raise Unsupported("VAR definition %r" % body.strip()[:60])
        defs.append((m.group(1), m.group(2).strip()))
    ret = expr[marks[-1][1]:].strip()

    def subst(text, name, value):
        uses = _var_uses(text, name)
        for args_call in CONTEXT_CALLS:
            for m in re.finditer(r"(?<![\w.])" + re.escape(args_call) + r"\s*\(", text, re.I):
                o = text.index("(", m.start())
                c = matching_paren(text, o)
                if any(o < u < c for u in uses):
                    raise Unsupported("variable %s is used inside %s(): inlining would move it into a new filter "
                                      "context" % (name, args_call))
        for u in reversed(uses):
            text = text[:u] + "(" + value + ")" + text[u + len(name):]
        return text

    resolved = []
    for name, value in defs:
        for prev, pval in resolved:
            value = subst(value, prev, pval)
        resolved.append((name, value))
    for name, value in reversed(resolved):
        ret = subst(ret, name, value)
    return ret


# --------------------------------------------------------------------------- model

class Model:
    """TMSL model (model.bim / --tmsl output) with case-insensitive lookups."""

    def __init__(self, doc):
        m = doc.get("model", doc) if isinstance(doc, dict) else {}
        self.raw = m
        self.tables = {}
        self.columns = {}
        self.measures = {}
        for t in m.get("tables", []) or []:
            tn = t.get("name")
            if not tn:
                continue
            self.tables[tn] = t
            for c in t.get("columns", []) or []:
                if c.get("name"):
                    self.columns[(tn, c["name"])] = c
            for x in t.get("measures", []) or []:
                if x.get("name"):
                    self.measures[x["name"]] = {
                        "name": x["name"], "table": tn, "format": x.get("formatString"),
                        "expression": strip_comments(expr_text(x.get("expression"))),
                    }
        self._tci = {t.lower(): t for t in self.tables}
        self._mci = {k.lower(): k for k in self.measures}
        self._cci = {(t.lower(), c.lower()): (t, c) for (t, c) in self.columns}
        self.relationships = []
        for i, r in enumerate(m.get("relationships", []) or []):
            ft, tt = self.table(r.get("fromTable")), self.table(r.get("toTable"))
            if not ft or not tt:
                continue
            fc = self.column(ft, r.get("fromColumn")) or (ft, r.get("fromColumn"))
            tc = self.column(tt, r.get("toColumn")) or (tt, r.get("toColumn"))
            self.relationships.append({
                "id": r.get("name") or "rel%d" % i,
                "from": fc, "to": tc,  # TMSL: from = many side, to = one side
                "active": r.get("isActive", True) is not False,
                "bidi": str(r.get("crossFilteringBehavior", "oneDirection")) == "bothDirections",
                "from_card": str(r.get("fromCardinality", "many")).lower(),
                "to_card": str(r.get("toCardinality", "one")).lower(),
            })

    def table(self, name):
        if name is None:
            return None
        return name if name in self.tables else self._tci.get(str(name).lower())

    def column(self, table, col):
        t = self.table(table)
        if not t or col is None:
            return None
        return (t, col) if (t, col) in self.columns else self._cci.get((t.lower(), str(col).lower()))

    def measure(self, name):
        if name is None:
            return None
        return name if name in self.measures else self._mci.get(str(name).lower())

    def expanded(self, name):
        """The measure's DAX with top-level VARs inlined (raises Unsupported when that is unsafe)."""
        m = self.measures[self.measure(name) or name]
        if "_expanded" not in m:
            try:
                m["_expanded"] = inline_vars(m["expression"])
            except Unsupported as e:
                m["_expanded"] = e
        if isinstance(m["_expanded"], Unsupported):
            raise m["_expanded"]
        return m["_expanded"]

    def column_type(self, table, col):
        c = self.columns.get(self.column(table, col) or (None, None)) or {}
        return str(c.get("dataType") or "string")

    def is_calculated(self, table, col):
        c = self.columns.get(self.column(table, col) or (None, None)) or {}
        return str(c.get("type", "")).lower() in ("calculated", "calculatedtablecolumn") and bool(c.get("expression"))

    def source_column(self, table, col):
        c = self.columns.get(self.column(table, col) or (None, None)) or {}
        return c.get("sourceColumn") or col

    def summarize_by(self, table, col):
        c = self.columns.get(self.column(table, col) or (None, None)) or {}
        s = str(c.get("summarizeBy") or "").lower()
        if s in ("", "default"):
            return "SUM" if self.column_type(table, col) in ("int64", "double", "decimal") else "COUNTA"
        return {"sum": "SUM", "average": "AVERAGE", "min": "MIN", "max": "MAX", "count": "COUNTA",
                "distinctcount": "DISTINCTCOUNT", "none": None}.get(s, "SUM")

    # ---- DAX references -------------------------------------------------
    _TOKEN = re.compile(r'"(?:[^"]|"")*"|\'((?:[^\']|\'\')+)\'\s*\[([^\]]+)\]|'
                        r'(?<![\w.\]])([A-Za-z_][A-Za-z0-9_]*)\s*\[([^\]]+)\]|\[([^\]]+)\]')

    def refs(self, expr):
        """-> (column refs [(table, col)], measure refs [name], unresolved bare refs [name])."""
        cols, meas, bare = [], [], []
        for m in self._TOKEN.finditer(expr):
            if m.group(1) is not None or m.group(3) is not None:
                tname = (m.group(1) or "").replace("''", "'") if m.group(1) is not None else m.group(3)
                inner = m.group(2) if m.group(1) is not None else m.group(4)
                t = self.table(tname)
                if t is None and m.group(3) is not None and m.group(3).upper() in DAX_KEYWORDS:
                    inner_name = inner
                    mm = self.measure(inner_name)
                    (meas if mm else bare).append(mm or inner_name)
                    continue
                ref = self.column(t, inner) if t else None
                if ref:
                    cols.append(ref)
                elif t and self.measure(inner):
                    meas.append(self.measure(inner))
                else:
                    bare.append("%s[%s]" % (tname, inner))
            elif m.group(5) is not None:
                mm = self.measure(m.group(5))
                (meas if mm else bare).append(mm or m.group(5))
        return cols, meas, bare

    def table_arg(self, arg):
        """A DAX table-expression argument -> the model table it scans, or None."""
        a = arg.strip()
        q = re.fullmatch(r"'((?:[^']|'')+)'", a)
        if q:
            return self.table(q.group(1).replace("''", "'"))
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_ ]*", a) and self.table(a):
            return self.table(a)
        m = re.match(r"(FILTER|CALCULATETABLE|RELATEDTABLE|KEEPFILTERS|ALL|ALLNOBLANKROW|VALUES|DISTINCT)\s*\(", a, re.I)
        if m:
            o = a.index("(")
            try:
                inner = split_top(a[o + 1:matching_paren(a, o)])
            except Unsupported:
                return None
            return self.table_arg(inner[0]) if inner else None
        cols, _m, _b = self.refs(a)
        return cols[0][0] if cols else None

    def scanned_tables(self, expr):
        """Tables an expression aggregates over (its facts)."""
        out = []
        for fn in COLUMN_AGGS | {"COUNTROWS"} | ITERATORS:
            for args in calls(expr, fn):
                if not args or not args[0]:
                    continue
                t = self.table_arg(args[0])
                if t and t not in out:
                    out.append(t)
        return out

    def ref_pair(self, text):
        """`'T'[C]` / `T[C]` -> (table, col) resolved, else None."""
        m = re.fullmatch(r"\s*(?:'((?:[^']|'')+)'|([A-Za-z_][A-Za-z0-9_ ]*?))\s*\[([^\]]+)\]\s*", text)
        if not m:
            return None
        return self.column((m.group(1) or "").replace("''", "'") if m.group(1) is not None else m.group(2), m.group(3))

    def measure_info(self, name):
        name = self.measure(name)
        if not name:
            return None
        info = dict(self.measures[name])
        e = info["expression"]
        cols, meas, bare = self.refs(e)
        fns = functions_in(e)
        info.update({
            "measure_refs": sorted(set(meas)),
            "column_refs": sorted(set(cols)),
            "unresolved_refs": sorted(set(bare)),
            "functions": fns,
            "scans": self.scanned_tables(e),
            "userelationship": [],
            "filter_removal": [],
            "selectors": [],
            "time_intel": sorted(set(fns) & TIME_INTEL),
            "treatas": "TREATAS" in fns,
            "crossfilter": "CROSSFILTER" in fns,
        })
        for args in calls(e, "USERELATIONSHIP"):
            if len(args) == 2:
                a, b = self.ref_pair(args[0]), self.ref_pair(args[1])
                if a and b:
                    info["userelationship"].append((a, b))
        for fn in sorted(FILTER_REMOVAL):
            for args in calls(e, fn):
                for a in args[:1] or ["<all>"]:
                    info["filter_removal"].append("%s(%s)" % (fn, a))
        for fn in sorted(SELECTORS):
            for args in calls(e, fn):
                if args and args[0]:
                    info["selectors"].append("%s(%s)" % (fn, args[0]))
        return info

    def closure(self, names):
        """Measure names -> dependency closure in evaluation order (dependencies first)."""
        seen, order = set(), []

        def visit(n, stack=()):
            n = self.measure(n)
            if not n or n in seen or n in stack:
                return
            for d in self.measure_info(n)["measure_refs"]:
                visit(d, stack + (n,))
            seen.add(n)
            order.append(n)

        for n in names:
            visit(n)
        return order


# --------------------------------------------------------------------------- signals / page inventory

def parse_query_ref(model, qr):
    """A PBIR queryRef -> {'kind': 'measure'|'column'|'implicit'|'unknown', ...}."""
    if not isinstance(qr, str) or not qr.strip():
        return {"kind": "unknown", "ref": qr}
    m = _AGG_WRAPPER.match(qr)
    if m:
        inner = parse_query_ref(model, m.group(2))
        if inner["kind"] == "column":
            return {"kind": "implicit", "ref": qr, "agg": _IMPLICIT_FN[m.group(1).lower()],
                    "table": inner["table"], "column": inner["column"]}
        return inner
    for i in [k for k, ch in enumerate(qr) if ch == "."]:
        t, f = qr[:i], qr[i + 1:]
        tt = model.table(t)
        if not tt:
            continue
        mm = model.measure(f)
        if mm and model.measures[mm]["table"] == tt:
            return {"kind": "measure", "ref": qr, "measure": mm, "table": tt}
        cc = model.column(tt, f)
        if cc:
            return {"kind": "column", "ref": qr, "table": cc[0], "column": cc[1]}
        # hierarchy-level refs ("T.Hierarchy.Level") resolve to their level column
        hl = f.split(".")
        if len(hl) >= 2:
            cc = _hierarchy_level(model, tt, hl[0], hl[-1])
            if cc:
                return {"kind": "column", "ref": qr, "table": cc[0], "column": cc[1]}
        if mm:
            return {"kind": "measure", "ref": qr, "measure": mm, "table": model.measures[mm]["table"]}
    mm = model.measure(qr.split(".")[-1])
    if mm:
        return {"kind": "measure", "ref": qr, "measure": mm, "table": model.measures[mm]["table"]}
    return {"kind": "unknown", "ref": qr}


def _hierarchy_level(model, table, hier, level):
    for h in (model.tables.get(table) or {}).get("hierarchies", []) or []:
        if norm(h.get("name")) != norm(hier):
            continue
        for lv in h.get("levels", []) or []:
            if norm(lv.get("name")) == norm(level):
                return model.column(table, lv.get("column"))
    return model.column(table, level)


def implicit_measure_name(agg, table, col):
    # no brackets: the name is used inside a DAX `[name]` reference
    return "__implicit__ %s %s.%s" % (agg, table, str(col).replace("]", ")"))


def implicit_measure_dax(agg, table, col):
    return "%s('%s'[%s])" % (agg, table.replace("'", "''"), col)


def is_slicer(v):
    vt = str(v.get("visual_type") or "")
    return str(v.get("sigma_kind")) == "control" or vt in ("slicer", "advancedSlicerVisual") or vt.startswith("SmartFilter")


def slicer_field(model, v):
    b = v.get("bindings") or {}
    order = [r for r in SLICER_ROLES if b.get(r)] + [r for r in b if r not in SLICER_ROLES]
    for role in order:
        for qr in b.get(role) or []:
            p = parse_query_ref(model, qr)
            if p["kind"] == "column":
                return p
    return None


def blank_policy(v):
    """'row': the slicer lists (Blank) as a member (Power BI's default). 'none': it does not
    (its own visual-level filter hides blanks, or it is a text/paste filter with no member list)."""
    vt = str(v.get("visual_type") or "").lower()
    if "text" in vt or "search" in vt or "paste" in vt:
        return "none"
    for f in v.get("filters") or []:
        if not isinstance(f, dict) or str(f.get("scope")) != "slicer-self":
            continue
        vals = f.get("values") or []
        blankish = [x for x in vals if x is None or (isinstance(x, str) and x.strip().lower() in ("", "(blank)"))]
        if str(f.get("mode")) == "exclude" and blankish:
            return "none"
        if str(f.get("mode")) == "include" and vals and not blankish:
            return "none"
        if f.get("type") in ("not-blank", "isnotblank") or str(f.get("condition", "")).lower().startswith("isnotblank"):
            return "none"
    return "row"


def saved_selection(v):
    st = v.get("slicer_state") or {}
    sel = st.get("saved_selection") if isinstance(st, dict) else None
    return sel if isinstance(sel, dict) and sel.get("values") is not None else None


def page_inventory(model, page):
    """One signals page -> its data visuals, slicers, measures and grouping columns."""
    inv = {"page_id": page.get("page_id"), "title": page.get("page_title") or page.get("page_id"),
           "visuals": [], "slicers": [], "measures": [], "groups": [], "unknown_refs": [],
           "filters": page.get("filters") or []}
    for v in page.get("visuals") or []:
        if v.get("hidden") and not is_slicer(v):
            continue
        eid = element_id_for_visual(v.get("visual_id"))
        if is_slicer(v):
            f = slicer_field(model, v)
            if f:
                inv["slicers"].append({
                    "visual_id": v.get("visual_id"), "element_id": eid,
                    "title": (v.get("header_title") or v.get("title") or f["column"]),
                    "field": (f["table"], f["column"]), "query_ref": f["ref"],
                    "saved_selection": saved_selection(v), "blank_policy": blank_policy(v),
                    "visual_type": v.get("visual_type"), "hidden": bool(v.get("hidden")),
                    "sync_group": v.get("sync_group"),
                })
            continue
        kind = str(v.get("sigma_kind") or "")
        groups, measures = [], []
        for role, qrs in (v.get("bindings") or {}).items():
            for qr in qrs or []:
                p = parse_query_ref(model, qr)
                if p["kind"] == "measure":
                    measures.append({"name": p["measure"], "query_ref": qr})
                elif p["kind"] == "implicit":
                    nm = implicit_measure_name(p["agg"], p["table"], p["column"])
                    measures.append({"name": nm, "query_ref": qr, "implicit": (p["agg"], p["table"], p["column"])})
                elif p["kind"] == "column":
                    if kind != "table" and role in VALUE_ROLES:
                        agg = model.summarize_by(p["table"], p["column"])
                        if agg:
                            nm = implicit_measure_name(agg, p["table"], p["column"])
                            measures.append({"name": nm, "query_ref": qr, "implicit": (agg, p["table"], p["column"])})
                        continue
                    if role in NON_GROUP_ROLES:
                        continue
                    g = (p["table"], p["column"])
                    if g not in [x["field"] for x in groups]:
                        groups.append({"field": g, "query_ref": qr})
                else:
                    inv["unknown_refs"].append(qr)
        if not measures and not groups:
            continue
        dn = v.get("display_names") or {}
        for x in measures:
            x["display"] = dn.get(x["query_ref"]) or (x["name"] if "implicit" not in x else x["implicit"][2])
        for x in groups:
            x["display"] = dn.get(x["query_ref"]) or x["field"][1]
        inv["visuals"].append({
            "visual_id": v.get("visual_id"), "element_id": eid, "kind": kind, "visual_type": v.get("visual_type"),
            "title": v.get("title") or v.get("visual_id"), "groups": groups, "measures": measures,
            "filters": v.get("filters") or [],
        })
        for x in measures:
            if x["name"] not in [m["name"] for m in inv["measures"]]:
                inv["measures"].append(x)
        for x in groups:
            if x["field"] not in [g["field"] for g in inv["groups"]]:
                inv["groups"].append(x)
    return inv


def normalize_filter(model, f):
    """A filter signal -> ({field, values, exclude}, None) for a list filter on a model column, else
    (None, reason). Slicer-self and empty (predicate: none) filters are ({}, None): nothing to do."""
    if not isinstance(f, dict) or str(f.get("scope")) == "slicer-self" or f.get("predicate") == "none":
        return {}, None
    tgt = parse_query_ref(model, f.get("target") or f.get("field") or "")
    what = "%s filter on %s" % (f.get("type") or "?", f.get("target") or "?")
    if tgt["kind"] != "column":
        return None, what + ": not a model column (a measure or an unresolved field)"
    if f.get("type") != "list" or not isinstance(f.get("values"), list):
        return None, what + ": only list (include/exclude) filters are applied automatically"
    return {"field": (tgt["table"], tgt["column"]), "values": list(f["values"]),
            "exclude": str(f.get("mode")) == "exclude"}, None


def context_filters(model, signals, page):
    """Report- and page-level filters -> (list filters [{field, values, exclude, scope}], notes [str])."""
    out, notes = [], []
    for scope, fl in (("report", (signals or {}).get("filters")), ("page", page.get("filters"))):
        for f in fl or []:
            nf, why = normalize_filter(model, f)
            if why:
                notes.append("%s %s" % (scope, why))
            elif nf:
                out.append(dict(nf, scope=scope))
    return out, notes


def register_implicit_measures(model, inv):
    """Make each implicit (column-in-Values) aggregate a real entry in model.measures."""
    for x in inv["measures"]:
        if "implicit" in x and x["name"] not in model.measures:
            agg, t, c = x["implicit"]
            model.measures[x["name"]] = {"name": x["name"], "table": t, "format": None,
                                         "expression": implicit_measure_dax(agg, t, c), "implicit": True}
            model._mci[x["name"].lower()] = x["name"]


# --------------------------------------------------------------------------- filter paths

def _rel_key(model, a, b):
    """USERELATIONSHIP(a, b) -> the relationship id joining those two columns (either order)."""
    for r in model.relationships:
        ends = {(norm(r["from"][0]), norm(r["from"][1])), (norm(r["to"][0]), norm(r["to"][1]))}
        if ends == {(norm(a[0]), norm(a[1])), (norm(b[0]), norm(b[1]))}:
            return r["id"]
    return None


class FilterGraph:
    """Relationships usable for filter propagation under a set of USERELATIONSHIP activations."""

    def __init__(self, model, activated=()):
        self.model = model
        self.activated, self.unresolved = set(), []
        for a, b in activated or ():
            rid = _rel_key(model, a, b)
            if rid:
                self.activated.add(rid)
            else:
                self.unresolved.append((a, b))
        act_pairs = {frozenset((r["from"][0], r["to"][0])) for r in model.relationships if r["id"] in self.activated}
        self.usable = []
        for r in model.relationships:
            if r["id"] in self.activated:
                self.usable.append(r)
            elif r["active"] and frozenset((r["from"][0], r["to"][0])) not in act_pairs:
                self.usable.append(r)

    def require_resolved(self):
        """USERELATIONSHIP pairs that name no model relationship would silently fall back to the active
        path; refuse them instead."""
        if self.unresolved:
            a, b = self.unresolved[0]
            raise Unsupported("USERELATIONSHIP(%s[%s], %s[%s]) names no relationship in the model" % (a + b))
        return self

    def hops_from(self, table):
        """(relationship, from_table, from_col, to_table, to_col, hop_type) a filter can take out of `table`."""
        for r in self.usable:
            mm = r["from_card"] == "many" and r["to_card"] == "many"
            if r["to"][0] == table:  # one side -> many side: the default direction
                yield (r, r["to"][0], r["to"][1], r["from"][0], r["from"][1], "M:M" if mm else "1:M")
            if r["from"][0] == table and (r["bidi"] or (r["from_card"] == "one" and r["to_card"] == "one")):
                one_one = r["from_card"] == "one" and r["to_card"] == "one"
                yield (r, r["from"][0], r["from"][1], r["to"][0], r["to"][1], "M:M" if mm else ("1:M" if one_one else "M:1"))

    def paths(self, source, target, max_len=6):
        out = []

        def walk(t, path, seen):
            if t == target:
                out.append(list(path))
                return
            if len(path) >= max_len:
                return
            for hop in self.hops_from(t):
                if hop[3] in seen:
                    continue
                path.append(hop)
                walk(hop[3], path, seen | {hop[3]})
                path.pop()

        if source == target:
            return [[]]
        walk(source, [], {source})
        return out

    @staticmethod
    def tier(types):
        t = ["M:M" if x == "M:M" else ("1:M" if x in ("1:M", "1:1") else "M:1") for x in types]
        if not t or all(x == "1:M" for x in t):
            return 1
        if all(x in ("1:M", "M:M") for x in t):
            return 2
        if all(x == "M:1" for x in t):
            return 3
        for k in range(1, len(t)):
            if all(x == "1:M" for x in t[:k]) and all(x == "M:1" for x in t[k:]):
                return 4
        for k in range(1, len(t)):
            if all(x in ("1:M", "M:M") for x in t[:k]) and all(x in ("M:1", "M:M") for x in t[k:]):
                return 5
        return 6

    def best_path(self, source, target):
        """-> (path or None, info). info: candidates, tier, weight, ambiguous, reason."""
        cands = self.paths(source, target)
        info = {"source": source, "target": target, "candidates": len(cands), "ambiguous": False}
        if not cands:
            info["reason"] = "no active relationship path from %s to %s" % (source, target)
            return None, info
        if len(cands) == 1:
            p = cands[0]
            info.update(tier=self.tier([h[5] for h in p]), weight=int(any(h[0]["id"] in self.activated for h in p)))
            return p, info
        common = set.intersection(*[{h[0]["id"] for h in p} for p in cands])
        scored = []
        for p in cands:
            rest = [h for h in p if h[0]["id"] not in common] or p
            scored.append((self.tier([h[5] for h in rest]), -int(any(h[0]["id"] in self.activated for h in p)), len(p), p))
        scored.sort(key=lambda x: (x[0], x[1]))
        best = [s for s in scored if (s[0], s[1]) == (scored[0][0], scored[0][1])]
        info.update(tier=best[0][0], weight=-best[0][1])
        if len(best) > 1:
            info["ambiguous"] = True
            info["reason"] = "%d paths share priority tier %d and weight %d" % (len(best), best[0][0], -best[0][1])
            info["paths"] = [describe_path(s[3], self.activated) for s in best]
            return None, info
        info["chosen_over"] = [describe_path(s[3], self.activated) for s in scored if s is not best[0]]
        return best[0][3], info


def describe_path(path, activated=()):
    if not path:
        return "(same table)"
    bits = [path[0][1]]
    for r, ft, fc, tt, tc, ht in path:
        bits.append("--%s[%s]=%s[%s] %s%s--> %s" % (ft, fc, tt, tc, ht, " USERELATIONSHIP" if r["id"] in activated else "", tt))
    return " ".join(bits)


def path_json(graph, path):
    return [{"relationship": h[0]["id"], "from": [h[1], h[2]], "to": [h[3], h[4]], "hop": h[5],
             "activated": h[0]["id"] in graph.activated} for h in path]


# --------------------------------------------------------------------------- warehouse sources

def quote_ident(name):
    return '"' + str(name).replace('"', '""') + '"'


def quote_path(path):
    parts = []
    for p in path:
        s = str(p)
        parts.append(s if re.fullmatch(r"[A-Z_][A-Z0-9_$]*", s) else quote_ident(s))
    return ".".join(parts)


def sql_literal(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return repr(v) if isinstance(v, float) else str(v)
    return "'" + str(v).replace("'", "''") + "'"


class SourceIndex:
    """Model table -> its data-model element SQL; model column -> the SQL output column."""

    def __init__(self, model, dm_spec, master_map=None):
        self.model = model
        doc = dm_spec or {}
        for key in ("sigmaDataModel", "dataModel", "spec"):
            if isinstance(doc.get(key), dict) and doc[key].get("pages"):
                doc = doc[key]
        self.elements = [e for p in doc.get("pages", []) or [] for e in p.get("elements", []) or []]
        self.by_id = {e.get("id"): e for e in self.elements if e.get("id")}
        self.by_name = {}
        for e in self.elements:
            if e.get("name"):
                self.by_name.setdefault(norm(e["name"]), e)
        self.table_el = {}
        masters = (master_map or {}).get("masters") or {}
        for key, m in masters.items():
            t = model.table(key)
            if not t:
                continue
            el = self.by_id.get(m.get("element_id"))
            if el is None:
                for c in m.get("columns", []) or []:
                    mm = re.match(r"\[([^/\]]+)/", str(c.get("formula", "")))
                    if mm and norm(mm.group(1)) in self.by_name:
                        el = self.by_name[norm(mm.group(1))]
                        break
            if el is not None:
                self.table_el[t] = el

    def element(self, table):
        t = self.model.table(table) or table
        if t in self.table_el:
            return self.table_el[t]
        el = self.by_name.get(norm(t))
        if el is None:
            for p in (self.model.tables.get(t) or {}).get("partitions", []) or []:
                ent = (p.get("source") or {}).get("entityName") or (p.get("source") or {}).get("table")
                if ent and norm(ent) in self.by_name:
                    el = self.by_name[norm(ent)]
                    break
        return el

    def kind(self, table):
        el = self.element(table)
        return (el or {}).get("source", {}).get("kind")

    def from_sql(self, table):
        el = self.element(table)
        if el is None:
            raise Unsupported("no data-model element for table %s" % table)
        src = el.get("source") or {}
        if src.get("kind") == "sql" and src.get("statement"):
            return "(\n" + str(src["statement"]).strip().rstrip(";") + "\n)"
        if src.get("kind") == "warehouse-table" and src.get("path"):
            return quote_path(src["path"])
        raise Unsupported("data-model element %s for table %s has no SQL or warehouse path" % (el.get("id"), table))

    def cte_body(self, table):
        """The SELECT that defines `table` inside a WITH clause."""
        el = self.element(table)
        src = (el or {}).get("source") or {}
        if src.get("kind") == "sql" and src.get("statement"):
            return str(src["statement"]).strip().rstrip(";")
        return "SELECT * FROM " + self.from_sql(table)

    def outputs(self, table):
        """Physical/output column names the element exposes."""
        el = self.element(table) or {}
        out = []
        for c in el.get("columns", []) or []:
            f = str(c.get("formula") or "")
            m = re.fullmatch(r"\[Custom SQL/([^\]]+)\]", f)
            if m:
                out.append(m.group(1))
                continue
            cid = str(c.get("id") or "")
            if "/" in cid:
                out.append(cid.split("/", 1)[1])
        return out

    def column(self, table, col):
        """-> (quoted SQL identifier, status). status: exact | case | fuzzy | assumed."""
        t, c = self.model.column(table, col) or (table, col)
        if self.model.is_calculated(t, c):
            raise Unsupported("%s[%s] is a DAX calculated column (no warehouse column)" % (t, c))
        want = [self.model.source_column(t, c), c]
        outs = self.outputs(t)
        for w in want:
            if w in outs:
                return quote_ident(w), "exact"
        for w in want:
            hit = [o for o in outs if o.lower() == str(w).lower()]
            if len(hit) == 1:
                return quote_ident(hit[0]), "case"
        for w in want:
            hit = [o for o in outs if norm(o) == norm(w)]
            if len(hit) == 1:
                return quote_ident(hit[0]), "fuzzy"
        return quote_ident(want[0]), "assumed"


# --------------------------------------------------------------------------- SQL: joins and semi-joins

TEXT_TYPE = {"snowflake": "VARCHAR", "databricks": "STRING", "bigquery": "STRING", "sqlite": "VARCHAR"}
FLOAT_TYPE = {"snowflake": "DOUBLE", "databricks": "DOUBLE", "bigquery": "FLOAT64", "sqlite": "DOUBLE"}


def value_set_sql(ctl):
    return "{{" + ctl + "}}"


def array_length_sql(ctl):
    return "{{#formula ArrayLength([" + ctl + "])}}"


def text_cast(expr, dialect="snowflake"):
    return "CAST(%s AS %s)" % (expr, TEXT_TYPE.get(dialect, "VARCHAR"))


def attr_match(alias_col, values, blank, dialect="snowflake", typed=False, blank_selected=None):
    """Membership of the slicer attribute. Text: COALESCE(CAST(x AS text), '(Blank)') IN values, so a
    '(Blank)' pick selects NULL. Typed (number, date, boolean lists): x IN values, with IS NULL only
    when a blank is statically selected."""
    if typed:
        base = "%s IN %s" % (alias_col, values) if values.strip() != "()" else "FALSE"
        return "(%s OR %s IS NULL)" % (base, alias_col) if blank_selected else base
    if blank:
        return "COALESCE(%s, '(Blank)') IN %s" % (text_cast(alias_col, dialect), values)
    return "%s IN %s" % (text_cast(alias_col, dialect), values)


def semi_join(src, path, slicer_col_sql, target_alias, values, blank=True, dialect="snowflake", refs=None,
              typed=False, blank_selected=None):
    """Condition on the target (fact) row `target_alias` that its filter path `path`
    (hops slicer table -> ... -> fact) carries the selection `values` (rendered SQL list).

    Each hop becomes `x.col IN (SELECT k.col FROM <src> k WHERE <cond on k>)`, a semi-join, so a
    duplicate key on the one side never multiplies fact rows. With `blank`, a one-to-many hop
    also lets rows whose key is NULL or matches no row reach Power BI's blank member:
    `OR ('(Blank)' IN values AND (x.col IS NULL OR x.col NOT IN (SELECT k.col ... IS NOT NULL)))`.
    `blank_selected` True/False makes that test static (literal page filters); None keeps it
    dynamic on the rendered values. The blank term is only added while every hop so far is
    one-to-many: the blank virtual row of a one-side table has blank attributes all the way up such
    a chain. `refs` maps a table to a CTE name already defined in the surrounding SQL (else its
    source SQL is inlined). The result can be NULL (SQL unknown) for a NULL key: wrap it in
    COALESCE(..., FALSE) before negating it."""
    refs = refs or {}
    ref = lambda t: refs.get(t) or src.from_sql(t)
    if not path:
        return attr_match("%s.%s" % (target_alias, slicer_col_sql), values, blank, dialect, typed, blank_selected)
    n = len(path)
    k_alias = "sj%d" % n
    cond = attr_match("%s.%s" % (k_alias, slicer_col_sql), values, blank, dialect, typed, blank_selected)
    all_one_to_many = True
    for i, hop in enumerate(path):
        r, ft, fc, tt, tc, ht = hop
        all_one_to_many = all_one_to_many and ht in ("1:M", "1:1")
        from_ident, _ = src.column(ft, fc)
        to_ident, _ = src.column(tt, tc)
        x_alias = target_alias if i == n - 1 else "sj%d" % (n - i - 1)
        c = "%s.%s IN (SELECT %s.%s FROM %s %s WHERE %s)" % (x_alias, to_ident, k_alias, from_ident, ref(ft), k_alias, cond)
        if blank and all_one_to_many and blank_selected is not False:
            test = "" if blank_selected else "'(Blank)' IN %s AND " % values
            c = ("(%s OR (%s(%s.%s IS NULL OR %s.%s NOT IN "
                 "(SELECT sjb.%s FROM %s sjb WHERE sjb.%s IS NOT NULL))))"
                 % (c, test, x_alias, to_ident, x_alias, to_ident, from_ident, ref(ft), from_ident))
        cond = c
        k_alias = x_alias
    return cond


def literal_filter(src, model, path, field, values, exclude, target_alias, dialect="snowflake", refs=None):
    """A fixed report/page list filter as a predicate on the fact row (Power BI semantics, incl. blanks)."""
    col, _ = src.column(*field)
    picks = [v for v in values if v is not None]
    has_blank = len(picks) != len(values)
    typ = model.column_type(*field)
    if typ == "string":
        lits = [sql_literal(str(v)) for v in picks] + (["'(Blank)'"] if has_blank else [])
        cond = semi_join(src, path, col, target_alias, "(%s)" % ", ".join(lits or ["''"]), blank=True,
                         dialect=dialect, refs=refs, blank_selected=has_blank)
    else:
        lits = [sql_literal(v) for v in picks]
        cond = semi_join(src, path, col, target_alias, "(%s)" % ", ".join(lits), blank=True, dialect=dialect,
                         refs=refs, typed=True, blank_selected=has_blank)
    return "NOT COALESCE(%s, FALSE)" % cond if exclude else cond


def guarded(ctl, condition):
    return "(CASE WHEN %s = 0 THEN TRUE ELSE %s END)" % (array_length_sql(ctl), condition)


def join_chain(src, fact, paths, fact_alias="f", refs=None):
    """LEFT JOIN chain from the fact outward along each table's filter path.

    `paths` = {table: path (grouping table -> ... -> fact)}. Every hop walked from the fact side
    must be many-to-one (the fact side is the many side), otherwise the join would fan out fact
    rows and Unsupported is raised. Returns (join lines, {table: alias})."""
    refs = refs or {}
    joins, aliases, by_prefix = [], {fact: fact_alias}, {}
    n = 0
    for table, path in paths.items():
        if table == fact:
            continue
        cur_alias, prefix = fact_alias, ()
        for hop in reversed(path):
            r, ft, fc, tt, tc, ht = hop
            if ht not in ("1:M", "1:1"):
                raise Unsupported("the path from %s to %s crosses a %s relationship (%s); a join would fan out fact rows"
                                  % (table, fact, ht, r["id"]))
            prefix = prefix + (r["id"], ft)
            if prefix not in by_prefix:
                n += 1
                alias = "j%d" % n
                k_one, _ = src.column(ft, fc)
                k_many, _ = src.column(tt, tc)
                joins.append("LEFT JOIN %s %s ON %s.%s = %s.%s"
                             % (refs.get(ft) or src.from_sql(ft), alias, alias, k_one, cur_alias, k_many))
                by_prefix[prefix] = alias
            cur_alias = by_prefix[prefix]
        aliases[table] = cur_alias
    return joins, aliases


def find_hooks(sql):
    """`/*@slicers fact="T" alias="f" userelationship="'A'[x]|'B'[y];..."*/` markers in a page-fact SQL."""
    out = []
    for m in re.finditer(r"/\*@slicers\s+(.*?)\*/", sql, re.S):
        attrs = dict(re.findall(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', m.group(1)))
        srcs = dict(p.split("=", 1) for p in attrs.get("sources", "").split(";") if "=" in p)
        out.append({"span": m.span(), "text": m.group(0), "fact": attrs.get("fact"), "alias": attrs.get("alias", "f"),
                    "userelationship": attrs.get("userelationship", ""), "sources": srcs})
    return out


def hook_marker(fact, alias, activations, ctes=None):
    act = ";".join("'%s'[%s]|'%s'[%s]" % (a[0].replace("'", "''"), a[1], b[0].replace("'", "''"), b[1])
                   for a, b in activations)
    srcs = ";".join("%s=%s" % (t.replace('"', ''), c) for t, c in sorted((ctes or {}).items()))
    return '/*@slicers fact="%s" alias="%s"%s%s*/' % (
        fact.replace('"', ''), alias, (' userelationship="%s"' % act) if act else "", (' sources="%s"' % srcs) if srcs else "")


def parse_activations(model, text):
    out = []
    for part in [p for p in (text or "").split(";") if p.strip()]:
        a, _, b = part.partition("|")
        ra, rb = model.ref_pair(a), model.ref_pair(b)
        if ra and rb:
            out.append((ra, rb))
    return out
