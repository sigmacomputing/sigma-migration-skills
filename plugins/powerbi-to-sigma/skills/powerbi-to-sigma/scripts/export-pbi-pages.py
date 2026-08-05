#!/usr/bin/env python3
"""export-pbi-pages.py — download the SOURCE Power BI report's rendered pages
for the Phase 5e visual compare, as PNGs the agent can Read with no system deps.

ExportToFile is the only agent-driven PBI render path:
  * PNG export first (multi-page comes back as a zip of per-page PNGs); PNG is
    often tenant-disabled ("Export report to image is disabled").
  * PDF fallback (almost never disabled). The PDF is then rasterized to one PNG
    per page IN THIS SCRIPT (pypdfium2 -> pdftoppm -> per-page PDF), because the
    downstream `Read` renders PNG natively but shells out to `pdftoppm` (poppler)
    for PDFs — which the agent's machine usually does NOT have. Handing over PNGs
    keeps the mandatory visual compare dependency-free.

Capacity: ExportToFile needs the report's workspace on Premium/PPU/Fabric
capacity with image/PDF export enabled. When it isn't (or export is
tenant-disabled / the job fails), this SOFT-FAILS (exit 3) with a reason and the
exact Phase-6 waiver to use — instead of crashing — so the visual-compare gate
falls back to the structural compare.

Guest/B2B: pass --tenant <guid|report-url> (or set PBI_TENANT) when the report
lives in a DIFFERENT tenant than your home tenant.

Usage:
  python3 export-pbi-pages.py --report <reportId> [--workspace <groupId>] \
      [--tenant <guid|url>] [--out-dir ./visual-qa]
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pbi_fabric as fab  # noqa: E402  (injects truststore; auth + tenant helpers)
import requests           # noqa: E402  (truststore already injected by pbi_fabric)

EXIT_NO_TOKEN = 2
EXIT_EXPORT_UNAVAILABLE = 3


def soft_fail(out_dir, reason):
    """Export can't run here — leave a machine/human readable reason and exit 3
    (non-crash) so Phase 5e degrades to a structural compare instead of aborting."""
    os.makedirs(out_dir, exist_ok=True)
    msg = (
        f"EXPORT UNAVAILABLE: {reason}\n\n"
        "ExportToFile is the only agent-driven PBI render path and needs the "
        "report's workspace on Premium/PPU/Fabric capacity with image/PDF export "
        "enabled. A structural (signals-based) compare is the expected fallback "
        "here. At the Phase-6 gate, waive the source-render bars with a reason:\n"
        "  --skip-anchors-gate  and/or  --skip-visual-similarity \"<reason>\"\n"
    )
    with open(os.path.join(out_dir, "EXPORT_UNAVAILABLE.txt"), "w") as fh:
        fh.write(msg)
    print(msg, file=sys.stderr)
    sys.exit(EXIT_EXPORT_UNAVAILABLE)


def rasterize_pdf(pdf_path, out_dir):
    """PDF -> one PNG per page. Prefer pypdfium2 (portable, pinned in
    requirements.txt, no system libraries); fall back to pdftoppm (poppler) if
    present; last resort keep per-page PDFs + a loud note. Returns the basenames
    the agent should Read, or None if only PDFs could be produced."""
    # 1) pypdfium2 + Pillow — cross-platform wheels, no system dependency
    try:
        import pypdfium2 as pdfium
        pdf = pdfium.PdfDocument(pdf_path)
        pngs = []
        for i in range(len(pdf)):
            bmp = pdf[i].render(scale=2)  # ~144 dpi
            out = os.path.join(out_dir, f"powerbi-page{i + 1}.png")
            bmp.to_pil().save(out)
            pngs.append(os.path.basename(out))
        pdf.close()
        if pngs:
            print(f"[export] rasterized {len(pngs)} page PNG(s) via pypdfium2 -> {out_dir}",
                  file=sys.stderr)
            return pngs
    except Exception as e:  # ImportError, or a render/Pillow failure
        print(f"[export] pypdfium2 rasterize unavailable ({e}); trying pdftoppm", file=sys.stderr)

    # 2) pdftoppm (poppler) if it happens to be installed
    import shutil
    import subprocess
    if shutil.which("pdftoppm"):
        prefix = os.path.join(out_dir, "powerbi-page")
        subprocess.run(["pdftoppm", "-png", "-r", "144", pdf_path, prefix], check=True)
        pngs = sorted(f for f in os.listdir(out_dir)
                      if f.startswith("powerbi-page") and f.endswith(".png"))
        print(f"[export] rasterized {len(pngs)} page PNG(s) via pdftoppm -> {out_dir}",
              file=sys.stderr)
        return pngs

    # 3) last resort — split into per-page PDFs (agent needs poppler to Read them)
    n = "?"
    try:
        from pypdf import PdfReader, PdfWriter
        rd = PdfReader(pdf_path)
        for i, pg in enumerate(rd.pages, 1):
            w = PdfWriter()
            w.add_page(pg)
            with open(os.path.join(out_dir, f"powerbi-page{i}.pdf"), "wb") as fh:
                w.write(fh)
        n = len(rd.pages)
    except Exception:
        pass
    print(f"[export] WARNING: no PNG rasterizer available — kept {n} PDF(s). `Read` needs "
          "poppler (brew install poppler) to view PDFs; install pypdfium2 (already in "
          "scripts/requirements.txt) for PNGs with no system deps.", file=sys.stderr)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--workspace", default=None, help="group id; omit for My workspace")
    ap.add_argument("--tenant", default=None,
                    help="target tenant when the report is in a DIFFERENT tenant (guest/B2B): "
                         "a raw tenant GUID, or a pasted report URL (ctid=... is extracted)")
    ap.add_argument("--out-dir", default="./visual-qa")
    a = ap.parse_args()

    # Set PBI_TENANT before get_token resolves the (call-time) authority/cache.
    if a.tenant:
        os.environ["PBI_TENANT"] = fab.normalize_tenant(a.tenant)

    tok = fab.get_token(scopes=fab.POWERBI_SCOPE)
    if not tok:
        print("NO_TOKEN — device code blocked or no client worked.", file=sys.stderr)
        sys.exit(EXIT_NO_TOKEN)
    H = {"Authorization": f"Bearer {tok}"}
    base = ("https://api.powerbi.com/v1.0/myorg" if not a.workspace
            else f"https://api.powerbi.com/v1.0/myorg/groups/{a.workspace}")
    os.makedirs(a.out_dir, exist_ok=True)

    # Capacity precheck (only determinable with an explicit workspace). ExportToFile
    # requires dedicated capacity — catch the common no-capacity case before the LRO.
    if a.workspace:
        try:
            ws = requests.get(base, headers=H, timeout=30).json()
            if ws.get("isOnDedicatedCapacity") is False:
                soft_fail(a.out_dir,
                          f"workspace '{ws.get('name', a.workspace)}' is not on dedicated capacity")
        except requests.RequestException:
            pass  # transient GET — let the export attempt surface the real error

    for fmt in ("PNG", "PDF"):  # PNG preferred; tenant-disabled falls through to PDF
        try:
            r = requests.post(f"{base}/reports/{a.report}/ExportTo",
                              headers={**H, "Content-Type": "application/json"},
                              json={"format": fmt}, timeout=60)
        except requests.RequestException as e:
            soft_fail(a.out_dir, f"ExportTo request failed: {e}")
        if r.status_code == 403 and "disabled" in r.text.lower():
            print(f"[export] {fmt} disabled at tenant level — trying next format", file=sys.stderr)
            continue
        if r.status_code >= 400:  # capacity / permission / other — degrade, don't crash
            soft_fail(a.out_dir, f"ExportTo {fmt} -> HTTP {r.status_code}: {r.text[:300]}")
        eid = r.json()["id"]
        st = {}
        for _ in range(80):
            st = requests.get(f"{base}/reports/{a.report}/exports/{eid}", headers=H, timeout=30).json()
            if st.get("status") in ("Succeeded", "Failed"):
                break
            time.sleep(5)
        if st.get("status") != "Succeeded":
            soft_fail(a.out_dir, f"export job did not succeed: {st}")
        data = requests.get(f"{base}/reports/{a.report}/exports/{eid}/file", headers=H, timeout=120).content
        if data[:2] == b"PK":  # multi-page PNG comes back zipped
            import io
            import zipfile
            zipfile.ZipFile(io.BytesIO(data)).extractall(a.out_dir)
            print(f"[export] unzipped page PNGs -> {a.out_dir}", file=sys.stderr)
        elif fmt == "PDF":
            pdf = os.path.join(a.out_dir, "powerbi-report.pdf")
            with open(pdf, "wb") as fh:
                fh.write(data)
            rasterize_pdf(pdf, a.out_dir)
        else:  # single-page PNG
            with open(os.path.join(a.out_dir, "powerbi-report.png"), "wb") as fh:
                fh.write(data)
        print(sorted(os.listdir(a.out_dir)))
        return
    soft_fail(a.out_dir, "all export formats (PNG, PDF) disabled for this tenant")


if __name__ == "__main__":
    main()
