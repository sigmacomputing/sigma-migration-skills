# frozen_string_literal: true
#
# test_phase6_parity_shape.rb — regression test for
# phase6-parity-thoughtspot.rb's workbook code-rep GET readback (Task 3.8).
#
# Live GET /v2/workbooks/{id}?includeContents=true nests non-metadata fields
# under a top-level `contents` key (`document` on the retired /spec GET).
# phase6-parity-thoughtspot.rb GETs the live workbook in PASS 1, enumerates
# flat contents.elements, and writes the unwrapped document to wb-readback.json.
#
# Run: ruby scripts/tests/test_phase6_parity_shape.rb

require 'minitest/autorun'
require_relative '../lib/code_rep'

SCRIPT_NAME = 'phase6-parity-thoughtspot.rb'

class TestPhase6ParityShape < Minitest::Test
  # Sanity-checks the shared adapter itself. Already shipped (Task 3.x), so
  # this alone would NOT fail pre-fix -- it documents the expected shape that
  # the real regression test below actually enforces against the script.
  def test_document_resolves_nested_readback
    readback = { 'workbookId' => 'w', 'contents' => { 'pages' => [{ 'id' => 'p1' }] } }
    assert_equal [{ 'id' => 'p1' }], Sigma::CodeRep.document(readback)['pages']
    assert_nil readback['pages'], 'proves the old flat read was nil'
    legacy = { 'workbookId' => 'w', 'document' => { 'pages' => [{ 'id' => 'p2' }] } }
    assert_equal [{ 'id' => 'p2' }], Sigma::CodeRep.document(legacy)['pages']
  end

  # The GET must use the non-deprecated endpoint via the shared path helper,
  # never the retired /spec path.
  def test_script_reads_via_read_path
    src = File.read(File.join(__dir__, '..', SCRIPT_NAME))
    assert_match(/Sigma::CodeRep\.read_path\(/, src,
                 "#{SCRIPT_NAME} must GET via Sigma::CodeRep.read_path(...)")
    refute_match(%r{workbooks/[^\s"']*/spec}, src.gsub(/^\s*#.*$/, ''),
                 "#{SCRIPT_NAME} must not call the deprecated /spec endpoint")
  end

  # Real regression signal: the script must route its GET readback through
  # Sigma::CodeRep.document(...) before writing wb-readback.json and enumerate
  # charts through workbook_elements (never pages[*].elements).
  def test_script_uses_code_rep_for_readback
    src = File.read(File.join(__dir__, '..', SCRIPT_NAME))
    assert_match(/Sigma::CodeRep\.document\(/, src,
                 "#{SCRIPT_NAME} must unwrap the GET readback via Sigma::CodeRep.document(...)")
    assert_match(/Sigma::CodeRep\.workbook_elements\(/, src,
                 "#{SCRIPT_NAME} must enumerate flat workbook elements")
    refute_match(/page\['elements'\]/, src,
                 "#{SCRIPT_NAME} must not assume pages own elements")
  end
end
