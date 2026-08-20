#!/usr/bin/env node
// Local convenience wrapper around the Power BI -> Sigma converter (dev/manual
// use; the normal path is the powerbi-to-sigma skill / MCP tool).
// Usage: node run_converter.mjs <model.bim> <sigma-conn-id> <DB> <SCHEMA> <out.json>
//   Point at the converter with CONVERTER_PATH=<.../build/powerbi.js> or
//   PBI_MCP_DIR=<converter-source checkout>. Falls back to the vendored
//   powerbi-to-sigma bundle if present.
import fs from "fs";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

// Resolve the converter WITHOUT a hardcoded path (this used to be a dev-only
// /Users/... absolute that ran on exactly one machine). Order: CONVERTER_PATH,
// then $PBI_MCP_DIR/build/powerbi.js, then the sibling powerbi-to-sigma skill's
// vendored bundle. Import via a file:// URL — a bare Windows drive-letter path
// is not a valid ESM specifier (ERR_UNSUPPORTED_ESM_URL_SCHEME, protocol 'c:').
const HERE = dirname(fileURLToPath(import.meta.url));
const SIBLING = join(HERE, "..", "..", "powerbi-to-sigma", "scripts", "converter", "powerbi.mjs");
const MCP = process.env.PBI_MCP_DIR ? join(process.env.PBI_MCP_DIR, "build", "powerbi.js") : null;
const CONV = process.env.CONVERTER_PATH
  || (MCP && existsSync(MCP) ? MCP : null)
  || (existsSync(SIBLING) ? SIBLING : null);
if (!CONV) {
  console.error("no converter found: set CONVERTER_PATH (or PBI_MCP_DIR) to the "
    + "converter-source build/powerbi.js, or use the powerbi-to-sigma skill / MCP tool");
  process.exit(2);
}
const { convertPowerBIToSigma } = await import(pathToFileURL(CONV).href);
const bim = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out = convertPowerBIToSigma(bim, { connectionId: process.argv[3]||"", database: process.argv[4]||"", schema: process.argv[5]||"" });
fs.writeFileSync(process.argv[6], JSON.stringify(out, null, 2));
const m = out.model || out;
console.log("keys:", Object.keys(out).join(","));
console.log("warnings:", (out.warnings||[]).length);
const els = (m.elements||[]);
console.log("elements:", els.length);
for (const e of els.slice(0,8)) {
  console.log(` - ${e.elementType||e.type||"?"} name=${e.name} source=${JSON.stringify(e.source||e.sources||{}).slice(0,120)}`);
}
