#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const skill = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const script = path.join(skill, "scripts/audit-lookml-readiness.mjs");
async function run(fixture) {
  const out = await mkdtemp(path.join(tmpdir(), "lookml-readiness-"));
  const files = { readiness: path.join(out, "readiness.json"), fields: path.join(out, "fields.json"), formulas: path.join(out, "formulas.json") };
  const proc = spawnSync(process.execPath, [script, "--lookml-dir", path.join(skill, "fixtures", fixture),
    "--out", files.readiness, "--field-census", files.fields, "--formula-mapping", files.formulas], { encoding: "utf8" });
  return { proc, readiness: JSON.parse(await readFile(files.readiness)), fields: JSON.parse(await readFile(files.fields)), formulas: JSON.parse(await readFile(files.formulas)) };
}

const orders = await run("skilltest-orders");
assert.equal(orders.proc.status, 0, orders.proc.stderr);
assert.equal(orders.readiness.inputs.explores[0], "order_fact");
assert.equal(orders.readiness.joins[0].keyParseStatus, "parsed");
assert.ok(orders.fields.fields.some(f => f.kind === "dimension_group" && f.timeframe === "month"));
const computed = orders.formulas.formulas.find(f => f.field === "average_order_value");
assert.ok(computed.warningIds.includes("LOOKML_COMPUTED_MEASURE"));
assert.ok(computed.warnings.some(w => w.id === "LOOKML_COMPUTED_MEASURE" && w.evidence.message));

const synthetic = await run("readiness-chain-extends");
assert.equal(synthetic.proc.status, 1, synthetic.proc.stderr);
assert.equal(synthetic.readiness.readiness, "blocked");
assert.equal(synthetic.readiness.explores[0].from, "chain_a");
assert.deepEqual(synthetic.readiness.joins[0].alias, "buyers");
assert.deepEqual(synthetic.readiness.joins[0].from, "customer");
assert.ok(synthetic.readiness.extends.cycles.length);
assert.ok(synthetic.fields.fields.some(f => f.field === "quadrupled" && f.dependencyDepth === 2));
assert.ok(synthetic.fields.fields.some(f => f.field === "broken" && f.unresolvedReferences.includes("does_not_exist")));
const multiHop = synthetic.formulas.formulas.find(f => f.field === "quadrupled");
assert.ok(multiHop.warningIds.includes("LOOKML_MEASURE_MULTI_HOP"));
assert.ok(multiHop.warnings.some(w => w.id === "LOOKML_MEASURE_MULTI_HOP" && w.evidence.dependencyDepth === 2));
const omitted = synthetic.formulas.formulas.find(f => f.field === "broken");
assert.equal(omitted.mapping, "omitted");
assert.ok(omitted.warningIds.includes("LOOKML_MEASURE_REFERENCE_UNRESOLVED"));
assert.ok(omitted.warnings.every(w => w.evidence));
const unmatched = synthetic.formulas.formulas.find(f => f.view === "cycle_a" && f.field === "a");
assert.equal(unmatched.mapping, "omitted");
assert.ok(unmatched.warningIds.includes("LOOKML_EMITTED_MATCH_OMITTED"));
assert.ok(unmatched.warnings.some(w => w.id === "LOOKML_EMITTED_MATCH_OMITTED" && w.evidence.field === "a"));
console.log("audit-lookml-readiness: ok");
