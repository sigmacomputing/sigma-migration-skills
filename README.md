# Sigma Migration Skills

Sigma Migration Skills are open-source [agent skills](https://docs.claude.com/en/docs/claude-code/skills)
plugins that may be used to migrate from your existing BI tools to
[Sigma](https://www.sigmacomputing.com/) (the "**Skills**"). These open-source
Skills are released by Sigma Computing, Inc. and made available to you under the
[Apache 2.0 license](http://www.apache.org/licenses/LICENSE-2.0).

Each Skills plugin is a pair of skills — a **converter** skill (that rebuilds your
source dashboards, reports, and data models in Sigma) and an **assessment** skill
(that provides an inventory, complexity, and a value/cost shortlist). The results
are validated end-to-end, with parity checked against your source data warehouse,
not just a best-effort port.

The Skills work with any coding agent. Install them as a
[Claude Code](https://claude.com/claude-code) plugin, or use them from Cursor,
Cortex Code, Codex, and others via [`AGENTS.md`](AGENTS.md). The Skills themselves
are agent-neutral (a `SKILL.md` + `scripts/`), and credentials load from a shared
`~/.sigma-migration/env` under any agent.

## Prerequisites

Before using the Skills to run a migration from your existing BI tools to Sigma,
you need:

- **A coding agent that runs Skills** — such as Claude Code, Cursor, Cortex Code,
  Codex, Claude Desktop, or claude.ai.
- **The most capable model your agent offers.** Formula/DAX translation, RLS
  detection, and parity debugging need real judgment, so use the highest-reasoning
  tier available (e.g. Opus or Fable in Claude Code/Desktop/claude.ai; the
  comparable flagship model in Cursor, Cortex Code, or Codex).
- **Runtimes on your machine** — **Ruby**, **Python 3**, **Node 18+**, and
  **bash**. macOS/Linux usually have most of these; Windows ships none by default
  (see [Windows notes](#windows) below).
- **A Sigma API key** — a **Client ID** and **Client Secret** created under
  **Sigma Administration → Developer Access**, plus your **Sigma API base URL**
  (the region host, e.g. `https://aws-api.sigmacomputing.com`).
- **A Sigma connection** pointing at your source data warehouse (Snowflake,
  Databricks, BigQuery, Redshift, or Postgres) that your existing BI tool's
  reports and dashboards query. This is required for the parity gate.
- **The Sigma MCP server connected in your agent** — to let the agent read/query
  your Sigma org and build and validate the migrated data models and workbooks.
  Follow [Use the Sigma MCP server](https://help.sigmacomputing.com/docs/use-sigma-mcp-server)
  to connect your agent.
- **Access to your existing BI tool** — a Tableau PAT, Power BI sign-in, Qlik API
  key, etc. Per-tool details live in each plugin's `refs/connection.md`.

> **No converter to install.** Each Skill bundles its data-model converter and
> runs it **locally by default** — this means no network calls, and your source
> data never leaves your machine.

## Install

**Claude Code** — add the marketplace and install the plugins you need:

```text
/plugin marketplace add sigmacomputing/sigma-migration-skills
/plugin install sigma-authoring@sigma-migration-skills      # companion Sigma spec — install alongside any converter
/plugin install tableau-to-sigma@sigma-migration-skills
/plugin install powerbi-to-sigma@sigma-migration-skills
/plugin install qlik-to-sigma@sigma-migration-skills
/plugin install thoughtspot-to-sigma@sigma-migration-skills
/plugin install quicksight-to-sigma@sigma-migration-skills
/plugin install cognos-to-sigma@sigma-migration-skills
/plugin install looker-to-sigma@sigma-migration-skills
/plugin install microstrategy-to-sigma@sigma-migration-skills
/plugin install sisense-to-sigma@sigma-migration-skills
/plugin install gooddata-to-sigma@sigma-migration-skills
/plugin install domo-to-sigma@sigma-migration-skills
/plugin install hex-to-sigma@sigma-migration-skills
```

**Other agents (e.g. Cursor, Cortex Code, …)** — clone this Skills repo and point
your agent at the skill folders; [`AGENTS.md`](AGENTS.md) maps each task to its
skill. For example, Cortex Code:

```bash
git clone https://github.com/sigmacomputing/sigma-migration-skills
cortex skill add sigma-migration-skills/plugins/tableau-to-sigma/skills/tableau-to-sigma
```

## Configure your Sigma credentials

From any converter skill's directory, run the setup script. It writes your Sigma
credentials — Base URL, Client ID, Client Secret, and optional Connection ID — to
`~/.claude/settings.json` (Claude Code auto-loads it) **and**
`~/.sigma-migration/env` (mode `0600`, sourceable by any other agent or shell):

```bash
ruby scripts/setup.rb
```

Or export them yourself:

```bash
export SIGMA_BASE_URL='https://aws-api.sigmacomputing.com'   # your region host
export SIGMA_CLIENT_ID='<your-client-id>'
export SIGMA_CLIENT_SECRET='<your-client-secret>'            # ~128 chars, shown once at key creation
export SIGMA_CONNECTION_ID='<warehouse-connection-uuid>'     # optional; needed for the parity gate
```

Three things that trip people up:

1. **Don't paste the Client ID into the Secret field.** The secret is a separate,
   ~128-character value shown only once when the key is created.
2. **Use the right region host.** A valid token against the wrong `SIGMA_BASE_URL`
   returns 401.
3. **Tokens expire in ~1 hour.** The Skills' libraries auto-refresh — you don't
   manage this yourself.

## Run the doctor first

Each Skill ships a preflight check. Run it once per session from the skill
directory before a migration; it verifies Ruby, Python 3, Node, bash (and
versions), your Sigma credentials, and operating-system and runtime gotchas:

```bash
bash scripts/doctor.sh                                        # macOS / Linux / Git Bash
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1   # Windows
```

Exit `0` means you're good to go; exit `1` lists what to fix. The orchestrator
gates on it.

Then just describe what you want migrated — e.g. *"migrate this Power BI report
to Sigma"* — and the Skill drives the discovery → translation → build → parity
workflow.

<a id="windows"></a>
### Windows notes

Windows ships with none of the required runtimes. Common fixes:

- **Python:** install from [python.org](https://www.python.org/) (not the
  Microsoft Store stub); invoke with `py -3`.
- **bash:** install [Git for Windows](https://git-scm.com/download/win) (Git Bash)
  or use WSL.
- **Line endings:** `git config --global core.autocrlf input`.
- **Ruby:** install via [RubyInstaller](https://rubyinstaller.org/) and confirm
  it's on `PATH`.
- **Node without admin:** `winget install Schniz.fnm` then `fnm install --lts`.
- **Python TLS on OpenSSL 3.x:** `pip install truststore` (mandatory on corporate
  networks).

The Windows preflight is `scripts\doctor.ps1`.

## What's in the marketplace

| Plugin | Source tool | Skills it installs |
|---|---|---|
| [`tableau-to-sigma`](plugins/tableau-to-sigma/) | Tableau | `tableau-to-sigma`, `tableau-assessment`, `tableau-vds-to-cdw` |
| [`powerbi-to-sigma`](plugins/powerbi-to-sigma/) | Power BI | `powerbi-to-sigma`, `powerbi-assessment`, `powerbi-import-to-snowflake` |
| [`qlik-to-sigma`](plugins/qlik-to-sigma/) | Qlik Sense / Cloud | `qlik-to-sigma`, `qlik-assessment` |
| [`thoughtspot-to-sigma`](plugins/thoughtspot-to-sigma/) | ThoughtSpot | `thoughtspot-to-sigma`, `thoughtspot-assessment` |
| [`quicksight-to-sigma`](plugins/quicksight-to-sigma/) | Amazon QuickSight | `quicksight-to-sigma`, `quicksight-assessment` |
| [`cognos-to-sigma`](plugins/cognos-to-sigma/) | IBM Cognos Analytics | `cognos-to-sigma`, `cognos-assessment` |
| [`looker-to-sigma`](plugins/looker-to-sigma/) | Looker | `looker-to-sigma`, `looker-assessment` |
| [`microstrategy-to-sigma`](plugins/microstrategy-to-sigma/) | MicroStrategy (Strategy One) | `microstrategy-to-sigma`, `microstrategy-assessment` |
| [`sisense-to-sigma`](plugins/sisense-to-sigma/) | Sisense (ElastiCube / Live) | `sisense-to-sigma`, `sisense-assessment` |
| [`gooddata-to-sigma`](plugins/gooddata-to-sigma/) | GoodData Cloud / .CN | `gooddata-to-sigma`, `gooddata-assessment` |
| [`domo-to-sigma`](plugins/domo-to-sigma/) | Domo | `domo-to-sigma`, `domo-assessment` |
| [`hex-to-sigma`](plugins/hex-to-sigma/) | Hex | `hex-to-sigma`, `hex-assessment` |

In Claude Code, installed Skills are namespaced — e.g. `/powerbi-to-sigma:powerbi-assessment`.

Two plugins bundle a **data-landing bridge** for source data that isn't in the
data warehouse yet. `tableau-to-sigma`'s **`tableau-vds-to-cdw`** pulls a published
extract / VDS feed via the VizQL Data Service API and lands it in **Snowflake**
or **Databricks**; `powerbi-to-sigma`'s **`powerbi-import-to-snowflake`** extracts
Import-mode model rows via the Power BI `executeQueries` API and lands them in
**Snowflake**. Each runs *before* the matching converter builds the model logic;
the assessment flags the sources that need it.

## The shared shape

Every converter follows the same phased flow:

```
Discover   →  pull the source model + report/sheets/dashboards
Translate  →  measures/calcs/expressions → Sigma formulas (a converter handles the bulk;
              a gap-scout sub-agent validates the hard cases against the live Sigma API)
Data model →  build the Sigma data model (tables + relationships + metrics), reconciled to the warehouse
Workbook   →  rebuild the pages/visuals as a Sigma workbook (layout applied last)
Parity     →  query Sigma vs the source warehouse — GREEN only on a match
```

Each plugin's `skills/<name>/SKILL.md` is the entry point; `refs/` holds the spec
gotchas and `scripts/` the pipeline. Skills are self-contained — no external
paths to wire up. The canonical phase arc and a per-skill phase-number mapping
live in [`docs/phase-schema.md`](docs/phase-schema.md).

## Corpus

[`corpus/`](corpus/README.md) is a regression corpus: sample source artifacts for
every tool — `.twb`, `.bim`, classic + PBIR report JSON, Qlik app metadata,
ThoughtSpot TML, QuickSight describes, Cognos modules/reports, LookML — with
**golden converter outputs** and a runner. Smoke-test converter or builder
changes without a live tenant:

```
corpus/run-corpus.sh --check      # no creds needed; CI-safe
```

## Contributing

Contributions are welcome. To learn more about how to contribute to this Skills
repo, see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the converter arc, the
shared-infra rules, and how to add a new source tool. To report a security
vulnerability, see [`SECURITY.md`](SECURITY.md).

## License

Copyright 2026 Sigma Computing, Inc.

Sigma Migration Skills are licensed under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance with the License. You
may obtain a copy of the License at <http://www.apache.org/licenses/LICENSE-2.0>.
Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License. The
full text of the License is also included as [`LICENSE`](LICENSE).

Third-party components bundled in this repository are attributed in
[`NOTICE`](NOTICE).
