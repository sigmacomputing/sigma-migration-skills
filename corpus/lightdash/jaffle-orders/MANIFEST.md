# lightdash / jaffle-orders

Synthetic BigQuery-flavoured Lightdash project (dbt `orders` / `customers` /
`payments` with `meta`) and a two-tab dashboard (six charts, a markdown tile,
an all-tile region filter and a `tileTargets`-limited segment filter).
Exercises 3-part BigQuery relations with preserved case, interval date
dimensions, filtered / ratio / `percent_of_total` (gap) metrics, a many-to-one
and a one-to-many join, an RLS `sql_filter` plus column `required_attributes`,
bar / line / big-number / table / donut tiles, and a running-total table calc
(gap). No tokens, no customer data.

## Artifacts

Plugin fixtures under `plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/`.

## Converter

```bash
ruby scripts/convert-dm.rb --source-dir fixtures/jaffle-orders --explore orders \
  --connection-id fixture-connection --out dm.json
ruby scripts/build-lightdash-workbook.rb \
  --dashboard fixtures/jaffle-orders/lightdash/dashboards/jaffle-overview.yml \
  --charts-dir fixtures/jaffle-orders/lightdash/charts \
  --dm-envelope dm.json --field-map field-map.json --dm-id fixture-dm \
  --folder-id fixture-folder --out wb.json --workbook-map-out workbook-map.json
```

Run from the `lightdash-to-sigma` skill directory. `checks.sh` byte-diffs both
goldens after id normalization and exercises the RLS gate (exit 2 without
`--ack`, then the plan).

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/dbt/dbt_project.yml", "format": "yaml"},
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/dbt/models/orders.yml", "format": "yaml"},
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/dbt/models/customers.yml", "format": "yaml"},
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/dbt/models/payments.yml", "format": "yaml"},
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/dbt/target/manifest.json", "format": "json"},
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/explores/orders.json", "format": "json"},
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/lightdash/dashboards/jaffle-overview.yml", "format": "yaml"},
    {"path": "../../../plugins/lightdash-to-sigma/skills/lightdash-to-sigma/fixtures/jaffle-orders/lightdash/charts/monthly-revenue.yml", "format": "yaml"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 4,
      "columns": 60,
      "metrics": 13,
      "relationships": 2,
      "warnings": 5,
      "element_names": ["orders", "customers", "payments", "Orders (Explore)"],
      "relationship_names": ["Customers", "Payments"]
    },
    "workbook.json": {
      "pages": 3,
      "elements": 11,
      "columns": 22,
      "metrics": 0,
      "relationships": 0,
      "warnings": 4,
      "element_names": ["Lightdash Data", "Lightdash Base 1", "Region", "Customer Segment", "About this dashboard", "Total Orders", "Monthly Revenue", "Revenue by Customer Segment", "Revenue by Region and Month", "Payments by Method", "Completed Revenue by Region"]
    }
  }
}
```
