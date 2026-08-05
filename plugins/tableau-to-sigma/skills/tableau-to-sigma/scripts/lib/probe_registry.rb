# frozen_string_literal: true
#
# probe_registry.rb — append-only LOCAL registry of throwaway Sigma artifacts
# (probe/scout workbooks + data models) created in a customer org (PLAN-v4
# E7.1). Field sessions left 30+ probe workbooks behind because every probe
# class orphans on process kill and no durable record of created ids existed.
#
# Contract:
#   - REGISTER AT CREATION TIME, before the first readback: a crash/SIGKILL
#     after the POST can then never orphan an id untraceably —
#     scripts/sweep-run-artifacts.rb deletes leftovers from this registry.
#   - Per-script at_exit/ensure cleanup stays the first line of defense; this
#     registry is the crash-path backstop, and cleanup appends a matching
#     record so the sweep (and the planned E7.4 gate) can tell cleaned from
#     outstanding.
#   - LOCAL state only: <workdir>/probe-artifacts.jsonl when the caller has a
#     workdir, else ~/.tableau-to-sigma/probe-artifacts.jsonl (dev probes).
#     Never committed (gitignored; CONTRIBUTING.md "Run state stays local").
#   - NEVER FATAL: registry I/O must not break a probe.
#
# Line shapes (append-only JSONL):
#   created:  {"id":"...","name":"...","created_at":"...Z","script":"..."}
#   cleaned:  {"id":"...","deleted_at":"...Z","via":"at_exit|ensure|sweep",
#              "outcome":"deleted|404|failed"}
# A reader distinguishes the two by created_at vs deleted_at. `outstanding`
# = created ids with no cleaned record whose outcome is deleted/404.

require 'json'
require 'fileutils'

module ProbeRegistry
  FILE_BASENAME = 'probe-artifacts.jsonl'

  module_function

  # Same home-override convention as learned-rules.rb.
  def home_dir
    ENV['TABLEAU_TO_SIGMA_HOME'] || File.expand_path('~/.tableau-to-sigma')
  end

  def path(workdir = nil)
    if workdir.to_s.empty?
      File.join(home_dir, FILE_BASENAME)
    else
      File.join(workdir, FILE_BASENAME)
    end
  end

  # Record a just-created artifact. Call IMMEDIATELY after the create response
  # parses, BEFORE any readback/export. Returns true when written.
  def created(id, name:, workdir: nil, script: nil)
    return false if id.to_s.empty?
    rec = { 'id' => id, 'name' => name,
            'created_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
    rec['script'] = script if script
    append(rec, workdir)
  end

  # Record a delete attempt's outcome ('deleted' | '404' | 'failed').
  def cleaned(id, workdir: nil, via: nil, outcome: 'deleted')
    return false if id.to_s.empty?
    rec = { 'id' => id, 'deleted_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'outcome' => outcome }
    rec['via'] = via if via
    append(rec, workdir)
  end

  # Parsed records, oldest first ([] on any error — a torn line never poisons).
  def entries(workdir = nil)
    p = path(workdir)
    return [] unless File.exist?(p)
    File.readlines(p).map { |l| JSON.parse(l) rescue nil }
        .select { |r| r.is_a?(Hash) && r['id'] }
  rescue StandardError
    []
  end

  # Created-but-not-cleaned records, oldest first. 404 counts as cleaned
  # (already gone); a 'failed' delete leaves the entry outstanding so the
  # sweep retries it.
  def outstanding(workdir = nil)
    done = {}
    entries(workdir).each do |r|
      done[r['id']] = true if r['deleted_at'] && %w[deleted 404].include?(r['outcome'].to_s)
    end
    entries(workdir).select { |r| r['created_at'] && !done[r['id']] }
  end

  def append(rec, workdir)
    p = path(workdir)
    FileUtils.mkdir_p(File.dirname(p))
    File.open(p, 'a') { |f| f.puts(JSON.generate(rec)) }
    true
  rescue StandardError
    false # bookkeeping only — never fail a probe on registry I/O
  end
end
