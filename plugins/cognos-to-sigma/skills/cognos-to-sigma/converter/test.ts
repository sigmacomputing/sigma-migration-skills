// Smoke test on the bundled fixtures: node --import tsx/esm test.ts
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { convertCognosToSigma } from './cognos.js';
import { convertCognosReportToSigma } from './cognos-report.js';
import { sigmaDisplayName } from './sigma-ids.js';
// @ts-expect-error Vendored runtime adapter is plain ESM.
import * as CodeRep from '../scripts/lib/code_rep.mjs';

const FIX = join(dirname(fileURLToPath(import.meta.url)), '..', 'fixtures');
let fail = 0;

// ── sigmaDisplayName must match Sigma's OWN derivation (incl. letter↔digit splits;
// verified against live DM readbacks 2026-06-10 — [bead]) ──────────────
const NAME_CASES: Array<[string, string]> = [
  ['CY_Q1_REVENUE', 'Cy Q 1 Revenue'],   // the 16-dep-not-found case: Q1 splits to "Q 1"
  ['PY_Q4', 'Py Q 4'],
  ['FY2024', 'Fy 2024'],                  // letters→digits boundary, multi-digit group
  ['REVENUE_FY2024', 'Revenue Fy 2024'],
  ['X2024FY', 'X 2024 Fy'],               // digits→letters boundary
  ['Sheet1_1', 'Sheet 1 1'],
  ['GROSS_PROFIT', 'Gross Profit'],
  ['Province_or_State', 'Province or State'],  // small words stay lowercase (not first)
  ['Month_number', 'Month Number'],
  ['_row_id', 'Row Id'],
];
for (const [input, expected] of NAME_CASES) {
  const got = sigmaDisplayName(input);
  if (got === expected) console.log(`✓ sigmaDisplayName(${JSON.stringify(input).padEnd(20)}) → ${JSON.stringify(got)}`);
  else { fail++; console.log(`✗ sigmaDisplayName(${JSON.stringify(input)}) → ${JSON.stringify(got)} (expected ${JSON.stringify(expected)})`); }
}

// ── go-sales-performance regression: macro→Switch wired by controlId, segmented
// control with values+default, KPI singletons, element filters ───────────────────
{
  const r = convertCognosReportToSigma(readFileSync(join(FIX, 'go-sales-performance.report.xml'), 'utf8'), { dataModelId: 'dm' });
  const doc = CodeRep.document(r.workbook);
  const els = CodeRep.workbookElements(r.workbook) as any[];
  const controls = els.filter((e: any) => e.kind === 'control');
  const ctl = controls.find((c: any) => c.controlId === 'pColumn') as any;
  const checks: Array<[string, boolean]> = [
    ['workbook uses document wrapper', !!r.workbook.document && !('pages' in (r.workbook as any))],
    ['pages are metadata-only', doc.pages.every((p: any) => !('elements' in p))],
    ['elements are flat', Array.isArray(doc.elements) && doc.elements.length === els.length],
    ['authoritative layout places every element',
      els.every((e: any) => (doc.layout.match(new RegExp(`elementId="${e.id}"`, 'g')) || []).length === 1)],
    ['layout uses live Element tags',
      /<Element\b/.test(doc.layout) && !/<(?:LayoutElement|GridContainer)\b/.test(doc.layout)],
    ['pColumn control is segmented', ctl?.controlType === 'segmented'],
    ['pColumn has explicit values', JSON.stringify(ctl?.source?.values) === JSON.stringify(['Revenue', 'Gross Profit'])],
    ['pColumn defaults to Revenue', ctl?.value === 'Revenue'],
    ['pQuarter control registered with Q1-Q4 + default Q4',
      controls.some((c: any) => c.controlId === 'pQuarter' && c.value === 'Q4' && c.source?.values?.length === 4)],
    ['Switch wired by controlId [pColumn]',
      els.some((e) => e.columns?.some((c: any) => /Switch\(\[pColumn\], "Gross Profit", \[Sheet 1\/Gross Profit\], \[Sheet 1\/Revenue\]\)/.test(c.formula)))],
    ['6 KPI singletons converted', els.filter((e) => e.kind === 'kpi-chart').length === 6],
    ['KPI value uses columnId', els.filter((e) => e.kind === 'kpi-chart').every((e) => e.value?.columnId)],
    ['KPI macro → Switch over digit-split refs',
      els.some((e) => e.kind === 'kpi-chart' && e.columns?.some((c: any) => c.formula.includes('[Sheet 1 1/Cy Q 1 Revenue]')))],
    ['detail filters became element filters', r.stats.filters >= 4],
    ['?pQuarter? filter is a boolean match column',
      els.some((e) => e.columns?.some((c: any) => c.formula === '[Quarter Label] = [pQuarter]'))],
    ['lists grouped', els.some((e) => e.kind === 'table' && e.groupings?.length)],
    ['year bound categorically on the line chart',
      els.some((e) => e.kind === 'line-chart' && e.columns?.some((c: any) => /^Text\(/.test(c.formula) && c.name === 'Year'))],
    ['no unresolved Switch placeholders', !els.some((e) => e.columns?.some((c: any) => /map prompt tokens/.test(c.formula)))],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ go-sales: ${label}`);
    else { fail++; console.log(`✗ go-sales: ${label}`); }
  }
}

// ── workbook-code release surface: flat elements + required layout and the
// newly released grounded mappings (waterfall/legend/drill/navigation/
// page-break/progress/panels/styles/repeaters); gated box stays loud. ──────────
{
  const xml = `<report viewPagesAsTabs="topLeft">
    <reportName>Release features</reportName>
    <layouts><layout><reportPages>
      <page name="Overview"><pageHeader><style><CSS value="background-color:#445566"/></style></pageHeader><pageBody><contents>
        <block name="Revenue panel"><style><CSS value="background-color:#112233;border-radius:8px"/></style>
          <vizControl name="Revenue bridge" type="com.ibm.vis.waterfall">
            <vcDataSet refDataStore="ds"/>
            <vcSlotData idSlot="categories"><vcSlotDsColumn refDsColumn="Category"/></vcSlotData>
            <vcSlotData idSlot="values"><vcSlotDsColumn refDsColumn="Revenue" rollupMethod="total"/></vcSlotData>
            <vizPropertyValues><vizPropertyBooleanValue name="legendVisible">true</vizPropertyBooleanValue>
              <vizPropertyEnumValue name="legendPosition">right</vizPropertyEnumValue></vizPropertyValues>
          </vizControl>
        </block>
        <pageBreak/>
        <repeater name="Category cards" refQuery="q"><dataItemValue refDataItem="Category"/></repeater>
        <drillBehavior enabled="true"/>
      </contents></pageBody></page>
      <page name="Detail"><pageBody><contents>
        <vizControl name="Target progress" type="com.ibm.vis.progressbar">
          <vcDataSet refDataStore="ds"/>
          <vcSlotData idSlot="values"><vcSlotDsColumn refDsColumn="Revenue" rollupMethod="total"/></vcSlotData>
        </vizControl>
        <vizControl name="Distribution" type="com.ibm.vis.boxplot">
          <vcDataSet refDataStore="ds"/>
          <vcSlotData idSlot="categories"><vcSlotDsColumn refDsColumn="Category"/></vcSlotData>
          <vcSlotData idSlot="values"><vcSlotDsColumn refDsColumn="Revenue" rollupMethod="total"/></vcSlotData>
        </vizControl>
      </contents></pageBody></page>
    </reportPages></layout></layouts>
    <queries><query name="q"><selection>
      <dataItem name="Category" aggregate="none"><expression>[C].[M].[Sales].[Category]</expression></dataItem>
      <dataItem name="Revenue" aggregate="total"><expression>[C].[M].[Sales].[Revenue]</expression></dataItem>
    </selection></query></queries>
    <reportDataStores><reportDataStore name="ds"><dsV5ListQuery refQuery="q"/></reportDataStore></reportDataStores>
  </report>`;
  const r = convertCognosReportToSigma(xml, { dataModelId: 'dm' });
  const doc = CodeRep.document(r.workbook);
  const els = CodeRep.workbookElements(r.workbook) as any[];
  const checks: Array<[string, boolean]> = [
    ['two Cognos pages stay two metadata-only pages', doc.pages.length === 2 && doc.pages.every((p: any) => !p.elements)],
    ['auto navigation emitted per tabbed report page', els.filter((e: any) => e.kind === 'navigation' && e.mode === 'auto').length === 2],
    ['waterfall uses released kind + yAxis', els.some((e: any) => e.kind === 'waterfall-chart' && e.yAxis?.columnIds?.length === 1)],
    ['legend settings grounded from viz properties', els.some((e: any) => e.kind === 'waterfall-chart' && e.legend?.visibility === 'shown' && e.legend?.position === 'right')],
    ['drillBehavior uses released drill control', els.some((e: any) => e.kind === 'control' && e.controlType === 'drill')],
    ['page break emitted', els.some((e: any) => e.kind === 'page-break')],
    ['progress emitted with hidden aggregate source', els.some((e: any) => e.kind === 'progress' && typeof e.value === 'string')
      && els.some((e: any) => e.name === 'Target progress (progress source)' && e.visibleAsSource === false)],
    ['named block becomes styled panel', els.some((e: any) => e.kind === 'container' && e.name === 'Revenue Panel' && e.style?.backgroundColor === '#112233')],
    ['page header becomes document panel', doc.panels?.some((p: any) => p.type === 'header'
      && p.pages?.[0] === doc.pages[0].id && p.config?.backgroundColor === '#445566')],
    ['repeater becomes repeated-container with child binding', els.some((e: any) => e.kind === 'repeated-container')
      && els.some((e: any) => e.name === 'Category cards source' && e.visibleAsSource === false)
      && els.some((e: any) => e.kind === 'text' && /Category cards source repeated container/.test(e.body || ''))],
    ['box chart remains loud and data-preserving', els.some((e: any) => e.kind === 'table' && /was box plot/.test(e.name || '') && e.groupings?.length)
      && r.warnings.some((w) => w.includes('⛔ WORKBOOK FEATURE GAP [box-chart (workspace gated)]'))],
    ['layout is authoritative for every flat element',
      els.every((e: any) => (doc.layout.match(new RegExp(`elementId="${e.id}"`, 'g')) || []).length === 1)],
    ['panel layout uses live Element/Container tags',
      /<Element\b/.test(doc.layout) && /<Container\b/.test(doc.layout)
        && !/<(?:LayoutElement|GridContainer)\b/.test(doc.layout)],
  ];
  for (const [label, ok] of checks) {
    if (ok) console.log(`✓ release: ${label}`);
    else { fail++; console.log(`✗ release: ${label}`); }
  }
}

for (const f of readdirSync(FIX)) {
  try {
    if (f.endsWith('.module.json')) {
      const r = convertCognosToSigma(readFileSync(join(FIX, f), 'utf8'), { connectionId: 'c', database: 'DB', schema: 'S' });
      if (!r.model.pages[0].elements.length) throw new Error('no elements');
      console.log(`✓ ${f.padEnd(34)} module → ${r.stats.elements} elems · ${r.stats.columns} cols · ${r.stats.metrics} metrics · ${r.stats.relationships} rels`);
    } else if (f.endsWith('.report.xml')) {
      const r = convertCognosReportToSigma(readFileSync(join(FIX, f), 'utf8'), { dataModelId: 'dm' });
      const doc = CodeRep.document(r.workbook);
      if (!Array.isArray(doc.elements) || doc.pages.some((p: any) => 'elements' in p) || !doc.layout) {
        throw new Error('legacy workbook representation');
      }
      if (/<(?:LayoutElement|GridContainer)\b/.test(doc.layout)) {
        throw new Error('legacy workbook layout tags');
      }
      console.log(`✓ ${f.padEnd(34)} report → ${r.stats.tables} tables · ${r.stats.pivots} pivots · ${r.stats.kpis} kpis · ${r.stats.charts} charts · ${r.stats.maps} maps · ${r.stats.columns} cols · ${r.stats.filters} filters · ${r.stats.controls} controls`);
    }
  } catch (e: any) { fail++; console.log(`✗ ${f} — ${e.message}`); }
}
console.log(fail ? `\n${fail} FAILED` : '\nall fixtures converted ✓');
process.exit(fail ? 1 : 0);
