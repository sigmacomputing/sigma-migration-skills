# Limits of this migration

## Bidirectional and many-to-many relationships

None in this model.

## Slicers not applied, and unreached slicers

- Unreached: slicer Vendor Country (CvVendorCountry) column Vendor.Vendor Country: column 'Vendor.Vendor Country' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead

## Optional customer step: Custom SQL as views

Where a customer wants a Custom SQL source to be a warehouse view instead, create it once and point the data model element at it. Replace `<TARGET_SCHEMA>` with the schema to create the views in.

```sql
CREATE OR REPLACE VIEW <TARGET_SCHEMA>.COVER_BUCKET AS
SELECT 'Under 7 days' AS "Bucket", 0 AS "Min Days", 7 AS "Max Days", 1 AS "Sort" UNION ALL SELECT '7 to 14 days', 7, 14, 2 UNION ALL SELECT '14 to 28 days', 14, 28, 3 UNION ALL SELECT '28 days or more', 28, 100000, 4;
```
