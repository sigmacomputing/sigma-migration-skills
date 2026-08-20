#!/usr/bin/env python3
"""GoodData-owned coverage rendering for released workbook features."""
import argparse
import importlib.util
import os
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
GENERATOR = os.path.join(SKILL, "scripts", "gen-coverage-matrix.py")
RELEASE_DIMENSION = "workbook-feature"
RELEASE_TITLE = "Released workbook features"


def render(catalogs):
    """Render with GoodData's release dimension without forking shared code."""
    spec = importlib.util.spec_from_file_location(
        "gooddata_shared_coverage_generator", GENERATOR)
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    generator.DIM_ORDER = generator.DIM_ORDER + [RELEASE_DIMENSION]
    generator.DIM_TITLE = dict(generator.DIM_TITLE)
    generator.DIM_TITLE[RELEASE_DIMENSION] = RELEASE_TITLE
    return generator.render(catalogs, "gooddata")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalogs", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    text = render(args.catalogs)
    if args.check:
        current = open(args.out).read() if os.path.exists(args.out) else ""
        if current != text:
            sys.stderr.write(
                "STALE: %s does not match GoodData coverage catalogs.\n" %
                args.out)
            return 1
        print("OK: %s matches the GoodData coverage catalogs." % args.out)
        return 0

    open(args.out, "w").write(text)
    print("wrote %s (%d bytes)" % (args.out, len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
