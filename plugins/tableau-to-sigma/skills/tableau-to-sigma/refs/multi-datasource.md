<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Independent multi-datasource workbooks → multi-element DM. -->

# Independent multi-datasource workbooks → multi-element DM

**Disposition: detected + auto-built by the CURRENT vendored converter.**
`converter/tableau.mjs` (PROVENANCE `source_commit: cc3e81a`, 2026-07-08+)
natively emits a MULTI-ELEMENT data model for this shape — one element set
per independent datasource, nothing dropped (§2). The gap scan still flags
the shape ❌-unhandled so the orchestrator STOPS (exit 11) and a human/agent
confirms the converter output before POSTing. The **guided manual path (§3)
remains the fallback** for older vendored converters (pre-`cc3e81a`) and for
edge cases the native merge mishandles.

## 1. What this shape is (and is not)

An **independent multi-datasource workbook** has N real datasources
(`Parameters` excluded) where each datasource is the PRIMARY source of its
own worksheet(s) — different sheets, different sources, **no linking fields**.
Nothing joins them at query time; they merely share dashboards.

That is NOT a blend. A *blend* is one worksheet pulling fields from 2+
datasources at once, linked on shared captions via
`<datasource-dependencies>` secondary blocks — see `refs/blending.md` for
that decision tree.

It is also NOT a **single-datasource relationship ("noodle" / object-model)
workbook** — ONE datasource whose 2020.2+ logical graph joins N tables. That
shape reports `Datasources: 1` and routes through `refs/object-model.md`
(fact election + edge wiring + its own gap-scan stop); misreading it as
"multiple data sources" was the 2026-07 field mis-diagnosis. The two shapes
route differently:

| | Blend (`refs/blending.md`) | Independent multi-DS (this doc) |
|---|---|---|
| Worksheet's `<view>` | lists 2+ datasources | lists exactly 1 |
| Linking fields | yes (shared captions) | none |
| Secondary DS is primary anywhere? | no (secondary-only) | every DS is a primary |
| Sidecar | `blend-plan.json` | `multi-ds-plan.json` |
| Sigma shape | one DM, elements + relationship | one DM, N elements, usually **unrelated** |

### Detection (Phase 0a — automatic)

`scripts/scan-workbook-gaps.rb` triggers when ≥2 real datasources are each
the primary (first `<view>` datasource) of at least one worksheet and at
least one pair of those primaries is not blend-linked. One detection pass
emits three outputs: an ❌-`unhandled` gap row ("Multiple independent
datasources (converter collapses to primary)" — the name is a stable
scout-ledger key; the CURRENT converter no longer collapses, see §2) that
hard-stops `migrate-tableau.rb` at the gap gate (exit 11) with the
datasource→sheet breakdown; a `multi_datasource` detail block in the gaps
JSON; and a `multi-ds-plan.json` sidecar next to the gaps report — **the
sidecar shape is a contract**:

```json
{ "independent": true,
  "datasources": [
    { "name": "federated.sales01", "caption": "Sales Pipeline",
      "connection_class": "sqlproxy",
      "table": null,
      "sqlproxy": true,
      "worksheets": ["Pipeline by Stage", "Pipeline by Owner"],
      "dashboards": ["Executive Overview"] }, ...
  ] }
```

`table` is best-effort `db.schema.table` from the datasource's relation; it
is `null` for published sources (`sqlproxy: true`) — the resolve→hydrate
step fills those in later — and for Custom SQL relations.

## 2. The converter fact (current: multi-element; older: silent collapse)

**Current vendored converter (PROVENANCE `cc3e81a`, 2026-07-08+):**
`convertTableauToSigma` dispatches multi-datasource workbooks to
`buildMultiDatasourceModel`, which runs the single-DS conversion once per
datasource internally (`datasourceIndex: i` + a private `__multiDsChild`
flag) and merges the results into ONE model:

- **All data elements land on a single page** (`pages: [{ elements:
  [...controls, ...dataElements] }]`) — one element set per datasource,
  nothing dropped. `stats.elements` counts the merged data elements.
- **Element-name collisions across datasources are auto-renamed** with a
  `_<datasource-caption-slug>` suffix (fallback `_DSn`), and every
  `[OldName/...]` formula prefix inside the renamed element is rewritten to
  match — element names are formula prefixes, so verify chart refs against
  the FINAL names in the emitted model.
- **Controls and parameters are deduped by name** across datasources;
  `workbookPatterns` dedupe by kind+name; `security` entries concatenate.
- **NO cross-datasource relationships are inferred** (`stats.relationships:
  0`); the emitted warning says to add joins in Sigma if the sources share
  keys. Unrelated elements in one DM are fine.
- The model `name` is the FIRST datasource's name, and the first warning line
  announces the multi-element build with a per-datasource element count.
- **`datasourceIndex` semantics changed:** on a multi-DS workbook the
  top-level call ignores it (the multi-element path always wins); it only
  selects a single datasource for internal child calls. The genuine-blend
  path (`tryBuildBlendModel`) still takes precedence over the multi-element
  path.

**Older vendored converters (pre-`cc3e81a`)** convert ONE datasource per
invocation (`datasourceIndex`, default 0) and **silently drop every other
datasource's columns and calculated fields**. This is a live, observed
failure mode: a 4-datasource workbook (2 published, 2 direct) lost 19 calc
fields from datasources 2–4; the workbook spec still referenced them as
`[Master/...]` and the Sigma POST failed ~28 times with `Dependency not
found`. Nothing errors at convert time — the loss is silent until publish.
Two safety nets now catch a collapse that slips through: the DM column-
droppage WARN in `post-and-readback.rb` and the pre-POST ref gate
(`scripts/assert-wb-refs-resolve.rb`, waivable only via
`--skip-ref-check "<reason>"`).

**Never run an OLD single-DM converter on this shape with defaults.** Check
the emitted `stats.datasources` vs `stats.elements` (a multi-element build
reports all sources) — if the converter collapsed, follow the guided path
below or stop and tell the user: *"this workbook requires a multi-element DM
— here are the N tables and their worksheet assignments"* (read them out of
`multi-ds-plan.json`).

## 3. The guided path (fallback: agent-assembled multi-element DM)

Use this when the vendored converter predates the native multi-element build
(`PROVENANCE.json` `source_commit` older than `cc3e81a`) or when the native
merge mishandles an edge case (e.g. a rename/rewrite you need to control).

1. **Hydrate published sources first.** For every plan entry with
   `sqlproxy: true`, run `scripts/resolve-published-ds.rb` →
   `scripts/hydrate-custom-sql.rb` (`hydrate_pds!`) so the `.twb` carries real
   relations before any conversion. Abort if a sqlproxy DS stays unresolved —
   never let the converter fabricate a phantom table.
2. **Run the converter once per datasource index** `0..N-1` (N =
   `multi-ds-plan.json` `datasources` length; the converter's first run also
   reports `stats.datasources`). Write a small node shim modeled on the one in
   `mechanical-specs.rb`, adding `datasourceIndex: i`:

   ```js
   import { readFileSync, writeFileSync } from 'node:fs';
   import { convertTableauToSigma } from './converter/tableau.mjs';
   const i = Number(process.argv[2] || 0);
   const out = convertTableauToSigma(readFileSync('hydrated.twb', 'utf8'),
     { connectionId: '<CONN_ID>', database: '<DB>', schema: '<SCHEMA>',
       datasourceIndex: i });
   writeFileSync(`dm-raw-ds${i}.json`, JSON.stringify(out, null, 2));
   ```

   Match each run to its plan entry by the emitted model `name` (the
   datasource's caption), **not** by array position — the converter indexes
   datasources in `.twb` document order, which need not match the plan's
   order. Keep each run's `warnings`/`security`/`workbookPatterns` — they are
   per-datasource too. (On the CURRENT converter, `datasourceIndex` alone is
   ignored for multi-DS workbooks — add `__multiDsChild: true` to the options
   to force a single-datasource run; but on the current converter you rarely
   need this path at all, see §2.)
3. **Assemble ONE `dm-spec.json` with N elements**: take the element(s) from
   each per-index model and put them all under a single page
   (`pages: [{ elements: [...] }]`, schema in `refs/data-model-spec.md`).
   Add a `relationships` entry ONLY where a genuine join key exists between
   two sources — **unrelated elements in one DM are fine; Sigma allows them.**
   Do not invent a relationship just to make the DM look connected. Element
   ids are random per converter run; collisions across runs are unlikely but
   verify uniqueness (ids AND element names — the element `name` becomes the
   formula prefix) before POSTing.
4. **Route every chart to the element whose datasource owned its worksheet.**
   `multi-ds-plan.json`'s `worksheets` arrays are the routing table: a chart
   built from worksheet W sources the element converted from W's datasource.
   There is no single shared `[Master/...]` — each page's master (grouping)
   element, or each chart's direct DM `source`, must point at the right
   element, so formula prefixes differ per chart (`[Sales Pipeline/Amount]`
   vs `[Ops Inventory/On Hand Qty]`). The `dashboards` arrays tell you which
   elements a page will mix — a dashboard spanning two datasources simply has
   charts sourcing two different elements.
5. **Re-enter the gated spine** with the agent-authored specs:

   ```
   ruby scripts/migrate-tableau.rb ... --dm-spec <WORK>/dm-spec.json \
        --wb-spec <WORK>/wb-spec.json
   ```

   This routes through the normal gates (POST, parity, reports) instead of
   bypassing them.

## 4. Escalation (residual converter gaps only)

The durable fix — the converter natively emitting N elements from an
independent multi-DS workbook — **shipped** in the converter repos and is in
the current vendored `converter/tableau.mjs` (§2). Escalate only residual
gaps in the native merge (wrong rename/rewrite, dropped controls/parameters,
a shape it misclassifies): file via `scripts/escalate-gap.py` with
`--category converter` (routes to `sigma-data-model-manager` +
`converter-source`). Dry-run first — the script defaults to a draft and
files NOTHING without `--yes`; filing is always user-opt-in.
