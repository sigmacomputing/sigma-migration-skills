# Connecting to Power BI / Fabric — the no-Entra-app recipe

Validated 2026-05-31, tenant `sigmacomputing.com` (corp), Fabric trial. This is the connection layer for Phases 1–2 and the reverse (write) direction.

## Why this path
In the corp tenant, the obvious routes are all blocked:
- **Entra app registration** — user can't create one (tenant-restricted).
- **Fabric Git integration** — greyed out (tenant setting off, IT-controlled).
- **XMLA** — needs PPU/capacity. Historically also needed the Windows-only ADOMD client (dead on macOS), BUT the [Power BI Modeling MCP](https://github.com/microsoft/powerbi-modeling-mcp) bundles a cross-platform TOM/ADOMD client and DOES reach XMLA from macOS — a viable secondary connector where the model is on capacity. See `refs/pbi-modeling-mcp.md`. (Still device-code by default; XMLA is the fallback.)
- **`.pbix` download** — gives layout but the model is a binary `DataModel` blob, not JSON.

The path that needs **no app and no IT toggle**: device-code login against a Microsoft **first-party public client**, as the user.

## Recipe (Python, macOS)
```python
import truststore; truststore.inject_into_ssl()   # MANDATORY — see TLS note
import msal, requests
_tenant = os.environ.get("PBI_TENANT", "organizations")  # override for guest/B2B — see below
app = msal.PublicClientApplication(
    "ea0616ba-638b-4df5-95b9-636659ae5121",          # well-known "Power BI Desktop" public client
    authority=f"https://login.microsoftonline.com/{_tenant}",
    token_cache=<SerializableTokenCache from /tmp/pbiauth/cache.bin>)
flow = app.initiate_device_flow(scopes=["https://api.fabric.microsoft.com/.default"])
# print flow["verification_uri"] + flow["user_code"]; user signs in once
res  = app.acquire_token_by_device_flow(flow)        # token aud=api.fabric.microsoft.com, scp=user_impersonation
```
`scripts/fabric-extract.py` (read) and `scripts/fabric-auth-check.py` (write-capability/capacity probe) implement this with a persistent cache + silent re-auth.

## Cross-tenant / guest (B2B) — `--tenant` (#347)
The default `organizations` authority always authenticates into the caller's **home**
tenant. When the report lives in a **different** tenant — the normal consultant/partner
case where you're a **guest (B2B)** in a client's tenant — a home-tenant token makes every
Fabric call 404 as `WorkspaceNotFound`, even though you can open the report in a browser.

Target the report's tenant with `--tenant` (or `PBI_TENANT`). It accepts a raw tenant GUID
**or** a pasted report URL (the `ctid=<guid>` query param is extracted automatically):
```
# the tenant GUID is the ctid= in the report URL:  https://app.powerbi.com/.../reports/<id>?ctid=<TENANT>
python scripts/fabric-extract.py --tenant <TENANT-GUID-or-report-URL> --report "<name>" ...
# or, driving the whole pipeline:
ruby scripts/migrate-powerbi.rb --tenant <TENANT> ...   # exported as PBI_TENANT to every PBI child
```
The token cache is **namespaced per tenant** (`/tmp/pbiauth/cache-<tenant>.bin`) so a guest
token never collides with the cached home-tenant token. `--tenant` is available on
`fabric-extract.py`, `fabric-extract-batch.py`, `migrate-powerbi.rb`,
`pbi_import_to_snowflake.py`, and the assessment scripts (`probe-admin.py`,
`fabric-inventory.py`); the orchestrator-invoked helpers inherit `PBI_TENANT` from the env.

## TLS inspection — the gotcha that bit us
Corp network MITM-inspects `api.fabric.microsoft.com` → Python raises `CERTIFICATE_VERIFY_FAILED: self-signed certificate in certificate chain`. Fix: **`truststore.inject_into_ssl()` as the first import** (uses the macOS keychain, which trusts the corp root CA). Note `login.microsoftonline.com` is *not* inspected (proxy bypass), so msal auth succeeds even without truststore — only the API calls fail. Always inject.

## Extract calls (read)
- `GET /v1/workspaces` → workspace ids. `capacityId` set ⇒ on Fabric capacity (writable via API).
- `GET /v1/workspaces/{ws}/semanticModels` → model ids.
- `POST /v1/workspaces/{ws}/semanticModels/{id}/getDefinition?format=TMSL` → **202 LRO**: poll `Location` (respect `Retry-After`) until `Succeeded`, GET `Location/result` → `definition.parts[]`; base64-decode the `model.bim` part = TMSL/TOM JSON for the MCP.

## Surprises worth remembering
- **getDefinition works on a model in *My workspace*** — no capacity move needed for the read.
- **Device-code is NOT Conditional-Access-blocked** in this tenant.
- The well-known PBI Desktop client returns a **Fabric-audience** token with `scp=user_impersonation`, which covers BOTH read and write (act-as-user) — a literal "ReadWrite" scope check is a false negative.
- Both `My workspace` and `Test` ended up on capacity (capacityId present) → both writable.

Workspace ids (this tenant): `My workspace` = `f16f69ff-3763-415e-88aa-f3fefcb11e3d`, `Test` = `269a33d0-98c4-476f-890d-612ea8072f9a`.
