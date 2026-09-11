# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-09-11

Converter-fidelity improvements. Synced from the private development repo via the
audited `derive-public` scrub.

### Changed
- **All converters** — canonicalized workbook-alignment fields in the shared CodeRep
  workbook builder (`scripts/lib/code_rep.*`), so generated workbook code
  representations are deterministic and consistent across the plugin fleet.
- **`powerbi-to-sigma`** (1.8.47 → 1.8.48) — improved retail DAX **calendar /
  time-intelligence** conversion, with new `retail_calendar` + `time_intelligence`
  model fixtures, DAX coverage / measure-pattern reference updates, and the
  refreshed `powerbi.mjs` converter bundle.

### Fixed
- **`metabase-to-sigma`** (0.1.1 → 0.1.2) — maintenance bump; confirmed telemetry-free
  at the source (the public mirror was already telemetry-free).

## [1.0.0] — 2026-07-22

Initial public open-source release under the Apache License 2.0.

### Added
- Public release of the `sigma-migration-skills` plugin marketplace with 11
  plugins (converter + assessment skill pairs) covering Tableau, Power BI, Qlik,
  ThoughtSpot, Amazon QuickSight, IBM Cognos, Looker, MicroStrategy, Sisense,
  and GoodData, plus the `sigma-authoring` companion.
- `NOTICE` file attributing bundled third-party components (fast-xml-parser,
  strnum, js-yaml, and the Tableau document schema).
- `SECURITY.md`, `CODE_OF_CONDUCT.md`, and contribution guidance for external
  contributors.

### Changed
- Relicensed from MIT to **Apache License 2.0**, copyright Sigma Computing, Inc.
