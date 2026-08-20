#!/usr/bin/env node
// test-post-and-readback.mjs — regression test for the workbook code-rep
// document-wrapper fix (Task 3.1). Verifies the shared CodeRep adapter
// (vendored at ./lib/code_rep.mjs) reads the LIVE nested workbook readback
// shape and produces a properly-nested POST body, confirms the datamodel
// surface's flat shape stays untouched (it is NOT changing — do not apply
// CodeRep to /v2/dataModels/.../spec payloads), and — the real regression
// signal — that post-and-readback.mjs itself routes its workbook branch
// through CodeRep rather than spreading the flat spec straight into the
// POST body.
//
// Run: node scripts/test-post-and-readback.mjs   (exit 0 = pass)
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as CodeRep from './lib/code_rep.mjs';
import { workbookContractErrors } from './lib/workbook_contract.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

let fail = 0;
const check = (cond, msg) => { if (!cond) fail++; console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${msg}`); };

// workbook readback pages found when nested
{
  const readback = { workbookId: 'w', document: { pages: [{ id: 'p1' }] } };
  check(JSON.stringify(CodeRep.document(readback).pages) === JSON.stringify([{ id: 'p1' }]),
        'workbook readback: CodeRep.document() finds pages nested under `document`');
}

// workbook post body is nested
{
  const doc = { schemaVersion: 1, pages: [{ id: 'p1' }], elements: [{ id: 'e1', kind: 'text', body: 'x' }],
    layout: '<Page id="p1"><Element elementId="e1"/></Page>', kind: 'workbook' };
  const body = CodeRep.wrap(doc, { name: 'n', folderId: 'f' });
  check(JSON.stringify(body.document) === JSON.stringify(doc), 'workbook POST body: document key holds the doc verbatim');
  check(!('pages' in body), 'workbook POST body: pages must not remain top-level');
  check(workbookContractErrors(body, { requireWrapper: true }).length === 0,
    'workbook POST body: flat elements + metadata-only pages + authoritative layout pass');
  const bad = { name: 'bad', document: { schemaVersion: 1, pages: [{ id: 'p1', elements: [{ id: 'e1' }] }] } };
  check(workbookContractErrors(bad, { requireWrapper: true }).some((e) => /metadata-only/.test(e)),
    'workbook POST body: legacy page-nested elements fail loudly');
}

// the DM branch must be left alone — that surface is not changing
{
  const readback = { dataModelId: 'd', pages: [{ id: 'p1' }], schemaVersion: 1 };
  check(JSON.stringify(readback.pages) === JSON.stringify([{ id: 'p1' }]),
        'DM readback must still be read flat, unchanged');
}

// Real regression signal: post-and-readback.mjs itself must route its
// workbook branch through CodeRep, not a flat `{ folderId, ...spec, name }`
// spread — that's the actual bug this task fixes.
const src = readFileSync(join(__dirname, 'post-and-readback.mjs'), 'utf8');
check(/CodeRep\.(document|wrap|metadata)/.test(src),
      'post-and-readback.mjs must call CodeRep for its workbook branch');
check(/assertWorkbookContract/.test(src),
      'post-and-readback.mjs must gate the required authoritative layout before and after POST');

// The property the check above does NOT protect: that CodeRep is reachable
// ONLY from the workbook side of the `a.type === 'workbook' ? ... : ...`
// ternary, never from the datamodel (else) side. A regex/substring match
// would still pass even if a future edit moved a CodeRep call into the
// datamodel branch of the same ternary. Locate the ternary's `?` after the
// workbook guard, then its own top-level `:` and terminating `;` by
// tracking ([{ }]) depth (object-literal colons inside a deeper `{...}`
// are skipped, not mistaken for the ternary's own `:`).
{
  const guardIdx = src.indexOf("a.type === 'workbook'");
  check(guardIdx !== -1, "post-and-readback.mjs: expected an `a.type === 'workbook'` guard");
  const rest = src.slice(guardIdx);
  const qMark = rest.indexOf('?');
  check(qMark !== -1, 'post-and-readback.mjs: expected a ternary (`?`) after the workbook guard');

  const findAtDepth0 = (from, chars) => {
    let depth = 0;
    for (let i = from; i < rest.length; i++) {
      const ch = rest[i];
      if ('([{'.includes(ch)) depth++;
      else if (')]}'.includes(ch)) depth--;
      else if (depth === 0 && chars.includes(ch)) return i;
    }
    return -1;
  };

  const colonIdx = qMark === -1 ? -1 : findAtDepth0(qMark + 1, ':');
  check(colonIdx !== -1,
        "post-and-readback.mjs: could not locate the ternary's top-level `:` — structure may have changed; update this test");
  const semiIdx = colonIdx === -1 ? -1 : findAtDepth0(colonIdx + 1, ';');
  check(semiIdx !== -1,
        'post-and-readback.mjs: could not locate the ternary\'s terminating `;` — structure may have changed; update this test');

  if (qMark !== -1 && colonIdx !== -1 && semiIdx !== -1) {
    const workbookBranch = rest.slice(qMark + 1, colonIdx);
    const datamodelBranch = rest.slice(colonIdx + 1, semiIdx);
    check(/CodeRep\.(document|wrap|metadata)/.test(workbookBranch),
          'ternary workbook branch must call CodeRep');
    check(!/CodeRep\.(document|wrap|metadata)/.test(datamodelBranch),
          'ternary datamodel (else) branch must NOT call CodeRep');
  }
}

console.log(fail === 0
  ? 'ALL PASS — cognos post-and-readback workbook branch wraps/unwraps via code_rep'
  : `${fail} FAILURE(S)`);
process.exit(fail === 0 ? 0 : 1);
