# Workbook-as-code release mappings and gaps

Tableau mappings for the Aug-2026 Sigma workbook code representation:

| Tableau semantic | Sigma release surface | Converter status |
|---|---|---|
| Gantt Bar positioned by `RUNNING_SUM` | `waterfall-chart` | Native waterfall with sum calculation, connector line, hidden zero start, and stacked grouping. Other Gantt uses remain manual because timelines and candlesticks have different semantics. |
| Explicit color legend zone | chart `legend.position` | Native when the zone names its worksheet, or when one legend and one color-encoded chart make ownership unambiguous. Floating pixel offsets collapse to the nearest chart edge. |
| Dashboard/story navigation | `navigation` | Story points emit manual page navigation. URL and sheet-navigation dashboard buttons keep their existing button/navigation translation. |
| Tableau story | pages + `navigation` | One page per story point, preserving point order and caption. Captured elements are cloned with page-local control IDs. Saved story filter state still requires parity review. |
| Show/hide or alternate-view container | `tabbed-container` | Available only when Tableau metadata establishes tab membership and ordering. Do not infer tabs from arbitrary tiled/floating layout containers. |
| Print pagination | `page-break` | Available when a source page-break object or pagination signal is explicit. Dashboard geometry alone is not a print break. |
| Progress or goal indicator | `progress` | Available when the source calculation identifies current value and goal/range semantics. Do not coerce an ordinary KPI or Gantt mark. |
| Repeated section | `repeated-container` | Available only when repeat-by field semantics are explicit. Duplicate dashboard zones are not evidence of a repeater. |
| Dashboard panels and navigation chrome | document `panels` and `settings.navigation` | Collections survive readback/update. They are emitted only from explicit source semantics; Tableau authoring sidebars and application chrome are not workbook content. |
| Zone fill, border, radius, padding, and margin | element/container style + authoritative layout | Literal styling is preserved where the target field is published. Per-side or responsive behavior without a target equivalent remains a visual-review item. |
| Hierarchy drill | drill control / hierarchy | Preserve only when the source hierarchy, target chart, and levels resolve. An unattached drill control is dead UI, so ambiguous metadata remains a gap. |
| Box-and-whisker | `box-chart` | Explicit gap: `box-chart` is not published in the current workbook spec. Re-author with reviewed quartile/reference-mark components or a table; never silently emit `box-chart` or coerce it to a bar. |

Workbook elements are document-global. `document.pages` is metadata-only and
`document.layout` is the sole page-membership authority. Data-model code
representation is outside this release and remains `pages[].elements`.
