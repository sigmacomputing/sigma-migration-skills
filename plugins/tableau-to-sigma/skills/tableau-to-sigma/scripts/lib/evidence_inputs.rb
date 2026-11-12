# frozen_string_literal: true

require 'digest'
require 'json'

# evidence_inputs.rb — what a derived evidence artifact was computed FROM.
#
# WHY: numeric-parity.json (gate 18) was judged fresh by its plan timestamp
# alone; after the workbook changed and anchors were added the preflight still
# accepted it and verify-ground-truth.rb had to be re-run by hand (live
# re-proof). verify-ground-truth.rb now stamps the digest of its inputs; the
# finalize preflight recomputes it and treats any difference as stale.
# Inputs: the anchors verdict (it carries the export's workbook document
# version), ground-truth actuals, the Sigma actuals, the source anchors and
# the persisted live spec wb-spec.json (apply-patch and pass-1 rebuilds
# rewrite it — a changed workbook invalidates the numeric comparison).
module EvidenceInputs
  GT_FILES = %w[anchors-verdict.json ground-truth-actuals.json source-anchors.json wb-spec.json].freeze

  module_function

  # { 'files' => { name => sha256|nil }, 'digest' => sha256 }
  def gt_fingerprint(dir, sigma_actuals: nil)
    paths = GT_FILES.map { |f| [f, File.join(dir.to_s, f)] }
    paths << ['sigma-actuals', sigma_actuals || File.join(dir.to_s, 'parity-actuals.json')]
    files = paths.each_with_object({}) do |(name, p), h|
      h[name] = File.file?(p.to_s) ? Digest::SHA256.file(p.to_s).hexdigest : nil
    end
    { 'files' => files, 'digest' => Digest::SHA256.hexdigest(JSON.generate(files.sort.to_h)) }
  end

  # Names of the inputs that changed since the stamp (empty = fresh).
  def changed(stamp, now)
    return ['(no input stamp — written before stamping)'] unless stamp.is_a?(Hash) && stamp['files'].is_a?(Hash)
    now['files'].keys.select { |k| stamp['files'][k] != now['files'][k] }
  end
end
