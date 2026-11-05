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
    fact_ids = set()
    for mid in sorted(metric_ids):
        m = s.get(f'/model/metrics/{mid}?showExpressionAs=tokens')
        bundle['metrics'][mid] = m
        for tok in m.get('expression', {}).get('tokens', []):
            tgt = tok.get('target')
            if tgt and tgt.get('subType') == 'fact':
                fact_ids.add(tgt['objectId'])
            if tgt and tgt.get('subType') == 'metric':
                metric_ids.add(tgt['objectId'])  # compound metric base

    # second pass for compound-metric bases discovered above
    for mid in sorted(metric_ids):
        if mid not in bundle['metrics']:
            m = s.get(f'/model/metrics/{mid}?showExpressionAs=tokens')
            bundle['metrics'][mid] = m
            for tok in m.get('expression', {}).get('tokens', []):
                tgt = tok.get('target')
                if tgt and tgt.get('subType') == 'fact':
                    fact_ids.add(tgt['objectId'])

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
