# tableau / pivot-pcto-direction

Hand-written minimal `.twb` (synthetic Region / Segment / Sales; no tenant
data). Four crosstabs with Segment on ROWS and Region on COLUMNS; the first three
carry a table calc whose "compute using" is Region (`<table-calc ordering-field=...>`):

1. a percent-of-total QUICK CALC pill on the marks card
   (`[pcto:sum:Sales:qk]`),
2. an explicit `SUM([Sales]) / TOTAL(SUM([Sales]))` calc,
3. `RUNNING_SUM(SUM([Sales]))` ordered by Region,
4. the same explicit share calc with NO `<table-calc>` at all (never
   re-addressed — Tableau's default Table (Across) → `"row"`).

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | the synthetic workbook (4 crosstab worksheets, 1 dashboard) |
| `get-workbook.json`, `master-columns.json` | minimal discovery fixtures so `build-charts-from-signals.rb` runs offline |
| `chart-specs.json` | PINNED builder output |
| `checks.sh` | regenerates the output, byte-compares to the pin, asserts the contracts below |

## Converter

No MCP converter; pins the SKILL-script contracts (`$S` = `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts`):

```
ruby $S/parse-twb-layout.rb workbook-content.twb dashboard-layout.json
ruby $S/build-charts-from-signals.rb --tableau-dir . --layout dashboard-layout.json \
  --meta dashboard-layout-meta.json --master-map master-columns.json \
  --master-element-id master --skip-dashboard-read corpus-fixture --page-per-worksheet \
  --title "Pivot Fixture" --out chart-specs.json
```

## Assertions

- Compute-using Region with Region on the COLUMNS shelf emits
  `PercentOfTotal(..., "row")` for both the quick calc and the explicit
  share calc (previously `"grand_total"`).
- The running sum over Region carries a hidden sort key column
  `If(IsNull([Master/Region]), "", [Master/Region])` and the Region axis is
  sorted by it (ascending, min) so a NULL member sorts FIRST as in Tableau.
  (The null member itself is warehouse data, not representable in the .twb; the
  contract pinned is the emitted key.)

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "get-workbook.json", "format": "json"},
    {"path": "master-columns.json", "format": "json"},
    {"path": "chart-specs.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
