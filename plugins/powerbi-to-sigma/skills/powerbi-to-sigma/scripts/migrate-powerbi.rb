#!/usr/bin/env ruby
# migrate-powerbi.rb — ONE-SHOT, single-process orchestrator for the
# powerbi-to-sigma pipeline. Runs the whole phased workflow in one Ruby process
# to cut agent turns / token cost, WITHOUT turning the migration into a black
# box: every phase prints a visible header + concise result, and the genuine
# human decision points are surfaced as a structured OPEN QUESTIONS block
# (exit 10) rather than silently auto-resolved.
#
# Modeled on quicksight-to-sigma/scripts/migrate-quicksight.rb. It does NOT
# re-implement any phase — it chains the EXISTING scripts + the local
# convert_powerbi_to_sigma converter build:
#   explode the PBIR bundle + extract-pbir.py        (Phase 1 Discover/Extract)
#   convertPowerBIToSigma() via a node shim           (Phase 2 Convert)
#   convert-model.rb --converter-out (fixups)         (Phase 3 Build DM)
#     + validate-spec.rb + post-and-readback.rb
#   auto master-map + build-workbook-from-pbir.rb     (Phase 4 Build workbook)
#     + post-and-readback.rb
#   put-layout.rb                                     (Phase 5 Layout)
#   /columns error-type guard + per-element probe     (Phase 6 Parity)
#
# The convert_powerbi_to_sigma MCP tool is an ESM module; we import its exported
# convertPowerBIToSigma() directly via a tiny node shim (same trick as the QS
# orchestrator). Override the build dir with PBI_MCP_DIR.
#
# The one PBI-specific artifact a human normally authors — master-map.json (maps
# each PBI Entity.Field queryRef -> {master, ref, agg}) — is DERIVED here
# deterministically from the converter output (element name + column display
# names + translated metric formulas) cross-referenced with the PBIR queryRefs.
# DAX measures the converter could not translate (the (c)-tail) surface as OPEN
# QUESTIONS, not silent Null columns.
#
# Usage:
#   # Sigma auth resolves through a valid caller token, stored browser session,
#   # or client credentials in ~/.sigma-migration/env.
#   ruby scripts/migrate-powerbi.rb \
#     --tmsl /tmp/assessment-pbi-live/raw-tmsl/Test__Superstore_Overview.tmsl \
#     --pbir /tmp/assessment-pbi-live/raw-pbir/Test__Superstore_Overview.json \
#     --connection <SIGMA_CONN_UUID> --database <DB> --schema <SCHEMA> \
#     --ref-dm <referenceDataModelId> \
#     [--name "Superstore Overview (from Power BI)"] [--folder <id>] \
#     [--out DIR] [--answers '<json>'] [--yes] \
#     [--mcp-dir <converter-source clone> | --converter-out <mcp-tool result.json>] \
#     [--python <interpreter>]
#
# FULLY-LOCAL alternative (no Fabric/tenant) — a single .pbix on disk. Phase 0
# extracts the model (pbixray -> model.bim) and the report (the zip's UTF-16LE
# Report/Layout -> signals) LOCALLY, then the same convert->build->verify
# pipeline runs. Needs pbixray for the model half (see refs/local-pbix.md):
#   ruby scripts/migrate-powerbi.rb --pbix /path/Sales.pbix \
#     --connection <SIGMA_CONN_UUID> --database <DB> --schema <SCHEMA> --ref-dm <id>
#
# Converter route (bead 7o01): with a local converter-source build (--mcp-dir /
# PBI_MCP_DIR / ~/Desktop or ~/ clone) the conversion runs in-process via a node
# shim. WITHOUT one, Phase 2 stops with a gate: run the convert_powerbi_to_sigma
# MCP tool yourself and resume with --converter-out <its result JSON> — the
# default route on machines without a local build.
#
# RERUN CACHE (Phase 0/1): extracting a large .pbix costs 60-120 s and a big migration is a
# loop of reruns. After a completed extraction the input fingerprint (content digest of
# --pbix, or --tmsl + --pbir, plus the extractor scripts) is recorded in
# <WORK>/run-provenance.json; a rerun whose fingerprint matches skips extraction
# automatically and says so on the PHASE TIMINGS line. --reuse-extract skips it whenever the
# extracted files (model.bim, signals.json, report-layout.json) are in <WORK>;
# --no-reuse-extract always extracts. See lib/pbi_extract_cache.rb.
#
# --probe-sources (OPT-IN, recommended for import / NativeQuery models): before the data model
# is posted, run scripts/probe-native-sources.py against --connection (scratch objects in
# --folder) so every Custom SQL element is checked ONCE instead of one POST 400 at a time:
# unknown [Custom SQL/X] refs are nulled pre-POST (<WORK>/sql-output-names.json feeds the
# dm-resolver), TMSL-vs-warehouse type mismatches get a cast in the element SQL
# (VARCHAR 'True'/'False' -> TRY_TO_BOOLEAN, ...), and the run STOPS (exit 10) when a bound
# column is missing from the SQL output (--probe-allow-missing proceeds and nulls it).
# Audit: <WORK>/native-source-probe.json. --probe-results <file> replays captured probe
# results offline instead of querying the warehouse.
#
# Phase E (OPT-IN) — Enhance: pass --enhance to run the shared enhancement
# engine AFTER parity passes: enhance-scan.rb emits candidates + app_options;
# design interview via enhance-select.rb / enhance-app-plan.rb; nothing
# applies without --enhance-accept <ids|all-low-risk> (without it the run
# stops at exit 14 with the proposals); enhance-apply.rb then clones the
# parity workbook ("<name> — Enhanced") and applies accepted items one at a
# time under a parity-unchanged gate. Default = OFF everywhere.
# See refs/phase-e-enhance.md.
#
# Exit codes: 0 = done (parity pass); 10 = decisions needed (OPEN QUESTIONS); 3 = parity fail;
# 14 = parity PASS + Phase E proposals pending acceptance (re-run with --enhance-accept); other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require 'digest'
require 'set'
require 'time'
require_relative 'lib/py_resolve'
require_relative 'lib/pbi_field_alts'
require_relative 'lib/pbi_master_key'
require_relative 'lib/pbi_view_route' # cross-table visuals -> joined View alts; friendly-entity aliases
require_relative 'lib/pbi_model_scope'  # scope the DM to the tables the report uses (default; --full-model opts out)
require_relative 'lib/offramp'
require_relative 'lib/pbi_extract_cache' # Phase 0/1 rerun cache (input fingerprint in run-provenance.json)
require_relative 'lib/pbi_probe_gate'    # --probe-sources: probe report -> sql-output-names / casts / stop
require_relative 'lib/pbi_extract_notes' # extraction notes that mean data was lost (Enter-data NULLs, assumed culture)
require_relative 'lib/code_rep'
require_relative 'lib/pbi_offramp_reason' # name the FAILING STAGE, never assert a cause we did not establish # role-playing dim copies must key on PBI table identity # derived field_map entries must wrap their ALTS too (pie/date-grain render bug) # real-Python resolver (Windows Store-stub safe)
begin; require_relative 'lib/modeling_advisory'; rescue LoadError; end # shared, vendor-neutral CDW join-cost advisory (optional; synced from shared/)

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'scout_gate'    # run-each-time gap-scout gate ()
require 'dax_gate'      # DAX warning → decision-question classifier (regression-tested)
require 'coverage_gate' # workbook-build coverage.json → consolidated report + assistance prompt
require 'pbi_element_match' # converter→readback element pairing (POST reorders; regression-tested)
require 'pbi_timeintel_route' # time-intel fallback-router fact-provenance guard (regression-tested)
require 'pbi_calc_table_sql' # DISTINCT/VALUES/SUMMARIZE calculated tables -> Custom SQL
require 'pbi_native_query' # preserve Value.NativeQuery/Query= SQL around the pinned converter
require 'pbi_composite' # remote-model detection; NativeQuery is warehouse SQL
require 'pbi_dm_resolver' # deterministic converter-output fixer (D1-D8) -> <WORK>/dm-resolver.json
require 'pbi_name_sanitize' # F13: "/" in column/measure names -> U+2215 before conversion
require 'materialization_schedules' # opt-in DM element schedule lifecycle
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

# Converter resolution (issue #227). The pinned VENDORED bundle is the DEFAULT so a
# developer machine and a customer machine produce identical output for the same
# input. A local converter-source build is used ONLY when EXPLICITLY opted in
# via --mcp-dir / PBI_MCP_DIR — there is NO silent auto-discovery of ~/… checkouts
# (that was the "works in my demo, differs for the customer" footgun). Returns
# [conv_module, mcp_build_dir_or_nil, loud_provenance_line].
def resolve_converter(mcp_dir, vendored, build_basename)
  build_dir = (mcp_dir && File.exist?(File.join(mcp_dir, 'build', build_basename))) ? mcp_dir : nil
  conv = build_dir ? File.join(build_dir, 'build', build_basename) :
         (File.exist?(vendored) ? vendored : nil)
  desc =
    if conv && conv == vendored
      prov = File.join(File.dirname(vendored), 'PROVENANCE.json')
      commit = (JSON.parse(File.read(prov))['source_commit'] rescue nil)
      "VENDORED #{File.basename(vendored)}#{commit ? " (pinned #{commit})" : ''} — no data egress"
    elsif conv
      "DEV BUILD #{conv} (explicit opt-in via --mcp-dir/PBI_MCP_DIR)"
    else
      'NONE — vendored bundle missing; convert_powerbi_to_sigma MCP / --converter-out fallback applies'
    end
  [conv, build_dir, desc]
end

opts = { db: '', schema: '' }
OptionParser.new do |o|
  o.on('--tmsl PATH')       { |v| opts[:tmsl]   = File.expand_path(v) }
  o.on('--pbir PATH')       { |v| opts[:pbir]   = File.expand_path(v) }
  # FULLY-LOCAL front door: a single .pbix on disk, no Fabric/tenant. Phase 0
  # extracts the model (pbixray -> model.bim) AND the report (the zip's
  # UTF-16LE Report/Layout -> signals) locally, then the normal pipeline runs.
  # Mutually exclusive with --tmsl/--pbir (which it derives).
  o.on('--pbix PATH')       { |v| opts[:pbix]   = File.expand_path(v) }
  # FIELD-LOSS GATE escape hatch (task 5). By default a run that loses field
  # BINDINGS hard-stops at Phase 5c (exit 10): measured on 4 real reports, runs that
  # had dropped 33-54% of their bindings still reported "12/12 source visual(s)
  # carried over; 0 dropped", because coverage was counted per VISUAL and a table
  # shipping 3 of 8 columns is only 'degraded'. Surfacing that was not enough — an
  # unattended run shipped it anyway. Pass this when the loss is a KNOWN, accepted
  # Sigma limit (USERELATIONSHIP / ISINSCOPE and friends); the reason is still
  # printed, never suppressed.
  o.on('--allow-field-loss', 'proceed despite field-binding loss (still reports it)') { opts[:allow_field_loss] = true }
  # Calculated-table incompleteness is earlier and more dangerous than workbook
  # field loss: a generated date spine can return rows while holiday columns are
  # all NULL. This override requires an auditable reason and is never implied by
  # --yes.
  o.on('--allow-incomplete-calculated-tables REASON',
       'proceed past placeholder/NULL/dropped calculated-table output; records REASON') do |v|
    opts[:allow_incomplete_calculated_tables] = v
  end
  o.on('--connection ID')   { |v| opts[:conn]   = v }
  o.on('--database DB')     { |v| opts[:db]     = v }
  o.on('--schema S')        { |v| opts[:schema] = v }
  # Target warehouse dialect for physical-identifier casing ([bead].7).
  # Databricks/Spark store identifiers lower-case and bind only against a lower-cased
  # warehouse path; Snowflake/BigQuery (the default) fold to UPPER. Default is read
  # from the resolved connection's `type` in connection.json; this flag overrides it.
  o.on('--warehouse-type T') { |v| opts[:wh_type] = v }
  o.on('--ref-dm ID')       { |v| opts[:ref_dm] = v }
  o.on('--folder ID')       { |v| opts[:folder] = v }
  o.on('--name NAME')       { |v| opts[:name]   = v }
  # SOURCE report display name (Fabric/Power BI "EMPLOYEE DASHBOARD") — used as
  # the header-band title fallback when a page has no promotable title textbox
  # and its own name is a generic "Page N". Defaults to the humanized slug.
  o.on('--source-title NAME') { |v| opts[:source_title] = v }
  o.on('--out DIR')         { |v| opts[:out]    = File.expand_path(v) }
  o.on('--answers JSON')    { |v| opts[:answers]= v }
  o.on('--yes')             {     opts[:yes]    = true }
  # bead 7o01 portability: no hardcoded developer paths. --mcp-dir / PBI_MCP_DIR
  # selects a local converter-source build; --converter-out feeds a converter
  # result produced by the convert_powerbi_to_sigma MCP TOOL (the default route
  # when no local build exists); --python / PBI_PY picks the Python interpreter.
  o.on('--mcp-dir DIR')        { |v| opts[:mcp_dir] = File.expand_path(v) }
  o.on('--converter-out PATH') { |v| opts[:cvt_out] = File.expand_path(v) }
  o.on('--python PATH')        { |v| opts[:python]  = File.expand_path(v) }
  # Resolve + print which converter would run (vendored vs explicit dev build), then
  # exit 0 — no creds/args needed. Used by the converter-default regression test.
  o.on('--print-converter')    {     opts[:print_converter] = true }
  # bead fmte — SOURCE-FRESHNESS PREFLIGHT. --workspace/--dataset identify the
  # LIVE semantic model (workspace id or "me" for My workspace) so Phase 1.5 can
  # pull its refresh history + a cheap executeQueries snapshot. Optional: without
  # them the preflight is skipped (offline TMSL+PBIR-only runs still work).
  o.on('--workspace ID')       { |v| opts[:ws] = v }
  o.on('--dataset ID')         { |v| opts[:dataset] = v }
  o.on('--skip-freshness')     {     opts[:skip_fresh] = true }
  # #347: target a report/model in a DIFFERENT tenant than your HOME tenant
  # (guest / B2B). A raw tenant GUID, or a pasted report URL (ctid=... parsed).
  # Threaded to every Power BI child via ENV['PBI_TENANT'] (they inherit env).
  o.on('--tenant ID')          { |v| opts[:tenant] = v }
  # Phase E (opt-in) — Enhance. NEVER runs without --enhance; with --enhance
  # but no --enhance-accept the run stops at exit 14 with the scan proposals
  # (present them per-item to the human, e.g. AskUserQuestion), then re-run
  # with --enhance-accept <id,id,...> or 'all-low-risk'.
  o.on('--enhance')            {     opts[:enhance] = true }
  o.on('--enhance-accept L')   { |v| opts[:enhance_accept] = v }
  # DM-REUSE (reuse-first). The scan runs by DEFAULT (Phase 2.9) and auto-reuses
  # an existing Sigma data model that already covers this model's warehouse
  # table(s) + columns, instead of building a 4th near-identical DM. --reuse-dm
  # forces a specific existing dataModelId (skips the scan); --no-reuse always
  # builds a new DM.
  o.on('--reuse-dm ID')        { |v| opts[:reuse_dm] = v }
  o.on('--no-reuse')           {     opts[:no_reuse] = true }
  # MODEL SCOPING (default ON): the Sigma DM only carries the tables the report
  # uses (plus measure/join-path/RLS closure), joined Views only where a visual
  # needs one, and Data-page masters only where something reads them.
  # --full-model restores the whole-semantic-model build (byte-identical).
  o.on('--full-model')         {     opts[:full_model] = true }
  # Phase 6b (runtime control-flip proof) is DEFAULT-ON: after posting, each
  # control is flipped live (probe-controls.rb) to prove it actually filters its
  # targets — a control that lints clean but is INERT fails the migration.
  # --skip-control-flip waives it (name the reason in your migration report).
  o.on('--skip-control-flip [REASON]', 'waive Phase 6b (runtime control-flip proof); the reason MUST be named in your migration report') { |v| opts[:skip_control_flip] = v || true }
  # COMPOSITE guard escape hatch. The Fabric --tmsl path GATES (exit 10) when the
  # extracted model looks like a composite / live-connected-to-remote model,
  # because getDefinition returns an INCOMPLETE model for those — the complete
  # model lives in the local .pbix (prefer --pbix). Pass this to proceed anyway
  # on the (known-incomplete) Fabric model.
  o.on('--allow-incomplete-model') { opts[:allow_incomplete_model] = true }
  # Native SQL followed by Table.RenameColumns/Table.SelectRows/etc. cannot be
  # represented by preserving the SQL alone. Gate by default; this override is
  # only for a user who has manually folded those transforms into the SQL.
  o.on('--allow-native-m-transforms') { opts[:allow_native_m_transforms] = true }
  # Debugging escape hatches for the two deterministic fixers. Both are ON by
  # default and write an audit file (name-sanitize.json / dm-resolver.json).
  # Rerun cache for the Phase 0/1 extraction (see the header comment).
  o.on('--reuse-extract', 'skip Phase 0/1 extraction when the extracted files are already in the work dir') { opts[:reuse_extract] = true }
  o.on('--no-reuse-extract', 'always re-extract (ignore the automatic fingerprint-match reuse)') { opts[:no_reuse_extract] = true }
  # Pre-POST Custom SQL probe (opt-in; see the header comment).
  o.on('--probe-sources', 'probe Custom SQL elements against the warehouse before the DM POST (needs --connection + --folder)') { opts[:probe_sources] = true }
  o.on('--probe-results FILE', 'with --probe-sources: replay captured sigma-sql-probe --types results instead of probing live') { |v| opts[:probe_results] = File.expand_path(v) }
  o.on('--probe-concurrency N', Integer, 'with --probe-sources: parallel export polls against the one scratch workbook (default 6)') { |v| opts[:probe_concurrency] = v }
  o.on('--probe-no-cache', 'with --probe-sources: ignore and do not write the per-statement probe cache (use after a warehouse-side fix)') { opts[:probe_no_cache] = true }
  o.on('--probe-cache-max-age-hours N', Float, 'with --probe-sources: re-probe cached statements older than N hours (default 24; 0 = never reuse)') { |v| opts[:probe_cache_max_age_hours] = v }
  o.on('--keep-probe-workbook', 'with --probe-sources: keep the scratch probe workbook (default: deleted after the run; debugging)') { opts[:keep_probe_workbook] = true }
  o.on('--probe-allow-missing', 'with --probe-sources: do not stop on a bound column missing from the SQL output (the resolver nulls it)') { opts[:probe_allow_missing] = true }
  o.on('--stop-before-post', 'run everything up to the validated DM spec (incl. --probe-sources), create nothing in Sigma, exit 0') { opts[:stop_before_post] = true }
  o.on('--skip-dm-resolver') { opts[:skip_dm_resolver] = true }
  # Page facts (refs/large-pbix.md "Measures: classify the page, then build it"). --scaffold-page-facts
  # drafts them (scaffold-page-fact.py -> <WORK>/page-facts-draft); --page-facts DIR folds COMPLETED
  # ones into the DM spec + master-map (integrate-page-fact.py) and gates their slicers after the
  # workbook build (wire-slicer-gate.py).
  o.on('--scaffold-page-facts [PAGES]', 'draft page facts into <WORK>/page-facts-draft (PAGES: comma-separated titles; default: pages classified page-fact); with --stop-before-post it is a draft-only run that writes nothing to Sigma') { |v| opts[:scaffold_page_facts] = v || true }
  o.on('--page-facts DIR', 'integrate the completed page facts under DIR (<page>/page-fact.json) and wire their slicers') { |v| opts[:page_facts] = File.expand_path(v) }
  o.on('--page-facts-update-dm', 'with --page-facts on a REUSED data model: PUT it with the page-fact elements added') { opts[:page_facts_update_dm] = true }
  o.on('--allow-page-fact-todo', 'with --page-facts: integrate page facts that still have TODO measures (those bind to their NULL stubs)') { opts[:allow_page_fact_todo] = true }
  o.on('--skip-name-sanitize') { opts[:skip_name_sanitize] = true }
  # Opt-in materialization schedule for converted Custom SQL elements. Cron is
  # required; timezone is IANA. Without --materialization-elements every SQL
  # source element is targeted. A comma-list selects exact element names.
  o.on('--materialization-cron CRON') { |v| opts[:materialization_cron] = v }
  o.on('--materialization-timezone TZ') { |v| opts[:materialization_timezone] = v }
  o.on('--materialization-elements LIST') { |v| opts[:materialization_elements] = v }
end.parse!

if opts[:materialization_timezone] && !opts[:materialization_cron]
  abort 'FATAL: --materialization-timezone requires --materialization-cron'
end
if (opts[:probe_results] || opts[:probe_allow_missing] || opts[:probe_concurrency] || opts[:probe_no_cache] || opts[:probe_cache_max_age_hours] || opts[:keep_probe_workbook]) && !opts[:probe_sources]
  abort 'FATAL: --probe-results / --probe-allow-missing / --probe-concurrency / --probe-no-cache / --probe-cache-max-age-hours / --keep-probe-workbook require --probe-sources'
end
if opts[:probe_sources] && !opts[:probe_results] && !opts[:folder]
  abort 'FATAL: --probe-sources needs --folder <Sigma folder id> (the probe writes scratch objects there) ' \
        'or --probe-results <file> to replay captured results'
end
if opts[:reuse_extract] && opts[:no_reuse_extract]
  abort 'FATAL: --reuse-extract and --no-reuse-extract are mutually exclusive'
end

# #347: publish the target tenant into the env so EVERY Power BI child process
# (fabric-extract.py, pbi-freshness.py, phase6 harness, …) inherits it and
# authenticates against the report's tenant instead of the caller's home tenant.
if opts[:tenant]
  ctid = opts[:tenant][/[?&]ctid=([0-9a-fA-F-]{36})/, 1]
  ENV['PBI_TENANT'] = ctid || opts[:tenant]
end

VENDORED_PBI = File.expand_path('../converter/powerbi.mjs', __dir__)
if opts[:print_converter]
  conv, _bd, desc = resolve_converter(opts[:mcp_dir] || ENV['PBI_MCP_DIR'], VENDORED_PBI, 'powerbi.js')
  puts(conv || 'none')
  puts desc
  exit 0
end

# The orchestrator REQUIRES the extracted model (TMSL) + report layout (PBIR).
# When they're missing, the failure mode we must prevent is an agent improvising
# a hand-built empty workbook. So the remediation is explicit: CONNECT to Power
# BI via device-code and extract them — never hand-author a spec.
CONNECT_HINT = <<~HINT.freeze
  Extract them by CONNECTING to Power BI (device-code login, no Entra app):
      python scripts/fabric-extract.py --report "<report name>" [--workspace "<ws id|name>"] \\
        [--tenant "<tenant GUID | report URL with ctid=...>"] \\
        --out-dir <WORK> --report-out-dir <WORK> --report-bundle <WORK>/report-bundle.json
  It prints a device code + https://microsoft.com/devicelogin — the USER signs in
  once, then re-run this command with the extracted --tmsl (model.bim) + --pbir
  (report-bundle.json). See refs/connection.md. Do NOT hand-author a workbook spec
  or proceed without the model — if you can't extract it, STOP and tell the user.
  Cross-tenant (guest/B2B): if the report lives in a client's tenant, pass
  --tenant <that tenant GUID or the ctid= in the report URL> here AND to
  fabric-extract.py, or every Fabric call 404s as WorkspaceNotFound.
HINT
# --pbix (fully-local) DERIVES --tmsl + --pbir in Phase 0 below, so the
# require-both checks apply only to the Fabric route. In --pbix mode we just
# confirm the file exists; Phase 0 produces model.bim + signals locally.
if opts[:pbix]
  abort "FATAL: --pbix not found: #{opts[:pbix]}" unless File.exist?(opts[:pbix])
  warn 'note: --pbix given — the local model (pbixray) + report (Report/Layout) are ' \
       'extracted in Phase 0; --tmsl/--pbir are ignored.' if opts[:tmsl] || opts[:pbir]
else
  abort "FATAL: missing --tmsl (the Power BI semantic model, TMSL/model.bim).\n#{CONNECT_HINT}" unless opts[:tmsl]
  abort "FATAL: --tmsl not found: #{opts[:tmsl]}\n#{CONNECT_HINT}" unless File.exist?(opts[:tmsl])
  abort "FATAL: missing --pbir (the Power BI report layout / PBIR bundle).\n#{CONNECT_HINT}" unless opts[:pbir]
  abort "FATAL: --pbir not found: #{opts[:pbir]}\n#{CONNECT_HINT}" unless File.exist?(opts[:pbir])
end
# intake.rb (front-door) caches the resolved connection in <out>/connection.json; honor it
# when --connection is omitted so the agent need not re-pass the id it just resolved.
if opts[:out] && File.exist?(File.join(opts[:out], 'connection.json'))
  _cj = (JSON.parse(File.read(File.join(opts[:out], 'connection.json'))) rescue {})
  opts[:conn]    ||= _cj['connection_id']
  opts[:wh_type] ||= _cj['type']   # warehouse dialect → physical-identifier casing ([bead].7)
end
# bead hjke(a): abort early on a truncated/partial connection id — it survives
# all the way to the DM POST and fails there opaquely ("Source not found").
if opts[:conn] && opts[:conn] !~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  abort "FATAL: --connection must be a FULL Sigma connection UUID (8-4-4-4-12 hex); " \
        "got #{opts[:conn].inspect}. List connections with GET /v2/connections."
end

# Converter resolution (issue #227): the pinned VENDORED bundle is the DEFAULT so a
# dev machine and a customer machine convert identically. A local build is used ONLY
# via explicit --mcp-dir / PBI_MCP_DIR — no silent auto-discovery of ~/… checkouts.
# CONV_MODULE is what the Phase-2 shim imports; nil only if the bundle is also absent
# (then --converter-out / the convert_powerbi_to_sigma MCP gate applies).
CONV_MODULE, MCP_DIR, CONVERTER_DESC =
  resolve_converter(opts[:mcp_dir] || ENV['PBI_MCP_DIR'], VENDORED_PBI, 'powerbi.js')
warn "converter: #{CONVERTER_DESC}"

# In --pbix mode opts[:tmsl] is not set yet (Phase 0 produces it), so slug from
# the .pbix basename instead.
name_slug = File.basename(opts[:tmsl] || opts[:pbix], '.*').gsub(/[^A-Za-z0-9_-]/, '-')
WORK = opts[:out] || File.expand_path("~/powerbi-migration/#{name_slug}")
FileUtils.mkdir_p(WORK)
WB_NAME = opts[:name] || "#{name_slug.gsub(/[_]+/, ' ').strip} (from Power BI)"

# Persist exact executable provenance for every incident report. A plugin file
# copy may have no git metadata; the plugin version + converter pin + real path
# still identify what actually ran.
plugin_manifest = File.expand_path('../../../.claude-plugin/plugin.json', HERE)
plugin_json = JSON.parse(File.read(plugin_manifest)) rescue {}
converter_prov_path = File.join(File.dirname(VENDORED_PBI), 'PROVENANCE.json')
converter_prov = JSON.parse(File.read(converter_prov_path)) rescue {}
repo_sha, repo_status = Open3.capture2('git', '-C', HERE, 'rev-parse', '--short', 'HEAD')
run_provenance = {
  'pluginVersion' => plugin_json['version'],
  'repoSha' => repo_status.success? ? repo_sha.strip : nil,
  'skillPath' => File.realpath(File.expand_path('..', HERE)),
  'converter' => CONVERTER_DESC,
  'converterProvenance' => converter_prov,
  'recordedAt' => Time.now.utc.iso8601
}
# Python interpreter resolution (shared by Phase 0 local extract + Phase 1).
# bead 7o01: --python / PBI_PY, else a bootstrapped venv (<work>/.venv), else
# the legacy /tmp/pbiauth venv, else a real system Python via PyResolve
# (Windows Store-stub safe; the offline PBIR parse is stdlib-only). PY_ARGV is
# an array so a multi-token launcher (`py -3`) survives the splat below.
# bead 4alk.4: venvs are POSIX bin/python OR Windows Scripts\python.exe.
py = opts[:python] || ENV['PBI_PY'] ||
     [File.join(WORK, '.venv', 'bin', 'python'), File.join(WORK, '.venv', 'Scripts', 'python.exe'),
      '/tmp/pbiauth/bin/python', '/tmp/pbiauth/Scripts/python.exe']
       .find { |p| File.exist?(p) }
PY_ARGV = py ? [py] : PyResolve.argv

# RERUN CACHE (Phase 0/1). The decision is made BEFORE run-provenance.json is rewritten: the
# recorded input fingerprint lives in that file. A run that extracts again starts without
# one (it is recorded only once the extraction has finished).
# The Enter-data SQL baked into model.bim is warehouse-dialect specific, and the pbixray version decides
# the VertiPaq decode: both are part of the pbix-route identity.
extract_dialect = PbiProbeGate.extract_dialect_for(opts[:wh_type])
extract_fp = PbiExtractCache.fingerprint(pbix: opts[:pbix], tmsl: opts[:tmsl], pbir: opts[:pbir],
                                         name: opts[:name], scripts_dir: HERE, dialect: extract_dialect,
                                         pbixray: (opts[:pbix] ? PbiExtractCache.pbixray_version(PY_ARGV) : nil))
extract_cache = PbiExtractCache.decide(WORK, extract_fp, forced: opts[:reuse_extract],
                                       disabled: opts[:no_reuse_extract])
_prior_fp = PbiExtractCache.recorded(WORK)
run_provenance[PbiExtractCache::KEY] = _prior_fp if extract_cache['reuse'] && _prior_fp
File.write(File.join(WORK, 'run-provenance.json'), JSON.pretty_generate(run_provenance))
# Name-sanitize rewrites signals.json in place; the pristine extraction is kept beside it so a
# cached rerun starts from the extraction, not from an already-sanitized file.
extracted_signals_copy = File.join(WORK, 'signals-extracted.json')
if extract_cache['reuse']
  FileUtils.cp(extracted_signals_copy, File.join(WORK, 'signals.json')) if File.exist?(extracted_signals_copy)
else
  FileUtils.rm_f(extracted_signals_copy)
end

# ---- phase timings (always written to <WORK>/timings.json) ------------------
# Fast-discovery evidence trail: every terminal exit (success, decisions gate,
# parity fail, workbook fallback) prints a PHASE TIMINGS line and persists the
# per-phase wall clock, so old-vs-new discovery comparisons are always possible.
$phase_times = []
$phase_open = nil
$extract_cache_note = nil # set when Phase 0/1 extraction was served from the rerun cache
def phase_mark(name)
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  $phase_times << [$phase_open[0], (now - $phase_open[1]).round(1)] if $phase_open
  $phase_open = name ? [name, now] : nil
end
at_exit do
  phase_mark(nil)
  unless $phase_times.empty?
    total = $phase_times.sum { |_, s| s }.round(1)
    begin
      File.write(File.join(WORK, 'timings.json'), JSON.pretty_generate(
        { 'phases' => $phase_times.map { |n, s| { 'phase' => n, 'seconds' => s } },
          'totalSeconds' => total }.merge($extract_cache_note ? { 'extractCache' => $extract_cache_note } : {})))
    rescue StandardError
      nil # timings are evidence, never a failure
    end
    puts
    puts 'PHASE TIMINGS  ' + $phase_times.map { |n, s| "#{n}=#{s}s" }.join('  ') + "  total=#{total}s" +
         ($extract_cache_note ? "  [#{$extract_cache_note}]" : '')
  end
end

def hdr(n, total, title)
  phase_mark("#{n}-#{title.downcase.gsub(/[^a-z0-9]+/, '-')}")
  puts
  puts "── Phase #{n}/#{total} · #{title} ──"
end

def run!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success?
  out
end

# --scaffold-page-facts: draft page facts from each page's DAX closure (offline, seconds) into
# <WORK>/page-facts-draft. Never blocks the run. mmap_path is optional: before the DM is posted (the
# --stop-before-post exits) the draft resolves sources by element name instead.
def scaffold_page_facts!(opts, model_path, signals_path, dm_spec, mmap_path, dialect)
  draft = File.join(WORK, 'page-facts-draft')
  cmd = [*PY_ARGV, File.join(HERE, 'scaffold-page-fact.py'), '--model', model_path, '--signals', signals_path,
         '--dm-spec', dm_spec, '--out-dir', draft,
         '--dialect', (%w[snowflake databricks bigquery].include?(dialect) ? dialect : 'snowflake')]
  cmd += ['--master-map', mmap_path] if mmap_path && File.exist?(mmap_path)
  opts[:scaffold_page_facts].split(',').map(&:strip).reject(&:empty?).each { |t| cmd += ['--page', t] } if opts[:scaffold_page_facts].is_a?(String)
  # Not a shell: an argv array that runs this plugin's scaffold-page-fact.py with the current Python; options come from this run's own flags and paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, st = Open3.capture2e(*cmd)
  puts '   PAGE FACTS (draft):'
  out.each_line { |l| puts "     #{l.rstrip}" } unless out.strip.empty?
  if st.success?
    puts "   -> #{draft}: read each <page>/closure.md, fill the TODOs, run check-plan.json, then rerun with --page-facts <dir>"
  else
    warn "   [warn] scaffold-page-fact.py failed (#{st.exitstatus}); the run continues without drafts"
  end
end

# Raised (and rescued in the DM-reuse block) to stop before PUTting page facts into a reused DM.
class StopBeforePostPageFacts < StandardError; end

# Page facts (--page-facts DIR): fold the completed page-fact.json files into a DM spec with
# integrate-page-fact.py. check: true reports without writing and returns :changed / :current.
def integrate_page_facts_dm!(opts, dm_spec, check: false)
  cmd = [*PY_ARGV, File.join(HERE, 'integrate-page-fact.py'), opts[:page_facts], '--dm-spec', dm_spec]
  cmd += check ? ['--check'] : ['--connection', opts[:conn].to_s]
  cmd << '--allow-todo' if opts[:allow_page_fact_todo]
  # Not a shell: an argv array that runs this plugin's integrate-page-fact.py with the current Python; options come from this run's own flags and paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  out, st = Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  return :changed if check && st.exitstatus == 3
  abort "FATAL: page-fact integration failed (#{st.exitstatus}); nothing was posted. Fix #{opts[:page_facts]} and rerun." unless st.success?
  :current
end

# Raised when the MECHANICAL WORKBOOK layer (build / validate / POST) fails after
# the data model is already posted + valid. The orchestrator catches this and
# degrades to a FRIENDLY agent-path handoff instead of a bare crash — the DM is
# ready, so the agent path can rebuild just the workbook against it.
class WorkbookBuildError < StandardError
  attr_reader :captured_output
  def initialize(msg, captured_output = '')
    super(msg)
    @captured_output = captured_output.to_s
  end
end

# Like run!, but on failure raises WorkbookBuildError (catchable) instead of
# abort()ing the process. Captures the child output so the caller can mine it for
# the offending field name(s) ("Dependency not found", "Unknown column", etc.).
def run_wb!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  raise WorkbookBuildError.new("command failed (#{st.exitstatus}): #{cmd.join(' ')}", out) unless st.success?
  out
end

# A DM POST fails HARD ("Cannot resolve columns … dependency not found" /
# "Source not found: warehouse table '…'") when a source table lives in a schema
# the connection CANNOT READ — the single most common enterprise blocker (customer
# feedback 2026-07-17; the "1,763 → 0 errors" iteration). Map the offending
# element/table in the POST output back to its source-path schema and return a
# concrete GRANT action so the user isn't left decoding an opaque 400. Returns nil
# when the failure isn't an unreadable-table error.
def explain_unreadable_tables(out, dm_spec_path, conn)
  spec = (JSON.parse(File.read(dm_spec_path)) rescue nil)
  return nil unless spec
  els = (spec['elements'] || []) + (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
  by_id = {}; by_tail = {}
  els.each do |e|
    p = e.dig('source', 'path')
    next unless p.is_a?(Array) && !p.empty?
    sch = p.length >= 3 ? "#{p[0]}.#{p[-2]}" : (p[-2] || p[0]).to_s
    by_id[e['id']] = [sch, p[-1]]
    by_tail[e['name'].to_s.downcase] = [sch, p[-1]] if e['name']
    by_tail[p[-1].to_s.downcase] = [sch, p[-1]]
  end
  hits = Hash.new { |h, k| h[k] = [] }
  out.scan(/table '([^']+)'/i) { |m| (s = by_id[m[0]]) && (hits[s[0]] << s[1]) }
  out.scan(/formula reference '([^'\/]+)\//i) { |m| (s = by_tail[m[0].to_s.downcase]) && (hits[s[0]] << s[1]) }
  out.scan(/warehouse table '([^']+)'/i) do |m|
    parts = m[0].split('.'); next if parts.size < 2
    sch = parts.size >= 3 ? "#{parts[0]}.#{parts[-2]}" : parts[-2]
    hits[sch] << parts[-1]
  end
  return nil if hits.empty?
  hits.map { |sch, tbls| "   │    • #{sch}  (table(s): #{tbls.uniq.first(6).join(', ')}) — grant to connection #{conn || '<the DM connection>'}" }.join("\n")
end

# Pull likely-offending field/column names out of a failed workbook build/POST log
# so the fallback message can name them. Looks for the common rejection shapes:
#   "Dependency not found: <X>", "Unknown column \"[<X>]\"", "source: {} ... <X>",
#   "Invalid value: undefined", unresolved [El/Col] refs.
def cull_failed_fields(*logs)
  text = logs.join("\n")
  names = []
  text.scan(/Dependency not found:?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Unknown column\s*"?\[?([^"\]\n]+)\]?"?/i) { |m| names << m[0].strip }
  text.scan(/unmapped (?:derived[- ]dim|measure|field)\s*[:=]?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Circular column reference[^\n]*\[([^\]]+)\]/i) { |m| names << m[0].strip }
  names.map { |n| n.gsub(/[\[\]"]/, '').strip }.reject(&:empty?).uniq
end

# COMPOSITE / live-connection detection on the FABRIC-extracted TMSL. A Power BI
# composite report (or one live-connected to a shared dataset) keeps references
# to a REMOTE semantic model; getDefinition of the report's bound model then
# returns an INCOMPLETE model (missing the report-local measures/calc tables, or
# not resolvable standalone). The COMPLETE model lives in the local .pbix — so
# we detect the incompleteness here and prompt for --pbix rather than silently
# building a broken DM. Conservative signals (import-mode happy path never
# fires): DirectQuery partitions, `entity` partitions bound to a remote model,
# or an M expression naming the AnalysisServices / Power BI dataset connector.
# Returns a list of human-readable reason strings ([] when the model is a
# complete import model). The offline analog is the .pbix Connections
# RemoteArtifacts tell (extract-model-pbix.py is_composite_connections).
TOTAL = 6


# ---------------------------------------------------------------------------
# Phase 0 — LOCAL .pbix extract (only with --pbix; no Fabric/tenant). Reads the
# .pbix's binary VertiPaq DataModel with pbixray and emits a TMSL model.bim in
# the SAME shape --tmsl consumes, then wires it in as opts[:tmsl]. The report
# half (the zip's UTF-16LE Report/Layout) is extracted in Phase 1. If pbixray
# is absent, extract-model-pbix.py exits with a clear install hint and this
# run stops here — the Fabric --tmsl/--pbir route and the report front door
# (extract-report-classic.py --pbix) do NOT need pbixray.
# ---------------------------------------------------------------------------
extract_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
if extract_cache['reuse']
  puts
  puts "   EXTRACT CACHE: #{extract_cache['reason']} - skipping the Phase 0/1 extraction " \
       "(#{opts[:pbix] ? 'model.bim, report-layout.json, signals.json' : 'signals.json'} from #{WORK}; " \
       '--no-reuse-extract forces a fresh one)'
elsif opts[:reuse_extract] || extract_cache['reason'] !~ /no recorded input fingerprint/
  puts
  puts "   EXTRACT CACHE: not used - #{extract_cache['reason']}"
end
if opts[:pbix]
  phase_mark('0-local-pbix-extract')
  puts
  puts '── Phase 0/6 · Local .pbix extract (no Fabric) ──'
  # Cheap stdlib-only probe (no pbixray): is this a composite / live-connected
  # .pbix? If so, using the LOCAL file (which carries the complete composite
  # model) is exactly right — note it so the choice is visible.
  comp_out, comp_st = Open3.capture2e(*PY_ARGV, File.join(HERE, 'extract-model-pbix.py'),
                                      '--pbix', opts[:pbix], '--detect-composite')
  if comp_st.success? && (JSON.parse(comp_out)['composite'] rescue false)
    puts '   composite / live-connected .pbix detected — the local file carries the COMPLETE'
    puts '   model (a Fabric getDefinition of the bound dataset would be incomplete). Using it.'
  end
  model_bim = File.join(WORK, 'model.bim')
  if extract_cache['reuse']
    puts "   VertiPaq model: reusing #{model_bim} (extract cache)"
  else
    puts "   VertiPaq model (pbixray) -> #{model_bim}"
    run!([*PY_ARGV, File.join(HERE, 'extract-model-pbix.py'),
          '--pbix', opts[:pbix], '--out', model_bim, '--dialect', extract_dialect,
          *(opts[:name] ? ['--name', opts[:name]] : [])])
  end
  opts[:tmsl] = model_bim
end

# ---------------------------------------------------------------------------
# Phase 1 — Discover / Extract (explode the PBIR bundle, parse TMSL + signals)
# ---------------------------------------------------------------------------
hdr(1, TOTAL, 'Discover / Extract')

signals_path = File.join(WORK, 'signals.json')
if opts[:pbix] && extract_cache['reuse']
  puts "   report: reusing #{signals_path} + report-layout.json (extract cache)"
elsif opts[:pbix]
  # Both classic Report/Layout and modern PBIR emit the same signals schema.
  puts '   local .pbix report — detecting classic Report/Layout or modern Report/definition PBIR'
  pbix_layout_dump = File.join(WORK, 'report-layout.json')
  run!([*PY_ARGV, File.join(HERE, 'extract-report-classic.py'), '--pbix', opts[:pbix], '--out', signals_path,
        '--dump-layout', pbix_layout_dump])
elsif extract_cache['reuse']
  # The bundle is still read (cheap) for the model-scope documents; only the explode +
  # extract-pbir/extract-report-classic run is skipped.
  bundle = JSON.parse(File.read(opts[:pbir]))
  scope_docs = bundle.select { |part, _| part.start_with?('definition/') }.values
  scope_docs = [bundle['report.json']].compact if scope_docs.empty?
  puts "   report: reusing #{signals_path} (extract cache; PBIR explode + extractor skipped)"
else
  # The raw-pbir/*.json files are a FLAT bundle: { "<part-path>": "<json text>", ... }.
  # extract-pbir.py wants an exploded definition/ folder — so explode it first.
  pbir_dir = File.join(WORK, 'pbir')
  FileUtils.mkdir_p(pbir_dir)
  bundle = JSON.parse(File.read(opts[:pbir]))
  scope_docs = bundle.select { |part, _| part.start_with?('definition/') }.values
  scope_docs = [bundle['report.json']].compact if scope_docs.empty?
  exploded = 0
  bundle.each do |part, payload|
    next unless part.start_with?('definition/') # the exploded-PBIR parts only
    fp = File.join(pbir_dir, part)
    FileUtils.mkdir_p(File.dirname(fp))
    File.write(fp, payload.is_a?(String) ? payload : JSON.pretty_generate(payload))
    exploded += 1
  end
  # bead anlb (orchestrator parity with run.sh): a fetched definition may be the
  # CLASSIC single report.json (top-level sections[]) instead of exploded PBIR
  # parts. Branch to extract-report-classic.py — same signals.json schema out.
  classic_rj = nil
  if exploded.zero? && bundle.key?('report.json')
    classic_rj = File.join(pbir_dir, 'report.json')
    payload = bundle['report.json']
    File.write(classic_rj, payload.is_a?(String) ? payload : JSON.pretty_generate(payload))
  end
  abort "FATAL: PBIR bundle has no definition/ parts and no classic report.json — keys=#{bundle.keys.first(3)}" if exploded.zero? && classic_rj.nil?
  if classic_rj
    puts '   classic single report.json detected — branching to extract-report-classic.py'
    run!([*PY_ARGV, File.join(HERE, 'extract-report-classic.py'), '--report-json', classic_rj, '--out', signals_path])
  else
    run!([*PY_ARGV, File.join(HERE, 'extract-pbir.py'), '--pbir-dir', pbir_dir, '--out', signals_path])
  end
end
signals = JSON.parse(File.read(signals_path))
# Extraction finished (or was served from the cache): record the input fingerprint so the next
# rerun can skip it, and say so on the PHASE TIMINGS line when it was skipped.
extract_elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - extract_t0).round(1)
if extract_cache['reuse']
  $extract_cache_note = PbiExtractCache.timings_note(extract_cache, extract_elapsed)
  puts "   #{$extract_cache_note}"
else
  PbiExtractCache.record(WORK, extract_fp, extract_elapsed)
end

# TMSL model summary + import/DirectQuery mode.
tmsl = JSON.parse(File.read(opts[:tmsl]))
model = tmsl['model'] || tmsl

# Extraction notes that mean data was LOST (Enter-data cells loaded as NULL, Enter-data SQL not
# generated for this warehouse, an assumed model culture). They live in model.bim annotations; read
# them here on every route (also a cached rerun) so they are loud, not buried in the TMSL.
extract_notes = PbiExtractNotes.collect(tmsl)
unless extract_notes.empty?
  File.write(File.join(WORK, 'extract-notes.json'), JSON.pretty_generate(extract_notes))
  PbiExtractNotes.lines(extract_notes).each { |l| warn "   #{l}" }
end

normalized_tmsl_path = File.join(WORK, 'model-normalized.bim')
File.write(normalized_tmsl_path, JSON.pretty_generate(PbiNativeQuery.normalize_tmsl(tmsl)))

# ---------------------------------------------------------------------------
# MODEL SCOPE — keep only the tables the report uses (default). The pruned
# model drives the converter, the DM-reuse signature and the workbook builder;
# everything else in this script keeps reading the FULL model (a superset is
# harmless there). --full-model skips all of it. Audit trail: model-scope.json.
# ---------------------------------------------------------------------------
scope_docs ||= []
if opts[:pbix]
  _ld = File.join(WORK, 'report-layout.json')
  scope_docs = [File.read(_ld)] if File.exist?(_ld)
end
scoped_tmsl_path = nil
scoped_model = nil
model_scope_path = File.join(WORK, 'model-scope.json')
model_scope = { 'enabled' => false, 'kept' => [], 'dropped_tables' => [], 'dropped_measures' => [],
                'dropped_calc_columns' => [], 'dropped_views' => [], 'dropped_masters' => [] }
write_model_scope = -> { File.write(model_scope_path, JSON.pretty_generate(model_scope)) }
if opts[:full_model]
  puts
  puts 'MODEL SCOPE: off (--full-model) - building the whole semantic model'
else
  _m0 = tmsl['model'] || tmsl
  _measure_home = {}
  (_m0['tables'] || []).each { |t| (t['measures'] || []).each { |m| _measure_home[m['name']] = t['name'] } }
  _measure_names = Set.new(_measure_home.keys)
  _tnames = (_m0['tables'] || []).map { |t| t['name'] }
  _used = PbiModelScope.report_measures(scope_docs, _measure_names)
  _sig_seeds = Set.new
  _used_columns = PbiModelScope.report_columns(scope_docs, _tnames)
  PbiModelScope.signal_page_refs(signals).flatten.each do |r|
    rb = PbiModelScope.resolve_binding(r, _tnames)
    next unless rb
    _sig_seeds << rb[0]
    _used << rb[1] if _measure_home[rb[1]] == rb[0]
    _used_columns << rb.join('.')
  end
  res = PbiModelScope.scope(tmsl, scope_docs, _used.to_a, _sig_seeds.to_a, _used_columns.to_a)
  model_scope.merge!(res.reject { |k, _| k == 'tmsl' })
  model_scope.delete('fallback_reason') unless res['fallback_reason']
  puts
  if res['fallback_reason']
    puts "MODEL SCOPE: fallback to the FULL model - #{res['fallback_reason']}"
    Offramp.log(WORK, kind: 'model-scope-fallback', reason: res['fallback_reason'])
  else
    total_tables = ((tmsl['model'] || tmsl)['tables'] || []).count { |t| !PbiModelScope.date_table?(t['name']) }
    puts "MODEL SCOPE: kept #{res['kept'].size} of #{total_tables} tables"
    res['kept'].each { |k| puts "   keep  #{k['table']}  (#{k['reasons'].join(', ')})" }
    puts "   dropped tables: #{res['dropped_tables'].join(', ')}" unless res['dropped_tables'].empty?
    puts "   dropped measures: #{res['dropped_measures'].join(', ')}" unless res['dropped_measures'].empty?
    puts "   dropped calculated columns: #{res['dropped_calc_columns'].join(', ')}" unless res['dropped_calc_columns'].empty?
    scoped_tmsl_path = File.join(WORK, 'model-scoped.bim')
    File.write(scoped_tmsl_path, JSON.pretty_generate(res['tmsl']))
    scoped_model = res['tmsl']['model'] || res['tmsl']
    normalized_tmsl_path = File.join(WORK, 'model-scoped-normalized.bim')
    File.write(normalized_tmsl_path, JSON.pretty_generate(PbiNativeQuery.normalize_tmsl(res['tmsl'])))
  end
end
write_model_scope.call

# ---------------------------------------------------------------------------
# F13 NAME SANITIZE - a column/measure name containing "/" cannot be referenced
# from a Sigma formula ([A/B] = "Dependency not found"). Rename it to U+2215
# (same glyph) consistently in the TMSL (names, DAX, relationships) and the
# signals bindings BEFORE conversion. Runs AFTER model scope on purpose: scope
# matches the raw report documents, which still carry the original names.
# Audit + rename map: <WORK>/name-sanitize.json (consumers translating a
# source-side name back, e.g. parity against live Power BI, read it).
# ---------------------------------------------------------------------------
name_sanitize = { 'renames' => [], 'unsanitized_tables' => [] }
unless opts[:skip_name_sanitize]
  _t_full, _s_new, name_sanitize = PbiNameSanitize.sanitize(tmsl, signals)
  unless name_sanitize['renames'].empty?
    tmsl = _t_full
    model = tmsl['model'] || tmsl
    signals = _s_new
    FileUtils.cp(signals_path, extracted_signals_copy) unless File.exist?(extracted_signals_copy)
    File.write(signals_path, JSON.pretty_generate(signals))
    if scoped_model
      _scoped_t = JSON.parse(File.read(scoped_tmsl_path))
      PbiNameSanitize.sanitize!(_scoped_t)
      File.write(scoped_tmsl_path, JSON.pretty_generate(_scoped_t))
      scoped_model = _scoped_t['model'] || _scoped_t
      File.write(normalized_tmsl_path, JSON.pretty_generate(PbiNativeQuery.normalize_tmsl(_scoped_t)))
    else
      _sanitized_bim = File.join(WORK, 'model-sanitized.bim')
      File.write(_sanitized_bim, JSON.pretty_generate(tmsl))
      opts[:tmsl] = _sanitized_bim
      File.write(normalized_tmsl_path, JSON.pretty_generate(PbiNativeQuery.normalize_tmsl(tmsl)))
    end
    puts "   NAME SANITIZE: renamed #{name_sanitize['renames'].size} column/measure name(s) containing '/' to U+2215 (see name-sanitize.json)"
  end
  unless name_sanitize['unsanitized_tables'].empty?
    warn "   \u26A0 table name(s) containing '/' cannot be referenced from a Sigma formula and were NOT renamed: #{name_sanitize['unsanitized_tables'].join(', ')}"
  end
  File.write(File.join(WORK, 'name-sanitize.json'), JSON.pretty_generate(name_sanitize)) unless name_sanitize['renames'].empty? && name_sanitize['unsanitized_tables'].empty?
end

# NativeQuery is ordinary warehouse SQL, not evidence of a remote/composite
# semantic model. Preserve it through the pinned converter. Downstream M steps
# are a separate fidelity question: they must be folded into the SQL or
# explicitly accepted, never silently discarded.
# Renames, duplicated columns, row filters and Table.Distinct fold into the
# SQL and its column bindings; type changes, removed/reordered columns and
# sorts are no-ops for a model table. Only the steps left over stop the run,
# and only in tables the report uses (after MODEL SCOPE).
native_transform_gaps = PbiNativeQuery.unfoldable(scoped_model || model, opts[:wh_type])
if native_transform_gaps.any? && !opts[:allow_native_m_transforms]
  puts
  puts '╭─ OPEN QUESTION — NativeQuery has Power Query steps that cannot be folded ─'
  native_transform_gaps.each do |native, folded|
    puts "│  • #{native.table}: #{folded.unsupported.join(', ')}"
  end
  puts '│'
  puts '│  The SQL and every foldable step are preserved; these steps are not part of'
  puts '│  it. Fold them into the SQL and rerun. If they are already represented'
  puts '│  manually, rerun with --allow-native-m-transforms.'
  puts '╰──────────────────────────────────────────────────────────────────────────────'
  exit 10
end

# COMPOSITE GATE (Fabric --tmsl path only; --pbix already IS the complete local
# model). getDefinition returns an INCOMPLETE model for composite / live-
# connected reports — the full model lives in the local .pbix. Detect it and
# PROMPT for the .pbix instead of silently building a broken DM. --allow-
# incomplete-model overrides. This is what MOTIVATES the local front door.
unless opts[:pbix] || opts[:allow_incomplete_model]
  composite_reasons = PbiComposite.incomplete_reasons(model)
  unless composite_reasons.empty?
    puts
    puts '╭─ OPEN QUESTION — composite / live-connected report (incomplete Fabric model) ─'
    puts '│  The extracted semantic model shows references to a REMOTE Power BI dataset:'
    composite_reasons.first(6).each { |r| puts "│    • #{r}" }
    puts '│'
    puts '│  This is a COMPOSITE (or live-connected) report: Fabric getDefinition returns'
    puts '│  only the report-BOUND model, which is INCOMPLETE (it misses the report-local'
    puts '│  measures / calc tables, or is not resolvable standalone). Power BI also BLOCKS'
    puts '│  export-to-.pbix for live-connected reports, so device-auth cannot download it.'
    puts '│  The COMPLETE model lives in the local .pbix on the author\'s machine.'
    puts '│'
    puts '│  ACTION: ask the user for the local .pbix and re-run through the local front door:'
    puts "│      ruby scripts/migrate-powerbi.rb --pbix <that file.pbix> \\"
    puts "│        --connection #{opts[:conn] || '<id>'} --database #{opts[:db].empty? ? '<DB>' : opts[:db]} --schema #{opts[:schema].empty? ? '<SCHEMA>' : opts[:schema]} --out #{WORK}"
    puts '│  (Deliberately proceeding on the known-incomplete Fabric model? add --allow-incomplete-model.)'
    puts '╰──────────────────────────────────────────────────────────────────────────────'
    exit 10
  end
end

tables = (model['tables'] || []).reject { |t| t['name'].to_s.start_with?('LocalDateTable_', 'DateTableTemplate_') }
all_measures = tables.flat_map { |t| (t['measures'] || []).map { |m| [t['name'], m['name'], Array(m['expression']).join] } }
# measure name -> its ORIGINAL TMSL table = the entity a PBIR visual binds it under.
# PBI measure names are model-unique (the same assumption ti_orig_table relies on).
# Used by the master-map loop to alias a re-homed measure back to its source entity
# so "_Measures.TotalSales" resolves ([bead]).
measure_orig_table = {}
all_measures.each { |tbl, mname, _| measure_orig_table[mname] = tbl }

# PBI friendly table name <-> physical warehouse table (the M-query path-tail). PBIR
# visuals reference columns under the FRIENDLY entity ("Sales") but the converter
# names the DM element after the PHYSICAL table ("vw_sales"), so an entity-qualified
# queryRef misses the master-map and the column silently drops — the customer's missing
# dim NAME columns ([bead]). Capture the map so the master-map can alias every
# key under the friendly entity too.
# 1:N, not 1:1. A model can import the SAME warehouse table under several names (six
# role-playing DATE_DIMs on real report R2); the old 1:1 Hash kept only the LAST, so five
# of the six copies got no alias at all.
physical_to_pbi = PbiMasterKey.physical_to_pbi(tables)
modes = tables.flat_map { |t| (t['partitions'] || []).map { |p| p['mode'] } }.compact.uniq
mode_summ = modes.empty? ? 'unknown' : modes.join('/')

all_visuals = signals['pages'].flat_map { |p| p['visuals'] }
vkinds = all_visuals.each_with_object(Hash.new(0)) { |v, h| h[v['visual_type']] += 1 }
vsumm = vkinds.map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
puts "   model '#{name_slug}': #{tables.size} table(s), #{tables.sum { |t| (t['columns'] || []).size }} column(s), " \
     "#{all_measures.size} measure(s), mode=#{mode_summ}"
puts "   report: #{signals['pages'].size} page(s), #{all_visuals.size} visual(s) (#{vsumm})"

# --- Phase 1.5 — SOURCE-FRESHNESS PREFLIGHT (bead fmte) — NON-BLOCKING ------
# An import-mode PBI model is a frozen snapshot; Sigma reads the LIVE warehouse.
# The preflight (refresh history + per-table executeQueries snapshot) is only
# CONSUMED at Phase 6 parity, so it runs as a BACKGROUND LANE concurrent with
# Phase 2 Convert / Phase 3-5 build instead of blocking the pipeline for its
# 3-8s of Power BI round-trips. Joined (with the log replayed) at Phase 6.
# Best-effort: a preflight failure warns and continues. If the run stops at a
# gate (decisions exit 10 / converter gate), the detached probe still finishes
# and writes freshness.json for the resume run, which reuses it.
fresh_path = File.join(WORK, 'freshness.json')
fresh_log  = File.join(WORK, 'freshness.log')
fresh_waiter = nil
if File.exist?(fresh_path) && !opts[:skip_fresh]
  puts "   freshness.json already present — reusing (delete #{fresh_path} to re-probe)"
elsif opts[:ws] && opts[:dataset] && !opts[:skip_fresh] && modes.include?('import')
  fresh_pid = Process.spawn(*PY_ARGV, File.join(HERE, 'pbi-freshness.py'),
                            '--workspace', opts[:ws], '--dataset', opts[:dataset],
                            '--tmsl', opts[:tmsl], '--out', fresh_path,
                            out: fresh_log, err: fresh_log)
  fresh_waiter = Process.detach(fresh_pid)
  puts "   freshness preflight launched NON-BLOCKING (pid #{fresh_pid}) — runs alongside Convert/Build, consumed at Phase 6"
elsif opts[:ws] && opts[:dataset] && !opts[:skip_fresh]
  puts "   (freshness preflight skipped — model is #{mode_summ}, not import-mode: Sigma and PBI both read live)"
end

# ---------------------------------------------------------------------------
# Phase 2 — Convert (run convertPowerBIToSigma via a node shim)
# ---------------------------------------------------------------------------
hdr(2, TOTAL, 'Convert')
if opts[:cvt_out]
  # bead 7o01: converter output supplied (the convert_powerbi_to_sigma MCP tool
  # ran out-of-process — the default route when no local build exists). Unwrap
  # the {model,...} / {sigmaDataModel} wrapper the same way the shim does.
  raw = JSON.parse(File.read(opts[:cvt_out]))
  bare = raw['model'] || raw['sigmaDataModel'] || raw
  File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(bare))
  File.write(File.join(WORK, 'conv-meta.json'),
             JSON.pretty_generate({ 'model' => bare, 'warnings' => raw['warnings'] || [],
                                    'stats' => raw['stats'] || {} }))
  puts "   converter output ingested from #{opts[:cvt_out]}"
elsif CONV_MODULE.nil?
  puts '   vendored converter (converter/powerbi.mjs) missing and no local converter-source build (--mcp-dir / PBI_MCP_DIR).'
  puts
  puts '   >>> GATE: run the convert_powerbi_to_sigma MCP tool on the TMSL model'
  puts "       (#{scoped_tmsl_path || opts[:tmsl]}) with connectionId=#{opts[:conn]} database=#{opts[:db]} schema=#{opts[:schema]} warehouseType=#{opts[:wh_type].to_s.empty? ? '(default UPPER)' : opts[:wh_type]},"
  puts '       save the tool result JSON to a file, then re-run this command with'
  puts '       --converter-out <that file>. No Sigma objects were created.'
  exit 10
end
unless opts[:cvt_out]
puts "   converter: #{CONV_MODULE == VENDORED_PBI ? 'vendored bundle (converter/powerbi.mjs)' : CONV_MODULE} (no data leaves this machine)"
puts "   warehouse dialect: #{opts[:wh_type].to_s.empty? ? 'default (UPPER — Snowflake/BigQuery)' : "#{opts[:wh_type]} → lower-case physical ids"} ([bead].7)"
shim = File.join(WORK, '_convert.mjs')
# Node ESM on Windows rejects a bare drive-letter specifier
# (`import ... from "C:/path/powerbi.mjs"` → ERR_UNSUPPORTED_ESM_URL_SCHEME,
# protocol 'c:'). Absolute paths must be file:// URLs there. POSIX absolute
# paths import fine as-is, so we only rewrite on Windows and leave the
# (working) macOS/Linux path byte-identical.
import_specifier =
  if Gem.win_platform? && CONV_MODULE.to_s.match?(/\A[A-Za-z]:/)
    'file:///' + CONV_MODULE.gsub('\\', '/')
  else
    CONV_MODULE
  end
File.write(shim, <<~JS)
  import { readFileSync, writeFileSync } from 'node:fs';
  import { convertPowerBIToSigma } from #{import_specifier.to_json};
  const model = JSON.parse(readFileSync(#{normalized_tmsl_path.to_json}, 'utf8'));
  const out = convertPowerBIToSigma(model, {
    connectionId: #{(opts[:conn] || '').to_json},
    database: #{opts[:db].to_json},
    schema: #{opts[:schema].to_json},
    warehouseType: #{(opts[:wh_type] || '').to_json},
  });
  // Write the UNWRAPPED model to dm-raw.json. convert-model.rb MODE B unwraps
  // only {sigmaDataModel} or a bare spec, NOT this converter's {model,...}
  // wrapper, so it must receive the bare model (else "pages: Invalid array").
  const bare = out.model || out.sigmaDataModel || out;
  writeFileSync(#{File.join(WORK, 'dm-raw.json').to_json}, JSON.stringify(bare, null, 2));
  writeFileSync(#{File.join(WORK, 'conv-meta.json').to_json}, JSON.stringify({ model: bare, warnings: out.warnings || [], stats: out.stats || {} }, null, 2));
  process.stderr.write('CONVSTATS ' + JSON.stringify({ warnings: out.warnings || [], stats: out.stats || {} }) + '\\n');
JS
_c_out, c_err, c_st = Open3.capture3('node', shim)
abort "FATAL: converter failed:\n#{c_err}#{_c_out}" unless c_st.success?
puts "   converter ran (build: #{MCP_DIR})"
end
conv = JSON.parse(File.read(File.join(WORK, 'conv-meta.json')))
dm_model = conv['model']
conv_warnings = conv['warnings'] || []
conv_stats = conv['stats'] || {}
native_result = PbiNativeQuery.apply!(dm_model, scoped_model || model, dialect: opts[:wh_type])
native_blockers = native_result['blockers'].reject do |blocker|
  opts[:allow_native_m_transforms] &&
    blocker['reason'].to_s.include?('followed by Power Query M transforms')
end
unless native_blockers.empty?
  abort "FATAL: NativeQuery restoration failed:\n" +
        native_blockers.map { |b| "  - #{b['table']}: #{b['reason']}" }.join("\n")
end
if native_result['converted'].any?
  File.write(File.join(WORK, 'native-query-conversion.json'), JSON.pretty_generate(native_result))
  File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(dm_model))
  conv['model'] = dm_model
  File.write(File.join(WORK, 'conv-meta.json'), JSON.pretty_generate(conv))
  puts "   restored #{native_result['converted'].size} NativeQuery source(s) as Custom SQL"
end

# MODEL SCOPE: drop converter Views no visual / helper / relocated column needs.
dropped_views = []
if scoped_model
  dropped_views = PbiModelScope.filter_views!(dm_model, signals, scoped_model)
  unless dropped_views.empty?
    File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(dm_model))
    conv['model'] = dm_model
    File.write(File.join(WORK, 'conv-meta.json'), JSON.pretty_generate(conv))
    puts "   MODEL SCOPE: dropped #{dropped_views.size} View(s): #{dropped_views.join(', ')}"
  end
  model_scope['dropped_views'] = dropped_views
  write_model_scope.call
end

# PROBE SOURCES (opt-in, --probe-sources): run every Custom SQL statement ONCE against the warehouse
# (scripts/probe-native-sources.py) BEFORE the data model is posted, instead of discovering a
# missing column / VARCHAR-vs-boolean mismatch one POST 400 at a time. The probe's output names
# become <WORK>/sql-output-names.json (the dm-resolver's authoritative [Custom SQL/X] source, so an
# unknown ref is nulled pre-POST), its casts are folded into the element SQL, and the run STOPS
# (exit 10) when a bound column is missing from the SQL output. Audit: native-source-probe.json.
probe_applied = []
probe_names_fresh = false # true only when THIS run wrote sql-output-names.json (it is then authoritative)
sql_names_path = File.join(WORK, 'sql-output-names.json')
sql_names_stamp_path = File.join(WORK, 'sql-output-names.stamp.json')
if opts[:probe_sources]
  phase_mark('2a-probe-sources')
  if PbiProbeGate.sql_elements(dm_model).empty?
    puts '   probe-sources: no Custom SQL elements in the data model - nothing to probe'
    FileUtils.rm_f([sql_names_path, sql_names_stamp_path]) # nothing probed: a previous run's names are stale
  else
    probe_report_path = File.join(WORK, 'native-source-probe.json')
    abort 'FATAL: --probe-sources needs a Sigma connection (--connection <id>) to probe against' unless opts[:probe_results] || opts[:conn]
    FileUtils.rm_f(probe_report_path)
    probe_dm_path = File.join(WORK, 'dm-probe-input.json')
    File.write(probe_dm_path, JSON.pretty_generate(dm_model))
    probe_argv = [*PY_ARGV, *PbiProbeGate.command(
      File.join(HERE, 'probe-native-sources.py'), dm_path: probe_dm_path, tmsl_path: normalized_tmsl_path,
      out_path: probe_report_path, state_path: File.join(WORK, 'native-source-probe.state.json'),
      connection: opts[:conn], folder: opts[:folder], dialect: PbiProbeGate.dialect_for(opts[:wh_type]),
      probe_results: opts[:probe_results]
    ),
                   *(opts[:probe_concurrency] ? ['--probe-concurrency', opts[:probe_concurrency].to_s] : []),
                   *(opts[:probe_no_cache] ? ['--probe-no-cache'] : []),
                   *(opts[:probe_cache_max_age_hours] ? ['--probe-cache-max-age-hours', opts[:probe_cache_max_age_hours].to_s] : []),
                   *(opts[:keep_probe_workbook] ? ['--keep-probe-workbook'] : [])]
    puts "   probe-sources: #{PbiProbeGate.sql_elements(dm_model).size} Custom SQL element(s) -> " \
         "#{opts[:probe_results] ? "replaying #{opts[:probe_results]}" : 'warehouse probe (one round trip per distinct statement)'}"
    _po, probe_err, probe_st = Open3.capture3(*probe_argv)
    (_po + probe_err).each_line { |l| puts "   #{l.rstrip}" unless l.strip.empty? }
    unless File.exist?(probe_report_path)
      abort "FATAL: probe-native-sources.py produced no report (exit #{probe_st.exitstatus}); nothing was posted. " \
            'Fix the probe error above, or rerun without --probe-sources.'
    end
    probe_report = JSON.parse(File.read(probe_report_path))
    probe_blocks = PbiProbeGate.blockers(probe_report, allow_missing: opts[:probe_allow_missing])
    unless probe_blocks.empty?
      puts
      puts PbiProbeGate.stop_message(probe_blocks, probe_report_path)
      exit 10
    end
    # sql-output-names.json is stamped with each element's statement hash (taken BEFORE the casts
    # are folded in): a later run without --probe-sources ignores the names of any element whose
    # SQL changed instead of nulling valid refs against a stale output list.
    File.write(sql_names_path, JSON.pretty_generate(PbiProbeGate.sql_output_names(probe_report)))
    File.write(sql_names_stamp_path, JSON.pretty_generate(PbiProbeGate.statement_stamps(dm_model)))
    probe_names_fresh = true
    probe_applied = PbiProbeGate.apply_casts!(dm_model, probe_report)
    probe_report['applied_to_dm'] = probe_applied
    File.write(probe_report_path, JSON.pretty_generate(probe_report))
    puts "   #{PbiProbeGate.summary_line(probe_report, probe_applied)} (native-source-probe.json)"
    probe_applied.each { |c| puts "   cast #{c['element']} / #{c['column']}: #{c['expression']} (#{c['warehouse_type']} -> #{c['tmsl_type']})" }
    probe_report['type_warnings'].to_a.first(8).each do |w|
      warn "   \u26A0 probe: #{w['table']}.#{w['column']}: #{w['reason']}"
    end
    PbiProbeGate.probe_errors(probe_report).each do |e|
      warn "   \u26A0 probe could not check #{e['element']}: #{e['error'][0, 200]} (its [Custom SQL/X] refs are left unverified)"
    end
    unless probe_applied.empty?
      File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(dm_model))
      conv['model'] = dm_model
      File.write(File.join(WORK, 'conv-meta.json'), JSON.pretty_generate(conv))
    end
  end
  phase_mark('2-convert-fixers')
end

# DM RESOLVER (D1-D8): deterministic fixes for the converter output that
# otherwise surface as one POST 400 at a time - stale element prefixes left by
# the NativeQuery restore, refs that differ from the target column only by
# case/punctuation, leaked DAX, refs that resolve nowhere (nulled + recorded),
# duplicate element ids, integer YYYYMMDD keys under DateTrunc/DateLookback,
# unnamed Null columns. Every rewrite and every nulled formula (with its
# unresolved refs) is written to <WORK>/dm-resolver.json.
# Optional inputs: <WORK>/sql-output-names.json {"Element": ["SQL output", ..]}
# (probed SQL output names, authoritative for [Custom SQL/X]) and
# <WORK>/dm-resolver-overrides.json {"overrides": {"Element|Name": formula}, "null_list": [..]}.
dm_resolver_changed = false
unless opts[:skip_dm_resolver]
  _rd = lambda do |fname|
    path = File.join(WORK, fname)
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  end
  _rov = _rd.call('dm-resolver-overrides.json')
  sql_names_in = _rd.call('sql-output-names.json')
  unless probe_names_fresh || sql_names_in.empty?
    # Not written by this run: only trust the entries whose statement is unchanged since the probe.
    _stamps = File.exist?(sql_names_stamp_path) ? (JSON.parse(File.read(sql_names_stamp_path)) rescue nil) : nil
    sql_names_in, _stale = PbiProbeGate.fresh_sql_names(sql_names_in, _stamps, dm_model)
    puts "   probe names ignored for #{_stale.join(', ')}: their Custom SQL changed since the last --probe-sources run (rerun with --probe-sources to re-check)" unless _stale.empty?
  end
  resolver_log = PbiDmResolver.resolve!(dm_model,
                                        sql_names: sql_names_in,
                                        overrides: _rov['overrides'] || {}, null_list: _rov['null_list'] || [],
                                        date_key_columns: PbiDmResolver.date_key_columns_from_tmsl(scoped_model || model))
  File.write(File.join(WORK, 'dm-resolver.json'), JSON.pretty_generate(resolver_log))
  puts "   #{PbiDmResolver.summary_line(resolver_log)} (dm-resolver.json)"
  # Every nulled formula is listed (a capped list hid lost calculated columns);
  # nulled names also stop counting as realized, so the DAX gate asks about them.
  PbiDmResolver.report_lines(resolver_log).each { |line| puts "   #{line}" }
  resolver_log['prefix_unresolved'].each { |p, why| warn "   \u26A0 dm-resolver: stale prefix [#{p}/..] #{why}" }
  unless (resolver_log['blockers'] || []).empty?
    warn "FATAL: dm-resolver found #{resolver_log['blockers'].size} blocker(s) (see above and dm-resolver.json); " \
         'no Sigma objects were created. Disambiguate the element ids, or pin the intended formulas in ' \
         'dm-resolver-overrides.json, then rerun.'
    exit 10
  end
  dm_resolver_changed = resolver_log['summary'].reject { |k, _| %w[ambiguous unverified].include?(k) }.values.any?(&:positive?)
  if dm_resolver_changed
    File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(dm_model))
    conv['model'] = dm_model
    File.write(File.join(WORK, 'conv-meta.json'), JSON.pretty_generate(conv))
  end
end

# Calculated tables that are just the distinct values of another table's columns
# have a warehouse source (the source table itself): convert them to Custom SQL
# and drop the converter's placeholder warning so the gate below only stops on
# the ones that are really unresolved. Record: <WORK>/calc-table-sql.json.
calc_sql_result = PbiCalcTableSql.apply!(dm_model, scoped_model || model, conv_warnings, dialect: opts[:wh_type])
unless calc_sql_result['converted'].empty?
  File.write(File.join(WORK, 'calc-table-sql.json'), JSON.pretty_generate(calc_sql_result))
  File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(dm_model))
  conv['model'] = dm_model
  conv['warnings'] = conv_warnings
  File.write(File.join(WORK, 'conv-meta.json'), JSON.pretty_generate(conv))
  puts "   converted #{calc_sql_result['converted'].size} distinct-values calculated table(s) to Custom SQL (calc-table-sql.json)"
  calc_sql_result['converted'].each do |c|
    pend = c['pending_calculated_columns'].map { |x| x['name'] }
    warn "   ⚠ calculated table #{c['table']}: calculated column(s) #{pend.join(', ')} were not carried over; re-author them" unless pend.empty?
  end
end

# Fail closed on calculated tables that only look converted. A CALENDAR spine
# with NULL event flags is queryable and can pass shape/readback checks, but
# every Black-Friday/Easter/etc. filter is wrong. Unlike ordinary DAX measure
# review questions this gate is NOT auto-accepted by --yes.
calc_table_issues = DaxGate.calculated_table_issues(dm_model, conv_warnings)
unless calc_table_issues.empty?
  override_reason = opts[:allow_incomplete_calculated_tables].to_s.strip
  gate_record = {
    'status' => override_reason.empty? ? 'blocked' : 'accepted_incomplete',
    'reason' => override_reason.empty? ? nil : override_reason,
    'issues' => calc_table_issues
  }.compact
  File.write(File.join(WORK, 'calculated-table-gate.json'), JSON.pretty_generate(gate_record))
  if override_reason.empty?
    abort "FATAL: incomplete DAX calculated table output; no Sigma objects were created:\n" \
          "#{calc_table_issues.map { |issue| "  - #{issue}" }.join("\n")}\n" \
          "Fix/restructure the calculated table, or explicitly accept the missing semantics with:\n" \
          "  --allow-incomplete-calculated-tables \"<reason>\"\n" \
          "(--yes does not bypass this gate.)"
  end
  warn "   \u26A0 calculated-table completeness override accepted: #{override_reason}"
  calc_table_issues.each { |issue| warn "      - #{issue}" }
end
_conv_els = (dm_model['pages'] || []).flat_map { |p| p['elements'] || [] }
if dropped_views.to_a.empty? && !dm_resolver_changed
  _n_els = conv_stats['elements']
  _n_cols = conv_stats['columns']
  _n_mets = conv_stats['metrics']
else
  # Views were dropped / the resolver changed the model after conversion: the converter's stats are stale.
  _n_els = _conv_els.size
  _n_cols = _conv_els.sum { |e| (e['columns'] || []).size }
  _n_mets = _conv_els.sum { |e| (e['metrics'] || []).size }
end
puts "   #{_n_els || _conv_els.size} element(s), " \
     "#{_n_cols} column(s), #{_n_mets} metric(s); #{conv_warnings.size} converter warning(s)"
# Vendor-neutral CDW join-cost advisory (informational only; never gates). See refs/modeling-strategy.md.
ModelingAdvisory.print_if_relevant(conv_stats['relationships']) if defined?(ModelingAdvisory)

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions
# ---------------------------------------------------------------------------
questions = []

# (a) + (b) DAX measures with no Sigma equivalent ((c)-tail) / DAX needing restructure.
# Classification lives in lib/dax_gate.rb (pure + unit-tested in test-dax-gate.rb).
# The converter marks each warning: ⛔ = no/failed translation (drops to Null);
# ⚠ = restructure-needed; ✅ = SUCCESS (auto-translated — RANKX→SQL window helper,
# USERELATIONSHIP→alternate join path); ℹ = informational. Only ⛔ and genuinely
# DROPPED ⚠ become decisions — ✅/ℹ and any ⚠ the converter actually REALIZED in the
# DM (e.g. time-intel → grouped element) are handled, NOT degradations. Regression fix:
# the gate used to bucket ✅ and built restructures as "needs scout", stalling --yes.
questions.concat(DaxGate.dax_questions(conv_warnings, dm_model))

# (b) visuals with no NATIVE Sigma kind. extract-pbir maps unknown visualTypes to
# "bar" as a fallback; flag any visualType that is NOT a recognized native PBI kind
# so a human confirms the approximation (treemap/funnel/gauge/map/etc.).
NATIVE = %w[card multiRowCard kpi textbox actionButton lineChart areaChart
            stackedAreaChart barChart clusteredBarChart stackedBarChart columnChart
            clusteredColumnChart stackedColumnChart hundredPercentStackedColumnChart
            hundredPercentStackedBarChart lineClusteredColumnComboChart
            lineStackedColumnComboChart pieChart donutChart scatterChart tableEx
            pivotTable matrix slicer].freeze
GAUGE = %w[gauge].freeze
all_visuals.each do |v|
  vt = v['visual_type']
  next if NATIVE.include?(vt)
  approx = GAUGE.include?(vt) ? 'approximate-to-kpi' : "approximate-to-#{v['sigma_kind']}"
  questions << { 'id' => 'visual_no_native_kind', 'severity' => 'review',
                 'visual' => v['title'] || v['visual_id'], 'pbi_type' => vt,
                 'detail' => "#{vt} has no native Sigma element kind (mapped to #{v['sigma_kind']})",
                 'options' => [approx, 'skip this visual'], 'default' => approx }
end

# (c) import vs DirectQuery / warehouse landing. Sigma is always live-on-warehouse;
# an IMPORT-mode PBI model has cached data, so values may drift vs the warehouse.
if modes.include?('import')
  questions << { 'id' => 'import_vs_directquery', 'severity' => 'review',
                 'detail' => "PBI model partition mode = #{mode_summ}. Sigma queries the warehouse LIVE; " \
                             "an import model's cached values may differ from the live #{opts[:db]}.#{opts[:schema]} table. " \
                             "Confirm the Sigma connection points at the same warehouse the import was sourced from.",
                 'options' => ["land live on connection #{opts[:conn]} (#{opts[:db]}.#{opts[:schema]})",
                               'abort and reconcile the warehouse source first'],
                 'default' => "land live on connection #{opts[:conn]} (#{opts[:db]}.#{opts[:schema]})" }
end

# (c-bis) NON-WAREHOUSE SOURCES — Fabric Dataflow / Lakehouse / OneLake / Dataverse
# / file. The converter can't derive a queryable warehouse path (the data lives
# OUTSIDE the semantic model, and any transform logic in the dataflow/query can't
# be translated) so it emitted placeholder paths that will NOT resolve until the
# data is landed. Offer the land-then-repoint handoff: run the
# powerbi-import-to-snowflake skill to land the data, then re-run Build (Phase 3)
# with convert-model.rb --table-map <manifest.json> (which reads the landing
# manifest directly — see convert-model.rb). Count comes from the converter's
# stats.nonWarehouseSourcedTables; per-table detail is in the ⛔ warnings.
nwt = conv_stats['nonWarehouseSourcedTables'].to_i
if nwt.positive?
  affected = conv_warnings.select { |w| w.include?('is sourced from a') }
                          .map { |w| w[/Table "(.+?)"/, 1] }.compact
  puts "   ⛔ #{nwt} table(s) sourced from a Fabric Dataflow / Lakehouse / Dataverse / file " \
       "— NOT warehouse-queryable; data must be landed before these resolve:"
  affected.each { |t| puts "      - #{t}" }
  land_opt = 'run the powerbi-import-to-snowflake skill to land the data, then re-run Build with ' \
             'convert-model.rb --table-map <manifest.json>'
  questions << {
    'id' => 'non_warehouse_source', 'severity' => 'required',
    'detail' => "#{nwt} table(s) (#{affected.join(', ')}) are sourced from a Fabric Dataflow / " \
                "Lakehouse / OneLake / Dataverse / file — NOT a warehouse Sigma can query, and their " \
                "transformation logic is not in the semantic model. The converter emitted placeholder " \
                "warehouse paths that will NOT resolve until the data is landed and the elements repointed.",
    'options' => [land_opt, 'proceed with placeholder paths (these elements will not resolve until repointed)'],
    'default' => land_opt
  }
end

# (required) connection.
unless opts[:conn]
  questions << { 'id' => 'connection', 'severity' => 'required',
                 'detail' => 'No Sigma --connection supplied; required to point the DM at the warehouse',
                 'options' => ['supply --connection <id>'], 'default' => nil }
end

# RUN-EACH-TIME GAP-SCOUT GATE (). Flagged DAX measures
# (⛔ no-equivalent → degrade to Null; ⚠ restructure-needed) are scout-eligible —
# the gap-scout must ATTEMPT a Sigma translation for each before we accept the
# degradation. --yes does NOT skip this; it only accepts gaps the scout already
# tried (validated locally, or escalated). The scout records each to
# <WORK>/scout-ledger.jsonl via scout-validate.py + lib/scout_gate.py. A
# 'validated' row is honored only when it carries signed live-probe evidence
# (ScoutGate integrity, issue #458): a hand-written or forged 'validated' line is
# treated as unvalidated (→ escalated bucket), so the gate still blocks.
dax_gaps = questions.select { |q| %w[dax_no_equivalent dax_needs_restructure].include?(q['id']) }
unless dax_gaps.empty?
  gid = ->(q) { 'dax:' + q['detail'].to_s.gsub(/\s+/, ' ').strip[0, 80] }
  gap_ids = dax_gaps.map { |q| gid.call(q) }.uniq
  buckets = ScoutGate.classify(WORK, gap_ids)
  if buckets[:unscouted].any?
    unattended = opts[:yes] || opts[:answers]
    if unattended
      # Regression fix (gap-scout PR #153 made this a hard `exit 11` that overrode
      # --yes, stalling the unattended/demo path even for measures the converter
      # already handled). Under --yes/--answers the gate is ADVISORY: these gaps
      # take their "proceed" default (already shown in the decisions list) and the
      # run flows through. Record them as accepted so re-runs don't re-surface them,
      # and recommend the gap-scout for anyone who wants a faithful translation.
      warn "   gap-scout: #{buckets[:unscouted].size} flagged DAX measure(s) not scouted — proceeding (unattended); recording as accepted degradations."
      warn '   (optional: run scripts/gap-scout.md on these to persist a faithful Sigma translation)'
      buckets[:unscouted].each { |id| ScoutGate.record(WORK, gap_id: id, feature: 'dax', status: 'accepted') }
    else
      # Interactive: the same measures already appear as dax_* review questions and
      # exit via the OPEN QUESTIONS block below (exit 10). Just nudge toward the scout.
      puts
      puts '-------------------- GAP-SCOUT RECOMMENDED --------------------'
      puts "#{buckets[:unscouted].size} of #{gap_ids.size} flagged DAX measure(s) have no faithful translation yet:"
      buckets[:unscouted].each { |id| puts "  --gap-id '#{id}'" }
      puts ''
      puts 'Optional: spawn a gap-scout per measure (scripts/gap-scout.md) with the --gap-id above'
      puts "plus --workdir #{WORK} to persist a translation; or re-run with --yes to accept the"
      puts 'degradation defaults. These also appear in OPEN QUESTIONS below.'
      puts '---------------------------------------------------------------'
    end
  else
    puts "   gap-scout: all #{gap_ids.size} flagged DAX measure(s) accounted for (validated or escalated)"
  end
end

answers = nil
if opts[:answers]
  answers = (JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON'))
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'model' => name_slug,
    'phases_completed' => ['1 Discover/Extract', '2 Convert'],
    'note' => 'Deterministic mechanical steps (fixup, master-map, POST, layout, parity) are NOT asked about. ' \
              'Re-run with --yes to accept all defaults, or --answers \'{"<id>":"<choice>"}\' to override.',
    'open_questions' => questions
  }
  puts
  puts '==================== OPEN QUESTIONS ===================='
  puts JSON.pretty_generate(block)
  puts '======================================================='
  puts
  puts "#{questions.size} decision(s) need a human. No Sigma objects were created."
  exit 10
end

if questions.any?
  puts
  puts "   decisions auto-resolved (#{opts[:yes] ? '--yes: defaults' : '--answers supplied'}):"
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    puts "     - #{q['id']}#{q['visual'] ? " [#{q['visual']}]" : ''}: #{chosen}"
  end
else
  puts '   no open questions — running straight through'
end

# Abort if any answer chose an abort/stop option.
chosen_all = questions.map { |q| (answers && answers[q['id']]) || q['default'] }
if chosen_all.any? { |c| c.to_s =~ /\babort\b/i }
  abort "STOP: a decision selected an abort option — not creating any Sigma objects."
end

# ---------------------------------------------------------------------------
# Phase 2.9 — DM-REUSE scan (reuse-first). Runs by DEFAULT before the DM build:
# score the existing Sigma DMs against this model's signature and AUTO-REUSE a
# guaranteed-safe match (same warehouse table(s) + all referenced columns) so we
# don't create a 4th near-identical DM and we skip the build + POST + validate.
# Opt out with --no-reuse; force a specific id with --reuse-dm <id>. Best-effort:
# any failure in the scan falls back to building a new DM — reuse never aborts.
# ---------------------------------------------------------------------------
reuse_dm_id = opts[:reuse_dm]
if reuse_dm_id
  puts
  puts "── Phase 2.9 · DM-reuse (explicit --reuse-dm #{reuse_dm_id}) ──"
  if scoped_tmsl_path
    model_scope['reuse_bypassed'] = reuse_dm_id
    write_model_scope.call
  end
elsif !opts[:no_reuse]
  puts
  puts '── Phase 2.9 · DM-reuse scan ──'
  begin
    sig_path   = File.join(WORK, 'dm-signature.json')
    match_path = File.join(WORK, 'dm-match.json')
    # Signature is parsed from the TMSL/model.bim (warehouse FQNs from the M
    # partition expressions). Best-effort — tolerate a non-zero exit.
    _so, _ss = Open3.capture2e(*PY_ARGV, File.join(HERE, 'pbi-dm-signature.py'),
                               '--bim', scoped_tmsl_path || opts[:tmsl], '--out', sig_path)
    _so.each_line { |l| puts "   #{l.rstrip}" } unless _so.strip.empty?
    if File.exist?(sig_path)
      # find-or-pick-dm.rb exits non-zero when no candidate qualifies; that is
      # NORMAL (build-new), so don't treat the exit code as fatal.
      Open3.capture2e(ENV.to_h, 'ruby', File.join(HERE, 'find-or-pick-dm.rb'),
                      '--workbook-signature', sig_path, '--out', match_path,
                      '--auto-pick', '--auto-pick-threshold', '0.5')
    end
    match = (File.exist?(match_path) ? JSON.parse(File.read(match_path)) : {}) || {}
    scope_guard_refused = false
    if scoped_tmsl_path && match['auto_picked'] && match['recommended_dm_id']
      cand = (match['candidates'] || []).find { |c| c['dm_id'] == match['recommended_dm_id'] }
      baseline = (dm_model['pages'] || []).flat_map { |pg| pg['elements'] || [] }.size
      model_scope['auto_pick_baseline'] = baseline
      write_model_scope.call
      if cand && !PbiModelScope.auto_pick_allowed?(cand, baseline)
        puts "   candidate #{cand['dm_name']} [#{cand['dm_id']}] has #{cand['raw_element_count']} elements - " \
             "larger than this report needs (#{baseline}); building a new scoped DM"
        scope_guard_refused = true
      end
    end
    if match['auto_picked'] && match['recommended_dm_id'] && !scope_guard_refused
      reuse_dm_id = match['recommended_dm_id']
      puts "   DM-REUSE (auto): #{match['rationale']}"
      puts "   ⚠ #{match['warning']}" if match['warning']
    else
      top = (match['candidates'] || []).first(3)
      if top.any?
        puts "   no auto-safe match (#{match['rationale'] || 'below threshold'}) — building a new DM. Top candidate(s):"
        top.each { |c| puts "     - #{c['dm_name']} [#{c['dm_id']}] score=#{c['score']}" }
      else
        puts "   no reuse candidate (#{match['rationale'] || 'none scored'}) — building a new DM"
      end
    end
  rescue StandardError => e
    puts "   [warn] DM-reuse scan skipped (#{e.message[0, 120]}) — building a new DM"
    reuse_dm_id = nil
  end
end

# ---------------------------------------------------------------------------
# Phase 3 — Build data model (fixups + validate + POST + readback) — OR reuse an
# existing DM (skip the build entirely; read its spec back instead).
# ---------------------------------------------------------------------------
hdr(3, TOTAL, 'Build data model')

if reuse_dm_id
  # REUSE PATH — skip convert-model.rb / validate / POST. GET the existing DM's
  # spec once and derive the SAME downstream variables the build path produces:
  #   dm_id    — the reused dataModelId
  #   dm_spec  — full spec file (Phase 4 reads columns[].name + folderId from it)
  #   dm_model — the spec itself (conv_elements is read from dm_model['pages'])
  #   dm_rb    — readback-shaped {dataModelId, pages[].elements[]{id,name}}
  # If anything here fails, fall back to building a new DM (reuse never aborts).
  begin
    require 'sigma_rest'
    spec = Sigma.request(:get, "/v2/dataModels/#{reuse_dm_id}/spec")
    spec = JSON.parse(spec) if spec.is_a?(String)
    raise 'no pages in reused DM spec' unless spec.is_a?(Hash) && spec['pages']
    dm_id   = reuse_dm_id
    dm_spec = File.join(WORK, 'dm-spec.json')
    File.write(dm_spec, JSON.pretty_generate(spec))
    dm_model = spec                                   # conv_elements reads dm_model['pages']
    dm_rb = {
      'dataModelId' => dm_id,
      'pages' => (spec['pages'] || []).map do |p|
        { 'id' => p['id'], 'name' => p['name'], 'visibility' => p['visibility'],
          'elements' => (p['elements'] || []).map { |e| { 'id' => e['id'], 'name' => e['name'] } } }
      end
    }
    File.write(File.join(WORK, 'dm-readback.json'), JSON.pretty_generate(dm_rb))
    n_el = dm_rb['pages'].flat_map { |p| p['elements'] || [] }.size
    puts "   REUSING dataModelId = #{dm_id} (#{n_el} element(s)) — convert + POST skipped"
    if opts[:page_facts] && integrate_page_facts_dm!(opts, dm_spec, check: true) == :changed
      # The reused DM lacks (or has stale) page-fact elements. Changing a shared, existing data model
      # is the user's call: say so and stop unless --page-facts-update-dm was given.
      unless opts[:page_facts_update_dm]
        puts
        puts '==================== OPEN QUESTIONS ===================='
        puts "   [required] page_facts_reused_dm: the reused data model #{dm_id} does not carry the page facts in"
        puts "              #{opts[:page_facts]}. Rerun with --page-facts-update-dm to PUT them into it, or with"
        puts '              --no-reuse to build a new data model that includes them.'
        exit 10
      end
      abort 'FATAL: --page-facts-update-dm needs --connection (the page-fact SQL elements run on it)' unless opts[:conn]
      integrate_page_facts_dm!(opts, dm_spec)
      if opts[:stop_before_post]
        puts "   page facts: would PUT them into reused data model #{dm_id} (--stop-before-post: not written)"
        raise StopBeforePostPageFacts
      end
      _put_rb = File.join(WORK, 'dm-readback.json')
      run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel', '--spec', dm_spec,
            '--out', _put_rb, '--workdir', WORK, '--update-id', dm_id], env: ENV.to_h)
      dm_rb = JSON.parse(File.read(_put_rb))
      dm_model = JSON.parse(File.read(dm_spec))
      puts "   page facts: PUT into reused data model #{dm_id}"
    end
    if opts[:stop_before_post]
      # --stop-before-post means NOTHING is created in Sigma on ANY path: the reuse path would go
      # on to build and POST the workbook in Phase 4. A draft-only page-fact run stops here too.
      scaffold_page_facts!(opts, scoped_tmsl_path || opts[:tmsl], signals_path, dm_spec, nil, PbiProbeGate.dialect_for(opts[:wh_type])) if opts[:scaffold_page_facts]
      puts
      puts "STOP BEFORE POST: would reuse existing data model #{dm_id} (spec read back -> #{dm_spec})"
      puts '   no Sigma objects were created; rerun without --stop-before-post to build the workbook on it'
      exit 0
    end
  rescue StopBeforePostPageFacts
    scaffold_page_facts!(opts, scoped_tmsl_path || opts[:tmsl], signals_path, dm_spec, nil, PbiProbeGate.dialect_for(opts[:wh_type])) if opts[:scaffold_page_facts]
    puts
    puts "STOP BEFORE POST: would reuse existing data model #{dm_id} with the page facts added (spec -> #{dm_spec})"
    puts '   no Sigma objects were created or changed; rerun without --stop-before-post to PUT and build the workbook'
    exit 0
  rescue StandardError => e
    puts "   [warn] could not read reused DM #{reuse_dm_id} (#{e.message[0, 120]}) — building a new DM instead"
    reuse_dm_id = nil
  end
end

unless reuse_dm_id
# Pre-fixup: the converter emits base warehouse-table columns with NO `name`
# (Sigma derives the display name from the source column at POST time). But
# validate-spec.rb resolves sibling refs by `name`, and a metric like
# `Sum([Sales])` then fails ("[Sales] not a sibling column"). So stamp each
# base column's display name from its own formula ([Tbl/Sales] -> "Sales")
# before convert-model.rb runs. Idempotent: only fills a missing/empty name.
raw_dm = JSON.parse(File.read(File.join(WORK, 'dm-raw.json')))
named_cols = 0
(raw_dm['pages'] || []).each do |pg|
  (pg['elements'] || []).each do |el|
    # Bug E: SQL elements synthesized from a DAX CALENDAR/VALUES calc-table
    # (DimDate, DimMonth, SalaryBands) ALSO need their columns named — their
    # follow-on calc columns reference siblings by bare [ColAlias], which
    # error-type if the referenced column has no display name. Previously only
    # warehouse-table (source.path) elements were stamped.
    is_warehouse = !el.dig('source', 'path').nil?
    is_sql       = el.dig('source', 'kind') == 'sql'
    next unless is_warehouse || is_sql
    (el['columns'] || []).each do |c|
      next if c['name'] && !c['name'].to_s.empty?
      f  = c['formula'].to_s
      dn = f.gsub(/^\[|\]$/, '').split('/')[-1]
      next if dn.to_s.empty?
      # Bug E (SQL elements): a SQL-OUTPUT column has a bare self-referencing
      # formula `[Date]` that maps to the SQL `AS "Date"` alias. Stamping
      # name="Date" on it makes `[Date]` a CIRCULAR reference -> error-type. Only
      # stamp a name when the formula is NOT a bare self-reference (i.e. a
      # follow-on calc column like `Year([Date])`), so its siblings can ref it,
      # while leaving SQL-output columns nameless to bind to their alias.
      if is_sql
        bare_self = (f =~ /\A\[[^\]\/]+\]\z/) && (f.gsub(/^\[|\]$/, '') == dn)
        next if bare_self
      end
      c['name'] = dn
      named_cols += 1
    end
  end
end
File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(raw_dm))
puts "   pre-fixup: named #{named_cols} base column(s) from their formula" if named_cols.positive?

dm_spec = File.join(WORK, 'dm-spec.json')
fixup = ['ruby', File.join(HERE, 'convert-model.rb'),
         '--converter-out', File.join(WORK, 'dm-raw.json'),
         '--out', dm_spec, '--name', WB_NAME.sub(/\(from Power BI\)\s*$/, 'DM (from Power BI)')]
if opts[:folder]
  # caller gave an explicit folder; still need an owner — harvest from ref-dm if
  # present, else resolve the current user via whoami. Without this, a build-new
  # (e.g. after DM-reuse correctly DECLINES an ambiguous wide-tie of look-alike
  # DMs — see find-or-pick-dm.rb) aborts with "need --ref-dm or --owner-id".
  fixup += ['--folder-id', opts[:folder]]
  if opts[:ref_dm]
    fixup += ['--ref-dm', opts[:ref_dm]]
  else
    begin
      require_relative 'lib/sigma_rest'
      uid = Sigma.request(:get, '/v2/whoami')['userId']
      fixup += ['--owner-id', uid] if uid && !uid.empty?
    rescue StandardError => e
      warn "   [warn] whoami owner-resolve failed (#{e.message[0, 80]}) — build-new may need --ref-dm/--owner-id"
    end
  end
elsif opts[:ref_dm]
  fixup += ['--ref-dm', opts[:ref_dm]]
else
  abort 'FATAL: need --ref-dm (to harvest folderId/ownerId) or --folder plus a --ref-dm for ownerId'
end
run!(fixup, env: ENV.to_h)
if opts[:page_facts]
  abort 'FATAL: --page-facts needs --connection (the page-fact SQL elements run on it)' unless opts[:conn]
  integrate_page_facts_dm!(opts, dm_spec)
end
run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec])
if opts[:stop_before_post]
  scaffold_page_facts!(opts, scoped_tmsl_path || opts[:tmsl], signals_path, dm_spec, nil, PbiProbeGate.dialect_for(opts[:wh_type])) if opts[:scaffold_page_facts]
  # Offline iteration mode for large models: everything up to and including the
  # DM spec validation ran (extract, scope, convert, NativeQuery restore,
  # name-sanitize, dm-resolver, --probe-sources). Nothing has been created in
  # Sigma; rerun without the flag (same --out: extraction is cached) to POST.
  puts
  puts "STOP BEFORE POST: data model spec is ready and validated -> #{dm_spec}"
  puts '   no Sigma objects were created; rerun without --stop-before-post to post it'
  exit 0
end
dm_readback = File.join(WORK, 'dm-readback.json')
# DM POST — captured (not run!) so an unreadable-table failure surfaces a concrete
# GRANT action instead of an opaque 400 (customer feedback 2026-07-17).
_dm_post = ['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
            '--spec', dm_spec, '--out', dm_readback, '--workdir', WORK]
_dm_out, _dm_st = Open3.capture2e(ENV.to_h, *_dm_post)
_dm_out.each_line { |l| puts "   #{l.rstrip}" } unless _dm_out.strip.empty?
unless _dm_st.success?
  hint = explain_unreadable_tables(_dm_out, dm_spec, opts[:conn])
  if hint
    warn ''
    warn '   ┌─ UNREADABLE WAREHOUSE TABLE(S): the data-model POST failed because the'
    warn '   │  connection cannot read one or more source tables — almost always a missing GRANT:'
    warn hint
    warn '   └─ grant the schema(s) above to the connection (or drop those tables/visuals), then re-run.'
  end
  abort "FATAL: data model POST failed (#{_dm_st.exitstatus})."
end
dm_rb = JSON.parse(File.read(dm_readback))
dm_id = dm_rb['dataModelId']
puts "   dataModelId = #{dm_id}"
end # unless reuse_dm_id (build-new path)

# Optional data-model materialization schedules (Beta). Run after readback so
# schedule calls use authoritative server element IDs. This is performance-only:
# failures are recorded and surfaced but do not invalidate the migrated model.
if opts[:materialization_cron]
  spec_elements = (dm_model['pages'] || []).flat_map { |page| page['elements'] || [] }
  readback_elements = (dm_rb['pages'] || []).flat_map { |page| page['elements'] || [] }
  paired = PbiElementMatch.pair(spec_elements, readback_elements)
  sql_with_readback = spec_elements.each_with_index.filter_map do |element, index|
    next unless element.dig('source', 'kind') == 'sql'
    server = paired[index]
    next unless server
    [element, { 'id' => server['id'], 'name' => server['name'] || element['name'] || element['id'] }]
  end

  selectors = opts[:materialization_elements].to_s.split(',').map(&:strip).reject(&:empty?)
  selected =
    if selectors.empty? || selectors == ['all-sql']
      sql_with_readback
    else
      sql_with_readback.select do |spec_element, server|
        selectors.include?(spec_element['name'].to_s) || selectors.include?(server['name'].to_s)
      end
    end

  missing = selectors.reject do |selector|
    selector == 'all-sql' || sql_with_readback.any? do |spec_element, server|
      selector == spec_element['name'].to_s || selector == server['name'].to_s
    end
  end
  actions = missing.map do |selector|
    {
      'elementName' => selector,
      'status' => 'error',
      'error' => 'requested materialization element was not found among Custom SQL elements',
      'remediation' => 'use an exact Custom SQL element name or all-sql'
    }
  end

  if selected.empty?
    puts '   materialization: no matching Custom SQL elements'
  else
    puts "   materialization: reconciling #{selected.size} Custom SQL schedule(s)"
    actions.concat(
      MaterializationSchedules.reconcile(
        data_model_id: dm_id,
        elements: selected.map(&:last),
        cron: opts[:materialization_cron],
        timezone: opts[:materialization_timezone]
      )
    )
  end
  File.write(File.join(WORK, 'materialization-actions.json'), JSON.pretty_generate(actions))
  actions.each do |action|
    if action['status'] == 'error'
      warn "   [warn] materialization #{action['elementName']}: #{action['error'].to_s.lines.first.to_s.strip[0, 140]}"
      warn "          remediation: #{action['remediation']}"
    else
      puts "   materialization #{action['status']}: #{action['elementName']}"
    end
  end
end

# ---------------------------------------------------------------------------
# Phase 4 — Build workbook (auto master-map from converter + signals, then build+POST)
# ---------------------------------------------------------------------------
# Last line of defence for --stop-before-post: both DM paths above exit before reaching here, but the
# workbook POST (and everything after it) must never run under the flag whatever path led here.
if opts[:stop_before_post]
  puts
  puts 'STOP BEFORE POST: not building or posting the workbook (--stop-before-post)'
  puts '   no Sigma objects were created by the workbook phase'
  exit 0
end
hdr(4, TOTAL, 'Build workbook')

# --- derive the master-map deterministically ---
# Converter element: name (= warehouse table) + columns (formula [Tbl/Display]) + metrics.
# The DM readback element name is authoritative (PUT may rename); match by name.
conv_elements = (dm_model['pages'] || []).flat_map { |p| p['elements'] || [] }
dm_elements = dm_rb['pages'].flat_map { |p| p['elements'] || [] }

# Display-name helper: a column formula "[Tbl/Order Id]" -> "Order Id".
disp = lambda { |formula| formula.to_s.gsub(/^\[|\]$/, '').split('/')[-1] }

# Bug A: For a JOIN/View element, columns carry the FULL cross-element ref path
# in their formula — e.g. "[ORDER_FACT/Customer Key]" (own column) AND
# "[ORDER_FACT/CUSTOMER_DIM/Customer Key]" (related column). Both leaf-resolve to
# "Customer Key", so keying the master-column id/name on the leaf produces a
# COLLISION (duplicate ids + duplicate names) and the workbook POST fails.
# These helpers reproduce Sigma's own disambiguation:
#   - the Sigma DISPLAY NAME of a related col is "Customer Key (CUSTOMER_DIM)"
#     (leaf + " (relName)") — matches the converter's viewColDisplay().
#   - the master-column ID keys on the FULL path so it is unique per column.
sigma_view_disp = lambda do |formula|
  parts = formula.to_s.gsub(/^\[|\]$/, '').split('/')
  parts.length <= 2 ? parts[-1] : "#{parts[-1]} (#{parts[-2]})"
end
# The path INSIDE the element (drop the element-name prefix), used as the master
# column's resolving formula, e.g. "[mid/CUSTOMER_DIM/Customer Key]".
inner_path = lambda do |formula|
  parts = formula.to_s.gsub(/^\[|\]$/, '').split('/')
  parts.length <= 1 ? parts[0].to_s : parts[1..].join('/')
end

# Build one master per converter element. master id is "master-<elementId-tail>".
# The POSTED dm-spec is the column display-name AUTHORITY: convert-model.rb's
# pre-fixup names bare columns from their formula (e.g. [Custom SQL/ANNUAL_SALARY]
# -> "Annual Salary"), and workbook refs resolve by that DISPLAY name. Deriving
# the name from the converter formula leaf alone left raw ALIASES on SQL-element
# masters ([Dense Rank DEPARTMENT/ANNUAL_SALARY] -> "Dependency not found").
spec_elements = begin
  (JSON.parse(File.read(dm_spec))['pages'] || []).flat_map { |p| p['elements'] || [] }
rescue StandardError
  []
end
masters = {}
field_map = {}
# Pair each converter element to its posted-DM readback element. A DM POST does
# NOT preserve element order (it floats nameless Custom SQL elements to the front),
# so this is NOT a positional index — see lib/pbi_element_match.rb for the full
# rationale + the run-2 SAFETY_INCIDENTS overwrite it prevents.
dmel_for = PbiElementMatch.pair(conv_elements, dm_elements)
# element index -> {table, confidence}. ORDER is authoritative (the converter emits one
# element per model table in table order); the column-set overlap is a CONFIDENCE signal
# only — making it authoritative measured WORSE than the old behaviour on 4 real models.
_pbi_tbl_for = PbiMasterKey.pbi_table_for_elements(conv_elements, tables)
_rp_dupes = _pbi_tbl_for.values.map { |v| v['table'] }.compact
             .group_by { |n| n }.select { |_n, g| g.size > 1 }
_lowconf = _pbi_tbl_for.values.select { |v| v['table'] && v['confidence'] < 0.8 }
unless _lowconf.empty?
  puts "   master-map: #{_lowconf.size} element(s) attributed by ORDER with low column agreement " \
       "(#{_lowconf.map { |v| "#{v['table']} #{(v['confidence'] * 100).round}%" }.first(4).join(', ')}) — " \
       'the converter adds columns the model lacks, so this is usually benign; verify if a tile looks wrong.'
end
_rp_groups = tables.group_by { |t| PbiMasterKey.norm_table(PbiMasterKey.physical_tail(t).to_s) }
                   .select { |k, g| !k.empty? && g.size > 1 }
unless _rp_groups.empty?
  puts "   master-map: #{_rp_groups.size} role-playing dimension group(s) kept DISTINCT " \
       "(#{_rp_groups.map { |k, g| "#{g.size}x #{k}" }.join(', ')}) — previously collapsed into one master."
end
conv_elements.each_with_index do |cel, cel_idx|
  cname = cel['name']
  dmel = dmel_for[cel_idx]
  cname ||= (dmel && dmel['name']) || 'Custom SQL'
  # POSTED-spec column display names for this element (matched the same way the
  # dm element was), keyed by formula — overrides the formula-leaf derivation.
  spec_el = (cel['name'] && spec_elements.find { |e| e['name'] == cel['name'] }) ||
            spec_elements[cel_idx]
  spec_name_for = (spec_el && spec_el['columns'] || [])
                  .each_with_object({}) { |c, h| h[c['formula'].to_s] = c['name'] if c['name'] }
  # ROLE-PLAYING DIMENSIONS. `cname` is the WAREHOUSE table (the converter names every
  # element after it), so a model importing the same table N times under N names — six
  # role-playing DATE_DIMs on real report R2 — collapsed into ONE master here:
  # masters[mkey] overwrote (last copy won) and all N shared one id, while the report's
  # visuals bind under the PBI name ("DATE_DIM submission date.CALENDAR_DATE"), a key
  # that never existed. Key on the PBI table instead; fall back to `cname` when the
  # element cannot be attributed, which is exactly the old behaviour.
  _pbi_tbl = _pbi_tbl_for[cel_idx] && _pbi_tbl_for[cel_idx]['table']
  mkey = _pbi_tbl || cname
  mid  = PbiMasterKey.master_id(mkey)
  # Bug A: key the master-column id on the FULL cross-element path (not the leaf)
  # and use Sigma's disambiguated display name. For a JOIN/View element, base and
  # related columns can share a leaf ("Customer Key"), so leaf-keying collides on
  # both id AND name -> duplicate columns -> workbook POST fails. The master table
  # element sources from the DM element (named `cname`); the DM element exposes a
  # related column under its disambiguated display name "Leaf (RelName)", so the
  # master column's formula references THAT display name on `cname`. Dedupe by the
  # full path so each underlying column yields exactly one master column.
  seen_paths = {}
  cols = (cel['columns'] || []).map do |c|
    # If the converter already stamped a display `name` (calc/derived/time-intel
    # columns), trust it — the column's formula is an expression, NOT a bare
    # [El/Col] ref, so formula-parsing would mangle the name (Bug C side effect).
    # Bug A formula-path keying applies ONLY to bare [El/.../Col] reference cols.
    bare_ref = c['formula'].to_s =~ /\A\[[^\]]+\]\z/
    if c['name'] && !c['name'].to_s.empty? && !bare_ref
      dn  = c['name'].to_s
      key = "#{cname}/calc/#{dn}"
      next nil if seen_paths[key]
      seen_paths[key] = true
      next({ 'id' => "mc-#{Digest::SHA1.hexdigest(key)[0, 10]}", 'name' => dn,
             'formula' => "[#{cname}/#{dn}]", '_leaf' => dn })
    end
    full = c['formula'].to_s.gsub(/^\[|\]$/, '')         # e.g. ORDER_FACT/CUSTOMER_DIM/Customer Key
    next nil if full.empty? || seen_paths[full]
    seen_paths[full] = true
    # the POSTED spec's display name wins (it's what workbook refs resolve by);
    # fall back to Sigma's own derivation from the formula path.
    dn   = spec_name_for[c['formula'].to_s] ||
           sigma_view_disp.call(c['formula'])            # "Customer Key (CUSTOMER_DIM)"
    { 'id' => "mc-#{Digest::SHA1.hexdigest("#{cname}/#{full}")[0, 10]}", 'name' => dn,
      'formula' => "[#{cname}/#{dn}]", '_leaf' => disp.call(c['formula']) }
  end.compact
  # column field refs: queryRef "Entity.Col" -> {master, ref:[mid/Name], agg:null}.
  # Map both the disambiguated name AND the bare leaf (PBIR queryRefs use the leaf
  # when the dim column is unambiguous in the original model) so bindings resolve.
  cols.each do |c|
    ref = { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
    field_map["#{cname}.#{c['name']}"] = ref
    field_map["#{cname}.#{c['_leaf']}"] ||= ref
  end
  cols.each { |c| c.delete('_leaf') } # internal-only; keep master columns clean
  # DM metrics (name + ORIGINAL bare formula, e.g. Sum([Net Revenue])) so the
  # workbook builder can bind a measure to a governed [Metrics/<name>] ref instead
  # of re-deriving the aggregation inline: it strips the `mid` prefix off the
  # emitted formula and matches by formula equivalence (shared binder). Kept bare
  # (not the [mid/…]-rewritten measure ref) so the strip+match lines up.
  metrics_for_master = (cel['metrics'] || []).map { |mm| { 'name' => mm['name'], 'formula' => mm['formula'] } }
  masters[mkey] = { 'id' => mid, 'element_id' => dmel['id'], 'data_model' => dm_id,
                    'columns' => cols, 'metrics' => metrics_for_master }
  # measure field refs: a translated metric "Sum([Sales])" -> rewrite bare col refs
  # to the master, set agg=null and pass the FULL formula as `ref` (build script
  # uses ref verbatim when agg is nil — handles ratios like DIVIDE too).
  #
  # Bug D: a metric formula may reference ANOTHER metric by name, e.g.
  #   Sales per Order = [Total Sales] / [Orders]
  # where Total Sales = Sum([Sales]) and Orders = CountDistinct([Order Id]).
  # Naively rewriting [Total Sales] -> [mid/Total Sales] points at a NON-EXISTENT
  # master column (metrics are formulas, not stored columns), and Sigma rejects
  # the dependency. Fix: substitute the referenced metric's FULL formula INLINE.
  # Stored master-column names ARE valid [mid/Name] refs; only metric-name refs
  # are inlined. Resolve recursively (with a guard) so chained metrics collapse.
  master_col_names = cols.map { |c| c['name'] }.to_set
  metric_by_name   = {}
  (cel['metrics'] || []).each { |mm| metric_by_name[mm['name'].to_s] = mm['formula'].to_s }
  resolve_metric = lambda do |formula, depth|
    formula.to_s.gsub(/\[([^\/\]]+)\]/) do
      ref = Regexp.last_match(1)
      if master_col_names.include?(ref)
        "[#{mid}/#{ref}]"                                   # real stored column
      elsif metric_by_name.key?(ref) && depth < 16
        "(#{resolve_metric.call(metric_by_name[ref], depth + 1)})" # inline the metric
      else
        "[#{mid}/#{ref}]"                                   # bare column ref (e.g. Sum([Sales]))
      end
    end
  end
  (cel['metrics'] || []).each do |m|
    rewritten = resolve_metric.call(m['formula'].to_s, 0)
    # Converter gap (live 2026-06-12): DAX SEARCH/FIND translate with their
    # start argument, but Sigma's Find() takes only (text, search) — a third
    # arg compiles the column to type "error" (verified: dropping it fixes).
    # Strip a trailing integer start arg until the converter is fixed.
    rewritten = rewritten.gsub(/\bFind\((\[[^\]]+\]|"[^"]*")\s*,\s*(\[[^\]]+\]|"[^"]*")\s*,\s*\d+\s*\)/, 'Find(\1, \2)')
    ref = { 'master' => mkey, 'ref' => rewritten, 'agg' => nil,
            'format' => (m.dig('format', 'formatString')) }
    field_map["#{cname}.#{m['name']}"] = ref
    # 2a ([bead]): a measure re-homed from a measure-only table onto the
    # fact element (powerbi.ts moveMeasures) is keyed here under the FACT element,
    # but the PBIR visual still binds it under its ORIGINAL measures-table entity
    # ("_Measures.TotalSales"). Alias it so the binding resolves — mirrors
    # ti_orig_table (below) / the calc-table Bug-E alias. Guarded (`||=` + orig !=
    # cname) so a converter-DROPPED measure is never fabricated, and a fact-native
    # measure is a no-op.
    orig = measure_orig_table[m['name']]
    field_map["#{orig}.#{m['name']}"] ||= ref if orig && orig != cname
  end
end

# Bug E (queryRef routing): a DAX calc-table (DimDate / SalaryBands / DimMonth)
# becomes a NAMELESS Custom SQL element (master keyed "Custom SQL"), but the PBIR
# chart still binds it under its ORIGINAL table name ("DimDate.Month"). Alias the
# original calc-table name + each column onto the Custom SQL master so those
# bindings resolve. The calc table is identified from the TMSL (partition source
# type 'calculated'); its column display names match the Custom SQL master cols.
calc_tables = tables.select do |t|
  Array(t['partitions']).any? { |p| p.dig('source', 'type') == 'calculated' }
end
# A Custom SQL master is recognizable by its column formulas using the
# `[Custom SQL/...]` prefix (the converter emits that for SQL-element columns).
sql_masters = masters.select do |_n, m|
  (m['columns'] || []).any? { |c| c['formula'].to_s.start_with?('[Custom SQL/') }
end
calc_tables.each do |t|
  orig = t['name'].to_s
  # pick the SQL master whose columns best cover this calc table's columns.
  tcols = (t['columns'] || []).reject { |c| c['type'] == 'rowNumber' || c['isGenerated'] }
                              .map { |c| (c['sourceColumn'] || c['name']).to_s.gsub(/^\[|\]$/, '') }
  best = sql_masters.max_by do |_n, m|
    names = (m['columns'] || []).map { |c| c['name'].to_s }
    tcols.count { |tc| names.any? { |n| n.casecmp?(tc) || n.gsub(/\s+/, '').casecmp?(tc.gsub(/\s+/, '')) } }
  end
  next unless best
  bmkey, bm = best
  (bm['columns'] || []).each do |c|
    ref = { 'master' => bmkey, 'ref' => "[#{bm['id']}/#{c['name']}]", 'agg' => nil }
    field_map["#{orig}.#{c['name']}"] ||= ref
  end
end

# Bug A (star schema): register a "<FACT> View" ALT for every field the joined View
# element also exposes, so a cross-table visual (dim from one table + fact measure)
# resolves on ONE master. Friendly PBI table names are mapped to the physical names the
# View uses. See lib/pbi_view_route.rb.
PbiViewRoute.add_view_alts!(field_map, masters, conv_elements, tables)

# Bind original source column spelling, including camelCase, to the unique
# readback-confirmed field. Do not let punctuation/case normalization pick an
# arbitrary column when two real fields normalize to the same name.
PbiMasterKey.add_column_aliases!(field_map, tables)

# Bug C: time-intel forwarding. The converter turns DAX SAMEPERIODLASTYEAR /
# TOTALYTD measures into NEW DM elements (source.kind=='table' sourcing another
# element, carrying DateLookback / CumulativeSum columns). Those elements get a
# master built above, but the ORIGINAL PBI queryRef ("ORDER_FACT.Net Revenue PY"
# / "ORDER_FACT.YoY %") still points at the fact table, where the measure no
# longer exists -> the workbook chart resolves no master -> emits source:{} and
# the POST fails with "Invalid value: undefined". Add synthetic field_map entries
# routing "<OrigTable>.<MeasureName>" -> the new element's computed column.
#   measure name -> original TMSL table (from Phase 1's all_measures).
ti_orig_table = {}
all_measures.each { |tbl, mname, _expr| ti_orig_table[mname] = tbl }
# converter element id -> name, so a synthesized time-intel element can report the
# FACT it was built from (its source View's table) — used to stop the fallback
# router from cross-wiring a measure to an unrelated fact's time-intel element.
conv_name_by_id = conv_elements.each_with_object({}) { |e, h| h[e['id']] = e['name'] }
# collect the emitted time-intel elements (element-sourced, DateLookback/CumulativeSum).
ti_elements = []
conv_elements.each do |cel|
  src = cel['source'] || {}
  next unless src['kind'] == 'table' && src['elementId'] # element sourced from another element
  cols = cel['columns'] || []
  is_time_intel = cols.any? { |c| c['formula'].to_s =~ /\b(DateLookback|CumulativeSum)\s*\(/ }
  next unless is_time_intel
  mname = cel['name'].to_s            # converter names the element after the measure
  mkey  = mname
  next unless masters[mkey]           # its master was built in the loop above
  mid   = masters[mkey]['id']
  # pick the headline computed column: prior-year / YTD / YoY %, falling back to
  # the last column (the converter appends the derived measure last).
  pick = cols.find { |c| c['formula'].to_s =~ /\bDateLookback\s*\(/ } ||
         cols.find { |c| c['formula'].to_s =~ /\bCumulativeSum\s*\(/ } ||
         cols.find { |c| c['name'].to_s =~ /YoY/i } || cols.last
  next unless pick
  # bead 525l: a SINGLE-VALUE KPI bound to this measure must NOT receive a bare
  # row-level ref (agg:nil) into the GROUPED element — Sigma evaluates an
  # unaggregated ref over a multi-row (one-per-period) element nondeterministically
  # (null / arbitrary row). Emit an explicit deterministic "latest period" headline
  # formula via the builder's verbatim-formula hook (measure_formula):
  #   Sum(If([mid/<dateCol>] = Max([mid/<dateCol>]), [mid/<col>], Null))
  # In a chart grouped BY that date column the same formula still evaluates to the
  # per-period value (within each group Max(date)=date), so it is safe for both
  # the KPI and the date-grouped chart paths. The date col = the element's groupBy.
  group_ids = (cel['groupings'] || []).flat_map { |g| g['groupBy'] || [] }
  date_col  = cols.find { |c| group_ids.include?(c['id']) } ||
              cols.find { |c| c['formula'].to_s =~ /\bDateTrunc\s*\(/ } ||
              cols.find { |c| c['name'].to_s =~ /\A(Year|Quarter|Month|Week|Date|Day)\z/i }
  headline = lambda do |colname|
    next nil unless date_col
    "Sum(If([#{mid}/#{date_col['name']}] = Max([#{mid}/#{date_col['name']}]), [#{mid}/#{colname}], Null))"
  end
  ti_fact = PbiTimeIntelRoute.fact_of(conv_name_by_id[src['elementId']])
  ti_elements << { 'name' => mname, 'mid' => mid, 'cols' => cols,
                   'date' => (date_col && date_col['name']), 'fact' => ti_fact }
  ref = { 'master' => mkey, 'ref' => "[#{mid}/#{pick['name']}]", 'agg' => nil }
  hf = headline.call(pick['name'])
  ref['formula'] = hf if hf
  orig = ti_orig_table[mname]
  route_table = PbiTimeIntelRoute.routing_table(orig, ti_fact)
  # route both the original-table queryRef and a self-named queryRef so whichever
  # form the PBIR binding used resolves to this element.
  field_map["#{orig}.#{mname}"] = ref if orig
  field_map["#{mname}.#{mname}"] ||= ref
  # also map any YoY % / Prior Year / YTD sibling column by its own name on the orig table.
  cols.each do |c|
    next unless c['name'].to_s =~ /YoY|Prior Year|YTD/i
    sub = { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
    shf = headline.call(c['name'])
    sub['formula'] = shf if shf
    field_map["#{orig}.#{c['name']}"] ||= sub if orig
  end
  # A chart that puts a PY/YoY column next to the BASE value and the period
  # dimension (e.g. Year × Net Revenue × Net Revenue PY) must source from THIS
  # grouped element — the View lacks the PY column. Register ALTS so those
  # sibling fields can ALSO resolve here: the grouped value is already aggregated,
  # so it is referenced as a PLAIN column (no extra Sum). visual_master then
  # majority-picks this element and field_spec swaps in the alt ref.
  base_val  = cols.find { |c| c['formula'].to_s =~ /\b(Sum|Avg|Count|CountDistinct|Min|Max)\s*\(/ }
  period_cols = cols.select { |c| c['name'].to_s =~ /\b(Year|Month|Quarter|Day|Date|Week)\b/i }
  reg_alt = lambda do |qr, colname|
    next unless field_map[qr] && colname
    (field_map[qr]['alts'] ||= []) << { 'master' => mkey, 'ref' => "[#{mid}/#{colname}]", 'agg' => nil }
  end
  if base_val
    # the base value measure under the orig table (any measure whose formula is an
    # aggregation of the same value column the PY/YTD element sums). Compare with
    # whitespace stripped from BOTH sides so "Net Revenue" matches "[Net Revenue]".
    valleaf  = base_val['name']
    valnorm  = valleaf.gsub(/\s+/, '').downcase
    all_measures.each do |t2, m2, e2|
      next unless t2 == route_table
      enorm = e2.to_s.gsub(/\s+/, '').downcase
      agg_of_val = enorm =~ /(sum|average|avg|min|max|count|distinctcount)\([^)]*#{Regexp.escape(valnorm)}/
      reg_alt.call("#{route_table}.#{m2}", valleaf) if agg_of_val || m2 == valleaf
    end
  end
  # The grouped element carries period dimension column(s) (Year and/or Month).
  # A chart that plots the time-intel measure BY one of those periods must source
  # from this element, so register each period column as an alt under the common
  # date-dim queryRef forms (the calc-table date dim is the usual binding source).
  period_cols.each do |pc|
    %w[DATE_DIM DimDate DimMonth Date].each { |dt| reg_alt.call("#{dt}.#{pc['name']}", pc['name']) }
    reg_alt.call("#{route_table}.#{pc['name']}", pc['name'])
  end
end

# Bug C (continued): OTHER time-intel measures (e.g. a standalone "YoY %" using a
# hand-rolled MAX/ALL prior-year pattern) may NOT get their own element — the
# converter folds the YoY computation into the prior-year element's "... YoY %"
# column. Any such measure still has a live PBI queryRef ("ORDER_FACT.YoY %")
# the chart binds, but no field_map entry -> source:{} -> POST fails. Route every
# remaining time-intel-shaped measure to the best-matching time-intel column.
if ti_elements.any?
  all_measures.each do |tbl, mname, expr|
    next if field_map.key?("#{tbl}.#{mname}")
    # time-intel-shaped: a DAX time-intel function, OR a YoY/growth name, OR a
    # hand-rolled MAX(...)/ALL(...) prior-year ratio.
    shape = PbiTimeIntelRoute.measure_shape(mname, expr)
    next unless shape
    # choose a target column across the emitted time-intel elements — but ONLY
    # those built from THIS measure's own fact. Cross-fact borrowing produced
    # garbage (live run-2: SAFETY "PY Incident Count" -> ABSENCE "Hours YTD").
    # If no same-fact element exists, leave the measure unresolved so it degrades
    # into coverage.json rather than binding to an unrelated table's column.
    target = nil; tmid = nil; tname = nil; tdate = nil
    ti_elements.each do |te|
      next unless PbiTimeIntelRoute.same_fact?(tbl, te['fact'])
      cand =
        case shape
        when :yoy   then te['cols'].find { |c| c['name'].to_s =~ /YoY/i }
        when :ytd   then te['cols'].find { |c| c['formula'].to_s =~ /\bCumulativeSum\s*\(/ }
        when :prior then te['cols'].find { |c| c['formula'].to_s =~ /\bDateLookback\s*\(/ }
        else te['cols'].find { |c| c['formula'].to_s =~ /\b(DateLookback|CumulativeSum)\s*\(/ }
        end
      if cand then target = cand; tmid = te['mid']; tname = te['name']; tdate = te['date']; break end
    end
    next unless target
    entry = { 'master' => tname, 'ref' => "[#{tmid}/#{target['name']}]", 'agg' => nil }
    # bead 525l: same headline-KPI determinism as above — a bare row-level ref on
    # the grouped element is nondeterministic when consumed by a single-value KPI.
    if tdate
      entry['formula'] = "Sum(If([#{tmid}/#{tdate}] = Max([#{tmid}/#{tdate}]), " \
                         "[#{tmid}/#{target['name']}], Null))"
    end
    field_map["#{tbl}.#{mname}"] = entry
  end
end

# PBI-friendly-entity aliases ([bead]): "VW_SALES.Amount" is ALSO reachable
# as "Sales.Amount", the form PBIR visuals use (1:1 physical->PBI only; role-playing
# copies are already keyed under each PBI table). Runs BEFORE the classic normalization
# below: "Sum(Sales.Amount)" is synthesized from its "Sales.Amount" base, which only
# exists once the alias does — run after, a friendly-named model's every implicit
# aggregate went unsynthesized and its chart lost the measure.
_n_alias = PbiViewRoute.add_friendly_aliases!(field_map, physical_to_pbi)
puts "   master-map: +#{_n_alias} PBI-friendly-entity alias(es) (physical view name -> friendly table name)" if _n_alias.positive?

# bead anlb (continued) — CLASSIC-report queryRefs "Sum(Entity.Col)" and
# "Entity.Col.Variation.Date Hierarchy.<Level>" resolve against the existing map,
# alts wrapped too (lib/pbi_field_alts.rb).
PbiFieldAlts.normalize_classic_refs!(field_map, all_visuals.flat_map { |v| (v['bindings'] || {}).values.flatten })

master_map = { 'masters' => masters, 'fields' => field_map }
mmap_path = File.join(WORK, 'master-map.json')
File.write(mmap_path, JSON.pretty_generate(master_map))
puts "   master-map: #{masters.size} master(s), #{field_map.size} field/measure ref(s) -> #{mmap_path}"

pf_model_path = scoped_tmsl_path || opts[:tmsl]
pf_dialect = PbiProbeGate.dialect_for(opts[:wh_type])
if opts[:page_facts]
  # page-scoped bindings: each page fact's page binds its measures + grain columns to the page fact
  _mm_cmd = [*PY_ARGV, File.join(HERE, 'integrate-page-fact.py'), opts[:page_facts], '--master-map', mmap_path,
             '--dm-readback', File.join(WORK, 'dm-readback.json')]
  _mm_cmd << '--allow-todo' if opts[:allow_page_fact_todo]
  run!(_mm_cmd)
end
if opts[:scaffold_page_facts]
  # Draft page facts from each page's DAX closure (offline, seconds). Never blocks the run: the
  # drafts go to <WORK>/page-facts-draft; complete their TODOs, prove them with check-plan.json,
  # then rerun with --page-facts <dir>.
  phase_mark('4a-scaffold-page-facts')
  scaffold_page_facts!(opts, pf_model_path, signals_path, dm_spec, mmap_path, pf_dialect)
  phase_mark('4-build-workbook')
end

wb_spec = File.join(WORK, 'workbook-spec.json')
layout = File.join(WORK, 'layout.xml')
build = ['ruby', File.join(HERE, 'build-workbook-from-pbir.rb'),
         '--signals', signals_path, '--master-map', mmap_path,
         '--data-model', dm_id, '--name', WB_NAME,
         '--source-title', (opts[:source_title] || name_slug.gsub(/[-_]+/, ' ').strip),
         # control-targeting wave (workstream B): the TMSL relationships drive
         # slicer-control target scope; control-scope.json (intended-scope
         # contract for the control lint) lands in WORK.
         '--model', scoped_tmsl_path || opts[:tmsl],
         '--control-scope-out', File.join(WORK, 'control-scope.json'),
         '--coverage-out', File.join(WORK, 'coverage.json'),
         '--out', wb_spec, '--layout-out', layout]
masters_pruned_path = File.join(WORK, 'masters-pruned.json')
build += (opts[:full_model] ? ['--no-prune-masters'] : ['--masters-pruned-out', masters_pruned_path])
# The workbook POST requires a folderId. Use --folder if given, else inherit the
# DM's folderId (harvested from the ref-dm at Phase 3) so both land together.
wb_folder = opts[:folder] || (JSON.parse(File.read(dm_spec))['folderId'] rescue nil)
build += ['--folder-id', wb_folder] if wb_folder

# GRACEFUL AGENT-PATH FALLBACK. The DM is already posted + valid (dm_id above), so
# if the MECHANICAL workbook layer (build / validate-spec / POST) hits a field it
# cannot translate (Sigma rejects the spec / unresolved "Dependency not found" /
# unmapped derived-dim or measure / source:{}), we must NOT bare-crash. Catch it
# and exit with a clear, FRIENDLY non-zero handoff: the agent path rebuilds the
# workbook against this DM (see SKILL.md). Never worse than the proven agent path.
begin
  build_log = run_wb!(build)
  if opts[:page_facts]
    # Slicers on dimensions a page fact does not carry: control-parameterized SQL behind a union gate
    # (refs/large-pbix.md). Rewrites the spec + layout.xml in place; report in slicer-gate.json.
    run_wb!([*PY_ARGV, File.join(HERE, 'wire-slicer-gate.py'), '--spec', wb_spec, '--page-facts', opts[:page_facts],
             '--model', pf_model_path, '--dm-spec', dm_spec, '--master-map', mmap_path, '--connection', opts[:conn].to_s,
             '--control-scope', File.join(WORK, 'control-scope.json'), '--layout-out', layout,
             '--report', File.join(WORK, 'slicer-gate.json'), '--verify-out', File.join(WORK, 'slicer-gate-verify.json'),
             '--dialect', (%w[snowflake databricks bigquery].include?(pf_dialect) ? pf_dialect : 'snowflake')])
  end
  if !opts[:full_model] && File.exist?(masters_pruned_path)
    begin
      model_scope['dropped_masters'] = JSON.parse(File.read(masters_pruned_path))
      write_model_scope.call
      puts "   MODEL SCOPE: pruned #{model_scope['dropped_masters'].size} unread Data-page master(s)" unless model_scope['dropped_masters'].empty?
    rescue StandardError => e
      warn "   [warn] could not merge #{masters_pruned_path}: #{e.message}"
    end
  end
  # Validate the WORKBOOK spec before POST — previously only the DM spec was
  # validated, so workbook-shape defects (source-less "[]" elements, dangling
  # grouping refs, missing kind) went straight to the API. The DM readback gives
  # the cross-ref context (master/DM element names + ids).
  dm_ctx = File.join(WORK, 'dm-context.json')
  File.write(dm_ctx, JSON.generate(dm_rb))
  # The generic shape validator does not cover live-render hazards such as
  # element-level KPI/bar backgrounds or unresolved local filter references.
  # Run the mandatory preflight before the first network write.
  run_wb!(['ruby', File.join(HERE, 'lib', 'preflight_lint.rb'), wb_spec])
  run_wb!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'workbook',
           '--dm-context', dm_ctx, wb_spec])
  wb_readback = File.join(WORK, 'wb-readback.json')
  rb_log = run_wb!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
                    '--spec', wb_spec, '--out', wb_readback, '--workdir', WORK], env: ENV.to_h)
rescue WorkbookBuildError => e
  failed = cull_failed_fields(e.captured_output, (defined?(build_log) ? build_log : ''))
  # Also surface the converter (c)-tail measures as the likely culprits when the
  # log itself doesn't name a field.
  if failed.empty?
    failed = conv_warnings.map { |w| w.to_s.gsub(/\s+/, ' ').strip }
                          .select { |w| w.start_with?('⛔') }
                          .map { |w| w[/[“"]([^”"]+)[”"]/, 1] || w.sub(/^⛔\s*/, '')[0, 60] }
                          .compact.uniq
  end
  # Classify from the output we ACTUALLY captured. The old code asserted a
  # field-translation failure unconditionally — when no field name could be culled it
  # still printed "one or more fields" — so a LAYOUT-LINT tile-height violation after a
  # SUCCESSFUL post was reported as untranslatable fields, sending the operator to rebuild
  # the whole workbook when the real fix was one tile height. An undetermined cause is now
  # reported as undetermined, with the captured output shown.
  info = PbiOfframp.classify(e.captured_output, failed)
  puts
  puts "── Mechanical path: data model built OK (dataModelId=#{dm_id})."
  puts "   FAILING STAGE: #{info['stage']} — #{info['message']}"
  unless info['salient'].to_s.strip.empty?
    puts '   captured output:'
    info['salient'].to_s.lines.each { |l| puts "     #{l.rstrip}" }
  end
  if info['posted']
    puts '   NOTE: the workbook POSTED — fix and re-apply with PUT /v2/workbooks/<id>/contents.'
    puts '   Do NOT re-POST (it creates an orphan) and do NOT rebuild via the agent path.'
  else
    puts "   Falling back to the agent path: rebuild the workbook via the skill's " \
         'agent-authored flow (see SKILL.md) against this DM. The data model is posted ' \
         'and ready to attach.'
  end
  exit 4
end
wb_rb = JSON.parse(File.read(wb_readback))
wb_id = wb_rb['workbookId']
puts "   workbookId = #{wb_id}"

# Gate-state stamp (after a live post): control_flip_required=true auto-enables
# the shared assert-phase6-ran.rb gate 7b on a STANDALONE run too, matching the
# tableau reference — so neither this one-shot path (Phase 6b below) nor a later
# standalone gate can silently skip the runtime control-flip proof.
begin
  _msf = File.join(WORK, 'migrate-state.json')
  _st  = (JSON.parse(File.read(_msf)) rescue {})
  _st  = {} unless _st.is_a?(Hash)
  _st.merge!('workbook_id' => wb_id, 'control_flip_required' => true)
  File.write(_msf, JSON.pretty_generate(_st))
rescue StandardError
  nil # sentinel bookkeeping never fails the run
end

# ---------------------------------------------------------------------------
# MIGRATION COVERAGE REPORT — what carried over, and what didn't ().
# The build warns loudly at each drop site, but on a complex report those warnings
# scatter through the log; this aggregates coverage.json into ONE readout and, for
# RECOVERABLE gaps, an explicit assistance prompt so nothing is "silently dropped".
# It leads with what DID convert — the perception that a lot is lost is usually
# "the few gaps weren't surfaced in one place". Non-blocking (the workbook is
# posted + usable); the recoverable items are HARD-gated later by
# assert-visual-compare.rb (must be ACCEPTED or fixed before Phase 6 sign-off).
# ---------------------------------------------------------------------------
coverage = CoverageGate.load(File.join(WORK, 'coverage.json'))
if coverage
  # Cause-grouping (customer feedback 2026-07-17: dim names/measures dropped → empty
  # tiles with no "why"). Attribute each silent drop to a CAUSE with an action.
  # UNGRANTED SCHEMA = a warehouse-table element the converter emitted that VANISHED
  # from the DM readback (POST dropped/error-typed it → the connection can't read
  # that schema); DAX drops come from the converter's ⛔/⚠ measure warnings.
  rb_names = dm_elements.map { |e| e['name'] }.compact
  rb_ids   = dm_elements.map { |e| e['id'] }.compact
  ungranted = Hash.new { |h, k| h[k] = [] }
  conv_elements.each do |cel|
    p = cel.dig('source', 'path')
    next unless p.is_a?(Array) && !p.empty?                         # warehouse-table element only
    next if rb_names.include?(cel['name']) || rb_ids.include?(cel['id'])  # survived the readback
    sch = p.length >= 3 ? "#{p[0]}.#{p[-2]}" : (p[-2] || p[0] || '(unknown)')
    ungranted[sch] << p[-1] unless ungranted[sch].include?(p[-1])
  end
  mname = ->(w) { w.to_s[/["“']([^"”']+)["”']/, 1] }
  dax_dropped    = conv_warnings.select { |w| w.to_s.include?('⛔') }.map(&mname).compact
  dax_crosstable = conv_warnings.select { |w| w.to_s =~ /cross-table|different relationship path/i }.map(&mname).compact
  coverage = CoverageGate.classify_causes(coverage, ungranted: ungranted, connection: opts[:conn],
                                          dax_dropped: dax_dropped, dax_crosstable: dax_crosstable)
  File.write(File.join(WORK, 'coverage.json'), JSON.pretty_generate(coverage)) # single channel for assert-visual-compare.rb
  puts
  puts '==================== MIGRATION COVERAGE ===================='
  puts "   #{CoverageGate.headline(coverage)}"
  # BOTH headlines, deliberately. The visual-level line above answers "did each tile
  # come across?"; the binding-level line answers "did each FIELD come across?" — and
  # only the second would have caught the customer's report, where every visual built
  # but 33-54% of its field bindings were pruned.
  puts "   #{CoverageGate.binding_headline(coverage)}"
  rlines = CoverageGate.report_lines_by_cause(coverage)
  unless rlines.empty?
    puts
    puts rlines.join("\n")
  end
  cov_qs = CoverageGate.questions(coverage)
  unless cov_qs.empty?
    puts
    if opts[:yes] || opts[:answers]
      puts "   #{cov_qs.size} recoverable gap(s) — proceeding (unattended); recorded as accepted degradations."
      puts '   (re-run after the action note on each to recover; they are also gated by assert-visual-compare.rb)'
    else
      puts '-------------------- ASSISTANCE AVAILABLE --------------------'
      puts "   #{cov_qs.size} gap(s) below are RECOVERABLE — ask the user whether to recover or accept each."
      puts '   These are NOT silent: each has a concrete action. assert-visual-compare.rb (Phase 5e)'
      puts '   will not go GREEN until every recoverable gap is recovered or explicitly ACCEPTED.'
      puts JSON.pretty_generate('recoverable_gaps' => cov_qs)
    end
  end
  puts '==========================================================='

  # ---- FIELD-LOSS GATE (task 5) -------------------------------------------
  # The readout above is INFORMATIONAL and always has been; that is exactly why a
  # badly degraded migration could ship. This turns FIELD loss into a stop.
  # Fails when (a) a functional component (control/kpi/chart/table) was DROPPED — a
  # lost control means the page lost its filter — or (b) binding resolution is below
  # the floor. --allow-field-loss converts either into a pass that STILL prints the
  # reason. exit 10 is this orchestrator's established "open question" code, so the
  # DM + workbook already posted above remain usable and attachable.
  fl_status, fl_reason = CoverageGate.gate!(coverage, min_resolved: 0.95,
                                                      allow_override: opts[:allow_field_loss])
  if fl_status == :fail
    puts
    puts '########## FIELD-LOSS GATE: FAIL ##########'
    # NB: the ratio-branch reason already embeds binding_headline, so print the
    # headline only when the reason does not (the dropped-functional-component
    # branch names components instead) — otherwise the block repeats itself.
    puts "   #{fl_reason}"
    bh = CoverageGate.binding_headline(coverage)
    puts "   #{bh}" unless fl_reason.to_s.include?(bh)
    cause_lines = CoverageGate.report_lines_by_cause(coverage)
    puts cause_lines.join("\n") unless cause_lines.empty?
    puts
    puts '   The workbook and data model DID post and are usable, but the report lost'
    puts '   FIELDS, not just styling — fix the cause above and re-run, or pass'
    puts '   --allow-field-loss to accept it explicitly (the reason is still reported).'
    puts '###########################################'
    exit 10
  elsif fl_reason.to_s.start_with?('overridden')
    puts "   FIELD-LOSS GATE: #{fl_reason}"
  end
end

# ---------------------------------------------------------------------------
# Phase 5 — Layout (authoritative final spec write — bead 16i)
# ---------------------------------------------------------------------------
hdr(5, TOTAL, 'Layout')
run!(['ruby', File.join(HERE, 'put-layout.rb'), '--workbook', wb_id, '--layout', layout], env: ENV.to_h)
puts "   layout applied to workbook #{wb_id}"
require 'sigma_rest'

# ---------------------------------------------------------------------------
# Phase 5b — Visual QA: auto-render each content page to a FULL-PAGE PNG so the
# layout can be reviewed against refs/layout-visual-qa.md AND compared to the
# source PBI page captures (SKILL.md Phase 5e/5f gate). Matches qlik/tableau
# Phase 5b. NON-FATAL — a transient export failure must not sink a green
# migration; the REVIEW (reading each PNG) is the actual gate. Page ids come
# from the LOCAL spec the builder wrote (deterministic; POST preserves them) —
# the live workbook readback has proven flaky mid-pipeline.
# ---------------------------------------------------------------------------
begin
  vqa = File.join(WORK, 'visual-qa')
  FileUtils.mkdir_p(vqa)
  local_spec = (JSON.parse(File.read(wb_spec)) rescue {})
  local_doc = Sigma::CodeRep.document(local_spec)
  content_pages_qa = (local_doc['pages'] || []).reject { |p| p['id'].to_s.downcase.include?('data') }
  tok = (Sigma.auth_token rescue ENV['SIGMA_API_TOKEN'])
  pngs = []
  content_pages_qa.each do |pg|
    out = File.join(vqa, "#{pg['id']}.png")
    _o, st = Open3.capture2e({ 'SIGMA_API_TOKEN' => tok.to_s }, *PY_ARGV,
                             File.join(HERE, 'sigma-export-png.py'),
                             '--workbook', wb_id, '--page', pg['id'], '--out', out,
                             '--w', '1800', '--h', '1000')
    st.success? ? (pngs << out) : (puts "   [warn] visual-QA render failed for page #{pg['id']}")
  end
  puts "   rendered #{pngs.size}/#{content_pages_qa.size} full-page PNG(s) for visual QA -> #{vqa}"
  if pngs.any?
    puts '   VISUAL QA (mandatory review — do not skip): open each PNG and check vs'
    puts '   refs/layout-visual-qa.md AND the source PBI page captures (export-pbi-pages.py) —'
    puts '   no overlaps/stacking, no clipped titles, controls in their own band, right chart'
    puts '   kinds/colors, even heights. See assert-visual-compare.rb for the source-vs-target gate.'
  end
rescue StandardError => e
  puts "   [warn] visual-QA render skipped: #{e.message[0, 120]}"
end

# ---------------------------------------------------------------------------
# Phase 6 — Parity (freshness banner FIRST, then formula guard + warehouse compare)
# ---------------------------------------------------------------------------
hdr(6, TOTAL, 'Parity')
require 'date'

# ---- join the NON-BLOCKING Phase-1.5 freshness lane (launched pre-Convert) --
if fresh_waiter
  fresh_waiter.join(180) # the probe ran concurrently; normally already done
  if File.exist?(fresh_log)
    File.read(fresh_log).each_line { |l| puts "   #{l.rstrip}" }
  end
  puts '   ⚠ freshness preflight produced no freshness.json (continuing without it)' unless File.exist?(fresh_path)
end
freshness = File.exist?(fresh_path) ? (JSON.parse(File.read(fresh_path)) rescue {}) : {}
stale_days = freshness['staleDays']

# bead fmte — the SOURCE-FRESHNESS banner LEADS the parity output (read this
# before any side-by-side): a stale import snapshot / failed refresh explains
# "Sigma shows more data" deltas up front instead of after they look wrong.
fresh_ok   = freshness['lastSuccessfulRefresh']
fresh_fail = (freshness['failures'] || []).first
if fresh_ok || fresh_fail
  puts '   ── SOURCE FRESHNESS (read this before any side-by-side) ──'
  if fresh_ok
    puts "   PBI dataset last refreshed #{fresh_ok['endTime']} (#{stale_days} days ago)"
  end
  if fresh_fail
    tag = freshness['credsSuspect'] ? ' — dataset credentials look EXPIRED' : ''
    puts "   ⚠ most recent refresh FAILURE #{fresh_fail['endTime']} (#{fresh_fail['errorCode']})#{tag}"
  end
  if stale_days && stale_days >= 1
    puts "   ⚠ source is ~#{stale_days.ceil} day(s) stale — Sigma reads the LIVE warehouse and is"
    puts '     EXPECTED to show more data. Deltas below are classified accordingly.'
  end
end

# (1) formula-resolution guard: no column resolved to type "error".
cols = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/columns") rescue { 'entries' => [] })
err_cols = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
total_cols = (cols['entries'] || []).size
wb_pairs = Sigma::CodeRep.workbook_elements_with_pages(wb_rb)
chart_pairs = wb_pairs.select { |_el, page| page && page['id'] != 'page-data' }
chart_els = chart_pairs.map(&:first)
chart_pages = chart_pairs.filter_map { |_el, page| page['id'] }.uniq

# (2) warehouse-vs-snapshot compare (bead fmte). For every table the preflight
# snapshotted, export the matching Data-page master element (Sigma = LIVE
# warehouse rows) via the REST export API and classify the delta:
#   MATCH            same row count (and max dates, when known)
#   STALE-EXPLAINED  Sigma has MORE/newer rows — the stale/failed-refresh
#                    snapshot explains it; NOT a conversion error
#   DIVERGENT        Sigma has FEWER/older rows — a real problem; blocks
norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
export_rows = lambda do |element_id|
  res = Sigma.request(:post, "/v2/workbooks/#{wb_id}/export",
                      body: { 'elementId' => element_id, 'format' => { 'type' => 'json' } }.to_json)
  qid = res.is_a?(Hash) ? res['queryId'] : nil
  raise 'export returned no queryId' unless qid
  deadline = Time.now + 90
  while Time.now < deadline
    body = (Sigma.request(:get, "/v2/query/#{qid}/download", binary: true) rescue nil)
    if body && !body.strip.empty?
      parsed = (JSON.parse(body) rescue nil)
      return parsed if parsed.is_a?(Array)
      return parsed['rows'] if parsed.is_a?(Hash) && parsed['rows'].is_a?(Array)
      lines = body.each_line.map { |l| (JSON.parse(l) rescue nil) }.compact
      return lines if lines.size > 1
    end
    sleep 2
  end
  raise 'export download timed out'
end

fresh_classes = []
data_els = wb_pairs.select do |_el, page|
  page && (page['id'] == 'page-data' || page['name'].to_s =~ /data/i)
end.map(&:first)
(freshness['snapshot'] || {}).each do |table, snap|
  pbi_rows = snap['rows']
  next if pbi_rows.nil?
  # match via the master-map (master key == converter element name == warehouse
  # table for base tables; the page-data element keeps the master's id), falling
  # back to a name match. Skip the derived "<Fact> View" join masters.
  _mk, master = masters.find { |k, _| norm.call(k) == norm.call(table) }
  el = (master && data_els.find { |e| e['id'] == master['id'] }) ||
       data_els.find { |e| norm.call(e['name']) == norm.call(table) }
  unless el
    fresh_classes << ['SKIPPED', table, 'no matching Data-page master element']
    next
  end
  if pbi_rows > 100_000
    fresh_classes << ['SKIPPED', table, "#{pbi_rows} rows — too large for an export row-count probe"]
    next
  end
  begin
    rows = export_rows.call(el['id'])
  rescue StandardError => e
    fresh_classes << ['SKIPPED', table, "export failed: #{e.message[0, 80]}"]
    next
  end
  wh_rows = rows.size
  # max-date compare: match each snapshot date col to an export key by name.
  date_note = nil
  newer_dates = false
  (snap['maxDates'] || {}).each do |dcol, pbi_max|
    next if pbi_max.nil?
    key = (rows.first || {}).keys.find { |k| norm.call(k) == norm.call(dcol) }
    next unless key
    wh_max = rows.map { |r| r[key] }.compact.max
    pd = (Date.parse(pbi_max.to_s) rescue nil)
    wd = (Date.parse(wh_max.to_s) rescue nil)
    next unless pd && wd
    if wd > pd
      newer_dates = true
      date_note = "max(#{dcol}) warehouse=#{wd} vs PBI=#{pd}"
    end
  end
  stale_or_failed = (stale_days && stale_days >= 1) || freshness['credsSuspect'] ||
                    (freshness['failures'] || []).any?
  if wh_rows == pbi_rows && !newer_dates
    fresh_classes << ['MATCH', table, "rows=#{wh_rows} (warehouse == PBI snapshot)"]
  elsif wh_rows >= pbi_rows
    why = stale_or_failed ? 'stale/failed-refresh snapshot explains it' : 'warehouse moved since the refresh'
    delta = wh_rows - pbi_rows
    msg = "Sigma will show more data: warehouse rows=#{wh_rows} vs PBI snapshot=#{pbi_rows}" \
          "#{delta.positive? ? " (+#{delta})" : ''}#{date_note ? "; #{date_note}" : ''} — #{why}"
    fresh_classes << ['STALE-EXPLAINED', table, msg]
  else
    fresh_classes << ['DIVERGENT', table,
                      "warehouse rows=#{wh_rows} < PBI snapshot=#{pbi_rows} — Sigma shows LESS data " \
                      'than the source snapshot; check the table/path mapping']
  end
end
if fresh_classes.any?
  puts '   freshness deltas (table-level, Sigma live vs PBI snapshot):'
  fresh_classes.each { |cls, table, msg| puts format('   %-15s %s: %s', cls, table, msg) }
end
divergent = fresh_classes.count { |c| c[0] == 'DIVERGENT' }

parity_ok = err_cols.empty? && divergent.zero?
# NOTE: this is a RESOLUTION check, not value parity. It proves every column
# resolves (no type "error") and the warehouse matches the PBI snapshot
# (freshness) — it does NOT diff the built aggregates against the source's
# DAX/SQL results. Value parity is the assert-phase6-ran.rb / phase6-parity-pbi.rb
# gate (writes parity-final.json). Labeling this "PARITY: PASS" over-claimed and
# masked that the value bar was never run in the one-shot path (bead: p5y2 seam).
if err_cols.empty?
  puts "   RESOLUTION: #{parity_ok ? 'PASS' : 'FAIL'} — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{chart_els.size} chart element(s) built across #{chart_pages.size} page(s)"
  puts '   NOTE: value parity NOT diffed vs source in this path — run assert-phase6-ran.rb / phase6-parity-pbi.rb to value-verify.'
  puts "   RESOLUTION: FAIL — #{divergent} DIVERGENT freshness delta(s) above" unless divergent.zero?
else
  puts "   RESOLUTION: FAIL — #{err_cols.size}/#{total_cols} column(s) resolved to type 'error':"
  err_cols.first(8).each { |c| puts "     [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
end

# ---------------------------------------------------------------------------
# Phase 6b — runtime control-flip proof (DEFAULT-ON). Gate 7 (control_lint.rb,
# run at post-and-readback) proves control WIRING against the live spec, but a
# builder-level listen->column mis-map yields a spec that lints clean yet does
# NOTHING when the user changes the control. The only independent proof is
# runtime: flip each control via the REST export API and confirm its targets'
# output actually changes (scripts/probe-controls.rb). Mirrors the shared
# assert-phase6-ran.rb gate 7b so the one-shot migrate enforces it too; the
# migrate-state.json control_flip_required stamp (above) enforces it on a
# standalone gate run as well. Escape: --skip-control-flip "<reason>".
# ---------------------------------------------------------------------------
require 'rbconfig'
flip_line = nil
_flip_libs = true
begin
  require_relative 'lib/pbi_flip'
  require_relative 'lib/control_lint'
  require_relative 'lib/flip_gate'
  require_relative 'lib/code_rep'
rescue LoadError => e
  _flip_libs = false
  warn "   [WARN] Phase 6b: #{e.message} — re-vendor scripts/lib (SHA-1 discipline); control flip UNVERIFIED"
end
if opts[:skip_control_flip]
  reason = opts[:skip_control_flip] == true ? '(no reason given)' : opts[:skip_control_flip]
  flip_line = "WAIVED — #{reason}"
  puts "   [WAIVED] Phase 6b: runtime control-flip proof — #{reason} (name it in your migration report)"
elsif !_flip_libs
  flip_line = 'UNVERIFIED — flip libs not loadable'
else
  # Count controls on the live posted workbook (same source of truth as gate 7b).
  n_controls = nil
  begin
    _spec = Sigma.request(:get, Sigma::CodeRep.read_path(wb_id))
    if _spec.is_a?(String)
      begin
        _spec = JSON.parse(_spec)
      rescue JSON::ParserError
        require 'yaml'; require 'date'
        _spec = (YAML.safe_load(_spec, permitted_classes: [Date, Time]) rescue nil)
      end
    end
    if _spec.is_a?(Hash)
      # Workbook code-rep GETs nest pages/schemaVersion under a top-level
      # `contents` key (`document` on the retired /spec GET); ControlLint.controls_report
      # expects a flat spec['pages'] (same "unwrap at the caller, not in the
      # lib" contract as the other ControlLint callers) — a bare _spec here
      # would always report 0 controls, silently skipping the runtime
      # control-flip proof instead of running it.
      _spec = Sigma::CodeRep.metadata(_spec).merge(Sigma::CodeRep.document(_spec))
      n_controls = ControlLint.controls_report(_spec).length
    end
  rescue StandardError => e
    warn "   [WARN] Phase 6b: could not fetch/parse the live spec to count controls (#{e.message})"
  end

  probe_out = File.join(WORK, 'probe-controls')
  probe     = File.join(HERE, 'probe-controls.rb')
  has_creds = begin
    !Sigma.base_url.to_s.empty? && !Sigma.auth_token.to_s.empty?
  rescue Sigma::Error
    false
  end

  decision, info =
    if n_controls == 0
      [:none, nil]
    elsif has_creds && File.exist?(probe)
      system(RbConfig.ruby, probe, '--workbook-id', wb_id, '--out', probe_out)
      _rc  = $?.exitstatus
      _res = (JSON.parse(File.read(File.join(probe_out, 'probe-results.json'))) rescue nil)
      FlipGate.decide(_rc, _res)
    elsif has_creds
      warn '   [WARN] Phase 6b: scripts/probe-controls.rb not vendored — control flip UNVERIFIED'
      [:offline, nil]
    else
      # Offline: accept RECORDED evidence, else UNVERIFIED (never hard-fail a run
      # that never reached the live API).
      _res = (JSON.parse(File.read(File.join(probe_out, 'probe-results.json'))) rescue nil)
      PbiFlip.recorded(_res)
    end

  status, flip_line, exit_code = PbiFlip.outcome(decision, info)
  case status
  when :ok, :none
    extra = (info && Array(info[:skips]).any?) ? " (#{Array(info[:skips]).length} un-probeable type(s) skipped)" : ''
    puts "   [OK] Phase 6b: #{flip_line}#{extra}"
  when :advisory
    warn "   [WARN] Phase 6b: #{flip_line} — date-range/slider/unlabeled control(s) need an explicit flip value; runtime wiring UNVERIFIED"
    begin
      FileUtils.mkdir_p(probe_out)
      File.write(File.join(probe_out, 'control-flip-unverified.json'),
                 JSON.pretty_generate('workbookId' => wb_id,
                                      'unprobed' => Array(info && info[:skips]).map { |c, n| { 'control' => c, 'note' => n } }))
    rescue StandardError
      nil
    end
  when :offline
    puts "   [SKIP] Phase 6b: #{flip_line}"
  when :fail
    puts "   [FAIL] Phase 6b: #{Array(info[:fails]).length} control(s) wired but INERT on workbook #{wb_id}:"
    Array(info[:fails]).each { |cid, note| puts "     - #{cid}: #{note}" }
    puts '     The control passed the static lint (gate 7) but does not filter its targets — a'
    puts '     builder listen->column mis-mapping. Re-check control targeting in the build, or'
    puts '     waive with --skip-control-flip "<reason>". Reproduce:'
    puts "       ruby scripts/probe-controls.rb --workbook-id #{wb_id}"
    exit exit_code
  when :error
    puts "   [FAIL] Phase 6b: probe-controls.rb could not verify the wiring on workbook #{wb_id}."
    puts '     An enforced gate that could not run must not pass silently. Re-run once the export'
    puts '     API is reachable, or waive with --skip-control-flip "<reason>".'
    exit exit_code
  else
    puts "   [WARN] Phase 6b: #{flip_line}"
  end
end

# ---------------------------------------------------------------------------
# Phase E (OPT-IN) — Enhance. Runs ONLY with --enhance AND a parity PASS:
# enhancements clone a PARITY-VERIFIED workbook, never an unproven one.
# Clone-first / scan-then-propose / accept-only / parity-unchanged-gated —
# see enhance-scan.rb + enhance-apply.rb (the shared Phase-E engine).
# ---------------------------------------------------------------------------
enhance_line = nil
if opts[:enhance] && !parity_ok
  enhance_line = 'SKIPPED — parity not green (Phase E only clones a parity-verified workbook)'
elsif opts[:enhance]
  puts
  puts '── Phase E (opt-in) · Enhance ──'
  enh_path = File.join(WORK, 'enhancements.json')
  e_out, e_st = Open3.capture2e(ENV.to_h, 'ruby', File.join(HERE, 'enhance-scan.rb'),
                                '--workbook-id', wb_id, '--workdir', WORK,
                                '--source', 'powerbi', '--out', enh_path)
  e_out.each_line { |l| puts "   #{l.rstrip}" }
  if !e_st.success?
    enhance_line = 'scan FAILED (migration itself passed parity; see output above)'
  elsif opts[:enhance_accept].nil?
    enh_doc = (JSON.parse(File.read(enh_path)) rescue {})
    cands = enh_doc['candidates'] || []
    app_options = enh_doc['app_options'] || []
    puts
    puts '==================== PHASE E PROPOSALS (acceptance required) ===================='
    puts "#{cands.size} enhancement candidate(s) in #{enh_path}. NOTHING has been applied."
    if app_options.empty?
      puts 'present each candidate to the human (interactive: one AskUserQuestion checklist),'
      puts 'then re-run this exact command adding:'
      puts '  --enhance --enhance-accept <id,id,...>   # or: --enhance-accept all-low-risk'
    else
      puts
      puts 'RUN THE DESIGN INTERVIEW FIRST — ask what the app should BE, not which'
      puts 'patches to apply. Options below are derived from this source\'s own data'
      puts '(see refs/phase-e-enhance.md -> "The design interview"):'
      app_options.each do |o|
        detail = o['archetype'] ?
          "#{o['archetype']} score=#{o['score']} confidence=#{o['confidence']}" :
          o['risk'].to_s
        puts format('  %-1s %-34s %s [%s]',
                    o['recommended'] ? '*' : ' ', o['id'], o['label'], detail)
        puts format('      why: %s', o['evidence'].to_s.gsub(/\s+/, ' ')[0, 96])
      end
      puts
      puts 'Present these with ONE AskUserQuestion (include the parity-only choice),'
      puts 'confirm any medium-risk item by name, then record the answer:'
      puts "  ruby scripts/enhance-select.rb --enhancements #{enh_path} \\"
      puts '    --option <option-id> [--confirm-medium <ids>]'
      puts 'For an app archetype, ask editable/approval/scenario/agent choices'
      puts 'and write app-plan.json before authoring:'
      puts "  ruby scripts/enhance-app-plan.rb --enhancements #{enh_path} \\"
      puts '    --option <option-id> --out <workdir>/app-plan.json'
      puts 'then re-run this exact command adding:'
      puts '  --enhance --enhance-accept <accepted_candidate_ids from enhance-selection.json>'
    end
    puts '================================================================================='
    exit 14
  else
    a_out, a_st = Open3.capture2e(ENV.to_h, 'ruby', File.join(HERE, 'enhance-apply.rb'),
                                  '--workbook-id', wb_id, '--enhancements', enh_path,
                                  '--accept', opts[:enhance_accept],
                                  '--out', File.join(WORK, 'enhance-report.json'))
    a_out.each_line { |l| puts "   #{l.rstrip}" }
    rep = (JSON.parse(File.read(File.join(WORK, 'enhance-report.json'))) rescue {})
    enhance_line = if a_st.success?
                     "clone #{rep['clone_id']} '#{rep['clone_name']}': " \
                     "#{(rep['applied'] || []).size} applied, #{(rep['skipped'] || []).size} skipped, " \
                     "#{(rep['reverted'] || []).size} reverted; parity-unchanged gate GREEN"
                   else
                     "apply NOT GREEN (exit #{a_st.exitstatus}) — see enhance-report.json"
                   end
  end
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts
puts '================ RESULT ================'
puts "dataModelId : #{dm_id}"
puts "workbookId  : #{wb_id}"
puts "RESOLUTION  : #{parity_ok ? 'PASS' : 'FAIL'} (#{total_cols} cols resolve, #{err_cols.size} error" \
     "#{fresh_classes.any? ? format(', freshness: %d match / %d stale-explained / %d divergent', fresh_classes.count { |c| c[0] == 'MATCH' }, fresh_classes.count { |c| c[0] == 'STALE-EXPLAINED' }, divergent) : ''}); value parity NOT run — see assert-phase6-ran.rb"
if fresh_ok
  puts "freshness   : PBI last refresh #{fresh_ok['endTime']} (#{stale_days} days ago)" \
       "#{freshness['credsSuspect'] ? ' — REFRESH FAILING (creds)' : ''}"
end
puts "ENHANCE     : #{enhance_line}" if enhance_line
puts "CONTROL-FLIP: #{flip_line}" if flip_line
# Empty-workbook guard + completion sentinel. parity_ok is VACUOUSLY true when no
# chart elements were built (0 cols, 0 divergent) — an empty/placeholder workbook
# would otherwise exit 0 and look "done" (the exact PBI failure: pages, no
# elements). Require real elements, and stamp a run-scoped success marker only on
# a genuine pass so verify-complete.rb (the done-check the SKILL points at) can't
# green an empty result.
built_ok = parity_ok && chart_els.size.positive?
if chart_els.size.zero?
  puts 'ELEMENTS    : 0 chart elements built — EMPTY workbook, NOT a complete migration.'
  puts '              Parity is vacuous with no elements. Do NOT report success: re-extract the'
  puts '              report layout (--pbir) or investigate why no visuals were produced. Never'
  puts '              hand-author placeholder pages to fill it.'
end
begin
  succ = File.join(WORK, 'phase6-success.json')
  if built_ok
    # 'resolution-pass' (not 'parity-pass'): this marker records that the build
    # resolved + freshness-matched, NOT that values were diffed against source.
    # verify-complete.rb reports value parity separately (parity-final.json).
    File.write(succ, JSON.pretty_generate('workbookId' => wb_id, 'chartCount' => chart_els.size,
                                          'gates' => 'resolution-pass',
                                          'generatedAt' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')))
  elsif File.exist?(succ)
    File.delete(succ) # a prior success marker is stale if this run isn't green
  end
rescue StandardError
  nil # sentinel bookkeeping never fails the run
end
puts '======================================='
exit(built_ok ? 0 : 3)
