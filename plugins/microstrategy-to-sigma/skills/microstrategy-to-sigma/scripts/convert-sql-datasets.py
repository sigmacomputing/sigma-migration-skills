#!/usr/bin/env python3
"""
convert-sql-datasets.py — MicroStrategy Freeform-SQL datasets -> Sigma data model.

Input is the `mstr-sql-datasets/1` file written by scripts/extract-sql-dataset.py
(contract + status: refs/sql-datasets.md): per dataset, the report's SQL text plus
the MicroStrategy attribute forms / metrics it maps to. Output is a Sigma data
model spec with ONE Custom SQL element per dataset:

  - element: id `sql-<slug(name)>` (suffixed -2, -3… when datasets slug alike;
    a repeated report name becomes "<name> (<reportId>)"), source {kind: sql,
    connectionId, statement}. The statement must pass the same read-only
    single-statement guard as convert.py --multi-fact-sql; a statement that fails
    it is invalid input (exit 1).
  - columns: one per output alias of the statement's final SELECT, in SQL order,
    `[Custom SQL/<alias>]`. Aliases are matched to MicroStrategy objects by an
    explicit column map first (--column-map, then the record's `columnMap`), then
    by name (lib/sql_dataset.py match_columns). Display name = metric name; the
    attribute name for its DESC form (or a sole form); "<Attribute> <Form>" for
    other forms; a friendly-cased alias for an alias no object claims. A metric's
    row-level column is "<Metric> (SQL column)" so it never shares the metric's
    name (Sigma can drop an element's metrics from readback on that collision).
  - metrics: one per metric object, `<aggregate>([<display>])`, the aggregate
    resolved from refs/catalogs/aggregation.json. Freeform-SQL metrics roll up by
    the metric's dynamic-aggregation setting, which the REST API does not expose:
    Sum is assumed and recorded as a review gap.

Every ambiguity is a loud gap, never a guess (blocking = wrong/missing data,
review = a semantic choice to confirm):
  blocking  capture failed (record carries `error`); select list not derivable
            and no column map; an object no alias matched (a fill-in template
            for --column-map is written with --column-map-template-out); a
            column-map entry that names no object / alias.
  review    the Sum assumption; each prompt (its answer is baked into the SQL);
            SQL aliases no object claims; capture warnings.

Usage:
  python3 scripts/convert-sql-datasets.py --datasets sql-datasets.json \
      --connection-id <uuid> --folder-id <uuid> [--dm-name NAME] \
      [--column-map map.json] [--column-map-template-out tpl.json] \
      [--out sigma_dm_spec.json] [--gaps-out sql-dataset-gaps.json] [--allow-gaps]

--column-map is `{"<reportId or report name>": [{"alias": "...", "object":
"<object name>", "form": "<form or null>"}]}`.

Exit 0 = no blocking gaps; 2 = blocking gaps (outputs still written for review;
pass --allow-gaps to exit 0); 1 = invalid input (nothing written).
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import coverage_catalog as _cc  # noqa: E402
import sql_dataset as _sd       # noqa: E402

_CAT_DIR = _cc.default_catalog_dir(__file__)
AGG_CAT = _cc.load(_CAT_DIR, "aggregation")   # MSTR group function -> Sigma aggregate

FORMAT_ID = "mstr-sql-datasets/1"
ASSUMED_AGG = "Sum"        # MSTR group function assumed for freeform-SQL metrics (catalog key)
METRIC_COLUMN_SUFFIX = " (SQL column)"   # row-level column behind a metric; keeps names distinct


class InputError(Exception):
    pass


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", str(s).lower()).strip("-")


def friendly(alias):
    """ALL_CAPS / all_lower warehouse-style names -> Title Case; anything already
    mixed-case or spaced is the author's choice and is kept."""
    if re.fullmatch(r"[A-Z0-9_]+", alias) or re.fullmatch(r"[a-z0-9_]+", alias):
        return " ".join(p.capitalize() for p in alias.split("_"))
    return alias


def _unique(base, used):
    cand, n = base, 2
    while cand in used:
        cand = "%s-%d" % (base, n)
        n += 1
    used.add(cand)
    return cand


class Converter:
    def __init__(self, args, doc, column_map):
        self.args = args
        self.doc = doc
        self.column_map = column_map or {}
        self.gaps, self.warnings, self.template = [], [], {}
        self.elements = []
        self.used_element_keys, self.used_element_names = set(), set()
        self.used_column_ids, self.used_metric_ids = set(), set()
        self.n_columns = self.n_metrics = 0
        agg = AGG_CAT.resolve(ASSUMED_AGG)
        self.agg = agg["sigma"] if agg else None

    # -------------------------------------------------------------- gaps
    def gap(self, rec, construct, severity, detail):
        self.gaps.append({"dataset": rec.get("name") or rec.get("reportId"), "reportId": rec.get("reportId"),
                          "construct": construct, "severity": severity, "detail": detail})

    # -------------------------------------------------------------- column map
    def _explicit_entries(self, rec):
        """--column-map entries first, then the record's `columnMap` entries for
        aliases and objects the CLI map leaves open (a filled-in template covers
        only the unmatched objects, so it must not drop hand-edited record entries)."""
        cli = []
        for key in (rec.get("reportId"), rec.get("name")):
            if key is not None and key in self.column_map:
                cli = [e for e in self.column_map[key] if isinstance(e, dict)]
                break

        def obj_key(e):
            return (str(e.get("object") or "").casefold(), str(e.get("form") or "").casefold())

        cli_aliases = {str(e.get("alias") or "").casefold() for e in cli if e.get("alias")}
        cli_objects = {obj_key(e) for e in cli if e.get("alias")}
        merged = list(cli)
        for e in rec.get("columnMap") or []:
            if not isinstance(e, dict):
                continue
            if str(e.get("alias") or "").casefold() in cli_aliases or obj_key(e) in cli_objects:
                continue
            merged.append(e)
        return merged

    @staticmethod
    def _resolve_object(entry, objects):
        """Entry {alias, object, form} -> one object of the record, or None."""
        name = str(entry.get("object") or "").casefold()
        form = entry.get("form")
        hits = [o for o in objects if str(o.get("name") or "").casefold() == name]
        metrics = [o for o in hits if o.get("kind") == "metric"]
        attrs = [o for o in hits if o.get("kind") == "attribute"]
        if form not in (None, ""):
            by_form = [o for o in attrs if str(o.get("form") or "").casefold() == str(form).casefold()]
            return by_form[0] if len(by_form) == 1 else (metrics[0] if len(metrics) == 1 and not attrs else None)
        if len(metrics) == 1 and not attrs:
            return metrics[0]
        desc = [o for o in attrs if str(o.get("form") or "").upper() == "DESC"]
        if len(desc) == 1 and not metrics:
            return desc[0]
        if len(attrs) == 1 and not metrics:
            return attrs[0]
        return None

    @staticmethod
    def _display(obj, objects):
        if obj.get("kind") == "metric":
            # The DM metric keeps the MicroStrategy name; its row-level source column
            # must not share it (Sigma can drop an element's metrics from readback on
            # a metric/column name collision — tableau-to-sigma/refs/phase-3-datamodel.md).
            return "%s%s" % (obj["name"], METRIC_COLUMN_SUFFIX)
        form = obj.get("form")
        siblings = [o for o in objects if o.get("kind") == "attribute"
                    and (o.get("id"), o.get("name")) == (obj.get("id"), obj.get("name"))]
        if not form or str(form).upper() == "DESC" or len(siblings) == 1:
            return obj["name"]
        return "%s %s" % (obj["name"], form)

    # -------------------------------------------------------------- one dataset
    def convert_dataset(self, rec):
        name = rec.get("name") or rec.get("reportId")
        if not isinstance(rec, dict) or not name:
            raise InputError("dataset record without a name/reportId: %r" % (rec,))
        if rec.get("error"):
            self.gap(rec, "capture failed", "blocking",
                     "extraction could not capture this dataset: %s. Re-run extract-sql-dataset.py "
                     "(with --allow-execute if the SQL is only available from an executed report) "
                     "or add the SQL to the record by hand." % rec["error"])
            return
        try:
            sql = _sd.guard_sql(_sd.strip_leading_comments(rec.get("sql")),
                                "SQL for dataset '%s'" % name)
        except SystemExit as e:
            raise InputError(str(e.code))
        objects = [o for o in (rec.get("objects") or []) if isinstance(o, dict)]
        for w in rec.get("warnings") or []:
            self.gap(rec, "capture warning", "review", w)

        aliases = _sd.select_aliases(sql)
        entries = [e for e in self._explicit_entries(rec) if isinstance(e, dict) and e.get("alias")]
        if aliases is None:
            if not entries:
                self.gap(rec, "select list not derivable", "blocking",
                         "the final SELECT list has a `*` or an unnamed expression, so the output "
                         "columns cannot be read from the SQL. Supply them with --column-map "
                         "(one {alias, object, form} entry per output column, in SQL order); no "
                         "element is emitted for this dataset until then.")
                return
            aliases = []
            for e in entries:
                if e["alias"] not in aliases:
                    aliases.append(e["alias"])
            self.warnings.append("%s: output columns and their order come from the column map, not the SQL "
                                 "(select list not derivable); verify against the statement." % name)

        # explicit entries first; name matching only fills what they leave open
        by_alias, taken = {}, set()
        folded = {a.casefold(): a for a in aliases}
        for e in entries:
            alias = e["alias"] if e["alias"] in aliases else folded.get(str(e["alias"]).casefold())
            obj = self._resolve_object(e, objects)
            if alias is None:
                self.gap(rec, "column map entry unresolved", "blocking",
                         "column map alias %r is not an output column of the SQL (%s)."
                         % (e["alias"], ", ".join(repr(a) for a in aliases)))
            elif obj is None:
                self.gap(rec, "column map entry unresolved", "blocking",
                         "column map entry for alias %r names %r (form %r), which matches no single "
                         "object of this report." % (alias, e.get("object"), e.get("form")))
            else:
                by_alias[alias] = obj
                taken.add(id(obj))
        rest_aliases = [a for a in aliases if a not in by_alias]
        rest_objects = [o for o in objects if id(o) not in taken]
        matched, unmatched, unused = _sd.match_columns(rest_aliases, rest_objects)
        by_alias.update(matched)

        # element key: unique across datasets (two reports can share a name, or names
        # can slug alike: "P&L" / "P L"), so element, column and metric ids never collide
        key = _unique(slug(name) or "dataset", self.used_element_keys)
        element_name = name
        if element_name in self.used_element_names:
            element_name = "%s (%s)" % (name, rec.get("reportId") or key)
            self.gap(rec, "duplicate dataset name", "review",
                     "another dataset is already named %r; this element is named %r." % (name, element_name))
        self.used_element_names.add(element_name)

        # columns, in SQL order
        columns, used_names, display_of = [], set(), {}
        for alias in aliases:
            obj = by_alias.get(alias)
            display = self._display(obj, objects) if obj else friendly(alias)
            if display in used_names:
                self.gap(rec, "duplicate column name", "review",
                         "two output columns would both be named %r; %r is renamed %r." %
                         (display, alias, "%s (%s)" % (display, alias)))
                display = "%s (%s)" % (display, alias)
            used_names.add(display)
            display_of[id(obj) if obj else alias] = display
            columns.append({"id": _unique("c-%s-%s" % (key, slug(display)), self.used_column_ids),
                            "name": display, "formula": "[Custom SQL/%s]" % alias})

        # metrics: one per matched metric object
        metrics = []
        for obj in objects:
            if obj.get("kind") == "metric" and id(obj) in {id(o) for o in by_alias.values()}:
                if not self.agg:
                    self.gap(rec, "metric aggregation", "blocking",
                             "the aggregation catalog has no row for %r." % ASSUMED_AGG)
                    break
                disp = display_of[id(obj)]
                metrics.append({"id": _unique("m-%s-%s" % (key, slug(obj["name"])), self.used_metric_ids),
                                "name": obj["name"], "formula": "%s([%s])" % (self.agg, disp)})

        # gaps
        if unmatched:
            tpl_path = self.args.column_map_template_out
            hint = ("Fill in the `alias` of each entry in %s and pass it back with --column-map." % tpl_path
                    if tpl_path else
                    "Re-run with --column-map-template-out <file> for a fill-in template, then pass it "
                    "back with --column-map.")
            for o in unmatched:
                what = ("metric %r" % o.get("name") if o.get("kind") == "metric"
                        else "attribute %r form %r" % (o.get("name"), o.get("form")))
                self.gap(rec, "unmatched object", "blocking",
                         "no SQL output column matched %s. Output columns no object claimed: %s. %s"
                         % (what, ", ".join(repr(a) for a in unused) or "none", hint))
                self.template.setdefault(rec.get("reportId") or name, []).append(
                    {"alias": None, "object": o.get("name"), "form": o.get("form")})
        for a in unused:
            self.gap(rec, "unused SQL alias", "review",
                     "output column %r matched no MicroStrategy object; it is kept as a plain column "
                     "named %r." % (a, friendly(a)))
        if metrics:
            self.gap(rec, "metric aggregation", "review",
                     "freeform-SQL metrics roll up by each metric's dynamic-aggregation setting, which the "
                     "REST API does not expose; %s is assumed (%s). Confirm against the source report and "
                     "in parity." % (ASSUMED_AGG, ", ".join(m["formula"] for m in metrics)))
        for p in rec.get("prompts") or []:
            self.gap(rec, "prompt: %s" % (p.get("name") or p.get("id")), "review",
                     "answer %s is baked into the captured SQL; recreate as a Sigma control/parameter "
                     "if users need to change it." % json.dumps(p.get("answer"), ensure_ascii=False))

        self.elements.append({
            "id": "sql-%s" % key, "kind": "table", "name": element_name,
            "source": {"kind": "sql", "connectionId": self.args.connection_id, "statement": sql},
            "columns": columns, "metrics": metrics})
        self.n_columns += len(columns)
        self.n_metrics += len(metrics)

    def run(self):
        datasets = self.doc.get("datasets")
        if self.doc.get("format") != FORMAT_ID or not isinstance(datasets, list) or not datasets:
            raise InputError("expected an %s file with a non-empty `datasets` list" % FORMAT_ID)
        for rec in datasets:
            if not isinstance(rec, dict):
                raise InputError("dataset record is not an object: %r" % (rec,))
            self.convert_dataset(rec)
        first = datasets[0].get("name") or datasets[0].get("reportId")
        return {"name": self.args.dm_name or "%s (MSTR SQL datasets)" % first,
                "folderId": self.args.folder_id, "schemaVersion": 1,
                "pages": [{"id": "page-1", "name": "Model", "elements": self.elements}]}


def _write(path, obj):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--datasets", required=True, help="mstr-sql-datasets/1 file from extract-sql-dataset.py")
    ap.add_argument("--connection-id", required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--dm-name", default=None, help="default: '<first dataset name> (MSTR SQL datasets)'")
    ap.add_argument("--column-map", default=None, help="JSON: reportId/name -> [{alias, object, form}]")
    ap.add_argument("--column-map-template-out", default=None,
                    help="write a fill-in --column-map template for objects no alias matched")
    ap.add_argument("--out", default="sigma_dm_spec.json")
    ap.add_argument("--gaps-out", default="sql-dataset-gaps.json")
    ap.add_argument("--allow-gaps", action="store_true", help="exit 0 even with blocking gaps")
    args = ap.parse_args(argv)
    try:
        with open(args.datasets, encoding="utf-8") as fh:
            doc = json.load(fh)
        column_map = None
        if args.column_map:
            with open(args.column_map, encoding="utf-8") as fh:
                column_map = json.load(fh)
            if not isinstance(column_map, dict) or not all(isinstance(v, list) for v in column_map.values()):
                raise InputError("--column-map must be {reportId|name: [{alias, object, form}]}")
        conv = Converter(args, doc, column_map)
        spec = conv.run()
    except (InputError, OSError, ValueError, KeyError, AttributeError) as e:
        print("convert-sql-datasets: invalid input: %s" % e, file=sys.stderr)
        return 1
    blocking = [g for g in conv.gaps if g["severity"] == "blocking"]
    gaps = {"blocking": len(blocking), "gaps": conv.gaps, "warnings": conv.warnings}
    _write(args.out, spec)
    _write(args.gaps_out, gaps)
    if args.column_map_template_out and conv.template:
        _write(args.column_map_template_out, conv.template)
    print("wrote %s (%d dataset element(s), %d columns, %d metrics) + %s (%d gaps: %d blocking, %d review)"
          % (args.out, len(conv.elements), conv.n_columns, conv.n_metrics, args.gaps_out, len(conv.gaps),
             len(blocking), len(conv.gaps) - len(blocking)))
    if args.column_map_template_out and conv.template:
        print("  wrote column-map template %s (fill in `alias`, pass back with --column-map)"
              % args.column_map_template_out)
    for w in conv.warnings:
        print("  " + w)
    if blocking and not args.allow_gaps:
        for g in blocking:
            print("  BLOCKING %s: %s — %s" % (g["dataset"], g["construct"], g["detail"]), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
