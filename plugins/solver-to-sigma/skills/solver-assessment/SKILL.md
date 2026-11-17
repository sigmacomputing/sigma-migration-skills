---
name: solver-assessment
description: Inventory a Solver (Solver Global / BI360) report estate from its Live Reporting downloads and produce a migration-readiness readout — per-report complexity, an automatable / iterate / complex bucket, near-duplicate report families, the data each report reads, and the questions to ask. Read-only and creds-free.
---

# Solver migration assessment (read-only)

> **Maturity: scaffold.** Runs offline over files; never connects to Solver, never writes to it, never posts to
> Sigma. Hand off to `solver-to-sigma` for the reports you pick.

Solver has no public API for report definitions, so the estate is assessed from files: each report's **Live
Reporting Download** (`.xlsx`), which embeds the full definition. Ask the customer's Solver administrator (or
each report owner) to download every report in scope into one folder. Executed-run exports are not needed here.

**Never open a `*.manifest` file.** It holds the sender's Solver session token. The scan lists such files as
refused without reading them; ask the sender to delete them and send the Download instead.

## Phase 0 — Collect
One folder of downloads, named as the business knows them. Note for each: owner, audience, how often it runs,
and whether it is still used. That is the **value** side of the shortlist, and it is not in the files.

## Phase 1 — Inventory
```bash
python3 scripts/assess-solver.py --in <downloads-folder> --out <out-dir>
```
Reuses the converter's parser and compiler from `../solver-to-sigma/scripts`, so what it counts is exactly what
the converter would translate. Per report: sheets, lines, expanded rows, expanding columns, parameters (hidden,
bursting via `Loop`, period), facts and dimension fields read, period functions, untranslated cells, a score
and a bucket:

- **automatable**: every value cell translates; one fact table; no expanded rows.
- **iterate**: a few untranslated cells or expanded rows for a person to check.
- **complex**: several fact tables, expanding columns, bursting, a sheet that cannot be compiled, or more than
  10% untranslated cells.

Untranslated cells include every cell an unsupported filter touches, value cells that read a text cell, date
filters and expanded rows that cannot be compiled; a sheet that fails outright counts all its formula cells.

## Phase 1.5 — Near-duplicates
Solver estates grow by copying a report and changing one filter. Find the families and migrate each once:
```bash
python3 scripts/dup-dashboards.py --in <out-dir>/dashboards.json --out <out-dir>/dup-groups.json --md
```

## Phase 2 — Score, shortlist, readout
`<out-dir>/readout.md` holds the bucket counts, the shortlist (lowest effort first), the fact tables and fields
the estate reads, and the questions to ask. Combine it with the value notes from Phase 0: start with reports
that are high-value and automatable, then the high-value complex ones (they set the patterns), and retire what
nobody uses.

Always raise these with the customer:
- Which reports are still used, by whom, how often?
- For each fact table: where does the same data live in the warehouse, which copy is the source of truth, and
  is it loaded daily? (A replicated Solver feed that stopped loading is a common trap.)
- One executed run per selected report, for a recent closed period, with its parameter values: the parity
  oracle.
- Solver's dimension security rules (not in the downloads).
- Which near-duplicate families should become one Sigma workbook with a control instead of N reports?
- Is Solver also the budgeting tool, or the only home of some master data or manual loads? Those switch off with
  it (`../solver-to-sigma/refs/field-notes.md`).
- Does any report produce an import file for the ERP? Plan it as a workflow app, not a report.

## Privacy
Downloads carry the customer's chart of accounts, entity and scenario codes, and labels, but no amounts.
Keep them and the readout in the customer's approved locations. Executed runs carry amounts.
