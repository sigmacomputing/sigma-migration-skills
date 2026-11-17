# Power BI to Sigma map


## Tables (9)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Date | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| As Of | (none) |  | not used by the report: scoped out of the model (no visual, slicer or measure reads it) |
| Category | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Vendor | (none) |  | not used by the report: scoped out of the model (no visual, slicer or measure reads it) |
| Product | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| SKU | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Customer | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Store | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Sales | (none) |  | no data model element carries this table (not used by the report, or read through another element) |

## Relationships (8)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales -> Date (Sales_OrderDate) | (none) |  | no matching relationship on the data model elements |
| Sales -> Date (Sales_ShipDate) [inactive] | (none) |  | no matching relationship on the data model elements |
| Sales -> SKU (Sales_SKU) | (none) |  | no matching relationship on the data model elements |
| Sales -> Customer (Sales_Customer) | (none) |  | no matching relationship on the data model elements |
| Sales -> Store (Sales_Store) | (none) |  | no matching relationship on the data model elements |
| SKU -> Product (SKU_Product) | (none) |  | no matching relationship on the data model elements |
| Product -> Category (Product_Category) | (none) |  | no matching relationship on the data model elements |
| Product -> Vendor (Product_Vendor) | (none) |  | not carried: table 'Vendor' is scoped out of the model (the report does not use it) |

## Measures (10)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales.Sales Amount | metric: Sales Amount | FACT_SALES | data model metric 'Sales Amount' on 'FACT_SALES' |
| Sales.Units | metric: Units | FACT_SALES | data model metric 'Units' on 'FACT_SALES' |
| Sales.Gross Margin | metric: Gross Margin | FACT_SALES | data model metric 'Gross Margin' on 'FACT_SALES' |
| Sales.GM % | metric: GM % | FACT_SALES | data model metric 'GM %' on 'FACT_SALES' |
| Sales.Orders | metric: Orders | FACT_SALES | data model metric 'Orders' on 'FACT_SALES' |
| Sales.Avg Price | metric: Avg Price | FACT_SALES | data model metric 'Avg Price' on 'FACT_SALES' |
| Sales.Cost | metric: Cost | FACT_SALES | data model metric 'Cost' on 'FACT_SALES' |
| Sales.List Value | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Private Label Sales | (none) |  | no data model metric or column of that name; the measure is not carried |
| Sales.Sales by Ship Date | (none) |  | no data model metric or column of that name; the measure is not carried |

## Visuals (18)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Overview: Sales Amount | kpi-chart: Sales Amount | Overview | built as kpi-chart on page 'Overview' |
| Overview: Units | kpi-chart: Units | Overview | built as kpi-chart on page 'Overview' |
| Overview: Gross Margin | kpi-chart: Gross Margin | Overview | built as kpi-chart on page 'Overview' |
| Overview: GM % | kpi-chart: GM % | Overview | built as kpi-chart on page 'Overview' |
| Overview: Orders | kpi-chart: Orders | Overview | built as kpi-chart on page 'Overview' |
| Overview: Avg Price | kpi-chart: Avg Price | Overview | built as kpi-chart on page 'Overview' |
| Overview: Sales Amount by Category | bar-chart: Sales Amount by Category | Overview | built as bar-chart on page 'Overview'; degraded: field(s) Category.Category Name not reachable on master 'Sales' — dropped; dropped: field(s) Category Name could not be resolved to a master column — dropped (would have shipped as a type=error column); degraded: bar-chart lost its category/dimension (xAxis) — it will aggregate every row into one mark |
| Overview: Sales Amount and Gross Margin by Month | line-chart: Sales Amount and Gross Margin by Month | Overview | built as line-chart on page 'Overview' |
| Overview: Brand: sales, list value, private label | pivot-table: Brand: sales, list value, private label | Overview | built as pivot-table on page 'Overview'; degraded: field(s) Product.Brand not reachable on master 'Sales' — dropped; degraded: sort field 'Product.Brand' is not among the built columns — sort skipped; dropped: field(s) Brand, List Value, Private Label Sales could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Shipping: Sales by Ship Date | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Shipping: Sales Amount | kpi-chart: Sales Amount (2) | Shipping | built as kpi-chart on page 'Shipping' |
| Shipping: Sales by ship month and order month | line-chart: Sales by ship month and order month | Shipping | built as line-chart on page 'Shipping'; dropped: field(s) Sales by Ship Date could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Shipping: Sales by Ship Date by Store Region | (none) |  | dropped: field(s) Sales by Ship Date could not be resolved to a master column — dropped (would have shipped as a type=error column); dropped: bar-chart has no measure on its yAxis — held back (its measures did not bind to the page's data) |
| Shipping: Channel: ship date vs order date | table: Channel: ship date vs order date | Shipping | built as table on page 'Shipping'; dropped: field(s) Sales by Ship Date could not be resolved to a master column — dropped (would have shipped as a type=error column) |
| Slicers: Sales Amount | kpi-chart: Sales Amount (3) | Slicers | built as kpi-chart on page 'Slicers' |
| Slicers: Units | kpi-chart: Units (2) | Slicers | built as kpi-chart on page 'Slicers' |
| Slicers: Sales Amount by Store Region | bar-chart: Sales Amount by Store Region | Slicers | built as bar-chart on page 'Slicers' |
| Slicers: Brand: sales and units | table: Brand: sales and units | Slicers | built as table on page 'Slicers'; degraded: field(s) Product.Brand not reachable on master 'Sales' — dropped; dropped: field(s) Brand could not be resolved to a master column — dropped (would have shipped as a type=error column); the sort on Brand was removed with it (Sigma rejects a sort on a column the element does not declare), so the source row order is not kept |

## Slicers (10)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Slicers: Category Name | control: Category Name | Category, DIM_PRODUCT View | control wired to 2 element(s) |
| Slicers: Brand | control: Brand | Product, DIM_PRODUCT View, DIM_SKU View | control wired to 3 element(s) |
| Slicers: Private Label | (none) |  | column 'Product.Private Label' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead |
| Slicers: Customer Region | control: Customer Region | FACT_SALES View | control wired to 1 element(s) |
| Slicers: Segment | control: Segment | FACT_SALES View | control wired to 1 element(s) |
| Slicers: Loyalty Member | control: Loyalty Member | FACT_SALES View | control wired to 1 element(s) |
| Slicers: Store Region | control: Store Region | FACT_SALES View | control wired to 1 element(s) |
| Slicers: Channel | control: Channel | FACT_SALES View | control wired to 1 element(s) |
| Slicers: Year | (none) |  | column 'Date.Year' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead |
| Slicers: Size | control: Size | FACT_SALES View | control wired to 1 element(s) |
