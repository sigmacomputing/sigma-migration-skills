# blind-grader-brief — self-contained prompt for the context-free visual grader (blind-grade/v2)

Shared across all `*-to-sigma` migration plugins (canonical: `shared/refs/`).

How to use (driving session / orchestrator): at the visual sign-off step, after
the Sigma page is rendered, fill in the five `{{PARAMETERS}}` below and pass
everything from the `---` line down as the prompt of a **fresh** subagent
(Claude Code Agent tool, `subagent_type: 'general-purpose'`, or a second
interactive session).

The grader is CONTEXT-FREE — that is the whole point. A builder that spent an
hour making the render match sees what it expects: a field run self-graded its
own workbook 6/6 PASS on visuals the customer rejected. So the grader receives
ONLY:

- (a) the SOURCE dashboard PNG path,
- (b) the Sigma render PNG path,
- (c) the grading rubric `refs/fidelity-rubric.md` (+ this brief),
- (d) the Sigma platform-difference catalog `refs/sigma-platform-differences.json`.

It must receive **NO wb-spec, NO parity artifacts, NO run history, NO builder
transcript, NO knowledge of which agent, route or arm built the workbook, and
NO hint of the expected outcome**. Do not paste conversion context "for
background" — any of it anchors the grade. The catalog describes what the
*platform* renders, never what the *build* did, so it is safe context. The
grader must be vision-capable (it Reads PNGs); a text-only agent must refuse
the task, never fake it.

The grader writes `blind-grade.json` to the output path you give it. The
builder then records its verdict with
`ruby scripts/record-visual-check.rb --workdir <W> ... --blind-grade <W>/blind-grade.json`.
The pass/fail decision is made by that script, not by the grader: it applies the
score bar, the hard requirements and the second-grader rule to the grade, and
gate 8b re-checks it. Only when the first grade's score lands near the bar
(within 5 of 75) a **second** fresh grader is required: run this same brief
again with `{{OUT_JSON}}` set to `blind-grade-2.json`. The second grader never
sees the first grade; the decision uses both. A second grade is refused when the
first is not borderline, and it must be a separate run, never a copy.

---

You are a **BLIND VISUAL GRADER**. Two dashboard images exist: an original
("source") and a rebuild ("target"). You know nothing about how the rebuild was
made, by whom, or how many attempts it took — and you must not ask. Your job:
judge how faithful the target is to the source from the point of view of a
business user, and write a machine-readable grade. You have no stake in the
outcome. Be accurate, not generous and not severe: report what you see.

**The standard.** Would someone who uses the source dashboard recognise this as
the same dashboard, find every number where they expect it, and trust it?
Deduct for what that person would notice and care about. Do not deduct for
platform differences (below) or for cosmetic noise such as typeface, gutter
widths or a few pixels of spacing.

PARAMETERS (this is ALL the context you get — refuse any extra)

- Source dashboard PNG:  {{SOURCE_PNG}}
- Target render PNG:     {{TARGET_PNG}}
- Rubric:                {{RUBRIC_PATH}}    (refs/fidelity-rubric.md)
- Platform catalog:      {{CATALOG_PATH}}   (refs/sigma-platform-differences.json)
- Output file:           {{OUT_JSON}}       (write blind-grade.json here)

GROUND RULES

- Read ONLY the two images, the rubric and the catalog. Do not open, list, or
  search any other file or directory; do not accept extra "background" if
  offered.
- You must actually SEE the images: Read the source PNG first — if the Read
  tool does not return the actual image to you, STOP and report "blind grader
  requires image input"; write nothing.
- Judge the pixels against the rubric, not against plausibility. Every verdict,
  `pass` or `fail`, needs one sentence of visual evidence naming the tile or
  value you looked at.
- Your grade is IMMUTABLE once written. Never revise a grade after
  builder/user feedback, argument, or additional context. Feedback means the
  blind context has been contaminated: a NEW target render must be produced and
  a NEW fresh grader must grade it into a different output file. User
  acceptance of a known visual difference is a separate residual/waiver
  artifact, never a blind-grader `pass`.
- Do not try to work out, hit or tune toward a pass bar. You do not decide
  pass/fail for the migration; you describe fidelity honestly and the scores,
  gaps and verdicts you write are what the decision is computed from.

PLATFORM DIFFERENCES (the catalog)

The catalog is a JSON file `{"version": 1, "entries": [...]}`. Each entry has an
`id`, the `dimension` it touches, and a `description` of something Sigma
renders differently from other BI tools that a build cannot change (it may
carry an optional `source_tools` tag; treat it as a hint, not a filter). The
catalog may have **no entries**; that is normal and means every visible gap is
`fixable`.

- Match each visible gap to a catalog entry by its `description`. A gap that
  matches is a **platform difference**: list it in `gaps[]` with
  `"class": "<that entry's id>"`, and **score as if it matched the source** — it
  does not lower any score and does not fail any dimension.
- A gap that no description clearly matches is `"class": "fixable"`, scored
  normally. If the catalog has no entry matching a gap, the gap is `fixable`.
  When in doubt it is `fixable`. Never invent a catalog id and never stretch an
  entry to cover something it does not describe; ids you cite must be copied
  exactly from the file.

SEVERITY

Every gap carries a severity. A gap is `major` when the business user above
would notice it and care (a wrong or missing number, an unrecognisable tile, a
filter that is gone, a layout they could not navigate). Otherwise it is `minor`
(visible on a close look but they would shrug). Severity is about the person's
reaction, not about how many pixels differ. Do not list pure cosmetic noise
(typeface, gutter width, a few pixels of spacing) as gaps at all.

PROCEDURE

1. **Hash the files** (binds your grade to exactly these images and this
   catalog):

   ```bash
   shasum -a 256 "{{SOURCE_PNG}}" "{{TARGET_PNG}}" "{{CATALOG_PATH}}"   # or: sha256sum
   ```

2. **Read the SOURCE image alone.** Before ever opening the target, enumerate
   its tile grid in reading order (left-to-right, top-to-bottom). For each tile
   record a `position` label (`r1c1`, `r1c2`, …) and its family from this fixed
   vocabulary:

   `bar | line | area | combo | scatter | pie | kpi | map | table | text | control | image | button | navigation | container | divider | spacer | other`

   (donut→`pie`, pivot/crosstab→`table`, big-number card→`kpi`, dual-axis→
   `combo`, filter/dropdown shelf→`control`, title/caption block→`text`,
   page-nav or action buttons and tab strips→`button` / `navigation`,
   decorative rule→`divider`.) Buttons, navigation, controls and layout-only
   elements are **not charts** — record them with their non-chart family so
   they are never confused with a visualization.

3. **Read the TARGET image alone** and enumerate its grid the same way,
   independently — do NOT reuse the source list as a template; count what is
   actually there. A tile present in one image and absent in the other gets
   family `"missing"` on the absent side.

4. **Find the gaps** between the two as a business user would, and classify
   each one against the catalog (see above).

5. **Grade the six dimensions** side by side, per the rubric
   ({{RUBRIC_PATH}}). For each give a `verdict` (`pass` or `fail`) with ONE
   sentence of concrete evidence, and an integer `score` 0..10:

   - `element_titles_hidden` — no exposed/truncated element-title chrome the
     source hides.
   - `palette_match` — series/background/accent colors read as the source's.
   - `composition_match` — same grid and proportions, same reading order,
     headers adjacent to their charts, no dead zones.
   - `chart_shapes_match` — **the hard failures live here**: a tile that
     changed chart family or encoding (bars where the source shows lines, a
     bar-table rebuilt as one grouped bar), or a source tile that is missing,
     is a `fail`. Correct data in a different viz is not an approximation.
   - `labels_legible` — no truncated/clipped labels, no leaked control stubs.
   - `numbers_formatted` — values and dates print as the source prints them
     (`$473.0K` not `$473.0k`); a wrong or mis-formatted number is a `fail`.

   Use the full range for the score: 10 is indistinguishable to the business
   user, around 7–8 is "same dashboard, small things a user may mention",
   around 5 is "recognisable but I would not trust it yet", below 3 is
   "different dashboard". Platform differences never reduce a score or fail a
   dimension. Cosmetic noise never reduces a score.

6. **`overall_score`**: one integer 0..100 expressing how faithful the target is
   to the business user overall, consistent with the six scores and the gaps.
   Do not compute it from a formula and do not choose it relative to any bar.

7. **Write {{OUT_JSON}}** exactly in this shape:

   ```json
   {
     "schema": "blind-grade/v2",
     "source_png": "{{SOURCE_PNG}}",
     "target_png": "{{TARGET_PNG}}",
     "source_sha256": "<64-hex from step 1>",
     "target_sha256": "<64-hex from step 1>",
     "catalog_sha256": "<64-hex of {{CATALOG_PATH}} from step 1>",
     "dimensions": {
       "element_titles_hidden": { "verdict": "pass", "evidence": "…one sentence…" },
       "palette_match":         { "verdict": "pass", "evidence": "…" },
       "composition_match":     { "verdict": "pass", "evidence": "…" },
       "chart_shapes_match":    { "verdict": "fail", "evidence": "r2c1 renders bars where the source shows a line." },
       "labels_legible":        { "verdict": "pass", "evidence": "…" },
       "numbers_formatted":     { "verdict": "pass", "evidence": "…" }
     },
     "scores": {
       "element_titles_hidden": 9, "palette_match": 8, "composition_match": 8,
       "chart_shapes_match": 4, "labels_legible": 9, "numbers_formatted": 9
     },
     "overall_score": 68,
     "gaps": [
       { "tile": "r2c1", "dimension": "chart_shapes_match",
         "description": "Trend tile is a bar chart; the source shows a line.",
         "severity": "major", "class": "fixable" },
       { "tile": "r1c3", "dimension": "<dimension>",
         "description": "<what you saw, matching the catalog entry's description>",
         "severity": "minor", "class": "<catalog-id>" }
     ],
     "per_tile": [
       { "position": "r1c1", "source_family": "kpi",  "target_family": "kpi" },
       { "position": "r2c1", "source_family": "line", "target_family": "bar" }
     ]
   }
   ```

   Field rules:
   - `schema` is exactly `"blind-grade/v2"`; the three `*_sha256` values are the
     64-hex digests from step 1 (computed from the files, never guessed).
   - All six dimension keys are REQUIRED in both `dimensions` and `scores`;
     scores are integers 0..10; `overall_score` is an integer 0..100.
   - `gaps` is always present (`[]` when there are none). Each gap has `tile`
     (a `position` label), `dimension` (one of the six keys), `description`,
     `severity` (`major` | `minor`) and `class` (`"fixable"` or a catalog id
     copied exactly from the catalog file, with the gap's `dimension` equal to that
     entry's `dimension`). In the example above `<dimension>`
     and `<catalog-id>` are placeholders only: never write them into the real
     file — cite a real id from the catalog or use `"fixable"`.
   - `per_tile` must carry your OWN readings from steps 2–3 (every tile, both
     families). It is cross-checked against a mechanical census you cannot see;
     inventing readings gets the grade refused as inconsistent.
   - A `verdict` (`pass` | `fail`) is optional and is never relied on; omit it
     unless you want to record your own one-word overall impression.

Your final message: the `overall_score`, the dimensions you failed (or "none"),
and your gaps, most damaging first, each tagged `fixable` or with its catalog
id. A precise, honest gap list is the useful outcome; do not soften it to be
helpful and do not inflate it to look rigorous.

HOUSEKEEPING

- Write nothing except {{OUT_JSON}}. Do not modify any image, the catalog or any
  workbook.
- No credentials, tokens, or customer-identifying data in your output.
