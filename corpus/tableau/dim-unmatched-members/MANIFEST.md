# tableau / dim-unmatched-members

Synthetic data-model readback (Order Fact → Store Dim relationship, the fact's
view element), its metrics, four worksheet CSVs, chart provenance and the
mechanical workbook spec BEFORE the unmatched-member pass (`wb-spec.pre.json`:
one fact-rooted master, a Store Type control and four tiles). No tenant data.

The shape is the local A+B regression: Tableau's relationship model keeps a
dimension member with NO fact rows (Phoenix Outlet / AZ, 0 orders) in every
tile keyed by STORE_DIM fields, the fact-rooted Sigma master dropped it.

## Artifacts

| File | What it is |
|---|---|
| `dm-readback.json` | the data-model readback (doubles as the offline DM context for validate-spec / the ref gate) |
| `metrics.json` | the DM metrics the tiles reference (`Total Net Revenue`, `Orders`) |
| `chart-provenance.json`, `get-workbook.json`, `views/*.csv` | tile → worksheet → Tableau view CSV |
| `control-scope.json` | the Store Type control's scope for control lint |
| `wb-spec.pre.json` | the mechanical workbook spec before the pass |
| `wb-spec.expected.json` | PINNED output of `apply-dim-preserve.rb` |
| `checks.sh` | regenerates the output, compares to the pin as parsed JSON, runs the gates |

## Converter

No MCP converter; pins the SKILL-script contract (`$S` = `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts`):

```
ruby $S/apply-dim-preserve.rb --workdir . --spec wb-spec.pre.json --out wb-spec.json
```

## Assertions

- Store State Map (long Measure Names/Values CSV: AZ blank revenue, 0 orders)
  and Store Scorecard (wide CSV: Phoenix Outlet blank, 0) are re-based on
  `master-stores-keep-store-dim` = Store Dim LEFT-OUTER JOIN Order Fact View on
  `Store Key = Order Store Key`, placed right after the master. Store columns
  read Store Dim, measures read the fact leg (null / CountDistinct 0 for an
  unmatched store — what the CSV shows). DM metrics are inlined.
- Revenue by Ship Method (a fact-table dimension; its 0 row is a real member)
  and Revenue by Store Type (related dimension, every member matched) stay on
  the master.
- The Store Type control also filters the clone; control lint is clean.
- `validate-spec.rb` reports 0 errors and the ref gate PASSes.
- Re-running the pass on its own output changes nothing.

## Expectations

```json
{
  "artifacts": [
    {"path": "dm-readback.json", "format": "json"},
    {"path": "metrics.json", "format": "json"},
    {"path": "chart-provenance.json", "format": "json"},
    {"path": "get-workbook.json", "format": "json"},
    {"path": "views/v-state-map.csv", "format": "text"},
    {"path": "views/v-scorecard.csv", "format": "text"},
    {"path": "views/v-ship.csv", "format": "text"},
    {"path": "views/v-type.csv", "format": "text"},
    {"path": "control-scope.json", "format": "json"},
    {"path": "wb-spec.pre.json", "format": "json"},
    {"path": "wb-spec.expected.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
