# Inventory and Purchasing (views shape): run notes

Final run exit 0 only with `--allow-field-loss`. 0 of the 4 data visuals were built (pivot, bar and both KPIs dropped: their measures and fields did not bind to a master column in the views
shape: no DAX translation of the Inventory measures); the Vendor Country slicer is unreached (`Vendor.Vendor Country` resolves to no master column).
Brand and Store Region controls exist; 4 hidden master tables, a page notice "4 visual(s) on this page could not be migrated". Parity: nothing to compare.
This is origin/main views behavior (not fixed; out of scope).
The first views attempt stopped at the calculated-table gate (the pinned converter flattened the DATATABLE `Cover Bucket` into one column); fixed in the
plugin (see the task report), and the final run needed no override.
