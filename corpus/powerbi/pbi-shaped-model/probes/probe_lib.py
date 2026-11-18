#!/usr/bin/env python3
"""Probe harness for the Power BI-shaped model mode.

A probe is a throwaway data model + workbook on sample data, compared with
warehouse SQL truth. Stdlib only; auth/host come from the skill's
scripts/lib/sigma_rest.py. Live calls read PROBE_CONNECTION_ID and
PROBE_FOLDER_ID from the environment (no defaults). Probes call `cleanup` in a
`finally` and write results through `redact(result, redact_terms())`.
"""
import csv
import io
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "..", "plugins", "powerbi-to-sigma", "skills", "powerbi-to-sigma"))
sys.path.insert(0, os.path.join(SKILL, "scripts", "lib"))
import sigma_rest  # noqa: E402
import code_rep  # noqa: E402

SQL_PROBE = os.path.join(SKILL, "scripts", "sigma-sql-probe.py")
REDACTED = "<redacted>"


def _env(name):
    v = os.environ.get(name)
    if not v:
        raise RuntimeError(f"{name} is not set")
    return v


def post_dm(spec):
    """POST /v2/dataModels/spec, then read back GET /v2/dataModels/{id}/spec.
    Returns the readback dict plus `dataModelId` (the response id field)."""
    r = sigma_rest.request("post", "/v2/dataModels/spec", json.dumps(spec).encode())
    dm_id = (r or {}).get("dataModelId")
    if not dm_id:
        raise RuntimeError(f"data model POST returned no dataModelId: {str(r)[:200]}")
    rb = sigma_rest.request("get", f"/v2/dataModels/{dm_id}/spec")
    out = dict(rb) if isinstance(rb, dict) else {"readback": rb}
    out.setdefault("dataModelId", dm_id)
    return out


def post_wb(spec, name="zz probe (scratch)"):
    """POST /v2/workbooks (envelope name/folderId + `contents`), then read back
    with includeContents. `spec` is the bare contents document (or already
    wrapped). Returns the readback plus `workbookId` (the file/inode id)."""
    body = code_rep.create_body(spec, extra={"name": name, "folderId": _env("PROBE_FOLDER_ID")})
    r = sigma_rest.request("post", code_rep.create_path(), json.dumps(body).encode())
    wb_id = (r or {}).get("workbookId")
    if not wb_id:
        raise RuntimeError(f"workbook POST returned no workbookId: {str(r)[:200]}")
    rb = sigma_rest.request("get", code_rep.read_path(wb_id))
    out = dict(rb) if isinstance(rb, dict) else {"readback": rb}
    out.setdefault("workbookId", wb_id)
    return out


_NUM = re.compile(r"-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?")


def _coerce(v):
    """CSV cell -> None / float / str. A leading-zero string ("007") stays a string."""
    if v is None or v == "":
        return None
    return float(v) if _NUM.fullmatch(v) else v


def export_rows(workbook_id, element_id, parameters=None, timeout=300, interval=2.0):
    """Export one element as CSV (POST /v2/workbooks/{id}/export, poll
    GET /v2/query/{queryId}/download) and return rows as dicts. Numeric-looking
    cells become floats, empty cells None."""
    body = {"elementId": element_id, "format": {"type": "csv"}}
    if parameters:
        body["parameters"] = parameters
    r = sigma_rest.request("post", f"/v2/workbooks/{workbook_id}/export", json.dumps(body).encode())
    qid = (r or {}).get("queryId")
    if not qid:
        raise RuntimeError(f"export returned no queryId: {str(r)[:200]}")
    deadline = time.time() + timeout
    while True:
        try:
            raw = sigma_rest.request("get", f"/v2/query/{qid}/download", accept="text/csv")
            if raw:
                break
        except sigma_rest.SigmaError as e:
            if not re.search(r"-> (202|204|404)\b", str(e)):
                raise
        if time.time() > deadline:
            raise RuntimeError(f"export of {element_id} not ready after {timeout}s")
        time.sleep(interval)
    text = raw.decode() if isinstance(raw, (bytes, bytearray)) else str(raw)
    return [{k: _coerce(v) for k, v in row.items()} for row in csv.DictReader(io.StringIO(text))]


def run_sql(sql):
    """Run warehouse SQL through the skill's scripts/sigma-sql-probe.py.

    The probe's own --cleanup wipes the scratch workbook id from its state, so
    it is not used: the state file (a temp path) is read for workbookId and the
    scratch workbook is deleted via cleanup() (DELETE + isArchived readback).
    Raises if the scratch workbook is not confirmed archived."""
    fd, state = tempfile.mkstemp(prefix="probe-sql-state-", suffix=".json")
    os.close(fd)
    os.unlink(state)
    wb_id = None
    try:
        cmd = [sys.executable, "-I", SQL_PROBE, "--connection-id", _env("PROBE_CONNECTION_ID"),
               "--folder-id", _env("PROBE_FOLDER_ID"), "--dialect", "snowflake",
               "--state", state, "--sql", sql]
        # Not a shell: an argv list that runs this skill's sigma-sql-probe.py with this Python (-I). The
        # environment values are its --connection-id / --folder-id option values (live-only probe tooling).
        p = subprocess.run(cmd, capture_output=True, text=True)  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        try:
            with open(state, encoding="utf-8") as fh:
                wb_id = json.load(fh).get("workbookId")
        except (OSError, ValueError):
            pass
        archived = cleanup([wb_id]) if wb_id else {}
    finally:
        try:
            os.unlink(state)
        except OSError:
            pass
    try:
        res = json.loads(p.stdout)
    except ValueError:
        raise RuntimeError(f"sigma-sql-probe gave unparseable output (exit {p.returncode}): "
                           f"{(p.stderr or p.stdout)[:300]}")
    r = res.get("sql", res) if isinstance(res, dict) else res
    if wb_id and not archived.get(wb_id):
        raise RuntimeError(f"scratch workbook {wb_id} was not confirmed archived")
    if not (isinstance(r, dict) and r.get("ok")):
        raise RuntimeError(f"SQL failed: {str(r)[:300]}")
    return r["rows"]


def cleanup(inode_ids):
    """DELETE /v2/files/{id} for each, then GET it back. Returns
    {id: isArchived}. A failed delete/readback yields False, never raises."""
    out = {}
    for iid in inode_ids:
        try:
            sigma_rest.request("delete", f"/v2/files/{iid}")
        except Exception:
            pass
        try:
            r = sigma_rest.request("get", f"/v2/files/{iid}")
            out[iid] = bool(isinstance(r, dict) and r.get("isArchived") is True)
        except Exception:
            out[iid] = False
    return out


def _cli_status():
    try:
        cmd = ["sigma", "auth", "status"]
        if os.environ.get("SIGMA_CLI_PROFILE"):  # the CLI has no env fallback for the profile
            cmd += ["-p", os.environ["SIGMA_CLI_PROFILE"]]
        # Not a shell: an argv list for `sigma auth status`; the profile name is an option value.
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
    except Exception:
        return ""


def redact_terms():
    """Terms to scrub: PROBE_REDACT_TERMS (comma-separated), PROBE_CONNECTION_ID,
    and the org slug from `sigma auth status` (Org URL: https://host/<slug>)."""
    terms = [t.strip() for t in os.environ.get("PROBE_REDACT_TERMS", "").split(",") if t.strip()]
    if os.environ.get("PROBE_CONNECTION_ID"):
        terms.append(os.environ["PROBE_CONNECTION_ID"])
    m = re.search(r"Org URL:\s*https?://[^/\s]+/([^/\s]+)", _cli_status())
    if m:
        terms.append(m.group(1))
    return list(dict.fromkeys(terms))


_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def redact(obj, terms):
    """Recursively replace every term in any string, key or value, and every UUID
    with a stable per-call placeholder (<uuid-1>, <uuid-2>, ...; same UUID, same
    placeholder, compared case-insensitively)."""
    ts = sorted({t for t in terms if t}, key=len, reverse=True)
    seen = {}

    def uid(m):
        return seen.setdefault(m.group(0).lower(), f"<uuid-{len(seen) + 1}>")

    def s(x):
        for t in ts:
            x = x.replace(t, REDACTED)
        return _UUID.sub(uid, x)

    def walk(o):
        if isinstance(o, str):
            return s(o)
        if isinstance(o, dict):
            return {(s(k) if isinstance(k, str) else k): walk(v) for k, v in o.items()}
        if isinstance(o, (list, tuple)):
            return [walk(v) for v in o]
        return o

    return walk(obj)


def _norm(v):
    """Key normalization: 1.0 == 1 == "1"; strings stripped; "007" stays "007"."""
    if isinstance(v, bool) or v is None:
        return str(v)
    if isinstance(v, str):
        v = v.strip()
        if _NUM.fullmatch(v):
            v = float(v)
        else:
            return v
    if isinstance(v, (int, float)):
        return str(int(v)) if float(v).is_integer() else repr(float(v))
    return str(v)


def _key(row, keys):
    return "|".join(_norm(row.get(k)) for k in keys)


def _eq(a, b, tol):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) \
            and not isinstance(a, bool) and not isinstance(b, bool):
        return math.isclose(a, b, rel_tol=tol, abs_tol=tol)
    return a == b


def compare(actual, truth, keys, tol=1e-6):
    """Match rows by normalized `keys`; numeric cells within tol. Returns
    {matched, mismatched:[{key,diffs}], missing:[keys only in truth],
    extra:[keys only in actual], duplicates:{actual:[keys], truth:[keys]}}.
    Duplicate keys are reported (first row wins), never silently collapsed."""
    def idx(rows):
        out, dups = {}, []
        for r in rows:
            k = _key(r, keys)
            if k in out:
                if k not in dups:
                    dups.append(k)
            else:
                out[k] = r
        return out, dups

    (a, adup), (t, tdup) = idx(actual), idx(truth)
    matched, mism = 0, []
    for k, trow in t.items():
        if k not in a:
            continue
        diffs = {c: {"actual": a[k].get(c), "truth": v}
                 for c, v in trow.items() if c not in keys and not _eq(a[k].get(c), v, tol)}
        if diffs:
            mism.append({"key": k, "diffs": diffs})
        else:
            matched += 1
    return {"matched": matched, "mismatched": mism,
            "missing": [k for k in t if k not in a], "extra": [k for k in a if k not in t],
            "duplicates": {"actual": adup, "truth": tdup}}
