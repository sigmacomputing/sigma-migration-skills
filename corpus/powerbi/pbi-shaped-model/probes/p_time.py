#!/usr/bin/env python3
"""Time-intelligence and summary probes P8a, P8b, P8c, P15, P16 for the Power BI-shaped model mode.

Each probe posts a small data model on the seeded retail sample plus a workbook whose charts read the data
model elements directly. Chart exports are compared with read-only Snowflake truth (`snow sql`). Everything
created is deleted in a `finally` and verified archived.

Run: python3 -I corpus/powerbi/pbi-shaped-model/probes/p_time.py
Needs PROBE_CONNECTION_ID, PROBE_FOLDER_ID, PROBE_DB, PROBE_SCHEMA (env only).
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe_lib as P  # noqa: E402
import p_metrics as M  # noqa: E402
from probe_shapes import (env, col, dm_src, layout_xml, truth, lower_keys, verdict, differs,  # noqa: E402
                          REV_SQL, snow, norm_month)
from p_metrics import wh2, dims, base_el, child_el, err, readback_el, cols_of, bar, wb_doc  # noqa: E402

PFX = "zz Claude probe – time "
M.PFX = PFX  # p_metrics.dm_doc / Run.charts read this module global for object names

REVF = "Sum([Sales/Revenue])"


# ---------------------------------------------------------------- shared shapes
def asof_el():
    return wh2("e-asof", "As Of", "AS_OF", [("AS_OF_DATE", "As Of Date")],
               calcs=[{"id": "e-asof/one", "name": "One", "formula": "1"}])


def child_calcs(asof=False):
    c = [{"id": "e-sales/rev", "name": "Revenue", "formula": "[Quantity] * [Unit Price] * (1 - [Discount])"},
         {"id": "e-sales/od", "name": "Order Date", "formula": "Lookup([Date/Cal Date], [Order Date Key], [Date/Date Key])"},
         {"id": "e-sales/sr", "name": "Store Region", "formula": "Lookup([Store/Store Region], [Store Key], [Store/Store Key])"}]
    if asof:
        c += [{"id": "e-sales/one", "name": "One", "formula": "1"},
              {"id": "e-sales/asof", "name": "As Of Date", "formula": "Lookup([As Of/As Of Date], [One], [As Of/One])"}]
    return c


SALES_AMOUNT = {"id": "m-sa", "name": "Sales Amount", "formula": "Sum([Revenue])"}


def sales_child(asof=False, asof_rel=True, metrics=()):
    el = child_el(calcs=child_calcs(asof), metrics=[SALES_AMOUNT] + list(metrics))
    if asof and asof_rel:
        el["relationships"].append(M.rel("e-sales-r-asof", "As Of", "e-asof", "e-sales/one", "e-asof/one")
                                   if hasattr(M, "rel") else None)
    return el


def model(elements, asof=False):
    d = dims() + ([asof_el()] if asof else []) + [base_el()]
    return d + elements


def grouped(eid, name, groupings, columns):
    """A grouped DM child of the Sales child. groupings: [(grouping_id, [groupBy col ids], [calc col ids])]."""
    return {"id": eid, "kind": "table", "name": name, "source": {"kind": "table", "elementId": "e-sales"},
            "columns": columns, "order": [c["id"] for c in columns],
            "groupings": [{"id": g, **({"groupBy": gb} if gb else {}), **({"calculations": ca} if ca else {})}
                          for g, gb, ca in groupings]}


def monthly_cols(pfx, region=False, extra=()):
    c = [col(f"{pfx}/year", "Year", 'DateTrunc("year", [Sales/Order Date])'),
         col(f"{pfx}/month", "Month", 'DateTrunc("month", [Sales/Order Date])'),
         col(f"{pfx}/sales", "Sales", "Sum([Sales/Revenue])"),
         col(f"{pfx}/ytd", "Sales YTD", "CumulativeSum(Sum([Sales/Revenue]))"),
         col(f"{pfx}/py", "Sales PY", 'DateLookback([Sales], [Month], 1, "year")')]
    if region:
        c.insert(0, col(f"{pfx}/region", "Store Region", "[Sales/Store Region]"))
    return c + list(extra)


def monthly_el(eid, name, mode, extra=()):
    """mode: plain | region_inner (Year, Month, Region) | region_outer (Region, Year, Month)."""
    p = eid
    cols = monthly_cols(p, region=mode != "plain", extra=extra)
    calcs = [f"{p}/sales", f"{p}/ytd", f"{p}/py"] + [e["id"] for e in extra]
    if mode == "plain":
        gs = [("g-year", [f"{p}/year"], []), ("g-month", [f"{p}/month"], calcs)]
    elif mode == "region_inner":
        gs = [("g-year", [f"{p}/year"], []), ("g-month", [f"{p}/month"], calcs), ("g-region", [f"{p}/region"], [])]
    else:
        gs = [("g-region", [f"{p}/region"], []), ("g-year", [f"{p}/year"], []), ("g-month", [f"{p}/month"], calcs)]
    return grouped(eid, name, gs, cols)


class Run(M.Run):
    def wb(self, charts, tag, extra_elements=()):
        els = list(extra_elements) + list(charts)
        doc = {"schemaVersion": 1, "kind": "workbook", "pages": [{"id": "pg1", "name": "Probe"}],
               "elements": els, "layout": layout_xml("pg1", els)}
        w = P.post_wb(doc, name=f"{PFX}{tag} workbook")
        self.created.append(w["workbookId"])
        return w

    def exp(self, wid, eid, params=None):
        try:
            return {"rows": P.export_rows(wid, eid, params)}
        except Exception as e:
            return {"export_error": err(e)}


def summ(res, truth_rows, keys):
    if "rows" not in res:
        return {"pass": False, **res}
    return verdict(res["rows"], truth_rows, keys)


def day_str(rows, key):
    for r in rows:
        if isinstance(r.get(key), str):
            r[key] = r[key][:10]
    return rows


# --------------------------------------------------------------------- P8a
def p8a(run):
    out = {"as_of": snow(f"SELECT AS_OF_DATE FROM {env('PROBE_DB')}.{env('PROBE_SCHEMA')}.AS_OF")[0]["as_of_date"]}
    db, sc = env("PROBE_DB"), env("PROBE_SCHEMA")
    asof = f"(SELECT AS_OF_DATE FROM {db}.{sc}.AS_OF)"
    t = {}
    for lab, unit in (("ytd", "year"), ("qtd", "quarter"), ("mtd", "month")):
        t[lab] = lower_keys(truth(f"st.STORE_REGION AS store_region, SUM({REV_SQL}) AS {lab}",
                                  where=f"WHERE od.CAL_DATE >= DATE_TRUNC('{unit}', {asof}) AND od.CAL_DATE <= {asof}",
                                  group="GROUP BY 1"))
    merged = {}
    for lab in t:
        for r in t[lab]:
            merged.setdefault(r["store_region"], {"store_region": r["store_region"]})[lab] = r[lab]
    truth_rows = list(merged.values())
    out["truth_rows"] = len(truth_rows)
    out["truth_ytd_qtd_mtd_pairwise_differing_regions"] = {
        "ytd_vs_qtd": differs(t["ytd"], t["qtd"], ["store_region"], "qtd") if False else
        sum(1 for r in truth_rows if abs((r.get("ytd") or 0) - (r.get("qtd") or 0)) > 1e-6),
        "qtd_vs_mtd": sum(1 for r in truth_rows if abs((r.get("qtd") or 0) - (r.get("mtd") or 0)) > 1e-6)}
    metrics = [{"id": "m-ytd", "name": "Sales YTD AsOf",
                "formula": 'SumIf([Revenue], [Order Date] >= DateTrunc("year", [As Of Date]) and [Order Date] <= [As Of Date])'},
               {"id": "m-qtd", "name": "Sales QTD AsOf",
                "formula": 'SumIf([Revenue], [Order Date] >= DateTrunc("quarter", [As Of Date]) and [Order Date] <= [As Of Date])'},
               {"id": "m-mtd", "name": "Sales MTD AsOf",
                "formula": 'SumIf([Revenue], [Order Date] >= DateTrunc("month", [As Of Date]) and [Order Date] <= [As Of Date])'}]
    out["variants"] = {}
    for label, rel_on in (("with_relationship_on_One", True), ("without_relationship", False)):
        v = {"lookup": "Lookup([As Of/As Of Date], [One], [As Of/One])", "metrics": {m["name"]: m["formula"] for m in metrics}}
        child = sales_child(asof=True, asof_rel=rel_on, metrics=metrics)
        rb, e = run.dm(f"P8a {label}", model([child], asof=True))
        if e:
            v["dm_post_error"] = e
            out["variants"][label] = v
            continue
        el = readback_el(rb, "Sales")
        v["readback_asof_column"] = cols_of(el).get("As Of Date")
        v["readback_metric_formulas"] = {m["name"]: m["formula"] for m in el.get("metrics", [])}
        src = dm_src(rb["dataModelId"], el["id"])
        ch = dict(id="a-reg", kind="bar-chart", name="asof by region", source=src,
                  columns=[col("a-x", "Store Region", "[Sales/Store Region]"),
                           col("a-ytd", "YTD", "[Metrics/Sales YTD AsOf]"),
                           col("a-qtd", "QTD", "[Metrics/Sales QTD AsOf]"),
                           col("a-mtd", "MTD", "[Metrics/Sales MTD AsOf]"),
                           col("a-asof", "As Of", "Max([Sales/As Of Date])")],
                  xAxis={"columnId": "a-x"}, yAxis={"columnIds": ["a-ytd", "a-qtd", "a-mtd"]}, stacking="none")
        try:
            w = run.wb([ch], f"P8a {label}")
            r = run.exp(w["workbookId"], "a-reg")
        except Exception as ex:
            v["workbook_error"] = err(ex)
            out["variants"][label] = v
            continue
        v["chart"] = summ(r, truth_rows, ["store_region"])
        if "rows" in r:
            v["export_header"] = list(r["rows"][0].keys()) if r["rows"] else None
            v["export_as_of_sample"] = r["rows"][0].get("As Of") if r["rows"] else None
            v["null_cells"] = sum(1 for row in r["rows"] for x in row.values() if x is None)
        out["variants"][label] = v
    out["working_variants"] = [k for k, v in out["variants"].items() if v.get("chart", {}).get("pass")]
    out["pass"] = bool(out["working_variants"]) and all(x > 0 for x in out["truth_ytd_qtd_mtd_pairwise_differing_regions"].values())
    return out


# ------------------------------------------------------------- P8b / P16 / P15 truth
def monthly_truth(region=None):
    """Monthly sales, YTD (reset each January) and same-month-prior-year per month (optionally one region)."""
    db, sc = env("PROBE_DB"), env("PROBE_SCHEMA")
    regs = [region] if isinstance(region, str) else (region or [])
    cond = ("WHERE st.STORE_REGION IN (" + ", ".join(f"'{x}'" for x in regs) + ")") if regs else ""
    q = (f"WITH m AS (SELECT DATE_TRUNC('month', od.CAL_DATE) AS mon, SUM({REV_SQL}) AS sales "
         f"FROM {db}.{sc}.FACT_SALES f LEFT JOIN {db}.{sc}.DIM_DATE od ON od.DATE_KEY = f.ORDER_DATE_KEY "
         f"LEFT JOIN {db}.{sc}.DIM_STORE st ON st.STORE_KEY = f.STORE_KEY {cond} GROUP BY 1) "
         "SELECT TO_CHAR(m.mon, 'YYYY-MM') AS month, m.sales AS sales, "
         "SUM(m.sales) OVER (PARTITION BY YEAR(m.mon) ORDER BY m.mon) AS ytd, p.sales AS py "
         "FROM m LEFT JOIN m p ON p.mon = DATEADD('year', -1, m.mon) ORDER BY 1")
    return lower_keys(snow(q))


def month_ytd_chart(cid, eid_name, pfx_cols=("Sales", "Sales YTD", "Sales PY")):
    n = eid_name
    return lambda src, agg_col="Max": dict(
        id=cid, kind="bar-chart", name=cid, source=src,
        columns=[col(cid + "-x", "Month", f"[{n}/Month]"),
                 col(cid + "-s", "Sales", f"{agg_col}([{n}/Sales])"),
                 col(cid + "-y", "YTD", f"{agg_col}([{n}/Sales YTD])"),
                 col(cid + "-p", "PY", f"{agg_col}([{n}/Sales PY])"),
                 col(cid + "-ys", "YTD Sum", f"Sum([{n}/Sales YTD])")],
        xAxis={"columnId": cid + "-x"}, yAxis={"columnIds": [cid + "-s", cid + "-y", cid + "-p", cid + "-ys"]}, stacking="none")


def p8b_p16(run):
    t = monthly_truth()
    jan = [r for r in t if r["month"].endswith("-01")]
    out = {"truth_months": len(t), "truth_januaries": len(jan),
           "truth_jan_ytd_equals_sales": all(abs(r["ytd"] - r["sales"]) < 1e-6 for r in jan),
           "truth_first_year_py_null": all(r["py"] is None for r in t if r["month"].startswith("2023")),
           "truth_py_nonnull_months": sum(1 for r in t if r["py"] is not None)}
    p16col = col("gm/p16", "Sales Amount Metric", "[Metrics/Sales Amount]")
    # ---- P8b (plain) in its own DM so a P16 rejection cannot hide it
    el = monthly_el("gm", "Sales Monthly", "plain")
    rb, e = run.dm("P8b grouped", model([sales_child()] + [el]))
    p8b = {"form": {"groupings": [{"id": g["id"], "groupBy": g.get("groupBy"), "calculations": g.get("calculations")}
                                  for g in el["groupings"]],
                    "columns": {c["name"]: c["formula"] for c in el["columns"]}}}
    if e:
        p8b["dm_post_error"] = e
        p8b["pass"] = False
    else:
        g = readback_el(rb, "Sales Monthly")
        p8b["readback_groupings"] = g.get("groupings")
        p8b["readback_columns"] = cols_of(g)
        src = dm_src(rb["dataModelId"], g["id"])
        mk = month_ytd_chart("gm-c", "Sales Monthly")
        try:
            w = run.wb([mk(src)], "P8b")
            r = run.exp(w["workbookId"], "gm-c")
            if "rows" in r:
                norm_month(r["rows"], "Month")
                p8b["export_header"] = list(r["rows"][0].keys()) if r["rows"] else None
                tys = [{"month": x["month"], "yearsum": x["ytd"]} for x in t]
                ys = [{"month": x.get("Month"), "yearsum": x.get("YTD Sum")} for x in r["rows"]]
                p8b["info_sum_instead_of_max_on_ytd"] = verdict(ys, tys, ["month"])
            p8b["chart_max_agg"] = summ(r, t, ["month"])
            if "rows" in r:
                jr = [x for x in r["rows"] if str(x.get("Month", "")).endswith("-01")]
                p8b["jan_ytd_equals_sales_in_export"] = bool(jr) and all(
                    isinstance(x.get("YTD"), float) and abs(x["YTD"] - x["Sales"]) < 1e-6 for x in jr)
            p8b["pass"] = bool(p8b["chart_max_agg"]["pass"]) and bool(p8b.get("jan_ytd_equals_sales_in_export"))
        except Exception as ex:
            p8b["workbook_error"] = err(ex)
            p8b["pass"] = False
    out["P8b"] = p8b
    # ---- P16: parent metric in the grouped element
    p16 = {"truth_sales": "equals Sum(Revenue) at month grain"}
    forms = {"brief_form_[Metrics/Sales Amount]": "[Metrics/Sales Amount]",
             "relative_[Sales Amount]": "[Sales Amount]",
             "child_qualified_[Sales/Sales Amount]": "[Sales/Sales Amount]"}
    p16["forms"] = {}
    for lab, f in forms.items():
        v = {"formula": f}
        el16 = monthly_el("gm", "Sales Monthly", "plain",
                          extra=[col("gm/p16", "Sales Amount Metric", f)])
        rb, e = run.dm(f"P16 {lab}", model([sales_child()] + [el16]))
        if e:
            v["dm_post_error"] = e
            p16["forms"][lab] = v
            continue
        g = readback_el(rb, "Sales Monthly")
        v["readback_formula"] = cols_of(g).get("Sales Amount Metric")
        src = dm_src(rb["dataModelId"], g["id"])
        ch = dict(id="p16-c", kind="bar-chart", name="p16", source=src,
                  columns=[col("p16-x", "Month", "[Sales Monthly/Month]"),
                           col("p16-m", "Sales", "Max([Sales Monthly/Sales Amount Metric])")],
                  xAxis={"columnId": "p16-x"}, yAxis={"columnIds": ["p16-m"]}, stacking="none")
        try:
            w = run.wb([ch], f"P16 {lab}")
            r = run.exp(w["workbookId"], "p16-c")
            if "rows" in r:
                norm_month(r["rows"], "Month")
            v["chart_vs_sum_revenue_truth"] = summ(r, [{"month": x["month"], "sales": x["sales"]} for x in t], ["month"])
            v["pass"] = bool(v["chart_vs_sum_revenue_truth"]["pass"])
        except Exception as ex:
            v["workbook_error"] = err(ex)
            v["pass"] = False
        p16["forms"][lab] = v
    p16["working_forms"] = [k for k, v in p16["forms"].items() if v.get("pass")]
    p16["pass"] = bool(p16["working_forms"])
    p16["post_accepted"] = {k: "dm_post_error" not in v for k, v in p16["forms"].items()}
    out["P16"] = p16
    out["pass"] = p8b["pass"]
    return out


# -------------------------------------------------------------------- P15
def p15(run):
    out = {}
    t_all = monthly_truth()
    t_w = monthly_truth("West")
    out["truth"] = {"west_months": len(t_w), "all_months": len(t_all),
                    "pick_changes_sales_months": differs([{"month": r["month"], "revenue": r["sales"]} for r in t_w],
                                                         [{"month": r["month"], "revenue": r["sales"]} for r in t_all], ["month"]),
                    "pick_changes_ytd_months": differs([{"month": r["month"], "revenue": r["ytd"]} for r in t_w],
                                                       [{"month": r["month"], "revenue": r["ytd"]} for r in t_all], ["month"])}
    out["variants"] = {}
    for mode in ("region_outer", "region_inner"):
        v = {"mode": mode}
        el = monthly_el("gr", "Sales Monthly Region", mode)
        v["groupings"] = [{"id": g["id"], "groupBy": g.get("groupBy"), "calculations": g.get("calculations")} for g in el["groupings"]]
        rb, e = run.dm(f"P15 {mode}", model([sales_child()] + [el]))
        if e:
            v["dm_post_error"] = e
            out["variants"][mode] = v
            continue
        g = readback_el(rb, "Sales Monthly Region")
        v["readback_groupings"] = g.get("groupings")
        src = dm_src(rb["dataModelId"], g["id"])
        n = "Sales Monthly Region"
        ch = dict(id="r-c", kind="bar-chart", name="monthly by pick", source=src,
                  columns=[col("r-x", "Month", f"[{n}/Month]"), col("r-reg", "Store Region", f"[{n}/Store Region]"),
                           col("r-s", "Sales", f"Sum([{n}/Sales])"), col("r-y", "YTD", f"Sum([{n}/Sales YTD])"),
                           col("r-p", "PY", f"Sum([{n}/Sales PY])"),
                           col("r-sm", "Sales Max", f"Max([{n}/Sales])"), col("r-ym", "YTD Max", f"Max([{n}/Sales YTD])")],
                  xAxis={"columnId": "r-x"}, yAxis={"columnIds": ["r-s", "r-y", "r-p", "r-sm", "r-ym"]}, stacking="none")
        ctl = dict(kind="control", id="ctl-reg", controlId="StoreRegion", name="Store region", controlType="list",
                   mode="include", selectionMode="multiple", values=[],
                   source={"kind": "source", "source": {"kind": "table", "elementId": "r-c"}, "columnId": "r-reg"},
                   filters=[{"source": {"kind": "table", "elementId": "r-c"}, "columnId": "r-reg"}])
        try:
            w = run.wb([ch], f"P15 {mode}", extra_elements=[ctl])
        except Exception as ex:
            v["workbook_error"] = err(ex)
            out["variants"][mode] = v
            continue
        wid = w["workbookId"]
        no_pick, west = run.exp(wid, "r-c"), run.exp(wid, "r-c", {"StoreRegion": "West"})
        for r in (no_pick, west):
            if "rows" in r:
                norm_month(r["rows"], "Month")
        v["no_pick_vs_all_region_truth"] = summ(no_pick, t_all, ["month"])
        v["west_pick_vs_west_truth"] = summ(west, t_w, ["month"])
        if "rows" in west and "rows" in no_pick:
            v["pick_changed_numbers_in_export"] = sum(
                1 for a in west["rows"] for b in no_pick["rows"]
                if a["Month"] == b["Month"] and (a.get("Sales") != b.get("Sales") or a.get("YTD") != b.get("YTD")))
            v["west_sample"] = west["rows"][:2]
            v["no_pick_sample"] = no_pick["rows"][:2]
        # info: Max instead of Sum (what a consumer must use when the pick leaves one region row per month)
        for lab, r, tt in (("west_max_cols_vs_west_truth", west, t_w), ("west_max_cols_vs_all_region_truth", west, t_all)):
            if "rows" in r:
                v[lab] = verdict([{"month": x["Month"], "sales": x.get("Sales Max"), "ytd": x.get("YTD Max")} for x in r["rows"]],
                                 [{"month": x["month"], "sales": x["sales"], "ytd": x["ytd"]} for x in tt], ["month"])
        mp = run.exp(wid, "r-c", {"StoreRegion": "West,East"})
        if "rows" in mp:
            norm_month(mp["rows"], "Month")
        v["west_east_pick_vs_truth"] = summ(mp, monthly_truth(["West", "East"]), ["month"])
        v["pass"] = bool(v["west_pick_vs_west_truth"].get("pass") and v["no_pick_vs_all_region_truth"].get("pass")
                         and v.get("pick_changed_numbers_in_export", 0) > 0)
        out["variants"][mode] = v
    out["working_variants"] = [k for k, v in out["variants"].items() if v.get("pass")]
    out["pass"] = bool(out["working_variants"])
    return out


# -------------------------------------------------------------------- P8c
def p8c(run):
    db, sc = env("PROBE_DB"), env("PROBE_SCHEMA")
    q = (f"WITH d AS (SELECT od.CAL_DATE AS day, SUM({REV_SQL}) AS s FROM {db}.{sc}.FACT_SALES f "
         f"LEFT JOIN {db}.{sc}.DIM_DATE od ON od.DATE_KEY = f.ORDER_DATE_KEY GROUP BY 1), "
         f"sp AS (SELECT dd.CAL_DATE AS day, COALESCE(d.s, 0) AS s, d.s IS NOT NULL AS present "
         f"FROM {db}.{sc}.DIM_DATE dd LEFT JOIN d ON d.day = dd.CAL_DATE) "
         "SELECT TO_CHAR(day, 'YYYY-MM-DD') AS day, present, "
         "SUM(s) OVER (ORDER BY day ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS rolling28 FROM sp ORDER BY 1")
    t_all = lower_keys(snow(q))
    t = [r for r in t_all if r["day"] >= "2025-01-01"]
    present = [r for r in t if r["present"] in (True, "true", "TRUE")]
    out = {"truth_days_2025_on": len(t), "truth_days_with_sales": len(present),
           "truth_days_without_sales": len(t) - len(present), "truth_history_days": len(t_all)}
    texp = [{"day": r["day"], "rolling_28": r["rolling28"]} for r in t]
    # ---- Custom SQL over the dense spine
    sql = (f"WITH d AS (SELECT od.CAL_DATE AS DAY, SUM({REV_SQL}) AS S FROM {db}.{sc}.FACT_SALES f "
           f"LEFT JOIN {db}.{sc}.DIM_DATE od ON od.DATE_KEY = f.ORDER_DATE_KEY GROUP BY 1) "
           f"SELECT dd.CAL_DATE AS DAY, COALESCE(d.S, 0) AS DAY_SALES, "
           f"SUM(COALESCE(d.S, 0)) OVER (ORDER BY dd.CAL_DATE ROWS BETWEEN 27 PRECEDING AND CURRENT ROW) AS ROLLING_28 "
           f"FROM {db}.{sc}.DIM_DATE dd LEFT JOIN d ON d.DAY = dd.CAL_DATE")
    sqlel = {"id": "e-spine", "kind": "table", "name": "Rolling SQL",
             "source": {"kind": "sql", "connectionId": env("PROBE_CONNECTION_ID"), "statement": sql},
             "columns": [col("e-spine/DAY", "Day", "[Custom SQL/DAY]"), col("e-spine/DS", "Day Sales", "[Custom SQL/DAY_SALES]"),
                         col("e-spine/R28", "Rolling 28", "[Custom SQL/ROLLING_28]")]}
    sqlel["order"] = [c["id"] for c in sqlel["columns"]]
    # ---- MovingSum over present days only
    day = col("e-daily/day", "Day", 'DateTrunc("day", [Sales/Order Date])')
    ds = col("e-daily/s", "Day Sales", "Sum([Sales/Revenue])")
    ms = col("e-daily/ms", "Moving 28", "MovingSum([Day Sales], 27, 0)")
    daily = grouped("e-daily", "Sales Daily", [("g-day", ["e-daily/day"], ["e-daily/s", "e-daily/ms"])], [day, ds, ms])
    rb, e = run.dm("P8c rolling", model([sales_child(), daily, sqlel]))
    if e:
        out["dm_post_error"] = e
        out["pass"] = False
        return out
    gd, gs = readback_el(rb, "Sales Daily"), readback_el(rb, "Rolling SQL")
    out["readback"] = {"moving_sum_formula": cols_of(gd).get("Moving 28"), "sql_columns": cols_of(gs),
                       "sql_source_kind": (gs.get("source") or {}).get("kind")}
    ch_ms = dict(id="c-ms", kind="bar-chart", name="movingsum", source=dm_src(rb["dataModelId"], gd["id"]),
                 columns=[col("ms-x", "Day", "[Sales Daily/Day]"), col("ms-y", "Rolling 28", "Max([Sales Daily/Moving 28])")],
                 xAxis={"columnId": "ms-x"}, yAxis={"columnIds": ["ms-y"]}, stacking="none")
    ch_sq = dict(id="c-sq", kind="bar-chart", name="customsql", source=dm_src(rb["dataModelId"], gs["id"]),
                 columns=[col("sq-x", "Day", "[Rolling SQL/Day]"), col("sq-y", "Rolling 28", "Max([Rolling SQL/Rolling 28])")],
                 xAxis={"columnId": "sq-x"}, yAxis={"columnIds": ["sq-y"]}, stacking="none")
    try:
        w = run.wb([ch_ms, ch_sq], "P8c")
    except Exception as ex:
        out["workbook_error"] = err(ex)
        out["pass"] = False
        return out
    wid = w["workbookId"]
    # Custom SQL summary
    r = run.exp(wid, "c-sq")
    if "rows" in r:
        day_str(r["rows"], "Day")
        rows = [x for x in r["rows"] if x["Day"] >= "2025-01-01"]
        out["customsql_all_history_rows"] = len(r["rows"])
        out["customsql"] = verdict(rows, texp, ["day"])
        out["customsql_all_history"] = verdict(r["rows"], [{"day": x["day"], "rolling_28": x["rolling28"]} for x in t_all], ["day"])
    else:
        out["customsql"] = {"pass": False, **r}
    # MovingSum
    r = run.exp(wid, "c-ms")
    if "rows" in r:
        day_str(r["rows"], "Day")
        rows = [x for x in r["rows"] if x["Day"] >= "2025-01-01"]
        tm = {x["day"]: x["rolling28"] for x in t}
        pres = {x["day"] for x in present}
        diffs = []
        for x in rows:
            tv = tm.get(x["Day"])
            av = x.get("Rolling 28")
            if tv is None or av is None or abs(av - tv) > 1e-6:
                diffs.append((x["Day"], av, tv))
        rel = [abs(a - b) / b for _, a, b in diffs if a is not None and b]
        # classify: days within 27 days after a no-sales day (the window should contain a gap)
        gap_days = sorted(d for d in tm if d not in pres)
        out["movingsum"] = {
            "present_day_rows_compared": len(rows), "days_in_truth_2025_on": len(t),
            "days_missing_from_element": len(t) - len(rows),
            "days_where_value_differs": len(diffs), "share_of_present_days_differing": round(len(diffs) / max(len(rows), 1), 4),
            "max_abs_diff": max((abs(a - b) for _, a, b in diffs if a is not None and b is not None), default=0),
            "max_rel_diff": max(rel, default=0), "mean_rel_diff": (sum(rel) / len(rel)) if rel else 0,
            "first_five_diffs_(day,movingsum,truth)": diffs[:5],
            "calendar_gap_days_2025_on": len([d for d in gap_days if d >= "2025-01-01"]),
            "differs_from_calendar_truth": len(diffs) > 0,
            "matches_truth_when_no_gap_in_window": None}
        # days whose 28-day calendar window holds no gap day should match even for MovingSum
        gset = set(gap_days)
        from datetime import date, timedelta
        def window_has_gap(ds):
            y, m, dd = map(int, ds.split("-"))
            d0 = date(y, m, dd)
            return any((d0 - timedelta(k)).isoformat() in gset for k in range(28))
        clean = [x for x in rows if not window_has_gap(x["Day"])]
        if clean:
            out["movingsum"]["matches_truth_when_no_gap_in_window"] = {
                "days": len(clean), "all_match": all(abs(x["Rolling 28"] - tm[x["Day"]]) < 1e-6 for x in clean if x.get("Rolling 28") is not None)}
        out["movingsum"]["note"] = ("MovingSum counts element rows (present days), not calendar days; expected to differ after a gap. "
                                    "Window row order is the element's group order.")
        out["movingsum_matches_truth"] = verdict(rows, texp, ["day"])
    else:
        out["movingsum"] = {"pass": False, **r}
    # pass: the Custom SQL form equals truth AND MovingSum differs (the finding the mode relies on)
    out["pass"] = bool(out.get("customsql", {}).get("pass")) and bool(out.get("movingsum", {}).get("differs_from_calendar_truth"))
    return out


def main():
    run = Run()
    result = {}
    try:
        result["P8a"] = p8a(run)
        for name, fn in (("P8b_P16", p8b_p16), ("P8c", p8c), ("P15", p15)):
            try:
                result[name] = fn(run)
            except Exception as e:
                result[name] = {"pass": False, "error": f"{type(e).__name__}: {err(e)}"}
    except Exception as e:
        result["fatal"] = f"{type(e).__name__}: {err(e)}"
    finally:
        result["cleanup"] = P.cleanup(run.created)
        result["cleanup_all_archived"] = all(result["cleanup"].values()) and bool(result["cleanup"])
        result["objects_created"] = len(run.created)
        path = os.path.join(HERE, "results", "p_time.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(P.redact(result, P.redact_terms()), fh, indent=2, default=str)
            fh.write("\n")
    flat = {}
    for k, v in result.items():
        if isinstance(v, dict) and "pass" in v:
            flat[k] = v["pass"]
    if "P8b_P16" in result:
        flat["P8b"] = result["P8b_P16"].get("P8b", {}).get("pass")
        flat["P16"] = result["P8b_P16"].get("P16", {}).get("pass")
    print(json.dumps(P.redact({"checks": flat, "cleanup_all_archived": result["cleanup_all_archived"],
                               "unconfirmed": [k for k, v in result["cleanup"].items() if not v]}, P.redact_terms()), indent=1))


if __name__ == "__main__":
    main()
