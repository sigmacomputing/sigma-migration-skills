# gooddata / orders-workspace

The `test_workspace_orders.json` fixture from the gooddata-to-sigma plugin
(referenced, not duplicated) — a GoodData Cloud declarative workspace layout
(LDM + analytics model): an ORDER_FACT dataset + CUSTOMER_DIM with a dataset
reference, 5 MAQL metrics that map cleanly, and one `BY ALL` context metric
that must be flagged rather than mis-converted.

## Converter

The **in-repo converter** (not MCP), from the plugin's scripts/ dir. Runs
offline — the warehouse path (`--db`/`--schema`) and Sigma ids are placeholders
for the regression golden:

```
cd plugins/gooddata-to-sigma/skills/gooddata-to-sigma
python3 scripts/convert.py --workspace fixtures/test_workspace_orders.json \
  --connection-id inode-CONN0000 --db DEMO_DB --schema PUBLIC \
  --folder-id inode-FOLDER00 --out model.json --flags flags.json
```

The golden wraps the emitted DM spec as `{sigmaDataModel, warnings}` (the
flagged metrics become the `warnings` list) to mirror the MCP converters' shape.
The workbook golden is emitted directly by `build_workbook.py` and locks the
released workbook-code boundary: outer metadata, nested `document`, flat
`document.elements`, metadata-only pages, and required authoritative layout.

## Features exercised

- LDM datasets → table elements (dim-before-fact); attributes/facts → columns
- dataset `reference` → relationship (CUSTOMER_DIM, many side = ORDER_FACT)
- MAQL metrics → DM metrics via `maql.py` (SUM/COUNT/ratio, recursive inlining)
- "flag, never fake": `BY ALL` context metric → 1 warning (no DM-metric equiv)
- workbook metadata/document wrapper with flat elements and metadata-only pages
- authoritative layout places every workbook element exactly once using the
  live `<Element>` / `<Container>` tags (never legacy emission aliases)
- focused released-feature regression covers native waterfall, grounded
  repeated-container, legend/style, dashboard tabs/navigation, and loud
  drill/box gaps

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/gooddata-to-sigma/skills/gooddata-to-sigma/fixtures/test_workspace_orders.json", "format": "json"},
    {"path": "../../../plugins/gooddata-to-sigma/skills/gooddata-to-sigma/fixtures/expected_flags.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 2,
      "columns": 19,
      "metrics": 5,
      "relationships": 1,
      "warnings": 1,
      "element_names": ["CUSTOMER_DIM", "ORDER_FACT"],
      "metric_names": ["Avg Order Value", "Gross Revenue", "Net Profit", "Net Revenue", "Order Count"],
      "relationship_names": ["CUSTOMER_DIM"]
    },
    "workbook.json": {}
  }
}
```
