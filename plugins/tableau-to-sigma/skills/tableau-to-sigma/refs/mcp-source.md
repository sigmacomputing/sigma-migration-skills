# Local TWB + Tableau MCP

Use this Ruby-profile route when the user supplies a `.twb` and has Tableau MCP
but cannot provide a Tableau PAT. The file supplies structure, formulas, source
connections, and saved control defaults. Tableau MCP supplies rendered images
and query results. Sigma CLI authentication and Sigma MCP are independent of
Tableau authentication; neither should trigger a Tableau PAT setup request.

## Start

Run bootstrap with Sigma authentication available, then:

```bash
ruby scripts/migrate-tableau.rb --twb /path/source.twb \
  --out /path/run --connection <sigma-connection-id> --folder <folder-id> \
  --dashboard "Selected Dashboard"
```

Omit `--dashboard` to request every dashboard. Repeat it for multiple dashboards;
use dashboard names, not `--page` ids, on this route. Follow mission intake for
the destination and source scope. `--twb` selects this source route explicitly.
The existing `SIGMA_TABLEAU_VIA_MCP=1` also selects it when
`<WORK>/workbook-content.twb` is already present.

No evidence yet -> **exit 30**, writing `mcp-evidence-request.json`. This is an
agent handoff, not an authentication failure. The input TWB is copied once to
`workbook-content.twb`; existing evidence is not cleared. No Tableau revision
probe, PAT signin, GraphQL call, or REST discovery lane runs.

## Fill The Request

1. Use Tableau MCP `get-workbook` to resolve the published workbook and its
   view IDs. Save the response as `get-workbook.json`, either the direct workbook
   object or `{ "workbook": {...} }`, with `id`, `name`, `updatedAt` when
   available, and `views: { "view": [{ "id": "...", "name": "..." }] }`.
   Use MCP `list-views` for worksheet IDs omitted by `get-workbook`; retain their
   exact source names and IDs. Never invent a view or relabel a dashboard CSV as
   a worksheet export.
2. Re-run the same command. The request now names exact MCP view IDs and output
   paths. Start worksheet `get-view-data` requests **serially**. Increase
   concurrency only when the deployment's limits and successful requests support
   it, never above 4. Do not assume the REST discovery pool's concurrency is safe
   through the agent's MCP connection.
   Save raw CSV bytes, not a JSON tool wrapper or a summary, to the named files.
   Do not seal truncated or row-limited tool output as a complete source export;
   use the tool's full download if available, otherwise report that evidence gap.
   Header-only CSVs are retained honestly; downstream empty-data gates still run.
   On HTTP 429, retain successful exports and retry only the failed view, serially.
   Honor `Retry-After` when available; otherwise use bounded backoff (2s, then 4s,
   at most two retries). Continued throttling is a named source-evidence stop,
   not a reason to refetch the entire workbook or start another migration.
3. Fetch `get-view-image` for each requested dashboard, one image at a time.
   Save each actual PNG to the named `dashboards/` path. Do not fetch an image
   per worksheet unless a specific chart needs disambiguation.
4. Confirm the supplied TWB matches that published source revision and that
   the exports use the workbook's saved parameter/filter defaults. The initial
   route supports saved defaults only. Do not mix ad-hoc filtered MCP exports
   with a differently configured TWB. If they differ, obtain matching evidence
   or stop with that specific blocker; do not edit the expected numbers.
5. Seal the inputs with the same scope:

```bash
ruby scripts/import-tableau-mcp.rb --twb /path/source.twb \
  --workdir /path/run --workbook-id <tableau-workbook-id> \
  --dashboard "Selected Dashboard" --confirm-source-match
```

The importer makes **no network calls**. It validates identities and files,
records hashes in `source-evidence.json`, and prevents simultaneous imports and
builds using the workdir lock. `--confirm-source-match` is an attestation the
agent must support with the source evidence, not a flag to bypass missing inputs.

## Resume And Verify

Resume the original `--twb` command. Formula and Custom SQL extraction now read
only the local XML. The normal data-model, workbook, layout, parity, controls,
source-accounting, and visual gates remain mandatory. Read the source PNGs and
complete `png-read.json` / source anchors at the normal handoff.

Sigma actuals use the pooled REST exporter (including pivots); do not issue a
separate Sigma MCP query for every cell or re-fetch all source CSVs at every
repair. Sigma MCP is a targeted fallback when an exporter explicitly reports a
remainder. A working Sigma CLI profile is consumed noninteractively by the
shared token provider; scripts never run `sigma auth login` themselves.

Every re-entry rechecks the evidence hashes. Changed exports require a new
source-match check and seal. A different TWB requires a new workdir rather than
silently overwriting an existing migration's baseline. No synthetic REST
`discovery-stamp.json` or fabricated `timings.json` is necessary.

## Boundaries

- A bare TWB is not a numeric oracle or a rendered screenshot.
- Published-datasource placeholders (`sqlproxy`) without their real source
  definition stop before conversion. Obtain an exported source definition with
  its warehouse tables/Custom SQL; never invent a physical `SQLPROXY` table or
  ask for a forbidden PAT as an automatic fallback.
- Missing source data remains missing evidence, not a successful migration.
- If MCP cannot expose a hidden worksheet's result, this importer stops with the
  missing view/evidence named. It does not manufacture a CSV from another sheet;
  alternative datasource/warehouse-oracle handoffs need separate validation.
- This entrypoint is currently Ruby-profile only. Do not silently switch to the
  Python orchestrator and assume it implements this evidence contract.
- Live tests using recorded exports validate the ingestion/build boundary, not
  the MCP server's authentication, latency, or response transport. Report which
  parts were actually exercised.
