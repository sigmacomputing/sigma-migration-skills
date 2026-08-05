# GoodData *Platform* (classic "bear", `/gdc`) — extraction API

> Source of truth: GoodData Platform / Legacy-Classic REST docs
> (`help.gooddata.com/doc/enterprise` + `/classic`) and the `gooddata-java` /
> `gooddata-http-client` SDKs. Endpoints below are **doc-verified**; the response
> **shapes** (query/entries, objects/get wrappers, metric `content.expression`)
> are **NOT yet exercised against a live Platform org** — confirm field paths on
> first live run, same posture as `gooddata-api.md` for Cloud.

## Platform vs Cloud — why this is a separate client

| | GoodData **Cloud / .CN** | GoodData **Platform** (classic) |
|---|---|---|
| Docs | `gooddata.com/docs/cloud` | `help.gooddata.com/doc/enterprise` + `/classic` |
| API root | `/api/v1` (declarative + entity) | `/gdc` (metadata API) |
| Auth | `Authorization: Bearer <API token>` | **SST → TT** flow (below) |
| Container | **organization** = one host, one token | **project** = one of many under ONE domain |
| Multi-tenant | one org per host → loop hosts+tokens | many projects per host → **one token sweeps all** |
| Metrics | `metrics[].content.maql`, `{fact/id}` refs | metric obj `content.expression`, `[<uri>]` refs |
| RLS | user data filters / user attributes | **MUF** (mandatory user filters) |

**The multi-"instance" question resolves here.** On the Platform, what a customer
calls "separate instances" are **projects under a single domain**. A user with
access to all of them is enumerated with **one identity, one token** — see
`platform_auth.PlatformClient.projects()` and `assess_platform.py --all`. (On
Cloud the opposite is true: each org is a separate host+token, so you loop
credentials per org.)

## Auth — SST / TT flow

Every `/gdc` request **must** send a `User-Agent` header or it is rejected.

```
1. POST {HOST}/gdc/account/login
   body: {"postUserLogin":{"login":"<email>","password":"<pw>","remember":0,"verify_level":2}}
   -> SST in the `X-GDC-AuthSST` response header  (verify_level:2 = header token, not cookie)

2. GET  {HOST}/gdc/account/token          header: X-GDC-AuthSST: <SST>
   -> TT (Temporary Token) in the `X-GDC-AuthTT` response header. Short-lived (~10 min).

3. Every metadata call:                    header: X-GDC-AuthTT: <TT>
   On 401 -> mint a new TT from the SST and retry once.
```

`platform_auth.py` implements this (`PlatformClient`), env-driven:
`GOODDATA_PLATFORM_HOST`, `GOODDATA_PLATFORM_USER` + `GOODDATA_PLATFORM_PASSWORD`
(or a pre-obtained `GOODDATA_PLATFORM_SST`). `GOODDATA_TLS_VERIFY=1` forces strict
TLS (default permissive, matching `discover.py`).

> Bearer/personal-access tokens are a **Cloud** concept; the classic Platform is
> SST/TT. If a given org exposes PATs, they slot in as an alternate `_login()`.

## Projects (the "instance" list)

```
GET {HOST}/gdc/app/account/bootstrap            # -> current profile self-link
GET {HOST}/gdc/account/profile/{profileId}/projects
    -> { "projects": [ { "project": { "links": {"self": "/gdc/projects/{pid}"},
                                        "meta": {"title": "..."} } } ] }
GET {HOST}/gdc/projects/{pid}                    # project detail / title
```

## Per-project metadata

```
GET  {HOST}/gdc/md/{pid}/query/metrics            # -> query.entries[]{link,title,identifier,summary}
GET  {HOST}/gdc/md/{pid}/query/facts
GET  {HOST}/gdc/md/{pid}/query/attributes
GET  {HOST}/gdc/md/{pid}/query/datasets
GET  {HOST}/gdc/md/{pid}/query/reports
GET  {HOST}/gdc/md/{pid}/query/projectdashboards      # legacy pixel-perfect tabs
GET  {HOST}/gdc/md/{pid}/query/analyticaldashboards   # KPI dashboards
GET  {HOST}/gdc/md/{pid}/obj/{objectId}               # single object detail
POST {HOST}/gdc/md/{pid}/objects/get                  # bulk: {"get":{"items":[<uri>,...]}}
     -> {"objects":{"items":[ {"<type>":{"content":..,"meta":{"uri","identifier","title"}}} ]}}
```

- A **metric** object: `content.expression` = classic MAQL; `content.format` = number format.
- An **attribute** object: `content.displayForms[]` = its labels (display forms).
- A **dataset** object: `content.attributes[]` + `content.facts[]` (object URIs) = its grain.
- Bulk `objects/get` is the efficient path — pull all metric/attribute detail in
  chunks of 50 rather than N single `obj/{id}` calls.

## Classic MAQL → shared translator

Classic MAQL references objects by **URI** (`[/gdc/md/{pid}/obj/N]`) or
**identifier** (`[fact.sales.rev]`); Cloud MAQL uses typed tokens (`{fact/N}`).
`discover_platform.normalize_maql()` rewrites classic refs into the Cloud token
form (resolving display-form/label refs up to their parent attribute), so the
**one** existing `maql.py` translator scores both dialects — no forked scorer.
The `BY` / `BY ALL` / `WITHIN` / `FOR` / `WHERE` keyword surface is shared across
dialects, so the AUTO / CONTEXT / TIME_INTEL / WHERE / UNHANDLED categories carry
over directly.

## MUF (row-level security) — fast-follow

Mandatory User Filters are the Platform's RLS. Enumerate via
`GET /gdc/md/{pid}/query/userfilters` and the per-user assignment resource; the
filter expression is MAQL over an attribute. Maps to the same Sigma user-attribute
RLS path the Cloud converter uses. **Extraction of MUF is not built yet** — flag
RLS as a manual review item for Platform projects until it is.

## Honest limitations (Platform, today)

1. **Discovery + assessment only.** `convert.py` / `build_workbook.py` read the
   **Cloud** LDM shape (`dataSourceTableId` → warehouse FQN). Platform projects
   often store data in GoodData's own datastore/ADS, not a customer-owned
   warehouse, so **same-warehouse parity may not hold** and DM conversion is not
   wired for the Platform LDM. Treat Platform as: enumerate → assess → hand the
   normalized layout to a human for the DM decision.
2. **Reports vs insights.** Classic reports/dashboards don't carry a Cloud
   `visualizationUrl`; the assessment reports COUNTS (reports / legacy dashboards
   / KPI dashboards), not a per-widget viz-type histogram. Per-report widget-type
   tagging needs a live report definition to model — fast-follow.
3. **Not live-validated.** No live Platform org has been run. Every shape above is
   defended with fallbacks; confirm on first run.
