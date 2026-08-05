<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 4 — POST the data model + readback -->

## Phase 4 — POST the data model

```bash
eval "$(scripts/get-token.sh)" && \
ruby scripts/post-and-readback.rb --type datamodel \
  --spec <WORK>/dm-spec.json \
  --out <WORK>/dm-ids.json
```

The script:
- POSTs the spec,
- parses the YAML response (the spec endpoints return YAML by default),
- immediately GETs the spec back to retrieve server-assigned element IDs,
- writes a clean JSON map: `{dataModelId, pages: [{id, name, elements: [{id, kind, name}]}]}`.

Record the `dataModelId` and element IDs. The `dm-ids.json` is used by the
workbook validator (Phase 5) to accept `[Order Fact/...]` cross-source refs.

On error: read the message → fix the offending column formula → re-validate → re-POST.

---

