#!/usr/bin/env python3
"""Core probes P1, P2, P3, P5, P6, P12 for the Power BI-shaped model mode.

One data model (Sales/SKU/Product/Category/Store/Customer/Date, a second
Sales->Date relationship, a "Sales (source)" base and a "Sales" child) and one
workbook whose charts read the data model elements directly. Every check is
compared with warehouse truth from `snow sql` (SELECT only, independent of
Sigma). Everything is deleted in a `finally` and verified archived.

Run: python3 -I corpus/powerbi/pbi-shaped-model/probes/p_core.py
Needs PROBE_CONNECTION_ID, PROBE_FOLDER_ID, PROBE_DB, PROBE_SCHEMA (env only).
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe_lib as P  # noqa: E402
from probe_shapes import env, snow, tbl, wh, rel, SALES_COLS, sales_rels, col, dm_src, layout_xml, truth, norm_month, lower_keys, verdict, differs, REV, REV_SQL  # noqa: E402

DM_NAME = "zz Claude probe – core data model"
WB_NAME = "zz Claude probe – core workbook"
REVENUE = "Quantity * [Unit Price] * (1 - [Discount])"


def dm_spec():
    cat = wh("e-cat", "Category", "DIM_CATEGORY",
             [("CATEGORY_KEY", "Category Key"), ("CATEGORY_NAME", "Category Name")])
    prod = wh("e-prod", "Product", "DIM_PRODUCT",
              [("PRODUCT_KEY", "Product Key"), ("PRODUCT_NAME", "Product Name"), ("BRAND", "Brand"),
               ("CATEGORY_KEY", "Category Key")],
              rels=[rel("e-prod-r-cat", "Category", "e-cat", "e-prod/CATEGORY_KEY", "e-cat/CATEGORY_KEY")])
    sku = wh("e-sku", "SKU", "DIM_SKU",
             [("SKU_KEY", "Sku Key"), ("PRODUCT_KEY", "Product Key"), ("SIZE", "Size")],
             rels=[rel("e-sku-r-prod", "Product", "e-prod", "e-sku/PRODUCT_KEY", "e-prod/PRODUCT_KEY")])
    store = wh("e-store", "Store", "DIM_STORE",
               [("STORE_KEY", "Store Key"), ("STORE_NAME", "Store Name"), ("STORE_REGION", "Store Region"),
                ("CHANNEL", "Channel")])
    cust = wh("e-cust", "Customer", "DIM_CUSTOMER",
              [("CUSTOMER_KEY", "Customer Key"), ("SEGMENT", "Segment"), ("CUSTOMER_REGION", "Customer Region"),
               ("LOYALTY_MEMBER", "Loyalty Member")])
    date = wh("e-date", "Date", "DIM_DATE",
              [("DATE_KEY", "Date Key"), ("CAL_DATE", "Cal Date"), ("YEAR_NUM", "Year Num"),
               ("MONTH_NUM", "Month Num"), ("MONTH_NAME", "Month Name")],
              calcs=[{"id": "e-date/month", "name": "Month", "formula": 'DateTrunc("month", [Cal Date])'}])
    src = wh("e-sales-src", "Sales (source)", "FACT_SALES", SALES_COLS, rels=sales_rels("e-sales-src"))
    # child: same columns re-exposed from the base, own copy of the relationships
    ccols = [{"id": f"e-sales/{c}", "name": n, "formula": f"[Sales (source)/{n}]"} for c, n in SALES_COLS]
    ccols.append({"id": "e-sales/revenue", "name": "Revenue", "formula": f"[Quantity] * [Unit Price] * (1 - [Discount])"})
    child = {"id": "e-sales", "kind": "table", "name": "Sales",
             "source": {"kind": "table", "elementId": "e-sales-src"},
             "columns": ccols, "order": [c["id"] for c in ccols],
             "relationships": sales_rels("e-sales")}
    return {"name": DM_NAME, "schemaVersion": 1, "folderId": env("PROBE_FOLDER_ID"),
            "pages": [{"id": "p1", "name": "Page 1",
                       "elements": [cat, prod, sku, store, cust, date, src, child]}]}


# ----------------------------------------------------------------- workbook
def wb_contents(dm_id, el, variant):
    """Build the workbook contents. `el` maps DM element name -> id; `variant`
    selects the P3 value-list form."""
    sales = el["Sales"]
    region_col = "[Sales/Customer/Customer Region]"
    loyalty = "[Sales/Customer/Loyalty Member]"
    cat = dict(id="ch-cat", kind="bar-chart", name="Revenue by category", source=dm_src(dm_id, sales),
               columns=[col("c-cat", "Category", "[Sales/SKU/Product/Category/Category Name]"),
                        col("c-rev", "Revenue", "Sum([Sales/Revenue])"),
                        col("c-reg", "Customer Region", region_col)],
               xAxis={"columnId": "c-cat"}, yAxis={"columnIds": ["c-rev"]}, stacking="none")
    ship = dict(id="ch-ship", kind="line-chart", name="Revenue by ship month", source=dm_src(dm_id, sales),
                columns=[col("s-month", "Ship Month", "[Sales/Date (Ship Date Key)/Month]"),
                         col("s-rev", "Revenue", "Sum([Sales/Revenue])"),
                         col("s-reg", "Customer Region", region_col)],
                xAxis={"columnId": "s-month"}, yAxis={"columnIds": ["s-rev"]})
    rel5 = dict(id="ch-rel", kind="bar-chart", name="Revenue by store region and brand", source=dm_src(dm_id, sales),
                columns=[col("r-sr", "Store Region", "[Sales/Store/Store Region]"),
                         col("r-brand", "Brand", "[Sales/SKU/Product/Brand]"),
                         col("r-rev", "Revenue", "Sum([Sales/Revenue])"),
                         col("r-reg", "Customer Region", region_col)],
                xAxis={"columnId": "r-sr"}, yAxis={"columnIds": ["r-rev"]}, color={"by": "category", "column": "r-brand"})
    loy = dict(id="ch-loy", kind="bar-chart", name="Revenue by segment", source=dm_src(dm_id, sales),
               columns=[col("l-seg", "Segment", "[Sales/Customer/Segment]"),
                        col("l-rev", "Revenue", "Sum([Sales/Revenue])"),
                        col("l-txt", "Loyalty Text", f'If(IsNull({loyalty}), Null, If({loyalty}, "True", "False"))')],
               xAxis={"columnId": "l-seg"}, yAxis={"columnIds": ["l-rev"]}, stacking="none")
    if variant in ("direct", "direct+reader"):
        value_src = {"kind": "source", "source": dm_src(dm_id, el["Customer"]), "columnId": "e-cust/CUSTOMER_REGION"}
    else:
        value_src = {"kind": "source", "source": {"kind": "table", "elementId": "ch-cat"}, "columnId": "c-reg"}
    ctl = dict(kind="control", id="ctl-region", controlId="Region", name="Customer region", controlType="list",
               mode="include", selectionMode="multiple", values=[], source=value_src,
               filters=[{"source": {"kind": "table", "elementId": "ch-cat"}, "columnId": "c-reg"},
                        {"source": {"kind": "table", "elementId": "ch-ship"}, "columnId": "s-reg"}])
    ctl2 = dict(kind="control", id="ctl-loy", controlId="Loyalty", name="Loyalty member", controlType="list",
                mode="include", selectionMode="multiple", values=[],
                source={"kind": "source", "source": {"kind": "table", "elementId": "ch-loy"}, "columnId": "l-txt"},
                filters=[{"source": {"kind": "table", "elementId": "ch-loy"}, "columnId": "l-txt"}])
    ctl3 = dict(kind="control", id="ctl-single", controlId="RegionOne", name="Region (single)", controlType="list",
                mode="include", selectionMode="single", value="West",
                source={"kind": "source", "source": {"kind": "table", "elementId": "ch-cat"}, "columnId": "c-reg"},
                filters=[{"source": {"kind": "table", "elementId": "ch-rel"}, "columnId": "r-reg"}])
    vals = dict(id="ch-vals", kind="bar-chart", name="Customer region domain", source=dm_src(dm_id, sales),
                columns=[col("v-reg", "Customer Region", region_col), col("v-q", "Quantity", "Sum([Sales/Quantity])")],
                xAxis={"columnId": "v-reg"}, yAxis={"columnIds": ["v-q"]}, stacking="none")
    elements = [cat, ship, rel5, loy, vals, ctl, ctl2, ctl3]
    if variant == "direct+reader":
        # a workbook data element that reads the Customer element directly
        elements.insert(0, dict(id="tbl-cust", kind="table", name="Customer reader", source=dm_src(dm_id, el["Customer"]),
                                columns=[col("t-reg", "Customer Region", "[Customer/Customer Region]")]))
    return {"schemaVersion": 1, "kind": "workbook", "pages": [{"id": "pg1", "name": "Probe"}], "elements": elements,
            "layout": layout_xml("pg1", elements)}


def dry_run(contents):
    body = P.code_rep.create_body(contents, extra={"name": WB_NAME, "folderId": env("PROBE_FOLDER_ID")}, dry_run=True)
    try:
        r = P.sigma_rest.request("post", P.code_rep.create_path(), json.dumps(body).encode())
        return {"ok": True, "warnings": (r or {}).get("warnings")}
    except P.sigma_rest.SigmaError as e:
        return {"ok": False, "error": str(e).split("\n", 1)[-1][:600]}



def run_variant(variant, dm_id, el, created, out):
    """Build the workbook for one P3 value-list variant and run the checks."""
    contents = wb_contents(dm_id, el, variant)
    wb = P.post_wb(contents, name=WB_NAME + f" ({variant})")
    created.append(wb["workbookId"])
    wid = wb["workbookId"]
    doc = wb.get("contents") or wb.get("document") or {}
    out["readback_controls"] = [
        {k: v for k, v in e.items() if k in ("id", "controlId", "controlType", "selectionMode", "mode", "value", "values", "source")}
        for e in (doc.get("elements") or []) if e.get("kind") == "control"]
    out["readback_columns"] = {e["id"]: [(c.get("name"), c.get("formula")) for c in e.get("columns", [])]
                               for e in (doc.get("elements") or []) if e.get("kind") not in ("control",)}
    ex = {}

    def exp(eid, params=None):
        k = (eid, json.dumps(params, sort_keys=True))
        if k not in ex:
            ex[k] = P.export_rows(wid, eid, params)
        return ex[k]

    chk = out.setdefault("checks", {})

    # P1: bar by category through Sales/SKU/Product/Category (three hops)
    t = lower_keys(truth(f"c.CATEGORY_NAME AS category, {REV} AS revenue", group="GROUP BY 1"))
    a = exp("ch-cat")
    chk["P1"] = {**verdict(a, t, ["category"]), "formula": "[Sales/SKU/Product/Category/Category Name]",
                 "raw_header": list(a[0].keys()) if a else None}
    # P5: related columns picked from the child (Store + SKU/Product), color by brand
    # P6: by month through the SECOND (inactive) date relationship
    t = lower_keys(truth(f"TO_CHAR(DATE_TRUNC('month', sd.CAL_DATE), 'YYYY-MM') AS ship_month, {REV} AS revenue",
                         group="GROUP BY 1"))
    a = norm_month(exp("ch-ship"), "Ship Month")
    t_ord = lower_keys(truth(f"TO_CHAR(DATE_TRUNC('month', od.CAL_DATE), 'YYYY-MM') AS ship_month, {REV} AS revenue",
                             group="GROUP BY 1"))
    nd = differs(t, t_ord, ["ship_month"])
    v6 = verdict(a, t, ["ship_month"])
    v6.update({"ship_vs_order_truth_months_differing": nd, "truth_distinguishes_relationships": nd > 0,
               "formula": "[Sales/Date (Ship Date Key)/Month]"})
    v6["pass"] = v6["pass"] and nd > 0
    chk["P6"] = v6
    # P2: list control on a column no axis shows, two targets, with and without a pick
    p2 = {}
    t_all = lower_keys(truth(f"c.CATEGORY_NAME AS category, {REV} AS revenue", group="GROUP BY 1"))
    t_w = lower_keys(truth(f"c.CATEGORY_NAME AS category, {REV} AS revenue", where="WHERE cu.CUSTOMER_REGION = 'West'",
                           group="GROUP BY 1"))
    t_ws = lower_keys(truth(f"TO_CHAR(DATE_TRUNC('month', sd.CAL_DATE), 'YYYY-MM') AS ship_month, {REV} AS revenue",
                            where="WHERE cu.CUSTOMER_REGION = 'West'", group="GROUP BY 1"))
    p2["chart_cat_no_pick"] = verdict(exp("ch-cat"), t_all, ["category"])
    p2["chart_cat_west"] = verdict(exp("ch-cat", {"Region": "West"}), t_w, ["category"])
    p2["chart_ship_west"] = verdict(norm_month(exp("ch-ship", {"Region": "West"}), "Ship Month"), t_ws, ["ship_month"])
    # multi-pick wire form: informational (which string encoding the export accepts)
    t_we = lower_keys(truth(f"c.CATEGORY_NAME AS category, {REV} AS revenue",
                            where="WHERE cu.CUSTOMER_REGION IN ('West', 'East')", group="GROUP BY 1"))
    multi = {}
    for label, val in (("comma", "West,East"), ("json_array_string", '["West","East"]')):
        try:
            multi[label] = verdict(P.export_rows(wid, "ch-cat", {"Region": val}), t_we, ["category"])
        except Exception as e:
            multi[label] = {"pass": False, "error": str(e).split("\n", 1)[-1][:200]}
    p2["multi_pick_forms_informational"] = multi
    nd_cat, nd_ship = differs(t_w, t_all, ["category"]), differs(t_ws, lower_keys(truth(
        f"TO_CHAR(DATE_TRUNC('month', sd.CAL_DATE), 'YYYY-MM') AS ship_month, {REV} AS revenue", group="GROUP BY 1")), ["ship_month"])
    p2["west_vs_unfiltered_truth_differing"] = {"category": nd_cat, "ship_month": nd_ship}
    p2["pass"] = all(v["pass"] for k, v in p2.items() if k.startswith("chart_")) and nd_cat > 0 and nd_ship > 0
    p2["control_form"] = "list, selectionMode multiple, values [], filters -> [chart column Customer Region] x2; export parameters {\"Region\": \"West\"} (value is a STRING; an array is rejected 400)"
    chk["P2"] = p2
    # P2b: single-select default via `value`
    t_rel_w = lower_keys(truth(f"st.STORE_REGION AS store_region, p.BRAND AS brand, {REV} AS revenue",
                               where="WHERE cu.CUSTOMER_REGION = 'West'", group="GROUP BY 1, 2"))
    a = exp("ch-rel")
    t_rel_all = lower_keys(truth(f"st.STORE_REGION AS store_region, p.BRAND AS brand, {REV} AS revenue", group="GROUP BY 1, 2"))
    nd_rel = differs(t_rel_w, t_rel_all, ["store_region", "brand"])
    chk["P2b_single_default_value"] = {**verdict(a, t_rel_w, ["store_region", "brand"]),
                                       "west_vs_unfiltered_truth_differing": nd_rel,
                                       "readback": [c for c in out["readback_controls"] if c["id"] == "ctl-single"]}
    chk["P2b_single_default_value"]["pass"] = chk["P2b_single_default_value"]["pass"] and nd_rel > 0
    chk["P5"] = {**verdict(exp("ch-rel", {"RegionOne": "West"}), t_rel_w, ["store_region", "brand"]),
                 "note": "related columns [Sales/Store/Store Region], [Sales/SKU/Product/Brand] read from the child; "
                         "values compared under the single-select West default"}
    # P12: boolean slicer through a text filter column
    p12 = {}
    t_blank = lower_keys(truth(f"cu.SEGMENT AS segment, {REV} AS revenue", group="GROUP BY 1"))
    for label, params, cond in (("True", {"Loyalty": "True"}, "WHERE cu.LOYALTY_MEMBER = TRUE"),
                                ("False", {"Loyalty": "False"}, "WHERE cu.LOYALTY_MEMBER = FALSE"),
                                ("blank", None, "")):
        t = lower_keys(truth(f"cu.SEGMENT AS segment, {REV} AS revenue", where=cond, group="GROUP BY 1"))
        p12[label] = verdict(exp("ch-loy", params), t, ["segment"])
        if label != "blank":
            p12[label]["differs_from_unfiltered_truth"] = differs(t, t_blank, ["segment"])
            p12[label]["pass"] = p12[label]["pass"] and p12[label]["differs_from_unfiltered_truth"] > 0
    p12["blank_means"] = "no selection (unfiltered state: every row incl. NULL loyalty), not a null pick"
    p12["pass"] = all(v["pass"] for v in p12.values() if isinstance(v, dict))
    p12["formula"] = 'If(IsNull([Sales/Customer/Loyalty Member]), Null, If([Sales/Customer/Loyalty Member], "True", "False"))'
    chk["P12"] = p12
    # P3: the control's listed values vs SQL DISTINCT. The control element itself cannot be exported
    # (400), so the value list is read from the column the control lists from, plus the chart-domain.
    db, sc = env("PROBE_DB"), env("PROBE_SCHEMA")
    dom_fact = lower_keys(truth("cu.CUSTOMER_REGION AS customer_region, SUM(f.QUANTITY) AS quantity", group="GROUP BY 1"))
    p3 = {"control_source_readback": [c["source"] for c in out["readback_controls"] if c["id"] == "ctl-region"],
          "listed_from_chart_column": verdict(exp("ch-vals"), dom_fact, ["customer_region"]),
          "truth_distinct_incl_null": sorted(str(r["customer_region"]) for r in dom_fact)}
    if variant == "fallback":
        want_src = {"kind": "source", "source": {"kind": "table", "elementId": "ch-cat"}, "columnId": "c-reg"}
        col_formula = dict(out["readback_columns"]["ch-cat"]).get("Customer Region")
        src_ok = p3["control_source_readback"] == [want_src] and col_formula == "[Sales/Customer/Customer Region]"
        p3["control_source_expected"] = {**want_src, "column_formula": "[Sales/Customer/Customer Region]"}
    else:
        want_src = {"kind": "source", "source": {"kind": "data-model", "dataModelId": dm_id, "elementId": el["Customer"]},
                    "columnId": "e-cust/CUSTOMER_REGION"}
        src_ok = p3["control_source_readback"] == [want_src]
        p3["control_source_expected"] = want_src
    p3["control_source_matches_intended"] = src_ok
    # the controls endpoint lists names and value TYPES only (no values): evidence, not a value check
    p3["controls_endpoint"] = P.sigma_rest.request("get", f"/v2/workbooks/{wid}/controls")
    p3["pass"] = p3["listed_from_chart_column"]["pass"] and src_ok
    if variant == "direct+reader":
        truth_dim = snow(f"SELECT DISTINCT CUSTOMER_REGION AS customer_region FROM {db}.{sc}.DIM_CUSTOMER")
        got = sorted({str(r.get("Customer Region")) for r in exp("tbl-cust")})
        want = sorted(str(r["customer_region"]) for r in truth_dim)
        p3["direct_element_column"] = {"listed": got, "truth": want, "pass": bool(want) and got == want}
        p3["pass"] = p3["pass"] and p3["direct_element_column"]["pass"]
    chk["P3_value_list"] = p3


def main():
    created = []
    result = {"variants": {}, "dry_runs": {}, "checks": {}}
    try:
        dm = P.post_dm(dm_spec())
        created.append(dm["dataModelId"])
        els = [(e.get("name"), e.get("id")) for pg in dm["pages"] for e in pg["elements"]]
        el = dict(els)
        result["dm_elements"] = [n for n, _ in els]
        rels = {}
        for pg in dm["pages"]:
            for e in pg["elements"]:
                if e.get("relationships"):
                    rels[e["name"]] = [r.get("name") for r in e["relationships"]]
        result["dm_relationships_readback"] = rels
        for v in ("direct", "direct+reader", "fallback"):
            result["dry_runs"][v] = dry_run(wb_contents(dm["dataModelId"], el, v))
        valid = [v for v, r in result["dry_runs"].items() if r["ok"]]
        result["p3"] = {"direct_ok": result["dry_runs"]["direct"]["ok"],
                        "direct_with_reader_ok": result["dry_runs"]["direct+reader"]["ok"],
                        "fallback_ok": result["dry_runs"]["fallback"]["ok"],
                        "direct_error": result["dry_runs"]["direct"].get("error")}
        for v in valid:
            out = {}
            try:
                run_variant(v, dm["dataModelId"], el, created, out)
            except Exception as e:  # keep going: record, never hide
                out["error"] = f"{type(e).__name__}: {str(e)[:800]}"
            result["variants"][v] = out
    finally:
        result["cleanup"] = P.cleanup(created)
        result["cleanup_all_archived"] = all(result["cleanup"].values()) and bool(result["cleanup"])
        path = os.path.join(HERE, "results", "p_core.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(P.redact(result, P.redact_terms()), fh, indent=2, default=str)
            fh.write("\n")
    summ = {v: {k: c.get("pass") for k, c in o.get("checks", {}).items()} for v, o in result["variants"].items()}
    print(json.dumps(P.redact({"p3": result["p3"], "checks": summ, "cleanup_all_archived": result["cleanup_all_archived"]},
                              P.redact_terms()), indent=1))


if __name__ == "__main__":
    main()
