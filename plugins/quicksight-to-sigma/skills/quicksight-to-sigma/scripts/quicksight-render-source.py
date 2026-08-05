#!/usr/bin/env python3
"""quicksight-render-source.py — render a LIVE QuickSight dashboard to a single
source PNG for the Phase-1d / Phase-6 measured visual gates.

QuickSight has NO server-side PNG render. The only server-side, whole-dashboard
image path is the async **Snapshot Export** job, which emits PDF/CSV/EXCEL (never
PNG). So this script:

  1. StartDashboardSnapshotJob  — kick off an async PDF snapshot of the whole
     dashboard (one FileGroup, FormatType=PDF, SheetSelections =
     {SheetId, SelectionScope: ALL_VISUALS} for every sheet).
       https://docs.aws.amazon.com/quicksight/latest/APIReference/API_StartDashboardSnapshotJob.html
       https://docs.aws.amazon.com/boto3/latest/reference/services/quicksight/client/start_dashboard_snapshot_job.html
     Returns {Arn, SnapshotJobId, RequestId, Status}. PDF requires ALL_VISUALS
     scope. UserConfiguration.AnonymousUsers=[{RowLevelPermissionTags:[]}] is the
     default; pass --identity-enhanced to send UserConfiguration=null instead
     (required when the caller uses identity-enhanced session credentials).
  2. DescribeDashboardSnapshotJob — poll JobStatus until COMPLETED / FAILED
     (QUEUED | RUNNING | COMPLETED | FAILED).
       https://docs.aws.amazon.com/boto3/latest/reference/services/quicksight/client/describe_dashboard_snapshot_job.html
  3. DescribeDashboardSnapshotJobResult — read the finished result's S3Uri:
     Result.AnonymousUsers[].FileGroups[].S3Results[].S3Uri (+ ErrorInfo).
       https://docs.aws.amazon.com/boto3/latest/reference/services/quicksight/client/describe_dashboard_snapshot_job_result.html
     When NO custom DestinationConfiguration is supplied (the default here), the
     S3Uri is a short-lived **presigned HTTPS URL** that downloads directly (AWS
     BI blog "Automate financial statements using QuickSight Snapshot Export
     APIs":  https://aws.amazon.com/blogs/business-intelligence/automate-financial-statements-using-amazon-quicksight-snapshot-export-apis/ ).
     With --s3-bucket the S3Uri is an s3:// path fetched via `aws s3 cp`/boto3.
  4. PDF -> PNG — render each PDF page (poppler `pdftoppm`, else PyMuPDF `fitz`,
     else `pdf2image`) and stitch the pages into one tall PNG with Pillow.
  5. Write the PNG to <workdir>/dashboards/source.png — the exact path the
     Phase-6 hard gate scans (assert-phase6-ran.rb `find_source_png`:
     png-read.json.source_png -> views/*.png -> dashboards/*.png), which ARMS
     gate 13 (source-value anchors) and gate 14 (visual-similarity floor).

REQUIREMENTS / CAVEATS (state these to the user if the job fails):
  * QuickSight **Enterprise edition** AND the **Pixel Perfect Report add-on** are
    required for PDF snapshot export. Standard edition / no add-on -> the job
    FAILS; fall back to a customer screenshot dropped at
    <workdir>/dashboards/source.png (the gate accepts any PNG there).
  * Snapshots run against a **published DASHBOARD**, not an analysis — pass
    --dashboard-id (an analysis has no snapshot endpoint).
  * Anonymous snapshot users require the account's **capacity (session) pricing**
    plan; without it use --identity-enhanced or provide registered-user config.
  * The S3 bucket (custom or the QuickSight-managed default) must be in the SAME
    region as the API call.

Auth is REUSED from quicksight-discover.py's QSApi (in-process boto3 Session with
--profile/--region when boto3 is importable; `aws quicksight ...` CLI fallback
otherwise) — the same credential source Phase-2 discovery uses. No new auth path.

Usage:
  python3 scripts/quicksight-render-source.py \
    --account-id <ACCT> --region us-east-1 --profile <P> \
    --dashboard-id <DASHBOARD_ID> --workdir <WORK>
  # -> <WORK>/dashboards/source.png  (+ <WORK>/dashboards/source.pdf, render-source.json)

  # explicit sheet(s) (default: all sheets on the dashboard):
  #   --sheet-id SHEET_A --sheet-id SHEET_B
  # custom S3 bucket instead of the presigned default:
  #   --s3-bucket my-bkt --s3-prefix qs-snapshots [--s3-region us-east-1]
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# Reuse the discovery transport (boto3 session / profile / region + CLI fallback)
# — quicksight-discover.py is hyphenated, so load it by path (mirrors
# tests/test-quicksight-discover.py).
_spec = importlib.util.spec_from_file_location(
    "qsdisc", os.path.join(HERE, "quicksight-discover.py"))
qsdisc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(qsdisc)  # noqa: E402


def _sanitize_job_id(raw):
    """SnapshotJobId accepts [\\w-]; keep it short + unique per run."""
    safe = "".join(c if (c.isalnum() or c in "-_") else "-" for c in raw)
    return f"qs-src-{safe}-{int(time.time())}"[:490]


def _sheet_ids(api, dashboard_id, workdir, explicit):
    """Sheet ids to snapshot. Explicit --sheet-id wins; else read the Phase-2
    discovery artifacts in <workdir> (signals.json / analysis.json); else ask
    QuickSight via describe-dashboard-definition."""
    if explicit:
        return list(explicit)
    for name, dig in (("signals.json", lambda j: [s.get("sheetId") for s in j.get("sheets", [])]),
                      ("analysis.json", lambda j: [s.get("SheetId")
                                                   for s in j.get("Definition", {}).get("Sheets", [])])):
        p = os.path.join(workdir, name)
        if os.path.isfile(p):
            try:
                ids = [s for s in dig(json.load(open(p))) if s]
                if ids:
                    return ids
            except (ValueError, OSError):
                pass
    # last resort: live describe (Enterprise only; simple params -> QSApi.call ok)
    d = api.call("describe-dashboard-definition", DashboardId=dashboard_id)
    return [s.get("SheetId") for s in d.get("Definition", {}).get("Sheets", []) if s.get("SheetId")]


def _start_job(api, region, profile, request):
    """StartDashboardSnapshotJob with nested params. boto3 takes the dict kwargs
    directly; the CLI fallback needs the whole request as --cli-input-json
    (QSApi.call str()-ifies dicts, which the CLI can't parse)."""
    if api.boto is not None:
        return qsdisc._jsonable(api.boto.start_dashboard_snapshot_job(**request))
    cmd = ["aws", "quicksight", "start-dashboard-snapshot-job",
           "--region", region, "--output", "json",
           "--cli-input-json", json.dumps(request)]
    if profile:
        cmd += ["--profile", profile]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"start-dashboard-snapshot-job failed: {p.stderr.strip() or p.stdout.strip()}")
    return json.loads(p.stdout or "{}")


def _download(uri, out_path, region, profile):
    """Presigned HTTPS S3Uri -> fetch directly; s3:// (custom bucket) -> aws s3 cp
    (falls back to boto3 s3 when the CLI is absent)."""
    if uri.startswith("s3://"):
        cmd = ["aws", "s3", "cp", uri, out_path, "--region", region]
        if profile:
            cmd += ["--profile", profile]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode == 0:
            return
        try:  # boto3 fallback
            import boto3
            bkt, key = uri[5:].split("/", 1)
            sess = boto3.Session(profile_name=profile, region_name=region)
            sess.client("s3").download_file(bkt, key, out_path)
            return
        except Exception as e:  # noqa: BLE001
            sys.exit(f"could not download {uri}: {p.stderr.strip() or e}")
    else:  # presigned HTTPS — no auth header needed
        req = urllib.request.Request(uri, headers={"Accept": "application/pdf"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
        except urllib.error.HTTPError as e:
            sys.exit(f"presigned download {e.code}: {e.read()[:300].decode('utf-8', 'replace')}")
        with open(out_path, "wb") as f:
            f.write(data)


def _pdf_to_pngs(pdf_path, out_dir, dpi):
    """Render every PDF page to a PNG. Try poppler `pdftoppm`, then PyMuPDF
    (`fitz`), then `pdf2image`. Returns the ordered page-PNG paths, or [] if no
    backend is available."""
    prefix = os.path.join(out_dir, "source-page")
    # 1. poppler pdftoppm (fast, no python dep)
    from shutil import which
    if which("pdftoppm"):
        r = subprocess.run(["pdftoppm", "-png", "-r", str(dpi), pdf_path, prefix],
                           capture_output=True, text=True)
        if r.returncode == 0:
            pages = sorted(p for p in
                           (os.path.join(out_dir, f) for f in os.listdir(out_dir))
                           if os.path.basename(p).startswith("source-page") and p.endswith(".png"))
            if pages:
                return pages
    # 2. PyMuPDF
    try:
        import fitz  # PyMuPDF
        doc = fitz.open(pdf_path)
        pages = []
        for i, page in enumerate(doc):
            out = f"{prefix}-{i + 1:03d}.png"
            page.get_pixmap(dpi=dpi).save(out)
            pages.append(out)
        doc.close()
        if pages:
            return pages
    except Exception:  # noqa: BLE001
        pass
    # 3. pdf2image (wraps poppler)
    try:
        from pdf2image import convert_from_path
        pages = []
        for i, img in enumerate(convert_from_path(pdf_path, dpi=dpi)):
            out = f"{prefix}-{i + 1:03d}.png"
            img.save(out, "PNG")
            pages.append(out)
        if pages:
            return pages
    except Exception:  # noqa: BLE001
        pass
    return []


def _stitch(page_pngs, out_path):
    """Vertically concatenate page PNGs into one tall image (Pillow, already a
    visual-similarity dep). Single page -> just move it."""
    if len(page_pngs) == 1:
        os.replace(page_pngs[0], out_path)
        return
    try:
        from PIL import Image
    except ImportError:
        os.replace(page_pngs[0], out_path)  # no Pillow -> first page only
        print("[warn] Pillow missing — wrote page 1 only (pip install pillow to stitch)")
        return
    imgs = [Image.open(p).convert("RGB") for p in page_pngs]
    w = max(i.width for i in imgs)
    h = sum(i.height for i in imgs)
    canvas = Image.new("RGB", (w, h), "white")
    y = 0
    for im in imgs:
        canvas.paste(im, (0, y))
        y += im.height
    canvas.save(out_path, "PNG")


def render(args):
    api = qsdisc.QSApi(args.account_id, args.region, args.profile)
    print(f"[transport] {api.transport}")

    sheet_ids = _sheet_ids(api, args.dashboard_id, args.workdir, args.sheet_id)
    if not sheet_ids:
        sys.exit("no sheet ids found (pass --sheet-id, or run discovery into --workdir first)")
    print(f"[render] dashboard {args.dashboard_id}: {len(sheet_ids)} sheet(s) -> PDF")

    job_id = _sanitize_job_id(args.dashboard_id)
    file_group = {
        "Files": [{
            "SheetSelections": [{"SheetId": sid, "SelectionScope": "ALL_VISUALS"} for sid in sheet_ids],
            "FormatType": "PDF",
        }]
    }
    snap = {"FileGroups": [file_group]}
    if args.s3_bucket:
        snap["DestinationConfiguration"] = {"S3Destinations": [{"BucketConfiguration": {
            "BucketName": args.s3_bucket,
            "BucketPrefix": args.s3_prefix or "quicksight-source-snapshots",
            "BucketRegion": args.s3_region or args.region,
        }}]}

    request = {
        "AwsAccountId": args.account_id,
        "DashboardId": args.dashboard_id,
        "SnapshotJobId": job_id,
        "SnapshotConfiguration": snap,
    }
    if not args.identity_enhanced:
        # One anonymous-user object is REQUIRED ("No anonymous user objects were
        # defined. At least one should even if it is empty") but it must be an
        # EMPTY object: botocore validates RowLevelPermissionTags as min-length 1,
        # so sending {"RowLevelPermissionTags": []} fails client-side ParamValidation.
        request["UserConfiguration"] = {"AnonymousUsers": [{}]}

    started = _start_job(api, args.region, args.profile, request)
    print(f"[render] snapshot job {job_id} started (HTTP {started.get('Status')})")

    # poll
    deadline = time.time() + args.timeout
    status = None
    while time.time() < deadline:
        js = api.call("describe-dashboard-snapshot-job",
                      DashboardId=args.dashboard_id, SnapshotJobId=job_id)
        status = js.get("JobStatus")
        print(f"[render]   status={status}")
        if status in ("COMPLETED", "FAILED"):
            break
        time.sleep(args.poll)
    if status != "COMPLETED":
        sys.exit(f"snapshot job {job_id} ended status={status or 'TIMEOUT'} "
                 f"(Enterprise + Pixel Perfect Report add-on required for PDF; "
                 f"fall back to a customer screenshot at {os.path.join(args.workdir, 'dashboards', 'source.png')})")

    result = api.call("describe-dashboard-snapshot-job-result",
                      DashboardId=args.dashboard_id, SnapshotJobId=job_id)
    # pull the first PDF S3Uri out of the (Anonymous|Registered)Users tree
    uri, err = None, None
    res = result.get("Result", {}) or {}
    for group in (res.get("AnonymousUsers") or []) + (res.get("RegisteredUsers") or []):
        for fg in group.get("FileGroups", []):
            for s3 in fg.get("S3Results", []):
                if s3.get("ErrorInfo"):
                    err = s3["ErrorInfo"]
                if s3.get("S3Uri"):
                    uri = s3["S3Uri"]
                    break
            if uri:
                break
        if uri:
            break
    if not uri:
        sys.exit(f"no S3Uri in snapshot result (errors: {json.dumps(err)})")

    dash_dir = os.path.join(args.workdir, "dashboards")
    os.makedirs(dash_dir, exist_ok=True)
    pdf_path = os.path.join(dash_dir, "source.pdf")
    _download(uri, pdf_path, args.region, args.profile)
    print(f"[render] downloaded PDF -> {pdf_path} ({os.path.getsize(pdf_path)} bytes)")

    pages = _pdf_to_pngs(pdf_path, dash_dir, args.dpi)
    out_png = args.out or os.path.join(dash_dir, "source.png")
    if not pages:
        sys.exit("PDF downloaded but no PDF->PNG backend available. Install ONE of:\n"
                 "  brew install poppler   (macOS)  |  apt-get install poppler-utils (Linux)\n"
                 "  pip install pymupdf    |  pip install pdf2image\n"
                 f"then re-run, or hand-convert {pdf_path} -> {out_png}.")
    _stitch(pages, out_png)
    # tidy intermediate page PNGs that survived the stitch
    for p in pages:
        if os.path.abspath(p) != os.path.abspath(out_png) and os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                pass
    print(f"[render] source dashboard PNG -> {out_png}  (arms Phase-6 gates 13 + 14)")

    json.dump({"dashboardId": args.dashboard_id, "snapshotJobId": job_id,
               "sheets": sheet_ids, "pages": len(pages), "pdf": pdf_path,
               "source_png": os.path.relpath(out_png, args.workdir),
               "transport": api.transport},
              open(os.path.join(args.workdir, "render-source.json"), "w"), indent=2)


def main():
    ap = argparse.ArgumentParser(description="Render a QuickSight dashboard to a source PNG (Phase-6 gates 13/14).")
    ap.add_argument("--account-id", required=True)
    ap.add_argument("--region", required=True)
    ap.add_argument("--profile")
    ap.add_argument("--dashboard-id", required=True,
                    help="PUBLISHED dashboard id (snapshots do not run on analyses)")
    ap.add_argument("--workdir", required=True,
                    help="migration workdir; PNG lands at <workdir>/dashboards/source.png")
    ap.add_argument("--sheet-id", action="append",
                    help="sheet(s) to snapshot (repeatable); default = all sheets on the dashboard")
    ap.add_argument("--out", help="output PNG path (default <workdir>/dashboards/source.png)")
    ap.add_argument("--s3-bucket", help="custom S3 bucket (default: QuickSight-managed presigned URL)")
    ap.add_argument("--s3-prefix")
    ap.add_argument("--s3-region")
    ap.add_argument("--identity-enhanced", action="store_true",
                    help="send UserConfiguration=null (required with identity-enhanced session creds)")
    ap.add_argument("--dpi", type=int, default=130, help="PDF->PNG render DPI (default 130)")
    ap.add_argument("--poll", type=int, default=5, help="poll interval seconds (default 5)")
    ap.add_argument("--timeout", type=int, default=600, help="max seconds to wait (default 600)")
    args = ap.parse_args()
    args.workdir = os.path.expanduser(args.workdir)
    render(args)


if __name__ == "__main__":
    main()
