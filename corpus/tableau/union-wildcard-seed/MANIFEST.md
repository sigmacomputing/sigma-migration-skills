# tableau / union-wildcard-seed

W2.16 fixture: union datasource emission + the named-refusal stopgap. Before
W2.16 a unioned Tableau datasource converted to **nothing, silently** — the
worst defect class under the program's rules (verified 0 union hits in the
converter). A synthetic (neutral-name) workbook with one root-level
same-connection wildcard union (`SALES_2023` + `SALES_2024`, 3 shared columns,
a `Sheet` bookkeeping column that must be excluded, one currency-formatted
measure).

Emission shape per `plugins/sigma-authoring/skills/sigma-data-models/reference/sources.md`
"Union" (live-verified constraints):

- one intermediate **warehouse-table element per member** — union `sources`
  are **elementId-based** (direct `warehouse-table` entries fail on
  special-char columns);
- the union element carries **no `name`** (an explicit name breaks
  self-referential column validation; the API auto-names it
  `"Union of N Sources"`) — its column formulas use that prefix;
- `matches[].sourceColumns` entries are **bracketed friendly names**
  (`"[Order Id]"`, not raw `ORDER_ID`) resolved within each member element's
  own column set (member columns carry explicit `name` to pin resolution);
- members are pushed **first** and the union element **last** (last-writer-wins
  display-name resolution), while `factEl` selection prefers a union source —
  so translated calcs and auto-metrics attach to the stacked rows, not one
  member (pinned here: the `Net Revenue` metric lands on the union element).

Underivable shapes are **refused loudly**: named ⚠ warning, NO elements
emitted, and `scan-workbook-gaps.rb` reports the ❌-unhandled
`Union datasource (underivable / nested — NOT converted)` row (exit-11 stop
path). Three refused shapes are pinned here:

- root union with <2 derivable members or 0 metadata columns (W2.16);
- root union with any **non-table member** — e.g. a custom-SQL `text` member
  (fix-pass: previously the union emitted from the table members alone, a
  **silent subset** with the other members' rows gone);
- union **nested inside a join tree** — refused at the converter's join
  branch via `collectTables` (fix-pass: previously the join silently
  flattened to its plain-table branches and still emitted elements).

The handled wildcard shape reports the ⚠️-hint
`Union datasource (wildcard, converter-emitted)` row instead — never the ❌
(no false trips). `checks.sh` pins all directions plus converter↔golden
byte-identity and the three refusal variants.

Known seed boundaries (Wave-3): LOD calcs on a union datasource (the LOD
helper SQL has no single base table); two union datasources in one workbook
(both auto-named "Union of N Sources" — rename one in the UI); members with
renamed/missing columns need hand-edited `matches` (`null` for a member
lacking the column — stated in the emission warning).

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | Synthetic workbook XML: one root wildcard union (2 members, 3 columns + `Sheet`), one worksheet, one currency measure |
| `checks.sh` | Executable expectations (see above) |

## Converter

Vendored bundle (`plugins/tableau-to-sigma/.../converter/tableau.mjs`)
`convertTableauToSigma` with `xml_content=<workbook-content.twb>`,
`datasource_index=0`, empty connection/database/schema. Golden generated from
the vendored bundle (which carries the W2.16 local patch — see
`converter/PROVENANCE.json` `local_patches`), wrapped as
`{ sigmaDataModel: r.model, stats: r.stats, warnings: r.warnings }` and
normalized via `corpus/lib/corpus_check.py normalize`.

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 3,
      "columns": 9,
      "metrics": 1,
      "relationships": 0,
      "warnings": 2,
      "metric_names": ["Net Revenue"]
    }
  }
}
```
