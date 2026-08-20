# Workbook-as-code release mappings and gaps

QuickSight mappings for the Aug-2026 Sigma workbook code representation:

| QuickSight semantic | Sigma release surface | Converter status |
|---|---|---|
| Waterfall Categories/Values/Breakdowns | `waterfall-chart` | Native x/y/splitBy with connector and zero start. |
| Gauge value and ArcAxis range | `progress` | Native ring/value progress. Missing Max is warned and never guessed. |
| Sheet tabs | metadata-only pages + `navigation:auto` | Native for multi-sheet analyses. |
| LegendOptions | chart `legend` | Visibility and position preserved. Fonts, dimensions, and rich title style are loud gaps. |
| Explicit/Predefined ColumnHierarchy | drill control | Native only when every ordered level resolves on the routed master; otherwise the whole control is suppressed loudly. |
| Section page break | `page-break` | Native when `After.Status=ENABLED`; fixed one-row layout placement. |
| Body section repeat | `repeated-container` | Native for one resolvable repeat dimension and concrete section children. Multi-dimension/unresolved cases flatten loudly. |
| Small multiples | chart `trellis` | Native trellis; not misrepresented as a row-card repeater. |
| Filter controls | in-canvas `control` | QuickSight controls are not workbook panels. `document.panels` remains empty. |
| Alternate-view tabs | `tabbed-container` | Gap: QuickSight sheets are top-level pages and expose no equivalent in-canvas tab container. |
| Box plot | `box-chart` | Release-gated. Until published, data migrates as a grouped table with a loud warning. |

Data-model code representation is unchanged and remains nested under
`pages[].elements`. Workbook-only output uses outer create metadata plus
`document:{schemaVersion,kind,pages,elements,layout,...}`. Its authoritative
layout uses the live `<Element>` placement and `<Container>` band tags exactly;
Sigma's verify endpoint rejects the legacy tag names.
