# The plugin tier — matching a viz Sigma has no native analog for

Some source visualizations have **no Sigma element kind that reproduces them**.
For those, the choice is a bespoke **plugin element** or a lossy fallback. This
file is the decision rule and the build recipe.

**Rule: native first, plugin when native genuinely can't, fallback last — and
always label a fallback as an approximation.** Never ship a tile that drops an
encoding and call it a match.

## When the plugin tier applies

Sigma's complete visual set, enumerated from the compiled OpenAPI (2026-08-25):

`bar-chart · line-chart · area-chart · combo-chart · scatter-chart ·
donut-chart · pie-chart · kpi-chart · waterfall-chart · pivot-table · table ·
input-table · geography-map · region-map · point-map · plugin · container ·
tabbed-container · text · image · button · control · divider`

No treemap, no sankey, no tile-heatmap. So:

| MSTR type | n | Why native fails |
|---|---|---|
| `heat_map` | 188 | It is a **treemap**: area encodes the metric and groups nest. A pivot with `backgroundScale` keeps the numbers and loses both. |
| `sankey` | 42 | Flow/link geometry has no analog. |
| `network` | 25 | Node-link graph has no analog. |
| `sequences_sunburst` | ≤12 | Radial hierarchy has no analog. |

A ready treemap plugin: `github.com/sigmacomputing/sigma-treemap-plugin` (single
file, no build step, MIT).

## Recipe

1. **Build/choose the plugin.** Use the `sigma-plugin-authoring` skill.
2. **Host it persistently and publicly.** Localhost renders only in the
   builder's own browser — not for other viewers, and not for Sigma's
   server-side PNG export.
3. **Register:** `POST /v2/plugins {name, url, devUrl}` → `pluginId`.
4. **Embed** via the shared emitter (`shared/lib/plugin_embed.rb|py`), bound to
   a source element on the hidden data page.
5. **Verify** with a data-parity check on the bound element (always provable)
   plus a render check (needs the public host).

## Traps that cost a day on the Executive Financial Analysis migration

- ⚠️ **If the plugin loads and configures but never receives data, suspect the
  column-binding shape.** On this migration the plugin loaded, took its config,
  resolved its source element, and `subscribeToElementData` accepted the handle
  and never fired — no error anywhere, and `/verify` reported `valid:true`
  throughout. It started working once the element was bound **once in the
  editor UI**, which rewrote the bindings from bare `columnId` strings to
  `{kind:"column", columnId:…, source:"<element config key>"}`.
  Two changes landed together there (the object form, and the UI performing the
  bind), so treat this as **a thing to try, not a settled rule** — the
  `sigma-plugin-authoring` guidance specifies bare strings and may well be
  right for the paths it was verified against. **Bind it once in the UI and GET
  the spec back** — a UI-written config is ground truth for whatever the
  current API expects.
- 🚨 **The SDK UMD needs React as a peer global** from v1.2.0 (2026-05-19).
  Without `window.React` the factory throws and `window.SigmaPlugin` is an
  empty object → `client` undefined → the plugin silently never binds. Load
  `react@18.3.1` UMD **before** the SDK, and **pin the SDK** — unpinned
  `@latest` crosses that boundary on its own.
- ⚠️ **`devUrl` and `url` are different servers.** Edit mode loads `devUrl`,
  published view loads `url`. `devUrl=localhost` + `url=<public>` means the two
  modes run different code — a plugin can work in edit and fail in view for
  that reason alone. Keep them identical while debugging.
- ⚠️ **`url` is immutable.** `PATCH /v2/plugins/{id}` accepts only
  name/description/devUrl. Moving the host, or cache-busting, needs a new
  `POST` (new `pluginId`) and a repoint. This is why orgs accumulate
  `…v2/v3/v4` registrations — clean them up when done.
- ⚠️ **Control filters cannot target a viz element** (hard 400,
  `Dependency not found`). To reproduce MSTR's `visualization_as_filter`, give
  the *target* viz its own source table and filter that. Filtering the shared
  source would filter the plugin too, which the source selector does not do.
- 🚨 **`POST /v2/workbooks/spec/verify` returns `valid: true` for every one of
  the above.** It is not a render gate. Only opening the workbook catches them.
- ⚠️ **A local harness that stubs the SDK tests your rendering and none of the
  integration.** The React trap survived a full "verified" local pass that way.
  Prove the data path against a real workbook.

## Reproducing MSTR selectors

A viz whose `definition` carries
`selector.selectorType: "visualization_as_filter"` filters its `targets` on
click. Reproduce it with a plugin `variable` binding → a filters-only `list`
control → the **target's own** source table:

```
tile click → plugin setVariable(<control>) → list control → filters target's source table
```
