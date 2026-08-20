# Workbook-as-code release mappings and gaps

Sisense mappings for the Aug-2026 Sigma workbook code representation:

| Sisense semantic | Sigma release surface | Converter status |
|---|---|---|
| `chart/waterfall` | `waterfall-chart` | Native category/value axes with cumulative sum and connector line. |
| Explicit widget legend settings | chart `legend` | `enabled` and top/bottom/left/right position are retained; unknown values are warned and omitted. |
| Widget drill hierarchy | `controlType: drill` | Gap: the released control has no documented source/category/target binding. No dead control is invented. |
| Jump To Dashboard add-on | `navigation` | Gap: discovery does not normalize and validate its destination payload. |
| Tabber add-on | pages / `tabbed-container` | Gap: discovery does not expose grounded tab labels and widget membership. A regional Tabber is not guessed as top-level pages. |
| Print pagination | `page-break` | Source gap: Sisense dashboard layout has no persisted page-break marker. |
| Bounded `indicator/gauge` | `progress` | Native ring in value mode only when explicit value, minimum, and maximum are available; otherwise retained as KPI with a warning. |
| Dashboard filter panel | document `panels` | Gap: filters become in-canvas controls, but source application chrome has no grounded panel binding. |
| Literal widget/canvas background | element `style.backgroundColor`; theme canvas override | Native for literal hex colors. Dynamic/scripted styles remain loud gaps. |
| Data-bound repeating region | `repeated-container` | Source gap: ordinary Sisense columnar cells are static layout, not repeaters. |
| Box-and-whisker widget | `box-chart` | Release-gated: never emitted until workspace entitlement and create/readback behavior are verified. |

Workbook requests use an outer metadata envelope and nested `document`.
Workbook pages are metadata-only, elements are flat, and `layout` is required
and authoritative. Data-model code representation is unchanged and continues
to use `pages[].elements`.
