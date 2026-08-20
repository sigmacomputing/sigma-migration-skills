# frozen_string_literal: true
#
# test_phase6_parity_shape.rb — regression test for
# phase6-parity-quicksight.rb's workbook code-rep GET readback (Task 3.8).
#
# Live GET /v2/workbooks/{id}/spec now nests non-metadata fields under a
# top-level `document` key (verified 2026-08-03/04). phase6-parity-quicksight.rb
# GETs the live spec in PASS 1, reads spec['pages'] directly to enumerate
# chart elements, and writes the spec to wb-readback.json — this checks both
# reads route through the vendored Sigma::CodeRep.document() adapter rather
# than the raw (now-nested) GET response.
#
# Run: ruby scripts/tests/test_phase6_parity_shape.rb

require 'minitest/autorun'
require_relative '../lib/code_rep'

SCRIPT_NAME = 'phase6-parity-quicksight.rb'

class TestPhase6ParityShape < Minitest::Test
  # Sanity-checks the shared adapter itself. Already shipped (Task 3.x), so
  # this alone would NOT fail pre-fix -- it documents the expected shape that
  # the real regression test below actually enforces against the script.
  def test_document_resolves_nested_readback
    readback = { 'workbookId' => 'w', 'document' => { 'pages' => [{ 'id' => 'p1' }] } }
    assert_equal [{ 'id' => 'p1' }], Sigma::CodeRep.document(readback)['pages']
    assert_nil readback['pages'], 'proves the old flat read was nil'
  end

  # Real regression signal: the script must route its GET readback through
  # Sigma::CodeRep.document(...) before writing wb-readback.json / reading
  # spec['pages'] -- not the raw (now-nested) GET response.
  def test_script_uses_code_rep_for_readback
    src = File.read(File.join(__dir__, '..', SCRIPT_NAME))
    assert_match(/Sigma::CodeRep\.document\(/, src,
                 "#{SCRIPT_NAME} must unwrap the GET readback via Sigma::CodeRep.document(...)")
  end
end
