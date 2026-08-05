# The migration request — kickoff template + mission intake

Fidelity is enforced by the pipeline's gates, not by prompt wording. What a vague
request DOES cause is improvised **scope** decisions before the pipeline starts —
and in field runs those improvisations (a guessed project, an assumed folder, an
unstated landing schema, a skill copy that was never installed) invalidated whole
sessions before the first gate could fire. This file closes that hole from both
sides: a copy-paste request template for the person asking, and a mandatory
mission-intake step for the agent receiving it.

---

## For users — the kickoff template (copy, fill, paste)

> Migrate **<Tableau project URL, or explicit workbook list>** to Sigma.
>
> - **Sigma connection:** <connection name or id>
> - **Destination:** <workspace / folder name> (create it if absent)
> - **Data landing** (embedded-extract workbooks): land into **<DB>.<SCHEMA>**
>   using the skill's landing script
> - Use the **installed tableau-to-sigma plugin's gated pipeline end-to-end**
>   (`migrate-tableau.rb`). Never hand-roll Tableau/Sigma API calls or data loads.
> - Run **one builder agent per workbook** (`scripts/builder-brief.md`); final
>   verdicts are countersigned by a **fresh verifier agent**
>   (`scripts/verifier-brief.md`) — the builder never grades its own work.
> - Fidelity standard: **the source dashboard is the spec** — values must match
>   the source exactly (anchors gate), layout/design/controls/parameters per the
>   render-compare-fix loop, interactivity handed off via the post-publish guide.
>   Anything not replicable goes in the gap report classified skill-gap vs
>   Sigma-product-gap with the best workaround.
> - **If any of the above is ambiguous, stop and ask me. Never assume.**

Every placeholder you leave out is a decision the agent must either ask about or
invent. Ask-and-wait costs 30 seconds; a wrong invention costs the run.

## For agents — mission intake (MANDATORY, before Phase 0)

Before the doctor/Phase 0, restate the request as `<workdir>/mission.json`:

```json
{
  "source":       {"value": "<project url|workbook list>", "provenance": "stated|inferred"},
  "sigma_connection": {"value": "<id>",                    "provenance": "stated|inferred"},
  "destination":  {"value": "<folder/workspace>",          "provenance": "stated|inferred"},
  "landing":      {"value": "<DB.SCHEMA or n/a>",          "provenance": "stated|inferred"},
  "scope":        {"value": ["<workbook>", "..."],         "provenance": "stated|inferred"}
}
```

Rules:
- `provenance` is **`stated`** only when the user's words pin it. Everything you
  filled in yourself is **`inferred`**.
- **Any `inferred` field → STOP and confirm with the user before building**
  (present your inference and the alternatives — e.g. resolve-project's
  candidate table for the source, `pick-destination.rb list` for the folder).
  This generalizes the Phase-1a no-guessing gate to every scope decision: a
  wrong project/folder/schema wastes the entire run no matter how well the
  gates work afterward.
- Numeric `/projects/<id>` URLs resolve via `scripts/resolve-project.rb`
  (never by name-similarity or recency).
- Then proceed: doctor → intake.rb → the gated spine, with builders/verifiers
  per `refs/orchestration.md`.
