# sisense / ecommerce-smoke

The plugin's existing, sanitized Sample ECommerce discovery fixtures: one
four-table model (17 columns and three relations) plus two dashboards containing
24 widgets and two filters. The case references those fixtures in place rather
than duplicating them.

## Artifacts

| File | What it is |
|---|---|
| `plugins/.../fixtures/model_ecommerce.json` | Sisense model schema export with datasets, tables, columns, and relations |
| `plugins/.../fixtures/dashboards.json` | Inlined dashboards, widgets, filters, JAQL, and layouts |
| `checks.sh` | Offline scan, model/dashboard conversion, layout gate, and byte-golden checks |

## Features exercised

- structured gap census for every model table/column/relation and every
  dashboard/widget/filter
- deterministic `gap-report.json`, including manual treemap/sunburst and
  flagged map evidence
- model conversion with harvested governed metrics and three relationships
- dashboard conversion across KPI, bar, line, area, pie, scatter, grouped
  pivot/table, filters-to-controls, and unsupported-widget omission
- authoritative layout verification for every converted widget
- id-normalized data-model and workbook goldens

## Converter

`checks.sh` runs the in-repo Python CLI offline. It seeds the converter's random
client ids before each CLI invocation, then applies the ordinary corpus
normalizer:

```sh
bash corpus/sisense/ecommerce-smoke/checks.sh
./corpus/run-corpus.sh --check sisense
```

Equivalent scanner invocation:

```sh
python3 plugins/sisense-to-sigma/skills/sisense-to-sigma/scripts/scan_gaps.py \
  plugins/sisense-to-sigma/skills/sisense-to-sigma/fixtures/dashboards.json \
  --model plugins/sisense-to-sigma/skills/sisense-to-sigma/fixtures/model_ecommerce.json \
  --out gap-report.json
```

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/sisense-to-sigma/skills/sisense-to-sigma/fixtures/model_ecommerce.json", "format": "json"},
    {"path": "../../../plugins/sisense-to-sigma/skills/sisense-to-sigma/fixtures/dashboards.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 4,
      "columns": 17,
      "metrics": 5,
      "relationships": 3,
      "warnings": 0,
      "element_names": ["Country", "Category", "Brand", "Commerce"],
      "metric_names": ["Distinct Brands", "Total Revenue", "Total Quantity", "Avg Order Value", "Revenue per Unit"],
      "relationship_names": ["CATEGORY", "COUNTRY", "BRAND"]
    },
    "workbook.json": {
      "pages": 2,
      "elements": 24,
      "columns": 51,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0
    },
    "gap-report.json": {}
  }
}
```
