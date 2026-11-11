# frozen_string_literal: true
#
# test_put_layout_shape.rb — regression test for the workbook code-rep
# contents-wrapper handling. put-layout.rb is the mandatory "apply layout"
# step named in assert-phase6-ran.rb gate 4's own fix-it message. It does
# `spec = JSON.parse(GET /v2/workbooks/{id}?includeContents=true)` then
# `spec['pages'].each` then PUT /v2/workbooks/{id}/contents — the live API
# nests non-metadata fields under a top-level `contents` key, so a flat read
# leaves `spec['pages']` nil and iterating over it raises NoMethodError
# immediately, crashing the tool on every run.
#
# Run: ruby scripts/tests/test_put_layout_shape.rb

require 'minitest/autorun'
require_relative '../lib/code_rep'

class TestPutLayoutShape < Minitest::Test
  NESTED = { 'workbookId' => 'w', 'contents' => { 'pages' => [{ 'id' => 'p' }], 'layout' => nil } }

  def test_pages_iteration_does_not_raise_on_nested_readback
    # The bug: NESTED['pages'] is nil -> nil.each -> NoMethodError.
    assert_nil NESTED['pages'], 'proves the crash precondition'
    assert_equal [{ 'id' => 'p' }], Sigma::CodeRep.document(NESTED)['pages']
    Sigma::CodeRep.document(NESTED)['pages'].each { |p| assert p['id'] }   # must not raise
  end

  def test_put_body_is_wrapped
    doc = { 'pages' => [], 'layout' => '<Layout/>' }
    body = Sigma::CodeRep.update_body(doc)
    assert_equal doc.merge('elements' => []), body['contents']
    assert_equal ['contents'], body.keys
  end

  # Real regression signal: the two tests above only prove the already-shipped
  # shared adapter behaves as documented. This checks that put-layout.rb
  # itself actually calls it — not a flat spec['pages'] / JSON.pretty_generate
  # (spec) body, which is the actual bug this task fixes.
  def test_script_reads_via_code_rep_document
    src = File.read(File.join(__dir__, '..', 'put-layout.rb'))
    assert_match(/Sigma::CodeRep\.document\(/, src,
                 'put-layout.rb must unwrap the GET response via Sigma::CodeRep.document')
  end

  def test_script_writes_via_code_rep_update_body
    src = File.read(File.join(__dir__, '..', 'put-layout.rb'))
    assert_match(/Sigma::CodeRep\.update_body\(/, src,
                 'put-layout.rb must wrap the PUT body via Sigma::CodeRep.update_body')
    assert_match(/Sigma::CodeRep\.update_path\(/, src,
                 'put-layout.rb must PUT to Sigma::CodeRep.update_path')
    assert_match(/Sigma::CodeRep\.read_path\(/, src,
                 'put-layout.rb must GET via Sigma::CodeRep.read_path')
    refute_match(%r{workbooks/[^\s"']*/spec}, src.gsub(/^\s*#.*$/, ''),
                 'put-layout.rb must not call the deprecated /spec endpoint')
  end

  def test_sidecar_elements_are_injected_into_flat_collection
    src = File.read(File.join(__dir__, '..', 'put-layout.rb'))
    assert_match(/spec\['elements'\]\s*\|\|=/, src)
    assert_match(/spec\['elements'\]\s*<<\s*el/, src)
    refute_match(/page\['elements'\]\s*<<\s*el/, src,
                 'workbook pages are metadata-only; sidecar elements must be flat')
  end

  # Ordering: the document() unwrap must happen before the PUT, and the
  # update_body() must happen at (or immediately before) the PUT call — so
  # verify_spec!/http(:put, ...) can never be handed the still-flat spec.
  def test_unwrap_precedes_put_and_wrap_precedes_put
    src   = File.read(File.join(__dir__, '..', 'put-layout.rb'))
    lines = src.lines
    doc_idx  = lines.find_index { |l| l =~ /Sigma::CodeRep\.document\(/ }
    wrap_idx = lines.find_index { |l| l =~ /Sigma::CodeRep\.update_body\(/ }
    put_idx  = lines.find_index { |l| l =~ /http\(:put,/ }
    refute_nil doc_idx,  'expected a Sigma::CodeRep.document( call'
    refute_nil wrap_idx, 'expected a Sigma::CodeRep.update_body( call'
    refute_nil put_idx,  'expected an http(:put, ...) call'
    assert doc_idx < put_idx,  'the GET must be unwrapped before the PUT is issued'
    assert wrap_idx <= put_idx, 'the PUT body must be wrapped at or before the PUT call'
  end
end
