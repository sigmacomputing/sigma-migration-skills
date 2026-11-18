# Parity oracle for Retail Sales (views)

`parity-final.json` says `source: warehouse-sql-oracle` only because the local finalize path (`scripts/parity-from-oracle.py`) always writes that label.
The workbook was posted from the hand-repaired spec (pivot removed). The expected values were NOT produced by warehouse SQL: every chart was compared with the result of a Power BI `executeQueries` DAX query against the
published Retail Sales semantic model (Test workspace, read-only). The report filter (excludes Discontinued products) and the Slicers page's saved slicer
selection (Customer Region = West) were written into each query as `FILTER(ALL(...))` arguments to `SUMMARIZECOLUMNS` / `CALCULATE`; a pivot's grand total
is a separate `ROW(CALCULATE(...))` query. Sigma values are Sigma element CSV exports (`POST /v2/workbooks/{id}/export`). Tolerance: relative 1e-4, absolute 0.005 (strict).
Warehouse SQL (`scripts/sigma-sql-probe.py`) was used only to localize a divergence.
