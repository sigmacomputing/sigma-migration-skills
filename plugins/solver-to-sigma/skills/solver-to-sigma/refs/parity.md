# Parity for Solver reports

The oracle is an **executed run** for a closed period with known parameter values, never the template (it has
no values) and never "the numbers look right". Run the comparison per sheet and per parameter set the business
uses (month, quarter, year-to-date, trailing twelve months; each scenario set).

## Method

1. **Pre-flight (Phase 1):** reproduce two or three printed anchors from a small warehouse aggregate with
   `evaluate-solver-local.py` before building. If they do not match, the problem is the data, not the build.
2. **Build parity (Phase 6):** export the rebuilt report table with the run's parameter values and run
   `compare-solver-parity.py --sigma-export`. Default tolerance: 0.01 absolute or 1e-6 relative.
3. **Explain every difference.** Group the mismatches by line and column, find the smallest set of accounts,
   members or periods that explains each group, and agree each explanation with the report owner. Record them.
4. Re-run after every change to the definition mapping, the source map or the warehouse feeds.

## Differences seen in the field, and what they turned out to be

| Pattern | Usual cause | What to do |
|---|---|---|
| Older periods match, recent periods are empty or low | The mapped table is a replicated feed that stopped loading | Repoint to the ERP ledger or the governed mart; check last-loaded dates |
| One line differs by a small fixed amount in one period | A reclass posted in the ERP after the Solver run (or vice versa) | Confirm the journal; usually accept and record |
| Statistical lines (headcount, visits, hours) differ before a date | The statistic was re-coded; corrected history was back-loaded into Solver under the new code only | Decide with the owner: bring the history over, read the old code for old periods, or scope history out |
| A member shows two values for the same statistic | Both the old and the new code were posted for the same periods | Pick one code per period range, with the owner |
| Employee- or item-based lines differ by 0.1–1% | Master attributes (department, role flags) differ between Solver and the warehouse copy, or the warehouse master misses recent additions | List the members whose attributes differ; agree the source; fall back to the transaction's own attribute for members the master lacks |
| A whole column is off by a constant factor or sign | Sign convention (credit-normal revenue) or a `*1`/`*-1` in the formula | Check the cell formula's sign and the source's sign convention |
| Ratios (margin %, rate per unit) differ while their parts match | The ratio was averaged instead of computed from sums | The compiler computes ratios from base sums; check any hand-built change |
| YTD or QTD differs, month matches | Fiscal year start, or the period function's window | Confirm `fiscal_year_start_month` and the function table in `solver-definition-format.md` |
| Values differ only for some locations | A location exclusion flag (closed, divested) is not carried, or differs | Map the UDF the report filters on; confirm the member list |

## What parity does not cover

Formatting, drill-through, Solver commentary and distribution. Check the layout visually
(`solver-visual-qa.md`) and list anything the customer used that the rebuild does not have.
