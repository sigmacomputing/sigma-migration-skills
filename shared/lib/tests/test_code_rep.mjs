import assert from 'node:assert/strict';
import {
  createBody,
  createPath,
  document,
  dryRunResult,
  metadata,
  readPath,
  stripResponseOnly,
  updateBody,
  updatePath,
  workbookElements,
  workbookElementsWithPages,
  workbookPageElementIds,
  wrap,
} from '../code_rep.mjs';

const live = {
  workbookId: 'w1',
  name: 'N',
  document: {
    schemaVersion: 1,
    pages: [{ id: 'p' }],
    elements: [{ id: 'e1', kind: 'table' }],
    overlays: [{ id: 'o1' }],
    panels: [{ id: 'panel1' }],
    layout: '<Page id="p"><Element elementId="e1"/></Page>',
  },
};

assert.equal(document(live).elements[0].id, 'e1');
assert.deepEqual(Object.keys(metadata(live)).sort(), ['name', 'workbookId']);
assert.deepEqual(workbookPageElementIds(live), { p: ['e1'] });
assert.equal(workbookElementsWithPages(live)[0][1].id, 'p');

const nested = {
  schemaVersion: 1,
  pages: [{ id: 'p', elements: [{ id: 'old', kind: 'text' }] }],
};
assert.deepEqual(workbookElements(nested).map((element) => element.id), ['old']);
const wrapped = wrap(nested).document;
assert.deepEqual(wrapped.elements.map((element) => element.id), ['old']);
assert.equal('elements' in wrapped.pages[0], false);

const visibilityDoc = {
  schemaVersion: 1,
  pages: [{ id: 'data' }],
  elements: [
    { id: 'master', kind: 'table', visibleAsSource: false },
    { id: 'chart', kind: 'bar-chart', visibleAsSource: true },
  ],
};
const visibilityEmitted = wrap(visibilityDoc).document.elements;
assert.equal(visibilityEmitted.every((element) => !('visibleAsSource' in element)), true);
assert.equal(visibilityDoc.elements[0].visibleAsSource, false);
assert.equal(visibilityDoc.elements[1].visibleAsSource, true);

const legacyLayout = '<Page id="p"><GridContainer elementId="c"><LayoutElement elementId="e1"/>'
  + '<Noise elementId="not-layout"/></GridContainer></Page>';
assert.deepEqual(
  workbookPageElementIds({ ...live.document, layout: legacyLayout }),
  { p: ['c', 'e1'] },
);
const regionLayout = '<Page id="p"><Element elementId="page"/></Page>'
  + '<Panel id="sidebar"><Container elementId="panel"/></Panel>'
  + '<Overlay id="modal"><TabbedContainer elementId="overlay"/></Overlay>';
assert.deepEqual(
  workbookPageElementIds({ ...live.document, layout: regionLayout }),
  { p: ['page'], sidebar: ['panel'], modal: ['overlay'] },
);
const canonicalLayout = wrap({ ...live.document, layout: legacyLayout }).document.layout;
assert.equal(
  canonicalLayout,
  '<Page id="p"><Container elementId="c"><Element elementId="e1"/>'
    + '<Noise elementId="not-layout"/></Container></Page>',
);
assert.doesNotMatch(canonicalLayout, /LayoutElement|GridContainer/);

const legacyFields = {
  pages: [],
  elements: [
    { id: 'text', kind: 'text', verticalAlign: 'middle' },
    {
      id: 'kpi',
      kind: 'kpi-chart',
      layout: { anchor: 'start', verticalAnchor: 'end', titleOrient: 'bottom' },
    },
    { id: 'tabs', kind: 'tabbed-container', tabBar: { alignment: 'end' } },
    { id: 'h-rule', kind: 'divider', align: 'start' },
    { id: 'v-rule', kind: 'divider', direction: 'vertical', align: 'end' },
  ],
  overlays: [
    {
      id: 'filters',
      type: 'drawer',
      drawer: { width: 'medium', position: 'end', showShadow: 'shown' },
    },
  ],
};
const canonicalFields = wrap(legacyFields).document;
const fieldsById = Object.fromEntries(canonicalFields.elements.map((element) => [element.id, element]));
assert.equal(fieldsById.text.verticalAlign, 'center');
assert.deepEqual(
  fieldsById.kpi.layout,
  { anchor: 'left', verticalAnchor: 'bottom', titleOrient: 'bottom' },
);
assert.equal(fieldsById.tabs.tabBar.alignment, 'right');
assert.equal(fieldsById['h-rule'].align, 'top');
assert.equal(fieldsById['v-rule'].align, 'right');
assert.deepEqual(
  canonicalFields.overlays[0].drawer,
  { width: 'medium', showShadow: 'shown' },
);
assert.equal(legacyFields.elements[0].verticalAlign, 'middle');
assert.equal(legacyFields.overlays[0].drawer.position, 'end');

// ---- Endpoint helpers (the /spec endpoints are deprecated, OpenAPI 2.0.0+20261030)
assert.equal(createPath(), '/v2/workbooks');
assert.equal(readPath('w1'), '/v2/workbooks/w1?includeContents=true');
assert.equal(
  readPath('w1', 'workbook', { documentVersion: 3 }),
  '/v2/workbooks/w1?includeContents=true&documentVersion=3',
);
assert.equal(updatePath('w1'), '/v2/workbooks/w1/contents');
assert.equal(createPath('report'), '/v2/reports');
assert.equal(readPath('r1', 'report'), '/v2/reports/r1?includeContents=true');
assert.equal(updatePath('r1', 'report'), '/v2/reports/r1/contents');
assert.throws(() => createPath('dataModel'), /unknown code-rep type/);

const { document: liveDoc, ...liveEnvelope } = live;
const liveContents = { ...liveEnvelope, contents: liveDoc, documentVersion: 2 };
assert.deepEqual(document(liveContents), document(live));
assert.deepEqual(Object.keys(metadata(liveContents)).sort(), ['documentVersion', 'name', 'workbookId']);

const created = createBody({ ...live, folderId: 'f1' });
assert.deepEqual(Object.keys(created).sort(), ['contents', 'folderId', 'name']);
assert.deepEqual(created.contents.elements.map((element) => element.id), ['e1']);
assert.equal('document' in created, false);
assert.equal('dryRun' in created, false);

const overridden = createBody(live.document, {
  extra: { name: 'X', folderId: 'f2' },
  dryRun: true,
});
assert.equal(overridden.name, 'X');
assert.equal(overridden.folderId, 'f2');
assert.equal(overridden.dryRun, true);

const flatBody = createBody(nested, { extra: { name: 'N', folderId: 'f' } });
assert.deepEqual(flatBody.contents.elements.map((element) => element.id), ['old']);
assert.equal('elements' in flatBody.contents.pages[0], false);

assert.deepEqual(updateBody(live), { contents: createBody(live).contents });
assert.equal(updateBody(live, { documentVersion: 4 }).documentVersion, 4);

const report = { contents: { schemaVersion: 1, pages: [{ id: 'p', elements: [{ id: 'x' }] }] } };
assert.deepEqual(updateBody(report, { type: 'report' }).contents, report.contents);

// Live-observed 2026-11-03 response shapes.
assert.equal(dryRunResult(200, { dryRun: true, warnings: [] }).valid, true);
const bad = dryRunResult(400, {
  dryRun: true,
  valid: false,
  errors: [{ summary: 'contents.pages: Invalid array: undefined' }],
});
assert.equal(bad.valid, false);
assert.deepEqual(bad.errors.map((e) => e.summary), ['contents.pages: Invalid array: undefined']);
assert.deepEqual(
  dryRunResult(403, { message: 'forbidden', code: 'forbidden' }).errors,
  [{ summary: 'forbidden' }],
);

assert.deepEqual(
  Object.keys(stripResponseOnly({
    workbookId: 'w', workbookUrlId: 'u', path: 'p', latestVersion: 1,
    latestDocumentVersion: 1, folderId: 'f', name: 'N', contents: {},
  })).sort(),
  ['contents', 'folderId', 'name'],
);

console.log('PASS — JavaScript workbook code representation');
