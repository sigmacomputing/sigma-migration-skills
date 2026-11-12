#!/usr/bin/env python3
"""extract-model-pbix.py — LOCAL semantic-model front door for a `.pbix` file.

The normal powerbi-to-sigma model path is a Fabric getDefinition/TMSL bundle
(migrate-powerbi.rb --tmsl). A user who only has a local `.pbix` on disk has
no such bundle: the `.pbix` DataModel is a binary VertiPaq blob. This script
reads that blob LOCALLY with the `pbixray` library (no Fabric, no tenant) and
emits a TMSL `model.bim` in the SAME shape migrate-powerbi.rb --tmsl and the
vendored converter (convertPowerBIToSigma) already consume:

  { "name": <model>,
    "compatibilityLevel": 1600,
    "model": {
      "culture": "en-US",
      "tables": [ { "name", "columns":[{"name","dataType","sourceColumn",...}],
                    "measures":[{"name","expression"}],
                    "partitions":[M or calculated-table DAX] } ],
      "relationships": [ { "name","fromTable","fromColumn","toTable","toColumn",
                           "crossFilteringBehavior","isActive" } ] } }

The pbixray → TMSL assembly (assemble_tmsl / build_model_from_pbixray) is a
PURE function of the pbixray DataFrames, so it is unit-testable with mocked
dataframes and needs no `.pbix` at test time.

pbixray PACKAGING CAVEAT (be honest with the user): pbixray depends on
`xpress8` (ships a working wheel) plus `xpress9` and `xmhuffman`, whose PyPI
sdists are BROKEN — they must be built FROM SOURCE. Install path:
  pip install apsw pandas xpress8 \
    "git+https://github.com/Hugoberry/xpress9-python@main" \
    "git+https://github.com/Hugoberry/xmhuffman-cython@main" \
    pbixray
(see refs/local-pbix.md). Without pbixray this script exits with a clear
"pbixray required for local model extraction" message + that setup pointer;
the dependency-free report front door (extract-report-classic.py --pbix) and
the whole --tmsl Fabric path are unaffected.

Usage:
  python3 extract-model-pbix.py --pbix /path/Sales.pbix --out model.bim [--name "Sales"]
"""
import argparse, base64, datetime, json, math, os, re, sys, zipfile, zlib

# pbixray schema PandasDataType (pandas dtype string) -> TMSL dataType. TMSL
# uses string/int64/double/dateTime/boolean/binary; the converter special-cases
# "binary" (skips it as an embedded asset) and reads dataType on calc columns.
def _tmsl_datatype(pandas_dtype):
    d = str(pandas_dtype or "").strip().lower()
    if d.startswith("int") or d.startswith("uint"):
        return "int64"
    if d.startswith("float") or d.startswith("decimal") or d.startswith("number"):
        return "double"
    if d.startswith("datetime") or d.startswith("date") or d.startswith("timestamp"):
        return "dateTime"
    if d.startswith("bool"):
        return "boolean"
    if d.startswith("bytes") or d.startswith("binary"):
        return "binary"
    # "string", "object", "category", unknown -> Sigma treats as text
    return "string"


def _clean(v, default=""):
    """DataFrame cells arrive as str / numpy scalars / NaN — normalize to a
    plain Python string, mapping missing (None/NaN) to `default`."""
    if v is None:
        return default
    if isinstance(v, float) and math.isnan(v):
        return default
    s = str(v)
    return default if s in ("nan", "NaT", "None") else s


def _truthy(v, default=True):
    if v is None:
        return default
    if isinstance(v, float) and math.isnan(v):
        return default
    if isinstance(v, str):
        return v.strip().lower() not in ("false", "0", "", "no")
    return bool(v)


# TMSL dataType from the model's own metadata (tmschema_columns.DataType is the
# TOM DataType enum). pandas dtypes cannot tell a fixed-decimal column from a
# double, so the model's type wins whenever pbixray exposes it.
_TOM_DATATYPE = {2: "string", 6: "int64", 8: "double", 9: "dateTime",
                 10: "decimal", 11: "boolean", 17: "binary"}
_TOM_DATATYPE_NAMES = {"string": "string", "int64": "int64", "double": "double",
                       "datetime": "dateTime", "decimal": "decimal",
                       "boolean": "boolean", "binary": "binary"}


def _tom_datatype(v):
    s = _clean(v).strip()
    if not s:
        return None
    try:
        return _TOM_DATATYPE.get(int(float(s)))
    except ValueError:
        return _TOM_DATATYPE_NAMES.get(s.lower())


def _int_or_none(v):
    s = _clean(v).strip()
    try:
        return int(float(s)) if s else None
    except ValueError:
        return None


# TOM RefreshGranularityType (Day/Month/Quarter/Year) and RefreshPolicyMode.
_REFRESH_GRANULARITY = {0: "day", 1: "month", 2: "quarter", 3: "year"}
_REFRESH_MODE = {0: "import", 1: "hybrid"}


def _enum_name(v, table):
    n = _int_or_none(v)
    if n is not None:
        return table.get(n)
    s = _clean(v).strip().lower()
    return s if s in table.values() else None


# --- Power Query "Enter data" tables (Table.FromRows) -> SQL rows -----------
# Enter data stores its rows as base64(raw-deflate(JSON)) inside the M. A
# partition left like that has no warehouse behind it, so the converter would
# invent a placeholder path. The rows are decoded here and the Table.FromRows
# call is replaced by a Value.NativeQuery over a typed SELECT, so the table
# converts to a real Custom SQL element and the M steps after it (renames,
# type changes, ...) fold exactly like any other native query.
_SQL_DIALECT_TYPES = {
    "snowflake": {"string": "VARCHAR", "int64": "BIGINT", "double": "DOUBLE", "decimal": "DOUBLE",
                  "dateTime": "TIMESTAMP", "boolean": "BOOLEAN", "binary": "VARCHAR"},
    "databricks": {"string": "STRING", "int64": "BIGINT", "double": "DOUBLE", "decimal": "DOUBLE",
                   "dateTime": "TIMESTAMP", "boolean": "BOOLEAN", "binary": "STRING"},
    "bigquery": {"string": "STRING", "int64": "INT64", "double": "FLOAT64", "decimal": "FLOAT64",
                 "dateTime": "TIMESTAMP", "boolean": "BOOL", "binary": "STRING"},
    # Generic ANSI/PostgreSQL-flavoured types (Postgres, Redshift): there is no type named DOUBLE.
    "ansi": {"string": "VARCHAR", "int64": "BIGINT", "double": "DOUBLE PRECISION", "decimal": "DOUBLE PRECISION",
             "dateTime": "TIMESTAMP", "boolean": "BOOLEAN", "binary": "VARCHAR"},
}
# A dialect with no entry above (Synapse / SQL Server / MySQL / anything unknown) is "unsupported":
# Enter-data SQL is NOT generated for it (the partition is left as extracted, with a loud note)
# rather than emitted in Snowflake syntax that fails at the warehouse.
UNSUPPORTED_DIALECT = "unsupported"


CULTURE_ASSUMED_ANNOTATION = "SigmaMigration.CultureAssumed"
CULTURE_ASSUMED_TEXT = ("the model culture could not be read from the .pbix (pbixray exposes no culture accessor); "
                        "en-US is assumed. Culture-dependent steps (Enter-data dates, text-to-number casts) "
                        "may be wrong for a non-en-US model: check the culture in Power BI Desktop "
                        "(File > Options > Regional Settings, or Model view > Properties).")


def _normalize_dialect(dialect):
    d = str(dialect or "").strip().lower()
    if "bigquery" in d:
        return "bigquery"
    if "databricks" in d or "spark" in d:
        return "databricks"
    if not d or "snowflake" in d:
        return "snowflake"
    if "postgres" in d or "redshift" in d or d == "ansi":
        return "ansi"
    return UNSUPPORTED_DIALECT


def _quote_ident(name, dialect):
    if dialect in ("bigquery", "databricks"):
        return "`" + name.replace("`", "``") + "`"
    return '"' + name.replace('"', '""') + '"'


def _m_string_end(text, i):
    """Index just past the M string literal opening at text[i] ('"')."""
    i += 1
    while i < len(text):
        if text[i] == '"':
            if text[i + 1:i + 2] == '"':
                i += 2
                continue
            return i + 1
        i += 1
    return len(text)


def _split_m_args(text, start):
    """Split the arguments of the call whose '(' ends just before `start`.
    Returns (args, index just past the closing ')'), or (None, start) when
    unbalanced. Strings, comments aside, brackets nest."""
    args, depth, arg_start, i = [], 1, start, start
    while i < len(text):
        ch = text[i]
        if ch == '"':
            i = _m_string_end(text, i)
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append(text[arg_start:i].strip())
                return args, i + 1
        elif ch == "," and depth == 1:
            args.append(text[arg_start:i].strip())
            arg_start = i + 1
        i += 1
    return None, start


def _m_escape_string(sql):
    """SQL text -> the body of an M string literal that round-trips through the
    converter's M string decoder ('#' is written as the #(0023) escape)."""
    return (sql.replace('"', '""').replace("#", "#(0023)")
               .replace("\r", "#(cr)").replace("\n", "#(lf)").replace("\t", "#(tab)"))


def _m_name(raw):
    """A column name written as an M identifier, #"quoted identifier" or
    "string literal" -> the name."""
    raw = raw.strip()
    if raw.startswith('#"') or raw.startswith('"'):
        quote_at = raw.index('"')
        end = _m_string_end(raw, quote_at)
        return raw[quote_at + 1:end - 1].replace('""', '"')
    return raw


def _enter_data_columns(arg, width):
    """Column names from Table.FromRows' second argument (a `type table [..]`,
    possibly inside a let, or a list of names), else Column1..N."""
    if arg:
        m = re.search(r"\btype\s+table\s*\[", arg)
        if m:
            depth, i, cur, parts = 1, m.end(), m.end(), []
            while i < len(arg) and depth:
                ch = arg[i]
                if ch == '"':
                    i = _m_string_end(arg, i)
                    continue
                if ch in "([{":
                    depth += 1
                elif ch in ")]}":
                    depth -= 1
                    if depth == 0:
                        parts.append(arg[cur:i])
                elif ch == "," and depth == 1:
                    parts.append(arg[cur:i])
                    cur = i + 1
                i += 1
            names = []
            for part in parts:
                part = part.strip()
                if part.startswith('#"'):
                    names.append(_m_name(part))
                else:
                    names.append(part.split("=", 1)[0].strip())
            if names and all(names):
                return names
        stripped = arg.strip()
        if stripped.startswith("{") and stripped.endswith("}"):
            inner, _ = _split_m_args("(" + stripped[1:-1] + ")", 1)
            names = [_m_name(a) for a in (inner or [])]
            if names and all(names):
                return names
    return [f"Column{i + 1}" for i in range(width)]


def decode_enter_data(expr):
    """The Table.FromRows call inside an M expression -> {start, end, columns,
    rows}, or None when there is none / the payload cannot be decoded."""
    m = re.search(r"\bTable\.FromRows\s*\(", expr)
    if not m:
        return None
    args, end = _split_m_args(expr, m.end())
    if not args:
        return None
    blob = re.search(r'Binary\.FromText\s*\(\s*"([^"]*)"', args[0])
    if not blob:
        return None
    try:
        rows = json.loads(zlib.decompress(base64.b64decode(blob.group(1), validate=True), -15).decode("utf-8"))
    except (ValueError, zlib.error, UnicodeDecodeError):
        return None
    if not isinstance(rows, list) or not all(isinstance(r, list) for r in rows):
        return None
    width = max([len(r) for r in rows] or [0])
    columns = _enter_data_columns(args[1] if len(args) > 1 else None, width)
    if width > len(columns):
        return None
    return {"start": m.start(), "end": end, "columns": columns, "rows": rows}


def _final_column_names(tail, names):
    """Where each column name ends up after the Table.RenameColumns steps in
    `tail` (the M after the Table.FromRows step). {original: final}."""
    mapping = {n: n for n in names}
    for m in re.finditer(r"\bTable\.RenameColumns\s*\(", tail):
        args, _ = _split_m_args(tail, m.end())
        if not args or len(args) < 2:
            continue
        pairs = {a.replace('""', '"'): b.replace('""', '"') for a, b in
                 re.findall(r'\{\s*"((?:[^"]|"")*)"\s*,\s*"((?:[^"]|"")*)"\s*\}', args[1])}
        for orig, cur in list(mapping.items()):
            if cur in pairs:
                mapping[orig] = pairs[cur]
    return mapping


_ISO_TS = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?(?:Z|[+-]\d{2}:?\d{2})?$")


_INT_TEXT = re.compile(r"^-?\d+$")

# Enter Data keeps each cell as the TEXT the author typed (Serialized.Text), e.g. "1/15/2024" in an
# en-US model; a later Changed Type step parses it with the MODEL culture. So a dateTime cell is
# accepted in the culture's own numeric date order, not only as ISO.
_DATE_NUM = re.compile(r"^(\d{1,4})[/.\-](\d{1,2})[/.\-](\d{1,4})"
                       r"(?:[ T,]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?)?$")
_MDY_CULTURES = frozenset(("en-us", "es-us", "en-ph", "fil-ph", "en-as", "en-gu", "en-mh", "en-mp",
                           "en-um", "en-vi", "haw-us", "chr-us"))
_YMD_LANGS = frozenset(("ja", "zh", "ko", "hu", "lt", "mn"))


def date_order(culture):
    """'mdy' | 'dmy' | 'ymd': the order of a numeric short date in `culture` (default en-US: M/D/Y)."""
    tag = str(culture or "en-US").strip().lower().replace("_", "-")
    if tag in _MDY_CULTURES:
        return "mdy"
    if tag.split("-")[0] in _YMD_LANGS:
        return "ymd"
    return "dmy" if tag.split("-")[0] != "en" or "-" in tag else "mdy"


def _parse_datetime_cell(text, culture="en-US"):
    """(y, mo, d, hh, mi, ss) or None. ISO first; else a numeric date in the culture's order.
    Two-digit years and out-of-range parts are NOT guessed (None)."""
    text = str(text).strip()
    mt = _ISO_TS.match(text)
    if mt:
        parts = tuple(int(x) if x else 0 for x in mt.groups())
    else:
        m = _DATE_NUM.match(text)
        if not m:
            return None
        a, b, c = m.group(1), m.group(2), m.group(3)
        order = date_order(culture)
        if len(a) == 4:                      # year first is unambiguous: Y/M/D
            y, mo, d = int(a), int(b), int(c)
        elif len(c) == 4 and order in ("mdy", "dmy"):
            y = int(c)
            mo, d = (int(a), int(b)) if order == "mdy" else (int(b), int(a))
        else:
            return None
        hh, mi, ss = (int(m.group(i)) if m.group(i) else 0 for i in (4, 5, 6))
        ap = (m.group(7) or "").lower()
        if ap:
            if not 1 <= hh <= 12:
                return None
            hh = hh % 12 + (12 if ap == "pm" else 0)
        parts = (y, mo, d, hh, mi, ss)
    try:
        datetime.datetime(*parts)
    except ValueError:
        return None
    return parts


def _sql_literal(value, dtype, culture="en-US"):
    """One Enter-data cell -> a SQL literal for the TMSL `dtype`, or the string
    "NULL" for a missing cell. Returns None when the value does not fit the type.
    `culture` is the model culture (dateTime cells are typed text in that culture)."""
    if value is None:
        return "NULL"
    if dtype == "int64":
        try:
            if isinstance(value, bool):
                return None
            if isinstance(value, int):
                return str(value)
            text = str(value).strip()
            if _INT_TEXT.match(text):
                return str(int(text))  # exact: float() would round integers above 2**53
            f = float(text)
            return str(int(f)) if f == int(f) else None
        except (ValueError, OverflowError, TypeError):
            return None
    if dtype in ("double", "decimal"):
        try:
            if isinstance(value, bool):
                return None
            f = float(value)
            return repr(f) if math.isfinite(f) else None
        except (ValueError, TypeError):
            return None
    if dtype == "boolean":
        if isinstance(value, bool):
            return "TRUE" if value else "FALSE"
        t = str(value).strip().lower()
        return {"true": "TRUE", "false": "FALSE", "1": "TRUE", "0": "FALSE"}.get(t)
    if dtype == "dateTime":
        parsed = _parse_datetime_cell(value, culture)
        if parsed is None:
            return None
        y, mo, d, hh, mi, ss = parsed
        return f"CAST('{y:04d}-{mo:02d}-{d:02d} {hh:02d}:{mi:02d}:{ss:02d}' AS TIMESTAMP)"
    text = value if isinstance(value, str) else (json.dumps(value) if isinstance(value, bool) else str(value))
    text = (text.replace("\\", "\\\\").replace("'", "''")
                .replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t"))
    return f"'{text}'"


def enter_data_sql(columns, rows, dtypes, dialect="snowflake", culture="en-US"):
    """(sql, problems). One typed SELECT per row joined by UNION ALL: the first
    row casts every cell so the column types are explicit; no table is
    referenced (a FROM would be read as a warehouse path). Cells that do not fit
    their column's type become NULL and are listed in `problems`."""
    dialect = _normalize_dialect(dialect)
    if dialect not in _SQL_DIALECT_TYPES:
        raise ValueError(f"Enter-data SQL is not generated for warehouse dialect {dialect!r}")
    types = _SQL_DIALECT_TYPES[dialect]
    problems = []
    names = [_quote_ident(c, dialect) for c in columns]
    if not rows:
        cells = [f"CAST(NULL AS {types[t]}) AS {n}" for t, n in zip(dtypes, names)]
        return "SELECT " + ", ".join(cells) + " WHERE 1 = 0", problems
    selects = []
    for ri, row in enumerate(rows):
        cells = []
        for ci, (dtype, name) in enumerate(zip(dtypes, names)):
            value = row[ci] if ci < len(row) else None
            lit = _sql_literal(value, dtype, culture)
            if lit is None:
                why = f" (model culture {culture})" if dtype == "dateTime" else ""
                problems.append(f"{columns[ci]} (row {ri + 1}): {value!r} does not fit {dtype}{why}; loaded as NULL")
                lit = "NULL"
            if ri == 0:
                if not lit.startswith("CAST("):
                    lit = f"CAST({lit} AS {types[dtype]})"
                cells.append(f"{lit} AS {name}")
            else:
                cells.append(lit)
        selects.append("SELECT " + ", ".join(cells))
    return "\nUNION ALL ".join(selects), problems


def enter_data_partition(expr, col_types, dialect="snowflake", culture="en-US"):
    """M expression containing an Enter-data Table.FromRows -> (new M, notes),
    or (None, notes) when it cannot be decoded. `col_types` maps a column's final
    model sourceColumn/name to its TMSL dataType."""
    decoded = decode_enter_data(expr)
    if decoded is None:
        return None, ['Table.FromRows rows could not be decoded; the partition M is left as extracted']
    columns, rows = decoded["columns"], decoded["rows"]
    if _normalize_dialect(dialect) not in _SQL_DIALECT_TYPES:
        return None, [f"Enter-data SQL NOT generated: warehouse dialect {str(dialect)!r} is not supported "
                      f"({len(rows)} row(s)); the Table.FromRows partition is left as extracted and has no "
                      "warehouse behind it. Load these rows into a warehouse table and point the model at it."]
    final = _final_column_names(expr[decoded["end"]:], columns)
    dtypes = [col_types.get(final[c], "string") for c in columns]
    sql, problems = enter_data_sql(columns, rows, dtypes, dialect, culture)
    call = f'Value.NativeQuery(null, "{_m_escape_string(sql)}", null, [EnableFolding=true])'
    notes = [f"Enter-data rows ({len(rows)}) decoded to a SQL SELECT"] + [f"Enter data: {p}" for p in problems]
    return expr[:decoded["start"]] + call + expr[decoded["end"]:], notes


def assemble_tmsl(model_name, schema_recs, measure_recs, relationship_recs,
                  calc_col_recs=(), calc_table_recs=(), mquery_recs=(),
                  table_order=None, parameter_recs=(), column_recs=(),
                  hierarchy_recs=(), level_recs=(), refresh_policy_recs=(),
                  rls_recs=(), dialect="snowflake", culture=None, culture_note=None):
    """PURE pbixray-records -> TMSL model.bim dict.

    Each *_recs arg is a list of dicts (what pandas `df.to_dict("records")`
    yields), so this is fully testable with hand-built dicts — no pbixray:
      schema_recs       : {TableName, ColumnName, PandasDataType}
      measure_recs      : {TableName, Name, Expression, [Description]}
      relationship_recs : {FromTableName, FromColumnName, ToTableName,
                           ToColumnName, [IsActive], [CrossFilteringBehavior], [Name]}
      calc_col_recs     : {TableName, ColumnName, Expression}  (DAX calc columns)
      calc_table_recs   : {TableName, Expression}              (DAX calc tables)
      mquery_recs       : {TableName, Expression}              (Power Query M)
      parameter_recs    : {ParameterName, Expression, [Description]} (M parameters)
      column_recs       : tmschema_columns {TableName, Name, [Type], [DataType],
                           [SourceColumn], [ID], [SortByColumnID | SortByColumn]}
      hierarchy_recs    : tmschema_hierarchies {TableName, Name}
      level_recs        : tmschema_levels {TableName, HierarchyName, Name, ColumnName, Ordinal}
      refresh_policy_recs: tmschema_refresh_policies {TableName, PolicyType,
                           RollingWindowGranularity/Periods, IncrementalGranularity/Periods,
                           [PollingExpression], SourceExpression, [Mode]}
      rls_recs          : rls {RoleName, TableName, FilterExpression, [RoleDescription]}
    `dialect` (snowflake | databricks | bigquery | ansi | unsupported) only shapes the SQL emitted for
    Enter-data tables. `culture` is the model's real culture when it could be read from the .pbix;
    None means "unknown": en-US is assumed and `culture_note` (why) is recorded as a model annotation.
    """
    model_culture = culture or "en-US"
    tables = {}          # name -> table dict (insertion-ordered)
    order = []
    notes = {}           # table -> [extraction notes], emitted as annotations
    calc_tables = {}
    for r in calc_table_recs:
        tn = _clean(r.get("TableName"))
        expr = _clean(r.get("Expression"))
        if tn and expr:
            calc_tables.setdefault(tn, expr)

    def _table(name):
        name = _clean(name)
        if not name:
            return None
        if name not in tables:
            tables[name] = {"name": name, "columns": [], "measures": [], "partitions": []}
            order.append(name)
        return tables[name]

    # Seed table order from the model's declared table list when provided so
    # the emitted .bim mirrors the pbix ordering (fact-first, etc.).
    for t in (table_order or []):
        _table(t)

    # The model's own column metadata (tmschema_columns): real data types, the
    # query-side source column (model-level renames), and sort-by columns.
    col_meta = {}
    id_to_name = {}
    for r in column_recs:
        tn, cn = _clean(r.get("TableName")), _clean(r.get("Name"))
        if not (tn and cn):
            continue
        col_meta[(tn, cn)] = r
        cid = _int_or_none(r.get("ID"))
        if cid is not None:
            id_to_name[(tn, cid)] = cn

    # Calculated (DAX) columns by table. pbixray's schema also lists each of
    # them as a plain column; that phantom binds to a SQL column that does not
    # exist, so it is dropped (its dtype still types the calculated column).
    calc_names = {}
    for r in calc_col_recs:
        tn, cn = _clean(r.get("TableName")), _clean(r.get("ColumnName"))
        if tn and cn and _clean(r.get("Expression")):
            calc_names.setdefault(tn, set()).add(cn)
    phantom_dtype = {}

    # Data columns (schema).
    for r in schema_recs:
        t = _table(r.get("TableName"))
        if t is None:
            continue
        col = _clean(r.get("ColumnName"))
        if not col:
            continue
        if col in calc_names.get(t["name"], ()):
            phantom_dtype[(t["name"], col)] = r.get("PandasDataType")
            continue
        is_calc_table = t["name"] in calc_tables
        meta = col_meta.get((t["name"], col), {})
        src = _clean(meta.get("SourceColumn"))
        column = {
            "name": col,
            "dataType": _tom_datatype(meta.get("DataType")) or _tmsl_datatype(r.get("PandasDataType")),
            "sourceColumn": f"[{col}]" if is_calc_table else (src or col),
            "summarizeBy": "none",
        }
        if is_calc_table:
            column["type"] = "calculatedTableColumn"
        t["columns"].append(column)

    # Calculated (DAX) columns — carried through so the converter's calc-column
    # translator can see them; marked type=calculated so it does NOT treat them
    # as warehouse columns.
    for r in calc_col_recs:
        t = _table(r.get("TableName"))
        if t is None:
            continue
        col = _clean(r.get("ColumnName"))
        expr = _clean(r.get("Expression"))
        if not col or not expr:
            continue
        meta = col_meta.get((t["name"], col), {})
        dtype = (_tom_datatype(meta.get("DataType"))
                 or (_tmsl_datatype(phantom_dtype[(t["name"], col)]) if (t["name"], col) in phantom_dtype else None)
                 or "string")
        t["columns"].append({
            "name": col, "type": "calculated", "expression": expr,
            "dataType": dtype, "summarizeBy": "none",
        })

    # sortByColumn: only when the model names one (pbixray may not expose it).
    for (tn, cn), meta in col_meta.items():
        t = tables.get(tn)
        if t is None:
            continue
        sort_name = _clean(meta.get("SortByColumn")) or _clean(meta.get("SortByColumnName"))
        if not sort_name:
            sid = _int_or_none(meta.get("SortByColumnID"))
            sort_name = id_to_name.get((tn, sid), "") if sid is not None else ""
        if sort_name and sort_name != cn:
            for c in t["columns"]:
                if c["name"] == cn and c.get("type") != "calculatedTableColumn":
                    c["sortByColumn"] = sort_name

    # Measures.
    for r in measure_recs:
        t = _table(r.get("TableName"))
        if t is None:
            continue
        nm = _clean(r.get("Name"))
        if not nm:
            continue
        m = {"name": nm, "expression": _clean(r.get("Expression"))}
        desc = _clean(r.get("Description"))
        if desc:
            m["description"] = desc
        t["measures"].append(m)

    # Hierarchies: levels ordered by ordinal, each bound to its column.
    levels_by = {}
    for r in level_recs:
        key = (_clean(r.get("TableName")), _clean(r.get("HierarchyName")))
        col = _clean(r.get("ColumnName"))
        if not (key[0] and key[1] and col):
            continue
        levels_by.setdefault(key, []).append(
            (_int_or_none(r.get("Ordinal")) or 0, _clean(r.get("Name")) or col, col))
    for r in hierarchy_recs:
        tn, hn = _clean(r.get("TableName")), _clean(r.get("Name"))
        if tn not in tables or not hn or not levels_by.get((tn, hn)):
            continue
        levels = [{"name": nm, "ordinal": o, "column": col} for o, nm, col in sorted(levels_by[(tn, hn)])]
        tables[tn].setdefault("hierarchies", []).append({"name": hn, "levels": levels})

    # Incremental-refresh policies (TMSL table.refreshPolicy). A policy's
    # partitions are generated at refresh time, so the .pbix has no M for the
    # table: its source is the policy's SourceExpression.
    policy_m = {}
    for r in refresh_policy_recs:
        tn = _clean(r.get("TableName"))
        t = tables.get(tn)
        if t is None:
            continue
        src = r.get("SourceExpression")
        src_text = "\n".join(src) if isinstance(src, (list, tuple)) else _clean(src)
        policy = {"policyType": "basic"}
        for tmsl_key, rec_key, kind in (
                ("rollingWindowGranularity", "RollingWindowGranularity", "gran"),
                ("rollingWindowPeriods", "RollingWindowPeriods", "int"),
                ("incrementalGranularity", "IncrementalGranularity", "gran"),
                ("incrementalPeriods", "IncrementalPeriods", "int"),
                ("incrementalPeriodsOffset", "IncrementalPeriodsOffset", "int")):
            val = _enum_name(r.get(rec_key), _REFRESH_GRANULARITY) if kind == "gran" else _int_or_none(r.get(rec_key))
            if val is not None:
                policy[tmsl_key] = val
        mode = _enum_name(r.get("Mode"), _REFRESH_MODE)
        if mode:
            policy["mode"] = mode
        polling = _clean(r.get("PollingExpression"))
        if polling:
            policy["pollingExpression"] = polling.split("\n")
        if src_text:
            policy["sourceExpression"] = src_text.split("\n")
            policy_m[tn] = src_text
        t["refreshPolicy"] = policy

    # Partitions. A DAX calculated table must win over the generic no-M fallback:
    # pbixray exposes its constructor through dax_tables, and losing that
    # expression makes the converter invent a physical warehouse table. Regular
    # tables retain their Power Query M (and therefore warehouse FQN); a table
    # with an incremental-refresh policy but no M takes the policy's source;
    # tables with none of those get an honest placeholder M partition.
    mq_by_table = {}
    for r in mquery_recs:
        tn = _clean(r.get("TableName"))
        expr = _clean(r.get("Expression"))
        if tn and expr:
            mq_by_table.setdefault(tn, expr)
    for name, t in tables.items():
        mq = mq_by_table.get(name) or policy_m.get(name)
        calc_expr = calc_tables.get(name)
        if calc_expr:
            t["partitions"].append({"name": name, "mode": "import",
                                    "source": {"type": "calculated",
                                               "expression": calc_expr}})
        elif mq:
            if name not in mq_by_table:
                notes.setdefault(name, []).append(
                    "no partition M in the .pbix; source taken from the incremental-refresh policy's SourceExpression")
            if re.search(r"\bTable\.FromRows\s*\(", mq):
                col_types = {}
                for c in t["columns"]:
                    if c.get("type") not in ("calculated", "calculatedTableColumn"):
                        col_types.setdefault(c.get("sourceColumn") or c["name"], c["dataType"])
                        col_types.setdefault(c["name"], c["dataType"])
                new_m, why = enter_data_partition(mq, col_types, dialect, model_culture)
                notes.setdefault(name, []).extend(why)
                mq = new_m or mq
            t["partitions"].append({"name": name, "mode": "import",
                                    "source": {"type": "m", "expression": mq}})
        else:
            t["partitions"].append({"name": name, "mode": "import", "source": {
                "type": "m",
                "expression": [
                    f'-- pbixray: no Power Query (M) captured for "{name}"',
                    '-- source path falls back to --database/--schema + table name at convert time',
                ]}})
    for name, items in notes.items():
        tables[name]["annotations"] = [
            {"name": f"SigmaMigration.ExtractNote{i + 1}", "value": text} for i, text in enumerate(items)]

    # Relationships.
    relationships = []
    for i, r in enumerate(relationship_recs):
        ft = _clean(r.get("FromTableName")); fc = _clean(r.get("FromColumnName"))
        tt = _clean(r.get("ToTableName")); tc = _clean(r.get("ToColumnName"))
        if not (ft and fc and tt and tc):
            continue
        xfb_raw = _clean(r.get("CrossFilteringBehavior")).lower()
        xfb = "bothDirections" if xfb_raw in ("both", "2", "bothdirections") else "oneDirection"
        rel = {
            "name": _clean(r.get("Name")) or f"rel_{ft}_{tt}_{i}",
            "fromTable": ft, "fromColumn": fc, "toTable": tt, "toColumn": tc,
            "crossFilteringBehavior": xfb,
            "isActive": _truthy(r.get("IsActive")),
        }
        relationships.append(rel)

    # M parameters -> TMSL shared expressions, as a Fabric model.bim carries
    # them: a NativeQuery that navigates {[Name=<parameter>]} needs its value.
    expressions = []
    for r in parameter_recs:
        name = _clean(r.get("ParameterName"))
        expr = _clean(r.get("Expression"))
        if not (name and expr):
            continue
        entry = {"name": name, "kind": "m", "expression": expr}
        desc = _clean(r.get("Description"))
        if desc:
            entry["description"] = desc
        expressions.append(entry)

    # Row-level security -> TMSL roles. The vendored converter reads
    # model.roles[].tablePermissions[].{name, filterExpression} and reports each
    # as a security[] entry (the skill's RLS gate then fires). Table permissions
    # without a filter (metadata-only) carry no RLS and are dropped.
    roles = {}
    for r in rls_recs:
        role_name, tn = _clean(r.get("RoleName")), _clean(r.get("TableName"))
        fe = _clean(r.get("FilterExpression")).strip()
        if not (role_name and tn and fe):
            continue
        role = roles.get(role_name)
        if role is None:
            role = roles[role_name] = {"name": role_name, "modelPermission": "read", "tablePermissions": []}
            desc = _clean(r.get("RoleDescription"))
            if desc:
                role["description"] = desc
        role["tablePermissions"].append({"name": tn, "filterExpression": fe})

    model = {
        "culture": model_culture,
        "tables": [tables[n] for n in order],
        "relationships": relationships,
    }
    if not culture:
        model["annotations"] = [{"name": CULTURE_ASSUMED_ANNOTATION, "value": culture_note or CULTURE_ASSUMED_TEXT}]
    if expressions:
        model["expressions"] = expressions
    if roles:
        model["roles"] = list(roles.values())
    return {
        "name": model_name,
        "compatibilityLevel": 1600,
        "model": model,
    }


# --- composite / live-connection detection --------------------------------
# A Power BI COMPOSITE report (or one live-connected to a shared dataset) keeps
# references to a REMOTE semantic model. The offline tell is the `.pbix` zip's
# `Connections` member: a JSON doc whose `RemoteArtifacts` lists the shared
# dataset(s) it points at ([{DatasetId, ReportId}, ...]), and/or a `Connections`
# entry whose connection string names a remote PBI model (pbiazure /
# PbiModelDatabaseName). For such reports the Fabric getDefinition of the
# report's BOUND semantic model is INCOMPLETE — it misses the report-local
# measures / calc tables (composite) or isn't resolvable standalone
# (thin-live). The COMPLETE model lives in this local `.pbix`, so we prefer it.
CONNECTIONS_MEMBER = "Connections"


def read_pbix_connections(pbix_path):
    """Parse the `.pbix`'s `Connections` member (JSON) -> dict, or None if the
    file has no such member. stdlib-only (no pbixray)."""
    try:
        with zipfile.ZipFile(pbix_path) as z:
            member = next((n for n in z.namelist()
                           if n.replace("\\", "/") == CONNECTIONS_MEMBER), None)
            if not member:
                return None
            raw = z.read(member)
    except (OSError, zipfile.BadZipFile):
        return None
    for enc in ("utf-8-sig", "utf-8", "utf-16-le", "utf-16"):
        try:
            return json.loads(raw.decode(enc))
        except (UnicodeDecodeError, ValueError):
            continue
    return None


def remote_artifacts(connections):
    """The RemoteArtifacts list ([{DatasetId, ReportId}, ...]) or []."""
    if not isinstance(connections, dict):
        return []
    ra = connections.get("RemoteArtifacts") or connections.get("remoteArtifacts") or []
    return [a for a in ra if isinstance(a, dict)]


_REMOTE_CONN_RE = re.compile(
    r"pbiazure|PbiModelDatabaseName|PbiServiceModelId|PbiModelVirtualServerName"
    r"|Data\s*Source\s*=\s*pbiazure|powerbi://", re.I)


def is_composite_connections(connections):
    """True when the Connections doc shows a COMPOSITE / live-connected model:
    RemoteArtifacts present, or a connection entry that points at a remote PBI
    model (pbiazure / PbiModelDatabaseName / a live-connect ConnectionType)."""
    if not isinstance(connections, dict):
        return False
    if remote_artifacts(connections):
        return True
    for c in (connections.get("Connections") or connections.get("connections") or []):
        if not isinstance(c, dict):
            continue
        blob = " ".join(str(c.get(k, "")) for k in
                        ("ConnectionString", "connectionString", "PbiModelDatabaseName"))
        if _REMOTE_CONN_RE.search(blob):
            return True
        if str(c.get("ConnectionType", c.get("connectionType", ""))).lower() in (
                "pbiservicexmlastyleliveconnect", "analysisservicesdatabaselive",
                "pbiservicelive", "pbidatasetlive"):
            return True
    return False


def pbix_is_composite(pbix_path):
    return is_composite_connections(read_pbix_connections(pbix_path))


def _records(df):
    """DataFrame (pandas or any object exposing to_dict('records')) -> list of
    dicts. None / empty -> []. A plain list is returned as-is (mock convenience)."""
    if df is None:
        return []
    if isinstance(df, list):
        return df
    empty = getattr(df, "empty", None)
    if empty is True:
        return []
    to_dict = getattr(df, "to_dict", None)
    if callable(to_dict):
        try:
            return to_dict("records")
        except TypeError:
            return to_dict(orient="records")
    return list(df)


def _optional_records(pbi, attr):
    """A pbixray DataFrame property, or [] when this pbixray version does not
    expose it (older releases) or reading it fails."""
    try:
        return _records(getattr(pbi, attr, None))
    except Exception:
        return []


_CULTURE_TAG = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")


def detect_culture(pbi):
    """(culture, note). The model's real culture if pbixray exposes it, else (None, why).
    pbixray documents no culture property, so this probes the accessors a version might carry
    (`culture` / `model_culture`; a `cultures` / `tmschema_cultures` table; a `metadata`
    Name/Value table) and NEVER guesses: several candidate cultures with no way to tell the
    model default from a translation also yield None."""
    for attr in ("culture", "model_culture"):
        try:
            v = getattr(pbi, attr, None)
        except Exception:
            v = None
        if isinstance(v, str) and _CULTURE_TAG.match(v.strip()):
            return v.strip(), None
    found = []
    for attr in ("cultures", "tmschema_cultures"):
        for r in _optional_records(pbi, attr):
            name = _clean(r.get("Name") or r.get("name") or r.get("CultureName"))
            if _CULTURE_TAG.match(name) and name not in found:
                found.append(name)
    if len(found) == 1:
        return found[0], None
    if len(found) > 1:
        return None, (CULTURE_ASSUMED_TEXT + f" The .pbix lists several cultures ({', '.join(found)}) "
                      "and the default cannot be told apart.")
    for r in _optional_records(pbi, "metadata"):
        if _clean(r.get("Name") or r.get("name")).lower() in ("culture", "modelculture", "model_culture"):
            v = _clean(r.get("Value") or r.get("value"))
            if _CULTURE_TAG.match(v):
                return v, None
    return None, None


def build_model_from_pbixray(pbi, model_name, dialect="snowflake"):
    """PBIXRay-like object (real pbixray.PBIXRay OR a mock exposing the same
    DataFrame properties) -> TMSL model.bim dict."""
    try:
        table_order = [str(t) for t in list(pbi.tables)]
    except Exception:
        table_order = None
    culture, culture_note = detect_culture(pbi)
    return assemble_tmsl(
        model_name,
        _records(getattr(pbi, "schema", None)),
        _records(getattr(pbi, "dax_measures", None)),
        _records(getattr(pbi, "relationships", None)),
        calc_col_recs=_records(getattr(pbi, "dax_columns", None)),
        calc_table_recs=_records(getattr(pbi, "dax_tables", None)),
        mquery_recs=_records(getattr(pbi, "power_query", None)),
        table_order=table_order,
        parameter_recs=_records(getattr(pbi, "m_parameters", None)),
        column_recs=_optional_records(pbi, "tmschema_columns"),
        hierarchy_recs=_optional_records(pbi, "tmschema_hierarchies"),
        level_recs=_optional_records(pbi, "tmschema_levels"),
        refresh_policy_recs=_optional_records(pbi, "tmschema_refresh_policies"),
        rls_recs=_optional_records(pbi, "rls"),
        dialect=dialect,
        culture=culture,
        culture_note=culture_note,
    )


PBIXRAY_HINT = (
    "pbixray required for local model extraction.\n"
    "Install it (its xpress9/xmhuffman deps ship BROKEN sdists — build from source):\n"
    "  pip install apsw pandas xpress8 \\\n"
    '    "git+https://github.com/Hugoberry/xpress9-python@main" \\\n'
    '    "git+https://github.com/Hugoberry/xmhuffman-cython@main" \\\n'
    "    pbixray\n"
    "See refs/local-pbix.md. The report front door (extract-report-classic.py "
    "--pbix) and the --tmsl Fabric path do NOT need pbixray."
)


def load_pbix(pbix_path, model_name, dialect="snowflake"):
    try:
        from pbixray import PBIXRay  # lazy: only local-model extraction needs it
    except ImportError:
        raise SystemExit("FATAL: " + PBIXRAY_HINT)
    pbi = PBIXRay(pbix_path)
    return build_model_from_pbixray(pbi, model_name, dialect=dialect)


LOSS_NOTE_PREFIXES = ("Enter data:", "Enter-data SQL NOT generated", "Table.FromRows rows could not be decoded")


def extract_warnings(tmsl):
    """Every extraction note that means data or fidelity was lost (Enter-data cells loaded as NULL,
    Enter-data SQL not generated, an assumed model culture), as printable lines. The same notes
    live in the model.bim annotations, where lib/pbi_extract_notes.rb reads them on every route."""
    m = tmsl.get("model", tmsl)
    out = []
    for a in m.get("annotations") or []:
        if a.get("name") == CULTURE_ASSUMED_ANNOTATION:
            out.append(f"model: {a.get('value')}")
    for t in m.get("tables") or []:
        for a in t.get("annotations") or []:
            v = str(a.get("value") or "")
            if str(a.get("name", "")).startswith("SigmaMigration.ExtractNote") and v.startswith(LOSS_NOTE_PREFIXES):
                out.append(f"{t.get('name')}: {v}")
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Extract a local .pbix VertiPaq model into a TMSL model.bim "
                    "(pbixray → the shape migrate-powerbi.rb --tmsl consumes).")
    ap.add_argument("--pbix", required=True, help="local .pbix file")
    ap.add_argument("--out", help="output model.bim path (required unless --detect-composite)")
    ap.add_argument("--name", help="model name (default: .pbix basename)")
    ap.add_argument("--dialect", default="snowflake",
                    help="target warehouse dialect (snowflake | databricks | bigquery | ansi) for the SQL emitted "
                         "for Enter-data tables; migrate-powerbi.rb passes this flag, normalised from its "
                         "--warehouse-type")
    # stdlib-only composite probe (no pbixray): prints
    # {"composite":bool,"remoteArtifacts":[...]} and exits. Used by the
    # orchestrator/Fabric path to decide whether to prefer this local .pbix.
    ap.add_argument("--detect-composite", action="store_true",
                    help="report whether the .pbix is a composite/live-connected model, then exit")
    a = ap.parse_args()
    if a.detect_composite:
        conns = read_pbix_connections(a.pbix)
        print(json.dumps({
            "composite": is_composite_connections(conns),
            "remoteArtifacts": remote_artifacts(conns),
        }))
        return
    if not a.out:
        raise SystemExit("FATAL: --out is required (unless --detect-composite).")
    model_name = a.name or os.path.splitext(os.path.basename(a.pbix))[0]
    tmsl = load_pbix(a.pbix, model_name, a.dialect)
    with open(a.out, "w") as f:
        json.dump(tmsl, f, indent=2)
    m = tmsl["model"]
    ncols = sum(len(t["columns"]) for t in m["tables"])
    nmeas = sum(len(t["measures"]) for t in m["tables"])
    print(f"[pbix-model] '{model_name}': {len(m['tables'])} table(s), {ncols} column(s), "
          f"{nmeas} measure(s), {len(m['relationships'])} relationship(s) -> {a.out}",
          file=sys.stderr)
    for line in extract_warnings(tmsl):
        print(f"[pbix-model] WARNING {line}", file=sys.stderr)


if __name__ == "__main__":
    main()
