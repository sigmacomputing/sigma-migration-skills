<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Troubleshooting -->

## Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `Expecting UUID at 0.folderId but instead got: undefined` | `folderId` missing from spec | Find with `GET /v2/files?typeFilters=workbook` → `parentId` |
| `Invalid kind: 'kpi' \| 'pie' \| 'donut'` | Used Sigma example library naming | Replace with `kpi-chart` / `pie-chart` / `donut-chart`; the validator catches this |
| Element kind rejected, unknown | Guessed an unsupported kind | `GET /v2/workbooks/<existing-id>/spec` and read `kind` fields of real elements |
| `dependency not found: formula reference 'orders/country region'` | Slash in column `name` field | Rename the column to "Country" before saving the DM spec (preflight N2 warns on these; the ref gate resolves whole slashed names first) |
| **Mass `Dependency not found: '<dim table>/…'` at DM POST** (object-model workbook, often 50+ at once), or helper SQL like `SELECT <fact measure> FROM <date/dim table>` failing with `invalid identifier` | **Wrong fact elected.** A 2020.2+ relationship ("noodle") datasource serializes edges onto the authoring-order BASE table — routinely a dimension — and every LOD/Top-N/window helper + the master built their SQL/refs FROM the elected element | Find the `ℹ Object-model fact election: elected "<name>"` line in the converter output. If it names the wrong table: re-run with `--fact-table <TRUE_FACT>`. Already POSTed? Patch the emitted `dm-spec.json` (re-point the fact, rewire relationships fact→dim, rebuild helper FROMs) and **re-enter the gated spine with `--reuse-dm <id> --wb-spec <path>` — never hand-POST, never flatten the tables into a warehouse view**. The pre-POST sql-ident gate (exit 20) catches the wrong-FROM class before the POST; `object-graph-plan.json` (Phase 0) has the full wiring table |
| All columns on a table fail together | One bad formula poisons the element | Find the specific bad ref in the error message; fix only that column |
| `jq: parse error: Invalid numeric literal` | Sigma spec endpoints return YAML | Use `post-and-readback.rb` (it parses YAML); never pipe spec responses to `jq` |
| Validator flags `[X/col]` as unknown prefix on a workbook spec | `--dm-context` not passed | Re-run with `--dm-context <WORK>/dm-ids.json` |
| `401` on `get-view-data` in parallel batch | VizQL session contention — batches of 5+ trigger this | Cap batches at 4. Retry that view solo after 1-2s (PAT-mode `tableau-discover.rb` does this automatically); if still 401, skip — view is inaccessible |
| `401` on `get-view-image` | Always solo, never parallel with other view calls | Retry the image solo, no concurrent requests |
| `429` on Tableau view image | Rate limited | Wait and retry |
| Column fetch returns empty list | Response key is `entries`, not `columns` | Use `discover-warehouse-columns.rb` (handles this) |
| PUT returns `invalid_request` with no field named | Read-only metadata fields included in PUT body | Use `put-layout.rb` (strips them) |
| PUT returns `Invalid 1: schemaVersion, got undefined` | `schemaVersion` stripped from PUT body | Keep `schemaVersion`; the script preserves it |
| Layout PUT rejected, some elements not visible | `elementId=""` in layout XML | Script aborts on this; check the per-workbook layout config for nil IDs and guard with `.compact` |
| Layout has elements stacked vertically | No layout XML provided, or wrong IDs | Read IDs from `wb-ids.json` (Phase 5c readback), not your spec |
| KPI names invisible / truncated inside container | Inner `gridRow` smaller than container's outer span — `gridTemplateRows="auto"` does NOT expand | Set inner KPI `gridRow` end = container outer end |
| Empty containers visible on page | Container elements in spec but layout XML uses `<LayoutElement>` not `<GridContainer>` for them | Use `gc(...)` helper, not `le(...)`, for elements that wrap children |
| Wrong endpoint — workbook created instead of data model | Used `--type workbook` instead of `--type datamodel` | Delete the workbook; re-POST with the right `--type` |
| Bar chart renders vertical but Tableau shows horizontal | Orientation is UI-only — `"orientation": "horizontal"` silently dropped | Set post-publish: chart editor → Properties → Chart type → Horizontal |
| Sigma chart shows dim values Tableau's view never had | Missed Phase 2.5 filter | Diff CSV signals vs warehouse; add the filter as control/element-level |
| Axis label rotation / dashboard title alignment | UI-only fields | Set in element editor post-publish |
| `mcp__sigma-mcp-v2__query` returns "Table X not found" | Workbook queries don't resolve element names as table refs | Use `type: "connection"` with raw inodeId for unfiltered warehouse queries |
| `Unresolved column: <name>` on workbook/datamodel query | These surfaces expose **column IDs**, not display names | `describe` the element first; use the quoted IDs from the DDL |
| `Duplicate id: 'ctl-xxx'` on workbook POST | A control element's `id` matches its `controlId` (same namespace) | Use distinct values: `id: "el-ctl-region"`, `controlId: "ctl-region"` |
| Integer date key column renders as number axis | `ORDER_DATE_KEY` stored as YYYYMMDD integer | Cast in workbook column: `Date(Left(Text([Master/ORDER_DATE_KEY]), 4) & "-" & Mid(..., 5, 2) & "-" & Right(..., 2))`. `DateParse()` and `ToText()` do not exist in Sigma. |
| Sigma line chart shows 24 month-year buckets where Tableau shows 12 month names | Tableau MONTH part collapses across years; Sigma `DateTrunc("month", ...)` preserves year | See `refs/column-gotchas.md` "Cross-year month rollup" |
| Parity DIVERGE: bucket values differ but ratios match | Wrong source column for a Tableau calc | Calc-derived buckets must be re-derived from the same source the Tableau calc used (see `calc-fields.json` from Phase 1e), not from a same-named warehouse column |
| Calc-extracted formula uses `IIF`/`COUNTD`/LOD | Tableau syntax that's not 1:1 with Sigma | `IIF(c,t,e)` → `If(c,t,e)`; `COUNTD(x)` → `CountDistinct(x)`; LOD expressions need a per-case Sigma equivalent (window, Lookup, or pre-aggregation) |
| Ruby heredoc inside `bash -c '...'` fails with backslash errors | Bash's single-quoted block reaches into the heredoc | Write Ruby to a file with the `Write` tool and run `ruby /tmp/script.rb` |
| `dependency not found` / unresolved ref on an element that exists later in the spec | Spec dependency resolution is **strictly forward-in-document-order** — an element can only reference elements that appear EARLIER in the document | Order masters/helpers before every consumer. Also keep master elements **control-free**: a master column referencing a control defined on a later page breaks the same way (verified 2026-07-07) |
| Building a master table feels forced on a chart-only page | Masters are a convention, not a spec requirement | Charts may source DM elements **directly** (`source: {kind: "data-model", dataModelId, elementId}`) — a master is optional when no page-level filter/control needs a shared funnel (verified 2026-07-07) |
| `build-parity-plan.rb` plan has far fewer charts than the workbook (e.g. 17→5) | Plan keys charts by element **name**; blank/duplicate display names collide and overwrite each other | Give every chart element a unique non-blank `name` before building the plan, or uniquify the plan keys by element **id** before `verify-warehouse` (hit live 2026-07-07) |



---

## Shell footguns (relocated from SKILL.md — PR-15 diet)

> **bash-only alternative:** `eval "$(scripts/get-token.sh)"` still works in
> bash. But never use `TOKEN=$(eval "$(scripts/get-token.sh)")` — `$()` creates a
> subshell where the exported var dies immediately; keep eval + curl in the same
> `bash -c '...'`. PowerShell/cmd cannot run this idiom at all — use
> `get_token.py` there.

> **Inline Python inside bash — DON'T.** Triple-nested escapes (`f"...{e.get(\\\"name\\\")}..."` inside `python3 -c "..."` inside `bash -c '...'`) silently break. Instead **always write a `.py` file with `Write` and call it via `python3 file.py`.** Same rule for any inline script over ~5 lines: write it to disk, then exec. It's not slower, it's deterministic, and the file becomes a reusable artifact. (Same applies to Ruby — prefer `ruby file.rb` over `ruby -e '...'`.)
