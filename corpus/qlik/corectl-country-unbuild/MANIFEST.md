# qlik / corectl-country-unbuild

Synthetic standard corectl full-property-tree export. It reproduces two failure
classes without any customer identifiers or credentials: empty master-item files
despite two inline sheet visuals under recursive `qChildren`, and a calculated
`If(Match(...)) AS REGION_GROUP` LOAD field used by a chart.

## Features exercised

- Recursive corectl sheet/object normalization into `charts.json` and `layout.json`
- Empty master `measures.json` / `dimensions.json` without an empty workbook
- Qlik `If(Match(...))` to SQL `CASE WHEN ... IN (...)`
- Pre-write workbook source coverage (2 authored visuals -> 2 queryable elements)
- Dry-run rejection of a hidden-Data-page-only workbook
- Sigma REST connection-catalog preflight through an offline injected seam

## Converter

No converter golden is stored. `checks.sh` executes the plugin's offline regression
tests, including the vendored converter through the one-command dry-run.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/fixtures/corectl-country-unbuild/corectl.yml", "format": "text"},
    {"path": "../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/fixtures/corectl-country-unbuild/script.qvs", "format": "text"},
    {"path": "../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/fixtures/corectl-country-unbuild/measures.json", "format": "json"},
    {"path": "../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/fixtures/corectl-country-unbuild/dimensions.json", "format": "json"},
    {"path": "../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/fixtures/corectl-country-unbuild/app-properties.json", "format": "json"},
    {"path": "../../../plugins/qlik-to-sigma/skills/qlik-to-sigma/fixtures/corectl-country-unbuild/objects/sheet-country-overview.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
