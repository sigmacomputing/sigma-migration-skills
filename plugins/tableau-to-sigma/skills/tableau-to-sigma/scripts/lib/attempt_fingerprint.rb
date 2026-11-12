# frozen_string_literal: true

require 'digest'
require 'json'

# attempt_fingerprint.rb — fold the INPUT SPEC into a loop-breaker context.
#
# WHY: the exit-4 breaker keyed its repeat / no-progress rules on the error
# text alone, so an operator who changed the spec between two re-entries and
# hit a similar-looking error was told "re-running will not converge" after 2
# attempts (live proof). The attempt is only a repeat when the INPUT is the
# same too: the context carries a digest of the spec file(s) that drove it.
# The attempt cap (scope-based) still bounds a spec that keeps changing.
module AttemptFingerprint
  module_function

  # Short content digest over the given files (missing / unreadable ones are
  # skipped; nil when none could be read).
  def digest(paths)
    files = Array(paths).compact.map(&:to_s).reject(&:empty?).uniq.select { |p| File.file?(p) }
    return nil if files.empty?

    sha = Digest::SHA256.new
    files.each do |p|
      sha << File.basename(p) << "\0"
      sha << (File.binread(p) rescue '') << "\0"
    end
    sha.hexdigest[0, 12]
  end

  # "exit4" → "exit4:spec=<digest>" (unchanged when nothing could be read).
  def context(base, paths)
    d = digest(paths)
    d ? "#{base}:spec=#{d}" : base.to_s
  end

  # Agent-changed inputs of a --finalize attempt (live re-proof: two finalizes
  # with identical failing-gate statuses were counted as grinding although the
  # agent had added anchors and re-run ground truth between them). Only files
  # an AGENT changes between attempts — never artifacts the finalize itself
  # rewrites each run (that would make every attempt look like progress).
  # Ledgers the preflight re-derives (lod-audit / join-plan) contribute only
  # their recorded resolutions.
  FINALIZE_FILES = %w[source-anchors.json png-read.json controls-waivers.json waivers.json manual-residues.json
                      semantic-edits.json blind-grade.json wb-spec.json].freeze
  RESOLUTION_LEDGERS = %w[lod-audit.json join-plan.json fidelity-ledger.json].freeze

  def finalize_digest(work, actuals: nil)
    sha = Digest::SHA256.new
    (FINALIZE_FILES.map { |f| File.join(work.to_s, f) } + [actuals].compact).each do |p|
      next unless File.file?(p.to_s)
      sha << File.basename(p.to_s) << "\0" << (File.binread(p.to_s) rescue '') << "\0"
    end
    RESOLUTION_LEDGERS.each do |f|
      doc = (JSON.parse(File.read(File.join(work.to_s, f))) rescue nil)
      list = doc.is_a?(Hash) ? Array(doc['entries']) : Array(doc)
      res = list.map { |e| e.is_a?(Hash) ? [e['resolution'], e['resolved'], e['status']] : nil }
      sha << f << "\0" << JSON.generate(res) << "\0"
    end
    sha.hexdigest[0, 12]
  end

  # "finalize" → "finalize:inputs=<digest>"
  def finalize_context(work, actuals: nil)
    "finalize:inputs=#{finalize_digest(work, actuals: actuals)}"
  end

  # The spec files that are this attempt's input: the operator's --wb-spec /
  # --dm-spec when given (the re-entry route), else the generated spec.
  def input_specs(wb_spec_opt:, dm_spec_opt:, generated_wb_spec:)
    given = [wb_spec_opt, dm_spec_opt].compact.map(&:to_s).reject(&:empty?)
    given.empty? ? [generated_wb_spec] : given
  end
end
