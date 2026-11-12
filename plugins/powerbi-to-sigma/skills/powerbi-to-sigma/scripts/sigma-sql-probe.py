#!/usr/bin/env python3
"""sigma-sql-probe.py - run arbitrary SQL through a Sigma connection.

There is no SQL runner in the migration skill: the warehouse is only reachable
through the customer's Sigma connection. This tool turns that connection into
one. Each SQL statement is written into a private scratch workbook as a `sql`
element with ONE JSON column (the whole row packed into a single value so
column names and NULLs survive the CSV round trip), then read back with
POST /v2/workbooks/{id}/export + GET /v2/query/{queryId}/download.

  Snowflake   SELECT OBJECT_CONSTRUCT_KEEP_NULL(*)::VARCHAR AS J FROM (<sql>)
  Databricks  SELECT to_json(struct(*), map('ignoreNullFields','false')) AS J FROM (<sql>)
  BigQuery    SELECT TO_JSON_STRING(t) AS J FROM (<sql>) AS t

Features: batched (several statements per workbook write), resumable (a per-run
state file remembers the scratch workbook and every finished result), retries
5xx / 524 / transport errors, and a BISECT on a batch whose write is rejected
(HTTP 400) so the one bad statement is isolated and Sigma's own error text is
surfaced instead of a whole batch failing opaquely.

Modes
  (default)   rows:    result = {"ok", "rows":[{col: value}], "row_count"}
  --columns   columns: LIMIT 1; result = {"ok", "columns":[output names]}
              (also correct for a zero-row query)
  --types     types:   columns pass, then a type pass (Snowflake SYSTEM$TYPEOF,
              Databricks typeof); result adds "types": {column: warehouse type}

Usage
  python3 scripts/sigma-sql-probe.py --connection-id <id> --folder-id <id> \\
      --in queries.json --out results.json [--columns | --types] \\
      [--dialect snowflake|databricks|bigquery] [--state run/probe-state.json]
  python3 scripts/sigma-sql-probe.py --connection-id ... --folder-id ... --sql "SELECT 1 AS X"

  queries.json = {"<key>": "<sql>", ...}. Exit 0 = every key ok, 1 = some failed,
  2 = usage error.

Auth and host come from the shared lib/sigma_rest.py (browser keychain, Sigma CLI
profile, client credentials). Tokens are never printed or written to the state
file. Pass --base-url to pin the host when ~/.sigma-migration/env names another
org's. The state file and --out can hold warehouse data: both are written 0600.
Python stdlib only.
"""
import argparse
import concurrent.futures as cf
import csv
import hashlib
import io
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))

DIALECTS = ("snowflake", "databricks", "bigquery")
PROBE_ROW_KEY = "__PROBE_ROW__"
RETRYABLE = frozenset({429, 500, 502, 503, 504, 524, 599})  # 599 = transport error / timeout
MODES = ("rows", "columns", "types")
DEFAULT_CACHE_MAX_AGE_HOURS = 24.0


class ProbeError(Exception):
    pass


# --------------------------------------------------------------------------- SQL

def clean_statement(sql):
    s = str(sql).strip()
    while s.endswith(";"):
        s = s[:-1].rstrip()
    return s


def quote_ident(name, dialect):
    if dialect in ("databricks", "bigquery"):
        return "`" + str(name).replace("`", "``") + "`"
    return '"' + str(name).replace('"', '""') + '"'


# The statement goes on its own lines so a trailing `-- comment` cannot swallow
# the closing parenthesis.
def rows_statement(sql, dialect="snowflake"):
    stmt = clean_statement(sql)
    if dialect == "snowflake":
        return f"SELECT OBJECT_CONSTRUCT_KEEP_NULL(*)::VARCHAR AS J FROM (\n{stmt}\n)"
    if dialect == "databricks":
        return f"SELECT to_json(struct(*), map('ignoreNullFields', 'false')) AS J FROM (\n{stmt}\n)"
    if dialect == "bigquery":
        return f"SELECT TO_JSON_STRING(t) AS J FROM (\n{stmt}\n) AS t"
    raise ProbeError(f"unsupported dialect {dialect!r} (want one of {', '.join(DIALECTS)})")


def _first_row_with_marker(stmt, dialect):
    """`SELECT * FROM (<sql>) LIMIT 1` LEFT JOINed onto a one-row marker so a
    query that returns zero rows still reports its column names (as NULLs)."""
    inner = f"(SELECT * FROM (\n{stmt}\n) LIMIT 1) b"
    marker = quote_ident(PROBE_ROW_KEY, dialect)
    return f"(SELECT 1 AS {marker}) d LEFT JOIN {inner} ON TRUE"


def columns_statement(sql, dialect="snowflake"):
    stmt = clean_statement(sql)
    if dialect == "snowflake":
        return (f"SELECT OBJECT_CONSTRUCT_KEEP_NULL(*)::VARCHAR AS J FROM "
                f"{_first_row_with_marker(stmt, dialect)} LIMIT 1")
    if dialect == "databricks":
        return (f"SELECT to_json(struct(*), map('ignoreNullFields', 'false')) AS J FROM "
                f"{_first_row_with_marker(stmt, dialect)} LIMIT 1")
    if dialect == "bigquery":
        # BigQuery cannot enumerate a zero-row struct; a zero-row query yields no names.
        return f"SELECT TO_JSON_STRING(t) AS J FROM (\n{stmt}\n) AS t LIMIT 1"
    raise ProbeError(f"unsupported dialect {dialect!r}")


def types_statement(sql, columns, dialect="snowflake"):
    """One row: {output column: warehouse type}. Needs the column names first."""
    if dialect not in ("snowflake", "databricks"):
        raise ProbeError(f"--types is not supported for dialect {dialect!r} "
                         "(no per-column typeof); use --columns and read types from INFORMATION_SCHEMA")
    stmt = clean_statement(sql)
    fn = "SYSTEM$TYPEOF" if dialect == "snowflake" else "typeof"
    sel = ", ".join(f"{fn}(b.{quote_ident(c, dialect)}) AS {quote_ident(c, dialect)}" for c in columns)
    inner = f"SELECT {sel} FROM {_first_row_with_marker(stmt, dialect)}"
    return rows_statement(inner, dialect)


# ------------------------------------------------------------------------- HTTP

class SigmaHttp:
    """(method, path, body, raw) -> (status, payload) over the shared sigma_rest
    client. Non-2xx statuses are RETURNED (not raised) and 202-vs-200 is kept,
    which the export download poll depends on. Credentials never leave
    sigma_rest; nothing here prints or stores them."""

    def __init__(self, timeout=300):
        self.timeout = timeout

    def call(self, method, path, body=None, raw=False):
        import sigma_rest as sr
        base = sr.base_url()
        sr._validate_once(base)
        url = f"{base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        attempts = 0
        while True:
            attempts += 1
            headers = {"Authorization": f"Bearer {sr.auth_token()}",
                       "Accept": "*/*" if raw else "application/json"}
            if data is not None:
                headers["Content-Type"] = "application/json"
            try:
                resp = sr._send(method.upper(), url, headers, data, self.timeout)
            except (OSError, urllib.error.URLError, TimeoutError) as e:  # SystemExit (bad host) propagates
                return 599, f"{type(e).__name__}: {e}"
            if resp.status == 401 and attempts == 1:
                sr.refresh_token()
                continue
            if raw and 200 <= resp.status < 300:
                return resp.status, resp.body
            text = resp.body.decode(errors="replace")
            try:
                return resp.status, (json.loads(text) if text.strip() else {})
            except ValueError:
                return resp.status, text


def _err_text(payload, limit=3000):
    if isinstance(payload, (bytes, bytearray)):
        payload = payload.decode(errors="replace")
    if isinstance(payload, dict):
        bits = []
        if payload.get("message"):
            bits.append(str(payload["message"]))
        for e in payload.get("errors") or []:
            bits.append(str(e.get("summary") or e.get("message") or e) if isinstance(e, dict) else str(e))
        payload = " | ".join(bits) if bits else json.dumps(payload)
    return str(payload)[:limit]


# ------------------------------------------------------------------------ Probe

def _sql_hash(sql):
    return hashlib.sha256(clean_statement(sql).encode()).hexdigest()[:16]


class Probe:
    def __init__(self, api, connection_id, folder_id, dialect="snowflake", state_path=None,
                 name="zz SQL probe (scratch)", batch=6, workers=5, retries=3, backoff=2.0,
                 poll_interval=1.5, poll_timeout=900, sleep=time.sleep, log=None, workbook_id=None,
                 cache_path=None, use_cache=True, cache_max_age_hours=DEFAULT_CACHE_MAX_AGE_HOURS,
                 now=time.time):
        if dialect not in DIALECTS:
            raise ProbeError(f"unsupported dialect {dialect!r}")
        self.api, self.connection_id, self.folder_id, self.dialect = api, connection_id, folder_id, dialect
        self.state_path, self.name = state_path, name
        # POST /v2/workbooks is NOT idempotent: the scratch workbook gets a name unique to this
        # probe so a create whose response was lost can be found again (and never duplicated).
        self.create_name = f"{name} {uuid.uuid4().hex[:8]}"
        self._create_attempted = False
        self.batch, self.workers, self.retries, self.backoff = max(1, batch), max(1, workers), retries, backoff
        self.poll_interval, self.poll_timeout, self.sleep = poll_interval, poll_timeout, sleep
        self.log = log if log is not None else (lambda m: print(m, file=sys.stderr))
        self.state = self._load_state()
        # Per-statement result cache: survives the scratch workbook (and its state file) being deleted.
        self.cache_path, self.use_cache = cache_path, use_cache
        self.cache_max_age_hours, self.now = cache_max_age_hours, now
        self.cache_times, self._cache_mtime = {}, None
        self.cache = self._load_cache()
        self._keys, self._probed_keys = set(), set()
        if workbook_id:
            self.state.update({"workbookId": workbook_id, "created": False})

    # ---- state
    def _load_state(self):
        if self.state_path and os.path.exists(self.state_path):
            try:
                with open(self.state_path, encoding="utf-8") as fh:
                    st = json.load(fh)
                if isinstance(st, dict):
                    st.setdefault("results", {})
                    return st
            except (OSError, ValueError):
                pass
        return {"version": 1, "workbookId": None, "created": False, "results": {}}

    def _save(self):
        if self.state_path:
            _write_private_json(self.state_path, self.state)

    @property
    def stats(self):
        """{"cached": N, "probed": M} in QUERIES (a statement probed in two passes counts once)."""
        probed = len(self._probed_keys)
        return {"cached": len(self._keys) - probed, "probed": probed}

    # ---- result cache (keyed by sha256(connection + dialect + mode + normalized statement))
    def _cache_key(self, tag, stmt):
        raw = "\0".join((str(self.connection_id), self.dialect, tag, clean_statement(stmt)))
        return hashlib.sha256(raw.encode()).hexdigest()

    def _load_cache(self):
        if self.cache_path and os.path.exists(self.cache_path):
            try:
                with open(self.cache_path, encoding="utf-8") as fh:
                    c = json.load(fh)
                if isinstance(c, dict) and isinstance(c.get("entries"), dict):
                    # Per-entry timestamps live in "times". A pre-timestamp (v1) file has none:
                    # its entries are aged by the file's mtime instead of being dropped.
                    times = c.get("times")
                    self.cache_times = {k: float(v) for k, v in times.items()
                                        if isinstance(v, (int, float))} if isinstance(times, dict) else {}
                    self._cache_mtime = os.stat(self.cache_path).st_mtime
                    return c["entries"]
            except (OSError, ValueError):
                pass
        return {}

    def _save_cache(self):
        if self.cache_path and self.use_cache:
            _write_private_json(self.cache_path, {"version": 2, "entries": self.cache, "times": self.cache_times})

    def _cache_put(self, ckey, result):
        self.cache[ckey] = result
        self.cache_times[ckey] = float(self.now())

    def _cache_fresh(self, ckey):
        """A cached result is reused only while younger than --cache-max-age-hours: a warehouse fix
        (added column, altered view) with unchanged SQL text must eventually be re-probed."""
        if not self.cache_max_age_hours or self.cache_max_age_hours <= 0:
            return False
        t = self.cache_times.get(ckey, self._cache_mtime)
        if t is None:
            return False
        return (self.now() - t) <= self.cache_max_age_hours * 3600

    # ---- low level
    def _call(self, method, path, body=None, raw=False):
        """api() with retry on transient statuses. Returns the last (status, payload)."""
        st, payload = 0, None
        for attempt in range(self.retries + 1):
            st, payload = self.api(method, path, body, raw)
            if st not in RETRYABLE or attempt == self.retries:
                break
            self.sleep(self.backoff * (attempt + 1))
        return st, payload

    def _contents(self, items):
        els, lay = [], []
        for i, (_key, stmt) in enumerate(items):
            eid = f"q{i}"
            els.append({"id": eid, "kind": "table", "name": eid,
                        "source": {"kind": "sql", "connectionId": self.connection_id, "statement": stmt},
                        "columns": [{"id": "j", "formula": "[Custom SQL/J]", "name": "J"}]})
            lay.append(f'  <Element elementId="{eid}" gridColumn="1 / 25" gridRow="{i * 4 + 1} / {i * 4 + 5}"/>')
        layout = ('<?xml version="1.0" encoding="utf-8"?>\n'
                  '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">\n'
                  + "\n".join(lay) + "\n</Page>")
        return {"schemaVersion": 1, "kind": "workbook", "pages": [{"id": "p1", "name": "Probe"}],
                "elements": els, "layout": layout}

    def _write(self, items):
        """Write the items as the workbook contents. Returns (status, payload)."""
        contents = self._contents(items)
        wb = self.state.get("workbookId")
        if wb:
            st, payload = self._call("PUT", f"/v2/workbooks/{wb}/contents", {"contents": contents})
            if st != 404:
                return st, payload
            self.state.update({"workbookId": None, "created": False})  # scratch workbook was deleted
        st, payload = self._create(contents)
        if 200 <= st < 300 and isinstance(payload, dict) and payload.get("workbookId"):
            self.state.update({"workbookId": payload["workbookId"], "created": True})
            self._save()
        return st, payload

    def _find_by_name(self):
        """Ids of the scratch workbooks in the folder named self.create_name, or None when the
        listing itself failed (the caller then cannot tell whether a create landed)."""
        ids, page = [], None
        for _ in range(20):
            q = {"parentId": self.folder_id, "typeFilters": "workbook", "limit": "500"}
            if page:
                q["page"] = page
            st, payload = self._call("GET", "/v2/files?" + urllib.parse.urlencode(q))
            if not 200 <= st < 300 or not isinstance(payload, dict):
                return None
            for e in payload.get("entries") or []:
                if isinstance(e, dict) and e.get("name") == self.create_name:
                    wid = e.get("id") or e.get("workbookId")
                    if wid:
                        ids.append(wid)
            # Live GET /v2/files returns {entries, total, nextPage}; nextPage is the only
            # continuation signal (there is no hasMore field).
            page = payload.get("nextPage")
            if not page:
                break
        return ids

    def _create(self, contents):
        """POST /v2/workbooks WITHOUT blind retry. After a transient failure (5xx / 524 / 599) the
        create may still have landed server-side, so the folder is searched for the unique scratch
        name first: found -> adopt it (never create a second copy of the customer SQL); not found
        -> safe to retry; lookup failed -> stop (cleanup() will search again)."""
        self._create_attempted = True
        body = {"name": self.create_name, "folderId": self.folder_id, "contents": contents}
        self.state["createName"] = self.create_name
        st, payload = 0, None
        for attempt in range(self.retries + 1):
            st, payload = self.api("POST", "/v2/workbooks", body, False)
            if st not in RETRYABLE:
                return st, payload
            found = self._find_by_name()
            if found is None:
                return st, payload
            if found:
                self.log(f"  create answered {st} but the scratch workbook exists; adopting {found[0]}")
                for extra in found[1:]:
                    self._call("DELETE", f"/v2/files/{extra}")
                return 200, {"workbookId": found[0]}
            if attempt == self.retries:
                break
            self.sleep(self.backoff * (attempt + 1))
        return st, payload

    def _export(self, element_id):
        """Export + download one element. A transient server-side 5xx on the download ("Export failed")
        is retried ONCE with a fresh export after a short backoff before it is reported."""
        res = self._export_once(element_id)
        if (not res.get("ok") and res.get("kind") == "query-failed"
                and str(res.get("error", "")).startswith("download 5")):
            self.sleep(self.backoff)
            res = self._export_once(element_id)
        return res

    def _export_once(self, element_id):
        wb = self.state["workbookId"]
        st, r = self._call("POST", f"/v2/workbooks/{wb}/export",
                           {"elementId": element_id, "format": {"type": "csv"}})
        if not 200 <= st < 300 or not isinstance(r, dict) or not r.get("queryId"):
            return {"ok": False, "kind": "export-failed", "error": f"export {st}: {_err_text(r, 800)}"}
        qid = r["queryId"]
        polls = max(1, int(self.poll_timeout / max(self.poll_interval, 0.001)))
        transient = 0
        for _ in range(polls):
            st, b = self.api("GET", f"/v2/query/{qid}/download", None, True)
            if st == 200:
                return _parse_export(b)
            if st in (202, 204, 404):
                self.sleep(self.poll_interval)
                continue
            if st in RETRYABLE and transient < self.retries:
                transient += 1
                self.sleep(self.backoff * transient)
                continue
            return {"ok": False, "kind": "query-failed", "error": f"download {st}: {_err_text(b, 800)}"}
        return {"ok": False, "kind": "timeout", "error": f"export of {element_id} not ready after {self.poll_timeout}s"}

    # ---- batching / bisect
    def _run_group(self, items, out):
        """items = [(key, statement)] -> out[key] = raw export result (CSV parsed)."""
        if not items:
            return
        st, payload = self._write(items)
        if 200 <= st < 300:
            with cf.ThreadPoolExecutor(min(self.workers, len(items))) as ex:
                futs = {ex.submit(self._export, f"q{i}"): k for i, (k, _) in enumerate(items)}
                for f in cf.as_completed(futs):
                    try:
                        out[futs[f]] = f.result()
                    except Exception as e:  # one broken export never aborts the others
                        out[futs[f]] = {"ok": False, "kind": "internal", "error": f"{type(e).__name__}: {e}"}
            return
        if st == 400 and len(items) > 1:
            self.log(f"  batch of {len(items)} rejected (400); bisecting to isolate the bad statement")
            mid = len(items) // 2
            self._run_group(items[:mid], out)
            self._run_group(items[mid:], out)
            return
        kind = "write-rejected" if st == 400 else "write-failed"
        for k, _ in items:
            out[k] = {"ok": False, "kind": kind, "error": f"workbook write {st}: {_err_text(payload)}"}

    def _execute(self, statements, force):
        """statements = {key: (mode_tag, statement, hash)} -> {key: raw result}, cached in state."""
        results = self.state["results"]
        todo = []
        backfilled = False
        for key, (tag, stmt, h) in statements.items():
            ck = f"{tag}:{key}"
            c = results.get(ck)
            if not force and c and c.get("hash") == h and c.get("result", {}).get("ok"):
                # A state hit also lands in the file cache: the orchestrator deletes the
                # scratch workbook (and so this state) after each run, so the NEXT run
                # has only the file cache to go on.
                if self.use_cache:
                    ckey = self._cache_key(tag, stmt)
                    if ckey not in self.cache:
                        self._cache_put(ckey, c["result"])
                        backfilled = True
                continue
            ckey = self._cache_key(tag, stmt)
            hit = self.cache.get(ckey) if (self.use_cache and not force) else None
            if hit and isinstance(hit, dict) and hit.get("ok") and self._cache_fresh(ckey):
                results[ck] = {"hash": h, "result": hit}
                continue
            self._probed_keys.add(key)
            todo.append((ck, stmt, h))
        if backfilled:
            self._save_cache()
        for i in range(0, len(todo), self.batch):
            chunk = todo[i:i + self.batch]
            out = {}
            self._run_group([(ck, stmt) for ck, stmt, _ in chunk], out)
            stmt_by_ck = {ck: stmt for ck, stmt, _ in chunk}
            for ck, _, h in chunk:
                results[ck] = {"hash": h, "result": out.get(ck) or {"ok": False, "kind": "internal", "error": "no result"}}
                if self.use_cache and results[ck]["result"].get("ok"):
                    self._cache_put(self._cache_key(ck.split(":", 1)[0], stmt_by_ck[ck]), results[ck]["result"])
            self._save()
            self._save_cache()
            ok = sum(1 for ck, _, _ in chunk if results[ck]["result"].get("ok"))
            self.log(f"  batch {i // self.batch + 1}/{(len(todo) + self.batch - 1) // self.batch}: {ok}/{len(chunk)} ok")
        return {key: results[f"{tag}:{key}"]["result"] for key, (tag, _, _) in statements.items()}

    # ---- public
    def run(self, queries, mode="rows", force=False):
        if mode not in MODES:
            raise ProbeError(f"unknown mode {mode!r}")
        queries = {str(k): v for k, v in queries.items()}
        self._keys, self._probed_keys = set(queries), set()
        if mode == "rows":
            stm = {k: ("rows", rows_statement(s, self.dialect), _sql_hash(s)) for k, s in queries.items()}
            return {k: _shape_rows(r) for k, r in self._execute(stm, force).items()}
        stm = {k: ("columns", columns_statement(s, self.dialect), _sql_hash(s)) for k, s in queries.items()}
        cols = {k: _shape_columns(r) for k, r in self._execute(stm, force).items()}
        if mode == "columns":
            return cols
        tstm, final = {}, {}
        for k, r in cols.items():
            if not r["ok"] or not r["columns"]:
                final[k] = r if not r["ok"] else {**r, "ok": False, "kind": "no-columns",
                                                  "error": "query returned no column names", "types": {}}
                continue
            tstm[k] = ("types", types_statement(queries[k], r["columns"], self.dialect), _sql_hash(queries[k]))
        for k, r in self._execute(tstm, force).items():
            if not r.get("ok"):
                final[k] = {**r, "columns": cols[k]["columns"]}
                continue
            row = (r.get("rows") or [{}])[0]
            final[k] = {"ok": True, "columns": cols[k]["columns"],
                        "types": {c: row.get(c) for c in cols[k]["columns"]}}
        return {k: final[k] for k in queries}

    def cleanup(self):
        """Delete the scratch workbook, but only one this probe created."""
        wb = self.state.get("workbookId")
        if not wb and self._create_attempted:
            # A create whose outcome was never confirmed: find it by its unique name and delete it.
            found = self._find_by_name() or []
            ok = True
            for wid in found:
                st, payload = self._call("DELETE", f"/v2/files/{wid}")
                if not (200 <= st < 300 or st == 404):
                    self.log(f"  could not delete scratch workbook {wid}: -> {st}: {_err_text(payload, 300)}")
                    ok = False
            return bool(found) and ok
        if not wb or not self.state.get("created"):
            return False
        # DELETE /v2/files/{id} is the delete route (/v2/workbooks/{id} answers 404 and would leak it).
        st, payload = self._call("DELETE", f"/v2/files/{wb}")
        if 200 <= st < 300 or st == 404:  # 404 = already gone
            self.state.update({"workbookId": None, "created": False, "results": {}})
            self._save()
            return True
        self.log(f"  could not delete scratch workbook {wb}: DELETE /v2/files/{wb} -> {st}: {_err_text(payload, 300)}")
        return False


def _parse_export(body):
    try:
        text = body.decode("utf-8", errors="replace") if isinstance(body, (bytes, bytearray)) else str(body)
        rows = list(csv.reader(io.StringIO(text)))
        vals = []
        for r in rows[1:]:
            if r and r[0] != "":
                vals.append(json.loads(r[0]))
            else:
                vals.append(None)
        return {"ok": True, "rows": vals}
    except ValueError as e:
        return {"ok": False, "kind": "unparseable", "error": f"could not parse export: {e}"}


def _shape_rows(r):
    if not r.get("ok"):
        return r
    rows = [x for x in r["rows"] if isinstance(x, dict)]
    return {"ok": True, "rows": rows, "row_count": len(rows)}


def _shape_columns(r):
    if not r.get("ok"):
        return r
    first = next((x for x in r["rows"] if isinstance(x, dict)), None)
    cols = [c for c in (first or {}) if c != PROBE_ROW_KEY]
    out = {"ok": True, "columns": cols}
    if not cols:
        # BigQuery cannot name the columns of a zero-row result through the one-JSON-column export.
        # Callers must treat this as UNVERIFIED, never as "every column is missing".
        out["note"] = "query returned no rows and the dialect cannot name columns of an empty result"
        out["unverified"] = True
    return out


def _write_private_json(path, obj):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".probe-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# -------------------------------------------------------------------------- CLI

def build_parser():
    ap = argparse.ArgumentParser(description="Run SQL through a Sigma connection (scratch workbook + export API).")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--in", dest="inp", help='JSON {"<key>": "<sql>", ...}')
    src.add_argument("--sql", help="a single statement (result key: sql)")
    src.add_argument("--sql-file", help="a file holding a single statement (result key: sql)")
    ap.add_argument("--out", help="results JSON (default: stdout)")
    ap.add_argument("--connection-id", default=os.environ.get("SIGMA_PROBE_CONNECTION_ID"))
    ap.add_argument("--folder-id", default=os.environ.get("SIGMA_PROBE_FOLDER_ID"),
                    help="folder the private scratch workbook is created in")
    ap.add_argument("--dialect", default="snowflake", choices=DIALECTS)
    ap.add_argument("--state", help="state file (scratch workbook id + finished results); default <out>.state.json")
    ap.add_argument("--workbook-id", help="reuse an existing scratch workbook (never deleted by --cleanup)")
    ap.add_argument("--base-url", help="pin SIGMA_BASE_URL for this run")
    ap.add_argument("--name", default="zz SQL probe (scratch)")
    ap.add_argument("--batch", type=int, default=6, help="statements per scratch-workbook write")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--poll-timeout", type=float, default=900, help="seconds to wait for one export")
    ap.add_argument("--force", action="store_true", help="ignore cached results")
    ap.add_argument("--cleanup", action="store_true", help="delete the scratch workbook when done")
    ap.add_argument("--cache", help="per-statement result cache file (default: none)")
    ap.add_argument("--no-cache", action="store_true", help="ignore and do not write the result cache")
    ap.add_argument("--cache-max-age-hours", type=float, default=DEFAULT_CACHE_MAX_AGE_HOURS,
                    help="re-probe cached results older than this (default 24; 0 = never reuse)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--columns", action="store_true", help="LIMIT 1; keys = output column names")
    mode.add_argument("--types", action="store_true", help="columns + SYSTEM$TYPEOF per column")
    return ap


def main(argv=None, api=None, sleep=time.sleep):
    ap = build_parser()
    a = ap.parse_args(argv)
    if not a.connection_id or not a.folder_id:
        ap.error("--connection-id and --folder-id are required (or SIGMA_PROBE_CONNECTION_ID / SIGMA_PROBE_FOLDER_ID)")
    if a.inp:
        with open(a.inp, encoding="utf-8") as fh:
            queries = json.load(fh)
    elif a.sql is not None:
        queries = {"sql": a.sql}
    elif a.sql_file:
        with open(a.sql_file, encoding="utf-8") as fh:
            queries = {"sql": fh.read()}
    else:
        ap.error("give --in, --sql or --sql-file")
    if not isinstance(queries, dict) or not queries:
        ap.error("queries must be a non-empty JSON object {key: sql}")
    if a.base_url:
        os.environ["SIGMA_BASE_URL"] = a.base_url
    state = a.state or ((a.out + ".state.json") if a.out else "sigma-sql-probe-state.json")
    mode = "types" if a.types else "columns" if a.columns else "rows"
    probe = Probe(api or SigmaHttp().call, a.connection_id, a.folder_id, dialect=a.dialect, state_path=state,
                  name=a.name, batch=a.batch, workers=a.workers, retries=a.retries,
                  poll_timeout=a.poll_timeout, sleep=sleep, workbook_id=a.workbook_id,
                  cache_path=a.cache, use_cache=not a.no_cache, cache_max_age_hours=a.cache_max_age_hours)
    results = probe.run(queries, mode=mode, force=a.force)
    if a.out:
        _write_private_json(a.out, results)
    else:
        json.dump(results, sys.stdout, indent=1)
        print()
    if a.cleanup:
        probe.cleanup()
    failed = [k for k, r in results.items() if not r.get("ok")]
    print(f"[sigma-sql-probe] {len(results) - len(failed)}/{len(results)} ok"
          + (f"; failed: {', '.join(failed[:10])}" if failed else ""), file=sys.stderr)
    for k in failed[:5]:
        print(f"[sigma-sql-probe] {k}: {str(results[k].get('error'))[:500]}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
