# Table calculations, custom metrics, parameters: gap policy

Nothing here is guessed. A construct either translates to a formula the Sigma
workbook can evaluate, or it is recorded in the degradation ledger
(`chart-gaps.json`, plus a warning) and the chart is built without it.

## Table calculations (`metricQuery.tableCalculations`)

| Source | Result |
|---|---|
| Arithmetic over `${table.field}` / other calcs (`+ - * /`, parentheses) | a calculated column on the chart: `[Metrics/<a>] / [Metrics/<b>]` (`groupings.calculations`) |
| SQL, window functions (`SUM(...) OVER`, running total, rank), format/template calcs, anything else | `scope-cut` ledger entry quoting the original SQL; the column is not built |

**Finishing by hand:** open the ledger entry, read the quoted SQL, and add the
equivalent calculation to the chart in Sigma (a cumulative or percent-of-total
calculation on the metric column). Fixture example: the running total on
`orders-by-region-table`.

## Custom metrics (`additionalMetrics`)

Single-column aggregates (sum, count, count_distinct, average, min, max, median)
with equals / notEquals filters become an aggregate column on the chart
(`LightdashFormula.aggregate_formula`). `periodOverPeriod` and complex SQL are
gaps. A chart dimension that is not in `field-map.json` (for example a Lightdash
custom dimension) cannot be resolved and is recorded as a gap.

## DM metrics that become gaps

`percent_of_total`, `percent_of_previous`, `running_total` are post-calculations
over result rows with no data-model equivalent: skipped in `field-map.json`
(`kind: skipped`), ledger gap, rebuild as a workbook calculation. A metric
`filters:` operator with no Sigma translation (`inThePast…`, text operators) is
a gap, never a silent equality. `hidden: true` metrics are emitted visible
(Sigma DM metrics have no hidden flag) with a `quality-waiver` entry.

## Parameters, Liquid, windows

`${lightdash.parameters.*}`, Liquid templating, window functions and subqueries
in dimension/metric SQL have no translation (the formula engine returns
`[nil, reason]`): ledger gap, and the field is skipped rather than passed
through, because the DM reference documents no SQL passthrough for column
formulas. If the logic matters, land it as a warehouse view or column and
re-point the model.

## Function names to verify on the first live run

The formula engine emits `Len`, `Mid`, `Ceiling`, `Greatest`, `Least`,
`SplitPart`, `DayOfYear`, `NullIf`, `Between`, `IsNotNull`, `Now`, `Today`, the
`%` operator and `PercentileCont` (Lightdash `percentile`). Names come from the
Sigma function reference and sibling converters, not from a live POST. A bad name
surfaces when the DM POST is read back (an error-typed column, if the spec
readback exposes column types; the gate checks) or at the workbook's phase-6
live column scan (`type=error`); fix it in
`scripts/lib/lightdash_formula.rb` or in the Sigma DM by hand.
