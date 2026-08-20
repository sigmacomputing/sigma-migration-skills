#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-layout-contract-e2e.rb — LIVE go/no-go probe for the 2026-08-07
# spec-write contract (document.elements, every element placed, <Element>/
# <Container> tags). Creds-gated: needs a live Sigma org, so it is NOT part of
# the offline creds-free CI corpus. Mirrors verify-ws5-tabbed-e2e.rb.
#
# THE SURFACE UNDER TEST: POST /v2/workbooks/spec accepts a spec our emitters
# built. A WRONG LAYOUT TAG DOES NOT PRODUCE A VALIDATION MESSAGE — it returns
# an opaque {"message":"An error has occurred ... incident-id=..."} body. This
# script treats that as a HARD FAILURE, never as a transient outage.
#
# Usage: ruby shared/scripts/verify-layout-contract-e2e.rb <spec.json> [more...]
# Each <spec.json> is `{ document: { pages, elements, layout, ... }, ... }`. A
# top-level folderId/name and document.schemaVersion/kind are REQUIRED by the
# live API but resolved/backfilled here at run time when a fixture omits them
# (see ensure_postable! below) rather than hardcoded, since folderId is a
# live-org UUID the hygiene sweep blocks from tracked files. A caller passing
# its own fully-built spec (real converter output, own folderId already set)
# is untouched.
# Env (ALL from ENV — never hardcode ids; the hygiene sweep blocks them):
#   SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or SIGMA_API_TOKEN)
#   SIGMA_E2E_KEEP=1  — skip probe cleanup (default: delete by tracked id)
# Exit: 0 = every spec accepted + read back intact, or a clean SKIP.
#       1 = any spec rejected, altered on readback, or the probe broke.

require 'json'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'

def log(m) = puts("[layout-contract] #{m}")
def skip!(m)
  puts("SKIP: #{m}")
  exit 0
end

skip!('no spec files given') if ARGV.empty?
unless ENV['SIGMA_BASE_URL'] && (ENV['SIGMA_API_TOKEN'] ||
       (ENV['SIGMA_CLIENT_ID'] && ENV['SIGMA_CLIENT_SECRET']))
  skip!('no Sigma creds in env — live probe cannot run')
end

INCIDENT = /incident-id|An error has occurred/i

# POST /v2/workbooks/spec requires a top-level folderId (a live-org UUID) and
# name, plus document.schemaVersion (literal 1) and document.kind ("workbook")
# — confirmed live against the real 400 validation responses while building
# this harness. folderId is exactly the kind of live-org id the hygiene sweep
# blocks from tracked files, so testdata/*.json fixtures never carry one —
# this harness resolves the caller's own home folder at run time (same calls
# as verify-ws4-e2e.rb / verify-ws5-tabbed-e2e.rb) and fills in whatever the
# loaded spec doesn't already specify. A caller that already built a complete
# spec (real converter output with its own folderId) is untouched — this only
# backfills what's missing, so a minimal structural fixture can isolate the
# layout-tag question without embedding an org id.
#
# Some converter goldens under corpus/ (e.g. gooddata) are shared with the
# OFFLINE, creds-free corpus runner (corpus/run-corpus.sh), which stores
# goldens id-NORMALIZED (see corpus/README.md — "Goldens are id-normalized"):
# a real folderId a converter emitted gets rewritten to a stable placeholder
# token like "inode-FOLDER00" for byte-diffing. That's correct for the
# offline use case but is NOT a real UUID, so a *present-but-placeholder*
# folderId must be treated the same as a *missing* one here — otherwise this
# harness ships the placeholder straight to the live API, which 400s with
# "Expecting UUID at 0.folderId". Detect "present but not UUID-shaped" and
# backfill it too, rather than only checking presence.
DEFAULT_SCHEMA_VERSION = 1
DEFAULT_KIND = 'workbook'
UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

@home_folder_id = nil
def home_folder_id
  return @home_folder_id if @home_folder_id
  me = Sigma.request(:get, '/v2/whoami')
  uid = me && me['userId']
  raise 'could not resolve userId from /v2/whoami' unless uid
  mem = Sigma.request(:get, "/v2/members/#{uid}")
  home = mem && mem['homeFolderId']
  raise 'could not resolve homeFolderId' unless home
  @home_folder_id = home
end

def ensure_postable!(spec, path)
  filled = []
  existing = spec['folderId']
  if existing.nil?
    spec['folderId'] = home_folder_id
    filled << 'folderId'
  elsif !(existing.is_a?(String) && existing.match?(UUID_RE))
    log "  fixture folderId #{existing.inspect} is not a live UUID " \
        '(looks like an offline corpus normalization placeholder) — ' \
        'replacing with the resolved home folder, not posting it verbatim'
    spec['folderId'] = home_folder_id
    filled << 'folderId (placeholder replaced)'
  end
  unless spec['name']
    spec['name'] = "layout-contract-probe — #{File.basename(path)} — #{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
    filled << 'name'
  end
  doc = (spec['document'] ||= {})
  unless doc['schemaVersion']
    doc['schemaVersion'] = DEFAULT_SCHEMA_VERSION
    filled << 'document.schemaVersion'
  end
  unless doc['kind']
    doc['kind'] = DEFAULT_KIND
    filled << 'document.kind'
  end
  log "  auto-filled #{filled.join(', ')} (not present in the fixture; never hardcoded)" unless filled.empty?
  spec
end

# Count the structural facts that the contract break destroyed.
def shape(spec)
  doc = spec['document'] || spec
  xml = doc['layout'].to_s
  {
    elements:   (doc['elements'] || []).length,
    pages:      (doc['pages'] || []).length,
    containers: xml.scan(/<Container\b/).length,
    placed:     xml.scan(/<Element\b/).length,
    old_tags:   xml.scan(/<LayoutElement\b|<GridContainer\b/).length
  }
end

def probe(path)
  spec = JSON.parse(File.read(path))
  ensure_postable!(spec, path)
  want = shape(spec)
  log "#{File.basename(path)} — sending #{want[:elements]} elements, " \
      "#{want[:placed]} placed, #{want[:containers]} containers"

  begin
    raw = Sigma.request(:post, '/v2/workbooks/spec',
                        body: JSON.generate(spec), accept: 'application/json')
  rescue StandardError => e
    log "  REJECTED: #{e.message[0, 300]}"
    log '  ^ opaque incident-id => suspect your layout tags first' if e.message =~ INCIDENT
    return false
  end

  # Sigma.request(accept: 'application/json') already JSON.parses a 2xx body,
  # returning a Hash/Array/nil — NOT the raw wire string. Hash#to_s renders
  # Ruby inspect syntax ({"k"=>"v"}, no colon), which neither of the regexes
  # below would ever match, so every legitimate ACCEPT would misreport as
  # "no workbookId in response". Re-serialize to real JSON text first so the
  # string-shaped checks below see actual JSON, not Ruby's inspect format.
  body = raw.is_a?(String) ? raw : JSON.generate(raw)
  if body =~ INCIDENT
    log "  REJECTED (incident-id body): #{body[0, 300]}"
    log '  ^ this is YOUR layout tags, not a Sigma outage'
    return false
  end

  wb = body[/"workbookId"\s*:\s*"([^"]+)"/, 1] || body[/workbookId:\s*(\S+)/, 1]
  unless wb
    log "  REJECTED: no workbookId in response: #{body[0, 300]}"
    return false
  end
  log "  ACCEPTED workbookId=#{wb}"

  begin
    back  = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
    got   = shape(back.is_a?(String) ? JSON.parse(back) : back)
    ok    = %i[elements pages containers].all? { |k| got[k] == want[k] }
    log(ok ? "  READBACK intact: #{got.inspect}"
           : "  READBACK ALTERED: wanted #{want.inspect} got #{got.inspect}")
    ok
  ensure
    if ENV['SIGMA_E2E_KEEP'] == '1'
      log "  kept probe workbook #{wb} (SIGMA_E2E_KEEP=1)"
    else
      # Delete by the id we just created and tracked — never by name prefix.
      begin
        Sigma.request(:delete, "/v2/files/#{wb}")
        log "  cleaned up probe #{wb}"
      rescue StandardError => e
        log "  WARNING: probe #{wb} not deleted (#{e.message[0, 120]}) — remove by hand"
      end
    end
  end
end

results = ARGV.to_h { |p| [p, probe(p)] }
puts
puts format('%-58s %s', 'SPEC', 'VERDICT')
results.each { |p, ok| puts format('%-58s %s', File.basename(p), ok ? 'PASS' : 'FAIL') }
failed = results.count { |_, ok| !ok }
puts(failed.zero? ? 'ALL PASS' : "#{failed} FAILED")
exit(failed.zero? ? 0 : 1)
