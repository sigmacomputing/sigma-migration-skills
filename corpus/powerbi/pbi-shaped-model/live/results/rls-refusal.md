# RLS refusal, live

Command: the Retail Sales run (RUNBOOK section 1) with `--tmsl` pointing at the Retail Sales model that carries a `West Stores`
role (a row filter `[Store Region] = "West"` on `Store`), `--model-shape pbi --materialization-cron "0 6 * * *"`, against the test org.

Result: exit code 10, at the very start of the run (phase timings: `1-discover-extract` only, 0.1 s). Nothing was posted: no
`POST ok` line in the log, and the scratch folder had the same 2212 entries before and after (no new object, compared by id).

Message (open question, required):

```
model_shape_security: OPEN QUESTION: --model-shape pbi does not support row- or column-level security,
and this model has role(s) with a table filter or column permission: West Stores.
Rerun without --model-shape pbi (the default shape ports security today). Nothing was built.
```

The refusal names the role; the default shape is the way to port security.
