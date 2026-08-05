# Column-name alignment — the crux of a remap-free repoint

For the converted Sigma data model to resolve against the landed tables with **no
remapping**, the warehouse column names must exactly match what the
`powerbi-to-sigma` converter emits.

The converter uses two different conventions (see `sigma-ids.js` in the converter):

- **Columns** → `sigmaPhysicalName`: camelCase / acronym / digit boundaries become
  `_`, then uppercased; a name that is already `[A-Z0-9_]+` passes through verbatim.
  - `LocationID` → `LOCATION_ID`
  - `City Name` → `CITY_NAME`
  - `Sum_GrossMarginAmount` → `SUM_GROSS_MARGIN_AMOUNT`
  - `DM` → `DM` (already canonical)
- **Tables** → plain `.toUpperCase()` (no snake-casing).

This tool replicates `sigmaPhysicalName` for column names (`sigma_physical_name`
in the script) so the two agree byte-for-byte. If you change the converter's
normalization, change it here too, or the DM POST will fail with
`Source not found` / columns won't resolve.

**Caveat:** a Power BI table name containing spaces would produce an invalid
Snowflake identifier under plain `.toUpperCase()`. Single-token / no-space table
names (the common case) are fine. For spaced table names, rename before landing.
