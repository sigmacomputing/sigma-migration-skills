// Runtime proof that an emitted action actually FIRES — not merely that it
// survived a readback.
//
// CRITICAL: navigate IN-APP, never page.goto(). A fresh page load discards
// action-set control state, which cost a false negative during the 2026-08-06
// probe: the control had been set correctly, the reload cleared it, and the
// target came back unfiltered.
//
// Usage:
//   node scripts/probe-actions-runtime.mjs --url <workbook-url> \
//        --click-text "West" --expect-rows-before 911 --expect-rows-after 319

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? dflt : process.argv[i + 1];
};

const url = arg('url');
if (!url) {
  console.error('SKIP: no --url given — runtime probe not run (this is not a pass)');
  process.exit(0);
}

// Dynamic import: only load puppeteer if we're actually running with a URL.
// This way the SKIP path works even if puppeteer is not installed.
const puppeteerModule = await import('puppeteer');
const puppeteer = puppeteerModule.default;

const clickText = arg('click-text');
const before = Number(arg('expect-rows-before', '0'));
const after = Number(arg('expect-rows-after', '0'));

const browser = await puppeteer.launch({ headless: 'new' });
const page = await browser.newPage();
const fails = [];

try {
  // The ONLY page.goto in this file: the initial load. Everything after this
  // point must reach its next state by clicking inside the app.
  await page.goto(url, { waitUntil: 'networkidle2', timeout: 120000 });
  await page.waitForSelector('[data-testid="table-cell"], [role="grid"]', { timeout: 120000 });

  const countRows = async () =>
    page.$$eval('[role="row"]', (rows) => rows.length);

  const initial = await countRows();
  if (before && initial !== before) {
    fails.push(`expected ${before} rows before the click, saw ${initial}`);
  }

  const target = await page.evaluateHandle(
    (t) => [...document.querySelectorAll('text, tspan, [role="gridcell"]')]
      .find((el) => el.textContent.trim() === t),
    clickText,
  );
  if (!target || !(await target.asElement())) {
    fails.push(`could not find a clickable mark labelled "${clickText}"`);
  } else {
    await target.asElement().click();
    // Wait for the row count to CHANGE rather than a fixed sleep — a fixed
    // sleep either flakes or wastes wall-clock.
    await page.waitForFunction(
      (n) => document.querySelectorAll('[role="row"]').length !== n,
      { timeout: 60000 },
      initial,
    );
    const filtered = await countRows();
    if (after && filtered !== after) {
      fails.push(`expected ${after} rows after clicking "${clickText}", saw ${filtered}`);
    }
    console.log(`rows: ${initial} -> ${filtered}`);
  }
} catch (e) {
  fails.push(`runtime probe threw: ${e.message}`);
} finally {
  await browser.close();
}

if (fails.length === 0) {
  console.log('OK: the action fired and filtered the target at runtime');
} else {
  console.log(`FAILED (${fails.length}):`);
  fails.forEach((f) => console.log(`  - ${f}`));
  process.exit(1);
}
