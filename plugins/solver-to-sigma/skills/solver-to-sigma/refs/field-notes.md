# Field notes: what a Solver migration involves beyond the converter

Lessons from field migrations of Solver financial statements and Solver-driven import files. None of these is
automated yet; read them when scoping, and use them to set expectations with the report owner.

## Report families

- **Sibling sheets are not always filter variants.** Statement packs often ship one sheet per period window and
  segment (MTD / QTD / YTD / trailing twelve months x all / segment A / segment B). The best Sigma shape is usually
  one page with a period-to-date control and a segment control, not one page per sheet. Merge only after compiling
  every sheet and diffing the same line across sheets: some lines genuinely differ (a budget column filtered
  differently on one segment, for example). Keep those per sheet, tagged with the segments they apply to. The
  converter builds one page per sheet; consolidation is a design step after parity.
- **Templates carry defects.** The same cross-sheet diff surfaces formula slips, such as a ratio inverted on one
  sheet only. Reproduce faithfully, list each one, and let the report owner decide. Record the decision.
- **Excel row outlines** (collapsed groups of account rows) map to a detail-level control (summary / groups /
  accounts) better than to separate tables.
- **Near-duplicates differ in their filters, not their names.** Two reports titled "excluding closed sites" and
  "excluding recent acquisitions" can look like synonyms and exclude different members. Compare the definitions (`solver-assessment` does), not the titles.

## What switches off with Solver

- **Budgets.** Solver is often also the budgeting tool: budgets are entered there and exported to the warehouse.
  Migrating the reports does not remove that dependency; the planning process needs its own home. Ask early.
- **Master data that lives only in Solver.** Exclusion tags on entities, re-coded employees or accounts, and
  attributes maintained by hand in Solver's dimensions often have no other copy. A warehouse extract of a Solver
  master may also stop receiving new members once Solver is retired. List every UDF the reports filter on, find
  its other home, and name an owner for each one that has none.
- **Manual loads.** Monthly or weekly upload templates (statistics, headcount, vendor files) feed reports. Each
  becomes a Sigma input table or a warehouse load, with an owner.

## Not every Solver report is a statement

Some Solver reports produce an **import file** for the ERP: for example, AP bills built from a supplier's weekly
invoice file plus maintained mapping lists (item to GL account, account to location). Rebuild those as a workflow
app rather than a report: load the file, map it, list the exceptions, approve changes to the mappings, export the
file. Prove parity at the grain of the file (one bill, one line, exact text formats for ids and dates), from the
definition's own window logic (`Date.AddDays(-7)` to the run date, both ends included). CSV uploads type numeric
ids as decimals; cast them before they reach a key or an export.

## Oracles and runs

- **Another tool may already hold Solver's metrics.** If a BI model (Power BI, an Excel model) imports Solver's
  data warehouse, its measures are a metric dictionary and its numbers a second parity oracle.
- **Capture every parameter of an executed run** (a screenshot of the parameter panel). A run re-used with only the
  period changed keeps its other parameters; if they select nothing, every value exports as zero, which
  `compare-solver-parity.py` refuses.

## Dates and performance

- **Date ranges** are tested against the stored datetime at both ends, and placeholder dates (a far-past
  acquisition or opening date) drop members out of a range on purpose. The compiler reports date filters as gaps:
  build them by hand and test both edges, including a member dated on the end day itself.
- **Scan only the months the report needs.** The generated SQL sums over the whole fact table. On a large ledger,
  add a period predicate covering the union of the windows the parameters select; in the field this cut page load
  several-fold.
