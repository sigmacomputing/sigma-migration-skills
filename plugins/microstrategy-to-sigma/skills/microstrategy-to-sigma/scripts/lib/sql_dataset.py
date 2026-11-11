"""Freeform ("hand-written") SQL dataset helpers for the MicroStrategy converter.

A MicroStrategy report authored as Freeform SQL has no schema objects behind it
(`/model/reports/{id}` has no attribute/metric units), so it cannot go through
extract.py's semantic-model path. This module captures such a report as an
`mstr-sql-dataset/1` record — the SQL text plus the MicroStrategy objects it maps
to — and offers the pure helpers the converter needs:

  capture(session, report_id, allow_execute)  REST capture (no query execution by default)
  select_aliases(sql)                         output column names of the final SELECT
  match_columns(aliases, objects)             SQL alias <-> MicroStrategy object by name
  guard_sql(statement, label)                 read-only single-statement guard

Contract + status: refs/sql-datasets.md. Endpoint response shapes are UNVERIFIED
against a live MicroStrategy server: every lookup here is tolerant of missing keys
and the raw responses are stored on the record.
"""
import re
from datetime import datetime, timezone

FORMAT_ID = "mstr-sql-dataset/1"

# ------------------------------------------------------------------ SQL guard


def guard_sql(statement, label):
    """Validate one read-only SELECT/CTE statement; return it without a trailing `;`.

    `label` names the input in messages (a CLI flag such as ``--multi-fact-sql``,
    or a description such as ``SQL for dataset 'X'``). Raises SystemExit with the
    message, the same way convert.py always has.
    """
    statement = (statement or "").strip()
    if statement.endswith(";"):
        statement = statement[:-1].rstrip()
    if not statement:
        raise SystemExit(f"{label} is empty")
    if ";" in statement:
        raise SystemExit(
            f"{label} must contain one SELECT/CTE statement; "
            "multi-step or volatile-table plans are not accepted"
        )
    if not re.match(r"(?is)^(select|with)\b", statement):
        raise SystemExit(f"{label} must start with SELECT or WITH")
    forbidden = re.search(
        r"(?is)\b(create\s+(?:or\s+replace\s+)?(?:volatile|temp(?:orary)?)"
        r"|drop\s+table|insert\s+into|update\s+|delete\s+from|merge\s+into)\b",
        statement)
    if forbidden:
        raise SystemExit(
            f"{label} must be a read-only single query; found "
            f"{forbidden.group(1)!r}"
        )
    unresolved = re.search(r"\{\{|\}\}|\$\{|\%\([^)]+\)s", statement)
    if unresolved:
        raise SystemExit(
            f"{label} still contains an unresolved placeholder. "
            "Resolve prompts/security substitutions from a live report "
            "instance before conversion."
        )
    return statement


def strip_leading_comments(sql):
    """Drop `--` / `/* */` comments (and whitespace) before the first token, so a
    hand-written statement that opens with a header comment passes guard_sql.
    Comments after the first token are left alone."""
    s = sql or ""
    while True:
        s = s.lstrip()
        if s.startswith("--"):
            nl = s.find("\n")
            s = "" if nl < 0 else s[nl + 1:]
        elif s.startswith("/*"):
            end = s.find("*/")
            s = "" if end < 0 else s[end + 2:]
        else:
            return s


# ------------------------------------------------------------- select list parse
_WORD_RE = re.compile(r"[A-Za-z0-9_$#@\u0080-￿]+")
# Words that can end a select item without being its alias.
_NOT_ALIAS = {"end", "null", "true", "false", "asc", "desc", "distinct", "all"}
# Depth-0 keywords that end the select list.
_LIST_END = {"from", "where", "group", "having", "order", "union", "intersect",
             "except", "minus", "limit", "into", "offset", "fetch", "window"}


def _tokenize(sql):
    """Comment-free tokens: (kind, text, depth). kind in word|qid|str|op.

    Quoted identifiers ("x", [x], `x`) keep their unquoted text; strings keep
    their raw body. `(` is reported at the depth outside it, `)` likewise.
    """
    toks, i, n, depth = [], 0, len(sql), 0
    while i < n:
        c = sql[i]
        if c.isspace():
            i += 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j + 1
        elif sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c in "'\"`[":
            close = {"'": "'", '"': '"', "`": "`", "[": "]"}[c]
            j, buf = i + 1, []
            while j < n:
                if sql[j] == close:
                    if j + 1 < n and sql[j + 1] == close:  # doubled quote = escaped quote
                        buf.append(close)
                        j += 2
                        continue
                    break
                buf.append(sql[j])
                j += 1
            toks.append(("str" if c == "'" else "qid", "".join(buf), depth))
            i = j + 1
        elif c == "(":
            toks.append(("op", "(", depth))
            depth += 1
            i += 1
        elif c == ")":
            depth = max(depth - 1, 0)
            toks.append(("op", ")", depth))
            i += 1
        else:
            m = _WORD_RE.match(sql, i)
            if m:
                toks.append(("word", m.group(0), depth))
                i = m.end()
            else:
                toks.append(("op", c, depth))
                i += 1
    return toks


def _is_word(tok, *names):
    return tok[0] == "word" and tok[1].lower() in names


def _item_alias(item):
    """Output name of one select-list item (tokens at any depth), or None."""
    if not item:
        return None
    # `<expr> AS alias` — the last depth-0 AS
    as_at = [k for k, t in enumerate(item) if t[2] == 0 and _is_word(t, "as")]
    if as_at:
        k = as_at[-1]
        if k + 1 < len(item) and item[k + 1][0] in ("word", "qid", "str"):
            return item[k + 1][1]
        return None
    last = item[-1]
    if last[0] == "op" and last[1] == "*":              # `*` / `t.*`
        return None
    # bare column reference: ident (. ident)*
    if all((k % 2 == 0 and t[0] in ("word", "qid")) or (k % 2 == 1 and t[:2] == ("op", "."))
           for k, t in enumerate(item)) and len(item) % 2 == 1:
        if last[0] == "word" and last[1].lower() in _NOT_ALIAS:
            return None
        return last[1]
    # `<expr> alias` — trailing identifier after an expression, no AS
    if len(item) >= 2 and last[0] in ("word", "qid") and last[2] == 0:
        prev = item[-2]
        if last[0] == "word" and last[1].lower() in _NOT_ALIAS:
            return None
        if prev[0] in ("word", "qid", "str") or prev[:2] == ("op", ")"):
            return last[1]
    return None


def select_aliases(sql):
    """Output column names of the statement's final top-level SELECT, or None.

    None means "not derivable": no SELECT found, a `*` item, or an item that has
    no alias and is not a plain column reference.
    """
    toks = _tokenize(sql or "")
    start = next((k for k, t in enumerate(toks) if t[2] == 0 and _is_word(t, "select")), None)
    if start is None:
        return None
    k = start + 1
    while k < len(toks) and toks[k][2] == 0 and _is_word(toks[k], "distinct", "all"):
        k += 1
    if k < len(toks) and toks[k][2] == 0 and _is_word(toks[k], "top"):
        k += 1
        if k < len(toks) and toks[k][:2] == ("op", "("):          # TOP (n)
            depth0 = toks[k][2]
            k += 1
            while k < len(toks) and not (toks[k][:2] == ("op", ")") and toks[k][2] == depth0):
                k += 1
            k += 1
        else:                                                      # TOP n
            k += 1
        if k < len(toks) and _is_word(toks[k], "percent"):
            k += 1
        if k + 1 < len(toks) and _is_word(toks[k], "with") and _is_word(toks[k + 1], "ties"):
            k += 2
    items, cur = [], []
    while k < len(toks):
        t = toks[k]
        if t[2] == 0 and t[0] == "word" and t[1].lower() in _LIST_END:
            break
        if t[2] == 0 and t[:2] == ("op", ","):
            items.append(cur)
            cur = []
        else:
            cur.append(t)
        k += 1
    items.append(cur)
    aliases = []
    for item in items:
        a = _item_alias(item)
        if not a:
            return None
        aliases.append(a)
    return aliases or None


# ------------------------------------------------------------------ name matching
_NORM_RE = re.compile(r"[\s_\-]+")


def _norm(s):
    return _NORM_RE.sub("", str(s)).casefold()


def _candidates(obj, objects):
    """Normalized alias names an object may carry, best first."""
    name = obj.get("name") or ""
    if obj.get("kind") != "attribute":
        return [_norm(name)]
    form = obj.get("form")
    forms = [o for o in objects if o.get("kind") == "attribute"
             and (o.get("id"), o.get("name")) == (obj.get("id"), name)]
    out = []
    if not form or str(form).upper() == "DESC" or len(forms) == 1:
        out.append(_norm(name))                       # bare attribute name
    if form:
        out.append(_norm(f"{name} {form}"))           # "<attr> <form>" == "<attr>_<form>"
    return list(dict.fromkeys(out))


def match_columns(aliases, objects):
    """Map SQL output aliases to MicroStrategy objects by normalized name.

    Returns ``(mapping, unmatched_objects, unused_aliases)`` where mapping is
    ``{alias: object}``. Names compare casefolded with spaces/underscores/hyphens
    dropped. Ambiguity (several aliases for one object, or several objects for
    one alias) leaves the involved objects unmatched and the aliases unused.
    """
    norm_aliases = {}
    for a in aliases:
        norm_aliases.setdefault(_norm(a), []).append(a)
    claims = {}                       # alias -> [object index]
    obj_alias = {}                    # object index -> alias
    for i, obj in enumerate(objects):
        for cand in _candidates(obj, objects):
            hits = norm_aliases.get(cand, [])
            if len(hits) == 1:
                obj_alias[i] = hits[0]
                claims.setdefault(hits[0], []).append(i)
                break
            if len(hits) > 1:         # ambiguous alias spelling -> unmatched
                break
    mapping, taken = {}, set()
    for alias in aliases:             # SQL order
        idx = claims.get(alias, [])
        if len(idx) == 1:
            mapping[alias] = objects[idx[0]]
            taken.add(idx[0])
    unmatched = [o for i, o in enumerate(objects) if i not in taken]
    unused = [a for a in aliases if a not in mapping]
    return mapping, unmatched, unused


def utc_now():
    return datetime.now(timezone.utc).isoformat()


# ------------------------------------------------------------------ REST capture
# Every shape below is UNVERIFIED against a live server (refs/sql-datasets.md):
# lookups tolerate missing keys and the raw responses ride along on the record.


def _find_key(node, key):
    """First non-empty string value stored under `key` anywhere in a JSON tree."""
    if isinstance(node, dict):
        v = node.get(key)
        if isinstance(v, str) and v.strip():
            return v
        for child in node.values():
            found = _find_key(child, key)
            if found:
                return found
    elif isinstance(node, list):
        for child in node:
            found = _find_key(child, key)
            if found:
                return found
    return None


def _dtype(node):
    t = node.get("dataType")
    if isinstance(t, dict):
        t = t.get("type")
    return t


def _attribute_objects(attr):
    forms = [f for f in (attr.get("forms") or []) if isinstance(f, dict)]
    if not forms:
        return [{"kind": "attribute", "id": attr.get("id"), "name": attr.get("name"),
                 "form": None, "dataType": _dtype(attr)}]
    return [{"kind": "attribute", "id": attr.get("id"), "name": attr.get("name"),
             "form": f.get("name"), "dataType": _dtype(f) or _dtype(attr)} for f in forms]


def _metric_object(m):
    return {"kind": "metric", "id": m.get("id"), "name": m.get("name"), "dataType": _dtype(m)}


def _objects_from_definition(definition):
    """One entry per attribute form and per metric from `availableObjects`,
    else from the grid's rows/columns/page-by."""
    d = definition.get("definition") if isinstance(definition.get("definition"), dict) else definition
    avail = d.get("availableObjects")
    out = []
    if isinstance(avail, dict) and (avail.get("attributes") or avail.get("metrics")):
        for a in avail.get("attributes") or []:
            if isinstance(a, dict):
                out.extend(_attribute_objects(a))
        for m in avail.get("metrics") or []:
            if isinstance(m, dict):
                out.append(_metric_object(m))
    else:
        grid = d.get("grid") or {}
        for axis in ("rows", "columns", "pageBy"):
            for el in grid.get(axis) or []:
                if not isinstance(el, dict):
                    continue
                kind = str(el.get("type") or "").lower()
                if kind == "attribute":
                    out.extend(_attribute_objects(el))
                elif kind == "metric":
                    out.append(_metric_object(el))
                elif kind in ("templatemetrics", "metrics"):
                    out.extend(_metric_object(m) for m in el.get("elements") or [] if isinstance(m, dict))
    seen, unique = set(), []
    for o in out:
        key = (o["kind"], o["id"], o.get("form"), o["name"])
        if key not in seen:
            seen.add(key)
            unique.append(o)
    return unique


def _normalize_prompts(raw):
    items = raw.get("prompts") if isinstance(raw, dict) else raw
    out = []
    for p in items or []:
        if not isinstance(p, dict):
            continue
        answer = next((p[k] for k in ("answers", "answer", "defaultAnswer") if k in p), None)
        out.append({"id": p.get("id") or p.get("key"), "name": p.get("name") or p.get("title"),
                    "type": p.get("type"), "answer": answer})
    return out


def capture(session, report_id, allow_execute=False):
    """Capture a Freeform-SQL report as an ``mstr-sql-dataset/1`` record.

    The SQL is read WITHOUT running the query when possible
    (``POST /model/reports/{id}/instances?executionStage=resolve_prompts``).
    Executing the report against the warehouse (``POST /v2/reports/{id}/instances``,
    then ``.../sqlView``) happens only when ``allow_execute`` is true AND the first
    route produced no SQL. Raises RuntimeError when no SQL could be obtained.
    """
    warnings = []
    try:
        definition = session.get(f"/v2/reports/{report_id}")
    except Exception as e:  # noqa: BLE001 — tolerate; the SQL is the load-bearing part
        definition = None
        warnings.append(f"report definition unavailable ({e}); objects not captured")
    definition = definition if isinstance(definition, dict) else {}
    name = definition.get("name") or (definition.get("definition") or {}).get("name") or report_id
    objects = _objects_from_definition(definition)

    prompts_raw, prompts_err = None, []
    for path in (f"/v2/reports/{report_id}/prompts", f"/reports/{report_id}/prompts"):
        try:
            prompts_raw = session.get(path)
            break
        except Exception as e:  # noqa: BLE001
            prompts_err.append(str(e))
    if prompts_raw is None:
        warnings.append("prompts unavailable from both prompts endpoints "
                        f"({'; '.join(prompts_err)}); any prompt answers baked into the SQL are unknown")
    prompts = _normalize_prompts(prompts_raw)

    sql_response, sql, source, resolve_err = None, None, None, None
    try:
        sql_response = session.post(
            f"/model/reports/{report_id}/instances?executionStage=resolve_prompts")
        sql = _find_key(sql_response, "sqlStatement")
        source = "resolve_prompts"
    except Exception as e:  # noqa: BLE001
        resolve_err = str(e)
    if not sql and allow_execute:
        inst = session.post(f"/v2/reports/{report_id}/instances?limit=1")
        # instanceId only: a bare `id` anywhere in the response may be an object id
        instance_id = _find_key(inst, "instanceId")
        if not instance_id:
            raise RuntimeError(f"report {report_id}: instance creation returned no instance id")
        sql_response = session.get(f"/v2/reports/{report_id}/instances/{instance_id}/sqlView")
        sql = _find_key(sql_response, "sqlStatement")
        source = "sqlView"
    if not sql:
        why = f" (resolve_prompts failed: {resolve_err})" if resolve_err else ""
        raise RuntimeError(
            f"report {report_id}: no SQL available without executing the report{why}. "
            "Re-run with --allow-execute (runs the report against the warehouse once) "
            "or supply the SQL by hand in the dataset record.")
    return {
        "format": FORMAT_ID,
        "reportId": report_id,
        "name": name,
        "provenance": {"sqlSource": source, "retrievedAtUtc": utc_now()},
        "sql": sql,
        "objects": objects,
        "prompts": prompts,
        "columnMap": None,
        "warnings": warnings,
        "raw": {"definition": definition or None, "prompts": prompts_raw, "sqlResponse": sql_response},
    }
