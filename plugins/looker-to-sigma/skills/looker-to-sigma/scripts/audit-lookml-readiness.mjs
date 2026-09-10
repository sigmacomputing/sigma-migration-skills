#!/usr/bin/env node
/**
 * Credentials-free LookML readiness audit.  This intentionally calls the
 * public API of the converter shipped beside this script; it does not carry a
 * second LookML parser or formula translator.
 */
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseLookML, convertLookMLToSigma } from "../converter/lookml.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CATALOG_PATH = path.join(HERE, "../refs/lookml-warning-catalog.json");
const rank = { clean: 0, caveat: 1, blocked: 2 };
const worst = (...xs) => xs.reduce((a, b) => rank[b] > rank[a] ? b : a, "clean");
const arr = v => v == null ? [] : Array.isArray(v) ? v : [v];
const norm = s => String(s || "").toLowerCase().replace(/[^a-z0-9]/g, "");
const display = s => String(s || "").replace(/([a-z])([A-Z])/g, "$1_$2")
  .split(/[_\s/-]+/).filter(Boolean).map(w => w[0].toUpperCase() + w.slice(1).toLowerCase()).join(" ");

function usage(message) {
  if (message) console.error(message);
  console.error("Usage: audit-lookml-readiness.mjs --lookml-dir DIR [--explore NAME ...] --out FILE --field-census FILE --formula-mapping FILE [--dashboard-contract FILE]");
  process.exit(2);
}

function argsOf(argv) {
  const out = { explore: [] };
  const values = new Set(["lookml-dir", "explore", "out", "field-census", "formula-mapping", "dashboard-contract"]);
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith("--")) usage(`Unknown argument: ${token}`);
    const [key, inline] = token.slice(2).split(/=(.*)/s, 2);
    if (!values.has(key)) usage(`Unknown option: --${key}`);
    const value = inline ?? argv[++i];
    if (!value || value.startsWith("--")) usage(`Missing value for --${key}`);
    if (key === "explore") out.explore.push(...value.split(",").filter(Boolean));
    else out[key] = value;
  }
  for (const k of ["lookml-dir", "out", "field-census", "formula-mapping"]) if (!out[k]) usage(`Missing --${k}`);
  out.explore = [...new Set(out.explore)].sort();
  return out;
}

async function walk(root, dir = root) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const found = [];
  for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) found.push(...await walk(root, full));
    else if (e.isFile() && (e.name.endsWith(".model.lkml") || e.name.endsWith(".view.lkml")))
      found.push({ name: path.relative(root, full).split(path.sep).join("/"), content: await fs.readFile(full, "utf8") });
  }
  return found;
}

function refs(sql) {
  return [...String(sql || "").matchAll(/\$\{([^}]+)\}/g)].map(m => m[1])
    .filter(x => x !== "TABLE" && !x.endsWith(".SQL_TABLE_NAME"));
}

function expandFields(view) {
  const fields = [];
  for (const d of arr(view.dimension)) fields.push({ view: view._name, name: d._name, kind: "dimension", type: d.type || "string", sql: d.sql || "", source: d });
  for (const g of arr(view.dimension_group)) {
    const frames = arr(g.timeframes).length ? arr(g.timeframes) : ["raw", "date", "week", "month", "quarter", "year"];
    for (const frame of frames) fields.push({ view: view._name, name: frame === "raw" ? `${g._name}_raw` : `${g._name}_${frame}`, sourceName: g._name, timeframe: frame, kind: "dimension_group", type: g.type || "time", sql: g.sql || "", source: g });
  }
  for (const m of arr(view.measure)) fields.push({ view: view._name, name: m._name, kind: "measure", type: m.type || "number", sql: m.sql || "", source: m });
  return fields;
}

function dependencyInfo(fields) {
  const byKey = new Map(fields.map(f => [`${f.view}.${f.name}`, f]));
  const measures = fields.filter(f => f.kind === "measure");
  const result = new Map();
  function visit(field, stack = []) {
    const key = `${field.view}.${field.name}`;
    if (stack.includes(key)) return { depth: stack.length, unresolved: [], cycle: [...stack.slice(stack.indexOf(key)), key] };
    let depth = 0, unresolved = [], cycle = [];
    for (const ref of refs(field.sql)) {
      const qualified = ref.includes(".") ? ref : `${field.view}.${ref}`;
      const dep = byKey.get(qualified);
      if (!dep) { unresolved.push(ref); continue; }
      if (dep.kind === "measure") {
        const sub = visit(dep, [...stack, key]);
        depth = Math.max(depth, 1 + sub.depth);
        unresolved.push(...sub.unresolved);
        cycle.push(...sub.cycle);
      }
    }
    return { depth, unresolved: [...new Set(unresolved)].sort(), cycle: [...new Set(cycle)] };
  }
  for (const m of measures) result.set(`${m.view}.${m.name}`, visit(m));
  return result;
}

function emitted(result) {
  const names = new Set(), formulas = new Map(), byView = new Map();
  for (const page of result.model?.pages || []) for (const el of page.elements || []) {
    const viewKey = norm(String(el.name || "").replace(/ View$/, ""));
    if (!byView.has(viewKey)) byView.set(viewKey, new Set());
    for (const item of [...(el.columns || []), ...(el.metrics || [])]) {
      const name = item.name || String(item.formula || "").match(/\/([^/\]]+)\]$/)?.[1];
      if (name) {
        names.add(norm(name));
        byView.get(viewKey).add(norm(name));
        formulas.set(`${viewKey}:${norm(name)}`, item.formula || "");
      }
    }
  }
  return { names, formulas, byView };
}

function classifyWarning(text, catalog) {
  const item = catalog.warnings.find(w => new RegExp(w.pattern, "i").test(text));
  if (item) return { id: item.id, readiness: item.readiness, source: "converter", message: text, evidence: { message: text } };
  const severity = /not run|placeholder|skipped|could not|unresolved|unsupported|manually/i.test(text) ? "blocked" : "caveat";
  return { id: "LOOKML_UNCLASSIFIED_CONVERTER_WARNING", readiness: severity, source: "converter",
    message: text, evidence: { message: text }, unclassified: true };
}

function structuralWarning(id, evidence, catalog) {
  const item = catalog.warnings.find(w => w.id === id);
  if (!item) throw new Error(`Warning ID ${id} is missing from ${path.basename(CATALOG_PATH)}`);
  return { id, readiness: item.readiness, source: "structural", evidence };
}

function stableWarnings(warnings) {
  const seen = new Set();
  return warnings.filter(w => {
    const key = JSON.stringify(w);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).sort((a, b) => `${a.id}:${JSON.stringify(a.evidence)}`.localeCompare(`${b.id}:${JSON.stringify(b.evidence)}`));
}

function cycleComponents(graph) {
  const cycles = [], state = new Map(), stack = [];
  function dfs(n) {
    if (state.get(n) === 1) {
      const cycle = [...stack.slice(stack.indexOf(n)), n];
      cycles.push(cycle);
      return;
    }
    if (state.get(n) === 2) return;
    state.set(n, 1); stack.push(n);
    for (const p of graph.get(n) || []) if (graph.has(p)) dfs(p);
    stack.pop(); state.set(n, 2);
  }
  for (const n of [...graph.keys()].sort()) dfs(n);
  return cycles.sort((a, b) => a.join().localeCompare(b.join()));
}

async function writeJson(filename, value) {
  await fs.mkdir(path.dirname(path.resolve(filename)), { recursive: true });
  await fs.writeFile(filename, JSON.stringify(value, null, 2) + "\n");
}

async function main() {
  const opt = argsOf(process.argv.slice(2));
  const root = path.resolve(opt["lookml-dir"]);
  const files = await walk(root);
  if (!files.length) throw new Error("No .model.lkml or .view.lkml files found");
  const catalog = JSON.parse(await fs.readFile(CATALOG_PATH, "utf8"));
  const parsedFiles = files.map(file => ({ file: file.name, parsed: parseLookML(file.content) }));
  const views = new Map(), explores = new Map();
  for (const { file, parsed } of parsedFiles) {
    for (const v of parsed.views) views.set(v._name, { ...v, _file: file });
    if (file.endsWith(".model.lkml")) for (const e of parsed.explores) explores.set(e._name, { ...e, _file: file });
  }
  const targets = opt.explore.length ? opt.explore :
    (explores.size ? [...explores.keys()].sort() : [...views.keys()].sort());

  const conversion = [], allEmitted = new Set(), emittedFormula = new Map(), emittedByView = new Map(), warningRows = [];
  for (const name of targets) {
    const result = convertLookMLToSigma(files, { exploreName: name, connectionId: "READINESS_AUDIT" });
    const e = emitted(result);
    for (const n of e.names) allEmitted.add(n);
    for (const [n, f] of e.formulas) emittedFormula.set(n, f);
    for (const [v, names] of e.byView) {
      if (!emittedByView.has(v)) emittedByView.set(v, new Set());
      for (const n of names) emittedByView.get(v).add(n);
    }
    const warnings = (result.warnings || []).map(w => {
      const warning = classifyWarning(w, catalog);
      return { explore: name, ...warning, evidence: { explore: name, ...warning.evidence } };
    });
    warningRows.push(...warnings);
    conversion.push({ explore: name, stats: result.stats || {}, readiness: worst(...warnings.map(w => w.readiness)), warnings });
  }

  const sourceFields = [...views.values()].flatMap(expandFields);
  const deps = dependencyInfo(sourceFields);
  const warningByField = new Map();
  for (const warning of warningRows) {
    const field = warning.message.match(/^[^"]*"([^"]+)"/)?.[1];
    if (field) {
      const key = norm(field);
      if (!warningByField.has(key)) warningByField.set(key, []);
      warningByField.get(key).push(warning);
    }
  }
  const fieldRows = sourceFields.map(f => {
    const viewOutput = emittedByView.get(norm(display(f.view)));
    const hit = Boolean(viewOutput?.has(norm(display(f.name))) || viewOutput?.has(norm(f.name)));
    const dep = deps.get(`${f.view}.${f.name}`);
    let mapping = hit ? "exact" : "omitted";
    const reasons = [];
    const warnings = [...(warningByField.get(norm(f.name)) || [])];
    if (dep?.depth > 1 && hit) { mapping = "approximate"; reasons.push("multi-hop-measure-chain"); }
    if (dep?.unresolved.length) { mapping = hit ? "approximate" : "omitted"; reasons.push("unresolved-reference"); }
    if (dep?.cycle.length) { mapping = "omitted"; reasons.push("measure-cycle"); }
    if (dep?.depth > 1) warnings.push(structuralWarning("LOOKML_MEASURE_MULTI_HOP",
      { view: f.view, field: f.name, dependencyDepth: dep.depth }, catalog));
    if (dep?.unresolved.length) warnings.push(structuralWarning("LOOKML_MEASURE_REFERENCE_UNRESOLVED",
      { view: f.view, field: f.name, unresolvedReferences: dep.unresolved }, catalog));
    if (dep?.cycle.length) warnings.push(structuralWarning("LOOKML_MEASURE_DEPENDENCY_CYCLE",
      { view: f.view, field: f.name, cycle: dep.cycle }, catalog));
    if (!hit) warnings.push(structuralWarning("LOOKML_EMITTED_MATCH_OMITTED",
      { view: f.view, field: f.name }, catalog));
    const rowWarnings = stableWarnings(warnings);
    const warningReadiness = worst(...rowWarnings.map(w => w.readiness));
    if (warningReadiness === "blocked") { mapping = "omitted"; reasons.push("converter-warning"); }
    else if (warningReadiness === "caveat" && mapping === "exact") { mapping = "approximate"; reasons.push("converter-warning"); }
    return {
      view: f.view, field: f.name, ...(f.sourceName ? { sourceField: f.sourceName } : {}),
      kind: f.kind, type: f.type, mapping, reasons: [...new Set(reasons)].sort(),
      warningIds: [...new Set(rowWarnings.map(w => w.id))].sort(), warnings: rowWarnings,
      ...(f.timeframe ? { timeframe: f.timeframe } : {}),
      ...(dep ? { dependencyDepth: dep.depth, dependencies: refs(f.sql).sort(), unresolvedReferences: dep.unresolved, dependencyCycle: dep.cycle } : {})
    };
  }).sort((a, b) => `${a.view}.${a.field}`.localeCompare(`${b.view}.${b.field}`));

  const extendsGraph = new Map();
  for (const [name, v] of views) extendsGraph.set(name, arr(v.extends).map(String).sort());
  const extendsCycles = cycleComponents(extendsGraph);
  const missingParents = [...extendsGraph].flatMap(([child, parents]) => parents.filter(p => !views.has(p)).map(parent => ({ child, parent })))
    .sort((a, b) => `${a.child}.${a.parent}`.localeCompare(`${b.child}.${b.parent}`));
  const unmerged = [];
  for (const [child, parents] of extendsGraph) for (const parent of parents) {
    if (!views.has(parent)) continue;
    const childNames = new Set(expandFields(views.get(child)).map(f => f.name));
    const omitted = expandFields(views.get(parent)).map(f => f.name).filter(n => !childNames.has(n));
    if (omitted.length) unmerged.push({ child, parent, omittedFields: omitted.sort() });
  }

  const joinRows = [...explores.values()].flatMap(ex => arr(ex.join).map(j => {
    const alias = j._name, from = j.from || alias, sql = j.sql_on || "";
    const equality = [...sql.matchAll(/\$\{([^}]+)\}\s*=\s*\$\{([^}]+)\}/g)].map(m => ({ left: m[1], right: m[2] }));
    return { explore: ex._name, alias, from, relationship: j.relationship || null, type: j.type || null,
      keyParseStatus: equality.length && sql.replace(/\$\{[^}]+\}\s*=\s*\$\{[^}]+\}/g, "").trim() === "" ? "parsed" : "manual",
      keys: equality };
  })).sort((a, b) => `${a.explore}.${a.alias}`.localeCompare(`${b.explore}.${b.alias}`));

  const derivedTables = [...views.values()].filter(v => v.derived_table).map(v => ({
    view: v._name, kind: v.derived_table.explore_source ? "native" : "sql",
    sqlTableNameReferences: [...String(v.derived_table.sql || "").matchAll(/\$\{([^}]+\.SQL_TABLE_NAME)\}/g)].map(m => m[1]).sort(),
    persistent: Boolean(v.derived_table.persist_for || v.derived_table.persist_with || v.derived_table.datagroup_trigger || v.derived_table.sql_trigger_value)
  })).sort((a, b) => a.view.localeCompare(b.view));

  let dashboard = null;
  if (opt["dashboard-contract"]) {
    const contract = JSON.parse(await fs.readFile(opt["dashboard-contract"], "utf8"));
    const tiles = contract.tiles || contract.dashboard?.tiles || contract.elements || [];
    dashboard = { file: path.basename(opt["dashboard-contract"]), tileCount: Array.isArray(tiles) ? tiles.length : 0,
      tiles: Array.isArray(tiles) ? tiles.map((t, i) => ({ id: String(t.id ?? t.name ?? i), explore: t.explore ?? t.query?.explore ?? null })).sort((a, b) => a.id.localeCompare(b.id)) : [] };
  }

  const formulaRows = sourceFields.filter(f => f.sql || f.kind === "measure").map(f => {
    const census = fieldRows.find(x => x.view === f.view && x.field === f.name);
    return { view: f.view, field: f.name, kind: f.kind, sourceFormula: f.sql || null,
      sigmaFormula: emittedFormula.get(`${norm(display(f.view))}:${norm(display(f.name))}`) ??
        emittedFormula.get(`${norm(display(f.view))}:${norm(f.name)}`) ?? null, mapping: census.mapping,
      dependencies: refs(f.sql).sort(), dependencyDepth: census.dependencyDepth ?? 0,
      unresolvedReferences: census.unresolvedReferences || [],
      warningIds: census.warningIds, warnings: census.warnings };
  }).sort((a, b) => `${a.view}.${a.field}`.localeCompare(`${b.view}.${b.field}`));

  const structuralWarnings = stableWarnings([
    ...extendsCycles.map(cycle => structuralWarning("LOOKML_EXTENDS_CYCLE", { cycle }, catalog)),
    ...missingParents.map(x => structuralWarning("LOOKML_EXTENDS_PARENT_MISSING", x, catalog)),
    ...unmerged.map(x => structuralWarning("LOOKML_EXTENDS_UNMERGED_FIELDS", x, catalog)),
    ...fieldRows.flatMap(f => f.warnings.filter(w => w.source === "structural"))
  ]);
  const omitted = fieldRows.filter(f => f.mapping === "omitted").length;
  const status = worst(...warningRows.map(w => w.readiness), ...structuralWarnings.map(w => w.readiness), omitted ? "blocked" : "clean");
  const readiness = {
    schemaVersion: 1, readiness: status,
    inputs: { lookmlFiles: files.map(f => f.name), explores: targets, dashboardContract: dashboard?.file || null },
    summary: { views: views.size, fields: fieldRows.length, explores: explores.size, joins: joinRows.length,
      derivedTables: derivedTables.length, exact: fieldRows.filter(f => f.mapping === "exact").length,
      approximate: fieldRows.filter(f => f.mapping === "approximate").length, omitted },
    views: [...views.values()].map(v => ({ name: v._name, file: v._file, extends: arr(v.extends).map(String).sort(),
      derivedTable: Boolean(v.derived_table), filters: arr(v.filter).map(x => x._name).sort(),
      accessFilters: arr(v.access_filter).map(x => x._name || x.field || "").filter(Boolean).sort() })).sort((a, b) => a.name.localeCompare(b.name)),
    explores: [...explores.values()].map(e => ({ name: e._name, file: e._file, from: e.from || e._name,
      filters: arr(e.always_filter).concat(arr(e.conditionally_filter)), accessFilters: arr(e.access_filter) })).sort((a, b) => a.name.localeCompare(b.name)),
    joins: joinRows, derivedTables, extends: { cycles: extendsCycles, missingParents, unmerged }, conversions: conversion,
    warnings: [...warningRows, ...structuralWarnings], dashboard
  };
  await Promise.all([
    writeJson(opt.out, readiness),
    writeJson(opt["field-census"], { schemaVersion: 1, fields: fieldRows }),
    writeJson(opt["formula-mapping"], { schemaVersion: 1, formulas: formulaRows })
  ]);
  process.exitCode = status === "blocked" ? 1 : 0;
}

main().catch(error => {
  console.error(`LookML readiness audit failed: ${error.message}`);
  process.exitCode = 2;
});
