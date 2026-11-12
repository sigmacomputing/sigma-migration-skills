#!/usr/bin/env python3
"""page-facts-multipage: execute the generated SQL in SQLite (stdlib) and check it.

  1. every page fact, rolled up to each visual (check-queries.json), MATCHes the independent
     oracle (oracle-queries.json) through parity-from-oracle.py --spec check-plan.json;
  2. the parameterized SQL with every control empty and the gate open equals the page fact
     (wire-slicer-gate.py --verify-out, slicer-gate-verify-plan.json);
  3. the parameterized SQL, rendered the way Sigma inlines control values, answers like the
     oracle's filtered scenario for a one-hop slicer, a two-hop (Blank) pick and a bridged slicer.

usage: check_sqlite.py <seed.sql> <page-facts dir> <work dir> <parity-from-oracle.py>
Exit 0 = all pass.
"""
import json
import os
import re
import sqlite3
import subprocess
import sys

# Visuals the oracle compiler cannot evaluate (ISBLANK is outside its grammar) are pinned by hand:
# a check query with neither an oracle nor a pin FAILS, it is never skipped.
PINNED = {
    "Store.Region=West": {"stock-cover__el-signed970db8": [{"Unassigned Stock": None}]},  # West stores all have a manager key
    "Manager.Manager Name=(Blank)": {"stock-cover__el-signed970db8": [{"Unassigned Stock": 7.0}]},  # store 13 only
}
SCENARIOS = [  # (page, page dir, control picks, oracle scenario)
    ("Stock Cover", "stock-cover", {"RegionFilter": ["West"]}, "Store.Region=West"),
    ("Stock Cover", "stock-cover", {"ManagerNameFilter2": ["(Blank)"]}, "Manager.Manager Name=(Blank)"),
    ("Rollup", "rollup", {"SupplierNameFilter2": ["Acme"]}, "Supplier.Supplier Name=Acme"),
]


def jload(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def jdump(obj, path):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f)


def rows(db, sql):
    cur = db.execute(sql)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def render(sql, picks):
    sql = re.sub(r"\{\{#formula ArrayLength\(\[([^\]]+)\]\)\}\}", lambda m: str(len(picks.get(m.group(1), []))), sql)
    return re.sub(r"\{\{([A-Za-z0-9_]+)\}\}", lambda m: "(" + ", ".join(
        "'%s'" % str(v).replace("'", "''") for v in (picks.get(m.group(1)) or [""])) + ")", sql)


def body(sql):
    return "\n".join(line for line in sql.split("\n") if not line.startswith("-- "))


def main(seed, pf_dir, work, parity):
    db = sqlite3.connect(":memory:")
    db.create_function("EQUAL_NULL", 2, lambda a, b: 1 if (a is None and b is None) or (a is not None and a == b) else 0,
                       deterministic=True)
    with open(seed, encoding="utf-8") as f:
        db.executescript(f.read())
    fails = 0
    for page in sorted(d for d in os.listdir(pf_dir) if os.path.isdir(os.path.join(pf_dir, d))):
        d = os.path.join(pf_dir, page)
        for src, dst in (("check-queries.json", "check-results.json"), ("oracle-queries.json", "oracle-results.json")):
            jdump({k: {"ok": True, "rows": rows(db, q)} for k, q in jload(os.path.join(d, src)).items()}, os.path.join(d, dst))
        r = subprocess.run([sys.executable, parity, "--spec", os.path.join(d, "check-plan.json"),
                            "--out-dir", os.path.join(work, "parity-" + page)], capture_output=True, text=True)
        print("     %s  page fact = oracle: %s" % ("ok " if r.returncode == 0 else "FAIL", page))
        fails += r.returncode != 0
    v = jload(os.path.join(work, "slicer-gate-verify.json"))
    jdump({k: {"ok": True, "rows": rows(db, q)} for k, q in v.items()}, os.path.join(work, "slicer-gate-verify-results.json"))
    r = subprocess.run([sys.executable, parity, "--spec", os.path.join(work, "slicer-gate-verify-plan.json"),
                        "--out-dir", os.path.join(work, "parity-verify")], capture_output=True, text=True)
    print("     %s  gated SQL, every control empty = page fact (%d page(s))" % ("ok " if r.returncode == 0 else "FAIL", len(v) // 2))
    fails += r.returncode != 0
    report = jload(os.path.join(work, "slicer-gate.json"))
    doc = jload(os.path.join(work, "workbook-spec.json"))["document"]
    els = {e["id"]: e for e in doc["elements"]}
    for page, slug, picks, scen in SCENARIOS:
        p = next(x for x in report["pages"] if x["page"] == page)
        live = body(render(els[p["parameterized"]]["source"]["statement"], picks))
        base = body(jload(os.path.join(pf_dir, slug, "page-fact.json"))["sql"])
        checks, oracle = jload(os.path.join(pf_dir, slug, "check-queries.json")), jload(os.path.join(pf_dir, slug, "oracle-queries.json"))
        n = bad = 0
        for key, q in checks.items():
            if key + "@" + scen in oracle:
                want = rows(db, oracle[key + "@" + scen])
            elif key in PINNED.get(scen, {}):
                want = PINNED[scen][key]
            else:
                print("     FAIL %s: %s has no oracle and no pinned value for %s" % (page, key, scen))
                bad += 1
                continue
            got = rows(db, q.replace(base, live))
            cols = list(want[0]) if want else []
            canon = lambda rs: sorted((tuple(round(r[c], 6) if isinstance(r[c], float) else r[c] for c in cols) for r in rs), key=repr)
            n += 1
            bad += canon(got) != canon(want)
        ok = n > 0 and bad == 0
        print("     %s  %s: slicer %s answers like the oracle (%d visual(s))" % ("ok " if ok else "FAIL", page, scen, n))
        fails += not ok
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:5]))
