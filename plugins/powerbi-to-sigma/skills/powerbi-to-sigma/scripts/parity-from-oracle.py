#!/usr/bin/env python3
"""parity-from-oracle.py - value parity between Sigma element exports and warehouse-SQL oracle rows.

Replaces the hand-written comparison scripts. For each chart, compares a Sigma
element export CSV (POST /v2/workbooks/{id}/export, format csv) with the oracle
SQL result rows (build-oracle-sql.rb SQL run through sigma-sql-probe.py) by KEY
columns, then compares each MEASURE cell within a tolerance, classifying every
cell MATCH or DIVERGENT. It then writes parity-final.json in EXACTLY the shape
`phase6-parity-pbi.rb --finalize` produces, which `assert-phase6-ran.rb` reads
(status, mode, charts_total, charts_pass, pass_names, fail_names, ...).

Per chart:
  keys      dimension columns that identify a row: "Sigma Header=ORACLE_COL" or "Name"
            (a bare name is looked up on both sides; lookup is exact, then case-
            insensitive, then punctuation-insensitive). No keys = a KPI (one row).
  measures  same syntax; default = every non-key column present on both sides.
  Key values are canonicalised before joining: 2026 == "2026", ISO datetimes at
  midnight == the day, "January 2026" == 2026-01, blank == "(Blank)" == null.
  A month-label vs first-of-month mismatch retries at month grain (noted).

Cell rules: both blank = MATCH; numbers match when |a-b| <= max(abs_tol,
rel_tol*max(|a|,|b|)); Sigma exports may be formatted ("$1,234.50", "(12.30)",
"12.5%": percent strings also match a fraction oracle); anything else compares as
trimmed text. A key only in the oracle is DIVERGENT (missing-in-sigma). A key only
in Sigma is ignored when all its measures are blank (an empty bucket the SQL
join dropped), otherwise DIVERGENT (extra-in-sigma; --ignore-extra-sigma to allow).
Duplicate keys on either side are reported, never summed.

Inputs
  --spec plan.json   {"charts":[{"name","export","oracle","oracle_key"?,"keys":[..],
                      "measures":[..]?, "rel_tol"?, "abs_tol"?}]}  (paths relative to the spec)
  or one chart: --name N --export sigma.csv --oracle rows.json|rows.csv --keys A=B,C [--measures ..]
  Oracle files: a JSON list of row objects, {"rows": [...]}, a sigma-sql-probe results
  file (pick the entry with --oracle-key / "oracle_key"), or a CSV with a header.

Outputs (in --out-dir)
  parity-final.json          the phase-6 sentinel (keys in phase6-parity-pbi.rb order;
                             source "warehouse-sql-oracle"; STALE is never produced here)
  parity-oracle-detail.json  per chart: counts, per-measure stats, divergent cells
                             (first 200; every cell with --all-cells), issues, notes

Exit: 0 all charts MATCH, 2 any DIVERGENT (like phase6-parity-pbi.rb), 3 usage/input error.
Tolerances: --rel-tol (default 1e-4) and --abs-tol (default 0.005, i.e. a 2-decimal display);
--extract-mode [--extract-tol 0.02] loosens rel-tol for stale extracts and records mode "extract".
Python stdlib only.
"""
import argparse
import csv
import io
import json
import math
import os
import re
import sys
import tempfile
import time

DEFAULT_REL_TOL = 1e-4
DEFAULT_ABS_TOL = 0.005
MAX_DIVERGENT_LISTED = 200
SCHEMA = "parity-from-oracle/v1"

MONTH_NUM = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12, "jan": 1, "feb": 2, "mar": 3, "apr": 4,
    "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
}
# What a CELL that is text counts as blank. The literal words 'None' / 'null' / 'nan' are REAL members
# (a Discount Tier of 'None' next to genuine NULLs): they are text, not blanks. A real NULL arrives as
# Python None (JSON null) or a float NaN, or as an empty CSV cell.
_BLANK_WORDS = {"", "(blank)"}


class ParityError(Exception):
    pass


# ------------------------------------------------------------------- value rules

def is_blank(v):
    if v is None:
        return True
    if isinstance(v, float) and math.isnan(v):
        return True
    return isinstance(v, str) and v.strip().lower() in _BLANK_WORDS


_NUM_RE = re.compile(r"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?")
_THOUSANDS_RE = re.compile(r"[+-]?\d{1,3}(,\d{3})+(\.\d+)?")


def parse_number_ex(x):
    """-> (value, was_percent) or (None, False). Bools are not numbers here."""
    if x is None or isinstance(x, bool):
        return None, False
    if isinstance(x, (int, float)):
        return (None, False) if (isinstance(x, float) and math.isnan(x)) else (float(x), False)
    s = str(x).strip()
    if not s:
        return None, False
    neg = False
    if s.startswith("(") and s.endswith(")"):
        neg, s = True, s[1:-1].strip()
    pct = s.endswith("%")
    if pct:
        s = s[:-1].strip()
    s = re.sub(r"[$€£]", "", s).strip()
    if _THOUSANDS_RE.fullmatch(s):
        s = s.replace(",", "")
    if not _NUM_RE.fullmatch(s):
        return None, False
    v = float(s)
    v = -v if neg else v
    return (v / 100.0 if pct else v), pct


def parse_number(x):
    return parse_number_ex(x)[0]


def _num_key(f):
    if f == int(f) and abs(f) < 1e15:
        return str(int(f))
    return format(f, ".12g")


def canonical_key(v):
    """Canonical text of a dimension value so equivalent buckets join across representations."""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return "" if (isinstance(v, float) and math.isnan(v)) else _num_key(float(v))
    s = str(v).strip()
    low = s.lower()
    if low in _BLANK_WORDS:
        return ""
    if low in ("true", "false"):
        return low
    if re.fullmatch(r"-?\d+(\.\d+)?", s):
        return _num_key(float(s))
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})[T ]00:00:00(?:\.0+)?(?:Z|[+-]\d{2}:?\d{2})?", s)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        return s
    m = re.fullmatch(r"([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})", s)
    if m and m.group(1).lower() in MONTH_NUM:
        return "%s-%02d-%02d" % (m.group(3), MONTH_NUM[m.group(1).lower()], int(m.group(2)))
    m = re.fullmatch(r"([A-Za-z]+)\s+(\d{4})", s)
    if m and m.group(1).lower() in MONTH_NUM:
        return "%s-%02d" % (m.group(2), MONTH_NUM[m.group(1).lower()])
    m = re.fullmatch(r"(\d{4})\s+Q([1-4])", s, re.I)
    if m:
        return "%s-%02d-01" % (m.group(1), (int(m.group(2)) - 1) * 3 + 1)
    return s


def _is_month(k):
    return bool(re.fullmatch(r"\d{4}-\d{2}", k))


def _is_day(k):
    return bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", k))


def compare_cell(sv, ov, rel_tol, abs_tol, blank_is_zero=False):
    """-> (status, kind, delta, sigma_value, oracle_value)."""
    sb, ob = is_blank(sv), is_blank(ov)
    if sb and ob:
        return "MATCH", None, None, None, None
    if sb or ob:
        other = ov if sb else sv
        if blank_is_zero and parse_number(other) == 0.0:
            return "MATCH", None, None, None, None
        return "DIVERGENT", "blank-mismatch", None, (None if sb else _display(sv)), (None if ob else _display(ov))
    sn, spct = parse_number_ex(sv)
    on = parse_number(ov)
    if sn is not None and on is not None:
        cands = [sn] + ([sn * 100.0] if spct else [])
        best = None
        for c in cands:
            d = abs(c - on)
            if d <= max(abs_tol, rel_tol * max(abs(c), abs(on))):
                return "MATCH", None, None, None, None
            best = d if best is None else min(best, d)
        return "DIVERGENT", "value-mismatch", best, sn, on
    same_bucket = canonical_key(sv) == canonical_key(ov) and canonical_key(sv) != ""
    if same_bucket or str(sv).strip() == str(ov).strip():
        return "MATCH", None, None, None, None
    return "DIVERGENT", "value-mismatch", None, _display(sv), _display(ov)


def _display(v):
    n = parse_number(v)
    return n if n is not None else v


# ------------------------------------------------------------------- table input

class Table:
    def __init__(self, header, rows):
        self.header, self.rows = header, rows


def read_csv_rows(text):
    if text.startswith("﻿"):
        text = text[1:]
    rows = list(csv.reader(io.StringIO(text)))
    if not rows:
        raise ParityError("export CSV is empty (no header)")
    return Table(rows[0], rows[1:])


def load_oracle_rows(text, path, oracle_key=None):
    """Oracle rows (list of dicts) from JSON (list / {"rows"} / probe results) or CSV."""
    if str(path).lower().endswith(".csv"):
        if text.startswith("﻿"):
            text = text[1:]
        return [dict(r) for r in csv.DictReader(io.StringIO(text))]
    try:
        data = json.loads(text)
    except ValueError as e:
        raise ParityError(f"{path}: not valid JSON ({e})")
    if isinstance(data, dict) and oracle_key is not None:
        if oracle_key not in data:
            raise ParityError(f"{path}: no entry {oracle_key!r}")
        data = data[oracle_key]
    elif isinstance(data, dict) and "rows" not in data:
        probes = {k: v for k, v in data.items() if isinstance(v, dict) and ("rows" in v or "ok" in v)}
        if len(probes) == 1 and len(data) == 1:
            data = next(iter(probes.values()))
        else:
            raise ParityError(f"{path}: holds {len(data)} entries; choose one with --oracle-key / \"oracle_key\"")
    if isinstance(data, dict):
        if data.get("ok") is False:
            raise ParityError(f"oracle query failed: {str(data.get('error'))[:300]}")
        data = data.get("rows")
    if not isinstance(data, list) or any(not isinstance(r, dict) for r in data):
        raise ParityError(f"{path}: oracle rows must be a list of objects (column -> value)")
    return data


# --------------------------------------------------------------------- comparison

def _norm_name(s):
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


def _resolve(names, wanted):
    """Index of `wanted` in names: exact, then case-insensitive, then punctuation-insensitive."""
    for test in (lambda n: n == wanted, lambda n: str(n).lower() == str(wanted).lower(),
                 lambda n: _norm_name(n) == _norm_name(wanted) and _norm_name(wanted) != ""):
        for i, n in enumerate(names):
            if test(n):
                return i
    return None


def parse_col_spec(spec):
    if isinstance(spec, dict):
        s = spec.get("sigma") or spec.get("name")
        return s, spec.get("oracle") or s
    text = str(spec)
    if "=" in text:
        a, b = text.split("=", 1)
        return a.strip(), b.strip()
    return text.strip(), text.strip()


def _empty_result(name):
    return {"chart": name, "classification": "MATCH", "rows_oracle": 0, "rows_sigma": 0, "cells_total": 0,
            "cells_match": 0, "cells_divergent": 0, "missing_in_sigma": 0, "extra_in_sigma": 0,
            "extra_empty_ignored": 0, "extra_ignored": 0, "measures": {}, "divergent_cells": [],
            "issues": [], "notes": []}


def compare_chart(name, sigma, oracle_rows, keys, measures=None, rel_tol=DEFAULT_REL_TOL, abs_tol=DEFAULT_ABS_TOL,
                  ignore_extra_sigma=False, blank_is_zero=False, all_cells=False, ci_keys=False):
    res = _empty_result(name)
    if all_cells:
        res["cells"] = []
    if not sigma.rows and not oracle_rows:
        # Nothing on either side: nothing was compared, so this must not read as a pass. An oracle
        # filter that wrongly returns 0 rows next to a header-only export looks exactly like this.
        res["issues"].append({"kind": "empty-both", "detail": "zero rows on both the Sigma export and the oracle: "
                                                              "nothing was compared (empty-both, unverified)"})
        res["classification"] = "DIVERGENT"
        res["unverified"] = True
        return res
    oracle_cols = []
    for r in oracle_rows:
        for c in r:
            if c not in oracle_cols:
                oracle_cols.append(c)
    key_specs = [parse_col_spec(k) for k in keys]
    key_idx, key_ocols = [], []
    for s, o in key_specs:
        si, oi = _resolve(sigma.header, s), _resolve(oracle_cols, o)
        if si is None:
            res["issues"].append({"kind": "column-not-found", "side": "sigma", "column": s, "role": "key"})
        if oi is None:
            res["issues"].append({"kind": "column-not-found", "side": "oracle", "column": o, "role": "key"})
        key_idx.append(si)
        key_ocols.append(oracle_cols[oi] if oi is not None else None)
    if measures:
        mspecs = [parse_col_spec(m) for m in measures]
    else:
        used = {c for c in key_ocols if c is not None}
        mspecs = [(sigma.header[_resolve(sigma.header, c)], c) for c in oracle_cols
                  if c not in used and _resolve(sigma.header, c) is not None]
    m_idx, m_ocols, m_names = [], [], []
    for s, o in mspecs:
        si, oi = _resolve(sigma.header, s), _resolve(oracle_cols, o)
        if si is None:
            res["issues"].append({"kind": "column-not-found", "side": "sigma", "column": s, "role": "measure"})
        if oi is None:
            res["issues"].append({"kind": "column-not-found", "side": "oracle", "column": o, "role": "measure"})
        m_idx.append(si)
        m_ocols.append(oracle_cols[oi] if oi is not None else None)
        m_names.append(s)
    if not m_names and not res["issues"]:
        res["issues"].append({"kind": "no-measures", "detail": "no measure columns to compare"})
    if res["issues"]:
        res["classification"] = "DIVERGENT"
        return res

    def canon(v):
        k = canonical_key(v)
        return k.lower() if ci_keys else k

    s_keys = [[canon(r[i]) if i < len(r) else "" for i in key_idx] for r in sigma.rows]
    o_keys = [[canon(r.get(c)) for c in key_ocols] for r in oracle_rows]
    for j in range(len(key_specs)):
        s_col, o_col = [k[j] for k in s_keys], [k[j] for k in o_keys]
        if ((any(map(_is_month, s_col)) and any(map(_is_day, o_col)))
                or (any(map(_is_day, s_col)) and any(map(_is_month, o_col)))):
            for ks in (s_keys, o_keys):
                for k in ks:
                    if _is_day(k[j]):
                        k[j] = k[j][:7]
            res["notes"].append(f"key '{key_specs[j][0]}' matched at month grain (label vs first-of-month representation)")

    def index(keys_list, rows, side):
        out, dups = {}, []
        for k, row in zip(keys_list, rows):
            t = tuple(k)
            if t in out:
                dups.append(list(t))
            else:
                out[t] = row
        if dups:
            res["issues"].append({"kind": "duplicate-keys", "side": side, "count": len(dups), "examples": dups[:5]})
        return out

    s_map = index(s_keys, sigma.rows, "sigma")
    o_map = index(o_keys, oracle_rows, "oracle")
    res["rows_sigma"], res["rows_oracle"] = len(sigma.rows), len(oracle_rows)
    stats = {m: {"match": 0, "divergent": 0, "max_abs_delta": 0.0} for m in m_names}

    def record(key, m, status, kind, delta, sv, ov):
        res["cells_total"] += 1
        stats[m]["match" if status == "MATCH" else "divergent"] += 1
        if delta is not None:
            stats[m]["max_abs_delta"] = max(stats[m]["max_abs_delta"], delta)
        if status == "MATCH":
            res["cells_match"] += 1
        else:
            res["cells_divergent"] += 1
        cell = {"key": list(key), "measure": m, "status": status}
        if status != "MATCH":
            cell.update(kind=kind, sigma=sv, oracle=ov)
            if delta is not None:
                cell["delta"] = delta
            if len(res["divergent_cells"]) < MAX_DIVERGENT_LISTED:
                res["divergent_cells"].append(cell)
        if all_cells:
            res["cells"].append(cell)

    def cell(row, i):
        return row[i] if i < len(row) else None

    for key, orow in o_map.items():
        srow = s_map.get(key)
        if srow is None:
            res["missing_in_sigma"] += 1
            for m, oc in zip(m_names, m_ocols):
                record(key, m, "DIVERGENT", "missing-in-sigma", None, None, orow.get(oc))
            continue
        for m, si, oc in zip(m_names, m_idx, m_ocols):
            st, kind, delta, sv, ov = compare_cell(cell(srow, si), orow.get(oc), rel_tol, abs_tol, blank_is_zero)
            if st == "MATCH" and not all_cells:
                res["cells_total"] += 1
                res["cells_match"] += 1
                stats[m]["match"] += 1
            else:
                record(key, m, st, kind, delta, sv, ov)
    for key, srow in s_map.items():
        if key in o_map:
            continue
        if all(is_blank(cell(srow, i)) for i in m_idx):
            res["extra_empty_ignored"] += 1
            continue
        if ignore_extra_sigma:
            res["extra_ignored"] += 1
            continue
        res["extra_in_sigma"] += 1
        for m, si in zip(m_names, m_idx):
            record(key, m, "DIVERGENT", "extra-in-sigma", None, cell(srow, si), None)
    res["measures"] = stats
    if res["cells_divergent"] or res["issues"]:
        res["classification"] = "DIVERGENT"
    return res


# --------------------------------------------------------------------- orchestration

def _read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def run_chart(cfg, base_dir, defaults):
    name = cfg["name"]

    def p(x):
        return x if os.path.isabs(x) else os.path.join(base_dir, x)

    try:
        sigma = read_csv_rows(_read_text(p(cfg["export"])))
        oracle = load_oracle_rows(_read_text(p(cfg["oracle"])), cfg["oracle"], cfg.get("oracle_key"))
    except (OSError, ParityError) as e:
        r = _empty_result(name)
        r["classification"] = "DIVERGENT"
        r["issues"].append({"kind": "input-error", "detail": str(e)[:400]})
        return r
    return compare_chart(
        name, sigma, oracle, keys=cfg.get("keys") or [], measures=cfg.get("measures") or None,
        rel_tol=cfg.get("rel_tol", defaults["rel_tol"]), abs_tol=cfg.get("abs_tol", defaults["abs_tol"]),
        ignore_extra_sigma=defaults["ignore_extra_sigma"], blank_is_zero=defaults["blank_is_zero"],
        all_cells=defaults["all_cells"], ci_keys=defaults["ci_keys"])


def build_final(results, workbook_id, mode):
    """The parity-final.json document, key order identical to phase6-parity-pbi.rb --finalize."""
    passed = [r["chart"] for r in results if r["classification"] == "MATCH"]
    failed = [r["chart"] for r in results if r["classification"] != "MATCH"]
    total = len(results)
    return {
        "workbook_id": workbook_id,
        "ran_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "warehouse-sql-oracle",
        "mode": mode,
        "source_timezone": None,
        "charts_total": total,
        "charts_pass": len(passed),
        "charts_fail": len(failed),
        "charts_stale_explained": 0,
        "charts_verified": len(passed),
        "pass_names": passed,
        "stale_explained_names": [],
        "fail_names": failed,
        "classifications": {r["chart"]: r["classification"] for r in results},
        "freshness": None,
        "status": "PASS" if total and len(passed) == total else "FAIL",
    }


def _die(msg):
    print(f"[parity-from-oracle] {msg}", file=sys.stderr)
    sys.exit(3)


def _write_private_json(path, obj):
    """parity-final.json / parity-oracle-detail.json hold customer warehouse cell values: 0600
    (same pattern as sigma-sql-probe.py's writer)."""
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".parity-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(description="Sigma export vs oracle SQL rows -> parity-final.json")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--workbook-id")
    ap.add_argument("--spec")
    ap.add_argument("--name")
    ap.add_argument("--export")
    ap.add_argument("--oracle")
    ap.add_argument("--oracle-key")
    ap.add_argument("--keys", default="", help="comma list of 'Sigma=ORACLE' or 'Name'")
    ap.add_argument("--measures", default="")
    ap.add_argument("--rel-tol", type=float, default=DEFAULT_REL_TOL)
    ap.add_argument("--abs-tol", type=float, default=DEFAULT_ABS_TOL)
    ap.add_argument("--extract-mode", action="store_true")
    ap.add_argument("--extract-tol", type=float, default=0.02)
    ap.add_argument("--ignore-extra-sigma", action="store_true")
    ap.add_argument("--blank-zero", action="store_true", help="a blank cell equals 0")
    ap.add_argument("--ci-keys", action="store_true", help="compare key text case-insensitively")
    ap.add_argument("--all-cells", action="store_true", help="list every cell, not just divergent ones")
    a = ap.parse_args(argv)

    defaults = {"rel_tol": a.extract_tol if a.extract_mode else a.rel_tol, "abs_tol": a.abs_tol,
                "ignore_extra_sigma": a.ignore_extra_sigma, "blank_is_zero": a.blank_zero,
                "all_cells": a.all_cells, "ci_keys": a.ci_keys}
    if a.spec:
        try:
            spec = json.loads(_read_text(a.spec))
        except (OSError, ValueError) as e:
            _die(f"cannot read --spec: {e}")
        charts = spec.get("charts") if isinstance(spec, dict) else spec
        base_dir = os.path.dirname(os.path.abspath(a.spec))
    elif a.name and a.export and a.oracle:
        split = lambda s: [x.strip() for x in s.split(",") if x.strip()]  # noqa: E731
        charts = [{"name": a.name, "export": a.export, "oracle": a.oracle, "oracle_key": a.oracle_key,
                   "keys": split(a.keys), "measures": split(a.measures)}]
        base_dir = os.getcwd()
    else:
        _die("give --spec, or --name + --export + --oracle")
    if not isinstance(charts, list) or not charts:
        _die("the plan has no charts")
    for c in charts:
        if not isinstance(c, dict) or not all(c.get(k) for k in ("name", "export", "oracle")):
            _die("every chart needs name, export and oracle")

    results = [run_chart(c, base_dir, defaults) for c in charts]
    mode = "extract" if a.extract_mode else "strict"
    final = build_final(results, a.workbook_id, mode)
    os.makedirs(a.out_dir, exist_ok=True)
    _write_private_json(os.path.join(a.out_dir, "parity-final.json"), final)
    detail = {"schema": SCHEMA, "mode": mode,
              "tolerance": {"rel": defaults["rel_tol"], "abs": defaults["abs_tol"]}, "charts": results}
    _write_private_json(os.path.join(a.out_dir, "parity-oracle-detail.json"), detail)
    for r in results:
        tag = "PASS    " if r["classification"] == "MATCH" else ("UNVERIF " if r.get("unverified") else "DIVERGE ")
        print(f"{tag}[{mode}] {r['chart']}  ({r['cells_match']}/{r['cells_total']} cells; "
              f"missing {r['missing_in_sigma']}, extra {r['extra_in_sigma']}, issues {len(r['issues'])})")
        for c in r["divergent_cells"][:3]:
            print(f"    {c['key']} {c['measure']}: sigma={c.get('sigma')!r} oracle={c.get('oracle')!r} ({c['kind']})")
        for i in r["issues"][:3]:
            print(f"    issue: {i}")
    print(f"[parity-from-oracle] wrote parity-final.json (status={final['status']} "
          f"{final['charts_pass']} match / {final['charts_fail']} divergent of {final['charts_total']})",
          file=sys.stderr)
    return 0 if final["status"] == "PASS" else 2


if __name__ == "__main__":
    sys.exit(main())
