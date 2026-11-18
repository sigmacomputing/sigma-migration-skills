# Parity oracle for Inventory and Purchasing (pbi)

`parity-final.json` says `source: warehouse-sql-oracle` only because the local finalize path (`scripts/parity-from-oracle.py`) always writes that label.
The expected values were NOT produced by warehouse SQL: every chart was compared with the result of a Power BI `executeQueries` DAX query against the
published Retail Inventory semantic model (Test workspace, read-only), with no slicer selection and no report filter (the report saves none).
Sigma values are Sigma element CSV exports (`POST /v2/workbooks/{id}/export`). Tolerance: relative 1e-4, absolute 0.005 (strict).

Before integration the hand-completed page summary SQL was also checked against the same DAX results (400 vendor x product rows, 4 measures each, the
bucket counts and the totals: 0 differences). The pivot export blanks repeated vendor cells; they were forward-filled before comparing, and the
oracle for the matrix is the DAX rows plus the per-vendor subtotals plus the grand total (the pivot shows both; 1704 cells).

## DAX query per chart (the chart name is the Sigma element name)

- `Vendor and Product: on hand, open POs, sales R28, cover`: `EVALUATE SUMMARIZECOLUMNS(Vendor[Vendor Name], Product[Product Name], "On Hand (Latest)", [On Hand (Latest)], "Open PO Units", [Open PO Units], "Sales R28 Units", [Sales R28 Units], "Days of Cover", [Days of Cover])`
  plus `SUMMARIZECOLUMNS(Vendor[Vendor Name], <same measures>)` for the vendor subtotals and `ROW(<same measures>)` for the grand total
- `Products by cover bucket`: `EVALUATE SUMMARIZECOLUMNS('Cover Bucket'[Bucket], "Products by Cover Bucket", [Products by Cover Bucket])`
- `On Hand (Latest)`: `EVALUATE ROW("On Hand (Latest)", [On Hand (Latest)])`
- `Open PO Units`: `EVALUATE ROW("Open PO Units", [Open PO Units])`

Slicer states, checked by DAX `TREATAS` against the explicit control-flip values: Vendor Country = Canada (85 rows; on hand 88686, open PO 320551,
R28 49962, days of cover 49.701933) and Brand = Everfield (50 rows; 48727 / 205037 / 29287 / 46.585721) equal the Sigma pivot's grand totals.
