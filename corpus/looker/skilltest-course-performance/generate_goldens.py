#!/usr/bin/env python3
"""Regenerate normalized offline goldens for this corpus case."""

import json
import os
import subprocess
import sys
import tempfile


CASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(CASE, "..", "..", ".."))
SKILL = os.path.join(ROOT, "plugins", "looker-to-sigma", "skills", "looker-to-sigma")
sys.path.insert(0, os.path.join(SKILL, "tests"))
sys.path.insert(0, os.path.join(ROOT, "corpus", "lib"))

import corpus_check  # noqa: E402
import test_course_performance_fixture as fixture  # noqa: E402


def dump(path, value):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(corpus_check.normalize(value), handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def main():
    golden = os.path.join(CASE, "golden")
    os.makedirs(golden, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        converted = fixture.converter_result(tmp)
        contract, dm, workbook = fixture.build_workbook(tmp, converted)
        subprocess.run(
            [
                sys.executable,
                os.path.join(SKILL, "scripts", "detect_modeling_hazards.py"),
                "--workdir",
                tmp,
                "--contract",
                contract,
                "--dm-spec",
                dm,
                "--wb-spec",
                workbook,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        dump(
            os.path.join(golden, "data-model.json"),
            {
                "sigmaDataModel": converted["model"],
                "stats": converted.get("stats") or {},
                "warnings": converted.get("warnings") or [],
                "dynamicParameters": converted.get("dynamicParameters") or [],
            },
        )
        dump(
            os.path.join(golden, "workbook.json"),
            {"workbook": json.load(open(workbook, encoding="utf-8")), "warnings": []},
        )
        dump(
            os.path.join(golden, "contract.json"),
            {"workbook": json.load(open(contract, encoding="utf-8")), "warnings": []},
        )
        dump(
            os.path.join(golden, "modeling-hazards.json"),
            json.load(open(os.path.join(tmp, "modeling-hazards.json"), encoding="utf-8")),
        )
        dump(
            os.path.join(golden, "dynamic-controls.json"),
            json.load(open(os.path.join(tmp, "dynamic-controls.json"), encoding="utf-8")),
        )
    print(f"wrote normalized goldens to {golden}")


if __name__ == "__main__":
    main()
