#!/usr/bin/env python3
"""Credentials-free tests for complex aggregation/window hazard gates."""

import json
import os
import subprocess
import sys
import tempfile


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPT = os.path.join(SKILL, "scripts", "detect_modeling_hazards.py")


def write(path, value):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle)


def fixtures(workdir, safe=False):
    contract = {
        "elements": [
            {
                "name": "Volatility",
                "fields": ["period", "metric"],
                "sorts": ["period asc"] if safe else [],
                "dynamicFields": [
                    {"expression": "MovingStddev(${metric}, 5)"}
                ],
            }
        ]
    }
    dm = {
        "pages": [
            {
                "elements": [
                    {
                        "id": "agg-a",
                        "name": "Period Metrics",
                        "source": {
                            "kind": "sql",
                            "statement": "SELECT period, dimension, AVG(rate) rate FROM fact GROUP BY period, dimension",
                        },
                        "relationships": [] if safe else [
                            {"name": "Bridge", "targetElementId": "agg-b", "keys": []}
                        ],
                    },
                    {
                        "id": "agg-b",
                        "name": "Bridge Metrics",
                        "source": {
                            "kind": "sql",
                            "statement": "SELECT period, SUM(volume) volume FROM fact GROUP BY period",
                        },
                    },
                ]
            }
        ]
    }
    aggregate = "Max" if safe else "Sum"
    wb = {
        "document": {
            "elements": [
                {
                    "id": "master",
                    "name": "Data",
                    "kind": "table",
                    "source": {"kind": "data-model", "dataModelId": "dm", "elementId": "agg-a"},
                    "columns": [{"id": "rate", "name": "Completion Rate", "formula": "[Period Metrics/Rate]"}],
                },
                {
                    "id": "tile",
                    "name": "Dimensions View",
                    "kind": "table",
                    "source": {"kind": "table", "elementId": "master"},
                    "columns": [
                        {
                            "id": "result",
                            "name": "Completion Rate",
                            "formula": f"{aggregate}([Data/Completion Rate])",
                        }
                    ],
                },
            ]
        }
    }
    write(os.path.join(workdir, "contract.json"), contract)
    write(os.path.join(workdir, "dm.json"), dm)
    write(os.path.join(workdir, "wb.json"), wb)


def run_scan(workdir):
    return subprocess.run(
        [
            sys.executable,
            SCRIPT,
            "--workdir",
            workdir,
            "--contract",
            os.path.join(workdir, "contract.json"),
            "--dm-spec",
            os.path.join(workdir, "dm.json"),
            "--wb-spec",
            os.path.join(workdir, "wb.json"),
        ],
        capture_output=True,
        text=True,
    )


def test_complex_shapes_block_and_feed_gate_19():
    with tempfile.TemporaryDirectory() as workdir:
        fixtures(workdir)
        run = run_scan(workdir)
        assert run.returncode == 2, run.stdout + run.stderr
        ledger = json.load(open(os.path.join(workdir, "agg-semantics.json"), encoding="utf-8"))
        hazards = {entry["hazard"] for entry in ledger["entries"]}
        assert hazards == {
            "preaggregated-relationship",
            "broadcast-additive",
            "unsafe-window-grain",
        }, hazards

        for index in range(len(ledger["entries"])):
            resolved = subprocess.run(
                [
                    sys.executable,
                    SCRIPT,
                    "--workdir",
                    workdir,
                    "--resolve",
                    str(index),
                    "--how",
                    "faithful-to-source",
                    "--reason",
                    "fixture verifies resolution persistence",
                ],
                capture_output=True,
                text=True,
            )
            assert resolved.returncode == 0, resolved.stdout + resolved.stderr
        rerun = run_scan(workdir)
        assert rerun.returncode == 0, rerun.stdout + rerun.stderr


def test_max_at_declared_grain_and_sorted_window_are_safe():
    with tempfile.TemporaryDirectory() as workdir:
        fixtures(workdir, safe=True)
        run = run_scan(workdir)
        assert run.returncode == 0, run.stdout + run.stderr
        ledger = json.load(open(os.path.join(workdir, "agg-semantics.json"), encoding="utf-8"))
        assert ledger["entries"] == []


if __name__ == "__main__":
    test_complex_shapes_block_and_feed_gate_19()
    test_max_at_declared_grain_and_sorted_window_are_safe()
    print("modeling hazards: PASS")
