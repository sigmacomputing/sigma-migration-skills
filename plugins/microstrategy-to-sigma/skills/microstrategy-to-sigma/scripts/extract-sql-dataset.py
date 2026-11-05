#!/usr/bin/env python3
"""
extract-sql-dataset.py — capture hand-written (Freeform SQL) MicroStrategy dataset
reports as `mstr-sql-dataset/1` records, WITHOUT running them by default.

Usage:
  python3 scripts/extract-sql-dataset.py <reportId> [<reportId> ...] \
      [--document <docId>] [--allow-execute] --out sql-datasets.json

  <reportId>        a dataset report (repeatable)
  --document <id>   also capture every dataset report the Report Services document
                    / dossier uses, listed via
                    GET /searches/results?usedByObject=<id>;55&type=3.
                    UNVERIFIED against a live server (refs/sql-datasets.md);
                    pass report ids explicitly if the listing fails.
  --allow-execute   when the SQL cannot be read without running the report, run it
                    ONCE against the warehouse (POST /v2/reports/{id}/instances?limit=1)
                    and read the SQL from its sqlView. Off by default: DBAs flag
                    warehouse CPU, and resolve_prompts normally yields the SQL
                    without executing anything.

Output: {"format": "mstr-sql-datasets/1", "_extraction": {...}, "datasets": [record, ...]}
(record contract: lib/sql_dataset.py capture(); doc: refs/sql-datasets.md). A report
that cannot be captured is written as {"reportId", "name", "error"} so the converter
reports it as a blocking gap. Exit 0 = every report captured, 2 = some failed
(output still written), 1 = usage error / document listing failed.
Credentials: scripts/mstr.py (MSTR_BASE_URL / MSTR_USERNAME / MSTR_PASSWORD).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import sql_dataset  # noqa: E402

FORMAT_ID = "mstr-sql-datasets/1"
DOCUMENT_TYPE = 55          # MicroStrategy object type for documents / dossiers


def list_document_datasets(s, document_id, limit=500):
    """[{id, name}] of the report objects a document uses (paginated, UNVERIFIED shape)."""
    out, offset = [], 0
    while True:
        r = s.get(f"/searches/results?usedByObject={document_id};{DOCUMENT_TYPE}"
                  f"&type=3&offset={offset}&limit={limit}")
        items = (r or {}).get("result", []) if isinstance(r, dict) else (r or [])
        out.extend(items)
        offset += len(items)
        total = r.get("totalItems", 0) if isinstance(r, dict) else 0
        if not items or offset >= total:
            return out


def main(argv=None, session=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("report_ids", nargs="*", metavar="reportId")
    ap.add_argument("--document", default=None, help="capture the document's dataset reports (UNVERIFIED listing)")
    ap.add_argument("--allow-execute", action="store_true",
                    help="run a report once against the warehouse when its SQL cannot be read otherwise")
    ap.add_argument("--out", default="sql-datasets.json")
    args = ap.parse_args(argv)
    if not args.report_ids and not args.document:
        print("extract-sql-dataset: give at least one <reportId> or --document <docId>", file=sys.stderr)
        return 1
    if session is None:
        import mstr
        session = mstr.Session()

    names = {}
    ids = list(args.report_ids)
    if args.document:
        try:
            for item in list_document_datasets(session, args.document):
                if item.get("id"):
                    ids.append(item["id"])
                    names[item["id"]] = item.get("name")
        except Exception as e:  # noqa: BLE001
            print("extract-sql-dataset: could not list the datasets of document %s (%s). "
                  "This listing is unverified; pass the report ids explicitly." % (args.document, e),
                  file=sys.stderr)
            return 1
    ids = list(dict.fromkeys(ids))

    datasets, failed = [], 0
    for rid in ids:
        try:
            datasets.append(sql_dataset.capture(session, rid, allow_execute=args.allow_execute))
        except Exception as e:  # noqa: BLE001 — record it, keep going
            failed += 1
            datasets.append({"reportId": rid, "name": names.get(rid) or rid, "error": str(e)})
            print("  FAILED %s: %s" % (rid, e), file=sys.stderr)
    doc = {"format": FORMAT_ID,
           "_extraction": {"retrievedAtUtc": sql_dataset.utc_now(), "reportIds": ids,
                           "document": args.document, "allowExecute": bool(args.allow_execute)},
           "datasets": datasets}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print("wrote %s: %d dataset(s), %d failed" % (args.out, len(datasets), failed))
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
