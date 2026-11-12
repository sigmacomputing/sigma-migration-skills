#!/usr/bin/env python3
"""integrate-page-fact.py - fold page facts into the data-model spec and the master-map.

Input: one or more page-fact.json files (scaffold-page-fact.py writes them; the agent completes
their TODOs), or a directory holding <page>/page-fact.json. Two independent steps, run at the
point of the pipeline where each artifact exists (migrate-powerbi.rb --page-facts runs both):

  --dm-spec FILE --connection ID
      Adds (or replaces, by name) one Custom SQL element per page fact in the DM spec:
      id pf-<hash>, name "<page> Page Fact", one column per page-fact column
      ([Custom SQL/<out>] named <name>). Written in place. With --check nothing is written and
      the exit code is 3 when an element is missing or its SQL differs (the DM-reuse path).

  --master-map FILE [--dm-readback FILE]
      Adds a master per page fact (id master-pf-<hash>; element id from the readback by name,
      else the spec id) and page-scoped bindings under master-map `page_fields`:
      {"<page title>": {"<queryRef>": {master, ref, agg: null}}}. build-workbook-from-pbir.rb
      uses them for that page only. A ref's {C:<column>} placeholders become [<master id>/<column>];
      an unknown column is an error (exit 1), never a silent Null.

A page fact that still has TODO measures is refused (exit 1) unless --allow-todo, which
binds each TODO measure to its all-NULL stub column so mixed visuals retain the field and every
visual remains on the slicer-gated page fact. Python stdlib only; offline.
"""
import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
from pbi_page_closure import short_hash  # noqa: E402


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def page_fact_files(inputs):
    out = []
    for p in inputs:
        if os.path.isdir(p):
            out += sorted(glob.glob(os.path.join(p, "*", "page-fact.json")))
            if os.path.exists(os.path.join(p, "page-fact.json")):
                out.append(os.path.join(p, "page-fact.json"))
        else:
            out.append(p)
    return out


def element_id(pf):
    return "pf-" + short_hash(pf["name"], 10)


def master_id(pf):
    return "master-pf-" + short_hash(pf["name"], 8)


def dm_element(pf, connection):
    eid = element_id(pf)
    cols = [{"id": "%s-%s" % (eid, short_hash(c["name"], 6)), "formula": "[Custom SQL/%s]" % c["out"], "name": c["name"]}
            for c in pf["columns"]]
    return {"id": eid, "kind": "table", "name": pf["name"],
            "source": {"kind": "sql", "connectionId": connection, "statement": pf["sql"]},
            "columns": cols, "order": [c["id"] for c in cols]}


def spec_elements(dm):
    doc = dm
    for key in ("sigmaDataModel", "dataModel", "spec"):
        if isinstance(doc.get(key), dict) and doc[key].get("pages"):
            doc = doc[key]
    if not doc.get("pages"):
        doc["pages"] = [{"id": "pg-dm", "name": "Page 1", "elements": []}]
    return doc


def todo_problem(pf, allow):
    todo = pf.get("todo") or []
    if todo and not allow:
        return "page fact %r still has %d TODO(s) (%s): fill them in page-fact.json or pass --allow-todo" % (
            pf["name"], len(todo), ", ".join(str(t.get("measure")) for t in todo[:4]))
    return None


def integrate_dm(pfs, dm_path, connection, check):
    dm = load(dm_path)
    doc = spec_elements(dm)
    all_els = [(p, e) for p in doc["pages"] for e in p.get("elements", [])]
    changes = []
    for pf in pfs:
        new = dm_element(pf, connection)
        hit = [(p, e) for p, e in all_els if e.get("name") == pf["name"] or e.get("id") == new["id"]]
        if hit:
            p, old = hit[0]
            same = (old.get("source") or {}).get("statement") == pf["sql"] and \
                [c.get("name") for c in old.get("columns", [])] == [c["name"] for c in new["columns"]]
            if same:
                continue
            changes.append("replace %s (%s)" % (pf["name"], old.get("id")))
            if not check:
                new["id"] = old.get("id") or new["id"]
                p["elements"][p["elements"].index(old)] = new
        else:
            changes.append("add %s (%s)" % (pf["name"], new["id"]))
            if not check:
                doc["pages"][0].setdefault("elements", []).append(new)
    if changes and not check:
        save(dm_path, dm)
    return changes


def integrate_master_map(pfs, mm_path, readback_path, allow_todo):
    mm = load(mm_path)
    masters = mm.setdefault("masters", {})
    page_fields = mm.setdefault("page_fields", {})
    rb_els = []
    dm_id = None
    if readback_path:
        rb = load(readback_path)
        dm_id = rb.get("dataModelId")
        rb_els = [e for p in (rb.get("pages") or []) for e in p.get("elements") or []]
    dm_id = dm_id or next((m.get("data_model") for m in masters.values() if m.get("data_model")), None)
    errors, report = [], []
    for pf in pfs:
        el = next((e for e in rb_els if e.get("name") == pf["name"]), None)
        if readback_path and el is None:
            errors.append("page fact %r is not in the data-model readback (post the DM first)" % pf["name"])
            continue
        mid = master_id(pf)
        cols = [{"id": "mc-" + short_hash(pf["name"] + "/" + c["name"], 10), "name": c["name"],
                 "formula": "[%s/%s]" % (pf["name"], c["name"])} for c in pf["columns"]]
        masters[pf["name"]] = {"id": mid, "element_id": (el or {}).get("id") or element_id(pf), "data_model": dm_id,
                               "columns": cols, "metrics": [], "page_fact": pf.get("page")}
        names = {c["name"] for c in pf["columns"]}

        def resolve(ref):
            def rep(m):
                col = m.group(1)
                if col not in names:
                    errors.append("%s: no page-fact column %r" % (pf["name"], col))
                    return m.group(0)
                return "[%s/%s]" % (mid, col)
            return re.sub(r"\{C:([^{}]+)\}", rep, ref)

        scoped = page_fields.setdefault(pf["page"], {})
        n_f = n_d = n_t = 0
        for qr, spec in (pf.get("fields") or {}).items():
            if spec.get("todo"):
                n_t += 1
            scoped[qr] = {"master": pf["name"], "ref": resolve(spec["ref"]), "agg": None}
            if spec.get("format"):
                scoped[qr]["format"] = spec["format"]
            n_f += 1
        for qr, col in (pf.get("dims") or {}).items():
            if col not in names:
                errors.append("%s: dim %r binds unknown column %r" % (pf["name"], qr, col))
                continue
            scoped[qr] = {"master": pf["name"], "ref": "[%s/%s]" % (mid, col), "agg": None}
            n_d += 1
        report.append("%s -> master %s, page %r: %d measure(s), %d dimension(s)%s"
                      % (pf["name"], mid, pf["page"], n_f, n_d, (", %d TODO measure stub(s)" % n_t) if n_t else ""))
    if not errors:
        save(mm_path, mm)
    return report, errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("inputs", nargs="+", help="page-fact.json files or directories of <page>/page-fact.json")
    ap.add_argument("--dm-spec")
    ap.add_argument("--connection")
    ap.add_argument("--check", action="store_true", help="with --dm-spec: report, write nothing, exit 3 on a difference")
    ap.add_argument("--master-map")
    ap.add_argument("--dm-readback")
    ap.add_argument("--allow-todo", action="store_true")
    a = ap.parse_args(argv)
    if not a.dm_spec and not a.master_map:
        ap.error("give --dm-spec and/or --master-map")
    files = page_fact_files(a.inputs)
    if not files:
        print("integrate-page-fact: no page-fact.json under %s" % ", ".join(a.inputs), file=sys.stderr)
        return 2
    pfs = [load(f) for f in files]
    for pf in pfs:
        why = todo_problem(pf, a.allow_todo)
        if why:
            print("integrate-page-fact: " + why, file=sys.stderr)
            return 1
    if a.dm_spec:
        if not a.connection and not a.check:
            ap.error("--dm-spec needs --connection (the Sigma connection the page-fact SQL runs on)")
        changes = integrate_dm(pfs, a.dm_spec, a.connection, a.check)
        for c in changes:
            print("data model: %s%s" % (c, " (check only)" if a.check else ""))
        if not changes:
            print("data model: %d page fact(s) already current" % len(pfs))
        if a.check and changes:
            return 3
    if a.master_map:
        report, errors = integrate_master_map(pfs, a.master_map, a.dm_readback, a.allow_todo)
        for r in report:
            print("master-map: " + r)
        if errors:
            for e in errors:
                print("integrate-page-fact: ERROR " + e, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
