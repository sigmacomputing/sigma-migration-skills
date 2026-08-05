#!/usr/bin/env python3
"""Probe whether the signed-in user has the Fabric Administrator role.

READ-ONLY. Hits one cheap call against each admin-gated API and prints a JSON
status object to stdout for probe-admin.rb to consume:

  { "activity_events": "ok" | "forbidden" | "error",
    "scanner":         "ok" | "forbidden" | "error" }

- **Activity Events API** (usage/adoption: views, distinct users) —
  GET /admin/activityevents — Fabric Administrator only.
- **Scanner API** (tenant-wide sprawl / lineage) —
  POST /admin/workspaces/getInfo — Fabric Administrator only.

On 401/403 we record "forbidden" and the assessment degrades to a
complexity-only shortlist. We never write anything.

Auth: same device-code recipe / shared cache as fabric-inventory.py. The
Activity Events + Scanner admin endpoints live on the Power BI REST audience
(analysis.windows.net), so we request a Power BI token.

Usage:
  /tmp/pbiauth/bin/python scripts/probe-admin.py [--no-interactive]
"""

import truststore; truststore.inject_into_ssl()
import sys, os, json, time, argparse, atexit, re
import requests
import msal


def _tenant_from_argv(argv):
    """#347: pre-read --tenant BEFORE the module-level MSAL app/cache are built.
    Accepts a raw tenant GUID or a pasted report URL (ctid=... is extracted)."""
    for i, a in enumerate(argv):
        v = a.split("=", 1)[1] if a.startswith("--tenant=") else (
            argv[i + 1] if a == "--tenant" and i + 1 < len(argv) else None)
        if v:
            m = re.search(r"[?&]ctid=([0-9a-fA-F-]{36})", v)
            return m.group(1) if m else v
    return None


_t = _tenant_from_argv(sys.argv)
if _t:
    os.environ["PBI_TENANT"] = _t
_TENANT = os.environ.get("PBI_TENANT", "organizations")  # default = caller's home tenant

CACHE = os.environ.get("PBI_TOKEN_CACHE") or ("/tmp/pbiauth/cache.bin" if _TENANT == "organizations" else f"/tmp/pbiauth/cache-{_TENANT}.bin")
CLIENT_ID = "ea0616ba-638b-4df5-95b9-636659ae5121"
AUTHORITY = f"https://login.microsoftonline.com/{_TENANT}"
PBI_SCOPE = ["https://analysis.windows.net/powerbi/api/.default"]
PBI_BASE = "https://api.powerbi.com/v1.0/myorg"

_cache = msal.SerializableTokenCache()
if os.path.exists(CACHE):
    _cache.deserialize(open(CACHE).read())
atexit.register(lambda: open(CACHE, "w").write(_cache.serialize()) if _cache.has_state_changed else None)
_app = msal.PublicClientApplication(CLIENT_ID, authority=AUTHORITY, token_cache=_cache)


def get_token(interactive=True):
    for acct in _app.get_accounts():
        s = _app.acquire_token_silent(PBI_SCOPE, account=acct)
        if s and "access_token" in s:
            return s["access_token"]
    if not interactive:
        return None
    flow = _app.initiate_device_flow(scopes=PBI_SCOPE)
    if "user_code" not in flow:
        return None
    print(f">>> {flow['verification_uri']}  code: {flow['user_code']}", file=sys.stderr)
    return _app.acquire_token_by_device_flow(flow).get("access_token")


def classify(status):
    if status == 200:
        return "ok"
    if status in (401, 403):
        return "forbidden"
    return "error"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-interactive", action="store_true")
    ap.add_argument("--tenant", default=None,
                    help="target tenant (guest/B2B) — raw GUID or a report URL with ctid=...; "
                         "pre-parsed at import (default: home tenant)")
    args = ap.parse_args()
    tok = get_token(interactive=not args.no_interactive)
    if not tok:
        print(json.dumps({"activity_events": "error", "scanner": "error",
                          "note": "no token"}))
        sys.exit(2)
    hdr = {"Authorization": f"Bearer {tok}"}

    # Activity Events — needs a startDateTime/endDateTime window (single UTC day).
    day = time.strftime("%Y-%m-%d", time.gmtime(time.time() - 86400))
    ae_url = (f"{PBI_BASE}/admin/activityevents"
              f"?startDateTime='{day}T00:00:00.000Z'&endDateTime='{day}T23:59:59.999Z'")
    try:
        ae = requests.get(ae_url, headers=hdr)
        ae_status = classify(ae.status_code)
    except Exception:
        ae_status = "error"

    # Scanner API — POST getInfo with an empty workspace set is the cheapest probe.
    try:
        sc = requests.post(f"{PBI_BASE}/admin/workspaces/getInfo",
                           headers=hdr, json={"workspaces": []})
        sc_status = classify(sc.status_code)
    except Exception:
        sc_status = "error"

    print(json.dumps({"activity_events": ae_status, "scanner": sc_status}))
    sys.exit(0 if ae_status == "ok" else 3)


if __name__ == "__main__":
    main()
