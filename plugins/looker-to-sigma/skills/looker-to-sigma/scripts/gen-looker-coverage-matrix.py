#!/usr/bin/env python3
"""Generate Looker's coverage matrix with plugin-owned release dimensions."""

import argparse
import importlib.util
import os
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
GENERATOR_PATH = os.path.join(HERE, "gen-coverage-matrix.py")


def _load_shared_generator():
    spec = importlib.util.spec_from_file_location(
        "shared_coverage_matrix_generator", GENERATOR_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load shared coverage matrix generator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def render(catalogs, skill):
    generator = _load_shared_generator()
    generator.DIM_ORDER = generator.DIM_ORDER + ["workbook-feature"]
    generator.DIM_TITLE = dict(
        generator.DIM_TITLE,
        **{"workbook-feature": "Workbook-as-code release feature"},
    )
    text = generator.render(catalogs, skill)
    return text.replace(
        "python3 scripts/gen-coverage-matrix.py",
        "python3 scripts/gen-looker-coverage-matrix.py",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalogs", required=True)
    parser.add_argument("--skill", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if --out is stale vs the catalogs (no write)",
    )
    args = parser.parse_args()

    text = render(args.catalogs, args.skill)
    if args.check:
        current = open(args.out).read() if os.path.exists(args.out) else ""
        if current != text:
            sys.stderr.write(
                "STALE: %s does not match refs/catalogs — regenerate.\n" % args.out
            )
            sys.exit(1)
        print("OK: %s matches the catalogs." % args.out)
        return

    open(args.out, "w").write(text)
    print("wrote %s (%d bytes)" % (args.out, len(text)))


if __name__ == "__main__":
    main()
