#!/usr/bin/env python3
"""Extract a MicroStrategy dossier + its full semantic model into one JSON bundle.

Usage: python3 extract.py <dossierId> [out.json]

The bundle is the converter input: dossier definition (chapters/pages/vizzes),
each dataset report's template, and the schema objects they reference —
attributes (forms, expressions, lookup tables), facts, metrics (formula text),
and logical tables (physical table + namespace + datasource).

A dataset report with no schema objects (hand-written / Freeform SQL: the
`/model/reports/{id}` call fails or has no attribute/metric units) cannot go
through the semantic-model path. It is captured WITHOUT executing the report
(lib/sql_dataset.py) and stored in `bundle['sqlDatasets'][reportId]` instead of
`bundle['reports']`; convert.py refuses such a bundle and points at
scripts/convert-sql-datasets.py.

Derived metrics (a metric built from other metrics inside a report or dossier)
are not project-schema objects, so `GET /model/metrics/{id}` 404s for them.
That 404 is never fatal (refs/mstr-rest-api.md "Derived metrics"):
  - report-level (embedded in the dataset report's template): the formula is
    read from a Modeling report instance (POST /model/reports/{id}/instances,
    then GET /model/reports/{id} with X-MSTR-MS-Instance). This loads the
    definition only; it never runs the report.
  - dossier-level (defined in the dossier on top of a dataset): read from
    GET /model/documents/{dossierId} -> datasets[].derivedMetrics[].
A recovered formula joins `bundle['metrics']` with a `_derived` marker; one no
endpoint exposes lands in `bundle['unresolvedMetrics']` (name, scope, error,
formulaText when only text came back) and convert.py skips it loudly.
"""
import json
import os
import sys
from datetime import datetime, timezone
import mstr

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
import sql_dataset  # noqa: E402  Freeform-SQL dataset capture (refs/sql-datasets.md)


def _has_schema_units(report):
    """True when the report template references attributes or metrics."""
    units = (report.get('dataSource', {}).get('dataTemplate', {})
             .get('units', []))
    return any(u.get('type') == 'attribute'
               or (u.get('type') == 'metrics' and u.get('elements'))
               for u in units)


def _not_resolvable(err):
    """True for the statuses a derived (non-schema) metric draws from the
    catalog (400/403/404). Auth failures and 5xx still abort the extract."""
    return any(f' -> {code}' in str(err) for code in (400, 403, 404))


def _template_metric_elements(report):
    units = (report.get('dataSource', {}).get('dataTemplate', {})
             .get('units', []))
    return [e for u in units if u.get('type') == 'metrics'
            for e in u.get('elements', [])]


def _queue_refs(metric, fact_ids):
    """Record the facts a metric's tokens reference; return its metric refs."""
    refs = []
    for tok in (metric.get('expression') or {}).get('tokens', []):
        tgt = tok.get('target')
        if tgt and tgt.get('subType') == 'fact':
            fact_ids.add(tgt['objectId'])
        if tgt and tgt.get('subType') == 'metric':
            refs.append(tgt['objectId'])  # compound / derived metric base
    return refs


def _node_id(node):
    info = node.get('information') if isinstance(node.get('information'), dict) else {}
    return node.get('id') or node.get('objectId') or info.get('objectId')


def _embedded_definitions(definition, wanted):
    """Metric nodes in a Modeling report definition whose id is in `wanted` and
    that carry expression tokens. The grid alias (the name the report shows;
    the object itself is often still "New Metric") wins over the object name."""
    found, names = {}, {}

    def visit(node):
        if isinstance(node, dict):
            nid = _node_id(node)
            if nid in wanted:
                alias = node.get('alias')
                info = node.get('information') or {}
                nm = (alias if isinstance(alias, str) and alias.strip() else None)
                if nm or nid not in names:
                    names[nid] = nm or node.get('name') or info.get('name') or nid
                expr = node.get('expression')
                if isinstance(expr, dict) and expr.get('tokens') and nid not in found:
                    found[nid] = {'text': expr.get('text', ''), 'tokens': expr['tokens']}
            for v in node.values():
                visit(v)
        elif isinstance(node, list):
            for v in node:
                visit(v)

    visit(definition)
    return {mid: {'information': {'objectId': mid, 'subType': 'metric',
                                  'name': names.get(mid, mid)},
                  'expression': expr}
            for mid, expr in found.items()}


def _report_instance_metrics(s, rid, mids):
    """Formulas of report-embedded metrics, read through a Modeling report
    instance (default executionStage loads the definition without running the
    report). Returns ({mid: metric}, error-or-None); the instance is always
    deleted. Live note (2026-11, public demo, guest user): the instance read
    exposed no expression for an embedded metric, so this is best effort.
    `GET /model/metrics/{id}` rejects X-MSTR-MS-Instance (400), so it is not
    retried inside the instance."""
    try:
        resp = s.post(f'/model/reports/{rid}/instances') or {}
    except RuntimeError as e:
        return {}, str(e)
    inst = resp.get('id') if isinstance(resp, dict) else None
    inst = inst or (getattr(s, 'last_headers', {}) or {}).get('x-mstr-ms-instance')
    if not inst:
        return {}, 'report instance returned no instance id'
    hdr = {'X-MSTR-MS-Instance': inst}
    found, err = {}, None
    try:
        try:
            d = s.get(f'/model/reports/{rid}?showExpressionAs=tokens', headers=hdr)
            found = _embedded_definitions(d or {}, set(mids))
        except RuntimeError as e:
            err = str(e)
        for m in found.values():
            m['_derived'] = {'scope': 'report', 'reportId': rid}
    finally:
        try:
            s.delete(f'/model/reports/{rid}/instances', headers=hdr)
        except RuntimeError:
            pass
    return found, err


_TREE_OPS = {'plus': '+', 'minus': '-', 'times': '*', 'divide': '/'}


class _Untranslatable(Exception):
    pass


def _char(v):
    return {'type': 'character', 'value': v}


def tree_to_tokens(tree, derived_ids=()):
    """A Modeling expression `tree` (what GET /model/documents/{id} returns for
    dossier-level derived metrics, whatever showExpressionAs says) -> the token
    list convert.py translates. Only arithmetic over metric references and
    numeric constants: + - * /, unary minus, nesting. Raises _Untranslatable
    for anything else (functions, Case, comparisons, running/rank, inline
    aggregations on embedded agg_metrics, attribute forms). An embedded
    metric reference is accepted only when it names another derived metric
    the same document defines (`derived_ids`), so derived-on-derived chains
    resolve while inline aggregations like `Sum(Revenue)` (embedded, not a
    document derived metric) stay unresolved with their formula text."""
    toks = []

    def emit(n, top):
        t = n.get('type')
        if t == 'object_reference':
            tgt = n.get('target') or {}
            if tgt.get('subType') != 'metric' or not tgt.get('objectId') or (
                    tgt.get('isEmbedded') and tgt['objectId'] not in derived_ids):
                raise _Untranslatable(
                    f"reference to {tgt.get('subType') or '?'}"
                    + (' (embedded)' if tgt.get('isEmbedded') else ''))
            toks.append({'type': 'object_reference',
                         'value': f"[{tgt.get('name', '')}]",
                         'target': {'objectId': tgt['objectId'],
                                    'subType': 'metric',
                                    'name': tgt.get('name', '')}})
        elif t == 'constant':
            v = str((n.get('variant') or {}).get('value', ''))
            try:
                float(v)
            except ValueError:
                raise _Untranslatable(f'non-numeric constant {v!r}') from None
            toks.append({'type': 'literal', 'value': v})
        elif t == 'operator' and n.get('function') == 'unary_minus':
            ch = n.get('children') or []
            if len(ch) != 1:
                raise _Untranslatable('malformed unary minus')
            toks.extend([_char('('), {'type': 'literal', 'value': '0'}, _char('-')])
            emit(ch[0], False)
            toks.append(_char(')'))
        elif t == 'operator' and n.get('function') in _TREE_OPS:
            ch = n.get('children') or []
            if len(ch) < 2:
                raise _Untranslatable(f"malformed {n.get('function')}")
            if not top:
                toks.append(_char('('))
            for i, c in enumerate(ch):
                if i:
                    toks.append(_char(_TREE_OPS[n['function']]))
                emit(c, False)
            if not top:
                toks.append(_char(')'))
        else:
            raise _Untranslatable(
                f"{t or '?'} {n.get('functionName') or n.get('function') or ''}".strip())

    emit(tree or {}, True)
    if not toks:
        raise _Untranslatable('empty expression')
    toks.append({'type': 'end_of_text', 'value': ''})
    return toks


def _grid_embedded_metrics(report):
    """Embedded (report-level derived) metric elements anywhere in a report:
    template elements flagged isEmbedded, and grid-only ones (shown in
    grid.viewTemplate but absent from dataSource.dataTemplate)."""
    out = {}

    def visit(node):
        if isinstance(node, dict):
            if node.get('isEmbedded') is True and node.get('subType') == 'metric' \
                    and node.get('id'):
                alias = node.get('alias')
                out.setdefault(node['id'], alias if isinstance(alias, str)
                               and alias.strip() else node.get('name'))
            for v in node.values():
                visit(v)
        elif isinstance(node, list):
            for v in node:
                visit(v)

    visit({'dataTemplate': (report.get('dataSource') or {}).get('dataTemplate'),
           'viewTemplate': (report.get('grid') or {}).get('viewTemplate')})
    return out


def extract(s, dossier_id):
    bundle = {
        '_extraction': {
            'dossierId': dossier_id,
            'retrievedAtUtc': datetime.now(timezone.utc).isoformat(),
        },
        'dossier': s.get(f'/v2/dossiers/{dossier_id}/definition'),
    }

    # datasets -> report definitions (template + data source). A report without
    # schema objects is a hand-written (Freeform SQL) dataset: capture its SQL
    # instead (never executes the report; never fails the whole extract).
    reports = {}
    bundle['sqlDatasets'] = {}
    for ds in bundle['dossier'].get('datasets', []):
        rid = ds['id']
        report = None
        try:
            report = s.get(f'/model/reports/{rid}?showExpressionAs=tokens')
        except RuntimeError:
            pass
        if report is not None and _has_schema_units(report):
            reports[rid] = report
            continue
        try:
            bundle['sqlDatasets'][rid] = sql_dataset.capture(
                s, rid, allow_execute=False)
        except Exception as e:  # noqa: BLE001 — record, keep extracting
            bundle['sqlDatasets'][rid] = {
                'reportId': rid, 'name': ds.get('name') or rid, 'error': str(e)}
    bundle['reports'] = reports

    # collect referenced attribute/metric ids from report templates
    attr_ids, metric_ids = set(), set()
    for r in reports.values():
        units = (r.get('dataSource', {}).get('dataTemplate', {})
                 .get('units', []))
        for u in units:
            if u.get('type') == 'attribute':
                attr_ids.add(u['id'])
            elif u.get('type') == 'metrics':
                for e in u.get('elements', []):
                    metric_ids.add(e['id'])

    bundle['attributes'] = {}
    table_ids = set()
    for aid in sorted(attr_ids):
        a = s.get(f'/model/attributes/{aid}?showExpressionAs=tokens')
        bundle['attributes'][aid] = a
        for f in a.get('forms', []):
            for ex in f.get('expressions', []):
                for t in ex.get('tables', []):
                    table_ids.add(t['objectId'])

    bundle['metrics'] = {}
    bundle['unresolvedMetrics'] = {}
    fact_ids = set()
    unres = bundle['unresolvedMetrics']

    # report-level derived metrics: flagged isEmbedded in the template or the
    # grid. Not schema objects, so never sent to /model/metrics (a 404).
    embedded = {}                          # mid -> (report id, display name)
    for rid, r in reports.items():
        for mid, name in _grid_embedded_metrics(r).items():
            embedded.setdefault(mid, (rid, name))
    template_metric_report = {}
    for rid, r in reports.items():
        for el in _template_metric_elements(r):
            template_metric_report.setdefault(el['id'], (rid, el.get('name')))

    def fetch(mids, scope):
        """Worklist fetch of catalog metrics and every metric they reference
        (compound / derived chains of any depth). Unresolvable ids (400/403/
        404) are returned, never raised; auth failures and 5xx still raise."""
        failed = {}
        pending = list(mids)
        while pending:
            mid = pending.pop(0)
            if mid in bundle['metrics'] or mid in failed or mid in unres:
                continue
            try:
                m = s.get(f'/model/metrics/{mid}?showExpressionAs=tokens')
            except RuntimeError as e:
                if not _not_resolvable(e):
                    raise
                failed[mid] = str(e)
                continue
            bundle['metrics'][mid] = m
            pending.extend(_queue_refs(m, fact_ids))
        return failed

    catalog_ids = sorted(m for m in metric_ids if m not in embedded)
    failed = fetch(catalog_ids, 'template')
    if catalog_ids and not bundle['metrics'] and failed:
        # EVERY catalog lookup failed: a permissions problem, not derived metrics
        raise RuntimeError(
            'every /model/metrics lookup failed (e.g. '
            + next(iter(failed.values()))[:200] + '). The MicroStrategy user '
            'likely lacks read access to schema objects (Architect / Modeling '
            'privileges); fix access before extracting.')
    for mid in failed:                     # unflagged template metric that 404s
        if mid in template_metric_report:
            embedded.setdefault(mid, template_metric_report[mid])

    # recover report-level formulas through a Modeling instance (best effort)
    by_report = {}
    for mid, (rid, _) in embedded.items():
        by_report.setdefault(rid, []).append(mid)
    later = []
    for rid, mids in sorted(by_report.items()):
        found, err = _report_instance_metrics(s, rid, mids)
        for mid in mids:
            if mid in found:
                bundle['metrics'][mid] = found[mid]
                later.extend(_queue_refs(found[mid], fact_ids))
                continue
            in_template = mid in template_metric_report
            unres[mid] = {
                'id': mid, 'name': embedded[mid][1] or mid,
                'scope': 'report' if in_template else 'report-grid',
                'reportId': rid,
                'error': (failed.get(mid, 'report-level derived metric (isEmbedded)')
                          + (f'; instance: {err}' if err else
                             '; the report definition carries no formula for it'))}
    for mid, e in failed.items():          # referenced by a formula only
        if mid not in bundle['metrics'] and mid not in unres:
            unres[mid] = {'id': mid, 'name': mid, 'scope': 'reference', 'error': e}

    # dossier-level derived metrics (never in a report template). Live-verified
    # shape: datasets[].derivedMetrics[] with expression {text, tree}.
    try:
        doc = s.get(f'/model/documents/{dossier_id}') or {}
    except RuntimeError as e:
        doc = {}
        bundle['_extraction']['documentModelError'] = str(e)
    auto_row_counts = 0
    doc_derived_ids = {(dm.get('information') or {}).get('objectId') or dm.get('id')
                       for ds in doc.get('datasets') or []
                       for dm in ds.get('derivedMetrics') or []}
    for ds in doc.get('datasets') or []:
        ds_id = (ds.get('information') or {}).get('objectId') or ds.get('id')
        if ds_id not in reports:           # cube / Freeform SQL: other paths
            continue
        for dm in ds.get('derivedMetrics') or []:
            info = dm.get('information') or {}
            mid = info.get('objectId') or dm.get('id')
            if not mid or mid in bundle['metrics']:
                continue
            expr = dm.get('expression') if isinstance(dm.get('expression'), dict) else {}
            name = info.get('name') or dm.get('name') or mid
            if expr.get('text', '').replace(' ', '') == 'Count("*")':
                auto_row_counts += 1       # auto "Row Count" metric: not authored
                continue
            tokens, why = expr.get('tokens'), None
            if not tokens and expr.get('tree'):
                try:
                    tokens = tree_to_tokens(expr['tree'], doc_derived_ids)
                except _Untranslatable as e:
                    why = f'formula uses {e}, which has no automatic Sigma translation'
            if tokens:
                bundle['metrics'][mid] = {
                    'information': {'objectId': mid, 'subType': 'metric', 'name': name},
                    'expression': {'text': expr.get('text', ''), 'tokens': tokens},
                    '_derived': {'scope': 'dossier', 'datasetId': ds_id}}
                unres.pop(mid, None)
                later.extend(_queue_refs(bundle['metrics'][mid], fact_ids))
            else:
                unres[mid] = {
                    'id': mid, 'name': name, 'scope': 'dossier', 'datasetId': ds_id,
                    'formulaText': expr.get('text'),
                    'error': why or 'GET /model/documents returned no expression'}

    if auto_row_counts:
        bundle['_extraction']['skippedAutoRowCountMetrics'] = auto_row_counts

    # base metrics the recovered derived formulas reference
    for mid, e in fetch(later, 'reference').items():
        unres[mid] = {'id': mid, 'name': mid, 'scope': 'reference', 'error': e}

    bundle['facts'] = {}
    for fid in sorted(fact_ids):
        f = s.get(f'/model/facts/{fid}?showExpressionAs=tokens')
        bundle['facts'][fid] = f
        for ex in f.get('expressions', []):
            for t in ex.get('tables', []):
                table_ids.add(t['objectId'])

    bundle['tables'] = {}
    for tid in sorted(table_ids):
        bundle['tables'][tid] = s.get(f'/model/tables/{tid}')

    # attribute relationships (hierarchy) for join/topology hints
    bundle['relationships'] = {}
    for aid in sorted(attr_ids):
        try:
            rel = s.get(f'/model/systemHierarchy/attributes/{aid}/relationships')
            if rel.get('relationships'):
                bundle['relationships'][aid] = rel['relationships']
        except Exception:
            pass

    return bundle


if __name__ == '__main__':
    dossier_id = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else 'bundle.json'
    s = mstr.Session()
    b = extract(s, dossier_id)
    json.dump(b, open(out, 'w'), indent=1)
    print(f'wrote {out}: {len(b["reports"])} reports, '
          f'{len(b["sqlDatasets"])} sqlDatasets, '
          f'{len(b["attributes"])} attributes, {len(b["metrics"])} metrics, '
          f'{len(b["facts"])} facts, {len(b["tables"])} tables')
    derived = [m for m in b['metrics'].values() if m.get('_derived')]
    if derived:
        print(f'recovered {len(derived)} derived metric formula(s): '
              + ', '.join(m['information']['name'] for m in derived))
    for u in b['unresolvedMetrics'].values():
        print(f"⚠ derived metric {u['name']!r} ({u['scope']}): formula not exposed "
              f"by the REST API — convert.py will skip it; hand-author it in Sigma"
              + (f" (MicroStrategy text: {u['formulaText']})" if u.get('formulaText')
                 else '') + f". {u['error'][:200]}", file=sys.stderr)
