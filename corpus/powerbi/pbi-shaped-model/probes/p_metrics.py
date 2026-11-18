#!/usr/bin/env python3
"""Metric and naming probes P4, P7, P13, P14, P17 for the Power BI-shaped model mode.

Each probe builds its own small data model (and a workbook that reads the data
model elements directly) on the seeded retail sample, compares chart exports with
warehouse truth from read-only `snow sql`, and records the exact working form or
the exact error text. Everything is deleted in a `finally` and verified archived.

Run: python3 -I corpus/powerbi/pbi-shaped-model/probes/p_metrics.py
Needs PROBE_CONNECTION_ID, PROBE_FOLDER_ID, PROBE_DB, PROBE_SCHEMA (env only).
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe_lib as P  # noqa: E402
from probe_shapes import (env, tbl, rel, SALES_COLS, sales_rels, col, dm_src, layout_xml,  # noqa: E402
                          truth, lower_keys, verdict, differs, REV_SQL, snow, norm_month)

PFX = "zz Claude probe – metrics "


def err(e):
    return str(e).split("\n", 1)[-1][:700]


# ---------------------------------------------------------------- data model
def auto_name(phys):
    return phys.replace("_", " ").title()


def wh2(eid, name, table, cols, rels=(), calcs=(), metrics=(), token="auto"):
    """Warehouse-table element. cols: [(PHYSICAL, 'Display Name')]. The formula token
    is the auto display name (`Order Date Key`) unless `token` says otherwise."""
    conn = env("PROBE_CONNECTION_ID")

    def tk(phys, nm):
        return {"auto": auto_name(phys), "new": nm, "physical": phys}[token]

    columns = [{"id": f"{eid}/{c}", "name": n, "formula": f"[{table}/{tk(c, n)}]"} for c, n in cols]
    columns += list(calcs)
    out = {"id": eid, "kind": "table", "name": name,
           "source": {"connectionId": conn, "kind": "warehouse-table", "path": tbl(table)},
           "columns": columns, "order": [c["id"] for c in columns]}
    if rels:
        out["relationships"] = list(rels)
    if metrics:
        out["metrics"] = list(metrics)
    return out


def dims(rn=False, token="auto"):
    """Dimension elements. rn=True renames Customer/Date columns to Power BI-style names."""
    cat = wh2("e-cat", "Category", "DIM_CATEGORY", [("CATEGORY_KEY", "Category Key"), ("CATEGORY_NAME", "Category Name")], token=token)
    prod = wh2("e-prod", "Product", "DIM_PRODUCT",
               [("PRODUCT_KEY", "Product Key"), ("PRODUCT_NAME", "Product Name"), ("BRAND", "Brand"),
                ("CATEGORY_KEY", "Category Key"), ("LIST_PRICE", "List Price")],
               rels=[rel("e-prod-r-cat", "Category", "e-cat", "e-prod/CATEGORY_KEY", "e-cat/CATEGORY_KEY")], token=token)
    sku = wh2("e-sku", "SKU", "DIM_SKU", [("SKU_KEY", "Sku Key"), ("PRODUCT_KEY", "Product Key"), ("SIZE", "Size")],
              rels=[rel("e-sku-r-prod", "Product", "e-prod", "e-sku/PRODUCT_KEY", "e-prod/PRODUCT_KEY")], token=token)
    store = wh2("e-store", "Store", "DIM_STORE",
                [("STORE_KEY", "Store Key"), ("STORE_NAME", "Store Name"), ("STORE_REGION", "Store Region"), ("CHANNEL", "Channel")],
                token=token)
    if rn:
        cust = wh2("e-cust", "Customer", "DIM_CUSTOMER",
                   [("CUSTOMER_KEY", "CustomerKey"), ("SEGMENT", "Customer Segment"), ("CUSTOMER_REGION", "Customer Region"),
                    ("LOYALTY_MEMBER", "LoyaltyMember")], token=token)
        date = wh2("e-date", "Date", "DIM_DATE",
                   [("DATE_KEY", "DateKey"), ("CAL_DATE", "CalDate"), ("YEAR_NUM", "YearNum"), ("MONTH_NUM", "MonthNum"),
                    ("MONTH_NAME", "MonthName")],
                   calcs=[{"id": "e-date/month", "name": "Month", "formula": 'DateTrunc("month", [CalDate])'}], token=token)
    else:
        cust = wh2("e-cust", "Customer", "DIM_CUSTOMER",
                   [("CUSTOMER_KEY", "Customer Key"), ("SEGMENT", "Segment"), ("CUSTOMER_REGION", "Customer Region"),
                    ("LOYALTY_MEMBER", "Loyalty Member")], token=token)
        date = wh2("e-date", "Date", "DIM_DATE",
                   [("DATE_KEY", "Date Key"), ("CAL_DATE", "Cal Date"), ("YEAR_NUM", "Year Num"), ("MONTH_NUM", "Month Num"),
                    ("MONTH_NAME", "Month Name")],
                   calcs=[{"id": "e-date/month", "name": "Month", "formula": 'DateTrunc("month", [Cal Date])'}], token=token)
    return [cat, prod, sku, store, cust, date]


def base_el(cols=SALES_COLS, calcs=(), metrics=(), token="auto"):
    return wh2("e-sales-src", "Sales (source)", "FACT_SALES", cols, rels=sales_rels("e-sales-src"),
               calcs=calcs, metrics=metrics, token=token)


def child_el(cols=SALES_COLS, calcs=(), metrics=(), filters=(), folders=(), rels=True):
    ccols = [{"id": f"e-sales/{c}", "name": n, "formula": f"[Sales (source)/{n}]"} for c, n in cols]
    ccols += list(calcs)
    el = {"id": "e-sales", "kind": "table", "name": "Sales", "source": {"kind": "table", "elementId": "e-sales-src"},
          "columns": ccols, "order": [c["id"] for c in ccols]}
    if rels:
        el["relationships"] = sales_rels("e-sales")
    if metrics:
        el["metrics"] = list(metrics)
    if filters:
        el["filters"] = list(filters)
    if folders:
        el["folders"] = list(folders)
    return el


def dm_doc(tag, elements):
    return {"name": PFX + tag, "schemaVersion": 1, "folderId": env("PROBE_FOLDER_ID"),
            "pages": [{"id": "p1", "name": "Page 1", "elements": elements}]}


# ---------------------------------------------------------------- workbook
def bar(cid, name, src, xf, yf, xname="Group", yname="Value"):
    return dict(id=cid, kind="bar-chart", name=name, source=src,
                columns=[col(cid + "-x", xname, xf), col(cid + "-y", yname, yf)],
                xAxis={"columnId": cid + "-x"}, yAxis={"columnIds": [cid + "-y"]}, stacking="none")


def wb_doc(charts):
    return {"schemaVersion": 1, "kind": "workbook", "pages": [{"id": "pg1", "name": "Probe"}],
            "elements": charts, "layout": layout_xml("pg1", charts)}


class Run:
    """Tracks every created object so the `finally` can delete them all."""

    def __init__(self):
        self.created = []

    def dm(self, tag, elements):
        """Post a data model. Returns (readback|None, error|None)."""
        try:
            rb = P.post_dm(dm_doc(tag, elements))
            self.created.append(rb["dataModelId"])
            return rb, None
        except Exception as e:  # recorded, never hidden
            return None, err(e)

    def charts(self, dm_id, charts, tag):
        """Post the charts (one workbook if it takes; otherwise one each so a bad
        chart is isolated). Returns {chart_id: {wb, rows|error}}. Each chart's
        export is a separate call, so one failing chart does not hide the others."""
        out, posts = {}, []
        groups = [charts]
        for grp in (groups, [[c] for c in charts]):
            posts = []
            for i, g in enumerate(grp):
                try:
                    wb = P.post_wb(wb_doc(g), name=f"{PFX}{tag} workbook {i + 1}")
                    self.created.append(wb["workbookId"])
                    posts.append((g, wb["workbookId"], None))
                except Exception as e:
                    posts.append((g, None, err(e)))
            if all(p[1] for p in posts):
                break
        for g, wid, perr in posts:
            for c in g:
                if wid is None:
                    out[c["id"]] = {"post_error": perr}
                    continue
                try:
                    out[c["id"]] = {"wb": wid, "rows": P.export_rows(wid, c["id"])}
                except Exception as e:
                    out[c["id"]] = {"wb": wid, "export_error": err(e)}
        return out


def check(res, cid, expect, keys, extra=None):
    r = res[cid]
    if "rows" not in r:
        d = {"pass": False, **{k: v for k, v in r.items() if k != "wb"}}
    else:
        d = verdict(r["rows"], expect, keys)
        d["null_cells_in_actual"] = sum(1 for row in r["rows"] for v in row.values() if v is None)
    if extra:
        d.update(extra)
    return d


def readback_el(rb, name):
    for pg in rb["pages"]:
        for e in pg["elements"]:
            if e.get("name") == name:
                return e
    return None


def cols_of(el):
    return {c["name"]: c.get("formula") for c in (el or {}).get("columns", [])}


def metric_summary(el):
    return [{k: m.get(k) for k in ("name", "formula", "description")} for m in (el or {}).get("metrics", [])]


# --------------------------------------------------------------------- P4
LV = "List Value"
LV_FORMULA = "Sum([Quantity] * [List Price])"


def p4(run):
    out = {"metric": f"{LV} = {LV_FORMULA}"}
    t_lv = lower_keys(truth("c.CATEGORY_NAME AS category, SUM(f.QUANTITY * p.LIST_PRICE) AS list_value", group="GROUP BY 1"))
    out["truth_rows"] = len(t_lv)
    # ---- base form: calc column on `Sales (source)` through the relationship path
    out["base"] = {}
    for label, ref in (("brief_form", "[Sales (source)/SKU/Product/List Price]"), ("short_form", "[SKU/Product/List Price]")):
        v = {"calc_column_formula": ref}
        calcs = [{"id": "e-sales-src/lp", "name": "List Price", "formula": ref}]
        rb, e = run.dm(f"P4 base {label}", dims() + [base_el(calcs=calcs, metrics=[{"id": "m-lv", "name": LV, "formula": LV_FORMULA}])])
        if e:
            v["dm_post_error"] = e
        else:
            el = readback_el(rb, "Sales (source)")
            v["readback_calc_formula"] = cols_of(el).get("List Price")
            v["readback_metrics"] = metric_summary(el)
            src = dm_src(rb["dataModelId"], el["id"])
            charts = [bar("b-metric", "metric", src, "[Sales (source)/SKU/Product/Category/Category Name]", f"[Metrics/{LV}]", "Category", LV),
                      bar("b-inline", "inline", src, "[Sales (source)/SKU/Product/Category/Category Name]",
                          "Sum([Sales (source)/Quantity] * [Sales (source)/List Price])", "Category", LV)]
            res = run.charts(rb["dataModelId"], charts, f"P4 base {label}")
            v["chart_metric_ref"] = check(res, "b-metric", t_lv, ["category"])
            v["chart_inline_calc"] = check(res, "b-inline", t_lv, ["category"])
        out["base"][label] = v
    # ---- child form: Lookup chain on the child `Sales`
    calcs = [{"id": "e-sales/pk", "name": "Product Key", "formula": "Lookup([SKU/Product Key], [Sku Key], [SKU/Sku Key])"},
             {"id": "e-sales/lp", "name": "List Price", "formula": "Lookup([Product/List Price], [Product Key], [Product/Product Key])"}]
    child = {"calc_columns": {c["name"]: c["formula"] for c in calcs}}
    rb, e = run.dm("P4 child lookup", dims() + [base_el(), child_el(calcs=calcs, metrics=[{"id": "m-lv", "name": LV, "formula": LV_FORMULA}])])
    if e:
        child["dm_post_error"] = e
    else:
        el = readback_el(rb, "Sales")
        child["readback_calc_formulas"] = {k: v for k, v in cols_of(el).items() if k in ("Product Key", "List Price")}
        child["readback_metrics"] = metric_summary(el)
        src = dm_src(rb["dataModelId"], el["id"])
        charts = [bar("c-metric", "metric", src, "[Sales/SKU/Product/Category/Category Name]", f"[Metrics/{LV}]", "Category", LV),
                  bar("c-inline", "inline", src, "[Sales/SKU/Product/Category/Category Name]",
                      "Sum([Sales/Quantity] * [Sales/List Price])", "Category", LV)]
        res = run.charts(rb["dataModelId"], charts, "P4 child")
        child["chart_metric_ref"] = check(res, "c-metric", t_lv, ["category"])
        child["chart_inline_calc"] = check(res, "c-inline", t_lv, ["category"])
    out["child_lookup"] = child
    base_ok = any(v.get("chart_metric_ref", {}).get("pass") for v in out["base"].values())
    child_ok = bool(child.get("chart_metric_ref", {}).get("pass"))
    out["base_form_works"] = base_ok
    out["child_form_works"] = child_ok
    out["pass"] = base_ok or child_ok
    out["decision"] = ("base form works: no fact split" if base_ok else
                       "only the child Lookup form works: split the fact (Sales (source) + child Sales)" if child_ok else
                       "neither works: class B goes to the agent brief")
    return out


# --------------------------------------------------------------------- P7
def p7(run):
    out = {}
    cat = wh2("e-cat", "Category", "DIM_CATEGORY", [("CATEGORY_KEY", "Category Key"), ("CATEGORY_NAME", "Category Name")],
              metrics=[{"id": "m-cat", "name": "Row Count", "formula": "Count([Category Key])"}])
    store = wh2("e-store", "Store", "DIM_STORE", [("STORE_KEY", "Store Key"), ("STORE_NAME", "Store Name")],
                metrics=[{"id": "m-store", "name": "Row Count", "formula": "Count([Store Key])"}])
    rb, e = run.dm("P7 duplicate metric name", [cat, store])
    if e:
        out["dm_post_error"] = e
        out["outcome"] = "400/error on POST"
        out["pass"] = True  # the behavior is the finding, recorded exactly
        return out
    out["readback"] = {n: metric_summary(readback_el(rb, n)) for n in ("Category", "Store")}
    counts = {n: len(out["readback"][n]) for n in out["readback"]}
    names = {n: [m["name"] for m in out["readback"][n]] for n in out["readback"]}
    out["outcome"] = ("POST accepted; both elements keep a metric named 'Row Count'" if all(v == ["Row Count"] for v in names.values())
                      else "POST accepted; readback differs from authored (see readback): " + json.dumps(names))
    out["metric_counts"] = counts
    # does the shared name resolve per element? query each element's metric
    sc = dm_src(rb["dataModelId"], readback_el(rb, "Category")["id"])
    st = dm_src(rb["dataModelId"], readback_el(rb, "Store")["id"])
    charts = [bar("p7c", "cat", sc, "[Category/Category Name]", "[Metrics/Row Count]", "Group", "Row Count"),
              bar("p7s", "store", st, "[Store/Store Name]", "[Metrics/Row Count]", "Group", "Row Count")]
    res = run.charts(rb["dataModelId"], charts, "P7")
    out["chart_category"] = {k: v for k, v in res["p7c"].items() if k != "wb"}
    out["chart_store"] = {k: v for k, v in res["p7s"].items() if k != "wb"}
    for k in ("chart_category", "chart_store"):
        rows = out[k].get("rows")
        if rows:
            out[k] = {"rows": len(rows), "sample": rows[:2]}
    out["pass"] = True  # behavior recorded, not asserted
    return out


# -------------------------------------------------------------------- P13
CAT_LOOKUPS = [
    {"id": "e-sales/pk", "name": "Product Key", "formula": "Lookup([SKU/Product Key], [Sku Key], [SKU/Sku Key])"},
    {"id": "e-sales/ck", "name": "Category Key", "formula": "Lookup([Product/Category Key], [Product Key], [Product/Product Key])"},
    {"id": "e-sales/cn", "name": "Category Name", "formula": "Lookup([Category/Category Name], [Category Key], [Category/Category Key])"},
]
KEEP = 'IsNull([Category Name]) or [Category Name] != "Discontinued"'


def p13(run):
    out = {}
    where = "WHERE c.CATEGORY_NAME IS NULL OR c.CATEGORY_NAME <> 'Discontinued'"
    sel = f"c.CATEGORY_NAME AS category, SUM({REV_SQL}) AS revenue"
    t_f = lower_keys(truth(sel, where=where, group="GROUP BY 1"))
    t_all = lower_keys(truth(sel, group="GROUP BY 1"))
    tot_f = sum(r["revenue"] for r in t_f)
    tot_all = sum(r["revenue"] for r in t_all)
    out["truth"] = {"filtered_total": tot_f, "unfiltered_total": tot_all,
                    "totals_differ": tot_f != tot_all, "groups_filtered": len(t_f), "groups_unfiltered": len(t_all),
                    "null_category_revenue_kept": next((r["revenue"] for r in t_f if r["category"] is None), None),
                    "discontinued_excluded": all(r["category"] != "Discontinued" for r in t_f)}
    # how Category Name reaches the child: relationship path column vs Lookup chain (unfiltered child)
    rel_calc = [{"id": "e-sales/cnrel", "name": "Category Name", "formula": "[SKU/Product/Category/Category Name]"}]
    variants = {
        "lookup_list_boolean": dict(calcs=CAT_LOOKUPS + [{"id": "e-sales/keep", "name": "Keep", "formula": KEEP}],
                                    filters=[{"id": "f-keep", "columnId": "e-sales/keep", "kind": "list", "mode": "include", "values": [True]}]),
        "lookup_list_text_flag": dict(calcs=CAT_LOOKUPS + [{"id": "e-sales/keep", "name": "Keep",
                                                            "formula": f'If({KEEP}, "keep", "drop")'}],
                                      filters=[{"id": "f-keep", "columnId": "e-sales/keep", "kind": "list", "mode": "include", "values": ["keep"]}]),
        "lookup_text_match_incl_nulls": dict(calcs=CAT_LOOKUPS,
                                             filters=[{"id": "f-cat", "columnId": "e-sales/cn", "kind": "text-match",
                                                       "mode": "does-not-equal", "value": "Discontinued", "case": "sensitive",
                                                       "includeNulls": "always"}]),
        "relpath_text_match_incl_nulls": dict(calcs=rel_calc,
                                              filters=[{"id": "f-cat", "columnId": "e-sales/cnrel", "kind": "text-match",
                                                        "mode": "does-not-equal", "value": "Discontinued", "case": "sensitive",
                                                        "includeNulls": "always"}]),
    }
    out["variants"] = {}
    for label, spec in variants.items():
        v = {"filter": spec["filters"][0],
             "category_name_column": {c["name"]: c["formula"] for c in spec["calcs"] if c["name"] in ("Category Name", "Keep")}}
        rb, e = run.dm(f"P13 {label}", dims() + [base_el(), child_el(calcs=spec["calcs"], filters=spec["filters"])])
        if e:
            v["dm_post_error"] = e
            out["variants"][label] = v
            continue
        el = readback_el(rb, "Sales")
        v["readback_filters"] = el.get("filters")
        src = dm_src(rb["dataModelId"], el["id"])
        cn = "[Sales/Category Name]"
        res = run.charts(rb["dataModelId"], [bar("g", "by category", src, cn, "Sum([Sales/Quantity] * [Sales/Unit Price] * (1 - [Sales/Discount]))",
                                                 "Category", "Revenue")], f"P13 {label}")
        d = check(res, "g", t_f, ["category"])
        # a NULL category key never matches by value; compare NULL group separately when the key column is empty
        rows = res["g"].get("rows") or []
        d["has_null_category_group"] = any(r.get("Category") is None for r in rows)
        d["has_discontinued_group"] = any(r.get("Category") == "Discontinued" for r in rows)
        d["total_actual"] = sum(r["Revenue"] for r in rows if isinstance(r.get("Revenue"), float)) if rows else None
        d["total_filtered_truth"] = tot_f
        d["total_unfiltered_truth"] = tot_all
        v["chart"] = d
        out["variants"][label] = v
    out["pass"] = out["truth"]["totals_differ"] and any(v.get("chart", {}).get("pass") for v in out["variants"].values())
    out["working_variants"] = [k for k, v in out["variants"].items() if v.get("chart", {}).get("pass")]
    return out


# -------------------------------------------------------------------- P14
def p14(run):
    out = {}
    cols = [("STORE_KEY", "Store Key"), ("STORE_NAME", "Store Name"), ("STORE_REGION", "Store Region"), ("CHANNEL", "Channel")]
    metrics = [{"id": "m-n", "name": "Store Count", "formula": "Count([Store Key])"},
               {"id": "m-r", "name": "Region Count", "formula": "CountDistinct([Store Region])"}]

    def el(folders, metrics=metrics, order_extra=()):
        e = wh2("e-store", "Store", "DIM_STORE", cols, metrics=metrics)
        e["folders"] = folders
        e["order"] = list(order_extra) + e["order"]
        return e

    variants = {
        "A_metric_ids_in_folder_items": el([{"id": "f-m", "name": "Counts", "items": ["m-n", "m-r"]}]),
        "B_metric_ids_in_folder_and_order": el([{"id": "f-m", "name": "Counts", "items": ["m-n", "m-r"]}], order_extra=["f-m"]),
        "C_column_folder_control": el([{"id": "f-c", "name": "Geography", "items": ["e-store/STORE_REGION", "e-store/CHANNEL"]}]),
        "D_metric_description_and_name_prefix": el(
            [], metrics=[{"id": "m-n", "name": "Counts / Store Count", "formula": "Count([Store Key])", "description": "Folder: Counts"},
                         {"id": "m-r", "name": "Counts / Region Count", "formula": "CountDistinct([Store Region])", "description": "Folder: Counts"}]),
    }
    out["variants"] = {}
    for label, elt in variants.items():
        v = {"authored_folders": elt.get("folders"), "authored_metric_names": [m["name"] for m in elt.get("metrics", [])]}
        if not elt.get("folders"):
            elt.pop("folders", None)
        rb, e = run.dm(f"P14 {label}", [elt])
        if e:
            v["dm_post_error"] = e
        else:
            r = readback_el(rb, "Store")
            v["readback_folders"] = r.get("folders")
            v["readback_metrics"] = metric_summary(r)
            v["readback_order"] = r.get("order")
            v["folder_kept"] = bool(r.get("folders"))
            fi = [it for f in (r.get("folders") or []) for it in f.get("items", [])]
            v["metric_ids_kept_in_folder"] = any(i.startswith("m-") or "m-" in str(i) for i in fi) if fi else False
            v["readback_item_ids"] = fi
        out["variants"][label] = v
    out["metric_folders_supported"] = any(v.get("metric_ids_kept_in_folder") for v in out["variants"].values())
    out["pass"] = True  # behavior recorded, not asserted
    survivors = [k for k, v in out["variants"].items()
                 if v.get("folder_kept") or any(m.get("description") for m in v.get("readback_metrics", []))]
    out["alternatives_that_survive_readback"] = survivors
    return out


# -------------------------------------------------------------------- P17
RENAME_COLS = [("SALES_LINE_KEY", "SalesLineKey"), ("ORDER_NUMBER", "OrderNumber"), ("ORDER_DATE_KEY", "OrderDateKey"),
               ("SHIP_DATE_KEY", "ShipDateKey"), ("SKU_KEY", "SkuKey"), ("CUSTOMER_KEY", "CustomerKey"),
               ("STORE_KEY", "StoreKey"), ("QUANTITY", "Quantity"), ("UNIT_PRICE", "UnitPrice"), ("DISCOUNT", "Discount"),
               ("UNIT_COST", "UnitCost")]


def p17(run):
    out = {"renames": {"ORDER_DATE_KEY": "OrderDateKey", "UNIT_PRICE": "UnitPrice", "SKU_KEY": "SkuKey",
                       "CUSTOMER_KEY (dim)": "CustomerKey", "SEGMENT": "Customer Segment", "DATE_KEY": "DateKey",
                       "CAL_DATE": "CalDate"}}
    t_reg = lower_keys(truth(f"cu.CUSTOMER_REGION AS region, SUM({REV_SQL}) AS revenue", group="GROUP BY 1"))
    t_mon = lower_keys(truth(f"TO_CHAR(DATE_TRUNC('month', od.CAL_DATE), 'YYYY-MM') AS month, SUM({REV_SQL}) AS revenue", group="GROUP BY 1"))
    t_seg = lower_keys(truth(f"cu.SEGMENT AS segment, SUM({REV_SQL}) AS revenue", group="GROUP BY 1"))
    out["tokens_tried"] = {}
    ok_token = None
    for token in ("auto", "new", "physical"):
        v = {}
        # relationships keep their column ids (physical ids never change), so only formulas are rewritten
        src = base_el(cols=RENAME_COLS, token=token)
        ccalcs = [{"id": "e-sales/revenue", "name": "Revenue", "formula": "[Quantity] * [UnitPrice] * (1 - [Discount])"}]
        child = child_el(cols=RENAME_COLS, calcs=ccalcs, metrics=[{"id": "m-rev", "name": "Revenue Total", "formula": "Sum([Revenue])"}])
        rb, e = run.dm(f"P17 token {token}", dims(rn=True, token=token) + [src, child])
        if e:
            v["dm_post_error"] = e
            out["tokens_tried"][token] = v
            continue
        s = readback_el(rb, "Sales (source)")
        c = readback_el(rb, "Sales")
        v["readback_base_columns"] = {k: f for k, f in cols_of(s).items() if k in ("OrderDateKey", "UnitPrice", "SkuKey", "Quantity")}
        v["readback_child_columns"] = {k: f for k, f in cols_of(c).items() if k in ("OrderDateKey", "UnitPrice", "Revenue")}
        v["readback_customer_columns"] = cols_of(readback_el(rb, "Customer"))
        v["readback_metrics"] = metric_summary(c)
        sc = dm_src(rb["dataModelId"], c["id"])
        charts = [bar("r-reg", "revenue by region", sc, "[Sales/Customer/Customer Region]", "Sum([Sales/Revenue])", "Region", "Revenue"),
                  bar("r-seg", "revenue by segment", sc, "[Sales/Customer/Customer Segment]", "[Metrics/Revenue Total]", "Segment", "Revenue"),
                  bar("r-mon", "revenue by order month", sc, "[Sales/Date/Month]",
                      "Sum([Sales/Quantity] * [Sales/UnitPrice] * (1 - [Sales/Discount]))", "Month", "Revenue")]
        res = run.charts(rb["dataModelId"], charts, f"P17 {token}")
        if "rows" in res["r-mon"]:
            norm_month(res["r-mon"]["rows"], "Month")
        v["chart_region"] = check(res, "r-reg", t_reg, ["region"])
        v["chart_segment_via_metric"] = check(res, "r-seg", t_seg, ["segment"])
        v["chart_month_via_renamed_date_key"] = check(res, "r-mon", t_mon, ["month"])
        v["pass"] = all(v[k]["pass"] for k in ("chart_region", "chart_segment_via_metric", "chart_month_via_renamed_date_key"))
        out["tokens_tried"][token] = v
        if v["pass"] and ok_token is None:
            ok_token = token
    out["working_token_form"] = ok_token
    out["token_forms"] = {"auto": "[FACT_SALES/Order Date Key] (Sigma auto display name of the physical column)",
                          "new": "[FACT_SALES/OrderDateKey] (the Power BI name)",
                          "physical": "[FACT_SALES/ORDER_DATE_KEY] (physical name)"}
    out["pass"] = ok_token is not None
    return out


def main():
    run = Run()
    result = {}
    try:
        for name, fn in (("P4", p4), ("P7", p7), ("P13", p13), ("P14", p14), ("P17", p17)):
            try:
                result[name] = fn(run)
            except Exception as e:  # keep going; record, never hide
                result[name] = {"pass": False, "error": f"{type(e).__name__}: {err(e)}"}
    finally:
        result["cleanup"] = P.cleanup(run.created)
        result["cleanup_all_archived"] = all(result["cleanup"].values()) and bool(result["cleanup"])
        result["objects_created"] = len(run.created)
        path = os.path.join(HERE, "results", "p_metrics.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(P.redact(result, P.redact_terms()), fh, indent=2, default=str)
            fh.write("\n")
    summ = {k: v.get("pass") for k, v in result.items() if isinstance(v, dict) and "pass" in v}
    print(json.dumps(P.redact({"checks": summ, "p4_decision": result.get("P4", {}).get("decision"),
                               "cleanup_all_archived": result["cleanup_all_archived"],
                               "unconfirmed": [k for k, v in result["cleanup"].items() if not v]}, P.redact_terms()), indent=1))


if __name__ == "__main__":
    main()
