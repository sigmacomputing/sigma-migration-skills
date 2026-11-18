# Parity oracle for Sales Trends (views)

`parity-final.json` says `source: warehouse-sql-oracle` only because the local finalize path (`scripts/parity-from-oracle.py`) always writes that label.
The expected values in this run were NOT produced by warehouse SQL: every chart was compared with the result of a Power BI `executeQueries` DAX query
against the published Retail Sales Trends semantic model (Test workspace, read-only), with no slicer selection and no report filter (the report saves none).
Sigma values are Sigma element CSV exports (`POST /v2/workbooks/{id}/export`). Tolerance: relative 1e-4, absolute 0.005 (strict).

Only the visuals the views shape built (6 of 21 source visuals) are compared, on the fields that survived (Sales Amount and the dimension axes that resolved); time-intelligence fields were dropped by the converter, so those cells are not compared. Two charts lost their dimension (Year, Quarter) and fail on missing key columns.

## DAX query per chart (the chart name is the Sigma element name)

- `Quarter  sales  QTD  YoY`: `EVALUATE SUMMARIZECOLUMNS('Date'[Year], 'Date'[Quarter], "Sales Amount", [Sales Amount], "Sales QTD", [Sales QTD], "Sales YoY %", [Sales YoY %])`
- `Sales Amount`: `EVALUATE ROW("Sales Amount", [Sales Amount])`
- `Sales Amount  2`: `EVALUATE ROW("Sales Amount", [Sales Amount])`
- `Sales Amount and prior year by year`: `EVALUATE SUMMARIZECOLUMNS('Date'[Year], "Sales Amount", [Sales Amount], "Sales PY", [Sales PY])`
- `Sales Amount vs prior year by month`: `EVALUATE SUMMARIZECOLUMNS('Date'[Month Start], "Sales Amount", [Sales Amount], "Sales PY", [Sales PY])`
- `Sales MTD`: `EVALUATE ROW("Sales MTD", [Sales MTD])`
- `Sales PY`: `EVALUATE ROW("Sales PY", [Sales PY])`
- `Sales QTD`: `EVALUATE ROW("Sales QTD", [Sales QTD])`
- `Sales R28`: `EVALUATE ROW("Sales R28", [Sales R28])`
- `Sales R28 by Customer Region`: `EVALUATE SUMMARIZECOLUMNS(Customer[Customer Region], "Sales R28", [Sales R28])`
- `Sales R28 by day`: `EVALUATE SUMMARIZECOLUMNS('Date'[Date], "Sales R28", [Sales R28])`
- `Sales YTD`: `EVALUATE ROW("Sales YTD", [Sales YTD])`
- `Sales YTD  As Of`: `EVALUATE ROW("Sales YTD (As Of)", [Sales YTD (As Of)])`
- `Sales YTD and YTD  As Of  by month`: `EVALUATE SUMMARIZECOLUMNS('Date'[Month Start], "Sales YTD", [Sales YTD], "Sales YTD (As Of)", [Sales YTD (As Of)])`
- `Sales YoY`: `EVALUATE ROW("Sales YoY %", [Sales YoY %])`
- `Store Region  R28 and sales`: `EVALUATE SUMMARIZECOLUMNS(Store[Store Region], "Sales R28", [Sales R28], "Sales Amount", [Sales Amount])`
