# Power BI to Sigma map


## Tables (9)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Date | table: Date | Date | carried as data model element 'Date' |
| Vendor | table: Vendor | Vendor | carried as data model element 'Vendor' |
| Product | table: Product | Product | carried as data model element 'Product' |
| SKU | table: SKU | SKU | carried as data model element 'SKU' |
| Store | table: Store | Store | carried as data model element 'Store' |
| Sales | table: Sales | Sales | carried as data model element 'Sales' |
| Inventory | table: Inventory | Inventory | carried as data model element 'Inventory' |
| Purchase Orders | table: Purchase Orders | Purchase Orders | carried as data model element 'Purchase Orders' |
| Cover Bucket | table: Cover Bucket | Cover Bucket | carried as data model element 'Cover Bucket' |

## Relationships (12)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales -> Date (Sales_OrderDate) | relationship: Date | Sales.Date | carried as a relationship on 'Sales' |
| Sales -> Date (Sales_ShipDate) [inactive] | relationship: Date | Sales.Date | carried as a relationship on 'Sales' |
| Sales -> SKU (Sales_SKU) | relationship: SKU | Sales.SKU | carried as a relationship on 'Sales' |
| Sales -> Store (Sales_Store) | relationship: Store | Sales.Store | carried as a relationship on 'Sales' |
| SKU -> Product (SKU_Product) | relationship: Product | SKU.Product | carried as a relationship on 'SKU' |
| Product -> Vendor (Product_Vendor) | relationship: Vendor | Product.Vendor | carried as a relationship on 'Product' |
| Inventory -> Date (Inventory_Date) | relationship: Date | Inventory.Date | carried as a relationship on 'Inventory' |
| Inventory -> SKU (Inventory_SKU) | relationship: SKU | Inventory.SKU | carried as a relationship on 'Inventory' |
| Inventory -> Store (Inventory_Store) | relationship: Store | Inventory.Store | carried as a relationship on 'Inventory' |
| Purchase Orders -> Date (PO_OrderDate) | relationship: Date | Purchase Orders.Date | carried as a relationship on 'Purchase Orders' |
| Purchase Orders -> Date (PO_ExpectedDate) [inactive] | relationship: Date | Purchase Orders.Date | carried as a relationship on 'Purchase Orders' |
| Purchase Orders -> SKU (PO_SKU) | relationship: SKU | Purchase Orders.SKU | carried as a relationship on 'Purchase Orders' |

## Measures (5)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Inventory.On Hand (Latest) | column: On Hand Units | Cover – summary | class D (uses ALL, which removes filters (snapshot or share-of-total logic)): built as column 'On Hand Units' on 'Cover – summary' |
| Inventory.Open PO Units | metric: Open PO Units | Purchase Orders | class A (aggregates and arithmetic over Purchase Orders columns only): data model metric 'Open PO Units' on 'Purchase Orders' |
| Inventory.Sales R28 Units | column: Sales R28 Units | Sales – rolling 28 days by day, Cover – summary | class C (rolling time intelligence (axis anchor) over an inline aggregate on Sales): built as column 'Sales R28 Units' on 'Sales – rolling 28 days by day' |
| Inventory.Days of Cover | column: On Hand Units | Cover – summary | class D (depends on class D measure [On Hand (Latest)]: uses ALL, which removes filters (snapshot or share-of-total logic)): built as column 'On Hand Units' on 'Cover – summary' |
| Inventory.Products by Cover Bucket | column: Products in Bucket | Cover – summary | class D (uses FILTER, which iterates over entities (per-entity bucketing)): built as column 'Products in Bucket' on 'Cover – summary' |

## Visuals (4)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Cover: Vendor and Product: on hand, open POs, sales R28, cover | pivot-table: Vendor and Product: on hand, open POs, sales R28, cover | Cover – summary, Cover | built as pivot-table on page 'Cover', reading 'Cover – summary'; degraded: sort field 'Vendor.Vendor Name' is not among the built columns — sort skipped; approximated: Power BI opens this matrix collapsed with +/- to expand (rows (2 levels, Power BI opens at Vendor Name)); the Sigma pivot carries the listed levels as nested rowsBy/columnsBy and opens expanded |
| Cover: Products by cover bucket | bar-chart: Products by cover bucket | Cover – summary, Cover | built as bar-chart on page 'Cover', reading 'Cover – summary' |
| Cover: On Hand (Latest) | kpi-chart: On Hand (Latest) | Cover – summary, Cover | built as kpi-chart on page 'Cover', reading 'Cover – summary' |
| Cover: Open PO Units | kpi-chart: Open PO Units | Cover – summary, Cover | built as kpi-chart on page 'Cover', reading 'Cover – summary' |

## Slicers (3)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Cover: Vendor Country | control: Vendor Country | Sales, Inventory, Purchase Orders, Vendor, Product, SKU, Cover – summary | control wired to 7 element(s) |
| Cover: Brand | control: Brand | Sales, Inventory, Purchase Orders, Product, SKU, Cover – summary | control wired to 6 element(s) |
| Cover: Store Region | (none) |  | no control was built for this slicer |
