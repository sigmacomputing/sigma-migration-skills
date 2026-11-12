# frozen_string_literal: true

# The per-element summary post-and-readback.rb writes into wb-ids.json for a workbook. The
# layout builder reads it, so what it keeps is a contract: a control keeps `controlType` (a
# legend control is told from a filter by it) and `colorAssignment` (its entry count sizes the
# legend's cell). Dropping either returns the live bug where a legend control landed in a
# control band (plan C live regression R5).
module WbIdsSummary
  module_function

  def element(element, column_labels = nil)
    summary = { 'id' => element['id'], 'kind' => element['kind'], 'name' => element['name'] }
    if element['kind'] == 'control'
      summary['controlType'] = element['controlType'] if element['controlType']
      summary['colorAssignment'] = element['colorAssignment'] if element['colorAssignment']
    end
    summary['columnLabels'] = column_labels if column_labels
    summary
  end
end
