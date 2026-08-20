#!/usr/bin/env python3
"""thoughtspot-render-source.py — render a WHOLE ThoughtSpot Liveboard to a single
source dashboard PNG, for the Phase-6 MEASURED parity gates in
assert-phase6-ran.rb: gate 13 (source-anchor value verification) + gate 14
(visual-similarity floor). Those gates arm the moment a source dashboard PNG is
on disk under <workdir>/dashboards/*.png (or views/*.png, or png-read.json
source_png); this script lands that image.

API (ThoughtSpot REST v2.0 — verified against the developer docs, 2026-07):
  POST {TS_HOST}/api/rest/2.0/report/liveboard
    Authorization: Bearer <TS_TOKEN>
    Content-Type: application/json
    { "metadata_identifier": "<liveboard-guid-or-name>",
      "file_format": "PNG",
      "png_options": { "image_resolution": 1920, "image_scale": 100,
                       "include_header": true } }

  * SYNCHRONOUS — the response body IS the raw PNG bytes (an extensionless
    binary/octet-stream file). There is NO async task, no S3 URL to poll
    (unlike the older /callosum PDF export or Looker's render-task API), so a
    single request → write is all that's needed.
  * Omitting "visualization_identifiers" renders the ENTIRE Liveboard (all
    tiles) as one tall PNG — the whole-dashboard source image the anchors +
    visual-similarity gates compare against. (Passing visualization_identifiers
    is the per-viz path used by ts_screenshot.py.)
  * "png_options" (image_resolution / image_scale / include_header) were added
    in 10.9.0.cl (June 2025); older orgs are handled by an automatic minimal-body
    retry, then a whole-Liveboard PDF→PNG fallback.
  * "tab_identifiers" restricts the render to one tab of a multi-tab Liveboard.
  Docs: https://developers.thoughtspot.com/docs/liveboard-export-api
        https://developers.thoughtspot.com/docs/fetch-data-and-report-apis
        https://developers.thoughtspot.com/docs/rest-apiv2-reference  (POST /report/liveboard)

Auth: the SAME bearer path every other TS script uses — TS_HOST + TS_TOKEN.
ts_lib.py reads them from the environment (get-ts-token.sh mints a service token
via Trusted Auth, or copy one from Develop → REST Playground). No new credential
source is introduced.

Blank-render guard: reuses ts_screenshot.png_health — when the Liveboard's
warehouse connection is down, ThoughtSpot still returns HTTP 200 with a
near-uniform placeholder PNG (or a JSON/HTML error body under a 200). Those are
reported as failures (exit 1) and NEVER written as a valid source image, so a
dead render can't silently arm the gate with a blank picture.

Fallback (older orgs that don't serve whole-Liveboard PNG): request the whole
Liveboard as PDF (always supported) and convert page 1 → PNG with whatever
converter is on PATH (pdftoppm > magick/convert > sips). Best-effort; if none is
installed the script says exactly that and exits non-zero rather than land a bad
image. (A multi-tab Liveboard's PDF has one page per tab — the fallback captures
page 1; use --tab to target a specific tab, or prefer the native PNG path.)

Output: <workdir>/dashboards/source.png  (auto-discovered by gate 13/14 via the
dashboards/*.png glob). Default workdir = $TS_WORKDIR or ./ts-migration; for a
multi-Liveboard run point --workdir at that Liveboard's parity dir
(<wd>/parity-<n>) so the image lands where its gate runs.

Usage:
  python3 thoughtspot-render-source.py <LIVEBOARD_ID> [--workdir DIR] [--out PATH]
  python3 thoughtspot-render-source.py <LIVEBOARD_ID> --tab <tabGuidOrName>
Env: TS_HOST, TS_TOKEN, TS_WORKDIR.
"""
import argparse
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ts_lib  # noqa: E402  — TS_HOST / TS_TOKEN, same auth as every TS script

try:
    from ts_screenshot import png_health  # reuse the blank/placeholder detector
except Exception:  # ts_screenshot imports yaml at module load; guard the dep
    def png_health(data):
        """Minimal signature+size guard (full blank heuristic lives in ts_screenshot)."""
        if len(data) < 1000:
            return False, f"suspiciously small response ({len(data)} bytes)"
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            return False, "not a PNG (error body?)"
        return True, "png signature ok"

_SSL = ts_lib.ssl_context()
ENDPOINT = "/api/rest/2.0/report/liveboard"


def _post_report(body, timeout=180):
    """POST the report/liveboard export and return the raw response bytes."""
    req = urllib.request.Request(
        ts_lib.HOST + ENDPOINT, data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": f"Bearer {ts_lib.TOKEN}",
                 "Content-Type": "application/json",
                 # The TS Cloud edge WAF rejects UA-less requests with an HTML 403.
                 "User-Agent": "thoughtspot-to-sigma/1.0"})
    with urllib.request.urlopen(req, context=_SSL, timeout=timeout) as r:
        return r.read()


def render_png(lb_id, tab=None, options=True):
    body = {"metadata_identifier": lb_id, "file_format": "PNG"}
    if options:
        body["png_options"] = {"image_resolution": 1920, "image_scale": 100,
                               "include_header": True}
    if tab:
        body["tab_identifiers"] = [tab]
    return _post_report(body)


def render_pdf(lb_id, tab=None):
    body = {"metadata_identifier": lb_id, "file_format": "PDF"}
    if tab:
        body["tab_identifiers"] = [tab]
    return _post_report(body)


def _pdf_to_png(pdf_bytes, out_path):
    """Best-effort PDF page-1 → PNG using whatever converter is on PATH."""
    with tempfile.TemporaryDirectory() as td:
        pdf = os.path.join(td, "src.pdf")
        with open(pdf, "wb") as fh:
            fh.write(pdf_bytes)
        if shutil.which("pdftoppm"):
            base = os.path.join(td, "pg")
            subprocess.run(["pdftoppm", "-png", "-singlefile", "-r", "150", pdf, base],
                           check=True)
            os.replace(base + ".png", out_path)
            return
        for tool in ("magick", "convert"):
            if shutil.which(tool):
                subprocess.run([tool, "-density", "150", pdf + "[0]", out_path], check=True)
                return
        if shutil.which("sips"):
            subprocess.run(["sips", "-s", "format", "png", pdf, "--out", out_path], check=True)
            return
    raise RuntimeError(
        "PDF fallback needs a PDF→PNG converter on PATH (pdftoppm / magick / "
        "convert / sips) — none found. Install poppler (pdftoppm) or ImageMagick, "
        "or capture the source PNG manually into <workdir>/dashboards/source.png.")


def _write_sidecar(out, lb_id, mode, nbytes, reason):
    """Provenance next to the image (does NOT touch the agent's png-read.json)."""
    workdir = os.path.dirname(os.path.dirname(out))
    side = os.path.join(os.path.dirname(out), "source-render.json")
    with open(side, "w") as fh:
        json.dump({"source_png": os.path.relpath(out, workdir),
                   "liveboard_id": lb_id, "mode": mode, "bytes": nbytes,
                   "health": reason,
                   "endpoint": "POST /api/rest/2.0/report/liveboard"}, fh, indent=2)


def main():
    ap = argparse.ArgumentParser(
        description="Render a whole ThoughtSpot Liveboard to a source dashboard PNG.")
    ap.add_argument("liveboard_id", help="Liveboard GUID (or name) to render")
    ap.add_argument("--workdir",
                    default=os.environ.get("TS_WORKDIR")
                    or os.path.join(os.getcwd(), "ts-migration"),
                    help="run dir; PNG lands in <workdir>/dashboards/ (default $TS_WORKDIR or ./ts-migration)")
    ap.add_argument("--out", help="explicit output PNG path (default <workdir>/dashboards/source.png)")
    ap.add_argument("--tab", help="render only this tab GUID/name (default = whole Liveboard)")
    a = ap.parse_args()

    if not ts_lib.HOST or not ts_lib.TOKEN:
        sys.exit("FATAL: set TS_HOST and TS_TOKEN (scripts/get-ts-token.sh, or copy a "
                 "token from Develop → REST Playground). Same auth as every TS script.")

    out = a.out or os.path.join(a.workdir, "dashboards", "source.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    # ── Primary: whole-Liveboard PNG (synchronous bytes) ─────────────────────
    data = None
    try:
        try:
            data = render_png(a.liveboard_id, a.tab, options=True)
        except urllib.error.HTTPError as e:
            if e.code in (400, 422):  # older org rejects png_options → minimal body
                print("  png_options rejected; retrying minimal PNG body", file=sys.stderr)
                data = render_png(a.liveboard_id, a.tab, options=False)
            else:
                raise
    except urllib.error.HTTPError as e:
        body = e.read()[:300].decode("utf-8", "replace")
        print(f"  whole-Liveboard PNG failed ({e.code} {e.reason}: {body}); "
              "trying PDF→PNG fallback", file=sys.stderr)
    except Exception as e:  # noqa: BLE001 — any transport failure → try the fallback
        print(f"  whole-Liveboard PNG failed ({e}); trying PDF→PNG fallback", file=sys.stderr)

    if data is not None:
        ok, reason = png_health(data)
        if ok:
            with open(out, "wb") as fh:
                fh.write(data)
            print(f"✓ whole-Liveboard PNG {len(data)} bytes ({reason}) -> {out}")
            _write_sidecar(out, a.liveboard_id, "png", len(data), reason)
            return 0
        print(f"  whole-Liveboard PNG unusable ({reason}); trying PDF→PNG fallback",
              file=sys.stderr)

    # ── Fallback: whole-Liveboard PDF → PNG ──────────────────────────────────
    try:
        pdf = render_pdf(a.liveboard_id, a.tab)
    except Exception as e:  # noqa: BLE001
        sys.exit(f"FATAL: both PNG and PDF export failed for {a.liveboard_id}: {e}")
    if pdf[:5] != b"%PDF-":
        head = pdf[:200].decode("utf-8", "replace")
        sys.exit(f"FATAL: PDF export did not return a PDF (error body?): {head}")
    _pdf_to_png(pdf, out)
    with open(out, "rb") as fh:
        ok, reason = png_health(fh.read())
    if not ok:
        sys.exit(f"FATAL: converted PDF page rendered blank/invalid ({reason}) — "
                 "the source dashboard may be disconnected from its warehouse.")
    nbytes = os.path.getsize(out)
    print(f"✓ Liveboard PDF→PNG {nbytes} bytes ({reason}) -> {out}")
    _write_sidecar(out, a.liveboard_id, "pdf->png", nbytes, reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
