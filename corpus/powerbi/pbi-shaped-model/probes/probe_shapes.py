"""Shared spec-building and truth helpers for the Power BI-shaped probes
(p_core.py, p_metrics.py). Env-only configuration; no values are hard-coded."""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import probe_lib as P  # noqa: E402

REV_SQL = "f.QUANTITY * f.UNIT_PRICE * (1 - f.DISCOUNT)"

def env(n):
    return P._env(n)


def snow(sql):
    """Read-only truth SQL through the snow CLI (connection name: PROBE_SNOW_CONNECTION).
    Returns rows with lower-case keys and decimals as floats."""
    p = subprocess.run(["snow", "sql", "-c", env("PROBE_SNOW_CONNECTION"), "-q", sql, "--format", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"snow sql failed: {(p.stderr or p.stdout)[:300]}")
    def num(v):
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)):
            return float(v)
        if isinstance(v, str) and re.fullmatch(r"-?\d+\.\d+", v):  # Snowflake decimals arrive as strings
            return float(v)
        return v
    return [{k.lower(): num(v) for k, v in r.items()} for r in json.loads(p.stdout)]


# --------------------------------------------------------------- data model
def tbl(table):
    return ["" + env("PROBE_DB"), env("PROBE_SCHEMA"), table]


def wh(eid, name, table, cols, rels=(), calcs=()):
    """A warehouse-table element. cols: [(WAREHOUSE_COL, 'Friendly Name')]."""
    conn = env("PROBE_CONNECTION_ID")
    columns = [{"id": f"{eid}/{c}", "name": n, "formula": f"[{table}/{n}]"} for c, n in cols]
    columns += list(calcs)
    return {"id": eid, "kind": "table", "name": name,
            "source": {"connectionId": conn, "kind": "warehouse-table", "path": tbl(table)},
            "columns": columns, "order": [c["id"] for c in columns],
            **({"relationships": list(rels)} if rels else {})}


def rel(rid, name, target, src_col, tgt_col):
    return {"id": rid, "name": name, "targetElementId": target,
            "keys": [{"sourceColumnId": src_col, "targetColumnId": tgt_col}]}


SALES_COLS = [("SALES_LINE_KEY", "Sales Line Key"), ("ORDER_NUMBER", "Order Number"),
              ("ORDER_DATE_KEY", "Order Date Key"), ("SHIP_DATE_KEY", "Ship Date Key"),
              ("SKU_KEY", "Sku Key"), ("CUSTOMER_KEY", "Customer Key"), ("STORE_KEY", "Store Key"),
              ("QUANTITY", "Quantity"), ("UNIT_PRICE", "Unit Price"), ("DISCOUNT", "Discount"),
              ("UNIT_COST", "Unit Cost")]


def sales_rels(prefix):
    """Relationships on a Sales element; column ids are `<prefix>/<COL>`."""
    return [
        rel(f"{prefix}-r-sku", "SKU", "e-sku", f"{prefix}/SKU_KEY", "e-sku/SKU_KEY"),
        rel(f"{prefix}-r-store", "Store", "e-store", f"{prefix}/STORE_KEY", "e-store/STORE_KEY"),
        rel(f"{prefix}-r-cust", "Customer", "e-cust", f"{prefix}/CUSTOMER_KEY", "e-cust/CUSTOMER_KEY"),
        rel(f"{prefix}-r-date", "Date", "e-date", f"{prefix}/ORDER_DATE_KEY", "e-date/DATE_KEY"),
        rel(f"{prefix}-r-ship", "Date (Ship Date Key)", "e-date", f"{prefix}/SHIP_DATE_KEY", "e-date/DATE_KEY"),
    ]



def col(cid, name, formula):
    return {"id": cid, "name": name, "formula": formula}


def dm_src(dm_id, el):
    return {"kind": "data-model", "dataModelId": dm_id, "elementId": el}



def layout_xml(page_id, elements):
    """One full-width row per element (probe only; layout is not under test)."""
    rows, r = [], 1
    for e in elements:
        h = 3 if e["kind"] == "control" else 10
        rows.append(f'  <Element elementId="{e["id"]}" gridColumn="1 / 25" gridRow="{r} / {r + h}"/>')
        r += h
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">\n'
            + "\n".join(rows) + "\n</Page>")



FACT = "{db}.{sc}.FACT_SALES f"


def truth(select, where="", group=""):
    db, sc = env("PROBE_DB"), env("PROBE_SCHEMA")
    q = (f"SELECT {select} FROM {db}.{sc}.FACT_SALES f "
         f"LEFT JOIN {db}.{sc}.DIM_SKU s ON s.SKU_KEY = f.SKU_KEY "
         f"LEFT JOIN {db}.{sc}.DIM_PRODUCT p ON p.PRODUCT_KEY = s.PRODUCT_KEY "
         f"LEFT JOIN {db}.{sc}.DIM_CATEGORY c ON c.CATEGORY_KEY = p.CATEGORY_KEY "
         f"LEFT JOIN {db}.{sc}.DIM_STORE st ON st.STORE_KEY = f.STORE_KEY "
         f"LEFT JOIN {db}.{sc}.DIM_CUSTOMER cu ON cu.CUSTOMER_KEY = f.CUSTOMER_KEY "
         f"LEFT JOIN {db}.{sc}.DIM_DATE od ON od.DATE_KEY = f.ORDER_DATE_KEY "
         f"LEFT JOIN {db}.{sc}.DIM_DATE sd ON sd.DATE_KEY = f.SHIP_DATE_KEY "
         f"{where} {group}")
    return snow(q)


def norm_month(rows, key):
    for r in rows:
        if isinstance(r.get(key), str):
            r[key] = r[key][:7]
    return rows


def lower_keys(rows):
    return [{k.lower().replace(" ", "_"): v for k, v in r.items()} for r in rows]


def verdict(actual, expect, keys):
    """compare() result -> {pass, rows, detail}. Rows must match one-for-one."""
    c = P.compare(lower_keys(actual), expect, keys)
    ok = (c["matched"] == len(expect) and not c["mismatched"] and not c["missing"]
          and not c["extra"] and not c["duplicates"]["actual"] and len(actual) == len(expect)
          and len(expect) > 0 and len(actual) > 0)  # an empty comparison proves nothing
    d = {"pass": ok, "rows_actual": len(actual), "rows_truth": len(expect), "matched": c["matched"]}
    if not ok:
        d["detail"] = {k: (v[:5] if isinstance(v, list) else v) for k, v in c.items()}
        d["sample_actual"] = actual[:3]
    return d


REV = f"SUM({REV_SQL})"


def differs(t1, t2, keys, val="revenue"):
    """Number of keys whose value differs between two truth sets (or exists in only one).
    A filtered/other-path check is only meaningful when this is > 0."""
    k = lambda r: "|".join(P._norm(r.get(x)) for x in keys)
    m1, m2 = {k(r): r.get(val) for r in t1}, {k(r): r.get(val) for r in t2}
    return sum(1 for x in set(m1) | set(m2) if x not in m1 or x not in m2 or not P._eq(m1[x], m2[x], 1e-6))

