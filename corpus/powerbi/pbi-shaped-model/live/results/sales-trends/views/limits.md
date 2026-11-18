# Limits of this migration

## Bidirectional and many-to-many relationships

None in this model.

## Slicers not applied, and unreached slicers

- Unreached: slicer Year (TrYear) column Date.Year: column 'Date.Year' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead
- Unreached: slicer Year (RoYear) column Date.Year: column 'Date.Year' resolves to no master column (master=nil); dropped loudly rather than wired to a wrong column or shipped dead

## Optional customer step: Custom SQL as views

Where a customer wants a Custom SQL source to be a warehouse view instead, create it once and point the data model element at it. Replace `<TARGET_SCHEMA>` with the schema to create the views in.

No Custom SQL sources in this model.
