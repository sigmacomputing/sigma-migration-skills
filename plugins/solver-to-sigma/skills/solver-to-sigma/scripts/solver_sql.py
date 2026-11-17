#!/usr/bin/env python3
"""Render a compiled Solver plan (solver_compile.compile_report) as Snowflake SQL for Sigma data-model elements.

The source map (refs/source-map.md) says where each Solver fact and attribute lives in the warehouse:

    {"connectionId": "<connection-id>", "fiscal_year_start_month": 1,
     "facts": {"GL_F_Trans": {"from": "DB.SCH.GL f LEFT JOIN DB.SCH.ACCOUNTS a ON a.CODE = f.ACCOUNT",
                              "values": {"Value1": "f.AMOUNT"},
                              "period": {"expr": "f.PERIOD_ID", "format": "yyyymm"}}},
     "attributes": {"d_Account.Code": "f.ACCOUNT", "d_Scenario.Code": "f.SCENARIO"},
     "fact_attributes": {"GL_F_Trans": {"d_Account.UDF001": "a.ROLLUP_1"}}}

Every predicate is evaluated inside the SELECT that owns the source map's FROM clause, so its table aliases resolve.
Solver parameters become data-model controls referenced as ``{{ControlId}}``; each reference is wrapped in
COALESCE(<control>, <report default>) because a bound workbook control with no value sends NULL, not the
data-model default. A parameter whose default is another parameter (``{@A}``) becomes COALESCE({{B}}, <A's reference>)
so it keeps following A in Sigma, as it does in Solver. Text comparisons are case-insensitive, as in Solver, and a
missing attribute compares as '' (NULL never silently drops a row under NOT).
"""
import re
from fractions import Fraction

import solver_compile as C

NUM_TYPES = ("System.Decimal", "System.Int32", "System.Int64", "System.Double")
SPLIT_RX = r"'\\s*,\\s*'"   # SQL string literal for the regex \s*,\s* (backslashes escaped for Snowflake)


class MappingError(Exception):
    pass


def q(s):
    return "'" + str(s).replace("'", "''") + "'"


def is_numeric_param(p):
    return bool(p) and (p.get("is_period") or p.get("data_type") in NUM_TYPES)


def _walk_params(p, names):
    if not isinstance(p, dict):
        return
    k = p.get("k")
    if k in ("and", "or"):
        for x in p["xs"]:
            _walk_params(x, names)
    elif k == "not":
        _walk_params(p["x"], names)
    elif k == "period_fn":
        names.add(p["param"].lower())
    elif k == "in":
        for part in p["parts"]:
            if "param" in part:
                names.add(part["param"].lower())


def follows(plan, name):
    """The parameter that ``name``'s default refers to ({@Other}), or None."""
    p = next((x for x in plan["parameters"] if (x["name"] or "").lower() == name.lower()), None)
    m = C.PARAM_REF.match((p or {}).get("default") or "")
    return m.group(1).strip() if m else None


def params_used(plan):
    """Parameter names referenced by any predicate (and the parameters their defaults follow), in definition order."""
    names = set()
    for s in plan["sheets"]:
        groups = [g for b in s["bases"].values() for g in b["groups"].values()]
        for d in s["details"]:
            groups += list(d["where"].values()) + [g for b in d["bases"].values() for g in b["groups"].values()]
        for g in groups:
            _walk_params(g, names)
    for n in list(names):
        seen = {n}
        nxt = follows(plan, n)
        while nxt and nxt.lower() not in seen:
            names.add(nxt.lower())
            seen.add(nxt.lower())
            nxt = follows(plan, nxt)
    order = [p["name"] for p in plan["parameters"] if (p["name"] or "").lower() in names]
    missing = sorted(names - {o.lower() for o in order})
    if missing:
        raise MappingError(f"parameters referenced but not defined in the report: {missing}")
    return order


def controls(plan):
    """[{"param", "controlId", "numeric", "default"}] for the parameters the SQL reads."""
    out, seen = [], set()
    for name in params_used(plan):
        p = next(x for x in plan["parameters"] if x["name"] == name)
        base = C.control_id(name)
        cid, n = base, 2
        while cid in seen:
            cid, n = f"{base}{n}", n + 1
        seen.add(cid)
        chained = follows(plan, name)
        default = C.param_value(plan["parameters"], name)
        numeric = is_numeric_param(p)
        if numeric and default is not None and "," in str(default):
            if p.get("is_period"):
                raise MappingError(f"period parameter {name!r} defaults to a list ({default!r}); "
                                   "a period parameter takes one period")
            numeric = False                       # a list of numeric codes is matched as text, like any list
        if chained:
            default = None                        # no saved value of its own: it follows the other parameter
        elif numeric:
            try:
                default = int(Fraction(str(default)))
            except (ValueError, TypeError):
                default = None
        out.append({"param": name, "controlId": cid, "numeric": numeric, "default": default, "follows": chained})
    return out


def column_names(s):
    """{letter: SQL alias}, {letter: display name}. Display names are made unique with the column letter."""
    labels = [c["label"] for c in s["columns"]]
    alias, display = {}, {}
    for c in s["columns"]:
        alias[c["letter"]] = f"C_{c['letter']}"
        unique = labels.count(c["label"]) == 1 and c["label"] != c["letter"]
        display[c["letter"]] = c["label"] if unique else f"{c['label']} ({c['letter']})"
    return alias, display


class Renderer:
    def __init__(self, plan, source_map):
        self.plan, self.sm = plan, source_map or {}
        self.ctl = {c["param"].lower(): c for c in controls(plan)}
        self.fy = int(self.sm.get("fiscal_year_start_month", 1))

    # -------------------------------------------------------------- mapping
    def fact(self, name):
        f = (self.sm.get("facts") or {}).get(name)
        if not f or not f.get("from"):
            raise MappingError(f"no warehouse source for Solver fact {name}; add it to the source map's facts")
        return f

    def attr(self, fact, dim, field):
        key = f"{dim}.{field}"
        per = (self.sm.get("fact_attributes") or {}).get(fact, {})
        expr = per.get(key, (self.sm.get("attributes") or {}).get(key))
        if not expr:
            raise MappingError(f"no warehouse column for {key} (fact {fact}); add it to the source map's attributes")
        return expr

    def value_expr(self, fact, value):
        ve = (self.fact(fact).get("values") or {}).get(value)
        if not ve:
            raise MappingError(f"fact {fact}: no warehouse column for value {value}")
        return ve

    def period_expr(self, fact):
        per = self.fact(fact).get("period") or {}
        pe = per.get("expr")
        if not pe:
            raise MappingError(f"fact {fact}: no period expression")
        return self.pidx(pe) if per.get("format", "yyyymm") == "yyyymm" else f"(YEAR({pe}) * 12 + MONTH({pe}) - 1)"

    def ctl_ref(self, param):
        c = self.ctl[param.lower()]
        if c.get("follows") and c["follows"].lower() in self.ctl:
            return f"COALESCE({{{{{c['controlId']}}}}}, {self.ctl_ref(c['follows'])})"
        d = c["default"]
        dflt = ("NULL" if d is None else str(d)) if c["numeric"] else q("" if d is None else d)
        return f"COALESCE({{{{{c['controlId']}}}}}, {dflt})"

    # -------------------------------------------------------------- predicates
    @staticmethod
    def norm(e):
        return f"UPPER(TRIM(COALESCE(TO_VARCHAR({e}), '')))"

    @staticmethod
    def pidx(e):
        return f"(FLOOR(({e}) / 100) * 12 + MOD(({e}), 100) - 1)"

    def window(self, fn, i):
        """SQL twin of solver_compile.period_window (month indexes, fiscal year start month self.fy)."""
        s = self.fy
        fys = f"({i} - MOD(MOD({i}, 12) + 1 - {s} + 12, 12))"
        qs = f"({i} - MOD(MOD({i}, 12) + 1 - {s} + 12, 3))"
        f = fn.upper()
        table = {"TPTY": (i, i), "TPLY": (f"({i} - 12)", f"({i} - 12)"), "QTD": (qs, i),
                 "QTDLY": (f"({qs} - 12)", f"({i} - 12)"), "YTD": (fys, i), "LYTD": (f"({fys} - 12)", f"({i} - 12)")}
        if f in table:
            return table[f]
        m = re.match(r"^R[A-Z]*?(\d+)M(LY)?$", f)
        if m:
            n, ly = int(m.group(1)), 12 if m.group(2) else 0
            return f"({i} - {n - 1 + ly})", f"({i} - {ly})"
        raise C.Unsupported(f"PeriodCalc function {fn!r}")

    def pred(self, p, fact):
        k = p["k"]
        if k in ("and", "or"):
            return "(" + f" {k.upper()} ".join(self.pred(x, fact) for x in p["xs"]) + ")"
        if k == "not":
            return f"(NOT {self.pred(p['x'], fact)})"
        if k == "period_fn":
            lo, hi = self.window(p["fn"], self.pidx(self.ctl_ref(p["param"])))
            return f"({self.period_expr(fact)} BETWEEN {lo} AND {hi})"
        if k == "period_lit":
            return f"({self.period_expr(fact)} BETWEEN {C.yyyymm_to_idx(p['lo'])} AND {C.yyyymm_to_idx(p['hi'])})"
        col = self.norm(self.attr(fact, p["dim"], p["field"]))
        if k == "contains":
            return f"CONTAINS({col}, {q(p['text'].upper())})"
        ors = []
        eqs = [x["eq"].upper() for x in p["parts"] if "eq" in x and "*" not in x["eq"]]
        if eqs:
            ors.append(f"{col} IN ({', '.join(q(e) for e in eqs)})")
        for x in p["parts"]:
            if "eq" in x and "*" in x["eq"]:
                # only a trailing * reaches here (solver_compile.leaf); STARTSWITH needs no LIKE escaping of _ or %
                ors.append("TRUE" if x["eq"].strip() == "*" else f"STARTSWITH({col}, {q(x['eq'].upper()[:-1])})")
            elif "lo" in x:
                ors.append(f"{col} BETWEEN {q(x['lo'].upper())} AND {q(x['hi'].upper())}")
            elif "param" in x:
                ref = self.ctl_ref(x["param"])
                ors.append(f"(TRIM({ref}) = '*' OR ARRAY_CONTAINS({col}::VARIANT, "
                           f"SPLIT(UPPER(REGEXP_REPLACE(TRIM({ref}), {SPLIT_RX}, ',')), ',')))")
        if not ors:
            return "FALSE"
        return ors[0] if len(ors) == 1 else "(" + " OR ".join(ors) + ")"

    def where(self, groups, fact):
        return " AND ".join(self.pred(g, fact) for _, g in sorted(groups.items())) or "TRUE"

    def sums(self, bases, fact):
        return [f"SUM(CASE WHEN {self.where(b['groups'], fact)} THEN {self.value_expr(fact, b['value'])} END) AS {bid}"
                for bid, b in bases.items()]

    # -------------------------------------------------------------- elements
    def sheet_sql(self, s, colnames):
        """One row per report line, one column per report column (the report's own shape)."""
        facts = {}
        for bid, b in s["bases"].items():
            facts.setdefault(b["fact"], {})[bid] = b
        ctes, joins = [], []
        for n, (fact, bases) in enumerate(sorted(facts.items()), 1):
            ctes.append(f"A{n} AS (SELECT {', '.join(self.sums(bases, fact))} FROM {self.fact(fact)['from']})")
            joins.append(f"A{n}")
        base_from = " CROSS JOIN ".join(joins) if joins else "(SELECT 1 AS ONE)"
        selects = []
        for ln in s["lines"]:
            cols = []
            for c in s["columns"]:
                cell = ln["cells"].get(c["letter"])
                v = C.expr_sql(cell["expr"], lambda b: b) if cell and "expr" in cell else "NULL"
                cols.append(f"{v} AS {colnames[c['letter']]}")
            selects.append(f"SELECT {ln['row']} AS ROW_NUM, {q(ln['label'])} AS LINE, " + ", ".join(cols) + f" FROM {base_from}")
        body = "\nUNION ALL\n".join(selects) if selects else "SELECT NULL AS ROW_NUM, NULL AS LINE WHERE FALSE"
        return ("WITH " + ",\n".join(ctes) + "\n" if ctes else "") + body

    def detail_sql(self, d):
        """An expanded row: one row per member, grouped by the attributes its cells read."""
        facts = sorted({b["fact"] for b in d["bases"].values()}) or sorted(self.sm.get("facts") or {})[:1]
        if len(facts) != 1:
            raise C.Unsupported("expanded row reads more than one fact table")
        fact = facts[0]
        gb = [(f"G{n}", self.attr(fact, dim, field), dim, field) for n, (dim, field) in enumerate(d["group_by"], 1)]
        cols = [f"{e} AS {a}" for a, e, _, _ in gb] + self.sums(d["bases"], fact)
        inner = (f"SELECT {', '.join(cols) or '1 AS ONE'} FROM {self.fact(fact)['from']} WHERE {self.where(d['where'], fact)}"
                 + (f" GROUP BY {', '.join(e for _, e, _, _ in gb)}" if gb else ""))
        outs = []
        for col, cell in sorted(d["cells"].items()):
            if "attribute" in cell:
                a = next(a for a, _, dim, field in gb if [dim, field] == cell["attribute"])
                outs.append(f"{a} AS C_{col}")
            elif "expr" in cell:
                outs.append(f"{C.expr_sql(cell['expr'], lambda b: b)} AS C_{col}")
        return f"SELECT {', '.join(outs) or 'NULL AS EMPTY'} FROM ({inner})"
