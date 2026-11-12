<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Read at Phase 5g on the hybrid SDK route (refs/phase-5g-sdk-hybrid.md), before the first build_workbook call. -->

# Sigma MCP Code Mode SDK — gotchas for the hybrid fix loop

These came from the 2026-11-05 hybrid A/B runs: the skill's code-rep build, then
fixes through `build_workbook`. Each one cost a failed write or a wrong render.
Read this before the first SDK write of a session. If the Sigma MCP plugin
skill (`sigma-workbook-quickstart` / `sigma-workbook-flex`) is loaded, its
Code Mode reference still wins on API shape. This list covers what bit the
*fix* path, and a bare MCP connection without that skill does not carry it.

**After ANY failed run, re-read before the next write.** A runtime failure
can leave partial state behind: the elements and columns created before the
exception stay in the workbook. Run `describe` (or `get_table`) on the page,
save the output, then record it with
`fidelity-loop.rb sdk-reread --evidence FILE`. `sdk-write` and `sdk-export`
refuse until you do. Never re-send the same program on the assumption that
nothing happened.

| # | Gotcha | Do this |
|---|---|---|
| 1 | `commands.*` presets can't be imported on the host. | Write the operation out explicitly in the program. Don't `import` or call a preset helper from host-side code. |
| 2 | `get_table` needs the ids that `model.list_tables()` returns, not the element ids `describe` returns (it rejects those). | Bind the data model, then pick the member by name: `dm = sigma.data.source.data_model(inode_id)`, `t = [t for t in dm.list_tables() if t.name() == "<member>"][0]`. This is the same idiom the MCP plugin skill uses. Keep it a single-`for` comprehension. |
| 3 | A runtime failure can persist partial state. | Re-read the page (box above), then reconcile: remove or finish the partial elements in the next write. |
| 4 | The data-label position literal is `"outside-end"`. | Use exactly `"outside-end"`. Don't guess at camelCase or underscore spellings. |
| 5 | String literals inside formulas need `sigma.formula.const_text`. | Wrap text constants: `sigma.formula.const_text("East")`. A bare Python string is not a formula text literal. |
| 6 | `set_formula` wants a Formula object. | Build the Formula (from `sigma.formula.*`) and pass it. Don't pass a raw formula string. |
| 7 | Pivot value columns don't accept widths. | Size the pivot element in the layout. Don't call width setters on value columns. |
| 8 | `set_sort_by_calculation` takes exactly one aggregate. | For a custom order (a Tableau manual sort, or a multi-key order), add a hidden helper column that encodes the rank and sort by that column. |
| 9 | `convert_to('bar')` keeps the element id. | Converting a chart kind is safe for the parity plan, anchors and layout, which all bind by element id. Prefer it over delete-and-recreate. The export records added and removed element ids, and phase-6 pass 1 rebuilds the parity plan from the exported spec. A pie or donut exports only its color and value channels, so its plan drops the other measure columns (`unplotted_columns`). |
| 10 | List-control values persist after a test. | After you flip a list control to check filtering, clear it with `set_value([])` before the next write or the export. Otherwise the saved workbook ships filtered. |
| 11 | MCP `query` can't set control values. | To check values under a control state, use the REST element export with `parameters` (the route `probe-controls.rb` and `collect-parity-actuals.rb` use). `query` only sees the default state. |

The MCP plugin skill also notes that a hidden data page's source element is
not queryable through `query`. Do value discovery before you hide it.

## How these interact with the gates

- Every SDK write is followed by `fidelity-loop.rb sdk-write` (program,
  result, and document version recorded in `fidelity-ledger.json`). A write
  missing from the ledger makes `sdk-export` refuse (exit 4: unrecorded write).
- Items 9–11 are the usual reasons an exported spec fails phase-6 parity even
  though the screenshot looked right: a sort helper column dropped, a control
  left filtered, or values checked only at the default state.
- `sdk-export` re-runs the column-type guard and the layout/control lints, the
  same checks `apply-patch` runs. A formula that compiles in the SDK but types
  as `error` fails the export (exit 5) and the session stays open. An export
  whose parity actuals are incomplete also exits 5 with the session still
  open: run `sdk-regate --actuals FILE`, or record more writes and export again.
