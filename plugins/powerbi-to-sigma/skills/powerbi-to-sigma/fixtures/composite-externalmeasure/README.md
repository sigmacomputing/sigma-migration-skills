# composite-externalmeasure (synthetic)

A made-up composite Power BI model, in the shape `scripts/extract-model-pbix.py`
emits for a report that uses DirectQuery to two published semantic models
(issue sigmacomputing/sigma-migration-skills#97). Every name is invented.

- `Harbor Sales` is a remote proxy table: its partition is an `entity` partition
  (`entityName` = the table in the remote model, `expressionSource` = the
  `DirectQuery to AS - Harbor Sales Model` shared expression), the shape a
  Fabric `model.bim` has and the extractor now emits. Its rows live in the
  remote model, not in any warehouse table. Two of its measures are
  `EXTERNALMEASURE(...)` pointers (their DAX lives in the remote models); the
  third (`Remote Revenue K`) is built on a pointer on the same table.
- `model.expressions` maps each `DirectQuery to AS - <model>` connection to
  `AnalysisServices.Database("powerbi://.../<workspace>", "<model>")`.
- `Targets` is a local table with one local measure (`Total Target`), two
  measures built on a pointer (`Revenue vs Target`, then `Revenue Gap`) and one
  built on the remote table (`Remote Order Count` = `COUNTROWS('Harbor Sales')`).
  The vendored converter drops the cross-table ones (a metric cannot reference
  another element's metric), so they are reported as gaps without being in the
  model.
- `report.json` is a classic report layout with one card per measure.

Used by `scripts/test-external-measure.rb`.
