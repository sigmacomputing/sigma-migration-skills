# tableau / fixed-lod-dimension

Hand-written minimal `.twb` (synthetic Customer Id / Order Date / Loyalty Tier /
Region; no tenant data) plus the mechanical workbook spec it produces BEFORE the
helper pass (`wb-spec.pre.json`: per-page masters, a Region control, and the
cohort pivot whose row reads `[Master/Cohort Year]`, a column no master has).

The shape is the live-proof sheet that stopped every run at the exit-4 handoff:
`Cohort Year = {FIXED [Customer Id] : MIN(YEAR([Order Date]))}` used as the ROW
dimension of a pivot (cols Loyalty Tier, COUNTD Customer Id).

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | the synthetic workbook (1 pivot worksheet, 1 dashboard) |
| `wb-spec.pre.json` | the mechanical workbook spec before the FIXED-LOD dimension pass |
| `dm-ids.json`, `metrics.json` | offline DM context for validate-spec / the ref gate |
| `control-scope.json` | the Region control's scope for control lint |
| `wb-spec.expected.json` | PINNED output of `apply-lod-dim-helpers.rb` |
| `checks.sh` | regenerates the output, compares to the pin as parsed JSON, runs the gates |

## Converter

No MCP converter; pins the SKILL-script contracts (`$S` = `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts`):

```
ruby $S/parse-twb-layout.rb workbook-content.twb dashboard-layout.json
ruby $S/apply-lod-dim-helpers.rb --workdir . --spec wb-spec.pre.json --out wb-spec.json
```

## Assertions

- A grouped helper `lod-cohort-year-helper` (groupBy Customer Id,
  `Min([Cohort Year Base])` over `Year([Fact View/Order Date])`) sits on the
  Data page right after its master and before the pivot; it reads the master's
  data-model element directly (unfiltered: Tableau computes FIXED before
  dimension filters).
- The pivot row becomes `Lookup([Cohort Year Helper/Cohort Year],
  [Master/Customer Id], [Cohort Year Helper/Customer Id])` and stays on its
  control-filtered master, so control lint stays clean (no partial control).
- `validate-spec.rb` reports 0 errors, the ref gate PASSes (the pre spec FAILs
  on Cohort Year: the exit-4 case), `audit-lod-calcs.rb` classifies Cohort Year
  `lod-synth`.
- An authored helper the layout leaves unplaced keeps its document position and
  is placed on the Data page (not inferred onto a dashboard page).
- The gap scan's formula audit reclassifies the converter's refusal of Cohort
  Year to `chart_only` (translator `lod_dim_helper`, sheet Customer Cohorts) and
  raises no converter-refused gap; the source-object census then accounts Cohort
  Year `migrated` against the helper-built spec and a passing parity (the
  Retail Command Center regression held YELLOW on this needs-review).

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "wb-spec.pre.json", "format": "json"},
    {"path": "dm-ids.json", "format": "json"},
    {"path": "metrics.json", "format": "json"},
    {"path": "control-scope.json", "format": "json"},
    {"path": "wb-spec.expected.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
