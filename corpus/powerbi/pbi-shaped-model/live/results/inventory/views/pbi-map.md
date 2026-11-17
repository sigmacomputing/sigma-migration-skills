# Power BI to Sigma map


## Tables (9)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Date | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Vendor | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Product | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| SKU | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Store | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Sales | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Inventory | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Purchase Orders | (none) |  | no data model element carries this table (not used by the report, or read through another element) |
| Cover Bucket | table: Cover Bucket | Cover Bucket | carried as data model element 'Cover Bucket' |

## Relationships (12)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Sales -> Date (Sales_OrderDate) | (none) |  | no matching relationship on the data model elements |
| Sales -> Date (Sales_ShipDate) [inactive] | (none) |  | no matching relationship on the data model elements |
| Sales -> SKU (Sales_SKU) | (none) |  | no matching relationship on the data model elements |
| Sales -> Store (Sales_Store) | (none) |  | no matching relationship on the data model elements |
| SKU -> Product (SKU_Product) | (none) |  | no matching relationship on the data model elements |
| Product -> Vendor (Product_Vendor) | (none) |  | no matching relationship on the data model elements |
| Inventory -> Date (Inventory_Date) | (none) |  | no matching relationship on the data model elements |
| Inventory -> SKU (Inventory_SKU) | (none) |  | no matching relationship on the data model elements |
| Inventory -> Store (Inventory_Store) | (none) |  | no matching relationship on the data model elements |
| Purchase Orders -> Date (PO_OrderDate) | (none) |  | no matching relationship on the data model elements |
| Purchase Orders -> Date (PO_ExpectedDate) [inactive] | (none) |  | no matching relationship on the data model elements |
| Purchase Orders -> SKU (PO_SKU) | (none) |  | no matching relationship on the data model elements |

## Measures (5)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Inventory.On Hand (Latest) | (none) |  | no data model metric or column of that name; the measure is not carried |
| Inventory.Open PO Units | (none) |  | no data model metric or column of that name; the measure is not carried |
| Inventory.Sales R28 Units | (none) |  | no data model metric or column of that name; the measure is not carried |
| Inventory.Days of Cover | (none) |  | no data model metric or column of that name; the measure is not carried |
| Inventory.Products by Cover Bucket | (none) |  | no data model metric or column of that name; the measure is not carried |

## Visuals (4)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Cover: Vendor and Product: on hand, open POs, sales R28, cover | (none) |  | degraded: sort field 'Vendor.Vendor Name' is not among the built columns — sort skipped; dropped: field(s) On Hand (Latest), Open PO Units, Sales R28 Units, Days of Cover could not be resolved to a master column — dropped (would have shipped as a type=error column); dropped: pivot-table has no values — held back (its measures did not bind to the page's data) |
| Cover: Products by cover bucket | (none) |  | dropped: field(s) Products by Cover Bucket could not be resolved to a master column — dropped (would have shipped as a type=error column); dropped: bar-chart has no measure on its yAxis — held back (its measures did not bind to the page's data) |
| Cover: On Hand (Latest) | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |
| Cover: Open PO Units | (none) |  | dropped: kpi-chart has no resolvable master element — element skipped |

## Slicers (3)

| Power BI | Sigma | Homes | Reason |
|---|---|---|---|
| Cover: Vendor Country | (none) |  | column 'Vendor.Vendor Country' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead |
| Cover: Brand | control: Brand | DIM_PRODUCT View | control wired to 1 element(s) |
| Cover: Store Region | control: Store Region | Store, FACT_SALES View, FACT_INVENTORY View | control wired to 3 element(s) |
