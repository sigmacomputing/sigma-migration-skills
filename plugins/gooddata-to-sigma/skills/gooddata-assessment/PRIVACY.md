# Privacy

`gooddata-assessment` is **read-only** and **local**. For GoodData Cloud / .CN it
calls the declarative layout API (`GET /api/v1/layout/...`) with the user's own
API token; for the legacy Platform it calls the classic metadata API
(`GET /gdc/md/{project}/query/...` + `/objects/get`) after an SST/TT login. Both
read only metadata — dataset / metric / insight / report / dashboard definitions —
and compute counts and complexity tags on the local machine.

- No workspace data (warehouse rows / query results) is read or transmitted.
- Nothing is written back to GoodData.
- No definitions or credentials are sent anywhere except to the user's own
  GoodData host. Output (the readout) stays local.
- Credentials (Cloud API token, or Platform host/user/password/SST) are read from
  the environment / `~/.gooddata_env` and are never logged. Platform SST/TT tokens
  live only in memory for the duration of a run.
