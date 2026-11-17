# powerbi / pbi-shaped-model

Freezes the offline output of the opt-in **Power BI-shaped mode** (`--model-shape pbi`) of
powerbi-to-sigma on the synthetic retail **Sales** model (invented names, no customer data, no live
tenant). The mode keeps Power BI table, column and measure names visible in the Sigma data model, puts
the warehouse shaping behind them, and builds the workbook straight on the data model. Rules and limits:
`plugins/powerbi-to-sigma/skills/powerbi-to-sigma/refs/pbi-shaped-model.md`.

## What runs

`checks.sh` calls `drive.rb`, which runs the real `migrate-powerbi.rb --model-shape pbi` with a stub in
place of Sigma's HTTP layer (no network, no credentials; every `SIGMA_*` variable is unset). The key
uniqueness check and the slicer-carry sizes are replayed from the fixture's `shape-probe-results.json`.
The run covers the shaped data model, the direct master map built on a faked data model readback, and
the builder with `--direct-sources`. It ends at the stubbed, refused workbook POST (exit 4 by design),
after the workbook spec is built, validated and linted. `pbi-shaped-report.rb` then writes the map and
limits files.

Pinned by `checks.sh`: the data model spec, the direct master map and the workbook spec (all normalized
with `lib/corpus_check.py normalize`, which rewrites generated ids to positional tokens), plus
`pbi-map.json`, `pbi-map.md` and `limits.md` as written. `validate-spec.rb` runs on both specs and
`preflight_lint.rb` on the workbook; the workbook must have no Data page.

Regenerate after an intended change with `bash corpus/powerbi/pbi-shaped-model/checks.sh --update`
and review the diff.

The golden data model carries a `DIM_VENDOR` element. That is an artifact of the full-model converter fixture
(`dm-raw`): in a real run Vendor is scoped out when no visual, slicer or measure reads it, so the element does not
appear. It is pinned here only because the fixture's converter output includes it.

## Inputs

The model, the converter output, the report layout and the probe replay live in the plugin's
`fixtures/pbi-shaped/sales/`. The PBIR bundle is the generated report in `out/retail-sales/`. The other
directories here (`src/`, `out/`, `probes/`, `tools/`, `live/`) are the fixture generator, the probes
behind the fallbacks and the Fabric verification tooling; `checks.sh` does not run them.

## Expectations

```json
{
  "artifacts": [
    {
      "path": "checks.sh",
      "format": "text"
    },
    {
      "path": "drive.rb",
      "format": "text"
    },
    {
      "path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/pbi-shaped/sales/model.bim",
      "format": "json"
    },
    {
      "path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/pbi-shaped/sales/dm-raw.json",
      "format": "json"
    },
    {
      "path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/pbi-shaped/sales/signals.json",
      "format": "json"
    },
    {
      "path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/pbi-shaped/sales/signals-trends.json",
      "format": "json"
    },
    {
      "path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/pbi-shaped/sales/shape-probe-results.json",
      "format": "json"
    },
    {
      "path": "out/retail-sales/report-bundle.json",
      "format": "json"
    },
    {
      "path": "golden/dm-spec.json",
      "format": "json"
    },
    {
      "path": "golden/master-map.json",
      "format": "json"
    },
    {
      "path": "golden/workbook.json",
      "format": "json"
    },
    {
      "path": "golden/pbi-map.json",
      "format": "json"
    },
    {
      "path": "golden/pbi-map.md",
      "format": "text"
    },
    {
      "path": "golden/limits.md",
      "format": "text"
    }
  ],
  "goldens": {
    "dm-spec.json": {
      "elements": 15,
      "relationships": 12,
      "pages": 2,
      "element_names": [
        "Date",
        "Category",
        "Product",
        "SKU",
        "Customer",
        "Store",
        "Sales (source)",
        "Sales",
        "Sales – rolling 28 days by day",
        "Sales by quarter (quarter reset)",
        "Sales by quarter",
        "Sales by month (month reset)",
        "Sales by month",
        "As Of",
        "DIM_VENDOR"
      ]
    },
    "workbook.json": {
      "elements": 60,
      "pages": 5
    }
  }
}
```
