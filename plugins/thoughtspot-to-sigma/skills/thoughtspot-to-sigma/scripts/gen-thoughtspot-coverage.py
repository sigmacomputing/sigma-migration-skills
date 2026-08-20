#!/usr/bin/env python3
"""Generate ThoughtSpot coverage while leaving the shared renderer unmodified."""
import argparse
import importlib.util
import os
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
SHARED_RENDERER = os.path.join(HERE, "gen-coverage-matrix.py")


def _renderer():
    spec = importlib.util.spec_from_file_location("shared_coverage_renderer", SHARED_RENDERER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    module.DIM_ORDER.append("workbook-feature")
    module.DIM_TITLE["workbook-feature"] = "Workbook-as-code release features"
    shared_target_cell = module._target_cell

    def thoughtspot_target_cell(row):
        if row.get("sigma") is None and row.get("sigma_if") is None:
            if row.get("source_gap"):
                return "— (no source semantic to map)"
            if row.get("converter_gap"):
                return "— (explicit converter gap)"
        return shared_target_cell(row)

    module._target_cell = thoughtspot_target_cell
    return module


def render(catalogs, skill):
    text = _renderer().render(catalogs, skill)
    return text.replace(
        "python3 scripts/gen-coverage-matrix.py",
        "python3 scripts/gen-thoughtspot-coverage.py",
        1,
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
