# frozen_string_literal: true
# Writes this skill's degradation-ledger entries (convert-dm gaps, builder gaps, the --new-dm waiver, the
# RLS pending record) in the artifacts the VENDORED DegradationLedger.derive actually reads, so the final
# verdict is never GREEN while scope-cuts or quality gaps exist:
#
#   scope-cut entries                  -> <workdir>/coverage.json `unresolved` rows (severity dropped|degraded)
#   quality-waiver / recorded-escape /
#   anything else                      -> <workdir>/offramps.jsonl `skip-flag-waived` records
#
# Every row/record carries an `origin` tag; a later write with the same origin REPLACES the earlier rows
# (re-runs never accumulate stale entries). Ruby 2.6-compatible, stdlib only.

require 'json'

module LightdashLedger
  module_function

  # Replace this origin's rows. entries: DegradationLedger.entry hashes.
  def write(workdir, entries, origin:)
    cov_path = File.join(workdir, 'coverage.json')
    cov = read_json(cov_path)
    cov = {} unless cov.is_a?(Hash)
    rows = Array(cov['unresolved']).reject { |r| r.is_a?(Hash) && r['origin'] == origin }
    entries.select { |e| e['class'] == 'scope-cut' }.each do |e|
      rows << { 'severity' => e['item'].to_s.start_with?('tile ') ? 'dropped' : 'degraded',
                'visual' => e['item'], 'detail' => e['reason'], 'origin' => origin }
    end
    cov['unresolved'] = rows
    File.write(cov_path, JSON.pretty_generate(cov) + "\n")

    replace_offramps(workdir, origin, entries.reject { |e| e['class'] == 'scope-cut' }.map do |e|
      { 'kind' => 'skip-flag-waived', 'detail' => e['item'], 'reason' => e['reason'], 'origin' => origin }
    end)
  end

  # Replace the offramps.jsonl records of one origin with `records` (an empty list just clears them).
  def replace_offramps(workdir, origin, records)
    path = File.join(workdir, 'offramps.jsonl')
    keep = File.file?(path) ? File.readlines(path, encoding: 'UTF-8').reject { |l| origin_of(l) == origin } : []
    return if keep.empty? && records.empty? && !File.file?(path)
    File.write(path, keep.map { |l| l.end_with?("\n") ? l : "#{l}\n" }.join + records.map { |r| "#{JSON.generate(r)}\n" }.join)
  end

  def origin_of(line)
    (JSON.parse(line) || {})['origin']
  rescue JSON::ParserError
    nil
  end

  def read_json(path)
    File.file?(path) ? JSON.parse(File.read(path, encoding: 'UTF-8')) : nil
  rescue JSON::ParserError
    nil
  end
end
