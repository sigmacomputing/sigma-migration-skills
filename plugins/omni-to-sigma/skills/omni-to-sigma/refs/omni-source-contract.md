# Omni source contract

Reads an offline model directory plus one dashboard JSON, or discovers both
from a live Omni instance (`OMNI_BASE_URL`, `OMNI_API_TOKEN`) via
`scripts/omni-discover.rb`.

## Model directory

Git-synced or `GET /api/v1/models/{id}/yaml?mode=combined` files:

| File | Role |
|---|---|
| `*.view` / `*.view.yaml` | Dimensions and measures (`schema`, `table_name` / `sql_table_name`, `extends:`, `aliases:`). View name is the `Reference this view as` comment, else the file stem. |
| `*.topic` / `*.topic.yaml` | `base_view`, `label`, `extends:`, recursive `joins`, `fields:` curation, `access_filters`. |
| `relationships.yaml` | `join_from_view`, `join_to_view`, `join_to_view_as`, `on_sql`, `relationship_type`, `reversible`. |
| `model.yaml` | `access_grants`, `default_topic_access_filters`. |
| `*.query.view` | Recorded and skipped. Not inlined. |

### Dimensions & Measures

- `${view.field}`, `${view.field[timeframe]}`, and intra-view `${field}` references resolve to Sigma columns, including view/field `aliases:`.
- Dimension `groups:` compile to Sigma `If(...)` / `In(...)` expressions (supporting `else:` and `else_raw_value: true`).
- Dimension `bin_boundaries:` compile to bucketed Sigma `If(...)` expressions.
- SQL expressions support `CASE WHEN ... THEN ... ELSE ... END`, Postgres/Snowflake `::type` casts, `CONCAT`, `COALESCE`, `NULLIF`, `LOWER`, `UPPER`, `TRIM`, `ROUND`, `FLOOR`, `CEIL`, `ABS`, `LEN`, `SUBSTR`, `DATEDIFF`, `DATE_TRUNC`, and `IS [NOT] NULL`.
- `aggregate_type` of `sum`, `count`, `count_distinct`, `average`, `min`, `max`, `median`, `list`, `percentile` (and `*_distinct_on` variants) becomes a Sigma metric.
- Measure `filters:` (`is`, `not`/`is_not`, `greater_than`, `less_than`, `between`, `contains`, `starts_with`, `ends_with`, `is_empty`, `null`) compile to conditional Sigma aggregates (`SumIf`, `CountIf`, `CountDistinctIf`, `AvgIf`, `MinIf`, `MaxIf`).
- A measure with no `aggregate_type` whose SQL is arithmetic over other measures becomes a derived/ratio metric (`NullIf`).
- `omni_dimensionalize`, Mustache `{{ omni_attributes.* }}`, and `DO NOT PARSE` are skipped with a warning.

### Relationships & Topics

- `on_sql` supports single or compound (`AND`) `${a.f} = ${b.g}` equalities.
- `many_to_one` / `assumed_many_to_one` → `N:1`, `one_to_one` → `1:1`, `one_to_many` → `1:N`, `many_to_many` → `N:N`.
- `reversible: false` stays one-directional and is warned; reversible relationships whose `join_to_view` is the topic's `base_view` orient from the base view with inverted cardinality.
- Topic `fields:` curation applies Omni's 5-level selector precedence (`all_views.*` → `view.*` → `tag:<t>` → `view:tag:<t>` → `view.field`, with `-` exclusions) to the topic explore element.
- Workbook-level extensions in `dashboard-export.json` (`workbookModel`) merge into the shared model when `--export` is passed to `convert-dm.rb`.

## Dashboard export

`GET /api/unstable/documents/{id}/export` (`exportVersion` `"0.1"`) or the
v2 envelope. The normalizer (`scripts/lib/omni_export.rb`) accepts:

- `dashboard.queryPresentationCollection.queryPresentationCollectionMemberships[].queryPresentation` (with `query.queryJson`, `miniUuid`, `queryIdentifierMapKey`, `prefersChart`, and `visConfig.spec` mark inference)
- `queryPresentations` as an array or `{data, order}` on `dashboard`, `dashboard.metadata`, `workbook`, or the top level
- `dashboard.metadata.layouts.lg` items `{i,x,y,w,h}` matched by `id`, `miniUuid`, or `queryIdentifierMapKey` (12-col boards scale ×2 onto Sigma's 24-col grid)
- `filterConfig` (including `dashboard.queryPresentationCollection.filterConfig` and `filterOrder`) plus `dashboard.metadata.tileFilterMap`
- `document.name` / `document.identifier`

A `tileFilterMap` value of `false` means that tile does not listen. Controls
are suppressed in that case because every chart shares one data element and a
shared filter cannot exclude one tile; the exclusion is written to
`filter-gaps.json`.

Spreadsheet `fileUploads` are ignored.

## Query oracle & Parity

`scripts/omni-query-oracle.rb` writes one `POST /api/v1/query/run` body per
tile. `scripts/verify-omni-parity.rb` compares Sigma chart exports against
Omni `query/run` responses (or offline fixtures) and writes `parity-final.json`.
