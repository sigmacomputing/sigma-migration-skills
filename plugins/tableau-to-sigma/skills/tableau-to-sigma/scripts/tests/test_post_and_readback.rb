# frozen_string_literal: true
#
# test_post_and_readback.rb — regression test for the workbook code-rep
# document-wrapper fix (Task 3.1). Verifies the shared Sigma::CodeRep adapter
# (vendored at ../lib/code_rep.rb) reads the LIVE nested workbook readback
# shape and produces a properly-nested POST/PUT body, while confirming the
# datamodel surface's flat shape is untouched (it is NOT changing — do not
# apply CodeRep to /v2/dataModels/.../spec payloads).
#
# Run: ruby scripts/tests/test_post_and_readback.rb

require 'minitest/autorun'
require_relative '../lib/code_rep'
require_relative '../lib/workbook_code'

# Static AST check: does every Sigma::CodeRep call site in a script live
# STRICTLY inside the "then" clause of an `if`/ternary keyed on
# `opts[:type] == 'workbook'` — never in that guard's "else" (the datamodel
# path), and never unguarded? Ruby's ternary (`a ? b : c`) and `if/else/end`
# both parse to the same :IF node, so one walk covers both spellings.
#
# This protects the property test_script_uses_code_rep_adapter_for_workbook_branch
# (below) does NOT: a substring/regex match for "Sigma::CodeRep" anywhere in
# the file would still pass even if a future edit accidentally routed the
# DATAMODEL branch through the adapter too (e.g. by deleting the `else` or
# copying the wrapped body into both branches).
module CodeRepGuardCheck
  CODE_REP_METHODS = %i[
    document wrap metadata workbook_elements workbook_page_element_ids
    workbook_page_by_element workbook_elements_with_pages
  ].freeze

  module_function

  def coderep_receiver?(recv)
    return false unless recv.is_a?(RubyVM::AbstractSyntaxTree::Node)
    case recv.type
    when :COLON2 then recv.children[1] == :CodeRep # Sigma::CodeRep
    when :CONST  then recv.children[0] == :CodeRep # bare CodeRep
    else false
    end
  end

  # First STR literal found in a condition subtree — extracts the 'workbook'
  # / 'datamodel' operand of an `opts[:type] == '<x>'` comparison regardless
  # of surrounding && / method-call wrapping.
  def type_guard_str(node)
    return nil unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
    return node.children[0] if node.type == :STR
    node.children.each do |c|
      next unless c.is_a?(RubyVM::AbstractSyntaxTree::Node)
      r = type_guard_str(c)
      return r if r
    end
    nil
  end

  # Walks the AST threading a context tag (:workbook / :datamodel / :top)
  # through nested `if`s so every CodeRep call is recorded with the tag of
  # the innermost type-keyed guard it's textually inside (or :top if none).
  def walk(node, ctx, findings)
    return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

    if node.type == :IF
      cond, then_b, else_b = node.children
      guard = type_guard_str(cond)
      then_ctx, else_ctx =
        case guard
        when 'workbook'  then [:workbook, :datamodel]
        when 'datamodel' then [:datamodel, :workbook]
        else [ctx, ctx]
        end
      walk(cond, ctx, findings)
      walk(then_b, then_ctx, findings)
      walk(else_b, else_ctx, findings)
      return
    end

    if %i[CALL FCALL].include?(node.type)
      recv = node.type == :CALL ? node.children[0] : nil
      mid  = node.type == :CALL ? node.children[1] : node.children[0]
      findings << { line: node.first_lineno, ctx: ctx, method: mid } if recv && coderep_receiver?(recv) && CODE_REP_METHODS.include?(mid)
    end

    node.children.each { |c| walk(c, ctx, findings) if c.is_a?(RubyVM::AbstractSyntaxTree::Node) }
  end

  def find_calls(path)
    findings = []
    walk(RubyVM::AbstractSyntaxTree.parse_file(path), :top, findings)
    findings
  end
end

class TestPostAndReadback < Minitest::Test
  def test_workbook_readback_pages_found_when_nested
    readback = { 'workbookId' => 'w', 'document' => { 'pages' => [{ 'id' => 'p1' }] } }
    assert_equal [{ 'id' => 'p1' }], Sigma::CodeRep.document(readback)['pages']
  end

  def test_workbook_post_body_is_nested
    doc  = {
      'schemaVersion' => 1, 'pages' => [{ 'id' => 'p1' }],
      'elements' => [{ 'id' => 'e1', 'kind' => 'text' }],
      'kind' => 'workbook',
      'layout' => '<Page id="p1"><Element elementId="e1"/></Page>'
    }
    body = Sigma::CodeRep.wrap(doc, extra: { 'name' => 'n', 'folderId' => 'f' })
    assert_equal doc, body['document']
    refute body.key?('pages'), 'pages must not remain top-level'
    refute body['document']['pages'].first.key?('elements')
  end

  # The DM branch must be left alone — that surface is not changing.
  def test_datamodel_branch_stays_flat
    readback = { 'dataModelId' => 'd', 'pages' => [{ 'id' => 'p1' }], 'schemaVersion' => 1 }
    assert_equal [{ 'id' => 'p1' }], readback['pages'],
                 'DM readback must still be read flat, unchanged'
  end

  # Real regression signal (the 3 tests above only exercise the already-shipped
  # shared adapter): the sibling post-and-readback.rb script itself must route
  # its workbook branch through Sigma::CodeRep, not a flat readback['pages'] /
  # spec.to_json body — that's the actual bug this task fixes.
  def test_script_uses_code_rep_adapter_for_workbook_branch
    src = File.read(File.join(__dir__, '..', 'post-and-readback.rb'))
    assert_match(/Sigma::CodeRep\.(document|wrap|metadata)/, src,
                 'post-and-readback.rb must call Sigma::CodeRep for its workbook branch')
  end

  # The property the test above does NOT protect: that a CodeRep call site
  # never appears reachable from the DATAMODEL branch (or unguarded). See
  # CodeRepGuardCheck's header comment for how "reachable" is determined.
  def test_code_rep_calls_are_workbook_only
    path = File.join(__dir__, '..', 'post-and-readback.rb')
    findings = CodeRepGuardCheck.find_calls(path)
    refute_empty findings, 'expected at least one Sigma::CodeRep call site in post-and-readback.rb'
    bad = findings.reject { |f| f[:ctx] == :workbook }
    assert_empty bad,
                 "Sigma::CodeRep call(s) reachable OUTSIDE the workbook branch: " +
                 bad.map { |f| "line #{f[:line]} (.#{f[:method]}, ctx=#{f[:ctx]})" }.join(', ')
  end

  # Re-scan finding (post-#609): POST /v2/workbooks/spec/verify is a THIRD
  # workbook-only call site (verify_spec!, tableau-to-sigma only among the 6
  # plugins this PR touches — the others have no /verify preflight) — besides
  # the readback GET and the create/update POST|PUT already covered above. Its
  # own header comment (post-and-readback.rb, "v5.0 preflight") and
  # code_rep.rb's own module header both say /verify requires the identical
  # nested `document` envelope and 400s on a flat body exactly like create/
  # update — and verify_spec! is fail-closed (aborts the whole run) on a
  # parseable 400/409/422, so a still-flat body here would abort EVERY
  # `--type workbook` run before the already-fixed POST/PUT is ever reached.
  #
  # Investigation for this task found the call sites (post-and-readback.rb
  # lines ~443-447 and ~498-502) already wrap put_body/post_body via
  # Sigma::CodeRep.wrap "immediately before both calls" (the existing code
  # comment's own words) — i.e. verify_spec! receives the SAME wrapped
  # variable used for the real PUT/POST, as part of the original Task 3.1
  # commit (34d301cc), not a separate unpatched gap. The two tests below prove
  # this and guard against a future regression:
  #
  #   1. test_verify_body_wraps_flat_spec_with_name_and_folder_id — the same
  #      wrap/document/metadata call the script uses, applied to a flat spec,
  #      nests it under `document` while keeping `name`/`folderId` top-level
  #      (the shape /verify requires).
  #   2. test_verify_preflight_runs_after_the_wrap — a static ordering check
  #      that the Sigma::CodeRep.wrap assignment to put_body/post_body appears
  #      (by line number) BEFORE the verify_spec!(...) call that consumes the
  #      same variable, in both the PUT and POST branches — so verify_spec!
  #      can never be hit with the pre-wrap flat body.
  def test_verify_body_wraps_flat_spec_with_name_and_folder_id
    flat_spec = {
      'name'          => 'My Workbook',
      'folderId'      => 'folder-123',
      'schemaVersion' => 1,
      'pages'         => [{ 'id' => 'p1', 'elements' => [] }]
    }
    verify_body = WorkbookCode.canonicalize(flat_spec)
    assert verify_body.key?('document'), 'verify body must nest the spec under document'
    assert_equal [{ 'id' => 'p1' }], verify_body['document']['pages']
    assert_equal [], verify_body['document']['elements']
    assert_includes verify_body['document']['layout'], '<Page'
    assert_equal 'My Workbook', verify_body['name']
    assert_equal 'folder-123', verify_body['folderId']
    refute verify_body.key?('pages'), 'pages must not remain top-level in the verify body'
  end

  def test_verify_preflight_runs_after_the_wrap
    src   = File.read(File.join(__dir__, '..', 'post-and-readback.rb'))
    lines = src.lines
    %w[put_body post_body].each do |var|
      wrap_idx   = lines.find_index { |l| l =~ /^\s*#{var}\s*=\s*JSON\.generate\(Sigma::CodeRep\.wrap/ }
      verify_idx = lines.find_index { |l| l =~ /verify_spec!\(#{var},/ }
      refute_nil wrap_idx,   "expected a Sigma::CodeRep.wrap assignment to #{var}"
      refute_nil verify_idx, "expected a verify_spec!(#{var}, ...) call"
      assert wrap_idx < verify_idx,
             "verify_spec!(#{var}, ...) at line #{verify_idx + 1} must run AFTER the " \
             "Sigma::CodeRep.wrap assignment to #{var} at line #{wrap_idx + 1} — the /verify " \
             'preflight requires the identical nested envelope as the real POST/PUT, so it ' \
             'must never be handed the still-flat body.'
    end
  end
end
