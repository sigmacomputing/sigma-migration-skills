# jaffle-orders fixture

Hand-written, BigQuery-flavoured, jaffle-shop style offline source for
`lightdash-to-sigma` (layout per `refs/lightdash-source-contract.md`). Synthetic
data only; the project id `acme-analytics` is a placeholder.

| Feature | Where |
|---|---|
| dbt >= 1.10 `config.meta` / legacy `meta` | `dbt/models/orders.yml` / `customers.yml`, `payments.yml` |
| Joins: many-to-one left with `fields` allow-list; one-to-many | `orders.yml` `joins` |
| string / number / boolean / date dims; intervals DAY..YEAR | `orders.yml` (`order_date`) |
| Custom `sql` CASE dim; `hidden` dim; `additional_dimensions` | `orders.yml` (`channel`; `internal_notes`; `order_year_str`) |
| sum, count, count_distinct, average, min, max, median | `orders.yml`, `customers.yml`, `payments.yml` |
| Filtered metrics (equals, `'!returned'`) | `completed_orders`, `completed_amount`, `kept_amount` |
| `number` metric over metrics + percent format | `completion_rate` |
| `percent_of_total` (gap) | `pct_of_total_amount` |
| RLS `sql_filter`; column `required_attributes` | `orders.yml` (model; `margin`) |
| Relations + adapter | `dbt/target/manifest.json` |
| Bar / line / big_number / table / pie / flipped bar | `lightdash/charts/*.yml` |
| Table-calc running total (gap), sort + limit | `orders-by-region-table.yml` |
| Chart-level filter | `completed-revenue-by-region.yml` |
| Two tabs, markdown tile, 36-col grid, all-tile + `tileTargets` filters | `lightdash/dashboards/jaffle-overview.yml` |

`ruby test/test-fixture-consistency.rb` verifies every field id resolves.
