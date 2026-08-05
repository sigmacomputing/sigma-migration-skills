#!/usr/bin/env ruby
# Phase-1 discovery via the Tableau REST API. Use this when you have a PAT —
# it is the FAST path (measured on "Orders Conversion Test": 61.8s serial →
# 13.7–18.9s with the unified pool). The Tableau MCP is the no-PAT fallback.
#
# Output layout (matches what the MCP-driven Phase 1 produces):
#   /tmp/<name>/get-workbook.json     — workbook metadata + view list
#   /tmp/<name>/ds-metadata.json      — VDS read-metadata response (field list + formulas)
#   /tmp/<name>/graphql-fields.json   — metadata API field list (cleaner formulas)
#   /tmp/<name>/views/<viewId>.csv    — every view's data CSV; on a
#                                       --dashboard-scoped mission only the
#                                       target dashboards' MEMBER SHEETS
#                                       (membership: Metadata API at t≈0, .twb
#                                       pre-parse fallback; unresolvable →
#                                       ALL views, fail-open + logged)
#   /tmp/<name>/views/<viewId>.png    — dashboard view image only (skip other views by default)
#   /tmp/<name>/dashboards/<name>.png — EVERY dashboard view at resolution=high,
#                                       keyed by (sanitized) dashboard name. This
#                                       is the per-page ground truth the render-
#                                       compare-fix (RCF) visual loop diffs
#                                       against — without it the fidelity loop
#                                       is structurally impossible.
#   /tmp/<name>/workbook-content.twb  — raw .twb XML (or .twbx zip bytes)
#   /tmp/<name>/timings.json          — per-task start/duration/attempts (ALWAYS
#                                       written — the evidence trail for any
#                                       future "discovery is slow" report)
#
# How it fetches: ONE shared thread pool (default 5, --pool N) covers every
# NON-IMAGE network task — .twb download, VDS read-metadata, GraphQL fields,
# all view CSVs. Only the initial workbook GET is serial (everything else
# needs its view list). 5 is the measured sweet spot; 8+ risks long-tail
# stragglers (a contended VizQL session can park one fetch for 40s+).
#
# IMAGES — a DEDICATED single worker thread (W2.20) owns EVERY PNG fetch from
# t≈0: image renders are the heaviest per-request VizQL load and must never
# run concurrently with ANOTHER IMAGE (the solo constraint is image-with-image
# only — an image beside the CSV batch is fine, and overlapping them is the
# point: the slow renders hide behind the CSVs instead of running serially
# after the pool drains). The dashboards/ set is enqueued the moment the .twb
# lands — dashboard names come from ./dashboards/dashboard elements, matched
# to the workbook's views by trimmed name; the single worker preserves FIFO,
# so a views/<id>.png fetched this run is REUSED for its dashboards/ twin
# instead of re-rendering. (--skip-images skips all of it; the legacy
# views/<viewId>.png heuristic single-dashboard fetch is kept for backward
# compatibility.)
#
# Resilience (insurance — none of it fired in validation, keep it anyway):
#   * 429 / 408 / 5xx / timeouts retry with exponential backoff + jitter
#     (max 4 attempts).
#   * 401s are re-minted single-flight by lib/tableau_rest.rb (refresh_token!);
#     if a 401 still escapes that retry, the task wrapper re-mints once more.
#   * BOUNDED workbook-content downloads (W2.21/E6.4): Net::HTTP's
#     read_timeout only bounds the gap BETWEEN bytes, so a trickling VizQL
#     response (field-observed: 800s+, one ~1.5h wedge) never trips it. The
#     two download tasks carry wall-clock budgets instead — 180s for the thin
#     .twb, 300s (scaled up by the Get Workbook size attribute, ceiling 900s)
#     for the includeExtract=true re-fetch — and an over-ceiling extract is
#     PRE-ABORTED before the first byte. --download-budget SECONDS overrides
#     both (explicit operator budget wins: no ceiling, no pre-abort). A blown
#     budget abandons the task (never retried) and discovery proceeds thin,
#     fail-open, exit 0.
#   * BOUNDED membership probe: the serial pre-pool dashboard-membership
#     GraphQL call carries its own budget (MEMBERSHIP_BUDGET, 15s/attempt,
#     2 attempts) so a wedged Metadata API cannot stall pool start; a blown
#     budget fails open to the .twb pre-parse / all-views path.
#
# Usage:
#   eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/tableau-discover.rb \
#     --workbook-name "Orders Conversion Test" \
#     --datasource-name "ORDER_FACT (DEMO_DB.ORDER_FACT)+ (New Virtual Connection)" \
#     --out /tmp/orders [--pool 5]
#
# At least one of --workbook-id / --workbook-name is required.
# --datasource-luid / --datasource-name are optional (auto-detected from the
# .twb when omitted). --datasource-luid must be the FULL UUID — the REST
# filter has no prefix matching.

require 'json'
require 'fileutils'
require 'optparse'
require 'thread'
require 'timeout' # explicit: the offline test stubs tableau_rest, so net/http
                  # never loads it transitively — the budget wrap needs it

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'tableau_rest'
# .twbx is a ZIP (inner .twb + embedded .hyper extract). Read it with the stdlib-
# only Zlib reader — NOT the rubygems 'zip' (crashes "cannot load such file -- zip"
# on stock RubyInstaller, field-caught) and NOT a shelled unzip/python (PATH/Store-
# stub footguns). lib/zip_extract selectively inflates ONE member, so we read the
# small .twb and derive .hyper presence from the name list without ever inflating
# the multi-GB extract.
require 'zip_extract'

opts = { fetch_view_images: 'dashboard-only', pool: 5 }
OptionParser.new do |o|
  o.on('--workbook-name NAME')    { |v| opts[:workbook_name] = v }
  o.on('--workbook-id ID')        { |v| opts[:workbook_id] = v }
  # W2.20 — scoped missions fetch ONLY the target dashboards' member-sheet
  # CSVs (membership: Metadata API at t≈0, .twb pre-parse fallback;
  # unresolvable → ALL views, stated not silent). Matching mirrors
  # parse-twb-layout: exact → case-insensitive → unique substring.
  o.on('--dashboard NAME', 'Scope view-CSV fetches to this dashboard\'s member sheets (repeatable). ' \
                           'Fail-open: unresolvable membership fetches all views.') { |v| (opts[:dashboards] ||= []) << v }
  o.on('--datasource-name NAME')  { |v| opts[:datasource_name] = v }
  o.on('--datasource-luid LUID', 'FULL datasource UUID (no prefix matching)') { |v| opts[:datasource_luid] = v }
  o.on('--no-auto-ds', 'Disable .twb-based datasource auto-detect') { opts[:no_auto_ds] = true }
  o.on('--out DIR', 'Output directory (required)') { |v| opts[:out] = v }
  o.on('--skip-images')           { opts[:fetch_view_images] = 'none' }
  o.on('--all-view-images')       { opts[:fetch_view_images] = 'all' }
  o.on('--skip-content')          { opts[:skip_content] = true }
  # --[no-]: existing callers (migrate-tableau.rb's live-repoint route) still
  # pass the old opt-out spelling; it must stay accepted even though skip is
  # now the default.
  o.on('--[no-]extract-refetch', 'opt IN to the includeExtract=true re-download when extract markers are found — ' \
                                 'default is to SKIP it (most routes never consume the frozen extract bytes); ' \
                                 'pass --extract-refetch on extract-landing runs') { |v| opts[:extract_refetch] = v }
  o.on('--pool N', Integer, 'Fetch-pool size (default 5 — measured sweet spot)') { |v| opts[:pool] = v }
  o.on('--download-budget SECONDS', Integer,
       'Wall-clock budget override for workbook-content downloads ' \
       '(default: 180s thin, 300s..900s size-scaled for --extract-refetch; ' \
       'an explicit override also disables the size pre-abort)') { |v| opts[:download_budget] = v }
end.parse!

abort 'Missing --out' unless opts[:out]
abort 'Need --workbook-id or --workbook-name' unless opts[:workbook_id] || opts[:workbook_name]

FileUtils.mkdir_p(opts[:out])
FileUtils.mkdir_p(File.join(opts[:out], 'views'))

T0 = Time.now.to_f
TIMINGS = []
TIMINGS_MUTEX = Mutex.new
LOG_MUTEX = Mutex.new

def log(msg)
  LOG_MUTEX.synchronize { warn format('[%7.3f] %s', Time.now.to_f - T0, msg) }
end

# Atomic write: downstream interleaved callers (migrate-tableau.rb) poll for
# these artifacts while this script is still running — never let them observe
# a half-written file.
def atomic_write(path, bytes)
  tmp = "#{path}.tmp.#{Process.pid}"
  File.binwrite(tmp, bytes)
  File.rename(tmp, path)
end

# 400 is included: Tableau Cloud's VizQL layer intermittently 400s view/data
# exports under concurrent load (observed on the FATSCALE 44-view fat workbook:
# 5/44 CSVs 400'd on one run, all succeeded on the next) — a retry with backoff
# recovers them. A genuinely-bad request just burns the 4 attempts.
RETRYABLE = /\b(429|408|400|50[234])\b|Too Many Requests|timed? ?out|Timeout/i

# W2.21 (E6.4) — wall-clock budgets for the two workbook-content downloads.
DL_BUDGET_TWB     = 180 # thin (includeExtract=false) download
DL_BUDGET_EXTRACT = 300 # includeExtract=true re-fetch, floor
DL_EXTRACT_CEIL   = 900 # derived-budget ceiling; beyond it → pre-abort
DL_FLOOR_MB_S     = 1.0 # conservative sustained throughput floor (MB/s)

# W2.20 fix (review finding): the dashboard-membership probe runs SERIALLY
# before the pool starts — under the W2.21 default (max_attempts 4, no budget)
# a wedged Metadata API could stall the twb download, every CSV, and the PNG
# worker behind a probe whose only job is to make the run FASTER. So it gets
# its own small per-attempt budget and a 2-attempt cap. Fail-open: a blown
# budget abandons the probe (non-retryable message) and scoping falls to the
# .twb pre-parse / all-views path. TABLEAU_MEMBERSHIP_BUDGET seconds overrides
# (emergencies + offline tests; healthy probes answer in ~1-2s).
MEMBERSHIP_BUDGET = [(ENV['TABLEAU_MEMBERSHIP_BUDGET'] || '15').to_i, 1].max

# Seconds the extract re-fetch may plausibly need, from Get Workbook's size
# attribute (megabytes): size at the throughput floor + 60s grace. Derivation
# input for both the scaled budget and the before-first-byte pre-abort.
def extract_seconds_needed(size_mb)
  return nil if size_mb.nil? || size_mb <= 0
  (size_mb / DL_FLOOR_MB_S).ceil + 60
end

# Budget for the extract re-fetch. An explicit --download-budget wins outright
# (operator asserted it; no ceiling). Otherwise scale with workbook size so a
# genuinely large extract on a slow link doesn't false-trip, capped at the
# ceiling (over-ceiling cases pre-abort before the first byte instead).
def extract_budget(size_mb, override)
  return override if override
  need = extract_seconds_needed(size_mb)
  need ? [[DL_BUDGET_EXTRACT, need].max, DL_EXTRACT_CEIL].min : DL_BUDGET_EXTRACT
end

# Run one named fetch task with timing + backoff-retry. Returns task result or nil.
# max_attempts caps the backoff-retry budget (default 4; the heavy extract
# re-download uses 2 — its 120s×4 worst case dominated failed discoveries).
# budget: PER-ATTEMPT wall-clock bound (W2.21). The timeout message avoids
# every RETRYABLE token ("#{n}s" keeps \b400\b from matching a 400s budget),
# so a blown budget is abandoned — never retried into a 4× burn. budget_msg
# replaces the default download wording for non-download tasks (the
# membership probe) — any custom message MUST keep avoiding RETRYABLE tokens,
# or a blown budget re-enters the retry loop it exists to skip.
def run_task(name, max_attempts: 4, budget: nil, budget_msg: nil)
  t0 = Time.now.to_f
  attempts = 0
  begin
    attempts += 1
    result = if budget
               Timeout.timeout(budget, nil,
                               budget_msg ||
                               "download budget #{budget}s exhausted (--download-budget raises it)") { yield }
             else
               yield
             end
    TIMINGS_MUTEX.synchronize do
      TIMINGS << { 'task' => name, 'start' => (t0 - T0).round(3),
                   'seconds' => (Time.now.to_f - t0).round(3), 'attempts' => attempts, 'ok' => true }
    end
    result
  rescue Tableau::Error, Timeout::Error, Errno::ETIMEDOUT, Net::ReadTimeout, Net::OpenTimeout => e
    msg = e.message.lines.first&.chomp || e.class.name
    if attempts < max_attempts && msg =~ RETRYABLE
      delay = (1.5 * (2**(attempts - 1))) + rand * 0.5
      log "#{name}: retryable (#{msg[0, 80]}) — backoff #{delay.round(1)}s (attempt #{attempts})"
      sleep delay
      retry
    elsif attempts < [max_attempts, 3].min && msg =~ /\b401\b/
      # lib already retried 401 once with a refreshed token; one more explicit
      # re-mint covers session invalidation racing across threads.
      log "#{name}: 401 escaped lib retry — re-minting token (attempt #{attempts})"
      (Tableau.refresh_token! rescue nil)
      sleep 1.0 + rand * 0.5
      retry
    end
    TIMINGS_MUTEX.synchronize do
      TIMINGS << { 'task' => name, 'start' => (t0 - T0).round(3),
                   'seconds' => (Time.now.to_f - t0).round(3), 'attempts' => attempts,
                   'ok' => false, 'error' => msg[0, 200] }
    end
    log "#{name}: FAILED after #{attempts} attempt(s): #{msg[0, 120]}"
    nil
  end
end

def xml_unescape(s)
  s.to_s.gsub('&lt;', '<').gsub('&gt;', '>').gsub('&quot;', '"')
   .gsub('&apos;', "'").gsub('&amp;', '&')
end

# --- W2.20 membership helpers ------------------------------------------------

# Match one --dashboard token against candidate dashboard names: exact
# (trimmed) → case-insensitive → unique substring (parse-twb-layout's
# documented semantics). nil = no unambiguous match.
def match_dashboard_name(target, names)
  t = target.to_s.strip
  return nil if t.empty?
  exact = names.find { |n| n.to_s.strip == t }
  return exact if exact
  ci = names.find { |n| n.to_s.strip.casecmp?(t) }
  return ci if ci
  subs = names.select { |n| n.to_s.downcase.include?(t.downcase) }
  subs.size == 1 ? subs.first : nil
end

# Resolve --dashboard targets to the member VIEW subset given a membership map
# {dashboard_name => [{'name' =>, 'luid' =>}, ...]}. Returns the view array,
# or nil when membership is UNRESOLVABLE (any unmatched target, empty map, or
# an all-hidden member set) — callers fall open to ALL views on nil, so this
# can only ever REMOVE fetches when membership is confidently known.
def scoped_views_for(targets, views, membership)
  return nil if membership.nil? || membership.empty?
  names = membership.keys
  subset = {}
  targets.each do |t|
    dn = match_dashboard_name(t, names)
    return nil unless dn
    (membership[dn] || []).each do |s|
      v = (views.find { |vv| vv['id'] == s['luid'] } if s['luid'].to_s != '')
      v ||= views.find { |vv| (vv['name'] || '').strip == s['name'].to_s.strip } ||
            views.find { |vv| (vv['name'] || '').strip.casecmp?(s['name'].to_s.strip) }
      if v
        subset[v['id']] = v
      else
        log "scope: member sheet #{s['name'].inspect} of #{dn.inspect} has no server view (hidden) — no CSV to fetch"
      end
    end
  end
  subset.empty? ? nil : subset.values
end

# Membership from the .twb XML (Metadata-API fallback): each <dashboard>'s
# zone name= attributes, intersected with the workbook's <worksheet> names so
# text/layout zones drop out naturally. Same regex style as the dashboards/
# PNG pass below. Returns {dashboard_name => [{'name' =>, 'luid' => nil}]}.
def twb_dashboard_membership(twb_xml)
  block = twb_xml[%r{<dashboards>.*?</dashboards>}m]
  return nil unless block
  ws_names = twb_xml.scan(/<worksheet\s[^>]*?name=(?:'([^']*)'|"([^"]*)")/)
                    .map { |sq, dq| xml_unescape(sq || dq) }.uniq
  membership = {}
  block.split(/(?=<dashboard[\s>])/).each do |seg|
    m = seg.match(/\A<dashboard\s[^>]*?name=(?:'([^']*)'|"([^"]*)")/)
    next unless m
    dname = xml_unescape(m[1] || m[2])
    zone_names = seg.scan(/<zone\s[^>]*?name=(?:'([^']*)'|"([^"]*)")/)
                    .map { |sq, dq| xml_unescape(sq || dq) }
    membership[dname] = (zone_names & ws_names).map { |n| { 'name' => n, 'luid' => nil } }
  end
  membership
end

# --- 1. Workbook (serial — everything else depends on the view list) --------
wb = run_task('get-workbook') do
  w = if opts[:workbook_id]
        Tableau.get_workbook(opts[:workbook_id])
      else
        hit = Tableau.find_workbook_by_name(opts[:workbook_name])
        abort "No workbook found with name=#{opts[:workbook_name]}" unless hit
        Tableau.get_workbook(hit['id'])
      end
  atomic_write(File.join(opts[:out], 'get-workbook.json'), JSON.pretty_generate(w))
  w
end
abort 'workbook fetch failed' unless wb
views = wb.dig('views', 'view') || []
views = [views] unless views.is_a?(Array)
log "wrote get-workbook.json  (id=#{wb['id']} views=#{views.size})"

# --- 1b. Capability banner ---------------------------------------------------
# Tableau Server can lack VDS and the Metadata API that Cloud always exposes.
# Announce the mode up front so an operator isn't left debugging why
# ds-metadata.json / graphql-fields.json never appeared — the .twb XML path
# covers both calc-formula sources when those services are off.
caps = (Tableau.capabilities rescue {})
if caps.any?
  meta_state = caps['metadata_api'] ? 'available' : 'OFF → calc formulas from .twb XML'
  log "capabilities: product=#{caps['product_version'] || '?'} " \
      "REST API=#{caps['rest_api_version'] || '?'}  Metadata API: #{meta_state}"
  log 'note: VDS is probed per-datasource below; on failure discovery falls back to the .twb XML.' unless caps['metadata_api']
end

# --- 1c. Dashboard→sheet membership at t≈0 (W2.20) ---------------------------
# A --dashboard-scoped mission fetches ONLY the target dashboards' member-sheet
# CSVs (the PNG ground-truth set is untouched — RCF needs every dashboard).
# Membership sources, in order: Metadata API (dashboards{name sheets{name
# luid}}) NOW — cheapest, one GraphQL round trip; else pre-parse the .twb the
# moment it lands (freshly-published workbooks lag the metadata index —
# membership may not exist there yet when discovery launches). UNRESOLVABLE
# membership falls open to ALL view CSVs: scoping is a speed lever, never a
# correctness gate, and the fallback is always stated, never silent. The probe
# itself is BOUNDED (MEMBERSHIP_BUDGET per attempt, 2 attempts): it runs
# serially before the pool, so a wedged Metadata API must never delay the very
# work scoping exists to speed up.
dash_targets = opts[:dashboards] || []
scoped_views = nil
membership_pending = false # true → the twb watcher owns the CSV enqueue
if dash_targets.any?
  if caps['metadata_api'] == false
    log 'scope: Metadata API is OFF — dashboard membership defers to the .twb pre-parse'
  else
    dashes = run_task('dashboard-membership', max_attempts: 2, budget: MEMBERSHIP_BUDGET,
                      budget_msg: "membership budget #{MEMBERSHIP_BUDGET}s exhausted — failing open") do
      Tableau.graphql_workbook_dashboards(wb['id'])
    end
    if dashes && !dashes.empty?
      membership = {}
      dashes.each { |d| membership[d['name'].to_s] = (d['sheets'] || []) }
      scoped_views = scoped_views_for(dash_targets, views, membership)
    end
    if scoped_views
      log "scope: #{dash_targets.map(&:inspect).join(', ')} → #{scoped_views.size} member-sheet CSV(s) " \
          "of #{views.size} view(s) (membership: metadata-api)"
    else
      log 'scope: membership not resolvable from the Metadata API ' \
          '(workbook unindexed, names unmatched, or probe abandoned)'
    end
  end
  membership_pending = scoped_views.nil? && !opts[:skip_content]
  if scoped_views.nil? && !membership_pending
    log "WARN: --dashboard membership UNRESOLVABLE (and --skip-content leaves no .twb to pre-parse) — " \
        "fetching ALL #{views.size} view CSVs (fail-open)"
  end
end

# --- 2. Build the task queue -------------------------------------------------
queue = Queue.new
twb_done = Queue.new # signals twb completion (for auto-ds fallback)

# Image lane (W2.20): ONE dedicated worker thread drains img_queue from t≈0 —
# every PNG goes through it, so image-with-image concurrency is impossible by
# construction while images overlap the CSV pool freely. pooled_pngs records
# view PNGs fetched THIS RUN (all image tasks run on the one worker thread, so
# plain hash access is safe); the dashboards/ pass reuses those bytes instead
# of re-rendering. A nil sentinel closes the queue: the watcher pushes it
# after enqueueing the dashboards/ set (or immediately below when no .twb
# task exists to wait for).
img_queue = Queue.new
pooled_pngs = {}
dash_png_stats = { expected: 0, fetched: 0 }

# 2a. twb download task (.twbx auto-extract preserved from the serial version)
unless opts[:skip_content]
  queue << lambda do
    bytes = run_task('twb-download', budget: opts[:download_budget] || DL_BUDGET_TWB) do
      Tableau.download_workbook_content(wb['id'])
    end
    # Persist the download (zip or bare .twb) and surface the inner XML.
    # The .twb is FCP-NORMALIZED at write time (lib/fcp_normalize) so every
    # downstream parser sees canonical element names — Tableau hides newer
    # design features (native rounded corners etc.) behind
    # `_.fcp.<Feature>.<bool>...` mangled names that literal-name XPaths
    # silently drop. Returns [twb_xml, had_hyper_payload].
    require_relative 'lib/fcp_normalize'
    persist = lambda do |payload|
      xml = nil
      hypers = false
      if payload.start_with?("PK\x03\x04")
        twbx_path = File.join(opts[:out], 'workbook-content.twbx')
        atomic_write(twbx_path, payload)
        log "wrote workbook-content.twbx  (#{payload.bytesize} bytes)"
        begin
          names  = ZipExtract.entries(twbx_path)
          hypers = names.any? { |n| n.downcase.end_with?('.hyper') } # from names — no inflation
          inner  = names.find { |n| n.downcase.end_with?('.twb') }
          if inner
            twb_path = File.join(opts[:out], 'workbook-content.twb')
            # Force UTF-8: the raw bytes may hold non-ASCII (em-dash, @handles,
            # curly quotes); force_encode so FcpNormalize + downstream regex don't
            # raise "invalid byte sequence in US-ASCII".
            xml = ZipExtract.read(twbx_path, inner).to_s.force_encoding('UTF-8')
            if FcpNormalize.needed?(xml)
              n = xml.scan(/_\.fcp\./).length
              xml = FcpNormalize.normalize(xml)
              log "FCP-normalized workbook XML (#{n} forward-compatibility token(s) → canonical names)"
            end
            atomic_write(twb_path, xml)
            log "extracted workbook-content.twb  (#{File.size(twb_path)} bytes) from .twbx"
          else
            log '.twbx contained no inner .twb — odd'
          end
        rescue StandardError => e
          log ".twbx read failed (#{e.message.to_s[0, 200]}); leaving .twbx in place"
        end
      else
        twb_path = File.join(opts[:out], 'workbook-content.twb')
        xml = payload.force_encoding('UTF-8')
        if FcpNormalize.needed?(xml)
          n = xml.scan(/_\.fcp\./).length
          xml = FcpNormalize.normalize(xml)
          log "FCP-normalized workbook XML (#{n} forward-compatibility token(s) → canonical names)"
        end
        atomic_write(twb_path, xml)
        log "wrote workbook-content.twb  (#{xml.bytesize} bytes)"
      end
      [xml, hypers]
    end

    twb_xml = nil
    begin
    if bytes
      twb_xml, had_hypers = persist.call(bytes)
      # EXTRACT-BACKED workbook, thin download: the default REST download
      # excludes the extract payload (includeExtract=false), so the .twbx has
      # NO Data/**/*.hyper inside — the extract-landing step needs it (three
      # independent field runs each hand-rewrote this re-fetch;
      # refs/extract-landing.md wrongly claimed discovery already had it).
      # Detect extract markers in the ACTUAL XML; the re-download WITH the
      # payload is OPT-IN (--extract-refetch) — it is the heaviest task in
      # discovery and only extract-landing routes consume the frozen bytes.
      # Non-extract workbooks never reach this branch at all.
      if twb_xml && !had_hypers &&
         (twb_xml.include?('<extract') || twb_xml =~ /class='(?:hyper|textscan)'/)
        if opts[:extract_refetch]
          # W2.21 size pre-abort — the thin-fetch decision is made BEFORE the
          # first byte: when Get Workbook's size attribute (MB) says the
          # payload cannot plausibly land within the derived-budget ceiling
          # even at the throughput floor, don't start a doomed fetch. An
          # explicit --download-budget disables this (operator asserted it).
          size_mb = wb['size'].to_f
          need = extract_seconds_needed(size_mb)
          if opts[:download_budget].nil? && need && need > DL_EXTRACT_CEIL
            log "WARN: extract re-fetch PRE-ABORTED before the first byte — Get Workbook reports #{size_mb.round} MB, " \
                "which needs >#{DL_EXTRACT_CEIL}s even at the #{DL_FLOOR_MB_S} MB/s floor. Proceeding with the thin .twb. " \
                'Pass --download-budget SECONDS to fetch anyway, or land the extract manually for land-extracts.py.'
          else
            log 'embedded extract detected but no .hyper payload in the download — re-fetching WITH includeExtract=true (--extract-refetch)'
            with_extract = run_task('twb-download-extract', max_attempts: 2,
                                    budget: extract_budget(size_mb, opts[:download_budget])) do
              Tableau.download_workbook_content(wb['id'], include_extract: true)
            end
            if with_extract && with_extract.bytesize > bytes.bytesize
              twb_xml2, had2 = persist.call(with_extract)
              twb_xml = twb_xml2 || twb_xml
              log had2 ? 'extract payload landed in workbook-content.twbx' :
                         'WARN: re-fetch still contained no .hyper — land-extracts.py will need a manual includeExtract=true download'
            elsif with_extract
              log 'WARN: includeExtract=true re-fetch returned nothing larger — proceeding with the thin .twb'
            else
              log 'WARN: extract re-fetch abandoned (task failure above) — proceeding with the thin .twb'
            end
          end
        else
          # One clear line, then move on. This is the breadcrumb for a landing
          # run that forgot the flag: without it, "land-extracts.py found no
          # .hyper" is undebuggable from the discovery log.
          log 'embedded extract detected — extract re-fetch SKIPPED (default; pass --extract-refetch when the frozen extract bytes must land, e.g. for land-extracts.py)'
        end
      end
    end
    ensure
      # Exactly-once, even when persist/normalize raises: the watcher blocks on
      # twb_done.pop and the pool spin loop waits on the watcher — a lost push
      # would hang discovery instead of failing it.
      twb_done << twb_xml
    end
  end
end

# 2b. datasource metadata tasks (VDS + GraphQL) — enqueued immediately when a
#     luid or name is supplied; otherwise chained after the twb task (the
#     .twb-caption auto-detect needs the downloaded XML).
ds_metadata_tasks = lambda do |ds_luid|
  queue << lambda do
    vds = run_task('vds-read-metadata') { Tableau.read_metadata(ds_luid) }
    if vds
      atomic_write(File.join(opts[:out], 'ds-metadata.json'), JSON.pretty_generate(vds))
      log "wrote ds-metadata.json  (#{vds.dig('data')&.size || 0} fields)"
    end
  end
  queue << lambda do
    gql = run_task('graphql-fields') { Tableau.graphql_datasource_fields(ds_luid) }
    if gql
      atomic_write(File.join(opts[:out], 'graphql-fields.json'), JSON.pretty_generate(gql))
      log 'wrote graphql-fields.json'
    end
  end
end

ds_luid = opts[:datasource_luid]
if ds_luid.nil? && opts[:datasource_name]
  hit = run_task('find-datasource') { Tableau.find_datasource_by_name(opts[:datasource_name]) }
  ds_luid = hit && hit['id']
end

auto_ds_pending = ds_luid.nil? && !opts[:no_auto_ds] && !opts[:skip_content]
ds_metadata_tasks.call(ds_luid) if ds_luid
if ds_luid.nil? && !auto_ds_pending
  warn 'no --datasource-luid/--datasource-name supplied (and auto-detect is unavailable); skipping VDS + GraphQL fetches'
end

# 2c. view PNG tasks — ON THE IMAGE WORKER from t≈0 (W2.20): the slow render
#     starts immediately and hides behind the CSV batch without ever running
#     beside another image.
case opts[:fetch_view_images]
when 'none'
  log 'skipping view images (--skip-images)'
when 'dashboard-only'
  # Heuristic: the view whose name matches "overview"/"dashboard", else the longest name.
  dash = views.find { |v| v['name'] =~ /\boverview\b|\bdashboard\b/i } ||
         views.max_by { |v| (v['name'] || '').length }
  if dash
    img_queue << lambda do
      png = run_task("png:#{dash['name']}") { Tableau.view_image(dash['id']) }
      if png
        atomic_write(File.join(opts[:out], 'views', "#{dash['id']}.png"), png)
        pooled_pngs[dash['id']] = true
        log "wrote views/#{dash['id']}.png  (dashboard: #{dash['name']}, #{png.bytesize} bytes)"
      end
    end
  end
when 'all'
  views.each do |v|
    img_queue << lambda do
      png = run_task("png:#{v['name']}") { Tableau.view_image(v['id']) }
      if png
        atomic_write(File.join(opts[:out], 'views', "#{v['id']}.png"), png)
        pooled_pngs[v['id']] = true
        log "wrote views/#{v['id']}.png  (#{v['name']})"
      end
    end
  end
end

# 2d. view CSV tasks — the member-sheet subset on resolved scoped missions;
# ALL views otherwise (unscoped, or membership unresolvable = fail-open). When
# membership is PENDING on the .twb, the watcher below enqueues instead.
enqueue_csv = lambda do |v|
  queue << lambda do
    csv = run_task("csv:#{v['name']}") { Tableau.view_data(v['id']) }
    if csv
      atomic_write(File.join(opts[:out], 'views', "#{v['id']}.csv"), csv)
      log "wrote views/#{v['id']}.csv  (#{v['name']}, #{csv.bytesize} bytes)"
    end
  end
end
if scoped_views
  scoped_views.each { |v| enqueue_csv.call(v) }
elsif membership_pending
  log 'scope: view-CSV enqueue deferred until the .twb lands (membership pre-parse)'
else
  views.each { |v| enqueue_csv.call(v) }
end

# 2e. ALL dashboard PNGs at resolution=high (RCF ground truth) — enqueued on
# the image worker by the watcher the moment the .twb lands. Without these the
# render-compare-fix visual loop is structurally impossible, so the set is
# NEVER scoped by --dashboard. run_task wraps each fetch (retry/backoff +
# timings; task names unchanged: dashboard-png:<name>). A views/<id>.png
# fetched this run is reused instead of re-rendered — the single image worker
# is FIFO, so the view PNGs (queued at t≈0) always land first.
enqueue_dashboard_pngs = lambda do |twb_xml|
  next if opts[:fetch_view_images] == 'none' || opts[:skip_content]
  dash_names = []
  if twb_xml
    block = twb_xml[%r{<dashboards>.*?</dashboards>}m] || ''
    dash_names = block.scan(/<dashboard\s[^>]*?name=(?:'([^']*)'|"([^"]*)")/)
                      .map { |sq, dq| xml_unescape(sq || dq) }
                      .uniq
  end
  if dash_names.empty?
    log 'no dashboards found in the .twb — skipping dashboards/ PNG set'
    next
  end
  FileUtils.mkdir_p(File.join(opts[:out], 'dashboards'))
  used_fnames = {}
  dash_names.each do |dname|
    v = views.find { |vv| (vv['name'] || '').strip == dname.strip } ||
        views.find { |vv| (vv['name'] || '').strip.casecmp?(dname.strip) }
    unless v
      log "dashboard #{dname.inspect}: no matching view (hidden/renamed on the server) — skipped"
      next
    end
    fname = dname.strip.gsub(/[^\w.-]+/, '_').gsub(/\A_+|_+\z/, '')
    fname = v['id'] if fname.empty?
    if (n = used_fnames[fname])
      used_fnames[fname] = n + 1
      fname = "#{fname}_#{n + 1}"
    else
      used_fnames[fname] = 1
    end
    dest = File.join(opts[:out], 'dashboards', "#{fname}.png")
    dash_png_stats[:expected] += 1
    img_queue << lambda do
      pooled = File.join(opts[:out], 'views', "#{v['id']}.png")
      if pooled_pngs[v['id']] && File.exist?(pooled)
        atomic_write(dest, File.binread(pooled))
        log "wrote dashboards/#{fname}.png  (reused views/#{v['id']}.png)"
        dash_png_stats[:fetched] += 1
      else
        png = run_task("dashboard-png:#{dname}") { Tableau.view_image(v['id'], resolution: 'high') }
        if png
          atomic_write(dest, png)
          log "wrote dashboards/#{fname}.png  (#{png.bytesize} bytes)"
          dash_png_stats[:fetched] += 1
        end
      end
    end
  end
end

# --- 3. Run the pool ----------------------------------------------------------
# Sizing counts CSVs still pending on the membership pre-parse — they arrive
# via the watcher after the .twb lands and must not run on a starved pool.
n_threads = [opts[:pool], queue.size + 1 + (membership_pending ? views.size : 0)].min
n_threads = 1 if n_threads < 1
log "pool: #{n_threads} threads, #{queue.size} queued tasks#{auto_ds_pending ? ' (+VDS/GraphQL after twb auto-detect)' : ''}" \
    "#{membership_pending ? ' (+scoped view CSVs after twb membership pre-parse)' : ''}"

# Post-.twb watcher: one consumer of twb_done that (a) finishes the W2.20
# membership fallback — the scoped (or fail-open ALL) CSV enqueue, (b) hands
# the dashboards/ PNG set to the image worker, and (c) runs the auto-ds chain
# enqueueing VDS/GraphQL. CSVs first: they feed the pool that is already
# running. The img_queue close rides an ensure so a raising watcher can never
# leave the image worker waiting forever.
watcher = nil
if opts[:skip_content]
  img_queue << nil # no .twb will land — nothing further can join the image lane
else
  watcher = Thread.new do
    twb_xml = twb_done.pop
    begin
    if membership_pending
      sv = twb_xml ? scoped_views_for(dash_targets, views, twb_dashboard_membership(twb_xml)) : nil
      if sv
        log "scope: #{dash_targets.map(&:inspect).join(', ')} → #{sv.size} member-sheet CSV(s) " \
            "of #{views.size} view(s) (membership: twb-preparse)"
        sv.each { |v| enqueue_csv.call(v) }
      else
        log "WARN: --dashboard membership UNRESOLVABLE (Metadata API and .twb pre-parse both came up empty) — " \
            "fetching ALL #{views.size} view CSVs (fail-open)"
        views.each { |v| enqueue_csv.call(v) }
      end
    end
    enqueue_dashboard_pngs.call(twb_xml)
    if auto_ds_pending && twb_xml.nil?
      log 'auto-detect skipped — no .twb content; skipping VDS/GraphQL'
    elsif auto_ds_pending
      caption = twb_xml.scan(/<datasource\s+caption='([^']+)'/).flatten
                       .reject { |c| c == 'Parameters' }
                       .first
      if caption
        bare = caption.sub(/\s*\+?\s*\(New Virtual Connection\)\s*$/i, '').strip
        found = nil
        %W[#{caption} #{bare}].uniq.each do |cand|
          hit = run_task("find-datasource:#{cand}") { Tableau.find_datasource_by_name(cand) }
          if hit
            found = hit['id']
            log "auto-detected datasource from .twb: #{cand.inspect} (luid=#{found})"
            break
          end
        end
        ds_metadata_tasks.call(found) if found
        log "could not resolve auto-detected datasource caption #{caption.inspect}; pass --datasource-luid to override" unless found
      else
        log 'auto-detect found no datasource caption in the .twb — skipping VDS/GraphQL'
      end
    end
    ensure
      img_queue << nil
    end
  end
end

# The dedicated image worker (W2.20): starts at t≈0, drains img_queue until
# the sentinel. ONE thread — the solo image constraint holds by construction.
img_worker = Thread.new do
  while (task = img_queue.pop)
    task.call
  end
  if dash_png_stats[:expected] > 0
    log "dashboards/: #{dash_png_stats[:fetched]}/#{dash_png_stats[:expected]} dashboard PNG(s) at resolution=high"
  end
end

pool = Array.new(n_threads) do
  Thread.new do
    loop do
      task = begin
               queue.pop(true)
             rescue ThreadError
               # queue momentarily empty — the auto-ds watcher may still add
               # tasks; spin until it's dead AND the queue is empty.
               if watcher && watcher.alive?
                 sleep 0.1
                 next
               end
               break
             end
      task.call
    end
  end
end
watcher&.join
pool.each(&:join)
img_worker.join # dashboards/ PNG set (enqueued by the watcher) drains here

# timings.json is ALWAYS written — it's the evidence trail when someone reports
# discovery slowness later (per-task start offsets show pool occupancy; attempts
# shows whether backoff/re-mint ever fired).
total = (Time.now.to_f - T0).round(3)
atomic_write(File.join(opts[:out], 'timings.json'),
             JSON.pretty_generate('total_seconds' => total, 'pool' => opts[:pool],
                                  'tasks' => TIMINGS.sort_by { |t| t['start'] }))
log "done. total=#{total}s (timings.json written)"
