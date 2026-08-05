# frozen_string_literal: true
#
# PbiOfframp — classify WHY the mechanical workbook path failed, from the output it
# actually captured, instead of asserting a cause it never established.
#
# THE BUG (hit during a live E2E, 2026-07-30). A run built its workbook, POSTED it
# successfully, and then failed LAYOUT LINT on a tile-height violation. The offramp said:
#
#     The WORKBOOK layer hit some field(s) the mechanical path can't translate
#     (one or more fields). Falling back to the agent path...
#
# There was no untranslatable field. `run_wb!` captures the real error into
# WorkbookBuildError#captured_output, but the handler printed only its own guess: when
# `cull_failed_fields` found no field name it fell back to the phrase "one or more
# fields" REGARDLESS of what had failed. So a one-line tile-height fix was reported as a
# field-translation failure and the operator was sent to rebuild the entire workbook via
# the agent path.
#
# That is the same class of defect as a coverage headline reading "0 dropped" while half
# the bindings were pruned: the run reports a cause it did not establish. The rule here is
# that an undetermined cause must be REPORTED as undetermined, with the captured output
# shown, never dressed up as a specific one.
module PbiOfframp
  module_function

  # captured : the combined stdout/stderr of the failing step
  # failed   : field names culled by the caller (cull_failed_fields), may be empty
  # ->  { 'stage', 'message', 'salient', 'posted' }
  #       stage  : 'layout-lint' | 'post' | 'validate-spec' | 'build' | 'unknown'
  #       posted : true when the output shows the workbook DID post (so the fix is a PUT,
  #                not an agent-path rebuild — re-POSTing would orphan the workbook)
  def classify(captured, failed = [])
    out = captured.to_s
    named = Array(failed).reject { |f| f.to_s.strip.empty? }

    if out =~ /layout lint:/i || out =~ /tile below minimum height/i
      return { 'stage' => 'layout-lint', 'posted' => posted?(out),
               'salient' => salient(out, /tile below minimum|layout lint:|violation/i),
               'message' =>
                 'the LAYOUT step rejected the spec (layout lint), not a field translation. ' \
                 'The data model and workbook are posted and usable — fix the layout and re-apply ' \
                 'with PUT /v2/workbooks/<id>/spec (re-POSTing creates an orphan).' }
    end

    if out =~ /POST\s+\/v2\/workbooks/i || out =~ /->\s*(4\d\d|5\d\d)\b/
      return { 'stage' => 'post', 'posted' => false,
               'salient' => salient(out, /Invalid value|message"|->\s*\d{3}/i),
               'message' => 'the workbook POST was REJECTED by the API. The captured response is ' \
                            'below; the data model is posted and can be attached.' }
    end

    if out =~ /Dependency not found|--- \d+ errors?/i || !named.empty?
      msg = if named.empty?
              'the workbook SPEC failed validation. The captured errors are below.'
            else
              "#{named.size} field(s) the mechanical path could not translate (#{named.join(', ')})."
            end
      return { 'stage' => 'validate-spec', 'posted' => posted?(out),
               'salient' => salient(out, /Dependency not found|errors?/i), 'message' => msg }
    end

    if out =~ /\[build-workbook\].*(ERROR|FATAL)/i
      return { 'stage' => 'build', 'posted' => false,
               'salient' => salient(out, /ERROR|FATAL/i),
               'message' => 'the workbook BUILD step failed. The captured error is below.' }
    end

    # Nothing matched. Say so — do NOT claim a field-translation failure, which is what the
    # old code did unconditionally.
    { 'stage' => 'unknown', 'posted' => posted?(out),
      'salient' => salient(out, /./),
      'message' => 'the mechanical workbook path failed and this run could not determine the ' \
                   'cause from its output — the captured output is below verbatim. Do not assume a ' \
                   'field-translation problem; read it before choosing a fix.' }
  end

  # The workbook posted when the output says so — the fix is then a PUT, and re-POSTing
  # would leave an orphan.
  def posted?(out)
    !!(out =~ /POST ok: workbookId=/i || out =~ /workbook DID post/i)
  end

  # The few most relevant lines of the captured output, so the operator sees evidence
  # rather than a summary. Blank input yields ''.
  def salient(out, pattern, limit = 4)
    lines = out.to_s.lines.map(&:rstrip).reject { |l| l.strip.empty? }
    hits = lines.select { |l| l =~ pattern }
    (hits.empty? ? lines : hits).first(limit).join("\n")
  end
end
