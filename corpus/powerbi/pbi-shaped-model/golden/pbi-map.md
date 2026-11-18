# Power BI to Sigma map


## Tables (9)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Date | table: Date | Date | carried as data model element 'Date' |
| As Of | table: As Of | As Of | carried as data model element 'As Of' |
| Category | table: Category | Category | carried as data model element 'Category' |
| Vendor | (none) |  | not used by the report: scoped out of the model (no visual, slicer or measure reads it) |
| Product | table: Product | Product | carried as data model element 'Product' |
| SKU | table: SKU | SKU | carried as data model element 'SKU' |
| Customer | table: Customer | Customer | carried as data model element 'Customer' |
| Store | table: Store | Store | carried as data model element 'Store' |
| Sales | table: Sales | Sales, Sales (source) | carried as data model element 'Sales' |

## Relationships (8)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales -> Date (Sales_OrderDate) | relationship: Date | Sales.Date | carried as a relationship on 'Sales' |
| Sales -> Date (Sales_ShipDate) [inactive] | relationship: Date (ShipDateKey) | Sales.Date (ShipDateKey) | carried as a relationship on 'Sales' |
| Sales -> SKU (Sales_SKU) | relationship: SKU | Sales.SKU | carried as a relationship on 'Sales' |
| Sales -> Customer (Sales_Customer) | relationship: Customer | Sales.Customer | carried as a relationship on 'Sales' |
| Sales -> Store (Sales_Store) | relationship: Store | Sales.Store | carried as a relationship on 'Sales' |
| SKU -> Product (SKU_Product) | relationship: Product | SKU.Product | carried as a relationship on 'SKU' |
| Product -> Category (Product_Category) | relationship: Category | Product.Category | carried as a relationship on 'Product' |
| Product -> Vendor (Product_Vendor) | (none) |  | not carried: table 'Vendor' is scoped out of the model (the report does not use it) |

## Measures (17)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales.Sales Amount | metric: Sales Amount | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'Sales Amount' on 'Sales' |
| Sales.Units | metric: Units | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'Units' on 'Sales' |
| Sales.Gross Margin | metric: Gross Margin | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'Gross Margin' on 'Sales' |
| Sales.GM % | metric: GM % | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'GM %' on 'Sales' |
| Sales.Orders | metric: Orders | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'Orders' on 'Sales' |
| Sales.Avg Price | metric: Avg Price | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'Avg Price' on 'Sales' |
| Sales.Cost | metric: Cost | Sales | class A (aggregates and arithmetic over Sales columns only): data model metric 'Cost' on 'Sales' |
| Sales.List Value | metric: List Value | Sales | class B (reads Product[List Price] through SKU > Product): data model metric 'List Value' on 'Sales' |
| Sales.Private Label Sales | metric: Private Label Sales | Sales | class B (reads Product[Private Label] through SKU > Product): data model metric 'Private Label Sales' on 'Sales' |
| Sales.Sales by Ship Date | metric: Sales by Ship Date | Sales | class B (uses inactive relationship Date (ShipDateKey)): data model metric 'Sales by Ship Date' on 'Sales' |
| Sales.Sales YTD | column: Sales YTD | Sales by month | class C (ytd time intelligence (axis anchor) over [Sales Amount]): built as column 'Sales YTD' on 'Sales by month' |
| Sales.Sales QTD | column: Sales QTD | Sales by quarter (quarter reset) | class C (qtd time intelligence (axis anchor) over [Sales Amount]): built as column 'Sales QTD' on 'Sales by quarter (quarter reset)' |
| Sales.Sales MTD | column: Sales MTD | Sales by month (month reset) | class C (mtd time intelligence (axis anchor) over [Sales Amount]): built as column 'Sales MTD' on 'Sales by month (month reset)' |
| Sales.Sales PY | column: Sales PY | Sales by month, Sales by quarter | class C (py time intelligence (axis anchor) over [Sales Amount]): built as column 'Sales PY' on 'Sales by month' |
| Sales.Sales YoY % | column: Sales YoY % (numerator) | Sales by quarter | class C (py time intelligence (axis anchor) over [Sales Amount]): built as column 'Sales YoY % (numerator)' on 'Sales by quarter' |
| Sales.Sales YTD (As Of) | metric: Sales YTD (As Of) | Sales | class C (ytd time intelligence (as_of anchor) over [Sales Amount]): data model metric 'Sales YTD (As Of)' on 'Sales' |
| Sales.Sales R28 | column: Sales R28 | Sales – rolling 28 days by day | class C (rolling time intelligence (axis anchor) over [Sales Amount]): built as column 'Sales R28' on 'Sales – rolling 28 days by day' |

## Visuals (34)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Overview: Sales Amount | kpi-chart: Sales Amount | Sales, Overview | built as kpi-chart on page 'Overview', reading 'Sales' |
| Overview: Units | kpi-chart: Units | Sales, Overview | built as kpi-chart on page 'Overview', reading 'Sales' |
| Overview: Gross Margin | kpi-chart: Gross Margin | Sales, Overview | built as kpi-chart on page 'Overview', reading 'Sales' |
| Overview: GM % | kpi-chart: GM % | Sales, Overview | built as kpi-chart on page 'Overview', reading 'Sales' |
| Overview: Orders | kpi-chart: Orders | Sales, Overview | built as kpi-chart on page 'Overview', reading 'Sales' |
| Overview: Avg Price | kpi-chart: Avg Price | Sales, Overview | built as kpi-chart on page 'Overview', reading 'Sales' |
| Overview: Sales Amount by Category | bar-chart: Sales Amount by Category | Sales, Overview | built as bar-chart on page 'Overview', reading 'Sales' |
| Overview: Sales Amount and Gross Margin by Month | line-chart: Sales Amount and Gross Margin by Month | Sales, Overview | built as line-chart on page 'Overview', reading 'Sales' |
| Overview: Brand: sales, list value, private label | pivot-table: Brand: sales, list value, private label | Sales, Overview | built as pivot-table on page 'Overview', reading 'Sales'; degraded: sort field 'Product.Brand' is not among the built columns — sort skipped |
| Shipping: Sales by Ship Date | kpi-chart: Sales by Ship Date | Sales, Shipping | built as kpi-chart on page 'Shipping', reading 'Sales' |
| Shipping: Sales Amount | kpi-chart: Sales Amount (2) | Sales, Shipping | built as kpi-chart on page 'Shipping', reading 'Sales' |
| Shipping: Sales by ship month and order month | (none) |  | dropped: class D visual held back (not built): needs two relationship paths to Date: the active relationship, Date (ShipDateKey); Sigma reads one path per element |
| Shipping: Sales by Ship Date by Store Region | bar-chart: Sales by Ship Date by Store Region | Sales, Shipping | built as bar-chart on page 'Shipping', reading 'Sales' |
| Shipping: Channel: ship date vs order date | table: Channel: ship date vs order date | Sales, Shipping | built as table on page 'Shipping', reading 'Sales' |
| Slicers: Sales Amount | kpi-chart: Sales Amount (3) | Sales, Slicers | built as kpi-chart on page 'Slicers', reading 'Sales' |
| Slicers: Units | kpi-chart: Units (2) | Sales, Slicers | built as kpi-chart on page 'Slicers', reading 'Sales' |
| Slicers: Sales Amount by Store Region | bar-chart: Sales Amount by Store Region | Sales, Slicers | built as bar-chart on page 'Slicers', reading 'Sales' |
| Slicers: Brand: sales and units | table: Brand: sales and units | Sales, Slicers | built as table on page 'Slicers', reading 'Sales' |
| Trends: Sales Amount | kpi-chart: Sales Amount (4) | Sales, Trends | built as kpi-chart on page 'Trends', reading 'Sales' |
| Trends: Sales YTD | kpi-chart: Sales YTD | Sales by month, Trends | built as kpi-chart on page 'Trends', reading 'Sales by month' |
| Trends: Sales QTD | kpi-chart: Sales QTD | Sales by quarter (quarter reset), Trends | built as kpi-chart on page 'Trends', reading 'Sales by quarter (quarter reset)' |
| Trends: Sales MTD | kpi-chart: Sales MTD | Sales by month (month reset), Trends | built as kpi-chart on page 'Trends', reading 'Sales by month (month reset)' |
| Trends: Sales PY | kpi-chart: Sales PY | Sales by month, Trends | built as kpi-chart on page 'Trends', reading 'Sales by month' |
| Trends: Sales YoY % | kpi-chart: Sales YoY % | Sales by quarter, Trends | built as kpi-chart on page 'Trends', reading 'Sales by quarter' |
| Trends: Sales YTD (As Of) | kpi-chart: Sales YTD (As Of) | Sales, Trends | built as kpi-chart on page 'Trends', reading 'Sales' |
| Trends: Sales Amount vs prior year by month | line-chart: Sales Amount vs prior year by month | Sales by month, Trends | built as line-chart on page 'Trends', reading 'Sales by month' |
| Trends: Sales YTD and YTD (As Of) by month | (none) |  | dropped: class D visual held back (not built): Sales YTD (As Of) is an as-of measure, which Power BI holds flat across the Date table (its CALCULATE filter replaces the Date filter), and this visual binds Date.Month Start; Sigma would plot one value per group; held back (class D) |
| Trends: Sales Amount and prior year by year | bar-chart: Sales Amount and prior year by year | Sales by month, Trends | built as bar-chart on page 'Trends', reading 'Sales by month' |
| Trends: Quarter: sales, QTD, YoY | table: Quarter: sales, QTD, YoY | Sales by quarter (quarter reset), Trends | built as table on page 'Trends', reading 'Sales by quarter (quarter reset)'; degraded: field(s) Sales.Sales YoY % not reachable on master 'Sales by quarter (quarter reset)' — dropped; dropped: field(s) Sales YoY % could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Rolling: Sales R28 | kpi-chart: Sales R28 | Sales – rolling 28 days by day, Rolling | built as kpi-chart on page 'Rolling', reading 'Sales – rolling 28 days by day' |
| Rolling: Sales Amount | kpi-chart: Sales Amount (5) | Sales, Rolling | built as kpi-chart on page 'Rolling', reading 'Sales' |
| Rolling: Sales R28 by day | line-chart: Sales R28 by day | Sales – rolling 28 days by day, Rolling | built as line-chart on page 'Rolling', reading 'Sales – rolling 28 days by day' |
| Rolling: Store Region: R28 and sales | table: Store Region: R28 and sales | Sales, Rolling | built as table on page 'Rolling', reading 'Sales'; degraded: field(s) Sales.Sales R28 not reachable on master 'Sales' — dropped; dropped: field(s) Sales R28 could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Rolling: Sales R28 by Customer Region | bar-chart: Sales R28 by Customer Region | Sales – rolling 28 days by day, Rolling | built as bar-chart on page 'Rolling', reading 'Sales – rolling 28 days by day' |

## Slicers (15)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Slicers: Category Name | control: Category Name | Category, Product, SKU, Sales | control wired to 4 element(s); the report filter Category.Category Name exclude ["Discontinued"] is not applied to Category itself, so this slicer still lists the excluded members |
| Slicers: Brand | control: Brand | Product, SKU, Sales | control wired to 3 element(s) |
| Slicers: Private Label | control: Private Label | Product, SKU, Sales | control wired to 3 element(s) |
| Slicers: Customer Region | control: Customer Region | Customer, Sales, Sales – rolling 28 days by day, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 7 element(s) |
| Slicers: Segment | control: Segment | Customer, Sales, Sales – rolling 28 days by day, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 7 element(s) |
| Slicers: Loyalty Member | control: Loyalty Member | Customer, Sales | control wired to 2 element(s) |
| Slicers: Store Region | control: Store Region | Store, Sales, Sales – rolling 28 days by day, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 7 element(s) |
| Slicers: Channel | control: Channel | Store, Sales | control wired to 2 element(s) |
| Slicers: Year | control: Year | Date, Sales, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 6 element(s) |
| Slicers: Size | control: Size | SKU, Sales | control wired to 2 element(s) |
| Trends: Year | control: Year | Date, Sales, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 6 element(s) |
| Rolling: Year | control:  | Date, Sales, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 6 element(s) |
| Rolling: Customer Region | control: Customer Region | Customer, Sales, Sales – rolling 28 days by day, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 7 element(s) |
| Rolling: Store Region | control: Store Region | Store, Sales, Sales – rolling 28 days by day, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 7 element(s) |
| Rolling: Segment | control: Segment | Customer, Sales, Sales – rolling 28 days by day, Sales by quarter (quarter reset), Sales by quarter, Sales by month (month reset), Sales by month | control wired to 7 element(s) |
