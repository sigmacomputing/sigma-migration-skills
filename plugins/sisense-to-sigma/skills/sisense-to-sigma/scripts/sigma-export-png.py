#!/usr/bin/env python3
"""sigma-export-png.py — render a Sigma workbook page or element to PNG via the
REST export API, for VISUAL QA of a migrated workbook (Phase 4: side-by-side
against the source Looker dashboard).

A PNG is more reliable than an MCP SQL query for catching LAYOUT/render problems —
hidden KPI titles, orphaned filters, overlapping tiles, wrong chart kinds — that a
numeric parity check can't see.

POST /v2/workbooks/{id}/export {pageId|elementId, format:{type:"png",pixelWidth,pixelHeight}}
  -> {queryId, jobComplete}; then GET /v2/query/{queryId}/download until the PNG is ready.

Env: none required when signed in (Sigma CLI profile or browser login); an
explicit SIGMA_BASE_URL / SIGMA_API_TOKEN still wins.
Usage:
  python3 sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/x.png
  python3 sigma-export-png.py --workbook <id> --element <elId> --out /tmp/x.png [--w 1600 --h 900]
"""
import argparse, os, sys, time, requests

_HERE = os.path.dirname(os.path.abspath(__file__))
for _lib in (os.path.join(_HERE, "lib"), os.path.join(_HERE, "..", "lib")):
    if os.path.isdir(_lib):
        sys.path.insert(0, _lib)
import sigma_rest

_AUTH_HINT = ("Sigma credentials unavailable: sign in with the Sigma CLI "
              "(`sigma auth login`), run scripts/browser-login.sh, or set "
              "SIGMA_BASE_URL plus SIGMA_API_TOKEN / client credentials")


def credentials():
    """(base, token) from the shared client: an explicit SIGMA_BASE_URL wins,
    else the host a signed-in Sigma CLI profile reports."""
    try:
        return sigma_rest.base_url().rstrip("/"), sigma_rest.auth_token()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        raise SystemExit(f"{_AUTH_HINT} ({exc})") from exc


def refreshed_token():
    """Force the token provider after a rejected bearer."""
    try:
        return sigma_rest.refresh_token()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        raise SystemExit(f"{_AUTH_HINT} ({exc})") from exc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workbook", required=True)
    ap.add_argument("--page"); ap.add_argument("--element")
    ap.add_argument("--out", required=True)
    ap.add_argument("--w", type=int, default=1600); ap.add_argument("--h", type=int, default=900)
    a = ap.parse_args()
    base, tok = credentials()
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
    fmt = {"type": "png", "pixelWidth": a.w, "pixelHeight": a.h}
    body = {"format": fmt}
    if a.element: body["elementId"] = a.element
    elif a.page:  body["pageId"] = a.page
    else: sys.exit("need --page or --element")
    export_url = f"{base}/v2/workbooks/{a.workbook}/export"
    r = requests.post(export_url, headers=h, json=body, timeout=60)
    if r.status_code == 401:
        tok = refreshed_token()
        h["Authorization"] = f"Bearer {tok}"
        r = requests.post(export_url, headers=h, json=body, timeout=60)
    if r.status_code != 200: sys.exit(f"export POST {r.status_code}: {r.text[:300]}")
    qid = r.json()["queryId"]
    dl = f"{base}/v2/query/{qid}/download"
    for i in range(60):
        g = requests.get(dl, headers={"Authorization": f"Bearer {tok}"}, timeout=60)
        ct = g.headers.get("Content-Type", "")
        if g.status_code == 200 and ("image" in ct or g.content[:8] == b"\x89PNG\r\n\x1a\n"):
            open(a.out, "wb").write(g.content)
            print(f"[png] {len(g.content)} bytes -> {a.out}"); return
        time.sleep(3)
    sys.exit("timed out waiting for PNG")

if __name__ == "__main__":
    main()
