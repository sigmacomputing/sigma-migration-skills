# Contributing to sigma-migration-skills

This repo grows fast (15+ converters/assessments) and is often worked by several
sessions at once. The rules below keep skills consistent and keep parallel PRs
from colliding. Most are enforced by CI (`.github/workflows/corpus-check.yml`) —
the goal is that "remember to…" is a failing check, not a hope.

## The arc every converter follows

The canonical Assess → Discover → Reuse-check → Convert → Post-DM gate → Build →
Layout → Parity → Security → Enhance arc (C1–C10) is in
[`docs/phase-schema.md`](docs/phase-schema.md), with each skill's local
phase-number mapping. **Never renumber a skill's phases** — scripts, gates, and
memory notes reference the local numbers. When you add a converter, add its
column to that table.

Mandatory gates (CI lints each converter SKILL.md for them — `tools/lint-skills.rb`):

- **C3 Reuse-check** — score existing Sigma DMs before creating one (`find-or-pick-dm.rb`).
- **C5 Post-DM gate** — POST the DM, **read back** real ids, wire the workbook to those.
- **C7 Layout** — apply layout as the **LAST write** (a bare spec PUT wipes it).
- **C8 Parity** — source vs Sigma (vs warehouse) — hard gate, never skip.
- **C9 Security** — detect RLS/CLS always; apply opt-in.

A genuinely-N/A gate goes in `tools/skill-lint-baseline.json` with a reason
(shows as a tracked WARN). Drive that file toward empty.

## Shared infrastructure — edit canonical, never a copy

Shared libs (`lib/sigma_rest.rb`, the lints, `escalate-gap.py`,
`find-or-pick-dm.rb`, `get-token.sh`, …) are **vendored byte-identical** into
every plugin so each plugin ships self-contained for the marketplace. The single
source of truth is [`shared/`](shared/); the fan-out is declared in
[`shared/manifest.json`](shared/manifest.json).

To change a shared file:

```bash
$EDITOR shared/scripts/find-or-pick-dm.rb   # edit the CANONICAL copy
ruby tools/sync-shared.rb                    # propagate to every plugin copy
git add shared/ plugins/                     # commit canonical + the fan-out
```

CI (`tools/check-shared.rb`) fails if any vendored copy drifts from canonical.
Intentional per-tool forks are allowlisted in `shared/manifest.json` (`exception`
+ reason). **Shared-lib changes go in their own PR**, merged before dependent
work — so concurrent feature PRs never both touch a copy.

## Per-agent instruction variants — edit SKILL.md, never a generated copy

Some skills ship non-Claude agent variants under `<skill>/generated/{cursor,codex,
cline,continue}/`. These are **generated from the skill's `SKILL.md`** so every
coding agent reads the SAME instructions. Never hand-edit a file under
`generated/` — edit `SKILL.md` and regenerate:

```bash
ruby tools/gen-agent-variants.rb --all   # regenerate every skill's variants
git add plugins/                         # commit SKILL.md + the regenerated variants
```

CI (`tools/check-agent-variants.rb`) fails if any committed variant drifts from
what `SKILL.md` would generate. Use the `<!-- agents:claude-only -->` /
`<!-- agents:non-claude … agents:end -->` markers in `SKILL.md` for the rare
content that must differ per agent.

## Adding a new converter

```bash
ruby tools/new-skill.rb <tool> "<Display Name>"
ruby tools/check-shared.rb && ruby tools/lint-skills.rb   # both green
```

The scaffolder stamps both skills with the mandatory gates documented, syncs +
registers the shared infra, and adds a `docs/phase-schema.md` stub. Then do the
printed human TODOs: marketplace entry, `AGENTS.md` row, a `corpus/` case, and
fill the SKILL.md prose.

## Local hooks (recommended — catch gate failures before you push)

Enable the repo's git hooks once per clone:

```bash
git config core.hooksPath .githooks
```

`pre-commit` and `pre-push` then run the same creds-free governance gate CI runs
(`.githooks/run-governance-checks.sh`: shared-lib drift, skill conformance, the
full hygiene sweep, the tracked-litter lint, the ESM-import and .twb-encoding
lints, agent-variant sync, and the bootstrap/doctor lockstep guard — ~10s total,
the sweep is most of it) so violations are caught locally instead of after a
push. The same setting enables the `commit-msg` hook, which greps each commit
message against the hygiene pattern sets (next section). Bypass with
`--no-verify` if you must — CI runs the same gate server-side, including a
push-range commit-message scan, so a bypass only defers the failure.

## Hygiene sweep (no test-org identifiers, ever)

Run `bash tools/hygiene-sweep.sh` before every commit (the governance hook runs
it). Five passes: every **tracked** file; the **staged diff** — including the
staged blobs of files whose gitattributes unset `diff`, which `git diff` would
otherwise hide as "Binary files differ"; every **untracked**, not-ignored file;
an **encoding-aware** pass over fixture binaries and anything binary-classified
(each candidate scanned as UTF-16LE/BE + UTF-32LE/BE + a strings view); and
file/directory **paths** — a fixture named after a real workbook has perfectly
neutral content, so names are scanned too. Patterns come from
`tools/hygiene-patterns.txt` **plus** the gitignored
`tools/hygiene-patterns.local.txt` (customer-derived guards; CI injects the
same set from the `HYGIENE_PRIVATE_PATTERNS` secret — keep secret and local
file in sync when you add one). Without the local file the sweep **WARNs**: a
clean exit with committed patterns only proves nothing about customer
identifiers. It fails with named hits if any test-org or customer identifier
(connection, workbook, customer, datasource, field/value literal, or object id)
appears anywhere. When new test infrastructure or a customer transcript enters
the vocabulary, add its stable identifiers to the right pattern file first and
write code/docs against neutral replacements ("the field workbook",
`<connection-id>`, "Region A & B"-style literals).

Commit messages and PR bodies are inside the hygiene boundary too — the file
sweep never sees them. The `.githooks/commit-msg` hook greps each proposed
message against the same pattern sets the sweep loads (committed file + the
gitignored `tools/hygiene-patterns.local.txt` when present), scanning
everything above the scissors line — **including `#`-prefixed lines**, which
`git commit -m`/`-F` (cleanup=whitespace) keep in the landed message. The
hygiene workflow applies the same check server-side: its "Commit-message
hygiene" step feeds each push/PR-range commit's `%B` to the same hook, so
`--no-verify` and unconfigured-hook bypasses are caught at the gate. Failures
report pattern-file **line numbers only** — matched text is never echoed, so a
hit on a private guard discloses nothing in a shared log.

**History decision (recorded 2026-07-18; re-measured 2026-07-22 — counts only
per the rule above):** history predating these guards carries identifier
residue. Mechanical basis: `git log --format=%B` over every commit reachable
from any pushed ref, grepped case-insensitively against both pattern sets (50
committed + 62 local at measurement). Messages: **25 commits** match a private
customer guard (22 reachable from `origin/main`, 3 only on two stale side
branches); **124 commits** match any active pattern (89 on `origin/main`) —
the committed-pattern bulk is test-infrastructure vocabulary from before the
sweep existed. An earlier revision of this note said "six commits"; that
undercounted (smaller pattern set, subjects only) and is superseded by the
basis above. File contents: pre-neutralization revisions of later-neutralized
files (a corpus case and a handoff doc) also remain reachable from
`origin/main` history. Decision for messages and file history alike:
**accept the residue — do not rewrite history.** A rewrite would orphan every
clone, open PR, and pinned SHA to scrub name-level (non-credential) leaks,
while the sweep, hooks, and CI range scan prevent recurrence. Cheap exposure
reduction worth doing: delete stale pushed side branches whose hit-carrying
commits never reached `main`. Revisit only if the repo is ever re-homed — a
fresh-history mirror is the cheaper fix at that point. This note records
counts only, never the identifiers.

## Run state stays local

Run registries and local run state never enter the repo. That covers the
cross-run registries (`probe-artifacts.jsonl`, `posted-workbooks.jsonl`,
`offramps.jsonl`), `workdir-*/` state a field run leaves inside a skill tree,
and everything under `~/.tableau-to-sigma/` (customer learned rules appended by
scout-validate-and-persist) — all of it carries run/environment fingerprints or
customer-derived rule text. The skill-root `.gitignore` ignores these shapes,
and `tools/lint-tree-litter.sh` (run by the governance hook) fails if one is
ever tracked. When a run artifact holds something worth keeping, neutralize it
into a `corpus/` fixture or a committed starter rule (neutral names and
placeholder literals, per the hygiene sweep section) — the raw artifact itself
is never committed.

## Regression: the corpus

Changing a converter/builder? Run `./corpus/run-corpus.sh --check` and reconvert
the affected case (`--reconvert` / `--diff`). Every converter must have at least
one `corpus/<tool>/<case>/` fixture with a golden output. See `corpus/README.md`.

## Working in parallel (multiple sessions / PRs)

Sessions can't talk live, so coordinate through shared state:

1. **Claim work up front** at **plugin granularity** — open (or comment on) a
   GitHub issue for the plugin before touching it, so contributors don't collide.
   One issue ≈ one plugin ≈ one PR.
2. **One PR = one plugin** (or one isolated shared-lib change). Don't mix plugins
   in a PR — it serializes review and invites merge conflicts.
3. **Use a git worktree per session** so parallel edits never stomp each other:
   `git worktree add ../sms-<tool> -b <tool>-work`.
4. **Shared-lib edits are their own PR**, merged first (see above).
5. Rebase on `main` before opening the PR; the CI gates catch drift introduced by
   another session that merged ahead of you.

## Before opening a PR

`ruby tools/check-shared.rb && ruby tools/lint-skills.rb && bash tools/hygiene-sweep.sh && ./corpus/run-corpus.sh --check`
— all green. The PR template (`.github/PULL_REQUEST_TEMPLATE.md`) lists the rest.

## Versioning & releases

Each plugin declares its release version in
`plugins/<name>/.claude-plugin/plugin.json` (`"version"`). Claude Code's
`claude plugin update` compares that string, so **if it doesn't move, consumers
never see your fix** — the update reports "already at the latest version" and
ships nothing (issue #486).

**Rule:** any change under `plugins/<name>/**` must bump that plugin's
`plugin.json` `version` — a strict [semver](https://semver.org/) increase
(patch for fixes, minor for features, major for breaking changes). The
`plugin-version-bump` CI gate enforces this over the PR's diff range.

**Escape hatch:** for a genuinely non-user-facing change (a comment, an internal
test, a typo that ships no behavior), add a commit trailer:

```
Skip-Version-Bump: <one-line reason>
```

The reason is required and is visible in history and review — use it honestly.
The trailer is global to the PR's whole diff range: a single `Skip-Version-Bump`
commit anywhere in the range exempts every otherwise-failing plugin in that PR,
not just the plugin its own commit touched.
