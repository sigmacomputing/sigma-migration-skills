require 'minitest/autorun'
require_relative '../code_rep'

# Regression pin for the phase-6 gate readback bug: assert-phase6-ran.rb's
# gate 4 (and probe-controls.rb) used to read spec['layout'] / spec['elements']
# flat on a live workbook readback. That surface nests non-metadata fields
# under a top-level key — `contents` on GET /v2/workbooks/{id}?includeContents=true,
# `document` on the retired GET /v2/workbooks/{id}/spec (verified live
# 2026-08-03/04 and 2026-11-03) — the flat read silently returned nil, so gate 4 hard-FAILed
# with exit 6 ("has NO top-level layout XML") on every workbook. Both gate
# scripts now route their live-spec reads through Sigma::CodeRep.document(),
# which this test pins.
class TestPhase6WorkbookReadback < Minitest::Test
  NESTED = { 'workbookId' => 'w', 'latestVersion' => 3, 'documentVersion' => 3,
             'contents' => { 'layout' => '<Page id="p"><Element elementId="kpi"/></Page>',
                             'pages' => [{ 'id' => 'p' }],
                             'elements' => [{ 'id' => 'kpi', 'kind' => 'kpi-chart' }] } }

  def test_gate_finds_elements_under_nested_document
    elements = Sigma::CodeRep.workbook_elements(NESTED)
    assert_equal 1, elements.length, 'gate must descend into document.elements'
    assert_nil Sigma::CodeRep.document(NESTED)['pages'].first['elements'],
               'workbook pages are metadata only'
  end

  # Gate 4 regression: this is the exit-6 "has NO top-level layout XML" failure.
  def test_gate4_finds_layout_under_nested_document
    refute_empty Sigma::CodeRep.document(NESTED)['layout'].to_s,
                 'gate 4 must read layout from document, not the envelope'
    assert_nil NESTED['layout'], 'proves the old top-level read returned nil'
  end

  # /spec-era readbacks (older wb-readback.json snapshots) keep the `document` key.
  def test_spec_era_document_readback_still_works
    old = { 'workbookId' => 'w', 'latestDocumentVersion' => 2,
            'document' => NESTED['contents'] }
    assert_equal Sigma::CodeRep.document(NESTED), Sigma::CodeRep.document(old)
    assert_equal 1, Sigma::CodeRep.workbook_elements(old).length
  end

  def test_legacy_flat_readback_still_works
    flat = { 'workbookId' => 'w',
             'layout' => '<Page id="p"><Element elementId="e"/></Page>',
             'pages' => [{ 'id' => 'p' }], 'elements' => [{ 'id' => 'e' }] }
    assert_equal [{ 'id' => 'p' }], Sigma::CodeRep.document(flat)['pages']
    assert_equal [{ 'id' => 'e' }], Sigma::CodeRep.workbook_elements(flat)
    refute_empty Sigma::CodeRep.document(flat)['layout'].to_s
  end
end
