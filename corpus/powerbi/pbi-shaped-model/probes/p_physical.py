#!/usr/bin/env python3
"""Physical-layer probes P9, P10, P11, timing baseline and the key-uniqueness check
for the Power BI-shaped model mode.

  P9      three data model pages (Sales, Inventory, Shared) with relationships across pages
  P10     materialization schedules on a warehouse-table element and on a child element,
          run once, poll, compare a chart over the child with SQL
  P11     a flattened child (`Sales (flattened)`) with Lookup-chain calc columns in folders
          `Store` and `Product`, optionally materialized
  Timing  export round-trip wall clock of one chart (Sales by Category through the three-hop
          path), live vs materialized, three cache-busted samples each
  Key     `SELECT COUNT(*) - COUNT(DISTINCT key)` through probe_lib.run_sql (the Sigma connection)

Everything created is deleted in a `finally` (schedules first, then the files) and verified
archived. Results are written redacted.

Run: python3 -I corpus/powerbi/pbi-shaped-model/probes/p_physical.py [P9 P10 P11 TIMING KEY]
Needs PROBE_CONNECTION_ID, PROBE_FOLDER_ID, PROBE_DB, PROBE_SCHEMA (env only).
"""
import json
import os
import re
import statistics
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe_lib as P  # noqa: E402
from probe_shapes import (env, rel, SALES_COLS, col, dm_src, layout_xml, truth, lower_keys,  # noqa: E402
                          verdict, differs, REV_SQL, snow)
from p_metrics import (dims, base_el, child_el, wh2, bar, wb_doc, check, readback_el, cols_of,  # noqa: E402
                       Run, err)

PFX = "zz Claude probe – physical "
REV_F = "Sum([{e}/Quantity] * [{e}/Unit Price] * (1 - [{e}/Discount]))"
CRON, TZ = "0 6 * * *", "America/New_York"
MAT_CAP_S = 24 * 60  # hard cap for all concurrent materializations together


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sreq(method, path, body=None):
    return P.sigma_rest.request(method, path, json.dumps(body).encode() if body is not None else None)


# ---------------------------------------------------------------- run tracking
class PRun(Run):
    """Run plus materialization schedule tracking: schedules are deleted before the files."""

    def __init__(self):
        super().__init__()
        self.schedules = []  # (dm_id, element_id)
        self.schedule_cleanup = {}

    def dm_pages(self, tag, pages):
        try:
            doc = {"name": PFX + tag, "schemaVersion": 1, "folderId": env("PROBE_FOLDER_ID"),
                   "pages": [{"id": pid, "name": nm, "elements": els} for pid, nm, els in pages]}
            rb = P.post_dm(doc)
            self.created.append(rb["dataModelId"])
            return rb, None
        except Exception as e:
            return None, err(e)

    def schedule(self, dm_id, element_id):
        """POST the schedule (the form materialization_schedules.rb uses). Returns (response|None, error|None)."""
        try:
            r = sreq("post", f"/v2/dataModels/{dm_id}/elements/{element_id}/materializationSchedules",
                     {"schedule": {"cronSpec": CRON, "timezone": TZ}})
            self.schedules.append((dm_id, element_id))
            return r, None
        except Exception as e:
            return None, err(e)

    def delete_schedules(self):
        for dm_id, el in self.schedules:
            try:
                sreq("delete", f"/v2/dataModels/{dm_id}/elements/{el}/materializationSchedules")
                left = P.sigma_rest.request("get", f"/v2/dataModels/{dm_id}/materializationSchedules")
                still = [e for e in (left or {}).get("entries", []) if e.get("elementId") == el]
                self.schedule_cleanup[f"{dm_id}/{el}"] = not still
            except Exception as e:
                self.schedule_cleanup[f"{dm_id}/{el}"] = f"error: {err(e)[:200]}"


def write_targets():
    """(database, schema) pairs of the connection's writebacks (where Sigma materializes), read at run time."""
    r = P.sigma_rest.request("get", "/v2/connections/" + env("PROBE_CONNECTION_ID"))
    return [(w["database"], w["schema"]) for w in (r or {}).get("writebacks", []) if w.get("database")]


def wh_tables_since(since_utc):
    """Warehouse tables created at/after `since_utc` in the probe database and in the connection's write
    schema(s) (read-only; database and schema names are replaced by roles so no env value is recorded)."""
    out = []
    places = [("probe_schema", env("PROBE_DB"), env("PROBE_SCHEMA"))]
    try:
        places += [("write_schema", d, sc) for d, sc in write_targets()]
    except Exception as e:
        out.append({"error": f"connection writebacks: {err(e)[:200]}"})
    for role, db, sc in places:
        try:
            rows = snow(f"SELECT TABLE_NAME, TABLE_TYPE, ROW_COUNT, CREATED FROM {db}.INFORMATION_SCHEMA.TABLES "
                        f"WHERE TABLE_SCHEMA = '{sc}' AND CREATED >= '{since_utc}'::TIMESTAMP_TZ ORDER BY CREATED")
            out += [{"where": role, "table": r["table_name"], "type": r["table_type"], "rows": r["row_count"],
                     "created": str(r["created"])} for r in rows]
        except Exception as e:
            out.append({"where": role, "error": err(e)[:200]})
    return out


# ----------------------------------------------------------- materialization
TERMINAL = ("ready", "succeeded", "complete", "completed", "failed", "error", "cancelled", "canceled", "skipped")


def materialize_all(targets, cap_s=MAT_CAP_S):
    """For every target {label, dm_id, sheet_id}: POST /v2/dataModels/{id}:materialize {sheetId}, retrying
    while it answers 'already in progress' (creating a schedule starts a first run of its own), then poll
    GET /v2/dataModels/{id}/materializations/{materializationId} until a terminal status or the cap.
    Targets are served round-robin, so several elements materialize concurrently. Mutates and returns
    {label: record} with every state seen."""
    t0 = time.time()
    recs = {t["label"]: {"sheet_id": t["sheet_id"], "dm_id": t["dm_id"], "schedule_created_utc": t.get("created_utc"),
                         "trigger_in_progress_rounds": 0, "states_seen": []} for t in targets}
    pending = {t["label"]: t for t in targets}
    while pending and time.time() - t0 < cap_s:
        for label, t in list(pending.items()):
            rec = recs[label]
            if "materialization_id" not in rec:
                try:
                    r = sreq("post", f"/v2/dataModels/{t['dm_id']}:materialize", {"sheetId": t["sheet_id"]})
                    rec["materialization_id"] = (r or {}).get("materializationId")
                    rec["materialize_response"] = r
                    rec["manual_trigger_accepted_after_s"] = round(time.time() - t0)
                    rec["manual_trigger_accepted_utc"] = utc()
                except Exception as e:
                    msg = err(e)
                    if "already in progress" in msg:
                        rec["trigger_in_progress_rounds"] += 1
                        rec["last_trigger_error"] = msg[:200]
                        continue
                    rec["trigger_error"] = msg[:300]
                    del pending[label]
                    continue
            g = P.sigma_rest.request("get", f"/v2/dataModels/{t['dm_id']}/materializations/{rec['materialization_id']}")
            st = (g or {}).get("status")
            if not rec["states_seen"] or rec["states_seen"][-1]["status"] != st:
                rec["states_seen"].append({"t_s": round(time.time() - t0), "status": st, "raw": g})
            if str(st).lower() in TERMINAL:
                rec["final_status"] = st
                del pending[label]
        if pending:
            time.sleep(10)
    for label in pending:
        recs[label]["final_status"] = "NOT_FINISHED_WITHIN_CAP"
    for rec in recs.values():
        rec["elapsed_total_s"] = round(time.time() - t0)
    return recs


def schedule_readback(dm_id):
    r = P.sigma_rest.request("get", f"/v2/dataModels/{dm_id}/materializationSchedules")
    return [{k: e.get(k) for k in ("sheetId", "elementId", "elementName", "schedule", "paused")}
            for e in (r or {}).get("entries", [])]


def probe_run_listing(dm_id):
    """Is there any way to list runs? Record what the obvious GETs return."""
    out = {}
    for path in (f"/v2/dataModels/{dm_id}/materializations", f"/v2/dataModels/{dm_id}/elements"):
        try:
            r = P.sigma_rest.request("get", path)
            out[path.replace(dm_id, "{dataModelId}")] = {"ok": True, "keys": sorted(r)[:8] if isinstance(r, dict) else type(r).__name__,
                                                         "sample": json.dumps(r)[:400]}
        except Exception as e:
            out[path.replace(dm_id, "{dataModelId}")] = {"ok": False, "error": err(e)[:200]}
    return out


# --------------------------------------------------------------------- P9
def p9(run):
    out = {}
    cats = {e["id"]: e for e in dims()}
    inv = wh2("e-inv", "Inventory", "FACT_INVENTORY",
              [("DATE_KEY", "Date Key"), ("SKU_KEY", "Sku Key"), ("STORE_KEY", "Store Key"), ("ON_HAND_UNITS", "On Hand Units")],
              rels=[rel("e-inv-r-store", "Store", "e-store", "e-inv/STORE_KEY", "e-store/STORE_KEY"),
                    rel("e-inv-r-sku", "SKU", "e-sku", "e-inv/SKU_KEY", "e-sku/SKU_KEY")])
    pages = [("pg-sales", "Sales", [base_el(), child_el(), cats["e-sku"], cats["e-prod"], cats["e-cat"]]),
             ("pg-inv", "Inventory", [inv]),
             ("pg-shared", "Shared", [cats["e-store"], cats["e-date"], cats["e-cust"]])]
    out["pages_authored"] = {nm: [e["name"] for e in els] for _, nm, els in pages}
    out["cross_page_relationships"] = ["Sales (source)->Store (Shared)", "Sales (source)->Customer (Shared)",
                                       "Sales (source)->Date (Shared)", "Sales->Store/Customer/Date (Shared)",
                                       "Inventory->Store (Shared)", "Inventory->SKU (Sales page)"]
    rb, e = run.dm_pages("P9 three pages", pages)
    if e:
        out["dm_post_error"] = e
        out["pass"] = False
        out["fallback_needed"] = "single page"
        return out
    out["readback_pages"] = {p["name"]: [x["name"] for x in p["elements"]] for p in rb["pages"]}
    # page names, page order and which elements sit on which page must survive; element order inside a page may be
    # re-sorted by the server (observed: dependency order, dimensions first), recorded separately
    out["readback_page_names_in_order"] = list(out["readback_pages"]) == list(out["pages_authored"])
    out["readback_page_membership_kept"] = ({k: sorted(v) for k, v in out["readback_pages"].items()}
                                            == {k: sorted(v) for k, v in out["pages_authored"].items()})
    out["readback_element_order_within_page_kept"] = out["readback_pages"] == out["pages_authored"]
    out["readback_page_layout_kept"] = out["readback_page_names_in_order"] and out["readback_page_membership_kept"]
    out["readback_relationships"] = {x["name"]: [(r["name"], r["targetElementId"]) for r in x.get("relationships", [])]
                                     for p in rb["pages"] for x in p["elements"] if x.get("relationships")}
    dm_id = rb["dataModelId"]
    sales, invr = readback_el(rb, "Sales"), readback_el(rb, "Inventory")
    ss, si = dm_src(dm_id, sales["id"]), dm_src(dm_id, invr["id"])
    rev = REV_F.format(e="Sales")
    charts = [
        bar("x-reg", "sales by store region (store on Shared)", ss, "[Sales/Store/Store Region]", rev, "Store Region", "Revenue"),
        bar("x-cat", "sales by category (same-page path)", ss, "[Sales/SKU/Product/Category/Category Name]", rev, "Category", "Revenue"),
        bar("x-cust", "sales by customer region (customer on Shared)", ss, "[Sales/Customer/Customer Region]", rev, "Customer Region", "Revenue"),
        bar("x-ireg", "on hand by store region (Inventory -> Shared)", si, "[Inventory/Store/Store Region]",
            "Sum([Inventory/On Hand Units])", "Store Region", "On Hand"),
        bar("x-ibrand", "on hand by brand (Inventory -> SKU -> Product, Sales page)", si, "[Inventory/SKU/Product/Brand]",
            "Sum([Inventory/On Hand Units])", "Brand", "On Hand"),
    ]
    t = lambda sel, grp: lower_keys(truth(sel, group=f"GROUP BY {grp}"))
    db, sc = env("PROBE_DB"), env("PROBE_SCHEMA")
    t_reg = t(f"st.STORE_REGION AS store_region, SUM({REV_SQL}) AS revenue", 1)
    t_cat = t(f"c.CATEGORY_NAME AS category, SUM({REV_SQL}) AS revenue", 1)
    t_cust = t(f"cu.CUSTOMER_REGION AS customer_region, SUM({REV_SQL}) AS revenue", 1)
    t_ireg = lower_keys(snow(f"SELECT st.STORE_REGION AS store_region, SUM(i.ON_HAND_UNITS) AS on_hand FROM {db}.{sc}.FACT_INVENTORY i "
                             f"LEFT JOIN {db}.{sc}.DIM_STORE st ON st.STORE_KEY = i.STORE_KEY GROUP BY 1"))
    t_ibr = lower_keys(snow(f"SELECT p.BRAND AS brand, SUM(i.ON_HAND_UNITS) AS on_hand FROM {db}.{sc}.FACT_INVENTORY i "
                            f"LEFT JOIN {db}.{sc}.DIM_SKU s ON s.SKU_KEY = i.SKU_KEY "
                            f"LEFT JOIN {db}.{sc}.DIM_PRODUCT p ON p.PRODUCT_KEY = s.PRODUCT_KEY GROUP BY 1"))
    res = run.charts(dm_id, charts, "P9")
    out["chart_store_region_from_shared_page"] = check(res, "x-reg", t_reg, ["store_region"])
    out["chart_category_same_page_path"] = check(res, "x-cat", t_cat, ["category"])
    out["chart_customer_region_from_shared_page"] = check(res, "x-cust", t_cust, ["customer_region"])
    out["chart_inventory_store_region"] = check(res, "x-ireg", t_ireg, ["store_region"])
    out["chart_inventory_brand_via_sales_page_sku"] = check(res, "x-ibrand", t_ibr, ["brand"])
    keys = ["chart_store_region_from_shared_page", "chart_category_same_page_path", "chart_customer_region_from_shared_page",
            "chart_inventory_store_region", "chart_inventory_brand_via_sales_page_sku"]
    out["cross_page_relationships_work"] = all(out[k].get("pass") for k in keys)
    out["pass"] = out["cross_page_relationships_work"] and out["readback_page_layout_kept"]
    return out


# --------------------------------------------------------------------- P10
def p10_setup(run):
    out = {"schedule_payload": {"schedule": {"cronSpec": CRON, "timezone": TZ}}, "created_utc": utc()}
    rb, e = run.dm("P10 materialization", dims() + [base_el(), child_el()])
    if e:
        out["dm_post_error"] = e
        return out
    out["dm_id"] = rb["dataModelId"]
    return out


def p10_finish(run, out, mats, since):
    dm_id = out["dm_id"]
    out["schedule_posts"] = out.pop("_posts")
    out["schedules_readback"] = schedule_readback(dm_id)
    out["run_listing_probe"] = probe_run_listing(dm_id)
    out["runs"] = {k: v for k, v in mats.items() if k in ("warehouse_table_element", "child_element")}
    out["warehouse_tables_after_run"] = wh_tables_since(since)
    src = dm_src(dm_id, "e-sales")
    rev = REV_F.format(e="Sales")
    t_reg = lower_keys(truth(f"st.STORE_REGION AS store_region, SUM({REV_SQL}) AS revenue", group="GROUP BY 1"))
    t_cat = lower_keys(truth(f"c.CATEGORY_NAME AS category, SUM({REV_SQL}) AS revenue", group="GROUP BY 1"))
    charts = [bar("m-reg", "child by store region", src, "[Sales/Store/Store Region]", rev, "Store Region", "Revenue"),
              bar("m-cat", "child by category", src, "[Sales/SKU/Product/Category/Category Name]", rev, "Category", "Revenue")]
    res = run.charts(dm_id, charts, "P10")
    out["chart_over_materialized_child_store_region"] = check(res, "m-reg", t_reg, ["store_region"])
    out["chart_over_materialized_child_category"] = check(res, "m-cat", t_cat, ["category"])
    out["run_now_endpoint_exists"] = any("materialize_response" in r for r in out["runs"].values())
    out["schedules_created"] = sorted(out["schedule_posts"])
    # the child must have built (`ready`); `skipped` is accepted only for the warehouse-table element's manual run
    out["pass"] = (len(out["runs"]) == 2
                   and str(out["runs"].get("child_element", {}).get("final_status")).lower() == "ready"
                   and str(out["runs"].get("warehouse_table_element", {}).get("final_status")).lower() in ("ready", "skipped")
                   and out["chart_over_materialized_child_store_region"]["pass"]
                   and out["chart_over_materialized_child_category"]["pass"])
    return out


def post_only(run, dm_id, charts, tag):
    """Post the charts in one workbook without exporting. Returns {chart_id: {wb}|{post_error}}."""
    try:
        wb = P.post_wb(wb_doc(charts), name=f"{PFX}{tag} workbook")
        run.created.append(wb["workbookId"])
        return {c["id"]: {"wb": wb["workbookId"]} for c in charts}
    except Exception as e:
        return {c["id"]: {"post_error": err(e)} for c in charts}


# --------------------------------------------------------------------- P11 + timing
FLAT = "Sales (flattened)"
FLAT_CALCS = [
    col("e-flat/pk", "Product Key", "Lookup([SKU/Product Key], [Sku Key], [SKU/Sku Key])"),
    col("e-flat/ck", "Category Key", "Lookup([Product/Category Key], [Product Key], [Product/Product Key])"),
    col("e-flat/br", "Brand", "Lookup([Product/Brand], [Product Key], [Product/Product Key])"),
    col("e-flat/cn", "Category Name", "Lookup([Category/Category Name], [Category Key], [Category/Category Key])"),
    col("e-flat/sr", "Store Region", "Lookup([Store/Store Region], [Store Key], [Store/Store Key])"),
    col("e-flat/ch", "Channel", "Lookup([Store/Channel], [Store Key], [Store/Store Key])"),
    col("e-flat/rev", "Revenue", "[Quantity] * [Unit Price] * (1 - [Discount])"),
]


def flat_el():
    cols = [{"id": f"e-flat/{c}", "name": n, "formula": f"[Sales (source)/{n}]"} for c, n in SALES_COLS] + FLAT_CALCS
    return {"id": "e-flat", "kind": "table", "name": FLAT, "source": {"kind": "table", "elementId": "e-sales-src"},
            "columns": cols, "order": [c["id"] for c in cols] + ["f-store", "f-product"],
            "folders": [{"id": "f-store", "name": "Store", "items": ["e-flat/sr", "e-flat/ch"]},
                        {"id": "f-product", "name": "Product", "items": ["e-flat/pk", "e-flat/ck", "e-flat/br", "e-flat/cn"]}]}


N_SAMPLES = 3
T_CAT = None  # category truth, set in p11_setup


def timed_chart(vid, src, e, xf, sample, group):
    pred = f"[{e}/Quantity] > -{group}{sample + 1}"  # excludes nothing, differs per sample and group -> distinct SQL text
    y = f"Sum(If({pred}, [{e}/Quantity] * [{e}/Unit Price] * (1 - [{e}/Discount]), 0))"
    return bar(f"t-{vid}-{sample}", f"{vid} sample {sample + 1}", src, xf, y, "Category", "Revenue")


def timing_group(run, dm_id, vs, group, tag):
    """Post one workbook with N_SAMPLES x variants charts (no export), then export them one by one,
    interleaving variants, timing each export round trip with wall-clock time."""
    charts = [timed_chart(v, *spec, s, group) for s in range(N_SAMPLES) for v, spec in vs.items()]
    r = post_only(run, dm_id, charts, tag)
    samples = {v: [] for v in vs}
    for s in range(N_SAMPLES):
        for v in vs:
            cid = f"t-{v}-{s}"
            wid = r[cid].get("wb")
            if not wid:
                samples[v].append({"sample": s + 1, "error": r[cid]})
                continue
            t0, st = time.time(), utc()
            try:
                rows = P.export_rows(wid, cid)
                dt = time.time() - t0
                ok = verdict(rows, T_CAT, ["category"])["pass"]
                samples[v].append({"sample": s + 1, "start_utc": st, "export_round_trip_s": round(dt, 2),
                                   "rows": len(rows), "matches_sql": ok})
            except Exception as ex:
                samples[v].append({"sample": s + 1, "start_utc": st, "error": err(ex)[:300]})
    return samples


def annotate_timing(tm):
    """Attach warehouse-side evidence from Snowflake's query history (read-only) to every timing sample: the
    query that Sigma sent for that chart is found by the workbook name and chart id in the SQL comment Sigma appends. Records warehouse elapsed/execution ms, bytes scanned, and
    whether the SQL reads a materialized table (`t_mat_`). Needs the same Snowflake user to see Sigma's queries."""
    import re
    flat = [(g, v, smp) for g in ("live", "materialized") for v, ss in tm.get(g, {}).items() for smp in ss
            if smp.get("start_utc") and "export_round_trip_s" in smp]
    if not flat:
        return
    ts = sorted(datetime.strptime(smp["start_utc"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) for _, _, smp in flat)
    lo = ts[0].timestamp() - 30
    mins = int((time.time() - lo) / 60) + 2
    rows = snow(f"SELECT START_TIME, TOTAL_ELAPSED_TIME, EXECUTION_TIME, COMPILATION_TIME, BYTES_SCANNED, QUERY_TEXT "
                f"FROM TABLE({env('PROBE_DB')}.INFORMATION_SCHEMA.QUERY_HISTORY("
                f"END_TIME_RANGE_START=>DATEADD('minute', -{mins}, CURRENT_TIMESTAMP()), RESULT_LIMIT=>10000)) "
                f"WHERE QUERY_TEXT ILIKE 'select%Revenue%' ORDER BY START_TIME")
    for g, v, smp in flat:
        # Sigma appends a comment naming the workbook and the exported chart: displayNodeId=t-<variant>-<sample-1>
        tag, node = f"TIMING-{g}-workbook", f"displayNodeId=t-{v}-{smp['sample'] - 1}"
        hits = [r for r in rows if tag in r["query_text"] and node + '"' in r["query_text"]]
        if len(hits) == 1:
            h = hits[0]
            smp["warehouse"] = {"total_elapsed_ms": h["total_elapsed_time"], "execution_ms": h["execution_time"],
                                "compilation_ms": h["compilation_time"], "bytes_scanned": h["bytes_scanned"],
                                "reads_materialized_table": "t_mat_" in h["query_text"]}
        else:
            smp["warehouse"] = {"error": f"{len(hits)} matching queries in history"}
    tm["median_warehouse_total_elapsed_ms"] = {}
    tm["median_warehouse_execution_ms"] = {}
    tm["reads_materialized_table"] = {}
    for g in ("live", "materialized"):
        for v, ss in tm.get(g, {}).items():
            w = [x["warehouse"] for x in ss if "total_elapsed_ms" in x.get("warehouse", {})]
            if len(w) == len(ss) and w:
                tm["median_warehouse_total_elapsed_ms"][f"{v}_{g}"] = statistics.median(x["total_elapsed_ms"] for x in w)
                tm["median_warehouse_execution_ms"][f"{v}_{g}"] = statistics.median(x["execution_ms"] for x in w)
                tm["reads_materialized_table"][f"{v}_{g}"] = [x["reads_materialized_table"] for x in w]


def p11_setup(run):
    """Post the data model, run the P11 live checks and the live timing samples."""
    global T_CAT
    out = {"p11": {"created_utc": utc()}, "timing": {}}
    p, tm = out["p11"], out["timing"]
    rb, e = run.dm("P11 flattened child", dims() + [base_el(), child_el(), flat_el()])
    if e:
        p["dm_post_error"] = e
        p["pass"] = False
        return out
    dm_id = rb["dataModelId"]
    out["dm_id"] = dm_id
    fl = readback_el(rb, FLAT)
    p["readback_folders"] = fl.get("folders")
    want = {"Store": ["Store Region", "Channel"], "Product": ["Product Key", "Category Key", "Brand", "Category Name"]}
    idname = {c["id"]: c["name"] for c in fl["columns"]}
    got = {f["name"]: [idname.get(i, i) for i in f.get("items", [])] for f in (fl.get("folders") or [])}
    p["folders_by_name"] = got
    p["folders_kept"] = got == want
    p["flattened_calc_formulas"] = {k: v for k, v in cols_of(fl).items() if k in ("Brand", "Category Name", "Store Region", "Channel")}
    src_f, src_c = dm_src(dm_id, fl["id"]), dm_src(dm_id, readback_el(rb, "Sales")["id"])
    out["src_f"], out["src_c"] = src_f, src_c
    revf, revc = REV_F.format(e=FLAT), REV_F.format(e="Sales")
    T_CAT = lower_keys(truth(f"c.CATEGORY_NAME AS category, SUM({REV_SQL}) AS revenue", group="GROUP BY 1"))
    t_ch = lower_keys(truth(f"st.CHANNEL AS channel, SUM({REV_SQL}) AS revenue", group="GROUP BY 1"))
    charts = [
        bar("f-cat", "flattened by category", src_f, f"[{FLAT}/Category Name]", revf, "Category", "Revenue"),
        bar("u-cat", "unflattened child by category", src_c, "[Sales/SKU/Product/Category/Category Name]", revc, "Category", "Revenue"),
        bar("f-ch", "flattened by channel", src_f, f"[{FLAT}/Channel]", revf, "Channel", "Revenue"),
        bar("f-mrev", "flattened Revenue column by category", src_f, f"[{FLAT}/Category Name]", f"Sum([{FLAT}/Revenue])", "Category", "Revenue"),
    ]
    res = run.charts(dm_id, charts, "P11")
    p["chart_flattened_by_category"] = check(res, "f-cat", T_CAT, ["category"])
    p["chart_unflattened_child_by_category"] = check(res, "u-cat", T_CAT, ["category"])
    p["chart_flattened_by_channel"] = check(res, "f-ch", t_ch, ["channel"])
    p["chart_flattened_revenue_column"] = check(res, "f-mrev", T_CAT, ["category"])
    fa, ua = res["f-cat"].get("rows"), res["u-cat"].get("rows")
    p["flattened_equals_unflattened_rows"] = bool(fa and ua) and verdict(fa, lower_keys(ua), ["category"])["pass"]
    p["pass_live"] = (p["folders_kept"] and p["chart_flattened_by_category"]["pass"] and p["chart_unflattened_child_by_category"]["pass"]
                      and p["chart_flattened_by_channel"]["pass"] and p["chart_flattened_revenue_column"]["pass"]
                      and p["flattened_equals_unflattened_rows"])
    tm["metric"] = ("wall-clock seconds for POST /v2/workbooks/{id}/export + poll GET /v2/query/{id}/download of one chart "
                    "(Sales by Category). The API exposes no in-browser page-load time, so this export round trip is the only "
                    "timing measured; it includes the export queue and CSV download, not just the warehouse query.")
    tm["cache_bust"] = ("per-sample predicate `Quantity > -k` inside the measure (excludes no rows, changes the SQL text so the "
                        "result cache misses); k differs per sample and per live/materialized group")
    tm["variants"] = {"child_3hop": "chart over child `Sales`, x = [Sales/SKU/Product/Category/Category Name]",
                      "flattened": f"chart over `{FLAT}`, x = [{FLAT}/Category Name] (Lookup-chain calc column)"}
    tm["live"] = timing_group(run, dm_id, {"child_3hop": (src_c, "Sales", "[Sales/SKU/Product/Category/Category Name]"),
                                           "flattened": (src_f, FLAT, f"[{FLAT}/Category Name]")}, 1, "TIMING live")
    out["_t_ch"] = t_ch
    return out


def p11_finish(run, out, mats, mat_ok):
    p, tm, dm_id = out["p11"], out["timing"], out["dm_id"]
    src_f, src_c = out["src_f"], out["src_c"]
    tm["materialization_runs"] = {k: v for k, v in mats.items() if k in ("child_timing_dm", "flattened_timing_dm")}
    p["materialized_flattened_run"] = tm["materialization_runs"].get("flattened_timing_dm")
    if mat_ok:
        res2 = run.charts(dm_id, [bar("fm-cat", "materialized flattened by category", src_f, f"[{FLAT}/Category Name]",
                                      REV_F.format(e=FLAT), "Category", "Revenue")], "P11 materialized")
        p["chart_materialized_flattened_by_category"] = check(res2, "fm-cat", T_CAT, ["category"])
        p["readback_folders_after_materialization"] = [f["name"] for f in (readback_el(P.sigma_rest.request("get", f"/v2/dataModels/{dm_id}/spec"), FLAT) or {}).get("folders", [])]
        tm["materialized"] = timing_group(run, dm_id, {"child_3hop": (src_c, "Sales", "[Sales/SKU/Product/Category/Category Name]"),
                                                        "flattened": (src_f, FLAT, f"[{FLAT}/Category Name]")}, 2, "TIMING materialized")

    def med(xs):
        v = [s["export_round_trip_s"] for s in xs if "export_round_trip_s" in s]
        return round(statistics.median(v), 2) if len(v) == len(xs) and v else None
    tm["median_s"] = {f"{k}_{g}": med(tm[g][k]) for g in ("live", "materialized") if g in tm for k in tm[g]}
    try:
        annotate_timing(tm)
    except Exception as e:
        tm["warehouse_annotation_error"] = err(e)[:300]
    p["pass"] = bool(p.get("pass_live")) and (not mat_ok or bool(p.get("chart_materialized_flattened_by_category", {}).get("pass")))
    out.pop("_t_ch", None)
    return out


# ------------------------------------------------------------------ key check
def key_check():
    db, sc = env("PROBE_DB"), env("PROBE_SCHEMA")
    out = {}
    for label, table, expect in (("unique_key", "DIM_PRODUCT", 0), ("duplicate_key", "DIM_PRODUCT_DUPKEY", 1)):
        sql = f"SELECT COUNT(*) - COUNT(DISTINCT PRODUCT_KEY) AS dup FROM {db}.{sc}.{table}"
        t0 = time.time()
        rows = P.run_sql(sql)
        dup = rows[0].get("DUP", rows[0].get("dup")) if rows else None
        out[label] = {"table": table, "sql_template": "SELECT COUNT(*) - COUNT(DISTINCT key) AS dup FROM <target>",
                      "dup": dup, "expected": expect, "round_trip_s": round(time.time() - t0, 1),
                      "pass": dup is not None and int(float(dup)) == expect}
    out["pass"] = all(v["pass"] for v in out.values() if isinstance(v, dict))
    return out


def mask_ids(obj):
    """Replace Sigma materialized table names (`t_mat_<hex>_<n>`) and schedule sheetIds with stable placeholders."""
    ids = {}

    def sheet_vals(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k in ("sheetId", "sheet_id") and isinstance(v, str):
                    ids.setdefault(v, f"<sheet-{len(ids) + 1}>")
                sheet_vals(v)
        elif isinstance(o, list):
            for v in o:
                sheet_vals(v)
    sheet_vals(obj)
    tabs = {}
    pat = re.compile(r"t_mat_[0-9a-f]{8,}_\d+")

    def s(x):
        for k, v in ids.items():
            x = x.replace(k, v)
        return pat.sub(lambda m: tabs.setdefault(m.group(0), f"<mat-table-{len(tabs) + 1}>"), x)

    def walk(o):
        if isinstance(o, str):
            return s(o)
        if isinstance(o, dict):
            return {s(k): walk(v) for k, v in o.items()}
        if isinstance(o, list):
            return [walk(v) for v in o]
        return o
    return walk(obj)


def main():
    which = set(a.upper() for a in sys.argv[1:]) or {"KEY", "P9", "P10", "P11"}
    if which == {"ANNOTATE"}:  # add query-history evidence to an existing results file (creates nothing live)
        path = os.path.join(HERE, "results", "p_physical.json")
        with open(path, encoding="utf-8") as fh:
            res = json.load(fh)
        annotate_timing(res["TIMING"])
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(mask_ids(P.redact(res, P.redact_terms())), fh, indent=2, default=str)
            fh.write("\n")
        print(json.dumps({k: res["TIMING"].get(k) for k in ("median_warehouse_total_elapsed_ms", "median_warehouse_execution_ms",
                                                            "reads_materialized_table")}, indent=1))
        return
    run = PRun()
    result = {"started_utc": utc()}
    try:
        if "KEY" in which:
            try:
                result["KEY"] = key_check()
            except Exception as e:
                result["KEY"] = {"pass": False, "error": f"{type(e).__name__}: {err(e)}"}
        if "P9" in which:
            try:
                result["P9"] = p9(run)
            except Exception as e:
                result["P9"] = {"pass": False, "error": f"{type(e).__name__}: {err(e)}"}
        p10o, p11o, targets = None, None, []
        mat_start = utc()
        try:
            if "P10" in which:
                p10o = p10_setup(run)
                result["P10"] = p10o
            if "P11" in which:
                p11o = p11_setup(run)
                result["P11"], result["TIMING"] = p11o["p11"], p11o["timing"]
            # schedules on every element under test, created together so the first runs overlap
            posts10 = {}
            if p10o and p10o.get("dm_id"):
                for label, el in (("warehouse_table_element", "e-sales-src"), ("child_element", "e-sales")):
                    r, e = run.schedule(p10o["dm_id"], el)
                    posts10[label] = {"element_id": el, **({"response": r} if r else {"error": e})}
                    if r:
                        targets.append({"label": label, "dm_id": p10o["dm_id"], "sheet_id": r["sheetId"], "created_utc": utc()})
                p10o["_posts"] = posts10
            if p11o and p11o.get("dm_id"):
                posts11 = {}
                for label, el in (("child_timing_dm", "e-sales"), ("flattened_timing_dm", "e-flat")):
                    r, e = run.schedule(p11o["dm_id"], el)
                    posts11[label] = {"element_id": el, **({"response": r} if r else {"error": e})}
                    if r:
                        targets.append({"label": label, "dm_id": p11o["dm_id"], "sheet_id": r["sheetId"], "created_utc": utc()})
                result["TIMING"]["schedule_posts"] = posts11
            mats = materialize_all(targets) if targets else {}
            if p10o and p10o.get("dm_id"):
                result["P10"] = p10_finish(run, p10o, mats, mat_start)
            if p11o and p11o.get("dm_id"):
                mat_ok = all(str(mats.get(k, {}).get("final_status")).lower() == "ready"
                             for k in ("child_timing_dm", "flattened_timing_dm"))
                p11_finish(run, p11o, mats, mat_ok)
                result["P11"], result["TIMING"] = p11o["p11"], p11o["timing"]
        except Exception as e:
            result["orchestration_error"] = f"{type(e).__name__}: {err(e)}"
        result["warehouse_tables_created_by_run_before_delete"] = wh_tables_since(result["started_utc"])
    finally:
        run.delete_schedules()
        result["schedule_cleanup"] = run.schedule_cleanup
        result["cleanup"] = P.cleanup(run.created)
        result["cleanup_all_archived"] = all(result["cleanup"].values()) and bool(result["cleanup"])
        result["objects_created"] = len(run.created)
        result["warehouse_tables_after_delete"] = wh_tables_since(result["started_utc"])
        path = os.path.join(HERE, "results", "p_physical.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(mask_ids(P.redact(result, P.redact_terms())), fh, indent=2, default=str)
            fh.write("\n")
    summ = {k: v.get("pass") for k, v in result.items() if isinstance(v, dict) and "pass" in v}
    print(json.dumps(P.redact({"checks": summ, "median_s": result.get("TIMING", {}).get("median_s"),
                               "cleanup_all_archived": result["cleanup_all_archived"],
                               "schedule_cleanup": result["schedule_cleanup"],
                               "orchestration_error": result.get("orchestration_error"),
                               "unconfirmed": [k for k, v in result["cleanup"].items() if not v]}, P.redact_terms()), indent=1))


if __name__ == "__main__":
    main()
