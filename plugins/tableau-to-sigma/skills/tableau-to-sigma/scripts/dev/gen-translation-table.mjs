#!/usr/bin/env node
// gen-translation-table.mjs — W2.13: THE generator for the ONE translation
// table. Emits refs/functions.json (new schema) and refs/coverage-manifest.json
// (compat view, old schema) by RUNNING the vendored converter's own
// tableauFormulaToSigma over one canonical probe per catalog function.
//
// Inputs (both committed, so CI can regenerate and diff):
//   converter/tableau.mjs            — the vendored bundle (X2 build artifact)
//   scripts/lib/tableau_functions.json — the live 187-entry tflex catalog that
//                                      CalcCoverage.catalog_index serves
//
// Why probe-the-translator instead of parsing name-maps: TABLEAU_FUNC_MAP is
// only one of the translator's surfaces — DATEPART/DATENAME/window/RLS
// rewrites live in code branches. Executing the real translator means the
// table CANNOT drift from the code: any converter change shows up as a diff
// in the regenerated table, and the determinism test fails until the artifact
// is re-committed alongside it.
//
// The bundle does not export its formula internals, so the generator imports
// a temp copy with an appended export shim (the bundle is self-contained —
// esbuild --bundle — so a copy imports cleanly from any path). Read-only:
// the vendored bundle itself is never modified.
//
// Determinism contract (CI-diffed): output depends only on the two inputs.
// No timestamps, sorted function order, stable key order, input sha256s
// recorded so a bundle change without a regen is visible in review.
//
// Usage: node scripts/dev/gen-translation-table.mjs [--out-dir DIR] [--check]
//   --check: regenerate to a temp location and diff against the committed
//            artifacts; exit 1 on drift (what CI runs).
import { readFileSync, writeFileSync, mkdtempSync, rmSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, '..', '..');
const BUNDLE = join(SKILL, 'converter', 'tableau.mjs');
const CATALOG = join(SKILL, 'scripts', 'lib', 'tableau_functions.json');
const OUT_FUNCTIONS = join(SKILL, 'refs', 'functions.json');
const OUT_MANIFEST = join(SKILL, 'refs', 'coverage-manifest.json');

const args = process.argv.slice(2);
const CHECK = args.includes('--check');
let outDir = null;
const odIdx = args.indexOf('--out-dir');
if (odIdx >= 0) outDir = args[odIdx + 1];

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

// ---------------------------------------------------------------- load inputs
const bundleText = readFileSync(BUNDLE, 'utf8');
const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'));

// Import a temp copy of the bundle with an export shim appended. The shim
// only ADDS exports; behavior is untouched.
const SHIM = `\nexport { tableauFormulaToSigma as __ttFormulaToSigma, TABLEAU_FUNC_MAP as __ttFuncMap, tableauWindowToSigmaChart as __ttWinChart, tableauWindowUntranslatable as __ttWinUntranslatable, tableauFormulaIsRls as __ttIsRls };\n`;
const tmp = mkdtempSync(join(tmpdir(), 'tt-table-'));
const tmpBundle = join(tmp, 'tableau-shimmed.mjs');
writeFileSync(tmpBundle, bundleText + SHIM);
const mod = await import(pathToFileURL(tmpBundle).href);
rmSync(tmp, { recursive: true, force: true });
const toSigma = mod.__ttFormulaToSigma;
const FUNC_MAP = mod.__ttFuncMap;
const winChart = mod.__ttWinChart;
const winUntranslatable = mod.__ttWinUntranslatable;
const isRls = mod.__ttIsRls;
if (typeof toSigma !== 'function' || !FUNC_MAP) {
  console.error('gen-translation-table: export shim failed — bundle internals renamed?');
  process.exit(2);
}

// ------------------------------------------------------------ probe synthesis
// One canonical Tableau invocation per catalog function. SPECIAL entries are
// the forms whose translator branches key on literal argument patterns
// (quoted dateparts, agg-wrapped table calcs, RLS string args). Everything
// else gets a generic arg vector — for name-map renames the args are inert.
// Placeholder field refs are NEUTRAL ([NUM_A]/[TXT_A]/[DATE_A]/[FLAG_A]).
const SPECIAL = {
  DATEPART: "DATEPART('year', [DATE_A])",
  DATENAME: "DATENAME('month', [DATE_A])",
  DATETRUNC: "DATETRUNC('month', [DATE_A])",
  DATEADD: "DATEADD('day', 7, [DATE_A])",
  DATEDIFF: "DATEDIFF('day', [DATE_A], [DATE_B])",
  DATEPARSE: "DATEPARSE('yyyy-MM-dd', [TXT_A])",
  MAKEDATE: 'MAKEDATE(2024, 1, 15)',
  MAKEDATETIME: 'MAKEDATETIME([DATE_A], [DATE_B])',
  MAKETIME: 'MAKETIME(12, 30, 0)',
  ISDATE: "ISDATE([TXT_A])",
  IIF: 'IIF([FLAG_A], 1, 0)',
  IFNULL: 'IFNULL([NUM_A], 0)',
  IFERROR: 'IFERROR([NUM_A], 0)',
  ISNULL: 'ISNULL([NUM_A])',
  ZN: 'ZN(SUM([NUM_A]))', // the dominant field null-guard idiom
  COUNT: 'COUNT([TXT_A])',
  COUNTD: 'COUNTD([TXT_A])',
  ATTR: 'ATTR([TXT_A])',
  MIN: 'MIN([NUM_A])',
  MAX: 'MAX([NUM_A])',
  SPLIT: "SPLIT([TXT_A], '-', 1)",
  FINDNTH: "FINDNTH([TXT_A], '-', 2)",
  FIND: "FIND([TXT_A], '-')",
  CONTAINS: "CONTAINS([TXT_A], '-')",
  STARTSWITH: "STARTSWITH([TXT_A], '-')",
  ENDSWITH: "ENDSWITH([TXT_A], '-')",
  REPLACE: "REPLACE([TXT_A], '-', '_')",
  REGEXP_EXTRACT: "REGEXP_EXTRACT([TXT_A], '(\\d+)')",
  REGEXP_EXTRACT_N: "REGEXP_EXTRACT_N([TXT_A], '(\\d+)', 1)",
  REGEXP_MATCH: "REGEXP_MATCH([TXT_A], '(\\d+)')",
  REGEXP_REPLACE: "REGEXP_REPLACE([TXT_A], '(\\d+)', '_')",
  LEFT: 'LEFT([TXT_A], 3)',
  RIGHT: 'RIGHT([TXT_A], 3)',
  MID: 'MID([TXT_A], 2, 3)',
  PERCENTILE: 'PERCENTILE([NUM_A], 0.5)',
  CORR: 'CORR([NUM_A], [NUM_B])',
  COVAR: 'COVAR([NUM_A], [NUM_B])',
  COVARP: 'COVARP([NUM_A], [NUM_B])',
  STDEVP: 'STDEVP([NUM_A])',
  VARP: 'VARP([NUM_A])',
  SQUARE: 'SQUARE([NUM_A])',
  SPACE: 'SPACE(3)',
  ROUND: 'ROUND([NUM_A], 2)',
  POWER: 'POWER([NUM_A], 2)',
  ATAN2: 'ATAN2([NUM_A], [NUM_B])',
  // table calcs — canonical forms the chart-router recognizes (or refuses)
  WINDOW_SUM: 'WINDOW_SUM(SUM([NUM_A]), -3, 0)',
  WINDOW_AVG: 'WINDOW_AVG(SUM([NUM_A]), -3, 0)',
  WINDOW_MIN: 'WINDOW_MIN(SUM([NUM_A]), -3, 0)',
  WINDOW_MAX: 'WINDOW_MAX(SUM([NUM_A]), -3, 0)',
  WINDOW_STDEV: 'WINDOW_STDEV(SUM([NUM_A]), -3, 0)',
  WINDOW_STDEVP: 'WINDOW_STDEVP(SUM([NUM_A]), -3, 0)',
  WINDOW_VAR: 'WINDOW_VAR(SUM([NUM_A]), -3, 0)',
  WINDOW_VARP: 'WINDOW_VARP(SUM([NUM_A]), -3, 0)',
  WINDOW_COUNT: 'WINDOW_COUNT(SUM([NUM_A]), -3, 0)',
  WINDOW_MEDIAN: 'WINDOW_MEDIAN(SUM([NUM_A]), -3, 0)',
  WINDOW_PERCENTILE: 'WINDOW_PERCENTILE(SUM([NUM_A]), 0.5)',
  WINDOW_CORR: 'WINDOW_CORR(SUM([NUM_A]), SUM([NUM_B]), -3, 0)',
  WINDOW_COVAR: 'WINDOW_COVAR(SUM([NUM_A]), SUM([NUM_B]), -3, 0)',
  WINDOW_COVARP: 'WINDOW_COVARP(SUM([NUM_A]), SUM([NUM_B]), -3, 0)',
  RUNNING_SUM: 'RUNNING_SUM(SUM([NUM_A]))',
  RUNNING_AVG: 'RUNNING_AVG(SUM([NUM_A]))',
  RUNNING_MIN: 'RUNNING_MIN(SUM([NUM_A]))',
  RUNNING_MAX: 'RUNNING_MAX(SUM([NUM_A]))',
  RUNNING_COUNT: 'RUNNING_COUNT(SUM([NUM_A]))',
  RANK: 'RANK(SUM([NUM_A]))',
  RANK_DENSE: 'RANK_DENSE(SUM([NUM_A]))',
  RANK_PERCENTILE: 'RANK_PERCENTILE(SUM([NUM_A]))',
  RANK_UNIQUE: 'RANK_UNIQUE(SUM([NUM_A]))',
  RANK_MODIFIED: 'RANK_MODIFIED(SUM([NUM_A]))',
  INDEX: 'INDEX()',
  SIZE: 'SIZE()',
  FIRST: 'FIRST()',
  LAST: 'LAST()',
  LOOKUP: 'LOOKUP(SUM([NUM_A]), -1)',
  PREVIOUS_VALUE: 'PREVIOUS_VALUE(0)',
  TOTAL: 'TOTAL(SUM([NUM_A]))',
  // RLS / user functions — string args the rewrites key on
  ISMEMBEROF: "ISMEMBEROF('group')",
  ISUSERNAME: "ISUSERNAME('user')",
  USERATTRIBUTE: "USERATTRIBUTE('attr')",
  USERATTRIBUTEINCLUDES: "USERATTRIBUTEINCLUDES('attr', 'v')",
  // RAWSQL family — passthrough SQL probes
  RAWSQL_BOOL: "RAWSQL_BOOL('1=1')",
  RAWSQL_DATE: "RAWSQL_DATE('%1', [DATE_A])",
  RAWSQL_DATETIME: "RAWSQL_DATETIME('%1', [DATE_A])",
  RAWSQL_INT: "RAWSQL_INT('%1', [NUM_A])",
  RAWSQL_REAL: "RAWSQL_REAL('%1', [NUM_A])",
  RAWSQL_STR: "RAWSQL_STR('%1', [TXT_A])",
  RAWSQLAGG_BOOL: "RAWSQLAGG_BOOL('1=1')",
  RAWSQLAGG_DATE: "RAWSQLAGG_DATE('%1', [DATE_A])",
  RAWSQLAGG_DATETIME: "RAWSQLAGG_DATETIME('%1', [DATE_A])",
  RAWSQLAGG_INT: "RAWSQLAGG_INT('%1', [NUM_A])",
  RAWSQLAGG_REAL: "RAWSQLAGG_REAL('%1', [NUM_A])",
  RAWSQLAGG_STR: "RAWSQLAGG_STR('%1', [TXT_A])"
};

const ARG_POOL = {
  number: ['[NUM_A]', '[NUM_B]', '[NUM_C]'],
  aggregate: ['[NUM_A]', '[NUM_B]', '[NUM_C]'],
  string: ['[TXT_A]', '[TXT_B]', '[TXT_C]'],
  date: ['[DATE_A]', '[DATE_B]', '[DATE_C]'],
  logical: ['[FLAG_A]', '[FLAG_B]', '[FLAG_C]'],
  'type-conversion': ['[TXT_A]', '[TXT_B]', '[TXT_C]'],
  user: ['[TXT_A]', '[TXT_B]', '[TXT_C]']
};

function genericProbe(entry) {
  const n = Math.max(0, entry.minArgs | 0);
  const pool = ARG_POOL[(entry.category || '').toLowerCase()] || ['[TXT_A]', '[TXT_B]', '[TXT_C]'];
  const args = [];
  for (let i = 0; i < n; i++) args.push(pool[i % pool.length]);
  return `${entry.name}(${args.join(', ')})`;
}

// ----------------------------------------------------------- classification
const PLACEHOLDER_RE = /^(NUM|TXT|DATE|FLAG)_[A-C]$/;
function sigmaNamesIn(template) {
  // function-name census over the Sigma-side output: mask [refs] and
  // "strings", then take identifier( tokens. Lowercase operators (and/or)
  // never match the leading-capital requirement is NOT imposed — Sigma names
  // are compared against the whitelist by the drift test, so collect all.
  const masked = template.replace(/"[^"]*"/g, '""').replace(/\[[^\]]*\]/g, '[]');
  const out = new Set();
  const re = /\b([A-Za-z][A-Za-z0-9_]*)\s*\(/g;
  let m;
  while ((m = re.exec(masked)) !== null) {
    if (PLACEHOLDER_RE.test(m[1])) continue;
    out.add(m[1]);
  }
  return [...out].sort();
}

function classify(entry) {
  const fn = entry.name.toUpperCase();
  const probe = SPECIAL[fn] || genericProbe(entry);
  const warnings = [];
  const template = toSigma(probe, warnings);
  const chart = winChart ? winChart(probe) : null;
  const row = {
    tableau_fn: fn,
    category: entry.category || 'other',
    probe,
    sigma_template: template,
    sigma_functions: [],
    arg_transform: 'none',
    context: 'spec',
    verify_flags: [],
    status: 'spec'
  };
  const verifyWarnings = warnings.filter((w) => /verify|Verify/.test(w));
  const unmappedWarning = warnings.find((w) => w.includes('Unmapped Tableau function(s) passed through'));
  const refusal = /^\/\*/.test(template.trim());

  if (refusal) {
    // /* LOD | table calc | no Sigma equivalent */ — loud refusal
    row.status = 'not_converted';
    row.context = 'none';
    row.arg_transform = 'none';
    row.verify_flags = warnings.map(shortWarn);
    return row;
  }
  if (chart && chart.formula) {
    row.status = 'chart_only';
    row.context = 'chart';
    row.arg_transform = 'rewrite';
    row.sigma_template = chart.formula;
    row.sigma_functions = sigmaNamesIn(chart.formula);
    row.verify_flags = warnings.map(shortWarn);
    if (chart.note) row.verify_flags.push(shortWarn(chart.note));
    return row;
  }
  const unmappedNamesThis = unmappedWarning &&
    new RegExp(`(^|[ ,:])${fn}([ ,]|$)`).test(unmappedWarning.split('passed through unconverted:')[1] || '');
  if (unmappedNamesThis) {
    row.status = 'unmapped';
    row.context = 'none';
    row.arg_transform = 'passthrough';
    row.sigma_functions = [];
    return row;
  }
  // translated
  row.sigma_functions = sigmaNamesIn(template);
  row.arg_transform = Object.prototype.hasOwnProperty.call(FUNC_MAP, fn) ? 'name-map' : 'rewrite';
  if (isRls && isRls(probe)) {
    row.status = 'rls';
    row.context = 'rls';
  } else if (verifyWarnings.length > 0) {
    row.status = 'verify';
  }
  row.verify_flags = verifyWarnings.map(shortWarn);
  return row;
}

function shortWarn(w) {
  return w.replace(/\s+/g, ' ').trim().slice(0, 160);
}

// ------------------------------------------------------------------- generate
const rows = catalog.functions
  .map((e) => classify(e))
  .sort((a, b) => (a.tableau_fn < b.tableau_fn ? -1 : a.tableau_fn > b.tableau_fn ? 1 : 0));

const counts = {};
for (const r of rows) counts[r.status] = (counts[r.status] || 0) + 1;
const sortedCounts = Object.fromEntries(Object.keys(counts).sort().map((k) => [k, counts[k]]));

// name-map keys the catalog does not know — must stay empty (drift pin)
const catalogNames = new Set(catalog.functions.map((e) => e.name.toUpperCase()));
const mapNotInCatalog = Object.keys(FUNC_MAP).filter((k) => !catalogNames.has(k.toUpperCase())).sort();

const functionsDoc = {
  _generated: {
    by: 'scripts/dev/gen-translation-table.mjs',
    note: 'BUILD ARTIFACT — regenerate with `node scripts/dev/gen-translation-table.mjs`; never hand-edit. One row per live-catalog function; sigma_template is the translator\'s real output for the recorded probe.',
    inputs: {
      bundle: 'converter/tableau.mjs',
      bundle_sha256: sha256(bundleText),
      catalog: 'scripts/lib/tableau_functions.json',
      catalog_sha256: sha256(readFileSync(CATALOG))
    },
    statuses: ['spec', 'verify', 'chart_only', 'rls', 'not_converted', 'unmapped'],
    map_not_in_catalog: mapNotInCatalog
  },
  counts: sortedCounts,
  functions: rows
};

// compat view — the retired hand-maintained coverage-manifest schema, kept
// byte-comparable so "counts change only where the manifest was provably
// stale" is reviewable in one diff. Old status vocabulary: not_converted →
// flagged, rls → reported.
const OLD_STATUS = { spec: 'spec', verify: 'verify', chart_only: 'chart_only', rls: 'reported', not_converted: 'flagged', unmapped: 'unmapped' };
const manifestRows = rows.map((r) => ({
  fn: r.tableau_fn,
  category: r.category,
  sigma: r.sigma_functions.length ? r.sigma_functions[0] : null,
  status: OLD_STATUS[r.status],
  probe: r.status === 'unmapped' || r.status === 'not_converted' ? null : r.probe
}));
const mCounts = {};
for (const r of manifestRows) mCounts[r.status] = (mCounts[r.status] || 0) + 1;
const manifestDoc = {
  generated_for: 'W2.13 generated translation table',
  generated_by: 'scripts/dev/gen-translation-table.mjs — BUILD ARTIFACT, regenerate, never hand-edit (was hand-maintained until wave 2)',
  source: 'converter/tableau.mjs tableauFormulaToSigma + TABLEAU_FUNC_MAP (vendored bundle), probed per scripts/lib/tableau_functions.json',
  counts: Object.fromEntries(Object.keys(mCounts).sort().map((k) => [k, mCounts[k]])),
  functions: manifestRows
};

const render = (doc) => JSON.stringify(doc, null, 1) + '\n';

if (CHECK) {
  let drift = 0;
  for (const [path, doc] of [[OUT_FUNCTIONS, functionsDoc], [OUT_MANIFEST, manifestDoc]]) {
    const fresh = render(doc);
    const committed = existsSync(path) ? readFileSync(path, 'utf8') : '';
    if (fresh !== committed) {
      console.error(`DRIFT: ${path} differs from regenerated output — run the generator and commit.`);
      drift = 1;
    } else {
      console.log(`OK: ${path} matches regenerated output`);
    }
  }
  process.exit(drift);
}

const dir = outDir ? resolve(outDir) : null;
if (dir) mkdirSync(dir, { recursive: true });
const fnOut = dir ? join(dir, 'functions.json') : OUT_FUNCTIONS;
const mfOut = dir ? join(dir, 'coverage-manifest.json') : OUT_MANIFEST;
writeFileSync(fnOut, render(functionsDoc));
writeFileSync(mfOut, render(manifestDoc));
console.log(`wrote ${fnOut} (${rows.length} functions: ${JSON.stringify(sortedCounts)})`);
console.log(`wrote ${mfOut}`);
if (mapNotInCatalog.length) {
  console.error(`WARNING: TABLEAU_FUNC_MAP keys missing from the catalog: ${mapNotInCatalog.join(', ')}`);
}
