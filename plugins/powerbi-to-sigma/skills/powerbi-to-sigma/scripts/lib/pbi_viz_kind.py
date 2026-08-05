#!/usr/bin/env python3
"""pbi_viz_kind.py — Python mirror of lib/pbi_viz_kind.rb for the extractors.

Resolves a raw Power BI ``visualType`` to a Sigma element kind + ROLE CLASS from
the SAME two catalogs the Ruby builder reads, so the two maps cannot drift:

    refs/catalogs/viz-kind.json       native PBI visualTypes (exact match)
    refs/catalogs/custom-visual.json  third-party/AppSource visuals (regex match)

This replaces the extractors' old ``VISUAL_KIND.get(vtype, "bar")`` dict, whose
silent default coerced any unrecognized visual into a bar chart (measured on 4
real customer .pbix files: 21 third-party date-picker SLICERS became bar charts).

All prose — per-row guidance plus the unknown/heuristic templates — lives in the
catalog JSON, so this file holds only resolution logic. Stdlib only.
"""
import json
import os
import re

FUNCTIONAL_ROLES = ("control", "kpi", "chart", "table")
NO_TARGET_ROLES = ("decoration", "unsupported")


def functional(role_class):
    """True when losing this visual is a FUNCTIONAL regression (gate-worthy)."""
    return str(role_class or "") in FUNCTIONAL_ROLES


def default_catalog_dir(script_file):
    """scripts/<any>.py or scripts/lib/<any>.py -> <skill>/refs/catalogs"""
    here = os.path.dirname(os.path.abspath(script_file))
    for up in ("..", os.path.join("..", "..")):
        cand = os.path.normpath(os.path.join(here, up, "refs", "catalogs"))
        if os.path.isdir(cand):
            return cand
    return os.path.normpath(os.path.join(here, "..", "refs", "catalogs"))


class Catalog:
    def __init__(self, catalog_dir):
        self.dir = catalog_dir
        with open(os.path.join(catalog_dir, "viz-kind.json")) as f:
            self.rows = json.load(f).get("rows") or []
        cvp = os.path.join(catalog_dir, "custom-visual.json")
        self.env = {}
        if os.path.exists(cvp):
            with open(cvp) as f:
                self.env = json.load(f)
        self.custom_rows = self.env.get("rows") or []
        self._by_type = {}
        for r in self.rows:
            for t in (r.get("pbi_visual_types") or []):
                self._by_type.setdefault(str(t).lower(), r)
        self._compiled = [(re.compile(cr["match"], re.I), cr)
                          for cr in self.custom_rows if cr.get("match")]
        self._slicer = re.compile(
            self.env.get("slicer_hint_pattern") or r"slicer|filter|picker", re.I)
        self._date = re.compile(
            self.env.get("date_hint_pattern") or r"date|timeline|calendar", re.I)

    def resolve(self, visual_type):
        """-> normalized row dict, or None when nothing matches."""
        t = str(visual_type or "").strip()
        if not t:
            return None
        r = self._by_type.get(t.lower())
        if r:
            return self._normalize(r, t, "viz-kind")
        for rx, cr in self._compiled:
            if rx.search(t):
                return self._normalize(cr, t, "custom-visual")
        return self._heuristic(t)

    def resolve_or_guidance(self, visual_type):
        """Never None — every caller gets a role_class + guidance to record."""
        return self.resolve(visual_type) or self.unknown_row(visual_type)

    def unknown_row(self, token):
        tmpl = self.env.get("unknown_guidance") or (
            "Unrecognized visual '{token}' — no Sigma kind was assumed; recorded as "
            "unsupported rather than silently rendered as a chart.")
        return {"source": str(token), "role_class": "unsupported", "sigma": None,
                "sigma_target": None, "builder_kind": None, "catalog": "none",
                "approximate": False, "visual_type": str(token),
                "guidance": tmpl.replace("{token}", str(token))}

    def _heuristic(self, t):
        """An unlisted visual whose NAME says it filters -> a control. Conservative
        by design: a false control is recoverable, a false bar chart silently
        deletes a page's filter."""
        if not self._slicer.search(t):
            return None
        kind = "date-range" if self._date.search(t) else "list"
        tmpl = self.env.get("heuristic_guidance") or (
            "Unlisted visual '{token}' looks like a filter — emitted as a Sigma {kind} control.")
        return {"source": t, "role_class": "control", "sigma": kind, "sigma_target": kind,
                "builder_kind": "control", "catalog": "heuristic", "approximate": False,
                "visual_type": t,
                "guidance": tmpl.replace("{token}", t).replace("{kind}", kind)}

    def _normalize(self, r, token, which):
        """The two catalogs carry the two names in DIFFERENT fields:
        viz-kind.json      `source` = the coarse token the Ruby builder switches on
                           (SIGMA_KIND[source] = sigma); `sigma` = the Sigma kind.
        custom-visual.json `sigma`  = that coarse token; `sigma_target` = Sigma kind.
        Getting this backwards emits sigma_kind='bar-chart' where the builder wants
        'bar' — caught by test-extract-viz-signals.py."""
        role = str(r.get("role_class") or "")
        builder = r.get("source") if which == "viz-kind" else r.get("sigma")
        sigma = r.get("sigma_target") or r.get("sigma")
        if role == "control" and (sigma is None or sigma == "control"):
            sigma = "list"
        if role in NO_TARGET_ROLES:
            sigma = None
            builder = None      # inert: the builder routes on role_class
        approx = token.lower() in [str(x).lower()
                                   for x in (r.get("approximate_types") or [])]
        return {"source": r.get("source"), "role_class": role, "sigma": sigma,
                "sigma_target": r.get("sigma_target"), "builder_kind": builder,
                "guidance": r.get("guidance"), "notes": r.get("notes"),
                "approximate": approx, "catalog": which, "visual_type": token}


def load(catalog_dir):
    return Catalog(catalog_dir)
