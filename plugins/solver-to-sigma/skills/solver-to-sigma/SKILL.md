---
name: solver-to-sigma
description: Rebuild a Solver (Solver Global, formerly BI360) report in Sigma from its Live Reporting download — definition extraction, compilation of its filters, period functions and Excel formulas into a Sigma data model and workbook, POST/readback gates, and parity against an executed run.
---

# Solver → Sigma

> **Maturity: scaffold.** The extractor, compiler, data-model and workbook builders, local evaluator and parity
> check are tested offline on synthetic fixtures and were run end to end against a Sigma org on synthetic
> warehouse data (independent SQL anchors matched to the cent). The method itself was proven on real financial
> statements during a field migration. Expect gaps on report shapes the fixtures do not cover; they surface as
> warnings, never as guesses.

A Solver report is an Excel layout designed in Solver's report designer and run against Solver's own data
warehouse: fact tables such as `GL_F_Trans` (`Value1` = amount), dimensions `d_Account`, `d_Scenario`, `Period`
and configurable `d_dim0…d_dimN`, each with user-defined fields `UDF001…`. There is no public API for report
definitions and no MCP converter. What every report does have is its **Live Reporting Download**: an `.xlsx`
that embeds the full definition as a custom XML part. This skill reads that, compiles it, and rebuilds it on the
warehouse tables that hold the same data.

<!-- mandatory-pre-read -->
Read before Phase 1: `refs/solver-definition-format.md` (what the definition holds and how it is evaluated) and
`refs/source-map.md` (where Solver's facts and fields live in the warehouse). Read `refs/parity.md` before Phase 6.
<!-- /mandatory-pre-read -->

## Inputs, and one hard safety rule

- The report's **Live Reporting Download** (`.xlsx`): the definition plus the sheet layout. It has no values.
- An **executed run** of the same report for a recent closed period (all sheets), **and the parameter values it
  was run with** (a screenshot of the parameter panel is fine). This is the parity oracle.
- Read access to the warehouse tables that hold Solver's facts and dimensions (see `refs/source-map.md`).
- **Never open a `*.manifest` file.** Solver hands one to its desktop designer; it holds the sender's session
  `AuthenticationToken` (edit rights), not metadata. The scripts refuse it by name. Ask the sender to delete it
  and to send the Download instead.

Run every command from this skill's directory. Python 3 stdlib only, plus Ruby for the shared data-model matcher
in Phase 1.5; no installs.

## Phase 0 — Assess (C1)
Use the sibling **`solver-assessment`** skill to inventory a folder of downloads, bucket each report
(automatable / iterate / complex), find near-duplicate report families (migrate once, not N times) and produce
the list of questions to ask. Pick one report to start. When scoping, read `refs/field-notes.md`: what else switches
off with Solver (budget entry, hand-kept master data, manual loads), report families worth consolidating, and the
reports that are import files rather than statements.

## Phase 1 — Discover (C2)
1. Extract and read the definition:
   ```bash
   python3 scripts/solver_def.py <download.xlsx> > definition.json      # IR: parameters, sheets, items, cells
   ```
   Note every parameter (name, default, hidden, `Loop` = per-member bursting), the facts and fields the filters
   read, the period functions (`PeriodCalc.GetFunction(YTD, @Period)` …) and the expanded rows.
2. Write the **source map** (`refs/source-map.md`): for each Solver fact, the warehouse FROM clause, value column
   and period column; for each `<dimension>.<field>` the filters read, its warehouse expression.
3. **Data-readiness pre-flight — before any build.** Pull a small Solver-shaped extract (or query the mapped
   tables) and reproduce two or three of the executed run's printed anchors:
   ```bash
   python3 scripts/convert-solver.py --definition <download.xlsx> --source-map source-map.json \
       --name "<Report> - Data" --folder-id <folder-id> --out dm.json --plan-out plan.json
   python3 scripts/evaluate-solver-local.py --plan plan.json --facts GL_F_Trans=extract.csv \
       --param Period=<yyyymm> --out values.json
   python3 scripts/compare-solver-parity.py --plan plan.json --run executed-run.xlsx --values values.json --out preflight.json
   ```
   If the anchors do not match, **stop and report**: row counts and column names alone are not evidence. The
   usual causes (stale replicated feed, re-coded accounts, master-data drift) are in `refs/parity.md`.

## Phase 1.5 — Reuse-check (C3)
Before creating a data model, score the org's existing models against the tables this report reads:
```bash
python3 scripts/convert-solver.py ... --signature-out workbook-signature.json
ruby scripts/find-or-pick-dm.rb --workbook-signature workbook-signature.json --out dm-match.json
```
A strong match is usually the customer's governed GL model. Reuse its tables and column meanings in the source
map (same source of truth), and decide with the customer whether the report's SQL element belongs in that model
or in a new one. Record the decision.

## Phase 2 — Convert (C4)
`convert-solver.py` (above) compiles each sheet and writes the data-model spec envelope
`{sigmaDataModel, stats, warnings}` plus `plan.json`:

- **One SQL element per sheet**, shaped like the report: one row per line (`Row`, `Line`) and one column per
  report column. Each cell is an expression over *bases* (one `SUM(CASE WHEN … )` per distinct resolved filter),
  so ratios, differences of ratios and rate × count are exact at the report's grain.
- **One SQL element per expanded row**, grouped by the attributes it lists.
- **One data-model control per parameter** the SQL reads (`{{ControlId}}`), number for periods, text otherwise.
  Every reference is wrapped in `COALESCE(<control>, <report default>)`: a bound workbook control with no value
  sends NULL, not the model's default. Comma-separated parameter values (`BUD,ADJ`) and `*` work as in Solver.
- Label and presentation cells (`OSRGet` of an attribute, `TEXT`, `&`, an `IF` whose branches are all text) are
  skipped as text, not values. Anything else the compiler cannot translate is a **gap cell**: listed in `warnings`,
  counted in `stats.gap_cells`, never approximated. In particular:
  - an unsupported filter (an unknown operator or `PeriodCalc` function) makes a gap of every cell that item filters;
    the rest of the sheet still compiles;
  - a value cell that reads a text cell (`=IF(D6>0,D6-D7,"n/a")` and everything that sums it) is a gap;
  - date filters are gaps: the `Date` dimension, `Date.AddDays(...)` windows, and date-range parameters on an
    attribute (Solver tests the stored datetime at both ends). Build them by hand and test both edges;
  - only a trailing wildcard (`ab*`, or `*`) is translated; `*ab` and `a*b` are gaps;
  - a sheet that cannot be compiled at all stops the run (exit 2), like an incomplete source map.
- Filled-down (shared) Excel formulas are expanded cell by cell; a multi-cell array formula is a gap.
- A parameter whose default is another parameter (`{@Location}`) keeps following it in Sigma
  (`COALESCE({{B}}, {{A}}, <default>)`). A missing attribute compares as `''`, as in the local evaluator.
  Exit 2 also lists every unmapped fact or field at once; fix the source map and rerun.

The SQL lives in the data model on purpose: business builders often lack the Write SQL permission and cannot
edit Custom SQL elements in a workbook, but can build on a data model.

## Phase 3 — Post the data model + read back (C5) ← HARD GATE
```bash
python3 scripts/post-solver.py dm --spec dm.json --readback dm-readback.json      # --update <id> to PUT a revision
```
POSTs the spec, then **reads back** `GET /v2/dataModels/{id}/spec` and refuses to continue if any element is
missing. The workbook is wired to the read-back ids and names only.

## Phase 4 — Build the workbook (C6)
```bash
python3 scripts/build-solver-workbook.py --plan plan.json --dm-readback dm-readback.json \
    --name "<Report>" --folder-id <folder-id> --out wb.json
python3 scripts/post-solver.py workbook --spec wb.json --dry-run      # validation only
python3 scripts/post-solver.py workbook --spec wb.json --readback wb-readback.json
```
One page per sheet: the title, the report table sorted by `Row`, and one table per expanded row. The parameter
controls go on the **first page only** (a control id is unique in a workbook, and its value applies on every page),
each bound to the data-model control of the same id (`parameters: [{kind: data-model, …}]`; number controls need
`mode`). Per-line number formats (percent lines inside a currency statement) are not carried; apply them with
conditional formatting or split the line out.

**A create always makes a new workbook.** Iterate with `post-solver.py workbook --spec wb.json --update
<workbookId>` (replaces the contents at the version it just read). Move any stray copy to Trash with
`DELETE /v2/files/{workbookId}` so the customer's folder holds one rebuild.

## Phase 5 — Layout (C7)
The layout travels in the **same create write**, with every element placed. Any later spec PUT must re-send the
read-back layout as its **last write**: a PUT without it wipes the layout. Then render each page
(`scripts/sigma-export-png.py`) and compare it with the executed run, per `refs/solver-visual-qa.md`
(`refs/layout-visual-qa.md` is the shared rendering playbook the export script points to).

## Phase 6 — Verify parity (C8) ← HARD GATE, never skip
Export the rebuilt tables (JSON) with the executed run's parameter values (keyed by `controlId`; a multi-value
text parameter is one comma-separated string), then compare. Element ids are in `wb-readback.json`:
`page-<sheet>-report` for the report table, `page-<sheet>-detail-<row>` for each expanded row.
```bash
python3 scripts/post-solver.py export --workbook-id <id> --element-id page-<sheet>-report \
    --param Period=<yyyymm> --param "BudgetScenario=<codes>" --out export.json
python3 scripts/post-solver.py export --workbook-id <id> --element-id page-<sheet>-detail-<row> \
    --param Period=<yyyymm> --out detail-<row>.json            # once per expanded row
python3 scripts/compare-solver-parity.py --plan plan.json --run executed-run.xlsx --sheet "<sheet>" \
    --sigma-export export.json --detail-export <row>=detail-<row>.json --out parity.json
```
Lines are matched by label in order on both sides (expanded blocks push rows down in a run); a line missing from
either side, an extra exported row, or a missing column is reported, never paired by position. Expanded rows are
compared member by member both ways. GREEN needs every compared cell inside tolerance, nothing unmatched, no gap
cells (`--allow-gaps` records them as accepted, with a reason in the notes) and a run that is not all zeros (a run
whose leftover parameters selected nothing); exit 1 otherwise. "Done" is
GREEN on every sheet and parameter set the customer uses, **every remaining difference explained** and agreed
with the report owner, a visual check, and sign-off. `refs/parity.md` lists the differences seen in the field.

## Security: RLS / CLS (C9)
Solver's own security (user access to dimension members, report folders) is configured in Solver's admin and is
**not in the report definition**, so it cannot be detected from the files: ask the Solver administrator for the
dimension-security rules, always. Port them opt-in as Sigma row-level security on the data model (a user
attribute compared in the SQL, or a filter on a `CurrentUserAttributeText()` column). Skipping it exposes every
row to everyone — say so loudly. A parameter with `Loop` (one output per member) maps to a Sigma export
**burst** split on a list control, configured in the Sigma UI.

## Gaps
Untranslated cells, expanding columns and multi-fact expanded rows are reported in `warnings`; file real tool
gaps with `python3 scripts/escalate-gap.py` (opt-in). Never fake a feature or call a local build a migration.

Exit codes: `0` success / GREEN; `1` parity RED; `2` incomplete source map, or a read-back that lacks an element.
