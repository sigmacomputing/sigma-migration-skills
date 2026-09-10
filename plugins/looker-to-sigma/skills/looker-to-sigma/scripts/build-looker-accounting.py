#!/usr/bin/env python3
"""Build deterministic Looker source-object and coverage accounting artifacts.

This is an offline reconciler.  It inventories the source from the LookML audit
artifacts and dashboard/Look contract, then derives terminal status from the
converter mapping, built Sigma specs/readback, parity, and control scope.
"""

import argparse
import json
import os
import re
import sys
from collections import Counter, OrderedDict
from pathlib import Path


TERMINAL = ("migrated", "approximated", "needs-review", "skipped", "not-applicable")
PASS_WORDS = {"pass", "passed", "green", "ok", "success", "successful", "clean"}
EXACT_WORDS = {"exact", "mapped", "resolved", "pass", "passed", "clean", "emitted", "built"}
APPROX_WORDS = {
    "approximate", "approximated", "approximation", "partial", "degraded",
    "substituted", "caveat",
}
OMIT_WORDS = {"omitted", "skipped", "dropped", "not-emitted", "excluded"}
BLOCK_WORDS = {
    "blocked", "unresolved", "needs-review", "review", "failed", "fail",
    "error", "unsupported", "unmapped", "manual", "pending", "needs-wiring",
}


class InputError(Exception):
    """Invocation or source-artifact error (exit 2)."""


def folded(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def slug_part(value):
    text = re.sub(r"\s+", " ", str(value or "").strip())
    return text or "unnamed"


def humanize(value):
    return re.sub(r"\s+", " ", re.sub(r"[_-]+", " ", str(value or ""))).strip().title()


def mapping_class(value):
    word = str(value or "").strip().lower().replace("_", "-").replace(" ", "-")
    if word in EXACT_WORDS:
        return "exact"
    if word in APPROX_WORDS:
        return "approximate"
    if word in OMIT_WORDS:
        return "omitted"
    if word in BLOCK_WORDS:
        return "blocked"
    return None


def json_path(workdir, explicit, patterns, required=False):
    if explicit:
        path = Path(explicit)
        if not path.is_absolute():
            path = workdir / path
        if not path.is_file():
            raise InputError("artifact does not exist: %s" % path)
        return path.resolve()
    for pattern in patterns:
        matches = sorted(path for path in workdir.glob(pattern) if path.is_file())
        if matches:
            return matches[0].resolve()
    if required:
        raise InputError("required artifact not found (tried %s)" % ", ".join(patterns))
    return None


def read_json(path):
    if path is None:
        return None
    try:
        with path.open(encoding="utf-8-sig") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise InputError("malformed JSON %s: %s" % (path, exc)) from exc
    except OSError as exc:
        raise InputError("cannot read %s: %s" % (path, exc)) from exc


def document_root(doc):
    if not isinstance(doc, dict):
        return {}
    return doc.get("document") if isinstance(doc.get("document"), dict) else doc


def normalize_formula(value):
    return re.sub(r"\s+", "", str(value or "")).lower()


class LookerAccounting:
    def __init__(self, workdir, paths, docs):
        self.workdir = workdir
        self.paths = paths
        self.docs = docs
        self.objects = OrderedDict()
        self.errors = []
        self.unaccounted = set()
        self.contradictory = set()
        self.contracts = []
        self.field_records = {}
        self.formula_records = {}
        self.root_readiness = mapping_class(
            docs["readiness"].get("readiness") if isinstance(docs["readiness"], dict) else None
        )
        self.wb_elements = []
        self.wb_pages = []
        self.wb_controls = []
        self.dm_elements = []
        self.dm_relationships = []
        self.dm_formulas = set()
        self.dm_filter_text = ""
        self.warning_rows = []
        self.control_rows = {}
        self.control_output_rows = []
        self.parity_green = False
        self.parity_pass = set()
        self.parity_fail = set()

    def artifact_name(self, kind):
        path = self.paths.get(kind)
        if path is None:
            return kind
        try:
            return str(path.relative_to(self.workdir))
        except ValueError:
            return str(path)

    def evidence(self, kind, detail):
        return {"artifact": self.artifact_name(kind), "detail": str(detail or "recorded")}

    def add_object(self, obj_type, obj_id, name, kind, detail, **meta):
        key = (str(obj_type), str(obj_id))
        if key not in self.objects:
            self.objects[key] = {
                "type": str(obj_type),
                "id": str(obj_id),
                "name": str(name or obj_id),
                "evidence": [],
                "_meta": {},
                "_mapping": [],
                "_accounted": True,
            }
        obj = self.objects[key]
        obj["evidence"].append(self.evidence(kind, detail))
        for meta_key, value in meta.items():
            if value is not None:
                obj["_meta"].setdefault(meta_key, value)
        return obj

    def add_mapping(self, obj, value, kind, detail):
        classification = mapping_class(value)
        if classification:
            obj["_mapping"].append((classification, self.evidence(kind, detail)))

    def inventory(self):
        self._inventory_readiness()
        self._inventory_fields()
        self._inventory_contracts()
        if not self.objects:
            raise InputError("source artifacts contain no recognizable Looker objects")

    def _inventory_readiness(self):
        doc = self.docs["readiness"]
        if not isinstance(doc, dict):
            raise InputError("readiness artifact must be a JSON object")

        # Newer audits may expose project/model rows.  Scalar names are accepted
        # too, without inventing them from filenames.
        for key, obj_type in (("projects", "project"), ("models", "model")):
            for row in doc.get(key) or []:
                if not isinstance(row, dict):
                    continue
                name = row.get("name") or row.get("id")
                if name:
                    obj = self.add_object(obj_type, "%s:%s" % (obj_type, slug_part(name)), name,
                                          "readiness", "%s audit object" % obj_type, record=row)
                    self.add_mapping(obj, row.get("mapping") or row.get("readiness") or row.get("status"),
                                     "readiness", "%s readiness" % obj_type)
        for key, obj_type in (("project", "project"), ("projectName", "project"),
                              ("model", "model"), ("modelName", "model")):
            value = doc.get(key)
            if isinstance(value, str) and value.strip():
                self.add_object(obj_type, "%s:%s" % (obj_type, slug_part(value)), value,
                                "readiness", "%s audit identity" % obj_type)

        for row in doc.get("views") or []:
            if not isinstance(row, dict):
                continue
            name = row.get("name") or row.get("id")
            if not name:
                continue
            obj = self.add_object("view", "view:%s" % slug_part(name), name, "readiness",
                                  "LookML view %s" % name, record=row)
            self.add_mapping(obj, row.get("mapping") or row.get("readiness") or row.get("status"),
                             "readiness", "view mapping")
            if row.get("derivedTable") is True:
                self._add_derived({"view": name, "name": name, "status": row.get("status")},
                                  "derived table declared on view")
            self._add_filters(row.get("filters"), "view", name, "filter")
            self._add_filters(row.get("accessFilters"), "view", name, "access-filter")

        for row in doc.get("explores") or []:
            if not isinstance(row, dict):
                continue
            name = row.get("name") or row.get("id")
            if not name:
                continue
            obj = self.add_object("explore", "explore:%s" % slug_part(name), name, "readiness",
                                  "LookML explore %s" % name, record=row)
            self.add_mapping(obj, row.get("mapping") or row.get("readiness") or row.get("status"),
                             "readiness", "explore mapping")
            self._add_filters(row.get("filters"), "explore", name, "filter")
            self._add_filters(row.get("accessFilters"), "explore", name, "access-filter")
            self._add_filters(row.get("alwaysFilters"), "explore", name, "always-filter")

        for row in doc.get("joins") or []:
            if not isinstance(row, dict):
                continue
            explore = row.get("explore") or "unknown"
            name = row.get("alias") or row.get("name") or row.get("from")
            if not name:
                continue
            obj = self.add_object(
                "join", "join:%s:%s" % (slug_part(explore), slug_part(name)), name,
                "readiness", "join %s on explore %s" % (name, explore), record=row,
            )
            join_state = row.get("mapping") or row.get("readiness") or row.get("status")
            if not join_state and row.get("keyParseStatus"):
                join_state = "exact" if str(row["keyParseStatus"]).lower() == "parsed" else "blocked"
            self.add_mapping(obj, join_state, "readiness",
                             "join key parse=%s" % (row.get("keyParseStatus") or "not recorded"))

        for row in doc.get("derivedTables") or doc.get("derived_tables") or []:
            if isinstance(row, dict):
                self._add_derived(row, "derived table audit row")
            elif row:
                self._add_derived({"name": row, "view": row}, "derived table audit row")

        for key, filter_type in (
            ("filters", "filter"), ("accessFilters", "access-filter"),
            ("access_filters", "access-filter"), ("alwaysFilters", "always-filter"),
            ("always_filters", "always-filter"),
        ):
            self._add_filters(doc.get(key), "model", doc.get("model") or "project", filter_type)

    def _add_derived(self, row, detail):
        view = row.get("view") or row.get("name") or row.get("id")
        if not view:
            return
        obj = self.add_object("derived-table", "derived-table:%s" % slug_part(view),
                              row.get("name") or view, "readiness", detail, record=row)
        state = row.get("mapping") or row.get("readiness") or row.get("status")
        if not state and (row.get("kind") == "native" or row.get("persistent") is True):
            state = "approximate"
        elif not state and row.get("kind") == "sql":
            state = "exact"
        self.add_mapping(obj, state,
                         "readiness", "derived table mapping")

    def _add_filters(self, rows, scope_type, scope_name, filter_type):
        if isinstance(rows, dict):
            rows = [dict(value, name=value.get("name") or key) if isinstance(value, dict)
                    else {"name": key, "value": value} for key, value in rows.items()]
        for index, row in enumerate(rows or []):
            if isinstance(row, str):
                row = {"name": row}
            if not isinstance(row, dict):
                continue
            nested = row.get("filters")
            if nested and not any(row.get(key) for key in ("name", "_name", "field", "dimension")):
                self._add_filters(nested, scope_type, scope_name, filter_type)
                continue
            name = (row.get("name") or row.get("_name") or row.get("field") or
                    row.get("dimension") or "filter-%d" % index)
            obj_id = "%s:%s:%s" % (filter_type, slug_part(scope_name), slug_part(name))
            obj = self.add_object(filter_type, obj_id, name, "readiness",
                                  "%s on %s %s" % (filter_type, scope_type, scope_name), record=row)
            self.add_mapping(obj, row.get("mapping") or row.get("readiness") or row.get("status"),
                             "readiness", "%s mapping" % filter_type)

    def _inventory_fields(self):
        census = self.docs["field_census"]
        mappings = self.docs["formula_mapping"]
        if not isinstance(census, dict) or not isinstance(census.get("fields"), list):
            raise InputError("field census must be an object with a fields array")
        if not isinstance(mappings, dict) or not isinstance(
            mappings.get("formulas") if "formulas" in mappings else mappings.get("mappings"), list
        ):
            raise InputError("formula mapping must contain a formulas or mappings array")

        for row in census["fields"]:
            if not isinstance(row, dict):
                continue
            obj = self._field_object(row, "field_census", "LookML field census row")
            if obj:
                self.field_records[(folded(row.get("view")), folded(row.get("field") or row.get("name")))] = row
                self.add_mapping(obj, row.get("mapping") or row.get("status"),
                                 "field_census", "field mapping=%s" % (row.get("mapping") or row.get("status")))

        formula_rows = mappings.get("formulas") if isinstance(mappings.get("formulas"), list) else mappings.get("mappings")
        for row in formula_rows:
            if not isinstance(row, dict):
                continue
            obj = self._field_object(row, "formula_mapping", "converter formula mapping row")
            if obj:
                key = (folded(row.get("view")), folded(row.get("field") or row.get("name")))
                self.formula_records[key] = row
                self.add_mapping(obj, row.get("mapping") or row.get("status") or row.get("outcome"),
                                 "formula_mapping",
                                 "formula mapping=%s" % (row.get("mapping") or row.get("status") or row.get("outcome")))

    def _field_object(self, row, kind, detail):
        view = row.get("view") or row.get("viewName") or row.get("sourceView")
        name = row.get("field") or row.get("name") or row.get("sourceField")
        if not name:
            return None
        qualified = "%s.%s" % (view, name) if view else str(name)
        return self.add_object("field", "field:%s" % qualified, qualified, kind, detail,
                               record=row, view=view, field=name, field_kind=row.get("kind"),
                               source_field=row.get("sourceField") or row.get("source_field"),
                               timeframe=row.get("timeframe"))

    def _inventory_contracts(self):
        raw = self.docs["contract"]
        if isinstance(raw, list):
            contracts = raw
        elif isinstance(raw, dict) and isinstance(raw.get("dashboards"), list):
            contracts = raw["dashboards"]
        elif isinstance(raw, dict):
            contracts = [raw]
        else:
            raise InputError("contract must be a dashboard/Look object or array")

        for contract_index, contract in enumerate(contracts):
            if not isinstance(contract, dict):
                continue
            contract_id = contract.get("id") or contract.get("dashboard") or "contract-%d" % contract_index
            title = contract.get("title") or contract.get("name") or str(contract_id)
            obj_type = "look" if str(contract.get("source") or "").lower() == "api-look" else "dashboard"
            root = self.add_object(obj_type, "%s:%s" % (obj_type, slug_part(contract_id)), title,
                                   "contract", "%s source contract" % obj_type, contract=contract)
            contract_meta = {"doc": contract, "object": root, "tiles": [], "filters": []}
            self.contracts.append(contract_meta)

            seen_names = Counter()
            for index, tile in enumerate(contract.get("elements") or []):
                if not isinstance(tile, dict):
                    continue
                name = tile.get("name") or tile.get("title") or tile.get("id") or "tile-%d" % index
                source_id = tile.get("id") or tile.get("look_id") or name
                seen_names[str(source_id)] += 1
                suffix = "" if seen_names[str(source_id)] == 1 else ":%d" % seen_names[str(source_id)]
                obj_id = "tile:%s:%s%s" % (slug_part(contract_id), slug_part(source_id), suffix)
                obj = self.add_object("tile", obj_id, name, "contract",
                                      "source tile type=%s" % (tile.get("tileType") or "unknown"),
                                      record=tile, contract_id=contract_id)
                contract_meta["tiles"].append(obj)

            seen_filters = Counter()
            for index, source_filter in enumerate(contract.get("filters") or []):
                if not isinstance(source_filter, dict):
                    continue
                name = source_filter.get("name") or source_filter.get("title") or "filter-%d" % index
                seen_filters[str(name)] += 1
                suffix = "" if seen_filters[str(name)] == 1 else ":%d" % seen_filters[str(name)]
                obj_id = "dashboard-filter:%s:%s%s" % (slug_part(contract_id), slug_part(name), suffix)
                obj = self.add_object("dashboard-filter", obj_id, name, "contract",
                                      "source dashboard filter type=%s" % (source_filter.get("type") or "unknown"),
                                      record=source_filter, contract_id=contract_id)
                contract_meta["filters"].append(obj)

    def parse_targets(self):
        for kind in ("wb_spec", "wb_readback", "dm_spec", "parity", "control_scope"):
            if self.paths.get(kind) is not None and not isinstance(self.docs.get(kind), dict):
                raise InputError("%s artifact must be a JSON object" % kind.replace("_", "-"))
        if self.paths.get("dm_warnings") is not None and not isinstance(
            self.docs.get("dm_warnings"), (list, dict)
        ):
            raise InputError("dm-warnings artifact must be a JSON array or object")
        wb_doc = self.docs.get("wb_readback") or self.docs.get("wb_spec") or {}
        wb_root = document_root(wb_doc)
        self.wb_pages = [row for row in wb_root.get("pages") or [] if isinstance(row, dict)]
        self.wb_elements = [row for row in wb_root.get("elements") or [] if isinstance(row, dict)]
        for page in self.wb_pages:
            self.wb_elements.extend(row for row in page.get("elements") or [] if isinstance(row, dict))
        self.wb_controls = [
            row for row in self.wb_elements
            if row.get("kind") == "control" or row.get("controlId") or row.get("controlType")
        ]

        dm_root = document_root(self.docs.get("dm_spec") or {})
        self.dm_elements = [row for row in dm_root.get("elements") or [] if isinstance(row, dict)]
        for page in dm_root.get("pages") or []:
            if isinstance(page, dict):
                self.dm_elements.extend(row for row in page.get("elements") or [] if isinstance(row, dict))
        for element in self.dm_elements:
            for row in element.get("columns") or []:
                if isinstance(row, dict) and row.get("formula"):
                    self.dm_formulas.add(normalize_formula(row["formula"]))
            for row in element.get("metrics") or []:
                if isinstance(row, dict) and row.get("formula"):
                    self.dm_formulas.add(normalize_formula(row["formula"]))
            self.dm_relationships.extend(
                row for row in element.get("relationships") or [] if isinstance(row, dict)
            )
        self.dm_filter_text = folded(json.dumps(dm_root.get("filters") or dm_root, sort_keys=True))
        self._parse_warnings()
        self._parse_parity()
        self._parse_controls()
        self._check_spec_readback()

    def _parse_warnings(self):
        raw = self.docs.get("dm_warnings")
        rows = raw.get("warnings") if isinstance(raw, dict) else raw
        for row in rows or []:
            if isinstance(row, str):
                self.warning_rows.append({"message": row})
            elif isinstance(row, dict):
                self.warning_rows.append(row)
        readiness = self.docs.get("readiness") or {}
        for row in readiness.get("warnings") or []:
            if isinstance(row, dict):
                self.warning_rows.append(row)

    def _parse_parity(self):
        doc = self.docs.get("parity") or {}
        if not isinstance(doc, dict):
            return
        state = folded(doc.get("status") or doc.get("verdict") or doc.get("result"))
        total = doc.get("charts_total")
        passed = doc.get("charts_pass")
        totals_agree = not (isinstance(total, int) and isinstance(passed, int)) or total == passed
        self.parity_green = state in {folded(word) for word in PASS_WORDS} and totals_agree
        self.parity_pass = {folded(value) for value in doc.get("pass_names") or doc.get("passed") or []}
        self.parity_fail = {folded(value) for value in doc.get("fail_names") or doc.get("failed") or []}

    def _parse_controls(self):
        doc = self.docs.get("control_scope") or {}
        if not isinstance(doc, dict):
            return
        for container in ("controls", "dropped"):
            for row in doc.get(container) or []:
                if not isinstance(row, dict):
                    continue
                names = [row.get("name"), row.get("controlId"), row.get("sourceName")]
                source_signal = row.get("source_signal")
                if source_signal:
                    match = re.search(r"filter ['\"]([^'\"]+)['\"]", str(source_signal), re.I)
                    names.append(match.group(1) if match else source_signal)
                for name in names:
                    if name:
                        bucket = self.control_rows.setdefault(folded(name), [])
                        if not any(existing is row for _, existing in bucket):
                            bucket.append((container, row))

        declared = doc.get("sourceFilterSignals")
        source_count = sum(len(meta["filters"]) for meta in self.contracts)
        if isinstance(declared, int) and declared != source_count:
            self._contradiction(
                "controls", "control-scope sourceFilterSignals=%d but contract has %d filters" %
                (declared, source_count)
            )

    def _check_spec_readback(self):
        if self.docs.get("wb_readback") is None or self.docs.get("wb_spec") is None:
            return
        spec_root = document_root(self.docs["wb_spec"])
        spec_names = {
            folded(row.get("name")) for row in spec_root.get("elements") or []
            if isinstance(row, dict) and row.get("name")
        }
        read_names = {folded(row.get("name")) for row in self.wb_elements if row.get("name")}
        source_tile_names = {
            folded(obj["name"]) for meta in self.contracts for obj in meta["tiles"]
        }
        stripped = sorted((spec_names & source_tile_names) - read_names)
        for name in stripped:
            self._contradiction("workbook-readback",
                                "workbook readback stripped source element %s present in wb-spec" % name)

    def _contradiction(self, key, detail):
        self.errors.append("contradiction: %s" % detail)
        self.contradictory.add(str(key))

    def _mark_unaccounted(self, obj, detail):
        obj["_accounted"] = False
        self.unaccounted.add(obj["id"])
        self.errors.append("unaccounted: %s:%s — %s" % (obj["type"], obj["id"], detail))
        obj["evidence"].append(self.evidence("accounting", detail))

    def _warning_signals(self, obj):
        names = [obj["name"], obj["_meta"].get("field")]
        out = []
        for row in self.warning_rows:
            message = row.get("message") or row.get("detail") or str(row)
            haystack = folded(message)
            if not any(folded(name) and folded(name) in haystack for name in names):
                continue
            classification = mapping_class(row.get("readiness") or row.get("status"))
            if not classification:
                lower = str(message).lower()
                if any(word in lower for word in ("omitted", "skipped", "dropped")):
                    classification = "omitted"
                elif any(word in lower for word in ("approx", "fallback", "lossy")):
                    classification = "approximate"
                elif any(word in lower for word in ("blocked", "unsupported", "unresolved", "error")):
                    classification = "blocked"
            if classification:
                out.append((classification, self.evidence("dm_warnings", message)))
        return out

    def _resolve_mapping(self, obj):
        signals = list(obj["_mapping"]) + self._warning_signals(obj)
        classes = {classification for classification, _ in signals}
        # The readiness audit deliberately emits an `omitted` field mapping and
        # a `blocked` warning explaining the same omission.  Those are one
        # coherent negative outcome, not contradictory evidence.
        if classes == {"omitted", "blocked"}:
            obj["evidence"].extend(evidence for _, evidence in signals)
            return "omitted"
        if len(classes) > 1:
            self._contradiction(
                obj["id"], "%s has incompatible mapping evidence: %s" %
                (obj["id"], ", ".join(sorted(classes)))
            )
            obj["evidence"].extend(evidence for _, evidence in signals)
            return "blocked"
        if signals:
            obj["evidence"].extend(evidence for _, evidence in signals)
            return signals[0][0]
        return None

    def _name_built(self, rows, *names):
        candidates = {folded(name) for name in names if name}
        for row in rows:
            row_names = {folded(row.get("name")), folded(row.get("id"))}
            if candidates & row_names:
                return True
        return False

    def _parity_for(self, name):
        key = folded(name)
        if key in self.parity_fail:
            return False
        if key in self.parity_pass:
            return True
        return self.parity_green

    def _dm_element_for(self, *names):
        candidates = {folded(name) for name in names if name}
        for row in self.dm_elements:
            identities = {folded(row.get("name"))}
            source = row.get("source") if isinstance(row.get("source"), dict) else {}
            path = source.get("path")
            if isinstance(path, list) and path:
                # Sigma commonly omits `name` for a warehouse-backed element on
                # GET readback.  The warehouse path tail is the converter's
                # stable view identity in that shape (CUSTOMER_DIM -> customer_dim).
                identities.add(folded(path[-1]))
            identities.discard("")
            if candidates & identities:
                return row
            if any(candidate and any(candidate + "view" == identity for identity in identities)
                   for candidate in candidates):
                return row
        return None

    def _field_built(self, obj):
        key = (folded(obj["_meta"].get("view")), folded(obj["_meta"].get("field")))
        record = self.formula_records.get(key) or {}
        sigma_formula = normalize_formula(record.get("sigmaFormula") or record.get("sigma_formula"))
        if sigma_formula and sigma_formula in self.dm_formulas:
            return True
        name = obj["_meta"].get("field")
        display = humanize(name)
        for element in self.dm_elements:
            for container in ("columns", "metrics"):
                for row in element.get(container) or []:
                    if not isinstance(row, dict):
                        continue
                    if folded(row.get("name")) == folded(display):
                        return True
                    references = re.findall(r"\[([^\]]+)\]", str(row.get("formula") or ""))
                    terminal = {folded(ref.split("/")[-1]) for ref in references}
                    if folded(name) in terminal or folded(display) in terminal:
                        return True
        if obj["_meta"].get("field_kind") == "dimension_group":
            return self._dimension_group_built(obj)
        return False

    def _dimension_group_built(self, obj):
        """Match the converter's expanded timeframe names, and only those names.

        A source `dimension_group: first_order` is inventoried as fields such as
        `first_order_raw`, `first_order_date`, and `first_order_month`.  Sigma
        readback can qualify the emitted names (`First Order Date (customer_dim)`)
        and can canonicalize their formulas, so formula equality is not a stable
        proof.  The field census carries the exact sourceField/timeframe pair;
        use that pair to derive the converter name without broadening ordinary
        dimension matching.
        """
        view = obj["_meta"].get("view")
        field = obj["_meta"].get("field")
        census = self.field_records.get((folded(view), folded(field))) or {}
        source_field = (
            census.get("sourceField") or census.get("source_field") or
            obj["_meta"].get("source_field")
        )
        timeframe = census.get("timeframe") or obj["_meta"].get("timeframe")
        if not source_field or not timeframe:
            return False

        base = humanize(source_field)
        expected = "%s %s" % (base, humanize(timeframe))
        expected_names = {folded(expected), folded(humanize(field))}
        view_key = folded(view)
        for element in self.dm_elements:
            for container in ("columns", "metrics"):
                for row in element.get(container) or []:
                    if not isinstance(row, dict):
                        continue
                    emitted = folded(row.get("name"))
                    if emitted in expected_names:
                        return True
                    # Joined-view/readback names append the view qualifier.  Do
                    # not accept arbitrary prefix matches: the only permitted
                    # suffix is this field's own source view.
                    if view_key and any(emitted == candidate + view_key for candidate in expected_names):
                        return True
                    # Some readbacks omit the display name but retain a
                    # qualified column reference. Match its terminal segment.
                    formula = str(row.get("formula") or "")
                    references = re.findall(r"\[([^\]]+)\]", formula)
                    terminal = {folded(ref.split("/")[-1]) for ref in references}
                    if terminal & expected_names:
                        return True
                    if view_key and any(
                        value == candidate + view_key
                        for value in terminal for candidate in expected_names
                    ):
                        return True
        return False

    def account(self):
        self._account_filters()
        for obj in self.objects.values():
            if obj["type"] == "dashboard-filter":
                continue
            self._account_object(obj)
            if obj.get("status") not in TERMINAL:
                raise AssertionError("internal accounting status error for %s" % obj["id"])

    def _account_filters(self):
        known_source_names = set()
        for meta in self.contracts:
            for obj in meta["filters"]:
                known_source_names.add(folded(obj["name"]))
                matches = self.control_rows.get(folded(obj["name"]), [])
                distinct = {
                    mapping_class(row.get("status")) or ("omitted" if container == "dropped" else None)
                    for container, row in matches
                }
                distinct.discard(None)
                if len(distinct) > 1:
                    self._contradiction(obj["id"], "control scope gives %s multiple statuses" % obj["name"])
                    classification = "blocked"
                elif distinct:
                    classification = next(iter(distinct))
                else:
                    classification = None

                built = self._name_built(self.wb_controls, obj["name"])
                if classification == "exact" and built:
                    status, ledger = "migrated", "emitted"
                elif classification == "omitted":
                    status, ledger = "skipped", "dropped"
                elif classification in ("blocked", "approximate"):
                    status, ledger = "needs-review", "needs-wiring"
                elif classification == "exact" and not built:
                    status, ledger = "needs-review", "needs-wiring"
                    self._contradiction(obj["id"],
                                        "control scope says emitted but workbook lacks %s" % obj["name"])
                else:
                    status, ledger = "needs-review", "needs-wiring"
                    self._mark_unaccounted(obj, "source filter has no control-scope record")

                details = []
                for container, row in matches:
                    details.append("%s status=%s" % (container, row.get("status") or "recorded"))
                    obj["evidence"].append(self.evidence("control_scope", details[-1]))
                if built:
                    obj["evidence"].append(self.evidence(
                        "wb_readback" if self.docs.get("wb_readback") is not None else "wb_spec",
                        "matching Sigma control",
                    ))
                obj["status"] = status
                self.control_output_rows.append({
                    "kind": "dashboard-filter",
                    "type": "dashboard-filter",
                    "id": obj["id"],
                    "name": obj["name"],
                    "status": ledger,
                    "terminal_status": status,
                    "detail": "; ".join(details) or "no control-scope record",
                    "evidence": self._clean_evidence(obj["evidence"]),
                })

        # A scope-only control is a stale/contradictory builder artifact.
        for key in self.control_rows:
            if not any(source and (source == key or source in key or key in source)
                       for source in known_source_names):
                self._contradiction("control-scope:%s" % key,
                                    "control-scope contains no matching contract filter: %s" % key)

    def _account_object(self, obj):
        obj_type = obj["type"]
        mapping = self._resolve_mapping(obj)
        built = False
        parity = self._parity_for(obj["name"])

        if obj_type in ("dashboard", "look"):
            built = self._name_built(self.wb_pages, obj["name"])
            if not built and obj_type == "look":
                built = any(folded(obj["name"]) == folded(row.get("name")) for row in self.wb_elements)
        elif obj_type == "tile":
            tile_record = obj["_meta"].get("record") or {}
            tile_type = tile_record.get("tileType")
            supported = self._tile_supported(tile_type, tile_record)
            built = self._name_built(self.wb_elements, obj["name"])
            if tile_record.get("merge") and built and mapping is None:
                mapping = "approximate"
                obj["evidence"].append(self.evidence(
                    "contract", "merged-results tile uses a documented Sigma substitute"
                ))
            if not supported:
                obj["status"] = "skipped"
                obj["evidence"].append(self.evidence(
                    "contract", "unsupported tile type %s has no Sigma mapping" % (tile_type or "unknown")
                ))
                if built:
                    self._contradiction(obj["id"],
                                        "unsupported tile %s nevertheless appears in workbook" % obj["name"])
                return
        elif obj_type == "field":
            built = self._field_built(obj)
        elif obj_type == "view":
            built = self._dm_element_for(obj["name"], humanize(obj["name"])) is not None
        elif obj_type == "explore":
            built = self._dm_element_for(obj["name"], humanize(obj["name"]),
                                         humanize(obj["name"]) + " View") is not None
        elif obj_type == "join":
            record = obj["_meta"].get("record") or {}
            names = {folded(obj["name"]), folded(record.get("alias")), folded(record.get("from"))}
            built = any(folded(row.get("name")) in names for row in self.dm_relationships)
        elif obj_type == "derived-table":
            built = self._dm_element_for(obj["name"], humanize(obj["name"])) is not None
        elif obj_type in ("filter", "access-filter", "always-filter"):
            built = folded(obj["name"]) in self.dm_filter_text
        elif obj_type in ("project", "model"):
            built = bool(self.dm_elements)

        built_kind = "wb_readback" if obj_type in ("dashboard", "look", "tile") and self.docs.get(
            "wb_readback"
        ) is not None else ("wb_spec" if obj_type in ("dashboard", "look", "tile") else "dm_spec")
        if built:
            obj["evidence"].append(self.evidence(built_kind, "matching built Sigma object/formula"))

        if mapping == "omitted":
            obj["status"] = "skipped"
            return
        if mapping == "blocked":
            obj["status"] = "needs-review"
            return
        if mapping == "approximate":
            if not built:
                obj["status"] = "needs-review"
                self._contradiction(obj["id"], "approximate mapping has no built substitute for %s" % obj["name"])
            elif not parity:
                obj["status"] = "needs-review"
                obj["evidence"].append(self.evidence("parity", "built substitute is not parity-proven"))
            else:
                obj["status"] = "approximated"
                obj["evidence"].append(self.evidence("parity", "built substitute passed parity"))
            return

        if mapping == "exact" and not built:
            obj["status"] = "needs-review"
            self._contradiction(obj["id"], "exact mapping has no matching built object for %s" % obj["name"])
            return
        if built:
            if parity:
                obj["status"] = "migrated"
                obj["evidence"].append(self.evidence("parity", "final parity proves the built object"))
            else:
                obj["status"] = "needs-review"
                obj["evidence"].append(self.evidence("parity", "built object lacks passing final parity"))
            return

        if self.root_readiness == "blocked" and obj_type not in ("dashboard", "look", "tile"):
            obj["status"] = "needs-review"
            obj["evidence"].append(self.evidence("readiness", "project readiness is blocked"))
            return

        obj["status"] = "needs-review"
        self._mark_unaccounted(obj, "no explicit mapping/omission and no matching built object")

    def _tile_supported(self, tile_type, record):
        if not tile_type and record.get("merge"):
            return True
        if tile_type == "looker_waterfall":
            kinds = {}
            for row in self.docs["field_census"].get("fields") or []:
                kinds[folded("%s.%s" % (row.get("view"), row.get("field")))] = row.get("kind")
            return any(kinds.get(folded(ref)) != "measure" for ref in record.get("fields") or [])
        catalog = Path(__file__).resolve().parent.parent / "refs" / "catalogs" / "viz-kind.json"
        try:
            doc = read_json(catalog)
            matches = [
                row for row in doc.get("rows") or []
                if isinstance(row, dict) and row.get("source") == tile_type
            ]
            return bool(matches and (matches[0].get("sigma") or matches[0].get("sigma_if")))
        except InputError:
            return tile_type in {
                "single_value", "looker_column", "looker_bar", "looker_line", "looker_area",
                "looker_pie", "looker_donut_multiples", "looker_scatter", "looker_waterfall",
                "looker_grid", "table", "text",
            }

    def outputs(self):
        ordered = sorted(self.objects.values(),
                         key=lambda row: (folded(row["type"]), folded(row["id"]), folded(row["name"])))
        public = []
        for obj in ordered:
            public.append({
                "type": obj["type"],
                "id": obj["id"],
                "name": obj["name"],
                "status": obj["status"],
                "evidence": self._clean_evidence(obj["evidence"]),
            })
        counts = {status: sum(row["status"] == status for row in public) for status in TERMINAL}
        diagnostics = {
            "errors": sorted(set(self.errors)),
            "unaccounted": sorted(self.unaccounted),
            "contradictory": sorted(self.contradictory),
        }
        census = {
            "schema_version": 1,
            "source": "looker",
            "summary": {
                "total": len(public),
                "accounted": len(public) - len(self.unaccounted),
                "complete": not self.errors,
                "counts": counts,
            },
            "objects": public,
            "inputs": [
                {"kind": kind.replace("_", "-"), "path": self.artifact_name(kind),
                 "present": path is not None}
                for kind, path in sorted(self.paths.items())
            ],
            "diagnostics": diagnostics,
        }
        coverage = self._coverage(public, diagnostics)
        controls = {
            "version": 1,
            "source": "looker",
            "summary": {
                "sourceFilters": len(self.control_output_rows),
                "emitted": sum(row["status"] == "emitted" for row in self.control_output_rows),
                "dropped": sum(row["status"] == "dropped" for row in self.control_output_rows),
                "needsWiring": sum(row["status"] == "needs-wiring" for row in self.control_output_rows),
            },
            "detail": sorted(self.control_output_rows,
                             key=lambda row: (folded(row["id"]), folded(row["name"]))),
            "diagnostics": diagnostics,
        }
        return census, coverage, controls

    def _coverage(self, public, diagnostics):
        by_id = {row["id"]: row for row in public}
        tiles = [obj for meta in self.contracts for obj in meta["tiles"]]
        built = sum(self._name_built(self.wb_elements, obj["name"]) for obj in tiles)
        unresolved = []
        for obj in tiles:
            row = by_id[obj["id"]]
            if row["status"] == "migrated":
                continue
            severity = {
                "approximated": "approximated",
                "skipped": "dropped",
                "needs-review": "degraded",
                "not-applicable": "dropped",
            }[row["status"]]
            source = obj["_meta"].get("record") or {}
            bindings = []
            for ref in list(source.get("fields") or []) + list(source.get("pivots") or []):
                field_obj = next(
                    (candidate for candidate in public
                     if candidate["type"] == "field" and folded(candidate["name"]) == folded(ref)),
                    None,
                )
                status = "resolved" if field_obj and field_obj["status"] in ("migrated", "approximated") else "degraded"
                bindings.append({"queryRef": ref, "status": status, "role_class": "chart"})
            unresolved.append({
                "visual": row["name"],
                "source_object_id": row["id"],
                "source_type": source.get("tileType") or "unknown",
                "sigma_kind": next(
                    (element.get("kind") for element in self.wb_elements
                     if folded(element.get("name")) == folded(row["name"])), None
                ),
                "severity": severity,
                "detail": "; ".join(evidence["detail"] for evidence in row["evidence"][-2:]),
                "recoverable": row["status"] == "needs-review",
                "action": "review the named mapping/build/parity evidence and rebuild" if row["status"] == "needs-review" else None,
                "role_class": "chart",
                "field_bindings": bindings,
            })
        all_bindings = [
            ref
            for meta in self.contracts
            for tile in meta["doc"].get("elements") or []
            if isinstance(tile, dict)
            for ref in list(tile.get("fields") or []) + list(tile.get("pivots") or [])
        ]
        resolved_bindings = 0
        for ref in all_bindings:
            field_obj = next(
                (row for row in public if row["type"] == "field" and folded(row["name"]) == folded(ref)),
                None,
            )
            if field_obj and field_obj["status"] in ("migrated", "approximated"):
                resolved_bindings += 1
        return {
            "version": 1,
            "source": "looker",
            "summary": {
                "sourceVisuals": len(tiles),
                "builtElements": built,
                "dropped": sum(row["severity"] == "dropped" for row in unresolved),
                "degraded": sum(row["severity"] == "degraded" for row in unresolved),
                "approximated": sum(row["severity"] == "approximated" for row in unresolved),
                "recoverable": sum(bool(row["recoverable"]) for row in unresolved),
                "sourceBindings": len(all_bindings),
                "resolvedBindings": resolved_bindings,
            },
            "unresolved": sorted(unresolved, key=lambda row: (row["severity"], folded(row["visual"]))),
            "objects": [
                {
                    "type": row["type"], "source_object_id": row["id"], "name": row["name"],
                    "status": row["status"],
                    "detail": "; ".join(evidence["detail"] for evidence in row["evidence"]),
                }
                for row in public
            ],
            "diagnostics": diagnostics,
        }

    @staticmethod
    def _clean_evidence(rows):
        unique = {
            (str(row.get("artifact") or ""), str(row.get("detail") or "")): {
                "artifact": str(row.get("artifact") or ""),
                "detail": str(row.get("detail") or ""),
            }
            for row in rows
            if isinstance(row, dict)
        }
        return [unique[key] for key in sorted(unique)]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    try:
        temporary.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--readiness")
    parser.add_argument("--field-census")
    parser.add_argument("--formula-mapping")
    parser.add_argument("--contract")
    parser.add_argument("--wb-spec")
    parser.add_argument("--wb-readback", "--readback", dest="wb_readback")
    parser.add_argument("--parity-final", "--parity", dest="parity")
    parser.add_argument("--control-scope")
    parser.add_argument("--dm-spec")
    parser.add_argument("--dm-warnings")
    parser.add_argument("--census-out")
    parser.add_argument("--coverage-out")
    parser.add_argument("--controls-out")
    return parser.parse_args(argv)


def main(argv=None):
    try:
        args = parse_args(argv)
        workdir = Path(args.workdir).expanduser().resolve()
        if not workdir.is_dir():
            raise InputError("--workdir is not a directory: %s" % workdir)
        paths = {
            "readiness": json_path(workdir, args.readiness,
                                   ("lookml-readiness.json", "*readiness*.json"), required=True),
            "field_census": json_path(workdir, args.field_census,
                                      ("lookml-field-census.json", "field-census.json", "*field*census*.json"),
                                      required=True),
            "formula_mapping": json_path(workdir, args.formula_mapping,
                                         ("formula-mapping.json", "*formula*mapping*.json"), required=True),
            "contract": json_path(workdir, args.contract,
                                  ("contract.json", "*.contract.json"), required=True),
            "wb_readback": json_path(workdir, args.wb_readback,
                                     ("wb-readback.json", "workbook-readback.json", "*wb*readback*.json")),
            "wb_spec": json_path(workdir, args.wb_spec,
                                 ("wb-spec.json", "wb-spec.resolved.json", "*workbook*spec*.json")),
            "parity": json_path(workdir, args.parity, ("parity-final.json",)),
            "control_scope": json_path(workdir, args.control_scope, ("control-scope.json",)),
            "dm_spec": json_path(workdir, args.dm_spec, ("dm-spec.json", "*dm*spec*.json")),
            "dm_warnings": json_path(workdir, args.dm_warnings,
                                     ("dm-spec-warnings.json", "*dm*warnings*.json")),
        }
        docs = {kind: read_json(path) for kind, path in paths.items()}
        accounting = LookerAccounting(workdir, paths, docs)
        accounting.inventory()
        accounting.parse_targets()
        accounting.account()
        census, coverage, controls = accounting.outputs()
        def output_path(value, default):
            if not value:
                return workdir / default
            candidate = Path(value)
            return (candidate if candidate.is_absolute() else workdir / candidate).resolve()

        census_out = output_path(args.census_out, "source-object-census.json")
        coverage_out = output_path(args.coverage_out, "coverage.json")
        controls_out = output_path(args.controls_out, "looker-controls-coverage.json")
        write_json(census_out, census)
        write_json(coverage_out, coverage)
        write_json(controls_out, controls)
        print(
            "looker accounting: %d objects (%d accounted), %d visuals, %d controls" %
            (census["summary"]["total"], census["summary"]["accounted"],
             coverage["summary"]["sourceVisuals"], controls["summary"]["sourceFilters"])
        )
        if accounting.errors:
            for error in sorted(set(accounting.errors)):
                print("ERROR: " + error, file=sys.stderr)
            return 1
        return 0
    except InputError as exc:
        print("build-looker-accounting: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
