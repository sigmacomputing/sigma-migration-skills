#!/usr/bin/env python3
"""Publish the generated pbi-shaped-model items to a Power BI / Fabric workspace.

Live-only (never run by checks.sh). Reads the output of src/build_reports.py (manifest.json,
<slug>/model.bim, <slug>/definition/..., ...) and, in order:

  1. creates each semantic model, or updates it in place with updateDefinition when an item with
     the same display name already exists in the workspace (no duplicates on a re-run);
  2. optionally binds each model to an existing Snowflake data source (Default.BindToGateway);
  3. optionally refreshes each model and polls it to a terminal state;
  4. creates or updates each report, bound by connection to its model (the {MODEL_ID} token in
     definition.pbir is replaced with the published model id).

It only ever touches items whose display name is in the manifest. It never enters credentials:
the data source to bind to must already exist and hold working credentials.

The directory passed as --dir must be generated with the REAL Snowflake coordinates, outside the
repository, because the data source path of the M source (<host>;<warehouse>) has to match the
existing data source exactly. Never commit that directory.

Auth: the cached sign-in of scripts/pbi_fabric.py (no prompt; sign in once with that script first).
Gateway and data source ids come from --gateway-id/--datasource-id or PBI_GATEWAY_ID /
PBI_DATASOURCE_ID, never from the repository.

Prints ids and states only.
"""
import argparse
import base64
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_SCRIPTS = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "..", "plugins", "powerbi-to-sigma", "skills", "powerbi-to-sigma", "scripts"))
sys.path.insert(0, HERE)
from refresh_pick import pick_refresh  # noqa: E402,F401

FAB = "https://api.fabric.microsoft.com/v1"
PBI = "https://api.powerbi.com/v1.0/myorg"
pf = None        # pbi_fabric, loaded by _load_live() (needs msal; also injects truststore)
requests = None  # loaded by _load_live(); tests may set a fake


def _load_live():
    global pf, requests
    sys.path.insert(0, SKILL_SCRIPTS)
    import pbi_fabric  # noqa: E402
    import requests as _requests  # noqa: E402
    pf, requests = pbi_fabric, _requests
TERMINAL = {"Completed", "Failed", "Disabled", "Cancelled"}


def hdr(tok):
    return {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}


def paged(tok, url, key="value"):
    out, cont = [], None
    while True:
        r = requests.get(url + (("&" if "?" in url else "?") + f"continuationToken={cont}" if cont else ""),
                         headers=hdr(tok))
        r.raise_for_status()
        j = r.json()
        out.extend(j.get(key, []))
        cont = j.get("continuationToken")
        if not cont:
            return out


def post_lro(tok, url, body, max_wait=300, label=""):
    """POST with a JSON body; follow a 202 Location until Succeeded. Returns the result JSON ({} if none)."""
    r = requests.post(url, headers=hdr(tok), data=json.dumps(body))
    if r.status_code == 429:
        time.sleep(min(float(r.headers.get("Retry-After", "10")), 60))
        r = requests.post(url, headers=hdr(tok), data=json.dumps(body))
    if r.status_code in (200, 201):
        return r.json() if r.text else {}
    if r.status_code != 202:
        raise RuntimeError(f"{label}: {r.status_code} {r.text[:400]}")
    op = r.headers.get("Location")
    ra = min(float(r.headers.get("Retry-After", "3") or 3), 5.0)
    deadline = time.monotonic() + max_wait
    while time.monotonic() < deadline:
        time.sleep(ra)
        sr = requests.get(op, headers=hdr(tok))
        if sr.status_code == 429:
            time.sleep(10)
            continue
        st = sr.json().get("status")
        if st == "Succeeded":
            rr = requests.get(op + "/result", headers=hdr(tok))
            return rr.json() if rr.status_code == 200 and rr.text else {}
        if st in ("Failed", "Undetermined"):
            raise RuntimeError(f"{label}: LRO {st}: {sr.text[:1500]}")
    raise RuntimeError(f"{label}: LRO timed out after {max_wait}s")


def parts_from_dir(root, skip=("report-bundle.json",)):
    parts = []
    for dp, _, fns in os.walk(root):
        for fn in sorted(fns):
            if fn in skip:
                continue
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            with open(full, "rb") as f:
                data = f.read()
            parts.append({"path": rel, "payload": base64.b64encode(data).decode(), "payloadType": "InlineBase64"})
    return sorted(parts, key=lambda p: p["path"])


def upsert(tok, ws, kind, display_name, parts, existing, label):
    """Create or update (in place) one item. Returns (id, 'created'|'updated')."""
    item = next((i for i in existing if i["displayName"] == display_name), None)
    if item:
        post_lro(tok, f"{FAB}/workspaces/{ws}/{kind}/{item['id']}/updateDefinition",
                 {"definition": {"parts": parts}}, label=f"{label} updateDefinition")
        return item["id"], "updated"
    res = post_lro(tok, f"{FAB}/workspaces/{ws}/{kind}", {"displayName": display_name, "definition": {"parts": parts}},
                   label=f"{label} create")
    if not res.get("id"):  # some LROs return no body: look the item up
        again = paged(tok, f"{FAB}/workspaces/{ws}/{kind}")
        res = next(i for i in again if i["displayName"] == display_name)
    existing.append({"id": res["id"], "displayName": display_name})
    return res["id"], "created"


def bind(ptok, ws, dataset_id, gateway_id, datasource_id):
    r = requests.post(f"{PBI}/groups/{ws}/datasets/{dataset_id}/Default.BindToGateway", headers=hdr(ptok),
                      data=json.dumps({"gatewayObjectId": gateway_id, "datasourceObjectIds": [datasource_id]}))
    return r.status_code, (r.text or "")[:300]


def start_refresh(ptok, ws, dataset_id):
    r = requests.post(f"{PBI}/groups/{ws}/datasets/{dataset_id}/refreshes", headers=hdr(ptok),
                      data=json.dumps({"notifyOption": "NoNotification"}))
    return r.status_code, (r.text or "")[:300], r.headers.get("RequestId") or r.headers.get("requestid")


def latest_refresh(ptok, ws, dataset_id, since=None, request_id=None):
    r = requests.get(f"{PBI}/groups/{ws}/datasets/{dataset_id}/refreshes?$top=10", headers=hdr(ptok))
    v = r.json().get("value", []) if r.status_code == 200 else []
    return pick_refresh(v, since, request_id)


def patch_report_parts(parts, model_id, workspace):
    """Fill the {MODEL_ID} and {WORKSPACE} tokens in a report's definition.pbir part (in place)."""
    for p in parts:
        if p["path"] == "definition.pbir":
            text = base64.b64decode(p["payload"]).decode().replace("{MODEL_ID}", model_id).replace("{WORKSPACE}", workspace)
            p["payload"] = base64.b64encode(text.encode()).decode()
    return parts


def poll_refreshes(ptok_fn, ws, ids, timeout, since, request_ids, interval=15, sleep=time.sleep):
    """ids: {slug: datasetId}. Polls until every model is terminal or the cap is hit.
    Returns {slug: {"states": [...], "final": str, "error": str|None}}."""
    result = {s: {"states": [], "final": "Unknown", "error": None} for s in ids}
    deadline = time.monotonic() + timeout
    pending = set(ids)
    while pending and time.monotonic() < deadline:
        sleep(interval)
        tok = ptok_fn()
        for s in sorted(pending):
            lr = latest_refresh(tok, ws, ids[s], since.get(s), request_ids.get(s))
            st = lr.get("status", "Unknown")
            if not result[s]["states"] or result[s]["states"][-1] != st:
                result[s]["states"].append(st)
                print(f"refresh {s}: {st}", flush=True)
            result[s]["final"] = st
            if st in TERMINAL:
                if st != "Completed":
                    result[s]["error"] = (lr.get("serviceExceptionJson") or "")[:600]
                pending.discard(s)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace", required=True, help="workspace display name, e.g. Test")
    ap.add_argument("--dir", required=True, help="output dir of build_reports.py (real coordinates, untracked)")
    ap.add_argument("--only", default="", help="comma list of slugs to publish (default: all)")
    ap.add_argument("--gateway-id", default=os.environ.get("PBI_GATEWAY_ID"))
    ap.add_argument("--datasource-id", default=os.environ.get("PBI_DATASOURCE_ID"))
    ap.add_argument("--refresh", action="store_true", help="refresh every model and poll to a terminal state")
    ap.add_argument("--refresh-timeout", type=int, default=900, help="seconds (default 900)")
    ap.add_argument("--state", default=None, help="write ids and states here (keep it out of the repository)")
    ap.add_argument("--skip-reports", action="store_true")
    a = ap.parse_args()

    _load_live()
    ftok = pf.get_token(pf.FABRIC_SCOPE, interactive=False)
    if not ftok:
        sys.exit("no cached Fabric token: sign in once with the skill's pbi_fabric.py first")
    ptok_fn = lambda: pf.get_token(pf.POWERBI_SCOPE, interactive=False)  # noqa: E731
    ws = next((w for w in paged(ftok, f"{FAB}/workspaces") if w["displayName"] == a.workspace), None)
    if not ws:
        sys.exit(f"workspace {a.workspace!r} not found")
    ws = ws["id"]
    with open(os.path.join(a.dir, "manifest.json")) as f:
        manifest = json.load(f)
    only = {s for s in a.only.split(",") if s}
    models = [m for m in manifest["models"] if not only or m["slug"] in only]
    reports = [r for r in manifest["reports"] if not only or r["slug"] in only]

    state = {"models": {}, "reports": {}, "bind": {}, "refresh": {}}
    existing_models = paged(ftok, f"{FAB}/workspaces/{ws}/semanticModels")
    for m in models:
        parts = parts_from_dir(os.path.join(a.dir, m["slug"]))
        mid, what = upsert(ftok, ws, "semanticModels", m["displayName"], parts, existing_models, m["slug"])
        state["models"][m["slug"]] = {"id": mid, "action": what, "displayName": m["displayName"]}
        print(f"model {m['slug']} {mid} {what}", flush=True)

    if a.gateway_id and a.datasource_id:
        for slug, info in state["models"].items():
            code, text = bind(ptok_fn(), ws, info["id"], a.gateway_id, a.datasource_id)
            state["bind"][slug] = {"status": code, "body": text}
            print(f"bind {slug} {code} {text}", flush=True)
    elif a.refresh:
        sys.exit("--refresh needs --gateway-id and --datasource-id (or PBI_GATEWAY_ID / PBI_DATASOURCE_ID)")

    if a.refresh:
        since, rids = {}, {}
        for slug, info in state["models"].items():
            # the local time immediately before the request: the per-model freshness floor
            since[slug] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
            code, text, rid = start_refresh(ptok_fn(), ws, info["id"])
            rids[slug] = rid
            print(f"refresh {slug} started {code} {text}", flush=True)
            if code not in (200, 202):
                state["refresh"][slug] = {"states": [], "final": "NotStarted", "error": text}
        state["refreshSince"], state["refreshRequestIds"] = since, rids
        ids = {s: i["id"] for s, i in state["models"].items() if s not in state["refresh"]}
        state["refresh"].update(poll_refreshes(ptok_fn, ws, ids, a.refresh_timeout, since, rids))

    if not a.skip_reports:
        existing_reports = paged(ftok, f"{FAB}/workspaces/{ws}/reports")
        for r in reports:
            model = next((i for i in state["models"].values() if i["displayName"] == r["model"]), None)
            if model is None:  # model not published in this run (--only): look it up
                model = next((i for i in existing_models if i["displayName"] == r["model"]), None)
            if model is None:
                sys.exit(f"report {r['slug']} needs model {r['model']!r}, which is not in the workspace")
            parts = parts_from_dir(os.path.join(a.dir, r["slug"]))
            patch_report_parts(parts, model["id"], a.workspace)
            rid, what = upsert(ftok, ws, "reports", r["displayName"], parts, existing_reports, r["slug"])
            state["reports"][r["slug"]] = {"id": rid, "action": what, "displayName": r["displayName"],
                                           "model": r["model"]}
            print(f"report {r['slug']} {rid} {what}", flush=True)

    state["workspaceId"] = ws
    if a.state:
        with open(a.state, "w") as f:
            json.dump(state, f, indent=2)
    bad = [s for s, v in state["refresh"].items() if v["final"] != "Completed"]
    if bad:
        print("refresh not Completed:", ", ".join(bad), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
