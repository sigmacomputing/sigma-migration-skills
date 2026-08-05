# sigma-authoring — vendored from `sigma-skills`

The skills under `skills/` (`sigma-workbooks`, `sigma-data-models`,
`custom-sql-to-data-model`) are **vendored copies** of the canonical
`sigma-skills` repo. They live here so the migration converters'
hard dependency on `sigma-workbooks` (the canonical Sigma spec reference) ships
in the **same marketplace** — installing any converter, install this too.

- **Source of truth:** the internal `sigma-skills` source repo (edit there)
- **Vendored at:** sigma-skills `7e40dfa`

## Refresh

Re-vendor when the canonical skills change:

```sh
SRC=/path/to/sigma-skills    # a fresh clone of sigma-skills
for s in sigma-workbooks sigma-data-models custom-sql-to-data-model; do
  rm -rf "plugins/sigma-authoring/skills/$s"
  cp -R "$SRC/$s" "plugins/sigma-authoring/skills/$s"
done

# CLOBBER-SAFETY (required): the vendored skill dirs ALSO carry manifest-fanned
# shared files (scripts/doctor.{sh,ps1}, scripts/bootstrap.{sh,ps1},
# refs/environment.md, the token scripts, …) that do NOT exist upstream — the
# rm -rf above deletes them. Re-fan them from shared/manifest.json and verify,
# or the shared-lib drift gate (tools/check-shared.rb in CI) fails:
ruby tools/sync-shared.rb        # restore the fanned shared copies the cp -R dropped
ruby tools/check-shared.rb       # MUST be green before committing

# then update the "Vendored at" SHA above and commit
```

Do NOT edit these copies directly — changes belong upstream in `sigma-skills`,
then re-vendor here. (Native trellis shapes were back-ported upstream in
`sigma-skills` #19; re-vendor `sigma-workbooks` from the SoT once that
merges to pick them up — the marketplace copy already carries the identical
recipe, so this is a consistency refresh, not a functional change.)
