<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 1.5 — reuse an existing DM (+ shape preflight) -->

## Phase 1.5 — Check for an existing DM the workbook can reuse (DO THIS FIRST)

Before running Phase 2 (warehouse column discovery) and Phase 3 (DM build), check whether the customer's Sigma org **already has a data model** that satisfies the workbook's needs. Reusing an existing DM:

- Avoids DM sprawl (customers complain when they end up with a 4th "Orders" DM)
- Cuts Phase 2 + Phase 3 entirely on the reuse path — typically the heaviest 2–3 minutes of a conversion

```bash
# Inputs:
#   workbook-signature.json — derived from Phase 1 .twb parse + view CSV headers
#     { tableau_workbook, warehouse_tables: [FQNs], referenced_columns: [...], measures: [...] }
ruby scripts/find-or-pick-dm.rb \
  --workbook-signature <WORK>/workbook-signature.json \
  --out <WORK>/dm-match.json \
  --limit 100 \
  [--min-score 0.6]   # default; below: build new
  [--force-new]        # bypass scan entirely
```

The picker parallel-fetches DM specs (10 concurrent threads — ~2s for 50 DMs vs ~15s serial). Scoring weights: column overlap 0.7, source-table FQN 0.2, metric overlap 0.1. Output thresholds:

| Score | Action |
|---|---|
| ≥ 0.85 | auto-reuse the recommended DM, skip Phase 2 + 3 |
| 0.6 – 0.85 | ambiguous — **ask the user** before reusing; surface the candidates from `dm-match.json` |
| < 0.6 | no usable match; proceed to Phase 2 + 3 |

Surface this in your conversation with the user:

> "Found existing DM `<name>` covering N/M of the columns this workbook references. Reuse this DM? It would skip ~2–3 min of conversion time but the workbook will inherit X extra columns (sample: ...). Reply `yes` to reuse, `no` to build new, or `show` to see other candidates."

When reusing, jump straight from Phase 1.5 to Phase 5 — the workbook spec's table elements set `source: { kind: data-model, dataModelId: <recommended_dm_id>, elementId: <chosen-element-id> }` and use formula prefixes derived from the existing DM's element name (e.g. `[Plugs Sales/Revenue]`).

The picker is **non-destructive** — it never modifies any DM. The downstream phase decides reuse vs build.

### Phase 1.5b — DM-shape preflight (MANDATORY when reusing)

> **Before writing the workbook spec, inspect the reused DM's element graph.** Skipping this is the single biggest source of conversion-time waste — a workbook POST that fails with `Cannot resolve columns on table master: dependency not found: formula reference customer_dim/region` forces 2–3 minutes of spec-rework.

Run:
```bash
ruby scripts/inspect-dm-shape.rb \
  --dm-id <recommended_dm_id> \
  --out <WORK>/dm-denorm-plan.json
```

The plan classifies every column on the DM as either:
- **`location: "fact"`** — already on the fact element, reference directly as `[Master/<col>]`
- **`location: "dim"`** — lives on a separate dim element, must use `Lookup([<DimElement>/<col>], [Master/<FK>], [<DimElement>/<PK>])`

For each dim column in `dm-denorm-plan.json`, the script provides the exact Lookup formula. When writing the workbook master table:
1. The primary master table sources from the fact element (use the `fact_element.id` from the plan).
2. For each dim element referenced by the workbook's worksheets, add a **hidden master table** sourcing that dim element (`visibleAsSource: false`).
3. Master-column formulas use the plan's `column_resolution["<col>"].formula` verbatim.

The plan also surfaces `unmatched_dim_elements` — dim elements with no detectable FK on the fact (often calendar tables). If a worksheet references columns from one of these, you'll need to manually identify the join key.

Measured 2026-05-22 against the same Tableau workbook in two consecutive conversions: the run that skipped this preflight rewound 130s (21.5% of total) on the failed-POST rework path. The plan computes in ~1s and eliminates that overhead.

---

