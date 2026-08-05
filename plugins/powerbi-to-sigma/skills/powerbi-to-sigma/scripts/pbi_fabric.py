#!/usr/bin/env python3
"""pbi_fabric.py — shared FAST-DISCOVERY layer for the powerbi-to-sigma scripts.

Why this exists (customer scale: 30-50 workspaces, 20-40 report estates):
  * getDefinition LROs were polled by sleeping the FULL Retry-After (3s+) before
    the FIRST status check; most definitions are ready in well under a second.
    `lro()` polls at 0.5s first, then backs off (1s, 2s, then Retry-After-capped)
    — saves 2.5-5s per artifact with zero extra load at steady state.
  * the model TMSL and the report PBIR are INDEPENDENT artifacts; `fetch_definitions()`
    runs them concurrently on a small pool (default 2, hard cap 4 — Fabric throttles
    per principal, and >4 concurrent LROs risks 429 long-tails).
  * workspace -> model/report enumeration was serial (1 + N requests); at 30-50
    workspaces that is 15-30s. `enumerate_estate()` fans the per-workspace lists
    out 8-wide (cheap metadata GETs — not LROs — so the higher cap is safe) and
    the result is cached per session at /tmp/pbiauth/estate-map.json, invalidated
    automatically on any name miss.
  * every entry point records wall-clock per task and ALWAYS writes timings.json.

Stdlib + msal/requests/truststore only (same deps as the scripts it serves).
"""
import base64
import json
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import truststore; truststore.inject_into_ssl()  # corp TLS inspection — mandatory  # noqa: E702
import msal
import requests

FAB_BASE = "https://api.fabric.microsoft.com/v1"
PBI_BASE = "https://api.powerbi.com/v1.0/myorg"


# --- tenant override (#347) -------------------------------------------------
# The target report may live in a DIFFERENT tenant than the caller's HOME
# tenant — the normal consultant/partner (guest / B2B) case. The generic
# `organizations` authority (the default) always authenticates into the home
# tenant, so a guest report then fails every Fabric call as WorkspaceNotFound.
# PBI_TENANT (a raw tenant GUID) overrides the authority; entry points expose
# it as --tenant. Authority AND cache path are resolved at CALL time so a
# --tenant parsed after this module is imported still takes effect, and the
# per-tenant cache file keeps a guest token from colliding with the home token.
def _tenant():
    return os.environ.get("PBI_TENANT", "organizations")


def _authority(tenant=None):
    return "https://login.microsoftonline.com/" + (tenant or _tenant())


def cache_path(tenant=None):
    if os.environ.get("PBI_TOKEN_CACHE"):
        return os.environ["PBI_TOKEN_CACHE"]
    t = tenant or _tenant()
    return "/tmp/pbiauth/cache.bin" if t == "organizations" else f"/tmp/pbiauth/cache-{t}.bin"


def estate_cache_path(tenant=None):
    if os.environ.get("PBI_ESTATE_CACHE"):
        return os.environ["PBI_ESTATE_CACHE"]
    t = tenant or _tenant()
    return "/tmp/pbiauth/estate-map.json" if t == "organizations" \
        else f"/tmp/pbiauth/estate-map-{t}.json"


def normalize_tenant(value):
    """Tenant id from a raw GUID, or the `ctid` extracted from a pasted report URL."""
    if not value:
        return None
    m = re.search(r"[?&]ctid=([0-9a-fA-F-]{36})", value)
    return m.group(1) if m else value


FABRIC_SCOPE = ["https://api.fabric.microsoft.com/.default"]
POWERBI_SCOPE = ["https://analysis.windows.net/powerbi/api/.default"]
# Well-known public clients — no app registration needed (PBI Desktop first).
CLIENT_CANDIDATES = [
    ("ea0616ba-638b-4df5-95b9-636659ae5121", "PowerBI Desktop"),
    ("04b07795-8ddb-461a-bbee-02f9e1bf7b46", "Azure CLI"),
]
# Fabric throttles getDefinition per principal; cap concurrent LROs hard.
MAX_LRO_POOL = 4
# Workspace metadata lists are cheap GETs — a wider pool is safe.
ENUM_POOL = 8

_cache_lock = threading.Lock()
_caches = {}  # cache-file path -> SerializableTokenCache (one per tenant)


def _load_cache(path):
    c = _caches.get(path)
    if c is None:
        c = msal.SerializableTokenCache()
        if os.path.exists(path):
            c.deserialize(open(path).read())
        _caches[path] = c
    return c


def _persist_msal(cache, path):
    if cache.has_state_changed:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with _cache_lock:
            open(path, "w").write(cache.serialize())


def get_token(scopes=None, interactive=True, tenant=None):
    """Silent token from the per-tenant cache; device-code fallback when allowed.
    A pre-acquired bearer in $PBI_ACCESS_TOKEN wins (CI / callers who already
    authed out-of-band) — audience must match `scopes`."""
    pre = os.environ.get("PBI_ACCESS_TOKEN")
    if pre:
        return pre
    scopes = scopes or FABRIC_SCOPE
    authority = _authority(tenant)
    path = cache_path(tenant)
    cache = _load_cache(path)
    for cid, cname in CLIENT_CANDIDATES:
        app = msal.PublicClientApplication(cid, authority=authority, token_cache=cache)
        for acct in app.get_accounts():
            r = app.acquire_token_silent(scopes, account=acct)
            if r and "access_token" in r:
                _persist_msal(cache, path)
                return r["access_token"]
        if not interactive:
            continue
        flow = app.initiate_device_flow(scopes=scopes)
        if "user_code" not in flow:
            continue
        print("=" * 60, file=sys.stderr)
        print(f"CLIENT={cname}  SCOPE={scopes[0]}  TENANT={_tenant() if tenant is None else tenant}",
              file=sys.stderr)
        print(f">>> Go to: {flow['verification_uri']}", file=sys.stderr)
        print(f">>> Enter code: {flow['user_code']}", file=sys.stderr)
        print("=" * 60, file=sys.stderr)
        res = app.acquire_token_by_device_flow(flow)
        if "access_token" in res:
            _persist_msal(cache, path)
            return res["access_token"]
    return None


class Timings:
    """Per-task wall-clock evidence trail; ALWAYS written (timings.json)."""

    def __init__(self):
        self._t0 = time.monotonic()
        self._lock = threading.Lock()
        self.tasks = []

    def record(self, name, seconds, **extra):
        with self._lock:
            self.tasks.append({"task": name, "seconds": round(seconds, 2), **extra})

    def timed(self, name, fn, **extra):
        t = time.monotonic()
        try:
            return fn()
        finally:
            self.record(name, time.monotonic() - t, **extra)

    def write(self, path, **meta):
        body = {"totalSeconds": round(time.monotonic() - self._t0, 2),
                "tasks": self.tasks, **meta}
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        json.dump(body, open(path, "w"), indent=2)
        return body


def _hdrs(tok):
    return {"Authorization": f"Bearer {tok}"}


def lro(tok, url, max_wait=300, label=""):
    """POST a Fabric LRO endpoint and return the result JSON.

    Fast-first polling: 0.5s -> 1s -> 2s, then the service Retry-After (capped
    at 4s) — instead of sleeping the full Retry-After before the FIRST check.
    Honors 429 with the server's Retry-After. Raises RuntimeError on failure.
    """
    r = requests.post(url, headers=_hdrs(tok))
    if r.status_code == 200:
        return r.json()
    if r.status_code == 429:  # throttled on the initiate itself — back off once
        time.sleep(min(float(r.headers.get("Retry-After", "5")), 30))
        r = requests.post(url, headers=_hdrs(tok))
        if r.status_code == 200:
            return r.json()
    if r.status_code != 202:
        raise RuntimeError(f"{label or url} -> {r.status_code}: {r.text[:300]}")
    op = r.headers.get("Location")
    ra = min(float(r.headers.get("Retry-After", "3") or 3), 4.0)
    schedule = [0.5, 1.0, 2.0]
    deadline = time.monotonic() + max_wait
    i = 0
    while time.monotonic() < deadline:
        time.sleep(schedule[i] if i < len(schedule) else ra)
        i += 1
        sr = requests.get(op, headers=_hdrs(tok))
        if sr.status_code == 429:
            time.sleep(min(float(sr.headers.get("Retry-After", "5")), 30))
            continue
        st = sr.json().get("status")
        if st == "Succeeded":
            rr = requests.get(op + "/result", headers=_hdrs(tok))
            if rr.status_code != 200:
                raise RuntimeError(f"{label} LRO result -> {rr.status_code}: {rr.text[:300]}")
            return rr.json()
        if st in ("Failed", "Undetermined"):
            raise RuntimeError(f"{label} LRO {st}: {sr.text[:300]}")
    raise RuntimeError(f"{label} LRO timed out after {max_wait}s")


def fetch_definition(tok, ws_id, kind, item_id, fmt=None, label=""):
    """getDefinition for one item; kind = semanticModels|reports."""
    url = f"{FAB_BASE}/workspaces/{ws_id}/{kind}/{item_id}/getDefinition"
    if fmt:
        url += f"?format={fmt}"
    return lro(tok, url, label=label or f"{kind}/{item_id} getDefinition")


def fetch_report_definition(tok, ws_id, report_id, label=""):
    """Report definition: try PBIR, fall back to the default (classic) format."""
    try:
        return fetch_definition(tok, ws_id, "reports", report_id, "PBIR", label=label)
    except RuntimeError:
        return fetch_definition(tok, ws_id, "reports", report_id, None, label=label)


def write_parts(defn, out_dir, flatten=False):
    """Decode definition parts to out_dir. flatten=True reproduces the legacy
    fabric-extract layout (path separators -> '__'); False keeps the tree
    (what extract-pbir.py expects)."""
    os.makedirs(out_dir, exist_ok=True)
    parts = defn.get("definition", {}).get("parts", [])
    written = []
    for p in parts:
        data = base64.b64decode(p["payload"])
        rel = p["path"].replace("/", "__") if flatten else p["path"]
        fp = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        open(fp, "wb").write(data)
        written.append(p["path"])
    return written


def parts_bundle(defn):
    """Definition parts -> the flat {part-path: text} bundle migrate-powerbi.rb
    accepts as --pbir (same shape the assessment's raw-pbir/*.json files use)."""
    out = {}
    for p in defn.get("definition", {}).get("parts", []):
        out[p["path"]] = base64.b64decode(p["payload"]).decode("utf-8", "replace")
    return out


def fetch_definitions(tok, jobs, pool=2, timings=None):
    """Fetch several INDEPENDENT definitions concurrently (pool capped at
    MAX_LRO_POOL=4 — Fabric throttles getDefinition per principal).

    jobs: [{name, ws, kind, id, fmt?, report_fallback?}, ...]
    returns {name: definition-json} ; raises the first failure after all join.
    """
    pool = max(1, min(int(pool or 2), MAX_LRO_POOL))
    results, errors = {}, {}

    def one(j):
        t = time.monotonic()
        try:
            if j.get("report_fallback"):
                d = fetch_report_definition(tok, j["ws"], j["id"], label=j["name"])
            else:
                d = fetch_definition(tok, j["ws"], j["kind"], j["id"], j.get("fmt"), label=j["name"])
            results[j["name"]] = d
        except Exception as e:  # noqa: BLE001 — surfaced after join
            errors[j["name"]] = e
        finally:
            if timings:
                timings.record(j["name"], time.monotonic() - t,
                               kind=j["kind"], ok=j["name"] in results)

    with ThreadPoolExecutor(max_workers=pool) as ex:
        list(ex.map(one, jobs))
    if errors:
        name, e = next(iter(errors.items()))
        raise RuntimeError(f"{name}: {e}")
    return results


# ---------------------------------------------------------------------------
# Estate enumeration (workspace -> models/reports) + per-session cache
# ---------------------------------------------------------------------------

def enumerate_estate(tok, pool=ENUM_POOL, timings=None):
    """GET /workspaces then list semanticModels + reports PER WORKSPACE in
    parallel (8-wide; cheap metadata GETs). 30-50 workspaces -> ~2-3s instead
    of 15-30s serial."""
    t = time.monotonic()
    r = requests.get(f"{FAB_BASE}/workspaces", headers=_hdrs(tok))
    if r.status_code != 200:
        raise RuntimeError(f"/workspaces -> {r.status_code}: {r.text[:300]}")
    wss = r.json().get("value", [])

    def one(w):
        out = {"id": w["id"], "name": w.get("displayName"), "models": [], "reports": []}
        for kind, key in (("semanticModels", "models"), ("reports", "reports")):
            rr = requests.get(f"{FAB_BASE}/workspaces/{w['id']}/{kind}", headers=_hdrs(tok))
            if rr.status_code == 200:
                out[key] = [{"id": m["id"], "name": m.get("displayName")}
                            for m in rr.json().get("value", [])]
        return out

    with ThreadPoolExecutor(max_workers=max(1, min(pool, ENUM_POOL))) as ex:
        detailed = list(ex.map(one, wss))
    estate = {"fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "workspaces": detailed}
    if timings:
        timings.record("enumerate-estate", time.monotonic() - t,
                       workspaces=len(detailed))
    return estate


def load_estate_cache():
    try:
        return json.load(open(estate_cache_path()))
    except (OSError, ValueError):
        return None


def save_estate_cache(estate):
    try:
        path = estate_cache_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(estate, open(path, "w"), indent=2)
    except OSError:
        pass  # cache is best-effort


def _match(items, needle):
    """id exact match first, then case-insensitive name substring."""
    if not needle:
        return None
    for it in items:
        if it["id"] == needle:
            return it
    n = needle.lower()
    return next((it for it in items if n in (it.get("name") or "").lower()), None)


def resolve_targets(tok, model_name=None, workspace=None, report=None,
                    use_cache=True, timings=None, log=lambda s: None):
    """Resolve (workspace, model, report) using the session estate cache,
    falling back to a LIVE parallel enumeration on any miss (cache invalidated
    + rewritten). When `workspace` is a workspace ID, the live path lists ONLY
    that workspace (skips full-estate enumeration entirely)."""

    def search(estate):
        wss = estate["workspaces"]
        ws = _match(wss, workspace) if workspace else None
        if workspace and not ws:
            return None
        scope = [ws] if ws else wss
        model = rep = None
        m_ws = r_ws = ws
        # Resolve the report FIRST so that, absent an explicit --model-name, we can
        # bind the model the report ACTUALLY uses (its datasetId) instead of the
        # workspace's first model — a silent mismatch that converts the WRONG model
        # (observed: --report "Superstore Overview" pulled "Workforce KitchenSink").
        if report:
            for w in scope:
                rr = _match(w["reports"], report)
                if rr:
                    rep, r_ws = rr, w
                    break
            if not rep:
                return None
        if model_name:
            for w in scope:
                m = _match(w["models"], model_name)
                if m:
                    model, m_ws = m, w
                    break
            if not model:
                return None
        elif rep:
            # Bind the report's own semantic model (GET reports/{id} -> datasetId).
            dsid = report_dataset_id((r_ws or {}).get("id"), rep["id"])
            if dsid:
                for w in scope:
                    m = next((mm for mm in w["models"] if mm.get("id") == dsid), None)
                    if m:
                        model, m_ws = m, w
                        break
                if not model:  # dataset not in the enumerated estate — use its id directly
                    model, m_ws = {"id": dsid, "name": None}, r_ws
            if not model and scope and scope[0]["models"]:
                log("[model] WARNING: could not bind the report to its dataset (datasetId "
                    "unavailable) — falling back to the workspace's FIRST model. Pass "
                    "--model-name if this converts the wrong model.")
                model, m_ws = scope[0]["models"][0], scope[0]
        elif scope and scope[0]["models"]:
            model, m_ws = scope[0]["models"][0], scope[0]
        return {"workspace": m_ws or r_ws, "model": model,
                "report": rep, "report_workspace": r_ws}

    if use_cache:
        cached = load_estate_cache()
        if cached:
            hit = search(cached)
            if hit:
                log(f"[estate-cache] hit ({estate_cache_path()}) — skipping enumeration")
                return hit
            log("[estate-cache] name miss — invalidating + re-enumerating live")

    # live: a workspace ID lets us list ONE workspace (2 GETs) instead of the estate
    if workspace and _looks_like_id(workspace):
        t = time.monotonic()
        out = {"id": workspace, "name": workspace, "models": [], "reports": []}
        for kind, key in (("semanticModels", "models"), ("reports", "reports")):
            rr = requests.get(f"{FAB_BASE}/workspaces/{workspace}/{kind}", headers=_hdrs(tok))
            if rr.status_code == 200:
                out[key] = [{"id": m["id"], "name": m.get("displayName")}
                            for m in rr.json().get("value", [])]
        if timings:
            timings.record("list-workspace", time.monotonic() - t, workspace=workspace)
        estate = {"fetchedAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "workspaces": [out]}
        hit = search(estate)
        if hit:
            _merge_into_cache(out)
            return hit
        raise LookupError(_miss_msg(estate, model_name, report))

    estate = enumerate_estate(tok, timings=timings)
    save_estate_cache(estate)
    hit = search(estate)
    if hit:
        return hit
    raise LookupError(_miss_msg(estate, model_name, report))


def _looks_like_id(s):
    import re
    return bool(re.fullmatch(r"[0-9a-fA-F-]{36}", s or ""))


def _merge_into_cache(ws_entry):
    cached = load_estate_cache() or {"fetchedAt": "", "workspaces": []}
    cached["workspaces"] = [w for w in cached["workspaces"] if w["id"] != ws_entry["id"]]
    cached["workspaces"].append(ws_entry)
    cached["fetchedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    save_estate_cache(cached)


def _miss_msg(estate, model_name, report):
    models = [m["name"] for w in estate["workspaces"] for m in w["models"]]
    reports = [r["name"] for w in estate["workspaces"] for r in w["reports"]]
    bits = []
    if model_name:
        bits.append(f"no model matching '{model_name}' (saw: {', '.join(models) or 'none'})")
    if report:
        bits.append(f"no report matching '{report}' (saw: {', '.join(reports) or 'none'})")
    return "; ".join(bits) or "nothing matched"


def report_dataset_id(ws_id, report_id):
    """The semantic model bound to a report, via the Power BI REST API
    (GET reports/{id} -> datasetId). Needs the analysis.windows.net scope;
    returns None on any failure (callers fall back to name matching)."""
    tok = get_token(POWERBI_SCOPE, interactive=False)
    if not tok:
        return None
    base = PBI_BASE if not ws_id else f"{PBI_BASE}/groups/{ws_id}"
    try:
        r = requests.get(f"{base}/reports/{report_id}", headers=_hdrs(tok))
        if r.status_code == 200:
            return r.json().get("datasetId")
    except requests.RequestException:
        pass
    return None
