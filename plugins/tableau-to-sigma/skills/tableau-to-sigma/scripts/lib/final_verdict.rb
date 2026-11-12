# frozen_string_literal: true
#
# FinalVerdict — the run's verdict is the WORSE of the gate's degradation-ledger
# verdict and the migration report's (migration-result.json) verdict.
#
# WHY: assert-phase6-ran.rb derives its verdict from the degradation ledger
# only, and in --finalize it runs BEFORE the final source-object census and
# the migration report exist. Source objects the census marks approximated /
# needs-review / skipped are not ledger entries, so an empty ledger let the
# gate (and, downstream, parity-final.json, phase6-success.json, the finalize
# STATUS line and verify-complete) claim GREEN while the report said YELLOW.
# Field case: the 2026-11-09 RCC re-finalize — empty ledger, 10 polish notes,
# census needs-review=3 / approximated=2: report YELLOW, every other surface
# GREEN. The minor-gaps-as-notes rule removed the residuals that used to mask it.
#
# Tableau-local (finalize + verify-complete). The Python profile already
# derives YELLOW from the census in assert-phase6-ran.py / verify-complete.py.
# Ruby 2.6-compatible, stdlib-only.

require 'json'

module FinalVerdict
  YELLOW_STATUSES = %w[approximated needs-review skipped].freeze
  BASIS = 'worse of the gate degradation-ledger verdict and migration-result.json'

  module_function

  # Census objects migration-result.json marks approximated / needs-review /
  # skipped, as { status => count } (only non-zero statuses).
  def yellow_objects(result)
    counts = Hash.new(0)
    Array(result.is_a?(Hash) ? result['source_objects'] : nil).each do |o|
      next unless o.is_a?(Hash) && YELLOW_STATUSES.include?(o['status'].to_s)

      counts[o['status'].to_s] += 1
    end
    counts
  end

  # The report-level verdict: migration-result.json's own verdict, raised to at
  # least YELLOW by any yellow-status source object (so a hand-edited 'verdict'
  # cannot hide the census). nil when there is no readable report.
  def report_level(result)
    return nil unless result.is_a?(Hash)

    v = result['verdict'].to_s.strip.upcase
    v = 'YELLOW' if v == 'GREEN' && yellow_objects(result).any?
    v.empty? ? nil : v
  end

  # The worse of a ledger verdict (GREEN | YELLOW | PARTIAL | PARTIAL+YELLOW,
  # GREEN possibly carrying the factory label) and a report verdict
  # (GREEN | YELLOW | RED | nil). A nil/GREEN report leaves the ledger verdict
  # (label included) untouched.
  def combine(ledger, report)
    ledger = ledger.to_s
    case report.to_s.upcase
    when 'RED' then 'RED'
    when 'YELLOW'
      base = ledger.split(' (').first.to_s
      if base == 'GREEN' || base.empty? then 'YELLOW'
      elsif base == 'PARTIAL' then 'PARTIAL+YELLOW'
      else base
      end
    else ledger
    end
  end

  # Finalize: combine the gate's minted verdict (phase6-success.json) with the
  # report and, when the report is worse, re-stamp BOTH gate markers
  # (phase6-success.json, parity-final.json): verdict = the run verdict,
  # gate_verdict = what the gate minted, verdict_basis = BASIS.
  # Returns [gate_verdict, run_verdict]; [nil, nil] when the gate minted none.
  def restamp(workdir, result)
    succ = (JSON.parse(File.read(File.join(workdir, 'phase6-success.json'))) rescue nil)
    gate = succ.is_a?(Hash) ? succ['verdict'] : nil
    return [nil, nil] if gate.to_s.empty?

    run = combine(gate, report_level(result))
    %w[phase6-success.json parity-final.json].each do |name|
      path = File.join(workdir, name)
      doc = (JSON.parse(File.read(path)) rescue nil)
      next unless doc.is_a?(Hash)

      if run != gate
        doc['gate_verdict'] = gate
        doc['verdict'] = run
        doc['verdict_basis'] = BASIS
      elsif doc.key?('gate_verdict') || doc.key?('verdict_basis')
        # a re-finalize that is no longer worse: drop the previous run's stamp
        doc.delete('gate_verdict')
        doc.delete('verdict_basis')
      else
        next
      end
      File.write(path, JSON.pretty_generate(doc) + "\n")
    end
    [gate, run]
  end

  # The finalize STATUS line: GREEN only when every gate passed AND the run
  # verdict is GREEN; a passing battery with a worse run verdict says so.
  def status_line(all_green, run_verdict, result)
    return 'NOT GREEN' unless all_green
    return 'GREEN' if run_verdict.nil? || run_verdict.to_s.split(' (').first == 'GREEN'

    "#{run_verdict} (all gates pass; #{report_reason(result)})"
  end

  # finalize-gates.json for the shared migration report (its finalize-gates
  # check): each finalize gate's PASS/FAIL and exit code, written BEFORE the
  # report is built so a failed hard gate can never leave migration-result.json
  # GREEN (2026-11-09 Complex Pivot: gate 14 failed, report GREEN). gates is
  # { name => Process::Status | true/false | [ok, exitstatus] }.
  def write_finalize_gates(workdir, gates)
    rows = gates.each_with_object({}) do |(name, st), out|
      ok, code = if st.is_a?(Array) then [st[0], st[1]]
                 elsif st.respond_to?(:success?) then [st.success?, st.exitstatus]
                 else [st, nil]
                 end
      row = { 'status' => ok ? 'PASS' : 'FAIL' }
      row['exit'] = code if !ok && code
      out[name.to_s] = row
    end
    File.write(File.join(workdir, 'finalize-gates.json'),
               JSON.pretty_generate('schema' => 'finalize-gates/v1', 'gates' => rows) + "\n")
    rows
  end

  # One line naming why the report is worse than the ledger, e.g.
  # "migration report YELLOW: 3 needs-review, 2 approximated source object(s)".
  def report_reason(result)
    counts = yellow_objects(result)
    v = report_level(result)
    return "migration report #{v}" if counts.empty?

    "migration report #{v}: " + counts.map { |s, n| "#{n} #{s}" }.join(', ') + ' source object(s)'
  end
end
