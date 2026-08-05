#!/usr/bin/env python3
"""microstrategy-render-source.py — render a MicroStrategy dossier to a single
source dashboard PNG for the Phase-6 MEASURED parity gates in assert-phase6-ran.rb:
gate 13 (source-anchor value verification) + gate 14 (visual-similarity floor).
Those gates arm the moment a source dashboard PNG is on disk under
<workdir>/dashboards/*.png (or views/*.png, or png-read.json source_png); this
script lands that image.

API (MicroStrategy REST — same session-bound flow export-dossier-pdf.py already uses):
  POST /api/dossiers/{id}/instances            -> { "mid": <instanceId> }
  POST /api/documents/{id}/instances/{mid}/pdf -> { "data": <base64 PDF> }
  (v1 path; /v2/dossiers/.../pdf 404s on the validated build.)
  Docs: https://github.com/MicroStrategy/rest-api-docs/blob/public/docs/common-workflows/analytics/export-to-pdf.md

MicroStrategy has no native whole-dossier PNG endpoint, so we export the dossier
to PDF (always supported) and convert page 1 -> PNG with whatever rasterizer is
on PATH (pdftoppm > magick/convert > sips). Best-effort: if none is installed the
script says exactly that and exits non-zero rather than land a bad image.

Auth: reuses lib/mstr.py Session (same credential path as export-dossier-pdf.py /
migrate) — no new credential source. Output: <workdir>/dashboards/source.png,
auto-discovered by gate 13/14. A multi-page dossier's PDF has one page per
chapter/page — page 1 is captured; pick another with --page.

Usage:
  python3 microstrategy-render-source.py <dossierId> [--workdir DIR] [--out PATH] [--page N]
Env: whatever lib/mstr.py Session reads (MSTR base URL + auth).
"""
import argparse
import base64
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mstr  # noqa: E402  — same Session/auth as export-dossier-pdf.py


def export_pdf(dossier_id):
    """Return the dossier's rendered PDF bytes (instance + export in ONE session)."""
    s = mstr.Session()
    iid = s.post(f"/dossiers/{dossier_id}/instances", {})["mid"]
    resp = s.post(f"/documents/{dossier_id}/instances/{iid}/pdf", {})
    if "data" not in resp:
        raise RuntimeError(f"PDF export returned no data: {str(resp)[:200]}")
    return base64.b64decode(resp["data"])


def pdf_to_png(pdf_bytes, out_path, page=1):
    """Best-effort PDF page -> PNG using whatever converter is on PATH."""
    with tempfile.TemporaryDirectory() as td:
        pdf = os.path.join(td, "src.pdf")
        with open(pdf, "wb") as fh:
            fh.write(pdf_bytes)
        if shutil.which("pdftoppm"):
            base = os.path.join(td, "pg")
            subprocess.run(["pdftoppm", "-png", "-r", "150", "-f", str(page),
                            "-l", str(page), "-singlefile", pdf, base], check=True)
            os.replace(base + ".png", out_path)
            return
        for tool in ("magick", "convert"):
            if shutil.which(tool):
                subprocess.run([tool, "-density", "150", f"{pdf}[{page - 1}]", out_path],
                               check=True)
                return
        if shutil.which("sips") and page == 1:  # sips can't select a page
            subprocess.run(["sips", "-s", "format", "png", pdf, "--out", out_path], check=True)
            return
    raise RuntimeError(
        "PDF->PNG needs a converter on PATH (pdftoppm / magick / convert / sips) — "
        "none found (or --page>1 with only sips). Install poppler (pdftoppm) or "
        "ImageMagick, or drop the source PNG manually into <workdir>/dashboards/source.png.")


def main():
    ap = argparse.ArgumentParser(
        description="Render a MicroStrategy dossier to a source dashboard PNG.")
    ap.add_argument("dossier_id", help="dossier GUID to render")
    ap.add_argument("--workdir", default=os.environ.get("MSTR_WORKDIR") or os.getcwd(),
                    help="run dir; PNG lands in <workdir>/dashboards/ (default $MSTR_WORKDIR or cwd)")
    ap.add_argument("--out", help="explicit output PNG path (default <workdir>/dashboards/source.png)")
    ap.add_argument("--page", type=int, default=1, help="PDF page to rasterize (default 1)")
    a = ap.parse_args()

    out = a.out or os.path.join(a.workdir, "dashboards", "source.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    try:
        pdf = export_pdf(a.dossier_id)
    except Exception as e:  # noqa: BLE001 — surface, never crash a migration
        sys.exit(f"FATAL: dossier PDF export failed for {a.dossier_id}: {e}")
    if pdf[:5] != b"%PDF-":
        sys.exit(f"FATAL: export did not return a PDF (error body?): {pdf[:200]!r}")
    pdf_to_png(pdf, out, a.page)
    if not os.path.exists(out) or os.path.getsize(out) < 1000:
        sys.exit(f"FATAL: rendered PNG missing/too small at {out} — check the PDF converter.")
    print(f"wrote {out} ({os.path.getsize(out)} bytes) — READ it, transcribe >=5 "
          "anchors into <workdir>/source-anchors.json (refs/source-anchors.md)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
