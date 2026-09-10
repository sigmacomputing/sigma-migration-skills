#!/usr/bin/env python3
"""
JAQL -> Sigma formula translation.

A JAQL panel item is `{ "jaql": {...}, "format": {...} }`. The jaql is one of:
  - dimension:        { "dim": "[Table.Column]", "level": "months"? , "sort"? , "filter"? }
  - aggregated meas.: { "dim": "[Table.Column]", "agg": "sum" }
  - formula measure:  { "formula": "SUM([r])/SUM([c])", "context": {"[r]":{dim..}, "[c]":{dim..}} }

translate_agg()   -> a Sigma aggregate formula string e.g. "Sum([Revenue])"
translate_dim()   -> a Sigma dimension column reference / date-trunc expression
classify()        -> ('measure'|'dimension', sigma_formula) for any jaql item

Unsupported constructs raise Unsupported so the converter FLAGS them instead of
emitting wrong logic. Column display names are taken verbatim from the JAQL dim
(the last [Table.Column] segment), which match the Sigma DM column names.
"""
import re, os, sys

class Unsupported(Exception):
    """A fail-closed JAQL translation with a machine-stable warning id."""
    def __init__(self, message, warning_id):
        super().__init__(message)
        self.warning_id = warning_id

# ── documentation-grounded aggregation catalog (SINGLE SOURCE OF TRUTH) ──────
# The JAQL `agg` -> Sigma aggregate map is LOADED from
# refs/catalogs/aggregation.json (cited rows, complete coverage). translate_agg()
# resolves against it and raises Unsupported (which convert.py turns into a loud
# FLAG) on any agg not listed — never a silent default. The generated coverage
# matrix lives in refs/sisense-coverage.md. Loader: shared/lib/coverage_catalog.py
# (synced to scripts/lib/).
# The flat `agg` and formula-function maps live in catalogs. The COMPOSITIONAL
# parser (context recursion, token replacement, callable scanning) and date-level
# DateTrunc map (LEVEL) stay in code because they are expression logic, not a
# flat source-token table.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import coverage_catalog as _cc  # noqa: E402
_CAT_DIR = _cc.default_catalog_dir(__file__)
_AGG_CAT = _cc.load(_CAT_DIR, "aggregation")
AGG = {r["source"]: r["sigma"] for r in _AGG_CAT.rows if r.get("sigma")}
FUNC_CAT = _cc.load(_CAT_DIR, "jaql-function")
FUNC_ROWS = {r["source"].upper(): r for r in FUNC_CAT.rows}
SAFE_FUNC = {k: r["sigma"] for k, r in FUNC_ROWS.items()
             if r.get("behavior") == "safe" and r.get("sigma")}
FLAG_FUNC = {k: r for k, r in FUNC_ROWS.items()
             if r.get("behavior") == "flag"}
UNKNOWN_FUNC = FUNC_ROWS["<UNKNOWN-FUNCTION>"]

# JAQL date level -> Sigma DateTrunc unit (None = no truncation)
LEVEL = {
    "years": "year", "quarters": "quarter", "months": "month", "weeks": "week",
    "days": "day", "minutes": "minute", "hours": "hour", "seconds": "second",
}

def col_name(dim):
    """'[Commerce.Revenue]' -> 'Revenue' (the column display name in the DM)."""
    m = re.match(r"\[([^.\]]+)\.([^\]]+)\]", dim.strip())
    if not m:
        raise Unsupported(f"unparseable JAQL dim: {dim!r}",
                          "SISENSE-JAQL-DIM-UNPARSEABLE")
    return m.group(2)

def table_of(dim):
    m = re.match(r"\[([^.\]]+)\.([^\]]+)\]", dim.strip())
    return m.group(1) if m else None

def translate_agg(jaql):
    agg = jaql["agg"].lower()
    if agg not in AGG:
        raise Unsupported(f"unsupported agg: {agg}",
                          "SISENSE-JAQL-AGG-UNSUPPORTED")
    return f"{AGG[agg]}([{col_name(jaql['dim'])}])"

def translate_dim(jaql):
    name = col_name(jaql["dim"])
    lvl = jaql.get("level")
    if lvl:
        if lvl not in LEVEL:
            raise Unsupported(f"unsupported date level: {lvl}",
                              "SISENSE-JAQL-LEVEL-UNSUPPORTED")
        return f'DateTrunc("{LEVEL[lvl]}", [{name}])'
    return f"[{name}]"

def translate_formula(jaql):
    """Resolve a JAQL formula's [tokens] from its context into a Sigma formula."""
    formula = jaql["formula"]
    ctx = jaql.get("context", {})
    # Resolve every callable through the catalog. Recognized flag rows and
    # uncataloged callables fail closed with the row's stable warning id.
    for fn in re.findall(r"([A-Za-z_]+)\s*\(", formula):
        row = FUNC_ROWS.get(fn.upper(), UNKNOWN_FUNC)
        if row.get("behavior") != "safe":
            detail = ("has no clean context-free Sigma equivalent"
                      if row.get("behavior") == "flag"
                      else "is not in the grounded JAQL function catalog")
            raise Unsupported(f"JAQL function {fn}() {detail}",
                              row["warning_id"])
    out = formula
    for token, sub in ctx.items():
        # a context member carrying a filter (filtered/scoped measure) has no
        # clean 1:1 Sigma form — flag rather than silently drop the filter
        if isinstance(sub, dict) and sub.get("filter"):
            raise Unsupported(
                "filtered/scoped JAQL measure — needs manual SumIf/CountIf",
                "SISENSE-JAQL-FILTERED-MEASURE")
        if "formula" in sub:
            rep = translate_formula(sub)
        elif "agg" in sub:
            rep = translate_agg(sub)
        elif "dim" in sub:
            rep = f"[{col_name(sub['dim'])}]"
        else:
            raise Unsupported(f"unresolvable JAQL context member: {sub!r}",
                              "SISENSE-JAQL-CONTEXT-UNRESOLVABLE")
        out = out.replace(token, rep)
    # map JAQL scalar/agg function names to Sigma (case-insensitive)
    def _fn(m):
        fn = m.group(1)
        return SAFE_FUNC[fn.upper()] + "("
    out = re.sub(r"([A-Za-z_]+)\s*\(", _fn, out)
    return out

def classify(jaql):
    """Return ('measure'|'dimension', sigma_formula). Raises Unsupported to flag."""
    if "formula" in jaql:
        return "measure", translate_formula(jaql)
    if jaql.get("agg"):
        return "measure", translate_agg(jaql)
    return "dimension", translate_dim(jaql)

def raw_dims(jaql):
    """Return a string containing every raw [Table.Column] token this JAQL item
    references — from its dim, or from each sub-item in a formula's context.
    Used to register the underlying columns into the workbook Master element."""
    toks = []
    if "dim" in jaql:
        toks.append(jaql["dim"])
    for sub in (jaql.get("context") or {}).values():
        if isinstance(sub, dict):
            toks.append(raw_dims(sub))
    return " ".join(toks)

def top_n(jaql):
    """Extract a top-N spec from a JAQL dim filter, or None."""
    f = jaql.get("filter") or {}
    top = f.get("top")
    if top:
        return {"count": top.get("count"), "by_col": col_name(top["by"]["dim"]),
                "by_agg": AGG.get(top["by"].get("agg", "sum").lower(), "Sum")}
    return None
