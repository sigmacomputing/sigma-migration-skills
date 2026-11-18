#!/usr/bin/env python3
"""Verify the published pbi-shaped-model items against Power BI and Snowflake.

Live-only (never run by checks.sh). For every model in the manifest (the main models and the RLS
model), checks:

  (a) the latest refresh reached Completed (with --since, a refresh that started at or after that time);
  (b) every measure returns a non-blank value through executeQueries;
  (c) for every visual of every report on the model, a DAX SUMMARIZECOLUMNS over the visual's
      grouping columns and measures (with the report-wide filter and each page's saved slicer
      selections applied, as a render would) returns at least one row and, for each measure, at
      least one non-blank value; a slicer's column returns distinct values;
  (d) five measures equal warehouse SQL from a read-only `snow sql` connection: Sales Amount, Units,
      Sales by Ship Date (by month), Sales YTD (As Of), Open PO Units. A model is compared on the
      ones it holds.

Rendering is NOT covered: the export API is disabled on this trial capacity and a browser cannot be
used, so a formatting problem that a DAX query cannot see would be missed.

Reads the generated model.bim and report definition from --dir (placeholder or real coordinates;
only names are read), finds the published items by display name, and writes a redacted JSON:
no ids, host, account or database name.

    python3 verify_pbi.py --workspace Test --dir <build_reports out dir> \
        --snow-connection <conn> --database <db> [--schema S] [--out ../live/pbi-verify.json]
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from refresh_pick import pick_refresh  # noqa: E402

SKILL_SCRIPTS = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "..", "plugins", "powerbi-to-sigma", "skills", "powerbi-to-sigma", "scripts"))
PBI = "https://api.powerbi.com/v1.0/myorg"
REL_TOL = 1e-6
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

FIVE = ["Sales Amount", "Units", "Sales by Ship Date", "Sales YTD (As Of)", "Open PO Units"]


# ----------------------------------------------------------------------------- DAX building (pure)
def q(name):
    return "'" + name.replace("'", "''") + "'"


def col_ref(entity, prop):
    return f"{q(entity)}[{prop}]"


def dax_str(v):
    return '"' + str(v).replace('"', '""') + '"'


def parse_projection(p):
    f = p["field"]
    if "Column" in f:
        c = f["Column"]
        return "column", c["Expression"]["SourceRef"]["Entity"], c["Property"]
    m = f["Measure"]
    return "measure", m["Expression"]["SourceRef"]["Entity"], m["Property"]


def filter_tables(filters):
    """[{table, column, mode, values}] -> DAX filter-table expressions."""
    out = []
    for f in filters:
        ref = col_ref(f["table"], f["column"])
        vals = "{" + ", ".join(dax_str(v) for v in f["values"]) + "}"
        if f["mode"] == "exclude":
            out.append(f"FILTER(ALL({ref}), NOT({ref} IN {vals}))")
        else:
            out.append(f"TREATAS({vals}, {ref})")
    return out


def visual_query(visual, filters):
    """-> (dax, kind, n_measures). `visual` is a visual.json dict."""
    v = visual["visual"]
    projs = [parse_projection(p) for blk in v["query"]["queryState"].values() for p in blk["projections"]]
    cols = [col_ref(e, p) for k, e, p in projs if k == "column"]
    meas = [col_ref(e, p) for k, e, p in projs if k == "measure"]
    if v["visualType"] == "slicer":
        return f"EVALUATE DISTINCT({cols[0]})", "slicer", 0
    parts = list(cols) + filter_tables(filters) + [f'"m{i}", {m}' for i, m in enumerate(meas)]
    return "EVALUATE SUMMARIZECOLUMNS(" + ", ".join(parts) + ")", "measures", len(meas)


def saved_selections(page_visuals):
    """Saved slicer selections on a page -> [{table, column, mode:'include', values}]."""
    out = []
    for vj in page_visuals:
        v = vj["visual"]
        if v["visualType"] != "slicer":
            continue
        for g in v.get("objects", {}).get("general", []):
            flt = (g.get("properties", {}).get("filter") or {}).get("filter")
            if not flt:
                continue
            ent = flt["From"][0]["Entity"]
            cond = flt["Where"][0]["Condition"]["In"]
            prop = cond["Expressions"][0]["Column"]["Property"]
            vals = [row[0]["Literal"]["Value"].strip("'").replace("''", "'") for row in cond["Values"]]
            out.append({"table": ent, "column": prop, "mode": "include", "values": vals})
    return out


def report_filters(report_json):
    out = []
    for f in (report_json.get("filterConfig") or {}).get("filters", []):
        flt = f["filter"]
        ent = flt["From"][0]["Entity"]
        cond = flt["Where"][0]["Condition"]
        exclude = "Not" in cond
        inner = cond["Not"]["Expression"]["In"] if exclude else cond["In"]
        prop = inner["Expressions"][0]["Column"]["Property"]
        vals = [row[0]["Literal"]["Value"].strip("'").replace("''", "'") for row in inner["Values"]]
        out.append({"table": ent, "column": prop, "mode": "exclude" if exclude else "include", "values": vals})
    return out


def blank(x):
    return x is None or x == ""


def analyse(rows, n_measures, kind):
    """-> dict(rows, nonblank_by_measure, ok, why)"""
    if not rows:
        return {"rows": 0, "ok": False, "why": "no rows"}
    if kind == "slicer":
        return {"rows": len(rows), "ok": True}
    nb = []
    for i in range(n_measures):
        key = f"[m{i}]"
        nb.append(sum(1 for r in rows if not blank(r.get(key))))
    ok = all(n > 0 for n in nb)
    res = {"rows": len(rows), "nonblank_by_measure": nb, "ok": ok}
    if not ok:
        res["why"] = "a measure is blank in every row"
    return res


def rel_equal(a, b):
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) <= REL_TOL * max(1.0, abs(a), abs(b))


# ----------------------------------------------------------------------------- truth SQL
def truth_sql(schema):
    s = "{db}." + schema
    return {
        "Sales Amount": f"select sum(quantity * unit_price * (1 - discount)) v from {s}.FACT_SALES",
        "Units": f"select sum(quantity) v from {s}.FACT_SALES",
        "Sales by Ship Date": (
            f"select to_char(date_trunc('month', d.cal_date), 'YYYY-MM') k, "
            f"sum(f.quantity * f.unit_price * (1 - f.discount)) v from {s}.FACT_SALES f "
            f"join {s}.DIM_DATE d on d.date_key = f.ship_date_key group by 1 order by 1"),
        "Sales YTD (As Of)": (
            f"select sum(f.quantity * f.unit_price * (1 - f.discount)) v from {s}.FACT_SALES f, {s}.AS_OF a "
            f"where f.order_date_key between to_number(to_char(date_trunc('year', a.as_of_date), 'YYYYMMDD')) "
            f"and to_number(to_char(a.as_of_date, 'YYYYMMDD'))"),
        "Open PO Units": f"select sum(ordered_units - received_units) v from {s}.FACT_PURCHASE_ORDER where status = 'Open'"}


def snow_rows(conn, sql):
    r = subprocess.run(["snow", "sql", "-c", conn, "--format", "json", "-q", sql], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("snow sql failed: " + (r.stderr or r.stdout)[:300])
    data = json.loads(r.stdout)
    if data and isinstance(data[0], list):
        data = data[0]
    return [{k.lower(): v for k, v in row.items()} for row in data]


def fnum(v):
    return None if v is None else float(v)


# ----------------------------------------------------------------------------- Power BI access
class Pbi:
    def __init__(self):
        sys.path.insert(0, SKILL_SCRIPTS)
        import pbi_fabric as pf
        import requests
        self.pf, self.requests = pf, requests

    def hdr(self):
        tok = self.pf.get_token(self.pf.POWERBI_SCOPE, interactive=False)
        if not tok:
            sys.exit("no cached Power BI token: sign in once with the skill's pbi_fabric.py first")
        return {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}

    def get(self, path):
        r = self.requests.get(PBI + path, headers=self.hdr())
        r.raise_for_status()
        return r.json()

    def execute(self, ws, ds, dax, retries=3):
        body = {"queries": [{"query": dax}], "serializerSettings": {"includeNulls": True}}
        for i in range(retries):
            r = self.requests.post(f"{PBI}/groups/{ws}/datasets/{ds}/executeQueries", headers=self.hdr(),
                                   data=json.dumps(body), timeout=300)
            if r.status_code == 429:
                time.sleep(min(float(r.headers.get("Retry-After", "20")), 60))
                continue
            try:
                j = r.json()
            except ValueError:
                return None, f"HTTP {r.status_code}: {r.text[:200]}"
            if r.status_code != 200:
                return None, f"HTTP {r.status_code}: {json.dumps(j)[:300]}"
            res = j["results"][0]
            if res.get("error"):
                return None, json.dumps(res["error"])[:300]
            return res["tables"][0].get("rows", []), None
        return None, "throttled"


def load_json(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as f:
        return json.load(f)


def visuals_by_page(report_dir):
    pages_dir = os.path.join(report_dir, "definition", "pages")
    order = load_json(pages_dir, "pages.json")["pageOrder"]
    out = []
    for pid in order:
        page = load_json(pages_dir, pid, "page.json")
        vdir = os.path.join(pages_dir, pid, "visuals")
        vis = [load_json(vdir, v, "visual.json") for v in sorted(os.listdir(vdir))]
        out.append((page["displayName"], vis))
    return out


def scrub(obj, secrets):
    s = json.dumps(obj)
    s = UUID.sub("<id>", s)
    for sec in secrets:
        if sec:
            s = s.replace(sec, "<redacted>")
    return json.loads(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--dir", required=True, help="build_reports.py output dir")
    ap.add_argument("--snow-connection", required=True, help="read-only snow CLI connection")
    ap.add_argument("--database", required=True, help="Snowflake database holding the schema (never written out)")
    ap.add_argument("--schema", default="ZZ_CLAUDE_PBI_SHAPED")
    ap.add_argument("--host", default="", help="optional, only used to scrub the output")
    ap.add_argument("--since", default=None, help="ISO UTC time (the publish run's refreshSince): only a refresh "
                    "that started at or after it counts for check (a)")
    ap.add_argument("--state", default=None, help="fabric_publish.py's state file: per-model refresh request "
                    "time and RequestId are read from it (preferred over --since)")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "live", "pbi-verify.json"))
    a = ap.parse_args()

    st = load_json(a.state) if a.state else {}
    st_since, st_rid = st.get("refreshSince", {}), st.get("refreshRequestIds", {})
    pbi = Pbi()
    ws = next(g for g in pbi.get("/groups")["value"] if g["name"] == a.workspace)["id"]
    datasets = {d["name"]: d["id"] for d in pbi.get(f"/groups/{ws}/datasets")["value"]}
    manifest = load_json(a.dir, "manifest.json")
    sqls = truth_sql(a.schema)
    out = {"generated": datetime.date.today().isoformat(), "schema": a.schema,
           "rendering": ("not performed: the export API is disabled on this trial capacity and a browser "
                         "cannot be used; formatting problems a DAX query cannot see are not covered"),
           "tolerance_relative": REL_TOL, "models": {}}
    failures = 0

    for m in manifest["models"]:
        ds = datasets[m["displayName"]]
        bim = load_json(a.dir, m["slug"], "model.bim")
        rec = {"displayName": m["displayName"]}
        lr = pick_refresh(pbi.get(f"/groups/{ws}/datasets/{ds}/refreshes?$top=10")["value"],
                          st_since.get(m["slug"], a.since), st_rid.get(m["slug"]))
        dur = None
        if lr.get("startTime") and lr.get("endTime"):
            f = "%Y-%m-%dT%H:%M:%S"
            dur = (datetime.datetime.strptime(lr["endTime"][:19], f) -
                   datetime.datetime.strptime(lr["startTime"][:19], f)).total_seconds()
        rec["refresh"] = {"status": lr.get("status", "none"), "type": lr.get("refreshType"), "durationSeconds": dur,
                          "ok": lr.get("status") == "Completed"}
        # (b) every measure
        mres = []
        for t in bim["model"]["tables"]:
            for me in t.get("measures", []):
                rows, err = pbi.execute(ws, ds, f'EVALUATE ROW("v", {col_ref(t["name"], me["name"])})')
                val = rows[0].get("[v]") if rows else None
                mres.append({"measure": me["name"], "table": t["name"], "value": val, "error": err,
                             "ok": err is None and not blank(val)})
        rec["measures"] = {"checked": len(mres), "nonblank": sum(r["ok"] for r in mres), "results": mres}
        # (c) visuals
        vres = {}
        for r in [r for r in manifest["reports"] if r["model"] == m["displayName"]]:
            rdir = os.path.join(a.dir, r["slug"])
            rfilters = report_filters(load_json(rdir, "definition", "report.json"))
            for page_name, vis in visuals_by_page(rdir):
                sel = saved_selections(vis)
                for vj in vis:
                    own_sel = [s for s in sel if vj["visual"]["visualType"] != "slicer"]
                    dax, kind, nm = visual_query(vj, rfilters + own_sel)
                    t0 = time.time()
                    rows, err = pbi.execute(ws, ds, dax)
                    res = analyse(rows or [], nm, kind) if err is None else {"rows": 0, "ok": False, "why": err}
                    res.update({"type": vj["visual"]["visualType"], "seconds": round(time.time() - t0, 1)})
                    vres[f"{r['displayName']} / {page_name} / {vj['name']}"] = res
        rec["visuals"] = {"checked": len(vres), "ok": sum(v["ok"] for v in vres.values()), "results": vres}
        # (d) truth
        truth = []
        names = {me["name"] for t in bim["model"]["tables"] for me in t.get("measures", [])}
        for name in [n for n in FIVE if n in names]:
            sql = sqls[name].replace("{db}", a.database)
            home = next(t["name"] for t in bim["model"]["tables"] for me in t.get("measures", []) if me["name"] == name)
            ref = col_ref(home, name)
            tr = snow_rows(a.snow_connection, sql)
            if name == "Sales by Ship Date":
                rows, err = pbi.execute(ws, ds, f'EVALUATE SUMMARIZECOLUMNS({col_ref("Date", "Month Start")}, "m", {ref})')
                got = {}
                for rw in rows or []:
                    k = (rw.get("Date[Month Start]") or "")[:7]
                    if k:
                        got[k] = fnum(rw.get("[m]"))
                want = {r["k"]: fnum(r["v"]) for r in tr}
                bad = [k for k in sorted(set(got) | set(want)) if not rel_equal(got.get(k), want.get(k))]
                truth.append({"measure": name, "grain": "month", "months_compared": len(want),
                              "months_mismatched": len(bad), "first_bad": bad[:3], "error": err,
                              "ok": err is None and bool(want) and not bad})
            else:
                rows, err = pbi.execute(ws, ds, f'EVALUATE ROW("v", {ref})')
                got = fnum(rows[0].get("[v]")) if rows else None
                want = fnum(tr[0]["v"])
                truth.append({"measure": name, "power_bi": got, "warehouse": want, "error": err,
                              "ok": err is None and got is not None and rel_equal(got, want)})
        rec["warehouse_truth"] = truth
        rec["ok"] = (rec["refresh"]["ok"] and rec["measures"]["nonblank"] == rec["measures"]["checked"]
                     and rec["visuals"]["ok"] == rec["visuals"]["checked"] and all(t["ok"] for t in truth))
        failures += 0 if rec["ok"] else 1
        out["models"][m["slug"]] = rec
        print(f"{m['slug']}: refresh={rec['refresh']['status']} measures={rec['measures']['nonblank']}/"
              f"{rec['measures']['checked']} visuals={rec['visuals']['ok']}/{rec['visuals']['checked']} "
              f"truth={sum(t['ok'] for t in truth)}/{len(truth)}", flush=True)

    out["all_ok"] = failures == 0
    out = scrub(out, [a.database, a.host, a.snow_connection])
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    print("wrote", os.path.relpath(a.out), "all_ok" if failures == 0 else f"{failures} model(s) failing")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
