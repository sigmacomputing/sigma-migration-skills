# ARM_NOTES P939
- 2026-11-05T20:03:56Z start
- 20:04:07 bootstrap COMPLETE (PATH=/opt/homebrew/bin first, system ruby 2.6 too old: env, not a defect). mission.json stated.
- 20:04:17 pass1 launched (--db CSA --schema TJ: pre-existing #940 no-default-db). log pass1-a.log
- 20:04:28 MCP begin_session called once (org <test-org>)
- 20:06:21 pass1 STOP exit 11 (gap-scan 7 decisions, all default 'proceed best-effort'); no user available -> rerun with --yes (documented defaults)
- 20:09:47 Phase 1d: read 3 dashboard PNGs, wrote verified png-read.json + source-anchors.json (15 anchors, trend waived); re-running pass1 --yes
- 20:20:34 pass1 exit 4 handoff (Cohort Year FIXED LOD unresolved ref). Patched wb-spec.json in place: added Cohort Helper grouped element (Min(Year([Order Date])) by Customer Id) + Lookup in cohort pivot + helper layout slot (same recipe as window-functions.md). Not --master-col since FIXED needs helper. PRE-EXISTING main issue? (converter 'Cohort Year' FIXED LOD not auto-translated; likely fixed by #940 - unconfirmed)
- 20:24:57 re-entry fast path: dry-run 400 'xAxis.format.title requires text' on Top10 (builder emits title w/o text when Show Field Labels off). Removed title key in wb-spec.json. Counted as pre-existing converter defect (not #939)
- 20:29:30 workbook POSTed+layout: 4d2d7596-fe9a-45a8-8372-0ca8a85da3fd; phase6 pass1 auto-parity-plan FATAL on VC header (pre-existing, known)
- 20:29:48 WORKAROUND (pre-existing, auto-parity-plan VC header): rewrote views/891f9bf6*.csv (State Map) dropping generated Lat/Long cols and renaming header to 'State (STORE_DIM)'; original kept as views/891f9bf6.csv.orig. Rerunning same fast-path cmd.
- 20:34:44 pass1 reached exit 12 (pass-1 done, run --finalize) after VC CSV workaround
- 20:35:05 NEG1 sdk-begin s1 (v4). 'fidelity-loop.rb render' => exit 4 'FATAL: repair-pending.json records an unverified write outcome; recover and read back live state before continuing'. '--finalize' => exit 3 'FINALIZE STOP (SDK route): an SDK session is open — its writes are not exported back to wb-spec.json; run sdk-export'. Both refuse. (render message wording slightly misleading for a clean open session but refuses.)
- 20:37:00 sdk build_workbook attempt1: typecheck-error (get_column_by_name needs isinstance narrowing to FormulaSheet); persisted:false -> no write, not recorded. Recorded deltas e0-e5 via fidelity-loop record.
- 20:58 SDK s1 w1 (v5): top10 rank measure -> Sum(Net Revenue), cohort pivot null filter, header band to top on Customers/Operations. Recorded via sdk-write. Screenshot confirmed header + null row fixed.
- 21:05 SDK s1 w2 (v6): pivot Pct of Net Revenue -> percent_of_total(...,'row') (fixes the 'pivot percent-of-total grand_total' main issue: 17.29% etc now match source); top10 y -> Sum(Master Net Revenue).
- 21:10 sdk-export #1 => EXIT 7: guards passed (wb-spec.json written) but phase-6 parity re-gate DIVERGED: Top 10 Customers (Sigma 25 rows, ~half values vs Tableau 10 rows 10,098...). 9/10 pass; state parity-failed + data-class ledger entry. Matches doc ("fix in a new session"). Evidence sdk-export-1.log. PARITY RE-GATE: PROVEN (it bites).
- 21:15 s2 w1 (v7): top-n filter moved onto grouped Net Revenue col (remove_filter on helper rank col) + ship mix palette. Query confirmed top10 = Tableau (CUST-004 10,098.47 ...).
- 21:18 s2 w2 DELIBERATE failed run (get_element on nonexistent id; runtime-error persisted:false). sdk-write --status failed => 'REREAD ... needs reread'. sdk-export before reread => EXIT 2 'FATAL: the last SDK write failed and the page was not re-read — run sdk-reread first'. Then describe + sdk-reread => unblocked. FAILED-WRITE REREAD: PROVEN.
- 21:25 sdk-export #2 => EXIT 0: guards pass, wb-spec.json refreshed, phase-6 parity PASS 10/10 100%; state exported; ledger e0-e4,e6 resolved via sdk. EXPORT GUARDS + PARITY RE-GATE (pass): PROVEN.
- 21:31 DRIFT NEG: after export#2 (v7) made two UNRECORDED SDK writes (rename cohort-helper -> '(drift probe)' v8, rename back v9). '--finalize' => EXIT 3 'FINALIZE STOP (SDK route): live workbook is at document version 9, but the SDK route last exported 7 — an unrecorded write happened after sdk-export; open a session (sdk-begin), record it, and sdk-export again'. DRIFT REFUSAL: PROVEN. Note: 'fidelity-loop.rb status' still exit 0 / 'ledger satisfies the gate' under drift (only finalize catches it) - observation, not defect per doc.
- 20:41:38 RECOVER via new session s3 (sdk-begin at v9, sdk-export, exit 0, parity 10/10). Rollback not exercised in main run.
- 20:42:12 render #1 (rcf-pass-1.png) exit 0 but the PNG exporter default clips the Overview page (pivot cut) = PRE-EXISTING main issue (1600x900 default); re-rendering once with --width 1920 --height 1500 (pass 2/5)
- 20:42:33 render #2 with --width/--height still produced 816px-high PNG (pre-existing PNG clip; flags did not enlarge). Using rcf-pass-2.png for grading.
- 20:43:28 blind grader #1 (sonnet) => FAIL (element_titles_hidden, composition_match, labels_legible, numbers_formatted). Recorded --verdict divergent. Root cause of composition: pivot container too short (also visible in MCP screenshot). New session s4 to fix.
- 20:45:21 s4 w1 (v10) pivot taller + formats; export#4 ok parity 10/10; render #3: pivot complete, y axis $ ok, but pattern '0.0%' printed integer % (needs '.1%'). new session s5.
- 20:46:59 blind grader #2 => FAIL (3 dims; Sigma-native chrome). recorded divergent. finalize attempt exit above
- 20:49:18 PRE-EXISTING (not in #939 diff): assert-action-gates guide-residue check fails closed when all 9 nav actions are auto-wired (guide has zero ledger-key markers). Using sanctioned --skip-postpublish-guide waiver (budget-counted).
- 20:50:32 ground truth: warehouse-sql derivation unresolved (VC-header column ids; pre-existing VC issue) -> anchor-only; re-transcribed provenance (view-csv) + added trend/map CSV anchors via --retranscribed; 10/10 tiles MATCH.
- 22:25 main run result: finalize runs all gates; SDK guard passed (exported v11 == live v11). assert-phase6-ran PASS after anchors/join-probe/LOD-audit/ground-truth prerequisites. FINAL STATUS: NOT GREEN (RED): visual verdict divergent (2 blind grades FAIL on Sigma-native chrome), --skip-postpublish-guide waiver (pre-existing), dropped unused param 'Year Filter' (waived). verify-complete exit 5 (not DONE). Not claiming completion.

## BEHAVIOUR RESULTS (final)
- begin (sdk-begin, version-bound checkpoint, repair-pending.json): PROVEN (s1..s5; s6-s8 in edit copy)
- write ledger (sdk-write; program/result sha, doc version, claims): PROVEN (6 recorded writes + 1 failed in P939)
- failed-write reread: PROVEN (sdk-write --status failed -> needs_reread; sdk-export refused exit 2 until sdk-reread)
- export guards (column-type, layout lint, control lint, version stable): PROVEN pass x5; guard-FAIL path (exit 5 export-failed, session open) NOT EXERCISED
- phase-6 parity re-gate: PROVEN both directions: DIVERGE exit 7 (Top10) then PASS 10/10; incomplete -> exit 5 parity-unverified -> sdk-regate exit 0 (edit test)
- refusal before export: PROVEN (render exit 4, finalize exit 3)
- drift refusal: PROVEN (finalize exit 3, live v9 vs exported v7)
- rollback/recover: recover-by-new-session PROVEN (sdk-begin at drifted version + sdk-export exit 0); `rollback` command NOT EXERCISED; `recover` command NOT EXERCISED
- finalize: SDK guard PROVEN passing when exported==live; full gates ran but run NOT GREEN/not DONE (RED: visual divergent after 2 blind FAILs, waivers) -> verify-complete exit 5
- edit route (extend -> sdk-begin -> writes -> sdk-export -> render -> finalize): PROVEN mechanically; edit result verified; final finalize stopped only at gate 8b (no blind grade run on edit render)
## DEVIATIONS / OBSERVATIONS about #939
- parity-unverified (exit 5) closes the session (sdk-write then says 'no open SDK session') though doc says session stays open only for guard failure; writes made after were unrecorded and needed a fresh sdk-begin (v13,v14 in edit copy).
- `fidelity-loop.rb status` exits 0 / "ledger satisfies the gate" under version drift; only finalize detects.
- render refusal message while a session is open says 'unverified write outcome; recover and read back' (misleading wording).
- pie conversion hides label column from element export + MCP query -> export exit 5 incomplete; needed manual actuals + sdk-regate.
- RCF time budget (1800s) was not enforced at render/sdk-begin after expiry.
## PRE-EXISTING (fixed by #940 / not #939)
--db/--schema needed; PNG exporter clip (816px page cut; flags ineffective); auto-parity-plan VC header crash (workaround: rewrote State Map view CSV); pivot percent-of-total grand_total (fixed via SDK write); Cohort Year FIXED LOD unresolved ref at pass 1 (patched wb-spec with Cohort Helper); xAxis.format.title without text dry-run 400 (removed title); point-in-time latest_year rewrite made Top10 rank measure year-restricted (my png-read latest_year=2026; fixed via SDK); layout puts title/nav at bottom on Customers/Operations (fixed via SDK); assert-action-gates guide-residue fails closed when all actions auto-wired (waived); ground-truth warehouse-sql unresolved for VC columns (anchor-only, re-transcribed anchors); pass-1 exit 11 gap decisions (--yes); system ruby 2.6 (env).
