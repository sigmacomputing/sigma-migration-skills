# Power BI to Sigma map


## Tables (5)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Date | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| As Of | table: AS_OF | AS_OF | carried as data model element 'AS_OF' |
| Customer | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Store | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Sales | (none) |  | no data model element carries this table (not used by the report, or read through another element) |

## Relationships (4)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales -> Date (Sales_OrderDate) | (none) |  | no matching relationship on the data model elements |
| Sales -> Date (Sales_ShipDate) [inactive] | (none) |  | no matching relationship on the data model elements |
| Sales -> Customer (Sales_Customer) | (none) |  | no matching relationship on the data model elements |
| Sales -> Store (Sales_Store) | (none) |  | no matching relationship on the data model elements |

## Measures (8)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales.Sales Amount | metric: Sales Amount | FACT_SALES | data model metric 'Sales Amount' on 'FACT_SALES' |
| Sales.Sales YTD | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Sales QTD | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Sales MTD | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Sales PY | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Sales YoY % | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Sales YTD (As Of) | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Sales R28 | (none) |  | no data model metric or column of that name; the measure is not carried |

## Visuals (16)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Trends: Sales Amount | kpi-chart: Sales Amount | Trends | built as kpi-chart on page 'Trends' |
| Trends: Sales YTD | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Trends: Sales QTD | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Trends: Sales MTD | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Trends: Sales PY | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Trends: Sales YoY % | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Trends: Sales YTD (As Of) | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Trends: Sales Amount vs prior year by month | line-chart: Sales Amount vs prior year by month | Trends | built as line-chart on page 'Trends'; dropped: field(s) Sales PY could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Trends: Sales YTD and YTD (As Of) by month | (none) |  | dropped: field(s) Sales YTD, Sales YTD (As Of) could not be resolved to a master column — dropped (would have shipped as a type=error column); dropped: line-chart has no measure on its yAxis — held back (its measures did not bind to the page's data) |
| Trends: Sales Amount and prior year by year | bar-chart: Sales Amount and prior year by year | Trends | built as bar-chart on page 'Trends'; dropped: field(s) Year, Sales PY could not be resolved to a master column — dropped (would have shipped as a type=error column); degraded: bar-chart lost its category/dimension (xAxis) — it will aggregate every row into one mark |
| Trends: Quarter: sales, QTD, YoY | table: Quarter: sales, QTD, YoY | Trends | built as table on page 'Trends'; dropped: field(s) Year, Quarter, Sales QTD, Sales YoY % could not be resolved to a master column — dropped (would have shipped as a type=error column); the sort on Year was removed with it (Sigma rejects a sort on a column the element does not declare), so the source row order is not kept |
| Rolling: Sales R28 | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Rolling: Sales Amount | kpi-chart: Sales Amount (2) | Rolling | built as kpi-chart on page 'Rolling' |
| Rolling: Sales R28 by day | (none) |  | dropped: line-chart has no resolvable master element — element skipped |
| Rolling: Store Region: R28 and sales | table: Store Region: R28 and sales | Rolling | built as table on page 'Rolling'; dropped: field(s) Sales R28 could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Rolling: Sales R28 by Customer Region | (none) |  | dropped: field(s) Sales R28 could not be resolved to a master column — dropped (would have shipped as a type=error column); dropped: bar-chart has no measure on its yAxis — held back (its measures did not bind to the page's data) |

## Slicers (5)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Trends: Year | (none) |  | column 'Date.Year' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead |
| Rolling: Year | (none) |  | column 'Date.Year' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead |
| Rolling: Customer Region | control: Customer Region | FACT_SALES View | control wired to 1 element(s) |
| Rolling: Store Region | control: Store Region | FACT_SALES View | control wired to 1 element(s) |
| Rolling: Segment | control: Segment | FACT_SALES View | control wired to 1 element(s) |
