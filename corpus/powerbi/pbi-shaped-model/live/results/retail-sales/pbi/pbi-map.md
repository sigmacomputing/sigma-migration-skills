# Power BI to Sigma map


## Tables (7)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Date | table: Date | Date | carried as data model element 'Date' |
| Category | table: Category | Category | carried as data model element 'Category' |
| Product | table: Product | Product | carried as data model element 'Product' |
| SKU | table: SKU | SKU | carried as data model element 'SKU' |
| Customer | table: Customer | Customer | carried as data model element 'Customer' |
| Store | table: Store | Store | carried as data model element 'Store' |
| Sales | table: Sales | Sales, Sales (source) | carried as data model element 'Sales' |

## Relationships (7)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales -> Date (Sales_OrderDate) | relationship: Date | Sales.Date | carried as a relationship on 'Sales' |
| Sales -> Date (Sales_ShipDate) [inactive] | relationship: Date | Sales.Date | carried as a relationship on 'Sales' |
| Sales -> SKU (Sales_SKU) | relationship: SKU | Sales.SKU | carried as a relationship on 'Sales' |
| Sales -> Customer (Sales_Customer) | relationship: Customer | Sales.Customer | carried as a relationship on 'Sales' |
| Sales -> Store (Sales_Store) | relationship: Store | Sales.Store | carried as a relationship on 'Sales' |
| SKU -> Product (SKU_Product) | relationship: Product | SKU.Product | carried as a relationship on 'SKU' |
| Product -> Category (Product_Category) | relationship: Category | Product.Category | carried as a relationship on 'Product' |

## Measures (10)

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

## Visuals (18)

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
| Shipping: Sales by Ship Date | kpi-chart: Sales by Ship Date | Shipping – summary, Shipping | built as kpi-chart on page 'Shipping', reading 'Shipping – summary' |
| Shipping: Sales Amount | kpi-chart: Sales Amount (2) | Shipping – summary, Shipping | built as kpi-chart on page 'Shipping', reading 'Shipping – summary' |
| Shipping: Sales by ship month and order month | line-chart: Sales by ship month and order month | Shipping – summary, Shipping | built as line-chart on page 'Shipping', reading 'Shipping – summary' |
| Shipping: Sales by Ship Date by Store Region | bar-chart: Sales by Ship Date by Store Region | Shipping – summary, Shipping | built as bar-chart on page 'Shipping', reading 'Shipping – summary' |
| Shipping: Channel: ship date vs order date | table: Channel: ship date vs order date | Shipping – summary, Shipping | built as table on page 'Shipping', reading 'Shipping – summary' |
| Slicers: Sales Amount | kpi-chart: Sales Amount (3) | Sales, Slicers | built as kpi-chart on page 'Slicers', reading 'Sales' |
| Slicers: Units | kpi-chart: Units (2) | Sales, Slicers | built as kpi-chart on page 'Slicers', reading 'Sales' |
| Slicers: Sales Amount by Store Region | bar-chart: Sales Amount by Store Region | Sales, Slicers | built as bar-chart on page 'Slicers', reading 'Sales' |
| Slicers: Brand: sales and units | table: Brand: sales and units | Sales, Slicers | built as table on page 'Slicers', reading 'Sales' |

## Slicers (10)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Slicers: Category Name | control: Category Name | Category, Product, SKU, Sales | control wired to 4 element(s); the report filter Category.Category Name exclude ["Discontinued"] is not applied to Category itself, so this slicer still lists the excluded members |
| Slicers: Brand | control: Brand | Product, SKU, Sales | control wired to 3 element(s) |
| Slicers: Private Label | control: Private Label | Product, SKU, Sales | control wired to 3 element(s) |
| Slicers: Customer Region | control: Customer Region | Customer, Sales | control wired to 2 element(s) |
| Slicers: Segment | control: Segment | Customer, Sales | control wired to 2 element(s) |
| Slicers: Loyalty Member | control: Loyalty Member | Customer, Sales | control wired to 2 element(s) |
| Slicers: Store Region | control: Store Region | Store, Sales | control wired to 2 element(s) |
| Slicers: Channel | control: Channel | Store, Sales | control wired to 2 element(s) |
| Slicers: Year | control: Year | Date, Sales | control wired to 2 element(s) |
| Slicers: Size | control: Size | SKU, Sales | control wired to 2 element(s) |
