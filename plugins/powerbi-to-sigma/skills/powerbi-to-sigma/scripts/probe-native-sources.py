#!/usr/bin/env python3
"""probe-native-sources.py - the pre-POST gate for Custom SQL (NativeQuery) elements.

A data model with Custom SQL sources used to be discovered one POST -> 400 at a
time: a bound column that the SQL does not return, or a column whose Power BI
type is boolean while the warehouse hands back VARCHAR 'True'/'False'. This gate
finds all of those in ONE warehouse round trip per distinct statement, before
anything is written to Sigma:

  1. probes every Custom SQL element once (columns + warehouse types, through
     sigma-sql-probe.py; identical statements are probed once),
  2. verifies every [Custom SQL/X] reference in the element's columns exists in
     the statement's OUTPUT (exact match; a case-only difference passes with a
     note unless --strict-case; an output name containing '/' is flagged because
     [Custom SQL/a/b] is ambiguous in Sigma),
  3. compares each column's TMSL dataType class with the warehouse type class
     and emits the cast needed (VARCHAR 'True'/'False' -> boolean, VARCHAR ->
     number, number -> text, ...). Pairs it cannot cast exactly are recorded as
     type_warnings, never guessed.

Output: a JSON report (default ./native-source-probe.json) and exit 1 on any
missing column, ambiguous name or failed probe (0 = clean, 2 = usage). With
--write-patched-dm the casts are folded into a COPY of the data model: each
affected statement becomes `SELECT <every output column, casts applied> FROM
(<original>)`, output names unchanged so every binding still resolves.

Inputs
  --dm     converter data-model output (dm-raw.json / dm-spec.json, or conv-meta.json)
  --tmsl   the model's TMSL (model.bim; bare or {"model": ...})
  EITHER --connection-id + --folder-id (probe live through sigma-sql-probe.py)
  OR     --probe-results <file>   results of `sigma-sql-probe.py --types` run on the
         queries written by --emit-queries (keys are statement keys)

Report shape (schema pbi-native-source-probe/v1)
  {status: PASS|FAIL, summary{...}, elements[{id,name,table,status,output_columns,types,bound[],error}],
   casts[{element_id,table,column,output_column,tmsl_type,warehouse_type,tmsl_class,
          warehouse_class,kind,expression}], patched_statements{element_id: sql},
   type_warnings[], unmapped_elements[], notes[]}

Python stdlib only.
"""
import argparse
import copy
import difflib
import importlib.util
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))

SCHEMA = "pbi-native-source-probe/v1"
CUSTOM_SQL_REF = re.compile(r"\[Custom SQL/([^\]]+)\]")


def _probe_module():
    mod = sys.modules.get("sigma_sql_probe")
    if mod is None:
        spec = importlib.util.spec_from_file_location("sigma_sql_probe", os.path.join(HERE, "sigma-sql-probe.py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules["sigma_sql_probe"] = mod
        spec.loader.exec_module(mod)
    return mod


# ------------------------------------------------------------------ type classes

def warehouse_class(type_text):
    """Warehouse type string (Snowflake SYSTEM$TYPEOF / Databricks typeof) -> class."""
    t = str(type_text or "").strip().lower()
    if not t:
        return "unknown"
    base = re.split(r"[(\[<\s]", t, maxsplit=1)[0]
    if base in ("varchar", "char", "character", "string", "text", "nvarchar", "nchar"):
        return "text"
    if base in ("number", "numeric", "decimal", "dec"):
        m = re.match(r"[a-z]+\(\s*\d+\s*,\s*(\d+)\s*\)", t)
        return "integer" if (m and int(m.group(1)) == 0) else "decimal"
    if base in ("int", "integer", "bigint", "smallint", "tinyint", "byteint", "long", "short"):
        return "integer"
    if base in ("float", "double", "real", "float4", "float8"):
        return "float"
    if base == "date":
        return "date"
    if base.startswith("timestamp") or base == "datetime":
        return "datetime"
    if base == "time":
        return "time"
    if base in ("boolean", "bool"):
        return "boolean"
    if base in ("binary", "varbinary", "bytes"):
        return "binary"
    if base in ("variant", "object", "array", "map", "struct", "geography", "geometry", "json"):
        return "variant"
    return "unknown"


def tmsl_class(data_type):
    return {"string": "text", "int64": "integer", "double": "float", "decimal": "decimal",
            "datetime": "datetime", "boolean": "boolean", "binary": "binary"}.get(str(data_type or "").lower())


_NUMERIC = ("integer", "decimal", "float")


def cast_kind(tmsl_cls, wh_cls):
    """None = compatible, a kind = cast needed, 'unresolved' = cannot cast exactly."""
    if tmsl_cls is None or wh_cls in ("unknown",):
        return None
    if tmsl_cls == "text":
        if wh_cls == "text":
            return None
        return "to_text" if wh_cls in _NUMERIC + ("boolean", "date", "datetime", "time", "variant") else "unresolved"
    if tmsl_cls in _NUMERIC:
        if wh_cls in _NUMERIC:
            return None
        if wh_cls == "text":
            return {"integer": "to_integer", "decimal": "to_decimal", "float": "to_float"}[tmsl_cls]
        return "unresolved"
    if tmsl_cls == "datetime":
        if wh_cls in ("date", "datetime"):
            return None
        return "to_timestamp" if wh_cls == "text" else "unresolved"
    if tmsl_cls == "boolean":
        if wh_cls == "boolean":
            return None
        if wh_cls == "text":
            return "to_boolean"
        # Snowflake's TRY_TO_BOOLEAN takes string input only: a NUMBER 0/1 flag needs a comparison.
        return "to_boolean_numeric" if wh_cls in _NUMERIC else "unresolved"
    return None  # binary / anything else: leave the warehouse type alone


_CASTS = {
    "snowflake": {
        "to_text": "TO_VARCHAR({c})", "to_integer": "TRY_TO_NUMBER({c}, 38, 0)",
        "to_decimal": "TRY_TO_DECIMAL({c}, 38, 9)", "to_float": "TRY_TO_DOUBLE({c})",
        "to_timestamp": "TRY_TO_TIMESTAMP({c})", "to_boolean": "TRY_TO_BOOLEAN({c})",
        "to_boolean_numeric": "IFF({c} IS NULL, NULL, {c} <> 0)"},
    "databricks": {
        "to_text": "CAST({c} AS STRING)", "to_integer": "TRY_CAST({c} AS BIGINT)",
        "to_decimal": "TRY_CAST({c} AS DECIMAL(38,9))", "to_float": "TRY_CAST({c} AS DOUBLE)",
        "to_timestamp": "TRY_CAST({c} AS TIMESTAMP)", "to_boolean": "TRY_CAST({c} AS BOOLEAN)",
        "to_boolean_numeric": "({c} <> 0)"},
    "bigquery": {
        "to_text": "CAST({c} AS STRING)", "to_integer": "SAFE_CAST({c} AS INT64)",
        "to_decimal": "SAFE_CAST({c} AS NUMERIC)", "to_float": "SAFE_CAST({c} AS FLOAT64)",
        "to_timestamp": "SAFE_CAST({c} AS TIMESTAMP)", "to_boolean": "SAFE_CAST({c} AS BOOL)",
        "to_boolean_numeric": "({c} <> 0)"},
}


# Power Query's `type number` parses TEXT with the model culture: in en-US "$1,234.50 " is
# 1234.5. A bare TRY_TO_DOUBLE / TRY_CAST returns NULL for it, silently undercounting every
# amount stored as text. So text -> number casts first normalise the text the way the
# culture writes numbers. Nested REPLACE is portable across Snowflake/Databricks/BigQuery.
_CURRENCY = ("$", "£", "€", "¥")
# Whether a culture writes 1.234,56 (decimal ',') is a property of the FULL culture tag, not of
# the language: es-ES is comma-decimal but es-MX is not; de-DE is, de-CH is not; en-US is not,
# en-ZA is. Resolution order: exact tag -> language default. Values below are from CLDR
# (Unicode CLDR number symbols; .NET cultures follow it).
#
# Language defaults: grouping '.', ' ' or NBSP, decimal ','.
_COMMA_DECIMAL = ("de", "fr", "es", "it", "nl", "pt", "ru", "pl", "sv", "da", "nb", "nn", "no", "fi", "tr",
                  "cs", "sk", "hu", "ro", "bg", "hr", "sl", "sr", "uk", "el", "lt", "lv", "et", "id", "vi",
                  "af", "ca", "gl", "eu", "be", "ka", "kk", "mk", "sq", "az", "hy", "is", "uz", "lb", "bs")
# Regions of a comma-decimal language that nevertheless write '.' as the decimal:
#   Swiss/Liechtenstein German + Swiss Italian (grouping is an apostrophe), and the Latin American
#   / US Spanish regions (es-MX, es-US, es-PR, es-DO, es-GT, es-HN, es-NI, es-PA, es-SV, es-PE, es-PH, es-419).
# fr-CH is NOT in this list: CLDR gives fr-CH a decimal comma (1 234,56); only de-CH / it-CH / de-LI
# use the Swiss '.' (1'234.56).
_DOT_DECIMAL_EXCEPTIONS = frozenset((
    "de-ch", "de-li", "it-ch", "es-mx", "es-us", "es-pr", "es-do", "es-gt", "es-hn", "es-ni",
    "es-pa", "es-sv", "es-pe", "es-ph", "es-419"))
# Regions of a dot-decimal language (English) that write ',' as the decimal.
_COMMA_DECIMAL_EXCEPTIONS = frozenset((
    "en-za", "en-dk", "en-de", "en-nl", "en-se", "en-fi", "en-at", "en-be", "en-si", "en-150"))
_NUMERIC_KINDS = ("to_integer", "to_decimal", "to_float")
# Grouping marks removed before the cast: space, NBSP, narrow NBSP (fr), apostrophe (Swiss; the
# ASCII one is written CHR(39) so no dialect's string-escape rules matter) and U+2019.
_GROUPING = ("\u00a0", "\u202f", "\u2019")


def decimal_comma(culture):
    tag = str(culture or "").strip().lower().replace("_", "-")
    if tag in _DOT_DECIMAL_EXCEPTIONS:
        return False
    if tag in _COMMA_DECIMAL_EXCEPTIONS:
        return True
    return tag.split("-")[0] in _COMMA_DECIMAL


def _sql_str(s):
    return "'" + s.replace("'", "''") + "'"


def _number_text(quoted_col, culture):
    e = f"TRIM({quoted_col})"
    for ch in _CURRENCY + (" ",) + _GROUPING:
        e = f"REPLACE({e}, {_sql_str(ch)}, '')"
    e = f"REPLACE({e}, CHR(39), '')"
    if decimal_comma(culture):
        e = f"REPLACE(REPLACE({e}, '.', ''), ',', '.')"
    else:
        e = f"REPLACE({e}, ',', '')"
    return e


def model_culture(tmsl):
    m = tmsl.get("model", tmsl) if isinstance(tmsl, dict) else {}
    return (m or {}).get("culture") or "en-US"  # Power BI's default model culture


def cast_expression(kind, quoted_col, dialect, tmsl_cls=None, culture=None):
    if culture and kind in _NUMERIC_KINDS:
        quoted_col = _number_text(quoted_col, culture)
    return _CASTS[dialect][kind].format(c=quoted_col)


# ------------------------------------------------------------------ model access

def _unwrap_dm(dm):
    if isinstance(dm, dict) and "pages" not in dm and isinstance(dm.get("model"), dict):
        return dm["model"]
    return dm


def _tables(tmsl):
    m = tmsl.get("model", tmsl) if isinstance(tmsl, dict) else {}
    return m.get("tables") or []


def _all_elements(dm):
    return [e for p in (_unwrap_dm(dm).get("pages") or []) for e in (p.get("elements") or [])]


def sql_elements(dm):
    """Custom SQL elements: kind sql, a statement, and at least one [Custom SQL/X] ref."""
    out = []
    for e in _all_elements(dm):
        src = e.get("source") or {}
        if src.get("kind") != "sql" or not str(src.get("statement") or "").strip():
            continue
        if any(CUSTOM_SQL_REF.search(str(c.get("formula") or "")) for c in e.get("columns") or []):
            out.append(e)
    return out


def statement_key(sql):
    p = _probe_module()
    return "s_" + p._sql_hash(sql)


def unique_queries(elements):
    out = {}
    for e in elements:
        stmt = e["source"]["statement"]
        out.setdefault(statement_key(stmt), stmt)
    return out


def _find_table(tmsl, name):
    tables = _tables(tmsl)
    for t in tables:
        if t.get("name") == name:
            return t
    low = str(name).lower()
    return next((t for t in tables if str(t.get("name", "")).lower() == low), None)


def _tmsl_column(table, col_name, output_name):
    cols = table.get("columns") or []
    hit = next((c for c in cols if c.get("name") == col_name), None)
    if hit is None:
        low = str(output_name).lower()
        hit = next((c for c in cols if str(c.get("sourceColumn", "")).lower() == low), None)
    return hit


# ----------------------------------------------------------------------- report

def _punct_free(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def _suggestions(ref, outputs):
    out = list(difflib.get_close_matches(ref, outputs, n=3, cutoff=0.6))
    pf = _punct_free(ref)
    out += [o for o in outputs if _punct_free(o) == pf and o not in out]
    return out[:5]


def _patched_statement(stmt, outputs, casts_by_output, dialect):
    p = _probe_module()
    sel = []
    for o in outputs:
        q = p.quote_ident(o, dialect)
        sel.append(f"{casts_by_output[o]} AS {q}" if o in casts_by_output else q)
    return f"SELECT {', '.join(sel)} FROM (\n{p.clean_statement(stmt)}\n)"


def build_report(dm, tmsl, probe_results, dialect="snowflake", strict_case=False):
    culture = model_culture(tmsl)
    p = _probe_module()
    elements = sql_elements(dm)
    rep = {"schema": SCHEMA, "dialect": dialect, "ran_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "status": "PASS", "elements": [], "casts": [], "patched_statements": {},
           "type_warnings": [], "unmapped_elements": [], "notes": []}
    n_bound = n_missing = n_case = n_ambig = n_probe_err = 0
    types_seen = False
    for e in elements:
        key = statement_key(e["source"]["statement"])
        res = probe_results.get(key)
        entry = {"id": e.get("id"), "name": e.get("name"), "statement_key": key}
        if not res or not res.get("ok"):
            entry.update(status="probe-error", error=str((res or {}).get("error") or "no probe result for this statement"))
            n_probe_err += 1
            rep["elements"].append(entry)
            continue
        outputs = list(res.get("columns") or [])
        if not outputs:
            # ok but nameless (BigQuery zero-row result): the output columns are UNKNOWN. Classing
            # every bound column 'missing' would hard-stop a run whose SQL is fine.
            entry.update(status="probe-error", error="unverified: " + str(
                res.get("note") or "the probe returned no output columns (zero-row result?)"))
            n_probe_err += 1
            rep["elements"].append(entry)
            continue
        types = res.get("types") or {}
        types_seen = types_seen or bool(types)
        entry.update(output_columns=outputs, types=types)
        exact, lower = set(outputs), {}
        for o in outputs:
            lower.setdefault(o.lower(), []).append(o)
        bound, seen = [], set()
        for c in e.get("columns") or []:
            for ref in CUSTOM_SQL_REF.findall(str(c.get("formula") or "")):
                if ref in seen:
                    continue
                seen.add(ref)
                b = {"column": c.get("name"), "ref": ref}
                if "/" in ref:
                    b.update(status="ambiguous-slash", actual=ref if ref in exact else None)
                    n_ambig += 1
                elif ref in exact:
                    b.update(status="ok", actual=ref)
                elif len(lower.get(ref.lower(), [])) == 1 and not strict_case:
                    b.update(status="case-insensitive", actual=lower[ref.lower()][0])
                    n_case += 1
                else:
                    b.update(status="missing", suggestions=_suggestions(ref, outputs))
                    n_missing += 1
                bound.append(b)
        n_bound += len(bound)
        entry["bound"] = bound
        bad = [b for b in bound if b["status"] in ("missing", "ambiguous-slash")]
        entry["status"] = ("missing-columns" if any(b["status"] == "missing" for b in bound)
                           else "ambiguous-names" if bad else "ok")

        table = _find_table(tmsl, e.get("name"))
        entry["table"] = table.get("name") if table else None
        if table is None:
            rep["unmapped_elements"].append({"id": e.get("id"), "name": e.get("name"),
                                             "reason": "no TMSL table with this name; types not compared"})
        elif types:
            casts_by_output = {}
            for c in e.get("columns") or []:
                m = re.fullmatch(r"\[Custom SQL/([^\]/]+)\]", str(c.get("formula") or "").strip())
                if not m:
                    continue
                actual = next((b["actual"] for b in bound if b["ref"] == m.group(1) and b.get("actual")), None)
                tcol = _tmsl_column(table, c.get("name"), m.group(1))
                if not actual or tcol is None or actual not in types:
                    continue
                tcls, wcls = tmsl_class(tcol.get("dataType")), warehouse_class(types[actual])
                kind = cast_kind(tcls, wcls)
                if kind is None:
                    continue
                base = {"element_id": e.get("id"), "table": table.get("name"), "column": c.get("name"),
                        "output_column": actual, "tmsl_type": tcol.get("dataType"), "warehouse_type": types[actual],
                        "tmsl_class": tcls, "warehouse_class": wcls}
                if kind == "unresolved":
                    rep["type_warnings"].append(dict(
                        base, reason=f"no exact cast from warehouse {wcls} to model {tcls}; left as the warehouse type"))
                    continue
                expr = cast_expression(kind, p.quote_ident(actual, dialect), dialect, tcls, culture=culture)
                rep["casts"].append(dict(base, kind=kind, expression=expr))
                casts_by_output[actual] = expr
            if casts_by_output:
                rep["patched_statements"][e.get("id")] = _patched_statement(
                    e["source"]["statement"], outputs, casts_by_output, dialect)
        rep["elements"].append(entry)

    if elements and not types_seen:
        rep["notes"].append("warehouse types unavailable (the probe returned none); "
                            "column existence was checked but no casts were evaluated")
    failed = [x for x in rep["elements"] if x["status"] != "ok"]
    rep["summary"] = {"elements_probed": len(elements), "elements_failed": len(failed),
                      "probe_errors": n_probe_err, "bound_columns": n_bound, "missing_columns": n_missing,
                      "case_only_matches": n_case, "ambiguous_names": n_ambig, "casts": len(rep["casts"]),
                      "type_warnings": len(rep["type_warnings"])}
    if failed:
        rep["status"] = "FAIL"
    return rep


def apply_patches(dm, report):
    """Copy of dm with each element's statement replaced by its cast-applying wrapper."""
    out = copy.deepcopy(dm)
    base = _unwrap_dm(out)
    for el in [e for pg in (base.get("pages") or []) for e in (pg.get("elements") or [])]:
        stmt = report["patched_statements"].get(el.get("id"))
        if stmt:
            el["source"]["statement"] = stmt
    return out


# -------------------------------------------------------------------------- CLI

def _read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _write_json(path, obj):
    """The report, queries and patched DM hold customer SQL / column names: private (0600)."""
    _probe_module()._write_private_json(path, obj)


def main(argv=None, api=None, sleep=time.sleep):
    ap = argparse.ArgumentParser(description="Pre-POST gate for Custom SQL elements (see module docstring).")
    ap.add_argument("--dm", required=True, help="converter data-model output (dm-raw.json / dm-spec.json)")
    ap.add_argument("--tmsl", required=True, help="model.bim")
    ap.add_argument("--out", default="native-source-probe.json")
    ap.add_argument("--probe-results", help="results of sigma-sql-probe.py --types (keys = statement keys)")
    ap.add_argument("--emit-queries", help="write {statement_key: sql} for sigma-sql-probe.py --in, then continue")
    ap.add_argument("--connection-id", default=os.environ.get("SIGMA_PROBE_CONNECTION_ID"))
    ap.add_argument("--folder-id", default=os.environ.get("SIGMA_PROBE_FOLDER_ID"))
    ap.add_argument("--dialect", default="snowflake", choices=("snowflake", "databricks", "bigquery"))
    ap.add_argument("--state", help="sigma-sql-probe state file (resumable)")
    ap.add_argument("--base-url", help="pin SIGMA_BASE_URL for this run")
    ap.add_argument("--probe-concurrency", type=int, default=6,
                    help="parallel export/download polls against the ONE scratch workbook (default 6)")
    ap.add_argument("--probe-no-cache", action="store_true",
                    help="ignore and do not write the per-statement result cache")
    ap.add_argument("--probe-cache-max-age-hours", type=float, default=24.0,
                    help="re-probe cached statements older than this (default 24; 0 = never reuse the cache). "
                         "Use --probe-no-cache after a warehouse-side fix.")
    ap.add_argument("--keep-probe-workbook", action="store_true",
                    help="do not delete the scratch workbook afterwards (debugging)")
    ap.add_argument("--strict-case", action="store_true", help="a case-only name difference counts as missing")
    ap.add_argument("--write-patched-dm", help="write a copy of the DM with the casts folded into the statements")
    a = ap.parse_args(argv)
    live = bool(a.connection_id and a.folder_id)
    cache_stats = None
    if not a.probe_results and not live and not a.emit_queries:
        ap.error("give --probe-results, or --connection-id and --folder-id to probe live")

    dm, tmsl = _read_json(a.dm), _read_json(a.tmsl)
    queries = unique_queries(sql_elements(dm))
    if a.emit_queries:
        _write_json(a.emit_queries, queries)
    if a.probe_results:
        results = _read_json(a.probe_results)
    elif live:
        if a.base_url:
            os.environ["SIGMA_BASE_URL"] = a.base_url
        p = _probe_module()
        state = a.state or os.path.splitext(a.out)[0] + ".probe-state.json"
        cache = os.path.splitext(a.out)[0] + ".cache.json"
        prb = p.Probe(api or p.SigmaHttp().call, a.connection_id, a.folder_id, dialect=a.dialect,
                      state_path=state, name="zz native-source probe (scratch)", sleep=sleep,
                      batch=10 ** 6, workers=max(1, a.probe_concurrency),  # all statements in ONE workbook write
                      cache_path=cache, use_cache=not a.probe_no_cache,
                      cache_max_age_hours=a.probe_cache_max_age_hours)
        # BigQuery has no per-column typeof: existence only (columns mode), no casts.
        mode = "columns" if a.dialect == "bigquery" else "types"
        try:
            results = prb.run(queries, mode=mode)
            cache_stats = dict(prb.stats)
        finally:
            # The scratch workbook holds every customer statement: never leave it behind.
            if not a.keep_probe_workbook:
                prb.cleanup()
    else:
        print(f"[probe-native-sources] wrote {len(queries)} queries to {a.emit_queries}; run "
              "sigma-sql-probe.py --types on them, then re-run with --probe-results", file=sys.stderr)
        return 0
    rep = build_report(dm, tmsl, results, dialect=a.dialect, strict_case=a.strict_case)
    if cache_stats is not None:
        rep["probe_cache"] = cache_stats
        print(f"[probe-native-sources] {cache_stats['cached']} cached, {cache_stats['probed']} probed", file=sys.stderr)
    if a.dialect == "bigquery" and not a.probe_results:
        rep["type_checks_skipped"] = True
        rep["notes"].append("type checks were skipped for dialect bigquery (no per-column typeof): "
                            "column existence was checked, no casts were evaluated")
    _write_json(a.out, rep)
    if a.write_patched_dm and rep["patched_statements"]:
        _write_json(a.write_patched_dm, apply_patches(dm, rep))
    s = rep["summary"]
    print(f"[probe-native-sources] {rep['status']}: {s['elements_probed']} element(s), {s['bound_columns']} bound "
          f"column(s), {s['missing_columns']} missing, {s['ambiguous_names']} ambiguous, {s['probe_errors']} probe "
          f"error(s), {s['casts']} cast(s), {s['type_warnings']} type warning(s) -> {a.out}", file=sys.stderr)
    for e in rep["elements"]:
        if e["status"] == "probe-error":
            print(f"  PROBE ERROR {e['name']}: {e['error'][:300]}", file=sys.stderr)
        for b in e.get("bound", []):
            if b["status"] == "missing":
                print(f"  MISSING {e['name']}: [Custom SQL/{b['ref']}] not in output"
                      + (f" (did you mean {', '.join(b['suggestions'])}?)" if b.get("suggestions") else ""),
                      file=sys.stderr)
            elif b["status"] == "ambiguous-slash":
                print(f"  AMBIGUOUS {e['name']}: output name {b['ref']!r} contains '/'; alias it without '/'",
                      file=sys.stderr)
    if s["missing_columns"] and cache_stats is not None and cache_stats["cached"]:
        print("  note: some results came from the probe cache; if you fixed the warehouse (same SQL text), "
              "rerun with --probe-no-cache (or --probe-cache-max-age-hours N)", file=sys.stderr)
    return 0 if rep["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
