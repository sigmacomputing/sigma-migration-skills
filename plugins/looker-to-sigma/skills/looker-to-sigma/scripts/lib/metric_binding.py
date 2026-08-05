#!/usr/bin/env python3
"""metric_binding.py — bind a workbook measure to a governed DM metric.

Every converter builds a Sigma data model whose elements carry reusable metrics
(name + formula), but the workbook builder tends to re-derive each measure inline
(``Sum([Master/Net Revenue])``, ``CountDistinct(...)``, ...), bypassing the
governed metric: the aggregation logic is duplicated (and can drift) and the
analyst never gets the metric object. This module is the thin, converter-agnostic
binder that lets a builder prefer a governed ``[Metrics/<name>]`` reference when it
is provably the same aggregation — and fall back to the inline formula otherwise.

Pure functions, stdlib only:

- ``available_metrics(element_id, elements_by_id)`` — the metrics REFERENCEABLE on
  an element: its own metrics plus those it inherits through the ``source.elementId``
  chain (a denorm "<X> View" element carries 0 own metrics but inherits its base
  fact's; Sigma exposes them and they resolve as ``[Metrics/<name>]`` on the denorm
  — verified live). Deduped by name, nearest element wins. Each metric is
  ``{"name", "formula"}``; entries missing either field are skipped. A
  COLLISION-SHAPED element (below) contributes NO metrics — none of them are
  provably referenceable.

- ``column_metric_collisions(element)`` — the names carried by BOTH a column and a
  governed metric of the SAME element (exact string equality — Sigma element
  namespaces are exact; no name/content heuristics). ``[]`` for a clean element.

- ``collision_exclusions(element_id, elements_by_id)`` — the audit half of the same
  chain walk: one ``{"element_id", "element_name", "collisions",
  "excluded_metrics"}`` record per collision-shaped element whose metrics
  ``available_metrics`` withheld, so callers surface the inline fallback (run note
  + decision ledger) instead of silently changing emission. ``element_name`` falls
  back to the element ID when the element is unnamed (converter-model BASE
  elements carry no ``name`` key — field-caught: the run note otherwise renders
  "DM element ''", identifying nothing), so the label is always render-safe.

- ``metric_ref_or_inline(inline, master_name, metrics)`` — returns
  ``[Metrics/<name>]`` when ``inline`` matches a metric by FORMULA EQUIVALENCE
  (strip the master prefix so ``Sum([Data/Net Revenue])`` equals a metric's
  ``Sum([Net Revenue])``, then compare ignoring whitespace), else returns ``inline``
  unchanged. Naming-independent and SAFE: ratios / filtered / custom / no-match /
  empty-metrics all fall through to the inline formula, so passing no metrics is
  byte-identical to the pre-binding behavior. Whether a given column is even a
  measure (worth binding) is the caller's decision — only call this for measures.

COLLISION SHAPE (wave-2 measurement finding F4, field-caught live): a DM element
that POSTs a governed metric NAMED IDENTICALLY to one of its own columns is
accepted by the API without error, but the live readback then returns the element
with its metrics OMITTED WHOLESALE — including same-element metrics whose names
do not collide (field evidence: a fact element with same-named column/metric
pairs came back as columns only; every metric name backed solely by a metric was
gone). Any ``[Metrics/<name>]`` ref bound to one of those metrics then fails the
post-readback workbook ref gate (exit 4, "Dependency not found" class) —
deterministically, on every cold run of the shape. The remedy validated live is
to re-derive the affected measures INLINE. So: when the shape is present, the
binder withholds ALL of that element's metrics (``available_metrics``) and
reports the withholding (``collision_exclusions``); the ref gate itself stays
fail-closed — emission just stops producing refs the readback cannot confirm.
Detection is purely structural: same element, one column + one metric, same
exact name.

The reference form is the literal namespace ``[Metrics/<Metric Name>]`` — NOT
``[Element/Name]`` (that errors). Extracted from the looker reference implementation
(PR #484); see the phase docs. Mirror: shared/lib/metric_binding.rb — keep the
two in lockstep.
"""
import re

_WS = re.compile(r"\s+")


def canon(formula):
    """Whitespace-insensitive canonical form of a Sigma formula (or empty)."""
    return _WS.sub("", formula or "")


def column_metric_collisions(element):
    """Names carried by BOTH a column and a governed metric of ``element`` — the
    structural F4 collision shape. Exact string equality, column order, deduped;
    ``[]`` for a clean element or non-dict input. Every NAMED entry counts, even
    a formula-less metric: the POSTed shape is what live Sigma drops on
    readback."""
    if not isinstance(element, dict):
        return []
    met_names = {m.get("name") for m in (element.get("metrics") or [])
                 if isinstance(m, dict) and m.get("name")}
    if not met_names:
        return []
    seen = set()
    out = []
    for c in (element.get("columns") or []):
        name = c.get("name") if isinstance(c, dict) else None
        if name and name in met_names and name not in seen:
            seen.add(name)
            out.append(name)
    return out


def available_metrics(element_id, elements_by_id):
    """Metrics referenceable on ``element_id`` = its own metrics + those inherited
    through the ``source.elementId`` chain, deduped by name (nearest element wins).

    ``elements_by_id`` maps an element id to its dict (each with an optional
    ``metrics`` list and ``source.elementId``). Returns a list of
    ``{"name", "formula"}`` dicts; metrics missing a name or formula are dropped,
    and a collision-shaped element (``column_metric_collisions``) contributes NO
    metrics — its measures must stay inline (F4; see the module docstring).
    Cycle-safe."""
    return _walk_chain(element_id, elements_by_id)["metrics"]


def collision_exclusions(element_id, elements_by_id):
    """Audit companion to ``available_metrics`` — the SAME walk's exclusion
    records: one ``{"element_id", "element_name", "collisions",
    "excluded_metrics"}`` dict per collision-shaped chain element whose metrics
    were withheld (``[]`` when the chain is clean). Callers surface these (run
    note + decision ledger) so the inline fallback is never silent.
    ``element_name`` is always a non-empty label: the element's name, or its ID
    when it has none (converter models leave base elements unnamed)."""
    return _walk_chain(element_id, elements_by_id)["exclusions"]


def _walk_chain(element_id, elements_by_id):
    """The one chain walk behind available_metrics / collision_exclusions:
    ``{"metrics": [...], "exclusions": [...]}``. Cycle-safe."""
    seen, chain, exclusions = set(), [], []
    eid = element_id
    while eid and eid not in seen:
        seen.add(eid)
        el = elements_by_id.get(eid)
        if not el:
            break
        harvest = [{"name": m.get("name"), "formula": m.get("formula")}
                   for m in (el.get("metrics") or [])
                   if isinstance(m, dict) and m.get("name") and m.get("formula")]
        collisions = column_metric_collisions(el)
        if not collisions:
            chain.extend(harvest)
        else:
            # Converter-model BASE elements carry no "name" key — fall back to
            # the element ID so the audit label never renders as '' (field-caught).
            el_name = el.get("name")
            if el_name in (None, ""):
                el_name = eid
            exclusions.append({"element_id": eid, "element_name": el_name,
                               "collisions": collisions,
                               "excluded_metrics": [m["name"] for m in harvest]})
        eid = (el.get("source") or {}).get("elementId")
    return {"metrics": _dedup_by_name(chain), "exclusions": exclusions}


def _dedup_by_name(metrics):
    seen, out = set(), []
    for m in metrics:
        if m["name"] not in seen:
            seen.add(m["name"])
            out.append(m)
    return out


def metric_ref_or_inline(inline, master_name, metrics):
    """Prefer ``[Metrics/<name>]`` when ``inline`` matches a metric by formula
    equivalence (master prefix stripped, whitespace ignored); otherwise return
    ``inline`` unchanged. Safe no-op when ``metrics`` is empty or ``inline`` is not
    a string. See the module docstring."""
    if not isinstance(inline, str) or not metrics:
        return inline
    want = canon(inline.replace(f"[{master_name}/", "["))
    for m in metrics:
        name, formula = m.get("name"), m.get("formula")
        if name and formula and canon(formula) == want:
            return f"[Metrics/{name}]"
    return inline
