#!/usr/bin/env python3
"""Phase 2b (Performance scan): cheap regex scan of a LookML project for
EXPENSIVE derived tables, so a migration doesn't blindly port slow SQL into
Sigma. The converter turns every `derived_table` into ONE Sigma Custom SQL
element with the SQL carried through verbatim (nested derived views inline as
stacked CTEs into a single element) — so a slow Looker derived table stays slow
in Sigma. This flags the ones worth MATERIALIZING (or rebuilding) instead.

NEVER SILENT, but NEVER SLOW when there's nothing to decide: if the project has
no derived tables, this prints NOTHING and exits 0. Findings are INFORMATIONAL —
this never blocks a migration (unlike the RLS gate); it recommends. Exit 2 only
on a usage/IO error.

Signals per derived table (from refs/layered-lookml.md + the converter's own
warning triggers in converter/lookml.mjs):
  - no_persistence   ephemeral derived_table with no datagroup_trigger /
                     persist_for / sql_trigger_value → re-runs every query
  - persisted_pdt    has a persistence hint → author already deemed it expensive
  - incremental_pdt  increment_key / {% incrementcondition %} → Sigma has no
                     incremental equiv; the element recomputes its full SQL
  - nested_dt        sql references ${other_view.SQL_TABLE_NAME} of ANOTHER
                     derived view → inlined as stacked CTEs (depth = # refs)
  - ndt              derived_table.explore_source (Native Derived Table)
  - sql complexity   counts of JOIN / GROUP BY / window OVER( / CTE (WITH ... AS)
  - cte_fragment     leading-comma CTE-continuation fragment (manual SQL layering)
  - warehouse_hints  cluster_keys / sortkeys / distribution / partition_keys

Recommendation ∈ {materialize, rebuild-as-element, leave-inline}. The
`materialize` set is the handoff to `--materialize-derived` (migrate-looker) and,
post-migration, to the `sigma-materialization-advisor` skill (credit ranking).

Dependency-free (stdlib only). Mirrors the style of detect_rls.py.

Usage:
    python3 detect_derived_perf.py <lookml_dir_or_file> [<more> ...] [--json]
        [--scope-explores e1,e2]   # only flag derived tables the explore(s) use
"""
import argparse
import json
import os
import re
import sys

# --- regexes (loose, whitespace-tolerant — LookML style) -------------------
_VIEW = re.compile(r"\bview\s*:\s*([A-Za-z0-9_]+)\s*\{")
_DERIVED = re.compile(r"\bderived_table\s*:\s*\{")
# derived_table's SQL: first `sql: ... ;;` after the derived_table opener
_DT_SQL = re.compile(r"\bsql\s*:\s*(.*?);;", re.DOTALL)
_SQL_TABLE_REF = re.compile(r"\$\{\s*([A-Za-z0-9_]+)\.SQL_TABLE_NAME\s*\}")
_PERSIST = re.compile(r"\b(datagroup_trigger|persist_for|sql_trigger_value|materialized_view)\s*:")
_INCREMENTAL = re.compile(r"\bincrement_key\s*:|\{%\s*incrementcondition")
_EXPLORE_SOURCE = re.compile(r"\bexplore_source\s*:")
_WH_HINTS = re.compile(r"\b(cluster_keys|sortkeys|distribution|partition_keys|indexes)\s*:")
# explore → the views it references (from + join {from|view}), for scoping
_EXPLORE = re.compile(r"\bexplore\s*:\s*([A-Za-z0-9_]+)\s*\{")
_FROM = re.compile(r"\bfrom\s*:\s*([A-Za-z0-9_]+)")
_JOIN = re.compile(r"\bjoin\s*:\s*([A-Za-z0-9_]+)")

HIGH, MED = 10, 4


def _view_slabs(text):
    """Yield (view_name, slab_text). A slab is a view's text from its `view:`
    opener to the next view opener (or EOF) — loose block scan like detect_rls,
    robust to nested braces we don't need to balance."""
    starts = [(m.group(1), m.start()) for m in _VIEW.finditer(text)]
    for i, (name, s) in enumerate(starts):
        e = starts[i + 1][1] if i + 1 < len(starts) else len(text)
        yield name, text[s:e]


def _derived_sql(slab):
    """The derived_table's SQL text (first `sql: … ;;` after the opener), or ''."""
    md = _DERIVED.search(slab)
    if not md:
        return ""
    ms = _DT_SQL.search(slab, md.end())
    return (ms.group(1).strip() if ms else "")


def _count(pat, s):
    return len(re.findall(pat, s, re.IGNORECASE))


def _analyze_view(name, slab, derived_names):
    """Return a finding dict for a derived-table view, or None."""
    if not _DERIVED.search(slab):
        return None
    dsql = _derived_sql(slab)
    signals, cost = [], 0

    persisted = bool(_PERSIST.search(slab))
    incremental = bool(_INCREMENTAL.search(slab))
    ndt = bool(_EXPLORE_SOURCE.search(slab))
    wh_hints = bool(_WH_HINTS.search(slab))
    cte_fragment = dsql.lstrip().startswith(",")

    refs = [v for v in _SQL_TABLE_REF.findall(dsql) if v != name]
    nested_refs = [v for v in refs if v in derived_names]

    joins = _count(r"\bjoin\b", dsql)
    group_bys = _count(r"\bgroup\s+by\b", dsql)
    windows = _count(r"\bover\s*\(", dsql)
    ctes = _count(r"\bwith\b|\)\s*,\s*[A-Za-z0-9_]+\s+as\s*\(", dsql)

    cost += joins * 2 + group_bys * 2 + windows * 3 + ctes * 2
    if joins:
        signals.append(f"joins:{joins}")
    if group_bys:
        signals.append(f"group_by:{group_bys}")
    if windows:
        signals.append(f"windows:{windows}")
    if ctes:
        signals.append(f"cte:{ctes}")
    if nested_refs:
        cost += 5
        signals.append(f"nested_dt:{len(nested_refs)}")
    if incremental:
        cost += 4
        signals.append("incremental_pdt")
    if ndt:
        cost += 3
        signals.append("ndt")
    if cte_fragment:
        signals.append("cte_fragment")
    if wh_hints:
        signals.append("warehouse_hints")
    if persisted:
        signals.append("persisted_pdt")
    else:
        signals.append("no_persistence")
        if cost >= MED:
            cost += 3  # re-runs every query in Sigma (was persisted-worthy in Looker)

    # recommendation
    if ndt:
        rec = "rebuild-as-element"
        why = ("Native Derived Table (explore_source) → the converter pushes the aggregation "
               "into one Custom SQL element; rebuilding it as a native Sigma data-model element "
               "is cleaner and faster.")
    elif persisted or incremental:
        rec = "materialize"
        why = ("Persisted/incremental PDT — the author already deemed it expensive enough to "
               "persist, but Sigma has no incremental derived table, so the converted element "
               "recomputes its full SQL. Materialize it on a schedule matching the datagroup cadence.")
    elif cost >= HIGH or (nested_refs and not persisted):
        rec = "materialize"
        why = ("Heavy, un-persisted derived table" + (f" nested on {len(nested_refs)} other derived "
               "view(s) (inlined as stacked CTEs into one element)" if nested_refs else "")
               + " — slow in Looker, slow in Sigma. Materialize it so runtime queries hit a stored table."
               + (" Very complex — a dbt model / warehouse view is another good home." if ctes >= 3 else ""))
    elif cost >= MED:
        rec = "materialize"
        why = "Non-trivial un-persisted derived table — materializing avoids re-running the SQL per query."
    else:
        rec = "leave-inline"
        why = "Simple derived table — cheap to inline as Custom SQL; no materialization needed."

    severity = "high" if cost >= HIGH else "medium" if cost >= MED else "low"
    return {
        "view": name,
        "signals": signals,
        "nested_on": nested_refs,
        "cost": cost,
        "severity": severity,
        "recommendation": rec,
        "why": why,
    }


def scan(paths):
    # pass 1: collect (view, slab, source) and the set of derived-table view names
    views, derived_names = [], set()
    for fp in _iter_files(paths):
        try:
            with open(fp, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as e:
            print(f"detect_derived_perf: cannot read {fp}: {e}", file=sys.stderr)
            continue
        src = os.path.relpath(fp)
        for name, slab in _view_slabs(text):
            views.append((name, slab, src))
            if _DERIVED.search(slab):
                derived_names.add(name)
    # pass 2: analyze each derived-table view (nested needs the full name set)
    findings = []
    for name, slab, src in views:
        f = _analyze_view(name, slab, derived_names)
        if f:
            f["source"] = src
            findings.append(f)
    findings.sort(key=lambda f: -f["cost"])
    return findings


def _iter_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for fn in files:
                    if fn.endswith((".lkml", ".lookml")):
                        yield os.path.join(root, fn)
        elif os.path.isfile(p):
            yield p
        else:
            print(f"detect_derived_perf: no such path: {p}", file=sys.stderr)


def _explore_views(paths, explores):
    """Views referenced (from / join) by the given explores, across model files —
    for scoping. Empty result (couldn't parse) means 'don't scope' (safe default)."""
    want = set()
    for fp in _iter_files(paths):
        try:
            with open(fp, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        estarts = [(m.group(1), m.start()) for m in _EXPLORE.finditer(text)]
        for i, (ename, s) in enumerate(estarts):
            if ename not in explores:
                continue
            e = estarts[i + 1][1] if i + 1 < len(estarts) else len(text)
            body = text[s:e]
            want.add(ename)  # explore name defaults to a view when `from:` is absent
            want.update(_FROM.findall(body))
            want.update(_JOIN.findall(body))
    return want


def split_scope(findings, in_scope_views):
    if not in_scope_views:
        return findings, []
    keep, info = [], []
    for f in findings:
        (keep if f["view"] in in_scope_views else info).append(f)
    return keep, info


def render(findings, informational):
    lines = ["DERIVED-TABLE PERFORMANCE SCAN — the converter ports derived_table SQL verbatim,",
             "so slow Looker SQL stays slow in Sigma. Consider materializing the flagged elements.",
             f"  {len(findings)} derived table(s) in scope"
             + (f", {len(informational)} out of scope" if informational else "") + "."]
    by = {}
    for f in findings:
        by.setdefault(f["recommendation"], []).append(f)
    for rec in ("materialize", "rebuild-as-element", "leave-inline"):
        items = by.get(rec)
        if not items:
            continue
        lines.append("")
        lines.append(f"  {rec}  ({len(items)}):")
        for it in items:
            lines.append(f"    - {it['view']}  [{it['severity']}, cost={it['cost']}]  "
                         f"({', '.join(it['signals'])})  — {it['source']}")
            lines.append(f"        → {it['why']}")
    if informational:
        lines.append("")
        lines.append(f"  INFORMATIONAL — {len(informational)} derived table(s) the migrated "
                     "explore(s) don't use:")
        for it in informational[:10]:
            lines.append(f"    - {it['view']} [{it['severity']}] — {it['source']}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="Scan LookML for expensive derived tables (silent if none).")
    ap.add_argument("paths", nargs="+", help="LookML dir(s)/file(s)")
    ap.add_argument("--json", action="store_true", help="emit findings as JSON")
    ap.add_argument("--scope-explores", help="comma-separated explore name(s) the migration uses — "
                    "derived tables NOT referenced by them become informational")
    a = ap.parse_args()

    findings = scan(a.paths)
    explores = {e.strip() for e in (a.scope_explores or "").split(",") if e.strip()}
    informational = []
    if explores:
        in_scope_views = _explore_views(a.paths, explores)
        findings, informational = split_scope(findings, in_scope_views)

    if not findings and not informational:
        if a.json:
            print(json.dumps({"findings": [], "informational": []}))
        return 0
    if a.json:
        print(json.dumps({"findings": findings, "informational": informational}, indent=2))
        return 0
    print(render(findings, informational))
    return 0


if __name__ == "__main__":
    sys.exit(main())
