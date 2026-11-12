# tableau / census-derived-names

Hand-written synthetic `.twb` (invented names on a neutral demo star; no
tenant data) in the shape of the store-operations regression dashboard whose
source-object census held YELLOW after every value and visual gate passed:
a rank table calc, a boolean flag on the Color shelf, and a styled filled map.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | the synthetic workbook (3 worksheets, 1 dashboard) |
| `wb-spec.json` | the built spec as the builder names these columns (`Revenue Rank along Store Name`, hidden `Low Margin Flag (flag)`, region-map; the source's light basemap is Sigma's default, so no `mapStyle` key) |
| `chart-provenance.json` | element → source worksheet provenance (what the build writes) |
| `checks.sh` | runs the gap scan, the layout parser and the census; asserts the accounting |

## Converter

No MCP converter; pins the SKILL-script contracts (`$S` = `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts`):

```
ruby $S/scan-workbook-gaps.rb workbook-content.twb
ruby $S/parse-twb-layout.rb workbook-content.twb dashboard-layout.json
ruby $S/build-source-object-census.rb --workdir .
```

## Assertions

- Formula audit: `Revenue Rank` is `chart_only` (`Rank(Sum([Net Revenue]), "desc")`),
  `Low Margin Flag` is `spec` — neither is a converter gap.
- Census: both calcs are `migrated` against the built spec even though the
  builder names their columns `Revenue Rank along Store Name` (Tableau's CSV
  export header) and `Low Margin Flag (flag)` (the hidden conditional-format
  driver).
- Layout: the map zone carries `map_style` = light basemap, washout 0.25,
  8 color steps; the builder's style plan resolves `baseStyle: light` (Sigma's
  default basemap, so the element carries no `mapStyle` key) and names
  exactly the washout and stepped-ramp residuals (candidate catalog ids
  `map-basemap-washout`, `map-stepped-color-scale`).

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "wb-spec.json", "format": "json"},
    {"path": "chart-provenance.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
