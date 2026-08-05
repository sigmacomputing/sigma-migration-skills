# Vendored Tableau workbook schema

| File | Upstream | Pinned commit | Vendored |
|---|---|---|---|
| `twb_2026.2.0.xsd` | [tableau/tableau-document-schemas](https://github.com/tableau/tableau-document-schemas) `schemas/2026_2/twb_2026.2.0.xsd` | `e5560910473c867e31adbe21621772a8177d0524` (2026-06-21) | 2026-07-11 |

License: Apache-2.0 (see `UPSTREAM-LICENSE.txt`, © Salesforce, Inc.). Vendored
verbatim — never edit the .xsd; refresh by re-downloading a newer pinned commit
and updating this table.

## Why it's vendored

This is the **official grammar** for .twb XML — zones, zone-styles
(`StyleAttribute-ST`, ~174 values incl. the native rounded-corner surface),
containers, device layouts, style rules. It turns the skill's
reverse-engineered parsing into schema-checkable code:

- `scripts/test-schema-coverage.rb` extracts the `StyleAttribute-ST` enum from
  this file and fails when a **new** attribute appears that the parser hasn't
  classified — Tableau adding design surface becomes a test failure, not a
  silent parity gap.
- The schema models only CANONICAL element names. Real .twb files wrap newer
  features in forward-compatibility names (`_.fcp.<Feature>.<true|false>...`),
  so all parsing runs behind `scripts/lib/fcp_normalize.rb` first.

## Refreshing

```bash
curl -sL -o schemas/twb_<ver>.xsd \
  https://raw.githubusercontent.com/tableau/tableau-document-schemas/<commit>/schemas/<ver_dir>/twb_<ver>.xsd
ruby scripts/test-schema-coverage.rb   # classify anything new it reports
```
