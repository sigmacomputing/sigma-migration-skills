#!/usr/bin/env python3
"""qlik-screenshot — export PNGs of Qlik viz objects via the Qlik Cloud reporting API.

    python3 qlik-screenshot.py --app <appId> --sheet <sheetId> --out shots/    # all charts on a sheet
    python3 qlik-screenshot.py --app <appId> --viz c-cat,c-mon --out shots/     # specific viz ids

Parallels tableau-to-sigma/scripts/export-chart-png.rb — capture before/after images for a
migration. Uses the active qlik-cli context (run `qlik context use <ctx>` first).

NOTE (verified 2026-06-03): the reporting API exports a **single visualization** as PNG
(`senseImageTemplate`); whole-sheet export is PDF/PPTX only. So this screenshots each viz
on the sheet individually. KPIs/auto-charts/tables render; bare concrete chart types built
via the API render blank (see refs/sigma-build-gotchas.md).
"""
import json, os, re, subprocess, sys, argparse, time

HERE = os.path.dirname(os.path.abspath(__file__))

def qlik(*a, raw_out=False, parse=True):
    o = subprocess.run(["qlik", *a], capture_output=True, text=True)
    if raw_out: return o.stdout, o.stderr
    if not parse: return o.stdout
    try: return json.loads(o.stdout or "null")
    except json.JSONDecodeError: return None

def sheet_children(app, sheet):
    lay = qlik("app", "object", "layout", sheet, "-a", app)
    items = ((lay or {}).get("qChildList") or {}).get("qItems", [])
    out = []
    for it in items:
        info = it.get("qInfo", {})
        out.append((info.get("qId"), (it.get("qData") or {}).get("title") or info.get("qId")))
    return out

def export_png(app, viz, out_dir, w=900, h=600, zoom=2):
    os.makedirs(out_dir, exist_ok=True)
    body = {"type":"sense-image-1.0",
            "senseImageTemplate":{"appId":app,"visualization":{"id":viz,"type":"visualization","widthPx":w,"heightPx":h},"selectionsByState":{}},
            "output":{"outputId":viz,"type":"image","imageOutput":{"outZoom":zoom,"outDpi":96,"outFormat":"png"}}}
    # Keep the request body beside the requested output. `/tmp` does not exist
    # on native Windows runners, and a shared global filename races concurrent
    # captures.
    bf = os.path.join(out_dir, f"._qshot_{viz}.json")
    with open(bf, "w", encoding="utf-8") as handle:
        json.dump(body, handle)
    out, err = qlik("raw","post","v1/reports","--body-file",bf,"--verbose", raw_out=True)
    try:
        os.unlink(bf)
    except OSError:
        pass
    m = re.search(r'reports/([a-f0-9-]+)/status', err + out)
    if not m: return None, "no report id"
    rid = m.group(1)
    for _ in range(45):
        st = qlik("raw","get",f"v1/reports/{rid}/status")
        if st and st.get("status") == "done":
            loc = st["results"][0]["location"]
            path = loc.split("/api/")[-1]
            # binary-safe download (text mode corrupts PNG bytes)
            png = subprocess.run(["qlik","raw","get",path], capture_output=True).stdout
            p = os.path.join(out_dir, f"{viz}.png")
            with open(p,"wb") as f: f.write(png)
            if png[:4] != b"\x89PNG":
                return None, "not a PNG (%d bytes)" % len(png), {
                    "path": p, "status": "ERROR",
                    "reasons": ["download is not a PNG (%d bytes)" % len(png)],
                }
            # Validate the bytes immediately. A syntactically valid but blank
            # reporting-API response is a failed capture, never an OK screenshot.
            health_out = os.path.join(out_dir, f"._{viz}_health.json")
            checked = subprocess.run(
                [sys.executable, os.path.join(HERE, "png_health.py"),
                 "--image", p, "--json-out", health_out],
                capture_output=True, text=True,
            )
            try:
                with open(health_out, encoding="utf-8") as handle:
                    health = json.load(handle)
            except (OSError, json.JSONDecodeError):
                health = {
                    "path": p, "status": "ERROR",
                    "reasons": [
                        "png_health.py exited %d without readable JSON" % checked.returncode
                    ],
                }
            try:
                os.unlink(health_out)
            except OSError:
                pass
            if checked.returncode != 0 or health.get("status") != "PASS":
                return None, "PNG health %s: %s" % (
                    health.get("status", "ERROR"),
                    "; ".join(health.get("reasons") or ["unknown failure"]),
                ), health
            return p, None, health
        if st and "fail" in (st.get("status") or "").lower(): return None, "report failed"
        time.sleep(2)
    return None, "timeout", {"path": None, "status": "ERROR", "reasons": ["timeout"]}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--sheet"); ap.add_argument("--viz")
    ap.add_argument("--out", default="shots")
    ap.add_argument("--width", type=int, default=900); ap.add_argument("--height", type=int, default=600)
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    targets = []
    if a.sheet: targets = sheet_children(a.app, a.sheet)
    elif a.viz: targets = [(v, v) for v in a.viz.split(",")]
    else: sys.exit("provide --sheet or --viz")
    manifest = {}
    health = {}
    for viz, title in targets:
        result = export_png(a.app, viz, a.out, a.width, a.height)
        # Backward-compatible defensive shape for failures returned before a
        # report download (older helper branches returned a 2-tuple).
        p, err, checked = result if len(result) == 3 else (*result, {
            "path": None, "status": "ERROR", "reasons": [str(result[1])]
        })
        print(f"  {viz} ({title}): {'OK '+p if p else 'FAIL '+str(err)}")
        manifest[viz] = {"title": title, "png": p, "error": err}
        health[viz] = checked
    with open(os.path.join(a.out, "_manifest.json"), "w", encoding="utf-8") as handle:
        json.dump({key: manifest[key] for key in sorted(manifest)}, handle, indent=2)
        handle.write("\n")
    health_doc = {
        "schema_version": 1,
        "status": "PASS" if health and all(
            row.get("status") == "PASS" for row in health.values()
        ) else "FAIL",
        "checked": len(health),
        "passed": sum(row.get("status") == "PASS" for row in health.values()),
        "images": {key: health[key] for key in sorted(health)},
    }
    with open(os.path.join(a.out, "_health.json"), "w", encoding="utf-8") as handle:
        json.dump(health_doc, handle, indent=2)
        handle.write("\n")
    print(f"-> {a.out}/ ({sum(1 for v in manifest.values() if v['png'])}/{len(manifest)} ok)")
    return 0 if health_doc["status"] == "PASS" else 1

if __name__ == "__main__": sys.exit(main())
