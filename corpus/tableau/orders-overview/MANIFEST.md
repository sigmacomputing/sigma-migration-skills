# tableau / orders-overview

The "Orders Conversion Test" (Orders Overview) Tableau workbook — the standard
Tableau→Sigma demo dashboard on the DEMO_DB.DEMO Snowflake star schema
(ORDER_FACT + CUSTOMER_DIM / PRODUCT_DIM / STORE_DIM / DATE_DIM / PROMO_DIM /
DIM_TIME). Captured 2026-06-10 from a live tableau-to-sigma skill discovery run
(synthetic demo data, a Tableau Cloud trial site).

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | Full Tableau workbook XML (federated/published-VDS datasource, calc fields, LOD, worksheets + dashboard) |
| `signals.json` | The skill's parsed discovery signals (views, fields, per-view headers) |

## Features exercised

- Federated datasource with published Virtual Connection naming
- Calculated fields incl. an LOD FIXED expression (→ child element with groupings: `Order Fact View` + `lodChildElements: 1`)
- Multi-table joins → 6 Sigma relationships
- Metric translation (Gross Margin Pct, Return Rate, Revenue Per Order + the
  d8a049a-era auto-Sum measure metrics on the fact)
- Converter warnings path (22 warnings: LOD/table-calc flags, plus the wave-2
  object-model additions — fact-election announcement naming ORDER_FACT,
  partial-wire summary for the computed-only ORDER_FACT↔DIM_TIME key,
  DIM_TIME-disconnected, and the slash-named derived-column drop warning)

## Converter

`mcp__sigma-data-model__convert_tableau_to_sigma` with
`xml_content=<workbook-content.twb>`, `datasource_index=0`, empty
connection/database/schema.

NOTE: this artifact (~204 KB) exceeds the hosted MCP server's request body
limit (HTTP 413). The golden is generated from the VENDORED bundle the skill
ships (the shipped truth, including its recorded local patches — see
`plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/PROVENANCE.json`);
last regenerated on the a later wave R3-1 role-play batch (role-played DATE_DIM
instances get deterministic role-suffixed element + relationship names —
"DATE_DIM (Return Date)" / "DATE_DIM (Ship Date)" — and the derived-view
[Base/REL/Field] refs resolve per instance instead of round-robin; prior
regen was the wave-2 object-model batch):

```
node -e 'import("file://<repo>/plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/tableau.mjs").then(m => {
  const r = m.convertTableauToSigma(require("fs").readFileSync("workbook-content.twb","utf8"), { datasourceIndex: 0 });
  console.log(JSON.stringify({ sigmaDataModel: r.model, stats: r.stats, warnings: r.warnings }, null, 2));
})'
```

For artifacts under ~100 KB, `corpus/lib/mcp_convert.py` calls the hosted MCP
endpoint directly.

## Known parity reference (live run 2026-06-10)

Strict chart parity vs Tableau view CSVs: **5/5 PASS** — Revenue by Region,
Orders by Category, Return Rate by Delivery Speed Tier, Gross Revenue by Delivery
Speed Category, Gross Margin % by Customer Value Tier. (Values drift as new
ORDER_FACT rows land; verify against the live Tableau datasource, not baked
numbers.)

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "signals.json", "format": "json"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 9,
      "columns": 229,
      "metrics": 26,
      "relationships": 6,
      "warnings": 22,
      "element_names": ["CUSTOMER_DIM", "DATE_DIM (Return Date)", "DATE_DIM (Ship Date)", "DIM_TIME", "PRODUCT_DIM", "PROMO_DIM", "STORE_DIM", "ORDER_FACT", "Order Fact View"],
      "metric_names": ["Shipping Amount", "Net Revenue", "Product Key", "Net Profit", "Unit Price", "Tax Amount", "Gross Revenue", "Ship Store Key", "Is Cancelled", "Unit Cost", "Gross Profit", "Order Store Key", "Order Line", "Quantity Ordered", "Is First Order", "Gross Margin Pct", "Return Rate", "Revenue Per Order", "Customer Key", "Return Date Key", "Days To Ship", "Is Returned", "Quantity Returned", "Promo Key", "Ship Date Key", "Discount Amount"]
    }
  }
}
```
