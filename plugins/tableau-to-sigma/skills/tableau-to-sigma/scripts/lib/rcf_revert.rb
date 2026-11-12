# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'time'

# rcf_revert.rb — keep fidelity-ledger.json honest across a pass-1 re-run.
#
# WHY: a 5g `apply-patch` repairs the LIVE workbook; re-running pass 1 then
# rebuilds the spec from the converter and PUTs it in place, reverting every
# RCF repair — while fidelity-ledger.json still says those deltas are
# resolved (live re-proof: the header-band layout patch was reverted and the
# ledger kept e1 resolved). The ledger and the live workbook then disagree
# silently and the 8d gate passes on stale evidence.
#
#   record_patch!  — apply-patch saves each applied patch under
#                    <WORK>/rcf-patches/ (+ rcf-patches.jsonl), so it can be
#                    re-applied verbatim.
#   reopen_after_rebuild! — after the orchestrator re-PUTs a rebuilt spec over
#                    the ledger's workbook, every resolved spec-fixable entry is
#                    REOPENED (resolved:false + a `reopened` note) and the exact
#                    re-apply commands are returned. The 8d gate then blocks
#                    until they are re-applied (or re-recorded), never silently.
module RcfRevert
  LOG = 'rcf-patches.jsonl'
  DIR = 'rcf-patches'

  module_function

  def log_path(work)
    File.join(work.to_s, LOG)
  end

  def patches(work)
    return [] unless File.file?(log_path(work))
    File.readlines(log_path(work)).map { |l| (JSON.parse(l) rescue nil) }.compact
  end

  # patch_text: the JSON text apply-patch merged. Returns the log record.
  def record_patch!(work, patch_text, resolves: [], document_version: nil)
    sha = Digest::SHA256.hexdigest(patch_text.to_s)
    FileUtils.mkdir_p(File.join(work, DIR))
    n = patches(work).size + 1
    path = File.join(work, DIR, format('%03d-%s.json', n, sha[0, 12]))
    File.write(path, patch_text)
    rec = { 'n' => n, 'sha256' => sha, 'path' => path, 'resolves' => Array(resolves).map(&:to_s),
            'document_version' => document_version.to_s, 'at' => Time.now.utc.iso8601 }
    File.open(log_path(work), 'a') { |f| f.puts(JSON.generate(rec)) }
    rec
  end

  def applied_sha?(work, patch_text)
    sha = Digest::SHA256.hexdigest(patch_text.to_s)
    patches(work).any? { |p| p['sha256'] == sha }
  end

  # Returns { reopened: [entry ids], commands: [String] } (empty when the
  # ledger is for another workbook, or no repair was ever written).
  def reopen_after_rebuild!(work, workbook_id:)
    lp = File.join(work.to_s, 'fidelity-ledger.json')
    ledger = (JSON.parse(File.read(lp)) rescue nil)
    return { reopened: [], commands: [] } unless ledger.is_a?(Hash) && ledger['workbook_id'].to_s == workbook_id.to_s

    logged = patches(work)
    wrote = logged.any? || Dir.exist?(File.join(work.to_s, 'repair-checkpoints'))
    return { reopened: [], commands: [] } unless wrote

    reopened = []
    Array(ledger['entries']).each do |e|
      next unless e.is_a?(Hash) && e['resolved'] == true && e['cls'] == 'spec-fixable'
      e['resolved'] = false
      e['reopened'] = { 'reason' => 'pass-1 re-run re-PUT the rebuilt spec in place; the RCF repair that resolved ' \
                                     'this entry is no longer live', 'at' => Time.now.utc.iso8601 }
      reopened << e['id']
    end
    File.write(lp, JSON.pretty_generate(ledger)) if reopened.any?
    cmds = logged.map do |p|
      res = p['resolves'].empty? ? '' : " --resolves #{p['resolves'].join(',')}"
      "ruby scripts/fidelity-loop.rb apply-patch --workdir #{work} --patch #{p['path']}#{res}"
    end
    { reopened: reopened, commands: cmds }
  end
end
