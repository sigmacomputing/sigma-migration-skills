# Power BI to Sigma map


## Tables (5)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Date | table: Date | Date | carried as data model element 'Date' |
| As Of | table: As Of | As Of | carried as data model element 'As Of' |
| Customer | table: Customer | Customer | carried as data model element 'Customer' |
| Store | table: Store | Store | carried as data model element 'Store' |
| Sales | table: Sales | Sales | carried as data model element 'Sales' |

## Relationships (4)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales -> Date (Sales_OrderDate) | relationship: Date | Sales.Date | carried as a relationship on 'Sales' |
| Sales -> Date (Sales_ShipDate) [inactive] | relationship: Date | Sales.Date | carried as a relationship on 'Sales' |
| Sales -> Customer (Sales_Customer) | relationship: Customer | Sales.Customer | carried as a relationship on 'Sales' |
| Sales -> Store (Sales_Store) | relationship: Store | Sales.Store | carried as a relationship on 'Sales' |

## Measures (8)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales.Sales Amount | metric: Sales Amount | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'Sales Amount' on 'Sales' |
| Sales.Sales YTD | column: YTD at Month | Trends – summary | class D (slicer fields exceed carry size; needs a live summary): built as column 'YTD at Month' on 'Trends – summary' |
| Sales.Sales QTD | column: QTD at Month | Trends – summary | class D (slicer fields exceed carry size; needs a live summary): built as column 'QTD at Month' on 'Trends – summary' |
| Sales.Sales MTD | column: MTD at Latest Month | Trends – summary | class D (slicer fields exceed carry size; needs a live summary): built as column 'MTD at Latest Month' on 'Trends – summary' |
| Sales.Sales PY | column: Sales PY | Trends – summary | class D (slicer fields exceed carry size; needs a live summary): built as column 'Sales PY' on 'Trends – summary' |
| Sales.Sales YoY % | column: Sales PY | Trends – summary | class D (slicer fields exceed carry size; needs a live summary): built as column 'Sales PY' on 'Trends – summary' |
| Sales.Sales YTD (As Of) | metric: Sales YTD (As Of) | Sales | class C (ytd time intelligence (as_of anchor) over [Sales Amount]): data model metric 'Sales YTD (As Of)' on 'Sales' |
| Sales.Sales R28 | column: Sales R28 | Sales – rolling 28 days by day | class C (rolling time intelligence (axis anchor) over [Sales Amount]): built as column 'Sales R28' on 'Sales – rolling 28 days by day' |

## Visuals (16)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Trends: Sales Amount | kpi-chart: Sales Amount | Trends – summary, Trends | built as kpi-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales YTD | kpi-chart: Sales YTD | Trends – summary, Trends | built as kpi-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales QTD | kpi-chart: Sales QTD | Trends – summary, Trends | built as kpi-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales MTD | kpi-chart: Sales MTD | Trends – summary, Trends | built as kpi-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales PY | kpi-chart: Sales PY | Trends – summary, Trends | built as kpi-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales YoY % | kpi-chart: Sales YoY % | Trends – summary, Trends | built as kpi-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales YTD (As Of) | kpi-chart: Sales YTD (As Of) | Trends – summary, Trends | built as kpi-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales Amount vs prior year by month | line-chart: Sales Amount vs prior year by month | Trends – summary, Trends | built as line-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales YTD and YTD (As Of) by month | line-chart: Sales YTD and YTD (As Of) by month | Trends – summary, Trends | built as line-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Sales Amount and prior year by year | bar-chart: Sales Amount and prior year by year | Trends – summary, Trends | built as bar-chart on page 'Trends', reading 'Trends – summary' |
| Trends: Quarter: sales, QTD, YoY | table: Quarter: sales, QTD, YoY | Trends – summary, Trends | built as table on page 'Trends', reading 'Trends – summary' |
| Rolling: Sales R28 | kpi-chart: Sales R28 | Rolling | built as kpi-chart on page 'Rolling' |
| Rolling: Sales Amount | kpi-chart: Sales Amount (2) | Sales, Rolling | built as kpi-chart on page 'Rolling', reading 'Sales' |
| Rolling: Sales R28 by day | line-chart: Sales R28 by day | Rolling | built as line-chart on page 'Rolling' |
| Rolling: Store Region: R28 and sales | table: Store Region: R28 and sales | Sales, Rolling | built as table on page 'Rolling', reading 'Sales'; degraded: field(s) Sales.Sales R28 not reachable on master 'Sales' — dropped; dropped: field(s) Sales R28 could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Rolling: Sales R28 by Customer Region | (none) |  | degraded: field(s) Sales.Sales R28 not reachable on master 'Customer' — dropped; dropped: field(s) Sales R28 could not be resolved to a master column — dropped (would have shipped as a type=error column); dropped: bar-chart has no measure on its yAxis — held back (its measures did not bind to the page's data) |

## Slicers (5)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Trends: Year | control: Year | Date, Sales, Trends – summary | control wired to 3 element(s) |
| Rolling: Year | control:  | Date, Sales, Trends – summary | control wired to 3 element(s) |
| Rolling: Customer Region | control: Customer Region | Customer, Sales | control wired to 2 element(s) |
| Rolling: Store Region | control: Store Region | Store, Sales, Sales – rolling 28 days by day | control wired to 3 element(s) |
| Rolling: Segment | control: Segment | Customer, Sales | control wired to 2 element(s) |
