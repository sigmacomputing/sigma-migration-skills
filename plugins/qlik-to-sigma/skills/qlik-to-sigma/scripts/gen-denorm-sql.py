#!/usr/bin/env python3
"""gen-denorm-sql — build the denormalized SQL element from a reconcile map.

    python3 gen-denorm-sql.py --reconcile reconcile.json --database DEMO_DB --schema DEMO [--out denorm.json]

Consumes reconcile-columns.py output and auto-generates the Sigma data-model SQL element:
  - SELECT writes `<realColumn> AS <qlikField>` for every field (preserving Qlik names while
    pointing at real warehouse columns — the rename reconciliation)
  - infers LEFT JOINs: the fact (table named *FACT or with the most *_KEY fields) joined to
    each dim on a shared Qlik *_KEY field name (mapped to each side's real column)
  - translates a conservative set of row-wise Qlik LOAD expressions (If/Match,
    string/date helpers, arithmetic) to SQL; unsupported functions hard-fail
    instead of silently dropping a workbook field
Emits a ready-to-POST Sigma element `{kind:table, source:{kind:sql,connectionId,statement}, columns}`
with `[Custom SQL/<RAW alias>]` formulas. Drops this into build-sigma-dm.py's element list.
"""
import re, json, argparse, secrets, string, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlik_load_expr import translate as translate_load_expression

# Sigma's own display-name derivation keeps small particles lowercase unless
# first word: DAYS_TO_SHIP → "Days to Ship" (NOT "Days To Ship"). Verified
# empirically 2026-06-10 against a live DM readback (Sigma derived "Days to
# Ship", "Revenue per Order", "Ship via Air", "Year and Month"). Matching the
# rule here means workbook refs line up with Sigma-derived names with no
# defensive describe round-trips.
SIGMA_LOWERCASE = {"a","an","the","and","but","or","for","nor","so","yet",
                   "at","by","in","of","on","to","up","as","into","via","per"}
def disp(c):
    words = [w for w in c.lower().split("_") if w]
    return " ".join(w if (i and w in SIGMA_LOWERCASE) else w.capitalize()
                    for i, w in enumerate(words))
def nid(n=10): return "".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(n))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reconcile", required=True)
    ap.add_argument("--database", required=True); ap.add_argument("--schema", required=True)
    ap.add_argument("--connection", default=os.environ.get("SIGMA_CONNECTION_ID",""),
                    help="your Sigma warehouse connection id (or set SIGMA_CONNECTION_ID)")
    ap.add_argument("--out", default="denorm-element.json")
    a = ap.parse_args()
    tables = json.load(open(a.reconcile))
    def wh(t):
        s = re.sub(r"\.csv$", "", t["sourceTable"], flags=re.I)
        return s if "." in s else f'{a.database}.{a.schema}.{s}'
    keyfields = lambda t: [f["qlikField"] for f in t["fields"] if f["qlikField"].upper().endswith("_KEY")]
    # fact = name has FACT, else most *_KEY fields
    fact = next((t for t in tables if "FACT" in t["qlikTable"].upper()), None) \
        or max(tables, key=lambda t: len(keyfields(t)))
    dims = [t for t in tables if t is not fact]
    factkeys = set(k.upper() for k in keyfields(fact))
    real = lambda t, q: next(f["realColumn"] for f in t["fields"] if f["qlikField"] == q)

    select, joins, alias = [], [], {}
    unsupported = []
    def projection(table, field, table_alias):
        if field["realColumn"] == "*":
            return None
        if not field.get("isExpression"):
            return f'{table_alias}.{field["realColumn"]}'
        warehouse_columns = dict(table.get("warehouseColumns") or {})
        for base_field in table["fields"]:
            if base_field.get("isExpression") or base_field["realColumn"] == "*":
                continue
            actual = warehouse_columns.get(base_field["realColumn"].upper(), base_field["realColumn"])
            warehouse_columns[base_field["qlikField"].upper()] = actual
            warehouse_columns[base_field["realColumn"].upper()] = actual
        translated = translate_load_expression(
            field.get("loadExpression") or field["realColumn"], table_alias, warehouse_columns)
        if translated is None:
            unsupported.append(
                f'{table["qlikTable"]}.{field["qlikField"]} <- '
                f'{field.get("loadExpression") or field["realColumn"]}')
        return translated
    # fact columns (exclude raw keys we only use for joins? keep all non-key + measures; keep keys too is fine)
    for f in fact["fields"]:
        value = projection(fact, f, "f")
        if value is not None:
            select.append(f'{value} AS {f["qlikField"]}')
    # build a safe dim-alias sequence that skips 'f' (reserved for the fact table)
    _dim_aliases = [c for c in 'abcdeghijklmnopqrstuvwxyz']
    a_i = 0
    for d in dims:
        # find join key: a *_KEY qlikField in this dim that the fact also has
        jk = next((k for k in keyfields(d) if k.upper() in factkeys), None)
        al = _dim_aliases[a_i]; a_i += 1; alias[d["qlikTable"]] = al
        if jk:
            joins.append(f'LEFT JOIN {wh(d)} {al} ON f.{real(fact, jk)} = {al}.{real(d, jk)}')
        # dim descriptive columns (skip its own key columns to avoid dup)
        for f in d["fields"]:
            if f["realColumn"] == "*": continue
            if f["qlikField"].upper().endswith("_KEY"): continue
            value = projection(d, f, al)
            if value is not None and f.get("isExpression") and jk:
                # The expression belongs to the Qlik dimension table. A missing
                # LEFT JOIN has no dimension row, so its calculated fields must
                # remain null rather than evaluating an ELSE branch on SQL nulls.
                value = f"CASE WHEN {al}.{real(d, jk)} IS NULL THEN NULL ELSE {value} END"
            if value is not None:
                select.append(f'{value} AS {f["qlikField"]}')
    if unsupported:
        raise SystemExit(
            "FATAL: unsupported Qlik LOAD expression(s); refusing to build a partial denorm:\n  - "
            + "\n  - ".join(unsupported))
    sql = "SELECT\n  " + ",\n  ".join(select) + f"\nFROM {wh(fact)} f\n" + "\n".join(joins)

    # element columns: [Custom SQL/<ALIAS>] where ALIAS is the qlik field name (the SQL output col)
    cols, order = [], []
    seen = set()
    for line in select:
        qn = line.rsplit(" AS ", 1)[-1].strip()
        if qn in seen: continue
        seen.add(qn)
        cidv = nid(); cols.append({"id": cidv, "name": disp(qn), "formula": f"[Custom SQL/{qn}]"}); order.append(cidv)
    element = {"id": nid(), "kind": "table",
               "source": {"connectionId": a.connection, "kind": "sql", "statement": sql},
               "columns": cols, "order": order}
    expressions = [f["qlikField"] for t in tables for f in t["fields"] if f.get("isExpression")]
    json.dump({"element": element, "sql": sql, "calculatedFields": expressions}, open(a.out, "w"), indent=2)
    print("fact:", fact["qlikTable"], "| dims:", [d["qlikTable"] for d in dims], "| columns:", len(cols))
    print("--- generated denorm SQL ---")
    print(sql)

if __name__ == "__main__":
    main()
