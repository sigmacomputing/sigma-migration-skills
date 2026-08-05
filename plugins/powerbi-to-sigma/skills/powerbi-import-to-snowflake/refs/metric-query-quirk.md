# Verifying value parity — the ad-hoc `metric()` quirk

When you verify the migrated model, prefer summing **base columns** over calling
converted metrics through the ad-hoc SQL path.

## The quirk

Converted metrics that reference *other metrics by display name* (e.g.
`TotalSales = [Regular_Sales_Dollars] + [Markdown_Sales_Dollars]`) do **not**
resolve through the programmatic `metric('<id>', t)` SQL path:

- `Missing Metric`, or
- `Unknown reference: [Regular_Sales_Dollars]`, or
- `Could not resolve metric column …` when the metric's base column is
  `hidden: true` (the converter hides base measure columns by default).

These metrics **render correctly in the Sigma workbook UI** — the quirk is only
in the ad-hoc `metric()` SQL evaluator, not in the model.

## Reliable parity check

Query the data-model element and `SUM` the base columns directly:

```sql
SELECT ROUND(SUM("<col-id-of-Sum-Regular-Sales-Dollars>"),2) AS regular_sales
FROM "datamodel"."<elementId>" t
```

Get the exact opaque column ids from `describe` (`datamodel-element`). If base
columns are hidden and you need them selectable, unhide them in the DM spec
(`hidden: false`) and re-POST — a straight `SUM` then matches the PBI
`executeQueries` golden exactly.
