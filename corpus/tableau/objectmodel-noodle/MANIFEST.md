# tableau / objectmodel-noodle

**Synthetic twins of the 2026-07-28 field-failure shape** (wave-2 object-model
batch), promoted from the empirical audit's fixture set. Invented names on a
neutral `ANALYTICS.PUBLIC` star (`FACT_VISITS` + `DIM_DATES` / `DIM_SITES` /
`DIM_PROVIDERS` / `ENTITLEMENTS`) — no customer identifiers, no live tenant.

## The shape (what makes these workbooks traps)

A **single** Tableau datasource that is a 2020.2+ *relationship ("noodle" /
object-model)* graph. Tableau serializes each `<object-graph>` edge onto its
`first-end-point` — the authoring-order BASE table, **not** semantically the
fact — so a converter that crowns the first relationship-carrying element in
document order elects a dimension, and every LOD/Top-N/window helper bakes its
SQL `FROM` off the wrong table (mass `Dependency not found` at POST).

- `workbook-fact-election.twb` — the ADVERSE orientation: 5 logical objects,
  `DIM_DATES` first in document order, **all 4 relationships serialized with
  the dim/entitlement as `first-end-point`**; two `{FIXED}` LODs (one date-dim
  grain, one sites-dim grain), a Top-3 set on sites by fact revenue, a bare
  measure, an `ENTITLEMENTS(SITE_KEY, USER_EMAIL)` table noodled into the fact
  behind a categorical datasource filter, and two parameters whose names
  collide after controlId normalization (`Top N Sites` / `Top_N_Sites`).
- `workbook-entitlement.twb` — the entitlement shape alone (4 objects, happy
  orientation): the documented Tableau entitlement-table pattern with **no
  user-function calc anywhere** — structural detection or nothing.
- `workbook-nokeys.twb` — 3 objects whose `<relationship>` entries carry
  endpoints but **no serialized key expression** (2020.2-era file): the
  refuse-don't-guess / disconnected-tables stop class.

## Artifacts

| File | What it is |
|---|---|
| `workbook-fact-election.twb` | Adverse-orientation noodle (5 objects, dims as first-end-points, LODs + Top-N + colliding params + entitlement) |
| `workbook-entitlement.twb` | Entitlement-table pattern, no user-function calc (structural RLS detection) |
| `workbook-nokeys.twb` | Relationships with endpoints but no serialized keys (disconnected-tables stop) |
| `golden/data-model.json` | Converter output for `workbook-fact-election.twb`, id-normalized, full envelope + `security[]` |
| `golden/data-model-entitlement.json` | Converter output for `workbook-entitlement.twb`, same envelope |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check` |

## What the goldens pin (wave-2 object-model batch)

- **Fact election is evidence-ranked, not document-order**: `FACT_VISITS`
  (degree 4, 3 measure columns) is elected although `DIM_DATES` is first in
  document order and carries the serialized edges; the election is ANNOUNCED
  (`ℹ Object-model fact election: elected "FACT_VISITS" …` warning).
- **Edge orientation**: all 4 Sigma relationships ride ON the fact element
  with dims as targets (key ids swapped with the orientation), matching
  Sigma's directional many-to-one/left-join semantics.
- **Helper ownership guards**: both cross-grain LODs and the dim-keyed Top-N
  set are REFUSED with actionable warnings instead of baked as wrong-FROM SQL
  + off-element relationship keys.
- **Single-DS controlId dedupe**: the two colliding parameters emit ONE
  control (`Top-N-Sites`) plus a warning naming the collision.
- **Structural entitlement-table RLS**: `security[]` carries
  `kind:"rls-entitlement-table"` (identity column, fact↔entitlement key
  pairs, Port strategies) in BOTH goldens — detected from the documented
  structural shape (related table + identity column + datasource-filter
  signal), with zero user-function calcs present; never auto-applied.
- **Unique-key contradiction warning**: the fixtures' perf-option hints mark
  the source side unique — the aggregated verify warning is pinned.

## Converter

`mcp__sigma-data-model__convert_tableau_to_sigma` with
`xml_content=<workbook.twb>`, `datasource_index=0` (artifacts are under the
hosted MCP body limit). The goldens are generated from the VENDORED bundle the
skill ships (the shipped truth, including its recorded local patches — see
`plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/PROVENANCE.json`),
with `security[]` kept in the envelope because the RLS detection is a pinned
behavior of this case:

```
node -e 'import("file://<repo>/plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/tableau.mjs").then(m => {
  const r = m.convertTableauToSigma(require("fs").readFileSync("workbook-fact-election.twb","utf8"), { datasourceIndex: 0 });
  console.log(JSON.stringify({ sigmaDataModel: r.model, stats: r.stats, warnings: r.warnings, security: r.security || [] }, null, 2));
})'
```

## Expected gate behaviors (encoded in checks.sh)

1. **Phase-0 detection** (`scan-workbook-gaps.rb`): the wired noodle is a
   ✅ Fully-auto row (a fully-wired graph must NOT stop — false-trip budget)
   telling the operator to VERIFY the announced election; the
   `object-graph-plan.json` sidecar names the degree-based fact candidate and
   the full wiring table.
2. **Disconnected-tables stop**: the no-keys workbook produces the
   ❌ Not-yet-handled row (the exit-11 checkpoint class, same rigor as
   multi-datasource) with the per-pair punch list and the patch-then-reenter
   route (`--reuse-dm`, never hand-POST).
3. **Golden byte-stability** (node runners): both workbooks reconvert
   byte-identically after id normalization.

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-fact-election.twb", "format": "xml"},
    {"path": "workbook-entitlement.twb", "format": "xml"},
    {"path": "workbook-nokeys.twb", "format": "xml"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "elements": 7,
      "columns": 38,
      "metrics": 1,
      "relationships": 4,
      "pages": 1,
      "element_kinds": {"control": 1, "table": 6},
      "metric_names": ["VISIT_REVENUE"],
      "relationship_names": ["DIM_DATES", "DIM_SITES", "DIM_PROVIDERS", "ENTITLEMENTS"],
      "warnings": 15
    },
    "data-model-entitlement.json": {
      "elements": 5,
      "columns": 33,
      "metrics": 0,
      "relationships": 3,
      "pages": 1,
      "element_kinds": {"table": 5},
      "relationship_names": ["DIM_DATES", "DIM_SITES", "ENTITLEMENTS"],
      "warnings": 6
    }
  }
}
```
