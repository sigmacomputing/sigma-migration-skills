#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sweep-run-artifacts.rb — delete probe/scout Sigma artifacts a crashed or
# killed run left behind in the customer org (PLAN-v4 E7.1; field sessions
# left 30+ probe workbooks in a customer workspace because every probe class
# orphans on process kill).
#
# Per-script at_exit/ensure cleanup is the first line of defense; this sweep
# is the crash-recovery path. Source preference order (BINDING — E7 sigma:ops
# amendment: prefer containment over smarter name matching):
#   1. THE REGISTRY — created-but-not-cleaned ids from
#      <workdir>/probe-artifacts.jsonl (--workdir) and the
#      ~/.tableau-to-sigma/probe-artifacts.jsonl dev fallback. Registry ids
#      were recorded by our own scripts at creation time: zero collision risk.
#   2. DEDICATED PROBE FOLDER LISTING (--folder-id, opt-in until the E7.2
#      per-run folder lands): enumerate ONLY that folder's children, delete
#      ONLY type=workbook entries — folder/workspace entries are hard-refused,
#      other types are named and skipped.
#   3. There is NO third source. This script NEVER pages the whole org's
#      /v2/files — every listing request carries parentId. A mistaken delete
#      of the skill's own probe is recoverable from Sigma's Trash by the
#      deleting user; a mistaken delete of customer content needs an Admin to
#      notice. We do not take that trade.
#
# DRY-RUN BY DEFAULT: prints the plan and touches nothing. --delete acts.
# Deleted documents land in Sigma's Trash, recoverable by the deleting user
# (https://help.sigmacomputing.com/docs/recover-deleted-documents).
#
# Every delete outcome is appended to the source registry ('deleted' | '404' —
# already gone, counts as cleaned | 'failed' — stays outstanding for the next
# sweep), so re-runs converge and the planned E7.4 gate can audit coverage.
#
# Usage:
#   ruby scripts/sweep-run-artifacts.rb [--workdir <WORK>] [--folder-id <id>]
#                                       [--delete]
#
# Exit codes: 0 = swept clean / nothing outstanding / dry-run printed;
#             1 = one or more DELETEs failed (re-run to retry);
#             2 = usage error.

require 'json'
require 'optparse'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'probe_registry'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR', 'conversion workdir whose probe-artifacts.jsonl to sweep') { |v| opts[:workdir] = v }
  p.on('--folder-id ID', 'dedicated probe folder to enumerate (listing stays inside this folder)') { |v| opts[:folder] = v }
  p.on('--delete', 'actually delete (default: dry-run, print the plan only)') { opts[:delete] = true }
end.parse!

if opts[:workdir] && !Dir.exist?(opts[:workdir])
  warn "[FAIL] sweep-run-artifacts: --workdir #{opts[:workdir]} does not exist"
  exit 2
end

# ---------------------------------------------------------------------------
# Collect candidates: {id => {name, created_at, source, registry_workdir}}.
# registry_workdir nil = the ~/.tableau-to-sigma home registry.
# ---------------------------------------------------------------------------
candidates = {}

add = lambda do |id, name, created_at, source, registry_workdir|
  candidates[id] ||= { 'name' => name, 'created_at' => created_at,
                       'source' => source, 'registry_workdir' => registry_workdir }
end

registries = []
registries << opts[:workdir] if opts[:workdir]
registries << nil # the home fallback is always swept (dev probes)
registries.each do |wd|
  ProbeRegistry.outstanding(wd).each do |r|
    add.call(r['id'], r['name'], r['created_at'],
             wd ? 'registry' : 'registry(home)', wd)
  end
end

# Folder listing (opt-in): ONLY the given folder's children, cursor-paged,
# workbooks only. Requires live creds even in dry-run (it lists).
folder_rows = []
if opts[:folder]
  require 'sigma_rest'
  cursor = nil
  loop do
    path = "/v2/files?parentId=#{opts[:folder]}&limit=200"
    path += "&page=#{cursor}" if cursor
    data = Sigma.request(:get, path)
    rows = data.is_a?(Hash) ? (data['entries'] || []) : []
    folder_rows.concat(rows)
    cursor = data.is_a?(Hash) ? data['nextPage'] : nil
    break if cursor.nil? || cursor.to_s.empty? || rows.empty?
  end
  folder_rows.each do |f|
    id = f['id'] || f['fileId']
    next if id.to_s.empty? || candidates.key?(id)
    type = f['type'].to_s
    if %w[folder workspace].include?(type)
      warn "  REFUSE  #{id}  type=#{type} #{f['name'].inspect} — folders/workspaces are never swept"
      next
    end
    unless type == 'workbook'
      warn "  SKIP    #{id}  type=#{type} #{f['name'].inspect} — folder mode deletes workbooks only"
      next
    end
    add.call(id, f['name'], f['createdAt'], 'folder-listing', opts[:workdir])
  end
end

if candidates.empty?
  puts '[OK] sweep-run-artifacts: nothing outstanding — registry clean' \
       "#{opts[:folder] ? ' and probe folder empty of workbooks' : ''}."
  exit 0
end

# ---------------------------------------------------------------------------
# Plan (dry-run prints and stops here).
# ---------------------------------------------------------------------------
puts "sweep-run-artifacts: #{candidates.size} leftover artifact(s):"
candidates.each do |id, c|
  puts format('  %-40s %-14s %-20s %s', id, c['source'], c['created_at'] || '-', c['name'])
end
unless opts[:delete]
  puts ''
  puts 'DRY-RUN (default) — nothing deleted. Re-run with --delete to remove these.'
  puts 'Deleted documents land in Sigma\'s Trash, recoverable by the deleting user.'
  exit 0
end

# ---------------------------------------------------------------------------
# Delete. 404 = already cleaned; failures stay outstanding for the next run.
# ---------------------------------------------------------------------------
require 'sigma_rest'
deleted = 0
gone    = 0
failed  = 0
candidates.each do |id, c|
  begin
    Sigma.request(:delete, "/v2/files/#{id}")
    ProbeRegistry.cleaned(id, workdir: c['registry_workdir'], via: 'sweep')
    puts "  DELETED #{id}  #{c['name']}"
    deleted += 1
  rescue StandardError => e
    if e.message.lines.first.to_s =~ /\b404\b/
      ProbeRegistry.cleaned(id, workdir: c['registry_workdir'], via: 'sweep', outcome: '404')
      puts "  GONE    #{id}  (404 — already cleaned)"
      gone += 1
    else
      ProbeRegistry.cleaned(id, workdir: c['registry_workdir'], via: 'sweep', outcome: 'failed')
      warn "  FAILED  #{id}  #{e.message.lines.first.to_s.strip}"
      failed += 1
    end
  end
end

puts "sweep-run-artifacts: #{deleted} deleted, #{gone} already gone, #{failed} failed" \
     ' (deleted documents are in Sigma\'s Trash, recoverable by the deleting user).'
exit(failed.zero? ? 0 : 1)
