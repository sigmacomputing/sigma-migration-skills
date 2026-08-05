# executeQueries truncation & band pagination

The Power BI `/executeQueries` endpoint **silently truncates** large results
(~48k rows / response — no error, just fewer rows). Landing a fact table naively
would lose data with no warning.

## Strategy

1. Extract with `EVALUATE SELECTCOLUMNS('<table>', ...)` (explicit scalar columns).
2. If the first pull returns `>= BAND_MAX` (default 45,000) rows, paginate:
   - Pick the **highest-cardinality `int64` column** as the band key
     (`DISTINCTCOUNT` across int columns). A low-cardinality key like `MonthID`
     won't split a fact table cleanly; `ItemID` will.
   - Get `MIN`/`MAX`, walk the range in bands, **halving** any band that still
     returns `>= BAND_MAX`.
   - If a single-value band (`step == 1`) is still too big, **fail loud** rather
     than silently truncate — that table needs a composite/manual band.

## Verification

- Row counts are asserted against the source (`COUNTROWS`) implicitly by the
  final `COUNT(*)` in `load.sql`.
- Band reassembly was validated dup/loss-free: forcing `PBI_BAND_MAX=50` on a
  734-row table drove ~15 bands and reassembled to exactly 734, `uniq -d` empty.
- At scale: SALES 923,371 and ITEM 364,184 landed with exact row parity, banded
  on `ItemID`.

`PBI_BAND_MAX` (env) tunes the ceiling — lower to exercise the band path in tests.
