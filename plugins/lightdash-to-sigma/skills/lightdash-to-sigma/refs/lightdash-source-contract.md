# Lightdash source contract

Reads an offline source directory (`lightdash download` output plus the dbt
project that defines the semantic layer), or discovers the same content from a
live Lightdash instance (`LIGHTDASH_URL`, `LIGHTDASH_API_KEY`) so a live run
needs no dbt checkout. Lightdash ships daily and schemas drift: consume the
keys listed below, **ignore unknown keys silently**, never fail on them.

## Offline directory layout

```
<source-dir>/
  lightdash/charts/*.yml          # `lightdash download -c` (one chart per file)
  lightdash/dashboards/*.yml      # `lightdash download -d`
  lightdash/spaces/*.space.yml    # ignored (space permissions are a gap)
  dbt/dbt_project.yml             # dbt project; model-paths default ["models"]
  dbt/models/**/*.yml             # schema files carrying Lightdash `meta:`
  dbt/target/manifest.json        # OPTIONAL; preferred relation + adapter source
```

YAML-only alternative (no dbt): `lightdash.config.yml` (`warehouse: {type: bigquery}`)
plus `models/*.yml` where each entry has `type: model`, `name`, `sql_from:
PROJ.DATASET.TABLE`, `dimensions:` (list) and `metrics:` (map). The same
field-id, join and metric rules apply; `sql_from` is the physical relation.

## Charts (`lightdash/charts/*.yml`)

Consumed: `name`, `slug`, `spaceSlug`, `description`, `tableName`,
`metricQuery.{exploreName, dimensions, metrics, filters, sorts, limit,
tableCalculations, additionalMetrics, customDimensions, pivotDimensions}`,
`chartConfig.{type, config}`, `tableConfig.columnOrder`.
Ignored: `version`, `downloadedAt`, `updatedAt`, `metricOverrides`,
`dimensionOverrides`, `timezone`, conditional formatting.

`chartConfig.type`: `cartesian` (layout `xField`, `yField[]`, `flipAxes`;
`eChartsConfig.series[].type` = `bar|line|area|scatter`), `table`,
`big_number`, `pie`. `funnel|treemap|gauge|map|sankey|custom|data_app_viz`
and `contentType: sql_chart` (no `metricQuery`) are recorded as gaps.

Filters: `metricQuery.filters` is `{dimensions|metrics: {id, and|or:
[{id, target: {fieldId}, operator, values, disabled}]}}`; a flat list of
rules is also accepted.

## Dashboards (`lightdash/dashboards/*.yml`)

Consumed: `name`, `slug`, `description`, `tabs[{uuid,name,order}]`,
`tiles[]`, `filters.{dimensions,metrics}`.
Tile: `type` (`saved_chart` -> `properties.chartSlug`; `markdown` ->
`properties.{title,content}`; `sql_chart`/other = gap), `x,y,w,h` on a
36-column grid (`LIGHTDASH_GRID_COLS = 36`, single constant), `tabUuid`
(null/absent = first tab), `tileSlug` (defaults to `chartSlug`).
Dashboard filter: `{id, target:{fieldId,tableName,fieldName}, operator,
values, disabled, tileTargets}`. Empty/absent `tileTargets` = applies to all
tiles; otherwise a map `tileSlug -> {fieldId, tableName}` (or `false` = tile
excluded); tiles not listed are filtered by default. Ignored: `config`, `downloadedAt`, `updatedAt`.

## Semantic layer (dbt `meta`)

Both forms are read; `config.meta` (dbt >= 1.10) wins over legacy `meta`, on
the model and on each column:

- Model meta: `label`, `joins`, `metrics` (model-level, usually `type: number`),
  `sql_filter` (RLS), `required_attributes`, `any_attributes`, `hidden`.
- Column meta: `dimension` (`type`, `label`, `sql`, `format`, `hidden`,
  `time_intervals`, `required_attributes`), `additional_dimensions`, `metrics`.
- Metric: `type` (count, count_distinct, sum, sum_distinct, average,
  average_distinct, min, max, median, percentile, number, string, date,
  timestamp, boolean, percent_of_previous, percent_of_total, running_total),
  `sql` (default `${TABLE}.<column>`), `label`, `format`, `filters`,
  `percentile`, `hidden`.
- Metric `filters`: list of `{dimension: value}`; value is a scalar (equals),
  a list (in), or an operator string (`'!returned'`, `'> 4'`, `'!null'`).
- Joins: `join` (model), `type` (inner|left|right|full), `sql_on`,
  `relationship` (one-to-one|one-to-many|many-to-one|many-to-many),
  `fields` allow-list / `exclusions`, `hidden`, `alias`, `label`.
- SQL refs: `${TABLE}.col` raw column; `${dim}` same-model dim;
  `${model.dim}` joined dim; `${metric}` (only `number` metrics and the
  post-calc types `percent_of_total`, `percent_of_previous`, `running_total`
  reference metrics -- a post-calc metric's `sql` is `${other_metric}`);
  `${lightdash.attributes.<attr>}` user attribute.

## Explore resolution and field ids

`metricQuery.exploreName` (== `tableName`) is a dbt **model name**; that model
is the explore's base table and its `joins` (one level) are the joined tables.
A field id is `<table>_<field>`: `orders.amount` -> `orders_amount`. A `date`
or `timestamp` dimension with `time_intervals` (default `[DAY, WEEK, MONTH,
QUARTER, YEAR]`, `RAW` allowed, `OFF` disables) exists **only** as interval
fields `<table>_<field>_<interval lowercase>`
(`orders_order_date_month`); the bare id is not a field. Joined tables use
their own name (`customers_segment`), restricted by the join `fields`
allow-list (matched on base field name) or `exclusions`. Table calculations
are addressed by bare `name`, and `tableConfig.columnOrder` may name them.
In table-calc SQL a field is `${orders.order_date_month}` (dot form).

## Relation resolution (physical table per model)

1. `dbt/target/manifest.json` `nodes["model.<project>.<name>"].relation_name`
   (BigQuery `` `proj`.`dataset`.`table` ``; quotes stripped, split on `.`).
2. Model `config.database` / `config.schema` / `config.alias` (or the
   manifest node's `database` / `schema` / `alias`).
3. `<--default-database>.<--default-schema>.<model name>`.

## Dialect resolution

1. `manifest.metadata.adapter_type` -> 2. `lightdash.config.yml`
`warehouse.type` -> 3. `--dialect` flag. No answer = stop and ask; never guess.

## Live discovery (replaces the offline directory)

| Offline input | Live endpoint (`<url>/api/v1/projects/{p}`, `Authorization: ApiKey <pat>`) |
|---|---|
| `lightdash/charts/*.yml` | `GET /charts/code` |
| `lightdash/dashboards/*.yml` | `GET /dashboards/code` |
| `dbt/models/**` + manifest | `GET /explores` and `GET /explores/{exploreId}` (`baseTable`, `joinedTables`, `tables.<t>.{dimensions,metrics,sqlTable,database,schema}`, `warehouse`) |

Responses are wrapped `{status: "ok", results: ...}`. Compiled-SQL oracle:
`POST /explores/{id}/compileQuery`; row oracle: `POST /explores/{id}/runQuery`
(row shape unverified: parse defensively).

## Gaps (warn, never guess)

SQL table calcs (raw warehouse SQL, windows) · formula table calcs
(`=RANK(...)`) · template quick calcs · parameters
(`${lightdash.parameters.x}`) · custom Vega charts · map / treemap / gauge /
sankey charts · SQL Runner charts · post-calc metrics (`percent_of_total`,
`running_total`, `percent_of_previous`) · period-over-period additionalMetrics
(`generationType: periodOverPeriod`) · conditional formatting · Liquid URLs ·
scheduled deliveries · space permissions.
