# Cognos → Sigma — dashboard/report classifier coverage matrix

> **Grounding note.** Cognos' executable catalog is
> `converter/workbook-features.ts`, bundled into `converter/cli.mjs` and consumed
> directly by `cognos-report.ts`. It records released, gated, and no-analog
> targets. Anything outside that catalog takes the loud
> `⛔ WORKBOOK FEATURE GAP […]` path; it never silently selects a chart.

Cognos was already the most loud of the classifiers (an unknown visual degrades to a
**warned table**, never a silent chart; number formats are read from the report's
`currencyFormat`/`percentFormat`/`numberFormat` nodes, never guessed from a column
name). This pass closed the one remaining silent default: an **unmapped Cognos
aggregate / rollup no longer silently becomes `Sum`** — it warns first.

## Visualization / chart kind
Source: `workbook-features.ts` `VIZ_KIND` (+ `VIZ_NO_ANALOG` / `VIZ_GATED`). Cognos `com.ibm.vis.*` → Sigma element kind.
Authoritative source: <https://www.ibm.com/docs/en/cognos-analytics> (visualization types).

| Cognos vizType | Sigma target | on-unmapped |
|---|---|---|
| `com.ibm.vis.clusteredbar` / `stackedbar` / `clusteredcolumn` / `stackedcolumn` | `bar-chart` | — |
| `com.ibm.vis.line` / `spline` | `line-chart` | — |
| `com.ibm.vis.area` / `stackedarea` | `area-chart` | — |
| `com.ibm.vis.pie` | `pie-chart` | — |
| `com.ibm.vis.donut` | `donut-chart` | — |
| `com.ibm.vis.clusteredcombination` / `stackedcombination` | `combo-chart` | — |
| `com.ibm.vis.bubble` / `scatter` | `scatter-chart` | — |
| `com.ibm.vis.waterfall` / `waterfallchart` | `waterfall-chart` (`source`, `columns`, required `yAxis`) | category columns retained; multi-level category hierarchy is a loud render-review gap because the released schema exposes no `xAxis` |
| `com.ibm.vis.box*` | `box-chart` only when the workspace feature is enabled | **gated**: loud warning + data-preserving table; never emit a box chart into an unknown entitlement |
| _unknown vizType_ | — (no grounded equivalent) | **loud `⛔ WORKBOOK FEATURE GAP` + emit the data as a `table`** — never a silent concrete chart |

## Workbook-code representation and released features

Source: `cognos-report.ts`, grounded status: `workbook-features.ts`
`RELEASED_WORKBOOK_FEATURES`.

| Cognos source | Sigma target | Guard / gap behavior |
|---|---|---|
| report workbook | outer `{name, document}` | CodeRep wrapper required before POST and again on readback |
| report pages | metadata-only `document.pages[]` | elements in a page object fail the contract gate |
| page contents | flat `document.elements[]` | page ownership comes only from layout |
| report page membership | required `document.layout` | every page gets one `<Page>` and every element is placed exactly once; missing/unknown/duplicate ids fail before POST and on readback |
| `viewPagesAsTabs` + multiple `<page>` nodes | metadata pages + `navigation {mode:auto}` | one navigation element per page, with source page labels |
| `vizProperty*Value name="*legend*"` | chart/map `legend.visibility` / `legend.position` | only explicit source properties are emitted |
| non-empty `<drillBehavior>` | `controlType: drill` control | cross-report `<reportDrill>` is **not** mislabeled as hierarchy drill; it remains a loud gap requiring explicit page/document navigation |
| `<pageBreak>` | `page-break` | layout always assigns exactly one grid row |
| progress/bullet/gauge viz | `progress` + hidden aggregate source table | value binds to the hidden source; percent mode retains 0–1 semantics |
| `<pageHeader>` | `document.panels[] {type:header, pages:[…]}` | safe CSS background maps to panel config; page ids are contract-gated |
| named `<block>` with converted children | styled `container` section | safe CSS background/radius properties only; children are authoritative live `<Container>` members |
| `<repeater>` / `<repeaterTable>` | hidden local source table + `repeated-container` + text bindings | local source name grounds Sigma's derived `"<source> repeated container"` namespace; unresolved query/content is loud |

### Remaining loud gaps

- Cross-report drill-through targets require the destination report to be
  converted and then wired as Sigma navigation/open-url.
- Cognos page footers remain loud: released workbook panels support page
  header/sidebar, not footer.
- Unknown visual kinds preserve their data as a table and carry a loud gap.
- Box plots remain workspace-gated until entitlement is proven.
- Waterfalls with multiple Cognos category levels require render verification
  because released workbook code does not expose a waterfall category axis.

## Aggregation
Source: `cognos-report.ts` `AGG` (list footer/dataItem) + `ROLLUP_AGG` (chart rollup). Cognos aggregate/rollup → Sigma aggregate function.
Authoritative source: IBM Cognos regularAggregate / rollup; Sigma <https://help.sigmacomputing.com/docs/aggregate-functions>.

| Cognos aggregate/rollup | Sigma target | on-unmapped |
|---|---|---|
| `total` / `summary` / `aggregate` / `calculated` / `sum` | `Sum` | — |
| `average` / `avg` | `Avg` | — |
| `count` | `Count` | — |
| `countdistinct` | `CountDistinct` | — |
| `maximum` | `Max` | — |
| `minimum` | `Min` | — |
| _unmapped aggregate/rollup_ | `Sum` (degraded) | **loud warn** ("unmapped Cognos aggregate/rollup '…' — defaulted to Sum (degraded); verify parity") — was a silent `\|\| 'Sum'` before this pass |

## Number format
Source: `cognos-report.ts` `formatFromNode` — reads the report's `currencyFormat` / `percentFormat` / `numberFormat` nodes (decimals from `@_decimalSize`, SI scaling from `@_scale`/`K`/`M`/`B`). Currency `$,.Nf` / `$,.Ns`, percent `,.N%`, number `,.Nf`.
| Cognos format node | Sigma target | on-unmapped |
|---|---|---|
| `currencyFormat` | `$,.<dec>f` (or `$,.<dec>s` scaled) | — |
| `percentFormat` | `,.<dec>%` | — |
| `numberFormat` | `,.<dec>f` (or `$,.<dec>s` scaled) | — |
| _no format node_ | `undefined` (Sigma type default) | benign — **no name-substring currency guessing** (contrast the other tools' disease) |

## Control / filter
Source: `cognos-report.ts` — Cognos `prompt('p',…)` → Sigma `segmented` control; detail filters → element `filters` (list, include/exclude); a macro measure-swap prompt → control + `Switch(...)`.
| Cognos construct | Sigma target | on-unmapped |
|---|---|---|
| `prompt(...)` parameter | `segmented` control (values from `<selectValue>`) | empty options → **warn** ("no `<selectValue>` options — emitted an empty segmented control; add values in Sigma") |
| detail filter (`= value`) | element `filters` (kind `list`, mode include/exclude) | — |
| `?prompt?` comparison | segmented control + boolean match column + list filter on `[true]` | — |

---
_The Cognos expression translator (`translateCognosExpr`), the crosstab/list grouping
logic, and the band layout are compositional and stay as cited code — this matrix
covers the enumerable maps. Re-bundle `converter/cli.mjs` from `converter/cognos-report.ts`
after any map change (esbuild; see `tools/vendor-converters.sh` cognos case)._
