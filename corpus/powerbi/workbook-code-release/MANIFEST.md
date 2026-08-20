# powerbi / workbook-code-release

Synthetic offline regression for the August 2026 Power BI workbook-as-code
release. It exercises the Power BI workbook builder directly with a stable
master map and source signals.

## Features exercised

- Outer workbook metadata plus `document:{schemaVersion,kind,pages,elements,layout}`
- Metadata-only pages, flat elements, and layout-authoritative membership
- Live canonical `<Element>` layout tags (`<Container>` for nested layouts)
- Native waterfall and ring progress elements
- Native drill control from a complete Power BI chart hierarchy
- Native legend control from a visible categorical legend binding
- Source-proven page navigation and list slicer
- Explicit absence of unsupported box charts and unproven tabs, page breaks,
  panels, and repeaters

## Converter

```shell
ruby plugins/powerbi-to-sigma/skills/powerbi-to-sigma/scripts/build-workbook-from-pbir.rb \
  --signals corpus/powerbi/workbook-code-release/signals.json \
  --master-map corpus/powerbi/workbook-code-release/master-map.json \
  --data-model dm-release --layout pbi \
  --name "Power BI Workbook Code Release" \
  --out /tmp/powerbi-workbook-code.json
```

`checks.sh` rebuilds the workbook byte-for-byte, validates it with the plugin
validator, and asserts the release shape and native control wiring.

## Expectations

```json
{
  "artifacts": [
    {"path": "signals.json", "format": "json"},
    {"path": "master-map.json", "format": "json"},
    {"path": "checks.sh", "format": "text"},
    {"path": "check_workbook.py", "format": "text"}
  ],
  "goldens": {
    "workbook.json": {}
  }
}
```
