#!/usr/bin/env node
import { groundWarehouseRefs } from './lib/warehouse-column-refs.mjs';

const spec = { pages: [{ elements: [{
  name: 'Sales Fact', source: { kind: 'warehouse-table', connectionId: 'conn', path: ['DB', 'S', 'SALES_FACT'] },
  columns: [{ id: 'inode-x/UNIT_COST', formula: '[SALES_FACT/Unit Cost]' },
    { id: 'calc', formula: 'Text([Sales Fact/Unit Cost])', name: 'Cost Text' }],
}, { name: 'Sales View', source: { kind: 'table', elementId: 'fact' },
  columns: [{ id: 'pass', formula: '[Sales Fact/Unit Cost]' }] }] }] };
const api = async (method, path) => {
  if (method === 'POST') return { ok: true, status: 200, json: { kind: 'table', inodeId: 't' }, text: '' };
  if (path.startsWith('/v2/connections/tables/')) return { ok: true, status: 200, json: { entries: [{ name: 'UNIT_COST' }] }, text: '' };
  return { ok: true, status: 200, json: { friendlyName: false }, text: '' };
};
const result = await groundWarehouseRefs(spec, api);
const [fact, view] = spec.pages[0].elements;
if (fact.name !== 'SALES_FACT') throw new Error('physical element name not applied');
if (fact.columns[0].formula !== '[SALES_FACT/UNIT_COST]' || fact.columns[0].name !== 'Unit Cost') throw new Error('base column not grounded');
if (fact.columns[1].formula !== 'Text([SALES_FACT/UNIT_COST])') throw new Error('qualified calc not grounded');
if (view.columns[0].formula !== '[SALES_FACT/Unit Cost]' || view.columns[0].name !== 'Unit Cost') throw new Error('derived ref not grounded');
if (result.connectionModes.conn !== false) throw new Error('connection mode not reported');
console.log('test-warehouse-column-refs: PASS');
