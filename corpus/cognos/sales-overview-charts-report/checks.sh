#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import json
from pathlib import Path

result = json.loads(Path("golden/workbook.json").read_text())
workbook = result["workbook"]
assert set(workbook) == {"name", "document"}, "workbook must use outer metadata + document wrapper"
doc = workbook["document"]
pages = doc["pages"]
elements = doc["elements"]
layout = doc["layout"]

assert len(pages) == 2, f"expected 2 metadata pages, got {len(pages)}"
assert all("elements" not in page for page in pages), "pages must be metadata-only"
assert len(elements) == 19, f"expected 19 flat elements, got {len(elements)}"
assert sum(len(element.get("columns", [])) for element in elements) == 28, "expected 28 columns"
assert all(f'<Page' in layout and f'id="{page["id"]}"' in layout for page in pages), "layout must contain every page"
assert "<LayoutElement" not in layout and "<GridContainer" not in layout, "layout must not emit compatibility aliases"
assert "<Element " in layout, "layout must use the live Element tag"
for element in elements:
    needle = f'elementId="{element["id"]}"'
    assert layout.count(needle) == 1, f'{element["id"]} must appear exactly once in layout'
assert any(element.get("kind") == "navigation" for element in elements), "multi-page report needs navigation"
assert result["stats"]["pages"] == 2
print("  ok   current workbook wrapper/flat-elements/layout contract")
PY
