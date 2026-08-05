# Tableau REST API mode (PAT fallback)

When the Tableau MCP tools (`mcp__tableau__*`) are missing in the session, the skill can
discover Tableau workbooks/datasources directly via the REST API using a Personal Access
Token. This doc covers the auth flow, endpoint inventory, response shapes, and the gotchas.

## When to use this mode

Pick MCP when it's available — it's simpler and the auth is already handled by the host.
Use PAT mode when:

- The agent runtime doesn't surface the Tableau MCP tools.
- You want to **download the workbook's `.twb` XML** for layout-hint extraction (the MCP
  doesn't expose this).
- The workbook uses an **embedded datasource** the MCP can't see (REST + `.twb` parsing can).
- You're on **self-hosted Tableau Server** (see below) — the hosted Tableau MCP targets Cloud.

## Tableau Server vs Cloud

The REST signin and the core endpoints (workbooks, views, view-data CSV, view-image PNG,
`.twb`/`.twbx` content) are **identical** on Cloud and self-hosted Server, so PAT mode works
on both. Four differences matter:

| | Tableau Cloud | Self-hosted Tableau Server |
|---|---|---|
| **REST API version** | always the latest | pinned to the installed release |
| **VDS** (`/api/v1/vizql-data-service`) | always on | needs **2024.2+** AND admin-enabled |
| **Metadata API** (`/api/metadata/graphql`) | always on | **OFF by default** (`tsm maintenance metadata-services enable`) |
| **Default site `contentUrl`** | n/a (always a named site) | the Default site uses an **empty** contentUrl |

Handled automatically:

- **Version negotiation** — `get-tableau-token.sh` reads the server's max `restApiVersion`
  from `/api/2.4/serverinfo` (no auth, so it can't trip the 4-strike PAT lockout) and signs
  in against that. Set `TABLEAU_API_VERSION` to override.
- **Default site** — `setup-tableau.rb` accepts an empty contentUrl; leave it blank when
  prompted on Server.
- **Capability banner** — `tableau-discover.rb` prints product version, REST API version,
  and Metadata-API on/off up front. When VDS/Metadata are off, calc formulas come from the
  downloaded `.twb` XML instead of `ds-metadata.json`/`graphql-fields.json` — discovery
  degrades gracefully rather than failing, but the banner tells you which mode you're in so
  a thin `ds-metadata.json` isn't mistaken for a bug.

## One-time setup

```bash
ruby scripts/setup-tableau.rb
```

Prompts for:

| Value | Where to find it |
|---|---|
| Server URL | The hostname only — Cloud `https://us-west-2b.online.tableau.com` or Server `https://tableau.mycompany.com`. No trailing slash needed. |
| Site contentUrl | The path segment after `/site/` in any Tableau URL — e.g. `mysite`. **Leave blank** for a Tableau Server "Default" site. |
| PAT name | The label you typed when creating the token in **Account Settings → Personal Access Tokens**. Case-sensitive. |
| PAT secret | The string shown at creation time. Copy verbatim — Tableau secrets are formatted as `base64==:base64`, the colon is part of the secret. |

Stored in `~/.claude/settings.json` as `TABLEAU_SERVER_URL`, `TABLEAU_SITE_CONTENT_URL`,
`TABLEAU_PAT_NAME`, `TABLEAU_PAT_SECRET`. Open a new Claude Code session (or
`! source ~/.claude/settings.json`) so they're live.

## Signin per session

```bash
eval "$(scripts/get-tableau-token.sh)"
```

Sets `TABLEAU_AUTH_TOKEN` and `TABLEAU_SITE_ID` in the calling shell. The token is good for
the duration of the session (Tableau Cloud session timeout, typically a few hours).

> **The script makes exactly one signin attempt.** Do not wrap it in a retry loop. Tableau
> Cloud invalidates a PAT after **four consecutive failed signins**, after which even
> correct credentials return 401001 and the only fix is creating a fresh PAT.

### ⚠️ PAT signin: the request body MUST be XML — JSON returns 400 "Payload malformed"

If you hand-roll the signin (curl, PowerShell, a REST client) instead of using the shipped
scripts, know this: `POST /api/<ver>/auth/signin` with a Personal Access Token **requires an
XML request body with `Content-Type: application/xml`**. Sending the JSON equivalent — even
a perfectly-shaped one with `Content-Type: application/json` — returns
**`400 "Payload malformed"`**, which looks like a credential problem but isn't (and each
retry-with-tweaked-JSON burns one of the PAT's four failed-signin strikes). **The response
is XML too** — pull the token out with a regex, **never pipe it to `jq`**.

The exact working call:

```bash
curl -sS -X POST "$TABLEAU_SERVER_URL/api/3.22/auth/signin" \
  -H "Content-Type: application/xml" \
  --data "<tsRequest><credentials personalAccessTokenName=\"$TABLEAU_PAT_NAME\" personalAccessTokenSecret=\"$TABLEAU_PAT_SECRET\"><site contentUrl=\"$TABLEAU_SITE_CONTENT_URL\"/></credentials></tsRequest>"

# The response is XML — extract with a regex (jq will fail on it):
#   <tsResponse ...><credentials token="..."><site id="..." .../></credentials></tsResponse>
TOKEN=$(printf '%s' "$RESPONSE"   | sed -n 's/.*token="\([^"]*\)".*/\1/p')
SITE_ID=$(printf '%s' "$RESPONSE" | sed -n 's/.*<site id="\([^"]*\)".*/\1/p')
```

(Adding `-H "Accept: application/json"` *asks* for a JSON response and usually gets one,
but don't depend on it — some server configurations return XML regardless, so the regex
parse is the only shape-proof option.) The shipped helpers already send the XML body:
the orchestrator mints its token in-process (`scripts/lib/tableau_rest.rb`), and
hand-driven calls have `get-tableau-token.sh` (bash) and its shell-neutral twin
`python scripts/get-tableau-token.py` (Windows-safe — see refs/environment.md). This
section exists for anyone driving the signin endpoint directly.

## Resolving a numeric `/projects/<N>` or `/workbooks/<N>` URL id (vizportal id) — never guess

A Tableau URL like `.../#/site/<site>/projects/1234567` — or a DIRECT workbook link like
`.../#/site/<site>/workbooks/4242001/views` — carries a **vizportal URL id**.
**REST has no numeric project id anywhere**: Query Projects (`GET $TABLEAU_BASE/projects`)
returns only `id` (the luid), `name`, `description`, `parentProjectId`, `owner`, and
`contentCounts` (filterable by name/ownerName/parentProjectId) — so no REST call can match
that number. The Metadata API can: `Workbook.projectVizportalUrlId` is "the ID of the project
in which the workbook is visible", next to `projectLuid`/`projectName`.

One command — `ruby scripts/resolve-project.rb --url "<url>"` — runs
`{ workbooks { luid name vizportalUrlId projectVizportalUrlId projectLuid projectName } }`
(plus the same project fields on `publishedDatasources` when the schema supports them) against
`POST /api/metadata/graphql`. A project URL groups by `projectVizportalUrlId` and exact-matches
the URL's number → `{vizportal_id, project_luid, project_name, workbooks}`; a workbook URL
exact-matches `Workbook.vizportalUrlId` → `{workbook_vizportal_id, workbook_luid, name,
project_luid, project_name}`. **Exit 2** (empty project, deleted workbook, or Metadata API off
on self-hosted Server) means the number is UNRESOLVABLE — the script prints the candidates
table; present it to the user and ask which project/workbook.
**Never guess from name or recency** — a wrong project aims the entire run at the wrong
content.

## Endpoint inventory

All paths assume `$TABLEAU_BASE = $TABLEAU_SERVER_URL/api/$TABLEAU_API_VERSION/sites/$TABLEAU_SITE_ID`.

| Skill need | Endpoint | Notes |
|---|---|---|
| Find workbook by name | `GET $TABLEAU_BASE/workbooks?filter=name:eq:NAME` | URL-encode the filter. Response is paginated; the filter is exact-match. |
| Get workbook (with views) | `GET $TABLEAU_BASE/workbooks/WBID` | Returns `views.view[]` with `id` + `name`. |
| List datasources | `GET $TABLEAU_BASE/datasources?pageSize=N&pageNumber=P` | Same filter syntax. |
| Find datasource by name | `GET $TABLEAU_BASE/datasources?filter=name:eq:NAME` | Exact-match. |
| VDS read-metadata (field list + calc formulas) | `POST /api/v1/vizql-data-service/read-metadata` | Body `{"datasource":{"datasourceLuid":"..."}}`. Returns `data[]` with `fieldName`, `fieldCaption`, `dataType`, `columnClass`, `formula` (for `CALCULATION` fields). |
| Metadata GraphQL (cleaner formulas) | `POST /api/metadata/graphql` | Returns formulas with **display-name field refs** like `SUM([Net Revenue])` instead of GUIDs. |
| View data (CSV) | `GET $TABLEAU_BASE/views/VID/data` | Cheap. Fire all views in parallel. |
| View image (PNG) | `GET $TABLEAU_BASE/views/VID/image?resolution=high` | Fetch dashboard view only by default. Solo (no concurrent image calls) — VizQL session contention causes 401s otherwise. The endpoint has NO size params (`vf_*` is the view-FILTER prefix; `vf_width`/`vf_height` were live-verified silent no-ops 2026-07-11) — exact-size renders come from the PDF row below. |
| View PDF (exact size) | `GET $TABLEAU_BASE/views/VID/pdf?type=Unspecified&vizWidth=W&vizHeight=H` | The ONLY REST path honoring authored canvas dims. Renders the canvas at 0.75pt/px + 36pt margins — rasterize at 4/3 and crop (scripts/render-baseline.rb does this). `vf_<Field>=<value>` applies view filters. |
| Workbook content download | `GET $TABLEAU_BASE/workbooks/WBID/content[?includeExtract=false]` | Returns raw `.twb` XML for workbooks with published datasources, or `.twbx` zip bytes if there are embedded extracts. Detect by checking the first 4 bytes for the ZIP magic `PK\x03\x04`. |
| Logout (optional) | `POST $TABLEAU_BASE/auth/signout` | Frees the session token; signin doesn't count against site quotas. |

## CLI: one-call discovery

The `scripts/tableau-discover.rb` helper produces all Phase-1 artifacts in one go:

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/tableau-discover.rb \
  --workbook-name "Orders Conversion Test" \
  --datasource-name "ORDER_FACT (DEMO_DB.ORDER_FACT)+ (New Virtual Connection)" \
  --out ~/tableau-migration/orders
```

Writes:
- `get-workbook.json` — workbook metadata + views list
- `ds-metadata.json` — VDS field list
- `graphql-fields.json` — metadata API field list (cleaner formulas)
- `views/<viewId>.csv` — every view's data
- `views/<viewId>.png` — dashboard view image only (by default)
- `workbook-content.twb` or `.twbx` — raw workbook content

Flags: `--workbook-id ID` (skip search), `--skip-images`, `--all-view-images`, `--skip-content`.

The output layout matches what the MCP-driven Phase 1 produces, so the downstream Phase
2–6 scripts (`fetch-view-data.rb`, `extract-calc-fields.rb`, `validate-spec.rb`, etc.) work
unchanged.

## Gotchas

### PAT invalidation

Four consecutive failed signins kill the PAT permanently. The only fix is a fresh token
from the Tableau Cloud UI. Always test the credentials with **one** call, fix-on-fail, then
try again — never iterate-guess names.

### Secret format

Tableau Cloud PAT secrets contain a colon and look like `+pFEL...XmMg==:gzS1...eB7E`.
The colon is part of the secret, **not** a name/secret separator. Copy the full string.

### VDS field names vs display names

`read-metadata` returns `fieldName` and `fieldCaption`. For fields belonging to **joined
logical tables** in a virtual connection, `fieldName` is a GUID like
`<field-id> (DATE_DIM (DEMO_DB.DATE_DIM)1)` — use `fieldCaption` for
the human-readable name. Calculations also have `fieldName == fieldCaption`, no GUID.

GraphQL's `name` field is always the display name — prefer GraphQL for calc-formula
extraction if you want references like `[Net Revenue]` instead of GUIDs.

### Workbook content: .twb vs .twbx

- Published-datasource workbooks: response is a raw `.twb` XML document. Parse directly.
- Embedded-extract workbooks: response is a `.twbx` zip — unzip and pull the `.twb` out.
- Detect by reading the first 4 bytes: `PK\x03\x04` → zip; otherwise XML.

The `.twb` XML contains a `<datasources>` block (with all calc formulas) and a
`<dashboards>/<dashboard>/<zones>` tree with x/y/w/h coordinates in units of 100000 (= 100%
of dashboard). The zone tree is the only way to get the Tableau dashboard's **layout**
structure programmatically — `get-view-image` only renders pixels.

### .twb calc formula GUIDs

Inside the `.twb` XML, `<calculation>` elements reference fields by GUID
(`[06db681d-04be-3a38-b324-85dc4732a408]`). To translate back to display names, walk the
sibling `<column>` elements in the same `<datasource>` and match `name="[guid]"` →
`caption="display name"`. For a one-shot read, prefer GraphQL or VDS read-metadata — both
return formulas with display-name refs.

### Image resolution

Default `get-view-image` returns 800x800. Pass `?resolution=high` for a usable dashboard
screenshot (caps ~1568px wide). The /image endpoint has NO size parameters — the old
`?vf_width=W&vf_height=H` advice was a silent no-op (`vf_` is the view-FILTER prefix;
`width`/`height` are not fields — live-verified 2026-07-11). For EXACT authored-size
renders use the /pdf endpoint (vizWidth/vizHeight) via scripts/render-baseline.rb.

### Pagination

`workbooks` and `datasources` endpoints paginate. The helper functions in
`scripts/lib/tableau_rest.rb` fetch one page; if your site has many items, walk the pages
via `pageNumber` and `pageSize`. The skill rarely needs this — `filter=name:eq:NAME`
returns at most a few matches.

### MCP fallback decision

The skill prefers MCP when both are available. The discovery CLI is opt-in:

- If you want explicit PAT-mode (e.g., to use `.twb` layout-hint extraction), run
  `scripts/tableau-discover.rb` and skip the MCP discovery steps.
- If you're in MCP mode and need just one REST-only capability (typically `.twb`
  download), call `Tableau.download_workbook_content` from a small Ruby snippet — no need
  to redo the whole discovery via REST.

---

## How the discovery fetch pool works — and why 5 (relocated from SKILL.md — PR-15 diet)

**How the pool works (and why 5):** every fetch after the initial workbook GET
(.twb, VDS read-metadata, GraphQL fields, all view CSVs, dashboard PNG) goes
through ONE shared pool of 5 threads, enqueued longest-job-first — the PNG
render is the longest single fetch, so it starts at t≈0 and hides behind the
CSV batch. **5 is the measured sweet spot; 8 risks long-tail stragglers** — at
8 threads a contended VizQL session parked one CSV fetch for ~40s (56s total
run vs. 13.7–18.9s at 5). The pool keeps 429/timeout exponential backoff and
single-flight 401 re-mint machinery as insurance even though neither fired at
pool 5 in validation. Also note Tableau's **~60s server-side render cache**:
a view rendered within the last minute returns much faster, so back-to-back
runs land at the fast end of the range and cold-cache runs at the slow end —
don't read a 5s spread between runs as a regression.

> **One signin attempt only.** Tableau Cloud invalidates a PAT after 4 consecutive failed
> signins. `get-tableau-token.sh` runs exactly once; never wrap it in a retry loop.

