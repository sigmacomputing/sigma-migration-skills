# frozen_string_literal: true
#
# phase_cache.rb — sha-stamped phase-output reuse for orchestrator RE-ENTRIES
# (speed workstream: refs/performance.md).
#
# The migration loop is DESIGNED to re-enter migrate-tableau.rb several times
# (exit 10 decisions → exit 11 gap scout → exit 4 workbook handoff → exit 12
# actuals → --finalize). Field timing showed each re-entry re-paying pure
# functions of unchanged inputs — parse-twb-layout, calc extraction, the
# custom-SQL scan — because their outputs, while on disk, carried no record of
# WHAT input produced them. This module is that record: a single
# <workdir>/phase-cache-stamps.json mapping phase → { input-key, outputs }.
#
# Contract:
#   * key    — a digest of the phase's INPUTS (e.g. the .twb sha256 + scope
#              flags). Same key + outputs present ⇒ the phase may be skipped.
#   * outputs — files the phase must have produced. Any missing ⇒ never fresh
#              (a half-written phase is re-run, not trusted).
#   * stamps are only written AFTER the block produced every output, so a
#              failed/partial phase is never blessed for reuse.
#   * escape hatch — delete phase-cache-stamps.json (or the output file) to
#              force a re-run; stamps are advisory metadata, never load-bearing
#              state (losing the file only costs a re-compute).
#
# TTL is deliberately NOT part of freshness: these phases are pure functions
# of on-disk inputs, so "how old" is irrelevant — only "did the input change".
# (Caches over LIVE external state — the DM-reuse scan in find-or-pick-dm.rb —
# add their own staleness bound on top.)

require 'json'
require 'time'
require 'digest'

module PhaseCache
  STAMP_BASENAME = 'phase-cache-stamps.json'

  def self.path(workdir)
    File.join(workdir, STAMP_BASENAME)
  end

  def self.load(workdir)
    doc = JSON.parse(File.read(path(workdir)))
    doc.is_a?(Hash) ? doc : {}
  rescue StandardError
    {}
  end

  # sha256 of a file's CONTENT (nil when absent) — mtime is not trusted
  # (checkouts, copies and clock skew all rewrite mtimes without changing bytes).
  def self.file_sha(file)
    File.file?(file) ? Digest::SHA256.file(file).hexdigest : nil
  end

  # Digest an input tuple into one stable key string.
  def self.key(*parts)
    Digest::SHA256.hexdigest(parts.map(&:to_s).join("\x1f"))
  end

  # true ⇔ the phase's recorded input key matches AND every output exists.
  def self.fresh?(workdir, phase, key:, outputs: [])
    st = load(workdir)[phase.to_s]
    return false unless st.is_a?(Hash)
    st['key'] == key && Array(outputs).all? { |o| File.exist?(o) }
  end

  def self.stamp!(workdir, phase, key:, outputs: [])
    st = load(workdir)
    st[phase.to_s] = {
      'key' => key,
      'outputs' => Array(outputs).map { |o| File.basename(o) },
      'stamped_at' => Time.now.utc.iso8601
    }
    File.write(path(workdir), JSON.pretty_generate(st))
  end

  # Run the block only when the stamp is stale or an output is missing.
  # Returns :reused (block skipped) or :ran. The stamp is written only when
  # every declared output exists after the block — partial work is never blessed.
  def self.cached(workdir, phase, key:, outputs: [])
    return :reused if fresh?(workdir, phase, key: key, outputs: outputs)
    yield
    stamp!(workdir, phase, key: key, outputs: outputs) if Array(outputs).all? { |o| File.exist?(o) }
    :ran
  end
end
