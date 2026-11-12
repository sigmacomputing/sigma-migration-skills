#!/usr/bin/env node
// Offline: readiness audit matches converter-emitted names (labels, physical
// ${TABLE} columns, join-alias `from:`) and the narrow --accept-omitted waiver.
import assert from "node:assert/strict";
import { cp, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const skill = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(skill, "scripts/audit-lookml-readiness.mjs");
const fixture = path.join(skill, "fixtures/readiness-logistics");

async function audit(dir, extra = []) {
  const out = await mkdtemp(path.join(tmpdir(), "lookml-readiness-names-"));
  const f = { readiness: path.join(out, "r.json"), fields: path.join(out, "f.json"), formulas: path.join(out, "m.json") };
  const proc = spawnSync(process.execPath, [script, "--lookml-dir", dir, "--out", f.readiness,
    "--field-census", f.fields, "--formula-mapping", f.formulas, ...extra], { encoding: "utf8" });
  const read = async p => { try { return JSON.parse(await readFile(p)); } catch { return null; } };
  return { proc, readiness: await read(f.readiness), fields: (await read(f.fields))?.fields, formulas: (await read(f.formulas))?.formulas };
}
const row = (r, v, n) => r.fields.find(x => x.view === v && x.field === n);

// (1) labeled measures, physical-column dims, join alias via from: -> all exact, exit 0
const clean = await audit(fixture);
assert.equal(clean.proc.status, 0, clean.proc.stderr + JSON.stringify(clean.readiness?.warnings));
for (const [v, n] of [["shipments", "n"], ["shipments", "total_weight"], ["shipments", "weight_kg"],
  ["shipments", "destination_city"], ["depots", "depot_name"], ["carriers", "carrier_count"]])
  assert.equal(row(clean, v, n).mapping, "exact", `${v}.${n}`);
assert.equal(clean.readiness.summary.omitted, 0);
assert.equal(clean.readiness.acceptedOmissions, undefined);
// formula-mapping picks the formula through the same candidates
assert.equal(clean.formulas.find(x => x.field === "n").sigmaFormula, "Count()");
assert.match(clean.formulas.find(x => x.field === "weight_kg").sigmaFormula, /\/Wt\]$/);
assert.match(clean.formulas.find(x => x.field === "destination_city").sigmaFormula, /\/City Nm\]$/);

// A single-timeframe dimension group emits only its physical warehouse column.
const singleFrame = await mkdtemp(path.join(tmpdir(), "lookml-readiness-single-frame-"));
await cp(fixture, singleFrame, { recursive: true });
const shipments = path.join(singleFrame, "views/shipments.view.lkml");
await writeFile(shipments, (await readFile(shipments, "utf8"))
  .replace("timeframes: [raw, date, month]", "timeframes: [date]"));
const singleFrameAudit = await audit(singleFrame);
assert.equal(singleFrameAudit.proc.status, 0, singleFrameAudit.proc.stderr);
assert.equal(row(singleFrameAudit, "shipments", "shipped_date").mapping, "exact");

// (2) a field the converter genuinely skips (a parameter ref with no default)
// stays omitted and blocks. (A ${dimension} comparison is a field ref, not a
// parameter: it converts — see test-lookml-calc-refs.mjs.)
const tmp = await mkdtemp(path.join(tmpdir(), "lookml-readiness-fx-"));
await cp(fixture, tmp, { recursive: true });
await writeFile(path.join(tmp, "views/shipments.view.lkml"),
  (await readFile(path.join(fixture, "views/shipments.view.lkml"), "utf8")).replace(/\}\s*$/,
    `  parameter: weight_unit {\n    type: unquoted\n  }\n  dimension: is_heavy {\n    type: string\n    sql: \${weight_unit} ;;\n  }\n}\n`));
const skipped = await audit(tmp);
assert.equal(skipped.proc.status, 1);
assert.equal(row(skipped, "shipments", "is_heavy").mapping, "omitted");
// ...and the waiver cannot clear a converter-blocked warning
const stillBlocked = await audit(tmp, ["--accept-omitted", "shipments.is_heavy", "--accept-omitted-reason", "test"]);
assert.equal(stillBlocked.proc.status, 1);
assert.equal(row(stillBlocked, "shipments", "is_heavy").mapping, "omitted");

// (3) waiver: an orphan view the converter never emits (only blocker = EMITTED_MATCH_OMITTED)
const orphan = await mkdtemp(path.join(tmpdir(), "lookml-readiness-orphan-"));
await cp(fixture, orphan, { recursive: true });
await writeFile(path.join(orphan, "views/fuel_stops.view.lkml"),
  `view: fuel_stops {\n  sql_table_name: LOGISTICS.PUBLIC.FUEL_STOPS ;;\n  dimension: stop_id {\n    type: number\n    sql: \${TABLE}.stop_id ;;\n  }\n  measure: stop_count {\n    type: count\n  }\n}\n`);
const blocked = await audit(orphan);
assert.equal(blocked.proc.status, 1);
assert.equal(row(blocked, "fuel_stops", "stop_count").mapping, "omitted");
const W = ["--accept-omitted", "fuel_stops.stop_id,fuel_stops.stop_count", "--accept-omitted-reason", "orphan view is out of scope"];
const waived = await audit(orphan, W);
assert.equal(waived.proc.status, 0, waived.proc.stderr);
assert.equal(waived.readiness.readiness, "caveat", "a waived omission must never read as clean");
const w = row(waived, "fuel_stops", "stop_count");
assert.equal(w.mapping, "approximate");
assert.ok(w.reasons.includes("accepted-omission"));
assert.equal(w.acceptedOmission.reason, "orphan view is out of scope");
assert.ok(!w.warningIds.includes("LOOKML_EMITTED_MATCH_OMITTED"));
assert.deepEqual(waived.readiness.acceptedOmissions,
  { reason: "orphan view is out of scope", fields: ["fuel_stops.stop_count", "fuel_stops.stop_id"] });
// partially listed -> the unlisted orphan field still blocks
const partial = await audit(orphan, ["--accept-omitted", "fuel_stops.stop_id", "--accept-omitted-reason", "x"]);
assert.equal(partial.proc.status, 1);

// unknown field -> exit 2; accepted-but-not-omitted -> exit 2; reason required both ways
const unknown = await audit(orphan, ["--accept-omitted", "fuel_stops.nope", "--accept-omitted-reason", "x"]);
assert.equal(unknown.proc.status, 2); assert.match(unknown.proc.stderr, /unknown field/);
const notOmitted = await audit(orphan, ["--accept-omitted", "shipments.n", "--accept-omitted-reason", "x"]);
assert.equal(notOmitted.proc.status, 2); assert.match(notOmitted.proc.stderr, /not actually omitted/);
const noReason = await audit(orphan, ["--accept-omitted", "fuel_stops.stop_id"]);
assert.equal(noReason.proc.status, 2); assert.match(noReason.proc.stderr, /accept-omitted-reason/);
const noFields = await audit(orphan, ["--accept-omitted-reason", "x"]);
assert.equal(noFields.proc.status, 2);
console.log("audit-lookml-readiness-names: ok");
