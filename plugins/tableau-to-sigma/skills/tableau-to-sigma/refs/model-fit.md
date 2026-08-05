<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Model fit & vision requirements -->

# Model fit & vision requirements

Design quality on this skill is **not** model-independent. The same skill version, on the
same healthy environment, produces measurably different dashboard fidelity depending on
which agent/model drives it (measured root cause #2/#3 of cross-user variance in the
2026-07 10-workbook live migration: 10 workbooks, 30 dashboards, 10/10 GREEN — every GREEN came
from 4–6 render-compare-fix passes by a vision-capable, top-tier agent). This ref makes the
two preconditions explicit and gives you one mandatory checkpoint. It is short — read all
of it.

## 1. Vision is a hard requirement for pixel-fidelity claims

The visual fidelity loop (**Phase 5g** RCF and the **Phase 6f** full-dashboard comparison)
works by the agent **Reading two PNGs** — the source dashboard render and the Sigma page
render — and judging the delta. There is no text-mode substitute: CSV parity proves the
numbers, not the design.

- **If you can read images** (the Read tool returns the picture, not a description of a
  file), run the loop normally and record verdicts with `record-visual-check.rb
  --verdict pass|divergent`.
- **If you cannot read images** (text-only agent, or image input disabled in this
  session), you MUST NOT record `pass` — that is a blind attestation, the exact failure
  mode gate 8b exists to stop. Record the verdict as **not-executable** instead: run the
  gate with the named degradation
  `--skip-visual-comparison "visual gate not executable: driving agent lacks image input — run the RCF loop from a vision-capable session"`
  and name it in your report. The conversion can still complete, but it ships **without a
  pixel-fidelity claim**, and the report must say so. Never silently attest.
- The same applies to the Phase 1d dashboard-read: `png-read.json` must come from actually
  Reading the source PNG. A text-only agent should ask the user (or a vision-capable
  session) to perform the read rather than fabricating tile inventories.

## 2. Model tier vs workbook complexity

Observed across audited runs:

- **Complex conversions** — multi-dashboard workbooks, dense zone trees (30+ zones per
  dashboard), exotic chart families (sankey/chord/polar/waffle/bump/floating bars), heavy
  calc-field translation (50+ calcs, nested LODs, parameter-driven metric switchers) —
  benefit materially from the **most capable model tier (Opus-class)**. The design
  synthesis (banded layouts, brand extraction, RCF judgment) is agent judgment, and the
  gap between tiers shows up directly as extra fix iterations or shipped composition
  regressions.
- **Simpler workbooks** — single dashboard, standard chart kinds, modest calc counts —
  convert well on **mid-tier (Sonnet-class)**. Don't push users to switch for these.
- Anything below mid-tier, or any agent without image input, should not drive a
  conversion end-to-end (see §1); it can still run the mechanical scripted phases.

## 3. MANDATORY Phase 0 checkpoint (execute, don't paraphrase away)

At Phase 0, after `scan-workbook-gaps.rb` and `estimate-cost.rb` have produced the
complexity bucket, evaluate:

**IF** the bucket is `large` or `very-large` — or any of: more than 1 dashboard, more than
30 zones on any dashboard, any ❌/manual rows in `gaps.json`, more than 50 calc fields —
**AND** the current model is not the top tier, **THEN pause and ask the user once** before
proceeding. Suggested wording (fill in N/M/K from the gap scan + cost estimate):

> "This workbook is complex (N dashboards, M chart zones, K calc fields). You're running
> on a mid-tier model; the most faithful design results in our testing came from the most
> capable tier (Opus-class) with image input. Continue on the current model, or switch
> (e.g., `/model opus`) and re-run? Continuing is fine — expect to spend more fix
> iterations in the visual loop."

Rules:

- **Never silently proceed on a `very-large` bucket without asking once.** One ask, then
  respect the user's answer — do not re-ask every phase.
- If the user says continue, record their choice in your report and budget extra RCF
  passes (Phase 5g default budget is 5; expect to use them).
- If the workbook is small/medium and no trigger fires, do not ask — proceeding on a
  mid-tier model is the normal, supported path.

## 4. Introspecting your own tier honestly

You know your own model family from your system context (the system prompt names the
model, e.g. "You are powered by ... Opus/Sonnet/Haiku"). Use that — do not guess from
capability vibes, and do not claim a tier you cannot verify. Mapping: Opus-class = top
tier; Sonnet-class = mid tier; Haiku-class (or any small/fast model) = below the bar for
end-to-end conversions. Non-Anthropic agents: map by the vendor's own flagship/mid/small
tiering. **If you are unsure which model is selected, ask the user** ("Which model is this
session running on?") rather than assuming top tier — an honest "I don't know, please
confirm" costs one message; a silently-wrong tier assumption costs the checkpoint its
entire purpose.

Vision self-test: if you cannot recall actually seeing image content in this session and
you are unsure whether Read returns pictures to you, test it on the source dashboard PNG
the moment discovery produces one — before Phase 1d, so a text-only session degrades
loudly at the first gate instead of at Phase 6f.
