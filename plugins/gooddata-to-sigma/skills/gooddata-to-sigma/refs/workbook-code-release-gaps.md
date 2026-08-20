# Workbook-as-code release mappings and gaps

GoodData mappings for the Aug-2026 Sigma workbook code representation:

| GoodData semantic | Sigma release surface | Converter status |
|---|---|---|
| `local:waterfall` with View + measure | `waterfall-chart` | Native x/y axes, cumulative sum, hidden zero start, and connectors. Missing prerequisites are loud. |
| Repeater Rows + Columns | `repeated-container` | Native grouped table source and cards. View-by cell sparklines remain a loud gap while values are preserved. |
| `properties.controls.legend` | chart `legend` | Enabled/hidden and top/bottom/left/right are preserved. Unknown properties are loud. |
| Dashboard tabs | metadata pages + `navigation:auto` | Native. Pages are metadata-only and required layout owns membership. |
| Literal insight background | `style.backgroundColor` | Native when the exported value is a resolved literal; dynamic/unknown style is rejected loudly. |
| Attribute hierarchy drill-down | drill control | Gap: source intent exists, but no published source/category/target authoring binding exists. No inert control is emitted. |
| Drill/open-dashboard interaction | navigation action | Gap until the target converted document/page id is resolved. Same-dashboard tabs use auto navigation. |
| Tab-local YAML filters | controls | Gap unless equivalent declarative `filterContext` bindings are available. |
| Print pagination | `page-break` | Source gap: dashboard tabs/sections are not print-page-break intent. |
| Standalone progress/bullet | `progress` | Source gap: GoodData Cloud exposes no documented value/min/max visualization contract. Repeater bars are not promoted. |
| Dashboard sections/filter chrome | document `panels` | Not equivalent to Sigma header/sidebar panels; the collection remains explicit and empty. |
| Box plot | box element | Capability-gated; never emitted by default. |

Workbook requests use outer metadata and a nested `document`. Workbook
`document.elements` is flat, `document.pages` is metadata-only, and
`document.layout` is required and authoritative. Data-model code representation
is unchanged and keeps `pages[].elements`.
