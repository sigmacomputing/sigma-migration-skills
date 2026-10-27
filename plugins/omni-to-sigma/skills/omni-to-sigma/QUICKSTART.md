# Omni → Sigma — Quickstart

Offline (no tokens), from this skill directory:

```bash
ruby scripts/convert-dm.rb \
  --model-dir fixtures/orders-overview --topic orders \
  --out /tmp/omni-dm.json

ruby scripts/build-omni-workbook.rb \
  --export fixtures/orders-overview/dashboard-export.json \
  --model-dir fixtures/orders-overview \
  --folder-id fixture-folder --out /tmp/omni-wb.json

ruby scripts/detect-rls.rb --model-dir fixtures/orders-overview --out /tmp/rls.json
ruby scripts/omni-query-oracle.rb \
  --export fixtures/orders-overview/dashboard-export.json --out /tmp/oracle.json
```

Live end-to-end migration (with Omni + Sigma credentials):

```bash
eval "$(scripts/get-token.sh)"
ruby scripts/migrate-omni.rb --document <doc-id> \
  --connection-id <uuid> --folder-id <uuid> --workdir /tmp/omni-run
```

Sigma auth, when posting: `eval "$(scripts/get-token.sh)"`.
Omni auth, when fetching or running queries: `OMNI_BASE_URL`, `OMNI_API_TOKEN`.
