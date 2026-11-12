#!/usr/bin/env node
// Regression: calculated dimensions that reference a physical column through
// ${TABLE}.col, or another dimension through ${field}, must translate to Sigma
// column refs (not raw SQL identifiers, and not "parameter substitution").
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { convertLookMLToSigma } from "../converter/lookml.mjs";

const skill = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtureDir = path.join(skill, "fixtures", "trip-legs-calc-refs");
const files = [];
for (const name of (await readdir(fixtureDir)).filter(f => f.endsWith(".lkml")).sort())
  files.push({ name, content: await readFile(path.join(fixtureDir, name), "utf8") });

const res = convertLookMLToSigma(files, { connectionId: "TEST", exploreName: "trip_legs" });
const el = res.model.pages[0].elements.find(e => e.name === "Trip Legs");
assert.ok(el, "Trip Legs element emitted");
const col = name => el.columns.find(c => c.name === name);
const warn = field => res.warnings.filter(w => w.includes(`"${field}"`));

// Bug 1: CASE over ${TABLE}.col → qualified column ref, no raw identifier.
assert.equal(col("Distance Band")?.formula, 'If([FACT_LEG/Distance Miles] > 100, "far", "near")');

// Bug 2: yesno over ${dim} → calculated column over that dim's column.
assert.equal(col("Is Long Haul")?.formula, "[FACT_LEG/Distance Miles] > 500");
assert.ok(!warn("is_long_haul").some(w => /parameter substitution/.test(w)), warn("is_long_haul").join("\n"));

// A dimension referencing the yesno inlines its (translated) expression.
assert.equal(col("Haul Label")?.formula, 'If([FACT_LEG/Distance Miles] > 500, "long", "short")');

// Genuine parameter refs with no default are still skipped as parameters.
assert.equal(col("Param Only"), undefined);
assert.ok(warn("param_only").some(w => /parameter substitution/.test(w)), warn("param_only").join("\n"));

// Unsupported field-ref expressions are skipped instead of becoming fake
// warehouse columns named after the calculated dimensions.
for (const field of ["Line Total", "Medium Distance", "Active Status"]) {
  assert.equal(col(field), undefined, `${field} should be skipped`);
}
for (const field of ["line_total", "medium_distance", "active_status"]) {
  assert.ok(warn(field).some(w => /could not auto-convert field-reference calculation/.test(w)), warn(field).join("\n"));
}

// Aliases and parameter-backed dimensions are omitted, so calculations that
// reference them must remain unresolved rather than point at missing columns.
for (const field of ["Distance Alias", "Alias Label", "Param Label"]) {
  assert.equal(col(field), undefined, `${field} should be skipped`);
}
for (const field of ["alias_label", "param_label"]) {
  assert.ok(warn(field).some(w => /parameter substitution/.test(w)), warn(field).join("\n"));
}

// No emitted formula may carry a lowercase raw SQL identifier.
for (const c of el.columns)
  assert.ok(!/\bdistance_miles\b/.test(c.formula), `raw identifier in ${c.name}: ${c.formula}`);

// Custom SQL (derived_table) element: refs must use the [Custom SQL/COL] form —
// a bare [Display Name] does not resolve against a SQL element's output columns.
const dt = convertLookMLToSigma(files, { connectionId: "TEST", exploreName: "leg_summary" });
const dtEl = dt.model.pages[0].elements.find(e => e.source?.kind === "sql");
const dtCol = name => dtEl.columns.find(c => c.name === name);
assert.equal(dtCol("Summary Band")?.formula, 'If([Custom SQL/DISTANCE_MILES] > 100, "far", "near")');
assert.equal(dtCol("Fare per Mile")?.formula, "[Custom SQL/FARE_AMT] / Nullif([Custom SQL/DISTANCE_MILES], 0)");
for (const c of dtEl.columns)
  assert.match(c.formula, /^[^[]*(\[Custom SQL\/[A-Z_]+\][^[]*)+$/, `unqualified ref in ${c.name}: ${c.formula}`);

// Readiness audit reports the fixed fields as exact.
const out = await mkdtemp(path.join(tmpdir(), "lookml-calc-refs-"));
const outs = { readiness: path.join(out, "r.json"), fields: path.join(out, "f.json"), formulas: path.join(out, "m.json") };
const proc = spawnSync(process.execPath, [path.join(skill, "scripts/audit-lookml-readiness.mjs"),
  "--lookml-dir", fixtureDir, "--out", outs.readiness, "--field-census", outs.fields,
  "--formula-mapping", outs.formulas], { encoding: "utf8" });
const formulas = JSON.parse(await readFile(outs.formulas, "utf8")).formulas;
for (const [view, field] of [["trip_legs", "distance_band"], ["trip_legs", "is_long_haul"], ["trip_legs", "haul_label"],
  ["leg_summary", "summary_band"], ["leg_summary", "fare_per_mile"]]) {
  const f = formulas.find(x => x.view === view && x.field === field);
  assert.equal(f?.mapping, "exact", `${field}: ${JSON.stringify(f)}\n${proc.stderr}`);
}
console.log("lookml-calc-refs: ok");
