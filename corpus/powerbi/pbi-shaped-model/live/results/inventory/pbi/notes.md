# Inventory and Purchasing (pbi shape): run notes

## What was built
- Report: one page (`Cover`), 7 visuals: 3 slicers (Vendor Country, Brand, Store Region), a vendor > product pivot (On Hand (Latest), Open PO Units, Sales R28 Units,
  Days of Cover), a bar of Products by Cover Bucket, two KPIs (On Hand (Latest), Open PO Units).
- Class D measures (On Hand (Latest): ALL; Days of Cover: depends on it; Products by Cover Bucket: FILTER over entities) are served by the hand-completed
  page summary `Cover – summary` (`page-fact-cover.sql`, `page-fact-cover.json`): one row per product (vendor, product, bucket, vendor country, brand,
  on hand units, open PO units, R28 units, product-in-bucket flag), parity-checked against DAX before integration.
- Open PO Units is class A on `Purchase Orders` (data model metric `SumIf(Coalesce(Ordered) - Coalesce(Received), Lower(Status) = "open")`); the page summary reads the same.

## Time-axis density probe
Did not run: this report has no grouped time-intelligence summary (the only time-intelligence measure, Sales R28 Units, is a rolling summary over a dense
day spine, and its visual is served by the page summary). `time_density` is empty, no measure was reclassified, `limits.md` has no "Time-axis density" section.

## Materialization
`--materialization-cron "0 6 * * *"` (UTC) created schedules for `Sales – rolling 28 days by day` and `Cover – summary` (the page summary), both ran now
and reached FRESH before the Phase 6 exports (materialization-freshness.json). `Cover Bucket` (literal rows, no base table) is deliberately not scheduled
(first attempt failed with "Dynamic Tables must have at least one base table"; fixed, see the defects in the task report).

## Control flip
Automatic Phase 6b: Vendor Country and Brand SKIP ("column not in export of the pivot": the summary-grain columns are not exported columns). Explicit
`probe-controls.rb --value VendorCountryFilter=Canada --value BrandFilter=Everfield`: both PASS (pivot 400 -> 85 and 400 -> 50 rows) and equal DAX under the same pick.
Store Region has no control: it is not carried by the summary (it changes On Hand and R28 per product but not Open PO, so it cannot be a grain column) and
the control was dropped by the direct-sources pass before the live slicer gate could wire it. `--allow-field-loss` is needed for that.

## Blank versus zero (probe on a scratch workbook)
Sigma `Sum` over a group whose values are all Null returns Null (blank), not 0: a grouped element with one all-Null group gave `Sum([V])` = blank and
`Sum(If(false, [V], Null))` = blank for it (a normal group sums as usual); a KPI over only Null rows also exports blank. The converter keeps `0` as the
else branch of the latest-period reads (documented in `limits.md`); flipping that branch to Null is now supported by this probe.

## Blank-as-0 arithmetic (DAX `+`/`-` treat BLANK as 0)
The sample warehouse has no NULL ordered/received units (60000 PO rows, 0 NULL either column), so the report data cannot show a difference. Synthetic rows
(10,3), (5,NULL), (NULL,4): DAX `SUMX(DATATABLE(...), [a]-[b])` = 8; Sigma `Sum([A]-[B])` = 7 (a NULL operand makes the row NULL and drops it); Sigma
`Sum(Coalesce([A],0)-Coalesce([B],0))` = 8. The converter's metric and the page summary both use the Coalesce form, so they match DAX; a raw `Sum(a-b)` would not.

## Known limits seen here
- Store Region slicer not carried (above). Not whole: nothing else; all 4 built charts are whole.
- Bar order is alphabetical in Sigma (Power BI sorts the buckets by their Sort column); the summary does not carry Sort. Data labels round (348 shows 350).
- On Hand (Latest) uses one global latest snapshot date over the slicer-filtered rows; every product shares it in this data (1 distinct per-product maximum).

## Rerun (regression check after the later fixes)
Rerun with the saved Cover page summary and `--allow-field-loss`: exit 0, parity 4/4 (1704 pivot cells), materialization FRESH for both schedules, control flip 2/2 by explicit `--value` (the automatic
Phase 6b still skips both, as above). The `Blank versus zero` section of `limits.md` is gone (latest-period reads use `Sum(If(cond, col, Null))`, so a blank latest period stays blank). These files are the rerun's.
Store Region on the Cover page is dropped (v1 limit): no element on the page reaches it. The hand-written page fact's Purchase Orders hook lists Store but it is never wired (no control); Power BI's Store Region does not filter Open PO Units.
