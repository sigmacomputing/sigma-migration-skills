#!/usr/bin/env python3
"""Compile a Solver report definition (IR from solver_def.py) into lines over "bases", then into SQL or values.

A Solver report is a grid. Report, Column, Row and Cell items each carry dimension filters; a Cell item's formula
reads a fact value through ``OSRGet("<fact>","<value>")`` in the context of its row and column. Plain-Excel formulas
around the Solver cells (subtotals, ratios, variances) reference other cells.

  * **base**   one aggregate: SUM(<fact value>) over the rows matching one resolved predicate.
  * **line**   one report row; each value column holds ``num / den`` where num and den are linear combinations of
               bases (den absent = plain sum). Covers OSRGet with a sign, SUM(OSRRef(...)), cell arithmetic,
               ratios and IFERROR(..., <constant>).
  * **detail** an expanded Row item (``Expand=true``): one output row per member, grouped by the attributes its cells
               read, with the fact values summed.

Context resolution (verified against executed runs): for each dimension, the most specific level that filters it
wins: Cell > Row > Column > Report. A FilterGroup is evaluated left to right; ``Not`` on its first expression is a
unary NOT. Comparisons are case-insensitive. Anything outside this grammar raises ``Unsupported`` and is reported as
a gap: the compiler never guesses.

Stdlib only.
"""
import csv
import json
import re
from fractions import Fraction

import solver_def

OSR_PREFIX = re.compile(r"_xll\.OneStop\.ReportPlayer\.OSRFunctions\.", re.I)
PERIOD_FN = re.compile(r"^\{\s*PeriodCalc\.GetFunction\(\s*(\w+)\s*,\s*@([^)]+?)\s*\)\s*\}$", re.I)
PARAM_REF = re.compile(r"^\{\s*@([^}]+?)\s*\}$")
PERIOD_DIM = "Period"
NUMERIC_TYPES = ("System.Decimal", "System.Int32", "System.Int64", "System.Double")
DATE_DIMS = ("Date",)
DATE_PARAM_TYPES = ("OneStop.PeriodInterval", "System.DateTime", "System.DateTimeOffset")
DATE_PARAM_KINDS = ("PeriodSelection", "DatePicker")


class Unsupported(Exception):
    """A construct the compiler does not translate. Surfaces as a gap; never silently approximated."""


TEXT_FN = re.compile(r"^\s*=?\s*(TRIM|MID|LEFT|RIGHT|UPPER|LOWER|PROPER|TEXT|DOLLAR|CONCATENATE|CONCAT)\s*\(", re.I)


def _top_args(s):
    """Top-level arguments of a call whose opening parenthesis was just consumed."""
    out, buf, depth, quoted = [], "", 0, False
    for ch in s:
        if ch == '"':
            quoted = not quoted
        elif not quoted and ch == "(":
            depth += 1
        elif not quoted and ch == ")":
            if depth == 0:
                return out + [buf]
            depth -= 1
        elif not quoted and ch == "," and depth == 0:
            out.append(buf)
            buf = ""
            continue
        buf += ch
    return out + [buf]


def is_text_formula(f, fact_tables=()):
    """True for cells that render text rather than a number."""
    g = OSR_PREFIX.sub("", f or "")
    if TEXT_FN.match(g) or "&" in re.sub(r'"[^"]*"', "", g) or re.match(r'^\s*=?\s*"', g):
        return True
    m = re.match(r"^\s*=?\s*IF\s*\(", g, re.I)
    if m:
        branches = _top_args(g[m.end():])[1:3]
        return bool(branches) and all(re.fullmatch(r'\s*"[^"]*"\s*', b) or is_text_formula(b) for b in branches)
    gets = re.findall(r'OSRGet\(\s*"([^"]+)"', g, re.I)
    return bool(gets) and not any(t in fact_tables or t.endswith("_F_Trans") for t in gets)


# ============================================================================================ periods
def period_window(fn, n_fy_start=1):
    """(start_offset, end_offset, shift) in months relative to the selected period, for a PeriodCalc function.

    Returned as a callable: idx -> (lo_idx, hi_idx) where idx = year*12 + month - 1."""
    f = fn.upper()

    def fy_start(i):
        m = i % 12 + 1
        return i - ((m - n_fy_start) % 12)

    def q_start(i):
        m = i % 12 + 1
        return i - ((m - n_fy_start) % 3)

    table = {
        "TPTY": lambda i: (i, i), "TPLY": lambda i: (i - 12, i - 12),
        "QTD": lambda i: (q_start(i), i), "QTDLY": lambda i: (q_start(i) - 12, i - 12),
        "YTD": lambda i: (fy_start(i), i), "LYTD": lambda i: (fy_start(i) - 12, i - 12),
    }
    if f in table:
        return table[f]
    m = re.match(r"^R[A-Z]*?(\d+)M(LY)?$", f)          # rolling N months, e.g. R12M, RBC12M (+LY)
    if m:
        n, ly = int(m.group(1)), 12 if m.group(2) else 0
        return lambda i: (i - n + 1 - ly, i - ly)
    raise Unsupported(f"PeriodCalc function {fn!r}")


def yyyymm_to_idx(p):
    p = int(Fraction(str(p)))
    return (p // 100) * 12 + (p % 100) - 1


def idx_to_yyyymm(i):
    return (i // 12) * 100 + (i % 12) + 1


# ============================================================================================ conditions
def split_tokens(cond):
    """Comma-separated condition -> tokens, keeping {…} expressions intact."""
    out, buf, depth = [], "", 0
    for ch in cond or "":
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(buf.strip())
            buf = ""
        else:
            buf += ch
    if buf.strip():
        out.append(buf.strip())
    return out


def _param_meta(params, name):
    return next((x for x in (params or []) if (x.get("name") or "").lower() == name.lower()), None)


def is_date_param(meta):
    return bool(meta) and (bool(meta.get("is_period")) or meta.get("data_type") in DATE_PARAM_TYPES
                           or meta.get("type") in DATE_PARAM_KINDS)


def leaf(dim, field, op, cond, params=None):
    """One Expression -> predicate leaf (a dict). Values are kept raw; matching is case-insensitive.
    ``params`` (the report's parameters) lets a date-range parameter on an attribute be reported as a gap."""
    if op not in ("In", "Contains"):
        raise Unsupported(f"filter operator {op!r} on {dim}.{field}")
    if op == "Contains":
        return {"k": "contains", "dim": dim, "field": field, "text": cond.strip().strip('"')}
    toks = split_tokens(cond)
    if dim == PERIOD_DIM:
        if len(toks) != 1:
            raise Unsupported(f"period condition with several tokens: {cond!r}")
        t = toks[0]
        m = PERIOD_FN.match(t)
        if m:
            period_window(m.group(1))                      # validate now
            return {"k": "period_fn", "dim": dim, "field": field, "fn": m.group(1).upper(), "param": m.group(2).strip()}
        m = PARAM_REF.match(t)
        if m:
            return {"k": "period_fn", "dim": dim, "field": field, "fn": "TPTY", "param": m.group(1).strip()}
        if re.match(r"^\d{6}(:\d{6})?$", t):
            lo, _, hi = t.partition(":")
            return {"k": "period_lit", "dim": dim, "field": field, "lo": int(lo), "hi": int(hi or lo)}
        raise Unsupported(f"period condition {cond!r}")
    if dim in DATE_DIMS:
        raise Unsupported(f"date filter on {dim}.{field} ({cond!r}): Solver compares stored datetimes, both ends "
                          "inclusive; not translated")
    parts = []
    for t in toks:
        m = PARAM_REF.match(t)
        if m:
            name = m.group(1).strip()
            if is_date_param(_param_meta(params, name)):
                raise Unsupported(f"date-range parameter {{@{name}}} on {dim}.{field}: Solver tests the stored datetime "
                                  "against both ends of the range; not translated")
            parts.append({"param": name})
        elif "{" in t or "'" in t:
            raise Unsupported(f"condition expression {t!r} on {dim}.{field}")
        elif "*" in t and (":" in t or t.count("*") > 1 or not t.endswith("*")):
            raise Unsupported(f"wildcard {t!r} on {dim}.{field}: only a trailing * (prefix match) is translated")
        elif ":" in t:
            lo, hi = [x.strip() for x in t.split(":", 1)]
            parts.append({"lo": lo, "hi": hi})
        else:
            parts.append({"eq": t})
    return {"k": "in", "dim": dim, "field": field, "parts": parts}


def group_pred(exprs, params=None):
    """A FilterGroup -> predicate tree, evaluated left to right."""
    acc = None
    for e in exprs:
        lf = leaf(e["dim"], e["field"], e["op"], e["cond"], params)
        lo = e.get("logic")
        if acc is None:
            acc = {"k": "not", "x": lf} if lo == "Not" else lf
        elif lo == "And":
            acc = {"k": "and", "xs": [acc, lf]}
        elif lo == "Or":
            acc = {"k": "or", "xs": [acc, lf]}
        elif lo == "AndNot":
            acc = {"k": "and", "xs": [acc, {"k": "not", "x": lf}]}
        elif lo == "OrNot":
            acc = {"k": "or", "xs": [acc, {"k": "not", "x": lf}]}
        else:
            raise Unsupported(f"logical operator {lo!r}")
    return acc


def element_groups(el, params=None):
    """{group name (dimension): predicate} for one DefinitionElement."""
    out = {}
    for fg in el.get("filters", []):
        p = group_pred(fg["exprs"], params)
        if p is not None:
            g = fg["group"]
            out[g] = {"k": "and", "xs": [out[g], p]} if g in out else p
    return out


# ============================================================================================ expressions
# A cell value is an expression tree over bases (each base is a SUM at the report grain), so any arithmetic
# Excel allows between Solver cells is exact here: ratios of sums, differences of ratios, rate x count.
#   ["base", id] | ["const", "p/q"] | ["neg", x] | ["add", x, y] | ["sub", x, y] | ["mul", x, y] | ["div", x, y]
#   | ["iferror", x, fallback]
def K(x):
    return ["const", str(Fraction(x))]


def add(a, b, sign=1):
    return ["add" if sign == 1 else "sub", a, b]


def is_const(e):
    return e[0] == "const"


def bases_of(e, acc=None):
    acc = set() if acc is None else acc
    if e[0] == "base":
        acc.add(e[1])
    for x in e[1:]:
        if isinstance(x, list):
            bases_of(x, acc)
    return acc


def eval_expr(e, bv):
    """Fraction, or None for an error (division by zero) not caught by IFERROR."""
    k = e[0]
    if k == "base":
        return bv.get(e[1], Fraction(0))
    if k == "const":
        return Fraction(e[1])
    if k == "iferror":
        x = eval_expr(e[1], bv)
        return x if x is not None else eval_expr(e[2], bv)
    vals = [eval_expr(x, bv) for x in e[1:]]
    if any(v is None for v in vals):
        return None
    if k == "neg":
        return -vals[0]
    a, b = vals
    if k == "add":
        return a + b
    if k == "sub":
        return a - b
    if k == "mul":
        return a * b
    if k == "div":
        return None if b == 0 else a / b
    raise Unsupported(f"expression {k}")


def expr_sql(e, base_col):
    """Snowflake SQL. An empty base is 0 (as in Excel); x/0 is NULL, which IFERROR's COALESCE then replaces."""
    k = e[0]
    if k == "base":
        return f"COALESCE({base_col(e[1])}, 0)"
    if k == "const":
        f = Fraction(e[1])
        return str(f.numerator) if f.denominator == 1 else f"({f.numerator} / {f.denominator})"
    if k == "neg":
        return f"(-{expr_sql(e[1], base_col)})"
    if k == "iferror":
        return f"COALESCE({expr_sql(e[1], base_col)}, {expr_sql(e[2], base_col)})"
    a, b = expr_sql(e[1], base_col), expr_sql(e[2], base_col)
    if k == "div":
        return f"({a} / NULLIF({b}, 0))"
    return f"({a} {dict(add='+', sub='-', mul='*')[k]} {b})"


TOKEN = re.compile(r'\s*(?:(?P<str>"[^"]*")|(?P<num>\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)'
                   r"|(?P<ref>\$?[A-Z]{1,3}\$?\d+(?::\$?[A-Z]{1,3}\$?\d+)?)|(?P<name>[A-Za-z_][A-Za-z0-9_.]*)|(?P<op>[-+*/(),%]))")


def tokenize(src):
    pos, out = 0, []
    s = src.strip()
    if s.startswith("="):
        s = s[1:]
    s = OSR_PREFIX.sub("", s)
    while pos < len(s):
        m = TOKEN.match(s, pos)
        if not m or m.end() == pos:
            if s[pos:].strip() == "":
                break
            raise Unsupported(f"formula token at {s[pos:pos + 20]!r}")
        pos = m.end()
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
    return out


def expand_range(ref):
    a, _, b = ref.replace("$", "").partition(":")
    ca, ra = solver_def._col_letters(a)
    if not b:
        return [(ca, ra)]
    cb, rb = solver_def._col_letters(b)
    out = []
    for c in range(solver_def.col_to_num(ca), solver_def.col_to_num(cb) + 1):
        for r in range(ra, rb + 1):
            out.append((solver_def.num_to_col(c), r))
    return out


class FormulaParser:
    """Recursive descent over the small Excel subset Solver reports use. ``osr_get(table, attr)`` and
    ``cell(col_letter, row)`` are callbacks returning an expression (or raising Unsupported)."""

    def __init__(self, tokens, osr_get, cell):
        self.t, self.i, self.osr_get, self.cell = tokens, 0, osr_get, cell

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self, kind=None, val=None):
        k, v = self.peek()
        if (kind and k != kind) or (val is not None and v != val):
            raise Unsupported(f"formula: expected {val or kind}, found {v!r}")
        self.i += 1
        return v

    def parse(self):
        r = self.expr()
        if self.i != len(self.t):
            raise Unsupported(f"formula: trailing {self.peek()[1]!r}")
        return r

    def expr(self):
        r = self.term()
        while self.peek() in (("op", "+"), ("op", "-")):
            sign = 1 if self.take("op") == "+" else -1
            r = add(r, self.term(), sign)
        return r

    def term(self):
        r = self.factor()
        while self.peek() in (("op", "*"), ("op", "/")):
            op = self.take("op")
            r = ["mul" if op == "*" else "div", r, self.factor()]
        return r

    def factor(self):
        k, v = self.peek()
        if (k, v) == ("op", "-"):
            self.take()
            return ["neg", self.factor()]
        if (k, v) == ("op", "+"):
            self.take()
            return self.factor()
        if k == "num":
            self.take()
            r = K(Fraction(v))
            if self.peek() == ("op", "%"):
                self.take()
                r = K(Fraction(v) / 100)
            return r
        if k == "ref":
            self.take()
            cells = expand_range(v)
            if len(cells) != 1:
                raise Unsupported(f"bare range {v} outside SUM")
            return self.cell(*cells[0])
        if (k, v) == ("op", "("):
            self.take()
            r = self.expr()
            self.take("op", ")")
            return r
        if k == "name":
            name = self.take().upper()
            self.take("op", "(")
            return self.call(name)
        raise Unsupported(f"formula: unexpected {v!r}")

    def args(self):
        out = []
        if self.peek() == ("op", ")"):
            self.take()
            return out
        while True:
            k, v = self.peek()
            nxt = self.t[self.i + 1] if self.i + 1 < len(self.t) else (None, None)
            if (k, v) in (("op", ","), ("op", ")")):          # empty argument: Excel reads it as 0
                out.append(("val", K(0)))
            elif k in ("ref", "str") and nxt in (("op", ","), ("op", ")")):
                self.take()
                out.append((k, v))
            else:
                out.append(("val", self.expr()))
            if self.take("op") == ")":
                return out

    def call(self, name):
        a = self.args()
        if name == "OSRGET":
            if len(a) != 2 or any(x[0] != "str" for x in a):
                raise Unsupported("OSRGet with non-literal arguments")
            return self.osr_get(a[0][1].strip('"'), a[1][1].strip('"'))
        if name in ("SUM", "OSRREF"):
            terms = []
            for kind, v in a:
                if kind == "ref":
                    terms += [self.cell(c, r) for c, r in expand_range(v)]
                elif kind == "val":
                    terms.append(v)
                else:
                    raise Unsupported(f"{name} of a string")
            total = terms[0] if terms else K(0)
            for t in terms[1:]:
                total = add(total, t)
            return total
        if name == "IFERROR":
            if len(a) != 2:
                raise Unsupported("IFERROR arity")
            x = a[0][1] if a[0][0] == "val" else self._as_val(a[0])
            fb = a[1][1] if a[1][0] == "val" else self._as_val(a[1])
            return ["iferror", x, fb]
        raise Unsupported(f"function {name}")

    def _as_val(self, arg):
        kind, v = arg
        if kind == "ref":
            return self.cell(*expand_range(v)[0])
        raise Unsupported("string where a number was expected")


# ============================================================================================ sheet compile
def _canon(p):
    return json.dumps(p, sort_keys=True)


def _fact_tables(source_map):
    return set((source_map or {}).get("facts", {}))


def _is_fact(table, source_map, results):
    if table in _fact_tables(source_map):
        return True
    return table.endswith("_F_Trans") or any(r.get("dim") == table and r.get("aggregation") == "Sum" for r in results)


class SheetCompiler:
    def __init__(self, ir, sheet, source_map=None):
        self.ir, self.sh, self.sm = ir, sheet, source_map or {}
        self.report_groups, self.col_groups, self.row_groups, self.cell_groups = {}, {}, {}, {}
        self.cell_formula, self.row_items, self.results = {}, {}, {}
        self.warnings_init, self.item_errors = [], {}
        for it in sheet["items"]:
            g = {}
            t = it["type"]
            try:
                for el in it["elements"]:
                    for k, v in element_groups(el, ir.get("parameters")).items():
                        g[k] = {"k": "and", "xs": [g[k], v]} if k in g else v
            except Unsupported as e:
                # the cells this item filters become gaps (context() raises); the rest of the sheet still compiles
                key = {"Report": ("Report",), "Column": ("Column", it["col"]), "Row": ("Row", it["row"]),
                       "Cell": ("Cell", it["row"], it["col"])}.get(t, (t, it["row"], it["col"]))
                where = {"Report": "", "Column": f" column {solver_def.num_to_col(it['col'] or 1)}",
                         "Row": f" row {it['row']}"}.get(t, f" {solver_def.num_to_col(it['col'] or 1)}{it['row']}")
                self.item_errors[key] = f"{t} item{where}: {e}"
                g = {}
            if t == "Report":
                self.report_groups.update(g)
            elif t == "Column":
                self.col_groups[it["col"]] = g
                if it.get("expand"):
                    self.warnings_init.append(f"{sheet['name']}: column {solver_def.num_to_col(it['col'] or 1)} expands "
                                              "(one column per member); build it as a pivot column, not translated")
            elif t == "Row":
                self.row_groups[it["row"]] = g
                self.row_items[it["row"]] = it
            elif t == "Cell":
                self.cell_groups[(it["row"], it["col"])] = g
                if it.get("formula"):
                    self.cell_formula[(it["row"], it["col"])] = it["formula"]
                self.results[(it["row"], it["col"])] = [r for el in it["elements"] for r in el["results"]]
        self.bases, self.by_key, self.memo, self.stack, self.warnings = {}, {}, {}, set(), list(self.warnings_init)
        self.text_cells = 0

    # ---------------------------------------------------------------- context
    def context(self, r, c):
        for key in (("Report",), ("Column", c), ("Row", r), ("Cell", r, c)):
            if key in self.item_errors:
                raise Unsupported(self.item_errors[key])
        g = dict(self.report_groups)
        g.update(self.col_groups.get(c, {}))
        g.update(self.row_groups.get(r, {}))
        g.update(self.cell_groups.get((r, c), {}))
        return g

    def base(self, table, attr, r, c):
        groups = self.context(r, c)
        key = _canon([table, attr, groups])
        if key not in self.by_key:
            bid = f"B{len(self.bases) + 1:03d}"
            self.bases[bid] = {"fact": table, "value": attr, "groups": groups}
            self.by_key[key] = bid
        return self.by_key[key]

    # ---------------------------------------------------------------- cells
    def formula_at(self, col, row):
        c = solver_def.col_to_num(col)
        if (row, c) in self.cell_formula:
            return self.cell_formula[(row, c)]
        cell = self.sh["cells"].get(f"{col}{row}")
        if cell is None:
            return None
        if cell.get("f"):
            return cell["f"]
        v = cell.get("v")
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return str(v)
        return None

    def cell_value(self, col, row):
        key = (col, row)
        if key in self.memo:
            return self.memo[key]
        if key in self.stack:
            raise Unsupported(f"circular reference at {col}{row}")
        f = self.formula_at(col, row)
        if f is None:
            return K(0)
        if is_text_formula(f, _fact_tables(self.sm)):
            raise Unsupported(f"reads {col}{row}, a text cell (label or formatted text), as a number")
        self.stack.add(key)
        try:
            c = solver_def.col_to_num(col)

            def osr_get(table, attr):
                if not _is_fact(table, self.sm, self.results.get((row, c), [])):
                    raise Unsupported(f"OSRGet of attribute {table}.{attr} used as a number")
                return ["base", self.base(table, attr, row, c)]

            val = FormulaParser(tokenize(f), osr_get, self.cell_value).parse()
        finally:
            self.stack.discard(key)
        self.memo[key] = val
        return val

    # ---------------------------------------------------------------- lines
    def _refs(self, f):
        return [(solver_def.col_to_num(c), int(r)) for c, r in re.findall(r"\$?([A-Z]{1,3})\$?(\d+)", f or "")]

    def layout(self):
        """(value columns, line rows). Solver columns hold Column/Cell items; a derived column holds plain-Excel
        formulas on line rows that reference Solver cells (variances, ratios); a line row has a Solver cell or a
        formula in a Solver column (subtotals)."""
        expanded = {r for r, it in self.row_items.items() if it.get("expand")}
        facts = _fact_tables(self.sm)
        value_cells = {(r, c) for (r, c), f in self.cell_formula.items()
                       if r not in expanded and not is_text_formula(f, facts)}
        solver_cols = set(c for c in self.col_groups if c) | {c for (_, c) in value_cells}
        rows = {r for (r, _) in value_cells}
        for ref, cell in self.sh["cells"].items():
            col, row = solver_def._col_letters(ref)
            f = cell.get("f") or ""
            if col and f and solver_def.col_to_num(col) in solver_cols and row not in expanded \
                    and not re.search(r"OSRGet", f, re.I) and not is_text_formula(f, facts):
                rows.add(row)
        derived = set()
        for ref, cell in self.sh["cells"].items():
            col, row = solver_def._col_letters(ref)
            c = solver_def.col_to_num(col) if col else None
            f = cell.get("f") or ""
            if c and c not in solver_cols and row in rows and f and not re.search(r"OSR", f, re.I):
                if any(rc in solver_cols and rr in rows for rc, rr in self._refs(f[1:])):
                    derived.add(c)
        return sorted(solver_cols | derived), sorted(rows)

    def label_cell(self, row, first_value_col):
        """(label, column letter) of the first text cell left of the value columns; ("Row N", None) if none."""
        for c in range(1, first_value_col):
            L = solver_def.num_to_col(c)
            cell = self.sh["cells"].get(f"{L}{row}")
            if cell and isinstance(cell.get("v"), str) and cell["v"].strip() and not (cell.get("f") or "").upper().count("OSR"):
                return cell["v"].strip(), L
        return f"Row {row}", None

    def label(self, row, first_value_col):
        return self.label_cell(row, first_value_col)[0]

    def header(self, col, first_row):
        for r in range(first_row - 1, 0, -1):
            cell = self.sh["cells"].get(f"{solver_def.num_to_col(col)}{r}")
            if cell and isinstance(cell.get("v"), str) and cell["v"].strip():
                return cell["v"].strip()
        return solver_def.num_to_col(col)

    def compile(self):
        cols, rows = self.layout()
        expanded = {r for r, it in self.row_items.items() if it.get("expand")}
        lines, details = [], []
        first_value_col = min(cols) if cols else 1
        first_row = min(rows) if rows else 1
        facts = _fact_tables(self.sm)
        for r in sorted(r for r in expanded if any(rr == r for rr, _ in self.cell_formula)):
            try:
                details.append(self.detail(r, first_value_col))
            except Unsupported as e:
                details.append({"row": r, "label": self.label(r, first_value_col), "gap": str(e), "group_by": [],
                                "cells": {}, "bases": {}, "where": {}, "labels": {}})
                self.warnings.append(f"{self.sh['name']}: expanded row {r}: {e}")
        for r in rows:
            cells = {}
            for c in cols:
                L = solver_def.num_to_col(c)
                f = self.formula_at(L, r)
                if f is None:
                    continue
                if is_text_formula(f, facts):            # the cell itself is a label: not a value, not a gap
                    self.text_cells += 1
                    continue
                try:
                    cells[L] = {"expr": self.cell_value(L, r)}
                except Unsupported as e:
                    cells[L] = {"gap": str(e)}
                    self.warnings.append(f"{self.sh['name']}!{L}{r}: {e}")
            if not cells:
                continue
            fmt = next((self.sh["cells"].get(f"{solver_def.num_to_col(c)}{r}", {}).get("fmt") for c in cols
                        if self.sh["cells"].get(f"{solver_def.num_to_col(c)}{r}", {}).get("fmt")), None)
            lab, lab_col = self.label_cell(r, first_value_col)
            lines.append({"row": r, "label": lab, "label_col": lab_col, "format": fmt, "cells": cells})
        columns = [{"col": c, "letter": solver_def.num_to_col(c), "label": self.header(c, first_row),
                    "kind": "solver" if c in self.col_groups else "derived"} for c in cols]
        return {"name": self.sh["name"], "columns": columns, "lines": lines, "details": details,
                "bases": self.bases, "warnings": self.warnings, "text_cells": self.text_cells}

    def detail(self, r, first_value_col=2):
        """An expanded Row item: one output row per member. Grouping = the Row item's Group result attributes (or
        the attributes its cells read); each value cell is an expression over per-member bases."""
        it = self.row_items[r]
        groups_by = [(x["dim"], x["name"]) for el in it["elements"] for x in el["results"] if x.get("aggregation") == "Group"]
        out = {"row": r, "label": self.label(r, first_value_col), "group_by": [], "cells": {}, "bases": {},
               "where": self.context(r, None)}
        bases, by_key = out["bases"], {}
        for (rr, c), f in sorted(self.cell_formula.items()):
            if rr != r:
                continue
            L = solver_def.num_to_col(c)
            g = OSR_PREFIX.sub("", f)
            m = re.match(r'^\s*=\s*OSRGet\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)\s*$', g, re.I)
            if not m and is_text_formula(g, _fact_tables(self.sm)):
                m = re.search(r'OSRGet\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)', g, re.I)
                if m:
                    self.warnings.append(f"{self.sh['name']}!{L}{r}: text transform around {m.group(1)}.{m.group(2)} "
                                         "shown untransformed (re-apply it as a Sigma formula)")
            if m and not _is_fact(m.group(1), self.sm, self.results.get((r, c), [])):
                out["cells"][L] = {"attribute": [m.group(1), m.group(2)]}
                if (m.group(1), m.group(2)) not in groups_by:
                    groups_by.append((m.group(1), m.group(2)))
                continue

            def osr_get(table, attr, c=c):
                if not _is_fact(table, self.sm, self.results.get((r, c), [])):
                    raise Unsupported(f"attribute {table}.{attr} inside arithmetic")
                key = _canon([table, attr, self.context(r, c)])
                if key not in by_key:
                    bid = f"D{len(bases) + 1:03d}"
                    bases[bid] = {"fact": table, "value": attr, "groups": self.context(r, c)}
                    by_key[key] = bid
                return ["base", by_key[key]]

            def no_cells(col, row):
                raise Unsupported(f"expanded row reads cell {col}{row} (a block subtotal); build it as a Sigma subtotal")
            try:
                out["cells"][L] = {"expr": FormulaParser(tokenize(f), osr_get, no_cells).parse()}
            except Unsupported as e:
                out["cells"][L] = {"gap": str(e)}
                self.warnings.append(f"{self.sh['name']}!{L}{r}: {e}")
        out["group_by"] = [list(x) for x in groups_by]
        head_row = min([rr for (rr, _) in self.cell_formula if rr not in {x for x, it in self.row_items.items() if it.get("expand")}]
                       or [r])
        labels = {}
        for L, cell in out["cells"].items():
            h = self.header(solver_def.col_to_num(L), head_row)
            labels[L] = h if h != L else (cell["attribute"][1] if "attribute" in cell else L)
        out["labels"] = labels
        return out


def compile_report(ir, source_map=None):
    """-> plan. ``failed_sheets`` lists sheets that could not be compiled at all (convert exits 2 on any);
    gaps inside a sheet are cells or expanded rows carrying ``gap`` and are listed in ``warnings``."""
    sheets, warnings, failed = [], [], []
    for sh in ir["sheets"]:
        try:
            s = SheetCompiler(ir, sh, source_map).compile()
        except Unsupported as e:
            warnings.append(f"{sh['name']}: sheet not compiled: {e}")
            failed.append({"name": sh["name"], "error": str(e),
                           "formula_cells": sum(1 for it in sh["items"] if it.get("formula"))
                           + sum(1 for c in sh.get("cells", {}).values() if c.get("f"))})
            continue
        warnings += s["warnings"]
        sheets.append(s)
    fy = int((source_map or {}).get("fiscal_year_start_month", 1))
    return {"title": ir.get("title"), "parameters": ir["parameters"], "fiscal_year_start_month": fy,
            "sheets": sheets, "failed_sheets": failed, "warnings": warnings}


def gap_count(plan):
    """Untranslated cells and expanded rows in a plan, plus every formula cell of a sheet that failed outright."""
    n = sum(1 for s in plan["sheets"] for ln in s["lines"] for c in ln["cells"].values() if "gap" in c)
    n += sum(1 for s in plan["sheets"] for d in s["details"] for c in d["cells"].values() if "gap" in c)
    n += sum(1 for s in plan["sheets"] for d in s["details"] if "gap" in d)
    return n + sum(f.get("formula_cells", 1) or 1 for f in plan.get("failed_sheets", []))


# ============================================================================================ parameters
def param_value(params, name, overrides=None, _seen=None):
    overrides = overrides or {}
    if name in overrides:
        v = overrides[name]
    else:
        p = next((x for x in params if (x["name"] or "").lower() == name.lower()), None)
        if p is None:
            raise Unsupported(f"parameter {name!r} is referenced but not defined")
        v = p.get("default")
    m = PARAM_REF.match(v or "")
    if m:
        _seen = (_seen or set()) | {name}
        if m.group(1) in _seen:
            raise Unsupported(f"parameter default cycle at {name!r}")
        return param_value(params, m.group(1), overrides, _seen)
    return v


def control_id(name):
    s = re.sub(r"[^A-Za-z0-9]+", " ", name or "").title().replace(" ", "")
    return s if s and s[0].isalpha() else "P" + s


# ============================================================================================ local evaluator
def _match_in(val, parts, params, overrides, numeric=False):
    v = (str(val).strip().upper() if val is not None else "")
    for p in parts:
        if "param" in p:
            pv = param_value(params, p["param"], overrides) or ""
            if pv.strip() == "*":
                return True
            if v in [x.strip().upper() for x in pv.split(",")]:
                return True
        elif "eq" in p:
            e = p["eq"].upper()
            if e == "*" or v == e or (e.endswith("*") and e.count("*") == 1 and v.startswith(e[:-1])):
                return True
        else:
            lo, hi = p["lo"].upper(), p["hi"].upper()
            if lo <= v <= hi:
                return True
    return False


def eval_pred(p, row, params, overrides, fy_start=1):
    k = p["k"]
    if k == "and":
        return all(eval_pred(x, row, params, overrides, fy_start) for x in p["xs"])
    if k == "or":
        return any(eval_pred(x, row, params, overrides, fy_start) for x in p["xs"])
    if k == "not":
        return not eval_pred(p["x"], row, params, overrides, fy_start)
    val = row.get(f"{p['dim']}.{p['field']}")
    if k == "in":
        return _match_in(val, p["parts"], params, overrides)
    if k == "contains":
        return p["text"].upper() in str(val or "").upper()
    if k == "period_lit":
        return val is not None and p["lo"] <= int(Fraction(str(val))) <= p["hi"]
    if k == "period_fn":
        if val in (None, ""):
            return False
        lo, hi = period_window(p["fn"], fy_start)(yyyymm_to_idx(param_value(params, p["param"], overrides)))
        return lo <= yyyymm_to_idx(val) <= hi
    raise Unsupported(f"predicate {k}")


def _sum_bases(bases, rows, params, overrides, fy_start):
    bv = {}
    for bid, b in bases.items():
        total = Fraction(0)
        for row in rows.get(b["fact"], []):
            if all(eval_pred(g, row, params, overrides, fy_start) for g in b["groups"].values()):
                total += Fraction(str(row.get(f"{b['fact']}.{b['value']}") or 0))
        bv[bid] = total
    return bv


def _num(x):
    return None if x is None else float(x)


def evaluate(plan, facts, overrides=None, fy_start=None):
    """facts: {fact table: [rows keyed "<dim>.<field>" and "<fact>.<value>"]} (a Solver-shaped extract).
    -> {sheet: {"lines": {row: {col: value}}, "details": {row: [{col: value}]}}}. The fiscal year start comes from
    the plan (the source map's ``fiscal_year_start_month``, the same value the SQL uses) unless overridden."""
    params = plan["parameters"]
    fy_start = int(fy_start or plan.get("fiscal_year_start_month") or 1)
    out = {}
    for s in plan["sheets"]:
        bv = _sum_bases(s["bases"], facts, params, overrides, fy_start)
        lines = {ln["row"]: {col: (None if "gap" in c else _num(eval_expr(c["expr"], bv))) for col, c in ln["cells"].items()}
                 for ln in s["lines"]}
        details = {}
        for d in s["details"]:
            if "gap" in d:
                continue
            keyed = {}
            for fact, rows in facts.items():
                for row in rows:
                    if not all(eval_pred(g, row, params, overrides, fy_start) for g in d["where"].values()):
                        continue
                    key = tuple(str(row.get(f"{a}.{b}", "")) for a, b in d["group_by"])
                    keyed.setdefault(key, {}).setdefault(fact, []).append(row)
            outrows = []
            for key, sub in sorted(keyed.items()):
                dbv = _sum_bases(d["bases"], sub, params, overrides, fy_start)
                vals = {}
                for col, c in d["cells"].items():
                    if "attribute" in c:
                        vals[col] = key[d["group_by"].index(c["attribute"])]
                    elif "expr" in c:
                        vals[col] = _num(eval_expr(c["expr"], dbv))
                outrows.append(vals)
            details[d["row"]] = outrows
        out[s["name"]] = {"lines": lines, "details": details}
    return out


def read_facts_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))
