# page-facts fixture (synthetic)

An invented retail star used by the page-fact and slicer-gate tests and by the
`corpus/powerbi/page-facts-multipage` case. No customer names or data.

- `model.bim`: 8 tables (Sales and Stock facts; Calendar, Store, Manager, Product, Supplier dims;
  a Rollup bridge with an INACTIVE Sales -> Rollup relationship that measures switch on with
  USERELATIONSHIP), 15 measures (additive, ratio, VAR/RETURN, CALCULATE filter, ISBLANK filter,
  DISTINCTCOUNT, time intelligence, USERELATIONSHIP).
- `signals.json`: three pages. *Sales Overview* (one fact; per-visual; a visual-level "Region is not
  blank" filter), *Stock Cover* (two facts in one pivot; a page-level Supplier filter; a Region and a
  two-hop Manager slicer the page fact does not carry), *Rollup*
  (USERELATIONSHIP: a Supplier slicer must reach Sales through the bridge, not the direct
  Product relationship).
- `dm-spec.json` / `master-map.json`: one Custom SQL element and master per table, plus a
  converter-style joined "Sales View" (with alternates) so the per-visual page builds cleanly.
- `seed.sql`: SQLite rows, with a NULL and an unmatched store key, a NULL manager name, a NULL
  category and a product missing from the bridge, so (Blank) handling is exercised.
