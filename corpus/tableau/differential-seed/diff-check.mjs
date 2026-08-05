#!/usr/bin/env node
// differential-seed (W2.15) — translator-differential checker/recorder.
//
// THE regression floor under any future engine flip (W2.19): every pair's
// Tableau-dialect formula is re-run through the vendored bundle's OWN
// translator (same temp-copy export shim as scripts/dev/
// gen-translation-table.mjs — the bundle itself is never modified) and the
// output must byte-match the recorded sigma_expected + warnings. An engine
// that changes ANY pair's translation shows up here as a named diff and the
// re-record is a reviewed re-baseline, never a silent drift.
//
//   node diff-check.mjs            — compare (exit 1 on any mismatch)
//   node diff-check.mjs --record   — rewrite pairs.json from the current
//                                    translator (engine-flip re-baseline;
//                                    authored fields are preserved)
//
// Determinism: each pair is translated twice in-process and must agree.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');
const BUNDLE = join(REPO, 'plugins', 'tableau-to-sigma', 'skills', 'tableau-to-sigma', 'converter', 'tableau.mjs');
const PAIRS = join(HERE, 'pairs.json');
const RECORD = process.argv.includes('--record');

const SHIM = `\nexport { tableauFormulaToSigma as __ttFormulaToSigma, tableauWindowToSigmaChart as __ttWinChart };\n`;
const tmp = mkdtempSync(join(tmpdir(), 'diff-seed-'));
const tmpBundle = join(tmp, 'tableau-shimmed.mjs');
writeFileSync(tmpBundle, readFileSync(BUNDLE, 'utf8') + SHIM);
const mod = await import(pathToFileURL(tmpBundle).href);
rmSync(tmp, { recursive: true, force: true });
const toSigma = mod.__ttFormulaToSigma;
const winChart = mod.__ttWinChart;
if (typeof toSigma !== 'function') {
  console.error('diff-check: export shim failed — bundle internals renamed?');
  process.exit(2);
}

function translate(pair) {
  const warnings = [];
  const dm = toSigma(pair.tableau, warnings);
  if (pair.context === 'chart') {
    const chart = winChart ? winChart(pair.tableau) : null;
    return { formula: chart && chart.formula ? chart.formula : dm, warnings };
  }
  return { formula: dm, warnings };
}

const doc = JSON.parse(readFileSync(PAIRS, 'utf8'));
let fail = 0;
for (const pair of doc.pairs) {
  const a = translate(pair);
  const b = translate(pair); // determinism: same input, same output, same run
  if (a.formula !== b.formula || JSON.stringify(a.warnings) !== JSON.stringify(b.warnings)) {
    console.log(`FAIL ${pair.id}: translator is nondeterministic for this input`);
    fail++;
    continue;
  }
  if (RECORD) {
    pair.sigma_expected = a.formula;
    pair.warnings = a.warnings;
    console.log(`RECORDED ${pair.id}: ${a.formula}`);
    continue;
  }
  if (a.formula !== pair.sigma_expected) {
    console.log(`FAIL ${pair.id} [${pair.class}]\n  tableau:  ${pair.tableau}\n  expected: ${pair.sigma_expected}\n  got:      ${a.formula}`);
    fail++;
  } else if (JSON.stringify(a.warnings) !== JSON.stringify(pair.warnings)) {
    console.log(`FAIL ${pair.id} [${pair.class}]: warning drift\n  expected: ${JSON.stringify(pair.warnings)}\n  got:      ${JSON.stringify(a.warnings)}`);
    fail++;
  } else {
    console.log(`PASS ${pair.id}: ${a.formula}`);
  }
}

if (RECORD) {
  writeFileSync(PAIRS, JSON.stringify(doc, null, 2) + '\n');
  console.log(`wrote ${PAIRS} (${doc.pairs.length} pair(s))`);
}
process.exit(fail === 0 ? 0 : 1);
