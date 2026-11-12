# frozen_string_literal: true
#
# sdk_route.rb — Phase 5g HYBRID route ledger state (pure, IO-free).
#
# The hybrid route keeps the gated code-rep build and runs the RCF fix loop
# (and later edits) through the Sigma MCP Code Mode SDK instead of
# `fidelity-loop.rb apply-patch`. Each SDK write is recorded in
# fidelity-ledger.json under `sdk`, and the session ends with an export-back:
# the live code representation becomes <workdir>/wb-spec.json again and is
# re-gated (column guard, layout/control lint, phase-6 parity) before
# --finalize. See refs/phase-5g-sdk-hybrid.md.
#
# Ledger shape (additive; REST-only ledgers carry no `sdk` key):
#   "route": "sdk",
#   "sdk": { "state": <STATES>, "sessions": [ {id, checkpoint, base_version,
#            mcp_server, opened_at, needs_reread, writes:[], rereads:[],
#            exports:[] } ] }
module SdkRoute
  class Error < StandardError; end

  # reconciled = `fidelity-loop.rb recover` archived an open session's pending
  # marker without exporting it; a NEW session must be opened and exported.
  STATES = %w[open export-failed exported parity-failed parity-unverified rolled-back reconciled].freeze
  # States in which the session still holds repair-pending.json. An export
  # whose parity re-gate came back unverified keeps its session open, the way
  # a guard failure does: the next fix is a recorded sdk-write, or sdk-regate
  # with the missing actuals (2026-11-05 live proof, rough edge 1).
  OPEN_STATES = %w[open export-failed parity-unverified].freeze
  # States --finalize accepts.
  CLOSED_OK = %w[exported rolled-back].freeze
  PARITY_SOURCE = 'sdk-export-parity'

  module_function

  def now
    Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  end

  def sessions(ledger)
    sdk = ledger['sdk']
    sdk.is_a?(Hash) ? Array(sdk['sessions']) : []
  end

  def state(ledger)
    ledger['sdk'].is_a?(Hash) ? ledger['sdk']['state'] : nil
  end

  def last_session(ledger)
    sessions(ledger).last
  end

  # The session that still holds the pending marker, or nil.
  def open_session(ledger)
    OPEN_STATES.include?(state(ledger)) ? last_session(ledger) : nil
  end

  def begin_session!(ledger, checkpoint:, base_version:, mcp_server:)
    raise Error, 'an SDK session is already open; sdk-export (or rollback) it first' if open_session(ledger)
    max = ledger['max_passes'].to_i
    if max.positive? && ledger['pass'].to_i >= max
      raise Error, "RCF pass budget spent (#{ledger['pass']}/#{max}); the final budgeted REST render " \
                   'would be impossible after export — obtain an attributed `extend` first'
    end
    raise Error, '--mcp-server NAME required (the Sigma MCP server the SDK writes go through)' if mcp_server.to_s.strip.empty?
    ledger['route'] = 'sdk'
    sdk = (ledger['sdk'] ||= { 'sessions' => [] })
    sdk['sessions'] ||= []
    session = {
      'id' => "s#{sdk['sessions'].length + 1}", 'checkpoint' => checkpoint.to_s,
      'base_version' => base_version.to_s, 'mcp_server' => mcp_server.to_s, 'opened_at' => now,
      'needs_reread' => false, 'writes' => [], 'rereads' => [], 'exports' => []
    }
    sdk['sessions'] << session
    sdk['state'] = 'open'
    session
  end

  def require_open!(ledger)
    session = open_session(ledger)
    raise Error, 'no open SDK session — run `fidelity-loop.rb sdk-begin` first' unless session
    session
  end

  def add_write!(ledger, status:, summary:, program_sha256:, program_path:, document_version:,
                 result_sha256: nil, claims: [], error: nil, over_budget: false)
    session = require_open!(ledger)
    if session['needs_reread']
      raise Error, 'the previous SDK write FAILED and may have persisted partial state — re-read the page ' \
                   '(describe/get_table) and record it with `sdk-reread --evidence FILE` before another write'
    end
    raise Error, "--status must be ok or failed (got #{status.inspect})" unless %w[ok failed].include?(status)
    raise Error, '--summary required (what this write changed)' if summary.to_s.strip.empty?
    ids = Array(ledger['entries']).map { |e| e['id'] }
    unknown = Array(claims) - ids
    raise Error, "--claims names unknown ledger entr#{unknown.length == 1 ? 'y' : 'ies'}: #{unknown.join(', ')}" if unknown.any?
    write = {
      'id' => "w#{session['writes'].length + 1}", 'at' => now, 'status' => status,
      'summary' => summary, 'program_sha256' => program_sha256, 'program_path' => program_path,
      'result_sha256' => result_sha256, 'document_version' => document_version.to_s,
      'claims' => Array(claims), 'error' => error
    }
    # Recorded even past the repair clock: the SDK call already ran, and an
    # unrecorded write would only surface later as export drift.
    write['over_budget'] = true if over_budget
    session['writes'] << write
    session['needs_reread'] = true if status == 'failed'
    # Any write after an export makes that export stale.
    ledger['sdk']['state'] = 'open'
    write
  end

  def add_reread!(ledger, evidence_sha256:)
    session = require_open!(ledger)
    raise Error, 'no failed write is awaiting a re-read' unless session['needs_reread']
    last = session['writes'].last
    reread = { 'after' => last && last['id'], 'evidence_sha256' => evidence_sha256, 'at' => now }
    session['rereads'] << reread
    session['needs_reread'] = false
    reread
  end

  # The live version an export expects: the last recorded write (even a failed
  # one may have persisted), else the version the session started from.
  def expected_live_version(session)
    last = Array(session['writes']).last
    (last && !last['document_version'].to_s.empty? ? last['document_version'] : session['base_version']).to_s
  end

  # Mark every entry claimed by an `ok` write resolved, attributed to the route.
  def resolve_claims!(ledger, session)
    by_id = Array(ledger['entries']).to_h { |e| [e['id'], e] }
    resolved = []
    Array(session['writes']).select { |w| w['status'] == 'ok' }.each do |w|
      Array(w['claims']).each do |cid|
        entry = by_id[cid]
        next unless entry
        via = (entry['resolved_via'] ||= { 'route' => 'sdk', 'session' => session['id'], 'writes' => [] })
        via['writes'] |= [w['id']]
        entry['resolved'] = true
        resolved |= [cid]
      end
    end
    resolved
  end

  # May phase6-parity --finalize run on these actuals? Mirrors phase6-parity's
  # own pass-1 "collected" rule (rows, or the render-verify-required pivot
  # marker it resolves by render-read); too-large/timeout markers and missing
  # charts stay agent-mediated. A plan with no collectible charts (anchors /
  # anchors-warehouse oracle) defers to phase6 --finalize — that is a decision
  # for the verifier, never a reason to block forever.
  def actuals_complete?(plan, actuals)
    return [false, 'no readable parity-plan.json'] unless plan.is_a?(Hash)
    charts = Array(plan['charts']).select { |c| c.is_a?(Hash) }
    collectible = charts.select { |c| Array(c['sigma_columns']).length >= 1 }
    if collectible.empty?
      return [true, "no collectible charts (oracle_mode #{plan['oracle_mode'] || 'n/a'}) — phase6 --finalize decides"]
    end
    return [false, 'no readable parity-actuals.json'] unless actuals.is_a?(Hash)
    usable = lambda do |v|
      (v.is_a?(Array) && v.any?) || (v.is_a?(Hash) && v['status'] == 'render-verify-required')
    end
    missing = collectible.reject { |c| usable.call(actuals[c['chart']] || actuals[c['name']]) }
    return [false, "#{missing.size} exportable chart(s) not machine-collected (#{missing.map { |c| c['chart'] || c['name'] }.first(3).join(', ')})"] if missing.any?
    [true, "#{collectible.size} chart(s) collected"]
  end

  # result: 'pass' | 'fail' | 'unverified'. A divergence becomes a DATA-class
  # ledger entry (blocks gate 8d unconditionally); a later pass resolves it.
  def record_parity!(ledger, session, result:, exit_code:, detail: nil)
    export = Array(session['exports']).last
    raise Error, 'no export recorded for this session' unless export
    export['parity'] = result
    export['parity_exit'] = exit_code
    export['parity_detail'] = detail if detail
    entries = (ledger['entries'] ||= [])
    open_parity = entries.select { |e| e['source'] == PARITY_SOURCE && !e['resolved'] }
    case result
    when 'pass'
      open_parity.each do |e|
        e['resolved'] = true
        e['resolved_via'] = { 'route' => 'sdk', 'session' => session['id'], 'export_version' => export['document_version'] }
      end
      ledger['sdk']['state'] = 'exported'
    when 'fail'
      if open_parity.empty?
        entries << {
          'id' => "e#{entries.length}", 'pass' => ledger['pass'], 'dimension' => 'accuracy',
          'delta' => "phase-6 parity DIVERGED on the SDK-exported spec (document version #{export['document_version']})" \
                     "#{detail ? ": #{detail}" : ''}",
          'cls' => 'data', 'fix' => 'fix via another SDK session (or rollback), then sdk-export re-runs parity',
          'resolved' => false, 'route' => 'sdk', 'source' => PARITY_SOURCE
        }
      end
      ledger['sdk']['state'] = 'parity-failed'
    when 'unverified'
      ledger['sdk']['state'] = 'parity-unverified'
    else
      raise Error, "unknown parity result #{result.inspect}"
    end
    export
  end

  # nil when the LIVE workbook is still the one the route last exported.
  # A render proves only what was visible at a live version; it does not update
  # wb-spec.json, so it cannot make a later workbook version authoritative.
  def live_version_block_reason(ledger, live_version)
    return nil unless ledger.is_a?(Hash) && ledger['sdk'].is_a?(Hash) && state(ledger) == 'exported'
    export = Array((last_session(ledger) || {})['exports']).last
    return nil unless export
    known = export['document_version'].to_s
    return 'live workbook version could not be read; the SDK export cannot be confirmed current' if live_version.to_s.empty?
    return nil if live_version.to_s == known
    "live workbook is at document version #{live_version}, but the SDK route last exported #{known} — " \
      'an unrecorded write happened after sdk-export; open a session (sdk-begin), record it, and sdk-export again'
  end

  # Why render / apply-patch / sdk-begin refuse while `session` holds the
  # pending marker, naming the command that releases it.
  def open_block_message(ledger, session)
    id = session['id']
    if session['needs_reread']
      "SDK session #{id} is open and its last write FAILED (it may have persisted partial state) — " \
        're-read the page, record it with `fidelity-loop.rb sdk-reread --evidence FILE`, then `sdk-export`'
    elsif state(ledger) == 'parity-unverified'
      "SDK session #{id} is open: its export passed the guards but phase-6 parity is unverified — " \
        'supply the missing actuals with `fidelity-loop.rb sdk-regate --actuals FILE`, ' \
        'or fix with sdk-write and run `sdk-export` again'
    else
      "SDK session #{id} is open — run `fidelity-loop.rb sdk-export` first (render, apply-patch and " \
        'completion wait until its writes are exported back and re-gated; or rollback the session)'
    end
  end

  # The "no open session" refusal for sdk-write / sdk-reread / sdk-export.
  def closed_session_message(ledger)
    st = state(ledger)
    return 'no open SDK session — run `fidelity-loop.rb sdk-begin` before the first build_workbook call' if st.nil?
    why = case st
          when 'parity-failed' then 'its export closed it after phase-6 parity DIVERGED'
          when 'exported'      then 'its export closed it after phase-6 parity passed'
          when 'rolled-back'   then 'it was rolled back'
          when 'reconciled'    then '`recover` reconciled it without an export'
          else "its state is #{st.inspect}"
          end
    "no open SDK session (state #{st}: #{why}). Run `fidelity-loop.rb sdk-begin` BEFORE the next " \
      'build_workbook call. If that call already ran, sdk-begin now: its base is the live version, ' \
      'so the write is folded in unrecorded and re-gated by sdk-export — say so in the next --summary'
  end

  # nil when --finalize may proceed; else the reason it may not.
  def finalize_block_reason(ledger)
    return nil unless ledger.is_a?(Hash) && ledger['sdk'].is_a?(Hash)
    st = state(ledger)
    return nil if CLOSED_OK.include?(st)
    case st
    when 'open'              then 'an SDK session is open — its writes are not exported back to wb-spec.json; run `fidelity-loop.rb sdk-export`'
    when 'export-failed'     then 'the last sdk-export failed its guards — fix via SDK writes and re-run `fidelity-loop.rb sdk-export` (or rollback)'
    when 'parity-failed'     then 'phase-6 parity diverged on the SDK-exported spec — fix in a new SDK session, then sdk-export'
    when 'parity-unverified' then 'phase-6 parity on the SDK-exported spec is incomplete (the session stays open) — run `fidelity-loop.rb sdk-regate --actuals FILE`, or fix with sdk-write and sdk-export again'
    when 'reconciled'        then 'an SDK session was reconciled by `recover` without an export — open a new session (sdk-begin) and sdk-export it'
    else "unknown SDK route state #{st.inspect} in fidelity-ledger.json"
    end
  end
end
