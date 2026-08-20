require 'minitest/autorun'
require_relative '../code_rep'

class TestParityChainShape < Minitest::Test
  NESTED = { 'workbookId' => 'w',
             'document' => { 'pages' => [{ 'id' => 'p' }],
                             'elements' => [{ 'id' => 'table', 'kind' => 'table' }],
                             'layout' => '<Page id="p"><Element elementId="table"/></Page>' } }

  # build-parity-plan.rb — the keystone silent failure.
  def test_parity_plan_sees_flat_document_elements
    elements = Sigma::CodeRep.workbook_elements(NESTED)
    refute_empty elements, 'parity plan must see document.elements, not silently zero them'
    assert_equal 'p', Sigma::CodeRep.workbook_page_by_element(NESTED)['table']['id']
    assert_empty(NESTED['elements'] || [], 'proves the old envelope-level read yielded zero elements')
  end

  # --emit-spec must write the INNER document so blind_grade/verify-anchors stay simple.
  def test_emit_spec_writes_unwrapped_document
    emitted = Sigma::CodeRep.document(NESTED)
    refute emitted.key?('document'), 'wb-readback.json must not be double-wrapped'
    refute_empty Array(emitted['elements'])
  end

  # enhance-scan.rb / enhance-apply.rb abort guards must stop aborting.
  def test_enhance_abort_guard_passes_on_nested
    refute_nil Sigma::CodeRep.document(NESTED)['elements'],
               'enhance-* abort guard must not fire on a nested readback'
  end

  def test_legacy_flat_readback_still_supported
    flat = { 'pages' => [{ 'id' => 'p' }], 'elements' => [{ 'id' => 'e' }],
             'layout' => '<Page id="p"><Element elementId="e"/></Page>' }
    assert_equal [{ 'id' => 'e' }], Sigma::CodeRep.workbook_elements(flat)
  end
end
