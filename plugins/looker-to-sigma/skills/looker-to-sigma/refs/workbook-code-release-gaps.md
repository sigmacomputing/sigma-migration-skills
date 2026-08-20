# Workbook-as-code release mappings and gaps

Looker mappings for the Aug-2026 Sigma workbook code representation:

| Looker semantic | Sigma release surface | Converter status |
|---|---|---|
| `looker_waterfall` | `waterfall-chart` | Native for dimension + measure: x/y, cumulative sum, zero start, connector line, and pivot split are emitted. Measure-only waterfall is a loud gap. |
| `hide_legend`, `legend_position` | chart `legend` | Hidden/shown and left/right are preserved. Looker `center` is alignment rather than a Sigma position, so it is warned and omitted. |
| Standalone legend filter | `controlType: legend` | Source gap: Looker legends are per-chart display encoding, not standalone filter artifacts. No legend control is invented. |
| Single-value `comparison_type: progress*` | `progress` | Native when both value and comparison measures exist; otherwise the KPI is retained with a warning. |
| Dashboard `tabs` + element `tab_name` | metadata pages + required layout + `navigation:auto` | Native. Every source tab becomes a page; page membership comes only from layout. |
| Literal `background_color` | element `style.backgroundColor`; theme canvas override | Native. Liquid/dynamic colors are rejected loudly. |
| Field `drill_fields` | `controlType: drill` | Gap: the released control has no documented source/category/target binding. Dead drill UI is not emitted. |
| Tab-navigation button | `navigation` | Gap: `rich_content_json` destination parsing is not grounded yet. Auto tab navigation is emitted instead. |
| Filter sidebar | document `panels` | Gap: Looker filter-bar chrome has no grounded panel/control binding. In-canvas controls remain and the sidebar request is warned. |
| Dashboard tabs as regional tabs | `tabbed-container` | Not equivalent: Looker tabs are top-level pages, so no tabbed container is invented. |
| Print pagination | `page-break` | Source gap: LookML dashboards expose no print page-break marker. |
| Data-bound repeating region | `repeated-container` | Source gap: Looker dashboard rows are static layout, not repeaters. |
| `looker_boxplot` | `box-chart` | Release-gated: `box-chart` is not published in the workbook schema. The tile is skipped loudly until the gate and round-trip test exist. |

Workbook requests use an outer metadata envelope and nested `document`.
Workbook pages are metadata-only, elements are flat, and `layout` is required
and authoritative. Data-model code representation is unchanged and continues
to use `pages[].elements`.
