"""migrate-tableau.py's gap scan must write the gaps.json it then reads (and
that Phase 6's assert-phase6-ran.py requires). scan-workbook-gaps.py derives
its JSON from the markdown path's stem, so a `gaps-report.md` argument wrote
gaps-report.json and the orchestrator silently read nothing. Offline."""
import ast
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ORCH = HERE / "migrate-tableau.py"
SCAN = HERE / "scan-workbook-gaps.py"
FIXTURE = next(iter(sorted((HERE / "fixtures").glob("*.twb"))), None)


def scan_markdown_arg() -> str:
    """The markdown path literal the orchestrator passes to scan-workbook-gaps.py."""
    tree = ast.parse(ORCH.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if (isinstance(node, ast.Call) and len(node.args) >= 3
                and isinstance(node.args[1], ast.Constant) and node.args[1].value == "scan-workbook-gaps.py"):
            for item in node.args[2].elts:
                if (isinstance(item, ast.Call) and item.args and isinstance(item.args[0], ast.BinOp)
                        and isinstance(item.args[0].right, ast.Constant)
                        and str(item.args[0].right.value).endswith(".md")):
                    return item.args[0].right.value
    raise AssertionError("scan-workbook-gaps.py call not found in migrate-tableau.py")


class GapScanPathsTest(unittest.TestCase):
    def test_orchestrator_markdown_maps_to_gaps_json(self):
        spec = importlib.util.spec_from_file_location("scan_gaps", SCAN)
        scan = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = scan  # dataclasses resolve annotations through sys.modules
        sys.path.insert(0, str(HERE / "lib"))
        sys.path.insert(0, str(HERE))
        spec.loader.exec_module(scan)
        md = pathlib.Path("/w") / scan_markdown_arg()
        self.assertEqual(scan.json_report_path(md).name, "gaps.json")

    @unittest.skipIf(FIXTURE is None, "no .twb fixture")
    def test_scan_with_orchestrator_path_writes_gaps_json(self):
        work = pathlib.Path(tempfile.mkdtemp())
        out = work / scan_markdown_arg()
        proc = subprocess.run([sys.executable, str(SCAN), str(FIXTURE), str(out)],
                              capture_output=True, text=True, cwd=str(HERE))
        self.assertTrue((work / "gaps.json").is_file(), proc.stderr[-800:])
        self.assertTrue((work / "formula-audit.json").is_file(), proc.stderr[-800:])


if __name__ == "__main__":
    unittest.main()
