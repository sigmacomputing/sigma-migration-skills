#!/usr/bin/env python3
"""Resolve effective properties for Qlik wrapper visualizations."""


def effective_chart_properties(properties, object_type=None):
    """Return Qlik's generated concrete chart for an auto-chart wrapper."""
    properties = properties or {}
    qtype = object_type or (properties.get("qInfo") or {}).get("qType")
    generated = ((properties.get("qUndoExclude") or {}).get("generated") or {})
    if qtype != "auto-chart" or not isinstance(generated, dict):
        return properties, qtype
    concrete = generated.get("visualization") or (generated.get("qInfo") or {}).get("qType")
    return (generated, concrete) if concrete else (properties, qtype)
