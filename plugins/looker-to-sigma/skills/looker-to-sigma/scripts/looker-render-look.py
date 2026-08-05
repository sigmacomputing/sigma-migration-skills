#!/usr/bin/env python3
"""looker-render-look.py — render a LIVE Looker Look to PNG for Phase 4 SOURCE-vs-
MIGRATED side-by-side visual QA (the Look analog of looker-render-dashboard.py).

A Look renders SYNCHRONOUSLY — no render-task poll:
  GET /looks/{id}/run/png?width=&height=   -> raw PNG bytes

Pairs with sigma-export-png.py: render the Looker SOURCE Look here and the migrated
Sigma workbook there, then read them together to catch chart-kind / grouping /
formatting drift a numeric parity check can't see.

Reuses looker_api.py's ~/.looker/looker.ini auth (fresh login per call). The render
endpoint returns binary, so this fetches the bytes directly (no json decode).

Usage:
  python3 looker-render-look.py <look_id> [out.png] [--w 1200 --h 900]
"""
import argparse
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import looker_api  # noqa: E402


def _get_bytes(url, tok, verify, accept="image/png"):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok,
                                               "Accept": accept}, method="GET")
    try:
        with urllib.request.urlopen(req, context=looker_api._ctx(verify), timeout=180) as r:
            return r.status, r.read(), r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers.get("Content-Type", "")


def render(look_id, out_path, width, height, fmt="png"):
    base, tok, verify = looker_api.login()
    url = f"{base}/looks/{look_id}/run/{fmt}?width={width}&height={height}"
    code, content, ct = _get_bytes(url, tok, verify)
    if code != 200 or not content:
        sys.exit(f"look render GET {code} ({ct}): {content[:400].decode('utf-8', 'replace')}")
    with open(out_path, "wb") as f:
        f.write(content)
    print(f"[looker] {len(content)} bytes -> {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("look_id")
    ap.add_argument("out", nargs="?", default=None,
                    help="output PNG path (default: /tmp/looker-look-<id>.png)")
    ap.add_argument("--w", type=int, default=1200, help="render width px")
    ap.add_argument("--h", type=int, default=900, help="render height px")
    a = ap.parse_args()
    render(a.look_id, a.out or f"/tmp/looker-look-{a.look_id}.png", a.w, a.h)


if __name__ == "__main__":
    main()
