import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import blind_grade_v2 as bg  # noqa: E402

RUBY_LIB = HERE / "lib" / "blind_grade.rb"
CATALOG = bg.shipped_catalog()


def dims(**fails):
    return {
        k: {"verdict": "fail" if k in fails else "pass", "evidence": "fixture"}
        for k in bg.DIMENSION_KEYS
    }


def grade(overall=90, gaps=None, fail_dims=(), sha=None, **extra):
    doc = {
        "schema": bg.SCHEMA_V2,
        "source_png": "s.png",
        "target_png": "t.png",
        "source_sha256": "a" * 64,
        "target_sha256": "b" * 64,
        "catalog_sha256": sha or CATALOG["sha256"],
        "verdict": "pass",
        "dimensions": dims(**{k: 1 for k in fail_dims}),
        "per_tile": [{"position": 1, "source_family": "bar", "target_family": "bar"}],
        "scores": {k: 9 for k in bg.DIMENSION_KEYS},
        "overall_score": overall,
        "gaps": gaps or [],
    }
    doc.update(extra)
    return doc


def gap(cls="fixable", dimension="composition_match", severity="minor", tile="Tile A", description="d"):
    return {"tile": tile, "dimension": dimension, "description": description,
            "severity": severity, "class": cls}


def catalog_entry():
    return CATALOG["entries"][0]


class BlindGradeV2Test(unittest.TestCase):
    def test_constants_and_shipped_catalog(self):
        self.assertEqual((75, 5), (bg.PASS_SCORE, bg.BORDERLINE))
        self.assertEqual([], CATALOG["errors"])
        self.assertEqual(11, len(CATALOG["ids"]))
        self.assertIn("pivot-row-height-fixed", CATALOG["ids"])
        self.assertIn("map-basemap-washout", CATALOG["ids"])
        self.assertIn("map-stepped-color-scale", CATALOG["ids"])

    def test_faithful_single_clear_pass(self):
        out = bg.faithful([grade(90)], CATALOG)
        self.assertTrue(out["faithful"])
        self.assertFalse(out["needs_second"])
        self.assertEqual(90.0, out["score"])

    def test_borderline_single_needs_second_but_two_use_mean(self):
        self.assertTrue(bg.faithful([grade(72)], CATALOG)["needs_second"])
        two = bg.faithful([grade(72), grade(84)], CATALOG)
        self.assertEqual(78.0, two["score"])
        self.assertTrue(two["faithful"])
        self.assertFalse(two["needs_second"])

    def test_unknown_catalog_id_and_sha_mismatch_refused(self):
        errs = bg.validate_v2(grade(gaps=[gap(cls="made-up-id")]), CATALOG)
        self.assertTrue(any("made-up-id" in e for e in errs), errs)
        errs = bg.validate_v2(grade(sha="0" * 64), CATALOG)
        self.assertTrue(any("catalog_sha256 mismatch" in e for e in errs), errs)

    def test_valid_grade_has_no_errors(self):
        e = catalog_entry()
        doc = grade(gaps=[gap(cls=e["id"], dimension=e["dimension"])])
        self.assertEqual([], bg.validate_v2(doc, CATALOG))


@unittest.skipUnless(shutil.which("ruby"), "ruby not on PATH")
class PythonRubyAgreementTest(unittest.TestCase):
    def test_python_and_ruby_faithful_agree(self):
        e = catalog_entry()
        other = next(c for c in CATALOG["entries"] if c["dimension"] != e["dimension"])
        wrong_dim = "palette_match" if e["dimension"] != "palette_match" else "labels_legible"
        cases = {
            "faithful": [grade(90)],
            "borderline": [grade(72)],
            "two_mean": [grade(72), grade(84)],
            "two_mean_below": [grade(70), grade(76)],
            "major_fixable": [grade(95, gaps=[gap(severity="major", description="bad axis")])],
            "minor_residual": [grade(88, gaps=[gap()])],
            "platform_only": [grade(90, gaps=[gap(cls=e["id"], dimension=e["dimension"])])],
            "dedup_two": [grade(72, gaps=[gap(), gap(cls=e["id"], dimension=e["dimension"])]),
                          grade(80, gaps=[gap(), gap(cls=other["id"], dimension=other["dimension"])])],
            "dim_mismatch": [grade(90, gaps=[gap(cls=e["id"], dimension=wrong_dim)])],
            "unknown_id": [grade(90, gaps=[gap(cls="nope")])],
            "bad_sha": [grade(90, sha="1" * 64)],
            "bad_scores": [grade(90, scores={"palette_match": 11})],
            "chart_shapes_fail": [grade(95, fail_dims=("chart_shapes_match",))],
            "numbers_fail_one_of_two": [grade(72), grade(84, fail_dims=("numbers_formatted",))],
        }
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            manifest = {}
            for name, docs in cases.items():
                paths = []
                for i, doc in enumerate(docs):
                    p = tmp / f"{name}-{i}.json"
                    p.write_text(json.dumps(doc))
                    paths.append(str(p))
                manifest[name] = paths
            (tmp / "manifest.json").write_text(json.dumps(manifest))
            script = (
                "require 'json'; require %r; " % str(RUBY_LIB)
                + "cat = BlindGrade.load_catalog(ARGV[1]); "
                "m = JSON.parse(File.read(ARGV[0])); out = {}; "
                "m.each { |n, ps| docs = ps.map { |p| JSON.parse(File.read(p)) }; "
                "out[n] = { 'validate' => docs.map { |d| BlindGrade.validate_v2(d, cat) }, "
                "'faithful' => BlindGrade.faithful(docs, cat) } }; "
                "puts JSON.generate(out)"
            )
            proc = subprocess.run(
                ["ruby", "-e", script, str(tmp / "manifest.json"), str(bg.SHIPPED_CATALOG)],
                capture_output=True, text=True, env={**__import__("os").environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"},
            )
            self.assertEqual(0, proc.returncode, proc.stderr)
            ruby = json.loads(proc.stdout)
        for name, docs in cases.items():
            py_validate = [bg.validate_v2(d, CATALOG) for d in docs]
            self.assertEqual(ruby[name]["validate"], py_validate, f"{name}: validate_v2")
            py_f = bg.faithful(docs, CATALOG)
            rb_f = ruby[name]["faithful"]
            self.assertEqual(sorted(rb_f), sorted(py_f), f"{name}: keys")
            for key in rb_f:
                self.assertEqual(rb_f[key], py_f[key], f"{name}: {key}")
        # sanity: the fixtures actually exercise both outcomes
        self.assertTrue(ruby["faithful"]["faithful"]["faithful"])
        self.assertFalse(ruby["major_fixable"]["faithful"]["faithful"])
        self.assertTrue(any(ruby["dim_mismatch"]["validate"][0]))


    def test_python_and_ruby_extras_and_catalog_errors_agree(self):
        bad_docs = {
            "verdict_bad": grade(90, verdict="maybe"),
            "verdict_absent": {k: v for k, v in grade(90).items() if k != "verdict"},
            "per_tile_missing": {k: v for k, v in grade(90).items() if k != "per_tile"},
            "per_tile_empty": grade(90, per_tile=[]),
            "per_tile_bad_row": grade(90, per_tile=[{"position": 1, "source_family": "bar"}]),
            "ok": grade(90),
        }
        good = json.loads(Path(bg.SHIPPED_CATALOG).read_text())
        dup = json.loads(json.dumps(good))
        dup["entries"].append(dict(dup["entries"][0]))
        bad_cats = {
            "missing": None,
            "not_json": "{nope",
            "not_object": "[]",
            "bad_version": json.dumps({**good, "version": 2}),
            "entries_not_array": json.dumps({"version": 1, "entries": {}}),
            "dup_id": json.dumps(dup),
            "bad_entry": json.dumps({"version": 1, "entries": [
                {"id": "x", "dimension": "nope", "description": "", "evidence": "e",
                 "last_verified": "yesterday", "source_tools": "t"}, 3]}),
        }
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            docs = {}
            for name, doc in bad_docs.items():
                p = tmp / f"{name}.json"
                p.write_text(json.dumps(doc))
                docs[name] = str(p)
            cats = {}
            for name, text in bad_cats.items():
                p = tmp / f"cat-{name}.json"
                if text is not None:
                    p.write_text(text)
                cats[name] = str(p)
            (tmp / "m.json").write_text(json.dumps({"docs": docs, "cats": cats}))
            script = (
                "require 'json'; require %r; " % str(RUBY_LIB)
                + "m = JSON.parse(File.read(ARGV[0])); out = { 'docs' => {}, 'cats' => {} }; "
                "m['docs'].each { |n, p| r = BlindGrade.load_and_validate(p, workdir: File.dirname(p), "
                "catalog: BlindGrade.load_catalog(ARGV[1])); "
                "out['docs'][n] = r['errors'].select { |e| e =~ /per_tile|verdict must/ } }; "
                "m['cats'].each { |n, p| out['cats'][n] = BlindGrade.load_catalog(p)['errors'] }; "
                "puts JSON.generate(out)"
            )
            proc = subprocess.run(
                ["ruby", "-e", script, str(tmp / "m.json"), str(bg.SHIPPED_CATALOG)],
                capture_output=True, text=True,
                env={**__import__("os").environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"},
            )
            self.assertEqual(0, proc.returncode, proc.stderr)
            ruby = json.loads(proc.stdout)
            for name, path in docs.items():
                doc = json.loads(Path(path).read_text())
                self.assertEqual(ruby["docs"][name], bg.validate_extras(doc), name)
            for name, path in cats.items():
                py = bg.load_catalog(path)["errors"]
                if name == "not_json":  # parser wording differs by language; prefix must agree
                    py = [e.split(": ")[0] for e in py]
                    ruby["cats"][name] = [e.split(": ")[0] for e in ruby["cats"][name]]
                self.assertEqual(ruby["cats"][name], py, f"catalog {name}")
        self.assertTrue(ruby["docs"]["verdict_bad"])
        self.assertTrue(ruby["docs"]["per_tile_missing"])
        self.assertEqual([], ruby["docs"]["ok"])
        self.assertTrue(ruby["cats"]["bad_entry"])


class V2DegradationsTest(unittest.TestCase):
    def test_divergent_adds_visual_verdict_and_gaps(self):
        decision = bg.faithful([grade(90, gaps=[gap(severity="major", description="bad axis"), gap()])], CATALOG)
        out = bg.v2_degradations(decision, "blind-grade.json")
        items = [d["item"] for d in out]
        self.assertEqual("visual verdict: divergent", items[0])
        self.assertIn("visual residual (major): Tile A: bad axis", items)
        self.assertIn("visual residual (minor): Tile A: d", items)
        self.assertTrue(all(d["class"] == "fidelity-residual" for d in out))

    def test_faithful_clean_has_none_and_minor_only_is_polish_note(self):
        self.assertEqual([], bg.v2_degradations(bg.faithful([grade(90)], CATALOG), "b.json"))
        decision = bg.faithful([grade(90, gaps=[gap()])], CATALOG)
        self.assertEqual([], bg.v2_degradations(decision, "b.json"))
        self.assertEqual(
            [{"item": "Tile A: d", "dimension": "composition_match", "source_artifact": "b.json"}],
            bg.v2_polish_notes(decision, "b.json"),
        )

    def test_polish_notes_dedupe_keep_order_and_severity_normalised(self):
        decision = {"faithful": True, "fixable_major": [], "platform_differences": [],
                    "residuals": [gap(description="x"), gap(description="x"),
                                  gap(description="y", severity=" Minor ")]}
        notes = bg.v2_polish_notes(decision, "b.json")
        self.assertEqual([], bg.v2_degradations(decision, "b.json"))
        self.assertEqual(["Tile A: x", "Tile A: y"], [n["item"] for n in notes])

    def test_unfaithful_keeps_minor_as_degradation_and_no_polish_notes(self):
        decision = bg.faithful([grade(40, gaps=[gap()])], CATALOG)
        self.assertFalse(decision["faithful"])
        self.assertEqual([], bg.v2_polish_notes(decision, "b.json"))
        items = [d["item"] for d in bg.v2_degradations(decision, "b.json")]
        self.assertEqual(["visual verdict: divergent", "visual residual (minor): Tile A: d"], items)

    def test_major_gap_keeps_minor_degradation_no_polish_notes(self):
        decision = bg.faithful([grade(90, gaps=[gap(severity="major", description="m"), gap()])], CATALOG)
        self.assertEqual([], bg.v2_polish_notes(decision, "b.json"))
        items = [d["item"] for d in bg.v2_degradations(decision, "b.json")]
        self.assertIn("visual residual (minor): Tile A: d", items)
        self.assertIn("visual residual (major): Tile A: m", items)


def _entry(eid, dim="composition_match", desc=None):
    return {"id": eid, "dimension": dim, "description": desc or f"{eid} differs",
            "evidence": "probe", "last_verified": "2026-11-10"}


class CatalogHistoryTest(unittest.TestCase):
    """Ancestor rule (catalog_compat), mirrored field for field with Ruby."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.cat_path = self.tmp / "sigma-platform-differences.json"
        self.records = []
        a = [_entry("legend-inside"), _entry("font-family", "labels_legible")]
        self.sha_a = self.write_catalog(a)
        self.sha_chg = self.write_catalog([_entry("legend-inside", desc="reworded"), a[1], _entry("x")])
        self.sha_rm = self.write_catalog([a[1]])
        self.sha_b = self.write_catalog(a + [_entry("row-height-fixed")])  # B = A + one entry, current
        self.cat = bg.load_catalog(self.cat_path)

    def write_catalog(self, entries):
        data = json.dumps({"version": 1, "entries": entries}, indent=2).encode()
        self.cat_path.write_bytes(data)
        parsed = bg.parse_catalog_bytes(data)
        self.assertEqual([], parsed["errors"])
        if parsed["sha256"] not in [r["sha256"] for r in self.records]:
            self.records.append({"sha256": parsed["sha256"], "entries": parsed["entry_hashes"]})
        Path(bg.history_path_for(self.cat_path)).write_text(
            json.dumps({"schema": bg.HISTORY_SCHEMA, "catalogs": self.records}))
        return parsed["sha256"]

    def test_current_sha_still_accepted(self):
        out = bg.catalog_compat(self.sha_b, self.cat)
        self.assertEqual((True, "current", []), (out["ok"], out["status"], out["new_ids"]))

    def test_ancestor_subset_accepted(self):
        out = bg.catalog_compat(self.sha_a.upper(), self.cat)
        self.assertEqual((True, "ancestor"), (out["ok"], out["status"]))
        self.assertEqual(["row-height-fixed"], out["new_ids"])
        self.assertEqual(["legend-inside", "font-family"], out["graded_ids"])

    def test_changed_entry_refused(self):
        out = bg.catalog_compat(self.sha_chg, self.cat)
        self.assertFalse(out["ok"])
        self.assertIn("legend-inside was CHANGED", out["error"])

    def test_removed_entry_refused(self):
        self.write_catalog([_entry("legend-inside"), _entry("font-family", "labels_legible")])
        out = bg.catalog_compat(self.sha_b, bg.load_catalog(self.cat_path))
        self.assertFalse(out["ok"])
        self.assertIn("row-height-fixed was REMOVED", out["error"])

    def test_unknown_sha_refused(self):
        out = bg.catalog_compat("e" * 64, self.cat)
        self.assertFalse(out["ok"])
        self.assertIn("unknown catalog", out["error"])
        self.assertIn("catalog_sha256 mismatch", out["error"])

    def test_ancestor_grade_cannot_cite_a_later_id_and_keeps_gaps_as_graded(self):
        doc = grade(85, sha=self.sha_a, gaps=[gap("font-family", "labels_legible"), gap()])
        self.assertEqual([], bg.validate_v2(doc, self.cat))
        dec = bg.faithful([doc], self.cat)
        self.assertEqual(["fixable"], [g["class"] for g in dec["residuals"]])
        late = grade(85, sha=self.sha_a, gaps=[gap("row-height-fixed")])
        self.assertTrue(any("added AFTER" in e for e in bg.validate_v2(late, self.cat)))

    def test_malformed_history_fails_closed(self):
        Path(bg.history_path_for(self.cat_path)).write_text('{"schema": "nope", "catalogs": []}')
        cat = bg.load_catalog(self.cat_path)
        self.assertFalse(bg.catalog_compat(self.sha_a, cat)["ok"])
        self.assertTrue(bg.catalog_compat(self.sha_b, cat)["ok"])

    def test_canonical_json_vector_matches_ruby_pin(self):
        value = {"z": "é— \u0001\u007f😀\"\\/", "a": [1, -2, True, False, None, {}], "B": {}}
        self.assertEqual(
            '{"B":{},"a":[1,-2,true,false,null,{}],"z":"\\u00e9\\u2014\\u2028\\u0001\\u007f\\ud83d\\ude00\\"\\\\/"}',
            bg.canonical_json(value),
        )
        with self.assertRaises(ValueError):
            bg.canonical_json({"x": 1.5})

    def test_ruby_and_python_agree_on_history_and_compat(self):
        shas = [self.sha_a, self.sha_b, self.sha_chg, self.sha_rm, "e" * 64, None]
        script = (
            "require 'json'; require %r; " % str(RUBY_LIB)
            + "cat = BlindGrade.load_catalog(ARGV[0]); shas = JSON.parse(ARGV[1]); "
            "puts JSON.generate('hashes' => cat['entry_hashes'], 'history' => cat['history'], "
            "'compat' => shas.map { |s| BlindGrade.catalog_compat(s, cat) })"
        )
        proc = subprocess.run(
            ["ruby", "-e", script, str(self.cat_path), json.dumps(shas)], capture_output=True, text=True,
            env={**__import__("os").environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"},
        )
        self.assertEqual(0, proc.returncode, proc.stderr)
        ruby = json.loads(proc.stdout)
        self.assertEqual(ruby["hashes"], self.cat["entry_hashes"])
        self.assertEqual(ruby["history"], self.cat["history"])
        for sha, rb in zip(shas, ruby["compat"]):
            self.assertEqual(rb, bg.catalog_compat(sha, self.cat), f"compat {sha}")

    def test_non_string_id_is_a_catalog_error_in_both_twins(self):
        data = json.dumps({"version": 1, "entries": [{**_entry("x"), "id": True}]})
        py = bg.parse_catalog_bytes(data.encode())["errors"]
        rb = subprocess.run(
            ["ruby", "-e", "require 'json'; require %r; puts JSON.generate(BlindGrade.parse_catalog_bytes(ARGV[0])['errors'])"
             % str(RUBY_LIB), data], capture_output=True, text=True,
            env={**__import__("os").environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"},
        )
        self.assertEqual(0, rb.returncode, rb.stderr)
        self.assertEqual(json.loads(rb.stdout), py)
        self.assertTrue(any("id must be a string (got TrueClass)" in e for e in py), py)

    def test_shipped_history_lists_the_shipped_catalog(self):
        self.assertEqual([], CATALOG["history_errors"])
        self.assertEqual(CATALOG["entry_hashes"], CATALOG["history"][CATALOG["sha256"]])


if __name__ == "__main__":
    unittest.main()
