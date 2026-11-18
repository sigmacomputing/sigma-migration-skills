#!/usr/bin/env bash
# Live-only: seeds ZZ_CLAUDE_PBI_SHAPED in Snowflake. Never run by checks.sh.
set -euo pipefail
: "${SNOW_CONNECTION:?set SNOW_CONNECTION to a snow CLI connection name}"
: "${SEED_DB:?set SEED_DB to the target Snowflake database}"
: "${SIGMA_READ_ROLE:?set SIGMA_READ_ROLE to the role that receives read access}"
# Optional: a second read role (e.g. the Power BI service user's role). CREATE OR REPLACE
# drops grants on reseed, so it is regranted here. Unset = same as SIGMA_READ_ROLE.
PBI_READ_ROLE="${PBI_READ_ROLE:-$SIGMA_READ_ROLE}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snow sql -c "$SNOW_CONNECTION" -f "$here/seed.sql" \
  -D "db=$SEED_DB" -D "role=$SIGMA_READ_ROLE" -D "pbi_role=$PBI_READ_ROLE"
