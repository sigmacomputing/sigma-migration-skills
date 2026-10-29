#!/usr/bin/env python3
"""Generate invented Tableau test data and a workbook outside the skill tree.

Optional --package needs tableauhyperapi and emits an extract-backed TWBX.
The declared Snowflake Custom SQL uses literals only, so the same data can be
queried in Sigma without provisioning warehouse tables or copying tenant data.
"""
import argparse
import csv
import datetime as dt
import json
from pathlib import Path
# Builds and serializes XML only; nothing here parses untrusted input.
import xml.etree.ElementTree as ET  # nosemgrep: python.lang.security.use-defused-xml.use-defused-xml
import zipfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lib'))
import workdir_guard


def generate(out, package=False):
    workdir_guard.check(out, '--out')
    out.mkdir(parents=True, exist_ok=True)
    fields = [('PERIOD', 'date', 'Period'), ('AREA', 'string', 'Area'),
              ('UNITS', 'integer', 'Units'), ('FAILURES', 'integer', 'Failures')]
    rows = [[dt.date(2025, 2, 3) + dt.timedelta(weeks=w), area,
             100 + 20 * w + a * 10, 7 + w + a]
            for w in range(4) for a, area in enumerate(('North', 'South', 'West'))]
    values = ', '.join(f"('{p.isoformat()}', '{a}', {u}, {f})" for p, a, u, f in rows)
    sql = 'SELECT TO_DATE(column1) AS PERIOD, column2::VARCHAR AS AREA, column3::INTEGER AS UNITS, column4::INTEGER AS FAILURES FROM VALUES ' + values
    root = ET.Element('workbook', {'locale': 'en_US', 'version': '18.1', 'source-platform': 'mac'})
    sources = ET.SubElement(root, 'datasources')
    params = ET.SubElement(sources, 'datasource', {'name': 'Parameters', 'inline': 'true', 'hasconnection': 'false', 'version': '18.1'})
    param = ET.SubElement(params, 'column', {'name': '[Parameter 1]', 'caption': 'Metric Choice', 'datatype': 'string',
                                          'role': 'measure', 'type': 'nominal', 'param-domain-type': 'list', 'value': '"Units"'})
    ET.SubElement(param, 'calculation', {'class': 'tableau', 'formula': '"Units"'})
    members = ET.SubElement(param, 'members')
    for value in ('Units', 'Failure Rate'):
        ET.SubElement(members, 'member', {'value': f'"{value}"'})
    source = ET.SubElement(sources, 'datasource', {'name': 'federated.synthetic', 'caption': 'Synthetic Metrics', 'inline': 'true', 'version': '18.1'})
    connection = ET.SubElement(source, 'connection', {'class': 'federated'})
    named = ET.SubElement(ET.SubElement(connection, 'named-connections'), 'named-connection', {'name': 'snowflake.synthetic', 'caption': 'Synthetic SQL'})
    ET.SubElement(named, 'connection', {'class': 'snowflake', 'server': 'warehouse.example.com', 'dbname': 'DEMO_DB', 'schema': 'DEMO'})
    ET.SubElement(connection, 'relation', {'name': 'Synthetic Rows', 'type': 'text', 'connection': 'snowflake.synthetic'}).text = sql
    metadata = ET.SubElement(connection, 'metadata-records')
    for i, (name, datatype, _caption) in enumerate(fields):
        record = ET.SubElement(metadata, 'metadata-record', {'class': 'column'})
        for tag, value in [('remote-name', name), ('local-name', f'[{name}]'),
                           ('parent-name', '[Synthetic Rows]'), ('local-type', datatype), ('ordinal', str(i))]:
            ET.SubElement(record, tag).text = value
    columns = []
    for name, datatype, caption in fields:
        dim = datatype in ('date', 'string')
        attrs = {'name': f'[{name}]', 'caption': caption, 'datatype': datatype,
                 'role': 'dimension' if dim else 'measure', 'type': 'nominal' if dim else 'quantitative'}
        ET.SubElement(source, 'column', attrs)
        columns.append((attrs, None))
    calcs = [('Failure Rate', 'SUM([FAILURES]) / SUM([UNITS])'),
             ('Selected Metric', "CASE [Parameters].[Parameter 1] WHEN 'Units' THEN SUM([UNITS]) WHEN 'Failure Rate' THEN [Failure Rate] END")]
    for name, formula in calcs:
        attrs = {'name': f'[{name}]', 'caption': name, 'datatype': 'real', 'role': 'measure', 'type': 'quantitative'}
        col = ET.SubElement(source, 'column', attrs)
        ET.SubElement(col, 'calculation', {'class': 'tableau', 'formula': formula})
        columns.append((attrs, formula))
    extract = ET.SubElement(source, 'extract', {'count': str(len(rows)), 'enabled': 'true'})
    ec = ET.SubElement(extract, 'connection', {'class': 'hyper', 'dbname': 'Data/Extracts/synthetic.hyper', 'schema': 'Extract', 'access_mode': 'readonly'})
    ET.SubElement(ec, 'relation', {'name': 'Extract', 'table': '[Extract].[Extract]', 'type': 'table'})
    worksheets = ET.SubElement(root, 'worksheets')
    def sheet(name, kind, row, col, text=None):
        ws = ET.SubElement(worksheets, 'worksheet', {'name': name})
        table = ET.SubElement(ws, 'table')
        view = ET.SubElement(table, 'view')
        ET.SubElement(ET.SubElement(view, 'datasources'), 'datasource', {'name': 'federated.synthetic', 'caption': 'Synthetic Metrics'})
        deps = ET.SubElement(view, 'datasource-dependencies', {'datasource': 'federated.synthetic'})
        for attrs, formula in columns:
            cc = ET.SubElement(deps, 'column', attrs)
            if formula:
                ET.SubElement(cc, 'calculation', {'class': 'tableau', 'formula': formula})
        for field, derivation, prefix, typ in [('AREA', 'None', 'none', 'nk'), ('PERIOD', 'None', 'none', 'nk'),
                                             ('UNITS', 'Sum', 'sum', 'qk'), ('FAILURES', 'Sum', 'sum', 'qk'),
                                             ('Failure Rate', 'User', 'usr', 'qk'), ('Selected Metric', 'User', 'usr', 'qk')]:
            ET.SubElement(deps, 'column-instance', {'column': f'[{field}]', 'derivation': derivation,
                'name': f'[{prefix}:{field}:{typ}]', 'pivot': 'key', 'type': 'nominal' if typ == 'nk' else 'quantitative'})
        ET.SubElement(view, 'aggregation', {'value': 'true'})
        pane = ET.SubElement(ET.SubElement(table, 'panes'), 'pane', {'selection-relaxation-option': 'selection-relaxation-allow'})
        ET.SubElement(ET.SubElement(pane, 'view'), 'breakdown', {'value': 'auto'})
        ET.SubElement(pane, 'mark', {'class': kind})
        if text:
            ET.SubElement(ET.SubElement(pane, 'encodings'), 'text', {'column': text})
        ET.SubElement(table, 'rows').text = row
        ET.SubElement(table, 'cols').text = col
    ref = lambda instance: f'[federated.synthetic].[{instance}]'
    sheet('Area Totals', 'Bar', ref('none:AREA:nk'), ref('sum:UNITS:qk'))
    sheet('Weekly Units', 'Line', ref('sum:UNITS:qk'), ref('none:PERIOD:nk'))
    sheet('Rate Matrix', 'Text', ref('none:AREA:nk'), ref('none:PERIOD:nk'), ref('usr:Failure Rate:qk'))
    sheet('Metric Switch', 'Bar', ref('none:AREA:nk'), ref('usr:Selected Metric:qk'))
    dashboards = ET.SubElement(root, 'dashboards')
    for name, names in [('Synthetic Overview', ['Area Totals', 'Weekly Units']), ('Synthetic Detail', ['Rate Matrix', 'Metric Switch'])]:
        dash = ET.SubElement(dashboards, 'dashboard', {'name': name})
        ET.SubElement(dash, 'size', {'sizing-mode': 'fixed', 'maxheight': '700', 'maxwidth': '1100', 'minheight': '700', 'minwidth': '1100'})
        zones = ET.SubElement(dash, 'zones')
        for i, ws in enumerate(names):
            ET.SubElement(zones, 'zone', {'id': str(i + 1), 'name': ws, 'x': str(i * 50000), 'y': '10000', 'w': '50000', 'h': '90000'})
        if name == 'Synthetic Detail':
            # Exercise compact → list explicitly; an absent mode means segmented.
            ET.SubElement(zones, 'zone', {'id': '3', 'type-v2': 'paramctrl', 'param': '[Parameters].[Parameter 1]',
                                         'mode': 'compact', 'x': '50000', 'y': '0', 'w': '50000', 'h': '10000'})
    windows = ET.SubElement(root, 'windows')
    for ws in worksheets:
        ET.SubElement(windows, 'window', {'class': 'worksheet', 'name': ws.get('name')})
    for dash in dashboards:
        window = ET.SubElement(windows, 'window', {'class': 'dashboard', 'name': dash.get('name')})
        viewpoints = ET.SubElement(window, 'viewpoints')
        for zone in dash.findall('zones/zone'):
            if zone.get('name'):
                vp = ET.SubElement(viewpoints, 'viewpoint', {'name': zone.get('name')})
                ET.SubElement(vp, 'zoom', {'type': 'entire-view'})
    twb = out / 'synthetic-metrics.twb'
    ET.indent(root)
    ET.ElementTree(root).write(twb, encoding='utf-8', xml_declaration=True)
    with (out / 'synthetic-rows.csv').open('w') as handle:
        writer = csv.writer(handle)
        writer.writerow([f[0] for f in fields])
        writer.writerows(rows)
    (out / 'source.sql').write_text(sql + '\n')
    if package:
        from tableauhyperapi import HyperProcess, Connection, Telemetry, CreateMode, TableDefinition, TableName, SqlType, Inserter
        hyper = out / 'synthetic.hyper'
        with HyperProcess(Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as process:
            with Connection(process.endpoint, str(hyper), CreateMode.CREATE_AND_REPLACE) as conn:
                conn.catalog.create_schema('Extract')
                definition = TableDefinition(TableName('Extract', 'Extract'), [
                    TableDefinition.Column(name, typ) for (name, _, _), typ in zip(fields, [SqlType.date(), SqlType.text(), SqlType.big_int(), SqlType.big_int()])])
                conn.catalog.create_table(definition)
                with Inserter(conn, definition) as inserter:
                    inserter.add_rows(rows)
                    inserter.execute()
        with zipfile.ZipFile(out / 'synthetic-metrics.twbx', 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.write(twb, twb.name)
            archive.write(hyper, 'Data/Extracts/synthetic.hyper')
    return {'rows': len(rows), 'worksheets': 4, 'dashboards': 2, 'total_units': sum(r[2] for r in rows)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--package', action='store_true')
    args = parser.parse_args()
    print(json.dumps(generate(args.out, args.package)))
